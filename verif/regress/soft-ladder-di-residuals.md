# Soft-ladder DI residuals — directed test checklist

Companion to `architecture/multi-threading/soft-ladder/`.  
**Goal:** B1 residuals get bare-metal (or minimal) tests that do not require
OpenSBI binary patching.

Status: **scaffold** — tests listed are planned; mark **landed** when in-tree.

| Inventory id | Test sketch | Status | Suite hook |
|--------------|-------------|--------|------------|
| `b1-amo-spin-lock` | `amoadd.w.aqrl` ticket-style + ALU/c.mv/stack filler | **landed scaffold** `verif/tests/custom/multicore/mini_amoadd_w_spin.S` | wire dual-iss / smt2 DI harness |
| `b1-lrsc-cmpxchg` | LR; filler ops; SC success; LR; store; SC fail | planned | dual-iss-safe (no Zacas) |
| `b1-csr-expected-trap` | illegal CSR then `csrw mtvec`; check handler / no silent skip | planned | CSR / custom |
| `b1-fdt-lenp-store` | store word via pointer that is dual-issued with address math | planned | custom |
| `b1-dual-cmv-s3` | pair `c.mv` + live `s3` consumer | planned | custom |

## Gate command (when tests land)

```bash
# Placeholder — replace with real suite name
# bash verif/regress/<suite>.sh
# Prefer DI / g6lc64_smt2 Variane; Spike not LR/SC AMO golden for all cases
```

## OpenSBI cookie gate (B2/B3, optional)

```bash
# Authoritative lab tree often E:\cva6
# python tmp-dual-ci/mk_plat_skip.py
# wsl: Variane + CVA6_TRAP_DUMP=1; SUCCESS iff 51b1babe in .err
```

See `architecture/multi-threading/soft-ladder/b3-sim-harness.md`.
