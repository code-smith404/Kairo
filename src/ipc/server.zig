//! Newline-delimited JSON control socket.
//!
//! The socket lives at `$XDG_RUNTIME_DIR/kairo.sock`. Every connection may
//! issue commands and optionally subscribe to state-change events. Responses
//! are one JSON object per line, which makes the protocol easy to consume from
//! shell scripts and from `kairoctl`.

const std = @import("std");
const c = @import("../bindings.zig").c;
const proto = @import("protocol.zig");
const log = @import("../util/log.zig");
const layout = @import("../layout/layout.zig");
const Server = @import("../core/server.zig").Server;
const Window = @import("../core/window.zig").Window;
const Output = @import("../core/output.zig").Output;

pub const Event = enum {
    window,
    tag,
    output,
    layout,
    session,

    pub fn name(self: Event) []const u8 {
        return @tagName(self);
    }

    pub fn bit(self: Event) u8 {
        return @as(u8, 1) << @intFromEnum(self);
    }
};

const Client = struct {
    ipc: *Ipc,
    fd: std.posix.fd_t,
    source: ?*c.struct_wl_event_source = null,
    buffer: std.ArrayList(u8),
    subscribed: u8 = 0,
    closed: bool = false,

    fn send(self: *Client, bytes: []const u8) bool {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.posix.write(self.fd, bytes[off..]) catch {
                self.close();
                return false;
            };
            if (n == 0) {
                self.close();
                return false;
            }
            off += n;
        }
        return true;
    }

    fn close(self: *Client) void {
        if (self.closed) return;
        self.closed = true;
        if (self.source) |src| _ = c.wl_event_source_remove(src);
        std.posix.close(self.fd);
        self.buffer.deinit(self.ipc.allocator);
        self.ipc.removeClient(self);
    }
};

