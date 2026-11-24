#!/bin/sh
# End-to-end org.freedesktop.Notifications test against a real Kairo instance.
#
# Runs a private session bus with dbus-run-session, starts the daemon, and
# drives the full lifecycle through tests/notification_client.c: name
# ownership, Notify with id, CloseNotification and the NotificationClosed
# signal. A screencopy grab additionally proves the toast is composited.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=${KAIRO_BIN:-"$root/zig-out/bin/kairo"}
daemon=${KAIRO_NOTIFICATIONS:-"$root/zig-out/bin/kairo-notifications"}
tmp=$(mktemp -d /tmp/kairo-notif-test.XXXXXX)
runtime="$tmp/runtime"
kairo_pid=

cleanup() {
    if [ -n "${kairo_pid:-}" ]; then kill "$kairo_pid" 2>/dev/null || true; fi
    if [ -n "${kairo_pid:-}" ]; then wait "$kairo_pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

command -v dbus-run-session >/dev/null 2>&1 || {
    echo "dbus-run-session is required" >&2
    exit 1
}
command -v pkg-config >/dev/null 2>&1 || {
    echo "pkg-config is required" >&2
    exit 1
}

cc -O1 -o "$tmp/nclient" "$root/tests/notification_client.c" \
    $(pkg-config --cflags --libs dbus-1)
wayland-scanner client-header "$root/protocols/wlr-screencopy-unstable-v1.xml" \
    "$tmp/wlr-screencopy-unstable-v1-client-protocol.h"
wayland-scanner private-code "$root/protocols/wlr-screencopy-unstable-v1.xml" \
    "$tmp/wlr-screencopy-unstable-v1-protocol.c"
cc -O1 -I"$tmp" -o "$tmp/shot" "$root/tests/screencopy_shot.c" \
    "$tmp/wlr-screencopy-unstable-v1-protocol.c" -lwayland-client

mkdir -p "$runtime"
chmod 700 "$runtime"
XDG_RUNTIME_DIR="$runtime" "$bin" --headless --exit-after 9000 --log-level info \
    >"$tmp/kairo.log" 2>&1 &
kairo_pid=$!

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

# Everything below shares one private session bus.
dbus-run-session -- sh -c "
    XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$display '$daemon' \
        >'$tmp/notif.err' 2>&1 &
    daemon=\$!
    for _ in \$(seq 1 100); do
        grep -q 'kairo-notifications: ready' '$tmp/notif.err' 2>/dev/null && break
        sleep 0.05
    done
    grep -q 'kairo-notifications: ready' '$tmp/notif.err' || {
        echo 'kairo-notifications did not start' >&2
        cat '$tmp/notif.err' >&2
        kill \$daemon 2>/dev/null
        exit 1
    }
    '$tmp/nclient' full
    status=\$?
    kill \$daemon 2>/dev/null
    exit \$status
" >"$tmp/run.out" 2>&1

if ! grep -q "notification lifecycle ok" "$tmp/run.out"; then
    echo "notification lifecycle did not complete" >&2
    cat "$tmp/run.out" >&2
    cat "$tmp/notif.err" >&2
    exit 1
fi

if ! grep -q "owning org.freedesktop.Notifications" "$tmp/notif.err"; then
    echo "daemon did not own the notifications name" >&2
    cat "$tmp/notif.err" >&2
    exit 1
fi

# Prove the toast is composited: the lifecycle client showed a critical
# notification with a 1.5 s timeout; the daemon is gone by now, so send
# another one, grab the screen while it is up, then close it.
dbus-run-session -- sh -c "
    XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$display '$daemon' \
        >'$tmp/notif2.err' 2>&1 &
    daemon=\$!
    for _ in \$(seq 1 100); do
        grep -q 'kairo-notifications: ready' '$tmp/notif2.err' 2>/dev/null && break
        sleep 0.05
    done
    '$tmp/nclient' notify-only
    sleep 0.4
    XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$display '$tmp/shot' '$tmp/toast.ppm' 2>/dev/null
    kill \$daemon 2>/dev/null
" >"$tmp/run2.out" 2>&1

python3 - "$tmp/toast.ppm" <<'PYEOF'
import sys
path = sys.argv[1]
data = open(path, "rb").read()
i = 0
for _ in range(3):
    i = data.index(b"\n", i) + 1
raw = data[i:]
w, h = 1920, 1080
def px(x, y):
    o = (y * w + x) * 3
    return raw[o], raw[o + 1], raw[o + 2]
# Toast panel: 360 wide, anchored top-right with a 12 px margin.
r, g, b = px(1560, 100)
if not (r < 40 and g < 40 and 10 <= b < 45):
    sys.exit(f"toast background missing at (1560,100): {(r, g, b)}")
# Critical urgency accent bar on the left edge of the toast.
r, g, b = px(1551, 100)
if not (r > 150 and g < 120 and b < 120):
    sys.exit(f"critical urgency accent missing at (1551,100): {(r, g, b)}")
print("toast composition: ok")
PYEOF

echo "notifications integration: ok"
