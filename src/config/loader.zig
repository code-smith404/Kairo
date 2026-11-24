//! Configuration loader and validating parser.
//!
//! Kairo's configuration is a flat, line-oriented format:
//!
//!     mod = Super
//!     bind = SUPER+SHIFT, Q, quit
//!     rule = app_id:firefox, floating:1, tags:2
//!
//! Every value is validated while parsing and errors are reported with the
//! file name and line number.

const std = @import("std");
const Config = @import("config.zig").Config;
const config = @import("config.zig");
const layout = @import("../layout/layout.zig");

pub const Diagnostic = config.Diagnostic;

const MAX_INCLUDE_DEPTH = 8;

const Parser = struct {
    cfg: *Config,
    allocator: std.mem.Allocator,
    vars: std.StringHashMap([]const u8),
    depth: u32 = 0,
    current_mode: []const u8 = "default",
    saw_default_bind: bool = false,
    saw_mousebind: bool = false,
    saw_axisbind: bool = false,

    fn addDiag(self: *Parser, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) void {
        if (self.cfg.diag_count >= self.cfg.diags.len) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "configuration error";
        const file_copy = self.cfg.pool.dupe(file) catch file;
        const msg_copy = self.cfg.pool.dupe(msg) catch msg;
        self.cfg.diags[self.cfg.diag_count] = .{ .file = file_copy, .line = line, .message = msg_copy };
        self.cfg.diag_count += 1;
    }

    fn expand(self: *Parser, input: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, input, '$') == null) return input;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '$' and i + 1 < input.len) {
                i += 1;
                var name: []const u8 = &.{};
                if (input[i] == '{') {
                    const close = std.mem.indexOfScalarPos(u8, input, i + 1, '}') orelse {
                        out.append(self.allocator, '$') catch return input;
                        continue;
                    };
                    name = input[i + 1 .. close];
                    i = close + 1;
                } else {
                    const start = i;
                    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) i += 1;
                    name = input[start..i];
                    if (name.len == 0 or std.ascii.isDigit(name[0])) {
                        out.append(self.allocator, '$') catch return input;
                        i = start;
                        continue;
                    }
                }
                if (self.vars.get(name)) |value| {
                    out.appendSlice(self.allocator, value) catch return input;
                } else {
                    // Leave unknown variables untouched for the shell.
                    out.append(self.allocator, '$') catch return input;
                    if (input[i - 1] != '}') out.appendSlice(self.allocator, name) catch return input;
                }
            } else {
                out.append(self.allocator, input[i]) catch return input;
                i += 1;
            }
        }
        return self.cfg.pool.dupe(out.items) catch input;
    }

    fn parseFile(self: *Parser, path: []const u8, optional: bool) void {
        if (self.depth >= MAX_INCLUDE_DEPTH) {
            self.addDiag(path, 0, "maximum include depth exceeded", .{});
            return;
        }
        const data = std.fs.cwd().readFileAlloc(self.allocator, path, 1 << 20) catch |err| {
            if (!optional) self.addDiag(path, 0, "cannot read configuration: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(data);
        self.depth += 1;
        defer self.depth -= 1;
        self.parseText(data, path);
    }

    fn parseText(self: *Parser, text: []const u8, filename: []const u8) void {
        var line_no: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            line_no += 1;
            const line = stripComment(raw_line);
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '[') {
                self.addDiag(filename, line_no, "sections are not used; use 'key = value' lines", .{});
                continue;
            }
            const eq = indexOfOutsideQuotes(trimmed, '=') orelse {
                self.addDiag(filename, line_no, "expected 'key = value'", .{});
                continue;
            };
            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            var value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
            if (key.len == 0) {
                self.addDiag(filename, line_no, "empty key", .{});
                continue;
            }
            if (std.mem.eql(u8, key, "source") or std.mem.eql(u8, key, "source_optional") or std.mem.eql(u8, key, "include")) {
                const optional = std.mem.eql(u8, key, "source_optional");
                const expanded = self.expand(value);
                const resolved = self.resolvePath(filename, expanded);
                defer self.allocator.free(resolved);
                self.parseFile(resolved, optional);
                continue;
            }
            value = self.expand(value);
            self.apply(filename, line_no, key, value);
        }
    }

    fn resolvePath(self: *Parser, current_file: []const u8, path: []const u8) []u8 {
        var expanded: []const u8 = path;
        var home_buf: ?[]u8 = null;
        defer if (home_buf) |b| self.allocator.free(b);
        if (path.len > 0 and path[0] == '~') {
            if (std.posix.getenv("HOME")) |home| {
                const rest = if (path.len > 1 and path[1] == '/') path[2..] else path[1..];
                home_buf = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ home, rest }) catch null;
                if (home_buf) |b| expanded = b;
            }
        }
        if (std.fs.path.isAbsolute(expanded)) {
            return self.allocator.dupe(u8, expanded) catch @constCast(expanded);
        }
        const base = std.fs.path.dirname(current_file) orelse ".";
        return std.fs.path.resolve(self.allocator, &.{ base, expanded }) catch @constCast(expanded);
    }

    fn apply(self: *Parser, file: []const u8, line: u32, key_raw: []const u8, value: []const u8) void {
        var key_buf: [64]u8 = undefined;
        const lower = std.ascii.lowerString(&key_buf, key_raw);
        const key = std.mem.replaceOwned(u8, self.allocator, lower, "-", "_") catch lower;
        defer if (key.ptr != lower.ptr) self.allocator.free(key);

        if (std.mem.eql(u8, key, "var")) {
            const comma = std.mem.indexOfScalar(u8, value, ',') orelse std.mem.indexOfScalar(u8, value, '=') orelse {
                self.addDiag(file, line, "var expects name,value", .{});
                return;
            };
            const name = std.mem.trim(u8, value[0..comma], " \t");
            const val = std.mem.trim(u8, value[comma + 1 ..], " \t");
            if (name.len == 0 or !isVarName(name)) {
                self.addDiag(file, line, "invalid variable name '{s}'", .{name});
                return;
            }
            const cname = self.cfg.pool.dupe(name) catch return;
            const cval = self.cfg.pool.dupe(val) catch return;
            self.vars.put(cname, cval) catch {};
            return;
        }

        if (std.mem.eql(u8, key, "bind") or std.mem.eql(u8, key, "bindr") or std.mem.eql(u8, key, "bindp") or
            std.mem.eql(u8, key, "bindn") or std.mem.eql(u8, key, "bindl") or std.mem.eql(u8, key, "bindc"))
        {
            self.parseBind(file, line, key, value);
            return;
        }
        if (std.mem.eql(u8, key, "mousebind")) {
            self.parseMouseBind(file, line, value);
            return;
        }
        if (std.mem.eql(u8, key, "axisbind")) {
            self.parseAxisBind(file, line, value);
            return;
        }
        if (std.mem.eql(u8, key, "rule") or std.mem.eql(u8, key, "window_rule") or std.mem.eql(u8, key, "window_rule_once")) {
            self.parseRule(file, line, value, std.mem.eql(u8, key, "window_rule_once"));
            return;
        }
        if (std.mem.eql(u8, key, "monitor")) {
            self.parseMonitor(file, line, value);
            return;
        }
        if (std.mem.eql(u8, key, "scratchpad")) {
            self.parseScratchpad(file, line, value);
            return;
        }
        if (std.mem.eql(u8, key, "exec") or std.mem.eql(u8, key, "spawn")) {
            self.addAutostart(file, line, value, false);
            return;
        }
        if (std.mem.eql(u8, key, "exec_once")) {
            self.addAutostart(file, line, value, true);
            return;
        }
        if (std.mem.eql(u8, key, "env")) {
            const comma = std.mem.indexOfScalar(u8, value, ',');
            const eq = std.mem.indexOfScalar(u8, value, '=');
            const sep = if (comma != null and (eq == null or comma.? < eq.?)) comma.? else if (eq) |e| e else {
                self.addDiag(file, line, "env expects NAME,VALUE", .{});
                return;
            };
            const name = std.mem.trim(u8, value[0..sep], " \t");
            const val = std.mem.trim(u8, value[sep + 1 ..], " \t");
            if (name.len == 0) {
                self.addDiag(file, line, "env variable name is empty", .{});
                return;
            }
            if (self.cfg.env_count >= config.MAX_ENV) {
                self.addDiag(file, line, "too many env entries", .{});
                return;
            }
            self.cfg.env[self.cfg.env_count] = .{
                .name = self.cfg.pool.dupe(name) catch return,
                .value = self.cfg.pool.dupe(val) catch return,
            };
            self.cfg.env_count += 1;
            return;
        }
        if (std.mem.eql(u8, key, "mode") or std.mem.eql(u8, key, "key_mode")) {
            const name = std.mem.trim(u8, value, " \t");
            if (!isModeName(name)) {
                self.addDiag(file, line, "invalid key mode '{s}'", .{name});
                return;
            }
            self.current_mode = self.cfg.pool.dupe(name) catch "default";
            return;
        }

        // Scalar options.
        if (std.mem.eql(u8, key, "mod")) {
            if (parseMods(value)) |m| self.cfg.mods = m else self.addDiag(file, line, "unknown modifier '{s}'", .{value});
        } else if (std.mem.eql(u8, key, "terminal")) {
            self.cfg.terminal = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "menu")) {
            self.cfg.menu = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "lock_command") or std.mem.eql(u8, key, "locker")) {
            self.cfg.lock_command = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "idle_timeout_ms") or std.mem.eql(u8, key, "idle_timeout")) {
            self.cfg.idle_timeout_ms = std.fmt.parseInt(u32, value, 10) catch {
                self.addDiag(file, line, "expected unsigned integer (milliseconds)", .{});
                return;
            };
        } else if (std.mem.eql(u8, key, "idle_lock")) {
            self.cfg.idle_lock = parseBool(value) orelse {
                self.addDiag(file, line, "expected boolean", .{});
                return;
            };
        } else if (std.mem.eql(u8, key, "idle_suspend")) {
            self.cfg.idle_suspend = parseBool(value) orelse {
                self.addDiag(file, line, "expected boolean", .{});
                return;
            };
        } else if (std.mem.eql(u8, key, "default_layout")) {
            self.cfg.default_layout = layout.Kind.fromName(value) orelse {
                self.addDiag(file, line, "unknown layout '{s}'", .{value});
                return;
            };
        } else if (std.mem.eql(u8, key, "master_count")) {
            self.cfg.master_count = @intCast(std.math.clamp(parseInt(value) orelse 1, 0, 16));
        } else if (std.mem.eql(u8, key, "master_factor")) {
            self.cfg.master_factor = std.math.clamp(parseFloat(value) orelse 0.55, 0.1, 0.9);
        } else if (std.mem.eql(u8, key, "gaps") or std.mem.eql(u8, key, "gap")) {
            self.cfg.gap = parseInt(value) orelse 6;
        } else if (std.mem.eql(u8, key, "inner_gaps") or std.mem.eql(u8, key, "inner_gap")) {
            self.cfg.inner_gap = parseInt(value) orelse 6;
        } else if (std.mem.eql(u8, key, "border_width")) {
            self.cfg.border_width = parseInt(value) orelse 2;
        } else if (std.mem.eql(u8, key, "border_color_focused")) {
            self.cfg.border_color_focused = parseColor(file, line, self, value) orelse return;
        } else if (std.mem.eql(u8, key, "border_color_unfocused")) {
            self.cfg.border_color_unfocused = parseColor(file, line, self, value) orelse return;
        } else if (std.mem.eql(u8, key, "background") or std.mem.eql(u8, key, "background_color")) {
            self.cfg.background_color = parseColor(file, line, self, value) orelse return;
        } else if (std.mem.eql(u8, key, "focus_follows_mouse")) {
            self.cfg.focus_follows_mouse = parseBool(value) orelse {
                self.addDiag(file, line, "expected boolean", .{});
                return;
            };
        } else if (std.mem.eql(u8, key, "warp_cursor")) {
            self.cfg.warp_cursor = parseBool(value) orelse false;
        } else if (std.mem.eql(u8, key, "tag_count")) {
            const n = parseInt(value) orelse 9;
            self.cfg.tag_count = @intCast(std.math.clamp(n, 1, config.MAX_TAGS));
        } else if (std.mem.eql(u8, key, "animations") or std.mem.eql(u8, key, "animation")) {
            self.cfg.animations.enabled = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "animation_duration")) {
            self.cfg.animations.duration_ms = @intCast(@max(0, parseInt(value) orelse 200));
        } else if (std.mem.eql(u8, key, "animation_open_duration")) {
            self.cfg.animations.open_duration_ms = @intCast(@max(0, parseInt(value) orelse 0));
        } else if (std.mem.eql(u8, key, "animation_close_duration")) {
            self.cfg.animations.close_duration_ms = @intCast(@max(0, parseInt(value) orelse 0));
        } else if (std.mem.eql(u8, key, "animation_move_duration")) {
            self.cfg.animations.move_duration_ms = @intCast(@max(0, parseInt(value) orelse 0));
        } else if (std.mem.eql(u8, key, "animation_tag_duration")) {
            self.cfg.animations.tag_duration_ms = @intCast(@max(0, parseInt(value) orelse 0));
        } else if (std.mem.eql(u8, key, "animation_easing") or std.mem.eql(u8, key, "easing")) {
            self.cfg.animations.easing = config.Easing.fromName(value) orelse {
                self.addDiag(file, line, "unknown easing '{s}'", .{value});
                return;
            };
        } else if (std.mem.eql(u8, key, "animation_fade")) {
            self.cfg.animations.fade = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "blur")) {
            self.cfg.effects.blur_enabled = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "blur_radius")) {
            self.cfg.effects.blur_radius = parseInt(value) orelse 5;
        } else if (std.mem.eql(u8, key, "blur_passes")) {
            self.cfg.effects.blur_passes = parseInt(value) orelse 3;
        } else if (std.mem.eql(u8, key, "blur_noise")) {
            self.cfg.effects.blur_noise = parseFloat(value) orelse 0;
        } else if (std.mem.eql(u8, key, "blur_brightness")) {
            self.cfg.effects.blur_brightness = parseFloat(value) orelse 0.9;
        } else if (std.mem.eql(u8, key, "blur_contrast")) {
            self.cfg.effects.blur_contrast = parseFloat(value) orelse 1.0;
        } else if (std.mem.eql(u8, key, "blur_saturation")) {
            self.cfg.effects.blur_saturation = parseFloat(value) orelse 1.1;
        } else if (std.mem.eql(u8, key, "shadow") or std.mem.eql(u8, key, "shadows")) {
            self.cfg.effects.shadows_enabled = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "shadow_blur")) {
            self.cfg.effects.shadow_blur = parseFloat(value) orelse 12;
        } else if (std.mem.eql(u8, key, "shadow_offset")) {
            var it = std.mem.splitScalar(u8, value, ',');
            if (it.next()) |x| self.cfg.effects.shadow_offset_x = std.fmt.parseInt(i32, std.mem.trim(u8, x, " \t"), 10) catch 0;
            if (it.next()) |y| self.cfg.effects.shadow_offset_y = std.fmt.parseInt(i32, std.mem.trim(u8, y, " \t"), 10) catch 0;
        } else if (std.mem.eql(u8, key, "shadow_offset_x")) {
            self.cfg.effects.shadow_offset_x = parseInt(value) orelse 0;
        } else if (std.mem.eql(u8, key, "shadow_offset_y")) {
            self.cfg.effects.shadow_offset_y = parseInt(value) orelse 6;
        } else if (std.mem.eql(u8, key, "shadow_color")) {
            self.cfg.effects.shadow_color = parseColor(file, line, self, value) orelse return;
        } else if (std.mem.eql(u8, key, "corner_radius")) {
            self.cfg.effects.corner_radius = parseInt(value) orelse 8;
        } else if (std.mem.eql(u8, key, "opacity")) {
            self.cfg.effects.opacity = std.math.clamp(parseFloat(value) orelse 1, 0, 1);
        } else if (std.mem.eql(u8, key, "focused_opacity")) {
            self.cfg.effects.focused_opacity = std.math.clamp(parseFloat(value) orelse 1, 0, 1);
        } else if (std.mem.eql(u8, key, "unfocused_opacity")) {
            self.cfg.effects.unfocused_opacity = std.math.clamp(parseFloat(value) orelse 1, 0, 1);
        } else if (std.mem.eql(u8, key, "layer_blur")) {
            self.cfg.effects.layer_blur = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "keyboard_layout") or std.mem.eql(u8, key, "xkb_layout")) {
            self.cfg.input.xkb_layout = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "keyboard_variant") or std.mem.eql(u8, key, "xkb_variant")) {
            self.cfg.input.xkb_variant = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "keyboard_options") or std.mem.eql(u8, key, "xkb_options")) {
            self.cfg.input.xkb_options = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "keyboard_rules") or std.mem.eql(u8, key, "xkb_rules")) {
            self.cfg.input.xkb_rules = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "keyboard_model") or std.mem.eql(u8, key, "xkb_model")) {
            self.cfg.input.xkb_model = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "repeat_rate")) {
            self.cfg.input.repeat_rate = std.math.clamp(parseInt(value) orelse 25, 1, 200);
        } else if (std.mem.eql(u8, key, "repeat_delay")) {
            self.cfg.input.repeat_delay = @max(0, parseInt(value) orelse 600);
        } else if (std.mem.eql(u8, key, "tap_to_click")) {
            self.cfg.input.tap_to_click = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "natural_scroll")) {
            self.cfg.input.natural_scroll = parseBool(value) orelse false;
        } else if (std.mem.eql(u8, key, "left_handed")) {
            self.cfg.input.left_handed = parseBool(value) orelse false;
        } else if (std.mem.eql(u8, key, "disable_while_typing")) {
            self.cfg.input.disable_while_typing = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "accel_speed")) {
            self.cfg.input.accel_speed = parseFloat(value) orelse 0;
        } else if (std.mem.eql(u8, key, "cursor_theme")) {
            self.cfg.cursor_theme = self.cfg.pool.dupe(value) catch return;
        } else if (std.mem.eql(u8, key, "cursor_size")) {
            self.cfg.cursor_size = @intCast(std.math.clamp(parseInt(value) orelse 24, 8, 128));
        } else if (std.mem.eql(u8, key, "xwayland")) {
            self.cfg.xwayland = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "xwayland_persistence")) {
            self.cfg.xwayland_persistence = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "syncobj")) {
            self.cfg.syncobj = parseBool(value) orelse true;
        } else if (std.mem.eql(u8, key, "overview_gap")) {
            self.cfg.overview.gap = parseInt(value) orelse 16;
        } else if (std.mem.eql(u8, key, "overview_duration")) {
            self.cfg.overview.duration_ms = @intCast(@max(0, parseInt(value) orelse 180));
        } else {
            self.addDiag(file, line, "unknown option '{s}'", .{key_raw});
        }
    }

    fn parseBind(self: *Parser, file: []const u8, line: u32, key: []const u8, value: []const u8) void {
        var rest = value;
        const mods_s = takeField(&rest);
        const key_s = takeField(&rest);
        const cmd_s = takeField(&rest);
        const args = std.mem.trim(u8, rest, " \t");
        if (key_s.len == 0 or cmd_s.len == 0) {
            self.addDiag(file, line, "bind expects MODIFIERS,KEY,COMMAND[,ARGS]", .{});
            return;
        }
        const mods = parseMods(mods_s) orelse {
            self.addDiag(file, line, "unknown modifier '{s}'", .{mods_s});
            return;
        };
        var command = config.Command.fromName(cmd_s) orelse {
            self.addDiag(file, line, "unknown command '{s}'", .{cmd_s});
            return;
        };
        if (std.mem.eql(u8, cmd_s, "moveresize") or std.mem.eql(u8, cmd_s, "move_resize")) {
            command = if (std.mem.indexOf(u8, args, "resize") != null) .mouse_resize else .mouse_move;
        }
        if (!validateCommandArgs(self, file, line, command, args)) return;
        if (!self.saw_default_bind and std.mem.eql(u8, self.current_mode, "default")) {
            self.cfg.removeDefaultBindings();
            self.saw_default_bind = true;
        }
        const flags = Config.BindingFlags{
            .on_release = std.mem.eql(u8, key, "bindr"),
            .pass_through = std.mem.eql(u8, key, "bindp"),
            .allow_repeat = !std.mem.eql(u8, key, "bindn"),
            .allow_locked = std.mem.eql(u8, key, "bindl"),
            .mode = self.current_mode,
        };
        if (std.mem.startsWith(u8, key_s, "code:")) {
            const code = std.fmt.parseInt(i32, key_s[5..], 10) catch {
                self.addDiag(file, line, "invalid keycode '{s}'", .{key_s});
                return;
            };
            self.cfg.addKeyCode(mods, code, command, args, flags) catch {
                self.addDiag(file, line, "too many bindings", .{});
            };
        } else {
            self.cfg.addKey(mods, key_s, command, args, flags) catch {
                self.addDiag(file, line, "too many bindings", .{});
            };
        }
    }

    fn parseMouseBind(self: *Parser, file: []const u8, line: u32, value: []const u8) void {
        var rest = value;
        const mods_s = takeField(&rest);
        const button_s = takeField(&rest);
        const cmd_s = takeField(&rest);
        const args = std.mem.trim(u8, rest, " \t");
        const mods = parseMods(mods_s) orelse {
            self.addDiag(file, line, "unknown modifier '{s}'", .{mods_s});
            return;
        };
        var button = config.Button.fromName(button_s);
        if (std.mem.startsWith(u8, button_s, "code:")) {
            button = std.fmt.parseInt(i32, button_s[5..], 10) catch null;
        }
        const b = button orelse {
            self.addDiag(file, line, "unknown mouse button '{s}'", .{button_s});
            return;
        };
        var command: config.Command = undefined;
        if (std.mem.eql(u8, cmd_s, "moveresize") or std.mem.eql(u8, cmd_s, "move_resize")) {
            command = if (std.mem.indexOf(u8, args, "resize") != null) .mouse_resize else .mouse_move;
        } else {
            command = config.Command.fromName(cmd_s) orelse {
                self.addDiag(file, line, "unknown command '{s}'", .{cmd_s});
                return;
            };
        }
        if (command == .mouse_move and std.mem.indexOf(u8, args, "resize") != null) command = .mouse_resize;
        if (!self.saw_mousebind) {
            self.cfg.mouse_binding_count = 0;
            self.saw_mousebind = true;
        }
        self.cfg.addMouse(mods, @enumFromInt(b), command, args) catch {
            self.addDiag(file, line, "too many mouse bindings", .{});
        };
    }

    fn parseAxisBind(self: *Parser, file: []const u8, line: u32, value: []const u8) void {
        var rest = value;
        const mods_s = takeField(&rest);
        const dir_s = takeField(&rest);
        const cmd_s = takeField(&rest);
        const args = std.mem.trim(u8, rest, " \t");
        const mods = parseMods(mods_s) orelse {
            self.addDiag(file, line, "unknown modifier '{s}'", .{mods_s});
            return;
        };
        const dir: config.AxisDirection = blk: {
            inline for (std.meta.fields(config.AxisDirection)) |f| {
                if (std.ascii.eqlIgnoreCase(dir_s, f.name)) break :blk @enumFromInt(f.value);
            }
            self.addDiag(file, line, "unknown axis direction '{s}'", .{dir_s});
            return;
        };
        const command = config.Command.fromName(cmd_s) orelse {
            self.addDiag(file, line, "unknown command '{s}'", .{cmd_s});
            return;
        };
        if (!validateCommandArgs(self, file, line, command, args)) return;
        if (!self.saw_axisbind) {
            self.cfg.axis_binding_count = 0;
            self.saw_axisbind = true;
        }
        if (self.cfg.axis_binding_count >= config.MAX_AXIS_BINDINGS) {
            self.addDiag(file, line, "too many axis bindings", .{});
            return;
        }
        self.cfg.axis_bindings[self.cfg.axis_binding_count] = .{
            .mods = mods,
            .direction = dir,
            .command = command,
            .args = self.cfg.pool.dupe(args) catch return,
        };
        self.cfg.axis_binding_count += 1;
    }

    fn parseRule(self: *Parser, file: []const u8, line: u32, value: []const u8, once: bool) void {
        var rule = config.Rule{ .once = once };
        var rest = value;
        while (rest.len > 0) {
            const field = takeField(&rest);
            if (field.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, field, ':') orelse {
                self.addDiag(file, line, "rule field '{s}' is missing ':'", .{field});
                continue;
            };
            const k = std.mem.trim(u8, field[0..colon], " \t");
            const v = std.mem.trim(u8, field[colon + 1 ..], " \t");
            if (std.mem.eql(u8, k, "app_id")) {
                rule.app_id = self.cfg.pool.dupe(v) catch return;
            } else if (std.mem.eql(u8, k, "title")) {
                rule.title = self.cfg.pool.dupe(v) catch return;
            } else if (std.mem.eql(u8, k, "tags")) {
                rule.tags = parseTagMask(v) orelse {
                    self.addDiag(file, line, "invalid tag mask '{s}'", .{v});
                    return;
                };
            } else if (std.mem.eql(u8, k, "monitor") or std.mem.eql(u8, k, "output")) {
                rule.output = self.cfg.pool.dupe(v) catch return;
            } else if (std.mem.eql(u8, k, "is_floating") or std.mem.eql(u8, k, "floating")) {
                rule.floating = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "is_fullscreen") or std.mem.eql(u8, k, "fullscreen")) {
                rule.fullscreen = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "is_fake_fullscreen") or std.mem.eql(u8, k, "fake_fullscreen")) {
                rule.fake_fullscreen = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "is_maximized") or std.mem.eql(u8, k, "maximized")) {
                rule.maximized = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "is_minimized") or std.mem.eql(u8, k, "minimized")) {
                rule.minimized = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "is_global") or std.mem.eql(u8, k, "global")) {
                rule.global = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "is_overlay") or std.mem.eql(u8, k, "overlay")) {
                rule.overlay = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "is_open_silent") or std.mem.eql(u8, k, "silent")) {
                rule.silent = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "scratchpad") or std.mem.eql(u8, k, "is_scratchpad")) {
                rule.scratchpad = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "is_term") or std.mem.eql(u8, k, "term")) {
                rule.term = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "no_swallow") or std.mem.eql(u8, k, "swallow")) {
                rule.no_swallow = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "opacity")) {
                rule.opacity = std.math.clamp(parseFloat(v) orelse 1, 0, 1);
            } else if (std.mem.eql(u8, k, "focused_opacity")) {
                rule.focused_opacity = std.math.clamp(parseFloat(v) orelse 1, 0, 1);
            } else if (std.mem.eql(u8, k, "width")) {
                const f = parseFloat(v) orelse 0;
                if (f > 0 and f < 1) {
                    rule.width_fraction = f;
                } else {
                    rule.width = @intFromFloat(f);
                }
            } else if (std.mem.eql(u8, k, "height")) {
                const f = parseFloat(v) orelse 0;
                if (f > 0 and f < 1) {
                    rule.height_fraction = f;
                } else {
                    rule.height = @intFromFloat(f);
                }
            } else if (std.mem.eql(u8, k, "offset_x")) {
                rule.offset_x = parseInt(v);
            } else if (std.mem.eql(u8, k, "offset_y")) {
                rule.offset_y = parseInt(v);
            } else if (std.mem.eql(u8, k, "no_blur")) {
                rule.no_blur = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "no_shadow")) {
                rule.no_shadow = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "no_radius")) {
                rule.no_radius = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "no_border")) {
                rule.no_border = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "no_animation")) {
                rule.no_animation = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "allow_csd")) {
                rule.allow_csd = parseBool(v) orelse false;
            } else if (std.mem.eql(u8, k, "focus_on_map")) {
                rule.focus_on_map = parseBool(v) orelse true;
            } else {
                self.addDiag(file, line, "unknown rule property '{s}'", .{k});
                return;
            }
        }
        self.cfg.addRule(rule) catch {
            self.addDiag(file, line, "too many rules", .{});
        };
    }

    fn parseMonitor(self: *Parser, file: []const u8, line: u32, value: []const u8) void {
        var rule = config.MonitorRule{};
        var rest = value;
        rule.match = self.cfg.pool.dupe(takeField(&rest)) catch return;
        if (rule.match.len == 0) {
            self.addDiag(file, line, "monitor rule needs a name", .{});
            return;
        }
        const mode_s = takeField(&rest);
        if (mode_s.len > 0) {
            if (parseMode(mode_s)) |m| {
                rule.width = m.width;
                rule.height = m.height;
                rule.refresh_mhz = m.refresh;
            } else {
                self.addDiag(file, line, "invalid mode '{s}' (expected WIDTHxHEIGHT[@REFRESH])", .{mode_s});
                return;
            }
        }
        const scale_s = takeField(&rest);
        if (scale_s.len > 0) rule.scale = std.math.clamp(parseFloat(scale_s) orelse 1, 0.1, 10);
        const pos_s = takeField(&rest);
        if (pos_s.len > 0) {
            if (parsePosition(pos_s)) |p| {
                rule.x = p[0];
                rule.y = p[1];
            } else {
                self.addDiag(file, line, "invalid position '{s}' (expected XxY)", .{pos_s});
                return;
            }
        }
        const transform_s = std.mem.trim(u8, rest, " \t");
        if (transform_s.len > 0) {
            rule.transform = parseTransform(transform_s) orelse {
                self.addDiag(file, line, "invalid transform '{s}'", .{transform_s});
                return;
            };
        }
        if (self.cfg.monitor_count >= config.MAX_MONITORS) {
            self.addDiag(file, line, "too many monitor rules", .{});
            return;
        }
        self.cfg.monitors[self.cfg.monitor_count] = rule;
        self.cfg.monitor_count += 1;
    }

    fn parseScratchpad(self: *Parser, file: []const u8, line: u32, value: []const u8) void {
        var def = config.ScratchpadDef{ .name = "" };
        var rest = value;
        var have_name = false;
        while (rest.len > 0) {
            const field = takeField(&rest);
            if (field.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, field, ':') orelse {
                self.addDiag(file, line, "scratchpad field '{s}' is missing ':'", .{field});
                continue;
            };
            const k = std.mem.trim(u8, field[0..colon], " \t");
            const v = std.mem.trim(u8, field[colon + 1 ..], " \t");
            if (std.mem.eql(u8, k, "name")) {
                def.name = self.cfg.pool.dupe(v) catch return;
                have_name = true;
            } else if (std.mem.eql(u8, k, "command") or std.mem.eql(u8, k, "cmd")) {
                def.command = self.cfg.pool.dupe(v) catch return;
            } else if (std.mem.eql(u8, k, "app_id")) {
                def.app_id = self.cfg.pool.dupe(v) catch return;
            } else if (std.mem.eql(u8, k, "title")) {
                def.title = self.cfg.pool.dupe(v) catch return;
            } else if (std.mem.eql(u8, k, "width")) {
                def.width_fraction = std.math.clamp(parseFloat(v) orelse 0.6, 0.1, 1.0);
            } else if (std.mem.eql(u8, k, "height")) {
                def.height_fraction = std.math.clamp(parseFloat(v) orelse 0.6, 0.1, 1.0);
            } else {
                self.addDiag(file, line, "unknown scratchpad property '{s}'", .{k});
                return;
            }
        }
        if (!have_name or def.name.len == 0) {
            self.addDiag(file, line, "scratchpad needs a name", .{});
            return;
        }
        self.cfg.addScratchpad(def) catch {
            self.addDiag(file, line, "too many scratchpads", .{});
        };
    }

    fn addAutostart(self: *Parser, file: []const u8, line: u32, value: []const u8, once: bool) void {
        const cmd = std.mem.trim(u8, value, " \t");
        if (cmd.len == 0) {
            self.addDiag(file, line, "empty autostart command", .{});
            return;
        }
        if (self.cfg.autostart_count >= config.MAX_AUTOSTART) {
            self.addDiag(file, line, "too many autostart entries", .{});
            return;
        }
        self.cfg.autostart[self.cfg.autostart_count] = .{
            .command = self.cfg.pool.dupe(cmd) catch return,
            .once = once,
        };
        self.cfg.autostart_count += 1;
    }
};

