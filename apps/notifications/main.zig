//! Kairo Notifications — the session's org.freedesktop.Notifications daemon.
//!
//! A separate Wayland client: it owns the D-Bus name, renders toasts on a
//! layer-shell overlay with cairo, queues replacements and expires them by
//! timeout, and supports action buttons clicked with the pointer. Like every
//! Kairo desktop component it is an ordinary client: a crash here can never
//! take down the compositor.
//!
//! Not implemented (documented gaps): notification icons (text-only toasts),
//! persistent history, per-app settings and inline replies. Capabilities are
//! advertised honestly through GetCapabilities.

const std = @import("std");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("dbus/dbus.h");
    @cInclude("cairo/cairo.h");
    @cInclude("time.h");
    @cInclude("poll.h");
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
});

const VERSION = "0.5.0";
const TOAST_WIDTH: u32 = 360;
const TOAST_HEIGHT: u32 = 140;
const TOAST_MAX_LINES: usize = 4;
const DEFAULT_TIMEOUT_MS: i32 = 5000;
const MAX_QUEUE: usize = 8;
const MAX_TEXT: usize = 512;

const Urgency = enum(u8) { low = 0, normal = 1, critical = 2 };

const Notification = struct {
    id: u32,
    app_name: [64]u8 = [_]u8{0} ** 64,
    app_name_len: usize = 0,
    summary: [MAX_TEXT]u8 = [_]u8{0} ** MAX_TEXT,
    summary_len: usize = 0,
    body: [MAX_TEXT]u8 = [_]u8{0} ** MAX_TEXT,
    body_len: usize = 0,
    urgency: Urgency = .normal,
    expire_at: i64 = 0, // milliTimestamp; 0 = sticky
    actions: [4][64]u8 = .{[_]u8{0} ** 64} ** 4,
    action_count: usize = 0,
    action_key_len: usize = 0,
    action_label_len: usize = 0,

    fn appName(self: *const Notification) []const u8 {
        return self.app_name[0..self.app_name_len];
    }
    fn summaryText(self: *const Notification) []const u8 {
        return self.summary[0..self.summary_len];
    }
    fn bodyText(self: *const Notification) []const u8 {
        return self.body[0..self.body_len];
    }

    fn actionKey(self: *const Notification) []const u8 {
        return self.actions[0][0..self.action_key_len];
    }

    fn actionLabel(self: *const Notification) []const u8 {
        if (self.action_count >= 2) return self.actions[1][0..self.action_label_len];
        return self.actions[0][0..self.action_key_len];
    }
};

const Config = struct {
    dnd: bool = false,
    default_timeout_ms: i32 = DEFAULT_TIMEOUT_MS,
    max_width_chars: usize = 60,

    fn load(allocator: std.mem.Allocator) Config {
        var cfg = Config{};
        const home = std.posix.getenv("HOME") orelse "/root";
        const path = std.fs.path.join(allocator, &.{ home, ".config", "kairo", "notifications.conf" }) catch return cfg;
        defer allocator.free(path);
        const text = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024) catch return cfg;
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "dnd")) {
                cfg.dnd = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "default_timeout_ms")) {
                const n = std.fmt.parseInt(i32, value, 10) catch continue;
                if (n >= 0) cfg.default_timeout_ms = n;
            } else if (std.mem.eql(u8, key, "max_width_chars")) {
                const n = std.fmt.parseInt(usize, value, 10) catch continue;
                if (n > 10 and n < 400) cfg.max_width_chars = n;
            }
        }
        return cfg;
    }

    fn reload(self: *Config, allocator: std.mem.Allocator) void {
        self.* = Config.load(allocator);
    }
};

// ---------------------------------------------------------------------------
// D-Bus
// ---------------------------------------------------------------------------

