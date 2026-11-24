//! Kairo desktop shell: a separate Wayland client that renders the panel and
//! consumes the compositor's JSON IPC. It never runs inside the compositor
//! process, so a shell crash cannot take down the session.
//!
//! The first shell milestone is a layer-shell panel with workspace tags, the
//! active layout and a clock. Tags are dispatched through the same IPC socket
//! used by kairoctl; the shell has no privileged back door.

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
});

const PANEL_HEIGHT: u32 = 32;
const TAG_WIDTH: f64 = 27;
const TAG_GAP: f64 = 2;
const TAG_START: f64 = 8;
const MAX_TAG_BUTTONS: u32 = 9;

const State = struct {
    tags: u32 = 1,
    tag_count: u32 = 9,
    layout_buf: [32]u8 = [_]u8{0} ** 32,
    layout_len: usize = 0,
    locked: bool = false,

    fn layout(self: *const State) []const u8 {
        return self.layout_buf[0..self.layout_len];
    }

    fn setLayout(self: *State, value: []const u8) void {
        const n = @min(value.len, self.layout_buf.len);
        @memcpy(self.layout_buf[0..n], value[0..n]);
        self.layout_len = n;
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

    fn send(self: *Ipc, command: []const u8, args: []const u8) void {
        var w = proto.Writer.init(self.app.allocator);
        defer w.deinit();
        w.beginObject() catch return;
        w.key("command") catch return;
        w.string(command) catch return;
        if (args.len > 0) {
            w.key("args") catch return;
            w.string(args) catch return;
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

    fn subscribe(self: *Ipc) void {
        var w = proto.Writer.init(self.app.allocator);
        defer w.deinit();
        w.beginObject() catch return;
        w.key("command") catch return;
        w.string("subscribe") catch return;
        w.key("events") catch return;
        w.beginArray() catch return;
        w.string("tag") catch return;
        w.string("output") catch return;
        w.string("session") catch return;
        w.endArray() catch return;
        w.endObject() catch return;
        w.raw("\n") catch return;
        const out = w.toOwnedSlice() catch return;
        defer self.app.allocator.free(out);
        _ = std.posix.write(self.fd, out) catch {};
    }

    fn query(self: *Ipc) void {
        self.send("query", "");
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
        if (changed) {
            if (std.posix.getenv("KAIRO_SHELL_DEBUG") != null)
                std.debug.print("state change: tags={b} layout={s} locked={}\n", .{ app.state.tags, app.state.layout(), app.state.locked });
            app.redrawAll();
        }
    }

    fn readAvailable(self: *Ipc) void {
        if (std.posix.getenv("KAIRO_SHELL_DEBUG") != null)
            std.debug.print("ipc readable\n", .{});
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
};

const Panel = struct {
    app: *App,
    output: *c.struct_wl_output,
    surface: *c.struct_wl_surface,
    layer_surface: *c.struct_zwlr_layer_surface_v1,
    width: u32 = 0,
    height: u32 = PANEL_HEIGHT,
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
            "kairo-panel",
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
        c.zwlr_layer_surface_v1_set_size(layer_surface, 0, PANEL_HEIGHT);
        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, @intCast(PANEL_HEIGHT));
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
            const fd = c.memfd_create("kairo-panel", 0);
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

    fn draw(self: *Panel) void {
        if (!self.configured) return;
        self.ensureBuffers() catch |err| {
            std.debug.print("kairo-shell: panel buffer: {s}\n", .{@errorName(err)});
            return;
        };
        // Pick a buffer the compositor has released; if both are outstanding
        // the next wl_buffer.release will resume drawing.
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
        const scale: f64 = @floatFromInt(@max(1, self.scale));
        c.cairo_save(cr);
        c.cairo_scale(cr, scale, scale);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_rgba(cr, 0.045, 0.052, 0.070, 0.97);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

        // A quiet accent line makes the panel feel attached to the session,
        // not like an opaque unrelated strip.
        c.cairo_set_source_rgba(cr, 0.25, 0.55, 0.90, 0.85);
        c.cairo_rectangle(cr, 0, @floatFromInt(self.height - 1), @floatFromInt(self.width), 1);
        c.cairo_fill(cr);

        c.cairo_select_font_face(cr, "sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(cr, 12);

        const tag_count = @min(self.app.state.tag_count, MAX_TAG_BUTTONS);
        var i: u32 = 0;
        while (i < tag_count) : (i += 1) {
            const x = TAG_START + @as(f64, @floatFromInt(i)) * (TAG_WIDTH + TAG_GAP);
            const active = (self.app.state.tags & (@as(u32, 1) << @intCast(i))) != 0;
            c.cairo_set_source_rgba(cr, if (active) 0.25 else 0.12, if (active) 0.55 else 0.15, if (active) 0.90 else 0.22, 1.0);
            c.cairo_rectangle(cr, x, 6, TAG_WIDTH, 20);
            c.cairo_fill(cr);
            var text_buf: [4]u8 = undefined;
            // NUL-terminate: cairo reads until it finds a terminator.
            const text = std.fmt.bufPrint(text_buf[0..3], "{d}", .{i + 1}) catch "1";
            text_buf[text.len] = 0;
            c.cairo_set_source_rgba(cr, if (active) 1.0 else 0.55, if (active) 1.0 else 0.60, if (active) 1.0 else 0.70, 1.0);
            const text_extents: c.cairo_text_extents_t = blk: {
                var extents: c.cairo_text_extents_t = undefined;
                c.cairo_text_extents(cr, text.ptr, &extents);
                break :blk extents;
            };
            c.cairo_move_to(cr, x + (TAG_WIDTH - text_extents.width) / 2 - text_extents.x_bearing, 20);
            c.cairo_show_text(cr, text.ptr);
        }

        const layout_x = TAG_START + @as(f64, @floatFromInt(tag_count)) * (TAG_WIDTH + TAG_GAP) + 8;
        c.cairo_set_source_rgba(cr, 0.70, 0.78, 0.90, 1.0);
        c.cairo_move_to(cr, layout_x, 21);
        c.cairo_show_text(cr, self.app.state.layout().ptr);

        // Clock, right-aligned.
        var now: c.time_t = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);
        var clock_buf: [16]u8 = undefined;
        const clock_len = c.strftime(&clock_buf, clock_buf.len, "%H:%M", &tm);
        const clock = clock_buf[0..clock_len];
        if (clock.len > 0) {
            var extents: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(cr, clock.ptr, &extents);
            c.cairo_set_source_rgba(cr, 0.90, 0.92, 0.96, 1.0);
            c.cairo_move_to(cr, @as(f64, @floatFromInt(self.width)) - extents.width - 12, 21);
            c.cairo_show_text(cr, clock.ptr);
        }
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
    ipc: ?*Ipc = null,
    registry_listener: c.struct_wl_registry_listener,
    seat_listener: c.struct_wl_seat_listener,
    pointer_listener: c.struct_wl_pointer_listener,
    pointer_panel: ?*Panel = null,
    initialized: bool = false,

    fn init(allocator: std.mem.Allocator, display: *c.struct_wl_display) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .panels = std.ArrayList(*Panel).empty,
            .outputs = std.ArrayList(*c.struct_wl_output).empty,
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
        const display = self.display;
        _ = display;
        _ = c.wl_display_roundtrip(self.display);
        _ = c.wl_display_roundtrip(self.display);
        if (self.compositor == null or self.shm == null or self.layer_shell == null) {
            std.debug.print("kairo-shell: missing compositor/shm/layer-shell globals\n", .{});
            return error.MissingGlobal;
        }
        if (self.seat) |seat| _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
        for (self.outputs.items) |output| {
            _ = Panel.create(self, output) catch |err| {
                std.debug.print("kairo-shell: panel creation failed: {s}\n", .{@errorName(err)});
            };
        }
        self.initialized = true;
        self.ipc = Ipc.create(self) catch |err| blk: {
            std.debug.print("kairo-shell: IPC unavailable: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        if (self.ipc) |ipc| {
            ipc.subscribe();
            ipc.query();
        }
    }

    fn deinit(self: *App) void {
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
        self.redrawAll();
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
                _ = Panel.create(self, output) catch |err| std.debug.print("kairo-shell: hotplug panel: {s}\n", .{@errorName(err)});
            }
        }
    }

    fn handleGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
    }

    fn handleSeatCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data.?));
        if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0 and self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(self.seat) orelse return;
            _ = c.wl_pointer_add_listener(self.pointer, &self.pointer_listener, self);
        }
        _ = seat;
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
        _ = serial;
        _ = time;
        const self: *App = @ptrCast(@alignCast(data.?));
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED or button != 0x110) return;
        const panel = self.pointer_panel orelse return;
        if (panel.tagAt(panel.pointer_x, panel.pointer_y)) |tag| {
            var buf: [32]u8 = undefined;
            const args = std.fmt.bufPrint(&buf, "view_tag {d}", .{tag}) catch return;
            if (self.ipc) |ipc| ipc.send("dispatch", args);
        }
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

