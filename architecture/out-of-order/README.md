# Extension point: out-of-order execution (config-gated backend)

Program: `../router-core-upgrade-program.md` (U4 / U5).

**Status: config-gated implementation; full architectural qualification blocked.**
`OoOEn=1` routes the live dispatch/IQ/rename/LSQ/PRF path, but routing and component
passes do not establish a shipping backend. The accepted-store self-blocking defect
from the 2026-09-16 review has a directed repair; it is not the current unresolved
failure. Minimal/default packages keep `OoOEn=0`. Passing SMT2 and stream8 regressions
exercise that protected in-order path, not full OoO. The successful source-built
SMT2 OpenSBI/HSM profile likewise uses OoOEn=0 and drained context switches.

## Stability reassessment — current scope and priority

This section overrides conflicting conclusions in the historical investigation below. It records
source review and read-only metadata captures, not newly qualified RTL.

**Resolved by single-axis experiment: the PMP stop is a compiler-control artifact.** Two models were
built from ONE unmodified worktree source state, differing only in the presence of the pinned
`split-counter.vlt` control (`SOFT_LADDER_BUILD_VLT_ARGS`), then soaked serially on the frozen
`fw_payload.elf` (`6b2bad99...`):

| Arm | Model | Control in verFiles | Result |
|---|---|---|---|
| ctl | `480ceed1...` | present (2 refs) | runner `outcome: pass`, `strictDualPassed: true`, 12,765,628 cycles; hart0=333635, hart1=8932406 |
| noctl | `70da7cac...` | absent | runner `outcome: error`, rc=255, `pmp_entry.sv:81` assertion at cycle 12,731,487 |

**ESTABLISHED by an 8-run repeatability matrix (5 ctl + 3 noctl), serial, idle builder, runner pinned
to `ad4561bf...`, references unset so a verdict is always emitted.** Tags `s0-repeat-ctl-r1..r5` and
`s0-repeat-noctl-r1..r3`:

- ctl 5/5: `outcome: pass`, `strictDualPassed: true`, rc=0, stop cycle 12,765,628 and retirements
  333,635 / 8,932,406 IDENTICAL in every run; `OpenSBI v1.5` banner present; wall 752-782 s.
- noctl 3/3: `outcome: error`, rc=255, `pmp_entry.sv:81` in `i_ptw.i_pmp_ptw.gen_pmp.genblk1[1]`
  at cycle 12,731,487, `elapsedVerdicts: []`, `retiredByHart: {}`; banner also present, so the arm
  dies ~34k cycles short of the pass point, far past boot; wall 1209-1231 s.

Zero overlap across 8 runs with one varied axis. The compiler-control attribution is established, and
the protected anchor is now runner-CERTIFIED for the ctl arm, not merely a raw log reading.

**A retraction of a retraction — the trap to remember.** An intermediate pass claimed arm ctl "never
passed, it hung", reasoning that `*** SUCCESS *** (tohost = 0)` plus a preceding
`[trapdump]`/`[fdtmem]`/`[walk]`/`[hangpc] ... wfi0=1` dump was a hang-exit banner, since a real HTIF
pass writes nonzero `tohost`. The matrix refutes that: those markers and that exact banner appear in
ALL FIVE runner-certified passes. They are unconditional end-of-sim diagnostic dumps in this
testharness, NOT hang discriminators, and this harness prints `tohost = 0` on success. The original
evidence — the three strict stores confirmed in-trace — was correct. Lesson: an unfamiliar diagnostic
marker is not evidence of the condition it superficially names; establish what a marker means on a
KNOWN-GOOD run before using its presence to overturn a result. Over-correcting on a plausible-sounding
log reading cost as much as the original optimism would have.

What survives from that pass, because the matrix confirms it independently: read verdicts from the
runner's `outcome`/`strictDualPassed`/`retiredByHart`, never from simulator stdout. The discriminator
for the genuine outlier below is the ABSENCE of the `rvfi_tracer ... Simulation terminated` line plus
absent tohost/`strict_seen` stores — not the presence of the dump markers.

**Early termination remains unowned; do not report a flake probability.** Retained run
`s0-recipe-ctl-certified-v1` was incomplete at 1,531,692 cycles. The later `s0-cert-ctl-r6`
was incomplete at 3,573,269 cycles, with 325,956/2,109,370 retirements and no tracer-termination
marker. Its 4,870,657 trace lines match the passing replay prefix exactly. This is early
termination, not demonstrated architectural divergence. Model/firmware hashes and log prefixes do
not prove identity of all external inputs or process-control events. Neither a population failure
rate nor intrinsic simulator nondeterminism is established by these observations.