const DBus = struct {
    app: *App,
    conn: ?*c.DBusConnection = null,
    fd: c_int = -1,
    next_id: u32 = 1,
    got_name: bool = false,

    const IFACE = "org.freedesktop.Notifications";
    const PATH = "/org/freedesktop/Notifications";

    fn init(app: *App) !*DBus {
        const self = try app.allocator.create(DBus);
        errdefer app.allocator.destroy(self);
        self.* = .{ .app = app };
        // DBusError translates as an opaque type; give it generous aligned
        // zeroed storage (libdbus' DBusError is a small fixed struct).
        var err_storage: [128]u8 align(8) = [_]u8{0} ** 128;
        const err: ?*c.DBusError = @ptrCast(@alignCast(&err_storage));
        _ = c.dbus_error_init(err);
        defer c.dbus_error_free(err);
        self.conn = c.dbus_bus_get(c.DBUS_BUS_SESSION, err);
        if (self.conn == null) return error.DBusConnectFailed;
        _ = c.dbus_connection_set_exit_on_disconnect(self.conn, 0);

        const flags: u32 = c.DBUS_NAME_FLAG_REPLACE_EXISTING | c.DBUS_NAME_FLAG_ALLOW_REPLACEMENT;
        const result = c.dbus_bus_request_name(self.conn, IFACE, flags, err);
        if (result != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER and
            result != c.DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER)
        {
            return error.DBusNameTaken;
        }
        self.got_name = true;
        var fd: c_int = -1;
        _ = c.dbus_connection_get_unix_fd(self.conn, &fd);
        self.fd = fd;
        return self;
    }

    /// Handle one message if any is queued.
    fn handleOne(self: *DBus) void {
        const msg: ?*c.DBusMessage = c.dbus_connection_pop_message(self.conn);
        if (msg == null) return;
        const m = msg.?;
        defer c.dbus_message_unref(msg);
        const msg_type = c.dbus_message_get_type(m);
        if (msg_type == c.DBUS_MESSAGE_TYPE_METHOD_CALL) {
            const iface = c.dbus_message_get_interface(m);
            const member = c.dbus_message_get_member(m);
            const iface_s: []const u8 = if (iface != null) std.mem.span(iface) else "";
            const member_s: []const u8 = if (member != null) std.mem.span(member) else "";
            if (std.mem.eql(u8, iface_s, IFACE)) {
                if (std.mem.eql(u8, member_s, "Notify")) {
                    self.handleNotify(m);
                } else if (std.mem.eql(u8, member_s, "CloseNotification")) {
                    self.handleClose(m);
                } else if (std.mem.eql(u8, member_s, "GetCapabilities")) {
                    self.handleGetCapabilities(m);
                } else if (std.mem.eql(u8, member_s, "GetServerInformation")) {
                    self.handleGetServerInformation(m);
                } else {
                    self.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
                }
            } else if (std.mem.eql(u8, iface_s, "org.freedesktop.DBus.Introspectable")) {
                if (std.mem.eql(u8, member_s, "Introspect")) {
                    self.handleIntrospect(m);
                } else {
                    self.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
                }
            } else if (std.mem.eql(u8, iface_s, "org.freedesktop.DBus.Peer")) {
                self.replyError(m, "org.freedesktop.DBus.Error.NotSupported", "Peer not supported");
            } else {
                self.replyError(m, "org.freedesktop.DBus.Error.UnknownInterface", "Unknown interface");
            }
        }
    }

    fn iterString(it: *c.DBusMessageIter, out: *[]const u8) bool {
        var value: [*c]const u8 = null;
        if (c.dbus_message_iter_get_arg_type(it) != c.DBUS_TYPE_STRING) return false;
        c.dbus_message_iter_get_basic(it, @ptrCast(&value));
        if (value == null) return false;
        out.* = std.mem.span(value);
        return true;
    }

    fn handleNotify(self: *DBus, m: *c.DBusMessage) void {
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(m, &it) == 0) {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify needs arguments");
            return;
        }
        var app_name: []const u8 = "";
        if (!iterString(&it, &app_name)) {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify: app_name");
            return;
        }
        _ = c.dbus_message_iter_next(&it);
        if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_UINT32) {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify: replaces_id");
            return;
        }
        var replaces: u32 = 0;
        c.dbus_message_iter_get_basic(&it, @ptrCast(&replaces));
        _ = c.dbus_message_iter_next(&it);
        var icon: []const u8 = "";
        if (!iterString(&it, &icon)) {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify: app_icon");
            return;
        }
        if (icon.len > 0) {
            // text-only toasts: icon names are not resolved yet
            std.log.scoped(.kairo_notifications).debug("icon '{s}' ignored", .{icon});
        }
        _ = c.dbus_message_iter_next(&it);
        var summary: []const u8 = "";
        if (!iterString(&it, &summary)) {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify: summary");
            return;
        }
        _ = c.dbus_message_iter_next(&it);
        var body: []const u8 = "";
        if (!iterString(&it, &body)) {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify: body");
            return;
        }
        _ = c.dbus_message_iter_next(&it);

        // actions: array of strings (key, label, ...)
        var actions: [4][]const u8 = undefined;
        var action_count: usize = 0;
        if (c.dbus_message_iter_get_arg_type(&it) == c.DBUS_TYPE_ARRAY) {
            var sub: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&it, &sub);
            while (c.dbus_message_iter_get_arg_type(&sub) == c.DBUS_TYPE_STRING) {
                var label: []const u8 = "";
                if (!iterString(&sub, &label)) break;
                if (action_count < actions.len) {
                    actions[action_count] = label;
                    action_count += 1;
                }
                if (c.dbus_message_iter_next(&sub) == 0) break;
            }
            _ = c.dbus_message_iter_next(&it);
        } else {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify: actions");
            return;
        }

        // hints: dict string->variant
        var urgency: Urgency = .normal;
        if (c.dbus_message_iter_get_arg_type(&it) == c.DBUS_TYPE_ARRAY) {
            var sub: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&it, &sub);
            while (c.dbus_message_iter_get_arg_type(&sub) == c.DBUS_TYPE_DICT_ENTRY) {
                var entry: c.DBusMessageIter = undefined;
                c.dbus_message_iter_recurse(&sub, &entry);
                var key: []const u8 = "";
                if (iterString(&entry, &key)) {
                    if (c.dbus_message_iter_next(&entry) != 0 and
                        c.dbus_message_iter_get_arg_type(&entry) == c.DBUS_TYPE_VARIANT)
                    {
                        var variant: c.DBusMessageIter = undefined;
                        c.dbus_message_iter_recurse(&entry, &variant);
                        if (std.mem.eql(u8, key, "urgency") and
                            c.dbus_message_iter_get_arg_type(&variant) == c.DBUS_TYPE_BYTE)
                        {
                            var value: u8 = 0;
                            c.dbus_message_iter_get_basic(&variant, @ptrCast(&value));
                            if (value <= 2) urgency = @enumFromInt(value);
                        }
                    }
                }
                if (c.dbus_message_iter_next(&sub) == 0) break;
            }
            _ = c.dbus_message_iter_next(&it);
        } else {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "Notify: hints");
            return;
        }
        var timeout: i32 = 0;
        if (c.dbus_message_iter_get_arg_type(&it) == c.DBUS_TYPE_INT32) {
            c.dbus_message_iter_get_basic(&it, @ptrCast(&timeout));
        }

        const app = self.app;
        // Do-not-disturb: only critical notifications are shown.
        if (app.config.dnd and urgency != .critical) {
            self.replyUint(m, 0);
            return;
        }
        const timeout_ms: i32 = if (timeout < 0) app.config.default_timeout_ms else timeout;
        const expire_at: i64 = if (timeout_ms > 0)
            std.time.milliTimestamp() + @as(i64, timeout_ms)
        else
            0;

        if (replaces != 0) {
            for (app.queue.items) |existing| {
                if (existing.id == replaces) {
                    applyNotification(existing, app_name, summary, body, urgency, expire_at, replaces, &actions, action_count);
                    self.replyUint(m, replaces);
                    app.redrawAll();
                    return;
                }
            }
        }
        if (app.queue.items.len >= MAX_QUEUE) {
            self.app.removeNote(0, 1); // oldest expired to make room
        }
        const id = self.next_id;
        self.next_id += 1;
        const stored = app.allocator.create(Notification) catch {
            self.replyError(m, "org.freedesktop.DBus.Error.NoMemory", "out of memory");
            return;
        };
        stored.* = .{ .id = id };
        applyNotification(stored, app_name, summary, body, urgency, expire_at, id, &actions, action_count);
        app.queue.append(app.allocator, stored) catch {
            app.allocator.destroy(stored);
            self.replyError(m, "org.freedesktop.DBus.Error.NoMemory", "out of memory");
            return;
        };
        app.redrawAll();
        self.replyUint(m, id);
    }

    fn handleClose(self: *DBus, m: *c.DBusMessage) void {
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(m, &it) == 0 or
            c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_UINT32)
        {
            self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "CloseNotification needs a uint32");
            return;
        }
        var id: u32 = 0;
        c.dbus_message_iter_get_basic(&it, @ptrCast(&id));
        self.app.closeById(id);
        self.replyEmpty(m);
    }

    fn handleGetCapabilities(self: *DBus, m: *c.DBusMessage) void {
        const reply = c.dbus_message_new_method_return(m);
        if (reply == null) return;
        defer c.dbus_message_unref(reply);
        var it: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_init_append(reply, &it);
        var sub: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "s", &sub);
        const caps = [_][]const u8{ "actions", "body" };
        for (caps) |cap| {
            const z = std.fmt.allocPrintSentinel(self.app.allocator, "{s}", .{cap}, 0) catch continue;
            defer self.app.allocator.free(z);
            _ = c.dbus_message_iter_append_basic(&sub, c.DBUS_TYPE_STRING, @ptrCast(&z.ptr));
        }
        _ = c.dbus_message_iter_close_container(&it, &sub);
        _ = self.sendReply(reply);
    }

    fn handleGetServerInformation(self: *DBus, m: *c.DBusMessage) void {
        const reply = c.dbus_message_new_method_return(m);
        if (reply == null) return;
        defer c.dbus_message_unref(reply);
        var it: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_init_append(reply, &it);
        const name = "Kairo";
        const vendor = "Kairo contributors";
        const version = VERSION;
        const spec = "1.2";
        for ([_][]const u8{ name, vendor, version, spec }) |s| {
            const z = std.fmt.allocPrintSentinel(self.app.allocator, "{s}", .{s}, 0) catch return;
            defer self.app.allocator.free(z);
            _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&z.ptr));
        }
        _ = self.sendReply(reply);
    }

    fn handleIntrospect(self: *DBus, m: *c.DBusMessage) void {
        const reply = c.dbus_message_new_method_return(m);
        if (reply == null) return;
        defer c.dbus_message_unref(reply);
        const xml =
            \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
            \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
            \\<node>
            \\  <interface name="org.freedesktop.DBus.Introspectable">
            \\    <method name="Introspect"><arg name="data" direction="out" type="s"/></method>
            \\  </interface>
            \\  <interface name="org.freedesktop.Notifications">
            \\    <method name="Notify">
            \\      <arg name="app_name" direction="in" type="s"/>
            \\      <arg name="replaces_id" direction="in" type="u"/>
            \\      <arg name="app_icon" direction="in" type="s"/>
            \\      <arg name="summary" direction="in" type="s"/>
            \\      <arg name="body" direction="in" type="s"/>
            \\      <arg name="actions" direction="in" type="as"/>
            \\      <arg name="hints" direction="in" type="a{sv}"/>
            \\      <arg name="expire_timeout" direction="in" type="i"/>
            \\      <arg name="id" direction="out" type="u"/>
            \\    </method>
            \\    <method name="CloseNotification"><arg name="id" direction="in" type="u"/></method>
            \\    <method name="GetCapabilities"><arg name="capabilities" direction="out" type="as"/></method>
            \\    <method name="GetServerInformation">
            \\      <arg name="name" direction="out" type="s"/>
            \\      <arg name="vendor" direction="out" type="s"/>
            \\      <arg name="version" direction="out" type="s"/>
            \\      <arg name="spec_version" direction="out" type="s"/>
            \\    </method>
            \\    <signal name="NotificationClosed"><arg name="id" type="u"/><arg name="reason" type="u"/></signal>
            \\    <signal name="ActionInvoked"><arg name="id" type="u"/><arg name="action_key" type="s"/></signal>
            \\  </interface>
            \\</node>
        ;
        var it: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_init_append(reply, &it);
        const z = std.fmt.allocPrintSentinel(self.app.allocator, "{s}", .{xml}, 0) catch return;
        defer self.app.allocator.free(z);
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&z.ptr));
        _ = self.sendReply(reply);
    }

    fn replyUint(self: *DBus, m: *c.DBusMessage, id: u32) void {
        const reply = c.dbus_message_new_method_return(m);
        if (reply == null) return;
        defer c.dbus_message_unref(reply);
        var it: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_init_append(reply, &it);
        var v: u32 = id;
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_UINT32, @ptrCast(&v));
        _ = self.sendReply(reply);
    }

    fn replyEmpty(self: *DBus, m: *c.DBusMessage) void {
        const reply = c.dbus_message_new_method_return(m);
        if (reply == null) return;
        defer c.dbus_message_unref(reply);
        _ = self.sendReply(reply);
    }

    fn replyError(self: *DBus, m: *c.DBusMessage, name: []const u8, text: []const u8) void {
        const name_z = std.fmt.allocPrintSentinel(self.app.allocator, "{s}", .{name}, 0) catch return;
        defer self.app.allocator.free(name_z);
        const text_z = std.fmt.allocPrintSentinel(self.app.allocator, "{s}", .{text}, 0) catch return;
        defer self.app.allocator.free(text_z);
        const reply = c.dbus_message_new_error(m, name_z.ptr, text_z.ptr);
        if (reply == null) return;
        defer c.dbus_message_unref(reply);
        _ = self.sendReply(reply);
    }

    fn sendReply(self: *DBus, reply_opt: ?*c.DBusMessage) bool {
        const reply = reply_opt orelse return false;
        const conn = self.conn orelse return false;
        return c.dbus_connection_send(conn, reply, null) != 0;
    }

    /// Emit NotificationClosed (reason: 2 = dismissed by call, 1 = expired,
    /// 3 = closed by the user).
    fn emitClosed(self: *DBus, id: u32, reason: u32) void {
        const conn = self.conn orelse return;
        const msg = c.dbus_message_new_signal(PATH, IFACE, "NotificationClosed");
        if (msg == null) return;
        defer c.dbus_message_unref(msg);
        var it: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_init_append(msg, &it);
        var id_v: u32 = id;
        var reason_v: u32 = reason;
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_UINT32, @ptrCast(&id_v));
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_UINT32, @ptrCast(&reason_v));
        _ = c.dbus_connection_send(conn, msg, null);
    }

    /// Emit ActionInvoked for the first labelled action of a notification.
    fn emitAction(self: *DBus, id: u32, action_key: []const u8) void {
        const conn = self.conn orelse return;
        const msg = c.dbus_message_new_signal(PATH, IFACE, "ActionInvoked");
        if (msg == null) return;
        defer c.dbus_message_unref(msg);
        var it: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_init_append(msg, &it);
        var id_v: u32 = id;
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_UINT32, @ptrCast(&id_v));
        const z = std.fmt.allocPrintSentinel(self.app.allocator, "{s}", .{action_key}, 0) catch return;
        defer self.app.allocator.free(z);
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&z.ptr));
        _ = c.dbus_connection_send(conn, msg, null);
    }

    fn flush(self: *DBus) void {
        if (self.conn) |conn| _ = c.dbus_connection_flush(conn);
    }
};

