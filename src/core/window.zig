//! A managed window (Wayland xdg-toplevel or X11 window) and its scene nodes.

const std = @import("std");
const c = @import("../bindings.zig").c;
const geom = @import("../util/geometry.zig");
const log = @import("../util/log.zig");
const wl = @import("wl.zig");
const rules = @import("../window/rules.zig");
const effects = @import("../effects/effects.zig");
const anim = @import("../animation/engine.zig");
const Server = @import("server.zig").Server;
const Output = @import("output.zig").Output;
const config = @import("../config/config.zig");

pub const Kind = union(enum) {
    xdg: *c.struct_wlr_xdg_surface,
    x11: *c.struct_wlr_xwayland_surface,
};

pub const Window = struct {
    server: *Server,
    id: u32,
    kind: Kind,
    output: ?*Output = null,
    scene_tree: ?*c.struct_wlr_scene_tree = null,
    content: ?*c.struct_wlr_scene_tree = null,
    border: ?*c.struct_wlr_scene_rect = null,
    fx: effects.Nodes = .{},

    title_buf: []u8 = &.{},
    app_id_buf: []u8 = &.{},
    scratchpad_name: ?[]u8 = null,
    tags: u32 = 1,
    mapped: bool = false,
    mapped_once: bool = false,
    closing: bool = false,
    closing_sent: bool = false,
    visible_target: bool = false,
    destroyed: bool = false,

    floating: bool = false,
    fullscreen: bool = false,
    fake_fullscreen: bool = false,
    maximized: bool = false,
    minimized: bool = false,
    global: bool = false,
    overlay: bool = false,
    urgent: bool = false,
    silent: bool = false,
    scratchpad_visible: bool = false,
    no_blur: bool = false,
    no_shadow: bool = false,
    no_radius: bool = false,
    no_border: bool = false,
    no_animation: bool = false,
    allow_csd: bool = false,
    rules_once_applied: bool = false,

    natural_w: i32 = 800,
    natural_h: i32 = 600,
    /// Content rectangle in layout coordinates.
    geom: geom.Box = .{},
    /// Frame rectangle (content plus border) target.
    frame: geom.Box = .{},
    float_geom: geom.Box = .{},
    anim_frame: anim.RectTrack = .{ .from = .{}, .to = .{} },
    anim_opacity: anim.Track = .{ .from = 1, .to = 1 },
    opacity: f32 = 1.0,
    focused_opacity: f32 = 1.0,
    unfocused_opacity: f32 = 1.0,
    focused: bool = false,
    pending_open: bool = false,
    last_opacity: f32 = -1,
    last_radius: i32 = -1,
    border_width: i32 = 0,

    listeners: struct {
        commit: wl.Listener,
        map: wl.Listener,
        unmap: wl.Listener,
        destroy: wl.Listener,
        request_move: wl.Listener,
        request_resize: wl.Listener,
        request_maximize: wl.Listener,
        request_fullscreen: wl.Listener,
        request_minimize: wl.Listener,
        set_title: wl.Listener,
        set_app_id: wl.Listener,
        new_popup: wl.Listener,
        request_activate: wl.Listener = .{ .notify = ignoreEvent },
        set_parent: wl.Listener = .{ .notify = ignoreEvent },
        // XWayland-only listeners, installed by core/xwayland.zig.
        associate: wl.Listener = .{ .notify = ignoreEvent },
        dissociate: wl.Listener = .{ .notify = ignoreEvent },
        request_configure: wl.Listener = .{ .notify = ignoreEvent },
    },

    pub fn createXdg(server: *Server, toplevel_ptr: *c.struct_wlr_xdg_toplevel) !*Window {
        const tl_ptr = toplevel_ptr;
        const base = tl_ptr.base orelse return error.InvalidToplevel;
        const self = try server.allocator.create(Window);
        errdefer server.allocator.destroy(self);

        self.* = .{
            .server = server,
            .id = server.next_window_id,
            .kind = .{ .xdg = base },
            .border_width = server.config.border_width,
            .focused_opacity = server.config.effects.focused_opacity,
            .unfocused_opacity = server.config.effects.unfocused_opacity,
            .title_buf = &.{},
            .app_id_buf = &.{},
            .listeners = .{
                .commit = .{ .notify = handleCommit },
                .map = .{ .notify = handleMap },
                .unmap = .{ .notify = handleUnmap },
                .destroy = .{ .notify = handleDestroy },
                .request_move = .{ .notify = handleRequestMove },
                .request_resize = .{ .notify = handleRequestResize },
                .request_maximize = .{ .notify = handleRequestMaximize },
                .request_fullscreen = .{ .notify = handleRequestFullscreen },
                .request_minimize = .{ .notify = handleRequestMinimize },
                .set_title = .{ .notify = handleSetTitle },
                .set_app_id = .{ .notify = handleSetAppId },
                .new_popup = .{ .notify = handleNewPopup },
            },
        };
        server.next_window_id += 1;
        base.*.data = self;

        const surf = self.wlSurface() orelse return error.InvalidToplevel;
        const L = &self.listeners;
        L.commit.data = self;
        L.map.data = self;
        L.unmap.data = self;
        L.destroy.data = self;
        L.request_move.data = self;
        L.request_resize.data = self;
        L.request_maximize.data = self;
        L.request_fullscreen.data = self;
        L.request_minimize.data = self;
        L.set_title.data = self;
        L.set_app_id.data = self;
        L.new_popup.data = self;

        wl.listen(&surf.events.commit, &L.commit, handleCommit);
        wl.listen(&surf.events.map, &L.map, handleMap);
        wl.listen(&surf.events.unmap, &L.unmap, handleUnmap);
        wl.listen(&tl_ptr.events.destroy, &L.destroy, handleDestroy);
        wl.listen(&tl_ptr.events.request_move, &L.request_move, handleRequestMove);
        wl.listen(&tl_ptr.events.request_resize, &L.request_resize, handleRequestResize);
        wl.listen(&tl_ptr.events.request_maximize, &L.request_maximize, handleRequestMaximize);
        wl.listen(&tl_ptr.events.request_fullscreen, &L.request_fullscreen, handleRequestFullscreen);
        wl.listen(&tl_ptr.events.request_minimize, &L.request_minimize, handleRequestMinimize);
        wl.listen(&tl_ptr.events.set_title, &L.set_title, handleSetTitle);
        wl.listen(&tl_ptr.events.set_app_id, &L.set_app_id, handleSetAppId);
        wl.listen(&base.*.events.new_popup, &L.new_popup, handleNewPopup);

        try server.windows.append(server.allocator, self);
        return self;
    }

    pub fn createX11(server: *Server, xsurface: *c.struct_wlr_xwayland_surface) !*Window {
        const self = try server.allocator.create(Window);
        errdefer server.allocator.destroy(self);
        self.* = .{
            .server = server,
            .id = server.next_window_id,
            .kind = .{ .x11 = xsurface },
            .border_width = server.config.border_width,
            .focused_opacity = server.config.effects.focused_opacity,
            .unfocused_opacity = server.config.effects.unfocused_opacity,
            .title_buf = &.{},
            .app_id_buf = &.{},
            .listeners = .{
                .commit = .{ .notify = ignoreEvent },
                .map = .{ .notify = ignoreEvent },
                .unmap = .{ .notify = ignoreEvent },
                .destroy = .{ .notify = ignoreEvent },
                .request_move = .{ .notify = ignoreEvent },
                .request_resize = .{ .notify = ignoreEvent },
                .request_maximize = .{ .notify = ignoreEvent },
                .request_fullscreen = .{ .notify = ignoreEvent },
                .request_minimize = .{ .notify = ignoreEvent },
                .set_title = .{ .notify = ignoreEvent },
                .set_app_id = .{ .notify = ignoreEvent },
                .new_popup = .{ .notify = ignoreEvent },
                .associate = .{ .notify = handleX11Associate },
                .dissociate = .{ .notify = handleX11Dissociate },
                .request_configure = .{ .notify = handleX11RequestConfigure },
            },
        };
        server.next_window_id += 1;
        xsurface.data = self;

        const L = &self.listeners;
        inline for (.{
            "associate",          "dissociate",       "request_configure",
            "destroy",            "set_title",        "set_app_id",
            "request_move",       "request_resize",   "request_maximize",
            "request_fullscreen", "request_minimize", "request_activate",
            "set_parent",
        }) |name| {
            @field(L, name).data = self;
        }
        wl.listen(&xsurface.events.associate, &L.associate, handleX11Associate);
        wl.listen(&xsurface.events.destroy, &L.destroy, handleX11Destroy);
        wl.listen(&xsurface.events.dissociate, &L.dissociate, handleX11Dissociate);
        wl.listen(&xsurface.events.request_configure, &L.request_configure, handleX11RequestConfigure);
        wl.listen(&xsurface.events.set_title, &L.set_title, handleSetTitle);
        wl.listen(&xsurface.events.set_class, &L.set_app_id, handleSetAppId);
        wl.listen(&xsurface.events.request_move, &L.request_move, handleRequestMove);
        wl.listen(&xsurface.events.request_resize, &L.request_resize, handleX11RequestResize);
        wl.listen(&xsurface.events.request_maximize, &L.request_maximize, handleX11RequestMaximize);
        wl.listen(&xsurface.events.request_fullscreen, &L.request_fullscreen, handleX11RequestFullscreen);
        wl.listen(&xsurface.events.request_minimize, &L.request_minimize, handleX11RequestMinimize);
        wl.listen(&xsurface.events.request_activate, &L.request_activate, handleRequestActivate);
        wl.listen(&xsurface.events.set_parent, &L.set_parent, ignoreEvent);

        try server.windows.append(server.allocator, self);
        if (xsurface.surface) |surf| self.installX11Surface(surf);
        return self;
    }

    fn installX11Surface(self: *Window, surf: *c.struct_wlr_surface) void {
        const L = &self.listeners;
        L.map.data = self;
        L.unmap.data = self;
        wl.listen(&surf.events.map, &L.map, handleMap);
        wl.listen(&surf.events.unmap, &L.unmap, handleUnmap);
    }

    pub fn xdgBase(self: *Window) ?*c.struct_wlr_xdg_surface {
        return switch (self.kind) {
            .xdg => |b| b,
            .x11 => null,
        };
    }

    pub fn xwaylandSurface(self: *Window) ?*c.struct_wlr_xwayland_surface {
        return switch (self.kind) {
            .x11 => |x| x,
            .xdg => null,
        };
    }

    pub fn wlSurface(self: *Window) ?*c.struct_wlr_surface {
        switch (self.kind) {
            .xdg => |b| {
                const p = b.surface;
                if (p == null) return null;
                return @ptrCast(p);
            },
            .x11 => |x| {
                const p = x.surface;
                if (p == null) return null;
                return @ptrCast(p);
            },
        }
    }

    pub fn toplevel(self: *Window) ?*c.struct_wlr_xdg_toplevel {
        const b = self.xdgBase() orelse return null;
        const p = b.unnamed_0.toplevel;
        if (p == null) return null;
        return @ptrCast(p);
    }

    pub fn title(self: *const Window) []const u8 {
        return self.title_buf;
    }

    pub fn appId(self: *const Window) []const u8 {
        return self.app_id_buf;
    }

    pub fn isX11(self: *const Window) bool {
        return self.kind == .x11;
    }

    pub fn isVisible(self: *const Window) bool {
        if (!self.mapped or self.minimized) return false;
        if (self.closing and self.closing_sent) return true;
        if (self.scratchpad_name != null) return self.scratchpad_visible;
        if (self.global) return true;
        const o = self.output orelse return false;
        return o.tags.isVisible(self.tags);
    }

    pub fn effectiveOpacity(self: *const Window, cfg: *const config.Config) f32 {
        const base = if (self.focused) self.focused_opacity else self.unfocused_opacity;
        return std.math.clamp(self.opacity * base * cfg.effects.opacity, 0.0, 1.0);
    }

    pub fn fxParams(self: *Window, cfg: *const config.Config) effects.Params {
        const radius: i32 = if (self.no_radius) 0 else cfg.effects.corner_radius;
        return .{
            .radius = radius,
            .shadow_enabled = cfg.effects.shadows_enabled and !self.no_shadow,
            .shadow_blur = cfg.effects.shadow_blur,
            .shadow_offset_x = cfg.effects.shadow_offset_x,
            .shadow_offset_y = cfg.effects.shadow_offset_y,
            .shadow_color = cfg.effects.shadow_color,
            .blur_enabled = cfg.effects.blur_enabled and !self.no_blur,
        };
    }

    fn ensureScene(self: *Window) void {
        if (self.scene_tree != null) return;
        const parent = self.server.tiling_tree;
        const tree = c.wlr_scene_tree_create(parent) orelse return;
        self.scene_tree = @ptrCast(tree);

        const params = self.fxParams(&self.server.config);
        self.fx = effects.create(self.scene_tree.?, self.frame, params);

        const cfg = &self.server.config;
        const bw = if (self.no_border) 0 else cfg.border_width;
        self.border_width = bw;
        const color = if (self.focused) cfg.border_color_focused else cfg.border_color_unfocused;
        const rect = c.wlr_scene_rect_create(self.scene_tree.?, @max(1, self.frame.width), @max(1, self.frame.height), &color);
        if (rect) |r| {
            self.border = @ptrCast(r);
            c.wlr_scene_node_set_position(&r.*.node, -bw, -bw);
        }

        const content: ?*c.struct_wlr_scene_tree = switch (self.kind) {
            .xdg => |base| blk: {
                const t = c.wlr_scene_xdg_surface_create(self.scene_tree.?, base);
                break :blk if (t == null) null else @ptrCast(t);
            },
            .x11 => blk: {
                const surf = self.wlSurface() orelse break :blk null;
                const t = c.wlr_scene_subsurface_tree_create(self.scene_tree.?, surf);
                break :blk if (t == null) null else @ptrCast(t);
            },
        };
        self.content = content;
        c.wlr_scene_node_set_position(&self.scene_tree.?.node, self.frame.x + bw, self.frame.y + bw);
    }

    pub fn applyRules(self: *Window) void {
        const cfg = &self.server.config;
        const rule = rules.findFor(cfg, self.appId(), self.title()) orelse {
            // Defaults: tiling, on the currently visible tags.
            self.floating = false;
            if (self.output) |o| self.tags = o.tags.active;
            return;
        };
        if (rule.tags) |t| self.tags = t;
        if (rule.floating) |v| self.floating = v;
        if (rule.fullscreen) |v| self.fullscreen = v;
        if (rule.fake_fullscreen) |v| self.fake_fullscreen = v;
        if (rule.maximized) |v| self.maximized = v;
        if (rule.minimized) |v| self.minimized = v;
        if (rule.global) |v| self.global = v;
        if (rule.overlay) |v| self.overlay = v;
        if (rule.silent) |v| self.silent = v;
        if (rule.opacity) |v| self.opacity = v;
        if (rule.focused_opacity) |v| self.focused_opacity = v;
        if (rule.no_blur) |v| self.no_blur = v;
        if (rule.no_shadow) |v| self.no_shadow = v;
        if (rule.no_radius) |v| self.no_radius = v;
        if (rule.no_border) |v| self.no_border = v;
        if (rule.no_animation) |v| self.no_animation = v;
        if (rule.allow_csd) |v| self.allow_csd = v;
        if (rule.width) |w| self.natural_w = w;
        if (rule.height) |h| self.natural_h = h;
        if (rule.output.len > 0) {
            if (self.server.findOutputByName(rule.output)) |o| self.output = o;
        }
    }

    fn updateNaturalSize(self: *Window) void {
        switch (self.kind) {
            .xdg => |base| {
                if (base.geometry.width > 0 and base.geometry.height > 0) {
                    self.natural_w = base.geometry.width;
                    self.natural_h = base.geometry.height;
                } else if (self.toplevel()) |tl| {
                    if (tl.current.width > 0 and tl.current.height > 0) {
                        self.natural_w = tl.current.width;
                        self.natural_h = tl.current.height;
                    }
                }
            },
            .x11 => |x| {
                if (x.width > 0 and x.height > 0) {
                    self.natural_w = x.width;
                    self.natural_h = x.height;
                }
            },
        }
    }

    pub fn centerFloat(self: *Window, area: geom.Box) void {
        const bw = self.border_width * 2;
        const w = self.natural_w + bw;
        const h = self.natural_h + bw;
        self.float_geom = .{
            .x = area.x + @divTrunc(area.width - w, 2),
            .y = area.y + @divTrunc(area.height - h, 2),
            .width = w,
            .height = h,
        };
    }

    pub fn parentTo(self: *Window, parent: *c.struct_wlr_scene_tree) void {
        self.ensureScene();
        const tree = self.scene_tree orelse return;
        c.wlr_scene_node_reparent(&tree.node, parent);
    }

    pub fn raise(self: *Window) void {
        const tree = self.scene_tree orelse return;
        c.wlr_scene_node_raise_to_top(&tree.node);
    }

    pub fn setVisible(self: *Window, visible: bool) void {
        if (self.visible_target == visible) return;
        self.visible_target = visible;
        self.ensureScene();
        const tree = self.scene_tree orelse return;
        const now = wl.nowNsec();
        const cfg = &self.server.config;
        if (visible) {
            c.wlr_scene_node_set_enabled(&tree.node, true);
            const target = self.effectiveOpacity(cfg);
            if (cfg.animations.enabled and !self.no_animation and cfg.animations.fade) {
                const current = if (self.last_opacity >= 0) self.last_opacity else 0;
                self.anim_opacity.start(current, target, now, self.durationOpen(), cfg.animations.easing);
            } else {
                self.anim_opacity.to = target;
                self.anim_opacity.active = false;
            }
        } else {
            const target: f32 = 0;
            if (cfg.animations.enabled and !self.no_animation and cfg.animations.fade) {
                self.anim_opacity.start(self.anim_opacity.value(now), target, now, self.durationClose(), cfg.animations.easing);
            } else {
                self.anim_opacity.to = 0;
                self.anim_opacity.active = false;
                c.wlr_scene_node_set_enabled(&tree.node, false);
            }
        }
        self.scheduleFrame();
    }

    fn durationOpen(self: *Window) u32 {
        const a = &self.server.config.animations;
        return if (a.open_duration_ms > 0) a.open_duration_ms else a.duration_ms;
    }

    fn durationClose(self: *Window) u32 {
        const a = &self.server.config.animations;
        return if (a.close_duration_ms > 0) a.close_duration_ms else a.duration_ms;
    }

    pub fn scheduleFrame(self: *Window) void {
        const o = self.output orelse return;
        o.scheduleFrame();
    }

    /// Apply a frame rectangle (content + border). `animate` starts a geometry
    /// animation from the current visual position.
    pub fn applyGeometry(self: *Window, frame: geom.Box, animate: bool) void {
        self.ensureScene();
        const bw: i32 = if (self.no_border) 0 else self.server.config.border_width;
        self.border_width = bw;
        const inner = frame.inset(bw);
        self.frame = frame;
        self.geom = inner;
        if (self.floating or self.maximized or self.fullscreen or self.overlay) self.float_geom = frame;

        const now = wl.nowNsec();
        const cfg = &self.server.config;
        const a = &cfg.animations;
        if (animate and a.enabled and !self.no_animation and !self.closing and !self.pending_open) {
            const current = self.anim_frame.value(now);
            const dur = if (a.move_duration_ms > 0) a.move_duration_ms else a.duration_ms;
            self.anim_frame.start(current, frame, now, dur, a.easing);
        } else if (self.pending_open and a.enabled and !self.no_animation) {
            self.pending_open = false;
            const start = frame.inset(@max(8, @divTrunc(frame.width, 20)));
            self.anim_frame.start(start, frame, now, self.durationOpen(), a.easing);
            self.anim_opacity.start(0, self.effectiveOpacity(cfg), now, self.durationOpen(), a.easing);
        } else {
            self.anim_frame.from = frame;
            self.anim_frame.to = frame;
            self.anim_frame.active = false;
        }
        self.configure(inner.width, inner.height);
        self.updateEffects(frame);
        self.updateScene(now);
    }

    fn configure(self: *Window, w: i32, h: i32) void {
        switch (self.kind) {
            .xdg => {
                const tl = self.toplevel() orelse return;
                if (tl.current.width != w or tl.current.height != h) {
                    _ = c.wlr_xdg_toplevel_set_size(tl, w, h);
                }
                const edges: u32 = if (self.floating or self.fullscreen) 0 else 0xF;
                _ = c.wlr_xdg_toplevel_set_tiled(tl, edges);
                _ = c.wlr_xdg_toplevel_set_maximized(tl, self.maximized);
                _ = c.wlr_xdg_toplevel_set_fullscreen(tl, self.fullscreen);
            },
            .x11 => |x| {
                if (x.width != w or x.height != h or x.x != self.frame.x or x.y != self.frame.y) {
                    c.wlr_xwayland_surface_configure(x, @intCast(self.frame.x), @intCast(self.frame.y), @intCast(w), @intCast(h));
                }
            },
        }
    }

    fn updateEffects(self: *Window, frame: geom.Box) void {
        const cfg = &self.server.config;
        const params = self.fxParams(cfg);
        const shadow_visible = params.shadow_enabled and !self.fullscreen and self.visible_target;
        const blur_visible = params.blur_enabled and !self.fullscreen and self.visible_target;
        effects.update(self.fx, frame, self.border_width, params, shadow_visible, blur_visible);
        if (self.border) |b| {
            c.wlr_scene_rect_set_size(b, @max(1, frame.width), @max(1, frame.height));
            c.wlr_scene_node_set_position(&b.*.node, -self.border_width, -self.border_width);
        }
    }

    pub fn updateScene(self: *Window, now: i64) void {
        const tree = self.scene_tree orelse return;
        const cfg = &self.server.config;
        const vf = self.anim_frame.update(now);
        const bw = self.border_width;
        c.wlr_scene_node_set_position(&tree.node, vf.x + bw, vf.y + bw);
        self.updateEffects(vf);

        const target_opacity = self.effectiveOpacity(cfg);
        if (!self.anim_opacity.active and self.visible_target) self.anim_opacity.to = target_opacity;
        const op = self.anim_opacity.update(now);
        const radius: i32 = if (self.no_radius) 0 else cfg.effects.corner_radius;
        const apply_radius = !self.no_radius and radius > 0;
        if (@abs(op - self.last_opacity) > 0.001 or radius != self.last_radius) {
            if (self.content) |content| effects.applyToBuffers(content, op, radius, apply_radius);
            if (self.border) |b| {
                var col = if (self.focused) cfg.border_color_focused else cfg.border_color_unfocused;
                col[3] *= op;
                c.wlr_scene_rect_set_color(b, &col);
            }
            self.last_opacity = op;
            self.last_radius = radius;
        }

        if (!self.visible_target and !self.anim_opacity.active and op <= 0.001) {
            c.wlr_scene_node_set_enabled(&tree.node, false);
        }

        if (self.closing and !self.closing_sent and !self.anim_opacity.active) {
            self.sendClose();
        }
    }

    pub fn setFocused(self: *Window, focused: bool) void {
        if (self.focused == focused) return;
        self.focused = focused;
        if (self.border) |b| {
            const cfg = &self.server.config;
            c.wlr_scene_rect_set_color(b, if (focused) &cfg.border_color_focused else &cfg.border_color_unfocused);
        }
        const cfg = &self.server.config;
        const now = wl.nowNsec();
        const target = self.effectiveOpacity(cfg);
        if (cfg.animations.enabled and !self.no_animation) {
            self.anim_opacity.start(self.anim_opacity.value(now), target, now, cfg.animations.duration_ms, cfg.animations.easing);
        } else {
            self.anim_opacity.to = target;
            self.anim_opacity.active = false;
        }
        switch (self.kind) {
            .xdg => |_| {
                if (self.toplevel()) |tl| _ = c.wlr_xdg_toplevel_set_activated(tl, focused);
            },
            .x11 => |x| c.wlr_xwayland_surface_activate(x, focused),
        }
        self.scheduleFrame();
    }

    pub fn requestClose(self: *Window) void {
        if (self.closing) return;
        self.closing = true;
        const cfg = &self.server.config;
        const now = wl.nowNsec();
        if (cfg.animations.enabled and !self.no_animation and cfg.animations.fade) {
            self.anim_opacity.start(self.anim_opacity.value(now), 0, now, self.durationClose(), cfg.animations.easing);
            self.scheduleFrame();
        } else {
            self.sendClose();
        }
    }

    fn sendClose(self: *Window) void {
        if (self.closing_sent) return;
        self.closing_sent = true;
        // Animated close: hide immediately once faded out. The client is then
        // asked to close; the window object lives until its destroy event.
        switch (self.kind) {
            .xdg => |_| {
                if (self.toplevel()) |tl| c.wlr_xdg_toplevel_send_close(tl);
            },
            .x11 => |x| c.wlr_xwayland_surface_close(x),
        }
    }

    pub fn at(self: *Window, lx: f64, ly: f64) ?struct { surface: *c.struct_wlr_surface, sx: f64, sy: f64 } {
        if (!self.isVisible()) return null;
        const vf = self.anim_frame.value(wl.nowNsec());
        const frame = if (self.anim_frame.active) vf else self.frame;
        if (!frame.contains(lx, ly)) return null;
        const content_x = @as(f64, @floatFromInt(frame.x + self.border_width));
        const content_y = @as(f64, @floatFromInt(frame.y + self.border_width));
        switch (self.kind) {
            .xdg => |base| {
                var sx: f64 = 0;
                var sy: f64 = 0;
                const s = c.wlr_xdg_surface_surface_at(base, lx - content_x, ly - content_y, &sx, &sy);
                if (s == null) return null;
                return .{ .surface = @ptrCast(s), .sx = sx, .sy = sy };
            },
            .x11 => {
                const surf = self.wlSurface() orelse return null;
                if (!c.wlr_surface_point_accepts_input(surf, lx - content_x, ly - content_y)) return null;
                return .{ .surface = surf, .sx = lx - content_x, .sy = ly - content_y };
            },
        }
    }

    fn removeListeners(self: *Window) void {
        const L = &self.listeners;
        switch (self.kind) {
            .xdg => |base| {
                if (self.wlSurface()) |surf| {
                    wl.remove(&surf.events.commit, &L.commit);
                    wl.remove(&surf.events.map, &L.map);
                    wl.remove(&surf.events.unmap, &L.unmap);
                }
                if (self.toplevel()) |tl| {
                    wl.remove(&tl.events.destroy, &L.destroy);
                    wl.remove(&tl.events.request_move, &L.request_move);
                    wl.remove(&tl.events.request_resize, &L.request_resize);
                    wl.remove(&tl.events.request_maximize, &L.request_maximize);
                    wl.remove(&tl.events.request_fullscreen, &L.request_fullscreen);
                    wl.remove(&tl.events.request_minimize, &L.request_minimize);
                    wl.remove(&tl.events.set_title, &L.set_title);
                    wl.remove(&tl.events.set_app_id, &L.set_app_id);
                }
                wl.remove(&base.*.events.new_popup, &L.new_popup);
            },
            .x11 => |x| {
                if (x.surface) |surf| {
                    wl.remove(&surf.*.events.map, &L.map);
                    wl.remove(&surf.*.events.unmap, &L.unmap);
                }
                wl.remove(&x.events.associate, &L.associate);
                wl.remove(&x.events.dissociate, &L.dissociate);
                wl.remove(&x.events.request_configure, &L.request_configure);
                wl.remove(&x.events.destroy, &L.destroy);
                wl.remove(&x.events.set_title, &L.set_title);
                wl.remove(&x.events.set_class, &L.set_app_id);
                wl.remove(&x.events.request_move, &L.request_move);
                wl.remove(&x.events.request_resize, &L.request_resize);
                wl.remove(&x.events.request_maximize, &L.request_maximize);
                wl.remove(&x.events.request_fullscreen, &L.request_fullscreen);
                wl.remove(&x.events.request_minimize, &L.request_minimize);
                wl.remove(&x.events.request_activate, &L.request_activate);
                wl.remove(&x.events.set_parent, &L.set_parent);
            },
        }
    }

    pub fn destroy(self: *Window) void {
        if (self.destroyed) return;
        self.destroyed = true;
        self.removeListeners();
        self.server.removeWindowFromFocus(self);
        if (self.title_buf.len > 0) self.server.allocator.free(self.title_buf);
        if (self.app_id_buf.len > 0) self.server.allocator.free(self.app_id_buf);
        if (self.scratchpad_name) |n| self.server.allocator.free(n);
        for (self.server.windows.items, 0..) |w, i| {
            if (w == self) {
                _ = self.server.windows.swapRemove(i);
                break;
            }
        }
        if (self.scene_tree) |tree| c.wlr_scene_node_destroy(&tree.node);
        self.server.arrangeAll();
        self.server.allocator.destroy(self);
    }

    fn handleCommit(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const base = self.xdgBase() orelse return;
        if (base.initial_commit) {
            const cfg = &self.server.config;
            const caps = c.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN |
                c.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE |
                c.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE;
            _ = c.wlr_xdg_toplevel_set_wm_capabilities(base.unnamed_0.toplevel, caps);
            if (self.output) |o| {
                _ = c.wlr_xdg_toplevel_set_bounds(base.unnamed_0.toplevel, o.usable.width - 2 * cfg.gap, o.usable.height - 2 * cfg.gap);
            }
            _ = c.wlr_xdg_surface_schedule_configure(base);
            return;
        }
        if (base.geometry.width > 0 and base.geometry.height > 0) self.updateNaturalSize();
    }

    fn handleMap(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.ensureScene();
        self.mapped = true;
        self.closing = false;
        self.closing_sent = false;

        switch (self.kind) {
            .xdg => |base| {
                if (base.*.unnamed_0.toplevel) |tl| {
                    if (tl.*.app_id) |s| self.setAppId(std.mem.span(s));
                    if (tl.*.title) |s| self.setTitle(std.mem.span(s));
                }
            },
            .x11 => |x| {
                if (x.class) |s| self.setAppId(std.mem.span(s));
                if (x.title) |s| self.setTitle(std.mem.span(s));
            },
        }
        if (self.output == null) self.output = self.server.focusedOrFirstOutput();
        const out = self.output orelse return;
        self.tags = out.tags.active;
        self.applyRules();
        self.updateNaturalSize();

        if (self.floating or self.maximized or self.overlay) {
            if (self.float_geom.width <= 0) self.centerFloat(out.usable);
            self.frame = self.float_geom;
            self.geom = self.frame.inset(self.border_width);
        } else {
            self.frame = .{
                .x = out.usable.x + self.server.config.gap,
                .y = out.usable.y + self.server.config.gap,
                .width = @max(1, out.usable.width - self.server.config.gap * 2),
                .height = @max(1, out.usable.height - self.server.config.gap * 2),
            };
            self.geom = self.frame.inset(self.border_width);
        }
        self.pending_open = true;
        self.setVisible(true);
        if (!self.silent) self.server.focusWindow(self, out);
        self.server.arrangeAll();
        self.server.updateInputFocus();
    }

    fn handleUnmap(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.mapped = false;
        self.visible_target = false;
        if (self.scene_tree) |tree| c.wlr_scene_node_set_enabled(&tree.node, false);
        self.server.removeWindowFromFocus(self);
        self.server.arrangeAll();
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.destroy();
    }

    fn handleX11Destroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.destroy();
    }

    fn handleX11Associate(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const x = self.xwaylandSurface() orelse return;
        if (x.surface) |surf| self.installX11Surface(surf);
        if (x.title) |s| self.setTitle(std.mem.span(s));
        if (x.class) |s| self.setAppId(std.mem.span(s));
    }

    fn handleX11Dissociate(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        if (self.xwaylandSurface()) |x| {
            if (x.surface) |surf| {
                wl.remove(&surf.*.events.map, &self.listeners.map);
                wl.remove(&surf.*.events.unmap, &self.listeners.unmap);
            }
        }
        self.mapped = false;
        if (self.scene_tree) |tree| c.wlr_scene_node_set_enabled(&tree.node, false);
        self.server.removeWindowFromFocus(self);
        self.server.arrangeAll();
    }

    fn handleX11RequestConfigure(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const ev: *c.struct_wlr_xwayland_surface_configure_event = @ptrCast(@alignCast(data.?));
        const x = self.xwaylandSurface() orelse return;
        c.wlr_xwayland_surface_configure(x, ev.x, ev.y, ev.width, ev.height);
        if (self.floating) {
            self.float_geom = .{ .x = ev.x, .y = ev.y, .width = ev.width, .height = ev.height };
            self.applyGeometry(self.float_geom, true);
        }
    }

    fn handleRequestMove(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.server.input.beginMove(self);
    }

    fn handleRequestResize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const ev: *c.struct_wlr_xdg_toplevel_resize_event = @ptrCast(@alignCast(data.?));
        self.server.input.beginResize(self, ev.edges);
    }

    fn handleX11RequestResize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const ev: *c.struct_wlr_xwayland_resize_event = @ptrCast(@alignCast(data.?));
        self.server.input.beginResize(self, ev.edges);
    }

    fn handleRequestMaximize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.setMaximized(!self.maximized);
    }

    fn handleX11RequestMaximize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.setMaximized(!self.maximized);
    }

    pub fn setMaximized(self: *Window, value: bool) void {
        self.maximized = value;
        self.floating = true;
        self.server.arrangeAll();
    }

    fn handleRequestFullscreen(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.setFullscreen(!self.fullscreen);
    }

    fn handleX11RequestFullscreen(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.setFullscreen(!self.fullscreen);
    }

    pub fn setFullscreen(self: *Window, value: bool) void {
        self.fullscreen = value;
        self.server.arrangeAll();
        self.server.updateInputFocus();
    }

    fn handleRequestMinimize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.minimized = true;
        self.server.arrangeAll();
    }

    fn handleX11RequestMinimize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        self.minimized = true;
        self.server.arrangeAll();
    }

    fn handleRequestActivate(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        if (self.output) |o| self.server.focusWindow(self, o);
    }

    fn handleSetTitle(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        switch (self.kind) {
            .xdg => |_| {
                if (self.toplevel()) |tl| {
                    if (tl.title) |s| self.setTitle(std.mem.span(s));
                }
            },
            .x11 => |x| {
                if (x.title) |s| self.setTitle(std.mem.span(s));
            },
        }
    }

    fn handleSetAppId(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        switch (self.kind) {
            .xdg => |_| {
                if (self.toplevel()) |tl| {
                    if (tl.app_id) |s| self.setAppId(std.mem.span(s));
                }
            },
            .x11 => |x| {
                if (x.class) |s| self.setAppId(std.mem.span(s));
            },
        }
    }

    pub fn setTitleLoose(self: *Window, s: []const u8) void {
        self.setTitle(s);
    }

    pub fn setAppIdLoose(self: *Window, s: []const u8) void {
        self.setAppId(s);
    }

    fn setTitle(self: *Window, s: []const u8) void {
        const allocator = self.server.allocator;
        if (self.title_buf.len > 0) allocator.free(self.title_buf);
        self.title_buf = allocator.dupe(u8, s) catch &.{};
    }

    fn setAppId(self: *Window, s: []const u8) void {
        const allocator = self.server.allocator;
        if (self.app_id_buf.len > 0) allocator.free(self.app_id_buf);
        self.app_id_buf = allocator.dupe(u8, s) catch &.{};
    }

    fn handleNewPopup(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const popup: *c.struct_wlr_xdg_popup = @ptrCast(@alignCast(data.?));
        const parent = self.scene_tree orelse return;
        _ = c.wlr_scene_xdg_surface_create(parent, popup.base);
    }

    fn ignoreEvent(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = listener;
        _ = data;
    }
};
