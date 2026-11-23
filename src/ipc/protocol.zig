//! IPC wire protocol shared by Kairo and kairoctl.
//!
//! Messages are newline-delimited JSON objects. Requests look like
//! `{"command":"windows"}`; responses are `{"ok":true,"data":...}`.

const std = @import("std");

pub const Request = struct {
    command: []const u8,
    args: []const u8 = "",
    id: []const u8 = "",
    events: []const []const u8 = &.{},
};

pub const ParseError = error{
    InvalidJson,
    UnexpectedEnd,
    OutOfMemory,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    needs_comma: bool = false,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator, .buf = std.ArrayList(u8).empty };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *Writer) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    pub fn raw(self: *Writer, text: []const u8) !void {
        try self.buf.appendSlice(self.allocator, text);
    }

    pub fn beginObject(self: *Writer) !void {
        try self.separator();
        try self.buf.append(self.allocator, '{');
        self.needs_comma = false;
    }

    pub fn endObject(self: *Writer) !void {
        try self.buf.append(self.allocator, '}');
        self.needs_comma = true;
    }

    pub fn beginArray(self: *Writer) !void {
        try self.separator();
        try self.buf.append(self.allocator, '[');
        self.needs_comma = false;
    }

    pub fn endArray(self: *Writer) !void {
        try self.buf.append(self.allocator, ']');
        self.needs_comma = true;
    }

    pub fn key(self: *Writer, name: []const u8) !void {
        try self.separator();
        try self.stringRaw(name);
        try self.buf.append(self.allocator, ':');
        self.needs_comma = false;
    }

    pub fn string(self: *Writer, value: []const u8) !void {
        try self.separator();
        try self.stringRaw(value);
        self.needs_comma = true;
    }

    pub fn int(self: *Writer, value: i64) !void {
        try self.separator();
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.buf.appendSlice(self.allocator, text);
        self.needs_comma = true;
    }

    pub fn uint(self: *Writer, value: u64) !void {
        try self.separator();
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.buf.appendSlice(self.allocator, text);
        self.needs_comma = true;
    }

    pub fn float(self: *Writer, value: f32) !void {
        try self.separator();
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d:.3}", .{value});
        try self.buf.appendSlice(self.allocator, text);
        self.needs_comma = true;
    }

    pub fn boolean(self: *Writer, value: bool) !void {
        try self.separator();
        try self.buf.appendSlice(self.allocator, if (value) "true" else "false");
        self.needs_comma = true;
    }

    pub fn nullValue(self: *Writer) !void {
        try self.separator();
        try self.buf.appendSlice(self.allocator, "null");
        self.needs_comma = true;
    }

    fn separator(self: *Writer) !void {
        if (self.needs_comma) try self.buf.append(self.allocator, ',');
        self.needs_comma = false;
    }

    fn stringRaw(self: *Writer, value: []const u8) !void {
        try self.buf.append(self.allocator, '"');
        for (value) |ch| {
            switch (ch) {
                '"' => try self.buf.appendSlice(self.allocator, "\\\""),
                '\\' => try self.buf.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.buf.appendSlice(self.allocator, "\\n"),
                '\r' => try self.buf.appendSlice(self.allocator, "\\r"),
                '\t' => try self.buf.appendSlice(self.allocator, "\\t"),
                0x08 => try self.buf.appendSlice(self.allocator, "\\b"),
                0x0c => try self.buf.appendSlice(self.allocator, "\\f"),
                else => {
                    if (ch < 0x20) {
                        var tmp: [8]u8 = undefined;
                        const esc = try std.fmt.bufPrint(&tmp, "\\u{X:0>4}", .{ch});
                        try self.buf.appendSlice(self.allocator, esc);
                    } else {
                        try self.buf.append(self.allocator, ch);
                    }
                },
            }
        }
        try self.buf.append(self.allocator, '"');
    }
};

