# B3 — Sim / harness / suite contract (build-platform home)

These pieces must **never** be required for production ROM or tape-out firmware.
They define how the **residual scaffold** decides “green” and how peels isolate B1 work.

Long-term home: **build-platform optional suites + docs**, not `tmp-*` oracles.
See parent `README.md` phases **P0** (register contract) and **P3** (stack climb).

## SUCCESS definition (suite metadata)

| Signal | Meaning | Applies to |
|--------|---------|------------|
| Trapdump / mem `@0x80001000` low word `0x51b1babe` | Soft-ladder / OpenSBI residual **success cookie** | `soft-ladder-osbi` |
| `@0x80001068` / nearby `0x42414e52` (`BANR`) | Soft printf exercised (evidence, not sole green) | osbi |
| `coldboot_done=1` | OpenSBI coldboot flag | osbi |
| `tohost` timeout (`2147483647`) | Common after WFI cookie — **not** automatic fail if cookie present | osbi |
| `0x51b1dead` | Hang / error cookie | osbi |
| Mini tohost / PASS contract | Per-test bare-metal | `soft-ladder-di` |

**Hard rule:** for OpenSBI residual, **cookie wins over tohost FAIL/SUCCESS**.  
Harness `SUCCESS (tohost=0)` without `[1000]=…51b1babe` is **not** green for osbi.

## Build-platform placement

| Artifact | Role | Status |
|----------|------|--------|
| `verif/regress/soft-ladder-di-regress.sh` | Suite driver: B1 minis under DI | Suite id **`soft-ladder-di`** (optional) |
| `verif/regress/soft-ladder-opensbi-soak.sh` | Suite driver: OpenSBI cookie + `PEEL_*` | Suite id **`soft-ladder-osbi`** (optional) |
| `build-platform/src/config/defaults.ts` | Catalog: `optional: true`, not in `defaultSuites` | **P0 done** (+ diag `diag-soft-ladder-paths`) |
| `verif/regress/AGENTS-regress-scripts.md` | Isolation ladder + env knobs | Keep in lockstep |
| `verif/regress/dual-iss-regress.sh` | Dual-plane; `SOFT_LADDER=1` appends B1 minis | Related, optional |
| `software/smt2-linux/soft-ladder/mk_plat_skip.py` | Temporary binary oracle | Shrink on every peel; retire at P4 complete |
| `CVA6_TRAP_DUMP=1` / Variane `+time_out=` | TB observability | Sim-only |

### Registration sketch (P0)

```text
id: soft-ladder-di
  group: directed, target: g6lc64_smt2 (or harness-driven)
  optional: true, openSource: true
  tools: riscv-gcc, verilator
  SUCCESS: mini contracts

id: soft-ladder-osbi
  group: directed, target: g6lc64_smt2
  optional: true, openSource: true
  tools: riscv-gcc, verilator
  SUCCESS: cookie 51b1babe only
  env contract: SOFT_LADDER_HARNESS, PEEL_*, SOFT_*
```

Optional later **diag**: path-check for oracle/ELF; cookie grep helper — compartment under
`diagnostics.tests`, not a default `probe` gate.

## Generic residual knobs

| Variable | Scripts | Meaning |
|----------|---------|---------|
| `SOFT_LADDER_HARNESS` | di + osbi | Prefer `work-ver-smt2-fw64` (FETCH_WIDTH≥64) |
| `PEEL_*` | osbi + oracle | Bisect natural path; not default product |
| `SOFT_*` / default soft sites | oracle | Holding softs; inventory-tracked |
| `DV_TARGET` / package | suites | Topology package (smt2 vs stream8) |

Stack climb (narrow → wide), same isolation philosophy as `AGENTS-regress-scripts.md`:

```text
soft-ladder-di (bare minis, DI)
        ↓
soft-ladder-osbi (OpenSBI + cookie; peels for bisect)
        ↓
topology / R3 / Linux (only after FDT walk trusted)
```

## Harness work (scaffold backlog)

1. ~~**P0:** Register both suites in `defaults.ts`~~ **done** (+ residual path diag).
2. Codify cookie SUCCESS in soak exit path (already scripted; keep suite description explicit).
3. Optional TB decode of cookie without OpenSBI soft caves (long-term observability).
4. **Shrink rule:** no new hard-coded VA in `mk_plat_skip` without `inventory.yaml` row.
5. Lottery / multi-hart sim force stays separate from platform multi-hart bring-up.
6. Prefer directed minis that promote to **RTL** over growing soft defaults (P1–P2 active: FDT lenp).

## Related docs

| Path | Note |
|------|------|
| `README.md` | P0–P6 north star |
| `b1-rtl-residuals.md` | RTL promotion targets |
| `b2-firmware-policy.md` | P5 only |
| `verif/regress/soft-ladder-di-residuals.md` | Test table + gate commands |
| `../fdt-topology-soft-ladder.md` | After FDT peel trust |

## Retirement of `mk_plat_skip`

When all B1 open residuals are `rtl-fixed` and only intentional B2 softs remain
`source-landed`:

- Stock (or source-profile) OpenSBI on DI with cookie / real boot progress **without**
  binary patches → mark oracle **retired**.
- Keep `mk_plat_skip.py` as history / optional `SOFT_LADDER=1` rebuild helper only.
- Scaffold remains: suites + minis + peel knobs for the **next** residual class.
