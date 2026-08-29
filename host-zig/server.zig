const std = @import("std");
const application = @import("application.zig");
const assets = @import("assets");
const options_module = @import("options.zig");
const protocol = @import("protocol.zig");
const sources = @import("sources.zig");

const max_connections = 64;
const max_streaming_connections = 16;
const connection_stack_size = 2 * 1024 * 1024;
const request_timeout_seconds = 10;
const device_timeout_seconds = 45;
const replacement_timeout_seconds = 2;

const HELP =
    \\Usage: zig build run-host -- [options]
    \\
    \\Options:
    \\  --bind ADDRESS               HTTP bind address (default: 127.0.0.1)
    \\  --port PORT                  HTTP port (default: ESP_SERVER_PORT or 8080)
    \\  --rate HZ                    sample rate from 1 to 100 (default: 20)
    \\  --baud BAUD                  serial baud rate (default: 921600)
    \\  --ports PORT [PORT ...]      serial ports in esp32-1 through esp32-4 order
    \\  --serial                     ingest device records over USB serial (default)
    \\  --socket                     ingest device records at WebSocket path /device
    \\  --simulate                   generate CSI instead of opening serial ports
    \\  --calibration-samples COUNT  frames used for calibration (default: 80)
    \\  --hold-seconds SECONDS       occupancy hold duration (default: 20)
    \\  --verbose                    enable verbose request logging
    \\  -h, --help                   show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    var argument_iterator = init.minimal.args.iterate();
    _ = argument_iterator.next();
    var arguments: [64][]const u8 = undefined;
    var argument_count: usize = 0;
    while (argument_iterator.next()) |argument| {
        if (argument_count == arguments.len) {
            std.debug.print("too many command-line arguments\n", .{});
            return error.TooManyArguments;
        }
        arguments[argument_count] = argument;
        argument_count += 1;
    }

    const environment_port = init.environ_map.get("ESP_SERVER_PORT");
    const options = options_module.parse(arguments[0..argument_count], environment_port) catch |err| {
        std.debug.print("{s}\nUse --help for usage.\n", .{options_module.errorMessage(err)});
        return err;
    };
    if (options.help) {
        std.debug.print("{s}", .{HELP});
        return;
    }

    const address = resolveBindAddress(init.io, options.bind, options.port) catch {
        std.debug.print("invalid --bind address: {s}\n", .{options.bind});
        return error.InvalidBindAddress;
    };
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    var app = try application.Application.init(
        init.io,
        options.mode,
        options.rate,
        options.calibration_samples,
        options.hold_seconds,
        options.portSlice(),
    );
    switch (options.mode) {
        .simulation => try sources.startSimulator(&app),
        .serial => try sources.startSerial(&app, options.baud),
        .socket => {},
    }

    std.log.info(
        "serving {t} mode via {t} on http://{s}:{d}/",
        .{ app.mode, options.mode, options.bind, options.port },
    );

    var limiter: ConnectionLimiter = .{};
    while (true) {
        const stream = listener.accept(init.io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        if (!limiter.tryAcquire()) {
            stream.close(init.io);
            continue;
        }
        const thread = std.Thread.spawn(.{ .stack_size = connection_stack_size }, connectionThread, .{
            &app,
            init.gpa,
            stream,
            options.verbose,
            &limiter,
        }) catch |err| {
            limiter.release();
            stream.close(init.io);
            std.log.err("could not start connection: {s}", .{@errorName(err)});
            continue;
        };
        thread.detach();
    }
}

fn resolveBindAddress(io: std.Io, text: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.mem.eql(u8, text, "localhost")) {
        return .{ .ip4 = .loopback(port) };
    }
    if (std.Io.net.IpAddress.parse(text, port)) |address| {
        return address;
    } else |_| {}

    const host_name = try std.Io.net.HostName.init(text);
    var result_buffer: [16]std.Io.net.HostName.LookupResult = undefined;
    var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&result_buffer);
    try host_name.lookup(io, &results, .{ .port = port });
    while (true) {
        const result = results.getOneUncancelable(io) catch return error.NoAddressReturned;
        switch (result) {
            .address => |address| return address,
            .canonical_name => {},
        }
    }
}

