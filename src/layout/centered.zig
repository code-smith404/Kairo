const geom = @import("../util/geometry.zig");
const layout = @import("layout.zig");
const Box = geom.Box;
const Params = layout.Params;

fn workArea(area: Box, params: Params) Box {
    return area.inset(@max(0, params.gap_outer));
}

/// Centered master: the master column is centered; the remaining windows are
/// distributed over left and right stack columns.
pub fn arrange(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    const mc = layout.masterCount(params, n);
    if (mc == 0 or mc >= n) {
        return @import("tile.zig").tile(a, n, .{
            .master_count = params.master_count,
            .master_factor = params.master_factor,
            .gap_inner = gap,
            .gap_outer = 0,
        }, out);
    }
    const mw = layout.masterExtent(a.width, gap, params.master_factor);
    const side_space = a.width - mw - 2 * gap;
    if (side_space < 64) {
        return @import("tile.zig").tile(a, n, .{
            .master_count = params.master_count,
            .master_factor = params.master_factor,
            .gap_inner = gap,
            .gap_outer = 0,
        }, out);
    }
    const side_w = @divTrunc(side_space, 2);
    const master = Box.init(a.x + side_w + gap, a.y, mw, a.height);
    const left = Box.init(a.x, a.y, side_w, a.height);
    const right = Box.init(a.x + side_w + gap + mw + gap, a.y, a.width - side_w - gap - mw - gap, a.height);

    layout.splitAxis(master, mc, gap, true, out[0..mc]);

    const rest = n - mc;
    const left_count = (rest + 1) / 2;
    const right_count = rest - left_count;
    if (left_count > 0) layout.splitAxis(left, left_count, gap, true, out[mc .. mc + left_count]);
    if (right_count > 0) layout.splitAxis(right, right_count, gap, true, out[mc + left_count .. n]);
    return n;
}
