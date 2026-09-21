# OoO + SMT2 architecture contract (`core/ooo`, `core/smt`, LSU seams)

This is the contract of record for the config-gated out-of-order backend and its path to
mixed-resident SMT2. It states structures, owners, the age key, kill identities, what may issue
out of order, what stays singleton, the timing cones of record and the exit of every tranche.
It is short on purpose. History is in `architecture/out-of-order/log-2026-09.md`; the step plan
is `AGENTS-ooo-plan.md`. A claim that is not in this file with an evidence pointer is not a claim.

Status words used below: **live** (elaborates and simulates behind `OoOEn`), **leaf-qualified**
(directed fixture with positive, negative and restored-defect mutation), **integrated** (full
core, independent reference), **open**. Nothing here is release-qualified; `OoOEn=0` remains the
protected default and the SMT2 OpenSBI anchor runs with `OoOEn=0`.

## 1. Structures and owners

| Structure | File | Owns | Status |
|---|---|---|---|
| Scoreboard | `core/scoreboard.sv` | slot allocation in program order, `trans_id`, in-order commit pointer, younger-than-branch cancel mask | live (in-order baseline) |
| Rename / RAT / free list | `g6lc_rename.sv`, `g6lc_rat.sv`, `g6lc_freelist.sv` | architectural→physical maps per hart, checkpoints per branch, busy bits | leaf-qualified (integer, FP class, NrHarts=2 maps) |
| Issue queue | `g6lc_iq.sv` | operand readiness, oldest-ready select up to `NrIssuePorts` | live; compacting; store-age gate blocks a load behind every older live store |
| ROB | `g6lc_rob.sv` | completion-by-tid shadow of the scoreboard | live; not the commit authority |
| LSQ | `g6lc_lsq.sv` | load/store entries allocated at dispatch, live AGU addresses, store data, CAM/STL hazard verdict | leaf-qualified for forwarding/credits; **no alias validation** |
| Store buffer | `core/store_buffer.sv` | speculative queue (age-sorted under OoO) and committed queue; byte-exact forward | live; committed entries exempt from age compare |
| PRF | `g6lc_prf.sv` | write-through physical file, integer and FP classes | leaf-qualified |
| FU owner tables | `core/fpu_wrap.sv`, `core/mult.sv` | one live token per tid for FPnew and the serial divider; cancelled result suppression; flush clears | leaf-qualified (8/16 slots; 32 does not exercise overlap) |
| LSU tombstones | `core/lsu_bypass.sv`, `core/load_unit.sv` | pre-grant cancellation retention, post-grant response tombstones | leaf-qualified |
| CSR buffer | `core/csr_buffer.sv` | depth-1 address hold from issue to commit; holds `flu_ready` low | live; **singleton, freezes all FLU issue** |
| Thread select | `core/smt/g6lc_thread_select.sv` | drained coarse handoff between harts | leaf-qualified sims + live-port synthesis |

## 2. Age

- Key: `trans_id` circular distance from the scoreboard commit pointer,
  `(a - commit_ptr) < (b - commit_ptr)` ⇒ `a` older than `b`.
- Soundness condition: every compared entry is **scoreboard-live**. Committed store-queue entries
  are never age-compared; they are older than any live instruction by construction.
- Today the condition is implicit at six sites (`g6lc_iq.sv` ×2, `g6lc_lsq.sv`,
  `core/store_buffer.sv` ×3). T1 makes it one function in `g6lc_ooo_pkg`, one live/committed
  flag semantics, an assertion against the scoreboard `issued` mask, and an SBY proof. `{gen,tid}`
  widening is the fallback if the proof fails, not the default.

## 3. Kill identities

| Event | Identity | Who must not forget |
|---|---|---|
| Branch mispredict | scoreboard `cancelled_mask` (sticky per slot + same-cycle window) | IQ, ROB, LSQ, PRF write gate, FU owner tables, LSU pre-grant queue |
| Full flush (exception, fence, CSR side effect, WFI under OoO) | `flush_i` | FPnew and serdiv discard in-flight work, so owner tables clear; LSU tombstones stay |
| Fetch redirect | today: killed VA + "forget on replacement" (`frontend.sv` kill persistence) | **open** — T3 replaces it with a request token through `icache_dreq/drsp` |
| Memory-order violation | **absent** | T1 adds store-address arrival → younger issued load → `replay` at commit |
| Hart handoff | drained: no issued work crosses | T6 replaces drain with per-hart cancellation identity |

A cancelled instruction's late result must never complete, wake or supply data for the slot's next
owner. FPU and divider hold this; the dispatch leaf (scenario 18) still accepts an id-only late
result, so the remaining producers (pending stores, CSR/AMO commit path, CVXIF/accelerator) are open.

## 4. Issue legality

| May issue out of program order | Stays singleton / ordered | Reason |
|---|---|---|
| ALU, branch, multiply, FP (single hart) | CSR: only at the commit head | depth-1 `csr_buffer`; T2 keeps head-ordering as serialization and removes the FLU freeze |
| Loads past **resolved non-aliasing** older stores — after T1 validation + T2 relaxation | Loads today wait for every older live store | no alias validation exists yet |
| — | Stores issue in program order today | one-deep store translation pipe; T2 reserves the spec-queue slot at dispatch and drops PO *issue*, keeps PO drain |
| — | AMO buffer depth 1, CVXIF port 0 only | unchanged |

## 5. Timing cones of record (FO4 screen, not STA)

`sparse_issue_lsu` (IQ select, store-age scan, LSQ CAM), `sparse_ex` (FLU mux, owner-table
lookups). Budget ≈ 32 FO4 at 1.25 GHz / `fo4_ps=20` / margin 0.2. Every tranche records the screen
before and after; a screen never closes timing. Compaction of the IQ each cycle is the known cost
T4 removes.

## 6. Configuration guards and the evidence that removes each

| Guard (`config_pkg::check_cfg` + `g6lc_ooo_dispatch` `$error`) | Removal evidence |
|---|---|
| `!(OoOEn && FpPresent)` | T5: Spike-ordered FP suite + cancelled-DIVSQRT mutation on `g6lc64_ooo`, single hart |
| `!(OoOEn && NrHarts > 1)` | T6: hart-tagged IQ/ROB/LSQ, per-hart commit heads/credits, peer-isolation negatives |
| `!(OoOEn && FpPresent && FLen > XLEN)` | not planned; documents a pre-existing bus width |
| `SliceOoOEn ⊕ OoOEn` | permanent |

## 7. Exits

| Tranche | Exit (positive + negative + mutation + structural) |
|---|---|
| T0 | history archived verbatim; this contract and the plan exist; checkpoint commit reviewed |
| T1 | age function used at all six sites; live-tid assertion; SBY age/violation proof with a negative witness; replay path leaf-tested; lint/synth counts unchanged |
| T2 | CSR FIFO and store reservation leaf-tested; loads bypass resolved non-aliasing stores; Spike-ordered `g6lc64_ooo_int` smoke; PMU shows no FLU freeze on CSR |
| T3 | token kill; frozen failing layout repaired; independent observer; `G6LC_NO_KILL_PERSIST` retired |
| T4 | non-compacting IQ; same directed results; FO4 delta recorded |
| T5 | FP guard removed for `NrHarts==1` only |
| T6 | both harts perform checked work concurrently; drained handoff retired only after peer-isolation negatives |

Standing gates for every tranche: `verify --lint --synth --remote`, leaf audit cells with
negatives and mutations, protected SMT2 anchor unchanged, traceability records updated,
licensing tier check on every code edit.
