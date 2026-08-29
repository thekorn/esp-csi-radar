const std = @import("std");

pub const max_csi_bytes = 384;

pub const MacAddress = [17]u8;

pub const Role = enum {
    TX,
    RX,
};

pub const Hello = struct {
    mac: MacAddress,
    chip: []const u8,
};

pub const Ready = struct {
    role: Role,
    mac: MacAddress,
    channel: u8,
    detail: []const u8,
};

pub const DeviceError = struct {
    message: []const u8,
};

pub const CsiFrame = struct {
    receiver: MacAddress,
    sequence: u32,
    timestamp_us: u64,
    rssi: i16,
    noise_floor: i16,
    channel: u8,
    dropped: u32,
    samples: [max_csi_bytes]i8,
    samples_len: u16,

    pub fn sampleSlice(frame: *const CsiFrame) []const i8 {
        return frame.samples[0..frame.samples_len];
    }
};

pub const Message = union(enum) {
    hello: Hello,
    ready: Ready,
    device_error: DeviceError,
    csi: CsiFrame,
};

pub const ParseError = error{
    InvalidMac,
    InvalidHello,
    InvalidReady,
    InvalidError,
    InvalidCsi,
    InvalidNumber,
    InvalidPayload,
    PayloadLengthMismatch,
};

pub fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidMac => "MAC address is invalid",
        error.InvalidHello => "HELLO requires MAC and chip",
        error.InvalidReady => "READY contains an invalid role, identity, or channel",
        error.InvalidError => "ERROR requires one message",
        error.InvalidCsi => "CSI requires nine metadata fields and a payload",
        error.InvalidNumber => "record contains invalid numeric data",
        error.InvalidPayload => "CSI payload must contain complete hexadecimal I/Q pairs",
        error.PayloadLengthMismatch => "CSI payload length does not match its declaration",
    };
}

pub fn normalizeMac(value: []const u8) ParseError!MacAddress {
    var compact: [12]u8 = undefined;
    var compact_len: usize = 0;
    for (value) |byte| {
        if (byte == ':' or byte == '-') continue;
        if (compact_len == compact.len or !std.ascii.isHex(byte)) return error.InvalidMac;
        compact[compact_len] = std.ascii.toLower(byte);
        compact_len += 1;
    }
    if (compact_len != compact.len) return error.InvalidMac;

    var result: MacAddress = undefined;
    for (0..6) |index| {
        result[index * 3] = compact[index * 2];
        result[index * 3 + 1] = compact[index * 2 + 1];
        if (index != 5) result[index * 3 + 2] = ':';
    }
    return result;
}

fn parseInteger(comptime T: type, value: []const u8) ParseError!T {
    if (value.len == 0) return error.InvalidNumber;
    return std.fmt.parseInt(T, value, 10) catch error.InvalidNumber;
}

fn hexNibble(byte: u8) ParseError!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidPayload,
    };
}

