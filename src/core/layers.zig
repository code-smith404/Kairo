//! Layer-shell surfaces (bars, wallpapers, notifications, lock overlays).

const std = @import("std");
const c = @import("../bindings.zig").c;
const geom = @import("../util/geometry.zig");
const log = @import("../util/log.zig");
const wl = @import("wl.zig");
const Server = @import("server.zig").Server;
const Output = @import("output.zig").Output;

pub const LayerSurface = struct {
    server: *Server,
    layer_surface: *c.struct_wlr_layer_surface_v1,
    scene_layer: *c.struct_wlr_scene_layer_surface_v1,
    tree: *c.struct_wlr_scene_tree,
    output: *Output,
    mapped: bool = false,
    listeners: struct {
        map: wl.Listener,
        unmap: wl.Listener,
        commit: wl.Listener,
        destroy: wl.Listener,
        new_popup: wl.Listener,
    },

    pub fn create(server: *Server, surface: *c.struct_wlr_layer_surface_v1) !*LayerSurface {
        const self = try server.allocator.create(LayerSurface);
        errdefer server.allocator.destroy(self);

        var output: *Output = undefined;
        if (surface.output) |wlr_out| {
            output = server.findOutput(wlr_out) orelse server.focusedOrFirstOutput() orelse return error.NoOutput;
        } else {
            output = server.focusedOrFirstOutput() orelse return error.NoOutput;
            surface.output = output.wlr_output;
        }

        const parent = switch (surface.current.layer) {
            c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND => server.background_tree,
            c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM => server.bottom_tree,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP => server.top_layer_tree,
            else => server.overlay_tree,
        };
        const scene_layer = c.wlr_scene_layer_surface_v1_create(parent, surface) orelse return error.SceneCreateFailed;

        self.* = .{
            .server = server,
            .layer_surface = surface,
            .scene_layer = scene_layer,
            .tree = @ptrCast(scene_layer.*.tree),
            .output = output,
            .listeners = .{
                .map = .{ .notify = handleMap },
                .unmap = .{ .notify = handleUnmap },
                .commit = .{ .notify = handleCommit },
                .destroy = .{ .notify = handleDestroy },
                .new_popup = .{ .notify = handleNewPopup },
            },
        };
        surface.data = self;
        surface.surface.*.data = self;

        wl.listen(&surface.surface.*.events.map, &self.listeners.map, handleMap);
        wl.listen(&surface.surface.*.events.unmap, &self.listeners.unmap, handleUnmap);
        wl.listen(&surface.surface.*.events.commit, &self.listeners.commit, handleCommit);
        wl.listen(&surface.events.destroy, &self.listeners.destroy, handleDestroy);
        wl.listen(&surface.events.new_popup, &self.listeners.new_popup, handleNewPopup);

        if (surface.initialized) {
            self.server.layers.arrangeAll();
            output.arrange();
        }
        return self;
    }

    fn handleMap(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *LayerSurface = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.mapped = true;
        self.server.layers.arrangeAll();
        self.output.arrange();
        self.server.updateInputFocus();
    }

    fn handleUnmap(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *LayerSurface = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.mapped = false;
        self.server.layers.arrangeAll();
        self.output.arrange();
    }

    fn handleCommit(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *LayerSurface = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        if (!self.layer_surface.initialized) return;
        if (self.layer_surface.initial_commit) {
            // The initial configure is sent by the scene helper, which also
            // applies the desired size and anchors.
        }
        self.server.layers.arrangeAll();
        self.output.arrange();
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *LayerSurface = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.removeListeners();
        self.server.layers.remove(self);
        self.server.allocator.destroy(self);
    }

    fn removeListeners(self: *LayerSurface) void {
        const L = &self.listeners;
        wl.remove(&self.layer_surface.surface.*.events.map, &L.map);
        wl.remove(&self.layer_surface.surface.*.events.unmap, &L.unmap);
        wl.remove(&self.layer_surface.surface.*.events.commit, &L.commit);
        wl.remove(&self.layer_surface.events.destroy, &L.destroy);
        wl.remove(&self.layer_surface.events.new_popup, &L.new_popup);
    }

    fn handleNewPopup(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *LayerSurface = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const popup: *c.struct_wlr_xdg_popup = @ptrCast(@alignCast(data.?));
        _ = c.wlr_scene_xdg_surface_create(self.tree, popup.base);
    }
};

