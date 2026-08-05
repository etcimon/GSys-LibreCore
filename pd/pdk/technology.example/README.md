# `pd/pdk/technology.example/` — Per-technology drop-in TEMPLATE

This is a **committed template** showing the expected layout of a real (and
git-ignored) per-technology PDK drop-in. Copy it to `pd/pdk/<technology>/` — the
easy way is:

```
cva6-build tech init <technology>     # e.g. cva6-build tech init tsmcN5
```

which creates `pd/pdk/<technology>/` with its own `.gitignore` (ignoring
everything but a README) so you can populate it with NDA views safely.

## Expected layout of a real drop-in

```
pd/pdk/<technology>/
  manifest.json     # copy of ../manifest.example.json, filled in (NDA — gitignored)
  lib/              # Liberty timing/power (.lib) — NDA
  db/               # compiled Synopsys .db — NDA
  lef/              # abstract layout (.lef) — NDA
  gds/              # layout (.gds) — NDA
  macros/           # compiled SRAM/ROM/regfile + hard-macro wrappers — NDA
  cells/            # ICG / retention / level-shifter / isolation / IO cell wrappers — NDA
  views/            # UPF/CPF power views — NDA
```

## What maps where

- `manifest.json.cellMap.tc_sram` → the compiled memory macro / generator key
  fed to `tc_sram`'s `ImplKey` and the `sram_cache` `TECHNO_CUT` path.
- `manifest.json.cellMap.tc_clk_gating` → the library ICG bound to `tc_clk_gating`.
- `manifest.json.cellMap.tc_pwr` → the level-shifter / isolation / retention cells.

Nothing in a real `<technology>/` drop is ever committed. This template only
documents the shape; see `../README.md` and `AGENTS-technology.md`.
