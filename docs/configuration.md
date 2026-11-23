# Configuration

Kairo reads a line-oriented `key = value` file. Blank lines and comments
(`#` at the start of a line, or after whitespace) are ignored. Values are
trimmed; quotes are not required.

The default path is `${XDG_CONFIG_HOME:-$HOME/.config}/kairo/config`, or pass
`-c PATH`. `--validate-config` prints diagnostics with file and line numbers and
exits non-zero on errors.

## Includes and variables

```ini
source = ./theme.conf
source_optional = ./local.conf

var = browser, firefox
bind = SUPER, B, spawn, $browser
```

`source` paths are resolved relative to the including file. `source_optional`
silently ignores a missing file. Variables are expanded as `$name`; undefined
names are left untouched.

## Core options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `mod` | modifiers | `Super` | Modifier used by default bindings |
| `terminal` | command | `foot` | Terminal used by integrations |
| `menu` | command | empty | Application launcher command |
| `tag_count` | 1–32 | `9` | Number of selectable tags |
| `default_layout` | layout name | `tile` | Initial layout for new tags |
| `master_count` | 0–16 | `1` | Master windows for stacking layouts |
| `master_factor` | 0.1–0.9 | `0.55` | Master area fraction |
| `gaps` | pixels | `6` | Outer gap |
| `inner_gaps` | pixels | `6` | Gap between tiled windows |
| `border_width` | pixels | `2` | Window border width |
| `border_color_focused` | `#rrggbb[aa]` | `#739ef2` | Focused border |
| `border_color_unfocused` | `#rrggbb[aa]` | `#38405c` | Unfocused border |
| `background` | `#rrggbb[aa]` | `#0e0f14` | Output background |
| `focus_follows_mouse` | bool | `false` | Focus the window under the pointer |
| `warp_cursor` | bool | `false` | Move the pointer to a newly focused window |
| `xwayland` | bool | `true` | Start XWayland |
| `xwayland_persistence` | bool | `true` | Keep XWayland alive with no clients |
| `syncobj` | bool | `true` | Enable linux-drm-syncobj-v1 |
| `cursor_theme` | name | empty | Xcursor theme (empty uses the system default) |
| `cursor_size` | pixels | `24` | Xcursor size |

`Super`, `Logo`, `Mod4` and `Win` are aliases. Modifiers combine with `+`:
`SUPER+SHIFT`, `CTRL+ALT`, and so on.

## Animations

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `animations` (alias `animation`) | bool | `true` | Master switch |
| `animation_duration` | ms | `200` | Default duration |
| `animation_open_duration` | ms | `0` | Open duration (0 = default) |
| `animation_close_duration` | ms | `0` | Close duration (0 = default) |
| `animation_move_duration` | ms | `0` | Move/resize duration (0 = default) |
| `animation_tag_duration` | ms | `0` | Tag transition duration (0 = default) |
| `animation_easing` (alias `easing`) | easing | `ease_out_cubic` | Easing function |
| `animation_fade` | bool | `true` | Animate opacity |

Easings: `linear`, `ease_in_quad`, `ease_out_quad`, `ease_in_out_quad`,
`ease_out_cubic`, `ease_in_out_cubic`, `ease_out_quart`, `ease_out_expo`,
`ease_out_back`, `ease_in_back`.

## Effects

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `blur` | bool | `true` | Enable background blur |
| `blur_radius` | pixels | `5` | Blur radius |
| `blur_passes` | count | `3` | Blur passes |
| `blur_noise` | float | `0.0` | Noise amount |
| `blur_brightness` | float | `0.9` | Brightness multiplier |
| `blur_contrast` | float | `1.0` | Contrast multiplier |
| `blur_saturation` | float | `1.1` | Saturation multiplier |
| `shadow` / `shadows` | bool | `true` | Enable window shadows |
| `shadow_blur` | float | `12.0` | Shadow blur sigma |
| `shadow_offset_x` (or `shadow_offset = X,Y`) | pixels | `0` | Shadow X offset |
| `shadow_offset_y` | pixels | `6` | Shadow Y offset |
| `shadow_color` | color | `#0000008c` | Shadow color |
| `corner_radius` | pixels | `8` | Window corner radius |
| `opacity` | 0–1 | `1.0` | Global window opacity |
| `focused_opacity` | 0–1 | `1.0` | Focused window opacity |
| `unfocused_opacity` | 0–1 | `1.0` | Unfocused window opacity |

SceneFX is required for blur, shadows and rounded corners. Build with
`-Dscenefx=false` to compile those features out.

## Input

| Option | Type | Default |
| --- | --- | --- |
| `keyboard_layout` / `xkb_layout` | string | `us` |
| `keyboard_variant` / `xkb_variant` | string | empty |
| `keyboard_options` / `xkb_options` | string | empty |
| `keyboard_rules` / `xkb_rules` | string | empty |
| `keyboard_model` / `xkb_model` | string | empty |
| `repeat_rate` | keys/s | `25` |
| `repeat_delay` | ms | `600` |
| `tap_to_click` | bool | `true` |
| `natural_scroll` | bool | `false` |
| `left_handed` | bool | `false` |
| `disable_while_typing` | bool | `true` |
| `accel_speed` | −1..1 | `0.0` |

## Overview

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `overview_gap` | pixels | `16` | Padding around the overview grid |

## Bindings

```ini
bind  = MODS, KEY, COMMAND[, ARGS]
bindr = MODS, KEY, COMMAND[, ARGS]   # fire on release
bindp = MODS, KEY, COMMAND[, ARGS]   # pass the key through to the client
bindn = MODS, KEY, COMMAND[, ARGS]   # no auto-repeat
bindl = MODS, KEY, COMMAND[, ARGS]   # allowed while locked
bindc = MODS, KEY, COMMAND[, ARGS]   # reserved for conflict-allowed bindings
```

