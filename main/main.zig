//! Application behavior for the shared four-device ESP32 radar firmware.

const std = @import("std");
const builtin = @import("builtin");
const firmware_options = @import("firmware_options");

const sample_rate_hz: u8 = 20;
const max_csi_bytes = 384;
const status_interval_ms = 5000;

const DeviceRole = enum {
    tx,
    rx,
};

const Device = struct {
    name: []const u8,
    mac: [6]u8,
    role: DeviceRole,
};

const transmitter_mac = [6]u8{ 0xf4, 0x2d, 0xc9, 0x6b, 0xf2, 0x00 };
const devices = [_]Device{
    .{ .name = "esp32-1", .mac = transmitter_mac, .role = .tx },
    .{ .name = "esp32-2", .mac = .{ 0xe0, 0x8c, 0xfe, 0x59, 0x96, 0x34 }, .role = .rx },
    .{ .name = "esp32-3", .mac = .{ 0xe0, 0x8c, 0xfe, 0x59, 0x3f, 0x9c }, .role = .rx },
    .{ .name = "esp32-4", .mac = .{ 0xb0, 0xcb, 0xd8, 0xcc, 0xc5, 0xa8 }, .role = .rx },
};

extern fn platform_init() void;
extern fn platform_get_mac(output: *[6]u8) void;
extern fn platform_connect_wifi(
    network_name: [*]const u8,
    network_name_length: u8,
    network_secret: [*]const u8,
    network_secret_length: u8,
    hostname: [*]const u8,
    hostname_length: u8,
    channel: *u8,
) u8;
extern fn platform_start_websocket(server_host: [*]const u8, server_host_length: u16, server_port: u16) u8;
extern fn platform_start_tx() u8;
extern fn platform_send_probe(data: [*]const u8, length: u16) u8;
extern fn platform_start_rx(transmitter: *const [6]u8) u8;
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
extern fn platform_write(data: [*]const u8, length: u16) void;
extern fn platform_millis() u64;
extern fn platform_delay_ms(delay_ms: u32) void;

fn identifyDevice(mac: [6]u8) ?*const Device {
    for (&devices) |*device| {
        if (std.mem.eql(u8, &device.mac, &mac)) return device;
    }
    return null;
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

fn writeTransmitterReady(mac: [6]u8, channel: u8) void {
    var mac_buffer: [17]u8 = undefined;
    var line_buffer: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "RADAR,READY,TX,{s},{d},{d}\n", .{
        formatMac(&mac_buffer, mac), channel, sample_rate_hz,
    }) catch return;
    write(line);
}

fn writeReceiverReady(mac: [6]u8, channel: u8) void {
    var mac_buffer: [17]u8 = undefined;
    var tx_mac_buffer: [17]u8 = undefined;
    var line_buffer: [112]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "RADAR,READY,RX,{s},{d},{s}\n", .{
        formatMac(&mac_buffer, mac), channel, formatMac(&tx_mac_buffer, transmitter_mac),
    }) catch return;
    write(line);
}

fn announceTransmitter(mac: [6]u8, channel: u8) void {
    writeHello(mac);
    writeTransmitterReady(mac, channel);
}

fn announceReceiver(mac: [6]u8, channel: u8) void {
    writeHello(mac);
    writeReceiverReady(mac, channel);
}

fn putLittleEndian32(buffer: *[12]u8, offset: usize, value: u32) void {
    buffer[offset] = @truncate(value);
    buffer[offset + 1] = @truncate(value >> 8);
    buffer[offset + 2] = @truncate(value >> 16);
    buffer[offset + 3] = @truncate(value >> 24);
}

