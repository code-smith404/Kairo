# Architecture

This document is the top-level map. The detailed compositor walkthrough lives
in [docs/architecture.md](docs/architecture.md); this file records subsystem
boundaries and ownership.

## Process model

Kairo has one trusted core and ordinary Wayland clients:

```
kairo (compositor)
├── wlroots backend, renderer, scene graph, seat and protocols
├── session lock policy (ext-session-lock-v1)
├── IPC broker ($XDG_RUNTIME_DIR/kairo.sock)
└── shell/service clients (kairo-bar, kairo-notifications, kairo-screenshot, portals)
```

`kairo-bar` is the first such client: a layer-shell status bar that renders
tag buttons, the focused window title and system modules (CPU, memory,
temperature, battery, backlight, network, ALSA volume) with cairo, subscribes
to IPC events and dispatches tag switches through the same public socket as
`kairoctl`. It holds no privileges beyond those of any other Wayland client.
`kairo-screenshot` captures outputs through wlr-screencopy.
`kairo-notifications` owns `org.freedesktop.Notifications` on the session bus
and renders toasts on a layer-shell overlay; it is a plain client on both
buses. Later clients (portals, settings) will follow the same process
boundary.

The compositor never embeds a second event loop and never blocks the Wayland
loop with shell work. Desktop services are separate processes and communicate
through Wayland protocols, D-Bus, PipeWire or the Kairo IPC socket.

## Subsystems

| Subsystem | Location | Owns |
| --- | --- | --- |
| Server lifecycle | `src/core/server.zig` | display, backend, renderer, scene, outputs, windows, focus, IPC lifetime |
| Session lock | `src/core/session_lock.zig` | lock manager, lock surfaces, opaque lock backdrop, locked input focus |
| Window management | `src/core/window.zig`, `src/window/` | xdg-toplevel/X11 lifecycle, rules, geometry, scene nodes |
| Outputs | `src/core/output.zig` | output layout, per-output tags and usable area |
| Layout | `src/layout/` | pure geometry, no wlroots dependency |
| Workspaces/tags | `src/tags/` | visible masks, per-tag layout state, history |
| Input | `src/core/input.zig` | keyboard group, xkb, bindings, cursor, interactive move/resize |
| Config | `src/config/` | validated immutable config and atomic reload |
| IPC | `src/ipc/` | newline JSON protocol and non-blocking Unix socket |
| Effects | `src/effects/` | SceneFX blur/shadow/radius, compiled out without SceneFX |
| Bar client | `apps/bar/` | layer-shell bar, shm double-buffering, IPC subscription, /proc + /sys + ALSA modules |
| Screenshot client | `apps/screenshot/` | wlr-screencopy capture, PNG encoding |
| Notifications daemon | `apps/notifications/` | D-Bus name, toast queue, layer-shell overlay, actions |

## Session lock flow

1. `SessionLock.init` creates `wlr_session_lock_manager_v1` and a scene tree
   above every other tree.
2. A client binds the manager and requests a lock. Kairo sends `locked` once and
   rejects a second lock.
3. Kairo creates one opaque backdrop rectangle per output. This prevents the
   previous desktop from being visible before the lock client maps.
4. Each lock surface is configured with its output size, added to the lock tree,
   and positioned in output-layout coordinates. Mapping a surface enables it and
   moves keyboard focus to the lock surface.
5. While locked, `updateInputFocus` only targets lock surfaces; pointer hit
   testing only considers lock surfaces; normal bindings are skipped unless
   marked `bindl`; mouse/axis bindings are suppressed.
6. `unlock` or lock destruction removes lock nodes/backdrops, restores normal
   arrangement, pointer focus and top-window focus.

Authentication is intentionally outside this subsystem. `lock_command` starts
the user's lock client, which implements PAM and its own UI.

## Binding modes

`config.loader` parses `mode = NAME` and attaches that name to subsequent
`bind`/`bindl` entries. `Input` keeps a fixed-size active-mode buffer (no
allocation on the input path). A binding matches only when its mode, modifiers
and key all match. Reload resets an active mode that no longer exists.

## Ownership rules

- `Server` owns long-lived wlroots objects and arrays of managed windows/outputs.
- `Output` and `Window` own their scene trees and remove every listener before
  destruction.
- `SessionLock` owns lock bookkeeping and scene nodes; lock client resources are
  owned by wlroots.
- Config strings live in one fixed pool and are freed only by `Config.deinit`.
- IPC clients own their socket and line buffer; the broker removes them on any
  write/read failure.
