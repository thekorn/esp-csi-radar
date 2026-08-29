const std = @import("std");
const protocol = @import("protocol.zig");

const history_length = 120;
const max_links = 4;
const max_subcarriers = protocol.max_csi_bytes / 2;

pub const State = enum {
    offline,
    calibrating,
    occupied,
    clear,
};

fn round(value: f64, digits: u8) f64 {
    const factor = std.math.pow(f64, 10, @floatFromInt(digits));
    return @round(value * factor) / factor;
}

const HistorySnapshot = struct {
    values: [history_length]f64 = @splat(0),
    len: usize = 0,

    pub fn jsonStringify(self: *const HistorySnapshot, json: anytype) !void {
        try json.beginArray();
        for (self.values[0..self.len]) |value| try json.write(value);
        try json.endArray();
    }
};

pub const LinkSnapshot = struct {
    receiver: protocol.MacAddress,
    calibrated: bool,
    calibration: f64,
    active: bool,
    score: f64,
    rssi: i16,
    noiseFloor: i16,
    channel: u8,
    frames: u64,
    dropped: u64,
    lastSeenSeconds: f64,
    history: HistorySnapshot,
};

pub const LinkSnapshots = struct {
    values: [max_links]LinkSnapshot = undefined,
    len: usize = 0,

    pub fn jsonStringify(self: *const LinkSnapshots, json: anytype) !void {
        try json.beginArray();
        for (self.values[0..self.len]) |value| try json.write(value);
        try json.endArray();
    }
};

pub const Snapshot = struct {
    state: State,
    occupied: bool,
    score: f64,
    calibration: f64,
    holdRemainingSeconds: f64,
    generation: u64,
    links: LinkSnapshots,
};

const LinkState = struct {
    receiver: protocol.MacAddress,
    calibration_samples: u32,
    baseline: [max_subcarriers]f64 = @splat(0),
    baseline_len: usize = 0,
    calibration_count: u32 = 0,
    deviation_count: u32 = 0,
    deviation_mean: f64 = 0,
    deviation_m2: f64 = 0,
    threshold: f64 = 0.055,
    score: f64 = 0,
    active: bool = false,
    hit_streak: u8 = 0,
    clear_streak: u8 = 0,
    frames: u64 = 0,
    dropped: u64 = 0,
    rssi: i16 = 0,
    noise_floor: i16 = 0,
    channel: u8 = 0,
    last_sequence: ?u32 = null,
    last_seen: f64 = 0,
    history: [history_length]f64 = @splat(0),
    history_start: usize = 0,
    history_len: usize = 0,

    fn isCalibrated(link: *const LinkState) bool {
        return link.calibration_count >= link.calibration_samples;
    }

    fn resetShape(link: *LinkState, vector: []const f64) void {
        @memcpy(link.baseline[0..vector.len], vector);
        link.baseline_len = vector.len;
        link.calibration_count = 1;
        link.deviation_count = 0;
        link.deviation_mean = 0;
        link.deviation_m2 = 0;
        link.threshold = 0.055;
        link.score = 0;
        link.active = false;
        link.hit_streak = 0;
        link.clear_streak = 0;
        link.history_start = 0;
        link.history_len = 0;
    }

    fn appendHistory(link: *LinkState, value: f64) void {
        if (link.history_len < history_length) {
            const index = (link.history_start + link.history_len) % history_length;
            link.history[index] = value;
            link.history_len += 1;
        } else {
            link.history[link.history_start] = value;
            link.history_start = (link.history_start + 1) % history_length;
        }
    }

    fn addCalibrationDeviation(link: *LinkState, deviation: f64) void {
        link.deviation_count += 1;
        const delta = deviation - link.deviation_mean;
        link.deviation_mean += delta / @as(f64, @floatFromInt(link.deviation_count));
        const delta_after = deviation - link.deviation_mean;
        link.deviation_m2 += delta * delta_after;
    }

    fn ingest(link: *LinkState, frame: *const protocol.CsiFrame, now: f64) bool {
        const samples = frame.sampleSlice();
        if (samples.len < 16) return false;

        var vector: [max_subcarriers]f64 = undefined;
        const vector_len = samples.len / 2;
        var energy: f64 = 0;
        for (0..vector_len) |index| {
            const imaginary: f64 = @floatFromInt(samples[index * 2]);
            const real: f64 = @floatFromInt(samples[index * 2 + 1]);
            const amplitude = @sqrt(imaginary * imaginary + real * real);
            vector[index] = amplitude;
            energy += amplitude * amplitude;
        }
        const rms = @sqrt(energy / @as(f64, @floatFromInt(vector_len)));
        if (rms < 1e-6) return false;
        for (vector[0..vector_len]) |*value| value.* /= rms;

        link.frames += 1;
        link.dropped += frame.dropped;
        if (link.last_sequence) |last_sequence| {
            const expected = last_sequence +% 1;
            if (frame.sequence != expected) {
                const gap = frame.sequence -% expected;
                if (gap < 1_000_000) link.dropped += gap;
            }
        }
        link.last_sequence = frame.sequence;
        link.rssi = frame.rssi;
        link.noise_floor = frame.noise_floor;
        link.channel = frame.channel;
        link.last_seen = now;

        if (vector_len != link.baseline_len) {
            link.resetShape(vector[0..vector_len]);
            return false;
        }

        var squared_difference: f64 = 0;
        for (vector[0..vector_len], link.baseline[0..vector_len]) |value, baseline| {
            const difference = value - baseline;
            squared_difference += difference * difference;
        }
        const deviation = @sqrt(squared_difference / @as(f64, @floatFromInt(vector_len)));

        if (!link.isCalibrated()) {
            link.calibration_count += 1;
            const alpha = 1 / @as(f64, @floatFromInt(link.calibration_count));
            for (vector[0..vector_len], link.baseline[0..vector_len]) |value, *baseline| {
                baseline.* += alpha * (value - baseline.*);
            }
            if (link.calibration_count > 5) link.addCalibrationDeviation(deviation);
            if (link.isCalibrated()) {
                const spread = if (link.deviation_count > 1)
                    @sqrt(link.deviation_m2 / @as(f64, @floatFromInt(link.deviation_count)))
                else
                    0;
                link.threshold = @max(0.055, link.deviation_mean + 5 * spread);
            }
            link.score = 0;
            link.appendHistory(0);
            return false;
        }

        const raw_score = deviation / link.threshold;
        link.score = 0.7 * link.score + 0.3 * raw_score;
        link.appendHistory(@min(link.score, 4));

        if (link.score >= 1) {
            link.hit_streak +|= 1;
            link.clear_streak = 0;
            if (link.hit_streak >= 3) link.active = true;
        } else if (link.score < 0.55) {
            link.hit_streak = 0;
            link.clear_streak +|= 1;
            if (link.clear_streak >= 8) link.active = false;
        } else {
            link.hit_streak -|= 1;
            link.clear_streak = 0;
        }

        if (!link.active and link.score < 0.7) {
            for (vector[0..vector_len], link.baseline[0..vector_len]) |value, *baseline| {
                baseline.* += 0.001 * (value - baseline.*);
            }
        }
        return link.active;
    }

    fn snapshot(link: *const LinkState, now: f64) LinkSnapshot {
        var history: HistorySnapshot = .{};
        history.len = link.history_len;
        for (0..link.history_len) |index| {
            history.values[index] = round(
                link.history[(link.history_start + index) % history_length],
                3,
            );
        }
        return .{
            .receiver = link.receiver,
            .calibrated = link.isCalibrated(),
            .calibration = @min(1, @as(f64, @floatFromInt(link.calibration_count)) /
                @as(f64, @floatFromInt(link.calibration_samples))),
            .active = link.active,
            .score = round(link.score, 3),
            .rssi = link.rssi,
            .noiseFloor = link.noise_floor,
            .channel = link.channel,
            .frames = link.frames,
            .dropped = link.dropped,
            .lastSeenSeconds = round(now - link.last_seen, 2),
            .history = history,
        };
    }
};

