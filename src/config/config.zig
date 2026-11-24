//! Kairo configuration model. Values are stored in a fixed-size pool so a
//! loaded configuration is a single allocation with deterministic ownership.

const std = @import("std");
const layout = @import("../layout/layout.zig");

pub const MAX_BINDINGS = 256;
pub const MAX_MOUSE_BINDINGS = 64;
pub const MAX_AXIS_BINDINGS = 32;
pub const MAX_RULES = 128;
pub const MAX_MONITORS = 32;
pub const MAX_SCRATCHPADS = 32;
pub const MAX_AUTOSTART = 32;
pub const MAX_ENV = 64;
pub const POOL_SIZE = 512 * 1024;
pub const MAX_TAGS: u32 = 32;

pub const Command = enum {
    none,
    spawn,
    spawn_shell,
    quit,
    reload,
    killclient,
    force_kill,
    toggle_floating,
    toggle_all_floating,
    toggle_fullscreen,
    toggle_fake_fullscreen,
    toggle_maximized,
    toggle_minimized,
    restore_minimized,
    toggle_global,
    toggle_overlay,
    center_window,
    focus_next,
    focus_prev,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    move_next,
    move_prev,
    move_left,
    move_right,
    move_up,
    move_down,
    swap_next,
    swap_prev,
    swap_master,
    view_tag,
    toggle_tag,
    tag_window,
    toggle_tag_window,
    view_next_tag,
    view_prev_tag,
    set_layout,
    cycle_layout,
    set_master_count,
    set_master_factor,
    zoom,
    focus_monitor,
    move_to_monitor,
    toggle_scratchpad,
    toggle_named_scratchpad,
    show_overview,
    toggle_switcher,
    switcher_next,
    switcher_prev,
    switcher_commit,
    mouse_move,
    mouse_resize,
    set_key_mode,
    toggle_session_lock,

    pub fn name(self: Command) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(s: []const u8) ?Command {
        if (std.mem.eql(u8, s, "exec")) return .spawn;
        if (std.mem.eql(u8, s, "exec_once")) return .spawn;
        if (std.mem.eql(u8, s, "spawn_shell")) return .spawn_shell;
        if (std.mem.eql(u8, s, "close")) return .killclient;
        if (std.mem.eql(u8, s, "togglefloating")) return .toggle_floating;
        if (std.mem.eql(u8, s, "togglefullscreen")) return .toggle_fullscreen;
        if (std.mem.eql(u8, s, "togglefakefullscreen")) return .toggle_fake_fullscreen;
        if (std.mem.eql(u8, s, "togglemaximizescreen")) return .toggle_maximized;
        if (std.mem.eql(u8, s, "minimized")) return .toggle_minimized;
        if (std.mem.eql(u8, s, "toggleglobal")) return .toggle_global;
        if (std.mem.eql(u8, s, "centerwin")) return .center_window;
        if (std.mem.eql(u8, s, "view")) return .view_tag;
        if (std.mem.eql(u8, s, "tag")) return .tag_window;
        if (std.mem.eql(u8, s, "toggletag")) return .toggle_tag;
        if (std.mem.eql(u8, s, "toggletagwindow")) return .toggle_tag_window;
        if (std.mem.eql(u8, s, "setlayout")) return .set_layout;
        if (std.mem.eql(u8, s, "cyclelayout")) return .cycle_layout;
        if (std.mem.eql(u8, s, "incnmaster")) return .set_master_count;
        if (std.mem.eql(u8, s, "setmfact")) return .set_master_factor;
        if (std.mem.eql(u8, s, "togglescratchpad")) return .toggle_scratchpad;
        if (std.mem.eql(u8, s, "togglenamedscratchpad")) return .toggle_named_scratchpad;
        if (std.mem.eql(u8, s, "toggleoverview")) return .show_overview;
        if (std.mem.eql(u8, s, "toggleswitcher")) return .toggle_switcher;
        if (std.mem.eql(u8, s, "focusmon")) return .focus_monitor;
        if (std.mem.eql(u8, s, "movemon")) return .move_to_monitor;
        if (std.mem.eql(u8, s, "moveresize")) return .mouse_move; // refined by the caller
        inline for (std.meta.fields(Command)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const KeySpec = union(enum) {
    sym: []const u8,
    code: i32,
};

pub const Binding = struct {
    mods: u32 = 0,
    key: KeySpec,
    mode: []const u8 = "default",
    command: Command = .none,
    args: []const u8 = "",
    on_release: bool = false,
    pass_through: bool = false,
    allow_repeat: bool = true,
    allow_locked: bool = false,
};

pub const Button = enum(i32) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
    side = 0x113,
    extra = 0x114,
    forward = 0x115,
    back = 0x116,
    task = 0x117,

    pub fn fromName(s: []const u8) ?i32 {
        inline for (std.meta.fields(Button)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @intFromEnum(@field(Button, f.name));
        }
        return null;
    }
};

pub const MouseBinding = struct {
    mods: u32 = 0,
    button: i32 = 0,
    command: Command = .none,
    args: []const u8 = "",
};

pub const AxisDirection = enum { up, down, left, right };

pub const AxisBinding = struct {
    mods: u32 = 0,
    direction: AxisDirection = .up,
    command: Command = .none,
    args: []const u8 = "",
};

/// A window rule. Optional fields use `null` for "not specified".
pub const Rule = struct {
    app_id: []const u8 = "",
    title: []const u8 = "",
    tags: ?u32 = null,
    output: []const u8 = "",
    floating: ?bool = null,
    fullscreen: ?bool = null,
    fake_fullscreen: ?bool = null,
    maximized: ?bool = null,
    minimized: ?bool = null,
    global: ?bool = null,
    overlay: ?bool = null,
    silent: ?bool = null,
    scratchpad: ?bool = null,
    term: ?bool = null,
    no_swallow: ?bool = null,
    opacity: ?f32 = null,
    focused_opacity: ?f32 = null,
    width: ?i32 = null,
    height: ?i32 = null,
    width_fraction: ?f32 = null,
    height_fraction: ?f32 = null,
    offset_x: ?i32 = null,
    offset_y: ?i32 = null,
    no_blur: ?bool = null,
    no_shadow: ?bool = null,
    no_radius: ?bool = null,
    no_border: ?bool = null,
    no_animation: ?bool = null,
    allow_csd: ?bool = null,
    focus_on_map: ?bool = null,
    once: bool = false,
};

pub const MonitorRule = struct {
    match: []const u8 = "",
    width: ?i32 = null,
    height: ?i32 = null,
    refresh_mhz: ?i32 = null,
    scale: f32 = 1.0,
    x: ?i32 = null,
    y: ?i32 = null,
    transform: u8 = 0,
    vrr: u8 = 0, // 0 off, 1 on, 2 fullscreen only
    enabled: bool = true,
};

pub const ScratchpadDef = struct {
    name: []const u8,
    command: []const u8 = "",
    app_id: []const u8 = "",
    title: []const u8 = "",
    width_fraction: f32 = 0.6,
    height_fraction: f32 = 0.6,
};

pub const Autostart = struct {
    command: []const u8,
    once: bool = true,
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    message: []const u8,
};

pub const AnimationSettings = struct {
    enabled: bool = true,
    duration_ms: u32 = 200,
    open_duration_ms: u32 = 0,
    close_duration_ms: u32 = 0,
    move_duration_ms: u32 = 0,
    tag_duration_ms: u32 = 0,
    easing: Easing = .ease_out_cubic,
    fade: bool = true,
    slide: bool = true,
    zoom_open: bool = true,
};

pub const Easing = enum {
    linear,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_out_cubic,
    ease_in_out_cubic,
    ease_out_quart,
    ease_out_expo,
    ease_out_back,
    ease_in_back,

    pub fn fromName(s: []const u8) ?Easing {
        inline for (std.meta.fields(Easing)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const EffectsSettings = struct {
    blur_enabled: bool = true,
    blur_radius: i32 = 5,
    blur_passes: i32 = 3,
    blur_noise: f32 = 0.0,
    blur_brightness: f32 = 0.9,
    blur_contrast: f32 = 1.0,
    blur_saturation: f32 = 1.1,
    shadows_enabled: bool = true,
    shadow_blur: f32 = 12.0,
    shadow_offset_x: i32 = 0,
    shadow_offset_y: i32 = 6,
    shadow_color: [4]f32 = .{ 0, 0, 0, 0.55 },
    corner_radius: i32 = 8,
    opacity: f32 = 1.0,
    focused_opacity: f32 = 1.0,
    unfocused_opacity: f32 = 1.0,
    layer_blur: bool = true,
    layer_shadow: bool = false,
};

pub const InputSettings = struct {
    xkb_rules: []const u8 = "",
    xkb_model: []const u8 = "",
    xkb_layout: []const u8 = "us",
    xkb_variant: []const u8 = "",
    xkb_options: []const u8 = "",
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    tap_to_click: bool = true,
    natural_scroll: bool = false,
    left_handed: bool = false,
    middle_emulation: bool = false,
    disable_while_typing: bool = true,
    accel_speed: f32 = 0.0,
    accel_profile: []const u8 = "adaptive",
    scroll_method: []const u8 = "",
    scroll_button: i32 = 0,
    click_method: []const u8 = "",
    keyboard_group: bool = true,
};

pub const OverviewSettings = struct {
    enabled: bool = true,
    gap: i32 = 16,
    duration_ms: u32 = 180,
    show_all_tags: bool = true,
    backdrop: [4]f32 = .{ 0.02, 0.02, 0.04, 0.75 },
};

pub const Config = struct {
    pool: Pool,
    mods: u32 = 64, // WLR_MODIFIER_LOGO
    terminal: []const u8 = "foot",
    menu: []const u8 = "",
    lock_command: []const u8 = "",
    idle_timeout_ms: u32 = 0,
    idle_lock: bool = true,
    idle_suspend: bool = false,
    tag_count: u32 = 9,
    default_layout: layout.Kind = .tile,
    master_count: u16 = 1,
    master_factor: f32 = 0.55,
    gap: i32 = 6,
    inner_gap: i32 = 6,
    border_width: i32 = 2,
    border_color_focused: [4]f32 = .{ 0.45, 0.62, 0.95, 1.0 },
    border_color_unfocused: [4]f32 = .{ 0.22, 0.25, 0.36, 1.0 },
    background_color: [4]f32 = .{ 0.055, 0.06, 0.08, 1.0 },
    focus_follows_mouse: bool = false,
    warp_cursor: bool = false,
    xwayland: bool = true,
    xwayland_persistence: bool = true,
    syncobj: bool = true,
    animations: AnimationSettings = .{},
    effects: EffectsSettings = .{},
    input: InputSettings = .{},
    overview: OverviewSettings = .{},
    cursor_theme: []const u8 = "",
    cursor_size: u32 = 24,
    bindings: [MAX_BINDINGS]Binding = undefined,
    binding_count: usize = 0,
    mouse_bindings: [MAX_MOUSE_BINDINGS]MouseBinding = undefined,
    mouse_binding_count: usize = 0,
    axis_bindings: [MAX_AXIS_BINDINGS]AxisBinding = undefined,
    axis_binding_count: usize = 0,
    rules: [MAX_RULES]Rule = undefined,
    rule_count: usize = 0,
    monitors: [MAX_MONITORS]MonitorRule = undefined,
    monitor_count: usize = 0,
    scratchpads: [MAX_SCRATCHPADS]ScratchpadDef = undefined,
    scratchpad_count: usize = 0,
    autostart: [MAX_AUTOSTART]Autostart = undefined,
    autostart_count: usize = 0,
    env: [MAX_ENV]EnvVar = undefined,
    env_count: usize = 0,
    diags: [64]Diagnostic = undefined,
    diag_count: usize = 0,

    pub const Pool = struct {
        buf: []u8,
        used: usize = 0,

        pub fn dupe(self: *Pool, s: []const u8) ![]const u8 {
            if (self.used + s.len > self.buf.len) return error.ConfigTooLarge;
            const out = self.buf[self.used .. self.used + s.len];
            @memcpy(out, s);
            self.used += s.len;
            return out;
        }

        pub fn dupeZ(self: *Pool, s: []const u8) ![:0]const u8 {
            if (self.used + s.len + 1 > self.buf.len) return error.ConfigTooLarge;
            const out = self.buf[self.used .. self.used + s.len];
            @memcpy(out, s);
            self.buf[self.used + s.len] = 0;
            const z: [:0]const u8 = self.buf[self.used .. self.used + s.len :0];
            self.used += s.len + 1;
            return z;
        }
    };

    pub fn initDefault(allocator: std.mem.Allocator) !Config {
        const buf = try allocator.alloc(u8, POOL_SIZE);
        errdefer allocator.free(buf);
        var cfg = Config{ .pool = .{ .buf = buf } };
        cfg.installDefaults();
        return cfg;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.pool.buf);
        self.* = undefined;
    }

    fn installDefaults(self: *Config) void {
        const mod = self.mods;
        self.addKey(mod, "Return", .spawn, "foot", .{}) catch {};
        self.addKey(mod, "Q", .killclient, "", .{}) catch {};
        self.addKey(mod | 1, "E", .quit, "", .{}) catch {};
        self.addKey(mod, "R", .reload, "", .{}) catch {};
        self.addKey(mod, "F", .toggle_floating, "", .{}) catch {};
        self.addKey(mod, "M", .toggle_fullscreen, "", .{}) catch {};
        self.addKey(mod | 1, "M", .toggle_maximized, "", .{}) catch {};
        self.addKey(mod, "Space", .cycle_layout, "", .{}) catch {};
        self.addKey(mod, "Tab", .switcher_next, "", .{}) catch {};
        self.addKey(mod | 1, "Tab", .switcher_prev, "", .{}) catch {};
        self.addKey(mod, "J", .focus_next, "", .{}) catch {};
        self.addKey(mod, "K", .focus_prev, "", .{}) catch {};
        self.addKey(mod | 1, "J", .swap_next, "", .{}) catch {};
        self.addKey(mod | 1, "K", .swap_prev, "", .{}) catch {};
        self.addKey(mod, "H", .focus_left, "", .{}) catch {};
        self.addKey(mod, "L", .focus_right, "", .{}) catch {};
        self.addKey(mod, "BackSpace", .toggle_global, "", .{}) catch {};
        self.addKey(mod, "grave", .toggle_scratchpad, "", .{}) catch {};
        self.addKey(mod | 1, "Space", .show_overview, "", .{}) catch {};
        self.addKey(mod, "comma", .focus_monitor, "", .{}) catch {};
        self.addKey(mod, "period", .move_to_monitor, "", .{}) catch {};
        self.addKey(mod, "C", .center_window, "", .{}) catch {};
        self.addKey(mod, "Z", .zoom, "", .{}) catch {};
        self.addKey(mod, "Left", .focus_left, "", .{}) catch {};
        self.addKey(mod, "Right", .focus_right, "", .{}) catch {};
        self.addKey(mod, "Up", .focus_up, "", .{}) catch {};
        self.addKey(mod, "Down", .focus_down, "", .{}) catch {};
        self.addKey(mod | 1, "Left", .move_left, "", .{}) catch {};
        self.addKey(mod | 1, "Right", .move_right, "", .{}) catch {};
        self.addKey(mod | 1, "Up", .move_up, "", .{}) catch {};
        self.addKey(mod | 1, "Down", .move_down, "", .{}) catch {};
        for (1..10) |i| {
            var keybuf: [1]u8 = .{@intCast(i + '0')};
            self.addKey(mod, &keybuf, .view_tag, "", .{ .tag = @intCast(i) }) catch {};
            self.addKey(mod | 1, &keybuf, .tag_window, "", .{ .tag = @intCast(i) }) catch {};
            self.addKey(mod | 4, &keybuf, .toggle_tag, "", .{ .tag = @intCast(i) }) catch {};
        }
        self.addMouse(mod, .left, .mouse_move, "") catch {};
        self.addMouse(mod, .right, .mouse_resize, "") catch {};
    }

    pub const BindingFlags = struct {
        on_release: bool = false,
        pass_through: bool = false,
        allow_repeat: bool = true,
        allow_locked: bool = false,
        mode: []const u8 = "default",
        tag: ?u32 = null,
    };

    pub fn addKey(self: *Config, mods: u32, key: []const u8, command: Command, args: []const u8, flags: BindingFlags) !void {
        if (self.binding_count >= MAX_BINDINGS) return error.TooManyBindings;
        const b = &self.bindings[self.binding_count];
        var args_storage = args;
        if (flags.tag) |tag| {
            var buf: [8]u8 = undefined;
            args_storage = try std.fmt.bufPrint(&buf, "{d}", .{tag});
            args_storage = try self.pool.dupe(args_storage);
        }
        b.* = .{
            .mods = mods,
            .key = .{ .sym = try self.pool.dupe(key) },
            .mode = try self.pool.dupe(flags.mode),
            .command = command,
            .args = try self.pool.dupe(args_storage),
            .on_release = flags.on_release,
            .pass_through = flags.pass_through,
            .allow_repeat = flags.allow_repeat,
            .allow_locked = flags.allow_locked,
        };
        self.binding_count += 1;
    }

    pub fn removeDefaultBindings(self: *Config) void {
        var write: usize = 0;
        for (self.bindings[0..self.binding_count]) |binding| {
            if (!std.mem.eql(u8, binding.mode, "default")) {
                self.bindings[write] = binding;
                write += 1;
            }
        }
        self.binding_count = write;
    }

    pub fn addKeyCode(self: *Config, mods: u32, code: i32, command: Command, args: []const u8, flags: BindingFlags) !void {
        if (self.binding_count >= MAX_BINDINGS) return error.TooManyBindings;
        const b = &self.bindings[self.binding_count];
        b.* = .{
            .mods = mods,
            .key = .{ .code = code },
            .mode = try self.pool.dupe(flags.mode),
            .command = command,
            .args = try self.pool.dupe(args),
            .on_release = flags.on_release,
            .pass_through = flags.pass_through,
            .allow_repeat = flags.allow_repeat,
            .allow_locked = flags.allow_locked,
        };
        self.binding_count += 1;
    }

    pub fn addMouse(self: *Config, mods: u32, button: Button, command: Command, args: []const u8) !void {
        if (self.mouse_binding_count >= MAX_MOUSE_BINDINGS) return error.TooManyBindings;
        self.mouse_bindings[self.mouse_binding_count] = .{
            .mods = mods,
            .button = @intFromEnum(button),
            .command = command,
            .args = try self.pool.dupe(args),
        };
        self.mouse_binding_count += 1;
    }

    pub fn addRule(self: *Config, rule: Rule) !void {
        if (self.rule_count >= MAX_RULES) return error.TooManyRules;
        self.rules[self.rule_count] = rule;
        self.rule_count += 1;
    }

    pub fn addScratchpad(self: *Config, def: ScratchpadDef) !void {
        if (self.scratchpad_count >= MAX_SCRATCHPADS) return error.TooManyScratchpads;
        self.scratchpads[self.scratchpad_count] = def;
        self.scratchpad_count += 1;
    }
};
