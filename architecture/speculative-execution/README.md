# Extension point: speculative execution

Playbook: `../../agents/guides/AGENTS-speculation.md`.  
**Architecture of record:** [`full-speculation-architecture.md`](full-speculation-architecture.md)  
**Implementation plan:** [`UPDATE-PLAN.md`](UPDATE-PLAN.md)

Spec anchors: `../../agents/spec/riscv-spec-I-3.1-rvwmo.html`, `-I-4.1-zifencei.html`,
`-I-5.1-a.html`, `-I-5.5-zawrs.html`.

## Intent

Widen the speculative window, complete recovery, and deepen memory speculation while
keeping traps precise — **reusing** U1/U2/U4/U5/SMT/L2–L3 rather than inventing a
parallel pipeline.

## Current state (codebase)

| Path | Role | Related |
|------|------|---------|
| `frontend/` + U2 FTQ/FDIP/loopbuf | Predict / fetch ahead | U1, U2 |
| `g6lc_bp_ckpt.sv` | Prediction checkpoint FIFO | U1 → U4/U5/FSE |
| `scoreboard.sv` | In-flight + `SpeculativeSb` younger cancel | dual-issue, U4, U5 |
| `issue_read_operands.sv` | Operand / FU issue | multi-issue 2–8 |
| `cva6_slice_*.sv` | A-queue runahead | U4 |
| `core/ooo/*` | Rename / ROB / LSQ / memdep | U5 |
| `ex_stage` / `branch_unit` | Execute / resolve | — |
| `commit_stage` / `controller` | Retire / flush matrix | FSE recovery |
| LSU / `store_buffer` / `load_unit` | Memory speculation | **FSE S1 STQ depth** |
| `core/smt/*` | Banked state / fine switch | U6.1 |

## Config knobs

| Knob | Role |
|------|------|
| **`DeepSpecEn`** | FSE depth plane (auto SB/load/store/ckpt floors; deeper STQ) |
| `SpeculativeSb` | Younger cancel on bmiss (auto if SS / U4 / U5) |
| `NrScoreboardEntries`, `NrLoadBufEntries`, `MaxOutstandingStores` | Window / MLP |
| `BPCkptDepth` | Branch history checkpoints |
| `SliceOoOEn` / `OoOEn` | Slice MLP vs full OoO (exclusive) |
| `MemDepPredEn` | Store-set dependence predictor |

## Sanctioned seam

- Default packages: `DeepSpecEn=0` → STQ depth **4** (legacy).  
- Experimental: `cv64a6_spec_deep_config_pkg` (`DeepSpecEn=1`).  
- Full OoO: `g6lc64_ooo_server` + FSE depths.  
- New structures must appear in the recovery matrix (`full-speculation-architecture.md` §5).

## Invariants

Precise traps; speculative stores do not leave the store buffer before commit;
LR/SC and RVWMO respected; `OoOEn=0`/`DeepSpecEn=0` identity.

## Verification (S6)

| Artifact | Role |
|----------|------|
| `verif/tests/testlist_spec_deep.yaml` | Directed list (mispredict, STQ, fence, RVWMO/A) |
| `verif/regress/spec-deep-tests.{sh,ps1}` | Suite gate (`cva6.py` or lint fallback) |
| `verif/regress/spec-deep-path.{sh,ps1}` | Path/artifact gate + lint `spec_deep`/`ooo` |
| Suite id | `spec-deep-tests` in `build-platform` defaults |

## Security residual (S6.3)

Deepening speculation enlarges the Spectre-class surface. **Policy (no RTL default fence):**

| Residual | Mitigation in CVA6V-EC | Operator / software |
|----------|------------------------|---------------------|
| Speculative cache fill from wrong-path loads | PMA/PMP still gate permissions; no new cross-privilege allocate path in FSE | Prefer `fence`/`fence.i` / OpenSBI barriers for confidential regions |
| Branch/BTB history contamination | Mispredict restores GHR+RAS from banked ckpt (S2/S5); empty-ckpt flushes GHR | Training isolation optional later (`SpecFenceEn` **not** default) |
| SMT peer contamination | S5 same-hart cancel + banked GHR/RAS/ckpt | Keep confidential threads on separate harts only if SW trusts isolation |
| STQ / load-buf wrong-path data | Younger-only cancel (S4); stores never leave STQ before commit | RVWMO/A directed subset in `spec_rvwmo_litmus.S` |
| Multi-hart litmus / remote order | **Out of S6 scope** (single-hart directed only) | Full suite later or Spike/UVM |

Optional hardware `SpecFenceEn` / flush-on-mispredict remains a **future knob**, not enabled in production packages (performance). Document residual risk here and in `full-speculation-architecture.md` §8 rather than claiming “Spectre-proof.”

## Status vs scaffold

| Piece | Status |
|-------|--------|
| Core in-order speculation | **Shipping** |
| SpeculativeSb cancel | **Live** (SS/U4/U5) |
| U5 OoO path | **Gated** (`OoOEn`) |
| FSE architecture + plan | **Live docs** |
| FSE S1 depth plane | **Landed** (`DeepSpecEn`, STQ, PMU g3) |
| FSE S2 control recovery | **Landed** (GHR+RAS ckpt restore, NI audit) |
| FSE S3 memdep + OoO co-recovery | **Landed** (store-set train, timeline, formal) |
| FSE S4 younger-only LSU | **Landed** (load_buf + speculative STQ cancel) |
| FSE S5 SMT-tagged cancel | **Landed** (same-hart cancel + banked ckpt/GHR train) |
| FSE S6 hardening | **Landed** (`spec-deep-tests`, RVWMO/A subset, security residual) |