/// Encode a simple request. Used by kairoctl.
pub fn encodeRequest(allocator: std.mem.Allocator, command: []const u8, args: []const u8) ![]u8 {
    var w = Writer.init(allocator);
    errdefer w.deinit();
    try w.beginObject();
    try w.key("command");
    try w.string(command);
    if (args.len > 0) {
        try w.key("args");
        try w.string(args);
    }
    try w.endObject();
    try w.raw("\n");
    return w.toOwnedSlice();
}

pub fn encodeSubscribe(allocator: std.mem.Allocator, events: []const []const u8) ![]u8 {
    var w = Writer.init(allocator);
    errdefer w.deinit();
    try w.beginObject();
    try w.key("command");
    try w.string("subscribe");
    try w.key("events");
    try w.beginArray();
    for (events) |e| try w.string(e);
    try w.endArray();
    try w.endObject();
    try w.raw("\n");
    return w.toOwnedSlice();
}

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }

    fn expect(self: *Parser, ch: u8) ParseError!void {
        self.skipWs();
        if (self.pos >= self.text.len) return error.UnexpectedEnd;
        if (self.text[self.pos] != ch) return error.InvalidJson;
        self.pos += 1;
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        self.skipWs();
        if (self.pos >= self.text.len or self.text[self.pos] != '"') return error.InvalidJson;
        self.pos += 1;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        while (self.pos < self.text.len) {
            const ch = self.text[self.pos];
            self.pos += 1;
            if (ch == '"') {
                return out.toOwnedSlice(self.allocator);
            } else if (ch == '\\') {
                if (self.pos >= self.text.len) return error.UnexpectedEnd;
                const esc = self.text[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"' => try out.append(self.allocator, '"'),
                    '\\' => try out.append(self.allocator, '\\'),
                    '/' => try out.append(self.allocator, '/'),
                    'b' => try out.append(self.allocator, 0x08),
                    'f' => try out.append(self.allocator, 0x0c),
                    'n' => try out.append(self.allocator, '\n'),
                    'r' => try out.append(self.allocator, '\r'),
                    't' => try out.append(self.allocator, '\t'),
                    'u' => {
                        if (self.pos + 4 > self.text.len) return error.UnexpectedEnd;
                        const hex = self.text[self.pos .. self.pos + 4];
                        self.pos += 4;
                        const cp = std.fmt.parseInt(u16, hex, 16) catch return error.InvalidJson;
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidJson;
                        try out.appendSlice(self.allocator, buf[0..n]);
                    },
                    else => return error.InvalidJson,
                }
            } else if (ch < 0x20) {
                return error.InvalidJson;
            } else {
                try out.append(self.allocator, ch);
            }
        }
        return error.UnexpectedEnd;
    }

    fn parseValueRaw(self: *Parser) ParseError![]const u8 {
        self.skipWs();
        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const ch = self.text[self.pos];
            if (ch == ',' or ch == '}' or ch == ']' or std.ascii.isWhitespace(ch)) break;
        }
        if (self.pos == start) return error.InvalidJson;
        return self.allocator.dupe(u8, self.text[start..self.pos]) catch return error.OutOfMemory;
    }
};

