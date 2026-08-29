//! Application behavior for the shared four-device ESP32 radar firmware.

const std = @import("std");
const builtin = @import("builtin");

const default_channel: u8 = 6;
const default_rate_hz: u8 = 20;
const max_csi_bytes = 384;

const RxConfig = struct {
    channel: u8,
    transmitter_mac: [6]u8,
};

const TxConfig = struct {
    channel: u8,
    rate_hz: u8,
};

const Command = union(enum) {
    info,
    tx: TxConfig,
    rx: RxConfig,
};

const ParseError = error{
    InvalidCommand,
    InvalidChannel,
    InvalidRate,
    InvalidMac,
};

extern fn platform_init() void;
extern fn platform_get_mac(output: *[6]u8) void;
extern fn platform_start_tx(channel: u8) u8;
extern fn platform_send_probe(data: [*]const u8, length: u16) u8;
extern fn platform_start_rx(channel: u8, transmitter_mac: *const [6]u8) u8;
extern fn platform_csi_read(
    data: [*]i8,
    capacity: u16,
    length: *u16,
    timestamp_us: *u32,
    rssi: *i8,
    noise_floor: *i8,
    channel: *u8,
    dropped: *u32,
) u8;
extern fn platform_read_char() i32;
extern fn platform_write(data: [*]const u8, length: u16) void;
extern fn platform_millis() u64;
extern fn platform_delay_ms(delay_ms: u32) void;

fn parseU8(value: []const u8, minimum: u8, maximum: u8, parse_error: ParseError) ParseError!u8 {
    const parsed = std.fmt.parseInt(u8, value, 10) catch return parse_error;
    if (parsed < minimum or parsed > maximum) return parse_error;
    return parsed;
}

fn hexValue(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

fn parseMac(value: []const u8) ParseError![6]u8 {
    var compact: [12]u8 = undefined;
    var compact_length: usize = 0;
    for (value) |character| {
        if (character == ':' or character == '-') continue;
        if (compact_length == compact.len) return error.InvalidMac;
        compact[compact_length] = character;
        compact_length += 1;
    }
    if (compact_length != compact.len) return error.InvalidMac;

    var mac: [6]u8 = undefined;
    for (0..mac.len) |index| {
        const upper = hexValue(compact[index * 2]) orelse return error.InvalidMac;
        const lower = hexValue(compact[index * 2 + 1]) orelse return error.InvalidMac;
        mac[index] = upper * 16 + lower;
    }
    return mac;
}

fn parseCommand(line: []const u8) ParseError!Command {
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \r\n"), ',');
    const name = parts.next() orelse return error.InvalidCommand;

    if (std.ascii.eqlIgnoreCase(name, "INFO")) {
        if (parts.next() != null) return error.InvalidCommand;
        return .info;
    }
    if (!std.ascii.eqlIgnoreCase(name, "ROLE")) return error.InvalidCommand;

    const role = parts.next() orelse return error.InvalidCommand;
    if (std.ascii.eqlIgnoreCase(role, "TX")) {
        const channel_text = parts.next() orelse return error.InvalidCommand;
        const rate_text = parts.next() orelse return error.InvalidCommand;
        if (parts.next() != null) return error.InvalidCommand;
        return .{ .tx = .{
            .channel = try parseU8(channel_text, 1, 13, error.InvalidChannel),
            .rate_hz = try parseU8(rate_text, 1, 100, error.InvalidRate),
        } };
    }
    if (std.ascii.eqlIgnoreCase(role, "RX")) {
        const channel_text = parts.next() orelse return error.InvalidCommand;
        const mac_text = parts.next() orelse return error.InvalidCommand;
        if (parts.next() != null) return error.InvalidCommand;
        return .{ .rx = .{
            .channel = try parseU8(channel_text, 1, 13, error.InvalidChannel),
            .transmitter_mac = try parseMac(mac_text),
        } };
    }
    return error.InvalidCommand;
}

fn write(bytes: []const u8) void {
    platform_write(bytes.ptr, @intCast(bytes.len));
}

fn formatMac(buffer: *[17]u8, mac: [6]u8) []const u8 {
    const digits = "0123456789abcdef";
    for (0..mac.len) |index| {
        const offset = index * 3;
        buffer[offset] = digits[mac[index] >> 4];
        buffer[offset + 1] = digits[mac[index] & 0x0f];
        if (index + 1 < mac.len) buffer[offset + 2] = ':';
    }
    return buffer;
}

fn writeHello(mac: [6]u8) void {
    var mac_buffer: [17]u8 = undefined;
    var line_buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "RADAR,HELLO,{s},esp32\n", .{
        formatMac(&mac_buffer, mac),
    }) catch return;
    write(line);
}

fn readLine(buffer: []u8) []const u8 {
    var length: usize = 0;
    while (true) {
        const input = platform_read_char();
        if (input < 0) continue;
        const character: u8 = @intCast(input & 0xff);
        if (character == '\n' or character == '\r') {
            if (length != 0) return buffer[0..length];
            continue;
        }
        if (length < buffer.len) {
            buffer[length] = character;
            length += 1;
        }
    }
}

fn putLittleEndian32(buffer: *[12]u8, offset: usize, value: u32) void {
    buffer[offset] = @truncate(value);
    buffer[offset + 1] = @truncate(value >> 8);
    buffer[offset + 2] = @truncate(value >> 16);
    buffer[offset + 3] = @truncate(value >> 24);
}

