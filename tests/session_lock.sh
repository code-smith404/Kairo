#!/bin/sh
# End-to-end ext-session-lock-v1 test against a real Kairo instance.
#
# Usage:
#   ./tests/session_lock.sh
#   KAIRO_BIN=./zig-out-plain/bin/kairo WLR_RENDERER=pixman ./tests/session_lock.sh
#
# Requires wayland-scanner, a C compiler and the wayland-protocols staging XML.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=${KAIRO_BIN:-"$root/zig-out/bin/kairo"}
ctl=${KAIROCTL:-"$root/zig-out/bin/kairoctl"}
xml=/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml
tmp=$(mktemp -d /tmp/kairo-session-lock.XXXXXX)
runtime="$tmp/runtime"
pid=
client=

cleanup() {
    if [ -n "${client:-}" ]; then kill "$client" 2>/dev/null || true; fi
    if [ -n "${pid:-}" ]; then kill "$pid" 2>/dev/null || true; fi
    if [ -n "${client:-}" ]; then wait "$client" 2>/dev/null || true; fi
    if [ -n "${pid:-}" ]; then wait "$pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

[ -r "$xml" ] || { echo "missing $xml" >&2; exit 1; }
command -v wayland-scanner >/dev/null || { echo "wayland-scanner is required" >&2; exit 1; }

wayland-scanner client-header "$xml" "$tmp/ext-session-lock-v1-client-protocol.h"
wayland-scanner private-code "$xml" "$tmp/ext-session-lock-v1-protocol.c"
cc -O2 -I"$tmp" -o "$tmp/locktest" "$root/tests/session_lock_client.c" \
    "$tmp/ext-session-lock-v1-protocol.c" -lwayland-client

mkdir -p "$runtime"
chmod 700 "$runtime"
XDG_RUNTIME_DIR="$runtime" "$bin" --headless --exit-after 9000 --log-level info >"$tmp/kairo.log" 2>&1 &
pid=$!

display=
for _ in $(seq 1 100); do
    for socket in "$runtime"/wayland-*; do
        if [ -S "$socket" ]; then
            display=$(basename "$socket")
            break
        fi
    done
    [ -n "$display" ] && break
    sleep 0.05
done
if [ -z "$display" ]; then
    echo "kairo did not create a Wayland socket" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
fi

XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$display" "$tmp/locktest" 3 \
    >"$tmp/client.out" 2>"$tmp/client.log" &
client=$!

for _ in $(seq 1 100); do
    if grep -q "locktest: locked" "$tmp/client.log" 2>/dev/null &&
       grep -q "locktest: configured" "$tmp/client.log" 2>/dev/null &&
       grep -q "locktest: focused" "$tmp/client.log" 2>/dev/null; then break; fi
    sleep 0.05
done
if ! grep -q "locktest: locked" "$tmp/client.log" 2>/dev/null; then
    echo "lock client did not lock" >&2
    cat "$tmp/client.log" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
fi
if ! grep -q "locktest: configured" "$tmp/client.log" 2>/dev/null; then
    echo "lock client did not receive a configure event" >&2
    cat "$tmp/client.log" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
fi
if ! grep -q "locktest: focused" "$tmp/client.log" 2>/dev/null; then
    echo "lock client did not receive keyboard focus" >&2
    cat "$tmp/client.log" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
fi

locked_query=$(XDG_RUNTIME_DIR="$runtime" "$ctl" query --raw)
case "$locked_query" in
    *'"locked":true'*) ;;
    *)
        echo "compositor did not report a locked session: $locked_query" >&2
        cat "$tmp/kairo.log" >&2
        exit 1
        ;;
esac

if ! wait "$client"; then
    echo "lock client failed" >&2
    cat "$tmp/client.log" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
fi
client=

sleep 0.2
unlocked_query=$(XDG_RUNTIME_DIR="$runtime" "$ctl" query --raw)
case "$unlocked_query" in
    *'"locked":false'*) ;;
    *)
        echo "compositor did not report an unlocked session: $unlocked_query" >&2
        cat "$tmp/kairo.log" >&2
        exit 1
        ;;
esac

if ! grep -q "session locked" "$tmp/kairo.log" || ! grep -q "session unlocked" "$tmp/kairo.log"; then
    echo "compositor did not complete the lock lifecycle" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
fi

echo "session lock integration: ok"