const ConnectionLimiter = struct {
    active: std.atomic.Value(usize) = .init(0),
    streaming: std.atomic.Value(usize) = .init(0),

    fn tryAcquire(limiter: *ConnectionLimiter) bool {
        return tryIncrement(&limiter.active, max_connections);
    }

    fn release(limiter: *ConnectionLimiter) void {
        std.debug.assert(limiter.active.fetchSub(1, .monotonic) > 0);
    }

    fn tryAcquireStreaming(limiter: *ConnectionLimiter) bool {
        return tryIncrement(&limiter.streaming, max_streaming_connections);
    }

    fn releaseStreaming(limiter: *ConnectionLimiter) void {
        std.debug.assert(limiter.streaming.fetchSub(1, .monotonic) > 0);
    }

    fn tryIncrement(counter: *std.atomic.Value(usize), limit: usize) bool {
        var current = counter.load(.monotonic);
        while (current < limit) {
            current = counter.cmpxchgWeak(
                current,
                current + 1,
                .monotonic,
                .monotonic,
            ) orelse return true;
        }
        return false;
    }
};

const TimedStreamReader = struct {
    io: std.Io,
    interface: std.Io.Reader,
    stream: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    err: ?anyerror = null,

    fn init(stream: std.Io.net.Stream, io: std.Io, buffer: []u8) TimedStreamReader {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{
                    .stream = streamBytes,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .deadline = deadlineAfter(io, request_timeout_seconds),
        };
    }

    fn resetDeadline(reader: *TimedStreamReader, seconds: i64) void {
        reader.deadline = deadlineAfter(reader.io, seconds);
    }

    fn streamBytes(
        io_reader: *std.Io.Reader,
        io_writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const destination = limit.slice(try io_writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{destination};
        const count = try readVec(io_reader, &data);
        io_writer.advance(count);
        return count;
    }

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const reader: *TimedStreamReader = @alignCast(@fieldParentPtr("interface", io_reader));
        var vectors_buffer: [8][]u8 = undefined;
        const vector_count, const data_size = try io_reader.writableVector(&vectors_buffer, data);
        const vectors = vectors_buffer[0..vector_count];
        std.debug.assert(vectors[0].len > 0);
        const operation = reader.io.operateTimeout(.{ .net_read = .{
            .socket_handle = reader.stream.socket.handle,
            .data = vectors,
        } }, .{ .deadline = reader.deadline }) catch |err| {
            reader.err = err;
            return error.ReadFailed;
        };
        const count = operation.net_read catch |err| {
            reader.err = err;
            return error.ReadFailed;
        };
        if (count == 0) return error.EndOfStream;
        if (count > data_size) {
            reader.interface.end += count - data_size;
            return data_size;
        }
        return count;
    }
};

const TimedStreamWriter = struct {
    io: std.Io,
    interface: std.Io.Writer,
    stream: std.Io.net.Stream,
    timeout_seconds: i64 = request_timeout_seconds,
    err: ?anyerror = null,

    fn init(stream: std.Io.net.Stream, io: std.Io, buffer: []u8) TimedStreamWriter {
        return .{
            .io = io,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
            .stream = stream,
        };
    }

    fn drain(
        io_writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const writer: *TimedStreamWriter = @alignCast(@fieldParentPtr("interface", io_writer));
        const operation = writer.io.operateTimeout(.{ .net_write = .{
            .socket_handle = writer.stream.socket.handle,
            .header = io_writer.buffered(),
            .data = data,
            .splat = splat,
        } }, .{ .duration = awakeDuration(writer.timeout_seconds) }) catch |err| {
            writer.err = err;
            return error.WriteFailed;
        };
        const count = operation.net_write catch |err| {
            writer.err = err;
            return error.WriteFailed;
        };
        return io_writer.consume(count);
    }
};

fn awakeDuration(seconds: i64) std.Io.Clock.Duration {
    return .{ .raw = .fromSeconds(seconds), .clock = .awake };
}

fn deadlineAfter(io: std.Io, seconds: i64) std.Io.Clock.Timestamp {
    return .fromNow(io, awakeDuration(seconds));
}

