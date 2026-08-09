# tmp-dual-ci soft ladder (binary oracle)

## Role

`mk_plat_skip.py` builds `fw_payload_r3a_c15_plat_skip.elf` by **binary-patching**
a stock OpenSBI payload. It is the **interim oracle** for dual-issue OpenSBI
bring-up (cont.33–51), not production firmware.

Promotion map: `../architecture/multi-threading/soft-ladder/`.

## Rules

1. **No new hard-coded VA** without an `inventory.yaml` id and bucket.
2. **Prefer shrink over grow** — each B1/B2 landing should delete sites here.
3. **Probe scripts** (`run_c*.py`) are experimental; production path is only
   `mk_plat_skip.py` + documented inventory head.
4. **SUCCESS** = `51b1babe` in trapdump (see soft-ladder `b3-sim-harness.md`);
   tohost timeout alone is not a fail if cookie present.

## Build (lab)

```text
python tmp-dual-ci/mk_plat_skip.py
# → fw_payload_r3a_c15_plat_skip.elf
# Run under Variane DI (g6lc64_smt2 / work-ver-smt2) with CVA6_TRAP_DUMP=1
```

## Default soft ELF (2026-08-08)

| Item | Default | Bisect restore |
|------|---------|----------------|
| SA / freelist spins | **natural** (peeled) | `SOFT_SPIN=1` |
| atomic_cmpxchg | **natural LR/SC** (peeled) | `SOFT_CMPX=1` |
| hart_init CSR probes | **natural** (peeled) | `SOFT_CSR=1` |
| malloc/zalloc/free | **soft NULL/ret** | `PEEL_MALLOC=1` |
| dual c.mv @7312/14 | **nop** (still open) | `PEEL_CMV=1` (fails cookie) |

Cookie gate: `bash verif/regress/soft-ladder-opensbi-soak.sh`  
Step1 directed: `bash verif/regress/soft-ladder-di-regress.sh`

## Retirement

When inventory marks `b3-mk-plat-skip-oracle` **retired**, this README becomes
historical and the script is unused or gated by `SOFT_LADDER=1`.
