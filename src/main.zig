//! Kairo entry point.

const std = @import("std");
const c = @import("bindings.zig").c;
const log = @import("util/log.zig");
const Server = @import("core/server.zig").Server;
const Config = @import("config/config.zig").Config;
const loader = @import("config/loader.zig");
const build_options = @import("build_options");

const usage =
    \\Kairo — a MangoWM-inspired Wayland compositor
    \\
    \\Usage: kairo [options]
    \\
    \\  -c, --config PATH       Use PATH instead of ~/.config/kairo/config
    \\      --validate-config   Validate the configuration and exit
    \\      --headless          Start with the headless backend (testing)
    \\      --exit-after MS     Terminate after MS milliseconds (testing)
    \\      --log-level LEVEL   error|warn|info|debug
    \\  -v, --version           Print version information
    \\  -h, --help              Show this help
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path_arg: ?[]const u8 = null;
    var headless = false;
    var validate_only = false;
    var exit_after_ms: ?u32 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            var buf: [128]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "kairo {s} (wlroots 0.20, zig {s})\n", .{ build_options.version, @import("builtin").zig_version_string });
            try std.fs.File.stdout().writeAll(text);
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) fatalUsage("--config needs a path");
            config_path_arg = args[i];
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            config_path_arg = arg["--config=".len..];
        } else if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--validate-config")) {
            validate_only = true;
        } else if (std.mem.eql(u8, arg, "--exit-after")) {
            i += 1;
            if (i >= args.len) fatalUsage("--exit-after needs milliseconds");
            exit_after_ms = std.fmt.parseInt(u32, args[i], 10) catch fatalUsage("invalid --exit-after value");
        } else if (std.mem.startsWith(u8, arg, "--exit-after=")) {
            exit_after_ms = std.fmt.parseInt(u32, arg["--exit-after=".len..], 10) catch fatalUsage("invalid --exit-after value");
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) fatalUsage("--log-level needs a value");
            setLogLevel(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--log-level=")) {
            setLogLevel(arg["--log-level=".len..]);
        } else {
            std.debug.print("kairo: unknown argument '{s}'\n{s}", .{ arg, usage });
            std.process.exit(2);
        }
    }

    var config_path: ?[]u8 = null;
    defer if (config_path) |p| allocator.free(p);

    if (config_path_arg) |p| {
        config_path = try allocator.dupe(u8, p);
        if (!fileExists(p)) {
            std.debug.print("kairo: configuration file '{s}' does not exist\n", .{p});
            std.process.exit(1);
        }
    } else {
        config_path = try findDefaultConfig(allocator);
    }

    var config: Config = undefined;
    if (config_path) |p| {
        config = loader.load(allocator, p) catch |err| {
            std.debug.print("kairo: failed to load configuration '{s}': {s}\n", .{ p, @errorName(err) });
            std.process.exit(1);
        };
    } else {
        config = Config.initDefault(allocator) catch |err| {
            std.debug.print("kairo: failed to initialise configuration: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    if (config.diag_count > 0) {
        for (config.diags[0..config.diag_count]) |d| {
            std.debug.print("{s}:{d}: error: {s}\n", .{ d.file, d.line, d.message });
        }
        std.debug.print("kairo: {d} configuration error(s)\n", .{config.diag_count});
        config.deinit(allocator);
        std.process.exit(1);
    }

    if (validate_only) {
        std.debug.print("kairo: configuration is valid\n", .{});
        config.deinit(allocator);
        return;
    }

    applyEnvironment(allocator, &config);

    var server = Server.init(allocator, config, headless) catch |err| {
        std.debug.print("kairo: failed to initialise compositor: {s}\n", .{@errorName(err)});
        std.debug.print("Check that wlroots 0.20 and its dependencies are installed.\n", .{});
        config.deinit(allocator);
        std.process.exit(1);
    };
    errdefer server.deinit();
    if (config_path) |p| server.setConfigPath(p);

    const socket = server.socketName() catch |err| {
        std.debug.print("kairo: cannot create Wayland socket: {s}\n", .{@errorName(err)});
        std.debug.print("Make sure XDG_RUNTIME_DIR is set and writable.\n", .{});
        server.deinit();
        std.process.exit(1);
    };
    setEnv(allocator, "WAYLAND_DISPLAY", socket, true);
    setEnv(allocator, "XDG_SESSION_TYPE", "wayland", false);
    setEnv(allocator, "XDG_CURRENT_DESKTOP", "Kairo", false);
    setEnv(allocator, "XDG_SESSION_DESKTOP", "Kairo", false);

    if (exit_after_ms) |ms| {
        server.exit_after_timer = c.wl_event_loop_add_timer(server.event_loop, exitTimer, server);
        if (server.exit_after_timer) |t| _ = c.wl_event_source_timer_update(t, @intCast(ms));
    }

    server.start() catch |err| {
        std.debug.print("kairo: failed to start backend: {s}\n", .{@errorName(err)});
        server.deinit();
        std.process.exit(1);
    };

    // Start configured applications only after the backend and socket exist.
    for (server.config.autostart[0..server.config.autostart_count]) |entry| {
        if (entry.once) server.spawn(entry.command);
    }

    log.info("Kairo is running on WAYLAND_DISPLAY={s}", .{socket});
    server.run();
    server.deinit();
}

fn exitTimer(data: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(data.?));
    server.terminate();
    return 0;
}

fn fatalUsage(msg: []const u8) noreturn {
    std.debug.print("kairo: {s}\n{s}", .{ msg, usage });
    std.process.exit(2);
}

fn setLogLevel(s: []const u8) void {
    if (std.ascii.eqlIgnoreCase(s, "error")) {
        log.level = .err;
    } else if (std.ascii.eqlIgnoreCase(s, "warn")) {
        log.level = .warn;
    } else if (std.ascii.eqlIgnoreCase(s, "info")) {
        log.level = .info;
    } else if (std.ascii.eqlIgnoreCase(s, "debug")) {
        log.level = .debug;
    } else {
        fatalUsage("invalid log level");
    }
}

fn setEnv(allocator: std.mem.Allocator, name: []const u8, value: []const u8, overwrite: bool) void {
    const n = allocator.dupeZ(u8, name) catch return;
    defer allocator.free(n);
    const v = allocator.dupeZ(u8, value) catch return;
    defer allocator.free(v);
    _ = c.setenv(n.ptr, v.ptr, @intFromBool(overwrite));
}

fn applyEnvironment(allocator: std.mem.Allocator, config: *Config) void {
    for (config.env[0..config.env_count]) |entry| {
        setEnv(allocator, entry.name, entry.value, true);
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn findDefaultConfig(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        const path = try std.fs.path.join(allocator, &.{ xdg, "kairo", "config" });
        if (fileExists(path)) return path;
        allocator.free(path);
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".config", "kairo", "config" });
        if (fileExists(path)) return path;
        allocator.free(path);
    } else |_| {}
    if (fileExists("/etc/kairo/config")) {
        return try allocator.dupe(u8, "/etc/kairo/config");
    }
    return null;
}
