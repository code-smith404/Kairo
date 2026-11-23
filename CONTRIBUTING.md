# Contributing

## Toolchain

Kairo targets Zig **0.15.2** and wlroots **0.20**. SceneFX 0.5 is required for
the default build; `-Dscenefx=false` is a supported software-renderer build.
See the README for distribution packages.

```sh
export PATH="$HOME/.local/zig:$PATH"
zig build
zig build test
zig build -Dscenefx=false --prefix zig-out-plain
```

## Before a change

1. Read the relevant subsystem and its ownership comments.
2. Check whether the behavior already exists under another command or config
   spelling.
3. Prefer a focused change over a rewrite. Do not remove working behavior to
   simplify a diff.
4. If the change affects a documented gap or roadmap item, update the document
   in the same change.

## Required checks

```sh
zig fmt --check src cmd build.zig build.zig.zon
zig build test
zig build
zig build -Doptimize=ReleaseSafe
zig build -Dscenefx=false --prefix zig-out-plain
./zig-out/bin/kairo --validate-config -c examples/config
```

For runtime changes, also run a headless session:

```sh
XDG_RUNTIME_DIR=$(mktemp -d) ./zig-out/bin/kairo --headless --exit-after 1500
```

The CI workflow additionally checks that the plain build does not link SceneFX,
runs the end-to-end session-lock test, and starts the compositor with
`WLR_RENDERER=pixman`.

```sh
KAIRO_BIN=./zig-out-plain/bin/kairo WLR_RENDERER=pixman ./tests/session_lock.sh
```

## Code rules

- Keep the Wayland event loop non-blocking. Long work belongs in a separate
  process or an explicitly scheduled callback.
- Every listener added to a wlroots object must be removed before that object is
  destroyed. The `wl.Listener` helper exists to make ownership explicit.
- Never expose a placeholder command as working. Log a clear warning or leave it
  out; document the gap in `ROADMAP.md`.
- Configuration strings belong in `Config.pool`; do not free them individually.
- IPC input is untrusted. Keep the 1 MiB connection cap and per-request arena.
- New public behavior needs documentation in `docs/` and, where it is pure
  logic, a unit test in `src/tests.zig`.

## Commits

Use one logical change per commit and describe why it exists, not only what
files changed. Do not commit generated build output, local runtime sockets or
test clients.
