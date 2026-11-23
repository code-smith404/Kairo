#!/bin/sh
# Reproducible idle baseline for a headless Kairo session.
# Requires the SceneFX build and a DRM/EGL device, or set KAIRO_BIN to the
# software-renderer binary and export WLR_RENDERER=pixman.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=${KAIRO_BIN:-"$root/zig-out/bin/kairo"}
runtime=$(mktemp -d /tmp/kairo-bench.XXXXXX)
chmod 700 "$runtime"
log="$runtime/kairo.log"
pid=

cleanup() {
    if [ -n "${pid:-}" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$runtime"
}
trap cleanup EXIT INT TERM

XDG_RUNTIME_DIR="$runtime" "$bin" --headless --exit-after 6000 --log-level warn >"$log" 2>&1 &
pid=$!

for _ in $(seq 1 100); do
    [ -S "$runtime/kairo.sock" ] && break
    sleep 0.05
done
if [ ! -S "$runtime/kairo.sock" ]; then
    echo "kairo did not create an IPC socket" >&2
    cat "$log" >&2
    exit 1
fi

sleep 1
rss_before=$(awk '/VmRSS/{print $2}' "/proc/$pid/status")
ticks_before=$(awk '{print $14 + $15}' "/proc/$pid/stat")
sleep 3
rss_after=$(awk '/VmRSS/{print $2}' "/proc/$pid/status")
ticks_after=$(awk '{print $14 + $15}' "/proc/$pid/stat")

cpu_ticks=$((ticks_after - ticks_before))
printf 'binary=%s\n' "$bin"
printf 'idle_rss_kib=%s\n' "$rss_after"
printf 'rss_delta_kib=%s\n' "$((rss_after - rss_before))"
printf 'cpu_ticks_3s=%s\n' "$cpu_ticks"
printf 'sample_seconds=3\n'