`KEY` is an XKB keysym name (`Return`, `Q`, `2`, `Left`, `comma`) or a raw
keycode written as `code:24`. Bindings are case-insensitive for named
modifiers; keysym matching follows xkbcommon.

Declaring the first `bind` clears the built-in bindings, so a configuration file
is authoritative. Mouse and axis bindings behave the same way.

```ini
mousebind = SUPER, left, moveresize, curmove
mousebind = SUPER, right, moveresize, curresize
axisbind = SUPER, down, view_next_tag
axisbind = SUPER, up, view_prev_tag
```

Mouse buttons: `left`, `right`, `middle`, `side`, `extra`, `forward`, `back`,
or `code:N`. Axis directions: `up`, `down`, `left`, `right`.

`moveresize` takes `curmove` or `curresize` (anything containing `resize` means
resize). It may also be written as `move_resize`.

### Commands

| Command | Arguments | Description |
| --- | --- | --- |
| `spawn` / `exec` | command | Run a shell command |
| `spawn_shell` | command | Run a shell command |
| `quit` | — | Exit the compositor |
| `reload` | — | Reload the configuration |
| `killclient` / `close` | — | Ask the focused window to close |
| `force_kill` | — | Kill an X11 client, or close a Wayland client |
| `toggle_floating` / `togglefloating` | — | Toggle floating |
| `toggle_all_floating` | — | Toggle floating for all visible windows |
| `toggle_fullscreen` | — | Toggle fullscreen |
| `toggle_fake_fullscreen` | — | Fill the work area without fullscreen state |
| `toggle_maximized` | — | Toggle maximized |
| `toggle_minimized` | — | Toggle minimized |
| `restore_minimized` | — | Restore the first minimized window |
| `toggle_global` | — | Make the window visible on all tags |
| `toggle_overlay` | — | Keep the window above tiled windows |
| `center_window` / `centerwin` | — | Center a floating window |
| `focus_next` / `focus_prev` | — | Cycle focus |
| `focus_left` / `focus_right` / `focus_up` / `focus_down` | — | Directional focus |
| `move_next` / `move_prev` | — | Reorder the focused window |
| `swap_next` / `swap_prev` | — | Swap with the next/previous tiled window |
| `swap_master` / `zoom` | — | Move the focused window to the master slot |
| `view_tag` / `view` | index, `next`, `prev`, `last` | View a tag |
| `toggle_tag` / `toggletag` | index | Toggle a tag's visibility |
| `tag_window` / `tag` | index | Move the focused window to a tag |
| `toggle_tag_window` | index | Toggle the focused window's tag membership |
| `view_next_tag` / `view_prev_tag` | — | Switch to the adjacent tag |
| `set_layout` / `setlayout` | layout name | Set the active tag's layout |
| `cycle_layout` / `cyclelayout` | `next` or `prev` | Cycle layouts |
| `set_master_count` / `incnmaster` | count or `+N`/`-N` | Change master count |
| `set_master_factor` / `setmfact` | value or `+0.05`/`-0.05` | Change master factor |
| `focus_monitor` / `focusmon` | `next`, `prev`, name | Focus an output |
| `move_to_monitor` / `movemon` | `next`, `prev`, name | Move the window to an output |
| `toggle_scratchpad` / `togglescratchpad` | — | Toggle the default scratchpad |
| `toggle_named_scratchpad` | name | Toggle a named scratchpad |
| `show_overview` / `toggleoverview` | — | Toggle the window overview |
| `toggle_switcher` / `toggle_switcher` | — | Cycle focus (switcher) |
| `mouse_move` / `mouse_resize` | — | Begin interactive move/resize |

Layout names: `tile`, `scroller`, `vertical-scroller`, `master-stack`, `monocle`,
`grid`, `deck`, `dwindle`, `centered-master`, `center-tile`, `vertical-tile`,
`vertical-grid`, `tgmix`.

## Window rules

```ini
rule = app_id:firefox, floating:1, tags:2|3
rule = title:*Picture-in-Picture*, floating:true, no_shadow:1
```

Rules are matched in order; the last matching rule wins. `app_id` and `title`
support `*` and `?` wildcards and are case-insensitive. Without a matching rule,
a window is tiled on the currently visible tag.

| Field | Values |
| --- | --- |
| `app_id`, `title` | glob pattern |
| `tags` | `1`, `1|3`, `2-4`, `all` |
| `output` | output name |
| `floating`, `fullscreen`, `fake_fullscreen`, `maximized`, `minimized` | bool |
| `global`, `overlay`, `silent` | bool |
| `no_blur`, `no_shadow`, `no_radius`, `no_border`, `no_animation` | bool |
| `allow_csd` | bool |
| `opacity`, `focused_opacity` | 0–1 |
| `width`, `height` | pixels |

## Scratchpads

```ini
scratchpad = name:term, command:foot, app_id:foot
scratchpad = name:music, command:mpv, title:mpv
```

Fields: `name`, `command`, `app_id`, `title`, `width`, `height`. The scratchpad
command is spawned on first use; toggling hides and shows the matching window.

## Autostart and environment

```ini
exec = waybar
exec_once = kdeconnect-indicator
env = MOZ_ENABLE_WAYLAND,1
```

`exec` starts a command on every config load; `exec_once` starts it only when
Kairo starts. `env` accepts `NAME,VALUE` or `NAME=VALUE`.

## Monitor rules

```ini
monitor = name:DP-1, width:2560, height:1440, x:0, y:0, scale:1.0
```

Monitor rules are parsed and retained for output matching; `name` is the output
connector name.
