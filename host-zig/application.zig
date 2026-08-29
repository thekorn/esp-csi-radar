const std = @import("std");
const detector = @import("detector.zig");
const protocol = @import("protocol.zig");

pub const SourceMode = enum {
    serial,
    socket,
    simulation,
};

pub const ApplicationMode = enum {
    simulation,
    hardware,
};

pub const HardwareDevice = struct {
    name: []const u8,
    role: protocol.Role,
    mac: []const u8,
};

pub const hardware_devices: [4]HardwareDevice = .{
    .{ .name = "esp32-1", .role = .TX, .mac = "f4:2d:c9:6b:f2:00" },
    .{ .name = "esp32-2", .role = .RX, .mac = "e0:8c:fe:59:96:34" },
    .{ .name = "esp32-3", .role = .RX, .mac = "e0:8c:fe:59:3f:9c" },
    .{ .name = "esp32-4", .role = .RX, .mac = "b0:cb:d8:cc:c5:a8" },
};

const socket_ports: [4][]const u8 = .{
    "ws://esp32-1",
    "ws://esp32-2",
    "ws://esp32-3",
    "ws://esp32-4",
};

const simulation_ports: [4][]const u8 = .{
    "sim://tx",
    "sim://rx-1",
    "sim://rx-2",
    "sim://rx-3",
};

const max_status_text = 160;
const max_chip_text = 64;

const DeviceStatus = struct {
    port: []const u8,
    role: protocol.Role,
    mac: protocol.MacAddress,
    connected: bool = false,
    ready: bool = false,
    chip_buffer: [max_chip_text]u8 = undefined,
    chip_len: usize = 0,
    error_buffer: [max_status_text]u8 = undefined,
    error_len: usize = 0,
    malformed: u64 = 0,
    socket_generation: u64 = 0,

    fn setChip(status: *DeviceStatus, chip_text: []const u8) void {
        status.chip_len = @min(chip_text.len, status.chip_buffer.len);
        @memcpy(status.chip_buffer[0..status.chip_len], chip_text[0..status.chip_len]);
    }

    fn setError(status: *DeviceStatus, message: []const u8) void {
        status.error_len = @min(message.len, status.error_buffer.len);
        @memcpy(status.error_buffer[0..status.error_len], message[0..status.error_len]);
    }

    fn clearError(status: *DeviceStatus) void {
        status.error_len = 0;
    }

    fn chip(status: *const DeviceStatus) ?[]const u8 {
        return if (status.chip_len == 0) null else status.chip_buffer[0..status.chip_len];
    }

    fn errorText(status: *const DeviceStatus) ?[]const u8 {
        return if (status.error_len == 0) null else status.error_buffer[0..status.error_len];
    }
};

pub const DeviceSnapshot = struct {
    port: []const u8,
    role: protocol.Role,
    connected: bool,
    ready: bool,
    mac: protocol.MacAddress,
    chip: ?[]const u8,
    @"error": ?[]const u8,
    malformed: u64,
};

const DeviceSnapshots = struct {
    values: [4]DeviceSnapshot = undefined,
    len: usize = 0,

    pub fn jsonStringify(self: *const DeviceSnapshots, json: anytype) !void {
        try json.beginArray();
        for (self.values[0..self.len]) |value| try json.write(value);
        try json.endArray();
    }
};

const ApplicationSnapshot = struct {
    state: detector.State,
    occupied: bool,
    score: f64,
    calibration: f64,
    holdRemainingSeconds: f64,
    generation: u64,
    links: detector.LinkSnapshots,
    mode: ApplicationMode,
    sampleRateHz: u16,
    uptimeSeconds: f64,
    devices: DeviceSnapshots,
};

pub const SocketIdentity = struct {
    index: usize,
    generation: u64,
};

pub const SocketMessageError = error{
    UnknownIdentity,
    InconsistentIdentity,
    IdentityRequired,
    ReplacedConnection,
};

