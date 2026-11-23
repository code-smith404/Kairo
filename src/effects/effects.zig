//! Scene effects. With SceneFX, windows get shadows, background blur and
//! rounded corners. In a plain-wlroots build, the same interface degrades to
//! opacity only and never calls missing APIs.

const c = @import("../bindings.zig").c;
const fx = @import("../bindings.zig").scenefx;
const geom = @import("../util/geometry.zig");

pub const Params = struct {
    radius: i32 = 0,
    shadow_enabled: bool = false,
    shadow_blur: f32 = 10,
    shadow_offset_x: i32 = 0,
    shadow_offset_y: i32 = 0,
    shadow_color: [4]f32 = .{ 0, 0, 0, 0.5 },
    blur_enabled: bool = false,
    layer_blur: bool = false,
};

pub const Nodes = struct {
    shadow: ?*anyopaque = null,
    blur: ?*anyopaque = null,
};

pub fn create(parent: *c.struct_wlr_scene_tree, frame: geom.Box, params: Params) Nodes {
    var nodes = Nodes{};
    const w = @max(1, frame.width);
    const h = @max(1, frame.height);

    if (comptime fx) {
        if (params.blur_enabled) {
            const blur = c.wlr_scene_blur_create(parent, w, h);
            if (blur) |b| {
                c.wlr_scene_blur_set_corner_radius(b, params.radius);
                c.wlr_scene_node_set_enabled(&b.*.node, false);
                nodes.blur = @ptrCast(b);
            }
        }
        if (params.shadow_enabled) {
            const shadow = c.wlr_scene_shadow_create(parent, w, h, params.radius, params.shadow_blur, &params.shadow_color);
            if (shadow) |s| {
                c.wlr_scene_node_set_enabled(&s.*.node, false);
                nodes.shadow = @ptrCast(s);
            }
        }
    }
    return nodes;
}

pub fn update(nodes: Nodes, frame: geom.Box, border: i32, params: Params, visible_shadow: bool, visible_blur: bool) void {
    const w = @max(1, frame.width);
    const h = @max(1, frame.height);
    if (comptime fx) {
        if (nodes.shadow) |raw| {
            const shadow: *c.struct_wlr_scene_shadow = @ptrCast(@alignCast(raw));
            c.wlr_scene_shadow_set_size(shadow, w, h);
            c.wlr_scene_shadow_set_corner_radius(shadow, params.radius);
            c.wlr_scene_shadow_set_blur_sigma(shadow, params.shadow_blur);
            c.wlr_scene_node_set_position(&shadow.*.node, -border + params.shadow_offset_x, -border + params.shadow_offset_y);
            c.wlr_scene_node_set_enabled(&shadow.*.node, visible_shadow);
        }
        if (nodes.blur) |raw| {
            const blur: *c.struct_wlr_scene_blur = @ptrCast(@alignCast(raw));
            c.wlr_scene_blur_set_size(blur, w, h);
            c.wlr_scene_blur_set_corner_radius(blur, params.radius);
            c.wlr_scene_node_set_position(&blur.*.node, -border, -border);
            c.wlr_scene_node_set_enabled(&blur.*.node, visible_blur);
        }
    }
}

const BufferCtx = struct {
    opacity: f32,
    radius: i32,
    apply_radius: bool,
};

fn bufferCb(buffer: [*c]c.struct_wlr_scene_buffer, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void {
    _ = sx;
    _ = sy;
    const ctx: *BufferCtx = @ptrCast(@alignCast(data.?));
    c.wlr_scene_buffer_set_opacity(buffer, ctx.opacity);
    if (comptime fx) {
        if (ctx.apply_radius) c.wlr_scene_buffer_set_corner_radius(buffer, ctx.radius);
    }
}

pub fn applyToBuffers(tree: *c.struct_wlr_scene_tree, opacity: f32, radius: i32, apply_radius: bool) void {
    var ctx = BufferCtx{ .opacity = opacity, .radius = radius, .apply_radius = apply_radius };
    c.wlr_scene_node_for_each_buffer(&tree.node, bufferCb, &ctx);
}

pub fn configureSceneBlur(scene: *c.struct_wlr_scene, passes: i32, radius: i32, noise: f32, brightness: f32, contrast: f32, saturation: f32) void {
    if (comptime !fx) return;
    c.wlr_scene_set_blur_data(scene, passes, radius, noise, brightness, contrast, saturation);
}