fn connectionThread(
    app: *application.Application,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    verbose: bool,
    limiter: *ConnectionLimiter,
) void {
    defer limiter.release();
    defer stream.close(app.io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var stream_reader: TimedStreamReader = .init(stream, app.io, &read_buffer);
    var stream_writer: TimedStreamWriter = .init(stream, app.io, &write_buffer);
    var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        stream_reader.resetDeadline(request_timeout_seconds);
        var request = server.receiveHead() catch return;
        const target = request.head.target;
        const query_start = std.mem.findScalar(u8, target, '?') orelse target.len;
        const path = target[0..query_start];
        if (verbose and !std.mem.eql(u8, path, "/api/events")) {
            std.log.info("{t} {s}", .{ request.head.method, path });
        }
        const keep_serving = handleRequest(
            app,
            allocator,
            &request,
            path,
            stream,
            &stream_reader,
            &stream_writer,
            limiter,
        ) catch |err| {
            std.log.warn("request failed: {s}", .{@errorName(err)});
            request.respond("Internal Server Error", .{
                .status = .internal_server_error,
                .keep_alive = false,
            }) catch {};
            return;
        };
        if (!keep_serving) return;
    }
}

fn handleRequest(
    app: *application.Application,
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    path: []const u8,
    stream: std.Io.net.Stream,
    stream_reader: *TimedStreamReader,
    stream_writer: *TimedStreamWriter,
    limiter: *ConnectionLimiter,
) !bool {
    // A body-bearing HTTP method without framing cannot be safely followed by
    // another request on the same connection. The Zig HTTP server expects the
    // application to opt out of keep-alive in this case.
    if (request.head.method.requestHasBody() and
        request.head.transfer_encoding == .none and
        request.head.content_length == null)
    {
        request.head.keep_alive = false;
    }

    if (request.head.method == .GET and std.mem.eql(u8, path, "/device")) {
        if (app.source_mode != .socket) {
            try notFound(request);
            return request.head.keep_alive;
        }
        const key = switch (request.upgradeRequested()) {
            .websocket => |key| key orelse {
                try request.respond("Missing WebSocket key", .{ .status = .bad_request });
                return request.head.keep_alive;
            },
            else => {
                try notFound(request);
                return request.head.keep_alive;
            },
        };
        if (!limiter.tryAcquireStreaming()) {
            try request.respond("Too many streaming connections", .{
                .status = .service_unavailable,
                .keep_alive = false,
            });
            return false;
        }
        defer limiter.releaseStreaming();
        var websocket = try request.respondWebSocket(.{ .key = key });
        try websocket.flush();
        var device_socket: DeviceSocket = .{
            .io = app.io,
            .stream = stream,
            .reader = stream_reader,
            .writer = stream_writer,
            .websocket = &websocket,
            .owner = undefined,
        };
        device_socket.owner = .{
            .context = &device_socket,
            .replace_fn = DeviceSocket.replace,
        };
        handleDeviceSocket(app, &device_socket);
        return false;
    }

    if (request.head.method == .GET) {
        if (std.mem.eql(u8, path, "/api/state")) {
            const body = try app.snapshotJson(allocator);
            defer allocator.free(body);
            try request.respond(body, .{ .extra_headers = &.{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "content-type", .value = "application/json" },
            } });
            return request.head.keep_alive;
        }
        if (std.mem.eql(u8, path, "/api/health")) {
            const health = try app.healthJson(allocator);
            defer allocator.free(health.bytes);
            try request.respond(health.bytes, .{
                .status = if (health.healthy) .ok else .service_unavailable,
                .extra_headers = &.{
                    .{ .name = "cache-control", .value = "no-store" },
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
            return request.head.keep_alive;
        }
        if (std.mem.eql(u8, path, "/api/events")) {
            if (!limiter.tryAcquireStreaming()) {
                try request.respond("Too many streaming connections", .{
                    .status = .service_unavailable,
                    .keep_alive = false,
                });
                return false;
            }
            defer limiter.releaseStreaming();
            try eventStream(app, allocator, request);
            return false;
        }
        if (staticAsset(path)) |asset| {
            try request.respond(asset.body, .{ .extra_headers = &.{
                .{ .name = "cache-control", .value = asset.cache_control },
                .{ .name = "content-type", .value = asset.content_type },
            } });
            return request.head.keep_alive;
        }
    }

    if (request.head.method == .POST and std.mem.eql(u8, path, "/api/calibrate")) {
        app.reset();
        try request.respond("{\"ok\":true}", .{
            .status = .accepted,
            .extra_headers = &.{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return request.head.keep_alive;
    }

    try notFound(request);
    return request.head.keep_alive;
}

fn notFound(request: *std.http.Server.Request) !void {
    try request.respond("Not Found", .{ .status = .not_found });
}

const StaticAsset = struct {
    body: []const u8,
    content_type: []const u8,
    cache_control: []const u8,
};

fn staticAsset(path: []const u8) ?StaticAsset {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) return .{
        .body = assets.index_html,
        .content_type = "text/html; charset=utf-8",
        .cache_control = "no-cache",
    };
    if (std.mem.eql(u8, path, "/app.js")) return .{
        .body = assets.app_js,
        .content_type = "text/javascript; charset=utf-8",
        .cache_control = "public, max-age=300",
    };
    if (std.mem.eql(u8, path, "/styles.css")) return .{
        .body = assets.styles_css,
        .content_type = "text/css; charset=utf-8",
        .cache_control = "public, max-age=300",
    };
    return null;
}

fn eventStream(
    app: *application.Application,
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
) !void {
    var body_buffer: [16 * 1024]u8 = undefined;
    var body = try request.respondStreaming(&body_buffer, .{
        .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "content-type", .value = "text/event-stream" },
            },
        },
    });
    var event_id: u64 = 0;
    while (true) : (event_id +%= 1) {
        const json = try app.snapshotJson(allocator);
        defer allocator.free(json);
        body.writer.print("id: {d}\ndata: {s}\n\n", .{ event_id, json }) catch return;
        body.writer.flush() catch return;
        body.flush() catch return;
        std.Io.sleep(app.io, .fromMilliseconds(250), .awake) catch return;
    }
}

const DeviceSocket = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: *TimedStreamReader,
    writer: *TimedStreamWriter,
    websocket: *std.http.Server.WebSocket,
    write_mutex: std.Io.Mutex = .init,
    owner: application.SocketOwner,

    fn readSmallMessage(socket: *DeviceSocket) !std.http.Server.WebSocket.SmallMessage {
        socket.reader.resetDeadline(device_timeout_seconds);
        return socket.websocket.readSmallMessage();
    }

    fn writeMessage(
        socket: *DeviceSocket,
        data: []const u8,
        opcode: std.http.Server.WebSocket.Opcode,
    ) std.Io.Writer.Error!void {
        socket.write_mutex.lockUncancelable(socket.io);
        defer socket.write_mutex.unlock(socket.io);
        return socket.websocket.writeMessage(data, opcode);
    }

    fn close(socket: *DeviceSocket, code: u16, reason: []const u8) void {
        socket.write_mutex.lockUncancelable(socket.io);
        defer socket.write_mutex.unlock(socket.io);
        closeWebSocket(socket.websocket, code, reason);
    }

    fn replace(context: *anyopaque) void {
        const socket: *DeviceSocket = @ptrCast(@alignCast(context));
        socket.write_mutex.lockUncancelable(socket.io);
        defer socket.write_mutex.unlock(socket.io);
        socket.writer.timeout_seconds = replacement_timeout_seconds;
        closeWebSocket(socket.websocket, 4000, "replaced by reconnect");
        socket.stream.shutdown(socket.io, .both) catch {};
    }
};

