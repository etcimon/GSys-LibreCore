# Optional soak profile TOMLs

Profiles here are discovered by `python tools/svt.py monorepo-soak` when present.
If this directory is empty of `*.toml`, the package uses **built-in** profiles that
point at `../flists/sparse_*.f`.

Example `custom_ex.toml`:

```toml
id = "custom_ex"
flist = "verif/sv-timing-tests/flists/sparse_ex_units.f"
modules = ["alu", "mult"]
param_map = "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json"
target_mhz = 1250.0
soft_missing = true
notes = "narrower EX slice for package bring-up"
```

See `sv-timing/architecture/MONOREPO-SOAK.md`.
