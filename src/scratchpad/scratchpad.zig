//! Named and Sway-style scratchpads.

const std = @import("std");
const c = @import("../bindings.zig").c;
const log = @import("../util/log.zig");
const rules = @import("../window/rules.zig");
const Server = @import("../core/server.zig").Server;
const Window = @import("../core/window.zig").Window;

pub const Manager = struct {
    server: *Server,

    pub fn init(server: *Server) Manager {
        return .{ .server = server };
    }

    pub fn toggle(self: *Manager) void {
        // Sway-style scratchpad: every hidden window with an empty scratchpad
        // name. If any is visible, hide all of them; otherwise show the most
        // recently focused one.
        var any_visible = false;
        for (self.server.windows.items) |w| {
            if (w.scratchpad_name) |n| {
                if (n.len == 0 and w.scratchpad_visible) any_visible = true;
            }
        }
        if (any_visible) {
            for (self.server.windows.items) |w| {
                if (w.scratchpad_name) |n| {
                    if (n.len == 0) self.hide(w);
                }
            }
            return;
        }
        var best: ?*Window = null;
        for (self.server.focus_stack.items) |w| {
            if (w.scratchpad_name) |n| {
                if (n.len == 0 and w.mapped) {
                    best = w;
                    break;
                }
            }
        }
        if (best == null) {
            for (self.server.windows.items) |w| {
                if (w.scratchpad_name) |n| {
                    if (n.len == 0 and w.mapped) {
                        best = w;
                        break;
                    }
                }
            }
        }
        if (best) |w| self.show(w) else log.info("scratchpad is empty", .{});
    }

    pub fn toggleNamed(self: *Manager, name: []const u8) void {
        for (self.server.windows.items) |w| {
            if (w.scratchpad_name) |n| {
                if (std.mem.eql(u8, n, name)) {
                    if (w.scratchpad_visible) self.hide(w) else self.show(w);
                    return;
                }
            }
        }
        // Launch the configured command. The new window is matched by its
        // application id on map and starts hidden.
        for (self.server.config.scratchpads[0..self.server.config.scratchpad_count]) |def| {
            if (std.mem.eql(u8, def.name, name)) {
                if (def.command.len == 0) {
                    log.warn("scratchpad '{s}' has no command", .{name});
                    return;
                }
                self.server.spawn(def.command);
                return;
            }
        }
        log.warn("unknown scratchpad '{s}'", .{name});
    }

    pub fn show(self: *Manager, w: *Window) void {
        const out = self.server.focusedOrFirstOutput() orelse return;
        if (w.output != out) {
            w.output = out;
            w.tags = out.tags.active;
        }
        w.scratchpad_visible = true;
        w.floating = true;
        w.overlay = true;
        w.minimized = false;
        const frac = self.fractionFor(w);
        const area = out.usable;
        const width: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(area.width)) * frac[0]));
        const height: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(area.height)) * frac[1]));
        w.float_geom = .{
            .x = area.x + @divTrunc(area.width - width, 2),
            .y = area.y + @divTrunc(area.height - height, 2),
            .width = width,
            .height = height,
        };
        w.setVisible(true);
        w.applyGeometry(w.float_geom, true);
        w.raise();
        w.pending_open = true;
        self.server.arrangeAll();
        self.server.focusWindow(w, out);
    }

    pub fn hide(self: *Manager, w: *Window) void {
        w.scratchpad_visible = false;
        const was_focused = self.server.focused_window == w;
        self.server.arrangeAll();
        if (was_focused) self.server.focusTopWindow();
    }

    fn fractionFor(self: *Manager, w: *Window) [2]f32 {
        if (w.scratchpad_name) |name| {
            for (self.server.config.scratchpads[0..self.server.config.scratchpad_count]) |def| {
                if (std.mem.eql(u8, def.name, name)) return .{ def.width_fraction, def.height_fraction };
            }
        }
        return .{ 0.6, 0.6 };
    }
};