Source review found a concrete process-control hazard: proxy run/soak/di/shell preflight invoked a
global harness pkill; even a shell query merely mentioning the binary name took that path.
`g6lc_tb.cpp` handles SIGTERM by calling `dtm->stop()`, and its banner prints the exit code rather
than raw tohost memory. The automatic kill calls have been removed with regression tests, while
overlap refusal is retained. This supplies a plausible external-stop mechanism, not proof of the
sender or cause in either historical run. Keep both incomplete results as nonpassing evidence.

Matching historical cycle/retirement counts is a non-regression observation; it does not measure
whether kill-persistence logic activated. Positive recovery evidence still requires S1's independent
observer and collision cases. No activation count was established by the anchor comparison.

**Reference divergence explained: the retained reference is stale and architecturally wrong.** Both
arms diverge identically from the amo-ready reference at line 18,500,377. Decoding the retirement
settles it without further simulation: pc `0x80008662` holds insn `0x1607b52f` = opcode `0101111`
(AMO), funct5 `00010` (LR), funct3 `011` (doubleword), rs2=x0, rd=x10 — `lr.d.aqrl x10,(x15)`. An LR
reads memory and registers a reservation; it performs NO write. The reference's
`mem 0x80046088 0x0` is the two-value `mem_wmask` form, i.e. a phantom store of zero to the
reservation address. The current traces correctly omit it, because `core/cva6_rvfi.sv` now clears
`lsu_wmask` for `AMO_LRW`/`AMO_LRD` (LR is dispatched down the STORE path like every other atomic).
The divergence is at the FIRST LR retirement in the trace, exactly as that repair's comment predicts.

So the delta is an intended correctness improvement in the instrument, and the retained
`opensbi-amo-ready-dual-20260919` trace predates it. Retiring that reference and re-baselining is now
justified ON THAT RECORDED GROUND — not as a way to turn the check green. Re-baseline from a
current-source model and record the new reference's identity; do not compare a model against its own
trace and call it an independent check. The failed-SC `mem_wmask` suppression in the same repair is a
separate clause and is NOT exercised by this observation.

The retained r1 replacement is a same-model replay baseline, not an independent ISA oracle:
`/opt/testharness/runs/opensbi-dual-ref-s0-repeat-ctl-r1/output/trial/trace_rvfi_hart_00.dasm`,
SHA256 `260456169c8c847005ffcd5d3a18c20ba096cf7e17f2a4fdc846b5805669a2ea`.
A different invocation of the same implementation does not make a reference independent.
Further RVFI work remains: `lsu_rmask` currently recognizes LOAD only, while LR uses STORE;
removing the phantom write therefore does not establish complete LR read/address visibility.
The mem_paddr ownership and failed-SC clauses need their own checked cases before architectural
memory-trace qualification. Do not silently bless the replacement as a complete memory oracle.

**A missing build input, not a matched source-only bisect.** Proxy inspection of the actual generated
Verilator command shows passing anchor `f35d0e10...` uses
`/opt/testharness/runs/pmp-transition-split-20260919/output/source/split-counter.vlt`, whereas failing
truezero model `145c8d74...` does not. Captures are
`stability-reassessment-work-ver-smt2-loadcancel-v2-recipe-v1/audit.json` and
`stability-reassessment-work-ver-smt2-truezero-v1-recipe-v1/audit.json` under the C: artifact root.
The firmware hash and corrected runtime match. This external input was absent from the 689-file
source comparison. AGENTS.md already records the lzc packed-array scheduling issue and qualified
split_var control; the plan pins its hash. Missing that control is the leading explanation of the
repeated PMP stop. It is not yet a successful current-source rebuild/boot, nor proof of general
frontend correctness. Stop reverting unrelated sources to explain an unmatched build recipe.

PMP line81 asserts consistency of `size=trail_ones+3` with the input used to count those ones. It
does not establish malformed firmware PMP configuration. Preserve PMP logic and assertions;
reuse the existing transition/reference/mutation fixture and inspect compiler scheduling first.
Repeatability does not eliminate deterministic compiler defects. `translate_off` is a synthesis
boundary, not a promise that observers disappear from simulation or cannot perturb generated code.

**Current recovery candidate needs a broader contract.** The frontend's kill_owed state is cleared
on a replacement request and matched only by VA. The I$ supports response/new-request overlap;
FDIP, same-address refetch and hart/context changes require accepted-request ownership, not address
equality alone. The current report-only probe observes that same DUT state and cannot independently
catch its loss. Frozen-ELF before/after evidence supports the local symptom repair, not these other
lifetime cases. Prove an ordered single-outstanding interface or retain sufficient identity before
selecting a final repair; add no unbounded hold or address-based exception list.

**Do not reinstate the reverted assertion qualification.** For RV64's three-bit load offset, the
word-aligned values0/4 are necessarily <5 and the half-aligned values0/2/4/6 necessarily <7. The
old antecedent edit made the checks tautological while retaining their fatal messages. Current
load_unit has the original assertions. Replacement must check precise exception/kill and prohibit
erroneous normal completion with independent fault controls, including configured TvalEn behavior.

