//! C bindings for the wlroots 0.20 / SceneFX 0.5 ABI used by Kairo.
//!
//! The SceneFX scene graph is a drop-in extension of the wlroots scene graph
//! and uses the same header guard. It must be included before any wlroots
//! header that could pull in the base scene header. When Kairo is built with
//! `-Dscenefx=false`, the plain wlroots scene graph is used instead and visual
//! effects that need SceneFX are compiled out.

const build_options = @import("build_options");

pub const scenefx = build_options.scenefx;

pub const c = if (build_options.scenefx)
    @import("bindings_fx.zig").c
else
    @import("bindings_plain.zig").c;

pub const MAX_TAGS: u32 = 32;
