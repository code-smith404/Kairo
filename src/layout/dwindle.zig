const geom = @import("../util/geometry.zig");
const layout = @import("layout.zig");
const Box = geom.Box;
const Params = layout.Params;

fn workArea(area: Box, params: Params) Box {
    return area.inset(@max(0, params.gap_outer));
}

/// Dwindle: recursively split the work area, alternating the split axis so the
/// aspect ratio stays reasonable. The focused window is the first rectangle.
pub fn arrange(area: Box, n: usize, params: Params, out: []Box) usize {
    if (n == 0) return 0;
    const a = workArea(area, params);
    rec(a, out[0..n], @max(0, params.gap_inner));
    return n;
}

fn rec(area: Box, out: []Box, gap: i32) void {
    if (out.len == 0) return;
    if (out.len == 1) {
        out[0] = area;
        return;
    }
    if (out.len == 2) {
        if (area.width >= area.height) {
            const left = @divTrunc(area.width - gap, 2);
            out[0] = Box.init(area.x, area.y, left, area.height);
            out[1] = Box.init(area.x + left + gap, area.y, area.width - left - gap, area.height);
        } else {
            const top = @divTrunc(area.height - gap, 2);
            out[0] = Box.init(area.x, area.y, area.width, top);
            out[1] = Box.init(area.x, area.y + top + gap, area.width, area.height - top - gap);
        }
        return;
    }
    const half = out.len / 2;
    if (area.width >= area.height) {
        const left_w = @divTrunc(area.width - gap, 2);
        const left = Box.init(area.x, area.y, left_w, area.height);
        const right = Box.init(area.x + left_w + gap, area.y, area.width - left_w - gap, area.height);
        rec(left, out[0..half], gap);
        rec(right, out[half..], gap);
    } else {
        const top_h = @divTrunc(area.height - gap, 2);
        const top = Box.init(area.x, area.y, area.width, top_h);
        const bottom = Box.init(area.x, area.y + top_h + gap, area.width, area.height - top_h - gap);
        rec(top, out[0..half], gap);
        rec(bottom, out[half..], gap);
    }
}