pub const Layers = struct {
    server: *Server,
    surfaces: std.ArrayList(*LayerSurface),

    pub fn init(server: *Server) Layers {
        return .{
            .server = server,
            .surfaces = std.ArrayList(*LayerSurface).empty,
        };
    }

    pub fn deinit(self: *Layers) void {
        for (self.surfaces.items) |ls| {
            ls.removeListeners();
            self.server.allocator.destroy(ls);
        }
        self.surfaces.deinit(self.server.allocator);
    }

    pub fn add(self: *Layers, surface: *c.struct_wlr_layer_surface_v1) !void {
        const ls = try LayerSurface.create(self.server, surface);
        errdefer self.server.allocator.destroy(ls);
        try self.surfaces.append(self.server.allocator, ls);
    }

    pub fn remove(self: *Layers, ls: *LayerSurface) void {
        for (self.surfaces.items, 0..) |item, i| {
            if (item == ls) {
                _ = self.surfaces.swapRemove(i);
                break;
            }
        }
    }

    /// Position all layer surfaces of an output and return the remaining usable
    /// area. Exclusive surfaces are processed from the top layer down, exactly
    /// as layer-shell requires.
    pub fn arrangeOutput(self: *Layers, output: *Output) geom.Box {
        var full: c.struct_wlr_box = undefined;
        c.wlr_output_layout_get_box(self.server.output_layout, output.wlr_output, &full);
        var usable: c.struct_wlr_box = full;

        var layer_idx: i32 = 3;
        while (layer_idx >= 0) : (layer_idx -= 1) {
            for (self.surfaces.items) |ls| {
                if (ls.output != output) continue;
                if (!ls.mapped or !ls.layer_surface.initialized) continue;
                if (@as(i32, @intCast(ls.layer_surface.current.layer)) != layer_idx) continue;
                c.wlr_scene_layer_surface_v1_configure(ls.scene_layer, &full, &usable);
            }
        }
        output.usable = geom.Box.fromC(usable);
        output.full = geom.Box.fromC(full);
        return output.usable;
    }

    pub fn arrangeAll(self: *Layers) void {
        for (self.server.outputs.items) |o| _ = self.arrangeOutput(o);
    }

    pub fn surfaceAt(self: *Layers, lx: f64, ly: f64) ?struct { ls: *LayerSurface, surface: *c.struct_wlr_surface, sx: f64, sy: f64 } {
        // Iterate top to bottom.
        var layer_idx: i32 = 3;
        while (layer_idx >= 0) : (layer_idx -= 1) {
            for (self.surfaces.items) |ls| {
                if (!ls.mapped) continue;
                if (@as(i32, @intCast(ls.layer_surface.current.layer)) != layer_idx) continue;
                var nx: c_int = 0;
                var ny: c_int = 0;
                if (!c.wlr_scene_node_coords(&ls.tree.node, &nx, &ny)) continue;
                const box = geom.Box.init(nx, ny, @intCast(ls.layer_surface.current.actual_width), @intCast(ls.layer_surface.current.actual_height));
                if (!box.contains(lx, ly)) continue;
                var sx: f64 = 0;
                var sy: f64 = 0;
                const surf = c.wlr_layer_surface_v1_surface_at(ls.layer_surface, lx - @as(f64, @floatFromInt(nx)), ly - @as(f64, @floatFromInt(ny)), &sx, &sy);
                if (surf) |s| return .{ .ls = ls, .surface = s, .sx = sx, .sy = sy };
            }
        }
        return null;
    }

    pub fn hasKeyboardFocusable(self: *Layers) bool {
        for (self.surfaces.items) |ls| {
            if (ls.mapped and ls.layer_surface.current.keyboard_interactive != c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) return true;
        }
        return false;
    }

    pub fn focusTopmost(self: *Layers) void {
        var layer_idx: i32 = 3;
        while (layer_idx >= 0) : (layer_idx -= 1) {
            var it = self.surfaces.items.len;
            while (it > 0) {
                it -= 1;
                const ls = self.surfaces.items[it];
                if (!ls.mapped) continue;
                if (@as(i32, @intCast(ls.layer_surface.current.layer)) != layer_idx) continue;
                if (ls.layer_surface.current.keyboard_interactive == c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) continue;
                c.wlr_seat_keyboard_notify_enter(self.server.seat, ls.layer_surface.surface, null, 0, null);
                return;
            }
        }
    }
};
