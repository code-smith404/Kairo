//! Unit test aggregator. All compositor-independent modules are tested here.

const std = @import("std");

test {
    _ = @import("util/geometry.zig");
    _ = @import("layout/layout.zig");
    _ = @import("layout/grid.zig");
    _ = @import("tags/tags.zig");
    _ = @import("animation/engine.zig");
    _ = @import("window/rules.zig");
    _ = @import("config/config.zig");
    _ = @import("config/loader.zig");
    _ = @import("ipc/protocol.zig");
}
