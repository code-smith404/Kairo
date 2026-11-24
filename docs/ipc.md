# IPC protocol

Kairo exposes a Unix stream socket at `$XDG_RUNTIME_DIR/kairo.sock`. Override it
with `KAIRO_SOCKET` for both the compositor and `kairoctl`, or pass
`kairoctl --socket PATH`.

The socket is line-oriented JSON: each request is one JSON object followed by
`\n`, and each response or event is one JSON object followed by `\n`. Responses
are emitted in order on the same connection. A request may omit `id`, which
Kairo currently ignores.

## Requests

| Request | Description |
| --- | --- |
| `{"command":"version"}` | Build and backend information |
| `{"command":"query"}` | Complete compositor snapshot |
| `{"command":"windows"}` | Managed windows |
| `{"command":"monitors"}` | Outputs |
| `{"command":"tags"}` | Tag state |
| `{"command":"layouts"}` | Available layout names |
| `{"command":"focus","args":"3"}` | Focus window id 3 |
| `{"command":"focus","args":"next"}` | Focus the next window |
| `{"command":"focus","args":"prev"}` | Focus the previous window |
| `{"command":"set_layout","args":"grid"}` | Change the focused output's layout |
| `{"command":"toggle_floating"}` | Toggle floating for the focused window |
| `{"command":"reload"}` | Reload the configuration |
| `{"command":"dispatch","args":"view_tag 2"}` | Run any config command |
| `{"command":"dispatch","args":"set_key_mode resize"}` | Enter a binding mode |
| `{"command":"subscribe","events":["window","tag"]}` | Subscribe to events |

Commands with a hyphen are accepted too: `toggle-floating`, `set-layout`.
`dispatch` normalises hyphens to underscores before resolving the command name.

## Responses

A successful request returns:

```json
{"ok":true,"data":...}
```

A failed request returns:

```json
{"ok":false,"error":"NoFocusedWindow"}
```

Command-style requests that do not query state return `{"ok":true}`.

## State shapes

### version

```json
{
  "ok": true,
  "data": {
    "name": "kairo",
    "version": "0.3.0",
    "wlroots": "0.20",
    "scenefx": true
  }
}
```

### windows

```json
{
  "ok": true,
  "data": [
    {
      "id": 2,
      "title": "~",
      "app_id": "foot",
      "tags": 1,
      "mapped": true,
      "floating": false,
      "fullscreen": false,
      "maximized": false,
      "minimized": false,
      "focused": true,
      "x": 6,
      "y": 6,
      "width": 1908,
      "height": 1068,
      "x11": false,
      "output": "HEADLESS-1"
    }
  ]
}
```

`tags` is a 32-bit mask. `output` is `null` before a window is associated with a
monitor.

### monitors

```json
{
  "ok": true,
  "data": [
    {
      "name": "eDP-1",
      "width": 1920,
      "height": 1080,
      "x": 0,
      "y": 0,
      "usable_width": 1920,
      "usable_height": 1080,
      "focused": true,
      "tags": 1,
      "layout": "tile",
      "master_count": 1,
      "master_factor": 0.55
    }
  ]
}
```

### tags

```json
{
  "ok": true,
  "data": {
    "active": 3,
    "previous": 1,
    "per_output": [
      {"output": "eDP-1", "active": 3, "layout": "tile"}
    ]
  }
}
```

### query

`query` combines `windows`, `monitors`, `tags` and `layouts` under one object
and adds `version` and `focused_window`:

```json
{
  "ok": true,
  "data": {
    "version": "0.3.0",
    "focused_window": 2,
    "windows": [],
    "monitors": [],
    "tags": {},
    "layouts": []
  }
}
```

## Events

After a successful `subscribe`, Kairo pushes an event object whenever the
subscribed state changes:

```json
{"event":"window","data":[ ... same shape as windows ... ]}
{"event":"tag","data":{ ... same shape as tags ... }}
{"event":"output","data":[ ... same shape as monitors ... ]}
{"event":"layout","data":["tile","scroller", ...]}
{"event":"session","data":{"locked":false,"key_mode":"default"}}
```

Events are snapshots, not deltas. A slow client can therefore drop intermediate
states without applying a broken partial update. Unknown event names are
ignored. Subscriptions are per connection and are cleared when the connection
closes.

`kairo-bar` is itself a subscriber: it follows `tag`, `output` and
`session` events to keep its panel current and dispatches `view_tag N` on
panel clicks. Event emission is guaranteed for `view_tag`/`toggle_tag` and
layout changes, so panels built on the same protocol stay in sync.

## Example session

```sh
$ kairoctl version
{
  "ok": true,
  "data": {
    "name": "kairo",
    "version": "0.3.0",
    "wlroots": "0.20",
    "scenefx": true
  }
}

$ kairoctl --raw focus next
{"ok":true}

$ kairoctl --raw subscribe window tag
{"ok":true,"data":{"subscribed":["window","tag"]}}
{"event":"window","data":[...]}
```

Exit `kairoctl` with Ctrl+C; the compositor removes the subscription when the
socket closes.

## Security

The socket is created with mode `0600` and lives inside `XDG_RUNTIME_DIR`. Any
process running as the same user can control the compositor; do not forward the
socket to untrusted users or containers.
