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

## Ordered path step2 peels (env, default off)

| Env | Effect | Needs |
|-----|--------|--------|
| `PEEL_SPIN=1` | no SA/heap/scratch spin NOP4 | b1-amo-spin-lock RTL |
| `PEEL_CMPX=1` | no soft ld/sd cmpx (diag LR/SC) | b1-lrsc-cmpxchg RTL |
| `PEEL_CSR=1` | no CSR probe cut after memset | b1-csr-expected-trap RTL |
| `PEEL_CMV=1` | natural c.mv @7312/14 | b1-dual-cmv-s3 |
| `PEEL_ALL_B1=1` | all four (experimental) | all B1 minis green |

Step1 directed soak: `bash verif/regress/soft-ladder-di-regress.sh`.

## Retirement

When inventory marks `b3-mk-plat-skip-oracle` **retired**, this README becomes
historical and the script is unused or gated by `SOFT_LADDER=1`.