fn runTransmitter(mac: [6]u8, config: TxConfig) noreturn {
    if (platform_start_tx(config.channel) == 0) {
        write("RADAR,ERROR,tx_start_failed\n");
        while (true) platform_delay_ms(1000);
    }

    var mac_buffer: [17]u8 = undefined;
    var ready_buffer: [96]u8 = undefined;
    const ready = std.fmt.bufPrint(&ready_buffer, "RADAR,READY,TX,{s},{d},{d}\n", .{
        formatMac(&mac_buffer, mac), config.channel, config.rate_hz,
    }) catch unreachable;
    write(ready);

    var sequence: u32 = 0;
    var failures: u32 = 0;
    var previous_status = platform_millis();
    const period_ms: u32 = @max(1, 1000 / @as(u32, config.rate_hz));

    while (true) {
        var probe = [_]u8{ 'C', 'S', 'I', 'R', 0, 0, 0, 0, 0, 0, 0, 0 };
        putLittleEndian32(&probe, 4, sequence);
        putLittleEndian32(&probe, 8, @truncate(platform_millis()));
        if (platform_send_probe(&probe, probe.len) == 0) failures +%= 1;
        sequence +%= 1;

        const now = platform_millis();
        if (now - previous_status >= 5000) {
            var status_buffer: [80]u8 = undefined;
            const status = std.fmt.bufPrint(&status_buffer, "RADAR,TX_STATUS,{d},{d}\n", .{
                sequence, failures,
            }) catch unreachable;
            write(status);
            previous_status = now;
        }
        platform_delay_ms(period_ms);
    }
}

fn runReceiver(mac: [6]u8, config: RxConfig) noreturn {
    if (platform_start_rx(config.channel, &config.transmitter_mac) == 0) {
        write("RADAR,ERROR,rx_start_failed\n");
        while (true) platform_delay_ms(1000);
    }

    var mac_buffer: [17]u8 = undefined;
    var tx_mac_buffer: [17]u8 = undefined;
    var ready_buffer: [112]u8 = undefined;
    const mac_text = formatMac(&mac_buffer, mac);
    const ready = std.fmt.bufPrint(&ready_buffer, "RADAR,READY,RX,{s},{d},{s}\n", .{
        mac_text, config.channel, formatMac(&tx_mac_buffer, config.transmitter_mac),
    }) catch unreachable;
    write(ready);

    var sequence: u32 = 0;
    var csi_data: [max_csi_bytes]i8 = undefined;
    while (true) {
        var length: u16 = 0;
        var timestamp_us: u32 = 0;
        var rssi: i8 = 0;
        var noise_floor: i8 = 0;
        var channel: u8 = 0;
        var dropped: u32 = 0;
        if (platform_csi_read(
            &csi_data,
            csi_data.len,
            &length,
            &timestamp_us,
            &rssi,
            &noise_floor,
            &channel,
            &dropped,
        ) == 0) {
            platform_delay_ms(1);
            continue;
        }

        var line_buffer: [960]u8 = undefined;
        const header = std.fmt.bufPrint(&line_buffer, "RADAR,CSI,{s},{d},{d},{d},{d},{d},{d},{d},", .{
            mac_text,
            sequence,
            timestamp_us,
            rssi,
            noise_floor,
            channel,
            dropped,
            length,
        }) catch continue;
        var output_length = header.len;
        const digits = "0123456789abcdef";
        for (csi_data[0..length]) |signed_sample| {
            const sample: u8 = @bitCast(signed_sample);
            line_buffer[output_length] = digits[sample >> 4];
            line_buffer[output_length + 1] = digits[sample & 0x0f];
            output_length += 2;
        }
        line_buffer[output_length] = '\n';
        output_length += 1;
        write(line_buffer[0..output_length]);
        sequence +%= 1;
    }
}

pub fn app_main() callconv(.c) void {
    platform_init();
    var mac: [6]u8 = undefined;
    platform_get_mac(&mac);
    writeHello(mac);

    var command_buffer: [96]u8 = undefined;
    while (true) {
        const command = parseCommand(readLine(&command_buffer)) catch {
            write("RADAR,ERROR,invalid_command\n");
            continue;
        };
        switch (command) {
            .info => writeHello(mac),
            .tx => |config| runTransmitter(mac, config),
            .rx => |config| runReceiver(mac, config),
        }
    }
}

test "parses transmitter role" {
    const command = try parseCommand("ROLE,TX,6,20\r\n");
    switch (command) {
        .tx => |config| {
            try std.testing.expectEqual(@as(u8, default_channel), config.channel);
            try std.testing.expectEqual(@as(u8, default_rate_hz), config.rate_hz);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parses receiver role and colon separated MAC" {
    const command = try parseCommand("ROLE,RX,11,f4:2d:c9:6b:f2:00");
    switch (command) {
        .rx => |config| {
            try std.testing.expectEqual(@as(u8, 11), config.channel);
            try std.testing.expectEqualSlices(u8, &.{ 0xf4, 0x2d, 0xc9, 0x6b, 0xf2, 0x00 }, &config.transmitter_mac);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "rejects unsafe radio settings" {
    try std.testing.expectError(error.InvalidChannel, parseCommand("ROLE,TX,14,20"));
    try std.testing.expectError(error.InvalidRate, parseCommand("ROLE,TX,6,0"));
    try std.testing.expectError(error.InvalidMac, parseCommand("ROLE,RX,6,not-a-mac"));
}

test "formats stable MAC identity" {
    var buffer: [17]u8 = undefined;
    try std.testing.expectEqualStrings("f4:2d:c9:6b:f2:00", formatMac(&buffer, .{
        0xf4, 0x2d, 0xc9, 0x6b, 0xf2, 0x00,
    }));
}

comptime {
    if (!builtin.is_test) {
        @export(&app_main, .{ .name = "app_main" });
    }
}
