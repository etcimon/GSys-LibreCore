# Extension point: multi-threading (SMT)

Cross-cutting: `../../agents/guides/AGENTS-soc-readiness.md`. Program: U6.1 in
`../router-core-upgrade-program.md`.

## Intent
N hardware threads over shared pipeline resources; per-hart arch state; fair arbitration.

## Current state (codebase)
| Item | Status |
|------|--------|
| `NrHarts` in `cva6_cfg_t` | **Live** — legal values 1 or 2 (`check_cfg`); default **1** |
| `SmtPolicy` / `SmtFetchQuantum` / `SmtStarveLimit` | **Live** — RR / switch-on-miss / hybrid (default hybrid) |
| Pipeline `hart_id` tagging | **Live** — `fetch_entry_t` + `scoreboard_entry_t.hart_id`; decoder stamps active hart |
| Banked RF | **Live** — `core/smt/g6lc_smt_regfile.sv` (NrHarts=1 → single `ariane_regfile`) |
| Dual PC bank | **Live** — `core/smt/g6lc_smt_pc_bank.sv` + frontend restore |
| Banked CSR | **Live** — `g6lc_smt_csr_bank.sv` (commit by `hart_id`; priv mux by active) |
| Fine-grain switch | **Live** — IF + unissued flush only; EX drains; BP preserved |
| Per-hart WFI halt | **Live** — sticky `smt_hart_halt` from `halt_csr` |
| Per-hart RAS | **Live** — `ras.sv` banks when `NrHarts>1` |
| Per-hart GHR | **Live** — `g6lc_bp_ghist` + gshare GHR banks |
| Shared BHT/BTB | Shared tables (cross-hart pollution possible) |
| `g6lc_thread_select.sv` + `g6lc_hart_state.sv` | **Live** under `core/smt/` |

### Model: fine-grain SMT (drain-friendly)
On thread switch: flush **IF** and drop **unissued** decode; restore banked NPC; **do not** clear scoreboard/EX or BP. Outgoing-hart ops retire with CSR/RF keyed by instruction `hart_id`. Active fetch hart owns RAS/GHR bank and privilege mux. See `smt2-bringup.md`.

### Contention optimisations (where dual-hart contentions bite)
1. **Switch-on-D$/I$-miss** (`SMT_SWITCH_ON_MISS` / hybrid) — sticky miss state in `g6lc_hart_state` forces an immediate peer switch when the peer is ready.
2. **Fetch quantum RR** (`SmtFetchQuantum`, default 4) — bounds unfair share of IF bandwidth.
3. **Anti-starvation** (`SmtStarveLimit`, default 16) — force switch if a ready peer has been idle that many cycles.
4. **Banked integer RF** — per-hart private 32-entry banks eliminate cross-hart write-port conflicts.
5. **L2 MSHR merge + data banks (U6.0)** — sized for dual-hart MLP.

### Enable
```
core/include/g6lc64_smt2_config_pkg.sv   # NrHarts=2, SMT_HYBRID, L2
# Default packages keep NrHarts=1 (identity netlist path).
# Bring-up: architecture/multi-threading/smt2-bringup.md
```
`mhartid` for thread *h* = `hart_id_i + h`.

## Sanctioned seam
`NrHarts==1` remains behaviourally identity. Optional next: banked BHT/BTB; dual-commit multi-hart same cycle.

## Linux / rootfs track

| Stage | Doc / suite | Status |
|-------|-------------|--------|
| DTS + RTL IRQ path | `dts-linux-smt.md`, `smt-linux-boot-path` | **Landed** |
| Rootfs plan + preflight | `smt-linux-rootfs.md`, suite `smt-linux-rootfs` | **Landed** (R1–R2) |
| OpenSBI SMT2 + dual-hart SBI payload | `software/smt2-linux/` | **Landed** (R3a) |
| Full Linux Image / cva6-sdk | `CVA6_LINUX_PAYLOAD` / `LINUX_IMAGE` | **Lab / optional R3b–c** |

Bring-up: `smt2-bringup.md`. OpenSBI: `software/smt2-linux/README.md`.  
**FDT / cpu-map / threads-per-core plan:** `fdt-topology-soft-ladder.md`
(`NrCores` × `NrHarts`, stream vs SMT, soft-ladder gates before `/proc/cpuinfo`).

### Soft-ladder promotion (DI OpenSBI → codebase)

Binary peels in `software/smt2-linux/soft-ladder/mk_plat_skip.py` are an **oracle**, not the long-term
contract. Promote via three buckets and a closed iteration loop:

| Path | Role |
|------|------|
| `soft-ladder/README.md` | Buckets B1/B2/B3, promotion order, safety rails |
| `soft-ladder/inventory.yaml` | Soft-site registry (status, loci, retire criteria) |
| `soft-ladder/ITERATION.md` | Active iteration + backlog |
| `soft-ladder/b1-rtl-residuals.md` | Core DI residuals (AMO, LR/SC, CSR, FDT, c.mv) |
| `soft-ladder/b2-firmware-policy.md` | OpenSBI/platform source profile sketch |
| `soft-ladder/b3-sim-harness.md` | Cookies / TB / SUCCESS definition |
| `soft-ladder/monorepo-soak-integration.md` | monorepo-soak patches × cont.## × RTL sync |

**Order:** B1 RTL first → B3 harness SUCCESS → B2 firmware profile → retire binary patcher.

## Invariants
Per-hart precise traps and isolation; RVWMO per and across harts; no starvation (enforced by `SmtStarveLimit` under hybrid).

## Status vs scaffold
**Fine-grain dual-PC + CSR/RF/RAS/GHR banks + drain-on-switch.** Production default remains `NrHarts=1`.  
**Linux path:** boot-path + rootfs preflight in-repo; full rootfs needs external images.
