const std = @import("std");
const application = @import("application.zig");
const protocol = @import("protocol.zig");
const linux = std.os.linux;

pub fn startSerial(app: *application.Application, baud: u32) !void {
    for (0..app.statusCount()) |index| {
        const thread = try std.Thread.spawn(.{}, serialThread, .{ app, index, baud });
        thread.detach();
    }
}

fn serialThread(app: *application.Application, index: usize, baud: u32) void {
    const port = app.statusPort(index);
    while (true) {
        var file = std.Io.Dir.openFileAbsolute(app.io, port, .{
            .mode = .read_write,
            .allow_directory = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| {
            app.markSerialDisconnected(index);
            app.serialError(index, @errorName(err));
            std.log.warn("{s}: {s}", .{ port, @errorName(err) });
            sleep(app.io, 1);
            continue;
        };
        defer file.close(app.io);

        configureSerial(file, baud) catch |err| {
            app.markSerialDisconnected(index);
            app.serialError(index, @errorName(err));
            std.log.warn("{s}: {s}", .{ port, @errorName(err) });
            sleep(app.io, 1);
            continue;
        };

        app.markSerialConnected(index);
        std.log.info("opened {s}", .{port});
        readSerial(app, index, file);
        app.markSerialDisconnected(index);
        sleep(app.io, 1);
    }
}

fn readSerial(app: *application.Application, index: usize, file: std.Io.File) void {
    var read_buffer: [1200]u8 = undefined;
    var file_reader = file.readerStreaming(app.io, &read_buffer);
    while (true) {
        const line = file_reader.interface.takeDelimiter('\n') catch |err| {
            if (err == error.StreamTooLong) {
                app.malformedRecord(index, "record exceeds 1200 bytes");
            }
            return;
        } orelse return;
        const message = protocol.parseLine(line) catch |err| {
            app.malformedRecord(index, protocol.errorMessage(err));
            continue;
        };
        if (message) |record| app.applySerialMessage(index, &record);
    }
}

fn configureSerial(file: std.Io.File, baud: u32) !void {
    var attributes = try std.posix.tcgetattr(file.handle);
    const speed = try baudSpeed(baud);
    const raw_speed: linux.tcflag_t = @backingInt(speed);
    attributes.iflag = @bitCast(@as(linux.tcflag_t, 0));
    attributes.oflag = @bitCast(@as(linux.tcflag_t, 0));
    attributes.lflag = @bitCast(@as(linux.tcflag_t, 0));
    attributes.cflag = @bitCast(raw_speed | (3 << 4) | (1 << 7) | (1 << 11));
    attributes.ispeed = speed;
    attributes.ospeed = speed;
    attributes.cc[@backingInt(linux.V.MIN)] = 1;
    attributes.cc[@backingInt(linux.V.TIME)] = 0;
    try std.posix.tcsetattr(file.handle, .NOW, attributes);

    var modem_lines: c_int = 0x002 | 0x004; // DTR and RTS bits.
    const result = linux.ioctl(file.handle, linux.T.IOCMBIC, @intFromPtr(&modem_lines));
    if (std.posix.errno(result) != .SUCCESS) return error.ModemControlFailed;
}

fn baudSpeed(baud: u32) !linux.speed_t {
    return switch (baud) {
        9_600 => .B9600,
        19_200 => .B19200,
        38_400 => .B38400,
        57_600 => .B57600,
        115_200 => .B115200,
        230_400 => .B230400,
        460_800 => .B460800,
        500_000 => .B500000,
        576_000 => .B576000,
        921_600 => .B921600,
        1_000_000 => .B1000000,
        1_500_000 => .B1500000,
        2_000_000 => .B2000000,
        else => error.UnsupportedBaudRate,
    };
}

pub fn startSimulator(app: *application.Application) !void {
    const thread = try std.Thread.spawn(.{}, simulatorThread, .{app});
    thread.detach();
}

const SeededRandom = struct {
    seed: u32,

    fn next(random: *SeededRandom) f64 {
        random.seed +%= 0x6d2b79f5;
        var value = (random.seed ^ (random.seed >> 15)) *% (1 | random.seed);
        value = (value +% ((value ^ (value >> 7)) *% (61 | value))) ^ value;
        const result = value ^ (value >> 14);
        return @as(f64, @floatFromInt(result)) / 4_294_967_296.0;
    }
};

fn simulatorThread(app: *application.Application) void {
    var random: SeededRandom = .{ .seed = 0xc51 };
    var sequences: [3]u32 = @splat(0);
    const started_at = app.now();
    var next_frame = started_at;
    const period = 1 / @as(f64, @floatFromInt(app.rate_hz));

    while (true) {
        const timestamp = app.now();
        const elapsed = timestamp - started_at;
        const phase = @mod(elapsed, 32);
        const occupied = phase >= 8 and phase < 13;

        for (0..3) |receiver_index| {
            var frame: protocol.CsiFrame = .{
                .receiver = application.Application.receiverMac(receiver_index),
                .sequence = sequences[receiver_index],
                .timestamp_us = @intFromFloat(@floor(elapsed * 1_000_000)),
                .rssi = @intCast(-43 - @as(i16, @intCast(receiver_index)) * 5),
                .noise_floor = -94,
                .channel = 6,
                .dropped = 0,
                .samples = undefined,
                .samples_len = 128,
            };
            for (0..64) |subcarrier| {
                const carrier: f64 = @floatFromInt(subcarrier);
                const receiver: f64 = @floatFromInt(receiver_index);
                var base = 34 + 9 * @sin(carrier * 0.21 + receiver);
                if (occupied) {
                    base *= 1 + 0.24 * @sin(
                        elapsed * (1.4 + receiver * 0.15) + carrier * 0.37,
                    );
                }
                const radio_phase = carrier * 0.13 + receiver * 0.8;
                const noise = random.next() * 1.6 - 0.8;
                frame.samples[subcarrier * 2] = @intFromFloat(@round(
                    base * @sin(radio_phase) + noise,
                ));
                frame.samples[subcarrier * 2 + 1] = @intFromFloat(@round(
                    base * @cos(radio_phase) + noise,
                ));
            }
            app.ingest(&frame);
            sequences[receiver_index] +%= 1;
        }

        next_frame += period;
        const remaining = next_frame - app.now();
        if (remaining > 0) {
            const nanoseconds: i64 = @intFromFloat(remaining * std.time.ns_per_s);
            std.Io.sleep(app.io, .fromNanoseconds(nanoseconds), .awake) catch return;
        }
    }
}

fn sleep(io: std.Io, seconds: i64) void {
    std.Io.sleep(io, .fromSeconds(seconds), .awake) catch {};
}

test "simulator random source is deterministic" {
    var left: SeededRandom = .{ .seed = 0xc51 };
    var right: SeededRandom = .{ .seed = 0xc51 };
    for (0..10) |_| try std.testing.expectEqual(left.next(), right.next());
}
