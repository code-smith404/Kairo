//! kairo-screenshot — capture the screen through zwlr_screencopy_manager_v1
//! and write a PNG. No shell out, no subprocess, no subprocess screenshots.
//!
//! Usage: kairo-screenshot [--output PATH] [--dir DIR] [--output-name NAME]

const std = @import("std");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("wayland-client.h");
    @cInclude("wlr-screencopy-unstable-v1-client-protocol.h");
    @cInclude("time.h");
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const Version = "0.5.0";

const Capture = struct {
    display: *c.struct_wl_display,
    shm: ?*c.struct_wl_shm = null,
    manager: ?*c.struct_zwlr_screencopy_manager_v1 = null,
    output: ?*c.struct_wl_output = null,
    output_name: ?[]const u8 = null,
    // Frame state
    frame: ?*c.struct_zwlr_screencopy_frame_v1 = null,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,
    have_info: bool = false,
    ready: bool = false,
    failed: bool = false,
    pool: ?*c.struct_wl_shm_pool = null,
    buffer: ?*c.struct_wl_buffer = null,
    data: ?[*]u8 = null,
    size: usize = 0,
    swap_rb: bool = false,

    fn globalsListener(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
        _ = version;
        const self: *Capture = @ptrCast(@alignCast(data.?));
        const interface = std.mem.span(iface);
        if (std.mem.eql(u8, interface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, interface, "zwlr_screencopy_manager_v1")) {
            self.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_screencopy_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, interface, "wl_output")) {
            // Bind all outputs; pick the first (or a named one) after roundtrip.
            const out: *c.struct_wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 4));
            if (self.output == null) self.output = out;
        }
    }

    fn globalsRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
    }

    fn frameBuffer(data: ?*anyopaque, frame: ?*c.struct_zwlr_screencopy_frame_v1, format: u32, w: u32, h: u32, stride: u32) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(data.?));
        self.width = w;
        self.height = h;
        self.stride = stride;
        self.format = format;
        // Memory layout: ARGB8888/XRGB8888 is B,G,R,A; XBGR/ABGR is R,G,B,A.
        self.swap_rb = format == c.WL_SHM_FORMAT_XBGR8888 or format == c.WL_SHM_FORMAT_ABGR8888;
        self.createBuffer();
        _ = c.zwlr_screencopy_frame_v1_copy(frame, self.buffer);
    }

    fn createBuffer(self: *Capture) void {
        const shm = self.shm orelse return;
        const size = @as(usize, self.stride) * self.height;
        const fd = c.memfd_create("kairo-screenshot", 0);
        if (fd < 0) return;
        defer _ = c.close(fd);
        _ = c.ftruncate(fd, @intCast(size));
        const data = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (data == c.MAP_FAILED) return;
        @memset(@as([*]u8, @ptrCast(data))[0..size], 0);
        self.data = @ptrCast(data);
        self.size = size;
        self.pool = c.wl_shm_create_pool(shm, fd, @intCast(size));
        self.buffer = c.wl_shm_pool_create_buffer(self.pool, 0, @intCast(self.width), @intCast(self.height), @intCast(self.stride), self.format);
    }

    fn frameFlags(data: ?*anyopaque, frame: ?*c.struct_zwlr_screencopy_frame_v1, flags: u32) callconv(.c) void {
        _ = data;
        _ = frame;
        _ = flags;
    }

    fn frameReady(data: ?*anyopaque, frame: ?*c.struct_zwlr_screencopy_frame_v1, t1: u32, t2: u32, t3: u32) callconv(.c) void {
        _ = frame;
        _ = t1;
        _ = t2;
        _ = t3;
        const self: *Capture = @ptrCast(@alignCast(data.?));
        self.ready = true;
    }

    fn frameFailed(data: ?*anyopaque, frame: ?*c.struct_zwlr_screencopy_frame_v1) callconv(.c) void {
        _ = frame;
        const self: *Capture = @ptrCast(@alignCast(data.?));
        self.failed = true;
    }

    fn frameDamage(data: ?*anyopaque, frame: ?*c.struct_zwlr_screencopy_frame_v1, x: u32, y: u32, w: u32, h: u32) callconv(.c) void {
        _ = data;
        _ = frame;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
    }

    fn frameDmabuf(data: ?*anyopaque, frame: ?*c.struct_zwlr_screencopy_frame_v1, dev: [*c]c.struct_wl_array, format: u32) callconv(.c) void {
        _ = data;
        _ = frame;
        _ = dev;
        _ = format;
    }

    fn frameBufferDone(data: ?*anyopaque, frame: ?*c.struct_zwlr_screencopy_frame_v1) callconv(.c) void {
        _ = data;
        _ = frame;
    }
};