Other historical claims are too strong: a flush port does not prove cancellation reached every
owner; the displayed npc is npc_d, and with FtqDepth=8 an active exception legitimately selects
next_block(mtvec); a one-cycle warm I$ hit is supported, so3/8-cycle timing does not prove provenance.
Stage34 changes more than one target (handler contents and layout also differ). An OoO-off failure
establishes that OoO is not necessary for that case, not that all backend interactions are cleared.

**Ordered large passes:** S0 complete/pinned recipe and trustworthy gates; S1 precise frontend/I$/LSU
recovery and independent checkers; S2 backend all-FU/pending-store lifetimes and memory effects;
S3 two-hart drained-handoff context/trap/FP stability; S4 final-source reference/firmware/structural
qualification. S5 mixed residency follows those gates, before adaptive resource policy. The active
plan contains the inferred change surfaces and measurable exits. Existing pre-grant load-cancellation,
IQ acceptance, store-ordering and late-result controls remain regression assets, not universal
proofs. Full firmware, strict slang and physical qualification remain open. No active fetch_A or
smt_legacy input, issue-width reduction, firmware accommodation or guard promotion is authorized.

## Investigation history

The dated investigation record (exception redirect and offset assertion, pre-grant cancellation,
memory-ordering repairs, FP lifetime, two-issue recovery, rename recovery, broad RTL review,
combinational-loop evidence) is preserved verbatim in [`log-2026-09.md`](log-2026-09.md).
The active architecture contract is `core/ooo/AGENTS-ooo-contract.md`; the step plan is
`core/ooo/AGENTS-ooo-plan.md`.

## Pipeline (OoOEn=1)

```
decode → scoreboard (in-order alloc + commit)
              │
              ▼
     g6lc_ooo_dispatch
        multi-port rename (g6lc_rename)  ── freelist 32+ pool
        free+busy+map ckpt (recovery contract open)
        age-ordered IQ + writeback-qualified wakeup + multi-grant
        ROB multi-WB complete (by trans_id)
        LSQ multi-alloc + live AGU + CAM/STL + memdep
        PRF write-through + WB bypass → IRO operands
        mispredict: SB cancelled_mask → squash younger IQ/ROB/LSQ + gate PRF WB
              │
              ▼
     issue_read_operands  (PRF cutover when ooo_renamed)
              │
              ▼
            EX → WB → commit
```

**OoOEn=0:** identity (no dispatch module). **SliceOoOEn ⊕ OoOEn.**

Rename BMC (`g6lc_ooo_rename.sby`) is in `verify.formalTasks`. Cover
(`g6lc_ooo_rename_cover.sby`) is local yices only: testharness z3 timed
out 90 s with zero traces (`rename-cover-z3-2`). Do not mix this lane
with L2 RR or SMT2 pairing.

## Intended mechanisms and component work

The table records mechanisms present or intended in the source. The integration
blockers below supersede any implied claim of verified end-to-end precision.

| Bottleneck | Mitigation |
|------------|------------|
| Rename WAW/WAR multi-issue | Single-cycle multi-port rename; later ports see earlier allocs |
| Mispredict recovery | Precise map+free+busy checkpoint; **SB cancel mask** squashes younger IQ/ROB/LSQ; PRF WB gated |
| Wakeup latency | Busy-table clear on WB + IQ tag wakeup same cycle |
| Operand availability | IQ readiness now waits for actual WB; speculative producer-selection wakeup was unsafe and removed |
| PRF read latency | Write-through PRF + same-cycle **WB bypass** into issue operands |
| Issue width | IQ grants up to `NrIssuePorts` oldest-ready; mem_stall only blocks LD/ST |
| Mem dependence | Store-set predictor + LSQ CAM; stall only unknown/match-no-data |
| STL | Live AGU (`imm+rs1`) + store data at issue; youngest match forwards into load op A |
| LSQ capacity | Full `LsqLoad/StoreEntries` (no hard-8 cap); multi-port alloc |
| ROB complete | Multi-WB complete by scoreboard `trans_id` |
| Arch RAW stalls | IRO skips scoreboard RAW stall when `ooo_renamed` |
| Dual/multi commit free | Commit ports free old phys regs |
| Observability | PMU group 1 events 0–7 (rename/IQ/ROB/LSQ/STL); phys tags on `scoreboard_entry_t` |

## Modules (`core/ooo/`)

