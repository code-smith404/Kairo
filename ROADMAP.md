# Kairo roadmap

Kairo is built in small, independently verifiable milestones. A milestone is
complete only when it builds with Zig 0.15.2, passes `zig build test`, passes the
headless integration smoke test, and its user-visible behavior is documented.

## Current status

- **0.1 — Compositor core (done):** wlroots 0.20 backend, 13 layouts, tags,
  XWayland, layer-shell, SceneFX effects, animations, scratchpads, config
  reload, JSON IPC and `kairoctl`.
- **0.2 — Session core (done in this change):** `ext-session-lock-v1` support,
  lock-aware keyboard/pointer/binding policy, configurable locker command,
  binding modes, and session state in IPC.
- **0.3 — Desktop shell (done):** `kairo-shell`, a separate layer-shell client
  with a panel (tag buttons, layout name, clock) driven entirely by IPC
  subscription events and clickable tag switching. Software-buffer rendering
  works on GPU-less machines; a screencopy-based integration test verifies the
  panel is actually composited.
- **0.4 — Bar and capture (done):** the native `kairo-bar` status bar with
  system modules (CPU, memory, temperature, battery, backlight, network, ALSA
  volume), GTK color-scheme detection, `~/.config/kairo/bar.conf`
  configuration, and `kairo-screenshot` full-output PNG capture. Rofi 2.x is
  the launcher with a matching theme and default binding.
- **0.5 — System services (next):** notification daemon (org.freedesktop.
  Notifications over D-Bus), portal backend, clipboard history, MPRIS,
  idle/inhibit actions, screen recording over PipeWire.
- **0.5 — Desktop integration:** settings application, lock screen client,
  theme/accent pipeline, application launcher search, session manager and
  display-manager integration.
- **1.0 — Distribution ready:** packaging for additional distributions,
  reproducible benchmarks, upgrade/migration notes, accessibility review and a
  documented release process.

## 0.2 acceptance criteria

- [x] `ext-session-lock-v1` global is created.
- [x] A lock client can lock, map a lock surface, receive keyboard/pointer
  focus, and unlock without leaving the compositor in a locked state.
- [x] A second lock client is rejected.
- [x] Normal keyboard and mouse bindings are suppressed while locked; explicit
  `bindl` bindings remain available.
- [x] Pointer focus cannot reach windows or layer surfaces while locked.
- [x] An opaque backdrop covers all outputs before the first lock surface maps.
- [x] Lock surfaces follow output geometry and output hotplug.
- [x] `toggle_session_lock` launches the configured `lock_command`; it does not
  pretend the compositor can authenticate by itself.
- [x] Key modes are scoped by the `mode = NAME` config directive and
  `set_key_mode`; the active mode is visible over IPC.
- [x] Session state is queryable over IPC and emits a `session` event.
- [x] Unit tests cover mode parsing, invalid modes, and locker configuration.
- [x] Headless lock/unlock test client passes against the built compositor.

## 0.3 acceptance criteria

- [x] `kairo-shell` builds and installs alongside `kairo` and `kairoctl`.
- [x] The panel maps as a `zwlr_layer_shell_v1` top-layer surface, anchored to
  the top edge, with an exclusive zone; multiple outputs get one panel each.
- [x] Tag buttons, active layout name and a clock are rendered through cairo
  into double-buffered shm buffers at the output scale.
- [x] The shell subscribes to IPC `tag`/`output`/`session` events and redraws
  only when its state actually changes; the 1 Hz clock tick is the only
  steady-state redraw.
- [x] Clicking a tag button dispatches `view_tag N` through the same IPC socket
  used by `kairoctl` (no privileged back door).
- [x] A missing compositor, missing layer-shell or unreachable IPC socket
  degrades cleanly: the panel still renders, IPC reconnection is handled by
  dropping the client.
- [x] The first layer-surface commit no longer enters a configure/commit loop
  (surfaces are reconfigured only when the usable area actually changes).
- [x] `tests/shell.sh` verifies composition with real screencopy pixels.
- [x] An online installation path exists: GitHub release tarballs, a
  `curl`-able `install.sh`, an Arch PKGBUILD and a wayland session file.

## 0.4 acceptance criteria

- [x] `kairo-bar` maps as a layer-shell surface and is verified composited by
  screencopy (`tests/bar.sh`), including after an IPC tag switch.
- [x] Status modules read /proc, /sys and the ALSA mixer with no subprocesses
  and no busy loops; status refresh is 2 s, the clock 1 s, and redraws are
  event-driven with double-buffered shm surfaces.
- [x] Volume click/scroll and backlight click/scroll act through the ALSA API
  and sysfs writes respectively; failures degrade to hidden modules or
  reported warnings, never crashes.
- [x] A PipeWire-less environment cannot crash the bar through the ALSA
  plugin: the mixer falls back to `hw:0` when `$XDG_RUNTIME_DIR/pipewire-0`
  is absent.
- [x] The focused window title follows IPC `window` events, including
  unfocus (title clears).
- [x] GTK dark/light detection with explicit override in `bar.conf`.
- [x] `kairo-screenshot` writes a valid PNG verified by `tests/screenshot.sh`
  (zlib-decoded raw size must match exactly).
- [x] Rofi 2.x wayland theme (`packaging/rofi/kairo.rasi`), Super+D binding
  in the example config, packaged and documented.

## 0.3 design constraints

- The shell is a Wayland client, not a privileged thread inside the
  compositor.
- It must degrade cleanly when the compositor or IPC socket is unavailable.
- It must not require a GPU-specific renderer; a software buffer path is
  required for CI and virtual machines.
- Shell errors must never take down the compositor.

## Non-goals for 0.2

- Kairo does not implement password authentication. Lock clients own
  authentication and PAM integration.
- The graphical switcher overlay and `ext-background-effect-v1` client blur
  remain future work. They are documented as gaps rather than exposed as
  working commands.
