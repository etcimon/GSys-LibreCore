# Soft-ladder OpenSBI binary oracle

## Role

`mk_plat_skip.py` builds `build/fw_payload_r3a_c15_plat_skip.elf` by
**binary-patching** a stock OpenSBI payload (`build/fw_payload_diag.elf`).
It is the **interim oracle** for dual-issue OpenSBI bring-up, not production
firmware.

Promotion map: `architecture/multi-threading/soft-ladder/`
(`CONTRACT.md` = G1 genericity / later-axis soak; OpenSBI stays software).

Formerly lived at repo-root `tmp-dual-ci/` (moved 2026-08-09).

## Layout

| Path | Role |
|------|------|
| `mk_plat_skip.py` | Binary peels / soft stubs |
| `build/fw_payload_diag.elf` | Source payload (gitignored or lab artifact) |
| `build/fw_payload_r3a_c15_plat_skip.elf` | Patched output |
| `architecture/multi-threading/soft-ladder/` | Inventory, iteration log, B1/B2/B3 maps |

## Rules

1. **No new hard-coded VA** without an `inventory.yaml` id and bucket.
2. **Prefer shrink over grow** — each B1/B2 landing should delete sites here.
3. **SUCCESS** = `51b1babe` in trapdump (`b3-sim-harness.md`); harness
   `*** SUCCESS *** (tohost=0)` alone is not green.
4. **Soak** via `soak.sh` / `soak_common.sh` (no per-increment wrapper).
   Rebuild: `rebuild_slfix.sh [tag]`. Mini: `run_mini_p3split.sh` or
   `run_mini_trace.sh` (`CVA6_TRACE_FILE`). There is no testharness
   checkpoint. `g6lc_tb.cpp` + `CVA6_SOAK_EXIT=1` stops hold/nat at
   the cookie, peel at the known pin (`CVA6_PIN_MEPC`). Mini-first;
   soak after the mini moves or `SOAK_WHAT=hold`. See
   `architecture/multi-threading/soft-ladder/b3-sim-harness.md`.

## Build (lab)

```text
python software/smt2-linux/soft-ladder/mk_plat_skip.py
# → software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.elf

bash verif/regress/soft-ladder-opensbi-soak.sh
# Prefer SOFT_LADDER_HARNESS=work-ver-smt2-fw64
# Bisect: PEEL_FDT_GETPROP=1 (FDT lenp residual)
```

## Default soft ELF (2026-08-09)

| Item | Default | Bisect restore |
|------|---------|----------------|
| SA / freelist spins | **natural** | `SOFT_SPIN=1` |
| atomic_cmpxchg | **natural LR/SC** | `SOFT_CMPX=1` |
| hart_init CSR probes | **natural** | `SOFT_CSR=1` |
| dual c.mv | **natural** | `SOFT_CMV=1` |
| fdt_match | **natural** | `SOFT_FDT_MATCH=1` |
| sbi_strlen | **natural** (FETCH_WIDTH=64) | `SOFT_STRLEN=1` |
| malloc/zalloc/free | **natural** | `SOFT_MALLOC=1` |
| fdt getprop | **soft NULL** (iter-012) | `PEEL_FDT_GETPROP=1` |

## Retirement

When inventory marks `b3-mk-plat-skip-oracle` **retired**, this directory becomes
historical or empty of peels.
