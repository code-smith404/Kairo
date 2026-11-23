# Performance

Kairo's performance policy is: measure before changing the hot path, keep the
event loop non-blocking, and make regressions reproducible. Numbers below are a
baseline on one machine, not a claim that Kairo is faster than another
compositor.

## Baseline

Measured 2026-11-23 on Arch Linux, Intel HD Graphics 5500, one HEADLESS-1
output (1920x1080), SceneFX renderer, XWayland enabled, no client windows:

| Metric | Value |
| --- | --- |
| RSS after startup | 62,388 KiB |
| RSS growth over 3 s idle | 0 KiB |
| CPU time over 3 s idle | 3 ticks (1% of one CPU at 100 Hz) |

This baseline includes Mesa/EGL driver state and the XWayland child process is
not included in `/proc/<pid>/stat` CPU accounting. It is intentionally a
compositor-only measurement.

## Reproduce

```sh
./benchmarks/idle.sh
```

For a machine without `/dev/dri`:

```sh
zig build -Dscenefx=false --prefix zig-out-plain
KAIRO_BIN=./zig-out-plain/bin/kairo WLR_RENDERER=pixman ./benchmarks/idle.sh
```

The script starts a temporary headless session, waits for the IPC socket,
samples `/proc/<pid>/status` and `/proc/<pid>/stat` over three seconds, and
cleans up the session. It reports RSS and CPU ticks; it does not hide startup or
teardown time.

## Rules for future changes

- A performance change must include before/after numbers from the same machine
  and scenario.
- Do not trade correctness, input latency or teardown safety for a lower idle
  number.
- Do not add polling loops. wlroots frame/timer sources are the only recurring
  work in the compositor.
- Keep lock/input policy O(bindings) with a fixed-size mode buffer; no
  allocation on key or pointer events.
- IPC parsing uses a per-request arena and is capped at 1 MiB per connection.
- SceneFX effects must remain optional at build time (`-Dscenefx=false`) so
  software and virtualized environments have a supported path.

## Planned benchmarks

Window creation latency, tag-switch latency, input-to-display latency, frame
pacing, multi-monitor mixed refresh, and long-running RSS under repeated
open/close cycles are tracked in the roadmap. They will be added with
reproducible workloads rather than synthetic numbers.
