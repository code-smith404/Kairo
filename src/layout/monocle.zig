const geom = @import("../util/geometry.zig");
const layout = @import("layout.zig");
const Box = geom.Box;
const Params = layout.Params;

/// Monocle: every window occupies the work area. The server raises the focused
/// window, so the focused client is fully visible while the others remain
/// mapped (and can be previewed when the focused one is translucent).
pub fn arrange(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = area.inset(@max(0, params.gap_outer));
    for (0..n) |i| out[i] = a;
    return n;
}
