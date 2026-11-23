//! Layout engine: pure geometry. Every layout is a function from a work area,
//! window count and per-tag parameters to a list of rectangles. No compositor
//! state is touched here, which keeps layouts deterministic and testable.

const std = @import("std");
const geom = @import("../util/geometry.zig");
const tile = @import("tile.zig");
const scroller = @import("scroller.zig");
const monocle = @import("monocle.zig");
const grid = @import("grid.zig");
const deck = @import("deck.zig");
const dwindle = @import("dwindle.zig");
const centered = @import("centered.zig");

pub const Box = geom.Box;

pub const Kind = enum(u8) {
    tile,
    scroller,
    vertical_scroller,
    master_stack,
    monocle,
    grid,
    deck,
    dwindle,
    centered_master,
    center_tile,
    vertical_tile,
    vertical_grid,
    tg_mix,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .tile => "tile",
            .scroller => "scroller",
            .vertical_scroller => "vertical-scroller",
            .master_stack => "master-stack",
            .monocle => "monocle",
            .grid => "grid",
            .deck => "deck",
            .dwindle => "dwindle",
            .centered_master => "centered-master",
            .center_tile => "center-tile",
            .vertical_tile => "vertical-tile",
            .vertical_grid => "vertical-grid",
            .tg_mix => "tgmix",
        };
    }

    pub fn fromName(s: []const u8) ?Kind {
        inline for (std.meta.fields(Kind)) |f| {
            const k: Kind = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, k.name())) return k;
        }
        if (std.mem.eql(u8, s, "vertical-scroll")) return .vertical_scroller;
        if (std.mem.eql(u8, s, "centeredmaster")) return .centered_master;
        if (std.mem.eql(u8, s, "vertgrid")) return .vertical_grid;
        return null;
    }

    pub fn all() []const Kind {
        return &[_]Kind{
            .tile,            .scroller,    .vertical_scroller, .master_stack,
            .monocle,         .grid,        .deck,              .dwindle,
            .centered_master, .center_tile, .vertical_tile,     .vertical_grid,
            .tg_mix,
        };
    }
};

pub const Params = struct {
    master_count: u16 = 1,
    master_factor: f32 = 0.55,
    gap_inner: i32 = 4,
    gap_outer: i32 = 8,
    focused: usize = 0,
    /// Scroller: fraction of the work-area width (or height) per window.
    scroller_proportion: f32 = 0.9,
    /// Scroller: first visible offset in pixels, already computed by the caller.
    scroll_offset: i32 = 0,
};

pub fn arrange(kind: Kind, area: Box, count: usize, params: Params, out: []Box) usize {
    if (count == 0 or out.len == 0) return 0;
    const n = @min(count, out.len);
    return switch (kind) {
        .tile => tile.tile(area, n, params, out),
        .master_stack => tile.masterStack(area, n, params, out),
        .vertical_tile => tile.verticalTile(area, n, params, out),
        .center_tile => tile.centerTile(area, n, params, out),
        .tg_mix => tile.tgMix(area, n, params, out),
        .scroller => scroller.horizontal(area, n, params, out),
        .vertical_scroller => scroller.vertical(area, n, params, out),
        .monocle => monocle.arrange(area, n, params, out),
        .grid => grid.grid(area, n, params, out),
        .vertical_grid => grid.verticalGrid(area, n, params, out),
        .deck => deck.arrange(area, n, params, out),
        .dwindle => dwindle.arrange(area, n, params, out),
        .centered_master => centered.arrange(area, n, params, out),
    };
}

/// Split a rectangle into `n` slices along one axis, inserting `gap` between
/// slices. The final slice absorbs integer rounding so the slices always fill
/// the input rectangle exactly.
pub fn splitAxis(area: Box, n: usize, gap: i32, vertical: bool, out: []Box) void {
    if (n == 0) return;
    const total: i32 = if (vertical) area.height else area.width;
    const usable = @max(0, total - gap * @as(i32, @intCast(n - 1)));
    const base = @divTrunc(usable, @as(i32, @intCast(n)));
    const extra = @rem(usable, @as(i32, @intCast(n)));
    var pos: i32 = 0;
    for (0..n) |i| {
        const size = base + (if (i < @as(usize, @intCast(extra))) @as(i32, 1) else @as(i32, 0));
        if (vertical) {
            out[i] = Box.init(area.x, area.y + pos, area.width, size);
        } else {
            out[i] = Box.init(area.x + pos, area.y, size, area.height);
        }
        pos += size + gap;
    }
}

pub fn masterCount(params: Params, count: usize) usize {
    if (count == 0) return 0;
    const mc: usize = @intCast(params.master_count);
    if (mc == 0) return 0;
    return @min(mc, count);
}

/// Compute the master size from the master factor, clamped so both sides keep
/// at least one usable pixel when possible.
pub fn masterExtent(total: i32, gap: i32, factor: f32) i32 {
    const usable = @max(0, total - gap);
    const f = std.math.clamp(factor, 0.1, 0.9);
    const raw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(usable)) * f));
    return std.math.clamp(raw, 1, @max(1, usable - 1));
}

test "split fills exactly" {
    var out: [4]Box = undefined;
    splitAxis(Box.init(0, 0, 101, 50), 4, 3, false, &out);
    try std.testing.expectEqual(@as(i32, 101), out[3].right());
    try std.testing.expectEqual(@as(i32, 50), out[0].height);
}

test "all layouts produce valid rects" {
    var out: [12]Box = undefined;
    const area = Box.init(0, 0, 1920, 1080);
    for (Kind.all()) |kind| {
        for (1..9) |n| {
            const got = arrange(kind, area, n, .{}, &out);
            try std.testing.expectEqual(n, got);
            for (out[0..got]) |b| {
                try std.testing.expect(b.width > 0 and b.height > 0);
                try std.testing.expect(b.x >= -100 and b.y >= -100);
            }
        }
    }
}

test "every layout handles zero, one and many windows inside the area" {
    const area = Box.init(0, 0, 1920, 1080);
    const params = Params{ .master_count = 1, .master_factor = 0.55, .gap_inner = 6, .gap_outer = 6 };
    var boxes: [16]Box = undefined;
    for (Kind.all()) |kind| {
        for ([_]usize{ 0, 1, 2, 7 }) |n| {
            const count = arrange(kind, area, n, params, boxes[0..n]);
            try std.testing.expectEqual(n, count);
            for (boxes[0..n]) |b| {
                try std.testing.expect(b.width >= 0 and b.height >= 0);
                if (kind != .scroller and kind != .vertical_scroller) {
                    try std.testing.expect(b.x >= area.x and b.y >= area.y);
                    try std.testing.expect(b.x + b.width <= area.x + area.width);
                    try std.testing.expect(b.y + b.height <= area.y + area.height);
                }
            }
        }
    }
}
