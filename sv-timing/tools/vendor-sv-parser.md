# sv-parser submodule (Rust, not Python)

The package uses a **git submodule** of the GSys LibreCore fork
[etcimon/sv-parser](https://github.com/etcimon/sv-parser) (branch `g6lc`) under
`crates/sv-parser/`. That fork is [dalance/sv-parser](https://github.com/dalance/sv-parser)
v0.13.5 plus Verilator chained-select and comment-aware `/`. See `crates/sv-parser/G6LC.md`.

This is a **Rust** IEEE-1800 CST parser. It is **not** a Python parser, pyslang, or slang.
pyslang is only an optional lint of *emitted* SV in `verif/regress`.

## Pin

- Branch / rev file: `tools/sv-parser.rev` (currently `g6lc`)
- Gitlink SHA is the recorded commit in the parent repo
- License: MIT OR Apache-2.0 (kept verbatim)

## Refresh (cross-platform)

From `sv-timing/`:

```bash
python tools/svt.py vendor-sv-parser
```

In a git checkout of the monorepo, prefer:

```bash
git submodule update --init sv-timing/crates/sv-parser
```

`vendor-sv-parser` clones or fast-forwards the checkout when the tree is used
outside git (package extract) or when the submodule is missing.

## Do not

- Re-license parser crates as proprietary
- Point Cargo.toml at crates.io `sv-parser` for production builds (path dependency only)
- Treat pyslang / a Python SV parser as the production frontend
