# Soft-ladder DI residuals — directed test checklist

Companion to `architecture/multi-threading/soft-ladder/`.  
**Goal:** B1 residuals get bare-metal (or minimal) tests that do not require
OpenSBI binary patching.

**Ordered path:** `architecture/multi-threading/soft-ladder/CONT-FULL-MAP.md` §6.

## Gate command (step 1)

```bash
# Preferred: smt2 Variane harness + four B1 minis
bash verif/regress/soft-ladder-di-regress.sh

# Compile only (no sim)
SOFT_LADDER_COMPILE_ONLY=1 bash verif/regress/soft-ladder-di-regress.sh

# Dual-iss Spike+Variane append
SOFT_LADDER=1 bash verif/regress/dual-iss-regress.sh
```

| Inventory id | Test | Status | Suite hook |
|--------------|------|--------|------------|
| `b1-amo-spin-lock` | `mini_amoadd_w_spin.S` | **scaffold + gate** | soft-ladder-di-regress |
| `b1-lrsc-cmpxchg` | `mini_lrsc_d.S` | **scaffold + gate** | soft-ladder-di-regress |
| `b1-csr-expected-trap` | `mini_csr_expected_trap.S` | **scaffold + gate** | soft-ladder-di-regress |
| `b1-dual-cmv-s3` | `mini_dual_cmv_s3.S` | **scaffold + gate** | soft-ladder-di-regress |
| `b1-fdt-lenp-store` | FDT lenp / stack pointer under DI | planned | after step2 peels green |

## OpenSBI cookie gate (step 2, B2/B3)

```bash
python tmp-dual-ci/mk_plat_skip.py
# optional peels (one at a time):
# PEEL_SPIN=1 PEEL_CMPX=1 PEEL_CSR=1 PEEL_CMV=1
# Variane DI + CVA6_TRAP_DUMP=1; SUCCESS iff 51b1babe
```

See `architecture/multi-threading/soft-ladder/b3-sim-harness.md`.
