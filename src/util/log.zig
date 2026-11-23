const std = @import("std");

pub const Level = enum {
    err,
    warn,
    info,
    debug,
};

pub var level: Level = .info;

pub fn log(comptime lvl: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(lvl) > @intFromEnum(level)) return;
    const prefix = switch (lvl) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
    std.debug.print("[kairo] {s}: " ++ fmt ++ "\n", .{prefix} ++ args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}
