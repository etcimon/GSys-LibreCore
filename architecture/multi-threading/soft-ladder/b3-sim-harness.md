# B3 — Sim / harness only

These soft-ladder pieces must **never** be required for production ROM or
tape-out firmware. They define how the lab decides “green.”

## SUCCESS definition (current lab)

| Signal | Meaning |
|--------|---------|
| Trapdump / mem `@0x80001000` low word contains `0x51b1babe` | Soft-ladder success cookie |
| `@0x80001068` / nearby `0x42414e52` (`BANR`) | Soft printf exercised |
| `coldboot_done=1` | OpenSBI coldboot flag |
| `tohost` timeout (`2147483647`) | Common after WFI cookie — **not** automatic fail if cookie present |
| `0x51b1dead` | Hang / error cookie |

Document in soak scripts: **cookie wins over tohost FAIL** for soft-ladder DI runs.

## Artifacts

| Artifact | Role |
|----------|------|
| `tmp-dual-ci/mk_plat_skip.py` | Optional production soft ELF builder (oracle) |
| `tmp-dual-ci/run_c*.py` | Historical / ad-hoc peels — do not grow without inventory id |
| `tmp-dual-ci/veri_DI_*.err` | Trapdump evidence |
| `CVA6_TRAP_DUMP=1` | TB trapdump |
| Variane `+time_out=` | Bound sim |

## Harness work (iteration backlog)

1. **Codify SUCCESS** in one shell/ps1 helper used by soak (grep cookie; exit 0/1).
2. **Optional** TB decode of cookie address without OpenSBI soft caves (long-term).
3. **Shrink rule:** no new hard-coded VA in `mk_plat_skip` without a new `inventory.yaml` row.
4. **Lottery / multi-hart:** keep sim-only force separate from platform multi-hart bring-up.

## Related regress

| Script | Note |
|--------|------|
| `verif/regress/soft-ladder-di-regress.sh` | **Ordered path step1** — B1 four minis on work-ver-smt2 |
| `verif/regress/dual-iss-regress.sh` | Dual-plane; `SOFT_LADDER=1` appends B1 minis |
| `tmp-dual-ci/mk_plat_skip.py` | Step2 peels via `PEEL_SPIN` / `PEEL_CMPX` / `PEEL_CSR` / `PEEL_CMV` |
| `verif/regress/soft-ladder-di-residuals.md` | Test table + gate commands |
| `verif/regress/smt-linux-boot-path.*` | SMT2 Linux path |

## Retirement of `mk_plat_skip`

When all B1 open residuals are `rtl-fixed` and B2 intentional softs are
`source-landed`, run stock (or profile) OpenSBI on DI:

- Cookie or real boot progress without binary patches → mark
  `b3-mk-plat-skip-oracle` **retired**.
- Keep `mk_plat_skip.py` in history or behind `SOFT_LADDER=1` only.
