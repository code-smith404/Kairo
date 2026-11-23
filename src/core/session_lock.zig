//! Session locking.
//!
//! The compositor owns the `ext-session-lock-v1` global and confines input to
//! the lock client's surfaces while a lock is active. Authentication is
//! deliberately delegated to the lock client (for example swaylock); Kairo
//! never invents its own password prompt or unlock shortcut.

const std = @import("std");
const c = @import("../bindings.zig").c;
const log = @import("../util/log.zig");
const wl = @import("wl.zig");
const Server = @import("server.zig").Server;
const Output = @import("output.zig").Output;

const Backdrop = struct {
    owner: *SessionLock,
    output: *Output,
    rect: *c.struct_wlr_scene_rect,
    destroy: wl.Listener,

    fn create(owner: *SessionLock, output: *Output) !*Backdrop {
        const self = try owner.server.allocator.create(Backdrop);
        errdefer owner.server.allocator.destroy(self);
        const color = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
        const rect = c.wlr_scene_rect_create(owner.tree, @max(1, output.full.width), @max(1, output.full.height), &color) orelse
            return error.SceneRectCreateFailed;
        c.wlr_scene_node_set_position(&rect.*.node, output.full.x, output.full.y);
        self.* = .{
            .owner = owner,
            .output = output,
            .rect = rect,
            .destroy = .{ .notify = handleOutputDestroy },
        };
        self.destroy.data = self;
        wl.add(&output.wlr_output.events.destroy, &self.destroy);
        return self;
    }

    fn destroySelf(self: *Backdrop) void {
        wl.remove(&self.output.wlr_output.events.destroy, &self.destroy);
        c.wlr_scene_node_destroy(&self.rect.*.node);
        self.owner.server.allocator.destroy(self);
    }

    fn handleOutputDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Backdrop = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const owner = self.owner;
        owner.removeBackdrop(self);
    }
};

const LockSurface = struct {
    owner: *SessionLock,
    lock_surface: *c.struct_wlr_session_lock_surface_v1,
    surface: *c.struct_wlr_surface,
    output: *Output,
    scene_surface: *c.struct_wlr_scene_surface,
    map: wl.Listener,
    unmap: wl.Listener,
    destroy: wl.Listener,
    mapped: bool = false,

    fn create(owner: *SessionLock, lock_surface: *c.struct_wlr_session_lock_surface_v1) !*LockSurface {
        const wlr_output = lock_surface.output orelse return error.NoOutput;
        const output = owner.server.findOutputByWlr(wlr_output) orelse return error.UnknownOutput;
        const surface_raw = lock_surface.surface orelse return error.NoSurface;
        const surface: *c.struct_wlr_surface = @ptrCast(surface_raw);

        const self = try owner.server.allocator.create(LockSurface);
        errdefer owner.server.allocator.destroy(self);

        const scene_surface_raw = c.wlr_scene_surface_create(owner.tree, surface) orelse return error.SceneSurfaceCreateFailed;
        const scene_surface: *c.struct_wlr_scene_surface = @ptrCast(scene_surface_raw);
        c.wlr_scene_node_set_enabled(&scene_surface.buffer.*.node, false);
        c.wlr_scene_node_set_position(&scene_surface.buffer.*.node, output.full.x, output.full.y);

        self.* = .{
            .owner = owner,
            .lock_surface = lock_surface,
            .surface = surface,
            .output = output,
            .scene_surface = scene_surface,
            .map = .{ .notify = handleMap },
            .unmap = .{ .notify = handleUnmap },
            .destroy = .{ .notify = handleDestroy },
        };
        self.map.data = self;
        self.unmap.data = self;
        self.destroy.data = self;
        wl.add(&surface.events.map, &self.map);
        wl.add(&surface.events.unmap, &self.unmap);
        wl.add(&lock_surface.events.destroy, &self.destroy);

        // ext-session-lock-v1 requires the compositor to configure every lock
        // surface before the client can attach a buffer.
        const width: u32 = @intCast(@max(1, output.full.width));
        const height: u32 = @intCast(@max(1, output.full.height));
        _ = c.wlr_session_lock_surface_v1_configure(lock_surface, width, height);
        return self;
    }

    fn update(self: *LockSurface) void {
        c.wlr_scene_node_set_position(&self.scene_surface.buffer.*.node, self.output.full.x, self.output.full.y);
    }

    /// Remove our bookkeeping without touching the scene graph. Used from the
    /// protocol destroy callback, where SceneFX's surface listener already
    /// tears the scene buffer down.
    fn detach(self: *LockSurface) void {
        wl.remove(&self.surface.events.map, &self.map);
        wl.remove(&self.surface.events.unmap, &self.unmap);
        wl.remove(&self.lock_surface.events.destroy, &self.destroy);
        self.owner.removeSurface(self);
        self.owner.server.updateInputFocus();
        self.owner.server.allocator.destroy(self);
    }

    /// Tear down a still-live lock surface from the compositor side.
    fn destroyNow(self: *LockSurface) void {
        wl.remove(&self.surface.events.map, &self.map);
        wl.remove(&self.surface.events.unmap, &self.unmap);
        wl.remove(&self.lock_surface.events.destroy, &self.destroy);
        c.wlr_scene_node_destroy(&self.scene_surface.buffer.*.node);
        self.owner.removeSurface(self);
        self.owner.server.allocator.destroy(self);
    }

    fn handleMap(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *LockSurface = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.mapped = true;
        self.update();
        c.wlr_scene_node_set_enabled(&self.scene_surface.buffer.*.node, true);
        self.owner.server.updateInputFocus();
    }

    fn handleUnmap(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *LockSurface = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.mapped = false;
        c.wlr_scene_node_set_enabled(&self.scene_surface.buffer.*.node, false);
        self.owner.server.updateInputFocus();
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *LockSurface = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.detach();
    }
};

