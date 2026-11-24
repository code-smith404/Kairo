#!/bin/sh
# End-to-end kairo-bar test against a real Kairo instance.
#
# Verifies that the bar maps, subscribes to IPC, reflects a tag switch and is
# actually composited (checked through a screencopy grab).
#
# Usage:
#   ./tests/bar.sh
#   KAIRO_BIN=./zig-out-plain/bin/kairo WLR_RENDERER=pixman ./tests/bar.sh
#
# Verifies that the shell panel maps, subscribes to IPC, reflects a tag switch
# and is actually composited on screen (checked through a screencopy grab).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=${KAIRO_BIN:-"$root/zig-out/bin/kairo"}
bar=${KAIRO_BAR:-"$root/zig-out/bin/kairo-bar"}
ctl=${KAIROCTL:-"$root/zig-out/bin/kairoctl"}
shot_xml="$root/protocols/wlr-screencopy-unstable-v1.xml"
shot_c="$root/tests/screencopy_shot.c"
tmp=$(mktemp -d /tmp/kairo-bar-test.XXXXXX)
runtime="$tmp/runtime"
kairo_pid=
bar_pid=

cleanup() {
    if [ -n "${bar_pid:-}" ]; then kill "$bar_pid" 2>/dev/null || true; fi
    if [ -n "${kairo_pid:-}" ]; then kill "$kairo_pid" 2>/dev/null || true; fi
    if [ -n "${bar_pid:-}" ]; then wait "$bar_pid" 2>/dev/null || true; fi
    if [ -n "${kairo_pid:-}" ]; then wait "$kairo_pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

[ -r "$shot_xml" ] || { echo "missing $shot_xml" >&2; exit 1; }
command -v wayland-scanner >/dev/null || { echo "wayland-scanner is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

wayland-scanner client-header "$shot_xml" "$tmp/wlr-screencopy-unstable-v1-client-protocol.h"
wayland-scanner private-code "$shot_xml" "$tmp/wlr-screencopy-unstable-v1-protocol.c"
cc -O1 -I"$tmp" -o "$tmp/shot" "$shot_c" \
    "$tmp/wlr-screencopy-unstable-v1-protocol.c" -lwayland-client

mkdir -p "$runtime"
chmod 700 "$runtime"
XDG_RUNTIME_DIR="$runtime" "$bin" --headless --exit-after 9000 --log-level debug \
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

XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$display" "$bar" \
    >"$tmp/shell.out" 2>"$tmp/shell.err" &
bar_pid=$!

for _ in $(seq 1 100); do
    grep -q "kairo-bar: bar ready" "$tmp/shell.err" 2>/dev/null && break
    sleep 0.05
done
if ! grep -q "kairo-bar: bar ready" "$tmp/shell.err"; then
    echo "kairo-bar did not start" >&2
    cat "$tmp/shell.err" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
fi

# The compositor must have accepted the panel layer surface.
sleep 0.3
if ! grep -q "new layer_surface" "$tmp/kairo.log"; then
    echo "compositor did not create a layer surface for the panel" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
fi

# Switch to tag 3 through IPC; the panel must follow.
XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$display" "$ctl" dispatch view-tag 3 >/dev/null
sleep 0.5

XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$display" "$tmp/shot" "$tmp/shot.ppm" \
    2>"$tmp/shot.log" || { echo "screencopy failed" >&2; cat "$tmp/shot.log" >&2; exit 1; }

KAIRO_SHOT="$tmp/shot.ppm" python3 - <<'PYEOF'
import os, sys

w, h = 1920, 1080
data = open(os.environ["KAIRO_SHOT"], "rb").read()
# Skip the three P6 header lines.
i = 0
for _ in range(3):
    i = data.index(b"\n", i) + 1
pix = data[i:]
if len(pix) != w * h * 3:
    sys.exit("unexpected screenshot size")

def px(x, y):
    o = (y * w + x) * 3
    return pix[o], pix[o + 1], pix[o + 2]

# Panel background (rgba 0.045 0.052 0.070) must cover the strip.
for x, y in ((960, 0), (960, 16), (960, 30)):
    r, g, b = px(x, y)
    if not (r < 40 and g < 40 and 10 <= b < 45):
        sys.exit(f"panel background missing at ({x},{y}): {(r, g, b)}")

# Tag 3 (button index 2, x 66..93) is the active blue button (64,140,230);
# tag 1 (button index 0, x 8..35) must be inactive.
r, g, b = px(69, 9)
if not (55 < r < 75 and 130 < g < 150 and 220 < b < 240):
    sys.exit(f"active tag button not highlighted: {(r, g, b)}")
r, g, b = px(11, 9)
if not (20 <= r < 45 and 28 <= g < 55 and 45 <= b < 70):
    sys.exit(f"inactive tag button color unexpected: {(r, g, b)}")

# The right half carries the status modules; there must be lit text there.
lit_right = sum(
    1
    for x in range(w - 700, w - 20, 2)
    for y in (11, 15, 19)
    if px(x, y)[1] > 120
)
if lit_right < 20:
    sys.exit(f"status modules not rendered on the right side ({lit_right} lit pixels)")

print("panel composition: ok")
PYEOF

if ! wait "$bar_pid"; then
    echo "kairo-bar exited with an error" >&2
    cat "$tmp/shell.err" >&2
    exit 1
fi
bar_pid=

echo "kairo-bar integration: ok"