fn handleDeviceSocket(app: *application.Application, socket: *DeviceSocket) void {
    var identity: ?application.SocketIdentity = null;
    defer app.disconnectSocket(identity, &socket.owner);

    while (true) {
        const incoming = socket.readSmallMessage() catch return;
        switch (incoming.opcode) {
            .ping => {
                socket.writeMessage(incoming.data, .pong) catch return;
                continue;
            },
            .binary => {
                socket.close(1003, "text records required");
                return;
            },
            .text => {},
            else => return,
        }
        if (incoming.data.len > 1200) {
            socket.close(1009, "record exceeds 1200 bytes");
            return;
        }

        const message = protocol.parseLine(incoming.data) catch |err| {
            app.socketMalformed(identity, protocol.errorMessage(err));
            if (identity == null) {
                socket.close(1008, "invalid radar record");
                return;
            }
            continue;
        };
        if (message) |record| {
            app.applySocketMessage(&identity, &socket.owner, &record) catch |err| {
                const reason = switch (err) {
                    error.UnknownIdentity, error.InconsistentIdentity => "unknown or inconsistent device identity",
                    error.IdentityRequired => "device identity required",
                    error.ReplacedConnection => "replaced by reconnect",
                };
                socket.close(if (err == error.ReplacedConnection) 4000 else 1008, reason);
                return;
            };
        }
    }
}

