const std = @import("std");
const application = @import("application.zig");

pub const Options = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    rate: u16 = 20,
    baud: u32 = 921_600,
    ports: [8][]const u8 = undefined,
    ports_len: usize = 4,
    mode: application.SourceMode = .serial,
    calibration_samples: u32 = 80,
    hold_seconds: f64 = 20,
    verbose: bool = false,
    help: bool = false,

    pub fn portSlice(options: *const Options) []const []const u8 {
        return options.ports[0..options.ports_len];
    }
};

pub const ParseError = error{
    InvalidEnvironmentPort,
    MissingValue,
    InvalidNumber,
    InvalidPort,
    InvalidRate,
    InvalidCalibrationSamples,
    InvalidPorts,
    TooManyPorts,
    MutuallyExclusiveModes,
    UnknownOption,
};

pub fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidEnvironmentPort => "ESP_SERVER_PORT must be a whole number between 1 and 65535",
        error.MissingValue => "option requires a value",
        error.InvalidNumber => "option requires a valid value",
        error.InvalidPort => "--port must be between 1 and 65535",
        error.InvalidRate => "--rate must be between 1 and 100",
        error.InvalidCalibrationSamples => "--calibration-samples must be at least 10",
        error.InvalidPorts => "--ports requires at least one port",
        error.TooManyPorts => "--ports supports at most eight values",
        error.MutuallyExclusiveModes => "--serial, --socket, and --simulate are mutually exclusive",
        error.UnknownOption => "unknown option",
    };
}

pub fn parse(argv: []const []const u8, environment_port: ?[]const u8) ParseError!Options {
    var options: Options = .{};
    options.ports[0] = "/dev/esp32-1";
    options.ports[1] = "/dev/esp32-2";
    options.ports[2] = "/dev/esp32-3";
    options.ports[3] = "/dev/esp32-4";
    if (environment_port) |text| {
        const parsed = parseInteger(text) catch return error.InvalidEnvironmentPort;
        if (parsed < 1 or parsed > 65_535) return error.InvalidEnvironmentPort;
        options.port = @intCast(parsed);
    }

    var bind_was_set = false;
    var mode_was_set = false;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        const equals = std.mem.findScalar(u8, argument, '=');
        const name = if (equals) |position| argument[0..position] else argument;
        const inline_value: ?[]const u8 = if (equals) |position| argument[position + 1 ..] else null;

        if (std.mem.eql(u8, name, "--bind")) {
            options.bind = try takeValue(argv, &index, inline_value);
            bind_was_set = true;
        } else if (std.mem.eql(u8, name, "--port")) {
            const parsed = try parseInteger(try takeValue(argv, &index, inline_value));
            if (parsed < 1 or parsed > 65_535) return error.InvalidPort;
            options.port = @intCast(parsed);
        } else if (std.mem.eql(u8, name, "--rate")) {
            const parsed = try parseInteger(try takeValue(argv, &index, inline_value));
            if (parsed < 1 or parsed > 100) return error.InvalidRate;
            options.rate = @intCast(parsed);
        } else if (std.mem.eql(u8, name, "--baud")) {
            const parsed = try parseInteger(try takeValue(argv, &index, inline_value));
            if (parsed < 1 or parsed > std.math.maxInt(u32)) return error.InvalidNumber;
            options.baud = @intCast(parsed);
        } else if (std.mem.eql(u8, name, "--calibration-samples")) {
            const parsed = try parseInteger(try takeValue(argv, &index, inline_value));
            if (parsed < 10 or parsed > std.math.maxInt(u32)) return error.InvalidCalibrationSamples;
            options.calibration_samples = @intCast(parsed);
        } else if (std.mem.eql(u8, name, "--hold-seconds")) {
            options.hold_seconds = try parseFloat(try takeValue(argv, &index, inline_value));
        } else if (std.mem.eql(u8, name, "--ports")) {
            options.ports_len = 0;
            if (inline_value) |port| {
                if (port.len == 0) return error.InvalidPorts;
                options.ports[0] = port;
                options.ports_len = 1;
            }
            while (index + 1 < argv.len and !std.mem.startsWith(u8, argv[index + 1], "-")) {
                if (options.ports_len == options.ports.len) return error.TooManyPorts;
                index += 1;
                options.ports[options.ports_len] = argv[index];
                options.ports_len += 1;
            }
            if (options.ports_len == 0) return error.InvalidPorts;
        } else if (std.mem.eql(u8, name, "--serial")) {
            try selectMode(&options, &mode_was_set, .serial);
        } else if (std.mem.eql(u8, name, "--socket")) {
            try selectMode(&options, &mode_was_set, .socket);
        } else if (std.mem.eql(u8, name, "--simulate")) {
            try selectMode(&options, &mode_was_set, .simulation);
        } else if (std.mem.eql(u8, name, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) {
            options.help = true;
        } else {
            return error.UnknownOption;
        }
    }

    if (options.mode == .socket and !bind_was_set) options.bind = "0.0.0.0";
    return options;
}

fn takeValue(
    argv: []const []const u8,
    index: *usize,
    inline_value: ?[]const u8,
) ParseError![]const u8 {
    if (inline_value) |value| {
        if (value.len == 0) return error.InvalidNumber;
        return value;
    }
    index.* += 1;
    if (index.* >= argv.len) return error.MissingValue;
    return argv[index.*];
}

fn parseInteger(value: []const u8) ParseError!i64 {
    if (value.len == 0) return error.InvalidNumber;
    return std.fmt.parseInt(i64, value, 10) catch error.InvalidNumber;
}

fn parseFloat(value: []const u8) ParseError!f64 {
    if (value.len == 0) return error.InvalidNumber;
    const result = std.fmt.parseFloat(f64, value) catch return error.InvalidNumber;
    if (!std.math.isFinite(result)) return error.InvalidNumber;
    return result;
}

fn selectMode(
    options: *Options,
    mode_was_set: *bool,
    mode: application.SourceMode,
) ParseError!void {
    if (mode_was_set.* and options.mode != mode) return error.MutuallyExclusiveModes;
    options.mode = mode;
    mode_was_set.* = true;
}

test "options preserve the reference defaults and socket binding" {
    const defaults = try parse(&.{}, null);
    try std.testing.expectEqual(application.SourceMode.serial, defaults.mode);
    try std.testing.expectEqualStrings("127.0.0.1", defaults.bind);
    try std.testing.expectEqual(@as(u16, 8080), defaults.port);

    const socket = try parse(&.{"--socket"}, "9080");
    try std.testing.expectEqual(application.SourceMode.socket, socket.mode);
    try std.testing.expectEqualStrings("0.0.0.0", socket.bind);
    try std.testing.expectEqual(@as(u16, 9080), socket.port);
}

test "options parse inline values and reject conflicting modes" {
    const options = try parse(&.{
        "--simulate",
        "--bind",
        "0.0.0.0",
        "--port=9000",
        "--ports=/dev/esp32-2",
        "/dev/esp32-1",
    }, null);
    try std.testing.expectEqual(application.SourceMode.simulation, options.mode);
    try std.testing.expectEqual(@as(u16, 9000), options.port);
    try std.testing.expectEqualStrings("/dev/esp32-2", options.portSlice()[0]);
    try std.testing.expectError(error.MutuallyExclusiveModes, parse(
        &.{ "--serial", "--socket" },
        null,
    ));
    try std.testing.expectError(error.InvalidNumber, parse(&.{"--port="}, null));
}