fn applyNotification(target: *Notification, app_name: []const u8, summary: []const u8, body: []const u8, urgency: Urgency, expire_at: i64, id: u32, actions: []const []const u8, action_count: usize) void {
    target.id = id;
    target.app_name_len = @min(app_name.len, target.app_name.len);
    @memcpy(target.app_name[0..target.app_name_len], app_name[0..target.app_name_len]);
    target.summary_len = @min(summary.len, target.summary.len);
    @memcpy(target.summary[0..target.summary_len], summary[0..target.summary_len]);
    target.body_len = @min(body.len, target.body.len);
    @memcpy(target.body[0..target.body_len], body[0..target.body_len]);
    target.urgency = urgency;
    target.expire_at = expire_at;
    target.action_count = @min(action_count, target.actions.len);
    // actions come in (key, label) pairs; store the first pair
    if (target.action_count >= 1) {
        target.action_key_len = @min(actions[0].len, target.actions[0].len);
        @memcpy(target.actions[0][0..target.action_key_len], actions[0][0..target.action_key_len]);
    }
    if (target.action_count >= 2) {
        target.action_label_len = @min(actions[1].len, target.actions[1].len);
        @memcpy(target.actions[1][0..target.action_label_len], actions[1][0..target.action_label_len]);
    }
}

