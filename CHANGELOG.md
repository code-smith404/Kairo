# Changelog

All notable changes are recorded here. Kairo follows semantic versioning while
the compositor is pre-1.0.

## [0.3.0] - 2026-11-24

### Added

- `kairo-shell`, a separate Wayland client (not a privileged thread inside the
  compositor): a layer-shell top-layer panel with clickable tag buttons, the
  active layout name and a clock.
- Panel state is driven by IPC subscription events (`tag`, `output`,
  `session`); clicking a tag dispatches `view_tag N` through the same public
  IPC socket as `kairoctl`.
- Cairo rendering into double-buffered shm buffers with per-output scale
  support; software rendering works on GPU-less machines.
- Output hotplug creates a panel for new outputs; a layer-surface close
  removes it.
- Online installation: `install.sh` (GitHub release or from-source install),
  a release workflow publishing versioned tarballs with checksums, a
  wayland-session desktop file for display managers, and `tests/shell.sh`,
  a screencopy-based integration test that verifies the panel is composited.

### Fixed

- Layer surfaces are reconfigured only when their usable area actually
  changes, so clients no longer loop between configure and commit.
- `view_tag`/`toggle_tag` now emit the IPC `tag` event, so the shell and other
  subscribers update immediately.
- Shell panel redraws no longer stall when the compositor holds both buffers;
  the shell double-buffers and resumes on `wl_buffer.release`.

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
