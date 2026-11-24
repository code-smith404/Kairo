#!/bin/sh
# Kairo online installer.
#
# Run directly from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/code-smith404/Kairo/main/install.sh | sh
#
# Or download and run with options:
#   sh install.sh [--prefix DIR] [--version TAG] [--from-source] [--no-bar] [--user]
#
# By default the script downloads the latest GitHub release tarball and installs
# it under /usr/local. Pass --from-source to build from the git repository
# instead (needs zig 0.15.2 and the build dependencies from README.md).
set -eu

REPO_URL="https://github.com/code-smith404/Kairo"
REPO_API="https://api.github.com/repos/code-smith404/Kairo"
PREFIX="/usr/local"
VERSION=""
FROM_SOURCE=0
USER_INSTALL=0
INSTALL_BAR=1
INSTALL_SHELL=1

print_usage() {
    cat <<EOF
Kairo installer

Usage: sh install.sh [options]

Options:
  --prefix DIR      Install prefix (default: /usr/local)
  --version TAG     Install a specific release tag, e.g. v0.3.0
  --from-source     Clone and build instead of downloading a release
  --user            Shortcut: --prefix \$HOME/.local
  --no-bar          Skip kairo-bar and kairo-screenshot
  -h, --help        Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --from-source) FROM_SOURCE=1; shift ;;
        --user) USER_INSTALL=1; shift ;;
        --no-bar) INSTALL_BAR=0; shift ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; print_usage >&2; exit 2 ;;
    esac
done

if [ "$USER_INSTALL" = 1 ]; then
    PREFIX="${HOME}/.local"
fi

say() { printf '[kairo-install] %s\n' "$*"; }
fail() { printf '[kairo-install] ERROR: %s\n' "$*" >&2; exit 1; }

fetch() {
    # fetch URL DEST
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$2" "$1"
    else
        fail "need curl or wget to download files"
    fi
}

install_from_release() {
    work=$(mktemp -d /tmp/kairo-install.XXXXXX)
    trap 'rm -rf "$work"' EXIT INT TERM

    if [ -n "$VERSION" ]; then
        tag="$VERSION"
        say "looking up release $tag"
    else
        say "resolving latest release"
        tag=$(fetch "$REPO_API/releases/latest" "$work/latest.json" || true
              sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$work/latest.json" | head -n 1)
        [ -n "$tag" ] || fail "could not resolve the latest release; pass --version TAG or use --from-source"
        say "latest release: $tag"
    fi

    # Resolve the real asset URL from the release API when we fetched its
    # metadata (asset names may not embed the tag verbatim); fall back to
    # constructing the conventional name for --version without a lookup.
    tarball=""
    if [ -s "$work/latest.json" ]; then
        tarball=$(sed -n 's/.*"browser_download_url": *"\([^"]*x86_64-linux.tar.gz\)".*/\1/p' \
            "$work/latest.json" | head -n 1)
    fi
    if [ -z "$tarball" ]; then
        tarball="$REPO_URL/releases/download/$tag/kairo-$tag-x86_64-linux.tar.gz"
        [ -n "$VERSION" ] || tarball="$REPO_URL/releases/download/$tag/kairo-${tag#v}-x86_64-linux.tar.gz"
    fi
    say "downloading $tarball"
    fetch "$tarball" "$work/kairo.tar.gz" || fail "download failed; check that release $tag exists"

    say "extracting"
    mkdir -p "$work/inst"
    tar -xzf "$work/kairo.tar.gz" -C "$work/inst"

    # Release packages are wrapped in a single top-level directory
    # (kairo-<version>-x86_64-linux/); descend into it when present.
    if [ -d "$work/inst/bin" ]; then
        src_dir="$work/inst"
    else
        topdir=$(find "$work/inst" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        [ -n "$topdir" ] || fail "unexpected package layout"
        src_dir="$topdir"
    fi

    install_binaries "$src_dir"

    say "installed Kairo $tag to $PREFIX"
}

install_binaries() {
    src="$1"
    [ -x "$src/bin/kairo" ] || fail "$src/bin/kairo missing from package"
    bin_dir="$PREFIX/bin"
    mkdir -p "$bin_dir"
    install -m 755 "$src/bin/kairo" "$bin_dir/kairo"
    install -m 755 "$src/bin/kairoctl" "$bin_dir/kairoctl"
    if [ "$INSTALL_BAR" = 1 ] && [ -x "$src/bin/kairo-bar" ]; then
        install -m 755 "$src/bin/kairo-bar" "$bin_dir/kairo-bar"
    fi
    if [ "$INSTALL_BAR" = 1 ] && [ -x "$src/bin/kairo-screenshot" ]; then
        install -m 755 "$src/bin/kairo-screenshot" "$bin_dir/kairo-screenshot"
    fi
    if [ "$INSTALL_BAR" = 1 ] && [ -x "$src/bin/kairo-notifications" ]; then
        install -m 755 "$src/bin/kairo-notifications" "$bin_dir/kairo-notifications"
    fi

    # Session entry so display managers list Kairo.
    if [ -f "$src/wayland-sessions/kairo.desktop" ]; then
        if install -m 644 "$src/wayland-sessions/kairo.desktop" /usr/share/wayland-sessions/kairo.desktop 2>/dev/null; then
            say "session file installed to /usr/share/wayland-sessions"
        else
            say "skipped session file (need permission for /usr/share/wayland-sessions)"
        fi
    fi

    # Default config on first install.
    if [ -f "$src/share/doc/kairo/examples/config" ]; then
        mkdir -p "$PREFIX/share/doc/kairo/examples"
        install -m 644 "$src/share/doc/kairo/examples/config" "$PREFIX/share/doc/kairo/examples/config"
    fi

    if ! [ -w "$bin_dir" ]; then
        say "installed to $bin_dir without root: make sure $bin_dir is in PATH"
    fi
    bar_note=""
    if [ "$INSTALL_BAR" = 1 ]; then bar_note=", kairo-bar, kairo-screenshot, kairo-notifications"; fi
    say "binaries installed: kairo, kairoctl$bar_note"
}

install_from_source() {
    work=$(mktemp -d /tmp/kairo-install.XXXXXX)
    trap 'rm -rf "$work"' EXIT INT TERM

    command -v git >/dev/null 2>&1 || fail "git is required for --from-source"
    command -v zig >/dev/null 2>&1 || fail "zig (0.15.2) is required for --from-source"

    say "cloning $REPO_URL"
    git clone --depth 1 "$REPO_URL" "$work/Kairo"

    ref="$VERSION"
    if [ -n "$ref" ]; then
        (cd "$work/Kairo" && git fetch --depth 1 origin "$ref" && git checkout FETCH_HEAD)
    fi

    say "building (ReleaseSafe) — this needs wlroots 0.20, SceneFX 0.5 and friends"
    (cd "$work/Kairo" && zig build -Doptimize=ReleaseSafe)

    install_binaries "$work/Kairo/zig-out"
    say "installed build from source to $PREFIX"
}

case "$FROM_SOURCE" in
    1) install_from_source ;;
    *) install_from_release ;;
esac

say "next steps:"
say "  1. copy the example config: mkdir -p ~/.config/kairo && cp $PREFIX/share/doc/kairo/examples/config ~/.config/kairo/"
say "  2. log into a Kairo session from your display manager, or run 'kairo' from a TTY"
say "  3. start the bar in a session autostart entry: kairo-bar &"
say "     add notifications with: exec_once = kairo-notifications"
