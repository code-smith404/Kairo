//! Kairo Bar — the native Wayland status bar for the Kairo desktop.
//!
//! A separate layer-shell client: tag buttons, the focused window title and
//! system status modules (CPU, memory, temperature, battery, backlight,
//! network, ALSA volume) rendered with cairo into double-buffered shm
//! buffers. State comes from the compositor's IPC socket and from /proc and
//! /sys reads on a one-second tick; the bar never spawns subprocesses and
//! never busy-loops. A shell crash cannot take down the compositor.

const std = @import("std");
const proto = @import("ipc_protocol");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("cairo/cairo.h");
    @cInclude("time.h");
    @cInclude("poll.h");
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("alsa/asoundlib.h");
});

const BAR_HEIGHT: u32 = 32;
const TAG_WIDTH: f64 = 27;
const TAG_GAP: f64 = 2;
const TAG_START: f64 = 8;
const MAX_TAG_BUTTONS: u32 = 9;
const TITLE_MAX: f64 = 320;
const STATS_TICK_DIVIDER: u32 = 2; // stats refresh every 2 s, clock every 1 s

// ---------------------------------------------------------------------------
// Configuration (~/.config/kairo/bar.conf) and GTK appearance detection.
// ---------------------------------------------------------------------------

const Colors = struct {
    bg: [4]f64 = .{ 0.045, 0.052, 0.070, 0.97 },
    fg: [4]f64 = .{ 0.90, 0.92, 0.96, 1.0 },
    dim_fg: [4]f64 = .{ 0.70, 0.78, 0.90, 1.0 },
    accent: [4]f64 = .{ 0.25, 0.55, 0.90, 1.0 },
    accent_dim: [4]f64 = .{ 0.12, 0.15, 0.22, 1.0 },
    accent_text: [4]f64 = .{ 1.0, 1.0, 1.0, 1.0 },
    dim_text: [4]f64 = .{ 0.55, 0.60, 0.70, 1.0 },
};

const Config = struct {
    colors: Colors = .{},
    modules: []const u8 = "cpu mem temp bat net backlight volume clock",
    dark: bool = true,
    dark_explicit: bool = false,
    volume_step: i32 = 5,
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn parseColor(out: *[4]f64, value: []const u8) void {
    var it = std.mem.tokenizeAny(u8, value, " ,");
    var i: usize = 0;
    while (it.next()) |tok| {
        if (i >= 4) break;
        out[i] = std.fmt.parseFloat(f64, tok) catch return;
        i += 1;
    }
}

fn loadConfig(allocator: std.mem.Allocator) Config {
    var cfg = Config{};
    const home = std.posix.getenv("HOME") orelse "/root";
    const path = std.fs.path.join(allocator, &.{ home, ".config", "kairo", "bar.conf" }) catch return cfg;
    defer allocator.free(path);
    const text = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return cfg;
    defer allocator.free(text);

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = trim(line[1 .. line.len - 1]);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trim(line[0..eq]);
        const value = trim(line[eq + 1 ..]);
        if (std.mem.eql(u8, section, "colors")) {
            if (std.mem.eql(u8, key, "background")) parseColor(&cfg.colors.bg, value);
            if (std.mem.eql(u8, key, "foreground")) parseColor(&cfg.colors.fg, value);
            if (std.mem.eql(u8, key, "accent")) parseColor(&cfg.colors.accent, value);
            if (std.mem.eql(u8, key, "accent_dim")) parseColor(&cfg.colors.accent_dim, value);
        } else if (std.mem.eql(u8, section, "bar")) {
            if (std.mem.eql(u8, key, "dark")) {
                if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
                    cfg.dark = std.mem.eql(u8, value, "true");
                    cfg.dark_explicit = true;
                }
            }
            if (std.mem.eql(u8, key, "modules")) cfg.modules = value;
            if (std.mem.eql(u8, key, "volume_step")) {
                cfg.volume_step = std.fmt.parseInt(i32, value, 10) catch cfg.volume_step;
                if (cfg.volume_step <= 0) cfg.volume_step = 5;
                if (cfg.volume_step > 50) cfg.volume_step = 50;
            }
        }
    }
    return cfg;
}

/// Detect the user's GTK color scheme without spawning a subprocess. A
/// `prefer-dark` setting or a dark-suffixed GTK theme name switches the bar
/// palette; anything else falls back to the default dark palette.
fn detectGtkDark(allocator: std.mem.Allocator) bool {
    const home = std.posix.getenv("HOME") orelse "/root";
    const candidates = [_][]const u8{ "gtk-4.0", "gtk-3.0" };
    for (candidates) |sub| {
        const path = std.fs.path.join(allocator, &.{ home, ".config", sub, "settings.ini" }) catch continue;
        defer allocator.free(path);
        const text = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch continue;
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = trim(line[0..eq]);
            const value = trim(line[eq + 1 ..]);
            if (std.mem.eql(u8, key, "gtk-application-prefer-dark-theme")) {
                if (std.mem.eql(u8, value, "true")) return true;
                if (std.mem.eql(u8, value, "false")) return false;
            }
            if (std.mem.eql(u8, key, "gtk-theme")) {
                if (std.mem.indexOf(u8, value, "dark") != null or
                    std.mem.indexOf(u8, value, "Dark") != null) return true;
            }
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// System status modules. Plain /proc and /sys reads: no subprocesses.
// ---------------------------------------------------------------------------

const Cpu = struct {
    prev_total: u64 = 0,
    prev_idle: u64 = 0,
    percent: f64 = 0,

    fn update(self: *Cpu, allocator: std.mem.Allocator) void {
        const text = std.fs.cwd().readFileAlloc(allocator, "/proc/stat", 8 * 1024) catch return;
        defer allocator.free(text);
        var total: u64 = 0;
        var idle: u64 = 0;
        var found = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "cpu ")) continue;
            var it = std.mem.tokenizeAny(u8, line[4..], " ");
            while (it.next()) |tok| {
                const v = std.fmt.parseInt(u64, tok, 10) catch continue;
                total += v;
            }
            // Second field of "cpu " is idle, third is iowait.
            var it2 = std.mem.tokenizeAny(u8, line[4..], " ");
            if (it2.next()) |first| {
                idle = std.fmt.parseInt(u64, first, 10) catch 0;
                if (it2.next()) |iowait| {
                    idle += std.fmt.parseInt(u64, iowait, 10) catch 0;
                }
            }
            found = true;
            break;
        }
        if (!found or self.prev_total == 0) {
            self.prev_total = total;
            self.prev_idle = idle;
            return;
        }
        const dt = total -| self.prev_total;
        const di = idle -| self.prev_idle;
        self.prev_total = total;
        self.prev_idle = idle;
        if (dt > 0) {
            self.percent = 100.0 * @as(f64, @floatFromInt(dt - di)) / @as(f64, @floatFromInt(dt));
            if (self.percent < 0) self.percent = 0;
            if (self.percent > 100) self.percent = 100;
        }
    }
};

