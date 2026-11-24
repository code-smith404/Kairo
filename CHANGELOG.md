# Changelog

All notable changes are recorded here. Kairo follows semantic versioning while
the compositor is pre-1.0.

## [0.5.0] - 2026-11-24

### Added

- **Kairo Notifications** (`kairo-notifications`): the session's
  `org.freedesktop.Notifications` daemon, implemented as an ordinary Wayland
  client over a private D-Bus session. It owns the name, renders toasts on a
  layer-shell overlay (top-right, urgency accent, wrap-limited body text),
  queues and replaces notifications, honours `expire_timeout` including the
  sticky case, supports action buttons invoked by pointer click with
  `ActionInvoked`/`NotificationClosed` signals, and answers
  `GetCapabilities`/`GetServerInformation`/`Introspect`.
- Do-not-disturb: `dnd = true` in `~/.config/kairo/notifications.conf`
  suppresses everything except critical urgency.
- `tests/notifications.sh` drives the full lifecycle on a private session bus
  and verifies the toast is composited with a screencopy grab.
- Version 0.5.0.

- **Idle actions**: `idle_timeout_ms`, `idle_lock` and `idle_suspend` arm a
  compositor-side 1 s idle check driven by the same activity reporting as
  `ext-idle-notify-v1`. The timeout locks the session (via `lock_command`)
  and/or suspends; idle-inhibit clients postpone it, and an already-locked
  session is never re-locked.
- Idle inhibit accounting is now wired through: client inhibitors update the
  compositor's idle state (previously `wlr_idle_inhibit_v1` was created but
  never tracked, so inhibitors had no effect).
- `Server.notifyActivity` actually reports activity to the notifier (it was
  a stub).

### Documented gaps

- Notification icons are not resolved (text-only toasts); only `actions` and
  `body` are advertised capabilities.
- Persistent history and per-app settings are not implemented yet.

## [0.4.0] - 2026-11-24

### Added

- **Kairo Bar** (`kairo-bar`, replacing the `kairo-shell` panel): a native
  layer-shell status bar with clickable tag buttons, the focused window title
  and system modules — CPU, memory, temperature, battery, backlight, network
  (with Wi-Fi link quality), ALSA playback volume and the clock.
- Bar interactions: tag click/scroll dispatch through IPC; volume click mutes,
  scroll steps; backlight click brightens, scroll steps — all straight through
  sysfs/ALSA, no subprocesses.
- Bar configuration in `~/.config/kairo/bar.conf`: module list, colors and
  action steps, with a documented fallback palette.
- GTK color-scheme detection: the bar adopts the user's dark/light GTK
  preference on first start instead of imposing one.
- `kairo-screenshot`: full-output screenshots over wlr-screencopy, written as
  a valid PNG (deflate-stored stream, since Zig 0.15.2's flate encoder is
  incomplete); the written path is printed on stdout.
- Rofi 2.x launcher integration: a matching `kairo.rasi` theme in
  `packaging/rofi/`, a Super+D binding in the example config, and an
  `optdepends` in the Arch package. Rofi keeps its own configuration.
- Integration tests: `tests/bar.sh` verifies the composited bar with real
  screencopy pixels; `tests/screenshot.sh` verifies the PNG decodes to the
  exact expected raw size.

### Changed

- The shell binary is renamed to `kairo-bar`; the launcher/OSD/notification
  surfaces will be separate binaries in later milestones.
- `examples/config` autostarts `kairo-bar` (was `waybar`) and adds screenshot
  and launcher bindings (Print, Super+D).
- The release tarball and Arch package carry `kairo-bar` and
  `kairo-screenshot` and install the Rofi theme.
- Version 0.4.0.

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