| File | Role |
|------|------|
| `g6lc_rename.sv` | Multi-port RAT + free pool + busy + full-state branch ckpt (any port) |
| `g6lc_iq.sv` | Compacting IQ, chain wakeup, multi-grant ready select + cancel squash |
| `g6lc_rob.sv` | ROB with multi-WB complete-by-tid + cancel complete |
| `g6lc_lsq.sv` | Multi-alloc LSQ + live addr CAM + STL + cancel drop |
| `g6lc_memdep.sv` | Store-set |
| `g6lc_prf.sv` | Multi-port PRF with write-through |
| `g6lc_ooo_dispatch.sv` | Glue + AGU + PRF operand outs + PMU probes |

`scoreboard_entry_t` carries `p_rs1/p_rs2/p_rd/ooo_renamed` (zero when off). RVFI/commit sees tags via the SBE.

## Configured profiles (not release evidence)

| Package | Role |
|---------|------|
| `g6lc64_ooo_server_config_pkg.sv` | **Configured server**: 4-issue, 4c×2h, L2/L3 auto, `DeepSpecEn`, `MemDepPredEn` |
| `g6lc64_ooo_config_pkg.sv` | **Configured dual-issue lite**: 2-issue OoO + DeepSpec (bring-up / area-lean) |
| `g6lc64_ooo_int2_l3_config_pkg.sv` | **Configured int2 L3**: 2c×2h drained, ring 8 (M1d geometry; the T9f/M3 ring-32/TAGE/FTQ window was measured and **not adopted** — ablation in T9f) |
| `g6lc64_smt2_ooo_int_config_pkg.sv` | **Configured SMT2 int**: 1c×2h mixed residency, same ring-8 geometry (M3 window likewise not adopted) |
| Default `cv64a6_imafdc_sv39` etc. | `OoOEn=0` identity (still production in-order) |

The M3 uplift (ring 32, TAGE_LITE, FTQ/FDIP/loop buffer, DeepSpec/LSQ growth)
was qualified functionally but regressed strict-boot and branch-bound IPC
(+21.7 % / +28.9 % / +36.7 %) and is **not** configured: the per-knob
ablation found every uplifted knob regresses the strict four-hart boot
independently (ring > 8 alone times out at the 24 M cap; TAGE_LITE
multiplies boot mispredicts ~4.75×; DeepSpec/memdep replays dominate;
FTQ/FDIP taxes every control transfer), so both packages stay at ring 8
pending the M3b re-evaluation documented in
`../../core/ooo/AGENTS-ooo-plan.md` T9f. What remains landed from M3 is the
frontend switch-safety fix: `smt_restore_i` reseeds the FTQ to the restore PC
**and steps the cursor** (`arch_step=FtqEn`, else the window double-fetches)
and clears the loop buffer; proven by
`core/fetch_B/formal/g6lc_fetch_restore.sby` (bmc 16) and the
`tb_g6lc_fetch_restore` directed leaf (`NOFLUSH` mutant detected). If
FTQ/FDIP/loop buffer are ever enabled on a two-hart package, that evidence is
the gate.

ROB/IQ/LSQ/PRF depths 0 → scaled from issue width in `build_config_pkg`.

## Tests

| Suite | Path |
|-------|------|
| Directed list | `verif/tests/testlist_ooo_l3.yaml` |
| Regress | `verif/regress/ooo-l3-tests.{sh,ps1}` (`DV_TARGET=g6lc64_ooo_server`) |
| ILP / rename | `verif/tests/custom/ooo/ooo_ilp_chain.S` |
| Memdep / STL | `verif/tests/custom/ooo/ooo_mem_dep.S` |
| L2/L3 stream | `verif/tests/custom/l3/l3_stride_stream.S` |

`build-platform` suite id: **`ooo-l3-tests` (optional / lengthy)** — not in
default `verify.targets` or `defaultSuites` (runtime cost, not maturity).

```
cva6-build test --suite ooo-l3-tests
cva6-build verify --target g6lc64_ooo_server
cva6-build verify --target g6lc64_ooo
```

## PMU group 1 (`mhpmevent[7:5]==1`)

| Idx | Event |
|-----|-------|
| 0 | SB full \| rename stall \| ROB full |
| 1 | Issue stall \| IQ full |
| 2 | Branch mispredict |
| 3 | Load commit |
| 4 | Store commit |
| 5 | LSQ / memdep / STL stall |
| 6 | STL forward hit |
| 7 | Rename/freelist stall alone |

## Formal (optional CI)

| Artifact | Role |
|----------|------|
| `core/ooo/formal/g6lc_ooo_freelist_props.sv` | freelist/busy mutex + index bounds |
| `core/ooo/formal/g6lc_ooo_rob_props.sv` | ROB count/head/tail bounds |

## Related

- Recovery ordering: [`recovery-timeline.md`](recovery-timeline.md)
- FSE depth plane: `architecture/speculative-execution/` (`DeepSpecEn`, STQ, PMU g3)
- Slice MLP (U4): still off by default; mutually exclusive with U5