pub const Application = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    detector: detector.RoomDetector,
    source_mode: SourceMode,
    mode: ApplicationMode,
    rate_hz: u16,
    started_at: f64,
    statuses: [4]DeviceStatus = undefined,
    status_count: usize = 0,

    pub fn init(
        io: std.Io,
        source_mode: SourceMode,
        rate_hz: u16,
        calibration_samples: u32,
        hold_seconds: f64,
        ports: []const []const u8,
    ) !Application {
        var result: Application = .{
            .io = io,
            .detector = try .init(calibration_samples, hold_seconds),
            .source_mode = source_mode,
            .mode = if (source_mode == .simulation) .simulation else .hardware,
            .rate_hz = rate_hz,
            .started_at = nowSeconds(io),
        };

        var ordered_ports: [4][]const u8 = undefined;
        const selected_ports: []const []const u8 = switch (source_mode) {
            .simulation => &simulation_ports,
            .socket => &socket_ports,
            .serial => blk: {
                if (ports.len < 2 or ports.len > hardware_devices.len) {
                    return error.InvalidSerialPortCount;
                }
                @memcpy(ordered_ports[0..ports.len], ports);
                std.mem.sort([]const u8, ordered_ports[0..ports.len], {}, struct {
                    fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                        return std.mem.order(u8, left, right) == .lt;
                    }
                }.lessThan);
                break :blk ordered_ports[0..ports.len];
            },
        };

        result.status_count = selected_ports.len;
        for (selected_ports, hardware_devices[0..selected_ports.len], 0..) |port, device, index| {
            result.statuses[index] = .{
                .port = port,
                .role = device.role,
                .mac = protocol.normalizeMac(device.mac) catch unreachable,
            };
            if (source_mode == .simulation) {
                result.statuses[index].connected = true;
                result.statuses[index].ready = true;
                result.statuses[index].setChip("esp32-simulated");
            }
        }
        return result;
    }

    pub fn now(app: *const Application) f64 {
        return nowSeconds(app.io);
    }

    pub fn statusCount(app: *const Application) usize {
        return app.status_count;
    }

    pub fn statusPort(app: *const Application, index: usize) []const u8 {
        return app.statuses[index].port;
    }

    pub fn receiverMac(index: usize) protocol.MacAddress {
        return protocol.normalizeMac(hardware_devices[index + 1].mac) catch unreachable;
    }

    pub fn ingest(app: *Application, frame: *const protocol.CsiFrame) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        app.detector.ingest(frame, nowSeconds(app.io));
    }

    pub fn reset(app: *Application) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        app.detector.reset();
    }

    pub fn markSerialConnected(app: *Application, index: usize) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        const status = &app.statuses[index];
        status.connected = true;
        status.ready = false;
        status.clearError();
    }

    pub fn markSerialDisconnected(app: *Application, index: usize) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        const status = &app.statuses[index];
        status.connected = false;
        status.ready = false;
    }

    pub fn serialError(app: *Application, index: usize, message: []const u8) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        app.statuses[index].setError(message);
    }

    pub fn malformedRecord(app: *Application, index: usize, message: []const u8) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        const status = &app.statuses[index];
        status.malformed += 1;
        status.setError(message);
    }

    pub fn applySerialMessage(app: *Application, index: usize, message: *const protocol.Message) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        app.applyMessageLocked(index, message);
    }

    pub fn applySocketMessage(
        app: *Application,
        identity: *?SocketIdentity,
        message: *const protocol.Message,
    ) SocketMessageError!void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);

        const message_mac: ?protocol.MacAddress = switch (message.*) {
            .hello => |hello| hello.mac,
            .ready => |ready| ready.mac,
            .csi => |frame| frame.receiver,
            .device_error => null,
        };
        if (message_mac) |mac| {
            const index = app.findStatusLocked(&mac) orelse return error.UnknownIdentity;
            if (identity.*) |known| {
                if (known.index != index) return error.InconsistentIdentity;
            } else {
                const status = &app.statuses[index];
                status.socket_generation +%= 1;
                status.connected = true;
                status.clearError();
                identity.* = .{ .index = index, .generation = status.socket_generation };
            }
        }

        const known = identity.* orelse return error.IdentityRequired;
        if (app.statuses[known.index].socket_generation != known.generation) {
            return error.ReplacedConnection;
        }
        app.applyMessageLocked(known.index, message);
    }

    pub fn socketMalformed(app: *Application, identity: ?SocketIdentity, message: []const u8) void {
        const known = identity orelse return;
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        const status = &app.statuses[known.index];
        if (status.socket_generation != known.generation) return;
        status.malformed += 1;
        status.setError(message);
    }

    pub fn disconnectSocket(app: *Application, identity: ?SocketIdentity) void {
        const known = identity orelse return;
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        const status = &app.statuses[known.index];
        if (status.socket_generation != known.generation) return;
        status.connected = false;
        status.ready = false;
    }

    pub fn snapshotJson(app: *Application, allocator: std.mem.Allocator) ![]u8 {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try std.json.Stringify.value(app.snapshotLocked(), .{}, &output.writer);
        return output.toOwnedSlice();
    }

    pub fn healthJson(app: *Application, allocator: std.mem.Allocator) !struct {
        bytes: []u8,
        healthy: bool,
    } {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);

        var ready_receivers: usize = 0;
        for (app.statuses[0..app.status_count]) |status| {
            if (status.role == .RX and status.ready) ready_receivers += 1;
        }
        const detector_snapshot = app.detector.snapshot(nowSeconds(app.io));
        const healthy = ready_receivers >= 1;
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try std.json.Stringify.value(.{
            .ok = healthy,
            .readyReceivers = ready_receivers,
            .state = detector_snapshot.state,
        }, .{}, &output.writer);
        return .{ .bytes = try output.toOwnedSlice(), .healthy = healthy };
    }

    fn findStatusLocked(app: *const Application, mac: *const protocol.MacAddress) ?usize {
        for (app.statuses[0..app.status_count], 0..) |status, index| {
            if (std.mem.eql(u8, &status.mac, mac)) return index;
        }
        return null;
    }

    fn applyMessageLocked(app: *Application, index: usize, message: *const protocol.Message) void {
        const status = &app.statuses[index];
        switch (message.*) {
            .hello => |hello| {
                if (!std.mem.eql(u8, &hello.mac, &status.mac)) {
                    status.ready = false;
                    const text = std.fmt.bufPrint(
                        &status.error_buffer,
                        "expected {s}, received {s}",
                        .{ status.mac, hello.mac },
                    ) catch {
                        status.setError("device identity does not match its assigned port");
                        return;
                    };
                    status.error_len = text.len;
                    return;
                }
                status.setChip(hello.chip);
                status.clearError();
            },
            .ready => |ready| {
                status.ready = ready.role == status.role and std.mem.eql(u8, &ready.mac, &status.mac);
                if (status.ready) {
                    status.clearError();
                } else {
                    status.setError("firmware acknowledged the wrong identity or role");
                }
            },
            .device_error => |device_error| status.setError(device_error.message),
            .csi => |frame| {
                if (status.role != .RX or !std.mem.eql(u8, &frame.receiver, &status.mac)) {
                    status.setError("received CSI for the wrong device");
                    return;
                }
                status.ready = true;
                status.clearError();
                app.detector.ingest(&frame, nowSeconds(app.io));
            },
        }
    }

    fn snapshotLocked(app: *const Application) ApplicationSnapshot {
        const timestamp = nowSeconds(app.io);
        const detector_snapshot = app.detector.snapshot(timestamp);
        var devices: DeviceSnapshots = .{ .len = app.status_count };
        for (app.statuses[0..app.status_count], 0..) |*status, index| {
            devices.values[index] = .{
                .port = status.port,
                .role = status.role,
                .connected = status.connected,
                .ready = status.ready,
                .mac = status.mac,
                .chip = status.chip(),
                .@"error" = status.errorText(),
                .malformed = status.malformed,
            };
        }
        return .{
            .state = detector_snapshot.state,
            .occupied = detector_snapshot.occupied,
            .score = detector_snapshot.score,
            .calibration = detector_snapshot.calibration,
            .holdRemainingSeconds = detector_snapshot.holdRemainingSeconds,
            .generation = detector_snapshot.generation,
            .links = detector_snapshot.links,
            .mode = app.mode,
            .sampleRateHz = app.rate_hz,
            .uptimeSeconds = round(timestamp - app.started_at, 1),
            .devices = devices,
        };
    }
};

