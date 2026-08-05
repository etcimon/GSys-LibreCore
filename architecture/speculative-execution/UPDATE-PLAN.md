# FSE update plan — full speculative execution

Companion to `full-speculation-architecture.md`.  
**Rule:** each phase is mergeable with `DeepSpecEn=0` identity; enable experimental
package `cv64a6_spec_deep` (and later `g6lc64_ooo_server`) for depth.

---

## Phase map

| Phase | Name | Outcome | Depends |
|-------|------|---------|---------|
| **S0** | Architecture of record | This doc + architecture README | — |
| **S1** | Depth plane + STQ parameterize | `DeepSpecEn`, auto SB/load/store/ckpt floors, STQ depth, PMU g3, `cv64a6_spec_deep` | S0 |
| **S2** | Control recovery completeness | BP ckpt ↔ RAS/FTQ; mispredict residual kill; non-idempotent load gate audit | S1 |
| **S3** | Memory dependence + OoO attach | `MemDepPredEn` training, LSQ/SB co-squash, formal cancel invariant | S1 |
| **S4** | Selective recovery polish | Younger-only LSU squash; exception path cost; IQ class split (opt) | S2,S3 |
| **S5** | SMT-aware speculation | Hart-tagged cancel; dual-hart mispredict isolation | S2, SMT live |
| **S6** | Hardening | Litmus RVWMO/A, security note, optional suite `spec-deep-tests` | S3–S5 |

---

## S0 — Architecture of record ✅ (this pass)

- [x] `full-speculation-architecture.md`
- [x] `UPDATE-PLAN.md`
- [x] Refresh `README.md` status

---

## S1 — Depth plane + store queue ✅

### Intent
Unblock B1/B2 without turning on full OoO. Dual-issue + speculative SB can use a
**deeper** load/store window and matching BP checkpoints.

### Work items

| # | Item | Files | Done when |
|---|------|-------|-----------|
| S1.1 | `DeepSpecEn` in `cva6_user_cfg_t` / `cva6_cfg_t` + `check_cfg` | `config_pkg.sv`, packages | elab |
| S1.2 | `build_config_pkg` auto floors for SB, load, store, BPCkpt when DeepSpec | `build_config_pkg.sv` | DeepSpec package sizes |
| S1.3 | `store_buffer` DEPTH_SPEC/COMMIT from cfg when DeepSpec else 4 | `store_buffer.sv` | depth 4 identity |
| S1.4 | PMU group 3: bmiss cancel, sb_full, deep-spec markers | `perf_counters.sv`, probes | events selectable |
| S1.5 | Scoreboard: expose cancel-fire for PMU | `scoreboard.sv`, `cva6.sv` | probe wired |
| S1.6 | Package `cv64a6_spec_deep_config_pkg.sv` | `core/include/` | lint target |
| S1.7 | Docs + optional suite stub | architecture, defaults optional | documented |

### Timing / SoC notes
- Deeper STQ widens CAM for page-offset match → keep depth ≤16 on DeepSpec v1.
- No new clock domain; async reset discipline unchanged.

### Exit criteria
- Default targets lint **unchanged** behaviourally (DEPTH 4).
- `cv64a6_spec_deep` lint PASS with deeper queues.
- Architecture docs reference S1 loci.

---

## S2 — Control recovery completeness ✅

| # | Item | Notes | Status |
|---|------|-------|--------|
| S2.1 | Full RAS stack in `g6lc_bp_ckpt` + restore | `ras.sv` snapshot/restore; `bp_top` wires | **done** |
| S2.2 | Empty-ckpt mispredict flushes GHR | `ghist_flush = flush_bp \| (mispredict && !restore_v)` | **done** |
| S2.3 | NI speculative load audit | Documented in `load_unit`; WAIT_SPEC_LOAD + `!paddr_ni` gate | **done** |
| S2.4 | Directed test + gate | `verif/tests/custom/spec/spec_mispredict_chain.S`, `spec-deep-path.ps1` | **done** |

---

## S3 — Memory dependence + OoO co-recovery ✅

