const geom = @import("../util/geometry.zig");
const layout = @import("layout.zig");
const Box = geom.Box;
const Params = layout.Params;

fn workArea(area: Box, params: Params) Box {
    return area.inset(@max(0, params.gap_outer));
}

/// Deck: the master column is tiled, the remaining windows are stacked on top
/// of each other in the right-hand area, each offset a little so the deck is
/// visible. The server raises the focused card.
pub fn arrange(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    const mc = layout.masterCount(params, n);
    if (mc == 0) {
        return @import("grid.zig").grid(a, n, .{ .gap_inner = gap, .gap_outer = 0 }, out);
    }
    if (mc >= n) {
        layout.splitAxis(a, n, gap, true, out);
        return n;
    }
    const mw = layout.masterExtent(a.width, gap, params.master_factor);
    const master = Box.init(a.x, a.y, mw, a.height);
    layout.splitAxis(master, mc, gap, true, out[0..mc]);

    const stack = Box.init(a.x + mw + gap, a.y, a.width - mw - gap, a.height);
    const cards = n - mc;
    const offset = @min(@max(4, params.gap_inner * 3), @divTrunc(stack.width, 4));
    for (0..cards) |i| {
        const shift: i32 = @intCast(@min(i, 8));
        const x = stack.x + shift * offset;
        const w = @max(1, stack.width - shift * offset);
        out[mc + i] = Box.init(x, stack.y, w, stack.height);
    }
    return n;
}