const Mem = struct {
    used_gib: f64 = 0,
    total_gib: f64 = 0,
    percent: f64 = 0,

    fn update(self: *Mem, allocator: std.mem.Allocator) void {
        const text = std.fs.cwd().readFileAlloc(allocator, "/proc/meminfo", 16 * 1024) catch return;
        defer allocator.free(text);
        var total_kb: u64 = 0;
        var avail_kb: u64 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                total_kb = parseKb(line) catch total_kb;
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                avail_kb = parseKb(line) catch avail_kb;
            }
        }
        if (total_kb == 0) return;
        self.total_gib = @as(f64, @floatFromInt(total_kb)) / (1024 * 1024);
        const used_kb = total_kb -| avail_kb;
        self.used_gib = @as(f64, @floatFromInt(used_kb)) / (1024 * 1024);
        self.percent = 100.0 * @as(f64, @floatFromInt(used_kb)) / @as(f64, @floatFromInt(total_kb));
    }

    fn parseKb(line: []const u8) !u64 {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next(); // label
        const num = it.next() orelse return error.Parse;
        return std.fmt.parseInt(u64, num, 10);
    }
};

const Thermal = struct {
    zones: std.ArrayList([]const u8) = .empty,
    celsius: f64 = 0,

    fn init(self: *Thermal, allocator: std.mem.Allocator) void {
        var dir = std.fs.cwd().openDir("/sys/class/thermal", .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "thermal_zone")) continue;
            const path = std.fs.path.join(allocator, &.{ "/sys/class/thermal", entry.name, "temp" }) catch continue;
            self.zones.append(allocator, path) catch {
                allocator.free(path);
                continue;
            };
        }
        std.mem.sort([]const u8, self.zones.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
    }

    fn deinit(self: *Thermal, allocator: std.mem.Allocator) void {
        for (self.zones.items) |p| allocator.free(p);
        self.zones.deinit(allocator);
    }

    fn update(self: *Thermal, allocator: std.mem.Allocator) void {
        var hottest: f64 = 0;
        for (self.zones.items) |path| {
            const text = std.fs.cwd().readFileAlloc(allocator, path, 32) catch continue;
            defer allocator.free(text);
            const t = std.fmt.parseFloat(f64, trim(text)) catch continue;
            const celsius = t / 1000.0;
            if (celsius > hottest) hottest = celsius;
        }
        if (hottest > 0) self.celsius = hottest;
    }
};

const Battery = struct {
    percent: f64 = 0,
    charging: bool = false,
    present: bool = false,
    capacity_path: ?[]const u8 = null,
    status_path: ?[]const u8 = null,

    fn init(self: *Battery, allocator: std.mem.Allocator) void {
        var dir = std.fs.cwd().openDir("/sys/class/power_supply", .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "BAT")) continue;
            const base = std.fs.path.join(allocator, &.{ "/sys/class/power_supply", entry.name }) catch continue;
            const cap = std.fs.path.join(allocator, &.{ base, "capacity" }) catch {
                allocator.free(base);
                continue;
            };
            const status = std.fs.path.join(allocator, &.{ base, "status" }) catch {
                allocator.free(base);
                allocator.free(cap);
                continue;
            };
            allocator.free(base);
            self.capacity_path = cap;
            self.status_path = status;
            self.present = true;
            return;
        }
    }

    fn deinit(self: *Battery, allocator: std.mem.Allocator) void {
        if (self.capacity_path) |p| allocator.free(p);
        if (self.status_path) |p| allocator.free(p);
    }

    fn update(self: *Battery, allocator: std.mem.Allocator) void {
        if (!self.present) return;
        const cap_text = std.fs.cwd().readFileAlloc(allocator, self.capacity_path.?, 16) catch return;
        defer allocator.free(cap_text);
        self.percent = std.fmt.parseFloat(f64, trim(cap_text)) catch self.percent;
        const status = std.fs.cwd().readFileAlloc(allocator, self.status_path.?, 16) catch return;
        defer allocator.free(status);
        self.charging = std.mem.indexOf(u8, status, "Charging") != null or
            std.mem.indexOf(u8, status, "Full") != null;
    }
};

const Backlight = struct {
    device_dir: ?[]const u8 = null,
    percent: f64 = 0,

    fn init(self: *Backlight, allocator: std.mem.Allocator) void {
        var dir = std.fs.cwd().openDir("/sys/class/backlight", .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            const base = std.fs.path.join(allocator, &.{ "/sys/class/backlight", entry.name }) catch continue;
            self.device_dir = base;
            return;
        }
    }

    fn deinit(self: *Backlight, allocator: std.mem.Allocator) void {
        if (self.device_dir) |p| allocator.free(p);
    }

    fn update(self: *Backlight, allocator: std.mem.Allocator) void {
        const dir_path = self.device_dir orelse return;
        var buf: [64]u8 = undefined;
        const cur = self.readInt(allocator, dir_path, "brightness") orelse return;
        const max = self.readInt(allocator, dir_path, "max_brightness") orelse return;
        if (max == 0) return;
        self.percent = 100.0 * @as(f64, @floatFromInt(cur)) / @as(f64, @floatFromInt(max));
        _ = &buf;
    }

    fn readInt(self: *Backlight, allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) ?u64 {
        _ = self;
        const path = std.fs.path.join(allocator, &.{ dir_path, name }) catch return null;
        defer allocator.free(path);
        const text = std.fs.cwd().readFileAlloc(allocator, path, 32) catch return null;
        defer allocator.free(text);
        return std.fmt.parseInt(u64, trim(text), 10) catch null;
    }

    /// Step the backlight. Needs write permission on the sysfs node; a normal
    /// user usually gets it through a udev rule. Fails quietly otherwise.
    fn step(self: *Backlight, allocator: std.mem.Allocator, delta_percent: f64) bool {
        const dir_path = self.device_dir orelse return false;
        const cur = self.readInt(allocator, dir_path, "brightness") orelse return false;
        const max = self.readInt(allocator, dir_path, "max_brightness") orelse return false;
        if (max == 0) return false;
        var value: i64 = @intFromFloat(@as(f64, @floatFromInt(cur)) + delta_percent / 100.0 * @as(f64, @floatFromInt(max)));
        if (value < 1) value = 1;
        if (value > @as(i64, @intCast(max))) value = @intCast(max);
        const path = std.fs.path.join(allocator, &.{ dir_path, "brightness" }) catch return false;
        defer allocator.free(path);
        const text = std.fmt.allocPrint(allocator, "{d}\n", .{value}) catch return false;
        defer allocator.free(text);
        const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return false;
        defer f.close();
        f.writeAll(text) catch return false;
        self.update(allocator);
        return true;
    }
};

