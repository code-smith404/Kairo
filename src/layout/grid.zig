const geom = @import("../util/geometry.zig");
const layout = @import("layout.zig");
const Box = geom.Box;
const Params = layout.Params;

fn workArea(area: Box, params: Params) Box {
    return area.inset(@max(0, params.gap_outer));
}

fn cellStart(offset: i32, total: i32, count: usize, gap: i32, index: usize) struct { start: i32, size: i32 } {
    if (count == 0) return .{ .start = offset, .size = 0 };
    const c: i32 = @intCast(count);
    const usable = @max(0, total - gap * (c - 1));
    const base = @divTrunc(usable, c);
    const extra = @rem(usable, c);
    const idx: i32 = @intCast(index);
    const before_extra = @min(idx, extra);
    const start = offset + idx * base + before_extra * 1 + idx * gap;
    const size = base + (if (idx < extra) @as(i32, 1) else @as(i32, 0));
    return .{ .start = start, .size = @max(0, size) };
}

pub fn grid(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    var cols: usize = 1;
    while (cols * cols < n) : (cols += 1) {}
    const rows = (n + cols - 1) / cols;
    for (0..rows) |r| {
        const y = cellStart(a.y, a.height, rows, gap, r);
        const remaining = n - r * cols;
        const in_row = @min(cols, remaining);
        for (0..in_row) |col| {
            const x = cellStart(a.x, a.width, in_row, gap, col);
            out[r * cols + col] = Box.init(x.start, y.start, x.size, y.size);
        }
    }
    return n;
}

pub fn verticalGrid(area: Box, n: usize, params: Params, out: []Box) usize {
    const a = workArea(area, params);
    if (n == 1) {
        out[0] = a;
        return 1;
    }
    const gap = @max(0, params.gap_inner);
    var rows: usize = 1;
    while (rows * rows < n) : (rows += 1) {}
    const cols = (n + rows - 1) / rows;
    for (0..cols) |col| {
        const x = cellStart(a.x, a.width, cols, gap, col);
        const remaining = n - col * rows;
        const in_col = @min(rows, remaining);
        for (0..in_col) |r| {
            const y = cellStart(a.y, a.height, in_col, gap, r);
            out[col * rows + r] = Box.init(x.start, y.start, x.size, y.size);
        }
    }
    return n;
}

test "grid covers all windows" {
    var out: [16]Box = undefined;
    const n = grid(Box.init(0, 0, 1000, 800), 7, .{}, &out);
    try @import("std").testing.expectEqual(@as(usize, 7), n);
    for (out[0..7]) |b| try @import("std").testing.expect(b.width > 0 and b.height > 0);
}