fn nowSeconds(io: std.Io) f64 {
    const nanoseconds = std.Io.Clock.awake.now(io).toNanoseconds();
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s;
}

fn round(value: f64, digits: u8) f64 {
    const factor = std.math.pow(f64, 10, @floatFromInt(digits));
    return @round(value * factor) / factor;
}

test "application emits the reference JSON schema" {
    var app = try Application.init(std.testing.io, .simulation, 20, 80, 20, &.{});
    const json = try app.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("offline", parsed.value.object.get("state").?.string);
    try std.testing.expectEqualStrings("simulation", parsed.value.object.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, 20), parsed.value.object.get("sampleRateHz").?.integer);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.object.get("devices").?.array.items.len);
}

test "socket records associate a known receiver and update readiness" {
    var app = try Application.init(std.testing.io, .socket, 20, 80, 20, &.{});
    var identity: ?SocketIdentity = null;
    const hello = (try protocol.parseLine("RADAR,HELLO,e08cfe599634,esp32\n")).?;
    try app.applySocketMessage(&identity, &hello);
    const ready = (try protocol.parseLine("RADAR,READY,RX,e08cfe599634,6,f42dc96bf200\n")).?;
    try app.applySocketMessage(&identity, &ready);

    const health = try app.healthJson(std.testing.allocator);
    defer std.testing.allocator.free(health.bytes);
    try std.testing.expect(health.healthy);
    try std.testing.expectError(error.UnknownIdentity, app.applySocketMessage(
        &identity,
        &(try protocol.parseLine("RADAR,HELLO,001122334455,esp32\n")).?,
    ));
}