fn usage() void {
    std.fs.File.stdout().writeAll(
        \\Kairo shell
        \\
        \\Usage: kairo-shell [--version] [--help]
        \\
        \\The shell connects to WAYLAND_DISPLAY and $XDG_RUNTIME_DIR/kairo.sock.
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
            try std.fs.File.stdout().writeAll("kairo-shell 0.3.0\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        }
        std.debug.print("kairo-shell: unknown argument '{s}'\n", .{arg});
        usage();
        std.process.exit(2);
    }
    const display = c.wl_display_connect(null) orelse {
        std.debug.print("kairo-shell: cannot connect to Wayland\n", .{});
        return error.WaylandConnectFailed;
    };
    const app = try App.init(allocator, display);
    defer app.deinit();
    app.start() catch |err| {
        std.debug.print("kairo-shell: startup failed: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("kairo-shell: panel ready\n", .{});
    const display_fd = c.wl_display_get_fd(display);
    var last_tick = std.time.milliTimestamp();
    while (true) {
        _ = c.wl_display_flush(display);
        var fds = [2]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.ipc) |ipc| ipc.fd else -1, .events = c.POLLIN, .revents = 0 },
        };
        const rc = c.poll(&fds, fds.len, 1000);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            std.debug.print("kairo-shell: poll failed\n", .{});
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
        const now = std.time.milliTimestamp();
        if (now - last_tick >= 1000) {
            last_tick = now;
            app.tick();
        }
    }
}