const Net = struct {
    up: bool = false,
    wifi: bool = false,
    name_buf: [16]u8 = [_]u8{0} ** 16,
    name_len: usize = 0,
    signal_percent: f64 = 0,

    fn name(self: *const Net) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn update(self: *Net, allocator: std.mem.Allocator) void {
        self.up = false;
        self.wifi = false;
        var dir = std.fs.cwd().openDir("/sys/class/net", .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (std.mem.eql(u8, entry.name, "lo")) continue;
            const carrier_path = std.fs.path.join(allocator, &.{ "/sys/class/net", entry.name, "carrier" }) catch continue;
            defer allocator.free(carrier_path);
            const text = std.fs.cwd().readFileAlloc(allocator, carrier_path, 8) catch continue;
            defer allocator.free(text);
            if (trim(text).len == 0 or trim(text)[0] != '1') continue;
            self.up = true;
            self.wifi = std.mem.startsWith(u8, entry.name, "wl");
            const n = @min(entry.name.len, self.name_buf.len);
            @memcpy(self.name_buf[0..n], entry.name[0..n]);
            self.name_len = n;
            if (self.wifi) self.readSignal(allocator);
            return;
        }
    }

    fn readSignal(self: *Net, allocator: std.mem.Allocator) void {
        const text = std.fs.cwd().readFileAlloc(allocator, "/proc/net/wireless", 16 * 1024) catch return;
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len < self.name_len + 2) continue;
            if (!std.mem.eql(u8, trim(line[0..self.name_len]), self.name())) continue;
            // Columns: iface status link level noise ...
            var it = std.mem.tokenizeAny(u8, line, " :|");
            _ = it.next(); // iface
            _ = it.next(); // status
            _ = it.next(); // link quality
            const level = it.next() orelse break;
            const dbm = std.fmt.parseFloat(f64, level) catch break;
            // Map dBm (-100..-30) to 0..100 %, the usual convention.
            const clamped = @max(@min(dbm, -30.0), -100.0);
            self.signal_percent = (clamped + 100.0) * 100.0 / 70.0;
            return;
        }
    }
};

const Alsa = struct {
    percent: f64 = 0,
    muted: bool = false,
    capture_percent: f64 = 0,
    capture_muted: bool = false,
    ok: bool = false,
    mixer: ?*c.snd_mixer_t = null,
    volume_elem: ?*c.snd_mixer_elem_t = null,
    capture_elem: ?*c.snd_mixer_elem_t = null,

    fn init(self: *Alsa) void {
        if (c.snd_mixer_open(&self.mixer, 0) < 0) return;
        // When "default" is a PipeWire ALSA plugin and PipeWire is not
        // running, snd_mixer_attach aborts the process. Fall back to the
        // kernel mixer in that case; sound daemons usually expose
        // $XDG_RUNTIME_DIR/pipewire-0 when they are alive.
        const device = blk: {
            const runtime = std.posix.getenv("XDG_RUNTIME_DIR") orelse break :blk @as([]const u8, "default");
            const sock = std.fs.path.join(std.heap.page_allocator, &.{ runtime, "pipewire-0" }) catch break :blk @as([]const u8, "default");
            defer std.heap.page_allocator.free(sock);
            std.fs.cwd().access(sock, .{}) catch break :blk @as([]const u8, "hw:0");
            break :blk @as([]const u8, "default");
        };
        const dev_z = std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}", .{device}, 0) catch {
            _ = c.snd_mixer_close(self.mixer);
            self.mixer = null;
            return;
        };
        defer std.heap.page_allocator.free(dev_z);
        err: {
            if (c.snd_mixer_attach(self.mixer, dev_z.ptr) < 0) break :err;
            if (c.snd_mixer_selem_register(self.mixer, null, null) < 0) break :err;
            if (c.snd_mixer_load(self.mixer) < 0) break :err;
            self.ok = true;
            var it = c.snd_mixer_first_elem(self.mixer);
            while (it != null) : (it = c.snd_mixer_elem_next(it)) {
                if (c.snd_mixer_selem_is_active(it) == 0) continue;
                if (self.volume_elem == null and c.snd_mixer_selem_has_playback_volume(it) != 0) {
                    self.volume_elem = it;
                }
                if (self.capture_elem == null and c.snd_mixer_selem_has_capture_volume(it) != 0) {
                    self.capture_elem = it;
                }
            }
            return;
        }
        _ = c.snd_mixer_close(self.mixer);
        self.mixer = null;
    }

    fn deinit(self: *Alsa) void {
        if (self.mixer != null) _ = c.snd_mixer_close(self.mixer);
        self.mixer = null;
        self.ok = false;
    }

    fn update(self: *Alsa) void {
        if (!self.ok) return;
        if (c.snd_mixer_handle_events(self.mixer) < 0) return;
        if (self.volume_elem) |el| {
            var min: c_long = 0;
            var max: c_long = 0;
            if (c.snd_mixer_selem_get_playback_volume_range(el, &min, &max) == 0 and max > min) {
                var value: c_long = 0;
                if (c.snd_mixer_selem_get_playback_volume(el, c.SND_MIXER_SCHN_FRONT_LEFT, &value) == 0) {
                    self.percent = 100.0 * @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(max));
                }
            }
            var muted: c_int = 0;
            if (c.snd_mixer_selem_get_playback_switch(el, c.SND_MIXER_SCHN_FRONT_LEFT, &muted) == 0) {
                self.muted = muted == 0;
            }
        }
        if (self.capture_elem) |el| {
            var min: c_long = 0;
            var max: c_long = 0;
            if (c.snd_mixer_selem_get_capture_volume_range(el, &min, &max) == 0 and max > min) {
                var value: c_long = 0;
                if (c.snd_mixer_selem_get_capture_volume(el, c.SND_MIXER_SCHN_FRONT_LEFT, &value) == 0) {
                    self.capture_percent = 100.0 * @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(max));
                }
            }
            var muted: c_int = 0;
            if (c.snd_mixer_selem_get_capture_switch(el, c.SND_MIXER_SCHN_FRONT_LEFT, &muted) == 0) {
                self.capture_muted = muted == 0;
            }
        }
    }

    fn setVolume(self: *Alsa, delta_percent: f64) void {
        if (!self.ok or self.volume_elem == null) return;
        const el = self.volume_elem.?;
        var min: c_long = 0;
        var max: c_long = 0;
        if (c.snd_mixer_selem_get_playback_volume_range(el, &min, &max) != 0 or max <= min) return;
        var value: c_long = 0;
        if (c.snd_mixer_selem_get_playback_volume(el, c.SND_MIXER_SCHN_FRONT_LEFT, &value) != 0) return;
        var next: i64 = @intFromFloat(@as(f64, @floatFromInt(value)) + delta_percent / 100.0 * @as(f64, @floatFromInt(max)));
        if (next < min) next = min;
        if (next > max) next = max;
        _ = c.snd_mixer_selem_set_playback_volume_all(el, @intCast(next));
        self.update();
    }

    fn toggleMute(self: *Alsa) void {
        if (!self.ok or self.volume_elem == null) return;
        _ = c.snd_mixer_selem_set_playback_switch_all(self.volume_elem.?, if (self.muted) 1 else 0);
        self.update();
    }
};

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

