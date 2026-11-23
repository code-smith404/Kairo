//! PaperWM-inspired scroller layouts.

const geom = @import("../util/geometry.zig");
const layout = @import("layout.zig");
const Box = geom.Box;
const Params = layout.Params;

fn workArea(area: Box, params: Params) Box {
    return area.inset(@max(0, params.gap_outer));
}

pub fn horizontal(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    const prop = @min(1.0, @max(0.2, params.scroller_proportion));
    var colw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(a.width)) * prop));
    colw = @max(1, @min(a.width, colw));
    const stride = colw + gap;
    var strip_width: i32 = stride * @as(i32, @intCast(n)) - gap;
    const centered: bool = strip_width < a.width;
    var start: i32 = if (centered) a.x + @divTrunc(a.width - strip_width, 2) else a.x - params.scroll_offset;
    for (0..n) |i| {
        out[i] = Box.init(start, a.y, colw, a.height);
        start += stride;
    }
    // Keep the last window's right edge meaningful for clamping.
    strip_width = @max(strip_width, 0);
    return n;
}

pub fn vertical(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    const prop = @min(1.0, @max(0.2, params.scroller_proportion));
    var rowh: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(a.height)) * prop));
    rowh = @max(1, @min(a.height, rowh));
    const stride = rowh + gap;
    const strip_height: i32 = stride * @as(i32, @intCast(n)) - gap;
    const centered: bool = strip_height < a.height;
    var start: i32 = if (centered) a.y + @divTrunc(a.height - strip_height, 2) else a.y - params.scroll_offset;
    for (0..n) |i| {
        out[i] = Box.init(a.x, start, a.width, rowh);
        start += stride;
    }
    return n;
}