pub const MOD_SHIFT: u32 = 1;
pub const MOD_CAPS: u32 = 2;
pub const MOD_CTRL: u32 = 4;
pub const MOD_ALT: u32 = 8;
pub const MOD_MOD2: u32 = 16;
pub const MOD_MOD3: u32 = 32;
pub const MOD_LOGO: u32 = 64;
pub const MOD_MOD5: u32 = 128;

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    var cfg = try Config.initDefault(allocator);
    errdefer cfg.deinit(allocator);
    var parser = Parser{
        .cfg = &cfg,
        .allocator = allocator,
        .vars = std.StringHashMap([]const u8).init(allocator),
    };
    defer parser.vars.deinit();
    parser.parseFile(path, false);
    return cfg;
}

pub fn loadText(allocator: std.mem.Allocator, text: []const u8, filename: []const u8) !Config {
    var cfg = try Config.initDefault(allocator);
    errdefer cfg.deinit(allocator);
    var parser = Parser{
        .cfg = &cfg,
        .allocator = allocator,
        .vars = std.StringHashMap([]const u8).init(allocator),
    };
    defer parser.vars.deinit();
    parser.parseText(text, filename);
    return cfg;
}

fn validateCommandArgs(parser: *Parser, file: []const u8, line: u32, command: config.Command, args: []const u8) bool {
    const trimmed = std.mem.trim(u8, args, " \t");
    switch (command) {
        .spawn, .spawn_shell => {
            if (trimmed.len == 0) {
                parser.addDiag(file, line, "{s} requires a command", .{command.name()});
                return false;
            }
        },
        .view_tag, .toggle_tag, .tag_window, .toggle_tag_window => {
            if (std.mem.eql(u8, trimmed, "next") or std.mem.eql(u8, trimmed, "prev") or
                std.mem.eql(u8, trimmed, "last") or (parseTagIndex(trimmed) != null)) return true;
            parser.addDiag(file, line, "{s} requires a tag number (1-{d}) or next/prev/last", .{ command.name(), config.MAX_TAGS });
            return false;
        },
        .set_layout => {
            if (layout.Kind.fromName(trimmed) == null) {
                parser.addDiag(file, line, "unknown layout '{s}'", .{trimmed});
                return false;
            }
        },
        .toggle_named_scratchpad => {
            if (trimmed.len == 0) {
                parser.addDiag(file, line, "toggle_named_scratchpad requires a name", .{});
                return false;
            }
        },
        .set_key_mode => {
            if (trimmed.len != 0 and !isModeName(trimmed)) {
                parser.addDiag(file, line, "invalid key mode '{s}'", .{trimmed});
                return false;
            }
        },
        .set_master_factor => {
            if (trimmed.len == 0) return true;
            if (parseDeltaString(trimmed) == null and (std.fmt.parseFloat(f32, trimmed) catch null) == null) {
                parser.addDiag(file, line, "invalid master factor '{s}'", .{trimmed});
                return false;
            }
        },
        else => {},
    }
    return true;
}

