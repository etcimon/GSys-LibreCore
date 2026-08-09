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
| `b1-amo-spin-lock` | `mini_amoadd_w_spin.S` | **gate green**; OpenSBI spins peeled | soft-ladder-di-regress |
| `b1-lrsc-cmpxchg` | `mini_lrsc_d.S` | **gate green**; natural LR/SC default | soft-ladder-di-regress |
| `b1-csr-expected-trap` | `mini_csr_expected_trap.S` | **gate green**; CSR probes peeled | soft-ladder-di-regress |
| `b1-dual-cmv-s3` | `mini_dual_cmv_s3.S` (+ strlen bridges) | **peeled** natural c.mv | soft-ladder-di-regress |
| `b1-fdt-strlen` | `mini_strlen_rvc` / `mini_dual_cmv_strlen` bare green; OpenSBI PEEL_FDT_MATCH red | **active** | soft-ladder-opensbi-soak |
| `b1-heap-freelist-malloc` | soft malloc default | PEEL_MALLOC open | soft-ladder-opensbi-soak |
| `b1-fdt-lenp-store` | FDT lenp / real printf | planned | after fdt_match peel |

## OpenSBI cookie gate (step 2)

```bash
bash verif/regress/soft-ladder-opensbi-soak.sh   # strict 51b1babe
# Default soft ELF: soft malloc + natural spins/cmpx/CSR/c.mv + soft fdt_match
# PEEL_FDT_MATCH=1   # fails mid-sbi_strlen (iter-009)
# PEEL_MALLOC=1 SOFT_SPIN=1 SOFT_CMPX=1 SOFT_CSR=1 SOFT_CMV=1  # bisect
```

See `architecture/multi-threading/soft-ladder/b3-sim-harness.md`.
