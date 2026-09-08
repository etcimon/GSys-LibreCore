# AGENTS-vendor-sv-parser — Forked Rust parser (submodule)

> Companion to [`AGENTS.md`](AGENTS.md).
> Production parser: [etcimon/sv-parser](https://github.com/etcimon/sv-parser) branch `g6lc`
> (fork of [dalance/sv-parser](https://github.com/dalance/sv-parser) v0.13.5).
>
> **Not Python.** DESIGN.md Alternative 4 rejected Python parsers. pyslang is
> optional emit lint only (`verif/regress`). slang is the formal/Yosys frontend,
> not this crate.

## Policy

1. **Git submodule** at `crates/sv-parser/` is the production parse dependency.
2. First-party crates use **path dependencies** only (`workspace.dependencies` in root `Cargo.toml`).
3. **Do not** re-license upstream files; keep MIT OR Apache-2.0 notices.
4. Customize on the **fork** (`g6lc` branch), not by overlay patches in this package.
   Prefer a location adapter in `sv-timing-core` when a CST walk is enough.
5. Pin is `tools/sv-parser.rev` (branch name). The parent gitlink records the SHA.

## Refresh

```bash
python tools/svt.py setup
python tools/svt.py vendor-sv-parser
# or, from the monorepo root:
git submodule update --init sv-timing/crates/sv-parser
```

Implementation: `tools/refresh_sv_parser.py` (stdlib + `git`).

## After refresh

1. `python tools/svt.py cargo build -p sv-timing-core`
2. Fix first-party API usage if the fork's CST types changed.
3. Note pin bumps in `AGENTS-todo.md`.

## G6LC extensions (on the fork)

See `crates/sv-parser/G6LC.md`:

- Verilator chained select after a range select (`SelectSuffix`) — unblocks `core/alu.sv` xperm8
- `binary_operator` `/` does not steal `//` / `/*`

## Optional monorepo convenience

If this tree sits in a larger repo that uses `util/vendor.py`, do **not** re-vendor
a copy over the submodule. The gitlink is the pin.