pub const RoomDetector = struct {
    calibration_samples: u32,
    hold_seconds: f64,
    links: [max_links]LinkState = undefined,
    links_len: usize = 0,
    last_activity: ?f64 = null,
    generation: u64 = 0,

    pub fn init(calibration_samples: u32, hold_seconds: f64) !RoomDetector {
        if (calibration_samples < 10) return error.CalibrationTooShort;
        return .{
            .calibration_samples = calibration_samples,
            .hold_seconds = hold_seconds,
        };
    }

    pub fn ingest(detector: *RoomDetector, frame: *const protocol.CsiFrame, now: f64) void {
        var link: *LinkState = for (detector.links[0..detector.links_len]) |*candidate| {
            if (std.mem.eql(u8, &candidate.receiver, &frame.receiver)) break candidate;
        } else blk: {
            if (detector.links_len == detector.links.len) return;
            const candidate = &detector.links[detector.links_len];
            candidate.* = .{
                .receiver = frame.receiver,
                .calibration_samples = detector.calibration_samples,
            };
            detector.links_len += 1;
            break :blk candidate;
        };
        if (link.ingest(frame, now)) detector.last_activity = now;
    }

    pub fn reset(detector: *RoomDetector) void {
        detector.links_len = 0;
        detector.last_activity = null;
        detector.generation += 1;
    }

    pub fn snapshot(detector: *const RoomDetector, now: f64) Snapshot {
        var live_count: usize = 0;
        var all_calibrated = true;
        var score: f64 = 0;
        var calibration: f64 = 1;
        for (detector.links[0..detector.links_len]) |*link| {
            if (now - link.last_seen > 2) continue;
            live_count += 1;
            all_calibrated = all_calibrated and link.isCalibrated();
            score = @max(score, link.score);
            calibration = @min(
                calibration,
                @as(f64, @floatFromInt(link.calibration_count)) /
                    @as(f64, @floatFromInt(link.calibration_samples)),
            );
        }
        if (live_count == 0) {
            all_calibrated = false;
            calibration = 0;
        }
        const occupied = all_calibrated and detector.last_activity != null and
            now - detector.last_activity.? <= detector.hold_seconds;
        const state: State = if (live_count == 0)
            .offline
        else if (!all_calibrated)
            .calibrating
        else if (occupied)
            .occupied
        else
            .clear;

        var links: LinkSnapshots = .{};
        links.len = detector.links_len;
        for (detector.links[0..detector.links_len], 0..) |*link, index| {
            links.values[index] = link.snapshot(now);
        }
        std.mem.sort(LinkSnapshot, links.values[0..links.len], {}, struct {
            fn lessThan(_: void, left: LinkSnapshot, right: LinkSnapshot) bool {
                return std.mem.order(u8, &left.receiver, &right.receiver) == .lt;
            }
        }.lessThan);

        const hold_remaining = if (detector.last_activity) |last_activity|
            @max(0, detector.hold_seconds - (now - last_activity))
        else
            0;
        return .{
            .state = state,
            .occupied = occupied,
            .score = round(score, 3),
            .calibration = round(@min(1, calibration), 3),
            .holdRemainingSeconds = round(hold_remaining, 1),
            .generation = detector.generation,
            .links = links,
        };
    }
};

