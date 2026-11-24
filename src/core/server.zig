//! Kairo compositor server: owns the Wayland display, backend, renderer and
//! all global protocol state.

const std = @import("std");
const c = @import("../bindings.zig").c;
const log = @import("../util/log.zig");
const wl = @import("wl.zig");
const geom = @import("../util/geometry.zig");
const tags = @import("../tags/tags.zig");
const layout = @import("../layout/layout.zig");
const effects = @import("../effects/effects.zig");
const rules = @import("../window/rules.zig");
const Output = @import("output.zig").Output;
const idle_mod = @import("idle.zig");
const Window = @import("window.zig").Window;
const Config = @import("../config/config.zig").Config;
const loader = @import("../config/loader.zig");
const Input = @import("input.zig").Input;
const Layers = @import("layers.zig").Layers;
const XWayland = @import("xwayland.zig").XWayland;
const SessionLock = @import("session_lock.zig").SessionLock;
const ipc = @import("../ipc/server.zig");
const Scratchpad = @import("../scratchpad/scratchpad.zig").Manager;

pub const Server = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    event_loop: *c.struct_wl_event_loop,
    backend: *c.struct_wlr_backend,
    renderer: *c.struct_wlr_renderer,
    allocator_wlr: *c.struct_wlr_allocator,
    scene: *c.struct_wlr_scene,
    output_layout: *c.struct_wlr_output_layout,
    scene_layout: *c.struct_wlr_scene_output_layout,
    compositor: *c.struct_wlr_compositor,
    seat: *c.struct_wlr_seat,
    cursor: *c.struct_wlr_cursor,
    cursor_manager: *c.struct_wlr_xcursor_manager,
    xdg_shell: *c.struct_wlr_xdg_shell,
    layer_shell: *c.struct_wlr_layer_shell_v1,
    idle_notifier: ?*c.struct_wlr_idle_notifier_v1 = null,
    idle: ?*idle_mod.Idle = null,
    idle_inhibit: ?*idle_mod.InhibitTracker = null,
    output_manager: ?*c.struct_wlr_output_manager_v1 = null,
    config: Config,
    config_path: ?[]const u8 = null,
    input: *Input,
    layers: Layers,
    scratchpads: Scratchpad,
    xwayland: ?*XWayland = null,
    ipc: ?*ipc.Ipc = null,
    overview_active: bool = false,
    headless: bool = false,
    session_lock: ?*SessionLock = null,

    outputs: std.ArrayList(*Output),
    windows: std.ArrayList(*Window),
    focus_stack: std.ArrayList(*Window),
    focused_output: ?*Output = null,
    focused_window: ?*Window = null,
    next_window_id: u32 = 1,
    session_locked: bool = false,
    key_mode: []const u8 = "default",

    root_image: *c.struct_wlr_scene_tree,
    background_tree: *c.struct_wlr_scene_tree,
    bottom_tree: *c.struct_wlr_scene_tree,
    tiling_tree: *c.struct_wlr_scene_tree,
    floating_tree: *c.struct_wlr_scene_tree,
    top_window_tree: *c.struct_wlr_scene_tree,
    top_layer_tree: *c.struct_wlr_scene_tree,
    overlay_tree: *c.struct_wlr_scene_tree,
    lock_tree: *c.struct_wlr_scene_tree,

    new_output: wl.Listener,
    new_xdg_toplevel: wl.Listener,
    new_layer_surface: wl.Listener,
    request_set_cursor: wl.Listener,
    request_set_selection: wl.Listener,
    request_set_primary_selection: wl.Listener,
    new_input: wl.Listener,
    sig_sources: [4]?*c.struct_wl_event_source = .{ null, null, null, null },
    exit_after_timer: ?*c.struct_wl_event_source = null,

    pub fn init(allocator: std.mem.Allocator, config: Config, headless: bool) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .display = undefined,
            .event_loop = undefined,
            .backend = undefined,
            .renderer = undefined,
            .allocator_wlr = undefined,
            .scene = undefined,
            .output_layout = undefined,
            .scene_layout = undefined,
            .compositor = undefined,
            .seat = undefined,
            .cursor = undefined,
            .cursor_manager = undefined,
            .xdg_shell = undefined,
            .layer_shell = undefined,
            .config = config,
            .headless = headless,
            .input = undefined,
            .layers = undefined,
            .scratchpads = undefined,
            .outputs = std.ArrayList(*Output).empty,
            .windows = std.ArrayList(*Window).empty,
            .focus_stack = std.ArrayList(*Window).empty,
            .root_image = undefined,
            .background_tree = undefined,
            .bottom_tree = undefined,
            .tiling_tree = undefined,
            .floating_tree = undefined,
            .top_window_tree = undefined,
            .top_layer_tree = undefined,
            .overlay_tree = undefined,
            .lock_tree = undefined,
            .new_output = .{ .notify = handleNewOutput },
            .new_xdg_toplevel = .{ .notify = handleNewXdgToplevel },
            .new_layer_surface = .{ .notify = handleNewLayerSurface },
            .request_set_cursor = .{ .notify = handleRequestSetCursor },
            .request_set_selection = .{ .notify = handleRequestSetSelection },
            .request_set_primary_selection = .{ .notify = handleRequestSetPrimarySelection },
            .new_input = .{ .notify = handleNewInput },
        };
        self.new_output.data = self;
        self.new_xdg_toplevel.data = self;
        self.new_layer_surface.data = self;
        self.request_set_cursor.data = self;
        self.request_set_selection.data = self;
        self.request_set_primary_selection.data = self;
        self.new_input.data = self;

        if (headless) {
            _ = c.setenv("WLR_BACKENDS", "headless", 1);
            _ = c.setenv("WLR_HEADLESS_OUTPUTS", "1", 1);
            if (!@import("../bindings.zig").scenefx) {
                _ = c.setenv("WLR_RENDERER", "pixman", 1);
            }
        }

        self.display = c.wl_display_create() orelse return error.DisplayCreateFailed;
        errdefer c.wl_display_destroy(self.display);
        self.event_loop = c.wl_display_get_event_loop(self.display) orelse return error.EventLoopCreateFailed;

        const wlr_log_level: c.enum_wlr_log_importance = switch (log.level) {
            .debug => c.WLR_DEBUG,
            .info => c.WLR_INFO,
            .warn => c.WLR_ERROR,
            .err => c.WLR_ERROR,
        };
        _ = c.wlr_log_init(wlr_log_level, null);

        var session: ?*c.struct_wlr_session = null;
        self.backend = c.wlr_backend_autocreate(self.event_loop, &session) orelse return error.BackendCreateFailed;

        if (@import("../bindings.zig").scenefx) {
            self.renderer = c.fx_renderer_create(self.backend) orelse return error.RendererCreateFailed;
        } else {
            self.renderer = c.wlr_renderer_autocreate(self.backend) orelse return error.RendererCreateFailed;
        }

        self.allocator_wlr = c.wlr_allocator_autocreate(self.backend, self.renderer) orelse return error.AllocatorCreateFailed;

        if (!c.wlr_renderer_init_wl_shm(self.renderer, self.display)) return error.ShmInitFailed;

        self.scene = c.wlr_scene_create();
        self.root_image = &self.scene.tree;
        self.background_tree = @ptrCast(c.wlr_scene_tree_create(&self.scene.tree));
        self.bottom_tree = @ptrCast(c.wlr_scene_tree_create(&self.scene.tree));
        self.tiling_tree = @ptrCast(c.wlr_scene_tree_create(&self.scene.tree));
        self.floating_tree = @ptrCast(c.wlr_scene_tree_create(&self.scene.tree));
        self.top_window_tree = @ptrCast(c.wlr_scene_tree_create(&self.scene.tree));
        self.top_layer_tree = @ptrCast(c.wlr_scene_tree_create(&self.scene.tree));
        self.overlay_tree = @ptrCast(c.wlr_scene_tree_create(&self.scene.tree));
        // The lock tree is deliberately last: lock surfaces and their opaque
        // backdrop must cover every normal window and layer surface.
        self.lock_tree = @ptrCast(c.wlr_scene_tree_create(&self.scene.tree));

        self.session_lock = SessionLock.init(self, self.lock_tree) catch |err| blk: {
            log.err("session lock unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };

        effects.configureSceneBlur(
            self.scene,
            self.config.effects.blur_passes,
            self.config.effects.blur_radius,
            self.config.effects.blur_noise,
            self.config.effects.blur_brightness,
            self.config.effects.blur_contrast,
            self.config.effects.blur_saturation,
        );

        self.output_layout = c.wlr_output_layout_create(self.display);
        self.scene_layout = c.wlr_scene_attach_output_layout(self.scene, self.output_layout) orelse return error.SceneLayoutCreateFailed;

        self.compositor = c.wlr_compositor_create(self.display, 6, self.renderer) orelse return error.CompositorCreateFailed;
        _ = c.wlr_subcompositor_create(self.display);
        self.xdg_shell = c.wlr_xdg_shell_create(self.display, 6) orelse return error.XdgShellCreateFailed;
        self.layer_shell = c.wlr_layer_shell_v1_create(self.display, 4) orelse return error.LayerShellCreateFailed;
        _ = c.wlr_viewporter_create(self.display);
        _ = c.wlr_single_pixel_buffer_manager_v1_create(self.display);
        _ = c.wlr_fractional_scale_manager_v1_create(self.display, 1);
        _ = c.wlr_alpha_modifier_v1_create(self.display);
        _ = c.wlr_fixes_create(self.display, 1);
        _ = c.wlr_data_device_manager_create(self.display);
        _ = c.wlr_primary_selection_v1_device_manager_create(self.display);
        _ = c.wlr_data_control_manager_v1_create(self.display);
        _ = c.wlr_screencopy_manager_v1_create(self.display);
        _ = c.wlr_xdg_output_manager_v1_create(self.display, self.output_layout);
        _ = c.wlr_presentation_create(self.display, self.backend, 2);
        _ = c.wlr_pointer_constraints_v1_create(self.display);
        _ = c.wlr_relative_pointer_manager_v1_create(self.display);
        _ = c.wlr_pointer_gestures_v1_create(self.display);
        _ = c.wlr_cursor_shape_manager_v1_create(self.display, 1);
        _ = c.wlr_xdg_activation_v1_create(self.display);
        _ = c.wlr_xdg_decoration_manager_v1_create(self.display);
        _ = c.wlr_server_decoration_manager_create(self.display);
        _ = c.wlr_text_input_manager_v3_create(self.display);
        _ = c.wlr_input_method_manager_v2_create(self.display);
        self.idle_notifier = c.wlr_idle_notifier_v1_create(self.display);
        if (c.wlr_idle_inhibit_v1_create(self.display)) |manager| {
            self.idle_inhibit = idle_mod.InhibitTracker.create(self, manager) catch null;
        }
        _ = c.wlr_gamma_control_manager_v1_create(self.display);

        const dmabuf = c.wlr_linux_dmabuf_v1_create_with_renderer(self.display, 4, self.renderer);
        if (dmabuf != null) {
            _ = c.wlr_drm_create(self.display, self.renderer);
            c.wlr_scene_set_linux_dmabuf_v1(self.scene, dmabuf);
        }
        if (self.config.syncobj) {
            const fd = c.wlr_renderer_get_drm_fd(self.renderer);
            if (fd >= 0 and self.renderer.features.timeline and self.backend.features.timeline) {
                _ = c.wlr_linux_drm_syncobj_manager_v1_create(self.display, 1, fd);
            }
        }

        self.seat = c.wlr_seat_create(self.display, "seat0") orelse return error.SeatCreateFailed;
        if (headless) {
            // The headless backend has no physical input devices. Advertise the
            // seat capabilities so clients and integration tests can still
            // exercise keyboard focus and lock confinement.
            c.wlr_seat_set_capabilities(self.seat, c.WL_SEAT_CAPABILITY_POINTER | c.WL_SEAT_CAPABILITY_KEYBOARD);
        }
        self.cursor = c.wlr_cursor_create() orelse return error.CursorCreateFailed;
        c.wlr_cursor_attach_output_layout(self.cursor, self.output_layout);
        self.cursor_manager = c.wlr_xcursor_manager_create(null, self.config.cursor_size) orelse return error.XCursorCreateFailed;
        _ = c.wlr_xcursor_manager_load(self.cursor_manager, 1.0);
        c.wlr_cursor_set_xcursor(self.cursor, self.cursor_manager, "default");

        self.layers = Layers.init(self);
        self.scratchpads = Scratchpad.init(self);
        self.input = try Input.init(self);

        wl.add(&self.backend.events.new_output, &self.new_output);
        wl.add(&self.backend.events.new_input, &self.new_input);
        wl.add(&self.xdg_shell.events.new_toplevel, &self.new_xdg_toplevel);
        wl.add(&self.layer_shell.events.new_surface, &self.new_layer_surface);
        wl.add(&self.seat.events.request_set_cursor, &self.request_set_cursor);
        wl.add(&self.seat.events.request_set_selection, &self.request_set_selection);
        wl.add(&self.seat.events.request_set_primary_selection, &self.request_set_primary_selection);

        // Signals are handled through the Wayland event loop so they are
        // processed synchronously with compositor state.
        self.sig_sources[0] = c.wl_event_loop_add_signal(self.event_loop, c.SIGINT, handleSignal, self);
        self.sig_sources[1] = c.wl_event_loop_add_signal(self.event_loop, c.SIGTERM, handleSignal, self);
        self.sig_sources[2] = c.wl_event_loop_add_signal(self.event_loop, c.SIGUSR1, handleReloadSignal, self);

        self.xwayland = try XWayland.init(self);

        log.info("Kairo {s} initialised (wlroots 0.20, scenefx={})", .{ @import("build_options").version, @import("../bindings.zig").scenefx });
        return self;
    }

    pub fn run(self: *Server) void {
        c.wl_display_run(self.display);
    }

    pub fn terminate(self: *Server) void {
        c.wl_display_terminate(self.display);
    }

    pub fn deinit(self: *Server) void {
        if (self.exit_after_timer) |t| _ = c.wl_event_source_remove(t);
        for (self.sig_sources) |s| {
            if (s) |src| _ = c.wl_event_source_remove(src);
        }
        if (self.ipc) |i| {
            self.ipc = null;
            i.deinit();
        }
        self.input.deinit();
        self.allocator.destroy(self.input);
        wl.remove(&self.backend.events.new_output, &self.new_output);
        wl.remove(&self.backend.events.new_input, &self.new_input);
        wl.remove(&self.xdg_shell.events.new_toplevel, &self.new_xdg_toplevel);
        wl.remove(&self.layer_shell.events.new_surface, &self.new_layer_surface);
        wl.remove(&self.seat.events.request_set_cursor, &self.request_set_cursor);
        wl.remove(&self.seat.events.request_set_selection, &self.request_set_selection);
        wl.remove(&self.seat.events.request_set_primary_selection, &self.request_set_primary_selection);
        if (self.session_lock) |sl| {
            self.session_lock = null;
            sl.deinit();
        }
        while (self.windows.items.len > 0) self.windows.items[0].destroy();
        if (self.xwayland) |xw| xw.deinit();
        for (self.outputs.items) |o| o.destroy();
        self.layers.deinit();
        c.wl_display_destroy_clients(self.display);
        self.windows.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        self.focus_stack.deinit(self.allocator);
        if (self.config_path) |p| self.allocator.free(p);
        self.config.deinit(self.allocator);
        c.wl_display_destroy(self.display);
        self.allocator.destroy(self);
    }

    pub fn socketName(self: *Server) ![]const u8 {
        const name = c.wl_display_add_socket_auto(self.display) orelse return error.SocketCreateFailed;
        return std.mem.span(name);
    }

    pub fn start(self: *Server) !void {
        if (!c.wlr_backend_start(self.backend)) return error.BackendStartFailed;
        self.ipc = ipc.Ipc.init(self) catch |err| blk: {
            log.warn("IPC unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
        idle_mod.Idle.create(self);
    }

    pub fn emitWindow(self: *Server) void {
        if (self.ipc) |i| i.emit(.window);
    }

    pub fn emitTag(self: *Server) void {
        if (self.ipc) |i| i.emit(.tag);
    }

    pub fn emitOutput(self: *Server) void {
        if (self.ipc) |i| i.emit(.output);
    }

    pub fn emitLayout(self: *Server) void {
        if (self.ipc) |i| i.emit(.layout);
    }

    pub fn emitSession(self: *Server) void {
        if (self.ipc) |i| i.emit(.session);
    }

    pub fn setConfigPath(self: *Server, path: []const u8) void {
        if (self.config_path) |p| self.allocator.free(p);
        self.config_path = self.allocator.dupe(u8, path) catch null;
    }

    pub fn reloadConfig(self: *Server) void {
        const path = self.config_path orelse return;
        var new_cfg = loader.load(self.allocator, path) catch |err| {
            log.err("config reload failed: {s}", .{@errorName(err)});
            return;
        };
        if (new_cfg.diag_count > 0) {
            for (new_cfg.diags[0..new_cfg.diag_count]) |d| log.err("{s}:{d}: {s}", .{ d.file, d.line, d.message });
            new_cfg.deinit(self.allocator);
            log.err("configuration not reloaded ({d} error(s))", .{new_cfg.diag_count});
            return;
        }
        var old = self.config;
        self.config = new_cfg;
        old.deinit(self.allocator);
        self.input.reload();
        self.input.server = self;
        effects.configureSceneBlur(
            self.scene,
            self.config.effects.blur_passes,
            self.config.effects.blur_radius,
            self.config.effects.blur_noise,
            self.config.effects.blur_brightness,
            self.config.effects.blur_contrast,
            self.config.effects.blur_saturation,
        );
        for (self.outputs.items) |o| o.arrange();
        self.arrangeAll();
        for (self.config.autostart[0..self.config.autostart_count]) |a| {
            if (!a.once) self.spawn(a.command);
        }
        log.info("configuration reloaded", .{});
    }

    pub fn arrangeAll(self: *Server) void {
        if (self.overview_active) {
            self.arrangeOverview();
        } else {
            for (self.outputs.items) |o| o.arrange();
        }
        if (self.session_locked) {
            if (self.session_lock) |sl| sl.reposition();
        }
        self.emitWindow();
        self.emitOutput();
    }

    fn toggleOverview(self: *Server) void {
        self.overview_active = !self.overview_active;
        if (self.overview_active) {
            self.arrangeOverview();
        } else {
            self.arrangeAll();
        }
        self.emitWindow();
    }

    fn arrangeOverview(self: *Server) void {
        const out = self.focusedOrFirstOutput() orelse return;
        var list: [256]*Window = undefined;
        var n: usize = 0;
        for (self.windows.items) |w| {
            if (!w.mapped or w.closing) continue;
            if (w.tags & out.tags.active == 0) continue;
            if (n >= list.len) break;
            list[n] = w;
            n += 1;
        }
        if (n == 0) return;
        const cfg = &self.config;
        const area = out.usable.inset(@max(4, cfg.overview.gap));
        var boxes: [256]geom.Box = undefined;
        const params: layout.Params = .{
            .master_count = 1,
            .master_factor = 0.5,
            .gap_inner = cfg.overview.gap,
            .gap_outer = cfg.overview.gap,
        };
        _ = layout.arrange(.grid, area, n, params, boxes[0..n]);
        for (list[0..n], 0..) |w, i| {
            w.parentTo(self.top_window_tree);
            w.applyGeometry(boxes[i], true);
            w.setVisible(true);
            w.raise();
        }
        for (self.windows.items) |w| {
            var listed = false;
            for (list[0..n]) |item| {
                if (item == w) {
                    listed = true;
                    break;
                }
            }
            if (!listed) w.setVisible(false);
        }
        out.scheduleFrame();
    }

    pub fn tickAnimations(self: *Server, now: i64) void {
        for (self.windows.items) |w| w.updateScene(now);
        for (self.outputs.items) |o| o.scheduleFrame();
    }

    pub fn hasActiveAnimations(self: *Server) bool {
        for (self.windows.items) |w| {
            if (w.anim_frame.active or w.anim_opacity.active) return true;
        }
        return false;
    }

    pub fn findOutput(self: *Server, wlr_output: *c.struct_wlr_output) ?*Output {
        for (self.outputs.items) |o| {
            if (o.wlr_output == wlr_output) return o;
        }
        return null;
    }

    pub fn findOutputByWlr(self: *Server, wlr_output: *c.struct_wlr_output) ?*Output {
        for (self.outputs.items) |o| {
            if (o.wlr_output == wlr_output) return o;
        }
        return null;
    }

    pub fn findOutputByName(self: *Server, name: []const u8) ?*Output {
        for (self.outputs.items) |o| {
            if (o.wlr_output.name) |n| {
                if (std.mem.eql(u8, std.mem.span(n), name)) return o;
            }
        }
        return null;
    }

    pub fn focusedOrFirstOutput(self: *Server) ?*Output {
        if (self.focused_output) |o| return o;
        if (self.outputs.items.len > 0) return self.outputs.items[0];
        return null;
    }

    pub fn findWindow(self: *Server, id: u32) ?*Window {
        for (self.windows.items) |w| {
            if (w.id == id) return w;
        }
        return null;
    }

    pub fn focusWindow(self: *Server, window: ?*Window, output: ?*Output) void {
        if (self.session_locked) return;
        if (output) |o| self.focused_output = o;
        const w = window orelse {
            c.wlr_seat_keyboard_notify_clear_focus(self.seat);
            return;
        };
        if (!w.isVisible()) return;
        if (self.focused_window) |old| {
            if (old != w) old.setFocused(false);
        }
        self.focused_window = w;
        w.setFocused(true);
        if (w.output) |o| {
            o.focused_window = w;
            self.focused_output = o;
        }
        var i: usize = 0;
        while (i < self.focus_stack.items.len) : (i += 1) {
            if (self.focus_stack.items[i] == w) {
                _ = self.focus_stack.orderedRemove(i);
                break;
            }
        }
        self.focus_stack.insert(self.allocator, 0, w) catch {};
        if (w.floating or w.overlay or w.fullscreen) w.raise();
        if (self.config.warp_cursor) {
            const cx: f64 = @floatFromInt(w.frame.x + @divTrunc(w.frame.width, 2));
            const cy: f64 = @floatFromInt(w.frame.y + @divTrunc(w.frame.height, 2));
            _ = c.wlr_cursor_warp(self.cursor, null, cx, cy);
        }
        self.updateInputFocus();
        self.notifyActivity();
        if (self.overview_active) {
            self.overview_active = false;
            self.arrangeAll();
        }
        self.emitWindow();
    }

    pub fn removeWindowFromFocus(self: *Server, w: *Window) void {
        var i: usize = 0;
        while (i < self.focus_stack.items.len) : (i += 1) {
            if (self.focus_stack.items[i] == w) {
                _ = self.focus_stack.orderedRemove(i);
                break;
            }
        }
        if (self.focused_window == w) {
            self.focused_window = null;
            w.setFocused(false);
            self.focusTopWindow();
        }
    }

    pub fn focusTopWindow(self: *Server) void {
        if (self.focused_window) |w| {
            if (w.isVisible()) {
                self.updateInputFocus();
                return;
            }
        }
        for (self.focus_stack.items) |w| {
            if (w.isVisible()) {
                self.focusWindow(w, w.output);
                return;
            }
        }
        var i = self.windows.items.len;
        while (i > 0) {
            i -= 1;
            const w = self.windows.items[i];
            if (w.isVisible()) {
                self.focusWindow(w, w.output);
                return;
            }
        }
        self.focused_window = null;
        c.wlr_seat_keyboard_notify_clear_focus(self.seat);
    }

    pub fn updateInputFocus(self: *Server) void {
        if (self.session_locked) {
            if (self.session_lock) |sl| {
                sl.updateKeyboardFocus();
            } else {
                c.wlr_seat_keyboard_notify_clear_focus(self.seat);
            }
            return;
        }
        const w = self.focused_window orelse {
            c.wlr_seat_keyboard_notify_clear_focus(self.seat);
            return;
        };
        const surf = w.wlSurface() orelse return;
        var keycodes: [0]u32 = .{};
        c.wlr_seat_keyboard_notify_enter(self.seat, surf, &keycodes, 0, &self.input.group.keyboard.modifiers);
    }

    pub fn notifyActivity(self: *Server) void {
        if (self.idle_notifier) |notifier| {
            c.wlr_idle_notifier_v1_notify_activity(notifier, self.seat);
        }
        if (self.idle) |idle| idle.notifyActivity();
    }

    fn updatePointerFocus(self: *Server) void {
        self.input.updatePointerFocus(wl.nowMsec());
    }

    pub fn spawn(self: *Server, command: []const u8) void {
        if (command.len == 0) return;
        const cmd_z = self.allocator.dupeZ(u8, command) catch return;
        defer self.allocator.free(cmd_z);
        const pid = std.posix.fork() catch |err| {
            log.err("fork failed: {s}", .{@errorName(err)});
            return;
        };
        if (pid == 0) {
            _ = std.posix.setsid() catch {};
            const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch -1;
            if (devnull >= 0) {
                std.posix.dup2(devnull, 0) catch {};
                std.posix.dup2(devnull, 1) catch {};
                std.posix.dup2(devnull, 2) catch {};
                if (devnull > 2) std.posix.close(devnull);
            }
            var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr };
            std.posix.execveZ("/bin/sh", &argv, @ptrCast(std.c.environ)) catch std.process.exit(127);
        }
        log.info("spawned: {s} (pid {d})", .{ command, pid });
    }

    fn tagIndex(args: []const u8) ?u32 {
        const trimmed = std.mem.trim(u8, args, " \t");
        if (trimmed.len == 0) return null;
        const n = std.fmt.parseInt(u32, trimmed, 10) catch return null;
        if (n < 1 or n > tags.MAX_TAGS) return null;
        return n - 1;
    }

    pub fn dispatch(self: *Server, command: @import("../config/config.zig").Command, args: []const u8) void {
        const cfg_cmd = @import("../config/config.zig").Command;
        const focused = self.focused_window;
        switch (command) {
            .none => {},
            .spawn, .spawn_shell => self.spawn(args),
            .quit => self.terminate(),
            .reload => self.reloadConfig(),
            .killclient => {
                if (focused) |w| w.requestClose();
            },
            .force_kill => {
                if (focused) |w| {
                    if (w.xwaylandSurface()) |x| {
                        if (x.pid > 0) std.posix.kill(@intCast(x.pid), std.posix.SIG.KILL) catch {};
                    } else w.requestClose();
                }
            },
            .toggle_floating => {
                if (focused) |w| {
                    w.floating = !w.floating;
                    if (w.floating) {
                        if (w.output) |o| w.centerFloat(o.usable);
                        w.float_geom = w.frame;
                    }
                    self.arrangeAll();
                }
            },
            .toggle_all_floating => {
                for (self.windows.items) |w| {
                    if (!w.isVisible()) continue;
                    w.floating = !w.floating;
                    if (w.floating) w.float_geom = w.frame;
                }
                self.arrangeAll();
            },
            .toggle_fullscreen => {
                if (focused) |w| w.setFullscreen(!w.fullscreen);
            },
            .toggle_fake_fullscreen => {
                if (focused) |w| {
                    w.fake_fullscreen = !w.fake_fullscreen;
                    w.floating = w.fake_fullscreen;
                    if (w.fake_fullscreen) {
                        if (w.output) |o| w.float_geom = o.usable;
                    }
                    self.arrangeAll();
                }
            },
            .toggle_maximized => {
                if (focused) |w| w.setMaximized(!w.maximized);
            },
            .toggle_minimized => {
                if (focused) |w| {
                    w.minimized = !w.minimized;
                    if (w.minimized) self.focusTopWindow();
                    self.arrangeAll();
                }
            },
            .restore_minimized => {
                for (self.windows.items) |w| {
                    if (w.minimized) {
                        w.minimized = false;
                        if (w.output) |o| self.focusWindow(w, o);
                        break;
                    }
                }
                self.arrangeAll();
            },
            .toggle_global => {
                if (focused) |w| {
                    w.global = !w.global;
                    self.arrangeAll();
                }
            },
            .toggle_overlay => {
                if (focused) |w| {
                    w.overlay = !w.overlay;
                    if (w.overlay) w.floating = true;
                    self.arrangeAll();
                }
            },
            .center_window => {
                if (focused) |w| {
                    if (w.output) |o| {
                        w.centerFloat(o.usable);
                        w.applyGeometry(w.float_geom, true);
                    }
                }
            },
            .focus_next => self.focusCycle(true),
            .focus_prev => self.focusCycle(false),
            .focus_left => self.focusDirection(-1, 0),
            .focus_right => self.focusDirection(1, 0),
            .focus_up => self.focusDirection(0, -1),
            .focus_down => self.focusDirection(0, 1),
            .move_next => self.moveInOrder(focused, true),
            .move_prev => self.moveInOrder(focused, false),
            .swap_next => self.moveInOrder(focused, true),
            .swap_prev => self.moveInOrder(focused, false),
            .swap_master => self.zoom(),
            .view_tag => {
                const trimmed = std.mem.trim(u8, args, " \t");
                if (std.mem.eql(u8, trimmed, "next")) {
                    self.viewRelativeTag(1);
                } else if (std.mem.eql(u8, trimmed, "prev")) {
                    self.viewRelativeTag(-1);
                } else if (std.mem.eql(u8, trimmed, "last")) {
                    if (self.focusedOrFirstOutput()) |o| o.tags.viewLast();
                    self.arrangeAll();
                    self.focusTopWindow();
                } else if (tagIndex(trimmed)) |idx| {
                    if (self.focusedOrFirstOutput()) |o| o.viewTag(idx);
                }
            },
            .toggle_tag => {
                if (tagIndex(args)) |idx| {
                    if (self.focusedOrFirstOutput()) |o| o.toggleTag(idx);
                }
            },
            .tag_window => {
                if (focused) |w| {
                    if (tagIndex(args)) |idx| {
                        w.tags = tags.Manager.maskOf(idx);
                        self.arrangeAll();
                        self.focusTopWindow();
                    }
                }
            },
            .toggle_tag_window => {
                if (focused) |w| {
                    if (tagIndex(args)) |idx| {
                        w.tags ^= tags.Manager.maskOf(idx);
                        if (w.tags == 0) w.tags = tags.Manager.maskOf(idx);
                        self.arrangeAll();
                        self.focusTopWindow();
                    }
                }
            },
            .view_next_tag => self.viewRelativeTag(1),
            .view_prev_tag => self.viewRelativeTag(-1),
            .set_layout => {
                const kind = layout.Kind.fromName(std.mem.trim(u8, args, " \t")) orelse return;
                if (self.focusedOrFirstOutput()) |o| o.setLayout(kind);
            },
            .cycle_layout => {
                const trimmed = std.mem.trim(u8, args, " \t");
                const forward = !std.mem.eql(u8, trimmed, "prev");
                if (self.focusedOrFirstOutput()) |o| {
                    o.tags.cycleLayout(forward);
                    o.arrange();
                }
            },
            .set_master_count => {
                if (self.focusedOrFirstOutput()) |o| {
                    const delta = parseDelta(args);
                    const st = o.tags.activeState();
                    var n: i32 = @intCast(st.master_count);
                    if (delta != 0) {
                        n += delta;
                    } else if (std.fmt.parseInt(i32, std.mem.trim(u8, args, " \t"), 10)) |v| {
                        n = v;
                    } else |_| {}
                    st.master_count = @intCast(std.math.clamp(n, 0, 16));
                    o.arrange();
                }
            },
            .set_master_factor => {
                if (self.focusedOrFirstOutput()) |o| {
                    const trimmed = std.mem.trim(u8, args, " \t");
                    const st = o.tags.activeState();
                    var f = st.master_factor;
                    if (std.fmt.parseFloat(f32, trimmed)) |v| {
                        f = if (@abs(v) <= 1.0 and trimmed.len > 0 and (trimmed[0] == '+' or trimmed[0] == '-')) f + v else v;
                    } else |_| {}
                    st.master_factor = std.math.clamp(f, 0.1, 0.9);
                    o.arrange();
                }
            },
            .zoom => self.zoom(),
            .focus_monitor => self.focusMonitor(args),
            .move_to_monitor => self.moveWindowToMonitor(args),
            .toggle_scratchpad => self.scratchpads.toggle(),
            .toggle_named_scratchpad => self.scratchpads.toggleNamed(std.mem.trim(u8, args, " \t")),
            .show_overview => self.toggleOverview(),
            .toggle_switcher, .switcher_next => self.focusCycle(true),
            .switcher_prev => self.focusCycle(false),
            .switcher_commit => {},
            .mouse_move => {
                if (focused) |w| self.input.beginMove(w);
            },
            .mouse_resize => {
                if (focused) |w| self.input.beginResize(w, c.WLR_EDGE_BOTTOM | c.WLR_EDGE_RIGHT);
            },
            .set_key_mode => self.input.setMode(std.mem.trim(u8, args, " \t")),
            .toggle_session_lock => {
                if (self.session_locked) {
                    log.info("session is already locked; unlock through the lock client", .{});
                } else if (self.session_lock == null) {
                    log.warn("toggle_session_lock: ext-session-lock-v1 is unavailable", .{});
                } else if (self.config.lock_command.len == 0) {
                    log.warn("toggle_session_lock: no lock_command configured", .{});
                } else {
                    self.spawn(self.config.lock_command);
                }
            },
            else => {},
        }
        _ = cfg_cmd;
    }

    fn parseDelta(args: []const u8) i32 {
        const t = std.mem.trim(u8, args, " \t");
        if (t.len == 0) return 0;
        if (t[0] == '+' or t[0] == '-') {
            return std.fmt.parseInt(i32, t, 10) catch 0;
        }
        return 0;
    }

    fn focusCycle(self: *Server, forward: bool) void {
        const out = self.focusedOrFirstOutput() orelse return;
        const cur = self.focused_window;
        var start_idx: usize = 0;
        if (cur) |w| {
            for (self.focus_stack.items, 0..) |item, i| {
                if (item == w) {
                    start_idx = i;
                    break;
                }
            }
        }
        const len = self.focus_stack.items.len;
        if (len == 0) return;
        var step: usize = 1;
        while (step <= len) : (step += 1) {
            const idx = if (forward)
                (start_idx + step) % len
            else
                (start_idx + len - (step % len)) % len;
            const w = self.focus_stack.items[idx];
            if (w.isVisible() and w.output == out) {
                self.focusWindow(w, out);
                return;
            }
        }
    }

    fn focusDirection(self: *Server, dx: i32, dy: i32) void {
        const cur = self.focused_window orelse return;
        const out = cur.output orelse return;
        const cx = cur.frame.centerX();
        const cy = cur.frame.centerY();
        var best: ?*Window = null;
        var best_score: i64 = std.math.maxInt(i64);
        for (self.windows.items) |w| {
            if (w == cur or w.output != out or !w.isVisible()) continue;
            const wx = w.frame.centerX();
            const wy = w.frame.centerY();
            const vx = wx - cx;
            const vy = wy - cy;
            if (dx != 0 and (vx * dx) <= 0) continue;
            if (dy != 0 and (vy * dy) <= 0) continue;
            const score: i64 = @as(i64, vx) * vx + @as(i64, vy) * vy;
            if (score < best_score) {
                best_score = score;
                best = w;
            }
        }
        if (best) |w| self.focusWindow(w, out);
    }

    fn moveInOrder(self: *Server, window: ?*Window, forward: bool) void {
        const w = window orelse return;
        var idx: usize = 0;
        var found = false;
        for (self.windows.items, 0..) |item, i| {
            if (item == w) {
                idx = i;
                found = true;
                break;
            }
        }
        if (!found) return;
        var step: usize = 1;
        while (step <= self.windows.items.len) : (step += 1) {
            const j = if (forward)
                (idx + step) % self.windows.items.len
            else
                (idx + self.windows.items.len - (step % self.windows.items.len)) % self.windows.items.len;
            const other = self.windows.items[j];
            if (other == w) continue;
            if (other.output == w.output and other.isVisible() and !other.floating and !other.fullscreen) {
                const tmp = self.windows.items[idx];
                self.windows.items[idx] = self.windows.items[j];
                self.windows.items[j] = tmp;
                self.arrangeAll();
                return;
            }
        }
    }

    fn zoom(self: *Server) void {
        const w = self.focused_window orelse return;
        if (w.floating or w.fullscreen) return;
        for (self.windows.items, 0..) |item, i| {
            if (item == w) {
                // Move the window to the first tiled slot on this output.
                if (i > 0) {
                    const prev = self.windows.items[0];
                    self.windows.items[0] = w;
                    self.windows.items[i] = prev;
                }
                self.arrangeAll();
                return;
            }
        }
    }

    fn viewRelativeTag(self: *Server, delta: i32) void {
        const out = self.focusedOrFirstOutput() orelse return;
        const count = @max(1, self.config.tag_count);
        var idx: u32 = 0;
        var i: u32 = 0;
        while (i < tags.MAX_TAGS) : (i += 1) {
            if ((out.tags.active & (tags.Manager.maskOf(i))) != 0) {
                idx = i;
                break;
            }
        }
        if (delta > 0) {
            idx = (idx + 1) % count;
        } else {
            idx = (idx + count - 1) % count;
        }
        out.viewTag(idx);
    }

    fn focusMonitor(self: *Server, args: []const u8) void {
        if (self.outputs.items.len == 0) return;
        const trimmed = std.mem.trim(u8, args, " \t");
        var target: ?*Output = null;
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "next")) {
            const cur = self.focusedOrFirstOutput() orelse return;
            for (self.outputs.items, 0..) |o, i| {
                if (o == cur) {
                    target = self.outputs.items[(i + 1) % self.outputs.items.len];
                    break;
                }
            }
        } else if (std.mem.eql(u8, trimmed, "prev")) {
            const cur = self.focusedOrFirstOutput() orelse return;
            for (self.outputs.items, 0..) |o, i| {
                if (o == cur) {
                    target = self.outputs.items[(i + self.outputs.items.len - 1) % self.outputs.items.len];
                    break;
                }
            }
        } else {
            target = self.findOutputByName(trimmed);
        }
        const o = target orelse return;
        self.focused_output = o;
        o.centerCursor();
        if (o.focused_window) |w| {
            self.focusWindow(w, o);
        } else {
            self.focusTopWindow();
        }
        self.updatePointerFocus();
    }

    fn moveWindowToMonitor(self: *Server, args: []const u8) void {
        const w = self.focused_window orelse return;
        if (self.outputs.items.len == 0) return;
        const trimmed = std.mem.trim(u8, args, " \t");
        var target: ?*Output = null;
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "next")) {
            const cur = w.output orelse self.focusedOrFirstOutput() orelse return;
            for (self.outputs.items, 0..) |o, i| {
                if (o == cur) {
                    target = self.outputs.items[(i + 1) % self.outputs.items.len];
                    break;
                }
            }
        } else {
            target = self.findOutputByName(trimmed);
        }
        const o = target orelse return;
        w.output = o;
        w.tags = o.tags.active;
        if (w.floating) w.centerFloat(o.usable);
        self.focused_output = o;
        self.arrangeAll();
        self.focusWindow(w, o);
    }

    fn handleNewOutput(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const out = Output.create(self, @ptrCast(@alignCast(data.?))) catch |err| {
            log.err("failed to create output: {s}", .{@errorName(err)});
            return;
        };
        self.outputs.append(self.allocator, out) catch {
            out.destroy();
            return;
        };
        _ = c.wlr_xcursor_manager_load(self.cursor_manager, out.wlr_output.scale);
        if (self.focused_output == null) self.focused_output = out;
        log.info("output {s} added ({d}x{d})", .{ std.mem.span(out.wlr_output.name), out.wlr_output.width, out.wlr_output.height });
        if (self.session_lock) |sl| sl.refreshOutputs();
        self.arrangeAll();
    }

    fn handleNewXdgToplevel(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const toplevel: *c.struct_wlr_xdg_toplevel = @ptrCast(@alignCast(data.?));
        _ = Window.createXdg(self, toplevel) catch |err| {
            log.err("failed to create window: {s}", .{@errorName(err)});
            c.wlr_xdg_toplevel_send_close(toplevel);
        };
    }

    fn handleNewLayerSurface(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const surface: *c.struct_wlr_layer_surface_v1 = @ptrCast(@alignCast(data.?));
        self.layers.add(surface) catch |err| {
            log.err("failed to create layer surface: {s}", .{@errorName(err)});
            c.wlr_layer_surface_v1_destroy(surface);
        };
    }

    fn handleNewInput(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const device: *c.struct_wlr_input_device = @ptrCast(@alignCast(data.?));
        self.input.addDevice(device) catch |err| log.err("input device: {s}", .{@errorName(err)});
    }

    fn handleRequestSetCursor(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_seat_pointer_request_set_cursor_event = @ptrCast(@alignCast(data.?));
        if (self.seat.pointer_state.focused_client == event.seat_client) {
            c.wlr_cursor_set_surface(self.cursor, event.surface, event.hotspot_x, event.hotspot_y);
        }
    }

    fn handleRequestSetSelection(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_seat_request_set_selection_event = @ptrCast(@alignCast(data.?));
        c.wlr_seat_set_selection(self.seat, event.source, event.serial);
    }

    fn handleRequestSetPrimarySelection(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_seat_request_set_primary_selection_event = @ptrCast(@alignCast(data.?));
        c.wlr_seat_set_primary_selection(self.seat, event.source, event.serial);
    }

    fn handleSignal(signal: c_int, data: ?*anyopaque) callconv(.c) c_int {
        _ = signal;
        const self: *Server = @ptrCast(@alignCast(data.?));
        self.terminate();
        return 0;
    }

    fn handleReloadSignal(signal: c_int, data: ?*anyopaque) callconv(.c) c_int {
        _ = signal;
        const self: *Server = @ptrCast(@alignCast(data.?));
        self.reloadConfig();
        return 0;
    }
};
