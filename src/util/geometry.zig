const std = @import("std");

/// A rectangle in layout coordinates.
pub const Box = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub const zero = Box{};

    pub fn init(x: i32, y: i32, width: i32, height: i32) Box {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn right(self: Box) i32 {
        return self.x + self.width;
    }

    pub fn bottom(self: Box) i32 {
        return self.y + self.height;
    }

    pub fn centerX(self: Box) i32 {
        return self.x + @divTrunc(self.width, 2);
    }

    pub fn centerY(self: Box) i32 {
        return self.y + @divTrunc(self.height, 2);
    }

    pub fn isEmpty(self: Box) bool {
        return self.width <= 0 or self.height <= 0;
    }

    pub fn contains(self: Box, px: f64, py: f64) bool {
        return px >= @as(f64, @floatFromInt(self.x)) and
            py >= @as(f64, @floatFromInt(self.y)) and
            px < @as(f64, @floatFromInt(self.right())) and
            py < @as(f64, @floatFromInt(self.bottom()));
    }

    pub fn inset(self: Box, amount: i32) Box {
        var out = self;
        out.x += amount;
        out.y += amount;
        out.width -= amount * 2;
        out.height -= amount * 2;
        if (out.width < 0) out.width = 0;
        if (out.height < 0) out.height = 0;
        return out;
    }

    pub fn insetExt(self: Box, top: i32, right_in: i32, bottom_in: i32, left: i32) Box {
        var out = self;
        out.x += left;
        out.y += top;
        out.width -= left + right_in;
        out.height -= top + bottom_in;
        if (out.width < 0) out.width = 0;
        if (out.height < 0) out.height = 0;
        return out;
    }

    pub fn shrink(self: Box, dx: i32, dy: i32) Box {
        var out = self;
        out.width -= dx;
        out.height -= dy;
        if (out.width < 0) out.width = 0;
        if (out.height < 0) out.height = 0;
        return out;
    }

    pub fn translate(self: Box, dx: i32, dy: i32) Box {
        var out = self;
        out.x += dx;
        out.y += dy;
        return out;
    }

    pub fn eql(a: Box, b: Box) bool {
        return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
    }

    pub fn intersect(a: Box, b: Box) ?Box {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }

    pub fn toF64(self: Box) [4]f64 {
        return .{
            @floatFromInt(self.x),
            @floatFromInt(self.y),
            @floatFromInt(self.width),
            @floatFromInt(self.height),
        };
    }

    pub fn toC(self: Box) @import("../bindings.zig").c.struct_wlr_box {
        return .{
            .x = self.x,
            .y = self.y,
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn fromC(b: @import("../bindings.zig").c.struct_wlr_box) Box {
        return .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height };
    }
};

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn inBox(self: Point, box: Box) bool {
        return box.contains(self.x, self.y);
    }
};

test "box contains and edges" {
    const b = Box.init(10, 20, 100, 50);
    try std.testing.expect(b.right() == 110);
    try std.testing.expect(b.bottom() == 70);
    try std.testing.expect(b.contains(10, 20));
    try std.testing.expect(b.contains(109.9, 69.9));
    try std.testing.expect(!b.contains(110, 20));
    try std.testing.expect(!b.contains(10, 70));
}

test "inset clamps" {
    const b = Box.init(0, 0, 10, 10);
    try std.testing.expect(Box.eql(b.inset(3), Box.init(3, 3, 4, 4)));
    try std.testing.expect(Box.eql(b.inset(20), Box.init(20, 20, 0, 0)));
    try std.testing.expect(Box.eql(b.insetExt(1, 2, 3, 4), Box.init(4, 1, 4, 6)));
}

test "intersection" {
    const a = Box.init(0, 0, 10, 10);
    const b = Box.init(5, 5, 10, 10);
    const i = a.intersect(b) orelse return error.TestUnexpectedResult;
    try std.testing.expect(Box.eql(i, Box.init(5, 5, 5, 5)));
    try std.testing.expect(a.intersect(Box.init(20, 20, 1, 1)) == null);
}
