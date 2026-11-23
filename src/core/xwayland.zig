//! XWayland integration.

const std = @import("std");
const c = @import("../bindings.zig").c;
const log = @import("../util/log.zig");
const wl = @import("wl.zig");
const Server = @import("server.zig").Server;
const Window = @import("window.zig").Window;

pub const XWayland = struct {
    server: *Server,
    xwayland: *c.struct_wlr_xwayland,
    ready: wl.Listener,
    new_surface: wl.Listener,
    destroy: wl.Listener,

    pub fn init(server: *Server) !?*XWayland {
        if (!server.config.xwayland) return null;
        const xw = c.wlr_xwayland_create(server.display, server.compositor, !server.config.xwayland_persistence);
        if (xw == null) {
            log.warn("XWayland is not available; X11 applications will not run", .{});
            return null;
        }
        const self = try server.allocator.create(XWayland);
        errdefer server.allocator.destroy(self);
        self.* = .{
            .server = server,
            .xwayland = @ptrCast(xw),
            .ready = .{ .notify = handleReady },
            .new_surface = .{ .notify = handleNewSurface },
            .destroy = .{ .notify = handleDestroy },
        };
        self.ready.data = self;
        self.new_surface.data = self;
        self.destroy.data = self;

        c.wlr_xwayland_set_seat(self.xwayland, server.seat);
        wl.add(&self.xwayland.events.ready, &self.ready);
        wl.add(&self.xwayland.events.new_surface, &self.new_surface);
        wl.add(&self.xwayland.events.destroy, &self.destroy);
        if (self.xwayland.display_name) |name| {
            _ = c.setenv("DISPLAY", name, 1);
            log.info("XWayland display {s}", .{std.mem.span(name)});
        }
        return self;
    }

    pub fn deinit(self: *XWayland) void {
        const allocator = self.server.allocator;
        self.server.xwayland = null;
        wl.remove(&self.xwayland.events.ready, &self.ready);
        wl.remove(&self.xwayland.events.new_surface, &self.new_surface);
        wl.remove(&self.xwayland.events.destroy, &self.destroy);
        c.wlr_xwayland_destroy(self.xwayland);
        allocator.destroy(self);
    }

    fn handleReady(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *XWayland = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        if (self.xwayland.display_name) |name| {
            _ = c.setenv("DISPLAY", name, 1);
        }
        log.info("XWayland ready", .{});
    }

    fn handleNewSurface(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *XWayland = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const xsurface: *c.struct_wlr_xwayland_surface = @ptrCast(@alignCast(data.?));
        const w = Window.createX11(self.server, xsurface) catch |err| {
            log.err("failed to manage X11 window: {s}", .{@errorName(err)});
            return;
        };
        if (xsurface.override_redirect) {
            w.floating = true;
            w.overlay = true;
            w.no_border = true;
            w.silent = true;
        } else {
            w.floating = false;
        }
        if (xsurface.title) |t| w.setTitleLoose(std.mem.span(t));
        if (xsurface.class) |cls| w.setAppIdLoose(std.mem.span(cls));
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *XWayland = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        log.warn("XWayland server terminated", .{});
        self.server.xwayland = null;
        self.server.allocator.destroy(self);
    }
};
