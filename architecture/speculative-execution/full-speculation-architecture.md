# Full Speculative Execution (FSE) — architecture

**Status:** design of record for deep speculation on CVA6V-EC.  
**Seam:** config-gated (`DeepSpecEn`, existing `SpeculativeSb` / `OoOEn` / U1–U2 / U4).  
**Default:** production packages keep identity paths (`DeepSpecEn=0`, `OoOEn=0`).  
**Playbook:** `agents/guides/AGENTS-speculation.md`. **Plan:** `UPDATE-PLAN.md`.

---

## 1. Goal

Build a **unified speculative-execution stack** that reuses every live mechanism in the
tree (U1 prediction + checkpoints, U2 FTQ/FDIP/loopbuf, dual-issue + `SpeculativeSb`
cancel, U4 slice-OoO, U5 rename/ROB/LSQ, SMT banks, L2/L3 MLP) while attacking the
**common bottlenecks** that leave ILP/MLP on the table:

| Rank | Bottleneck (observed / structural) | Effect |
|------|------------------------------------|--------|
| B1 | Speculative store queue hard-coded `DEPTH_SPEC=4` | Store issue stalls after 4 in-flight stores |
| B2 | Load buffer default 2 entries | MLP capped; D$ miss hides poorly |
| B3 | Mispredict cancels SB younger ops but FE/ckpt/RAS not always co-restored | Extra residual bubbles |
| B4 | Memory dependence conservatism (or disabled store-set) | False load stalls / rare order bugs if over-aggressive |
| B5 | Rename/IQ/ROB full under 4-issue without scaled LSQ | OoO backpressure |
| B6 | Coarse exception flush (full pipe) vs selective squash | Over-kill recovery cost |
| B7 | SMT switch + shared BHT/BTB pollution | Cross-hart mispredict tax |
| B8 | Non-idempotent / fence / LR-SC interaction with deep load speculation | Correctness cliffs |

FSE is **not** “turn `OoOEn=1` and hope.” It is a **control plane + depth plan + recovery
contract** that makes in-order dual-issue, slice-OoO, and full OoO share one recovery model.

---

## 2. Current inventory (assets to exploit)

```
                    ┌──────────── U2 FTQ / FDIP / loop ────────────┐
                    │              U1 TAGE / ITTAGE / RAS            │
 Fetch ─────────────┤              g6lc_bp_ckpt (GHR)               ├──► ID
                    └──────────── resolved_branch / redirect ───────┘
                                      │
         SpeculativeSb cancel ◄───────┤ bmiss younger-than-branch
                                      ▼
 Decode ──► Scoreboard (window) ──► Issue ──► EX / branch_unit
                │                      │
                │                      ├──► LSU: load_unit buf, store_buffer
                │                      │         (spec Q → commit Q)
                │                      └──► U4 slice A/B (optional)
                │
                └── OoOEn? ──► rename / IQ / ROB / LSQ / memdep / PRF
                                      │
 Commit ◄──── in-order retire ────────┘    controller flush fan-out
 SMT: banked RF/CSR/PC/RAS/GHR; IF switch; mhartid = base+h
 Mem: L2/L3 + PF (MLP below core)
```

| Layer | Live RTL | Config |
|-------|----------|--------|
| Control predict | `frontend/`, `cva6_bp_*`, `g6lc_bp_ckpt` | `BPType`, `BPCkptDepth`, `FtqDepth`, `FdipEn` |
| In-flight window | `scoreboard.sv` cancel path | `NrScoreboardEntries`, **`SpeculativeSb`** (auto if SS/U4/U5) |
| Issue width | `issue_read_operands`, multi-issue | `NrIssuePorts`, `SuperscalarEn` |
| Slice MLP | `cva6_slice_*` | `SliceOoOEn` ⊥ `OoOEn` |
| Full OoO | `core/ooo/*` | `OoOEn`, ROB/IQ/LSQ/PRF auto in `build_config_pkg` |
| Mem order | `load_unit`, `store_buffer`, `lsu_bypass`, `amo_buffer` | `NrLoadBufEntries`, `MaxOutstandingStores` |
| Memdep | `g6lc_memdep.sv` | `MemDepPredEn` |
| Recovery ctrl | `controller.sv` | mispredict / fence / exception / SMT switch |
| SMT | `core/smt/*` | `NrHarts`, policies |
| Observability | `perf_counters` g0–g2, RVFI | `SscofpmfEn` |