/// Parses a firmware record and ignores ESP-IDF logs and empty lines.
pub fn parseLine(line: []const u8) ParseError!?Message {
    const stripped = std.mem.trim(u8, line, " \t\r\n");
    if (stripped.len == 0 or !std.mem.startsWith(u8, stripped, "RADAR,")) return null;

    var parts: [12][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, stripped, ',');
    while (iterator.next()) |part| {
        if (count == parts.len) return error.InvalidCsi;
        parts[count] = part;
        count += 1;
    }
    if (count < 2) return error.InvalidCsi;

    if (std.mem.eql(u8, parts[1], "HELLO")) {
        if (count != 4) return error.InvalidHello;
        return .{ .hello = .{
            .mac = try normalizeMac(parts[2]),
            .chip = parts[3],
        } };
    }
    if (std.mem.eql(u8, parts[1], "READY")) {
        if (count != 6) return error.InvalidReady;
        const role: Role = if (std.mem.eql(u8, parts[2], "TX"))
            .TX
        else if (std.mem.eql(u8, parts[2], "RX"))
            .RX
        else
            return error.InvalidReady;
        const channel = parseInteger(u8, parts[4]) catch return error.InvalidReady;
        if (channel < 1 or channel > 13) return error.InvalidReady;
        return .{ .ready = .{
            .role = role,
            .mac = try normalizeMac(parts[3]),
            .channel = channel,
            .detail = parts[5],
        } };
    }
    if (std.mem.eql(u8, parts[1], "ERROR")) {
        if (count != 3) return error.InvalidError;
        return .{ .device_error = .{ .message = parts[2] } };
    }
    if (!std.mem.eql(u8, parts[1], "CSI")) return null;
    if (count != 11) return error.InvalidCsi;

    const receiver = try normalizeMac(parts[2]);
    const sequence = try parseInteger(u32, parts[3]);
    const timestamp_us = try parseInteger(u64, parts[4]);
    const rssi = try parseInteger(i16, parts[5]);
    const noise_floor = try parseInteger(i16, parts[6]);
    const channel = try parseInteger(u8, parts[7]);
    const dropped = try parseInteger(u32, parts[8]);
    const declared_length = try parseInteger(u16, parts[9]);
    const payload = parts[10];
    if (payload.len % 2 != 0 or declared_length == 0 or declared_length % 2 != 0) {
        return error.InvalidPayload;
    }
    const payload_length = payload.len / 2;
    if (payload_length != declared_length) return error.PayloadLengthMismatch;
    if (payload_length > max_csi_bytes) return error.InvalidPayload;
    if (channel < 1 or channel > 13) return error.InvalidNumber;

    var samples: [max_csi_bytes]i8 = undefined;
    for (0..payload_length) |index| {
        const high = try hexNibble(payload[index * 2]);
        const low = try hexNibble(payload[index * 2 + 1]);
        samples[index] = @bitCast(high << 4 | low);
    }
    return .{ .csi = .{
        .receiver = receiver,
        .sequence = sequence,
        .timestamp_us = timestamp_us,
        .rssi = rssi,
        .noise_floor = noise_floor,
        .channel = channel,
        .dropped = dropped,
        .samples = samples,
        .samples_len = declared_length,
    } };
}

test "protocol ignores logs and parses identity records" {
    try std.testing.expectEqual(null, try parseLine("I (328) wifi:mode : sta"));
    const hello = (try parseLine("RADAR,HELLO,F42DC96BF200,esp32\n")).?.hello;
    try std.testing.expectEqualStrings("f4:2d:c9:6b:f2:00", &hello.mac);
    try std.testing.expectEqualStrings("esp32", hello.chip);

    const ready = (try parseLine("RADAR,READY,TX,F42DC96BF200,6,20\n")).?.ready;
    try std.testing.expectEqual(Role.TX, ready.role);
    try std.testing.expectEqual(@as(u8, 6), ready.channel);
}

test "protocol parses signed CSI and rejects a truncated payload" {
    const frame = (try parseLine(
        "RADAR,CSI,e0:8c:fe:59:96:34,7,1234,-47,-94,6,2,4,00ff7f80",
    )).?.csi;
    try std.testing.expectEqualSlices(i8, &.{ 0, -1, 127, -128 }, frame.sampleSlice());
    try std.testing.expectEqual(@as(u32, 2), frame.dropped);
    try std.testing.expectError(
        error.PayloadLengthMismatch,
        parseLine("RADAR,CSI,e08cfe599634,7,1234,-47,-94,6,0,8,00ff"),
    );
}

test "protocol normalizes common MAC syntax and rejects malformed identities" {
    const normalized = try normalizeMac("E0-8C-FE-59-96-34");
    try std.testing.expectEqualStrings("e0:8c:fe:59:96:34", &normalized);
    try std.testing.expectError(error.InvalidMac, normalizeMac("e0:8c:fe:59:96"));
    try std.testing.expectError(error.InvalidMac, normalizeMac("e0:8c:fe:59:96:3g"));
    try std.testing.expectError(error.InvalidMac, normalizeMac("e0:8c:fe:59:96:34:00"));
}

test "protocol rejects invalid readiness and CSI fields" {
    try std.testing.expectError(
        error.InvalidReady,
        parseLine("RADAR,READY,INVALID,e08cfe599634,6,f42dc96bf200"),
    );
    try std.testing.expectError(
        error.InvalidReady,
        parseLine("RADAR,READY,RX,e08cfe599634,14,f42dc96bf200"),
    );
    try std.testing.expectError(
        error.InvalidPayload,
        parseLine("RADAR,CSI,e08cfe599634,7,1234,-47,-94,6,0,2,0ff"),
    );
    try std.testing.expectError(
        error.InvalidPayload,
        parseLine("RADAR,CSI,e08cfe599634,7,1234,-47,-94,6,0,2,00fg"),
    );
    try std.testing.expectError(
        error.InvalidNumber,
        parseLine("RADAR,CSI,e08cfe599634,7,1234,-47,-94,0,0,2,00ff"),
    );
}
