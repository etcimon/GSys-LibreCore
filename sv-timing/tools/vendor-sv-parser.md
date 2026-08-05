# Vendoring sv-parser (integral in-tree copy)

The package carries a full copy of [dalance/sv-parser](https://github.com/dalance/sv-parser)
under `crates/sv-parser/` so builds never depend on crates.io network access for the
parser and local location patches can be applied.

## Pin

- Tag / rev file: `tools/sv-parser.rev` (currently `v0.13.5`)
- Upstream license: MIT OR Apache-2.0 (kept verbatim under `crates/sv-parser/`)

## Refresh (cross-platform)

From `sv-timing/`:

```bash
./svt.sh setup                 # rustup + cargo + python venv (contained)
./svt.sh vendor-sv-parser      # re-fetch pin into crates/sv-parser + apply patches
```

```powershell
.\svt.ps1 setup
.\svt.ps1 vendor-sv-parser
```

Both commands use:

- Contained `RUSTUP_HOME` / `CARGO_HOME` under `.tools/`
- Contained Python venv under `.tools/python-venv`
- `tools/refresh_sv_parser.py` (stdlib only)

## Patches

Ordered files in `patches/sv-parser/*.patch` are applied after clone.
Prefer adapter-layer changes in `sv-timing-core` over deep parser forks.

## Do not

- Re-license parser crates as proprietary
- Point Cargo.toml at crates.io `sv-parser` for production builds of this package
  (path dependency only)
