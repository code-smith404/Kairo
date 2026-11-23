# Kairo

Kairo is a tiling Wayland compositor written in Zig, inspired by
[MangoWM](https://github.com/mangowm/mango). It uses
[wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.20 as the backend and
[SceneFX](https://github.com/wlrfx/scenefx) 0.5 for blur, shadows and rounded
corners.

Kairo is deliberately small: one event loop, one scene graph, a pure-Zig layout
engine, and a JSON control socket. The compositor does not embed C beyond the
wlroots/SceneFX/libwayland ABI.

## Status

Kairo is usable as a daily-driver tiling compositor on Wayland, but it is still
beta software. The table below describes what is implemented today.

| Area | Implemented |
| --- | --- |
| Drawing | wlroots + SceneFX scene graph, output hotplug, multi-monitor layout |
| Windows | xdg-shell toplevels and popups, XWayland (including override-redirect), layer-shell |
| Tiling | 13 layouts: tile, scroller, vertical-scroller, master-stack, monocle, grid, deck, dwindle, centered-master, center-tile, vertical-tile, vertical-grid, tg-mix |
| Tags | 32-bit tag masks, multiple visible tags, per-tag layout state, tag history |
| Effects | SceneFX blur, shadow, rounded corners, opacity, open/close/move animations |
| Input | libinput via wlroots, xkbcommon keymaps, keyboard groups, repeats, mouse/axis bindings, interactive move/resize |
| Scratchpads | Named scratchpads with rules and toggle commands |
| Overview | Live window grid overview (Super+Shift+Space) |
| Control | `kairoctl` JSON IPC, state queries, command dispatch, event subscription |
| Configuration | Mango-style INI/TOML-like file, includes, variables, hot reload on Super+R |

Not yet implemented: session locking, the graphical switcher overlay, and
`ext-background-effect-v1` for client-requested blur. `kairoctl` and the config
loader report these plainly instead of pretending they work.

## Requirements

Kairo targets **Zig 0.15.2** and needs the development headers for:

- wlroots 0.20 (`wlroots0.20` on Arch)
- SceneFX 0.5 (`scenefx`)
- wayland-server, wayland-protocols
- libxkbcommon, pixman, libdrm, Mesa/EGL, GBM
- XWayland (optional at runtime, enabled by default)
- a C compiler and linker (`cc`)

On Arch Linux:

```sh
sudo pacman -S --needed base-devel zig wlroots0.20 scenefx wayland \
  wayland-protocols libxkbcommon pixman libdrm mesa xorg-xwayland
```

## Build

```sh
zig build -Doptimize=ReleaseSafe
sudo zig build -Doptimize=ReleaseSafe --prefix /usr
```

Build output:

- `zig-out/bin/kairo` — the compositor
- `zig-out/bin/kairoctl` — the control client

Run the unit test suite with:

```sh
zig build test
```

### Why the build calls `cc`

Zig 0.15.2's bundled ELF linker cannot process the SFrame relocations in GCC 16's
`crt1.o`. Kairo therefore compiles its Zig sources to an object file and lets
the system C driver perform the final link. This keeps the binary on the same
libc and dynamic loader as the rest of the system. `cc` must be in `PATH`.

## Running

Start Kairo from a TTY (not from inside another Wayland session):

```sh
kairo -c ~/.config/kairo/config
```

`kairo` creates a Wayland socket through wlroots and exports
`WAYLAND_DISPLAY` plus `XDG_CURRENT_DESKTOP=Kairo` for child processes.

Useful testing flags:

```sh
kairo --headless --exit-after 2000   # SceneFX build: needs a DRM/EGL device
kairo --validate-config              # parse the config and report diagnostics
kairo -c ./examples/config --log-level debug
```

For a headless run on a machine or CI container without `/dev/dri`, build the
plain-wlroots software renderer. The default SceneFX build deliberately links
SceneFX before wlroots, so it cannot fall back to pixman at runtime:

```sh
zig build -Dscenefx=false --prefix zig-out-plain
WLR_RENDERER=pixman ./zig-out-plain/bin/kairo --headless --exit-after 2000
```

The default configuration path is `${XDG_CONFIG_HOME:-$HOME/.config}/kairo/config`.
If the file does not exist, Kairo starts with built-in defaults.

### Default keybindings

`Super` is the modifier. See [docs/keybindings.md](docs/keybindings.md) for the
full list.

| Binding | Action |
| --- | --- |
| `Super+Return` | terminal (`foot`) |
| `Super+Q` | close focused window |
| `Super+Shift+E` | quit Kairo |
| `Super+R` | reload config |
| `Super+F` | toggle floating |
| `Super+M` | toggle fullscreen |
| `Super+Space` | cycle layout |
| `Super+J` / `Super+K` | focus next/previous |
| `Super+Shift+J` / `Super+Shift+K` | swap next/previous |
| `Super+1..9` | view tag |
| `Super+Shift+1..9` | move window to tag |
| `Super+Ctrl+1..9` | toggle tag visibility |
| `Super+grave` | toggle scratchpad |
| `Super+Shift+Space` | toggle overview |
| `Super+Tab` / `Super+Shift+Tab` | cycle focus (switcher) |
| `Super+Left/Right/Up/Down` | directional focus |
| `Super+Shift+Left/Right/Up/Down` | swap window |
| Mouse `Super+Left` | move window |
| Mouse `Super+Right` | resize window |

## Configuration

Kairo accepts a line-oriented `key = value` file. Bindings use
`bind = MODS,KEY,COMMAND[,ARGS]`; comments start with `#` when the `#` begins a
comment (hex colors such as `#4c7899` are preserved).

```ini
mod = Super
terminal = foot
default_layout = tile
gaps = 8
inner_gaps = 4
border_width = 2
border_color_focused = #4c7899
border_color_unfocused = #333333

animation = true
animation_duration = 180
blur = true
blur_radius = 6
shadow = true
corner_radius = 8

bind = SUPER, Return, spawn, foot
bind = SUPER+SHIFT, Q, quit
bind = SUPER, 2, view_tag, 2
mousebind = SUPER, left, moveresize, curmove
axisbind = SUPER, down, view_next_tag

rule = app_id:firefox, floating:1, tags:2|3
scratchpad = name:term, command:foot, app_id:foot
```

See [docs/configuration.md](docs/configuration.md) for every option and command,
and [examples/config](examples/config) for a complete starting point.

## Control socket

The compositor listens on `$XDG_RUNTIME_DIR/kairo.sock` (override with
`KAIRO_SOCKET`). Messages are newline-delimited JSON.

```sh
kairoctl version
kairoctl windows
kairoctl query
kairoctl focus next
kairoctl set-layout grid
kairoctl dispatch toggle-floating
kairoctl subscribe window tag
```

`kairoctl` prints indented JSON by default and compact JSON with `--raw`.
The IPC protocol is documented in [docs/ipc.md](docs/ipc.md).

## Project layout

```
src/
  main.zig          CLI, config resolution, socket setup, event loop
  core/             server, outputs, windows, input, layer shell, XWayland
  layout/           pure layout functions and the 13 layout engines
  tags/             tag masks and per-tag layout state
  animation/        easing functions and value tracks
  effects/          SceneFX blur/shadow/rounded-corner integration
  config/           config model and parser
  ipc/              JSON protocol and control socket
  scratchpad/       named scratchpad management
  window/           window rules and glob matching
  util/             geometry and logging
cmd/kairoctl.zig    control client
protocols/          wlroots protocol XML/headers not shipped by distro packages
docs/               user and developer documentation
packaging/arch/     Arch Linux PKGBUILD
```

## License

MIT. See [LICENSE](LICENSE). The vendored wlroots protocol files retain their
upstream MIT license; see `protocols/UPSTREAM-WLROOTS-LICENSE`.
