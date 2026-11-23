# Changelog

All notable changes are recorded here. Kairo follows semantic versioning while
the compositor is pre-1.0.

## [0.2.0] - 2026-11-23

### Added

- `ext-session-lock-v1` support with per-output opaque lock backdrops, lock
  surface configuration, keyboard/pointer confinement and output hotplug
  handling.
- Lock-aware binding policy: normal key/mouse/axis bindings are suppressed while
  locked, while `bindl` bindings remain available.
- `lock_command` / `locker` configuration option. `toggle_session_lock` starts
  the configured lock client; authentication stays in the client.
- Keyboard binding modes with `mode = NAME`, `set-key_mode`, scoped bindings and
  an active mode exposed through IPC.
- IPC `session` query object and `session` subscription event.
- `ROADMAP.md`, `ARCHITECTURE.md`, `PERFORMANCE.md`, `CONTRIBUTING.md` and a
  reproducible idle benchmark script.

### Changed

- `-Dscenefx=false` is now a genuinely SceneFX-free build; it no longer links
  `libscenefx` and can run with wlroots' pixman renderer.
- CI runs the headless smoke test against the software-renderer build on
  GPU-less runners.
- Documentation now describes the DRM/EGL requirement of the default build and
  the supported headless path.

### Fixed

- Removed the previous placeholder warnings for key modes and session lock.
- Lock activation now restores normal layout and focus after unlock.
- Normal window focus is rejected while a session lock is active.

## [0.1.0] - 2026-11-23

### Added

- Initial wlroots 0.20 compositor with 13 tiling layouts, 32-bit tags, scene
  graph, XWayland, layer-shell, scratchpads, animations, SceneFX effects,
  config reload, JSON IPC and `kairoctl`.
- Arch Linux packaging, GitHub Actions CI, unit tests and headless smoke test.