pub const PointerHit = struct {
    surface: *c.struct_wlr_surface,
    sx: f64,
    sy: f64,
};

pub const SessionLock = struct {
    server: *Server,
    tree: *c.struct_wlr_scene_tree,
    manager: *c.struct_wlr_session_lock_manager_v1,
    lock: ?*c.struct_wlr_session_lock_v1 = null,
    surfaces: std.ArrayList(*LockSurface),
    backdrops: std.ArrayList(*Backdrop),

    new_lock: wl.Listener,
    new_surface: wl.Listener,
    unlock: wl.Listener,
    destroy: wl.Listener,

    pub fn init(server: *Server, tree: *c.struct_wlr_scene_tree) !*SessionLock {
        const self = try server.allocator.create(SessionLock);
        errdefer server.allocator.destroy(self);
        const manager_raw = c.wlr_session_lock_manager_v1_create(server.display) orelse
            return error.SessionLockManagerCreateFailed;
        const manager: *c.struct_wlr_session_lock_manager_v1 = @ptrCast(manager_raw);
        self.* = .{
            .server = server,
            .tree = tree,
            .manager = manager,
            .surfaces = std.ArrayList(*LockSurface).empty,
            .backdrops = std.ArrayList(*Backdrop).empty,
            .new_lock = .{ .notify = handleNewLock },
            .new_surface = .{ .notify = handleNewSurface },
            .unlock = .{ .notify = handleUnlock },
            .destroy = .{ .notify = handleLockDestroy },
        };
        self.new_lock.data = self;
        self.new_surface.data = self;
        self.unlock.data = self;
        self.destroy.data = self;
        wl.add(&manager.events.new_lock, &self.new_lock);
        return self;
    }

    pub fn deinit(self: *SessionLock) void {
        wl.remove(&self.manager.events.new_lock, &self.new_lock);
        self.server.session_locked = false;
        self.detachLock();
        self.clearSurfaces();
        self.clearBackdrops();
        c.wlr_scene_node_destroy(&self.tree.node);
        self.surfaces.deinit(self.server.allocator);
        self.backdrops.deinit(self.server.allocator);
        self.server.allocator.destroy(self);
    }

    pub fn active(self: *const SessionLock) bool {
        return self.server.session_locked;
    }

    pub fn hasMappedSurface(self: *const SessionLock) bool {
        for (self.surfaces.items) |s| {
            if (s.mapped) return true;
        }
        return false;
    }

    /// Update keyboard focus to a lock surface. Called by Server whenever the
    /// focused output changes or a lock surface commits its first buffer.
    pub fn updateKeyboardFocus(self: *SessionLock) void {
        const target = self.mappedSurfaceForOutput(self.server.focused_output) orelse self.firstMappedSurface();
        if (target) |s| {
            var keycodes: [0]u32 = .{};
            c.wlr_seat_keyboard_notify_enter(self.server.seat, s.surface, &keycodes, 0, &self.server.input.group.keyboard.modifiers);
        } else {
            c.wlr_seat_keyboard_notify_clear_focus(self.server.seat);
        }
    }

    pub fn pointerAt(self: *SessionLock, x: f64, y: f64) ?PointerHit {
        var i = self.surfaces.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.surfaces.items[i];
            if (!s.mapped) continue;
            const b = s.output.full;
            if (x < @as(f64, @floatFromInt(b.x)) or y < @as(f64, @floatFromInt(b.y))) continue;
            if (x >= @as(f64, @floatFromInt(b.x + b.width)) or y >= @as(f64, @floatFromInt(b.y + b.height))) continue;
            return .{
                .surface = s.surface,
                .sx = x - @as(f64, @floatFromInt(b.x)),
                .sy = y - @as(f64, @floatFromInt(b.y)),
            };
        }
        return null;
    }

    pub fn reposition(self: *SessionLock) void {
        for (self.backdrops.items) |b| {
            c.wlr_scene_rect_set_size(b.rect, @max(1, b.output.full.width), @max(1, b.output.full.height));
            c.wlr_scene_node_set_position(&b.rect.*.node, b.output.full.x, b.output.full.y);
        }
        for (self.surfaces.items) |s| s.update();
    }

    /// Synchronise backdrops with the current output list. Called after
    /// output hotplug while a lock is active.
    pub fn refreshOutputs(self: *SessionLock) void {
        if (!self.server.session_locked) return;
        for (self.server.outputs.items) |output| {
            var found = false;
            for (self.backdrops.items) |b| {
                if (b.output == output) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const b = Backdrop.create(self, output) catch |err| {
                    log.err("session lock: failed to create output backdrop: {s}", .{@errorName(err)});
                    continue;
                };
                self.backdrops.append(self.server.allocator, b) catch {
                    b.destroySelf();
                };
            }
        }
        self.reposition();
    }

    fn firstMappedSurface(self: *SessionLock) ?*LockSurface {
        for (self.surfaces.items) |s| {
            if (s.mapped) return s;
        }
        return null;
    }

    fn mappedSurfaceForOutput(self: *SessionLock, output: ?*Output) ?*LockSurface {
        const o = output orelse return null;
        for (self.surfaces.items) |s| {
            if (s.mapped and s.output == o) return s;
        }
        return null;
    }

    fn removeSurface(self: *SessionLock, surface: *LockSurface) void {
        for (self.surfaces.items, 0..) |item, i| {
            if (item == surface) {
                _ = self.surfaces.swapRemove(i);
                return;
            }
        }
    }

    fn removeBackdrop(self: *SessionLock, backdrop: *Backdrop) void {
        for (self.backdrops.items, 0..) |item, i| {
            if (item == backdrop) {
                _ = self.backdrops.swapRemove(i);
                break;
            }
        }
        backdrop.destroySelf();
    }

    fn clearSurfaces(self: *SessionLock) void {
        while (self.surfaces.items.len > 0) {
            self.surfaces.items[0].destroyNow();
        }
    }

    fn clearBackdrops(self: *SessionLock) void {
        while (self.backdrops.items.len > 0) {
            self.backdrops.items[0].destroySelf();
            _ = self.backdrops.pop();
        }
    }

    fn activate(self: *SessionLock) void {
        const server = self.server;
        server.session_locked = true;
        server.overview_active = false;
        server.arrangeAll();
        if (server.input.repeat_active) {
            server.input.repeat_active = false;
            if (server.input.repeat_timer) |t| _ = c.wl_event_source_timer_update(t, 0);
        }
        server.input.resetPointerFocus();
        self.refreshOutputs();
        self.updateKeyboardFocus();
        server.emitSession();
        log.info("session locked", .{});
    }

    fn detachLock(self: *SessionLock) void {
        if (self.lock) |lock| {
            wl.remove(&lock.events.new_surface, &self.new_surface);
            wl.remove(&lock.events.unlock, &self.unlock);
            wl.remove(&lock.events.destroy, &self.destroy);
            self.lock = null;
        }
    }

    fn deactivate(self: *SessionLock) void {
        const server = self.server;
        self.clearSurfaces();
        self.clearBackdrops();
        server.session_locked = false;
        server.input.resetPointerFocus();
        server.arrangeAll();
        server.focusTopWindow();
        server.updateInputFocus();
        server.emitSession();
        log.info("session unlocked", .{});
    }

    fn handleNewLock(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *SessionLock = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const lock: *c.struct_wlr_session_lock_v1 = @ptrCast(@alignCast(data.?));
        if (self.lock != null) {
            // The protocol forbids a second lock client.
            c.wlr_session_lock_v1_destroy(lock);
            return;
        }
        lock.data = self;
        self.lock = lock;
        wl.add(&lock.events.new_surface, &self.new_surface);
        wl.add(&lock.events.unlock, &self.unlock);
        wl.add(&lock.events.destroy, &self.destroy);
        c.wlr_session_lock_v1_send_locked(lock);
        self.activate();
    }

    fn handleNewSurface(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *SessionLock = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const lock_surface: *c.struct_wlr_session_lock_surface_v1 = @ptrCast(@alignCast(data.?));
        const s = LockSurface.create(self, lock_surface) catch |err| {
            log.err("session lock: failed to create lock surface: {s}", .{@errorName(err)});
            return;
        };
        self.surfaces.append(self.server.allocator, s) catch {
            s.destroyNow();
            return;
        };
        s.update();
    }

    fn handleUnlock(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *SessionLock = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.detachLock();
        self.deactivate();
    }

    fn handleLockDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *SessionLock = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.detachLock();
        if (self.server.session_locked) self.deactivate();
    }
};