fn closeWebSocket(websocket: *std.http.Server.WebSocket, code: u16, reason: []const u8) void {
    var payload: [125]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], code, .big);
    const reason_len = @min(reason.len, payload.len - 2);
    @memcpy(payload[2..][0..reason_len], reason[0..reason_len]);
    websocket.writeMessage(payload[0 .. reason_len + 2], .connection_close) catch {};
}

test "connection limiter bounds total and streaming connections" {
    var limiter: ConnectionLimiter = .{};
    for (0..max_connections) |_| try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire());
    limiter.release();
    try std.testing.expect(limiter.tryAcquire());

    for (0..max_streaming_connections) |_| {
        try std.testing.expect(limiter.tryAcquireStreaming());
    }
    try std.testing.expect(!limiter.tryAcquireStreaming());
    limiter.releaseStreaming();
    try std.testing.expect(limiter.tryAcquireStreaming());
}

fn testServerRequest(app: *application.Application, request: []const u8) ![]u8 {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    const client_stream = try listener.socket.address.connect(std.testing.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer client_stream.close(std.testing.io);
    const server_stream = try listener.accept(std.testing.io);

    var write_buffer: [1024]u8 = undefined;
    var client_writer = client_stream.writer(std.testing.io, &write_buffer);
    try client_writer.interface.writeAll(request);
    try client_writer.interface.flush();

    var limiter: ConnectionLimiter = .{};
    try std.testing.expect(limiter.tryAcquire());
    connectionThread(
        app,
        std.testing.allocator,
        server_stream,
        false,
        &limiter,
    );

    var read_buffer: [1024]u8 = undefined;
    var client_reader = client_stream.reader(std.testing.io, &read_buffer);
    return client_reader.interface.allocRemaining(std.testing.allocator, .limited(64 * 1024));
}

test "server exposes state and calibration APIs" {
    var app = try application.Application.init(
        std.testing.io,
        .simulation,
        20,
        80,
        20,
        &.{},
    );
    const state_response = try testServerRequest(
        &app,
        "GET /api/state HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(state_response);
    try std.testing.expect(std.mem.indexOf(u8, state_response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, state_response, "content-type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, state_response, "\"mode\":\"simulation\"") != null);

    const calibrate_response = try testServerRequest(
        &app,
        "POST /api/calibrate HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(calibrate_response);
    try std.testing.expect(std.mem.indexOf(u8, calibrate_response, "HTTP/1.1 202 Accepted") != null);
    try std.testing.expect(std.mem.endsWith(u8, calibrate_response, "{\"ok\":true}"));

    const snapshot = try app.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("generation").?.integer);
}

test "server serves static assets and returns 404 for unknown routes" {
    var app = try application.Application.init(
        std.testing.io,
        .simulation,
        20,
        80,
        20,
        &.{},
    );
    const asset_response = try testServerRequest(
        &app,
        "GET /app.js?version=test HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(asset_response);
    try std.testing.expect(std.mem.indexOf(u8, asset_response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, asset_response, "content-type: text/javascript; charset=utf-8") != null);
    try std.testing.expect(std.mem.endsWith(u8, asset_response, assets.app_js));

    const missing_response = try testServerRequest(
        &app,
        "GET /missing HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n",
    );
    defer std.testing.allocator.free(missing_response);
    try std.testing.expect(std.mem.indexOf(u8, missing_response, "HTTP/1.1 404 Not Found") != null);
    try std.testing.expect(std.mem.endsWith(u8, missing_response, "Not Found"));
}
