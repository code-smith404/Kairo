# Architecture

Kairo is a single-threaded wlroots compositor: one Wayland display, one event
loop, one renderer, and one scene graph. There are no worker threads and no
hidden event sources apart from the Wayland/libinput/XWayland timers that
wlroots owns.

## Initialisation

1. `main.zig` parses CLI options, resolves the config path, and loads the config.
2. `Server.init` creates the `wl_display`, acquires the backend, creates the
   SceneFX renderer, allocator, scene graph, output layout and all protocol
   globals (compositor, xdg-shell, layer-shell, seat, cursor, idle notify,
   screencopy, dmabuf, syncobj, foreign-toplevel, session-lock and XWayland).
3. `Server.start` starts the backend and opens the IPC socket.
4. `main.zig` starts autostart entries, exports session variables, then calls
   `Server.run` (`wl_display_run`).
5. `Server.deinit` removes every signal listener before destroying surfaces and
   global objects, then destroys the display.

## Scene graph

The scene graph is the single source of truth for rendering and hit testing:

```
scene
├── background_tree      solid output background
├── bottom_tree          layer-shell background/bottom
├── tiling_tree          tiled windows
├── floating_tree        floating/maximized windows
├── top_window_tree      fullscreen/overlay/overview windows
├── top_layer_tree       layer-shell top
├── overlay_tree         layer-shell overlay and popups
└── output_layout        wlr_scene_output per monitor
```

Each managed window owns a `wlr_scene_tree` containing its content tree, border
rectangle and (with SceneFX) shadow/blur nodes. SceneFX's `fx_renderer` renders
the same scene while adding blur/shadow passes.

Layer-shell surfaces are created with `wlr_scene_layer_surface_v1_create` and
arranged in exclusive then non-exclusive order by `core/layers.zig`. The
remaining usable area is passed to the output's layout engine.

## Tiling and tags

`layout/` is pure geometry. `layout.arrange` dispatches to one of the 13
engines and writes rectangles into a caller-owned slice. No layout code touches
wlroots, which makes it unit-testable without a compositor.

`tags/` stores a 32-bit visible mask per output plus 32 independent `TagState`
records (layout, master count/factor, gaps, scroller parameters) and a short
view history. Windows also carry a 32-bit tag mask, so a window can belong to
several tags at once. `Output.arrange` filters windows by `window.tags &
output.tags.active`, groups them into floating/fullscreen/tiled passes, and
calls the layout engine for the tiled pass.

## Windows

`core/window.zig` supports two kinds:

- xdg-toplevel: commit/map/unmap/destroy on the `wlr_surface`; move, resize,
  maximize, fullscreen, minimize, title and app-id on the `wlr_xdg_toplevel`.
- XWayland: associate/dissociate/destroy/configure and ICCCM hints on
  `wlr_xwayland_surface`.

Listener storage is a layout-compatible superset of `struct wl_listener`
(`core/wl.zig::Listener`) carrying an owner pointer. This is necessary because
wlroots 0.20 removed `wl_listener.data`; the helper keeps the signal ABI intact
and gives every callback a typed owner without global maps.

Window rules are applied on first map. Geometry is animated with `RectTrack`
and opacity with `Track`; both are pure value tracks in `animation/`.

## Session lock

`core/session_lock.zig` owns the `ext-session-lock-v1` manager, the active lock,
per-output lock surfaces and opaque backdrops. Lock surfaces live in the final
`lock_tree`, so they cover windows and layer surfaces. While `session_locked` is
true, keyboard focus is restricted to the lock surface for the focused output,
pointer hit testing only considers lock surfaces, normal bindings are skipped,
and `focusWindow` refuses to change window focus. `bindl` bindings are the
explicit escape hatch. Unlock clears lock nodes/backdrops and restores normal
arrangement, pointer focus and the top window. Authentication is delegated to
the configured `lock_command` client.

## Input

`core/input.zig` owns a `wlr_keyboard_group`, the xkb keymap, the cursor, the
repeat timer and all pointer/keyboard listeners. Key bindings are resolved to
keysyms at config load and matched against the current xkb state, the active
binding mode, and the session-lock policy. The active mode is a fixed-size
buffer so mode changes allocate nothing.

Pointer handling does hit testing against the scene graph, updates keyboard and
pointer focus, and implements interactive move/resize. `focus_follows_mouse`
and `warp_cursor` are applied here.

## IPC

`ipc/server.zig` creates the Unix socket and registers it as a `wl_event_loop`
fd source. Accepted client sockets are non-blocking and registered as separate
fd sources, so one slow client cannot stall the compositor. Each request is
parsed in an arena that is released after dispatch. Subscribed clients receive
snapshot events when state changes.

The wire format and request/response shapes are documented in
[ipc.md](ipc.md).

## Configuration

`config/config.zig` defines a fixed-size pool (512 KiB) for all strings and
arrays, so a loaded config has one allocation and deterministic ownership.
`config/loader.zig` is a line parser with `source=` includes, `$var` expansion,
per-line diagnostics, and validation of bindings, rules, scratchpads and
monitor entries. The first default-mode binding in a user config clears the
built-in default bindings; custom-mode bindings do not.

Reload builds a complete new config, rejects it if any diagnostic was emitted,
then swaps it in and re-applies outputs, effects and keymaps.

## Testing

- `zig build test` runs pure-Zig unit tests for geometry, all layout engines,
  tags, animation tracks, config parsing, window-rule globbing and the IPC JSON
  codec.
- `zig build` compiles the compositor, links it through the system C driver, and
  builds `kairoctl`.
- `kairo --headless --exit-after N` exercises backend startup, output creation,
  XWayland, scene rendering and teardown. The SceneFX build needs a DRM/EGL
  device; the software-renderer build (`-Dscenefx=false` with
  `WLR_RENDERER=pixman`) runs without one and is what CI uses.
- `kairo --validate-config -c FILE` exercises config diagnostics.