fn parseDeltaString(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    if (s[0] != '+' and s[0] != '-') return null;
    return std.fmt.parseInt(i32, s, 10) catch null;
}

fn parseTagIndex(s: []const u8) ?u32 {
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    if (n < 1 or n > config.MAX_TAGS) return null;
    return n - 1;
}

fn parseTagMask(s: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(s, "all")) return 0xffff_ffff;
    var mask: u32 = 0;
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const a = std.fmt.parseInt(u32, part[0..dash], 10) catch return null;
            const b = std.fmt.parseInt(u32, part[dash + 1 ..], 10) catch return null;
            if (a < 1 or b > config.MAX_TAGS or a > b) return null;
            var i = a;
            while (i <= b) : (i += 1) mask |= @as(u32, 1) << @intCast(i - 1);
        } else {
            const n = std.fmt.parseInt(u32, part, 10) catch return null;
            if (n < 1 or n > config.MAX_TAGS) return null;
            mask |= @as(u32, 1) << @intCast(n - 1);
        }
    }
    if (mask == 0) return null;
    return mask;
}

fn parseMode(s: []const u8) ?struct { width: i32, height: i32, refresh: i32 } {
    var rest = s;
    const x = std.mem.indexOfScalar(u8, rest, 'x') orelse return null;
    const w = std.fmt.parseInt(i32, rest[0..x], 10) catch return null;
    rest = rest[x + 1 ..];
    var refresh: i32 = 0;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        refresh = std.fmt.parseInt(i32, rest[at + 1 ..], 10) catch return null;
        rest = rest[0..at];
    }
    const h = std.fmt.parseInt(i32, std.mem.trim(u8, rest, " \t"), 10) catch return null;
    if (w <= 0 or h <= 0) return null;
    return .{ .width = w, .height = h, .refresh = refresh * 1000 };
}

