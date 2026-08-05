# AGENTS-vendor-sv-parser — Integral in-tree parser

> Companion to [`AGENTS.md`](AGENTS.md). Upstream: [dalance/sv-parser](https://github.com/dalance/sv-parser).

## Policy

1. **Integral copy** under `crates/sv-parser/` is the production parse dependency.
2. First-party crates use **path dependencies** only (`workspace.dependencies` in root `Cargo.toml`).
3. **Do not** re-license upstream files; keep MIT OR Apache-2.0 notices.
4. Prefer **location adapter** in `sv-timing-core` over deep forks; patches only if required
   (`patches/sv-parser/*.patch`, applied in sort order).
5. Pin is `tools/sv-parser.rev` (tag or commit). Stamp file: `crates/sv-parser/VENDOR_STAMP`.

## Refresh

```bash
python tools/svt.py setup                 # once
python tools/svt.py vendor-sv-parser      # re-fetch pin + apply patches
```

Implementation: `tools/refresh_sv_parser.py` (stdlib + `git`).

## After refresh

1. `python tools/svt.py cargo build -p sv-timing-core`
2. Fix first-party API usage if upstream signatures changed.
3. Note pin bumps in `AGENTS-todo.md`.

## Optional monorepo convenience

If this tree sits in a larger repo that uses `util/vendor.py`, an hjson **may** target
`sv-timing/crates/sv-parser` — output must match this script. Package must not **require** that tool.
