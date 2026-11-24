//! Session idle actions: lock and/or suspend after a configured timeout,
//! and idle-inhibit accounting for the ext-idle-notify-v1 state.
//!
//! wlroots 0.20 exposes the notifier global and expects the compositor to
//! report activity (Server.notifyActivity) and maintain inhibition state.
//! This module owns the timer that turns the configured timeout into session
//! actions, and the inhibit bookkeeping that video players and similar
//! clients rely on. Idle lock actions respect the session lock: they are
//! skipped while a lock is already active.

const std = @import("std");
const c = @import("../bindings.zig").c;
const log = @import("../util/log.zig");
const wl = @import("wl.zig");
const Server = @import("server.zig").Server;

pub const Idle = struct {
    server: *Server,
    timer: ?*c.struct_wl_event_source = null,
    last_activity_ms: i64 = 0,
    fired: bool = false,
    inhibit_count: u32 = 0,

    pub fn create(server: *Server) void {
        if (server.idle_notifier == null) return;
        const self = server.allocator.create(Idle) catch {
            log.warn("idle management unavailable: out of memory", .{});
            return;
        };
        self.* = .{ .server = server };
        server.idle = self;
        const loop = c.wl_display_get_event_loop(server.display);
        self.timer = c.wl_event_loop_add_timer(loop, timerFire, self);
        if (self.timer != null) {
            _ = c.wl_event_source_timer_update(self.timer, 1000);
        }
        self.last_activity_ms = wl.nowMsec();
        const timeout = server.config.idle_timeout_ms;
        if (timeout != 0 and (server.config.idle_lock or server.config.idle_suspend)) {
            log.info("idle actions armed: timeout {d} ms (lock={}, suspend={})", .{ timeout, server.config.idle_lock, server.config.idle_suspend });
        }
    }

    pub fn destroy(self: *Idle) void {
        if (self.timer) |t| _ = c.wl_event_source_remove(t);
        self.server.allocator.destroy(self);
    }

    pub fn notifyActivity(self: *Idle) void {
        self.last_activity_ms = wl.nowMsec();
        if (self.fired) {
            self.fired = false;
            log.info("idle state ended", .{});
        }
    }

    fn timerFire(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Idle = @ptrCast(@alignCast(data.?));
        const server = self.server;
        const timeout: i64 = @intCast(server.config.idle_timeout_ms);
        const armed = timeout > 0 and (server.config.idle_lock or server.config.idle_suspend);
        if (armed and !self.fired and self.inhibit_count == 0) {
            const idle_ms = wl.nowMsec() - self.last_activity_ms;
            if (idle_ms >= timeout) {
                self.fired = true;
                self.fireActions();
            }
        }
        return 1000; // re-arm the 1 s tick
    }

    fn fireActions(self: *Idle) void {
        const server = self.server;
        if (server.session_locked) {
            log.info("idle timeout reached; session already locked", .{});
            return;
        }
        if (server.config.idle_lock) {
            if (server.config.lock_command.len == 0) {
                log.warn("idle lock requested but lock_command is not configured", .{});
            } else {
                log.info("idle timeout reached; locking session", .{});
                server.dispatch(.toggle_session_lock, "");
            }
        }
        if (server.config.idle_suspend) {
            log.info("idle timeout reached; suspending", .{});
            server.spawn("systemctl suspend");
        }
    }
};

/// Track idle-inhibit clients and mirror their presence into the notifier so
/// the ext-idle-notify-v1 state matches reality.
pub const InhibitTracker = struct {
    server: *Server,
    manager: *c.struct_wlr_idle_inhibit_manager_v1,
    count: u32 = 0,
    listeners: struct {
        new_inhibitor: wl.Listener,
        destroy: wl.Listener,
    },

    pub fn create(server: *Server, manager: *c.struct_wlr_idle_inhibit_manager_v1) !*InhibitTracker {
        const self = try server.allocator.create(InhibitTracker);
        errdefer server.allocator.destroy(self);
        self.* = .{
            .server = server,
            .manager = manager,
            .listeners = .{
                .new_inhibitor = .{ .notify = handleNewInhibitor },
                .destroy = .{ .notify = handleManagerDestroy },
            },
        };
        self.listeners.new_inhibitor.data = self;
        self.listeners.destroy.data = self;
        wl.listen(&manager.events.new_inhibitor, &self.listeners.new_inhibitor, handleNewInhibitor);
        wl.listen(&manager.events.destroy, &self.listeners.destroy, handleManagerDestroy);
        return self;
    }

    fn bump(self: *InhibitTracker, delta: i32) void {
        const before = self.count;
        if (delta < 0) {
            self.count -|= @intCast(-delta);
        } else {
            self.count += @intCast(delta);
        }
        if (before != self.count) {
            c.wlr_idle_notifier_v1_set_inhibited(self.server.idle_notifier, self.count > 0);
            log.info("idle inhibition: {d} client(s)", .{self.count});
        }
    }

    fn handleNewInhibitor(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *InhibitTracker = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const inhibitor: *c.struct_wlr_idle_inhibitor_v1 = @ptrCast(@alignCast(data.?));
        self.bump(1);
        // Keep the inhibitor alive in our accounting until its surface dies.
        const watcher = self.server.allocator.create(Watcher) catch return;
        watcher.* = .{
            .tracker = self,
            .inhibitor = inhibitor,
            .listener = .{ .notify = handleInhibitorDestroy },
        };
        watcher.listener.data = watcher;
        wl.listen(&inhibitor.events.destroy, &watcher.listener, handleInhibitorDestroy);
    }

    fn handleInhibitorDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const watcher: *Watcher = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        wl.remove(&watcher.inhibitor.events.destroy, &watcher.listener);
        watcher.tracker.bump(-1);
        watcher.tracker.server.allocator.destroy(watcher);
    }

    fn handleManagerDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *InhibitTracker = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.server.idle_inhibit = null;
        self.server.allocator.destroy(self);
    }
};

const Watcher = struct {
    tracker: *InhibitTracker,
    inhibitor: *c.struct_wlr_idle_inhibitor_v1,
    listener: wl.Listener,
};
