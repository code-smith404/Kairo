#!/bin/sh
# End-to-end kairo-screenshot test: capture the headless output and verify
# the PNG decodes to the exact raw size with python3's zlib.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=${KAIRO_BIN:-"$root/zig-out/bin/kairo"}
shot=${KAIRO_SHOT:-"$root/zig-out/bin/kairo-screenshot"}
tmp=$(mktemp -d /tmp/kairo-shot-test.XXXXXX)
runtime="$tmp/runtime"
kairo_pid=

cleanup() {
    if [ -n "${kairo_pid:-}" ]; then kill "$kairo_pid" 2>/dev/null || true; fi
    if [ -n "${kairo_pid:-}" ]; then wait "$kairo_pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

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

XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$display" timeout 20 "$shot" \
    --output "$tmp/shot.png" >"$tmp/path.txt" 2>"$tmp/shot.err" || {
    echo "kairo-screenshot failed" >&2
    cat "$tmp/shot.err" >&2
    cat "$tmp/kairo.log" >&2
    exit 1
}

[ -s "$tmp/shot.png" ] || { echo "screenshot file is empty" >&2; exit 1; }
[ "$(cat "$tmp/path.txt")" = "$tmp/shot.png" ] || {
    echo "screenshot did not report the written path: $(cat "$tmp/path.txt")" >&2
    exit 1
}

KAIRO_SHOT_PNG="$tmp/shot.png" python3 - <<'PYEOF'
import os, struct, sys, zlib

data = open(os.environ["KAIRO_SHOT_PNG"], "rb").read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG file")
pos = 8
idat = b""
width = height = 0
while pos < len(data):
    ln = struct.unpack(">I", data[pos:pos+4])[0]
    typ = data[pos+4:pos+8]
    chunk = data[pos+8:pos+8+ln]
    if typ == b"IHDR":
        width, height, depth, ctype = struct.unpack(">IIBB", chunk[:10])
        if depth != 8 or ctype != 2:
            sys.exit(f"unexpected IHDR depth/ctype {depth}/{ctype}")
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + ln
raw = zlib.decompress(idat)
expected = height * (1 + width * 3)
if len(raw) != expected:
    sys.exit(f"raw size {len(raw)} != expected {expected}")
print(f"screenshot png ok ({width}x{height})")
PYEOF

echo "kairo-screenshot integration: ok"
