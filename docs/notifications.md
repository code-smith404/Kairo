# Kairo Notifications

`kairo-notifications` implements the standard
`org.freedesktop.Notifications` interface for the Kairo session. It is an
ordinary Wayland client and an ordinary D-Bus client: it owns the name on
your session bus and draws toasts on a layer-shell overlay. A daemon crash
can never take down the compositor, and it holds no privileges beyond any
other client.

## Behaviour

- **Toasts** appear top-right on every output, below the bar, with an accent
  bar colored by urgency (blue normal, red critical, light blue low).
- **Timeouts** follow `expire_timeout`: negative values use the configured
  default (5 s), positive values are respected, `0` stays until closed.
- **Replacement**: `replaces_id` updates an existing toast in place.
- **Actions**: the first `(key, label)` action pair is rendered as a button;
  clicking it emits `ActionInvoked` and dismisses the toast. Any other click
  dismisses it. Signals use the spec reasons: `1` expired, `2` dismissed via
  CloseNotification, `3` closed by the user.
- **Do-not-disturb**: with `dnd = true`, only `urgency: 2` (critical)
  notifications are displayed; others are answered with id 0.
- **Queue**: at most eight notifications; the oldest is expired to make room.

## Configuration

`~/.config/kairo/notifications.conf`:

```ini
dnd = false
default_timeout_ms = 5000
max_width_chars = 60
```

## Capabilities and gaps

`GetCapabilities` returns exactly `actions` and `body`, because those are
what is implemented. Notification icons are not resolved — toasts are
text-only — and there is no persistent history or per-app configuration yet.
`GetServerInformation` reports `Kairo / Kairo contributors / <version> /
spec 1.2`.

## Testing

`tests/notifications.sh` starts a private session bus (`dbus-run-session`),
runs the daemon against a headless compositor and drives the complete
lifecycle with `tests/notification_client.c`, then captures the screen
through wlr-screencopy to prove the toast is composited.