pub const Ipc = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    listen_fd: std.posix.fd_t,
    path: []u8,
    source: ?*c.struct_wl_event_source = null,
    clients: std.ArrayList(*Client),

    pub fn init(server: *Server) !*Ipc {
        const allocator = server.allocator;
        const path = try socketPath(allocator);
        errdefer allocator.free(path);

        std.posix.unlink(path) catch {};
        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(fd);

        var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try std.posix.listen(fd, 16);
        std.posix.fchmod(fd, 0o600) catch {};

        const self = try allocator.create(Ipc);
        self.* = .{
            .server = server,
            .allocator = allocator,
            .listen_fd = fd,
            .path = path,
            .clients = std.ArrayList(*Client).empty,
        };
        self.source = c.wl_event_loop_add_fd(
            server.event_loop,
            fd,
            @intCast(c.WL_EVENT_READABLE),
            handleAccept,
            self,
        );
        if (self.source == null) return error.EventSourceCreateFailed;
        log.info("IPC socket ready at {s}", .{path});
        return self;
    }

    pub fn deinit(self: *Ipc) void {
        for (self.clients.items) |client| {
            if (client.source) |src| _ = c.wl_event_source_remove(src);
            if (!client.closed) std.posix.close(client.fd);
            client.buffer.deinit(self.allocator);
            self.allocator.destroy(client);
        }
        self.clients.deinit(self.allocator);
        if (self.source) |src| _ = c.wl_event_source_remove(src);
        std.posix.close(self.listen_fd);
        std.posix.unlink(self.path) catch {};
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn removeClient(self: *Ipc, client: *Client) void {
        for (self.clients.items, 0..) |item, i| {
            if (item == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
        self.allocator.destroy(client);
    }

    fn accept(self: *Ipc) void {
        while (true) {
            const fd = std.posix.accept(self.listen_fd, null, null, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    log.warn("IPC accept failed: {s}", .{@errorName(err)});
                    return;
                },
            };
            const client = self.allocator.create(Client) catch {
                std.posix.close(fd);
                return;
            };
            client.* = .{
                .ipc = self,
                .fd = fd,
                .buffer = std.ArrayList(u8).empty,
            };
            client.source = c.wl_event_loop_add_fd(
                self.server.event_loop,
                fd,
                @intCast(c.WL_EVENT_READABLE),
                handleReadable,
                client,
            );
            if (client.source == null) {
                std.posix.close(fd);
                self.allocator.destroy(client);
                continue;
            }
            self.clients.append(self.allocator, client) catch {
                client.close();
                continue;
            };
            log.debug("IPC client connected", .{});
        }
    }

    fn readable(client: *Client) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(client.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    client.close();
                    return;
                },
            };
            if (n == 0) {
                client.close();
                return;
            }
            client.buffer.appendSlice(client.ipc.allocator, buf[0..n]) catch {
                client.close();
                return;
            };
            if (client.buffer.items.len > 1024 * 1024) {
                Ipc.sendError(client, "request too large");
                client.close();
                return;
            }
            while (std.mem.indexOfScalar(u8, client.buffer.items, '\n')) |nl| {
                const line = client.buffer.items[0..nl];
                if (line.len > 0) Ipc.handleLine(client, line);
                if (client.closed) return;
                const rest = client.buffer.items[nl + 1 ..];
                std.mem.copyForwards(u8, client.buffer.items[0..rest.len], rest);
                client.buffer.shrinkRetainingCapacity(rest.len);
                if (client.closed) return;
            }
        }
    }

    fn handleLine(client: *Client, line: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(client.ipc.allocator);
        defer arena.deinit();
        const req = proto.parseRequest(arena.allocator(), line) catch {
            Ipc.sendError(client, "invalid JSON request");
            return;
        };
        log.debug("IPC command: {s}", .{req.command});
        Ipc.dispatch(client, req) catch |err| {
            Ipc.sendError(client, @errorName(err));
        };
    }

    fn dispatch(client: *Client, req: proto.Request) !void {
        const server = client.ipc.server;
        if (std.mem.eql(u8, req.command, "version")) {
            var w = proto.Writer.init(client.ipc.allocator);
            defer w.deinit();
            try w.beginObject();
            try w.key("ok");
            try w.boolean(true);
            try w.key("data");
            try w.beginObject();
            try w.key("name");
            try w.string("kairo");
            try w.key("version");
            try w.string(@import("build_options").version);
            try w.key("wlroots");
            try w.string("0.20");
            try w.key("scenefx");
            try w.boolean(@import("../bindings.zig").scenefx);
            try w.endObject();
            try w.endObject();
            try w.raw("\n");
            const out = try w.toOwnedSlice();
            defer client.ipc.allocator.free(out);
            _ = client.send(out);
            return;
        }

        if (std.mem.eql(u8, req.command, "subscribe")) {
            var bits: u8 = 0;
            for (req.events) |event| {
                inline for (std.meta.fields(Event)) |f| {
                    if (std.mem.eql(u8, event, f.name)) {
                        const e: Event = @enumFromInt(f.value);
                        bits |= e.bit();
                    }
                }
            }
            client.subscribed |= bits;
            var w = proto.Writer.init(client.ipc.allocator);
            defer w.deinit();
            try w.beginObject();
            try w.key("ok");
            try w.boolean(true);
            try w.key("data");
            try w.beginObject();
            try w.key("subscribed");
            try w.beginArray();
            inline for (std.meta.fields(Event)) |f| {
                const e: Event = @enumFromInt(f.value);
                if ((client.subscribed & e.bit()) != 0) try w.string(e.name());
            }
            try w.endArray();
            try w.endObject();
            try w.endObject();
            try w.raw("\n");
            const out = try w.toOwnedSlice();
            defer client.ipc.allocator.free(out);
            _ = client.send(out);
            return;
        }

        if (std.mem.eql(u8, req.command, "query") or std.mem.eql(u8, req.command, "windows") or
            std.mem.eql(u8, req.command, "monitors") or std.mem.eql(u8, req.command, "tags") or
            std.mem.eql(u8, req.command, "layouts"))
        {
            var w = proto.Writer.init(client.ipc.allocator);
            defer w.deinit();
            try w.beginObject();
            try w.key("ok");
            try w.boolean(true);
            try w.key("data");
            if (std.mem.eql(u8, req.command, "query")) {
                try writeQuery(&w, server);
            } else if (std.mem.eql(u8, req.command, "windows")) {
                try writeWindows(&w, server);
            } else if (std.mem.eql(u8, req.command, "monitors")) {
                try writeMonitors(&w, server);
            } else if (std.mem.eql(u8, req.command, "tags")) {
                try writeTags(&w, server);
            } else {
                try writeLayouts(&w);
            }
            try w.endObject();
            try w.raw("\n");
            const out = try w.toOwnedSlice();
            defer client.ipc.allocator.free(out);
            _ = client.send(out);
            return;
        }

        if (std.mem.eql(u8, req.command, "focus")) {
            const target = std.mem.trim(u8, req.args, " \t");
            if (target.len == 0) return error.MissingArgument;
            if (std.mem.eql(u8, target, "next")) {
                server.dispatch(.focus_next, "");
            } else if (std.mem.eql(u8, target, "prev") or std.mem.eql(u8, target, "previous")) {
                server.dispatch(.focus_prev, "");
            } else {
                const id = std.fmt.parseInt(u32, target, 10) catch return error.InvalidArgument;
                var found: ?*Window = null;
                for (server.windows.items) |win| {
                    if (win.id == id) found = win;
                }
                const win = found orelse return error.WindowNotFound;
                server.focusWindow(win, win.output);
            }
            return Ipc.sendOk(client);
        }

        if (std.mem.eql(u8, req.command, "reload")) {
            server.reloadConfig();
            return Ipc.sendOk(client);
        }

        if (std.mem.eql(u8, req.command, "set_layout")) {
            const name = std.mem.trim(u8, req.args, " \t");
            const kind = layout.Kind.fromName(name) orelse return error.UnknownLayout;
            const out = server.focusedOrFirstOutput() orelse return error.NoOutput;
            out.setLayout(kind);
            server.emitLayout();
            return Ipc.sendOk(client);
        }

        if (std.mem.eql(u8, req.command, "toggle_floating")) {
            const win = server.focused_window orelse return error.NoFocusedWindow;
            server.dispatch(.toggle_floating, "");
            _ = win;
            return Ipc.sendOk(client);
        }

        if (std.mem.eql(u8, req.command, "dispatch")) {
            const args = std.mem.trim(u8, req.args, " \t");
            const space = std.mem.indexOfScalar(u8, args, ' ');
            const raw_name = if (space) |i| args[0..i] else args;
            const rest = if (space) |i| std.mem.trim(u8, args[i + 1 ..], " \t") else "";
            if (raw_name.len == 0) return error.MissingArgument;
            var name_buf: [96]u8 = undefined;
            if (raw_name.len > name_buf.len) return error.InvalidArgument;
            for (raw_name, 0..) |ch, i| name_buf[i] = if (ch == '-') '_' else ch;
            const name = name_buf[0..raw_name.len];
            const command = @import("../config/config.zig").Command.fromName(name) orelse return error.UnknownCommand;
            server.dispatch(command, rest);
            return Ipc.sendOk(client);
        }

        return error.UnknownCommand;
    }

    fn sendOk(client: *Client) void {
        _ = client.send("{\"ok\":true}\n");
    }

    fn sendError(client: *Client, message: []const u8) void {
        const allocator = client.ipc.allocator;
        var w = proto.Writer.init(allocator);
        defer w.deinit();
        w.beginObject() catch return;
        w.key("ok") catch return;
        w.boolean(false) catch return;
        w.key("error") catch return;
        w.string(message) catch return;
        w.endObject() catch return;
        w.raw("\n") catch return;
        const out = w.toOwnedSlice() catch return;
        defer allocator.free(out);
        _ = client.send(out);
    }

    pub fn emit(self: *Ipc, event: Event) void {
        if (self.clients.items.len == 0) return;
        var i = self.clients.items.len;
        while (i > 0) {
            i -= 1;
            const client = self.clients.items[i];
            if (client.closed or (client.subscribed & event.bit()) == 0) continue;
            var w = proto.Writer.init(self.allocator);
            defer w.deinit();
            w.beginObject() catch continue;
            w.key("event") catch continue;
            w.string(event.name()) catch continue;
            w.key("data") catch continue;
            switch (event) {
                .window => writeWindows(&w, self.server) catch continue,
                .tag => writeTags(&w, self.server) catch continue,
                .output => writeMonitors(&w, self.server) catch continue,
                .layout => writeLayouts(&w) catch continue,
                .session => writeSession(&w, self.server) catch continue,
            }
            w.endObject() catch continue;
            w.raw("\n") catch continue;
            const out = w.toOwnedSlice() catch continue;
            defer self.allocator.free(out);
            _ = client.send(out);
        }
    }
};

fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("KAIRO_SOCKET")) |p| return allocator.dupe(u8, p);
    const runtime = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ runtime, "kairo.sock" });
}

fn outputName(out: *Output) []const u8 {
    return std.mem.span(out.wlr_output.name);
}

fn writeWindows(w: *proto.Writer, server: *Server) !void {
    try w.beginArray();
    for (server.windows.items) |win| {
        try w.beginObject();
        try w.key("id");
        try w.uint(win.id);
        try w.key("title");
        try w.string(win.title());
        try w.key("app_id");
        try w.string(win.appId());
        try w.key("tags");
        try w.uint(win.tags);
        try w.key("mapped");
        try w.boolean(win.mapped);
        try w.key("floating");
        try w.boolean(win.floating);
        try w.key("fullscreen");
        try w.boolean(win.fullscreen);
        try w.key("maximized");
        try w.boolean(win.maximized);
        try w.key("minimized");
        try w.boolean(win.minimized);
        try w.key("focused");
        try w.boolean(server.focused_window == win);
        try w.key("x");
        try w.int(win.frame.x);
        try w.key("y");
        try w.int(win.frame.y);
        try w.key("width");
        try w.int(win.frame.width);
        try w.key("height");
        try w.int(win.frame.height);
        try w.key("x11");
        try w.boolean(std.meta.activeTag(win.kind) == .x11);
        try w.key("output");
        if (win.output) |out| try w.string(outputName(out)) else try w.nullValue();
        try w.endObject();
    }
    try w.endArray();
}