/// Minimal PNG writer: 8-bit RGB. The zlib stream is built from raw deflate
/// "stored" blocks — the only deflate encoding that needs no compression
/// engine, since Zig 0.15.2's std flate encoder is incomplete. Screenshots
/// are therefore uncompressed but fully valid PNGs.
const PngWriter = struct {
    fn writeChunk(file: std.fs.File, kind: *const [4]u8, payload: []const u8) !void {
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(payload.len), .big);
        @memcpy(header[4..8], kind);
        try file.writeAll(&header);
        try file.writeAll(payload);
        var crc = std.hash.Crc32.init();
        crc.update(kind[0..]);
        crc.update(payload);
        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, crc_buf[0..4], crc.final(), .big);
        try file.writeAll(&crc_buf);
    }

    fn adler32(data: []const u8) u32 {
        const prime: u32 = 65521;
        var a: u32 = 1;
        var b: u32 = 0;
        var i: usize = 0;
        while (i < data.len) {
            const end = @min(i + 5550, data.len); // avoid overflow between mods
            while (i < end) : (i += 1) {
                a += data[i];
                b += a;
            }
            a %= prime;
            b %= prime;
        }
        return (b << 16) | a;
    }

    /// zlib (RFC 1950) wrapper around a raw deflate stream made of stored
    /// blocks (RFC 1951 BTYPE=00).
    fn zlibStored(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, &.{ 0x78, 0x01 }); // CMF/FLG: deflate, 32K window
        var rest = raw;
        while (rest.len > 0) {
            const n: u16 = @intCast(@min(rest.len, 65535));
            const final: u8 = if (rest.len == n) 1 else 0;
            try out.append(allocator, final); // BFINAL bit + BTYPE=00, byte aligned
            var lenb: [4]u8 = undefined;
            std.mem.writeInt(u16, lenb[0..2], n, .little);
            std.mem.writeInt(u16, lenb[2..4], n ^ 0xffff, .little);
            try out.appendSlice(allocator, &lenb);
            try out.appendSlice(allocator, rest[0..n]);
            rest = rest[n..];
        }
        var adler: [4]u8 = undefined;
        std.mem.writeInt(u32, adler[0..4], adler32(raw), .big);
        try out.appendSlice(allocator, &adler);
        return out.toOwnedSlice(allocator);
    }

    fn write(allocator: std.mem.Allocator, path: []const u8, width: u32, height: u32, rgb: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("\x89PNG\r\n\x1a\n");

        // IHDR: width, height, bit depth 8, color type 2 (truecolor).
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], width, .big);
        std.mem.writeInt(u32, ihdr[4..8], height, .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 2; // color type RGB
        ihdr[10] = 0; // compression
        ihdr[11] = 0; // filter
        ihdr[12] = 0; // interlace
        try writeChunk(file, "IHDR", &ihdr);

        // Raw scanlines with filter byte 0.
        const row_len = 1 + @as(usize, width) * 3;
        const raw = try allocator.alloc(u8, height * row_len);
        defer allocator.free(raw);
        var y: usize = 0;
        while (y < height) : (y += 1) {
            raw[y * row_len] = 0;
            const src_row = rgb[y * @as(usize, width) * 3 ..][0 .. @as(usize, width) * 3];
            @memcpy(raw[y * row_len + 1 ..][0 .. @as(usize, width) * 3], src_row);
        }

        const idat = try zlibStored(allocator, raw);
        defer allocator.free(idat);
        try writeChunk(file, "IDAT", idat);
        try writeChunk(file, "IEND", "");
    }
};

fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = std.posix.getenv("XDG_PICTURES_DIR") orelse std.posix.getenv("HOME") orelse "/tmp";
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);
    var stamp: [40]u8 = undefined;
    const len = c.strftime(&stamp, stamp.len, "%Y%m%d-%H%M%S", &tm);
    return std.fmt.allocPrint(allocator, "{s}/kairo-{s}.png", .{ dir, stamp[0..@intCast(len)] });
}