fn testFrame(sequence: u32, changed: bool, scale: f64) protocol.CsiFrame {
    var result: protocol.CsiFrame = .{
        .receiver = protocol.normalizeMac("e0:8c:fe:59:96:34") catch unreachable,
        .sequence = sequence,
        .timestamp_us = @as(u64, sequence) * 50_000,
        .rssi = -45,
        .noise_floor = -94,
        .channel = 6,
        .dropped = 0,
        .samples = undefined,
        .samples_len = 64,
    };
    for (0..32) |subcarrier| {
        const carrier: f64 = @floatFromInt(subcarrier);
        var amplitude = 35 + 8 * @sin(carrier * 0.31);
        if (changed) amplitude *= 1 + 0.35 * @sin(carrier * 0.73);
        result.samples[subcarrier * 2] = @intFromFloat(@round(
            scale * amplitude * @sin(carrier * 0.17),
        ));
        result.samples[subcarrier * 2 + 1] = @intFromFloat(@round(
            scale * amplitude * @cos(carrier * 0.17),
        ));
    }
    return result;
}

test "detector calibrates and detects changed channel shape" {
    var detector = try RoomDetector.init(12, 3);
    for (0..12) |sequence| {
        const frame = testFrame(@intCast(sequence), false, 1);
        detector.ingest(&frame, @as(f64, @floatFromInt(sequence)) * 0.05);
    }
    try std.testing.expectEqual(State.clear, detector.snapshot(0.6).state);

    for (12..18) |sequence| {
        const frame = testFrame(@intCast(sequence), true, 1);
        detector.ingest(&frame, @as(f64, @floatFromInt(sequence)) * 0.05);
    }
    const changed = detector.snapshot(0.9);
    try std.testing.expectEqual(State.occupied, changed.state);
    try std.testing.expect(changed.links.values[0].active);
    try std.testing.expect(changed.score > 1);
    try std.testing.expectEqual(State.offline, detector.snapshot(4.1).state);
}

test "detector normalizes uniform gain and reset requires calibration" {
    var detector = try RoomDetector.init(12, 3);
    for (0..12) |sequence| {
        const frame = testFrame(@intCast(sequence), false, 1);
        detector.ingest(&frame, @as(f64, @floatFromInt(sequence)) * 0.05);
    }
    for (12..22) |sequence| {
        const frame = testFrame(@intCast(sequence), false, 1.7);
        detector.ingest(&frame, @as(f64, @floatFromInt(sequence)) * 0.05);
    }
    try std.testing.expectEqual(State.clear, detector.snapshot(1.1).state);
    try std.testing.expect(detector.snapshot(1.1).score < 1);
    detector.reset();
    try std.testing.expectEqual(State.offline, detector.snapshot(1.1).state);
    try std.testing.expectEqual(@as(u64, 1), detector.generation);
}

test "detector accounts for reported drops and sequence gaps" {
    var detector = try RoomDetector.init(10, 3);
    var first = testFrame(3, false, 1);
    first.dropped = 2;
    detector.ingest(&first, 0);
    var second = testFrame(7, false, 1);
    second.dropped = 1;
    detector.ingest(&second, 0.05);

    const snapshot = detector.snapshot(0.1);
    try std.testing.expectEqual(@as(usize, 1), snapshot.links.len);
    try std.testing.expectEqual(@as(u64, 2), snapshot.links.values[0].frames);
    try std.testing.expectEqual(@as(u64, 6), snapshot.links.values[0].dropped);
}
