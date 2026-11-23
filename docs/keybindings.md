# Keybindings

`Super` is the default modifier (`mod` in the config). Declaring the first
default-mode `bind` replaces the built-in default bindings, so copy the entries
you want into your config if you customise them. Bindings in a custom mode do
not clear the defaults.

## Built-in bindings

| Binding | Command | Description |
| --- | --- | --- |
| `Super+Return` | `spawn foot` | Open the terminal |
| `Super+Q` | `killclient` | Close the focused window |
| `Super+Shift+E` | `quit` | Exit Kairo |
| `Super+R` | `reload` | Reload the config |
| `Super+F` | `toggle_floating` | Toggle floating |
| `Super+M` | `toggle_fullscreen` | Toggle fullscreen |
| `Super+Shift+M` | `toggle_maximized` | Toggle maximized |
| `Super+Space` | `cycle_layout` | Cycle layouts |
| `Super+Tab` | `switcher_next` | Focus the next window |
| `Super+Shift+Tab` | `switcher_prev` | Focus the previous window |
| `Super+J` / `Super+K` | `focus_next` / `focus_prev` | Cycle focus |
| `Super+Shift+J` / `Super+Shift+K` | `swap_next` / `swap_prev` | Swap window order |
| `Super+H` / `Super+L` | `focus_left` / `focus_right` | Directional focus |
| `Super+Left/Right/Up/Down` | `focus_*` | Directional focus |
| `Super+Shift+Left/Right/Up/Down` | `move_*` | Move/swap in a direction |
| `Super+1` … `Super+9` | `view_tag N` | View tag N |
| `Super+Shift+1` … `Super+Shift+9` | `tag_window N` | Move window to tag N |
| `Super+Ctrl+1` … `Super+Ctrl+9` | `toggle_tag N` | Toggle tag N visibility |
| `Super+BackSpace` | `toggle_global` | Show window on all tags |
| `Super+grave` | `toggle_scratchpad` | Toggle the default scratchpad |
| `Super+Shift+Space` | `show_overview` | Toggle the overview grid |
| `Super+comma` | `focus_monitor` | Focus the next output |
| `Super+period` | `move_to_monitor` | Move the window to the next output |
| `Super+C` | `center_window` | Center a floating window |
| `Super+Z` | `zoom` | Promote the focused window to master |
| `Super+Left mouse` | `mouse_move` | Interactive move |
| `Super+Right mouse` | `mouse_resize` | Interactive resize |

The `Super+Tab` switcher is a focus cycle; Kairo does not draw a separate
switcher overlay yet.

## Binding modes

`mode = NAME` scopes the following bindings. Enter a mode with
`set_key_mode NAME`; use `default` to leave it.

```ini
mode = resize
bind = SUPER, H, set_master_factor, -0.05
bind = SUPER, L, set_master_factor, +0.05
bindl = SUPER, Escape, set_key_mode, default

mode = default
bind = SUPER, R, set_key_mode, resize
```

## Session locking

`bindl` bindings remain active while the session is locked. Do not bind
destructive window actions with `bindl`.

```ini
lock_command = swaylock -f
bind = SUPER+ALT, L, toggle_session_lock
```

Kairo configures lock surfaces and confines input, but the configured lock
client owns authentication and the lock-screen UI.

## Modifiers

`Super`, `Logo`, `Mod4` and `Win` all select the logo modifier. Other names:
`Shift`, `Ctrl`/`Control`, `Alt`/`Mod1`, `Mod2`, `Mod3`, `Mod5`.
Combine them with `+`, for example `SUPER+SHIFT`.

## Key names

Keys are XKB keysym names, matched case-insensitively:

- Letters: `A` … `Z`
- Digits: `0` … `9`
- Named keys: `Return`, `Escape`, `Tab`, `BackSpace`, `Space`, `Left`, `Right`,
  `Up`, `Down`, `Home`, `End`, `Page_Up`, `Page_Down`, `comma`, `period`,
  `grave`, `minus`, `equal`
- Raw evdev codes: `code:24`

## Examples

```ini
# Open a browser and a file manager
bind = SUPER, B, spawn, firefox
bind = SUPER, E, spawn, thunar

# Vim-style focus and swap
bind = SUPER, H, focus_left
bind = SUPER, L, focus_right
bind = SUPER+SHIFT, H, move_left
bind = SUPER+SHIFT, L, move_right

# Layout shortcuts
bind = SUPER, T, set_layout, tile
bind = SUPER, S, set_layout, scroller
bind = SUPER, G, set_layout, grid

# Resize the master area
bind = SUPER, bracketleft, set_master_factor, -0.05
bind = SUPER, bracketright, set_master_factor, +0.05

# Named scratchpad
bind = SUPER, N, toggle_named_scratchpad, notes
```