fn parsePosition(s: []const u8) ?[2]i32 {
    if (std.mem.indexOfScalar(u8, s, 'x')) |x| {
        const a = std.fmt.parseInt(i32, s[0..x], 10) catch return null;
        const b = std.fmt.parseInt(i32, s[x + 1 ..], 10) catch return null;
        return .{ a, b };
    }
    return null;
}

fn parseTransform(s: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(s, "normal")) return 0;
    if (std.ascii.eqlIgnoreCase(s, "90")) return 1;
    if (std.ascii.eqlIgnoreCase(s, "180")) return 2;
    if (std.ascii.eqlIgnoreCase(s, "270")) return 3;
    if (std.ascii.eqlIgnoreCase(s, "flipped")) return 4;
    if (std.ascii.eqlIgnoreCase(s, "flipped-90")) return 5;
    if (std.ascii.eqlIgnoreCase(s, "flipped-180")) return 6;
    if (std.ascii.eqlIgnoreCase(s, "flipped-270")) return 7;
    return null;
}

fn isModeName(s: []const u8) bool {
    if (s.len == 0 or s.len > 31) return false;
    for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

pub fn parseMods(s_in: []const u8) ?u32 {
    const s = std.mem.trim(u8, s_in, " \t");
    if (s.len == 0 or std.ascii.eqlIgnoreCase(s, "none")) return 0;
    var mods: u32 = 0;
    var it = std.mem.splitScalar(u8, s, '+');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "super") or std.ascii.eqlIgnoreCase(part, "logo") or
            std.ascii.eqlIgnoreCase(part, "mod4") or std.ascii.eqlIgnoreCase(part, "win"))
        {
            mods |= MOD_LOGO;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            mods |= MOD_SHIFT;
        } else if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            mods |= MOD_CTRL;
        } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "mod1")) {
            mods |= MOD_ALT;
        } else if (std.ascii.eqlIgnoreCase(part, "mod2")) {
            mods |= MOD_MOD2;
        } else if (std.ascii.eqlIgnoreCase(part, "mod3")) {
            mods |= MOD_MOD3;
        } else if (std.ascii.eqlIgnoreCase(part, "mod5")) {
            mods |= MOD_MOD5;
        } else {
            return null;
        }
    }
    return mods;
}