fn runTransmitter(mac: [6]u8, channel: u8) noreturn {
    if (platform_start_tx() == 0) {
        write("RADAR,ERROR,tx_start_failed\n");
        while (true) platform_delay_ms(1000);
    }
    announceTransmitter(mac, channel);

    var sequence: u32 = 0;
    var failures: u32 = 0;
    var previous_status = platform_millis();
    const period_ms: u32 = 1000 / @as(u32, sample_rate_hz);

    while (true) {
        var probe = [_]u8{ 'C', 'S', 'I', 'R', 0, 0, 0, 0, 0, 0, 0, 0 };
        putLittleEndian32(&probe, 4, sequence);
        putLittleEndian32(&probe, 8, @truncate(platform_millis()));
        if (platform_send_probe(&probe, probe.len) == 0) failures +%= 1;
        sequence +%= 1;

        const now = platform_millis();
        if (now - previous_status >= status_interval_ms) {
            announceTransmitter(mac, channel);
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

fn runReceiver(mac: [6]u8, wifi_channel: u8) noreturn {
    if (platform_start_rx(&transmitter_mac) == 0) {
        write("RADAR,ERROR,rx_start_failed\n");
        while (true) platform_delay_ms(1000);
    }
    announceReceiver(mac, wifi_channel);

    var sequence: u32 = 0;
    var previous_status = platform_millis();
    var csi_data: [max_csi_bytes]i8 = undefined;
    while (true) {
        const now = platform_millis();
        if (now - previous_status >= status_interval_ms) {
            announceReceiver(mac, wifi_channel);
            previous_status = now;
        }

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

        var mac_buffer: [17]u8 = undefined;
        var line_buffer: [960]u8 = undefined;
        const header = std.fmt.bufPrint(&line_buffer, "RADAR,CSI,{s},{d},{d},{d},{d},{d},{d},{d},", .{
            formatMac(&mac_buffer, mac),
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

fn startNetwork(device: *const Device) ?u8 {
    var channel: u8 = 0;
    if (platform_connect_wifi(
        firmware_options.network_name.ptr,
        @intCast(firmware_options.network_name.len),
        firmware_options.network_secret.ptr,
        @intCast(firmware_options.network_secret.len),
        device.name.ptr,
        @intCast(device.name.len),
        &channel,
    ) == 0) {
        write("RADAR,ERROR,wifi_connect_failed\n");
        return null;
    }
    if (platform_start_websocket(
        firmware_options.server_host.ptr,
        @intCast(firmware_options.server_host.len),
        firmware_options.server_port,
    ) == 0) {
        write("RADAR,ERROR,websocket_start_failed\n");
    }
    return channel;
}

pub fn app_main() callconv(.c) void {
    platform_init();
    var mac: [6]u8 = undefined;
    platform_get_mac(&mac);
    const device = identifyDevice(mac) orelse {
        write("RADAR,ERROR,unknown_device\n");
        while (true) platform_delay_ms(1000);
    };
    writeHello(mac);

    const channel = startNetwork(device) orelse {
        while (true) platform_delay_ms(1000);
    };
    switch (device.role) {
        .tx => runTransmitter(mac, channel),
        .rx => runReceiver(mac, channel),
    }
}

fn validateFirmwareOptions() void {
    if (firmware_options.network_name.len == 0 or firmware_options.network_name.len > 32) {
        @compileError("ESP_NETWORK_NAME must contain between 1 and 32 bytes");
    }
    if (firmware_options.network_secret.len < 8 or firmware_options.network_secret.len > 64) {
        @compileError("ESP_NETWORK_SECRET must contain between 8 and 64 bytes");
    }
    if (firmware_options.server_host.len == 0 or firmware_options.server_host.len > 253) {
        @compileError("ESP_SERVER_HOST must contain between 1 and 253 bytes");
    }
    if (std.mem.indexOf(u8, firmware_options.server_host, "://") != null) {
        @compileError("ESP_SERVER_HOST must not include a URL scheme");
    }
    if (firmware_options.server_port == 0) {
        @compileError("ESP_SERVER_PORT must be an integer from 1 to 65535");
    }
}

test "identifies every device by factory MAC" {
    for (devices, 0..) |expected, index| {
        const actual = identifyDevice(expected.mac) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.role, actual.role);
        try std.testing.expectEqual(index == 0, actual.role == .tx);
    }
}

test "rejects an unknown device MAC" {
    try std.testing.expectEqual(@as(?*const Device, null), identifyDevice(.{ 0, 1, 2, 3, 4, 5 }));
}

test "formats stable MAC identity" {
    var buffer: [17]u8 = undefined;
    try std.testing.expectEqualStrings("f4:2d:c9:6b:f2:00", formatMac(&buffer, transmitter_mac));
}

comptime {
    if (!builtin.is_test) {
        validateFirmwareOptions();
        @export(&app_main, .{ .name = "app_main" });
    }
}