// ---------------------------------------------------------------------------
// Toast rendering (layer-shell overlay)
// ---------------------------------------------------------------------------

const Toast = struct {
    app: *App,
    surface: *c.struct_wl_surface,
    layer_surface: *c.struct_zwlr_layer_surface_v1,
    width: u32 = TOAST_WIDTH,
    height: u32 = 120,
    scale: i32 = 1,
    buffers: [2]?*c.struct_wl_buffer = .{ null, null },
    cairo_surfaces: [2]?*c.cairo_surface_t = .{ null, null },
    crs: [2]?*c.cairo_t = .{ null, null },
    busy: [2]bool = .{ false, false },
    next_index: usize = 0,
    configured: bool = false,
    configure_listener: c.struct_zwlr_layer_surface_v1_listener,
    closed_listener: c.struct_zwlr_layer_surface_v1_listener,
    output_listener: c.struct_wl_output_listener,
    buffer_listener: c.struct_wl_buffer_listener,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_inside: bool = false,
    // Action button geometry in surface coordinates (only button 0 supported).
    action_rect: [4]f64 = .{ 0, 0, 0, 0 },

    fn create(app: *App, output: *c.struct_wl_output) !*Toast {
        const compositor = app.compositor orelse return error.NoCompositor;
        const layer_shell = app.layer_shell orelse return error.NoLayerShell;
        const surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(surface);
        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            surface,
            output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "kairo-notification",
        ) orelse return error.LayerSurfaceCreateFailed;
        errdefer c.zwlr_layer_surface_v1_destroy(layer_surface);
        const self = try app.allocator.create(Toast);
        errdefer app.allocator.destroy(self);
        self.* = .{
            .app = app,
            .surface = surface,
            .layer_surface = layer_surface,
            .configure_listener = .{ .configure = handleConfigure, .closed = handleClosed },
            .closed_listener = undefined,
            .output_listener = .{
                .geometry = outputGeometry,
                .mode = outputMode,
                .done = outputDone,
                .scale = outputScale,
                .name = outputName,
                .description = outputDescription,
            },
            .buffer_listener = .{ .release = handleBufferRelease },
        };
        _ = c.zwlr_layer_surface_v1_add_listener(layer_surface, &self.configure_listener, self);
        _ = c.wl_output_add_listener(output, &self.output_listener, self);
        c.zwlr_layer_surface_v1_set_size(layer_surface, TOAST_WIDTH, TOAST_HEIGHT);
        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_exclusive_zone(self.layer_surface, -1);
        c.zwlr_layer_surface_v1_set_margin(layer_surface, 48, 12, 12, 12);
        c.wl_surface_commit(surface);
        app.toasts.append(app.allocator, self) catch {
            c.zwlr_layer_surface_v1_destroy(layer_surface);
            c.wl_surface_destroy(surface);
            app.allocator.destroy(self);
            return error.OutOfMemory;
        };
        return self;
    }

    fn destroy(self: *Toast) void {
        c.zwlr_layer_surface_v1_destroy(self.layer_surface);
        c.wl_surface_destroy(self.surface);
        for (0..2) |i| {
            if (self.crs[i]) |cr| c.cairo_destroy(cr);
            if (self.cairo_surfaces[i]) |s| c.cairo_surface_destroy(s);
            if (self.buffers[i]) |b| c.wl_buffer_destroy(b);
        }
        self.app.allocator.destroy(self);
    }

    fn draw(self: *Toast) void {
        const app = self.app;
        const note = app.currentNotification() orelse {
            // Nothing to show: hide the surface by attaching nothing.
            c.wl_surface_attach(self.surface, null, 0, 0);
            c.wl_surface_commit(self.surface);
            return;
        };
        if (!self.configured) return;
        const scale: u32 = @intCast(@max(1, self.scale));
        const pixel_width = self.width * scale;
        // Fixed height: summary + up to 4 body lines + an action row.
        self.height = TOAST_HEIGHT;
        self.ensureBuffers(pixel_width, TOAST_HEIGHT * scale) catch return;
        const lines = wrapLines(self.crs[0] orelse return, note.bodyText(), @as(f64, @floatFromInt(self.width)) - 32);

        var index: ?usize = null;
        for (0..2) |i| {
            const candidate = (self.next_index + i) % 2;
            if (!self.busy[candidate]) {
                index = candidate;
                break;
            }
        }
        const idx = index orelse return;
        self.next_index = (idx + 1) % 2;
        const cr = self.crs[idx] orelse return;
        const s: f64 = @floatFromInt(scale);

        c.cairo_save(cr);
        c.cairo_scale(cr, s, s);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_rgba(cr, 0.045, 0.052, 0.070, 0.97);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

        const urg_color: [4]f64 = switch (note.urgency) {
            .low => .{ 0.55, 0.75, 0.95, 1.0 },
            .normal => .{ 0.25, 0.55, 0.90, 1.0 },
            .critical => .{ 0.90, 0.35, 0.30, 1.0 },
        };
        c.cairo_set_source_rgba(cr, urg_color[0], urg_color[1], urg_color[2], 1.0);
        c.cairo_rectangle(cr, 0, 0, 4, @floatFromInt(self.height));
        c.cairo_fill(cr);
        c.cairo_set_source_rgba(cr, urg_color[0], urg_color[1], urg_color[2], 0.6);
        c.cairo_rectangle(cr, 0, @as(f64, @floatFromInt(self.height)) - 1, @floatFromInt(self.width), 1);
        c.cairo_fill(cr);

        c.cairo_select_font_face(cr, "sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(cr, 12.5);
        drawTextN(cr, 14, 26, note.appName(), .{ 0.85, 0.88, 0.95, 0.8 });
        drawTextN(cr, 14 + appTextWidth(self.crs[0], note.appName()) + 8, 26, note.summaryText(), .{ 0.95, 0.97, 1.0, 1.0 });

        c.cairo_select_font_face(cr, "sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(cr, 11.5);
        var y: f64 = 44;
        var count: usize = 0;
        while (count < @min(lines.items.len, TOAST_MAX_LINES)) : (count += 1) {
            drawTextN(cr, 14, y, lines.items[count], .{ 0.80, 0.85, 0.92, 1.0 });
            y += 17;
        }

        if (note.action_count > 0) {
            const label = if (note.action_count > 1) note.actions[1] else note.actions[0];
            var label_buf: [64]u8 = undefined;
            const n = @min(label.len, label_buf.len - 1);
            @memcpy(label_buf[0..n], label[0..n]);
            label_buf[n] = 0;
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(cr, label_buf[0..n :0].ptr, &ext);
            const bw = ext.x_advance + 20;
            const bh: f64 = 24;
            const bx = @as(f64, @floatFromInt(self.width)) - bw - 12;
            const by = @as(f64, @floatFromInt(self.height)) - bh - 10;
            c.cairo_set_source_rgba(cr, 0.25, 0.55, 0.90, 1.0);
            c.cairo_rectangle(cr, bx, by, bw, bh);
            c.cairo_fill(cr);
            c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
            c.cairo_move_to(cr, bx + 10, by + 16);
            c.cairo_show_text(cr, label_buf[0..n :0].ptr);
            self.action_rect = .{ bx, by, bw, bh };
        } else {
            self.action_rect = .{ 0, 0, 0, 0 };
        }
        c.cairo_restore(cr);

        c.wl_surface_attach(self.surface, self.buffers[idx], 0, 0);
        c.wl_surface_damage_buffer(self.surface, 0, 0, @intCast(pixel_width), @intCast(self.height * scale));
        c.wl_surface_commit(self.surface);
        self.busy[idx] = true;
    }

    const Lines = std.ArrayList([]const u8);

    fn wrapLines(cr: ?*c.cairo_t, text: []const u8, max_width: f64) Lines {
        var lines = Lines.empty;
        var start: usize = 0;
        var i: usize = 0;
        var last_space: usize = 0;
        while (i <= text.len) {
            if (i == text.len or text[i] == '\n') {
                lines.append(std.heap.page_allocator, text[start..i]) catch return lines;
                start = i + 1;
                last_space = start;
                i += 1;
                continue;
            }
            if (text[i] == ' ') last_space = i;
            // Measure current word-wrapped segment periodically.
            if (i - start > 8) {
                const seg = text[start .. i + 1];
                if (appTextWidth(cr, seg) > max_width and last_space > start) {
                    lines.append(std.heap.page_allocator, text[start..last_space]) catch return lines;
                    start = last_space + 1;
                }
            }
            i += 1;
        }
        return lines;
    }

    fn ensureBuffers(self: *Toast, pixel_width: u32, pixel_height: u32) !void {
        if (self.buffers[0] != null and self.buffers[1] != null and
            self.cairo_surfaces[0] != null and self.cairo_surfaces[1] != null)
        {
            const w = c.cairo_image_surface_get_width(self.cairo_surfaces[0].?);
            const h = c.cairo_image_surface_get_height(self.cairo_surfaces[0].?);
            if (w == @as(c_int, @intCast(pixel_width)) and h == @as(c_int, @intCast(pixel_height))) {
                // Height changed: grow the configure height to match content.
                c.zwlr_layer_surface_v1_set_size(self.layer_surface, self.width, pixel_height / @as(u32, @intCast(@max(1, self.scale))));
                return;
            }
        }
        for (0..2) |i| {
            if (self.crs[i]) |cr| c.cairo_destroy(cr);
            if (self.cairo_surfaces[i]) |s| c.cairo_surface_destroy(s);
            if (self.buffers[i]) |b| c.wl_buffer_destroy(b);
            self.crs[i] = null;
            self.cairo_surfaces[i] = null;
            self.buffers[i] = null;
            self.busy[i] = false;
        }
        const stride: i32 = @intCast(pixel_width * 4);
        const size: usize = @intCast(stride * @as(i32, @intCast(pixel_height)));
        for (0..2) |i| {
            const fd = c.memfd_create("kairo-notification", 0);
            if (fd < 0) return error.ShmFdFailed;
            defer _ = c.close(fd);
            if (c.ftruncate(fd, @intCast(size)) != 0) return error.ShmFtruncateFailed;
            const data = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
            if (data == c.MAP_FAILED) return error.ShmMapFailed;
            @memset(@as([*]u8, @ptrCast(data))[0..size], 0);
            const pool = c.wl_shm_create_pool(self.app.shm orelse return error.NoShm, fd, @intCast(size)) orelse return error.ShmPoolFailed;
            const buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(pixel_width), @intCast(pixel_height), stride, c.WL_SHM_FORMAT_ARGB8888) orelse {
                c.wl_shm_pool_destroy(pool);
                return error.ShmBufferFailed;
            };
            c.wl_shm_pool_destroy(pool);
            const cairo_surface = c.cairo_image_surface_create_for_data(
                @ptrCast(data),
                c.CAIRO_FORMAT_ARGB32,
                @intCast(pixel_width),
                @intCast(pixel_height),
                stride,
            ) orelse return error.CairoSurfaceFailed;
            const cr = c.cairo_create(cairo_surface) orelse return error.CairoContextFailed;
            self.buffers[i] = buffer;
            self.cairo_surfaces[i] = cairo_surface;
            self.crs[i] = cr;
            _ = c.wl_buffer_add_listener(buffer, &self.buffer_listener, self);
        }
        c.wl_surface_set_buffer_scale(self.surface, @intCast(@max(1, self.scale)));
    }

    fn drawTextN(cr: ?*c.cairo_t, x: f64, y: f64, text: []const u8, color: [4]f64) void {
        if (text.len == 0) return;
        var buf: [MAX_TEXT + 1]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        c.cairo_set_source_rgba(cr, color[0], color[1], color[2], color[3]);
        c.cairo_move_to(cr, x, y);
        c.cairo_show_text(cr, buf[0..n :0].ptr);
    }

    fn appTextWidth(cr: ?*c.cairo_t, text: []const u8) f64 {
        if (text.len == 0) return 0;
        var buf: [MAX_TEXT + 1]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        var ext: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(cr, buf[0..n :0].ptr, &ext);
        return ext.x_advance;
    }

    fn contains(self: *Toast, x: f64, y: f64) bool {
        const r = self.action_rect;
        return x >= r[0] and x <= r[0] + r[2] and y >= r[1] and y <= r[1] + r[3];
    }

    fn handleConfigure(data: ?*anyopaque, layer_surface: ?*c.struct_zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
        _ = layer_surface;
        const self: *Toast = @ptrCast(@alignCast(data.?));
        c.zwlr_layer_surface_v1_ack_configure(self.layer_surface, serial);
        self.width = width;
        self.height = height;
        self.configured = true;
        self.draw();
    }

    fn handleClosed(data: ?*anyopaque, layer_surface: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
        _ = layer_surface;
        const self: *Toast = @ptrCast(@alignCast(data.?));
        self.app.removeToast(self);
    }

    fn handleBufferRelease(data: ?*anyopaque, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
        const self: *Toast = @ptrCast(@alignCast(data.?));
        for (0..2) |i| {
            if (self.buffers[i] == buffer) {
                self.busy[i] = false;
                break;
            }
        }
    }

    fn outputGeometry(data: ?*anyopaque, output: ?*c.struct_wl_output, x: i32, y: i32, pw: i32, ph: i32, subpixel: i32, make: [*c]const u8, model: [*c]const u8, transform: i32) callconv(.c) void {
        _ = data;
        _ = output;
        _ = x;
        _ = y;
        _ = pw;
        _ = ph;
        _ = subpixel;
        _ = make;
        _ = model;
        _ = transform;
    }
    fn outputMode(data: ?*anyopaque, output: ?*c.struct_wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
        _ = data;
        _ = output;
        _ = flags;
        _ = width;
        _ = height;
        _ = refresh;
    }
    fn outputDone(data: ?*anyopaque, output: ?*c.struct_wl_output) callconv(.c) void {
        _ = data;
        _ = output;
    }
    fn outputScale(data: ?*anyopaque, output: ?*c.struct_wl_output, factor: i32) callconv(.c) void {
        _ = output;
        const self: *Toast = @ptrCast(@alignCast(data.?));
        if (factor > 0 and factor != self.scale) {
            self.scale = factor;
        }
    }
    fn outputName(data: ?*anyopaque, output: ?*c.struct_wl_output, name: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = output;
        _ = name;
    }
    fn outputDescription(data: ?*anyopaque, output: ?*c.struct_wl_output, description: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = output;
        _ = description;
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    registry: ?*c.struct_wl_registry = null,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    layer_shell: ?*c.struct_zwlr_layer_shell_v1 = null,
    seat: ?*c.struct_wl_seat = null,
    pointer: ?*c.struct_wl_pointer = null,
    toasts: std.ArrayList(*Toast),
    outputs: std.ArrayList(*c.struct_wl_output),
    queue: std.ArrayList(*Notification),
    config: Config,
    dbus: ?*DBus = null,
    registry_listener: c.struct_wl_registry_listener,
    seat_listener: c.struct_wl_seat_listener,
    pointer_listener: c.struct_wl_pointer_listener,
    pointer_toast: ?*Toast = null,
    initialized: bool = false,
    last_tick: i64 = 0,
    shutdown: bool = false,

    fn init(allocator: std.mem.Allocator, display: *c.struct_wl_display) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .toasts = std.ArrayList(*Toast).empty,
            .outputs = std.ArrayList(*c.struct_wl_output).empty,
            .queue = std.ArrayList(*Notification).empty,
            .config = Config.load(allocator),
            .registry_listener = .{ .global = handleGlobal, .global_remove = handleGlobalRemove },
            .seat_listener = .{ .capabilities = handleSeatCapabilities, .name = handleSeatName },
            .pointer_listener = .{
                .enter = handlePointerEnter,
                .leave = handlePointerLeave,
                .motion = handlePointerMotion,
                .button = handlePointerButton,
                .axis = handlePointerAxis,
                .frame = handlePointerFrame,
                .axis_source = handlePointerAxisSource,
                .axis_stop = handlePointerAxisStop,
                .axis_discrete = handlePointerAxisDiscrete,
            },
        };
        self.registry = c.wl_display_get_registry(self.display) orelse return error.RegistryFailed;
        _ = c.wl_registry_add_listener(self.registry, &self.registry_listener, self);
        return self;
    }

    fn start(self: *App) !void {
        _ = c.wl_display_roundtrip(self.display);
        _ = c.wl_display_roundtrip(self.display);
        if (self.compositor == null or self.shm == null or self.layer_shell == null) {
            std.debug.print("kairo-notifications: missing compositor/shm/layer-shell globals\n", .{});
            return error.MissingGlobal;
        }
        if (self.seat) |seat| _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
        for (self.outputs.items) |output| {
            _ = Toast.create(self, output) catch |err| {
                std.debug.print("kairo-notifications: toast surface failed: {s}\n", .{@errorName(err)});
            };
        }
        self.initialized = true;
        self.dbus = DBus.init(self) catch |err| blk: {
            std.debug.print("kairo-notifications: D-Bus unavailable: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        if (self.dbus) |d| {
            d.flush();
            std.debug.print("kairo-notifications: owning {s}\n", .{DBus.IFACE});
        }
        self.last_tick = std.time.milliTimestamp();
    }

    fn deinit(self: *App) void {
        for (self.queue.items) |n| self.allocator.destroy(n);
        self.queue.deinit(self.allocator);
        while (self.toasts.items.len > 0) {
            self.toasts.items[0].destroy();
            _ = self.toasts.orderedRemove(0);
        }
        self.toasts.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        if (self.dbus) |d| {
            if (d.conn) |conn| c.dbus_connection_unref(conn);
        }
        c.wl_display_disconnect(self.display);
        self.allocator.destroy(self);
    }

    fn currentNotification(self: *App) ?*Notification {
        if (self.queue.items.len == 0) return null;
        return self.queue.items[0];
    }

    fn closeById(self: *App, id: u32) void {
        for (self.queue.items, 0..) |note, i| {
            if (note.id == id) {
                self.removeNote(i, 2); // 2 = dismissed by CloseNotification call
                return;
            }
        }
    }

    /// reason: 1 expired, 2 dismissed by call, 3 closed by the user.
    fn removeNote(self: *App, index: usize, reason: u32) void {
        const note = self.queue.orderedRemove(index);
        if (self.dbus) |d| d.emitClosed(note.id, reason);
        self.allocator.destroy(note);
        self.redrawAll();
    }

    fn redrawAll(self: *App) void {
        for (self.toasts.items) |t| t.draw();
    }

    fn removeToast(self: *App, toast: *Toast) void {
        for (self.toasts.items, 0..) |item, i| {
            if (item == toast) {
                _ = self.toasts.orderedRemove(i);
                break;
            }
        }
        if (self.pointer_toast == toast) self.pointer_toast = null;
        toast.destroy();
    }

    fn tick(self: *App) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_tick < 250) return;
        self.last_tick = now;
        if (self.queue.items.len > 0) {
            const note = self.queue.items[0];
            if (note.expire_at != 0 and now >= note.expire_at) {
                self.removeNote(0, 1);
            }
        }
    }

    fn handleGlobal(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
        _ = version;
        const self: *App = @ptrCast(@alignCast(data.?));
        const interface = std.mem.span(iface);
        if (std.mem.eql(u8, interface, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4));
        } else if (std.mem.eql(u8, interface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            self.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, 4));
        } else if (std.mem.eql(u8, interface, "wl_seat")) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 7));
        } else if (std.mem.eql(u8, interface, "wl_output")) {
            const output: *c.struct_wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 4));
            self.outputs.append(self.allocator, output) catch {
                c.wl_output_destroy(output);
                return;
            };
            if (self.initialized) {
                _ = Toast.create(self, output) catch {};
            }
        }
    }

    fn handleGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
    }

    fn handleSeatCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
        _ = seat;
        const self: *App = @ptrCast(@alignCast(data.?));
        if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0 and self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(self.seat) orelse return;
            _ = c.wl_pointer_add_listener(self.pointer, &self.pointer_listener, self);
        }
    }

    fn handleSeatName(data: ?*anyopaque, seat: ?*c.struct_wl_seat, name: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = seat;
        _ = name;
    }

    fn handlePointerEnter(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        _ = pointer;
        _ = serial;
        const self: *App = @ptrCast(@alignCast(data.?));
        for (self.toasts.items) |t| {
            if (t.surface == surface) {
                self.pointer_toast = t;
                t.pointer_x = c.wl_fixed_to_double(sx);
                t.pointer_y = c.wl_fixed_to_double(sy);
                t.pointer_inside = true;
                return;
            }
        }
        self.pointer_toast = null;
    }

    fn handlePointerLeave(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
        _ = pointer;
        _ = serial;
        _ = surface;
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.pointer_toast) |t| t.pointer_inside = false;
        self.pointer_toast = null;
    }

    fn handlePointerMotion(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.pointer_toast) |t| {
            t.pointer_x = c.wl_fixed_to_double(sx);
            t.pointer_y = c.wl_fixed_to_double(sy);
        }
    }

    fn handlePointerButton(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        _ = pointer;
        _ = serial;
        _ = time;
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED or button != 0x110) return;
        const self: *App = @ptrCast(@alignCast(data.?));
        const toast = self.pointer_toast orelse return;
        if (self.queue.items.len == 0) return;
        const note = self.queue.items[0];
        var index: usize = 0;
        for (self.queue.items, 0..) |n, i| {
            if (n.id == note.id) {
                index = i;
                break;
            }
        }
        // A click inside the action button invokes the action; any other
        // click dismisses the toast.
        if (toast.contains(toast.pointer_x, toast.pointer_y)) {
            if (self.dbus) |d| d.emitAction(note.id, note.actionKey());
        }
        self.removeNote(index, 3);
    }

    fn handlePointerAxis(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
        _ = value;
    }
    fn handlePointerFrame(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer) callconv(.c) void {
        _ = data;
        _ = pointer;
    }
    fn handlePointerAxisSource(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, source: u32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = source;
    }
    fn handlePointerAxisStop(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, axis: u32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
    }
    fn handlePointerAxisDiscrete(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = discrete;
    }
};