fn parseBool(s: []const u8) ?bool {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(t, "true") or std.mem.eql(u8, t, "1") or std.ascii.eqlIgnoreCase(t, "yes") or std.ascii.eqlIgnoreCase(t, "on")) return true;
    if (std.ascii.eqlIgnoreCase(t, "false") or std.mem.eql(u8, t, "0") or std.ascii.eqlIgnoreCase(t, "no") or std.ascii.eqlIgnoreCase(t, "off")) return false;
    return null;
}

fn parseInt(s: []const u8) ?i32 {
    return std.fmt.parseInt(i32, std.mem.trim(u8, s, " \t"), 10) catch null;
}

fn parseFloat(s: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t")) catch null;
}

fn parseColor(file: []const u8, line: u32, parser: *Parser, s: []const u8) ?[4]f32 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0 or t[0] != '#') {
        parser.addDiag(file, line, "invalid color '{s}' (expected #rrggbb or #rrggbbaa)", .{t});
        return null;
    }
    const hex = t[1..];
    if (hex.len != 6 and hex.len != 8) {
        parser.addDiag(file, line, "invalid color '{s}'", .{t});
        return null;
    }
    const rgb = std.fmt.parseInt(u32, hex[0..6], 16) catch {
        parser.addDiag(file, line, "invalid color '{s}'", .{t});
        return null;
    };
    const a: u32 = if (hex.len == 8) (std.fmt.parseInt(u32, hex[6..8], 16) catch 255) else 255;
    const r: f32 = @as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(rgb & 0xff)) / 255.0;
    return .{ r, g, b, @as(f32, @floatFromInt(a)) / 255.0 };
}