**Identity rule:** `DeepSpecEn=0 ∧ OoOEn=0 ∧ SliceOoOEn=0` must remain synthesizable and
behaviourally equivalent to the pre-FSE dual-issue path (store queue depth stays 4).

---

## 3. Architecture principles

1. **One recovery contract.** Every speculative structure is either:
   - *age-squashable* on mispredict (SB cancel, rename ckpt, LSQ younger-than-branch), or  
   - *flushed* on exception/fence/CSR side-effect (controller existing fan-out), or  
   - *hint-only* (way-pred, IST, store-set tables) and may clear anytime.
2. **Architectural visibility only at commit.** Stores leave speculative→commit queue only
   after commit; CSRs/RF via commit; LR/SC reservation rules preserved (`#ext:a`, RVWMO).
3. **Depth scales with window, not with hope.** SB, BP ckpt, load buf, store Q, ROB/LSQ
   grow together under `DeepSpecEn` / `OoOEn` via `build_config_pkg` inference.
4. **Bottleneck-first.** Prefer fixing B1–B4 before adding exotic predictors (value
   prediction, runahead threads).
5. **Config-gated SoC readiness.** New behaviour behind `cva6_cfg_t` + `check_cfg`;
   minimal packages still elaborate; DFT/scan/RVFI preserved.
6. **Composability.** FSE depths work with `NrHarts=1` first; SMT gets per-hart squash
   tags in a later phase (S5), not in the first depth ramp.

---

## 4. Logical planes

### 4.1 Control-flow speculation (CFE)

- **Predict:** U1 fabric + U2 FTQ supply fetch stream.
- **Checkpoint:** `g6lc_bp_ckpt` holds GHR; depth ≥ in-flight branch count (≈ SB).
- **Resolve:** `branch_unit` → `resolved_branch_i`.
- **Recover:** mispredict → FE redirect + flush IF/unissued + **SB younger cancel**
  (`SpeculativeSb`) + rename/IQ/ROB squash when `OoOEn` + restore GHR from ckpt.
- **Optimize:** reduce residual wrong-path issue after bmiss; ensure ckpt not undersized
  (`BPCkptDepth ≥ NR_SB_ENTRIES` when speculative).

### 4.2 Data / memory speculation (MEM)

- **Load speculation:** issue loads past unresolved stores when safe; buffer misses
  (`NrLoadBufEntries` / LSQ loads).
- **Store speculation:** hold in speculative STQ until commit (`store_buffer`).
- **Dependence:** store-set (`MemDepPredEn`) + LSQ CAM/STL under OoO; conservative
  page-offset match on in-order path.
- **Fences / non-idempotent:** no speculative load from non-idempotent PMA; fence drains
  commit STQ + optional D$ policy bits.
- **Optimize B1/B2:** parameterize STQ depth; raise load buf with DeepSpec.

### 4.3 Register / rename speculation (REG) — when `OoOEn`

- Multi-port rename + precise map/free/busy checkpoint (already in `g6lc_rename`).
- Same-cycle chain wakeup, PRF write-through + WB bypass (bottleneck table in
  `architecture/out-of-order/README.md`).
- FSE requires **recovery co-timing**: mispredict_i and flush_i order documented in
  UPDATE-PLAN S3.

### 4.4 Thread speculation (SMT)

- Fine-grain IF switch already preserves EX/SB; banks isolate arch state.
- FSE later: tag cancel windows by `hart_id` so hart0 mispredict does not cancel hart1
  younger ops (today shared SB requires careful issue rules when `NrHarts>1`).

### 4.5 Hierarchy speculation (MEM system)

- L2/L3 + server PF already provide miss MLP; FSE deepens **core-side** outstanding
  misses so hierarchy latency is hidden. Not a new L1 protocol.

---

## 5. Recovery matrix (normative for implementers)