fn usage() void {
    std.fs.File.stdout().writeAll(
        \\Kairo Notifications — org.freedesktop.Notifications daemon for Kairo
        \\
        \\Usage: kairo-notifications [--version] [--help]
        \\
        \\Connects to the session bus, owns org.freedesktop.Notifications and
        \\renders toasts on a layer-shell overlay. Configure Do-Not-Disturb,
        \\timeouts and text width in ~/.config/kairo/notifications.conf:
        \\
        \\  dnd = true|false
        \\  default_timeout_ms = 5000
        \\  max_width_chars = 60
        \\
        \\Capabilities advertised: actions, body. Icons and persistent history
        \\are documented gaps.
        \\
    ) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try std.fs.File.stdout().writeAll("kairo-notifications " ++ VERSION ++ "\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        }
        std.debug.print("kairo-notifications: unknown argument '{s}'\n", .{arg});
        usage();
        std.process.exit(2);
    }
    const display = c.wl_display_connect(null) orelse {
        std.debug.print("kairo-notifications: cannot connect to Wayland\n", .{});
        return error.WaylandConnectFailed;
    };
    const app = try App.init(allocator, display);
    defer app.deinit();
    app.start() catch |err| {
        std.debug.print("kairo-notifications: startup failed: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("kairo-notifications: ready\n", .{});

    const display_fd = c.wl_display_get_fd(app.display);
    while (!app.shutdown) {
        _ = c.wl_display_flush(app.display);
        var fds = [2]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.dbus) |d| d.fd else -1, .events = c.POLLIN, .revents = 0 },
        };
        const rc = c.poll(&fds, fds.len, 250);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            std.debug.print("kairo-notifications: poll failed\n", .{});
            break;
        }
        if (fds[0].revents & (c.POLLERR | c.POLLHUP) != 0) break;
        if (fds[0].revents & c.POLLIN != 0) {
            if (c.wl_display_dispatch(app.display) == -1) break;
        }
        if (app.dbus) |d| {
            if (fds[1].revents & (c.POLLERR | c.POLLHUP) != 0) {
                std.debug.print("kairo-notifications: D-Bus connection lost\n", .{});
                app.dbus = null;
            } else if (fds[1].revents & c.POLLIN != 0) {
                var guard: usize = 0;
                while (guard < 64) : (guard += 1) {
                    // libdbus only queues incoming messages after its own
                    // read; read_write with a zero timeout does exactly that.
                    _ = c.dbus_connection_read_write(d.conn, 0);
                    d.handleOne();
                    if (c.dbus_connection_get_dispatch_status(d.conn) != c.DBUS_DISPATCH_DATA_REMAINS and
                        c.dbus_connection_get_outgoing_size(d.conn) == 0) break;
                }
                d.flush();
            }
        }
        app.tick();
    }
}
