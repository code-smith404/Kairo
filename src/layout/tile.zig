//! Tile family: master/stack orientation variants.

const geom = @import("../util/geometry.zig");
const layout = @import("layout.zig");
const Box = geom.Box;
const Params = layout.Params;

fn workArea(area: Box, params: Params) Box {
    return area.inset(@max(0, params.gap_outer));
}

pub fn tile(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    const mc = layout.masterCount(params, n);
    if (mc == 0) {
        layout.splitAxis(a, n, gap, true, out);
        return n;
    }
    if (mc >= n) {
        layout.splitAxis(a, n, gap, true, out);
        return n;
    }
    const mw = layout.masterExtent(a.width, gap, params.master_factor);
    const master = Box.init(a.x, a.y, mw, a.height);
    const stack = Box.init(a.x + mw + gap, a.y, a.width - mw - gap, a.height);
    layout.splitAxis(master, mc, gap, true, out[0..mc]);
    layout.splitAxis(stack, n - mc, gap, true, out[mc..n]);
    return n;
}

pub fn masterStack(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    const mc = layout.masterCount(params, n);
    if (mc == 0) {
        layout.splitAxis(a, n, gap, false, out);
        return n;
    }
    if (mc >= n) {
        layout.splitAxis(a, n, gap, false, out);
        return n;
    }
    const mh = layout.masterExtent(a.height, gap, params.master_factor);
    const master = Box.init(a.x, a.y, a.width, mh);
    const stack = Box.init(a.x, a.y + mh + gap, a.width, a.height - mh - gap);
    layout.splitAxis(master, mc, gap, false, out[0..mc]);
    layout.splitAxis(stack, n - mc, gap, false, out[mc..n]);
    return n;
}

/// Full-width rows. The master count is respected by giving the first
/// `master_count` windows a fraction of the height, the rest share the rest.
pub fn verticalTile(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    const mc = layout.masterCount(params, n);
    if (mc == 0 or mc >= n) {
        layout.splitAxis(a, n, gap, true, out);
        return n;
    }
    const mh = layout.masterExtent(a.height, gap, params.master_factor);
    const master = Box.init(a.x, a.y, a.width, mh);
    const stack = Box.init(a.x, a.y + mh + gap, a.width, a.height - mh - gap);
    layout.splitAxis(master, mc, gap, true, out[0..mc]);
    layout.splitAxis(stack, n - mc, gap, true, out[mc..n]);
    return n;
}

/// Tile layout restricted to a centered column. The column is `master_factor`
/// of the work area (clamped to 30%..100%).
pub fn centerTile(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    const frac = @min(1.0, @max(0.3, params.master_factor * 2.0));
    const w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(a.width)) * frac));
    const centered = Box.init(a.x + @divTrunc(a.width - w, 2), a.y, w, a.height);
    return tile(centered, n, .{
        .master_count = params.master_count,
        .master_factor = params.master_factor,
        .gap_inner = params.gap_inner,
        .gap_outer = 0,
        .focused = params.focused,
    }, out);
}

/// Master on the left, the remaining windows arranged as a grid on the right.
pub fn tgMix(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    const mc = layout.masterCount(params, n);
    if (mc == 0) {
        return @import("grid.zig").grid(a, n, params, out);
    }
    if (mc >= n) {
        layout.splitAxis(a, n, gap, true, out);
        return n;
    }
    const mw = layout.masterExtent(a.width, gap, params.master_factor);
    const master = Box.init(a.x, a.y, mw, a.height);
    const rest = Box.init(a.x + mw + gap, a.y, a.width - mw - gap, a.height);
    layout.splitAxis(master, mc, gap, true, out[0..mc]);
    _ = @import("grid.zig").grid(rest, n - mc, .{
        .gap_inner = gap,
        .gap_outer = 0,
    }, out[mc..n]);
    return n;
}