/// Parse a request object. The returned slices are allocated from `allocator`;
/// callers normally use an arena and free it after handling the request.
pub fn parseRequest(allocator: std.mem.Allocator, line: []const u8) ParseError!Request {
    var p = Parser{ .text = line, .allocator = allocator };
    try p.expect('{');
    var command: ?[]const u8 = null;
    var args: []const u8 = "";
    var id: []const u8 = "";
    var events = std.ArrayList([]const u8).empty;
    errdefer events.deinit(allocator);

    p.skipWs();
    if (p.pos < line.len and line[p.pos] == '}') {
        p.pos += 1;
    } else {
        while (true) {
            const key = try p.parseString();
            try p.expect(':');
            p.skipWs();
            if (std.mem.eql(u8, key, "events")) {
                try p.expect('[');
                p.skipWs();
                if (p.pos < line.len and line[p.pos] == ']') {
                    p.pos += 1;
                } else {
                    while (true) {
                        const item = try p.parseString();
                        try events.append(allocator, item);
                        p.skipWs();
                        if (p.pos >= line.len) return error.UnexpectedEnd;
                        if (line[p.pos] == ',') {
                            p.pos += 1;
                            continue;
                        }
                        try p.expect(']');
                        break;
                    }
                }
            } else if (line[p.pos] == '"') {
                const value = try p.parseString();
                if (std.mem.eql(u8, key, "command")) {
                    command = value;
                } else if (std.mem.eql(u8, key, "args")) {
                    args = value;
                } else if (std.mem.eql(u8, key, "id")) {
                    id = value;
                }
            } else {
                _ = try p.parseValueRaw();
            }
            p.skipWs();
            if (p.pos >= line.len) return error.UnexpectedEnd;
            if (line[p.pos] == ',') {
                p.pos += 1;
                continue;
            }
            try p.expect('}');
            break;
        }
    }
    const cmd = command orelse return error.InvalidJson;
    return .{ .command = cmd, .args = args, .id = id, .events = try events.toOwnedSlice(allocator) };
}

/// Check whether a response line contains `"ok":false`.
pub fn responseIsError(line: []const u8) ?[]const u8 {
    const ok = std.mem.indexOf(u8, line, "\"ok\":") orelse return null;
    var rest = line[ok + 5 ..];
    rest = std.mem.trimLeft(u8, rest, " \t");
    if (std.mem.startsWith(u8, rest, "false")) {
        if (std.mem.indexOf(u8, line, "\"error\":\"")) |e| {
            const start = e + 9;
            if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| return line[start..end];
        }
        return "request failed";
    }
    return null;
}

/// Re-indent a compact JSON document for human consumption.
pub fn pretty(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (json) |ch| {
        if (in_string) {
            try out.append(allocator, ch);
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => {
                in_string = true;
                try out.append(allocator, ch);
            },
            '{', '[' => {
                try out.append(allocator, ch);
                depth += 1;
                try out.append(allocator, '\n');
                try indent(allocator, &out, depth);
            },
            '}', ']' => {
                depth -= 1;
                try out.append(allocator, '\n');
                try indent(allocator, &out, depth);
                try out.append(allocator, ch);
            },
            ',' => {
                try out.append(allocator, ',');
                try out.append(allocator, '\n');
                try indent(allocator, &out, depth);
            },
            ':' => {
                try out.appendSlice(allocator, ": ");
            },
            ' ', '\n', '\r', '\t' => {},
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn indent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(allocator, "  ");
}

test "json writer escapes strings" {
    const a = std.testing.allocator;
    var w = Writer.init(a);
    defer w.deinit();
    try w.beginObject();
    try w.key("command");
    try w.string("a\"b\\c\n");
    try w.key("n");
    try w.int(42);
    try w.endObject();
    const out = try w.toOwnedSlice();
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"command\":\"a\\\"b\\\\c\\n\",\"n\":42}", out);
}

test "parse request" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "{\"command\":\"dispatch\",\"args\":\"toggle-floating\",\"events\":[\"window\",\"tag\"]}");
    try std.testing.expectEqualStrings("dispatch", req.command);
    try std.testing.expectEqualStrings("toggle-floating", req.args);
    try std.testing.expectEqual(@as(usize, 2), req.events.len);
    try std.testing.expectEqualStrings("window", req.events[0]);
}

test "invalid json rejected" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidJson, parseRequest(arena.allocator(), "{}"));
    try std.testing.expectError(error.InvalidJson, parseRequest(arena.allocator(), "{\"command\":}"));
}

test "pretty printing" {
    const a = std.testing.allocator;
    const out = try pretty(a, "{\"ok\":true,\"data\":[1,2]}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n  ") != null);
}
