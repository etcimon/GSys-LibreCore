# Ara (RVV) vendor drop-in (U10ᵇ)

This directory is the **PDK-style drop-in** for [PULP Ara](https://github.com/pulp-platform/ara)
(or an equivalent RVV 1.0 unit). Fetch on demand; **`Flist.ara` is maintained** once synced.

## Fetch

```bash
./build.sh vendor sync ara
# or: bun build-platform/src/cli/index.ts vendor sync ara
```

Layout after sync:

```
vendor/ara/upstream/        # Ara git root (submodule)
vendor/ara/Flist.ara        # RTL flist (src + lanes; no TB) — present
vendor/ara/Flist.ara.example
```

## Wire-up checklist

1. ~~Populate `Flist.ara`~~ **done** after sync.
2. Append `Flist.ara` from the SoC/sim flist (not `core/Flist.cva6` — keep core clean).
3. List Ara’s `cva6_accel_first_pass_decoder.sv` **after** the core stub so it overrides.
4. Select package **`cv64a6_server_math_v_config_pkg`** (`RVV=1`, `CvxifEn=0`).
5. Connect Ara memory port to cluster xbar / tightly-coupled SRAM in `corev_apu`.
6. DFT: thread `test_en_i` / `testmode_i`; PMU: vector busy event.
7. Software: OpenSBI vector context; Linux `riscv,isa-extensions = "…v…"`.

## Contract

See `architecture/ara-vector-attach.md`. Accelerator path is `EnableAccelerator`
(`build_config_pkg` ← `CVA6Cfg.RVV`) through `core/acc_dispatcher.sv`.

## License

Ara’s upstream license applies to fetched RTL (typically Solderpad / Apache-style).
Do not re-license vendored files; this README is MIT (project docs only).
