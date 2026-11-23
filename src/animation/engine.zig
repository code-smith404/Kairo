//! Animation primitives: easings and rectangular value tracks.

const std = @import("std");
const geom = @import("../util/geometry.zig");
const config = @import("../config/config.zig");

pub const Easing = config.Easing;

pub fn ease(easing: Easing, t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return switch (easing) {
        .linear => x,
        .ease_in_quad => x * x,
        .ease_out_quad => 1.0 - (1.0 - x) * (1.0 - x),
        .ease_in_out_quad => if (x < 0.5) 2.0 * x * x else 1.0 - std.math.pow(f32, -2.0 * x + 2.0, 2.0) / 2.0,
        .ease_out_cubic => 1.0 - std.math.pow(f32, 1.0 - x, 3.0),
        .ease_in_out_cubic => if (x < 0.5) 4.0 * x * x * x else 1.0 - std.math.pow(f32, -2.0 * x + 2.0, 3.0) / 2.0,
        .ease_out_quart => 1.0 - std.math.pow(f32, 1.0 - x, 4.0),
        .ease_out_expo => if (x >= 1.0) 1.0 else 1.0 - std.math.pow(f32, 2.0, -10.0 * x),
        .ease_out_back => blk: {
            const c1: f32 = 1.70158;
            const c3 = c1 + 1.0;
            break :blk 1.0 + c3 * std.math.pow(f32, x - 1.0, 3.0) + c1 * std.math.pow(f32, x - 1.0, 2.0);
        },
        .ease_in_back => blk: {
            const c1: f32 = 1.70158;
            const c3 = c1 + 1.0;
            break :blk c3 * x * x * x - c1 * x * x;
        },
    };
}

pub const Track = struct {
    from: f32,
    to: f32,
    start_ns: i64 = 0,
    duration_ns: i64 = 0,
    easing: Easing = .ease_out_cubic,
    active: bool = false,

    pub fn start(self: *Track, from: f32, to: f32, now_ns: i64, duration_ms: u32, easing: Easing) void {
        self.from = from;
        self.to = to;
        self.start_ns = now_ns;
        self.duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms;
        self.easing = easing;
        self.active = duration_ms > 0 and from != to;
        if (!self.active) self.from = to;
    }

    pub fn value(self: *const Track, now_ns: i64) f32 {
        if (!self.active) return self.to;
        if (self.duration_ns <= 0) return self.to;
        const elapsed = now_ns - self.start_ns;
        if (elapsed <= 0) return self.from;
        if (elapsed >= self.duration_ns) return self.to;
        const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ns));
        return self.from + (self.to - self.from) * ease(self.easing, t);
    }

    pub fn update(self: *Track, now_ns: i64) f32 {
        if (self.active and now_ns - self.start_ns >= self.duration_ns) self.active = false;
        return self.value(now_ns);
    }
};

pub const RectTrack = struct {
    from: geom.Box,
    to: geom.Box,
    start_ns: i64 = 0,
    duration_ns: i64 = 0,
    easing: Easing = .ease_out_cubic,
    active: bool = false,

    pub fn start(self: *RectTrack, from: geom.Box, to: geom.Box, now_ns: i64, duration_ms: u32, easing: Easing) void {
        self.from = from;
        self.to = to;
        self.start_ns = now_ns;
        self.duration_ns = @as(i64, duration_ms) * std.time.ns_per_ms;
        self.easing = easing;
        self.active = duration_ms > 0 and !geom.Box.eql(from, to);
        if (!self.active) self.from = to;
    }

    fn lerp(a: i32, b: i32, t: f32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * t));
    }

    pub fn value(self: *const RectTrack, now_ns: i64) geom.Box {
        if (!self.active or self.duration_ns <= 0) return self.to;
        const elapsed = now_ns - self.start_ns;
        if (elapsed <= 0) return self.from;
        if (elapsed >= self.duration_ns) return self.to;
        const t = ease(self.easing, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ns)));
        return .{
            .x = lerp(self.from.x, self.to.x, t),
            .y = lerp(self.from.y, self.to.y, t),
            .width = lerp(self.from.width, self.to.width, t),
            .height = lerp(self.from.height, self.to.height, t),
        };
    }

    pub fn update(self: *RectTrack, now_ns: i64) geom.Box {
        if (self.active and now_ns - self.start_ns >= self.duration_ns) self.active = false;
        return self.value(now_ns);
    }
};

test "linear easing" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), ease(.linear, 0.5), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease(.ease_out_cubic, 1.0), 0.0001);
    try std.testing.expect(ease(.ease_out_cubic, 0.5) > 0.5);
    try std.testing.expect(ease(.ease_in_quad, 0.5) < 0.5);
}

test "track clamps and completes" {
    var t = Track{ .from = 0, .to = 0 };
    const start: i64 = 1_000_000_000;
    t.start(0, 100, start, 100, .linear);
    try std.testing.expectApproxEqAbs(@as(f32, 50), t.value(start + 50 * std.time.ns_per_ms), 0.001);
    _ = t.update(start + 200 * std.time.ns_per_ms);
    try std.testing.expect(!t.active);
    try std.testing.expectApproxEqAbs(@as(f32, 100), t.value(start + 2_000 * std.time.ns_per_ms), 0.001);
}

test "rect interpolation" {
    var r = RectTrack{ .from = geom.Box.zero, .to = geom.Box.zero };
    const start: i64 = 1_000_000_000;
    r.start(geom.Box.init(0, 0, 10, 10), geom.Box.init(100, 100, 50, 50), start, 100, .linear);
    const mid = r.value(start + 50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i32, 50), mid.x);
    try std.testing.expectEqual(@as(i32, 30), mid.width);
    _ = r.update(start + 100 * std.time.ns_per_ms);
    try std.testing.expect(!r.active);
}