const State = struct {
    tags: u32 = 1,
    tag_count: u32 = 9,
    layout_buf: [32]u8 = [_]u8{0} ** 32,
    layout_len: usize = 0,
    title_buf: [128]u8 = [_]u8{0} ** 128,
    title_len: usize = 0,
    locked: bool = false,

    fn layout(self: *const State) []const u8 {
        return self.layout_buf[0..self.layout_len];
    }

    fn setLayout(self: *State, value: []const u8) void {
        const n = @min(value.len, self.layout_buf.len);
        @memcpy(self.layout_buf[0..n], value[0..n]);
        self.layout_len = n;
    }

    fn title(self: *const State) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn setTitle(self: *State, value: []const u8) void {
        const n = @min(value.len, self.title_buf.len);
        @memcpy(self.title_buf[0..n], value[0..n]);
        self.title_len = n;
    }
};

const Ipc = struct {
    app: *App,
    fd: std.posix.fd_t,
    buffer: std.ArrayList(u8),

    fn create(app: *App) !*Ipc {
        const path = try socketPath(app.allocator);
        defer app.allocator.free(path);
        const fd = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer std.posix.close(fd);
        var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

        const self = try app.allocator.create(Ipc);
        errdefer app.allocator.destroy(self);
        self.* = .{
            .app = app,
            .fd = fd,
            .buffer = std.ArrayList(u8).empty,
        };
        return self;
    }

    fn destroy(self: *Ipc) void {
        std.posix.close(self.fd);
        self.buffer.deinit(self.app.allocator);
        self.app.allocator.destroy(self);
    }

    fn sendRequest(self: *Ipc, command: []const u8, args: []const u8, events: ?[]const []const u8) void {
        var w = proto.Writer.init(self.app.allocator);
        defer w.deinit();
        w.beginObject() catch return;
        w.key("command") catch return;
        w.string(command) catch return;
        if (args.len > 0) {
            w.key("args") catch return;
            w.string(args) catch return;
        }
        if (events) |list| {
            w.key("events") catch return;
            w.beginArray() catch return;
            for (list) |e| w.string(e) catch return;
            w.endArray() catch return;
        }
        w.endObject() catch return;
        w.raw("\n") catch return;
        const out = w.toOwnedSlice() catch return;
        defer self.app.allocator.free(out);
        var off: usize = 0;
        while (off < out.len) {
            const n = std.posix.write(self.fd, out[off..]) catch return;
            if (n == 0) return;
            off += n;
        }
    }

    fn readAvailable(self: *Ipc) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.app.dropIpc();
                    return;
                },
            };
            if (n == 0) {
                self.app.dropIpc();
                return;
            }
            self.buffer.appendSlice(self.app.allocator, buf[0..n]) catch {
                self.app.dropIpc();
                return;
            };
            if (self.buffer.items.len > 1024 * 1024) {
                self.app.dropIpc();
                return;
            }
            while (std.mem.indexOfScalar(u8, self.buffer.items, '\n')) |nl| {
                const line = self.buffer.items[0..nl];
                if (line.len > 0) self.process(line);
                const rest = self.buffer.items[nl + 1 ..];
                std.mem.copyForwards(u8, self.buffer.items[0..rest.len], rest);
                self.buffer.shrinkRetainingCapacity(rest.len);
            }
        }
    }

    fn process(self: *Ipc, line: []const u8) void {
        const app = self.app;
        var changed = false;
        if (jsonUintAfter(line, "\"active\":")) |active| {
            if (active <= 0xffff_ffff and app.state.tags != @as(u32, @intCast(active))) {
                app.state.tags = @intCast(active);
                changed = true;
            }
        }
        if (jsonStringAfter(line, "\"layout\":\"")) |layout| {
            if (!std.mem.eql(u8, layout, app.state.layout())) {
                app.state.setLayout(layout);
                changed = true;
            }
        }
        if (jsonUintAfter(line, "\"tag_count\":")) |count| {
            const n: u32 = @intCast(@min(count, 32));
            if (n != app.state.tag_count) {
                app.state.tag_count = n;
                changed = true;
            }
        }
        if (jsonBoolAfter(line, "\"locked\":")) |locked| {
            if (locked != app.state.locked) {
                app.state.locked = locked;
                changed = true;
            }
        }
        // Window events carry the focused window's title. The snapshot is a
        // flat array of window objects; pick the object with focused:true.
        if (std.mem.indexOf(u8, line, "\"focused\":true") != null) {
            if (extractFocusedTitle(line)) |title| {
                if (!std.mem.eql(u8, title, app.state.title())) {
                    app.state.setTitle(title);
                    changed = true;
                }
            } else if (app.state.title_len != 0) {
                app.state.title_len = 0;
                changed = true;
            }
        }
        if (changed) app.redrawAll();
    }
};

/// Return the "title" value of the window object that contains
/// "focused":true. Objects are top-level `{...}` entries; scan from the
/// focused marker outwards to its enclosing braces.
fn extractFocusedTitle(line: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, line, "\"focused\":true") orelse return null;
    var start = marker;
    while (start > 0) : (start -= 1) {
        if (line[start] == '{') break;
    }
    if (line[start] != '{') return null;
    var end = marker;
    // depth is signed: the marker can sit behind a '}' that closes an inner
    // object before we see its '{' while scanning forward.
    var depth: i64 = 0;
    var seen_open = false;
    while (end < line.len) : (end += 1) {
        if (line[end] == '{') {
            depth += 1;
            seen_open = true;
        }
        if (line[end] == '}') {
            depth -= 1;
            if (seen_open and depth == 0) break;
        }
    }
    if (end >= line.len) return null;
    const obj = line[start .. end + 1];
    const key = "\"title\":\"";
    const tpos = std.mem.indexOf(u8, obj, key) orelse return null;
    const begin = tpos + key.len;
    const quote = std.mem.indexOfScalarPos(u8, obj, begin, '"') orelse return null;
    return obj[begin..quote];
}

fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("KAIRO_SOCKET")) |p| return allocator.dupe(u8, p);
    const runtime = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ runtime, "kairo.sock" });
}

