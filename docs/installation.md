# Installing Kairo

Kairo is distributed three ways: prebuilt release tarballs, a curl-able online
installer, and packages (currently Arch). All of them install the compositor
(`kairo`), the control client (`kairoctl`) and the desktop shell
(`kairo-bar`, `kairo-screenshot`).

## One-line online install

```sh
curl -fsSL https://raw.githubusercontent.com/code-smith404/Kairo/main/install.sh | sh
```

This downloads the latest release tarball from GitHub Releases and installs
into `/usr/local` (binaries in `/usr/local/bin`, the session file in
`/usr/share/wayland-sessions`). Options:

| Option | Effect |
| --- | --- |
| `--prefix DIR` | install into `DIR` instead of `/usr/local` |
| `--user` | shortcut for `--prefix $HOME/.local` |
| `--version TAG` | install a specific release tag, e.g. `v0.3.0` |
| `--from-source` | clone the repository and build instead of downloading |
| `--no-bar` | skip `kairo-bar` and `kairo-screenshot` |

## Release tarballs

Every tagged release publishes `kairo-<version>-x86_64-linux.tar.gz` plus a
`sha256` checksum at
<https://github.com/code-smith404/Kairo/releases>. The tarball layout is
POSIX-friendly:

```
bin/kairo  bin/kairoctl  bin/kairo-bar  bin/kairo-screenshot
wayland-sessions/kairo.desktop
share/doc/kairo/{README.md,LICENSE,docs/*,examples/config,rofi/kairo.rasi}
```

Unpack anywhere and put `bin/` on your `PATH`; the session file can be copied
to `/usr/share/wayland-sessions/` to make Kairo appear in SDDM/GDM/LightDM.

## Arch Linux

`packaging/arch/PKGBUILD` in this repository builds the package from git:

```sh
cd packaging/arch
makepkg -si
```

The package installs `kairo`, `kairoctl`, `kairo-bar`, `kairo-screenshot`, the
session file, the Rofi theme and the documentation. An AUR package is planned;
the PKGBUILD in-tree is kept current.

## From source

Dependencies (Arch package names):

- `zig` 0.15.2 — the pinned toolchain; newer Zig is not supported yet
- `wlroots0.20`, `scenefx` — compositor backend and effects
- `wayland`, `wayland-protocols`, `libxkbcommon`, `pixman`, `libdrm`, `mesa`
- `cairo` — used by `kairo-shell`
- `xorg-xwayland` (optional at runtime)
- a C toolchain (`cc`)

```sh
git clone https://github.com/code-smith404/Kairo.git
cd Kairo
zig build -Doptimize=ReleaseSafe
sudo zig build -Doptimize=ReleaseSafe --prefix /usr
```

A software-renderer build without SceneFX (useful for containers, VMs without
GPU passthrough and CI) is available with:

```sh
zig build -Dscenefx=false
```

This build does not link SceneFX at all and runs with wlroots' pixman
renderer.

## Starting a session

1. Copy the example config:

   ```sh
   mkdir -p ~/.config/kairo
   cp /usr/share/doc/kairo/examples/config ~/.config/kairo/config
   ```

2. Log out and pick **Kairo** in your display manager, or start it from a TTY:

   ```sh
   dbus-run-session -- kairo
   ```

3. Autostart the bar from your config (see `docs/configuration.md`):

   ```ini
   exec_once = kairo-bar
   ```

4. Optional: install the Rofi launcher theme.

   ```sh
   mkdir -p ~/.config/rofi
   cp /usr/share/doc/kairo/rofi/kairo.rasi ~/.config/rofi/
   # Super+D opens the launcher (see examples/config).
   ```

## Verifying the installation

```sh
kairo --version
kairoctl version      # needs a running compositor
kairo-bar --version
kairo-screenshot --version
```

All three binaries should report the same version.
