//! kairoctl — command-line client for the Kairo IPC socket.

const std = @import("std");
const proto = @import("ipc_protocol");
const build_options = @import("build_options");

const usage =
    \\kairoctl — control a running Kairo compositor
    \\
    \\Usage: kairoctl [options] COMMAND [ARGS...]
    \\
    \\Commands:
    \\  version                 Compositor version
    \\  query                   Full compositor state as JSON
    \\  windows                 List managed windows
    \\  monitors                List outputs
    \\  tags                    List tag state
    \\  layouts                 List available layouts
    \\  focus <id|next|prev>    Focus a window
    \\  reload                  Reload configuration
    \\  set-layout <name>       Change the active tag's layout
    \\  toggle-floating         Toggle floating for the focused window
    \\  dispatch <command>      Dispatch a compositor command
    \\  subscribe [EVENTS...]   Stream events (window,tag,output,layout)
    \\
    \\Options:
    \\  --socket PATH           IPC socket (default $XDG_RUNTIME_DIR/kairo.sock)
    \\  --raw                   Print compact JSON
    \\  --pretty                Print indented JSON (default)
    \\  -h, --help              Show this help
    \\  -v, --version           Print kairoctl version
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var socket_override: ?[]const u8 = null;
    var raw = false;
    var positional = std.ArrayList([]const u8).empty;
    defer positional.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            var buf: [64]u8 = undefined;
            try stdout().writeAll(try std.fmt.bufPrint(&buf, "kairoctl {s}\n", .{build_options.version}));
            return;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            i += 1;
            if (i >= args.len) fatal("--socket needs a path");
            socket_override = args[i];
        } else if (std.mem.startsWith(u8, arg, "--socket=")) {
            socket_override = arg["--socket=".len..];
        } else if (std.mem.eql(u8, arg, "--raw")) {
            raw = true;
        } else if (std.mem.eql(u8, arg, "--pretty")) {
            raw = false;
        } else if (arg.len > 0 and arg[0] == '-') {
            fatal("unknown option");
        } else {
            try positional.append(allocator, arg);
        }
    }

    if (positional.items.len == 0) {
        fatal("missing command");
    }

    const cmd = positional.items[0];
    const rest = positional.items[1..];
    const request = if (std.mem.eql(u8, cmd, "subscribe") or std.mem.eql(u8, cmd, "events"))
        try buildSubscribe(allocator, rest)
    else
        try buildRequest(allocator, cmd, rest);
    defer allocator.free(request);
    const subscribe = std.mem.eql(u8, cmd, "subscribe") or std.mem.eql(u8, cmd, "events");

    const socket_path = try resolveSocket(allocator, socket_override);
    defer allocator.free(socket_path);

    const fd = connectSocket(socket_path) catch |err| {
        std.debug.print("kairoctl: cannot connect to {s}: {s}\n", .{ socket_path, @errorName(err) });
        std.debug.print("Is Kairo running? Set KAIRO_SOCKET or --socket if needed.\n", .{});
        std.process.exit(1);
    };
    defer std.posix.close(fd);

    try writeAll(fd, request);

    var buf: [64 * 1024]u8 = undefined;
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(allocator);

    while (true) {
        const n = std.posix.read(fd, &buf) catch |err| {
            std.debug.print("kairoctl: read failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (n == 0) break;
        try pending.appendSlice(allocator, buf[0..n]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            const line = pending.items[0..nl];
            if (line.len > 0) {
                if (proto.responseIsError(line)) |err| {
                    std.debug.print("kairoctl: {s}\n", .{err});
                    std.process.exit(1);
                }
                if (raw) {
                    try stdout().writeAll(line);
                    try stdout().writeAll("\n");
                } else {
                    const formatted = proto.pretty(allocator, line) catch line;
                    defer if (formatted.ptr != line.ptr) allocator.free(formatted);
                    try stdout().writeAll(formatted);
                    try stdout().writeAll("\n");
                }
            }
            const remaining = try allocator.dupe(u8, pending.items[nl + 1 ..]);
            pending.clearRetainingCapacity();
            try pending.appendSlice(allocator, remaining);
            allocator.free(remaining);
        }
        if (!subscribe) break;
    }

    if (!subscribe and pending.items.len > 0) {
        if (proto.responseIsError(pending.items)) |err| {
            std.debug.print("kairoctl: {s}\n", .{err});
            std.process.exit(1);
        }
        if (raw) {
            try stdout().writeAll(pending.items);
            try stdout().writeAll("\n");
        } else {
            const formatted = proto.pretty(allocator, pending.items) catch pending.items;
            defer if (formatted.ptr != pending.items.ptr) allocator.free(formatted);
            try stdout().writeAll(formatted);
            try stdout().writeAll("\n");
        }
    }
}

fn buildRequest(allocator: std.mem.Allocator, cmd: []const u8, rest: []const []const u8) ![]u8 {
    if (std.mem.eql(u8, cmd, "version")) return proto.encodeRequest(allocator, "version", "");
    if (std.mem.eql(u8, cmd, "query")) return proto.encodeRequest(allocator, "query", "");
    if (std.mem.eql(u8, cmd, "windows")) return proto.encodeRequest(allocator, "windows", "");
    if (std.mem.eql(u8, cmd, "monitors")) return proto.encodeRequest(allocator, "monitors", "");
    if (std.mem.eql(u8, cmd, "tags")) return proto.encodeRequest(allocator, "tags", "");
    if (std.mem.eql(u8, cmd, "layouts")) return proto.encodeRequest(allocator, "layouts", "");
    if (std.mem.eql(u8, cmd, "reload")) return proto.encodeRequest(allocator, "reload", "");
    if (std.mem.eql(u8, cmd, "toggle-floating") or std.mem.eql(u8, cmd, "toggle-floating-window"))
        return proto.encodeRequest(allocator, "toggle_floating", "");

    const command_name = if (std.mem.eql(u8, cmd, "set-layout")) "set_layout" else if (std.mem.eql(u8, cmd, "focus")) "focus" else if (std.mem.eql(u8, cmd, "dispatch")) "dispatch" else cmd;
    const joined = try std.mem.join(allocator, " ", rest);
    defer allocator.free(joined);
    return proto.encodeRequest(allocator, command_name, joined);
}

fn buildSubscribe(allocator: std.mem.Allocator, rest: []const []const u8) ![]u8 {
    if (rest.len == 0) {
        const defaults = [_][]const u8{ "window", "tag", "output", "layout" };
        return proto.encodeSubscribe(allocator, &defaults);
    }
    return proto.encodeSubscribe(allocator, rest);
}

fn resolveSocket(allocator: std.mem.Allocator, override: ?[]const u8) ![]u8 {
    if (override) |o| return allocator.dupe(u8, o);
    if (std.process.getEnvVarOwned(allocator, "KAIRO_SOCKET")) |s| return s else |_| {}
    const runtime = std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch {
        return allocator.dupe(u8, "/tmp/kairo.sock");
    };
    defer allocator.free(runtime);
    return std.fs.path.join(allocator, &.{ runtime, "kairo.sock" });
}

fn connectSocket(path: []const u8) !std.posix.fd_t {
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    errdefer std.posix.close(fd);
    var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    return fd;
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        off += try std.posix.write(fd, data[off..]);
    }
}

fn stdout() std.fs.File {
    return std.fs.File.stdout();
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("kairoctl: {s}\n{s}", .{ msg, usage });
    std.process.exit(2);
}