fn jsonUintAfter(line: []const u8, key: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    var i = start + key.len;
    while (i < line.len and line[i] == ' ') i += 1;
    const begin = i;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == begin) return null;
    return std.fmt.parseInt(u64, line[begin..i], 10) catch null;
}

fn jsonBoolAfter(line: []const u8, key: []const u8) ?bool {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[start + key.len ..];
    if (std.mem.startsWith(u8, rest, "true")) return true;
    if (std.mem.startsWith(u8, rest, "false")) return false;
    return null;
}

fn jsonStringAfter(line: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    const begin = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, begin, '"') orelse return null;
    return line[begin..end];
}

// ---------------------------------------------------------------------------
// Panel surface
// ---------------------------------------------------------------------------

const Panel = struct {
    app: *App,
    output: *c.struct_wl_output,
    surface: *c.struct_wl_surface,
    layer_surface: *c.struct_zwlr_layer_surface_v1,
    width: u32 = 0,
    height: u32 = BAR_HEIGHT,
    scale: i32 = 1,
    buffers: [2]?*c.struct_wl_buffer = .{ null, null },
    cairo_surfaces: [2]?*c.cairo_surface_t = .{ null, null },
    crs: [2]?*c.cairo_t = .{ null, null },
    busy: [2]bool = .{ false, false },
    next_index: usize = 0,
    dirty: bool = true,
    configured: bool = false,
    configure_listener: c.struct_zwlr_layer_surface_v1_listener,
    closed_listener: c.struct_zwlr_layer_surface_v1_listener,
    output_listener: c.struct_wl_output_listener,
    buffer_listener: c.struct_wl_buffer_listener,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_inside: bool = false,

    fn create(app: *App, output: *c.struct_wl_output) !*Panel {
        const compositor = app.compositor orelse return error.NoCompositor;
        const layer_shell = app.layer_shell orelse return error.NoLayerShell;
        const surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(surface);
        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            surface,
            output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            "kairo-bar",
        ) orelse return error.LayerSurfaceCreateFailed;
        errdefer c.zwlr_layer_surface_v1_destroy(layer_surface);
        const self = try app.allocator.create(Panel);
        errdefer app.allocator.destroy(self);
        self.* = .{
            .app = app,
            .output = output,
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
            .scale = 1,
        };
        _ = c.zwlr_layer_surface_v1_add_listener(layer_surface, &self.configure_listener, self);
        _ = c.wl_output_add_listener(output, &self.output_listener, self);
        c.zwlr_layer_surface_v1_set_size(layer_surface, 0, BAR_HEIGHT);
        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, @intCast(BAR_HEIGHT));
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(layer_surface, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        c.wl_surface_commit(surface);
        app.panels.append(app.allocator, self) catch {
            c.zwlr_layer_surface_v1_destroy(layer_surface);
            c.wl_surface_destroy(surface);
            app.allocator.destroy(self);
            return error.OutOfMemory;
        };
        return self;
    }

    fn destroy(self: *Panel) void {
        c.zwlr_layer_surface_v1_destroy(self.layer_surface);
        c.wl_surface_destroy(self.surface);
        self.destroyBuffers();
        self.app.allocator.destroy(self);
    }

    fn destroyBuffers(self: *Panel) void {
        for (0..2) |i| {
            if (self.crs[i]) |cr| c.cairo_destroy(cr);
            if (self.cairo_surfaces[i]) |surface| c.cairo_surface_destroy(surface);
            if (self.buffers[i]) |buffer| c.wl_buffer_destroy(buffer);
            self.crs[i] = null;
            self.cairo_surfaces[i] = null;
            self.buffers[i] = null;
            self.busy[i] = false;
        }
        self.next_index = 0;
    }

    fn ensureBuffers(self: *Panel) !void {
        if (self.width == 0) return error.NotConfigured;
        const scale: u32 = @intCast(@max(1, self.scale));
        const pixel_width = self.width * scale;
        const pixel_height = self.height * scale;
        if (self.buffers[0] != null and self.buffers[1] != null and
            self.cairo_surfaces[0] != null and self.cairo_surfaces[1] != null)
        {
            const w = c.cairo_image_surface_get_width(self.cairo_surfaces[0].?);
            if (w == @as(c_int, @intCast(pixel_width))) return;
        }
        self.destroyBuffers();
        const stride: i32 = @intCast(pixel_width * 4);
        const size: usize = @intCast(stride * @as(i32, @intCast(pixel_height)));
        for (0..2) |i| {
            const fd = c.memfd_create("kairo-bar", 0);
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
            ) orelse {
                c.wl_buffer_destroy(buffer);
                return error.CairoSurfaceFailed;
            };
            const cr = c.cairo_create(cairo_surface) orelse {
                c.cairo_surface_destroy(cairo_surface);
                c.wl_buffer_destroy(buffer);
                return error.CairoContextFailed;
            };
            self.buffers[i] = buffer;
            self.cairo_surfaces[i] = cairo_surface;
            self.crs[i] = cr;
            self.busy[i] = false;
            _ = c.wl_buffer_add_listener(buffer, &self.buffer_listener, self);
        }
        c.wl_surface_set_buffer_scale(self.surface, @intCast(scale));
    }

    fn setColor(cr: ?*c.cairo_t, color: [4]f64) void {
        c.cairo_set_source_rgba(cr, color[0], color[1], color[2], color[3]);
    }

    fn drawText(cr: ?*c.cairo_t, x: f64, baseline: f64, text: []const u8, color: [4]f64) f64 {
        if (text.len == 0) return 0;
        var buf: [256]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0; // cairo reads a NUL-terminated string
        c.cairo_set_source_rgba(cr, color[0], color[1], color[2], color[3]);
        c.cairo_move_to(cr, x, baseline);
        c.cairo_show_text(cr, buf[0..n :0].ptr);
        var extents: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(cr, buf[0..n :0].ptr, &extents);
        return extents.x_advance;
    }

    fn textWidth(cr: ?*c.cairo_t, text: []const u8) f64 {
        if (text.len == 0) return 0;
        var buf: [256]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        var extents: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(cr, buf[0..n :0].ptr, &extents);
        return extents.x_advance;
    }

    fn draw(self: *Panel) void {
        if (!self.configured) return;
        self.ensureBuffers() catch |err| {
            std.debug.print("kairo-bar: panel buffer: {s}\n", .{@errorName(err)});
            return;
        };
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
        const colors = self.app.config.colors;
        const scale: f64 = @floatFromInt(@max(1, self.scale));

        c.cairo_save(cr);
        c.cairo_scale(cr, scale, scale);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        setColor(cr, colors.bg);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

        const baseline: f64 = 21;
        const height: f64 = @floatFromInt(self.height);

        // Accent line along the bottom edge.
        setColor(cr, colors.accent);
        c.cairo_set_source_rgba(cr, colors.accent[0], colors.accent[1], colors.accent[2], 0.85);
        c.cairo_rectangle(cr, 0, height - 1, @floatFromInt(self.width), 1);
        c.cairo_fill(cr);

        c.cairo_select_font_face(cr, "sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(cr, 12);

        var x: f64 = TAG_START;

        // Tag buttons.
        const tag_count = @min(self.app.state.tag_count, MAX_TAG_BUTTONS);
        var i: u32 = 0;
        while (i < tag_count) : (i += 1) {
            const active = (self.app.state.tags & (@as(u32, 1) << @intCast(i))) != 0;
            setColor(cr, if (active) colors.accent else colors.accent_dim);
            c.cairo_rectangle(cr, x, 6, TAG_WIDTH, 20);
            c.cairo_fill(cr);
            var text_buf: [4]u8 = undefined;
            const text = std.fmt.bufPrint(text_buf[0..3], "{d}", .{i + 1}) catch "1";
            text_buf[text.len] = 0;
            c.cairo_set_source_rgba(cr, if (active) colors.accent_text[0] else colors.dim_text[0], if (active) colors.accent_text[1] else colors.dim_text[1], if (active) colors.accent_text[2] else colors.dim_text[2], 1.0);
            var extents: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(cr, text_buf[0..text.len :0].ptr, &extents);
            c.cairo_move_to(cr, x + (TAG_WIDTH - extents.width) / 2 - extents.x_bearing, baseline);
            c.cairo_show_text(cr, text_buf[0..text.len :0].ptr);
            x += TAG_WIDTH + TAG_GAP;
        }
        x += 6;

        // Focused window title (if it fits).
        const title = self.app.state.title();
        if (title.len > 0) {
            const w = textWidth(cr, title);
            if (w <= TITLE_MAX) {
                _ = drawText(cr, x, baseline, title, colors.dim_fg);
                x += w + 12;
            } else {
                // Truncate to fit the reserved title area.
                var len = title.len;
                while (len > 1) {
                    len -= 1;
                    var buf: [128]u8 = undefined;
                    const n = @min(len, buf.len - 4);
                    @memcpy(buf[0..n], title[0..n]);
                    @memcpy(buf[n..][0..3], "...");
                    if (textWidth(cr, buf[0 .. n + 3]) <= TITLE_MAX) {
                        _ = drawText(cr, x, baseline, buf[0 .. n + 3], colors.dim_fg);
                        break;
                    }
                }
                x += TITLE_MAX + 8;
            }
        }

        // Right-aligned status modules.
        const stats = &self.app.stats;
        var parts: [10][64]u8 = undefined;
        var lens: [10]usize = .{0} ** 10;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, self.app.config.modules, " ,");
        while (it.next()) |module| {
            if (count >= parts.len) break;
            var text: []const u8 = "";
            if (std.mem.eql(u8, module, "cpu")) {
                text = std.fmt.bufPrint(&parts[count], "CPU {d:.0}%", .{@round(stats.cpu.percent)}) catch "";
            } else if (std.mem.eql(u8, module, "mem")) {
                text = std.fmt.bufPrint(&parts[count], "MEM {d:.1}G", .{stats.mem.used_gib}) catch "";
            } else if (std.mem.eql(u8, module, "temp")) {
                if (stats.thermal.celsius > 0)
                    text = std.fmt.bufPrint(&parts[count], "{d:.0}°C", .{@round(stats.thermal.celsius)}) catch "";
            } else if (std.mem.eql(u8, module, "bat")) {
                if (stats.battery.present)
                    text = std.fmt.bufPrint(&parts[count], "BAT {d:.0}%{s}", .{ @round(stats.battery.percent), if (stats.battery.charging) "+" else "" }) catch "";
            } else if (std.mem.eql(u8, module, "net")) {
                if (stats.net.up) {
                    if (stats.net.wifi)
                        text = std.fmt.bufPrint(&parts[count], "{s} {d:.0}%", .{ stats.net.name(), @round(stats.net.signal_percent) }) catch ""
                    else
                        text = std.fmt.bufPrint(&parts[count], "{s}", .{stats.net.name()}) catch "";
                } else text = "offline";
            } else if (std.mem.eql(u8, module, "backlight")) {
                if (stats.backlight.device_dir != null)
                    text = std.fmt.bufPrint(&parts[count], "BR {d:.0}%", .{@round(stats.backlight.percent)}) catch "";
            } else if (std.mem.eql(u8, module, "volume")) {
                if (stats.alsa.ok and stats.alsa.volume_elem != null) {
                    if (stats.alsa.muted) {
                        text = "VOL mute";
                    } else {
                        text = std.fmt.bufPrint(&parts[count], "VOL {d:.0}%", .{@round(stats.alsa.percent)}) catch "";
                    }
                }
            } else if (std.mem.eql(u8, module, "clock")) {
                const now: c.time_t = c.time(null);
                var tm: c.struct_tm = undefined;
                _ = c.localtime_r(&now, &tm);
                var clock_buf: [16]u8 = undefined;
                const clock_len = c.strftime(&clock_buf, clock_buf.len, "%H:%M", &tm);
                if (clock_len > 0) {
                    const n = @min(@as(usize, @intCast(clock_len)), parts[count].len);
                    @memcpy(parts[count][0..n], clock_buf[0..n]);
                    text = parts[count][0..n];
                }
            } else continue;
            if (text.len > 0) {
                lens[count] = text.len;
                count += 1;
            }
        }

        // Measure from the right edge backwards.
        var widths: [10]f64 = .{0} ** 10;
        var total: f64 = 0;
        var k: usize = 0;
        while (k < count) : (k += 1) {
            widths[k] = textWidth(cr, parts[k][0..lens[k]]);
            total += widths[k] + 14;
        }

        var rx: f64 = @as(f64, @floatFromInt(self.width)) - 12;
        k = count;
        while (k > 0) {
            k -= 1;
            rx -= widths[k] + 7;
            self.app.module_positions[k] = rx; // remember x for click hit-testing
            _ = drawText(cr, rx, baseline, parts[k][0..lens[k]], if (k == 0) colors.fg else colors.dim_fg);
        }
        // Store module metadata for pointer hit tests (copies, not stack refs).
        var m: usize = 0;
        while (m < count) : (m += 1) {
            const n = @min(lens[m], self.app.module_texts[m].len);
            @memcpy(self.app.module_texts[m][0..n], parts[m][0..n]);
            self.app.module_lens[m] = n;
        }
        self.app.module_count = count;

        c.cairo_restore(cr);

        c.wl_surface_attach(self.surface, self.buffers[idx], 0, 0);
        c.wl_surface_damage_buffer(self.surface, 0, 0, @intCast(self.width * @as(u32, @intCast(@max(1, self.scale)))), @intCast(self.height * @as(u32, @intCast(@max(1, self.scale)))));
        c.wl_surface_commit(self.surface);
        self.busy[idx] = true;
        self.dirty = false;
    }

    fn tagAt(self: *Panel, x: f64, y: f64) ?u32 {
        if (y < 6 or y > 26) return null;
        const tag_count = @min(self.app.state.tag_count, MAX_TAG_BUTTONS);
        var i: u32 = 0;
        while (i < tag_count) : (i += 1) {
            const start = TAG_START + @as(f64, @floatFromInt(i)) * (TAG_WIDTH + TAG_GAP);
            if (x >= start and x <= start + TAG_WIDTH) return i + 1;
        }
        return null;
    }

    /// Index into the app's module list whose text box contains x.
    fn moduleAt(self: *Panel, x: f64) ?usize {
        const app = self.app;
        const cr = self.crs[0] orelse return null;
        var i: usize = 0;
        while (i < app.module_count) : (i += 1) {
            const w = textWidth(cr, app.module_texts[i][0..app.module_lens[i]]);
            const left = app.module_positions[i];
            if (x >= left and x <= left + w + 14) return i;
        }
        return null;
    }

    fn invalidate(self: *Panel) void {
        self.dirty = true;
        self.draw();
    }

    fn handleConfigure(data: ?*anyopaque, layer_surface: ?*c.struct_zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
        _ = layer_surface;
        const self: *Panel = @ptrCast(@alignCast(data.?));
        c.zwlr_layer_surface_v1_ack_configure(self.layer_surface, serial);
        self.width = width;
        self.height = height;
        self.configured = true;
        self.dirty = true;
        self.draw();
    }

    fn handleClosed(data: ?*anyopaque, layer_surface: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
        _ = layer_surface;
        const self: *Panel = @ptrCast(@alignCast(data.?));
        self.app.removePanel(self);
    }

    fn handleBufferRelease(data: ?*anyopaque, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
        const self: *Panel = @ptrCast(@alignCast(data.?));
        for (0..2) |i| {
            if (self.buffers[i] == buffer) {
                self.busy[i] = false;
                break;
            }
        }
        if (self.dirty) self.draw();
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
        const self: *Panel = @ptrCast(@alignCast(data.?));
        if (factor != self.scale and factor > 0) {
            self.scale = factor;
            self.invalidate();
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

const Stats = struct {
    cpu: Cpu = .{},
    mem: Mem = .{},
    thermal: Thermal = .{},
    battery: Battery = .{},
    backlight: Backlight = .{},
    net: Net = .{},
    alsa: Alsa = .{},

    fn init(self: *Stats, allocator: std.mem.Allocator) void {
        self.thermal.init(allocator);
        self.battery.init(allocator);
        self.backlight.init(allocator);
        self.alsa.init();
        if (!self.alsa.ok) {
            std.debug.print("kairo-bar: ALSA mixer unavailable, volume module disabled\n", .{});
        }
    }

    fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        self.thermal.deinit(allocator);
        self.battery.deinit(allocator);
        self.backlight.deinit(allocator);
        self.alsa.deinit();
    }

    fn update(self: *Stats, allocator: std.mem.Allocator) void {
        self.cpu.update(allocator);
        self.mem.update(allocator);
        self.thermal.update(allocator);
        self.battery.update(allocator);
        self.backlight.update(allocator);
        self.net.update(allocator);
        self.alsa.update();
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
    panels: std.ArrayList(*Panel),
    outputs: std.ArrayList(*c.struct_wl_output),
    state: State = .{},
    stats: Stats = .{},
    config: Config,
    ipc: ?*Ipc = null,
    registry_listener: c.struct_wl_registry_listener,
    seat_listener: c.struct_wl_seat_listener,
    pointer_listener: c.struct_wl_pointer_listener,
    pointer_panel: ?*Panel = null,
    pointer_button_serial: u32 = 0,
    initialized: bool = false,
    tick_counter: u32 = 0,
    last_tick: i64 = 0,
    module_texts: [10][64]u8 = .{[_]u8{0} ** 64} ** 10,
    module_lens: [10]usize = .{0} ** 10,
    module_positions: [10]f64 = .{0} ** 10,
    module_count: usize = 0,
    modules_right_edge: f64 = 0,

    fn init(allocator: std.mem.Allocator, display: *c.struct_wl_display) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .panels = std.ArrayList(*Panel).empty,
            .outputs = std.ArrayList(*c.struct_wl_output).empty,
            .config = blk: {
                var cfg = loadConfig(allocator);
                if (!cfg.dark_explicit) cfg.dark = detectGtkDark(allocator);
                break :blk cfg;
            },
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
        if (!self.config.dark) applyLightPalette(&self.config.colors);
        self.registry = c.wl_display_get_registry(self.display) orelse return error.RegistryFailed;
        _ = c.wl_registry_add_listener(self.registry, &self.registry_listener, self);
        return self;
    }

    fn applyLightPalette(colors: *Colors) void {
        colors.bg = .{ 0.93, 0.94, 0.96, 0.97 };
        colors.fg = .{ 0.10, 0.12, 0.16, 1.0 };
        colors.dim_fg = .{ 0.20, 0.26, 0.38, 1.0 };
        colors.accent = .{ 0.20, 0.48, 0.85, 1.0 };
        colors.accent_dim = .{ 0.82, 0.86, 0.92, 1.0 };
        colors.accent_text = .{ 1.0, 1.0, 1.0, 1.0 };
        colors.dim_text = .{ 0.25, 0.30, 0.40, 1.0 };
    }

    fn start(self: *App) !void {
        _ = c.wl_display_roundtrip(self.display);
        _ = c.wl_display_roundtrip(self.display);
        if (self.compositor == null or self.shm == null or self.layer_shell == null) {
            std.debug.print("kairo-bar: missing compositor/shm/layer-shell globals\n", .{});
            return error.MissingGlobal;
        }
        if (self.seat) |seat| _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
        for (self.outputs.items) |output| {
            _ = Panel.create(self, output) catch |err| {
                std.debug.print("kairo-bar: panel creation failed: {s}\n", .{@errorName(err)});
            };
        }
        self.initialized = true;
        self.ipc = Ipc.create(self) catch |err| blk: {
            std.debug.print("kairo-bar: IPC unavailable: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        if (self.ipc) |ipc| {
            ipc.sendRequest("subscribe", "", &.{ "tag", "output", "session", "window" });
            ipc.sendRequest("query", "", null);
        }
        self.stats.init(self.allocator);
        self.stats.update(self.allocator);
        self.last_tick = std.time.milliTimestamp();
    }

    fn deinit(self: *App) void {
        self.stats.deinit(self.allocator);
        if (self.ipc) |ipc| {
            self.ipc = null;
            ipc.destroy();
        }
        while (self.panels.items.len > 0) {
            self.panels.items[0].destroy();
            _ = self.panels.orderedRemove(0);
        }
        self.panels.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        c.wl_display_disconnect(self.display);
        self.allocator.destroy(self);
    }

    fn dropIpc(self: *App) void {
        if (self.ipc) |ipc| {
            self.ipc = null;
            ipc.destroy();
        }
    }

    fn removePanel(self: *App, panel: *Panel) void {
        for (self.panels.items, 0..) |item, i| {
            if (item == panel) {
                _ = self.panels.orderedRemove(i);
                break;
            }
        }
        if (self.pointer_panel == panel) self.pointer_panel = null;
        panel.destroy();
    }

    fn redrawAll(self: *App) void {
        for (self.panels.items) |panel| panel.invalidate();
    }

    fn tick(self: *App) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_tick < 1000) return;
        self.last_tick = now;
        self.tick_counter += 1;
        if (self.tick_counter % STATS_TICK_DIVIDER == 0) {
            self.stats.update(self.allocator);
        }
        self.redrawAll();
    }

    fn dispatchTag(self: *App, tag: u32) void {
        var buf: [32]u8 = undefined;
        const args = std.fmt.bufPrint(&buf, "view_tag {d}", .{tag}) catch return;
        if (self.ipc) |ipc| ipc.sendRequest("dispatch", args, null);
    }

    fn volumeAction(self: *App, action: enum { toggle, up, down }) void {
        switch (action) {
            .toggle => self.app_alsa().toggleMute(),
            .up => self.app_alsa().setVolume(@floatFromInt(self.config.volume_step)),
            .down => self.app_alsa().setVolume(-@as(f64, @floatFromInt(self.config.volume_step))),
        }
        self.redrawAll();
    }

    fn app_alsa(self: *App) *Alsa {
        return &self.stats.alsa;
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
                _ = Panel.create(self, output) catch |err| std.debug.print("kairo-bar: hotplug panel: {s}\n", .{@errorName(err)});
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
        for (self.panels.items) |panel| {
            if (panel.surface == surface) {
                self.pointer_panel = panel;
                panel.pointer_x = c.wl_fixed_to_double(sx);
                panel.pointer_y = c.wl_fixed_to_double(sy);
                panel.pointer_inside = true;
                return;
            }
        }
        self.pointer_panel = null;
    }

    fn handlePointerLeave(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
        _ = pointer;
        _ = serial;
        _ = surface;
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.pointer_panel) |p| p.pointer_inside = false;
        self.pointer_panel = null;
    }

    fn handlePointerMotion(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.pointer_panel) |panel| {
            panel.pointer_x = c.wl_fixed_to_double(sx);
            panel.pointer_y = c.wl_fixed_to_double(sy);
        }
    }

    fn handlePointerButton(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *App = @ptrCast(@alignCast(data.?));
        self.pointer_button_serial = serial;
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED or button != 0x110) return;
        const panel = self.pointer_panel orelse return;
        if (panel.tagAt(panel.pointer_x, panel.pointer_y)) |tag| {
            self.dispatchTag(tag);
            return;
        }
        if (panel.moduleAt(panel.pointer_x)) |m| {
            const name = self.module_texts[m][0..self.module_lens[m]];
            if (std.mem.startsWith(u8, name, "VOL")) {
                self.volumeAction(.toggle);
            } else if (std.mem.startsWith(u8, name, "BR")) {
                // Left click steps brightness up.
                _ = self.stats.backlight.step(self.allocator, @floatFromInt(self.config.volume_step));
                self.redrawAll();
            }
        }
    }

    fn handlePointerAxis(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *App = @ptrCast(@alignCast(data.?));
        if (axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL) return;
        const panel = self.pointer_panel orelse return;
        const delta = c.wl_fixed_to_double(value);
        if (panel.tagAt(panel.pointer_x, panel.pointer_y) != null) {
            // Scrolling the tags switches workspaces, like Mango.
            const args = if (delta > 0) "view_tag next" else "view_tag prev";
            if (self.ipc) |ipc| ipc.sendRequest("dispatch", args, null);
            return;
        }
        if (panel.moduleAt(panel.pointer_x)) |m| {
            const name = self.module_texts[m][0..self.module_lens[m]];
            if (std.mem.startsWith(u8, name, "VOL")) {
                self.volumeAction(if (delta > 0) .down else .up);
            } else if (std.mem.startsWith(u8, name, "BR")) {
                const d: f64 = @floatFromInt(self.config.volume_step);
                if (self.stats.backlight.step(self.allocator, if (delta > 0) -d else d)) self.redrawAll();
            }
        }
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
        \\Kairo Bar — the native status bar for the Kairo desktop
        \\
        \\Usage: kairo-bar [--version] [--help]
        \\
        \\The bar connects to WAYLAND_DISPLAY and $XDG_RUNTIME_DIR/kairo.sock.
        \\Configure it in ~/.config/kairo/bar.conf ([bar] modules,
        \\[colors] background/foreground/accent).
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
            try std.fs.File.stdout().writeAll("kairo-bar 0.5.0\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        }
        std.debug.print("kairo-bar: unknown argument '{s}'\n", .{arg});
        usage();
        std.process.exit(2);
    }
    const display = c.wl_display_connect(null) orelse {
        std.debug.print("kairo-bar: cannot connect to Wayland\n", .{});
        return error.WaylandConnectFailed;
    };
    const app = try App.init(allocator, display);
    defer app.deinit();
    app.start() catch |err| {
        std.debug.print("kairo-bar: startup failed: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("kairo-bar: bar ready\n", .{});
    const display_fd = c.wl_display_get_fd(display);
    while (true) {
        _ = c.wl_display_flush(display);
        var fds = [2]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.ipc) |ipc| ipc.fd else -1, .events = c.POLLIN, .revents = 0 },
        };
        const rc = c.poll(&fds, fds.len, 250);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            std.debug.print("kairo-bar: poll failed\n", .{});
            break;
        }
        if (fds[0].revents & (c.POLLERR | c.POLLHUP) != 0) break;
        if (fds[0].revents & c.POLLIN != 0) {
            if (c.wl_display_dispatch(display) == -1) break;
        }
        if (app.ipc) |ipc| {
            if (fds[1].revents & (c.POLLERR | c.POLLHUP) != 0) {
                app.dropIpc();
            } else if (fds[1].revents & c.POLLIN != 0) {
                ipc.readAvailable();
            }
        }
        app.tick();
    }
}
