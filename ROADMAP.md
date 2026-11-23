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
- **0.3 — Desktop shell (next):** a separate `kairo-shell` client built on
  layer-shell: panel, workspace switcher, clock/status, launcher, and a shared
  shell rendering surface. The shell will consume the existing IPC protocol so
  it cannot bypass compositor policy.
- **0.4 — System services:** notification daemon/client, portal backend,
  clipboard history, MPRIS, idle/inhibit, screenshot and screen recording
  integration over PipeWire.
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