fn takeField(s: *[]const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, s.*, ',') orelse {
        const out = s.*;
        s.* = "";
        return std.mem.trim(u8, out, " \t");
    };
    const out = s.*[0..idx];
    s.* = s.*[idx + 1 ..];
    return std.mem.trim(u8, out, " \t");
}

fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#') {
            const at_start = i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t';
            if (at_start and !looksLikeHexColor(line[i..])) return std.mem.trimRight(u8, line[0..i], " \t");
        }
    }
    return line;
}

fn looksLikeHexColor(s: []const u8) bool {
    if (s.len != 7 and s.len != 9) return false;
    for (s[1..]) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn indexOfOutsideQuotes(s: []const u8, needle: u8) ?usize {
    var quote: u8 = 0;
    for (s, 0..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == needle) return i;
    }
    return null;
}

fn isVarName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

test "parse basic configuration" {
    const allocator = std.testing.allocator;
    const text =
        \\mod = Super
        \\terminal = foot
        \\gaps = 10
        \\blur = false
        \\border_color_focused = #112233
        \\bind = SUPER, Return, spawn, foot
        \\bind = SUPER+SHIFT, Q, quit
        \\bind = SUPER, 2, view_tag, 2
        \\mousebind = SUPER, left, moveresize, curmove
        \\axisbind = SUPER, down, view_next_tag
        \\rule = app_id:firefox, floating:1, tags:2|3
        \\scratchpad = name:term, command:foot, app_id:foot
        \\var = browser, firefox
        \\bind = SUPER, B, spawn, $browser
    ;
    var cfg = try loadText(allocator, text, "test.conf");
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), cfg.diag_count);
    try std.testing.expectEqualStrings("foot", cfg.terminal);
    try std.testing.expectEqual(@as(i32, 10), cfg.gap);
    try std.testing.expect(!cfg.effects.blur_enabled);
    try std.testing.expectEqual(@as(usize, 4), cfg.binding_count);
    try std.testing.expectEqualStrings("default", cfg.bindings[0].mode);
    try std.testing.expectEqual(@as(usize, 1), cfg.mouse_binding_count);
    try std.testing.expectEqual(@as(usize, 1), cfg.axis_binding_count);
    try std.testing.expectEqual(@as(usize, 1), cfg.rule_count);
    try std.testing.expectEqual(@as(usize, 1), cfg.scratchpad_count);
    try std.testing.expectEqual(@as(u32, 0b110), cfg.rules[0].tags.?);
    try std.testing.expectEqualStrings("firefox", cfg.bindings[3].args);
}

