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
| `b1-lrsc-cmpxchg` | `mini_lrsc_d.S` | **opt-in** (2nd SC-without-LR may fail on fw64; natural LR/SC still default in osbi) | soft-ladder-di-regress (`SOFT_LADDER_TESTS=…`) |
| `b1-csr-expected-trap` | `mini_csr_expected_trap.S` + **`mini_csr_pmp_probe.S`** | **gate green** on slfix (simple + OpenSBI a3 multi-pmp shape). Hold still softs full `sbi_hart_init`. | soft-ladder-di-regress |
| `b1-plat-ops-jalr` | hold SOFT_PLAT_OPS | **active holding** — irqchip/ipi/timer/tlb `c.jalr` → FDT; soft `c.li a0,0` | soft-ladder-osbi held ELF |
| `b1-dual-cmv-s3` | `mini_dual_cmv_s3.S` (+ strlen bridges) | **peeled** natural c.mv | soft-ladder-di-regress |
| `b1-sbi-strlen-rvi` | `mini_strlen_rvc` + natural strlen | **peeled** (FETCH_WIDTH=64) | soft-ladder-di-regress |
| `b1-heap-freelist-malloc` | `mini_freelist_unlink` + natural malloc | **peeled** | soft-ladder-di-regress / osbi |
| `b1-fdt-lenp-store` | `mini_fdt_{lenp_sw,s2_nest,check_prop_nest,next_tag_lbu}` shape **PASS**; **`mini_fdt_a0_is_fdt`** stage 0 (P0–P9 fail-codes). Soft getprop holds; **PEEL `129f8`/4/9** | **active** — COMPLETION.md G0 after this mini | soft-ladder-di + soft-ladder-opensbi-soak |

## OpenSBI cookie gate (step 2)

```bash
bash verif/regress/soft-ladder-opensbi-soak.sh   # strict 51b1babe
# Default soft ELF: soft fdt getprop + soft printf; natural strlen/malloc/spins/...
# PEEL_FDT_GETPROP=1   # natural getprop → FDT lenp red (iter-012)
# SOFT_STRLEN=1 SOFT_MALLOC=1 SOFT_SPIN=1 …  # bisect restores
```

See `architecture/multi-threading/soft-ladder/b3-sim-harness.md`.