fn writeMonitors(w: *proto.Writer, server: *Server) !void {
    try w.beginArray();
    for (server.outputs.items) |out| {
        try w.beginObject();
        try w.key("name");
        try w.string(outputName(out));
        try w.key("width");
        try w.int(out.full.width);
        try w.key("height");
        try w.int(out.full.height);
        try w.key("x");
        try w.int(out.full.x);
        try w.key("y");
        try w.int(out.full.y);
        try w.key("usable_width");
        try w.int(out.usable.width);
        try w.key("usable_height");
        try w.int(out.usable.height);
        try w.key("focused");
        try w.boolean(server.focused_output == out);
        try w.key("tags");
        try w.uint(out.tags.active);
        try w.key("layout");
        try w.string(out.tags.activeState().layout.name());
        try w.key("master_count");
        try w.uint(out.tags.activeState().master_count);
        try w.key("master_factor");
        try w.float(out.tags.activeState().master_factor);
        try w.endObject();
    }
    try w.endArray();
}

fn writeTags(w: *proto.Writer, server: *Server) !void {
    try w.beginObject();
    try w.key("active");
    try w.uint(if (server.focusedOrFirstOutput()) |o| o.tags.active else 1);
    try w.key("previous");
    try w.uint(if (server.focusedOrFirstOutput()) |o| o.tags.previous else 1);
    try w.key("per_output");
    try w.beginArray();
    for (server.outputs.items) |out| {
        try w.beginObject();
        try w.key("output");
        try w.string(outputName(out));
        try w.key("active");
        try w.uint(out.tags.active);
        try w.key("layout");
        try w.string(out.tags.activeState().layout.name());
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

fn writeLayouts(w: *proto.Writer) !void {
    try w.beginArray();
    for (layout.Kind.all()) |kind| try w.string(kind.name());
    try w.endArray();
}

fn writeSession(w: *proto.Writer, server: *Server) !void {
    try w.beginObject();
    try w.key("locked");
    try w.boolean(server.session_locked);
    try w.key("key_mode");
    try w.string(server.input.modeName());
    try w.endObject();
}

fn writeQuery(w: *proto.Writer, server: *Server) !void {
    try w.beginObject();
    try w.key("version");
    try w.string(@import("build_options").version);
    try w.key("session");
    try writeSession(w, server);
    try w.key("focused_window");
    if (server.focused_window) |win| try w.uint(win.id) else try w.nullValue();
    try w.key("windows");
    try writeWindows(w, server);
    try w.key("monitors");
    try writeMonitors(w, server);
    try w.key("tags");
    try writeTags(w, server);
    try w.key("layouts");
    try writeLayouts(w);
    try w.endObject();
}

fn handleAccept(fd: c_int, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
    _ = fd;
    _ = mask;
    const self: *Ipc = @ptrCast(@alignCast(data.?));
    self.accept();
    return 0;
}

fn handleReadable(fd: c_int, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
    _ = fd;
    _ = mask;
    const client: *Client = @ptrCast(@alignCast(data.?));
    Ipc.readable(client);
    return 0;
}