test "unknown option is reported with line number" {
    const allocator = std.testing.allocator;
    var cfg = try loadText(allocator, "mod = Super\nnonsense = 1\n", "bad.conf");
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), cfg.diag_count);
    try std.testing.expectEqual(@as(u32, 2), cfg.diags[0].line);
    try std.testing.expect(std.mem.indexOf(u8, cfg.diags[0].message, "unknown option") != null);
}

test "tag mask parsing" {
    try std.testing.expectEqual(@as(?u32, 0b101), parseTagMask("1|3"));
    try std.testing.expectEqual(@as(?u32, 0b1110), parseTagMask("2-4"));
    try std.testing.expectEqual(@as(?u32, 0xffffffff), parseTagMask("all"));
    try std.testing.expect(parseTagMask("0") == null);
    try std.testing.expect(parseTagMask("40") == null);
}

test "comment stripping respects quoted shell commands" {
    try std.testing.expectEqualStrings("bind = SUPER, Q, spawn, sh -c 'echo #hi'", stripComment("bind = SUPER, Q, spawn, sh -c 'echo #hi' # comment"));
    try std.testing.expectEqualStrings("gaps = 5", stripComment("gaps = 5 # comment"));
}

test "key mode sections scope bindings" {
    const allocator = std.testing.allocator;
    const text =
        \\mode = resize
        \\bind = SUPER, H, set_master_factor, -0.05
        \\bindl = SUPER, Escape, set_key_mode, default
        \\mode = default
        \\bind = SUPER, Return, spawn, foot
    ;
    var cfg = try loadText(allocator, text, "modes.conf");
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), cfg.diag_count);
    try std.testing.expectEqual(@as(usize, 3), cfg.binding_count);
    try std.testing.expectEqualStrings("resize", cfg.bindings[0].mode);
    try std.testing.expectEqualStrings("resize", cfg.bindings[1].mode);
    try std.testing.expect(cfg.bindings[1].allow_locked);
    try std.testing.expectEqualStrings("default", cfg.bindings[2].mode);
}

test "invalid key mode is rejected" {
    const allocator = std.testing.allocator;
    var cfg = try loadText(allocator, "mode = bad mode\n", "badmode.conf");
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), cfg.diag_count);
    try std.testing.expect(std.mem.indexOf(u8, cfg.diags[0].message, "invalid key mode") != null);
}

test "lock command is parsed" {
    const allocator = std.testing.allocator;
    var cfg = try loadText(allocator, "lock_command = swaylock -f\n", "lock.conf");
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), cfg.diag_count);
    try std.testing.expectEqualStrings("swaylock -f", cfg.lock_command);
}
