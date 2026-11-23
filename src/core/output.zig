//! An output (monitor) and its per-output tag/layer state.

const std = @import("std");
const c = @import("../bindings.zig").c;
const geom = @import("../util/geometry.zig");
const log = @import("../util/log.zig");
const wl = @import("wl.zig");
const tags = @import("../tags/tags.zig");
const layout = @import("../layout/layout.zig");
const Server = @import("server.zig").Server;
const Window = @import("window.zig").Window;

const MAX_TILE_WINDOWS = 256;

pub const Output = struct {
    server: *Server,
    wlr_output: *c.struct_wlr_output,
    scene_output: *c.struct_wlr_scene_output,
    layout_output: *c.struct_wlr_output_layout_output,
    background: *c.struct_wlr_scene_rect,
    tags: tags.Manager,
    full: geom.Box = .{},
    usable: geom.Box = .{},
    focused_window: ?*Window = null,
    fullscreen_window: ?*Window = null,
    tiled: std.ArrayList(*Window),

    frame: wl.Listener,
    request_state: wl.Listener,
    destroy_listener: wl.Listener,
    wired: bool = false,

    pub fn create(server: *Server, wlr_output: *c.struct_wlr_output) !*Output {
        if (!c.wlr_output_init_render(wlr_output, server.allocator_wlr, server.renderer)) {
            return error.OutputRenderInitFailed;
        }

        const self = try server.allocator.create(Output);
        errdefer server.allocator.destroy(self);

        var box: c.struct_wlr_box = undefined;
        c.wlr_output_layout_get_box(server.output_layout, wlr_output, &box);
        var w: i32 = if (wlr_output.width > 0) wlr_output.width else 1280;
        var h: i32 = if (wlr_output.height > 0) wlr_output.height else 720;
        if (box.width > 0) w = box.width;
        if (box.height > 0) h = box.height;

        const scene_output = c.wlr_scene_output_create(server.scene, wlr_output) orelse return error.SceneOutputCreateFailed;
        const layout_output = c.wlr_output_layout_add_auto(server.output_layout, wlr_output);
        c.wlr_scene_output_layout_add_output(server.scene_layout, layout_output, scene_output);

        var state: c.struct_wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        c.wlr_output_state_set_enabled(&state, true);
        if (c.wlr_output_preferred_mode(wlr_output)) |mode| {
            c.wlr_output_state_set_mode(&state, mode);
        } else {
            c.wlr_output_state_set_custom_mode(&state, 1920, 1080, 60000);
        }
        if (c.wlr_output_test_state(wlr_output, &state)) {
            if (!c.wlr_output_commit_state(wlr_output, &state)) log.warn("initial output commit failed", .{});
        }
        c.wlr_output_state_finish(&state);

        var box2: c.struct_wlr_box = undefined;
        c.wlr_output_layout_get_box(server.output_layout, wlr_output, &box2);
        const color = server.config.background_color;
        const bg = c.wlr_scene_rect_create(server.background_tree, box2.width, box2.height, &color) orelse return error.SceneRectCreateFailed;
        c.wlr_scene_node_set_position(&bg.*.node, box2.x, box2.y);

        self.* = .{
            .server = server,
            .wlr_output = wlr_output,
            .scene_output = scene_output,
            .layout_output = layout_output,
            .background = bg,
            .tags = tags.Manager.initDefault(server.config.default_layout, server.config.master_count, server.config.master_factor, server.config.gap),
            .full = geom.Box.fromC(box2),
            .usable = geom.Box.fromC(box2),
            .tiled = std.ArrayList(*Window).empty,
            .frame = .{ .notify = handleFrame },
            .request_state = .{ .notify = handleRequestState },
            .destroy_listener = .{ .notify = handleDestroy },
        };
        self.tags.active = 1;
        wlr_output.data = self;

        self.frame.data = self;
        self.request_state.data = self;
        self.destroy_listener.data = self;
        wl.add(&wlr_output.events.frame, &self.frame);
        wl.add(&wlr_output.events.request_state, &self.request_state);
        wl.add(&wlr_output.events.destroy, &self.destroy_listener);
        self.wired = true;

        self.arrange();
        self.scheduleFrame();
        return self;
    }

    pub fn destroy(self: *Output) void {
        if (self.wired and self.wlr_output.data == @as(?*anyopaque, self)) {
            wl.remove(&self.wlr_output.events.frame, &self.frame);
            wl.remove(&self.wlr_output.events.request_state, &self.request_state);
            wl.remove(&self.wlr_output.events.destroy, &self.destroy_listener);
        }
        c.wlr_scene_output_destroy(self.scene_output);
        c.wlr_output_layout_remove(self.server.output_layout, self.wlr_output);
        self.tiled.deinit(self.server.allocator);
        self.server.allocator.destroy(self);
    }

    pub fn scheduleFrame(self: *Output) void {
        c.wlr_output_schedule_frame(self.wlr_output);
    }

    pub fn outputBox(self: *Output) void {
        var box: c.struct_wlr_box = undefined;
        c.wlr_output_layout_get_box(self.server.output_layout, self.wlr_output, &box);
        self.full = geom.Box.fromC(box);
        c.wlr_scene_rect_set_size(self.background, box.width, box.height);
        c.wlr_scene_node_set_position(&self.background.*.node, box.x, box.y);
    }

    pub fn viewTag(self: *Output, tag_index: u32) void {
        if (tag_index >= self.server.config.tag_count) return;
        self.tags.view(tag_index);
        self.server.arrangeAll();
        self.server.focusTopWindow();
    }

    pub fn toggleTag(self: *Output, tag_index: u32) void {
        if (tag_index >= self.server.config.tag_count) return;
        self.tags.toggle(tag_index);
        self.server.arrangeAll();
        self.server.focusTopWindow();
    }

    pub fn setLayout(self: *Output, kind: layout.Kind) void {
        self.tags.activeState().layout = kind;
        self.arrange();
        self.server.emitLayout();
    }

    pub fn activeLayout(self: *Output) layout.Kind {
        return self.tags.activeState().layout;
    }

    pub fn arrange(self: *Output) void {
        const now = wl.nowNsec();
        const cfg = &self.server.config;

        if (!self.wlr_output.enabled) return;
        if (self.full.width <= 0) self.outputBox();
        self.usable = self.server.layers.arrangeOutput(self);

        self.tiled.clearRetainingCapacity();
        var focused_in_tiled: usize = 0;
        self.fullscreen_window = null;

        // First pass: parent, visibility and special states.
        for (self.server.windows.items) |w| {
            if (w.output != self) continue;
            if (!w.isVisible()) {
                w.setVisible(false);
                continue;
            }
            w.setVisible(true);

            if (w.fullscreen and self.fullscreen_window == null) {
                self.fullscreen_window = w;
                w.parentTo(self.server.top_window_tree);
                w.applyGeometry(self.full, true);
                w.raise();
                continue;
            }

            if (w.overlay) {
                w.parentTo(self.server.top_window_tree);
                w.applyGeometry(if (w.floating) w.float_geom else w.geom, true);
                w.raise();
                continue;
            }

            if (w.floating or w.maximized) {
                w.parentTo(self.server.floating_tree);
                if (w.maximized) {
                    const area = self.usable.inset(@max(0, cfg.gap));
                    w.applyGeometry(area, true);
                } else {
                    if (w.float_geom.width <= 0 or w.float_geom.height <= 0) {
                        w.centerFloat(self.usable);
                    }
                    w.applyGeometry(w.float_geom, true);
                }
                if (w == self.server.focused_window) w.raise();
                continue;
            }

            w.parentTo(self.server.tiling_tree);
            if (w == self.server.focused_window) focused_in_tiled = self.tiled.items.len;
            self.tiled.append(self.server.allocator, w) catch continue;
        }

        // Second pass: tiled geometry using the active tag's layout state.
        const n = self.tiled.items.len;
        if (n > 0) {
            const state = self.tags.activeState();
            var boxes: [MAX_TILE_WINDOWS]geom.Box = undefined;
            const count = @min(n, MAX_TILE_WINDOWS);
            const params: layout.Params = .{
                .master_count = state.master_count,
                .master_factor = state.master_factor,
                .gap_inner = state.inner_gap,
                .gap_outer = state.gap,
                .focused = @min(focused_in_tiled, count - 1),
                .scroller_proportion = state.scroller_proportion,
                .scroll_offset = state.scroller_offset,
            };
            _ = layout.arrange(state.layout, self.usable, count, params, boxes[0..count]);
            for (0..count) |i| {
                self.tiled.items[i].applyGeometry(boxes[i], true);
            }
            // Monocle/deck need the focused window on top.
            if (state.layout == .monocle or state.layout == .deck) {
                if (focused_in_tiled < count) self.tiled.items[focused_in_tiled].raise();
            }
        }

        // Hide tiled windows beyond the fixed geometry budget instead of
        // drawing them with stale geometry.
        if (n > MAX_TILE_WINDOWS) {
            for (self.tiled.items[MAX_TILE_WINDOWS..]) |w| w.setVisible(false);
        }

        for (self.server.windows.items) |w| {
            if (w.output == self and w.isVisible()) w.updateScene(now);
        }
        self.scheduleFrame();
    }

    pub fn focusWindow(self: *Output, w: ?*Window) void {
        self.server.focusWindow(w, self);
    }

    pub fn centerCursor(self: *Output) void {
        const cx: f64 = @floatFromInt(self.full.x + @divTrunc(self.full.width, 2));
        const cy: f64 = @floatFromInt(self.full.y + @divTrunc(self.full.height, 2));
        _ = c.wlr_cursor_warp(self.server.cursor, null, cx, cy);
    }

    fn handleFrame(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Output = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const now = wl.nowNsec();
        self.server.tickAnimations(now);
        for (self.server.windows.items) |w| {
            if (w.output == self) w.updateScene(now);
        }

        if (c.wlr_scene_output_needs_frame(self.scene_output)) {
            _ = c.wlr_scene_output_commit(self.scene_output, null);
        }
        var now_ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now_ts);
        c.wlr_scene_output_send_frame_done(self.scene_output, &now_ts);
        if (self.server.hasActiveAnimations()) self.scheduleFrame();
    }

    fn handleRequestState(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_output_event_request_state = @ptrCast(@alignCast(data.?));
        if (!c.wlr_output_commit_state(self.wlr_output, event.state)) {
            log.warn("output {s}: requested state rejected", .{std.mem.span(self.wlr_output.name)});
        }
        self.outputBox();
        self.arrange();
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Output = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const server = self.server;
        for (server.outputs.items, 0..) |o, i| {
            if (o == self) {
                _ = server.outputs.swapRemove(i);
                break;
            }
        }
        for (server.windows.items) |w| {
            if (w.output == self) w.output = null;
        }
        if (server.focused_output == self) server.focused_output = null;
        self.destroy();
        if (server.outputs.items.len > 0) {
            server.focused_output = server.outputs.items[0];
            server.arrangeAll();
        }
    }
};