| Event | IF | Unissued | SB | EX pipeline | Spec STQ | Load buf | BP/FTQ | Rename/ROB/LSQ | Arch state |
|-------|----|----------|-----|-------------|----------|----------|--------|----------------|------------|
| Branch mispredict | flush | flush | cancel younger | drain / cancel younger | flush younger stores* | flush younger loads* | restore ckpt + redirect | squash younger | unchanged |
| Exception / illegal | flush | flush | full flush | flush | flush | flush | flush/redirect PC | full flush | commit older only |
| FENCE / FENCE.I | flush | flush | flush | flush | drain+policy | flush | — | flush | as ISA |
| SFENCE/HFENCE | flush | flush | flush | flush | drain | flush | — | flush | TLB |
| CSR side-effect | flush | flush | flush | flush | — | — | — | flush | at commit |
| SMT switch (fine) | flush | drop unissued | keep | drain | keep | keep | keep (banked RAS/GHR) | keep | banked |

\*In-order path: today STQ/load flush is coarse (`flush_i`). S2 refines younger-only where safe.

---

## 6. Depth / sizing model (`DeepSpecEn`)

When `DeepSpecEn=1` (experimental / server profiles only):

| Structure | Inference (0 or undersized → auto) |
|-----------|--------------------------------------|
| `NrScoreboardEntries` | max(user, `8 × NrIssuePorts`) |
| `BPCkptDepth` | max(user, `NR_SB_ENTRIES`) |
| `NrLoadBufEntries` | max(user, `4 × NrIssuePorts`) |
| `MaxOutstandingStores` | max(user, `4 × NrIssuePorts`) |
| STQ `DEPTH_SPEC` | next_pow2(`MaxOutstandingStores`) when DeepSpec else **4** |
| STQ `DEPTH_COMMIT` | next_pow2(min(8, MaxOutstandingStores)) when DeepSpec else **4** |
| If `OoOEn` | existing ROB/IQ/LSQ/PRF scale; prefer `MemDepPredEn=1` |

`check_cfg`: `DeepSpecEn → SpeculativeSb`; `DeepSpecEn ∧ BPCkptDepth≠0 → BPCkptDepth ≥ NR_SB_ENTRIES`.

---

## 7. Bottleneck optimizations (design targets)

| ID | Mitigation | Phase |
|----|------------|-------|
| B1 | Config-tied STQ depth under `DeepSpecEn` | **S1** |
| B2 | Auto load-buf floor under `DeepSpecEn` | **S1** |
| B3 | Ckpt depth floor; RAS/FTQ restore completeness | S2 |
| B4 | Default store-set with OoO; train on squash | S3 |
| B5 | Keep OoO auto geometry; associative IQ later | S3–S4 |
| B6 | Selective exception path only if proven | S4 |
| B7 | Optional banked BHT; hart-tagged cancel | **S5** (cancel + banked ckpt/GHR; BHT table still shared) |
| B8 | PMA non-idempotent gate litmus + formal notes | S2/S6 |

---

## 8. Security / transient execution (policy)

Deepening speculation increases Spectre-class surface. FSE policy (**S6.3** detail in
`README.md`):

- No new cross-privilege cache allocate from wrong-path loads without existing PMA/PMP.
- Residual risk documented in README security table; optional `SpecFenceEn` /
  fence-on-mispredict is **not** default (performance).
- Prefer software (OpenSBI/Linux) barriers for confidential workloads; hardware fence
  mode is a later optional knob.
- SMT: same-hart cancel + banked BP state (S5) limit peer-hart wrong-path squashes,
  not a full confidentiality guarantee.

---

## 9. Verification strategy

| Layer | Method |
|-------|--------|
| Elab/lint | `cv64a6_spec_deep` + default `DeepSpecEn=0` identity |
| Directed | **`spec-deep-tests`**: mispredict, STQ stress, fence drain, RVWMO/A subset |
| OoO | existing `ooo-l3-tests` (optional) |
| Formal | rename freelist/ROB props; cancel-younger invariant (`g6lc_ooo_cancel_props`) |
| Linux | unchanged DTS (speculation not DT-visible); SMT path separate |

---

## 10. Non-goals (this program)

- Value prediction / multipath execution  
- Runahead “ghost” threads beyond existing SMT  
- Changing RVWMO to TSO by default  
- Moving L2/L3 into the core pipeline  

---

## 11. Related

- `UPDATE-PLAN.md` — phased implementation  
- `architecture/out-of-order/README.md` — U5 production path  
- `architecture/branch-prediction/README.md` — U1/U2  
- `router-core-upgrade-program.md` — U4/U5 program context  
