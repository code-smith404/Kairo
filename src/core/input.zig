//! Input: cursor, keyboard group, bindings and interactive move/resize.

const std = @import("std");
const c = @import("../bindings.zig").c;
const log = @import("../util/log.zig");
const wl = @import("wl.zig");
const geom = @import("../util/geometry.zig");
const config = @import("../config/config.zig");
const Server = @import("server.zig").Server;
const Window = @import("window.zig").Window;
const Output = @import("output.zig").Output;

const MOD_MASK: u32 = c.WLR_MODIFIER_SHIFT | c.WLR_MODIFIER_CTRL | c.WLR_MODIFIER_ALT | c.WLR_MODIFIER_LOGO;

pub const InteractiveMode = enum { move, resize };

pub const Interactive = struct {
    window: *Window,
    mode: InteractiveMode,
    start_x: f64,
    start_y: f64,
    start_frame: geom.Box,
    edges: u32,
    moved: bool,
};

pub const Input = struct {
    server: *Server,
    group: *c.struct_wlr_keyboard_group,
    cursor_motion: wl.Listener,
    cursor_motion_abs: wl.Listener,
    cursor_button: wl.Listener,
    cursor_axis: wl.Listener,
    cursor_frame: wl.Listener,
    key: wl.Listener,
    modifiers: wl.Listener,
    repeat_timer: ?*c.struct_wl_event_source = null,
    repeat_key: u32 = 0,
    repeat_code: i32 = -1,
    repeat_active: bool = false,

    xkb_context: ?*c.struct_xkb_context = null,
    xkb_ctx_owned: bool = false,
    xkb_layout: ?[:0]u8 = null,
    xkb_variant: ?[:0]u8 = null,
    xkb_options: ?[:0]u8 = null,
    xkb_rules: ?[:0]u8 = null,
    xkb_model: ?[:0]u8 = null,

    binding_syms: [config.MAX_BINDINGS]u32 = [_]u32{0} ** config.MAX_BINDINGS,
    binding_valid: [config.MAX_BINDINGS]bool = [_]bool{false} ** config.MAX_BINDINGS,

    interactive: ?Interactive = null,

    last_pointer_surface: ?*c.struct_wlr_surface = null,
    last_pointer_window: ?*Window = null,
    last_hit_x: f64 = 0,
    last_hit_y: f64 = 0,

    pub fn init(server: *Server) !*Input {
        const self = try server.allocator.create(Input);
        errdefer server.allocator.destroy(self);
        self.* = Input{
            .server = server,
            .group = undefined,
            .cursor_motion = .{ .notify = handleCursorMotion },
            .cursor_motion_abs = .{ .notify = handleCursorMotionAbsolute },
            .cursor_button = .{ .notify = handleCursorButton },
            .cursor_axis = .{ .notify = handleCursorAxis },
            .cursor_frame = .{ .notify = handleCursorFrame },
            .key = .{ .notify = handleKey },
            .modifiers = .{ .notify = handleModifiers },
        };
        self.cursor_motion.data = self;
        self.cursor_motion_abs.data = self;
        self.cursor_button.data = self;
        self.cursor_axis.data = self;
        self.cursor_frame.data = self;
        self.key.data = self;
        self.modifiers.data = self;

        wl.add(&server.cursor.*.events.motion, &self.cursor_motion);
        wl.add(&server.cursor.*.events.motion_absolute, &self.cursor_motion_abs);
        wl.add(&server.cursor.*.events.button, &self.cursor_button);
        wl.add(&server.cursor.*.events.axis, &self.cursor_axis);
        wl.add(&server.cursor.*.events.frame, &self.cursor_frame);

        self.group = blk: {
            const g = c.wlr_keyboard_group_create();
            break :blk if (g == null) @panic("failed to create keyboard group") else @ptrCast(g);
        };
        wl.add(&self.group.keyboard.events.key, &self.key);
        wl.add(&self.group.keyboard.events.modifiers, &self.modifiers);

        self.loadKeymap();
        c.wlr_keyboard_set_repeat_info(&self.group.keyboard, server.config.input.repeat_rate, server.config.input.repeat_delay);
        c.wlr_seat_set_keyboard(server.seat, &self.group.keyboard);
        self.repeat_timer = c.wl_event_loop_add_timer(server.event_loop, handleRepeat, self);
        self.resolveBindings();
        return self;
    }

    pub fn deinit(self: *Input) void {
        if (self.repeat_timer) |t| _ = c.wl_event_source_remove(t);
        const cursor = self.server.cursor;
        wl.remove(&cursor.*.events.motion, &self.cursor_motion);
        wl.remove(&cursor.*.events.motion_absolute, &self.cursor_motion_abs);
        wl.remove(&cursor.*.events.button, &self.cursor_button);
        wl.remove(&cursor.*.events.axis, &self.cursor_axis);
        wl.remove(&cursor.*.events.frame, &self.cursor_frame);
        wl.remove(&self.group.keyboard.events.key, &self.key);
        wl.remove(&self.group.keyboard.events.modifiers, &self.modifiers);
        c.wlr_keyboard_group_destroy(self.group);
        if (self.xkb_ctx_owned) {
            if (self.xkb_context) |ctx| c.xkb_context_unref(ctx);
        }
        const a = self.server.allocator;
        if (self.xkb_layout) |v| a.free(v);
        if (self.xkb_variant) |v| a.free(v);
        if (self.xkb_options) |v| a.free(v);
        if (self.xkb_rules) |v| a.free(v);
        if (self.xkb_model) |v| a.free(v);
    }

    fn loadKeymap(self: *Input) void {
        const a = self.server.allocator;
        const cfg = &self.server.config.input;
        if (self.xkb_layout) |v| a.free(v);
        if (self.xkb_variant) |v| a.free(v);
        if (self.xkb_options) |v| a.free(v);
        if (self.xkb_rules) |v| a.free(v);
        if (self.xkb_model) |v| a.free(v);
        self.xkb_layout = a.dupeZ(u8, cfg.xkb_layout) catch null;
        self.xkb_variant = a.dupeZ(u8, cfg.xkb_variant) catch null;
        self.xkb_options = a.dupeZ(u8, cfg.xkb_options) catch null;
        self.xkb_rules = a.dupeZ(u8, cfg.xkb_rules) catch null;
        self.xkb_model = a.dupeZ(u8, cfg.xkb_model) catch null;

        if (self.xkb_context == null) {
            self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
            self.xkb_ctx_owned = true;
        }
        const ctx = self.xkb_context orelse return;
        var names = c.struct_xkb_rule_names{
            .rules = if (self.xkb_rules) |v| v.ptr else null,
            .model = if (self.xkb_model) |v| v.ptr else null,
            .layout = if (self.xkb_layout) |v| v.ptr else null,
            .variant = if (self.xkb_variant) |v| v.ptr else null,
            .options = if (self.xkb_options) |v| v.ptr else null,
        };
        const keymap = c.xkb_keymap_new_from_names(ctx, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
            log.err("failed to compile keymap (layout '{s}')", .{cfg.xkb_layout});
            return;
        };
        defer c.xkb_keymap_unref(keymap);
        if (!c.wlr_keyboard_set_keymap(&self.group.keyboard, keymap)) {
            log.err("wlr_keyboard_set_keymap failed", .{});
        }
    }

    pub fn reload(self: *Input) void {
        self.loadKeymap();
        c.wlr_keyboard_set_repeat_info(&self.group.keyboard, self.server.config.input.repeat_rate, self.server.config.input.repeat_delay);
        self.resolveBindings();
    }

    fn resolveBindings(self: *Input) void {
        const cfg = &self.server.config;
        var buf: [128]u8 = undefined;
        for (cfg.bindings[0..cfg.binding_count], 0..) |*b, i| {
            switch (b.key) {
                .sym => |name| {
                    if (name.len == 0 or name.len >= buf.len) {
                        self.binding_valid[i] = false;
                        continue;
                    }
                    @memcpy(buf[0..name.len], name);
                    buf[name.len] = 0;
                    const z: [*:0]const u8 = @ptrCast(&buf);
                    const sym = c.xkb_keysym_from_name(z, c.XKB_KEYSYM_CASE_INSENSITIVE);
                    self.binding_syms[i] = sym;
                    self.binding_valid[i] = sym != c.XKB_KEY_NoSymbol;
                    if (!self.binding_valid[i]) log.warn("unknown key name '{s}' in binding", .{name});
                },
                .code => |code| {
                    self.binding_syms[i] = 0;
                    self.binding_valid[i] = code > 0;
                },
            }
        }
    }

    pub fn addDevice(self: *Input, device: *c.struct_wlr_input_device) !void {
        self.applyLibinputConfig(device);
        switch (device.type) {
            c.WLR_INPUT_DEVICE_KEYBOARD => {
                const kb = c.wlr_keyboard_from_input_device(device);
                if (kb == null) return error.InvalidKeyboard;
                if (!c.wlr_keyboard_group_add_keyboard(self.group, @ptrCast(kb))) {
                    log.warn("keyboard could not join group; using directly", .{});
                    if (device.name) |name| log.info("keyboard: {s}", .{std.mem.span(name)});
                }
                c.wlr_seat_set_keyboard(self.server.seat, &self.group.keyboard);
            },
            c.WLR_INPUT_DEVICE_POINTER => {
                c.wlr_cursor_attach_input_device(self.server.cursor, device);
            },
            c.WLR_INPUT_DEVICE_TOUCH => {
                c.wlr_cursor_attach_input_device(self.server.cursor, device);
            },
            else => {},
        }
        c.wlr_seat_set_capabilities(self.server.seat, c.WL_SEAT_CAPABILITY_POINTER | c.WL_SEAT_CAPABILITY_KEYBOARD);
    }

    fn applyLibinputConfig(self: *Input, device: *c.struct_wlr_input_device) void {
        if (!c.wlr_input_device_is_libinput(device)) return;
        const dev = c.wlr_libinput_get_device_handle(device) orelse return;
        const cfg = &self.server.config.input;
        _ = c.libinput_device_config_tap_set_enabled(dev, if (cfg.tap_to_click) 1 else 0);
        _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(dev, if (cfg.natural_scroll) 1 else 0);
        _ = c.libinput_device_config_left_handed_set(dev, if (cfg.left_handed) 1 else 0);
        _ = c.libinput_device_config_dwt_set_enabled(dev, if (cfg.disable_while_typing) 1 else 0);
        _ = c.libinput_device_config_accel_set_speed(dev, @floatCast(cfg.accel_speed));
    }

    fn handleCursorMotion(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Input = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_pointer_motion_event = @ptrCast(@alignCast(data.?));
        c.wlr_cursor_move(self.server.cursor, &event.pointer.*.base, event.delta_x, event.delta_y);
        self.motion(event.time_msec);
    }

    fn handleCursorMotionAbsolute(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Input = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data.?));
        c.wlr_cursor_warp_absolute(self.server.cursor, &event.pointer.*.base, event.x, event.y);
        self.motion(event.time_msec);
    }

    fn motion(self: *Input, time_msec: u32) void {
        if (self.interactive) |*it| {
            self.updateInteractive(it);
            return;
        }
        self.updatePointerFocus(time_msec);
    }

    pub fn updatePointerFocus(self: *Input, time_msec: u32) void {
        const cx = self.server.cursor.x;
        const cy = self.server.cursor.y;
        const hit = self.hitTest(cx, cy);

        // Layer surfaces have priority over normal windows.
        if (self.server.layers.surfaceAt(cx, cy)) |lh| {
            if (self.last_pointer_surface != lh.surface) {
                c.wlr_seat_pointer_notify_enter(self.server.seat, lh.surface, lh.sx, lh.sy);
                self.last_pointer_surface = lh.surface;
                self.last_pointer_window = null;
                c.wlr_cursor_set_xcursor(self.server.cursor, self.server.cursor_manager, "default");
            } else {
                c.wlr_seat_pointer_notify_motion(self.server.seat, time_msec, lh.sx, lh.sy);
            }
            if (lh.ls.layer_surface.current.keyboard_interactive != c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) {
                c.wlr_seat_keyboard_notify_enter(self.server.seat, lh.surface, null, 0, null);
            }
            self.updateFocusFollowsMouse(null);
            return;
        }

        if (hit) |h| {
            if (self.last_pointer_surface != h.surface) {
                c.wlr_seat_pointer_notify_enter(self.server.seat, h.surface, h.sx, h.sy);
                self.last_pointer_surface = h.surface;
                self.last_pointer_window = h.window;
                self.last_hit_x = h.sx;
                self.last_hit_y = h.sy;
                c.wlr_cursor_set_xcursor(self.server.cursor, self.server.cursor_manager, "default");
                if (h.window) |w| {
                    if (w.output) |o| self.server.focused_output = o;
                }
            } else {
                c.wlr_seat_pointer_notify_motion(self.server.seat, time_msec, h.sx, h.sy);
                self.last_hit_x = h.sx;
                self.last_hit_y = h.sy;
            }
            self.updateFocusFollowsMouse(h.window);
        } else {
            if (self.last_pointer_surface != null) {
                c.wlr_seat_pointer_notify_clear_focus(self.server.seat);
                self.last_pointer_surface = null;
                self.last_pointer_window = null;
                c.wlr_cursor_set_xcursor(self.server.cursor, self.server.cursor_manager, "default");
            }
        }
    }

    fn updateFocusFollowsMouse(self: *Input, window: ?*Window) void {
        if (!self.server.config.focus_follows_mouse) return;
        if (window) |w| {
            if (w != self.server.focused_window) {
                if (w.output) |o| self.server.focusWindow(w, o);
            }
        }
    }

    const Hit = struct {
        surface: *c.struct_wlr_surface,
        sx: f64,
        sy: f64,
        window: ?*Window,
    };

    fn hitTest(self: *Input, lx: f64, ly: f64) ?Hit {
        // Top layer first: overlays/fullscreen, then floating, then tiled.
        var pass: u8 = 0;
        while (pass < 3) : (pass += 1) {
            var i = self.server.windows.items.len;
            while (i > 0) {
                i -= 1;
                const w = self.server.windows.items[i];
                if (!w.isVisible()) continue;
                const is_top = w.overlay or w.fullscreen;
                const is_float = w.floating or w.maximized;
                if (pass == 0 and !is_top) continue;
                if (pass == 1 and (!is_float or is_top)) continue;
                if (pass == 2 and (is_float or is_top)) continue;
                if (w.at(lx, ly)) |hit| {
                    return .{ .surface = hit.surface, .sx = hit.sx, .sy = hit.sy, .window = w };
                }
            }
        }
        return null;
    }

    fn handleCursorButton(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Input = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_pointer_button_event = @ptrCast(@alignCast(data.?));
        const pressed = event.state == c.WL_POINTER_BUTTON_STATE_PRESSED;

        if (!pressed and self.interactive != null) {
            self.endInteractive();
            _ = c.wlr_seat_pointer_notify_button(self.server.seat, event.time_msec, event.button, event.state);
            c.wlr_seat_pointer_notify_frame(self.server.seat);
            return;
        }

        const mods = self.currentModifiers();
        if (pressed) {
            if (self.findMouseBinding(mods, @intCast(event.button))) |binding| {
                if (binding.command == .mouse_move) {
                    if (self.last_pointer_window) |w| self.beginMove(w);
                    return;
                } else if (binding.command == .mouse_resize) {
                    if (self.last_pointer_window) |w| self.beginResize(w, c.WLR_EDGE_BOTTOM | c.WLR_EDGE_RIGHT);
                    return;
                }
                self.server.dispatch(binding.command, binding.args);
                return;
            }
        }

        if (pressed) {
            if (self.hitTest(self.server.cursor.x, self.server.cursor.y)) |h| {
                if (h.window) |w| {
                    if (w.output) |o| self.server.focusWindow(w, o);
                }
            }
        }
        _ = c.wlr_seat_pointer_notify_button(self.server.seat, event.time_msec, event.button, event.state);
        c.wlr_seat_pointer_notify_frame(self.server.seat);
        self.server.notifyActivity();
    }

    fn findMouseBinding(self: *Input, mods: u32, button: i32) ?*const config.MouseBinding {
        const cfg = &self.server.config;
        var i = cfg.mouse_binding_count;
        while (i > 0) {
            i -= 1;
            const b = &cfg.mouse_bindings[i];
            if (b.mods == mods and b.button == button) return b;
        }
        return null;
    }

    fn handleCursorAxis(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Input = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_pointer_axis_event = @ptrCast(@alignCast(data.?));
        const mods = self.currentModifiers();
        const dir: ?config.AxisDirection = switch (event.orientation) {
            c.WL_POINTER_AXIS_VERTICAL_SCROLL => if (event.delta < 0) .up else .down,
            c.WL_POINTER_AXIS_HORIZONTAL_SCROLL => if (event.delta < 0) .left else .right,
            else => null,
        };
        if (dir) |d| {
            const cfg = &self.server.config;
            var i = cfg.axis_binding_count;
            while (i > 0) {
                i -= 1;
                const b = &cfg.axis_bindings[i];
                if (b.mods == mods and b.direction == d) {
                    self.server.dispatch(b.command, b.args);
                    return;
                }
            }
        }
        c.wlr_seat_pointer_notify_axis(self.server.seat, event.time_msec, event.orientation, event.delta, event.delta_discrete, event.source, event.relative_direction);
        c.wlr_seat_pointer_notify_frame(self.server.seat);
        self.server.notifyActivity();
    }

    fn handleCursorFrame(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Input = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        c.wlr_seat_pointer_notify_frame(self.server.seat);
    }

    fn handleKey(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Input = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        const event: *c.struct_wlr_keyboard_key_event = @ptrCast(@alignCast(data.?));
        const kb = &self.group.keyboard;
        const keycode = event.keycode + 8;
        const pressed = event.state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
        const mods = self.currentModifiers();
        self.server.notifyActivity();

        var syms: [*c]const c.xkb_keysym_t = null;
        const nsyms: c_int = c.xkb_state_key_get_syms(kb.xkb_state, keycode, &syms);
        const on_release = !pressed;

        const cfg = &self.server.config;
        var i = cfg.binding_count;
        while (i > 0) {
            i -= 1;
            const b = &cfg.bindings[i];
            if (b.on_release != on_release) continue;
            if (b.mods != mods) continue;
            if (!self.bindingMatches(i, b, keycode, syms, nsyms)) continue;

            if (pressed) {
                if (self.repeat_active) {
                    self.repeat_active = false;
                    if (self.repeat_timer) |t| _ = c.wl_event_source_timer_update(t, 0);
                }
                if (!b.pass_through) {
                    self.server.dispatch(b.command, b.args);
                    if (b.allow_repeat and self.repeat_timer != null) {
                        self.repeat_active = true;
                        self.repeat_code = -1;
                        self.repeat_key = 0;
                        self.repeat_code = @as(i32, @intCast(i));
                        _ = c.wl_event_source_timer_update(self.repeat_timer.?, self.server.config.input.repeat_delay);
                    }
                    return;
                }
            }
            if (b.pass_through) break;
        }

        c.wlr_seat_set_keyboard(self.server.seat, kb);
        c.wlr_seat_keyboard_notify_key(self.server.seat, event.time_msec, event.keycode, event.state);
        if (pressed) {
            self.repeat_active = true;
            self.repeat_code = -2;
            self.repeat_key = event.keycode;
            if (self.repeat_timer) |t| _ = c.wl_event_source_timer_update(t, self.server.config.input.repeat_delay);
        } else {
            if (self.repeat_active and (self.repeat_code == -2 or self.repeat_key == event.keycode)) {
                self.repeat_active = false;
                if (self.repeat_timer) |t| _ = c.wl_event_source_timer_update(t, 0);
            }
        }
    }

    fn bindingMatches(self: *Input, index: usize, b: *const config.Binding, keycode: u32, syms: [*c]const c.xkb_keysym_t, nsyms: c_int) bool {
        switch (b.key) {
            .code => |code| return keycode == @as(u32, @intCast(code)),
            .sym => {
                if (!self.binding_valid[index]) return false;
                const want = self.binding_syms[index];
                const lower_want = c.xkb_keysym_to_lower(want);
                var n: c_int = 0;
                while (n < nsyms) : (n += 1) {
                    const got = syms[@intCast(n)];
                    if (got == want or c.xkb_keysym_to_lower(got) == lower_want) return true;
                }
                return false;
            },
        }
    }

    fn handleModifiers(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const self: *Input = @ptrCast(@alignCast(@as(*wl.Listener, @ptrCast(listener)).data.?));
        c.wlr_seat_set_keyboard(self.server.seat, &self.group.keyboard);
        c.wlr_seat_keyboard_notify_modifiers(self.server.seat, &self.group.keyboard.modifiers);
    }

    fn handleRepeat(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Input = @ptrCast(@alignCast(data.?));
        if (!self.repeat_active) return 0;
        if (self.repeat_code >= 0) {
            const idx: usize = @intCast(self.repeat_code);
            if (idx < self.server.config.binding_count) {
                const b = &self.server.config.bindings[idx];
                if (b.allow_repeat) {
                    self.server.dispatch(b.command, b.args);
                } else {
                    self.repeat_active = false;
                    return 0;
                }
            }
        } else if (self.repeat_code == -2) {
            c.wlr_seat_keyboard_notify_key(self.server.seat, wl.nowMsec(), self.repeat_key, c.WL_KEYBOARD_KEY_STATE_PRESSED);
        }
        if (self.repeat_active) {
            const rate = @max(1, self.server.config.input.repeat_rate);
            const interval: u32 = @intCast(@divTrunc(1000, rate));
            if (self.repeat_timer) |t| _ = c.wl_event_source_timer_update(t, @intCast(interval));
        }
        return 0;
    }

    pub fn currentModifiers(self: *Input) u32 {
        return c.wlr_keyboard_get_modifiers(&self.group.keyboard) & MOD_MASK;
    }

    pub fn beginMove(self: *Input, w: *Window) void {
        if (!w.floating and !w.fullscreen) {
            w.floating = true;
            w.float_geom = w.frame;
        }
        w.raise();
        if (w.output) |o| self.server.focusWindow(w, o);
        self.interactive = .{
            .window = w,
            .mode = .move,
            .start_x = self.server.cursor.x,
            .start_y = self.server.cursor.y,
            .start_frame = w.frame,
            .edges = 0,
            .moved = false,
        };
        c.wlr_cursor_set_xcursor(self.server.cursor, self.server.cursor_manager, "grabbing");
    }

    pub fn beginResize(self: *Input, w: *Window, edges: u32) void {
        if (!w.floating and !w.fullscreen) {
            w.floating = true;
            w.float_geom = w.frame;
        }
        w.raise();
        if (w.output) |o| self.server.focusWindow(w, o);
        self.interactive = .{
            .window = w,
            .mode = .resize,
            .start_x = self.server.cursor.x,
            .start_y = self.server.cursor.y,
            .start_frame = w.frame,
            .edges = edges,
            .moved = false,
        };
        c.wlr_cursor_set_xcursor(self.server.cursor, self.server.cursor_manager, "grabbing");
    }

    fn updateInteractive(self: *Input, it: *Interactive) void {
        const dx: i32 = @intFromFloat(@round(self.server.cursor.x - it.start_x));
        const dy: i32 = @intFromFloat(@round(self.server.cursor.y - it.start_y));
        if (dx == 0 and dy == 0) return;
        it.moved = true;
        var f = it.start_frame;
        if (it.mode == .move) {
            f.x += dx;
            f.y += dy;
        } else {
            if (it.edges & c.WLR_EDGE_LEFT != 0) {
                f.x += dx;
                f.width -= dx;
            }
            if (it.edges & c.WLR_EDGE_RIGHT != 0) f.width += dx;
            if (it.edges & c.WLR_EDGE_TOP != 0) {
                f.y += dy;
                f.height -= dy;
            }
            if (it.edges & c.WLR_EDGE_BOTTOM != 0) f.height += dy;
            f.width = @max(64, f.width);
            f.height = @max(64, f.height);
        }
        it.window.float_geom = f;
        it.window.applyGeometry(f, false);
        it.window.scheduleFrame();
    }

    pub fn endInteractive(self: *Input) void {
        if (self.interactive) |it| {
            if (it.moved) self.server.arrangeAll();
        }
        self.interactive = null;
        c.wlr_cursor_set_xcursor(self.server.cursor, self.server.cursor_manager, "default");
    }

    pub fn isInteracting(self: *Input) bool {
        return self.interactive != null;
    }
};
