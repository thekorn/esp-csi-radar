const std = @import("std");
const application = @import("application.zig");
const assets = @import("assets");
const options_module = @import("options.zig");
const protocol = @import("protocol.zig");
const sources = @import("sources.zig");

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

    const address = parseBindAddress(options.bind, options.port) catch {
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

    while (true) {
        const stream = listener.accept(init.io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, connectionThread, .{
            &app,
            init.gpa,
            stream,
            options.verbose,
        }) catch |err| {
            stream.close(init.io);
            std.log.err("could not start connection: {s}", .{@errorName(err)});
            continue;
        };
        thread.detach();
    }
}

fn parseBindAddress(text: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.mem.eql(u8, text, "localhost")) {
        return .{ .ip4 = .loopback(port) };
    }
    return std.Io.net.IpAddress.parse(text, port);
}

fn connectionThread(
    app: *application.Application,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    verbose: bool,
) void {
    defer stream.close(app.io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(app.io, &read_buffer);
    var stream_writer = stream.writer(app.io, &write_buffer);
    var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = server.receiveHead() catch return;
        const target = request.head.target;
        const query_start = std.mem.findScalar(u8, target, '?') orelse target.len;
        const path = target[0..query_start];
        if (verbose and !std.mem.eql(u8, path, "/api/events")) {
            std.log.info("{t} {s}", .{ request.head.method, path });
        }
        const keep_serving = handleRequest(app, allocator, &request, path) catch |err| {
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
        var websocket = try request.respondWebSocket(.{ .key = key });
        try websocket.flush();
        handleDeviceSocket(app, &websocket);
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

fn handleDeviceSocket(app: *application.Application, websocket: *std.http.Server.WebSocket) void {
    var identity: ?application.SocketIdentity = null;
    defer app.disconnectSocket(identity);

    while (true) {
        const incoming = websocket.readSmallMessage() catch return;
        switch (incoming.opcode) {
            .ping => {
                websocket.writeMessage(incoming.data, .pong) catch return;
                continue;
            },
            .binary => {
                closeWebSocket(websocket, 1003, "text records required");
                return;
            },
            .text => {},
            else => return,
        }
        if (incoming.data.len > 1200) {
            closeWebSocket(websocket, 1009, "record exceeds 1200 bytes");
            return;
        }

        const message = protocol.parseLine(incoming.data) catch |err| {
            app.socketMalformed(identity, protocol.errorMessage(err));
            if (identity == null) {
                closeWebSocket(websocket, 1008, "invalid radar record");
                return;
            }
            continue;
        };
        if (message) |record| {
            app.applySocketMessage(&identity, &record) catch |err| {
                const reason = switch (err) {
                    error.UnknownIdentity, error.InconsistentIdentity => "unknown or inconsistent device identity",
                    error.IdentityRequired => "device identity required",
                    error.ReplacedConnection => "replaced by reconnect",
                };
                closeWebSocket(websocket, if (err == error.ReplacedConnection) 4000 else 1008, reason);
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
