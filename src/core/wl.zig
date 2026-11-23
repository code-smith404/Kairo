//! Small helpers around wlroots' C signal/list conventions.

const c = @import("../bindings.zig").c;

pub fn containerOf(comptime T: type, comptime field: []const u8, ptr: anytype) *T {
    const p: *anyopaque = @ptrCast(@constCast(ptr));
    return @ptrFromInt(@intFromPtr(p) - @offsetOf(T, field));
}

/// Layout-compatible superset of `struct wl_listener` that carries an owner
/// pointer. libwayland only ever touches `link` and `notify`.
pub const Listener = extern struct {
    link: c.struct_wl_list = std.mem.zeroes(c.struct_wl_list),
    notify: c.wl_notify_func_t = null,
    data: ?*anyopaque = null,
};

pub fn listen(signal: *c.struct_wl_signal, listener: *Listener, comptime cb: anytype) void {
    listener.notify = cb;
    c.wl_signal_add(signal, @ptrCast(listener));
}

pub fn add(signal: *c.struct_wl_signal, listener: *Listener) void {
    c.wl_signal_add(signal, @ptrCast(listener));
}

pub fn remove(signal: *c.struct_wl_signal, listener: *Listener) void {
    _ = signal;
    if (listener.link.prev == null or listener.link.next == null) return;
    c.wl_list_remove(&listener.link);
    listener.link = std.mem.zeroes(c.struct_wl_list);
}

pub fn dataOf(comptime T: type, listener: [*c]c.struct_wl_listener) *T {
    const l: *Listener = @ptrCast(@alignCast(listener));
    return @ptrCast(@alignCast(l.data.?));
}

pub fn listForEach(comptime T: type, comptime field: []const u8, list: *c.struct_wl_list, ctx: anytype, comptime cb: anytype) void {
    var it = list.next;
    while (it != list) {
        const next = it.*.next;
        const obj: *T = containerOf(T, field, it);
        cb(ctx, obj);
        it = next;
    }
}

pub fn initList(list: *c.struct_wl_list) void {
    list.prev = list;
    list.next = list;
}

pub fn nowMsec() u32 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @intCast(@divTrunc(@as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1000000), 1));
}

pub fn nowNsec() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * std.time.ns_per_s + ts.tv_nsec;
}

const std = @import("std");