fn usage() void {
    std.fs.File.stdout().writeAll(
        \\kairo-screenshot — capture a Kairo output to PNG
        \\
        \\Usage: kairo-screenshot [--output PATH] [--dir DIR] [--output-name NAME] [--version] [--help]
        \\
        \\Requires a compositor that advertises zwlr_screencopy_manager_v1
        \\(Kairo does). Without --output the file is written to
        \\$XDG_PICTURES_DIR (or $HOME) as kairo-<timestamp>.png.
        \\
    ) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var out_path: ?[]const u8 = null;
    var dir_override: ?[]const u8 = null;
    var output_name: ?[]const u8 = null;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            try std.fs.File.stdout().writeAll("kairo-screenshot " ++ Version ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        } else if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            out_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--dir") and i + 1 < args.len) {
            dir_override = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--output-name") and i + 1 < args.len) {
            output_name = args[i + 1];
            i += 1;
        } else {
            std.debug.print("kairo-screenshot: unknown argument '{s}'\n", .{arg});
            usage();
            std.process.exit(2);
        }
    }

    const display = c.wl_display_connect(null) orelse {
        std.debug.print("kairo-screenshot: cannot connect to Wayland\n", .{});
        return error.WaylandConnectFailed;
    };
    defer c.wl_display_disconnect(display);

    var cap = Capture{ .display = display };
    var listener = c.struct_wl_registry_listener{
        .global = Capture.globalsListener,
        .global_remove = Capture.globalsRemove,
    };
    const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
    _ = c.wl_registry_add_listener(registry, &listener, &cap);
    _ = c.wl_display_roundtrip(display);
    _ = c.wl_display_roundtrip(display);

    if (cap.manager == null) {
        std.debug.print("kairo-screenshot: compositor does not advertise zwlr_screencopy_manager_v1\n", .{});
        return error.NoScreencopy;
    }
    if (cap.shm == null or cap.output == null) {
        std.debug.print("kairo-screenshot: missing shm or output globals\n", .{});
        return error.MissingGlobal;
    }

    var frame_listener = c.struct_zwlr_screencopy_frame_v1_listener{
        .buffer = Capture.frameBuffer,
        .flags = Capture.frameFlags,
        .ready = Capture.frameReady,
        .failed = Capture.frameFailed,
        .damage = Capture.frameDamage,
        .linux_dmabuf = null,
        .buffer_done = null,
    };
    // wlr-screencopy v1 has no buffer_done/linux_dmabuf; the struct fields
    // exist in newer headers, so both spellings compile.
    cap.frame = c.zwlr_screencopy_manager_v1_capture_output(cap.manager, 0, cap.output);
    if (cap.frame == null) return error.CaptureFailed;
    _ = c.zwlr_screencopy_frame_v1_add_listener(cap.frame, &frame_listener, &cap);

    while (!cap.ready and !cap.failed) {
        if (c.wl_display_dispatch(display) < 0) break;
    }
    if (cap.failed or !cap.ready or cap.data == null) {
        std.debug.print("kairo-screenshot: capture failed\n", .{});
        return error.CaptureFailed;
    }

    // Convert to RGB for the PNG encoder.
    const w: usize = cap.width;
    const h: usize = cap.height;
    const rgb = try std.heap.page_allocator.alloc(u8, w * h * 3);
    defer std.heap.page_allocator.free(rgb);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const src = cap.data.?[y * cap.stride + x * 4 ..][0..4];
            const dst = rgb[(y * w + x) * 3 ..][0..3];
            if (cap.swap_rb) {
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
            } else {
                dst[0] = src[2];
                dst[1] = src[1];
                dst[2] = src[0];
            }
        }
    }

    const path = blk: {
        if (out_path) |p| break :blk try allocator.dupe(u8, p);
        if (dir_override) |d| {
            var now: c.time_t = c.time(null);
            var tm: c.struct_tm = undefined;
            _ = c.localtime_r(&now, &tm);
            var stamp: [40]u8 = undefined;
            const len = c.strftime(&stamp, stamp.len, "%Y%m%d-%H%M%S", &tm);
            break :blk try std.fmt.allocPrint(allocator, "{s}/kairo-{s}.png", .{ d, stamp[0..@intCast(len)] });
        }
        break :blk try defaultPath(allocator);
    };
    defer allocator.free(path);

    try PngWriter.write(allocator, path, cap.width, cap.height, rgb);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(path);
    try stdout.writeAll("\n");

    if (cap.pool) |p| c.wl_shm_pool_destroy(p);
}