| # | Item | Notes | Status |
|---|------|-------|--------|
| S3.1 | `OoOEn` ⇒ `MemDepPredEn` in `build_config`; multi-port + dep train | memdep clears on mispredict | **done** |
| S3.2 | Recovery timeline | `ooo_dispatch` header + `architecture/out-of-order/recovery-timeline.md` | **done** |
| S3.3 | Formal cancel vs commit_drop | `core/ooo/formal/g6lc_ooo_cancel_props.sv` | **done** |
| S3.4 | `spec_mispredict_chain` on `testlist_ooo_l3.yaml` | optional `ooo-l3-tests` suite | **done** |

---

## S4 — Selective recovery polish ✅

| # | Item | Notes | Status |
|---|------|-------|--------|
| S4.1 | Younger-only load_buf + speculative STQ cancel | `cancelled_mask` → `load_unit` / `store_buffer` (tid-tagged STQ) | **done** |
| S4.2 | Optional FU-class IQ split | deferred (area); age-ordered multi-grant IQ remains | deferred |
| S4.3 | STQ CAM vs depth note | recovery-timeline + below | **done** |

**S4.3 timing/area note:** Speculative STQ page-offset CAM is O(DEPTH_SPEC). Under
`DeepSpecEn`, DEPTH_SPEC is next_pow2(MaxOutstandingStores) capped at 16 — keep CAM
latency in mind for P&R; do not grow past 16 without pipelining the match.

---

## S5 — SMT-aware speculation

| # | Item | Notes |
|---|------|-------|
| S5.1 | Cancel window filtered by `hart_id` | **done** — `resolved_branch.hart_id` + SBE tags; NrHarts=1 identity |
| S5.2 | Per-hart BP ckpt or banked GHR restore only | **done** — banked `g6lc_bp_ckpt`; train/resolve hart on GHR/RAS/Gshare |
| S5.3 | Dual-hart CI + smt-linux-boot-path unchanged | speculation not DT-visible |

---

## S6 — Hardening

| # | Item | Notes |
|---|------|-------|
| S6.1 | Optional suite `spec-deep-tests` | **done** — `testlist_spec_deep.yaml` + regress + defaults suite |
| S6.2 | RVWMO/A litmus subset under DeepSpec | **done** — `spec_rvwmo_litmus.S` (single-hart); STQ/fence directed |
| S6.3 | Security residual section in README | **done** — residual table; no default SpecFenceEn |
| S6.4 | Update `AGENTS-specs-to-impl` / coverage | **done** — impl/tests/coverage maps |

---

## Package matrix

| Package | DeepSpecEn | OoOEn | Role |
|---------|------------|-------|------|
| `cv64a6_imafdc_sv39` (default) | 0 | 0 | production identity (in-order) |
| `cv64a6_spec_deep` | **1** | 0 | dual-issue deep in-order speculation |
| `g6lc64_smt2` | 0 (later 1) | 0 | SMT bring-up |
| `g6lc64_ooo` | **1** | **1** | **production** dual-issue OoO lite |
| `g6lc64_ooo_server` | **1** | **1** | **production** 4-issue server OoO + deep mem |

---

## Progress log

| Date | Phase | Note |
|------|-------|------|
| 2026-07-25 | S0+S1 start | Architecture + DeepSpecEn + STQ param + package + PMU g3 |
| 2026-07-25 | S1 landing | `DeepSpecEn` in cfg; build floors; store_buffer depth; `spec_cancel` PMU g3; `cv64a6_spec_deep` |
| 2026-07-25 | U5 promote | OoO **production** (not experimental); cancel-mask IQ/ROB/LSQ recovery; `g6lc64_ooo` lite |
| 2026-07-25 | **S2** | RAS stack ckpt/restore; empty-ckpt GHR flush; NI audit; `spec_mispredict_chain` + gate |
| 2026-07-25 | **S3** | MemDep auto+train; recovery timeline; cancel formal; testlist hook |
| 2026-07-25 | **Runner fix** | Windows/pwsh regress: runRegressScript, DV_TARGET, real lint (no silent PASS) |
| 2026-07-25 | **S4** | Younger-only load_buf/STQ cancel via cancelled_mask; STQ tid + dense repack |
| 2026-07-25 | **S5** | Hart-filtered SpeculativeSb cancel; banked BP ckpt; resolve-hart GHR/RAS train |
| 2026-07-25 | **S6** | `spec-deep-tests` suite; RVWMO/A directed litmus; security residual; traceability |
