# AGENTS workflow todo / pending-log

Live tracker for agent work. **Retrieval contract:** every open item below cites the architecture /
progress files that hold its priors (why it exists, seams, acceptance). Open those first; this file
is the queue, not the design.

| Layer | Open first | Role |
|-------|------------|------|
| Prime directive / nav | [`AGENTS.md`](AGENTS.md) · [`agents/spec/INDEX.md`](agents/spec/INDEX.md) | Spec→code map, SoC §0, standing disciplines |
| Programs of record | [`architecture/README.md`](architecture/README.md) · [`architecture/router-core-upgrade-program.md`](architecture/router-core-upgrade-program.md) · [`architecture/remaining-upgrade-sequence.md`](architecture/remaining-upgrade-sequence.md) | U1–U10 plan, live next, scaffold contract |
| Spec ⇄ RTL / tests | [`AGENTS-specs-to-impl.md`](AGENTS-specs-to-impl.md) · [`AGENTS-specs-to-tests.md`](AGENTS-specs-to-tests.md) · [`AGENTS-specs-coverage.md`](AGENTS-specs-coverage.md) | Status vocabulary + suite/testlist rows |
| Host / verify | [`AGENTS-build-platform.md`](AGENTS-build-platform.md) · [`AGENTS-build.md`](AGENTS-build.md) · [`build-platform/AGENTS.md`](build-platform/AGENTS.md) | CLI, residual soaks, probe→verify |
| Philosophy / SoC envelope | [`AGENTS-coding-philosophy.md`](AGENTS-coding-philosophy.md) · [`AGENTS-configuration.md`](AGENTS-configuration.md) · [`agents/guides/AGENTS-soc-readiness.md`](agents/guides/AGENTS-soc-readiness.md) | Timing, verify-in-lockstep, target SoC |

## Contract-first continuation (2026-09-21) — authoritative over the block below

The OoO/SMT2 work now follows `core/ooo/AGENTS-ooo-contract.md` and `core/ooo/AGENTS-ooo-plan.md`
(tranches T0–T6: archive/checkpoint; age namespace + memory-order validation; CSR FIFO + store
reservation + dispatch-time memdep; fetch token kill; non-compacting IQ; single-hart FP SKU;
per-hart ROB partition). The investigation history moved verbatim to
`architecture/out-of-order/log-2026-09.md`. Items below remain valid evidence and residuals; their
next actions are superseded by the tranche exits.

- [x] T0: history archived (6,292 lines, round-trip byte-identical), contract + plan written,
  `AGENTS.md` §2 row added.
- [x] T0: checkpoint commit `48c729e51` (71 files, no push).
- [x] T1: age key + LSQ alias validation + commit replay; exit met (see contract). Formal
  correction: `g6lc_ooo_rob.sby` had proved zero assertions; fixed with `-DFORMAL`, `dist_w`,
  flattening and abc bmc3.
- [x] Attributed the uniform +3 cycles on integer-OoO ELFs (`bis-*-v1`, seven isolated builds):
  not the frontend, not mult/fpu_wrap/ex_stage; it is the OoO issue-side closure of `48c729e51`
  (`g6lc_iq`/`g6lc_ooo_dispatch`/`g6lc_rename`/issue/id). First divergence at the exit epilogue
  `csrw mstatus`: the CSR-at-commit-head issue rule lets younger ALU ops issue first, delaying the
  flush-causing CSR by two cycles plus one refetch. That rule is the 09-20 repair for an
  uncommitted CSR wedging the whole FLU; the cycles are its price and T2's per-tid CSR table is
  the mechanism that removes both the wedge and the wait. Also found: pure parent `e64864263`
  FAILS stage 4 at 894 cycles (x15 wrong); the 09-19/20 doc baselines were measured on the
  pre-commit worktree, so "878/1109" is the pre-head-rule worktree, not a committed state.
- [x] T2: per-tid CSR table out of `flu_ready`, LSQ store entry as spec-slot reservation (stores
  issue OoO), loads wait only on unresolved older stores, dispatch-time memdep bypass with replay
  safety net; exit met (contract table). Stage 35 shows replay end-to-end. Dispatch scenario 18
  remains the open leaf finding (identical at T1 HEAD).
- [x] T3: fetch kill by request token (ledger proof + mutation), precise-misalignment properties
  (stages 32/33/34 now pass), `G6LC_NO_KILL_PERSIST` retired; exit met (contract table).
- [x] Pre-existing fetch proof failures found by T3 closed on the property side after reading the
  counterexamples (hold: port stimulus, SMT ports under an explicit selector contract, I8 supersede
  exemption, `redirect_accept` release leg + pend-kept assert; IQ: payloads agree on CF class).
- [ ] **Selector obligation (S3/T6):** the thread selector must never restore a hart while the
  frontend has a pending redirect (`redirect_pend_q`); the RTL exports only the trap case as
  `smt_trap_hold_o`. Prove it on `g6lc_thread_select` or widen the hold export; until then the hold
  proof assumes it (`g6lc_fetch_hold_props.sv`).
- [x] T4: stationary IQ with age matrix; all fixtures and ten frozen ELFs cycle-identical; FO4
  payload path 23.97 → 14.97.
- [x] T4b: cascaded oldest-first grant; select cone 27.0 → 16.0 (IQ module max 16.0); rank kept as
  the sim-only reference assert; fixtures/firmware cycle-identical.
- [ ] IQ cover task (`g6lc_fetch_iq.sby cover`) still times out under z3; `g6lc_ooo_dispatch` at
  30.0 adj FO4 is the OoO slice's worst cone (budget 32) — next timing owner after T5.
- [x] **Fetch (FtqDepth != 0 only): instruction-queue replay did not flush the FTQ/FDIP** → stale
  sequential entries served ahead of the refused window → one window skipped (OoO) or livelock
  (in order). Found by `ooo_fp_cancel_head_reuse` / `ooo_fetch_head_reuse_int`; fixed in
  `frontend.sv` (replay is a reseed like bp_fire). Protected `g6lc64_smt2` has FtqDepth=0 and was
  never exposed; anchor exact after the fix.
- [ ] **Residual fetch loss:** `ooo_fetch_head_reuse_int` still loses a whole two-window block in
  2–4 of 128 iterations on FtqDepth=4 (OoO and in order). Needs a VCD at the loss; same class.
- [ ] T5 (partial): FP suite green on the qualification build; owner-retention mutation inert at
  core level (structural: 32 SB entries, drop at head) — decide the bar; guard stays until then.
- [ ] Confirm the smt2 anchor model's boot-vector replay on a single-hart directed ELF is hart 1's
  boot (dual-hart model artifact), not a redirect fault.
- [ ] T6 per the plan file.

## Active stability-first review — authoritative next change sets

This block supersedes conflicting causal conclusions, completed-checkbox claims and next actions
in the historical investigation below. Preserve its raw run results; do not reuse its latest
narrative as proof. Detailed contracts, files, dependency order and exit gates are in the active
plan `C:/Users/etcim/.devin/plans/plan-ea69493e7a14829a.md`, section
"Stability-first reassessment", and `architecture/out-of-order/README.md`.

- [x] Read the complete coding/runtime-learning philosophies, all three reasoning guides and
  complete plan, plus the relevant SPEC/VALUES/NEGATIVE/SMT-LEGACY/firmware references.
  Historical fetch_A/smt_legacy never become active build inputs; shared support is core/smt.
- [x] Locate a missing anchor-comparison input using read-only proxy metadata inspection, not
  another soak. Passing model f35d0e10... has split-counter.vlt in its generated Verilator
  command; failing truezero145c8d74... does not. Evidence:
  `stability-reassessment-work-ver-smt2-{loadcancel-v2,truezero-v1}-recipe-v1/audit.json` under
  the configured C: artifact root. Both inspected firmware hashes and corrected runtime agree.
  The control is already documented in AGENTS.md and the plan's frozen-anchor section.
- [x] Reopen unsupported elimination claims: deterministic failures do not exclude a deterministic
  tool/scheduling defect; synthesis translate_off does not remove simulation assertions;
  same VA is not request identity; three-vs-eight cycles is not a cache latency bound;
  a wired flush is not an end-to-end proof; OoO-off failure is not general backend exoneration.
  With FtqDepth=8, npc_d=next_block(mtvec) is compatible with an active exception redirect.
- [x] Audit the reverted alignment-qualified checker: RV64 offsets with low two bits zero are
  0/4 (always <5); even offsets are 0/2/4/6 (always <7). Those weakened antecedents cannot
  detect the claimed error. The current source has the original fatal assertions restored.
- [x] **S0 attribution settled by single-axis experiment.** Two builds from ONE unmodified source
  state, differing only in the pinned `split-counter.vlt` (`SOFT_LADDER_BUILD_VLT_ARGS`), soaked
  serially on frozen `fw_payload.elf` `6b2bad99...`: control-present `480ceed1...` reports
  `SUCCESS (tohost=0) after 12765628 cycles` with hart0=333635/hart1=8932406 (exactly the historical
  anchor); control-absent `70da7cac...` stops at `pmp_entry.sv:81` cycle 12731487. The recurring stop
  is the omitted qualified lzc split_var control, not session RTL. No PMP/assertion/vendor/waiver
  edit; control stays opt-in. Artifacts `s0-recipe-{ctl,noctl}-v1`. Every attribution from the
  earlier recipe-mismatched builds — including the frontend-source bisect — is retroactively void.
- [x] **S0 residual (a): reference divergence explained; the retained reference is stale.** pc
  `0x80008662` holds `0x1607b52f` = `lr.d.aqrl x10,(x15)` (AMO opcode, funct5 `00010`=LR, funct3
  `011`). An LR performs no memory write, so the reference's two-value `mem 0x80046088 0x0` is a
  phantom store; current traces correctly omit it because `cva6_rvfi.sv` clears `lsu_wmask` for
  `AMO_LRW`/`AMO_LRD`. Divergence lands on the FIRST LR retirement, as that repair's comment predicts.
  The `opensbi-amo-ready-dual-20260919` reference predates the repair and must be retired.
- [x] **S0 residual (c): repeatability measured; compiler-control attribution ESTABLISHED.** 8-run
  matrix, serial, idle builder, runner pinned `ad4561bf...`, references unset. ctl 5/5
  `outcome: pass` + `strictDualPassed: true` at 12,765,628 (333,635/8,932,406 identical every run);
  noctl 3/3 `outcome: error` rc=255 at `pmp_entry.sv:81` @ 12,731,487. Zero overlap, one varied axis.
  The anchor is now runner-certified for the ctl arm. Tags `s0-repeat-{ctl-r1..r5,noctl-r1..r3}`.
  NOTE — retraction of a retraction: `*** SUCCESS *** (tohost = 0)` and the
  `[trapdump]`/`[walk]`/`[hangpc]` markers appear in all five CERTIFIED PASSES; they are unconditional
  end-of-sim dumps, not hang indicators, and this harness prints `tohost = 0` on success. Calibrate a
  marker on a known-good run before reading meaning into it. Still true: take verdicts from the
  runner's `outcome`, not stdout.
- [ ] **S0 early termination:** preserve both incomplete runs (1,531,692 and 3,573,269 cycles).
  The latter matches 4,870,657 lines of the passing trace prefix; no architectural divergence or
  population flake rate follows. Automatic proxy pkill calls are removed with regression tests,
  but historical signal sender/cause is unproven. Keep incomplete as nonpass, not retry-to-green.
- [x] **S0 runner-certified observations and replay baseline:** five controlled runs emitted pass
  and strictDualPassed; the retained r1 trace is pinned as a same-model replay baseline only.
  Different invocations are not independent architecture checks. Old reference remains retained.
- [x] **S0 remote runner validation:** exact-path/compiler-hash preflight refusal verified on
  target (`s0-refuse-ctl-v2` refused before launch, simulationStarted=false, no trial dir);
  streamed strict-store/reference-prefix checks (`s0-cert-safe-par-v1` pass, 18,532,093 lines);
  structured mismatch results kept pass/incomplete/error distinct; pre-launch invocation captured.
- [ ] **S0 build-time recipe attestation:** fresh build manifests must record the generated
  command/dependency recipe; the pinned `s0-recipe-ctl-v1` manifest predates attestation and stays
  explicitly labelled (`buildRecipeAttested: false`). This residual is not closed.
- [ ] **S0/S2 RVFI memory contract:** LR write suppression is correct, but LOAD-only lsu_rmask
  leaves LR read/address visibility unqualified. Check LR/SC/AMO masks, addresses and committed
  ownership independently before promoting any retirement reference to an architectural oracle.
- [x] **Remote resource execution policy:** capacity measured; up to 12 aggregate compiler jobs,
  three isolated -j4 leaf lanes, separate multi-script outputs, and non-destructive overlap refusal.
  Preserve pinned simulation threading and all S1–S5/deferred gates.

Parallel baseline evidence (2026-09-21): 18 isolated jobs ran with at most three concurrent lanes.
`s0-cert-safe-par-v1` completed strict dual-hart work at 12,765,628 cycles (333,635/8,932,406
retirements), and all 18,532,093 reference lines matched; the reference is same-model replay only.
`s0-refuse-ctl-v2` emitted refused/simulationStarted=false without a trial directory. Captured-log
checker regression retained one pass, two incomplete and one error outcome rather than masking them.
The old model manifest explicitly lacks build-time recipe attestation; that S0 residual is not closed.

WB-owner, drop, LSQ, rename, FP/hart rename, pending-store, WFI and fetch-queue leaf baselines passed
their existing positive/negative contracts. Dispatch scenario18 exposed an ID-reuse stale-value
failure at the leaf; real FU lifetime reachability still needs checking. CSR late-result scenarios
had a stale fixture commit head (cp0 versus producer1), and drain synthesis had a stale wrapper
missing pause_hint_i. Eight scoped follow-up jobs completed under the same three-lane budget:
`s23-par-dispatch-v2` (28 matched), `s23-par-lateresult-v2` (14 matched), its restored-defect
mutation (one detected), and `s23-par-latewake-v2` (four matched) pass their fixture contracts.
`s3-par-drain-v2` matched all 16 simulation controls; live-port synthesis has 250 cells, no latches
and zero SCCs. PMP simulation, decoder mutation and 32/56-bit proof checks also matched. The runtime
path was resolved literally from the pinned runtime JSON; its privateRoot is the non-rebuild path,
so the reported v1 path deviation was not real. No S1–S5 architectural closure or promotion follows.
Historical incomplete runs and the TID-reuse failure stay open.
- [ ] **S1: precise frontend/I$/LSU recovery as one contract pass.** Replace address-only killed-
  response reasoning with accepted-request lifetime and independently checked completion/kill
  ownership. Cover response/new request/kill overlap, same-VA refetch, multiple kills, miss/PTW,
  prefetch/loop supply, hart switch, replay and split targets. Keep frozen layout failures and
  validate observer non-interference. The current kill_drop patch is a local candidate, not closed.
- [ ] **S1 assertion/test obligation: do NOT reapply the old aligned-offset antecedent patch.**
  Check precise misalignment cause/PC/configured tval, no destination or forbidden device effect,
  and no trap from cancelled work. Fault-inject missing exception/kill and bad completion to prove
  detection. Stage32-34 historical passes used a different model/checker; current qualification
  is open. Make TvalEn expectations explicit (g6lc64_ooo_int sets it to1), and make layout variants
  reproducible rather than claiming stage34 changes only one branch-target co-factor.
- [x] **S2 FP result ownership after ID reuse (boundary-level).** Real `fpu_wrap`+`controller`+
  `scoreboard` fixture reproduced a cancelled FDIV result landing on a reused slot at8 and16
  entries (`s2-fp-lifetime-s{8,16}-beh-v1`);32 entries drained before reuse. `fpu_wrap.sv` now owns
  each live token until the raw result drains, treats cancel/flush as sticky cancellation, holds
  same-ID replacements and suppresses cancelled results; `ex_stage.sv` forwards the mask.
  `s2-fp-owner-{s8,s16,s32,inorder-s8}-v1` all matched; `s2-fp-owner-mut-s8-v1` detects the restored
  defect. Strict `-Werror-UNOPTFLAT` build (`s2-fp-owner-strict-s32-v1`) stays blocked by existing
  scoreboard/FPnew loops: OPEN structural gate, not waived. Full-core FP+OoO remains unqualified.
  Structural gate `s2-fp-owner-verify-v1`: remote lint PASS (cv64a6_imafdc_sv39 8/8, cv32a65x 54/54
  versus the gate's own remote baselines) and synth PASS (32/5 warnings); no warning names the new
  logic. Strict standalone slang elaboration SKIPPED on the builder (gate rc4, not accepted with
  --allow-skips). `s23-par-rename-fp-h2-v2` 4/4 matched, no leaf drift.
- [x] **S2 divider result ownership after ID reuse (boundary-level).** Same fixture with the real
  `mult`/`serdiv` path reproduced a cancelled DIVU result on a reused slot at8/16 entries
  (`s2-div-lifetime-s{8,16}-v1`, return cycle28 versus reuse13/21). `mult.sv` now keeps a per-slot
  divider owner table (`div_idle_q` shadows serdiv acceptance because `in_rdy_o` is low in the
  accepting cycle), refuses a divide whose ID is live or cancelled, and suppresses cancelled results
  before the FLU mux; the single-cycle multiplier needs no table. Correction recorded: FPnew and
  serdiv DISCARD in-flight tokens on full flush (FFLARNC clears, serdiv flush→IDLE), so ownership
  must clear on flush; a sticky-until-drain rule would deadlock the next same-ID producer. Scenario5
  (full flush then same-ID replacement) is the discriminator and passes in `s2-{fp,div}-owner-*-v2/v4`;
  both retention mutations reproduce the stale completion. Boundary caveat: the fixture now waits for
  `ready` before a same-ID replacement, matching the issue stage's flu_ready hold, so a request pulsed
  into a busy divider is not exercised. Gate `s2-owner-verify-v2`: lint8/54, synth32/5, no new
  warnings; strict slang still skipped on the builder. Full-core MULT/FP+OoO remain unqualified.
- [ ] **S2 dispatch-leaf scenario18:** the leaf still accepts an ID-only late result for a new owner.
  FP and divider now retain ownership at their producers; remaining producers to prove or protect:
  LSU post-grant tombstones (retained), pending stores, CSR/AMO commit path, CVXIF and accelerator
  writebacks. The leaf contract closes either when every producer is shown to retain ownership or
  when owner identity is carried to dispatch. Do not weaken the scenario.
- [ ] **S2: finish all-FU and pending-store lifetime ownership.** Enumerate every pre/post-accept
  owner through cancellation and TID reuse, including divider/multiplier/FPU, commit-produced
  CSR/AMO values and committed stores. Preserve pre-grant LSU cancellation evidence; extend
  independent/mutation tests for byte/age forwarding, capacity, paired commit, fences/MMIO and
  constrained LR/SC. Keep legal unconstrained SC divergence separately self-checking.
- [ ] **S3: finish two-hart drained-handoff correctness.** Test both roles and owner namespaces,
  CSR/MMU/SATP/ASID/PMP context, WFI/IPI/HSM, precise traps, FP f0/rs3/frm/fflags and memory
  publication. Do not remove drain or infer mixed residency. Use per-hart reference order plus
  allowed shared-memory outcomes; negative controls must catch peer corruption/lost wakeup.
- [ ] **S4: final-source integrated qualification.** Target-correct integer/FP/dual-hart tests,
  protected in-order boot, experimental OoO firmware, independent reference, formal/cover,
  enabled whole-core lint/elaboration/synthesis, then separate physical/DFT gates. Default
  cv32/cv64 smoke does not qualify OoO/SMT2; standalone slang remains an explicit open gate.
- [ ] **S1/S4: independent kill checker and seam retirement.** A checker reading DUT kill_owed
  cannot independently prove retained cancellation. Gate only a validated independent contract;
  retain restored-defect mutations, then remove temporary G6LC_NO_KILL_PERSIST infrastructure.
- [ ] **S5 deferred until coarse stability:** mixed-resident per-hart retirement/recovery/context
  and resource ownership, then scheduler/fetch/issue policy measurements. No guard/default promotion.
- [ ] Carry forward conditional FP widths, CASQ, PMU residuals, predictor/checkpoint arbitration,
  coherence/invalidation/hierarchy/snoop obligations, Linux/compliance/liveness, STA/DFT/power
  and joint useful-work performance qualification. These are not closed by S0-S4 or omitted.

No RTL, firmware, configuration default or verification policy is changed by this review.

## Historical investigation — pre-grant cancellation and subsequent probes (2026-09-20)

This block supersedes conflicting closure/attribution below; earlier runs remain
historical evidence, not results for subsequently changed RTL.

- [x] Read the complete coding/runtime-learning philosophies, SMT2 reasoning trio,
  full plan and applicable retired-fetch references. Keep fetch_B as the only build
  frontend; no legacy predicates or firmware workarounds restored.
- [x] Reproduce and locate the firmware failure before the final trap: cancelled
  pre-grant stack loads survive in lsu_bypass and write reused byte-load/branch TIDs.
  The old claim that late-TID stimulus is unreachable is superseded.
- [x] Retain exact cancellation with queued loads under OoOEn and discard cancelled
  heads without synthetic completion, preserving older cache tag/response duties.
  Reuse existing metadata; no issue-width/ISA/DTS/guard change.
- [x] Live boundary before failure, after positives/negatives, copied-source
  cancellation mutation, and translation/forwarding/concurrent-response controls.
  Artifacts: ooo-loadcancel-before-v2, after-v2, translation-v1, mutation-v1.
- [x] 19 integer directed/regression cases match Spike; FP1469/1253 and its negative986
  match; guarded startup663/LR-SC582/lock5883 pass and negative475 fails.
- [x] Eight-step live queue/reference safety and cancellation/mask-release/drain
  cover pass; the retained-cancellation mutation produces a formal counterexample.
- [x] Strengthen experimental/default firmware provenance and explicit timeout
  outcomes, retain source hash maps, and test positive/refusal cases (50 host tests).
- [x] The first candidate's full firmware run reaches OpenSBI banner/HART Count2
  and domain enumeration, then errors at time10,707,552 on load_unit.addr_offset0.
  No boot PASS: ooo-osbi-loadcancel-full-v1 and its retained assertion trace tail.
- [x] Correct-prediction-release self-critique fails on the first candidate and is
  repaired without broad branch cancellation; final leaf56 and eight-step
  safety/cover/mutation pass. Final live-port load-unit/bypass synth: zero latches/SCCs.
- [x] Final integer model315f6a05... passes19 Spike comparisons. Protected boot
  smt2-loadcancel-protected-v1 passes12,765,628 cycles,333,635/8,932,406; final
  in-order rebuild is byte-identical (f35d0e10...). Final lint passes10/11 warnings.
- [x] Localized the offset assertion: it is an INSTRUMENT defect, not an OoO signal.
  Directed stage32 aborts in796 cycles on OoO and1582 in-order; the `$fatal` severity
  and its "actually triggers a misaligned exception" comment are both upstream and
  unmodified. Antecedents are now alignment-qualified; no exception/kill rule relaxed.
  Witness `ooo-osbi-offset-witness-v1`: va=0x2f offset=7 tid=0 commit_tid=4, i.e. a load
  YOUNGER than the commit head; `speculative=0` is uninformative at SpeculativeSb=0, and
  the small-non-zero-address inference stays refused (five recorded reverts).
- [x] Wrong-path misaligned load is architecturally invisible: stage33 passes915 cycles
  Spike-matched with a failing negative; registered as ooo_load_misaligned_not_taken.
- [x] Built a one-axis in-order control by allowlisting `OoOEn` in
  isolated-config-overlay.py (both arms from one source state, no package edit):
  `OoOEn:1->0` on g6lc64_ooo_int, model e02f1f2d..., 4 build warnings, clean.
  The tool's uniqueness check correctly rejected my first pattern for also matching
  `SliceOoOEn`; the pattern is now line-anchored.
- [ ] **NEW, open — SHARED trap-restart defect, NOT OoO.** Two ELFs of the same source
  differing only in branch immediates, deterministic across replays:
  after-v2 -> OoO FAIL (restarts at 0x80000206, never enters mtvec) and in-order control
  TIMEOUT (cause=4 raised, then no further retirement); phase-v1 -> OoO PASS907,
  in-order PASS925. Since it reproduces at OoOEn=0, the two-issue OoO path is exonerated
  and this must not be fixed inside or counted against the OoO increment. cause/mepc are
  correct in both arms. Owner is the commit->frontend restart path; mechanism NOT
  identified, no repair attempted. Keep stage32 out of the passing gates until resolved.
  Restart source now OBSERVED via +smt_flow_trace (no rebuild): after the trap commits at
  0x800001f8, the frontend allocates gen=11 at 0x80000206 — the sequential stream — and
  0x800001fe/0x80000202 are never allocated, so PC-gen did not take the commit-supplied
  mtvec 0x80000210. Owner: PC-gen priority between the commit exception PC and a
  frontend-internal redirect (controller.sv already flags this seam in prose for
  "early load-misalign/illegal"). Candidate co-factor: the failing ELF has TWO branches
  sharing one target while the passing ELF has distinct targets. That candidate is now
  REFUTED, not weakened: stage34 reproduces the geometry byte for byte (8-aligned faulting
  load, 2-byte co-issued op, straddling 4-byte branch) WITH both branches sharing a target
  and PASSES on both models, non-vacuously (trace shows the trap then mtvec 0x80000210).
  What remains unexplained is narrower: the same shape fails with the shared target at
  0x8000025e and passes at 0x8000027e, though both sit at offset6 of their 8-byte window
  and are 2-byte aligned. No supported candidate remains; improve the observation rather
  than patch. Do NOT reorder PC-gen priority — heaviest recorded negative history.
  Stage34 registered as ooo_load_misaligned_shared_target to pin the geometry.
  MECHANISM IDENTIFIED (observation improved, still no repair): the exception flush is
  CORRECT in both arms (failing cycle=786, passing cycle=789, both flush=1
  flush_unissued=1). The difference is what the frontend supplies next — failing arm
  allocates 0x80000206 just 3 cycles after the flush, passing arm allocates mtvec
  0x80000210 after 8 cycles. Eight cycles is a real redirect plus I$ access; three is too
  few, so the failing arm delivers instruction supply that was ALREADY BUFFERED when the
  flush asserted. The later mispredict to 0x8000025e is a consequence, not the fault.
  CORRECTED same session (T9): the channel-3 "a queue entry survived the kill" reading is
  WITHDRAWN. instr_queue.sv wires flush_i to both FIFOs and resets idx_ds_q/idx_is_q/
  push_seq_q on the same condition, so the instruction queue IS cleared on flush and a
  surviving entry is not an available explanation. Observed facts that stand: the flush is
  correct in both arms; the failing arm's first post-flush allocation is a PRE-FLUSH-STREAM
  PC (0x80000206) not mtvec; it arrives in 3 cycles vs 8 for the correct redirect; the later
  mispredict and tohost=1 are downstream. NOT distinguished: delivery from a frontend
  structure the flush does not reach (loop buffer, FTQ, I$ output register, realigner carry —
  none inspected yet) versus PC-gen selecting the sequential PC. No owner named, no
  mechanism claimed. INSPECTION DONE: every frontend structure holding a fetched instruction
  or PC across flush_if is flush-qualified (instr_queue, realigner leftover, FTQ, loop
  buffer, predictor, icache_valid_q, inflight_q). The ONLY non-flush-qualified state is
  replay_q/replay_addr_q (frontend.sv:170-178), which also outranks the sequential step and
  the prediction in npc_select — recorded as a latent asymmetry, but NOT this defect:
  +fetch_win_trace shows rp=0 at the exception flush. DECISIVE NEGATIVE: the [win] line at
  the exception flush is IDENTICAL in both arms (vaddr=0x80000208 k1=1 k2=1 fl=1 mp=0 rp=0
  npc=0x80000218; failing t=799, passing t=802), so arch_valid is low in both and
  "trap vector not selected at the flush" explains nothing. THREE candidates now eliminated,
  none weakened: shared branch targets; a queue entry surviving the kill; replay_q /
  arch_valid-at-flush. DIVERGENCE NOW ISOLATED to one cycle after the flush: the failing arm
  ACCEPTS the I$ response for the window it just killed. failing t=799 kills 0x80000208
  (k1=1 k2=1 take=0), then t=800 rsp=1 vaddr=0x80000208 take=1 bpf=1 vmask=0111 npc=0x80000248
  — three instructions pushed and a prediction fired from a killed window; the t=804 mispredict
  to the fail exit is its consequence. The passing arm accepts nothing until t=808, and accepts
  0x80000210 = mtvec. Promise violated: a killed request's response must not be accepted after
  the kill (kill_s1/kill_s2 are single-cycle, inflight_q is cleared by kill_s2 the same cycle,
  and icache_take is no longer inhibited once fl=0). Channel3 at the RESPONSE boundary, not the
  queue. Strongly supported by a matched deterministic pair but still a CANDIDATE: the chain is
  CONFIRMED by instrument: +fetch_kill_check (frontend.sv, translate_off, report-only,
  allowlisted in corev_apu/tb/g6lc_tb.cpp) reports EXACTLY ONCE on the failing arm —
  "t=800 take=1 rsp_vaddr=0x80000208 killed_vaddr=0x80000208 same=1 npc=0x80000248" — and is
  SILENT for the whole passing run. same=1 proves the accepted response is the killed address,
  so this is not a frequent benign event. Chain closed by observation: killed response accepted
  -> trap vector never fetched -> mispredict into the fail exit.
- [x] Repair IMPLEMENTED: kill persistence in frontend.sv. kill_owed_q/kill_owed_addr_q remember a
  killed in-flight fetch until its response is seen or a replacement is issued; icache_take is
  gated by kill_drop, which drops a response only when its ADDRESS matches the killed one (an
  address compare, not a decision from fetched data, so channel5 stays closed). No new clock or
  reset; build clean at baseline 9 warnings, none added. Before/after on the frozen pair:
  after-v2 FAIL -> PASS 906 with "take=0 drop=1 npc=0x80000218" once at t=800; phase-v1 PASS 907
  unchanged with the checker silent. Regression: stages 17,20,22,25,29,30,31,32,33,34 Spike-matched
  (918/913/936/959/896/894/906/906/927/902), stage 26 self-checking PASS 911 (it must NOT be
  Spike-compared: its LR/store/SC sequence is unconstrained and both outcomes are legal — my
  SPIKE=1 invocation produced a false FAIL). Cycles within ~3 of pre-repair.
- [x] Cleared the kill-persistence repair of the anchor failure with a one-source-state control.
  G6LC_NO_KILL_PERSIST disables only the drop (state and probe kept). Repair ON (3a1e9742...) and
  repair OFF (64fcafec...) both stop at pmp_entry.sv:81 at EXACTLY 12,731,487 cycles — same
  assertion instance, same cycle. The repair neither causes nor influences it; the earlier reading
  "the repair regressed the anchor" is WITHDRAWN.
- [x] Reconfirmed the anchor on the OLD model: work-ver-smt2-loadcancel-v2 still PASSES
  (rc=0, 761s wall). So the anchor result is reproducible and the regression is real at the current
  revision — not a stale or lucky earlier pass. Note the wall-time asymmetry: 761s for the old model
  versus ~1243s for the new ones, explained by the added always_ff blocks (kill state + probe)
  costing simulation time every cycle even with the plusarg off.
- [x] FRONTEND FULLY EXCLUDED from the anchor regression. The G6LC_NO_KILL_PERSIST seam was widened
  to remove the added STATE and PROBE as well as the drop, giving a genuine zero-delta frontend arm
  (c196c15dd04275cc...). Four anchor runs: old loadcancel-v2 PASSES 12,765,628; repair-ON
  (3a1e9742...), drop-disabled (64fcafec...) and zero-delta (c196c15d...) all stop at pmp_entry.sv:81
  at EXACTLY 12,731,487. Same assertion instance, same cycle, three different builds. Neither the
  kill-persistence drop, nor its flops, nor the probe is involved.
- [x] Discarded a wall-time inference before using it: 1224s vs 761s is explained by the synthesis
  gate running CONCURRENTLY on the same builder, not by added logic. Do not read run duration as
  evidence while another job shares the machine.
- [x] DELTA SET ESTABLISHED WITHOUT SIMULATION by diffing the per-file source hashes in the two build
  manifests (689 sources each; smt2-loadcancel-v2 = passing, smt2-zerodelta-v1 = failing). Exactly
  THREE files differ, no additions or removals:
    core/fetch_B/frontend.sv   -- inert in the zero-delta arm by construction (ifdef'd out; only
                                  `logic kill_drop; assign kill_drop = 1'b0;` and a constant-folded
                                  `&& !kill_drop` remain)
    core/load_unit.sv          -- assertion antecedents only, inside //pragma translate_off
    corev_apu/tb/g6lc_tb.cpp   -- one plusarg allowlist string; cannot reach RTL
  This also disposes of a trap: `git diff` against HEAD shows 42 insertions in load_unit.sv, but most
  of those were ALREADY in the passing build (the cancellation repair), so the git diff is the wrong
  delta to reason about. Use the manifest hash diff for build-to-build attribution.
- [x] Checked the translate_off structure in load_unit.sv: ONE region, translate_off@758 ->
  translate_on@796 -> endmodule@798, with the edit entirely inside it. No boundary was disturbed, so
  the edit cannot be promoting real logic into or out of the stripped region. The added signals also
  drive nothing. That edit is therefore inert too.
- [x] Candidate "changed non-source input" EXCLUDED without simulation. Comparing the two anchor
  result records, 706 of 712 hash/firmware/profile/boot/cycle keys are IDENTICAL; the only
  differences are modelSha256, modelManifestSha256, logSha256 and the three source hashes. Firmware,
  DTB, payload, profile, bootrom, plusargs and cycle cap all match. Also confirmed the passing model
  is f35d0e10afd10fcb... — the true protected anchor, so the reconfirm was against the real baseline.
- [x] Candidate "non-reproducible build" LARGELY REFUTED: three independent builds (different
  verlibs and defines) all stop at EXACTLY 12,731,487. A non-deterministic build would vary. So the
  build is deterministic and the failure IS source-determined — which means one of the three deltas
  really is behavioural, contrary to inspection.
- [x] Recoverability of the passing contents: frontend.sv's passing hash EQUALS HEAD (dc3746b8...),
  so this session added the only changes there. load_unit.sv and g6lc_tb.cpp were ALREADY modified in
  the passing build, so neither can be restored from git — reconstruct them by reverting only this
  session's edits, not by checkout.
- [x] g6lc_tb.cpp allowlist EXCLUDED by inspection: `verilog_plusargs[]` is NULL-terminated and
  scanned with `while (*plusarg && ...)` (no hardcoded size or index), and the match is a prefix test
  that can only make MORE args legal, never fewer. `verilog_plusargs_legal` latches only on an
  UNrecognised arg. Adding one entry cannot change how the anchor's own plusargs are classified.
- [x] SETTLED, and it matters beyond this bug: **Verilator does NOT strip translate_off regions in
  this flow.** Proof by observation rather than by doc: pmp_entry.sv's assertions live inside a
  `// synthesis translate_off` region (pmp_entry.sv:76) and they DID fire. So sim-only regions are
  elaborated here. Consequence: the inertness of the load_unit.sv edit rests solely on the added
  signals driving nothing — NOT on the region being stripped. Anyone relying on translate_off for
  "this cannot affect the build" (AGENTS.md 2.5, carry-over checklist) should treat it as
  "not synthesized" and not as "not elaborated in simulation".
- [x] **RETRACTION: the "frontend exonerated by a zero-delta arm" conclusion was CONFOUNDED.** All
  three arms that "failed identically" still carried an unaccounted load_unit.sv delta — the enriched
  $fatal diagnostic added for the witness run, which I had never removed. So none of them was a
  zero-delta test. Delta accounting that is not hash-verified against the passing build is not
  accounting.
- [x] load_unit.sv is now EXACTLY the passing build's content, verified by hash
  (d875f9997d3a14baea84e65e373f472b4da9b270894aeae1dc8f321fd9201fd7). Achieved by removing BOTH the
  enriched $fatal diagnostic AND the assertion-antecedent edit. NOTE: the antecedent repair is
  therefore currently REVERTED in the worktree, so stages 32/33 will abort again until it is
  re-applied — re-apply it once the anchor question is closed.
- [x] With load_unit.sv clean and the kill-persistence repair ENABLED (model 70da7cac558b3618...),
  the anchor STILL stops at pmp_entry.sv:81 at 12,731,487. Source now differs from the passing build
  in only TWO files: core/fetch_B/frontend.sv and corev_apu/tb/g6lc_tb.cpp.
- [x] TRUE single-delta test RUN (model 145c8d74c0f36a84...): load_unit.sv byte-identical to the
  passing build AND G6LC_NO_KILL_PERSIST (frontend ifdef'd to nothing). The anchor STILL stops at
  pmp_entry.sv:81 at 12,731,487. The kill-persistence repair is therefore exonerated — this time on a
  clean arm, unlike the earlier confounded claim.
- [ ] **NEXT: revert this session's 5-line g6lc_tb.cpp allowlist addition, keep the define, run the
  anchor.** After that revert the only remaining difference from the passing build is frontend.sv's
  inert residual (`logic kill_drop; assign kill_drop = 1'b0;` plus a constant-folded `&& !kill_drop`
  and comments). PASS => the plusarg table affects the run, so inspect every consumer of
  verilog_plusargs beyond the legality scan. FAIL => the residual or the BUILD owns it; then restore
  frontend.sv to HEAD content (confirmed equal to the passing build, dc3746b8...) and rebuild — if
  THAT still fails, the source is fully exonerated and the builder/environment is the culprit, which
  would invalidate using this anchor as a gate until fixed.
- [ ] Tally of builds: FIVE session builds all stop at exactly 12,731,487; the one pre-session build
  passes at 12,765,628. Identical firmware/profile/DTB/bootrom/plusargs/cycle-cap (706/712 keys).
- [ ] Superseded framing, kept for provenance: every one of the
  three deltas has now been individually argued inert AND the build is deterministic AND the
  non-source inputs are identical. Those four statements cannot all be true, so one of the
  *arguments* is wrong, not merely the conclusion. Stop reasoning and MEASURE: the next action is the
  single-delta build (revert only this session's load_unit.sv assertion edit, keep everything else)
  because it is the only delta whose inertness argument depends on a claim about unused logic rather
  than on a structural impossibility. If that restores the anchor, inspect what those added signals
  actually elaborate to now that translate_off is known not to strip. If it does not, bisect the
  frontend file content itself (not the ifdef arm) against its HEAD version, since HEAD is confirmed
  to equal the passing content for that file.
  Until settled, NOTHING at the current revision may be called qualified, and the kill-persistence
  repair — though independently evidenced — must not be presented as qualified.
- [ ] Superseded framing of the same item: the protected anchor no longer completes at this revision. It completed at
  12,765,628 cycles earlier this session; it now stops on pmp_entry.sv:81 in the PTW's PMP
  (outcome=error, strictDualPassed=false, timedOut=false). Not distinguished: an over-strict upstream
  NAPOT check on a transient mid-update pmpaddr (OpenSBI writes pmpaddr and pmpcfg in separate
  instructions, so a malformed pair is observable between them) versus a real wrong value. Do NOT
  assume the over-strict reading just because this session opened with one. Bisection handed over:
  the only behavioural RTL delta since the passing run is the frontend repair, and the control has
  EXCLUDED it — so look at the non-behavioural edits (load_unit assertion antecedents are
  translate_off; harness/test/tooling) or at whether the anchor was already latent. Not part of the
  OoO increment.
- [ ] Decide on promoting +fetch_kill_check from report-only to a fatal gate, after a full-suite
  silence result. A fatal probe that fires in an unrelated configuration is worse than no probe.
- [ ] Separate, latent (found during that inspection, not a live defect): replay_q and
  replay_addr_q carry a pre-flush fetch address across flush_i and outrank the sequential
  and prediction cases in npc_select. No observation yet shows it firing across a flush;
  treat as a contract probe to be checked, not a repair to be made.
  The in-order arm reprinted the cap banner `SUCCESS (tohost=0) after 20000 cycles` and
  was correctly classified `timeout` — keep that H3 guard.
- [x] Final-source OoO integer remote lint passes10 warnings against baseline11.
- [ ] Collect final full-core synthesis (shell8add45), relaunched after the last
  cancellation-source refinement. The earlier clean2-warning run is retained but
  not borrowed for this source revision. Strict standalone slang remains a
  separate unavailable gate; no skip waiver. The licensing diag is unregistered;
  manual tier/header review does not constitute an automated licensing PASS.
- [ ] Broaden pre-grant lifetime qualification to pending stores, all response/FU
  types, non-power-of-two load geometries and bounded/unbounded formal properties.
  Cross-hart memory, traps/interrupts, FP across harts and mixed residency stay open.
- [ ] Audit earlier prose against current evidence: LR reservation survives LR
  retirement; stage31 is below capacity; raw boot work split is not fairness;
  stage26's legal SC divergence is not exact Spike matching. Current architecture
  record and plan state these corrections. No new architectural claim follows.

## Active continuation toward SMT2+OoO (2026-09-19)

The user's latest request reopens the earlier deferred dual-hart work. The first
milestone is coarse handoff, not mixed residency or guard promotion. Open
`architecture/out-of-order/README.md`, FP lifetime / guarded SMT2 foundation, first.

- [x] Collect the earlier integer recovery synthesis: clean, two warnings; strict
  standalone-slang still SKIP, so no aggregate all-gates PASS.
- [x] Repair FP committed-map updates and physical-zero storage, including f0.
  Frozen fence test goes code8 failure -> PASS1471;199 ordered retirements match Spike.
- [x] Repair FP hart-local reclaim and same-cycle physical ownership transfer.
  Wire dispatch/commit hart identity into rename; shared pools and geometry checks.
- [x] Separate completion from usable CSR/AMO data. Commit-time mirror wakes waiters;
  early placeholders no longer do. CSR->ALU goes FAIL1247 -> PASS1251,200 matched
  Spike retirements. Wrong-FMA control fails correctly with25 matched retirements.
- [x] Repair OoO WFI's precise park boundary and exclude legacy SMT store keep/replay
  rules from OoO. Before tests fail; WFI56 and store24 positive/negative records pass.
- [x] First guarded two-hart integer startup: PASS664,47/73 retirements; frozen
  negative FAIL630,48/61; observer off/on664. LR/SC RS1/RS2 PASS586, ALU PASS582,
  negative FAIL475. No default target, FP/hart guard or firmware change.
- [x] Final leaf sweep:122 matched records; WFI56/store24 controls, bounded recovery
  and rename proofs,99,645-cell live-port synthesis with zero latches/SCCs. Final
  integer S4/S5/S15/memdep/ILP and FP fence/status/negative ROIs all match Spike.
- [x] Final protected SMT2 rebuild booted: strictDualPassed=true,12,765,628 cycles,
  333,635/8,932,406 retirements, matching the anchor. No OoO boot claim.
- [x] Full-core synthesis for the FP/WFI/store-recovery increment: PASS, clean with
  two warnings (~54 min). Lint PASS at 10 warnings against baseline 11.
- [x] Full-core lint and synthesis re-run against the FINAL RTL (after the store
  admission, the LR/SC window repair and all three RVFI fixes): lint PASS 10 vs
  baseline11, synth PASS clean with 2 warnings. Strict standalone-slang remains unavailable on the builder, so
  the aggregate gate still reports incomplete and no skip-policy waiver is taken.
  Earlier synthesis runs in this session predate later edits; do not cite them.
- [x] OoO memory ordering in the LSU store buffer. Two contracts were violated and
  are repaired behind `OoOEn`: (a) forwarding/hazard matched on address alone, so a
  YOUNGER store could supply an older load; (b) the speculative queue was a FIFO in
  ISSUE order, so same-address stores reached memory out of program order. Directed
  stages17/18/19 go FAIL929 / FAIL949 / HANG -> PASS915/940/952 with Spike-matched
  retirements; negatives fail 928/943/938; the in-order control passed throughout.
  Leaf fixture 32 records. Regressions 878/974/883/1057/1109 and FP 1471/1251/988
  unchanged; guarded dual-hart 664 / 586 / 582 / 475 unchanged; protected in-order
  SMT2 boot re-run: strictDualPassed, 12,765,628 cycles, 333,635/8,932,406.
  The hazard age filter is a LIVENESS requirement (stage19 hung before it).
- [x] **Repaired a third, pre-existing defect: speculative store queue capacity
  inversion.** Stage22 (ten outstanding stores, oldest data-delayed) hung at the cap
  on both the new and the previous OoO model, while the in-order control passed at
  1792. Eight younger stores filled `DEPTH_SPEC=8`, the oldest could never post, and
  the queue drains only on in-order commit. Fixed by admitting stores at issue in
  program order relative to each other in `g6lc_iq.sv` — an admission rule over
  UNISSUED entries, so it does not reproduce the live-store-gate deadlock the file
  warns about. Chosen over IQ capacity reservation: no new cross-module signal on
  the issue path, and stores cannot retire out of order anyway. Measured ILP cost is
  nil — all regressions identical, stages17-21 within one cycle. Stage22
  TIMEOUT -> PASS933 and is now in the testlist.
- [x] AMO ordering against out-of-order neighbours is SOUND. Stage23/24 pass on
  their own checks; a second AMO (unforwardable, reads memory at commit) confirms
  0x807 landed. An apparent defect was retracted as an instrument fault.
- [x] **Repaired, verification infrastructure: RVFI operand capture under OoO.**
  `cva6_rvfi.sv` latched rs1/rs2 at DISPATCH keyed by `issue_pointer`, but
  `rvfi_rs1_o/rvfi_rs2_o` are the operands at ISSUE keyed by issue port. In order
  they coincide; under OoO the IQ issues a different entry, so the join is invalid
  and rs2 arrives as another instruction's value. AMO `mem_wdata` is computed from
  it, so AMO memory effects were silently unchecked in trace comparison. Fixed by
  exporting `rvfi_operand_valid_o`/`rvfi_operand_tid_o` from `issue_read_operands`
  through `issue_stage`/`cva6.sv`/`rvfi_probes_instr_t`, and re-capturing under
  `OoOEn` against the issuing trans_id; the in-order capture path is untouched.
  AMO rows now match Spike (stages23/24 qualified on model `6180bbc8e219402c…`),
  and all13 directed and regression programs still match with unchanged cycle
  counts. Does not retract earlier results (different fields; no AMOs in those
  programs). The comparator was NOT masked to achieve this.
- [x] LR/SC against a still-speculative older store is SOUND (stage25, PASS956).
  It exposed a second instrument fault: `lsu_wmask` keyed on `fu == STORE` alone
  reported a memory write for load-reserved, which only reads. Probe now carries
  `lsu_ctrl_op` and excludes `AMO_LRW`/`AMO_LRD`. All 14 directed and regression
  programs then match Spike with unchanged cycle counts. A FAILED SC also writes
  nothing; no directed test yet, named rather than assumed.
- [x] **Repaired, pre-existing: a plain store following a load-reserved never
  retired under OoO.** Stage26 (LR + store + SC) and stage27 (LR + store to an UNRELATED
  address) both time out at the cap; in-order passes at1751/1736. The trace shows
  the `lr.d` retiring normally and the next store never retiring, so it is not
  reservation logic nor same-address ordering. Times out identically on all four
  model generations including the pre-change baseline, so it is not from this
  session. Existing dual-hart LR/SC tests pass because they place `sc.d` directly
  after `lr.d` with no intervening plain store. Refined symptom: the store is
  allocated (`alloc id=3`), becomes the commit head (`commit_ptr=3`), never writes
  back, and ~24 instructions allocate behind it before dispatch stalls with the
  ROB not full; no `store_offer` ever appears, so it never reaches the LSU.
  A temporary store-unit probe settled the attribution in two corrections. It first
  refuted my own weakening (`st_ready=0, sb_rdy=1, amo_rdy=0` — the amo buffer WAS
  occupied, so `retire => ack => pop` was a bad inference), then refuted the
  original hypothesis too: extending the probe showed `amo_ack=1` at cycle800, so
  the buffer DOES drain, `st_ready` recovers and the store unit sits idle with
  `valid_i` never rising. **The store unit is exonerated; the store is withheld
  upstream and never presented to the LSU.** Stage28 (no fence) hangs identically,
  so the fence flush/re-push is not required either. All of 26/27/28 time out on
  all four model generations including the pre-change baseline, so the
  store-admission rule from this session is NOT implicated. Root cause then found
  on the upstream grant path and confirmed by the existing `issue_stall`
  diagnostic: `lrsc=1` is the sole asserted blocker with every other term ready.
  `lr_sc_pair_q` blocks non-SC STORE issue and closes only on SC issue or flush;
  in-order always gets one while the LR is live, OoO need not, and an LR with no
  SC is legal. Repaired under `OoOEn` by remembering the LR's trans_id and closing
  the window when that LR is no longer live (`fwd_i.still_issued`) — no new port,
  in-order path untouched. Stages26/27/28 now complete at 896/880/873 and are
  registered. Stage26 stays self-checking only: the sequence is unconstrained so
  the SC may legally succeed or fail (CVA6 fails, Spike succeeds).
- [x] Failed-SC write mask (the case previously named as untested). Stage26 caught
  a failed SC still reporting a memory write while the program's read-back proved
  memory untouched. `mem_wmask` is now suppressed at commit when an SC reports
  failure; the RTL memory-effect list becomes empty, matching the architecture.
  Temporary store-unit probe removed.
- [x] **Repaired: an uncommitted CSR wedged the whole FLU, stalling both harts.**
  `SMT_LOCK` (both harts contending for one amoswap lock) times out at 200k cycles
  with 35/39 retirements — both harts stalled, not spinning. In-order passes the
  same frozen ELF in 7,392 cycles with 1,600/2,037 retirements. Not the
  store-after-AMO path: stage29 (amoswap then store, the critical-section shape)
  passes at 893 and matches Spike. Not the LR/SC window either (`lr_sc_pair_q` is
  LR-only). Mechanism unidentified; no owner claimed. This bounds the dual-hart
  OoO milestone: reset rendezvous and LR/SC consumers pass, but mutual exclusion
  between harts does not, which is a prerequisite for OpenSBI/Linux on dual-hart
  OoO. Trace narrows it: `flu_ready=0` forever with every scoreboard entry live,
  and both harts still in the PROLOGUE (last PCs 0x80000066/0x80000060), so it is
  not contention over the lock itself; `lrsc=0` clears the LR/SC repair. Two
  single-hart candidates did not reproduce it: stage29 (amoswap+store, 893) and
  stage30 (younger CSR ahead of an older FLU consumer, 896), both registered.
  Root cause read from the code: `csr_buffer` is depth-1 and hart-agnostic and
  holds `csr_ready` low from issue until COMMIT; `ex_stage` feeds that into
  `flu_ready = csr_ready & mult_ready`, which IRO turns into "all FLU units busy"
  for both harts. In order a CSR is effectively oldest when issued so it commits
  promptly; out of order it can be stranded behind older FLU consumers while
  younger work fills the scoreboard. Repaired in `g6lc_iq.sv`: a CSR issues only
  when it is the oldest live instruction (`trans_id == commit_ptr_i`), restoring
  the buffer's own depth-1 assumption. **Two-hart lock now passes on OoO at 5,883
  cycles (1,600/1,952), faster than in-order's 7,392.** Cost: uniform +3 cycles on
  the directed/regression set. All 19 programs still Spike-matched; dual-hart
  startup/LR-SC and the FP suite unchanged.
- [x] **Firmware on dual-hart OoO is now MEASURABLE** via an explicit
  experimental-model mode in `run_opensbi_source_review.py`. The identity binding
  stays mandatory (hash must match; only the field name `modelSha256` is now
  accepted beside `executableSha256`), and two new refusals keep it honest: a
  substituted model without `SOURCE_REVIEW_EXPERIMENTAL=1` is rejected, and the
  flag without a substituted model is rejected. Default refusal verified. Results
  carry `experimentalModel`, `protectedAnchor: false`, `modelQualificationOnly`,
  `modelHarts` and the substitution list.
- [ ] **OPEN: OpenSBI does NOT boot on dual-hart OoO.** First measurement hits the
  16M cycle cap with `strictDualPassed: false`; hart0 retires 9,805,054 while
  hart1 manages only 42,592 — inverted against the in-order anchor's
  333,635/8,932,406 — and the hang pin shows `mcause1=0x1` (instruction access
  fault) with `wfi1=1`, so hart1 faulted and parked. The banner says SUCCESS after
  16000000 cycles, which is the cap, not completion. Next: trace hart1's fault PC
  and the faulting fetch under OoO.
- [x] Historical note: firmware on dual-hart OoO was previously blocked outright by
  the identity guard. With two-hart mutual exclusion working, OpenSBI on the guarded
  OoO dual-hart model was attempted and `run_opensbi_source_review.py` refused with
  `source-profile model identity mismatch`: it binds the measured model to a
  build manifest by `executableSha256` + `target`. The isolated OoO build carries
  its own truthful record (`target: g6lc64_smt2`, `harts: 2`, `qualificationOnly`,
  and a per-file original-vs-review SHA map of every guard substitution) but names
  the hash `modelSha256`. Renaming that field would satisfy the check while
  defeating its purpose — attributing an experimental, substituted build as the
  protected source-profile anchor — so it was NOT done. Correct unblock: teach the
  runner an explicit experimental-model mode that accepts the isolated record and
  propagates `qualificationOnly` and the substitution map into the result, marking
  it as not the protected anchor. That strengthens the control rather than eroding
  it; it needs a decision before implementation.
- [ ] Remaining dual-hart gates: late-TID reuse, traps/interrupts, FP across harts,
  cross-hart memory ownership, independent reference and firmware runs. Also STA
  for the added store-path age comparators, and a failed-SC trace case.
- [ ] Mixed residency: per-owner recovery and memory obligations before elastic
  sharing or scheduling performance work. Coarse startup is not mixed overlap.
- [ ] FP and SMT+OoO guard promotion remains separate from these directed passes.

## Active two-issue OoO recovery qualification (2026-09-19)

This block supersedes the loop-hang hypotheses below. Contract and evidence:
`architecture/out-of-order/README.md`, current two-issue recovery repair.

- [x] Read the coding/runtime-learning philosophies, all three SMT2 reasoning
  guides and the full active/historical plan. Preserve the fetch_B-only boundary;
  do not transplant fetch_A/smt_legacy recovery heuristics.
- [x] Reproduce and tag the first broken contract: a surviving older IQ entry is
  acknowledged in the cycle IRO suppresses every FU-valid for a younger redirect.
  The stuck tid4/gen11 is the load-result check, not the loop back-edge. Scoreboard
  `issued` proves allocation only. No circular-age or FLU-port repair was justified.
- [x] Repair the OoO dispatch seam: flush suppresses FU offers and actual offered
  valids qualify IQ acceptance. New admission also stops on full flush; selective
  younger cancellation and same-cycle wakeup remain live.
- [x] Frozen-ELF before/after controls: stages5/15 and ooo_mem_dep time out on the
  old model and pass at974/883/1057 cycles on the repaired TWO-issue model. Stage4
  and ILP stay878/1109; all16 memory-probe stages pass. Recovered tid4/gen11 now
  issues, writes back and retires. Stage15 observer on/off is883 cycles in both.
- [x] Permanent dispatch recovery/held-ack/wakeup/full-flush/cancel regressions and
  stage5/15 testlist entries; before-case fails. Frozen ELF replay, disassembly and
  fail-closed run classification added to the existing runner;42 host tests pass.
- [x] Recovery four-step live safety + reached cover + raw-ack fault counterexample;
  existing12-step rename BMC and its negative;128 matched fixture/negative/guard
  records. Live-port synthesis:99,359 generic cells, zero latches/SCCs.
- [x] Full-core remote lint:10 warnings, baseline11. Strict standalone-slang is
  still SKIP (no builder binary); aggregate gate is INCOMPLETE, not waived.
- [x] Collected the recovery-era full-core synthesis: clean with two warnings.
  Later foundation changes have a separate pending full-core regate above; the
  live-port fixture's result is not a substitute.
- [x] Fresh SMT2 rebuild is byte-identical to boot-qualified model34afc030...;
  preserves its12,765,628-cycle strict dual boot, not a new firmware execution.
- [x] Branch-chain oracle repaired: main now saves/restores its incoming ra.
  Original ELF times out in-order too. Corrected test passes OoO1258/in-order1291;
  wrong expected final count fails on both. This was not another RTL defect.
- [ ] Resume FP qualification after these integer gates; hart/FP refusals remain.
- [ ] Single-issue CASQ read-port elaboration remains a separate pending geometry
  defect; changing the shipping OoO configuration to single issue is not the fix.

No commit, feature-enable, scheduling-policy, issue-width or ISA/DTS change.

## Active P0–P2 continuation: contract re-evaluation

The continuation reassessment in `architecture/remaining-upgrade-sequence.md`
supersedes conflicting closure labels below. The requested coding philosophy,
SMT2/OpenSBI workflow, development logics/heuristics and runtime-learning guide
have been read against HEAD `1afd8d559` and the dirty RTL paths. No commit.

- [x] Fault-test the integration comparator: unordered multisets and duplicate
  collapse can hide ordering/conservation errors. The preservation predicate
  now fails closed; overlap-v8's architectural-preservation claim is withdrawn,
  not its raw run artifacts. `review-overlap-reassessment-v2` reclassifies all
  24 saved records as requiring independent validation, not as RTL failures.
- [x] Predictor overflow lifetime: stored FIFO drain no longer clears desync.
  Old RTL fails the two new cases; `review-ckpt-after-20260916` passes seven
  positives/five expected failures, and leaf synthesis is check/latch clean.
  End-to-end branch identity, replay/kill and bank-flush interactions stay open.
- [x] P2 bounded counter/install increment: concurrent HUM memory, MLP and exact
  collision tests; `review-l2-hum-clean-v1` passes 22 records and small RR0/RR1
  synth checks without latches/check problems. Old-assignment mutations reproduce
  three failures. Declaration/probe/merge-feedback warnings repaired; width/SRAM
  model warnings remain. RR write ownership is fixed, its port schedule is open.
- [x] P2 read-response ownership: five before-cases reproduce same-ID hit/bypass/
  waiter overtaking, nonadjacent A/B/A merge reordering and held-AR replacement.
  Repaired using existing MSHR primary/waiter IDs plus one AR-hold bit;
  `review-l2-read-order-after-v1` passes 38 records with different-ID hit-under-miss
  and same-ID MLP still live.
- [x] P2 write/ATOP response lifetime: the captured write now survives until B and
  every required RLAST handshake, ID-qualified and excluding fill beats. Three
  old-RTL failures reproduced; `review-l2-atop-after-v1` passes 54 records plus
  RR0/RR1 synthesis. Transport only — no atomic arithmetic or coherence claim.
- [x] P2 cache-stack simulation: `CHAIN_L3=1` runs L2 into a two-MSHR L3 across a
  vendor `axi_cut`; `review-l2-stack-chain-v4` passes 34 records and
  `review-l2-stack-direct-v2` re-passes 54 with synthesis. Direct abutment still
  fails the UNOPTFLAT gate (not waived); the lowered graph has zero SCCs.
- [x] P2 server-prefetch ownership: latch, non-ID-qualified absorb/retire, blanket
  demand blocking and reserved-ID collision reproduced then repaired;
  `review-pf-after-v2` passes 8 records with zero-SCC fixture synthesis.
- [x] P2 sequential leaf regression restored: the bench required fill ARs to carry
  the requester's id, which the reserved-fill-id engine no longer does. Oracle
  corrected (reserved id for cacheable unlocked fills, requester id for bypass) and
  leaf-unit ties added. Passes RR0 4-way/latency-8 and RR1 2-way/stalls, including
  bypass backpressure, three ATOP schedules, AMO/LR-SC, fill errors, masked
  invalidation and replacement hole; MSHR/data unit suite passes.
- [x] P2 invalidation source ownership: an external snoop discarded a same-cycle
  write self-invalidation, leaving a stale line that a later read hit without
  refilling (`review-l2-inval-before-v1`). A displaced self-invalidation is now
  deferred and retired when the shared match port frees, with request acceptance
  gated meanwhile; external ordering unchanged. `review-l2-inval-after-v2` 58
  records + synthesis, `review-l2-stack-chain-v6` 38 records, sequential leaf green.
- [x] P2 replacement-metadata port scheduling: one port served both the victim-pointer
  read and the install update, and the update won, so the accepted request's lookup
  used another set's pointer. The read now takes the port and a displaced update is
  held. Reaching the collision needed a phase sweep (a saturated MSHR parks the front
  end, so a continuous stream never collides); the test fails as inconclusive if no
  collision occurs. `review-l2-rr-fault-v3` `collide=1 lost=1`,
  `review-l2-rr-after-v3` `collide=1 lost=0`, `review-l2-rr-regate-v3` 60 records with
  RR0/RR1 synthesis, sequential RR1 policy oracle passes. No policy-benefit claim.
- [x] P2 inclusion engaged in the stack fixture: the first version left the outer
  cache's victim output unconnected, so an L3 eviction never reached the L2
  back-invalidation port and inclusion was never exercised. The fixture now
  arbitrates that port as the cluster does and counts accepted victims.
  `review-l2-inclusion-v1` 40 records; `review-l2-inclusion-fault-v1` disconnects the
  victim and the scenario fails with a stale hit. Mechanism engagement only — with one
  master the stale copy still holds correct data, so the discriminator is the refetch.
- [ ] Remaining P2: zero-cut abutment, prefetch accuracy/bandwidth, reserved-ID width
  decision, directory precision (no L2-residency tracking) and multi-master coherence.
- [x] P0 rename-checkpoint retirement: the pool released only on mispredict/flush,
  so dispatch stalled permanently after `CKPT_DEPTH` correct branches. Now a
  program-order ring retired at commit, levels as ring slots, retirement bounded by
  live count; dispatch derives strobes from commit and clears reused/resolved tags.
  `review-rename-ckpt-release-v1` 18 records, `review-rename-ckpt-fault-v1`
  reproduces the defect with retirement disabled, `review-dispatch-ckpt-release-v1`
  14 records. Leaf/fixture scope; hart/FP legality gates stay.
- [x] P0 LSQ group credits: admission asked only whether any entry was free while
  dispatch is all-or-nothing, so a surplus allocation was silently discarded and the
  op stayed live in ROB/IQ. LSQ now exports free counts and dispatch compares them
  against the group size. `review-lsq-credit-dispatch-v2` 16 records,
  `review-lsq-credit-lsq-v1` 24, `review-lsq-credit-fault-v2` reproduces the defect.
- [x] P0 enabled memdep: `MemDepPredEn=1` had never elaborated and closes a real
  combinational cycle (`md_stall` → IQ select → `issue_sbe_o` → memdep). The stall
  was also wrongly conservative (global store-pending blocked loads with only
  younger stores). The IQ age gate is the safety property, so `mem_stall_i` is tied
  off and the predictor trains/reports only. `review-memdep-before-v2` reproduces the
  loop, `review-memdep-after-v1` elaborates loop-free with 16 records. A relaxing
  predictor with a dispatch-time query and alias proof remains unbuilt.
- [x] P0 OoO latch inferences repaired in rename/LSQ/ROB/dispatch: block-locals are
  now declared and defaulted at `always_comb` scope. `review-ooo-latch-v2` builds
  with `-Werror-LATCH -Werror-UNOPTFLAT` (16 records); rename/LSQ/dispatch re-pass
  18/24/16. Elaborator cleanliness only, not mapped synthesis.
- [x] P0 committed-state recovery: a full flush reset the map to identity and freed
  32..N-1, so every committed value was discarded and its register reissued. Rename
  now keeps an architectural map updated at commit; a flush restores it and rebuilds
  the free list from it. `review-rename-flush-fault-v1` reproduces the loss,
  `review-rename-flush-after-v1` 20 records, `review-flush-dispatch-v1` 16 records.
- [x] P0 checkpoint recovery set: recovery used "free at the checkpoint and no longer
  free", so a register live at the checkpoint, freed by an older commit and then
  reallocated to younger work was never returned and leaked. Each level now carries a
  mask of registers allocated after it, replacing the snapshot at the same storage
  cost. `review-rename-leak-fault-v3` reproduces the leak (a faithful fault needs both
  the seeded snapshot and the removed accumulation), `review-rename-leak-after-v2` 22
  records, `review-p0-dispatch-regate-v1` 16, `review-p0-core-regate-v1` 66.
- [x] P0 hart/FP restriction hardened from a simulation warning to an elaboration
  refusal: `check_cfg` sits under `pragma translate_off`, so an unsound OoO+SMT2 or
  OoO+FP configuration still synthesised. `g6lc_ooo_dispatch` now carries generate-scope
  `$error` guards (same idiom as `gen_err_xif_and_acc`). `review-ooo-illegal-smt-v4` and
  `review-ooo-illegal-fp-v4` confirm the refusal without `-Wno-fatal` and match the
  specific guard message; `review-p0-guard-regate-v1` keeps the legal config at 66
  records. Two false positives (an `FPU` enum-name collision, a runner comparing the
  wrong message because the loop rebinds `kind`) were found and fixed.
- [ ] P0 open redesigns: per-hart map/free/busy namespaces (needs hart tagging across
  rename/IQ/ROB/LSQ/memdep and per-hart flush) and an FP register class (second map,
  class tagging through rename/wakeup/WB, PRF and issue_read_operands paths). Both are
  multi-module redesigns needing a full-core gate, not increments; the elaboration
  guards keep the configurations unbuildable meanwhile.
- [x] Recover supply-cap-v3 log without rerunning it: `review-supply-recovery-v1`
  has the PASS-cookie tail and final summaries, but model/input manifests are
  absent and rows omit explicit owner identity. This is diagnostic only.
- [ ] Independently validate warm-fetch overlap and compare fixed useful work.
  Bind model/ELF/runtime and ownership; do not transplant old analyses to new traces.
- [x] Platform gate no longer reports a pass for steps that did not run: `verify`
  counted only failures, so the dry-run printed "Gate passed: 8 step(s)" while every
  stage was SKIP. The verdict is now a pure `gateVerdict()`: failure outranks skip,
  skip outranks pass, a skipped stage yields exit 4 unless `--allow-skips`, and a dry
  run reports a plan explicitly. Unit-tested; `bun test` 219 pass / 0 fail, tsc clean.
  Two pre-existing tooling-test defects fixed while doing this: a stale
  `l2_leaf_passed` fixture (my earlier commit tightened the predicate without updating
  its test) and a branding scan that matched the word "program" inside a comment,
  which had been masking that two `.svh` includes declare no design unit.
- [x] Remote lint route for the gate (`verify --lint --lint-remote`): one round trip
  through the testharness proxy, the flattened flist and waiver rewritten to the
  builder's checkout, outcomes classified from emitted RESULT lines rather than the
  transport exit code. Verified substantive: 245 flist entries, real warnings from
  `/opt/testharness/repo/core/*.sv`, zero missing files, both targets rc=0.
  The builder's Verilator is not the local suite's, so local `warningBaseline` does
  NOT transfer — comparing against it would let a regression hide under a much larger
  accepted count (8 remote vs 483 local). A separate `verify.warningBaselineRemote`
  governs the remote route and is currently unset, so the route reports counts
  explicitly as ungated instead of implying a baseline comparison.
- [x] Remote synth route added and `--remote` switches every routable stage (lint,
  synth, formal) in one flag. `verify --lint --synth --remote` passes both targets on
  the builder: lint 8/54 warnings, synth clean after ~3.5 min of real elaboration per
  sweep. Two defects found in my own route while doing it: the slang frontend does not
  strip quotes from a command-file argument, so the quoted flist path reached it
  literally and every target failed; and the warning pattern `Warning:` matched
  nothing, reporting a false "0 warning(s)" where the log holds 32/5 — now counted
  with the same notion as the local `countDiagnostics`.
- [x] Gate coverage gap closed for the uncore: lint/synth elaborate top `cva6` from
  core/Flist.cva6, which contains NONE of g6lc_cluster, g6lc_l2_top, g6lc_l3_top or
  g6lc_server_prefetcher (276-line flist, zero matches) — so every L2/L3/prefetch
  repair in this review sat outside the standing gate, checked only by its own
  fixtures. Added `corev_apu/Flist.cluster` + `verif/tb/g6lc_cluster_lint_top.sv`
  (a typed top, since g6lc_cluster as top elaborates with `cva6_cfg_empty` and
  `axi_req_t = logic`), wired via extraFlistsByTarget/topByTarget on
  g6lc64_ooo_server — the only target with L3En=1.
- [x] Gate now refuses a configuration whose elaboration guards fire: `-Wno-fatal`
  demoted `%Warning-USERERROR` so g6lc64_ooo_server reported PASS while both hart/FP
  guards had fired. The remote lint counts them and fails: "remote refused: 2
  elaboration guard(s) fired". Default targets unaffected (8/54 warnings, pass).
- [x] RVFI CSR probe truncation repaired: `ariane.sv`'s DEFAULT `rvfi_probes_t` and
  `ariane_gate_tb.sv` declared `logic csr` while `cva6_rvfi_probes` assigns the whole
  CSR payload (5898 bits) to it. ariane_testharness already used the wide
  `rvfi_probes_csr_t`; the default and the gate-level bench now match it. Surfaced by
  the new uncore lint coverage; warnings 11 -> 10.
- [x] Uncore lint made usable: the only L3En=1 target is deliberately unsound, so
  gating the uncore on it could never pass. `g6lc_cluster_lint_top` clears OoOEn only
  (one field), keeping the full cache hierarchy, SMT and FP core legal and elaborating;
  the OoO backend keeps its own leaf suites and refusal checks. Remote lint: 2 warnings.
- [x] Tag reset elaboration blocker removed: the nested per-set/per-way reset loop is
  now a whole-array clear — behaviourally identical, but the loop form is unrolled per
  set and blew the synthesis frontend's budget at 512 sets. Re-gated: 60/60 direct with
  clean RR0/RR1 synthesis (`review-l2-tagreset-regate-v3`), 40/40 chained
  (`review-l2-tagreset-chain-v1`). One comment had to be reworded: a line beginning
  "Verilator" is parsed as a metacomment directive and failed the build.
- [x] Scenario 31 restricted to the cache-stack plan: it needs an outer cache to evict,
  so on the direct path its engagement check correctly failed and the default plan
  aborted. Chain-only now; default 60 records, chained 40.
- [ ] **Uncore synthesis smoke is nightly-scope, not per-change, and has NOT been
  observed to complete.** The route is correct (yosys confirmed running
  `read_slang ... --top g6lc_cluster_lint_top -DSYNTHESIS`) and both earlier
  elaboration blockers are gone, but a two-core cluster exceeded the 900s budget and
  was cut off mid-`proc`; at one core it was still running past ~30 minutes. Budget
  raised to 2400s and the synth smoke reduced to one core plus a smaller cache
  geometry under `SYNTHESIS` only. No pass is claimed for this stage.
- [ ] **Production-geometry synthesis remains open, not waived.** With L2 at
  262144 B / 8-way / 64 B line (512 sets) the tag module's per-set reset/maintenance
  loops (`g6lc_l2_tag.sv:105`) exceed the slang unroll budget: `Build failed: 2 errors`,
  `Design elaboration failed`. Verilator lints the same geometry fine. Root cause is a
  FLOP tag array (512x8 entries) where AGENTS 0.1/0.4 requires `tc_sram`; no leaf
  fixture could show it because they all used small geometries. Fix = tag array behind
  `tc_sram`, then re-run. Raising the tool limit is refused: it would hide a flop array
  in the production build and no mapped area/STA/power claim could rest on it.
- [x] corev_apu AXI 2-to-1 mux response ownership (DATA CORRUPTION, repaired): the
  core/Ara mux carries no ID remapping, so responses are routed purely by lock
  ownership, yet it released the lock whenever no request was momentarily valid —
  ignoring responses still owed. With any memory latency the core's read data was
  delivered to the vector unit and the core never got its beat
  (`review-mux-before-v2`: `MUX_R_MISROUTED port=0 got_id=3 want_id=5`). Separate
  read/write outstanding counters now hold the lock through RLAST/B, capping requests
  rather than wrapping. `review-mux-after-v1` 6 records, `review-mux-fault-v1`
  reproduces it. Reachable only under `CVA6_ARA_ATTACH`; port-0 priority starvation
  remains a known QoS limit.
- [x] Cross-core LR/SC ownership reviewed — **no defect** (negative result, recorded).
  The hart-local reservation in `hpdcache_uncached` is cleared only by that hart's own
  store/AMO; coherence invalidations reach the directory, not the reservation. That is
  sound because `g6lc_l2_top` forwards AxLOCK downstream to the exclusive monitor,
  which is authoritative — a stale-valid local reservation only lets the SC reach
  memory to be adjudicated, never grants one. Documented in
  `architecture/multi-core/README.md` because the question recurs.
- [x] RE-POINTED — `coh_sc_fail_o` -> `coh_sc_noresv_o` (tracker `sc_fail_o` ->
  `sc_noresv_o`), driven by a condition the hub genuinely observes: an SC-shaped store
  arriving with no matching reservation recorded for the storing core, evaluated
  against the pre-store state. Named "no reservation recorded here", NOT "SC failed" —
  the hub is not entitled to that claim (the downstream exclusive monitor is the
  authority), and a name implying it would repeat the over-reach of the dead signal.
  Probe port kept but documented unused. Renamed at all five live sites (tracker, hub
  port/tie-off/instantiation, cluster, tb_g6lc_coherence_hub, both wrappers in
  run_inval_review.py). Verified: uncore lint 4 warnings unchanged; hub reservation
  suite `review-hub-noresv-v1` 15/15.
- [~] (superseded) `coh_sc_fail_o` is hardwired zero: the hub ties `sc_probe_i = 1'b0`, so the
  tracker's `sc_fail_o` can never assert. AUDITED THE WHOLE SET: in gen_cluster,
  coh_inv_fire_o / coh_sf_hit_o / coh_sf_overapprox_o / coh_arb_starve_o /
  coh_split_conflict_o / coh_lr_kill_o are ALL genuinely driven — this is one dead
  signal, not a systemic gap. It also cannot be fixed by driving the probe: the hub
  does not adjudicate SC (g6lc_l2_top forwards AxLOCK to the downstream exclusive
  monitor by design), so the hub never learns an SC outcome. Options: retire the port,
  or re-point it at something observable here. Interface change => flagged in the RTL
  at the tie-off with the full reasoning, decision left to the owner.
- [x] Stale comment in `cva6.sv` corrected: it claimed "HPDCACHE/std paths ack and
  ignore" external L1 invalidations. HPDCACHE consumes them via the read-response
  inval port; only the std path ignores them. As written it read as "multi-core
  coherence is broken on HPDCACHE", which is what sent this review down a false trail,
  and `g6lc64_stream8` runs NrCores=2 with HPDCACHE_WT.
- [x] corev_apu snoop filter could hide a live sharer (STALE LINE, repaired): the hub
  gates invalidations with `sf_present & ~(1<<writer)`, and a capacity conflict forgot
  the displaced line's sharers — safe while untracked, but re-installing that line
  from one core's fetch produced a confident HIT naming only that core
  (`SF_SHARER_LOST must=01 targets=00 hit=1 over=0`), leaving the other core stale.
  Install over a different valid tag now starts all-present; a never-used index stays
  exact. `review-sf-after-v3` 5 records, `review-sf-fault-v3` reproduces. Live on
  stream8/ooo_server/server_math (COH_FILTERED + SnoopFilterEn=1).
- [ ] Follow-up: back-invalidate on snoop-filter displacement so forgetting sharers is
  sound and thrashed indices stay precise. Needs a new hub invalidation source with
  retention, or the repaired HUB_INV_LOSS defect returns.
- [x] Mux negative control STRENGTHENED (was: only required errors != 0, which a correct
  DUT cannot produce — it proved the harness complains about an absent error, not that
  the ID comparison catches a misroute). `+oracle_negative` now flips the OBSERVED
  response id so the routing check must fire: `review-mux-negctl-v2` 6 records ending
  `MUX_NEGATIVE_CAUGHT 2`, `review-mux-fault-v4` still reproduces the real defect
  (`MUX_R_MISROUTED port=0 got_id=3 want_id=5` + `MUX_R_LOST port=1`). Also fixed the
  diagnostic to print the COMPARED id: printing the raw one made the control's output
  read "got_id=3 want_id=3", which looks like a false alarm.
- [x] FINAL — the HPDCACHE invalidation hypothesis is REFUTED and my change is REVERTED.
  Two runs on the pre-change stream8 netlist passed; the second used a test where hart 1
  initialises LINE so hart 0's load provably misses and fills (`SUCCESS tohost=0`, 67100
  cycles), and every control word sits in a different cache set so no conflict eviction
  can refresh the copy. External invalidations ARE delivered.
  `core/cache_subsystem/cva6_hpdcache_subsystem.sv` restored to original; re-linted, 4
  warnings unchanged. Keeping an unvalidated edit that re-arbitrates the read-response
  channel on a working path would be pure risk. OPEN PUZZLE: the source-level
  `mem_resp_read_valid_i` gating still looks lossy and I cannot explain why it is not —
  that is a question to answer before anyone edits this path, not a defect.
- [!] (earlier) CORRECTION — the HPDCACHE invalidation defect is NOT REPRODUCED. The directed test
  ran on the pre-change stream8 netlist and PASSED (`SUCCESS tohost=0`, 57657 cycles):
  hart 0 observed hart 1's write. Fence-flush is ruled out (`DcacheFlushOnFence=0` on
  stream8). The likely flaw is my own test: hart 0 stores SEED then loads it back to
  "confirm" caching, and HPDcache can serve that load from the WRITE BUFFER without
  allocating a line — the check meant to prove the line was cached is what lets it not
  be. LINE must be initialised by something other than hart 0 before the caching load.
  The RTL change is retained but must NOT be counted as a repair. Original analysis
  below kept as a hypothesis:
- [~] HPDCACHE dropped external coherence invalidations (hypothesis, unvalidated): HPDcache
  samples `mem_resp_read_inval_i` only while `mem_resp_read_valid_i` is asserted (demux
  in hpdcache.sv, metadata FIFO write in hpdcache_miss_handler.sv) — correct for the
  L15 port where an inval IS a response beat, wrong for the AXI branch, which drove it
  from an independent external inval while reporting `inval_ready_o = 1'b1`. Every
  invalidation not coinciding with a read response was discarded and reported
  delivered. Now held in one slot and presented as its own beat in an idle arbiter
  cycle, retired on acceptance. Live on stream8 (NrCores=2), ooo_server, server_math.
- [x] Coverage finding: cacheable cross-core sharing was UNTESTED, which is why the
  HPDCACHE invalidation defect survived. The `mc_*` multicore tests are single-hart
  programs run under a multi-core config (`mc_cas_lock_handoff` CASes its own stack),
  and `ai_dual_core_excl_smoke` touches its shared line only via lr.d/sc.d (uncached),
  so a dropped cacheable invalidation cannot change its result. Added
  `verif/tests/custom/multicore/mc_shared_line_coherence.S` (hart 0 caches LINE with an
  ordinary load; hart 1 writes it and raises FLAG on a SEPARATE line so the spin
  cannot refill it; tohost=9 = stale) plus
  `verif/regress/remote/mc-shared-line-coherence.sh`.
- [x] Executed mc_shared_line_coherence on the pre-change netlist. The built model is at
  `/opt/testharness/work/work-ver-stream8/` (NOT in the repo checkout — my first check
  looked in the wrong place and wrongly concluded a build was needed). Result: PASSED,
  which contradicts the HPDCACHE hypothesis. See the correction above.
- [x] Test repaired (v2): hart 1 initialises LINE and hart 0 never writes it, so the
  caching load cannot be served by the write buffer. Five control words on five
  distinct cache sets. Ran on the pre-change netlist: PASS, 67100 cycles. The test is
  now a sound discriminator and is retained as the standing cross-core coherence
  check — it just has nothing to catch on this design.
- [!!!] RETRACTION + the real finding. My "the control was a different program" claim was
  itself an unvalidated instrument (RT-P1 / RT-H1 in the learning philosophy: validate
  before interpreting). Compiling the SAME source twice seconds apart gives different
  md5s (4e6a2d79… vs ef2f42d8…) — this toolchain embeds non-code content, so md5-of-ELF
  is NOT program identity. Disassembly md5 of mc2.elf (the 67100-cycle PASS), poll2.elf
  (the 1.2M-cycle hang) and a fresh compile are ALL 2e4409b189f6eebc3d8ccac8fb13424c —
  the same program. With the model binary also unchanged (5b487b85…), the actual finding
  is: SAME program + SAME binary => completion at 67100 cycles in one run and a hang past
  1.2M cycles in another. That is simulation NON-DETERMINISM. Leading hypothesis:
  X-initialisation / random-reset seeding — REFUTED: three consecutive runs of the same
  ELF with the same plusargs gave the identical verdict, identical 1200013 cycle count and
  identical warning at the identical cycle 240711. The sim is deterministic. Also learned:
  `+verilator+seed+N` is rejected by the HTIF arg parser before Verilator sees it, so seed
  control is unavailable at this boundary. THIRD hypothesis (files differ outside .text)
  also REFUTED: mc2.elf and poll2.elf are byte-identical in every loadable byte — same
  size 9832, zero section/program-header diffs, tohost at 0x80001000 in both, identical
  objcopy binary md5 8a6d40fd…. And mc2.elf, the file that once passed at 67100 cycles,
  now times out at 1200013 and at 600013 with the same terminal state, so +time_out is
  not the variable either.
  CONCLUSION: the current work-ver-stream8 model does not run ANY of these programs — it
  stalls in early boot at the same commit-dbg state (pc~0x80000074, cause=24) with the
  same g6lc_fetch_dbg assertion at the same cycle 240711, whichever ELF is loaded. That is
  a property of the model, not of a test. The earlier pass is unrecoverable: its model
  hash was never recorded, so whether the binary moved cannot be established now. That is
  the concrete cost of not pinning evidence.
  Scope of damage (philosophy §2.4): only results that depend on this simulator; leaf
  benches that hash their own sources, lint and synthesis are unaffected.
- [ ] Rebuild a g6lc64_stream8 model from a RECORDED source state and capture the model
  binary hash in the run record before any further coherence experiment. Every sim run
  record must carry: model-binary md5, ELF objcopy-image md5 (NOT the ELF file md5 —
  that embeds non-code content and differs between two compiles of the same source),
  plusargs, and the source commit/state.
- [x] ROOT CAUSE of the "early-boot stall": my invocation, not the model. `cause=24` is
  `riscv_pkg::DEBUG_REQUEST` — `ariane_testharness` defaults `debug_enable=1` on the DMI
  path, so a run without `+debug_disable` sits in a debug request. Adding it removes the
  cause=24 line. The canonical invocation (from testharness_proxy.py) is
  `+time_out=N +max-cycles=N +debug_disable +quiet_axi [+tohost=…] ELF`; I supplied only
  `+time_out`. That is also why `mc_boot_sanity.S` — which provably reached its store,
  stalling at the `j` AFTER the `sw` — never delivered tohost.
  `mc-shared-line-coherence.sh` now uses the canonical plusargs with a comment.
  Four of my conclusions in this episode were wrong in sequence (dropped invalidation,
  different program, non-determinism, broken model); every one came from an unvalidated
  instrument. Use the repo's runner instead of hand-rolling the harness command.
- [!] HARNESS VERDICT DEFECT (same class as the gate that passed over 8 SKIPs): with
  `+max-cycles` equal to `+time_out` — what testharness_proxy.py does — a run that never
  completes prints `*** SUCCESS *** (tohost = 0) after <bound> cycles` at EXACTLY the
  bound (verified at 200000 and 2000000). tohost reads 0 because nothing wrote it, so a
  hang is reported as a pass. With `+time_out` alone the same run reports
  tohost=2147483647, which is distinguishable. `mc-shared-line-coherence.sh` now omits
  `+max-cycles` and rejects a SUCCESS that lands on the bound as VACUOUS.
  NARROWED after reading the proxy: its `di` SUITE path ALREADY guards this correctly —
  it accepts a SUCCESS only when `rvfi_tracer ... Simulation terminated` is also
  present, else `verdict=FAIL reason=timeout`, and it runs mini_must_pass /
  mini_must_fail oracle controls first. The file even documents this exact defect
  shipping on 2026-08-31. So suite results are NOT suspect; the exposure is the simpler
  `run` path plus any human reading a raw SUCCESS line — which is how I was fooled.
- [x] Also established: `+tohost=<addr>` is NOT a valid plusarg (rejected with the usage
  banner), and a bare-metal ELF that stores to tohost and spins is not observed even
  with +debug_disable and a fence. The repo's review runners use `-m <cycles> -s 1
  +debug_disable` and check in-memory cookies instead of tohost — use those.
- [x] RESOLVED — the idle-observer question is ANSWERED. Missing plusarg was
  `+tohost_addr=0x…` (the proxy derives it from the ELF via nm), alongside
  `+debug_disable`. With `+time_out=400000 +debug_disable +quiet_axi
  +tohost_addr=0x80001000`: mc_boot_sanity SUCCESS 364 cy; mc_shared_line_coherence
  (polling) SUCCESS 773 cy; mc_shared_line_quiet (IDLE observer) SUCCESS 240698 cy —
  all terminating EARLY inside the 400000 bound and all carrying the
  `rvfi_tracer ... Simulation terminated` marker, so none is the vacuous
  SUCCESS-at-the-bound. The quiet run's 240698 cycles matches its 60000-iteration
  register-only wait, which proves the window was genuinely traffic-free.
  => HPDcache delivers external invalidations, and delivery does NOT depend on the
  observing hart's own memory traffic. The revert was correct. Mechanism by which the
  pulse survives the `mem_resp_read_valid_i` gate is still untraced — open question,
  not a defect.
  CAVEAT, not buried: the conclusion assumes hart 0's load ALLOCATED the line. The test
  forces that load to miss (hart 1 wrote the value, hart 0 never did) and read-allocate
  is standard, but I have not verified residency independently in this config. If the
  D-cache never held the line, BOTH the polling and idle tests pass vacuously.
- [~] Residency check built (`mc_shared_line_resident.S`) — makes the coherence verdict
  conditional on demonstrated residency. Two measurement lessons, both recorded in the
  test: (1) single-load timing is useless here — a csrr/ld/csrr window costs 16 cycles
  whether or not the line is resident, because csrr is serialising (measured: first=16,
  reload=16); (2) amortised over 64 same-line loads the cost is 791 cycles = 12.4/load,
  which is ambiguous because ~4-6 of that is loop overhead on an in-order core.
  BASELINE ADDED, and it kills the method: 64 loads of DISTINCT never-touched lines
  cost 779 cycles vs 793 for 64 loads of the same line — identical, with the
  guaranteed-miss loop marginally CHEAPER. On this model a miss costs no more than a
  hit, so TIMING CANNOT DETECT RESIDENCY. Not a threshold-tuning problem: the
  instrument has no resolution, which is what the baseline existed to reveal (a guessed
  constant would have "proved" either answer). Code 13 now means "residency unproven",
  never "not resident".
  ARCHITECTURAL INSTRUMENT TRIED AND IT IS BROKEN: mhpmevent legacy index 2 ("L1
  D-Cache misses") in mhpmcounter3 reads 0 misses across 64 GUARANTEED misses. The test
  reported code 15 ("counter not wired") instead of mistaking a dead counter for a
  resident line. POSITIVE CONTROL (`mc_pmu_control.S`, same program, event index 5 =
  load accesses): 64 and 64, exactly REPS per loop — so the CSR path, event programming
  and counter reads are all correct and the zero belongs to the event.
- [x] Tested and ELIMINATED my own innocent explanation for the zero: hpdcache excludes
  prefetch-driven allocations from the event (`evt_cache_read_miss_o =
  ~st2_mshr_alloc_is_prefetch_i`, hpdcache_ctrl_pe.sv), and my baseline walked a
  perfectly sequential BASE+i*64 stride — ideal prefetcher bait, so a HEALTHY counter
  could legitimately read 0. Re-ran with a shuffled walk (step 37 lines mod 64, every
  line once, no constant delta): STILL 0. Prefetch exclusion does not explain it.
- [!!!] ROOT CAUSE FOUND — the PMU event is NOT broken; that claim is WITHDRAWN. In
  `cva6_hpdcache_if_adapter.sv:94` a load is uncacheable if
  `!is_inside_cacheable_regions(...) || is_inside_execute_regions(...)`. On stream8 the
  ExecuteRegion (0x8000_0000 +0x4000_0000) is IDENTICAL to the CachedRegion, so EVERY
  DRAM load is uncacheable and the L1 D-cache holds NO DRAM data. One fact explains the
  whole chain: 0 miss events (nothing allocates an MSHR), no timing difference between
  same-line and distinct-line loops (all loads go to memory), and 64 D$ ACCESSES counted
  (requests reach the cache and bypass it).
- [!!] CONSEQUENCE — the cross-core coherence results are VACUOUS. Hart 0 never held the
  line, so "the idle observer saw the remote write" shows only that it read memory; it
  says nothing about invalidation delivery, busy or idle. The residency caveat I flagged
  earlier turned out to be the entire story. mc_shared_line_* cannot test coherence on a
  config where D-cache allocation is off for DRAM.
- [x] Attempted the source fix for the I$/D$ aliasing; RULED OUT the leading mechanism
  and fixed a real guard weakness found on the way. Candidate was response-ID aliasing:
  the arbiter demuxes read responses purely by id
  (`mem_resp_read_rt[i] = (i == icache_miss_id_i) ? 0 : 1`), so a D$ read carrying
  ICACHE_RDTXID would have its refill delivered to the I$ and hang the load. Ruled out
  for shipped configs: the bound `MEM_TID_WIDTH >= clog2(mshrSets*mshrWays)+1` reserves
  the MSB for the I$; stream8 needs 4/has 4, ooo_server needs 6/has 8. So this is NOT
  the 2jr mechanism and the real aliasing hazard REMAINS UNIDENTIFIED — not changing a
  load path on a guess.
  FIXED ANYWAY: that bound lived under `pragma translate_off`, so a violating config
  would SYNTHESIZE and hang silently. Promoted to generate-scope $error (same treatment
  as the OoO hart/FP guards). Verified BOTH ways: MemTidWidth 8->5 on ooo_server =>
  "remote refused: 1 elaboration guard(s) fired"; restored => pass, 4 warnings. Margin
  is ZERO on stream8 (needs 4, has 4) — NrLoadBufEntries=16 would have aliased silently.
- [x] RESOLVED — 2jr mechanism IDENTIFIED and the execute-region exclusion REMOVED.
  It was never a cache hazard: it is a bind-attached frontend checker reading the wrong
  signal. `kill_s1` is driven from replay_q (frontend.sv:820) while g6lc_fetch_dbg was
  bound with `.replay_i(replay)` — the combinational one. One cycle after replay drops,
  replay_q still holds kill_s1 high and replay_i reads 0, so a legal replay-kill trips
  "kill_s1 outside misp|flush|replay" and the sim aborts. FIX: bind `.replay_i(replay_q)`.
  THREE-ARM EVIDENCE (g6lc64_stream8, flavour B, arms differ only as stated):
    exclusion ON                  2jr/_pad/_data PASS 534/491/501 cy
    exclusion OFF, checker as-was all three ASSERT
    exclusion OFF, checker fixed  all three PASS 545/497/519 cy
    mc_boot_sanity PASS 359 cy in ALL THREE arms => arms otherwise equivalent (control)
  Execute-region term removed from cva6_hpdcache_if_adapter.sv => L1 D$ load allocation
  for DRAM is restored on every HPDCACHE config (it had been disabled wholesale to dodge
  a checker bug). `G6LC_DCACHE_EXEC_UNCACHED` restores the old behaviour for bisection.
  BREADTH: whole mini_hpd_* family + sanity tests on the default build, 22 pass / 0 fail,
  each requiring SUCCESS *and* the rvfi terminated marker. Default lint 8/54 unchanged.
  STILL OWED: a full regression before release — this changes D$ allocation behaviour on
  every HPDCACHE configuration.
- [x] RETRACTED + CORRECTED — core 1 DOES execute. My "second core never executes" claim
  below is WRONG; it rested on a silent verdict with no instrument that could see the
  DUT. Repaired the instrument first: CVA6_MC_PC_PROBE prints c1.npc but would not
  compile — stale hierarchy (`i_cva6_icache` -> `i_g6lc_icache`, 5 renames). With it:
    c1.npc: 0x10000 -> 0x10014 -> 0x8000001c -> 0x8000002c
  Core 1 is elaborated (102 generated files name gen_core__BRA__1), runs the bootrom,
  jumps to DRAM and executes the test. Disassembly of mc_hart1_alive.S: 0x80000024 is
  `sw a0,0(t0)` to tohost, 0x80000028 the fence, 0x8000002c the park loop AFTER both —
  so core 1 RETIRED the store. Probe also shows l2a=0x80001000 (the store's address at
  the L2), so it propagates that far.
- [!!! P0] CROSS-CORE COHERENCE IS BROKEN, and the D$ execute-region exclusion was MASKING
  it. This VINDICATES the original HPDCACHE invalidation concern I twice withdrew: it was
  withdrawn as "vacuous" because the L1 D$ held no DRAM data — true at the time — and the
  defect appears the moment D$ load allocation is restored.
  TEST: `mc_hart1_store_visible.S` separates property from reporting channel — hart 1
  stores a cookie to a shared cache line, HART 0 (whose tohost writes work) loads it and
  reports. code 1 = observed, code 9 = never observed.
  ONE-VARIABLE CONTROL, both flavour B, same source, differing only by
  G6LC_DCACHE_EXEC_UNCACHED:
    work-ver-s8-b-uncached (exclusion ON,  D$ alloc OFF) => SUCCESS 6449 cy  (observed)
    work-ver-s8-b-retired  (exclusion OFF, D$ alloc ON)  => code 9  320416 cy (NEVER)
    production work-ver-stream8 (exclusion ON)           => SUCCESS 8448 cy
  With the D$ actually caching DRAM, hart 0 polls a stale zero forever: hart 1's store
  never invalidates hart 0's copy.
- [!!] THE EXECUTE-REGION DECISION REVERSES ORDER. Removing the exclusion is still right
  for performance and the 2jr checker fix still stands, BUT the exclusion was also an
  unintended CORRECTNESS crutch: uncached DRAM loads make stale copies impossible, hiding
  the coherence defect. Required order: (1) fix cross-core invalidation delivery, THEN
  (2) remove the exclusion. Shipping (2) without (1) turns a performance problem into a
  correctness one. G6LC_DCACHE_EXEC_UNCACHED exists to restore the safe behaviour while
  (1) is in progress.
- [x] MECHANISM TRACED END TO END — the original source analysis was RIGHT. Every link
  checked, not assumed: (1) hub generates the target set (COH_FILTERED + SnoopFilterEn,
  `sf_present & ~(1<<aw_winner)`; SF allocates on `aw_fire | ar_fire` at
  g6lc_coherence_hub.sv:509, so core 0's polling load DOES register as a sharer);
  (2) inval_bus -> l1_inv_adapter -> l1_inval_valid_i; (3) cva6.sv:2127-2129 forwards it
  to the HPDCACHE subsystem (the std branch by contrast ties inval_ready=1 and drops —
  the distinction the corrected comment records); (4) subsystem AXI branch sets
  `dcache_resp_read_inval = inval_valid_i` with `inval_ready_o = 1'b1`;
  (5) **hpdcache.sv:1132 DROPS IT** —
      always_comb begin : mem_resp_read_demux_comb
        mem_resp_read_miss_valid = 1'b0;
        if (mem_resp_read_valid_i) begin        // THE GATE
          mem_resp_read_miss_valid = 1'b1;      // only ever set inside it
      assign mem_resp_read_miss_inval = mem_resp_read_inval_i;  // payload unconsumed
  `mem_resp_read_miss_valid` is what makes the miss handler act on the response AND its
  invalidation payload, and it is asserted ONLY while a read response is concurrently
  valid. So an external invalidation arriving with no D$ read response in flight is
  ACKNOWLEDGED AND SILENTLY DISCARDED — and `inval_ready_o = 1'b1` is the lie that makes
  it silent. An idle observer (exactly the failing case) never has a read response in
  flight.
- [x] FIX APPLIED AND VERIFIED — cva6_hpdcache_subsystem.sv AXI branch: one-entry retention
  holds the external invalidation until HPDCACHE consumes it, and inval_ready_o now
  reports REAL occupancy instead of unconditional acceptance:
    inv_inject             = ext_inv_pend_q & ~axi_rresp_valid;   // real response wins
    dcache_read_resp_valid = axi_rresp_valid | inv_inject;
    dcache_resp_read_inval = inv_inject;
    axi_rresp_ready        = dcache_read_resp_ready & ~inv_inject;
    inval_ready_o          = ~ext_inv_pend_q;
  Two points settled from SOURCE, not intuition: (1) an invalidation-only response is a
  FIRST-CLASS case in hpdcache_miss_handler.sv — it is how the OpenPiton/L15 port
  delivers invals at all: meta FIFO written on mem_resp_inval_i regardless of r_last,
  data FIFO explicitly NOT written (& ~mem_resp_inval_i), mem_resp_ready_o from meta
  space alone, REFILL_IDLE routes is_inval to REFILL_INVAL without touching the MSHR
  (mshr_ack = ~is_inval) — so the injected cycle needs no data/r_last/MSHR; (2) an inval
  must OWN its cycle, because is_inval diverts the FSM INSTEAD of refilling, so
  piggybacking would DROP the refill. One entry suffices BECAUSE the producer is now
  back-pressured rather than lied to.
  VERIFIED against the criterion committed BEFORE writing the fix:
    exclusion removed, unfixed        => code 9  @320416 cy (never observed)
    exclusion removed + retention fix => SUCCESS  @6471 cy  (OBSERVED)
    exclusion present (uncached ctl)  => SUCCESS  @6449 cy
  Fixed cached arm matches the uncached arm's latency (6471 vs 6449) — the signature of
  an inval that lands promptly. Breadth on the fixed build 22 pass / 0 fail; lint 8/54
  unchanged. This also UNBLOCKS the execute-region removal: step 1 (invalidation) is now
  done, so keeping D$ allocation no longer trades performance for correctness.
  BACK-PRESSURE NOW MEASURED — `mc_two_inval_backpressure.S`: hart 0 caches TWO lines
  (different sets, so no eviction/conflict refill can refresh either), waits in a
  register-only loop (no read response to ride on), and hart 1 writes both lines
  back-to-back with no fence between. Distinct codes (9 = A stale, 11 = B stale) so a
  dropped SECOND inval is distinguishable from a broken first.
    invfix   => SUCCESS (both observed) 60569 cy
    retired  => code 9 (A stale)        60561 cy  <- first inval already dropped, so
                                                     this arm never reaches the
                                                     back-pressure case
    uncached => SUCCESS                 60519 cy
  INSTRUMENTED (translate_off counters + final block in cva6_hpdcache_subsystem.sv:
  `injected` = invals delivered on a stolen response cycle, `backpressured` = cycles the
  producer was held off with the slot full):
    store-visible                      SUCCESS  6471 cy  injected=1      backpressured=0
    two invals, idle observer          SUCCESS 60569 cy  injected=2 / 4  backpressured=0
    miss-streaming observer, 4 writes  SUCCESS 37573 cy  injected=4 / 6  backpressured=0
    (mc_inval_bp_stress.S — observer walks 256 KiB so the response channel stays busy
     and injection is deferred, which is the only condition that keeps the slot full)
  GOOD: `injected` non-zero on both cores in every run => the injection path is really
  exercised; direct evidence for the MECHANISM, not just the outcome.
  NOT GOOD: `backpressured` = 0 EVERYWHERE, including the stress test => the one-entry
  depth's OVERFLOW PATH REMAINS UNPROVEN. Could not provoke it from software. Likely
  because g6lc_inval_bus already buffers INVAL_DEPTH per core
  (COH_DEFAULT_INVAL_DEPTH = 4, g6lc_coherence_pkg.sv:12), so the slot sees a drip not
  a burst.
  CLOSED — retention EXTRACTED to core/cache_subsystem/g6lc_inval_retain.sv (named unit,
  explicit contract, own assertions, DEPTH parameter; subsystem instantiates DEPTH=1).
  Extraction is behaviour-identical: the three full-core tests return the SAME cycle
  counts (6471 / 60569 / 37573) and the same counters as the inline version.
  UNIT BENCH verif/tb/uncore/tb_g6lc_inval_retain.sv drives producer + response channel
  directly so the slot can be held full. Checks conservation (exactly once, in order),
  honest backpressure, and "a real response always wins" (asserted: piggybacking would
  divert the FSM to REFILL_INVAL and DROP a refill).
    DEPTH=1 (SHIPPED) 3/3 pass, negative caught, backpressured=11
    DEPTH=2           3/3 pass, negative caught, backpressured=10
    DEPTH=4           3/3 pass, negative caught, backpressured=8
  => overflow path FINALLY EXERCISED, including at the shipped depth, nothing lost,
  order preserved. Scenario 1: emitted=0 while the channel is busy. Scenario 2: drains
  under toggling ready without loss.
  WIRED INTO A REVIEW RUNNER: verif/regress/remote/run_retain_review.py — hashes inputs,
  records the Verilator version, sweeps DEPTH 1/2/4 x scenarios 0/1/2, runs the negative
  control at every depth, and REFUSES a scenario-0 run reporting backpressured=0 (a
  verdict without back-pressure has not tested the overflow path). Plus an RTL FAULT arm
  (REVIEW_RETAIN_FAULT=1) restoring the ORIGINAL defect `inval_ready_o = 1'b1`:
    clean arm  12/12 matched, faultDetected=[] (correct), noBackPressure=[]
    fault arm  12/12 matched, detected at (1,0)(1,2)(2,0)(2,1)(2,2)(4,0)(4,1)
    source hashes differ (b4720bf2 vs 83d99bdd) so the arms are attributable; at
    DEPTH=1 the bench reports RETAIN_LOSS accepted=12 emitted=0 — the exact P0.
  RUNNER NOW SELF-SUFFICIENT: resolves inputs from the repo when nothing is staged, so
  it runs standalone on the builder over plain ssh. It previously needed the `remote py`
  wrapper, which blocks the local CLI for the whole run and costs a round trip per arm;
  both arms now finish in ONE invocation in ~15 s.
  THREE RUNNER LESSONS, all the same mistake in different clothing — an over-narrow
  criterion making CORRECT behaviour look like failure: (a) it demanded EVERY scenario
  detect the fault, but scenario 1 legitimately cannot (its check is unaffected by
  unconditional ready) — a fault control must assert the SUITE catches it, not every
  case; (b) it looked only for RETAIN_ERRORS, while at DEPTH>1 the unit's OWN assertion
  fires first — a detection counted as a miss; (c) it labelled the negative control's
  intentional errors as faultDetected, making the clean arm's results.json read as
  though good RTL had faults. `reported` and `detected` are now distinct.
  TWO BENCH LESSONS: (1) DEPTH made overridable (-GDEPTH) so the SHIPPED depth is
  qualified, not a friendlier one — it began as a localparam testing only DEPTH=2;
  (2) the NEGATIVE CONTROL WAS INERT AT DEPTH=1 because it perturbed the SECOND
  accepted entry and only one is ever accepted there (measured negative_caught=0 at
  DEPTH=1 vs 1 at 2/4). Now perturbs the first. Same failure mode this review keeps
  meeting: a control that cannot fail where it matters most — visible only because the
  depths were swept rather than assumed.
  (superseded) HONEST LIMIT: this proves both invals land; it does NOT prove the slot was OCCUPIED
  when the second arrived (adjacent stores to an idle target make it likely, not
  certain). Closing it needs instrumentation, not a verdict: an assertion that
  `inval_valid_i & ~inval_ready_o` is seen at least once, or a count of inv_inject
  events. Retention depth is currently justified by the handshake argument plus this
  end-to-end pass, not by a measured collision.
  RE-QUALIFIED the three original tests on the fixed build — ALL PASS, and the per-core
  `injected` counter separates the two delivery paths for the first time:
    mc_shared_line_coherence (polling)  SUCCESS 25661 cy  injected=0
    mc_shared_line_quiet     (idle)     SUCCESS 25422 cy  injected=4
    mc_shared_line_resident             SUCCESS 25156 cy  injected=3
  => the POLLING observer needs ZERO injections (its own refill traffic carries the
  invalidations — the exact "rescue" mechanism hypothesised earlier and then retracted
  for being consistent with both a working and a broken design); the IDLE observer needs
  4, because it has no read responses to ride on, so the retention path is what delivers
  them. And mc_shared_line_resident passing means its RESIDENCY GATE NOW PASSES, so
  residency is MEASURED at last — that gate could never pass before because the D$ held
  no DRAM data (same root cause).
  Three items asserted/retracted/left-open across this file — idle-observer delivery,
  polling self-rescue, and line residency — are now settled by ONE consistent set of
  measurements.
  REGRESSION RUN for this change:
    lint stream8 / ooo_server / server_math   PASS (7 / 4 / 7 warnings)
    synth of g6lc_inval_retain (yosys-slang)  PASS — 8 cells (2 $_DFFE_PN0P_, 2 ANDNOT,
                                             2 AND, NOT, OR), NO latch cells,
                                             check -assert 0 problems
    full-core sim mini_hpd_* + sanity         21/21
    full-core sim 3 cross-core tests          all pass
    unit bench both arms                     12/12 each
    whole-cluster synth (ooo_server)          KILLED exit 137 (SIGKILL) after ~16.5 min
  The cluster-synth failure is PRE-EXISTING, not this change. BUT MY FIRST EXPLANATION OF
  IT WAS WRONG and is corrected here rather than quietly fixed: I called it an OOM on a
  30 GiB host. The builder actually has 12 CORES AND 125 GiB (116 free), and the failures
  are DEADLINES, not crashes — cut at 900s, then exit 137 at ~994s, then exit 255 at 2412s
  against a 2400s budget. The route is SLOW, not broken.
  THREE CHANGES CAME OUT OF THAT:
   (1) MEASUREMENT so the next failure is attributable: each target's yosys now runs under
       /usr/bin/time and its peak RSS + elapsed ride out on the RESULT line. A run that
       dies otherwise leaves nothing to tell an OOM from a deadline — exactly how the first
       diagnosis went wrong.
   (2) PARALLELISM, WITH AN HONEST LIMIT: per-target runners launch via
       `xargs -P $(nproc)`, so a MULTI-TARGET sweep saturates the builder instead of
       costing N x one target. A SINGLE cluster target CANNOT saturate 12 cores — yosys is
       single-threaded. Splitting the cluster into independently synthesised submodules is
       what would, and is the real answer if per-change cost matters.
   (3) budget floor raised to 5400s so the route can complete at least once (run in
       flight at the time of writing).
  BUG IN MY OWN CHANGE, recorded: the per-target runners use a QUOTED heredoc so the yosys
  command text survives verbatim, but the child bash inherits the ENVIRONMENT and not plain
  shell variables — so they ran with an empty $RUNROOT/$YS and emitted no RESULT line. The
  gate then said "no RESULT lines ... check the proxy credentials", a misleading way to
  spell "the script I generated was broken". Fixed by exporting REPO/RUNROOT/YS/TIMEW.
  VERIFIED: g6lc64_stream8 synth PASSES clean in ~178s (36 warnings).
  BUT THE SYNTH STAGE CAUGHT A REAL DEFECT OF MINE that lint missed: I declared
  axi_rresp_valid/ready and axi_rresp AFTER the arbiter instantiation that consumes
  them. Verilator tolerates that use-before-declaration; yosys-slang correctly rejects
  it ("identifier 'axi_rresp_ready' used before its declaration"). => A Verilator-clean
  build is NOT evidence of SystemVerilog conformance, and the synth stage is not
  redundant with lint even when both merely elaborate. Declarations moved to the top of
  the AXI branch.
  PER-SUBMODULE PARALLEL UNCORE SYNTH now built:
  verif/regress/remote/run_cluster_synth_review.py synthesises 10 major uncore tops
  CONCURRENTLY (10 yosys at once, ~0.13s each) against a genuinely FLAT manifest — it
  expands ALL THREE variables (CVA6_REPO_DIR, TARGET_CFG, HPDCACHE_DIR) and INLINES
  nested -F includes recursively, because slang expands nothing itself. Three bugs on
  the way, each with a misleading symptom: (a) raw flist => "unknown class or package
  'cva6_config_pkg'" (corev_apu/Flist.cluster is an ADDITION to core/Flist.cva6 and
  carries no config package); (b) unexpanded HPDCACHE_DIR => "'/rtl/hpdcache.Flist': No
  such file" — the EMPTY PREFIX is the tell; (c) the same variable AGAIN inside the
  nested hpdcache.Flist, one level deeper.
  TYPED LINT TOPS ADDED (verif/tb/g6lc_uncore_lint_tops.sv, on corev_apu/Flist.cluster):
  hub / inval_bus / snoop_filter / axi_2to1_mux, each binding CONCRETE ariane_axi structs
  and NR_CORES=2 + SF enabled so the interesting logic stays alive.
  FINAL RESULT 10/10 with real cell counts, 0 latches everywhere (typed tops added for
  l2_top/l3_top/server_prefetcher too, the first two with the SYNTHESIS geometry shrink
  the cluster top already needs):
    l3_top        7640 cells  2.0 GB  278 s   <- at a SHRUNK 32 KiB geometry
    l2_top        4660 cells  682 MB   46 s   <- at a SHRUNK 16 KiB geometry
    coherence_hub 1236        213 MB  5.4 s
    snoop_filter   582        186 MB 14.6 s
    prefetcher     368   inval_bus 250   mux 80
    lr_sc_tracker   49   inval_retain 31  l1_inv_adapter 3
  Wall time is set by the SLOWEST module, not the sum: ~5 min for the whole suite
  against a cluster route that never finished in 40.
  THESE NUMBERS EXPLAIN THE CLUSTER FAILURE: l3_top alone costs 2.0 GB / 278 s at a
  shrunk geometry, l2_top 682 MB at 16 KiB, and the cluster elaborates BOTH plus two
  full cores at once. The deadline overruns are the direct cost of ~3.4 Mbit of tag
  state built from FLOPS — the strongest argument yet for the standing tc_sram
  migration: it is not only area, it is WHY there is no whole-cluster synth evidence.
  (superseded) 7/10 with real cell counts, 0 latches everywhere:
    coherence_hub 1236 cells (5.4s)   snoop_filter 582 (13.6s)
    inval_bus      250               axi_2to1_mux  80
    lr_sc_tracker   49               inval_retain  31      l1_inv_adapter 3
    still missing: l2_top, l3_top, server_prefetcher (need typed tops; they will also
    need the cluster top's SYNTHESIS geometry shrink, because the behavioural tc_sram
    model cannot elaborate at production geometry in the synth frontend)
  THE COUNT WENT 6 -> 3 -> 7, and both corrections were MY OWN vacuous passes:
   (1) rc=0 with ZERO cells — at NR_CORES=1 the hub/inval_bus/snoop_filter collapse to
       their degenerate path, so "success" meant nothing synthesised. `cells > 0` became
       part of the criterion; 6 dropped to 3.
   (2) TIE-OFFS DELETE THE DESIGN — my first typed wrappers tied every input to a
       constant and left outputs dangling, so `opt` removed everything as unreachable:
       stat showed wires and ports and NO CELLS while the run reported rc 0 / no
       latches. A vacuous pass MANUFACTURED BY THE HARNESS rather than found in the RTL.
       Wrappers now PASS THROUGH the DUT interface; the counts appeared immediately.
  The discriminating evidence for (2) was the resource measurement I had added earlier:
  213 MB / 5.4 s for the hub vs 64 MB / 0.12 s for a run that genuinely did nothing.
  `cells > 0` is a weak criterion — it cannot separate correct from partly-optimised —
  but it is exactly strong enough to catch "this proved nothing".
  (superseded) HONEST RESULT: 3/10, not the 6/10 I first reported.
    genuine (rc0, no latches, cells>0): lr_sc_tracker 49, inval_retain 31,
                                       l1_inv_adapter 3
    VACUOUS (rc0 but ZERO cells):       coherence_hub, inval_bus, snoop_filter
    error (needs a typed wrapper):      l2_top, l3_top, server_prefetcher,
                                       axi_2to1_mux
  The vacuous three have ports typed via `parameter type axi_req_t = logic`, so with the
  default parameter their generate branches collapse and NOTHING is synthesised — rc=0
  with 0 cells. `cells > 0` is now part of the pass criterion. The four errors are the
  same cause made visible: "invalid member access for type 'axi_resp_t' (aka 'logic')".
  => 7 OF 10 UNCORE MODULES STILL HAVE NO STANDALONE SYNTH EVIDENCE; the specific
  remaining work is a typed lint wrapper each, in the style of g6lc_cluster_lint_top.
  NOTE ON MYSELF: I reproduced this review's favourite failure mode — a vacuous pass —
  in my own runner, and only caught it because cells=0 looked wrong beside
  lr_sc_tracker's 49.
  STILL OWED: the whole-cluster synth route must complete somewhere before any
  area/timing claim.
- [~] (superseded by the applied fix) FIX DIRECTION (not applied — must be verified against the reproduction; the earlier
  attempt was reverted for want of one): retain the external invalidation until the miss
  handler consumes it (one-entry hold or small FIFO) and drive `inval_ready_o` from REAL
  acceptance instead of tying it to 1. ACCEPTANCE CRITERION, concrete: on the
  exclusion-removed arm `mc_hart1_store_visible.S` must flip from code 9 (320416 cy) to
  code 1, while the uncached arm keeps passing and mini_hpd_* breadth stays 22/0.
- [x] RESOLVED — "core 1's committed store never reaches polled memory" was a HARNESS
  artifact, not a lost write: the uncached arm passes in 6449 cy, so the store IS
  globally visible. The TB polls the DRAM array while the write sits in a write-back L2.
  tohost from hart 1 is not a reliable reporting channel; report via hart 0.
- [~] (superseded) REAL DEFECT TO CHASE: a COMMITTED STORE FROM CORE 1 NEVER BECOMES VISIBLE IN
  POLLED DRAM, while the identical store from core 0 does. The TB reads the DRAM array
  directly, so a write parked dirty in a cache — or lost in the hub write path — is
  invisible. The coherence hub is the only structural difference between the two cores'
  write paths, and it is in scope. Two-hart handshakes through memory cannot be
  interpreted until this lands.
- [x] OBSERVABILITY GAP CLOSED FOR VISIBILITY (not for verdicts). ariane_testharness.sv now
  instantiates a cva6_rvfi + rvfi_tracer per SECONDARY core, fed by tapping the
  cluster's per-core probe array hierarchically from the TB — chosen over widening
  `rvfi_probes_o` to an array because that scalar is consumed by ariane.sv, the
  Xilinx/Altera tops, ariane_gate_tb and the APU benches, and a missing pin is an error
  here (%Error-PINMISSING), so widening forces a change at EVERY instantiation.
  DESIGN: secondary tracers OBSERVE, never terminate — core 0's tracer_exit drives
  rvfi_exit and thus simulation end, so end_of_test_o is left open on the secondaries.
  HART_ID = c * NrHarts to match the cluster's mhartid derivation.
  VERIFIED: store-visibility run gives trace_rvfi_hart_00.dasm 6084 instructions and
  trace_rvfi_hart_01.dasm 8072 — core 1's stream visible for the first time; verdict
  unchanged (SUCCESS 6471 cy) and exactly ONE "Simulation terminated" marker, so the
  classifier contract is intact. Build clean, 8 warnings.
- [x] VERDICT NOW MULTI-CORE AWARE (no array-port change needed). Criterion: EVERY
  instantiated core must retire >=1 instruction by the time core 0 declares the test
  over; a violation forces exit code 127 through exit_o, the channel the C++ side already
  turns into the verdict. Deliberately the WEAKEST useful criterion: an idle park is
  indistinguishable from a hang without test-specific knowledge, so requiring progress
  would fail legitimate tests while requiring "it ran at all" cannot. Safe everywhere
  here because the bootrom sends ALL harts to DRAM_BASE (even single-hart tests execute
  the mhartid check per core); vacuous at NR_CORES==1.
  VERIFIED BOTH WAYS (a verdict never seen to fail == a verdict that cannot fail):
    normal                 SUCCESS + "[mc_verdict] all 2 core(s) retired instructions"
    +mc_verdict_fault      FAILED (tohost = 127), retired_mask=01
    breadth mini_hpd_*+sanity  21/21 pass, each also requiring the mc_verdict line
    three cross-core tests     all SUCCESS
  THREE GOTCHAS: (a) `rvfi_instr[N-1:0].valid` is ILLEGAL (no range on the instance part
  of a dotted reference) — use an explicit reduction loop; (b) the plusarg MUST be
  allowlisted in g6lc_tb.cpp or HTIF rejects it and the run dies, which looks exactly
  like the control working while the verdict was never exercised; (c) the diagnosis had
  to move to a `final` block — the C++ side leaves its loop the moment exit_o[0] is set,
  so the first version exited 127 with NO REASON PRINTED.
  STILL NOT COVERED: a secondary core that runs and THEN hangs while core 0 finishes.
  Needs per-core liveness windows or test-declared expectations; both risk failing
  legitimate idle parks, so left open rather than guessed.
- [~] (superseded) OBSERVABILITY GAP that hid all of this: `g6lc_cluster.sv:221` is
  `assign rvfi_probes_o = core_rvfi[0];` — the cluster forwards ONLY CORE 0's RVFI
  probes. Every trace-based check, including the suite classifier's
  "rvfi_tracer ... Simulation terminated" marker that this review treats as the gold
  standard, is blind to core 1 by construction. AGENTS.md 0.1(6) exists to prevent
  exactly this.
- [x] Fixed the TB multi-core PC probe (was the top multi-core item): 5 stale
  `i_cva6_icache` paths renamed to `i_g6lc_icache`; CVA6_MC_PC_PROBE_COMPILE builds
  clean (0 warnings, 0 errors) and produced every result above.
- [~] (WRONG, superseded) THE SECOND CORE NEVER EXECUTES — every two-hart result in this repo is vacuous.
  Probed directly instead of inferred: `mc_hart1_alive.S` inverts the roles so hart 0
  parks in a plain loop and ONLY hart 1 writes tohost; `mc_hart1_trap.S` makes hart 1's
  FIRST instruction a deliberate `unimp`, so even one fetched instruction would publish
  32+((mcause<<1)|1) via the trap handler. Results on BOTH work-ver-s8-b-retired and
  production work-ver-stream8: watchdog 2147483647 for all three variants (wfi park,
  plain-loop park, trap). => hart 1 does not execute a single instruction; store
  visibility and wfi are both ruled out.
  CONSEQUENCES: every two-hart test in verif/tests/custom/multicore/ has been passing on
  hart 0 alone, including the polling/idle-observer coherence results (already withdrawn
  for the D$-allocation reason — this is a SECOND independent reason). The old 773-cycle
  "polling observer" pass is explained: that version had hart 0 write the seed itself.
  No cross-core invalidation / snoop-filter / LR-SC claim can be supported by full-core
  sim on this config until core 1 boots.
  RULED OUT: bootrom (sends ALL harts to DRAM_BASE, parking deliberately removed; .sv
  newer than .S, commit "Sync the generated bootrom with its source"); BOOT_HOLD gating
  ((NC>1 && NrHarts>1) is false for stream8); boot address (PerCoreBoot only under
  G6LC_APU, both cores take ROMBase). WITHDRAWN: my "npc=0x0 means secondary boot
  failure" claim — g6lc_tb.cpp:676 prints CORE 0 ONLY and only for main_time<64.
  REMAINING CANDIDATES: core 1 held in reset by the harness; core 1 I$ fetch never
  answered through the hub/AXI arbiter (a real uncore defect, in scope); core 1 not
  elaborated.
- [ ] TOP MULTI-CORE ITEM: repair the TB's multi-core PC probe. It prints c1.npc, which is
  exactly the instrument needed, but CVA6_MC_PC_PROBE_COMPILE no longer compiles — stale
  hierarchy paths, e.g.
  gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_cva6_icache__DOT__cache_en_q.
- [~] (superseded) NEW BLOCKER for the coherence re-run: on the fixed flavour-B build all three
  cross-core tests fail with code 5 (READY timeout) at ~160.5k cycles — hart 1 never
  publishes, while hart 0 plainly runs. Boot trace shows `[boot] npc=0x0` on this build
  vs `npc=0x10000` (bootrom) on production and on every 2jr run. BOOT_HOLD is NOT the
  cause: it is (NC>1 && NrHarts>1) and stream8 is NrHarts=1/NrCores=2. The same test
  passed on production (773 cy, which required hart 1), so secondary-core boot works
  there and not under flavour B. Separate defect; chase it before reading anything into
  the coherence tests. NOTE for whoever picks this up: code 5 = "hart 1 never ran";
  only code 9 would mean a stale line.
- [x] Blocker cleared, and neither obstacle was an RTL defect: (1) `legacy` flavour cannot
  build (%Error-PINMISSING at core/fetch_A/smt_legacy/frontend.sv:4003, push_cf_i /
  cf_resolve_i) — ALL WORK NOW USES FLAVOUR B (fetch_B); fetch_A/smt_legacy is never the
  supply — and fetch_A is now RETIRED IN TOOLING, not merely avoided: the build harness
  refuses flavour legacy|a|A|oracle with a directive message
  (override SOFT_LADDER_ALLOW_RETIRED_FETCH_A=1 only to repair that supply). Flist
  trimmed ON EVIDENCE: of the 10 core/fetch_A/smt_legacy/* helpers listed, 5 were dead
  (referenced only by fetch_A files the flist never compiles — frontend.sv /
  instr_queue.sv / instr_realign.sv) and are REMOVED: g6lc_fe_kill, g6lc_iq_hide,
  g6lc_present, g6lc_leftover, g6lc_lj_hide. The OTHER 5 ARE NOT RETIRED despite their
  path and deleting them would break the build — g6lc_rvc_enc, g6lc_jalr_usable,
  g6lc_cf_unissued, g6lc_fe_keep, g6lc_sib_cjalr are used by the LIVE core
  (compressed_decoder, id_stage, controller, scoreboard, branch_unit,
  issue_read_operands, issue_stage).
  RELOCATED (follow-up now done): all five `git mv`'d from core/fetch_A/smt_legacy/ to
  core/, next to the consumers that use them, and core/Flist.cva6 updated. Checked first
  that nothing else referenced the old paths — Flist.smt_legacy and
  verif/sv-timing-tests/flists/sparse_frontend.f mention fetch_A but NOT these five, so
  core/Flist.cva6 was the only file to change. core/fetch_A now has ZERO entries in the
  stock flist, so the directory can be deleted without stranding live code — which was
  the point: live files inside a directory documented as retired are a trap for whoever
  finally deletes it. VERIFIED: stream8 flavour B builds clean (8 warnings), default lint
  8/54 unchanged.
  PROCESS NOTE: the path edits and the comment edit were done in one script whose LAST
  assertion failed, so nothing was written — but the `git mv` had already run, leaving
  moved files and a stale flist (a broken tree). Sequence the irreversible step AFTER the
  edits that can still abort, or make the whole thing idempotent. core/smt_legacy/* (9 entries) left alone: different directory,
  SMT support that NrHarts>1 configs need. Verified: stream8 flavour B builds clean,
  breadth 22/0, lint 8/54 unchanged, flavour legacy now refuses up front.
  SELF-INFLICTED NOTE: writing the .sh via Python on Windows injected CRLF and broke
  the harness ("$'
': command not found"); shell scripts must be written LF-only.
  (2) flavour B "segfaulted on every ELF" — it was the 8 MB DEFAULT STACK; the
  Verilated model is stack-allocated and exceeds it. gdb put the fault in getenv() inside
  main (first page past the limit). `ulimit -s unlimited` and it runs. Add that to any
  runner that launches this model.
- [~] (superseded) 2jr REPRODUCTION BLOCKED by a build-infrastructure regression, NOT by analysis.
  Built the seam (`G6LC_DCACHE_EXEC_CACHEABLE` in cva6_hpdcache_if_adapter.sv) plus
  `--define` support in isolated-config-overlay.py and a bare-NAME form in
  SOFT_LADDER_OVERLAY, so both arms build from ONE source state. Then:
    legacy flavour  -> BUILD FAILS: %Error-PINMISSING at
      core/fetch_A/smt_legacy/frontend.sv:4003, missing pins push_cf_i / cf_resolve_i
    B flavour       -> builds clean (8 warnings) but SEGFAULTS (rc=139) on every ELF,
      including the control built with NO define => crash is not from the seam
  Neither core/fetch_A, core/fetch_B, core/fetch nor core/frontend is modified in this
  worktree (`git status` clean for all four), so neither breakage is mine. Production
  work-ver-stream8 (2026-09-15) runs all four tests fine => it was built from an OLDER
  source state than the tree can reproduce today.
  METHOD NOTE: my first pair compared production vs an overlay build, and the overlay
  derives from the STOCK flist — so the arms differed by frontend supply (fetch_A vs
  fetch_B) as well as by the define, making its segfault unattributable. Corrected pair
  pins both arms to flavour B; verified by flist diff (identical but for the define) and
  config-package md5 (7ad570b1… both).
- [ ] PREREQUISITE for the 2jr mechanism hunt: fix the fetch_A/smt_legacy frontend pin
  mismatch (push_cf_i / cf_resolve_i), or fix whatever makes a fetch_B stream8 model
  segfault at startup. Until one is resolved, execute-region option 3 cannot be
  attempted and the exclusion cannot be removed on evidence.
- [ ] PERFORMANCE DEFECT to investigate on its own merits: the execute-region exclusion
  was added as a narrow I$/D$ aliasing fix (comment cites a jtab line the I$ already
  holds), but excluding the WHOLE execute region — which spans all DRAM — disables D$
  allocation for all ordinary data. Almost certainly not the intent; it would gut load
  performance on every config with this shape.
  SCOPE CONFIRMED: `is_inside_execute_regions` is a plain range check, and ALL THREE
  HPDCACHE configs (stream8, ooo_server, server_math) declare the identical overlap
  ExecuteRegion[0] = CachedRegion[0] = 0x8000_0000 +0x4000_0000. Asymmetry worth noting:
  the store/AMO branch of the same adapter applies only the cacheable check, so it is
  specifically LOAD allocation that is disabled.
  NOT PATCHED UNILATERALLY — the exclusion fixes a real I$/D$ aliasing case and names
  the tests it repaired (2jr_fencei / 2jr_pad / 2jr_data); deleting it would likely
  reintroduce that defect. Options for the owner: (1) narrow the predicate to the
  actual hazard (a load to a line the I$ holds) rather than the whole region;
  (2) shrink ExecuteRegion in config to the text range only — cheap but leaves the
  over-reach latent; (3) fix the aliasing at source and drop the exclusion. Any of
  them must use the 2jr_* tests as the regression gate.
- [~] (withdrawn) DEFECT — L1 D-cache miss PMU event does not fire on HPDCACHE configs. Wiring looks
  complete: cva6.sv connects `.dcache_miss_o` on the HPDCACHE branch and
  cva6_hpdcache_wrapper.sv drives it from hpdcache's `evt_cache_read_miss_o`, yet the
  counter never increments. Same class as `coh_sc_fail_o` hardwired zero; AGENTS.md
  0.1(6) requires a working PMU event. Worth fixing on its own merits — a dead
  cache-miss counter blinds every perf investigation on these configs. It is also the
  prerequisite for proving cache residency, which stays unproven until then.
  RESIDUAL: all evidence is black-box. The remaining check is an RTL trace of
  `dcache_miss_cache_perf` (waveform or an SVA counting pulses) to distinguish "never
  pulses" from "pulses but is swallowed before generic_counter".
- [~] (superseded) FIRST investigate the early-boot stall, which may be a real frontend defect and
  currently blocks the whole multi-core sim route: `g6lc_fetch_dbg.sv:347` — `I23
  redirect_hold age 3 exceeds geo.hold_max 2`, hart 1 frontend, cycle 240711, followed
  by a stall at pc~0x80000074 cause=24. Reproduces with every ELF tried.
- [~] (superseded) EVIDENCE SUSPENDED — all cross-core coherence results are currently untrustworthy.
  Re-running the UNMODIFIED polling test on the same netlist produced a 1.2M-cycle harness
  timeout instead of its earlier 67100-cycle pass. The simulator binary is unchanged
  (`/opt/testharness/work/work-ver-stream8/Variane_testharness`, md5
  5b487b85a4893e04876fe8bb2ba9f95e, 2026-09-15 02:12:59), but the two ELFs compiled from
  the SAME source path have different hashes: the passing `mc2.elf` is 9df35828… and
  today's control `poll2.elf` is ce2626c1…. So the control was not the same program, the
  comparison is void, and it is not known which source state produced the pass. The
  quiet-observer runs are uninterpretable for the same reason. ACTION before any further
  coherence experiment: pin and record the md5 of BOTH the simulator binary and the ELF in
  every run, refuse to compare runs whose hashes differ, and re-establish a passing
  baseline from a known source state.
- [ ] Separate defect surfaced by these runs, needs its own investigation: both harts trip
  `g6lc_fetch_dbg.sv:347` — `I23 redirect_hold age 3 exceeds geo.hold_max 2` on hart 1's
  frontend at ~240k cycles — followed by a machine-level stall (commit-dbg pc=0x80000074,
  cause=24). Unrelated to polling vs quiet waiting.
- [!] CORRECTION to the "self-proving" claim: the FLAG-loop argument proves delivery only
  for a POLLING observer, which is precisely the case where the observer's own refill
  traffic can supply the coincident read response. It does not cover an idle observer, so
  the polling passes do NOT settle the question and my previous conclusion was too strong.
  Cacheability is ruled out: stream8's cached region is [0x8000_0000, 0xC000_0000).
  Added `mc_shared_line_quiet.S` (resident line + register-only wait, no traffic) as the
  decisive variant; its first run returned `tohost=2147483647`, the harness CYCLE TIMEOUT
  at 900013 cycles — inconclusive, neither hart reached a verdict. v2 completes in 67100
  cycles, so the quiet variant does not terminate and needs per-stage progress markers and
  a smaller quiet window. Position: defect neither demonstrated nor excluded; change stays
  reverted for lack of a reproduction; concern NOT closed.
- [~] (superseded) The pass is self-proving: hart 0 spins on FLAG with ordinary loads and hart 1
  writes FLAG, so LEAVING the loop already requires hart 0's cached FLAG line to be
  invalidated — otherwise it exits with code 6 (timeout). The run completed in 67100
  cycles with the correct LINE value, so delivery is demonstrated twice in one run
  (FLAG loop exit and LINE value). The refutation is solid.
- [ ] Mechanism still unexplained (behaviour is correct): the arbiter drives
  `dcache_read_resp_valid_o = mem_resp_read_valid_arb[1]` (real read responses only)
  and the demux samples the inval only inside `if (mem_resp_read_valid_i)`, yet no
  pulse is lost. Settle it with a PMU-instrumented variant: load LINE twice before the
  remote write (second must HIT = resident) and once after (must MISS), reading the D$
  miss counter around each. Candidates: spin-loop refill traffic supplying the
  coincident response, or the region not being cached in this harness's PMA.
- [ ] Proxy usage note: `shell` takes the command POSITIONALLY. `--cmd "X"` is not a
  flag, so it was passed to bash as argv[0] ("--cmd: command not found") and the first
  command in the string was consumed. Global flags such as `--timeout` must precede
  the subcommand. Also: a proxy-side timeout kills the ssh command but leaves the
  remote simulator running, and the overlap guard then refuses the next run.
- [x] The ooo_server 2 -> 4 warning delta is identified and is NOT from the HPDCACHE
  repair: both new warnings are WIDTHCONCAT on `g6lc_l2_tag.sv:112` (`tags_q <= '0`,
  the earlier whole-array tag reset). They quantify the flop tag arrays at production
  geometry — **3,080,192 bits** (L3 instance) and **401,408 bits** (L2), ~3.4 Mbit of
  tag state in flops. Left unsilenced on purpose: they are the standing signal for the
  tag-SRAM item.
- [ ] Remote shell quoting gotcha (cost me several queries): `remote shell -- --cmd "X"`
  passes `--cmd` to bash as argv[0], so the FIRST command in the string is consumed.
  Prefix a sacrificial token (`x ; real command`) or the first command's output is
  silently missing — which is how a `grep` looked like "no matches".
- [ ] Remaining gate work: record `warningBaselineRemote` from a reviewed run; give
  slang elaboration a remote route (no standalone slang on the builder, and the
  Yosys-integrated frontend is not a substitute — it rejects hpdcache SVA that
  standalone slang accepts); add the uncore to the remote synth sweep; then execute
  the full source-bound gate including sim.
- [ ] Full source-bound platform verification and natural SMT2/OpenSBI remain
  gates, separate from in-order integer diagnostics and OoO-disabled regressions.
  The current `verify --lint --sim --synth --dry-run` still selects local tool
  routes and reports eight SKIPs, not qualification; remote-only routing must
  be reconciled before executing that full gate.
- [ ] Physical P2: tag/IQ/checkpoint lifetime and port studies, followed by
  approved macro/library/corner/clock/activity-based STA/area/power/DFT. Inputs
  remain missing; generic cell counts do not discharge this item.
- [ ] Preserve the documented OoO hart/FP legality restrictions and track the
  missing namespaces and simulator `-O0` divergence explicitly.

- [x] REMOTE WARNING BASELINE RECORDED — `verify.warningBaselineRemote` in
  build-platform/src/config/defaults.ts:
    cv64a6_imafdc_sv39 8   cv32a65x 54
    g6lc64_stream8     7   g6lc64_ooo_server 4   g6lc64_server_math 7
  WHY IT MATTERS: unset meant warnings were NOT GATED AT ALL on the remote route. The gate
  said so on every run of this session ("NO remote baseline recorded, warnings not
  gated") — a hole, not a default: a change adding twenty warnings would still have
  passed. Deliberately NOT copied from the local `warningBaseline` (483/146), because the
  builder's Verilator emits a different diagnostic set (8/54) and transferring the local
  numbers would hide real regressions under a much larger accepted count.
  Values are trustworthy because they held steady across many runs while the D$
  read-response path changed on all three HPDCACHE targets.
  VERIFIED THE BASELINE ACTUALLY GATES, not just that it is present: lowering
  cv64a6_imafdc_sv39 to 7 produced
    FAIL lint cv64a6_imafdc_sv39 remote 8 warning(s), remote baseline 7 — REGRESSION
  then restored to 8 and all five targets pass against their own baselines. A baseline
  never observed to fail is indistinguishable from one that is not consulted.

- [~] HUB ARBITRATION FAIRNESS — partially characterised, NOT qualified.
  The hub bench left `coh_arb_starve_o()` UNCONNECTED, so the starvation override had never
  been observed to fire in any test ("the RTL drives it" was the only evidence). Added
  tb_g6lc_coherence_hub scenario 9 (+ a `+starve_trace` probe) and connected the output.
  MEASURED (trace, both cores' AW asserted, memory refusing):
    i=14  starve0=14 starve1=14  force=0 hold=1 grant=1
    i=16  starve0=16 starve1=16  force=0 hold=1 grant=1
    i=19  starve0=16 starve1=16  force=0 hold=1 grant=1
  (1) COUNTERS ARE CORRECT and SATURATE at the limit — the `< LIMIT` guard (line 414) means
      a starvation claim cannot wrap and be silently lost. Previously a reading, now
      measured.
  (2) THE OVERRIDE NEVER FIRES: line 141 clears aw_starve_force whenever aw_hold_q is set,
      and the hold latches on grant and persists until the memory side accepts. So
      coh_arb_starve_o CANNOT ASSERT WHILE AN AW IS PENDING DOWNSTREAM, however long a core
      has waited. The suppression is correct in itself (the AW owner must not change
      mid-burst or W data mis-routes), but it means the override is NOT an unconditional
      service bound: the real bound is AXI_STARVE_LIMIT + hold duration, and the hold is set
      by downstream memory, not by the hub.
  MY FIRST STIMULUS WAS WRONG and the test SAID SO rather than passing: refusing AW for
  EVERYONE is not starvation (nobody is served, so nobody is relatively starved). Scenario 9
  fatals with HUB_STARVE_NOT_OBSERVED instead of reporting success — the behaviour a
  fairness test must have.
  FINAL MEASUREMENT, after TWO harness errors (bench parameterised -GNC/-GSTARVE_LIMIT/
  -GCYCLES). Total grants went from 4 to 600 once B was drained CORRECTLY:
    NC=2 L=16  total=600  300:300        override asserted 0 cycles
    NC=4 L=16  total=600  150 x4         override asserted 0 cycles
    NC=8 L=16  total=600  75 x8          override asserted 0 cycles
    NC=4 L=1   total=600  599:0:...      SHUT-OUT
    NC=8 L=1   total=600  599:0:...      SHUT-OUT
  RETRACTION: I previously recorded that the override "fires routinely at the production
  limit — 39 of 60 cycles" and that my round-robin reasoning was "not the operative
  effect". THAT WAS AN ARTIFACT of the stalled harness: with the hub jammed every core
  waited indefinitely and trivially passed the limit. On a working harness the override
  NEVER FIRES at the production limit — 0 cycles in 1200, at 2, 4 AND 8 cores — and
  round-robin alone distributes grants perfectly evenly. My original reasoning was right.
  THE REAL FINDING, sharper than a bias: when the override DOES engage it LOCKS THE
  ARBITER ONTO ONE CORE — 599 of 600 grants to a single core, others get NONE, at both 4
  and 8 cores. Cause: the selection loop (lines 129-140) assigns `aw_winner = c` for
  every starved core, so the highest-indexed starved core always wins; at a low limit it
  re-qualifies immediately after each grant and never yields.
  => The override is NOT a fairness net; engaged, it is a fairness HAZARD. What protects
  production is that it never engages: the margin between the service interval and
  AXI_STARVE_LIMIT=16 IS the safety argument, now measured rather than assumed. Anyone
  lowering the limit — or lengthening the service interval enough to reach it — should
  expect MONOPOLISATION, not rescue.
  TWO HARNESS ERRORS, both mine, both caught by data:
   (1) B never drained => scoreboard fills after MAX_OUTSTANDING and the hub stops
       granting; every config reported exactly 4 grants and a 20x window changed
       NOTHING. Identical counts over 20x the time = stalled harness, not unfair
       arbiter. Scenario now reports HUB_STARVE_INCONCLUSIVE when total grants < NC.
   (2) First B fix issued the response in the SAME cycle as the AW handshake, but the
       slot is only registered at the clock edge — the B arrived before the entry
       existed and was never matched. Delaying B one cycle: 4 -> 600 grants.
  SUITE STATE: 9/9 scenarios pass with the output connected. Default production config
  (2 cores, limit 16, 60 cycles): grants=15 15, starve_cycles=0 — even, override never
  engaged. s9 negative control fires (HUB_STARVE_SHUTOUT core 0), and the pre-existing
  s0 control still fires, so nothing was weakened.
  OWNER DECISION QUEUED: make the override pick ROTATIONALLY among starved cores (scan
  from aw_rr_q, take the first starved) instead of letting the loop's last iteration
  win. One changed loop; converts a hazard into the net it was meant to be. NOT applied
  here because the override is unreachable in production and changing arbitration
  without a reproduction of harm would be speculative.

- [x] INVAL_BUS DRAIN reviewed — NO LOSS, but the loss-signal was MISNAMED.
  inv_ready_o = can_accept, false whenever ANY target FIFO is full
  (g6lc_inval_bus.sv:60-84), so the producer is back-pressured and the hub holds the
  request. With the hub's registered invalidation obligation and the L1-side retention
  repaired earlier, ALL THREE stages of the path now hold rather than discard.
  THE NAME WAS THE DEFECT: `inv_drop_o`, documented "producer drop (all FIFOs full)", is
  assigned `inv_req_i.valid & ~inv_ready_o` — i.e. "refused this cycle", RETRIED not lost.
  On a coherence path that distinction is everything: anyone debugging a stale line would
  see inv_drop high and conclude invalidations were discarded — the wrong search direction.
  It is also UNCONNECTED in the hub, so nothing was going to contradict the misreading.
  RENAMED to inv_stall_o at all five sites. Two things confirm it was a naming defect and
  not a design one: both existing benches already bound it to a signal called `blocked`,
  and the module coalesces same-line invalidations rather than dropping them.
  Same repair as coh_sc_fail_o -> coh_sc_noresv_o: point the name at the condition the
  signal actually observes.
  VERIFIED: inval-bus leaf bench passes, hub suite 9/9, ooo_server lint 4 warnings against
  its recorded baseline.

- [x] LINE-ENDING CHURN CLEANED (self-inflicted, and the same trap already recorded in this
  file). Python `write_text` on Windows rewrites files as CRLF, so 17 edited files had
  become whole-file diffs:
    g6lc_coherence_hub.sv      666/651  ->  19/4
    g6lc_inval_bus.sv          145/139  ->   9/3
    tb_g6lc_inval_bus.sv       226/226  ->   1/1   (a ONE-LINE change)
    total across the tree   12287/8619  ->  3971/247
  ~8,400 lines of pure churn removed. Several files (ariane.sv, g6lc_cluster.sv,
  ariane_gate_tb.sv, g6lc_lr_sc_tracker.sv, tb_g6lc_rtl_review.sv, verify.ts, schema.ts)
  had been sitting as whole-file CRLF diffs from EARLIER in the session and only now show
  their real 1-4 line changes.
  METHOD, so this is reversible and safe: normalise ONLY files that were LF in HEAD —
  a file legitimately CRLF upstream must keep its endings. Checked per file against
  `git show HEAD:<path>` rather than blanket-converting.
  RE-VERIFIED AFTER: stream8 flavour B builds clean (8 warnings), breadth 21/21, the three
  cross-core tests pass, hub suite 9/9, inval-bus leaf bench passes.
  RULE (already in this file for .sh, now shown to apply to .sv/.ts/.py too): prefer the
  edit tool; if Python must write a repo file, write BYTES and preserve the original
  newlines. `git diff --numstat` is the cheap detector — insertions == deletions == file
  length means line endings, not content.

- [~] SECONDARY-CORE LIVENESS — diagnostic exercised, not generally qualified.
  2026-09-18 correction: sampled gaps do not establish an architectural delay bound;
  NR_CORES-based aggregation does not observe each SMT hart. WFI/wakeup, debug/boot
  holds, long legal stalls and original failure-code preservation remain obligations.
  Historical measurements and the injected-observer control follow:
  I had recorded this as needing "per-core liveness windows or test-declared expectations,
  both risking false failures on legitimate idle parks". WRONG in a useful way: AN IDLE
  PARK LOOP KEEPS RETIRING (it retires its own branch), so a parked core and a hung core
  ARE distinguishable by retirement even though they are identical by PC.
  BOUND MEASURED BEFORE IT WAS CHOSEN (max retirement gap, cycles):
    store-visible            core0 23  core1 25
    two-inval back-pressure  core0 32  core1 25
    miss-streaming stress    core0 60  core1 71   <- worst anywhere
    mini_hpd_2jr (parked)    core0 33  core1 30
    mc_boot_sanity           core0 23  core1 23
  Largest gap ANYWHERE is 71; parked cores 23-30. MC_GAP_LIMIT = 5000, ~70x the worst
  observed, so it cannot fire on a cache miss, DRAM stall or park.
  WFI (the one legitimate way to stop retiring) is excluded by the INSTRUCTION read from
  RVFI (insn == 0x10500073), NOT by a hierarchical reference to csr_regfile.wfi_q: that
  path runs through gen_std or gen_acc by configuration, and this review was already
  bitten once by a probe wired to a hierarchy that moved (i_cva6_icache).
  VERIFIED BOTH WAYS, with distinct exit codes so the log says which failure occurred:
    mini_hpd_* + sanity        21/21 pass
    three cross-core tests     all SUCCESS
    +mc_hang_fault             exit 126, "a core ran and then stopped retiring"
  127 = a core never ran; 126 = a core ran and then stopped.

- [x] STARVE OVERRIDE NOW ROTATES — decision REVERSED on new evidence, and applied.
  I had declined this as speculative ("unreachable in production; no reproduction of
  harm"). Right rule, WRONG CONCLUSION: the measurement behind it used a memory model that
  accepts every request immediately — the shortest possible service interval. The tell was
  in my own data: at 8 cores, 600 grants / 1200 cycles = 75 each = a core served every 16
  cycles = EXACTLY AXI_STARVE_LIMIT. The margin was not large, it was ZERO.
  Bench now sweeps memory acceptance (-GMEM_STALL, AW accepted 1 in N+1):
    NC=2 stall 0,3   override never fires, even (500:500, 250:250)
    NC=4 stall 0,3   override never fires, even (250x4, 125x4)
    NC=8 stall 0,1   override never fires, even (125x8)
    NC=8 stall 3     FIRES 992/2000 cycles -> grants 1,1,1,100,100,99,99,99 (100x!)
    NC=8 stall 7     FIRES -> SHUT-OUT, core 3 never granted
  Ordinary DRAM behaviour, not a pathological case. The mechanism meant to RESCUE a
  starved core was the thing STARVING it: the winner re-qualifies immediately and keeps
  winning the last-wins tie.
  REPAIR: reuse the arbiter's existing pick_rr over the starved subset, so a forced grant
  ADVANCES the rotation instead of fighting it. No new state (mask is combinational over
  existing counters).
    NC=8 stall 3  1,1,1,100,100,99,99,99 -> 63,63,63,63,62,62,62,62
    NC=8 stall 7  SHUT-OUT               -> 32,32,31,31,31,31,31,31
  The override still engages (992 / 496 cycles) — it is doing its job — but now
  distributes. Already-fair configurations unchanged, so this is not a behaviour swap.
  VERIFIED: hub suite 9/9, inval-bus bench passes, stream8 builds clean (8 warnings),
  breadth 21/21 + 3 cross-core pass + hang control still fires at 126, lint 7/4/7 against
  recorded baselines.
  LESSON, recorded because it nearly cost a real defect: "unreachable in production" was a
  conclusion drawn from a model whose one relevant parameter was pinned at its most
  favourable value. AN ARBITRATION MARGIN MEASURED AGAINST INFINITELY FAST MEMORY IS NOT A
  MARGIN.

- [!] TAG ARRAY RE-SCOPED — it is NOT a "swap to tc_sram" job, it is a PIPELINE CHANGE.
  BLOCKING PROPERTY IS THE READ CONTRACT, not the array declaration: the lookup is
  COMBINATIONAL (hit_o valid in the same cycle as index_i; the module header advertises
  "single cycle"). An SRAM read is REGISTERED, so the swap inserts a pipeline stage into
  the L2 lookup and changes the latency the parent is built around.
  THREE MORE PROPERTIES to resolve before binding a macro:
   * probe_tag_o / probe_valid_o are a SECOND combinational read at an arbitrary way,
     independent of the lookup index -> second read port or arbitration;
   * inval_match_i is CONTENT-ASSOCIATIVE: compares against ALL ways of a set and clears
     matches, read+write same set same cycle -> becomes a multi-cycle RMW that must not
     race the lookup;
   * write_i and inval_i are independent ifs in one always_comb, so both can update in the
     same cycle at different indices -> two write ports or serialisation.
  The standard valid-in-flops/tags-in-SRAM split is NECESSARY (it removes the whole-array
  reset) but is NOT where the area is: valid is 1 bit of a 48-bit entry = 2.0% of the L2
  array, 2.1% of L3. The tags are the cost AND are exactly what needs the registered read.
  FIGURE I CANNOT RECONCILE: this repo quotes 3,080,192 (L3) + 401,408 (L2) ~= 3.4 Mbit
  from a Verilator WIDTHCONCAT warning. Derived from geometry:
    L2 256 KiB a8 -> 512 sets, TAG 49, 4096 entries  = 0.205 Mbit
    L3 2 MiB  a16 -> 2048 sets, TAG 47, 32768 entries = 1.573 Mbit   total 1.78 Mbit
  The quoted numbers are 1.96x mine in BOTH cases — a uniform factor consistent with the
  warning counting the reset concat across tags_q AND tags_d rather than storage. Not
  proven either way, so: the array is BETWEEN 1.8 AND 3.4 Mbit of flops, dominant either
  way, and the precise figure must come from a synthesis flop count, not a lint warning.
  PLANNING CONSEQUENCE: not a contained P2 array swap. New pipeline stage + second read
  port/arbitration + serialised content-associative invalidate, invalidating timing
  assumptions of a module with extensive leaf suites (review-l2-read-order-*,
  review-l2-atop-*, review-l2-inclusion-*). Plan and qualify as a micro-arch change.

- [x] RETRACTION — the 3.4 Mbit tag figure is CORRECT; my challenge to it was WRONG.
  I derived 1.78 Mbit and flagged a "uniform 1.96x discrepancy". The error was mine: I used
  the DEFAULT geometry (256 KiB L2 / 2 MiB L3) instead of the CONFIGURED one. build_config
  scales caches with core count -- L2 = max(256 KiB, NrCores x 128 KiB), L3 = max(2 MiB,
  NrCores x 1 MiB) -- and g6lc64_ooo_server sets NrCores: 4, so the real geometry is
  512 KiB L2 / 4 MiB L3:
    L2 512 KiB a8  -> 1024 sets, TAG 48, 8192 entries  -> 8192*49  = 401,408   MATCHES
    L3 4 MiB   a16 -> 4096 sets, TAG 46, 65536 entries -> 65536*47 = 3,080,192 MATCHES
  Both to the bit. The array IS 3.48 Mbit of flops. The "1.96x" I found suspicious was just
  the ratio between two geometries differing 2x in size: doubling sets doubles entries
  while removing one tag bit.
  KEEP FROM THE DETOUR: the valid-bit fraction is unchanged and still small (1 of 49 bits,
  2.0%), so "the valid/tag split does not address the area" stands. And the lint-warning
  width was a RELIABLE measurement here -- distrusting it was reasonable, the arithmetic
  that seemed to support the distrust was not, and the fix was to read the CONFIGURED
  parameters rather than the defaults.

- [x] SNOOP-FILTER DISPLACEMENT reviewed — NO correctness hole; dead state removed instead.
  Every address resolves to exactly two outcomes: a lookup MISS reports ALL CORES PRESENT
  (present_o default {NC{1'b1}}), and an install over a live entry starts ALL PRESENT
  (install_present). So a displaced line's forgotten sharers can NEVER under-report -- the
  structure degrades to broadcast, which is safe. Back-invalidation buys PRECISION, not
  correctness => the item leaves the P0/P1 class.
  STRUCTURE IS NOT WHAT ITS STATE SUGGESTED: the filter is DIRECT-MAPPED (every access is
  mem_q[idx_of(addr)], no way selection) yet carried an `rr_q` counter incremented on every
  install and READ BY NOTHING. Dead state that also advertised a round-robin victim policy
  that does not exist -- anyone planning displacement handling would look for a victim to
  select and find none. Removed; direct-mapped property documented in its place.
  PRECISION STORY IS ALIASING, NOT CAPACITY: with NR_ENTRIES ~= 64 x NrCores and direct
  mapping, any working set aliasing in the index space evicts itself and each aliasing
  install re-arms all-present. Mitigation is more entries or associativity, NOT
  "back-invalidate on displacement".
  VERIFIED one-variable: committed filter and rr_q-removed filter both pass scenarios 0-2
  and both fire the injected-error control (rc 134). Identical.
  METHOD NOTE: my first control ran `git show HEAD:` ON THE BUILDER and got a PRE-SESSION
  file -- the remote is an rsync'd working tree with a stale .git (4bab99ca0, not the
  session commit). It usefully re-reproduced the original SF_SHARER_LOST signature, but a
  baseline must come from the LOCAL repo and be copied over, never from the remote's own
  history.

- [x] OoO P0s VERIFIED CONTAINED — refused at ELABORATION, not just in simulation.
  check_cfg has assert(!(OoOEn && NrHarts>1)) and assert(!(OoOEn && FpPresent)), but it is
  called from core/cva6.sv:2294 inside an `initial` block = SIMULATION ONLY. I went looking
  for the hole that implies (synthesis would accept the unsound config silently).
  THE HOLE IS NOT THERE: core/ooo/g6lc_ooo_dispatch.sv:101-106 carries GENERATE-SCOPE
  $error guards that fire during elaboration in BOTH flows. Verified by synthesising top
  `cva6` with the g6lc64_ooo_server package AS DECLARED (OoOEn=1, NrHarts=2, RVF/RVD=1)
  against a flat manifest:
    g6lc_ooo_dispatch.sv:102 $error OoO dispatch has no per-hart rename namespace
    g6lc_ooo_dispatch.sv:105 $error OoO dispatch has no FP register class
    Build failed: 2 errors -- Design elaboration failed
  => Both P0s are FEATURE GAPS BEHIND A HARD GUARD, not latent defects that can reach
  silicon. Materially different priority from "P0 defect": nothing can accidentally build
  the aliasing design. Remaining work is implementation (per-hart map/free/busy namespaces;
  FP register class through rename/PRF/operand read), to be planned and qualified as such.
  GENERAL POINT (recurring): an `initial`-block assert refuses the configuration to anyone
  who RUNS A TEST and refuses nothing to anyone who RUNS SYNTHESIS. The generate-scope
  $error is what makes it a BUILD refusal -- same promotion applied to the MEM_TID_WIDTH
  bound earlier in this review.

- [x] AUDITED whether the "simulation-only guard" pattern is SYSTEMIC. It is not, and the
  bounded answer is worth more than the suspicion was.
  COUNTS: check_cfg carries 124 asserts, ALL simulation-only (called from an `initial`
  block at core/cva6.sv:2294). Against that, the whole core carries only 12 generate-scope
  elaboration guards (`begin : gen_err_*`):
    cva6_hpdcache_subsystem  3  (MEM_TID_WIDTH -- promoted from translate_off THIS session)
    vendored hpdcache        6  (recovery, multi/single-way, scrubber, rdata ecc/noecc)
    cva6.sv                  1  (CvxifEn && EnableAccelerator)
    g6lc_ooo_dispatch        2  (NrHarts>1 aliasing; FpPresent not renamed)
  CLASSIFICATION of the risky check_cfg rules (those mentioning NrHarts/NrCores/FpPresent):
   * SILENT-ALIASING class -- a violation BUILDS FINE and corrupts architectural state:
     OoOEn && NrHarts>1, OoOEn && FpPresent. BOTH are separately guarded at elaboration.
   * SANITY class -- range/sizing rules (NrHarts/NrCores bounds, NrCores*NrHarts <= MAX,
     SnoopFilterEntries==0, SmtFetchQuantum==0) and platform-capability rules (NrHarts>1 or
     NrCores>1 requiring RVS/MmuPresent). A violation of these is self-evident: the build
     breaks on widths, or the software plainly cannot run. They do not silently alias
     hardware state, so an `initial` assert is adequate.
  => The one class that can silently alias core state is covered. The pattern DID exist
  (MEM_TID_WIDTH was translate_off-only until this session promoted it), which is why the
  suspicion was reasonable -- but it is not systemic, and I am not manufacturing an alarm
  where the audit does not support one.

- [~] OpenSBI/SMT2 SOAK — historical runs completed, but causal attribution and liveness
  qualification remain OPEN. The following historical interpretation is superseded by the
  2026-09-18 H3/H4 audit: an unmatched failing baseline cannot exonerate current edits;
  stock-runtime provenance and physical-core aggregation also limit its conclusions.
  Motivation: MC_GAP_LIMIT=5000 was calibrated on bare-metal tests whose worst gap is 71
  cycles. FIRMWARE is the case that could break it (real memory pressure, long stalls, WFI).
  Ran soft-ladder-opensbi-soak.sh (SUCCESS iff trapdump shows 51b1babe) on an SMT2 harness
  built from current source, then the SAME ELF on a pre-existing harness:
    work-ver-smt2-fw64-B (old build)  FAILED tohost=2147483647 @12,000,013 cy  cookie ABSENT  npc0=0x80002d38
    built from current source         FAILED tohost=126        @12,000,013 cy  cookie ABSENT  npc0=0x80012588
  BOTH fail, both exhaust the 12M budget, neither reaches the cookie => the boot failure is
  PRE-EXISTING, not introduced here.
  THE HANG VERDICT DID NOT FALSE-FIRE. Its output looks self-contradictory --
  "max retirement gap 270 cycles (limit 5000)" alongside "FAIL: a core ran and then stopped
  retiring" -- but they measure different things: mc_gap_max is the largest COMPLETED gap,
  the verdict tests the LIVE gap at end of run. The core retired healthily (gaps <=270)
  until it hung, then the live gap ran away. Exactly the designed behaviour, observed on a
  REAL hang rather than an injected one -- complements +mc_hang_fault (can fire) with
  (does fire on the real thing).
  TWO HONEST QUALIFICATIONS:
   * the baseline harness PREDATES this session, so it differs by everything committed
     since, not only my edits. It establishes "this boot was already failing", NOT "my
     edits changed nothing". The differing hang PCs are consistent with intervening commits
     OR run-to-run variation; I have not separated those.
   * a timeout's EXIT CODE can now change: previously 0x7FFFFFFF, now 126 if the core has
     also stopped retiring. More specific, but tooling matching the old code must know.
  SCOPE NOTE: SMT2 is NrCores=1, so the cluster takes its identity path and the
  invalidation machinery is INERT. This soak exercises the TESTHARNESS changes and the
  core, not the hub rotation or the retention (those are covered by their leaf suites and
  the two-core tests).

- [x] SMT2 methodology applied (2026-09-18): coding philosophy §2.9 + H3/H4/H5 + T2/T9.
  Fixed four reproduced soak-oracle defects: lost child rc, unbound cookie matching,
  explicit-model fallback and missing-hold substitution. Thirteen unittest methods pass.
  Run tooling checks with:
    python -m unittest discover -s verif/regress/remote -p test_testharness_proxy.py -v
  These use fake processes only; they are not RTL soak evidence.
- [x] Deterministic failing PREFIX established, not a boot pass: corrected-runtime fetch_B
  SMT2 model 62454f73... and frozen ELF 1a8bd52a...; threads=1, seed=1, cap=200000,
  three sequential proxy runs, same recorded pin/trapdump/verdict fields. Runtime canary
  separately reproduces stock failures=18 versus private failures=0; compiler dependency
  files bind the model to private header dfbc2c4a... . Prior soak used stock 8c408609... .
  Artifacts: remote-runs/smt2-method-prefix-20260918/output/ and
  remote-runs/smt2-method-build-20260918/build-manifest.json.
- [ ] SMT2 OpenSBI completion/attribution remains OPEN. The byte-at-PC observer reports
  395363 presentations, zero mismatches, with unchanged prefix pin. It is not an
  acceptance or instruction-boundary oracle. RVFI tail ends at 0x800138a0 while next-fetch
  PC is 0x80012588; this is a localization question, not a frontend diagnosis yet.
  Next: correlate accepted entries and ownership through IQ/issue/commit, then a generic
  co-factor mini; preserve ISA effects, firmware and fetch_B-only supply. Full soak,
  per-hart liveness, observer fault sensitivity and a matched before/after remain owed.
  No further commits (user instruction); e3c1fb642 remains the last commit.

- [x] Fetch_B-only source boundary (2026-09-18, user-authorized relocation): nine shared
  SMT support files moved from core/smt_legacy to core/smt; initially 100% byte-identical
  renames. Flist.cva6 and live artifact-gate references updated. The relocated SMT2 model
  is byte-identical to the pre-relocation issue-observer build (85495788...), and the
  failing prefix is unchanged. Fifteen proxy/runner tests pass, including recursive
  manifest exclusion and positive/negative generated-source guards for fetch_A and
  smt_legacy. No retired frontend built; no further git commit. Archived path mentions
  are history or replay-path conversion, not active build inputs.
- [x] Issue-group dependency ordering repaired in core/smt/g6lc_issue_barrier.sv:
  typed scoreboard trace shows empty SB, oldest direct call blocked by a younger low-PC
  target-path stack update. Both reversed-PC relationships fail the pre-fix leaf test.
  Same-group age now uses o<p with valid/same-hart guards, not PC magnitude. No new state,
  clock, reset, pipeline latency or ISA/DTS/config default. Removes a VLEN comparison;
  physical timing at the 1.25 GHz/12 nm target remains unmeasured. Visibility channels:
  restores progress/order, no squash/write filtering, data-value predicate or new memory
  effect. Debug observers are translate_off and opt-in; off/on prefix signatures agree.
  Evidence: issue-order-before-20260918; issue-order-relocated-after-20260918 (18 positive
  cases + 18 oracle negatives); issue-order-relocated-fault-20260918 (old rule restored,
  expected failures reproduced); issue-order-quality-20260918 (163 generic cells,
  zero latches, check -assert clean, two-port/two-hart leaf only). SMT2 remote lint passes
  with one existing WIDTHCONCAT warning; strict full-core slang stage is skipped, not passed.
- [~] SMT2 COOKIE REMAINS OPEN after that repair. Unchanged ELF 1a8bd52a..., new model
  8e888128..., corrected runtime dfbc2c4a..., VT1, seed1, fetch_B-only source check passed.
  Previously blocked call now allocates/WBs/retires at cycles 7022/7023/7024; the 200k
  prefix keeps retiring but has no cookie. Full-cap attempt ends at wall timeout 900s,
  9,019,026 cycles (NOT the requested 12M), rc124, cookie absent, plat_hc=80,
  coldboot_done=0, sp1=0. Harness SUCCESS text is rejected by the corrected oracle.
  Artifacts: smt2-relocated-prefix-20260918, smt2-order-prefix-20260918,
  smt2-order-cookie-20260918 under remote-runs. Both-hart progress remains unproven.
  Next: localize post-repair loop progress using the short trace and per-hart ownership;
  do not infer completion from continued retirement or extend the wall limit as a fix.

- [x] WT normal-response ownership repair (2026-09-18): after the issue-order repair,
  a call saved a new return address but reloaded the previous one. Typed observations
  follow correct operands, STQ accept/commit and D-cache grant. A final normal tag
  response switched to the fixup tag when tocheck emptied (cycle7041), then overwrote
  the true hit with a miss (7042). Select rd_tag_q by existing check_en_q instead of
  current |tocheck| in wt_dcache_wbuffer.sv. No added state, latency, clock/reset,
  address specialization, config default or firmware change. Selector is registered;
  no physical timing/area claim. All opt-in diagnostic logic is translate_off.
  Artifacts: smt2-frame-rvfi-v2-20260918, smt2-storeflow-{off,flow}-20260918,
  smt2-wt-check-window-20260918. Directed d12 Yosys checks at fixup depths0/2/4:
  3 positives, 3 reached normal-tail covers, 3 checker negatives; private old selector
  fails3/3. Authoritative artifacts are wt-tag-formal-{after,fault}-v2-20260918.
  Initial reference wrongly attributed empty-fixup reads to the normal word; v2 fixes
  that ownership model and re-runs both directions. Isolated timed Verilator leaf
  remains blocked by unchanged vendor lzc UNOPTFLAT; no waivers changed, no pass claimed.
- [x] SAME-ELF SOFT-LADDER COOKIE REACHED after WT repair: smt2-progress-cookie-20260918,
  ELF1a8bd52a..., modeld22bbbdc..., runtimedfbc2c4a..., VT1/seed1, fetch_B-only inputs.
  51b1babe and51b1d000 at1,693,696 cycles, plat_hc=2, last_hartidx=1, coldboot_done=1,
  banner present, driver rc0. Prefixes200k and1M without cookie were not successes.
  This supersedes the earlier cookie-open result after issue-order repair ALONE.
- [~] TWO-ACTIVE-HART OpenSBI remains OPEN: +smt_progress counts non-dropped typed
  commits by hart; cookie run reports1,301,234/0 retirements. Topology enumeration
  does not prove execution. cva6.sv masks unseen harts until IPI; policy unchanged.
  Same-model mini_ipi_hart1_sp passes with counts256/16 and hart1 SP initialized.
  Private equal-sized NOP replacement of only its two IPI stores gives4024/0 and no
  termination (smt2-activation-controls-20260918). This qualifies directed activation
  and the observer's positive direction, not both harts in the OpenSBI cookie run.
  Observer off/on200k snapshots match. The earlier model99dc42f3... without progress
  counter instrumentation also reaches the same cookie at exactly1,693,696 cycles
  (smt2-wttag-cookie-repeat-20260918), with matching final pins. Activation-controls-v2
  additionally binds the no-IPI result to the full30000-cycle cap; both arms repeat.
  Lint: SMT2=1 warning, default targets8/54 at baseline; strict full-core slang skipped.
  Fifteen tooling tests, Python compilation and scoped diff checks pass. No new commit.

- [~] RESET-TIME SMT / NATURAL OpenSBI (2026-09-19): user explicitly chose a separate
  source-built profile; frozen soft image1a8bd52a... is unchanged. Its count2 was forced
  and fdt_getprop_namelen actually contains li a0,0;ret. Both contexts now execute it,
  but table[0,0] legitimately sends hart1 to _start_hang. That cookie is not dual-hart
  completion, and forced plat_hc is not enumeration evidence.
  Fetch_B boot/time/unseen masks are excluded; runnable harts need no IPI to start.
  No-IPI atomic election/release mini reproduced old exclusion beyond250k cycles.
  Simply unmasking exposed an outgoing AMO flush deleting peer work; a registered
  quiescent handoff now blocks admission until SB and committed store/wbuffer drain.
  Halt admission avoids post-WFI work preventing drain; quantum comparison avoids
  minimum-quantum overflow. RVC/norvc minis pass642/643 cycles, counts47/53; corrupt
  result control fails. Scheduler 8 positives/8 checker negatives; drain-gate mutation
  fails multihart, preserves NH1. Live-port production-tuple synth215 cells, no latches,
  no SCCs (smt-drain-quality-20260919). This is coarse, not overlapping in-flight SMT;
  cancellation, privilege, FP breadth and physical timing remain unqualified.
  Natural profile: upstream455de672..., unchanged fw_base/sbi_init/sbi_hsm/generic
  platform/FDT source hashes, existing toolchain/platform adaptations, DTB validates
  two nodes. Strict S-mode payload requires HSM start, both checked seen flags and
  explicit tohost success; no peer-timeout pass. Archive and per-file identities in
  opensbi-source-dual-v3-20260919/output/profile.json. FW6b2bad99..., modelc5fdeca3...,
  8M cap: h0/h1=1,488,775/119,050, strictDualPassed=false; no payload completion.
  SAME ELF on retained d22bbbdc... held-hart control executes enumeration correctly:
  table[0,1] and count2 stores observed. Dual-active model instead calls at7392, then
  resumes at73f0 mid-instruction and skips enumeration continuation. Handoff at
  time327746 has decode/IQ empty and snapshots transport=73f0. Do not special-case
  this PC. Next boundary: pending fetch/redirect/carry ownership at restart.
  Evidence: opensbi-source-held-control-20260919, opensbi-held-enumeration-audit-20260919,
  opensbi-source-resume-prefix-20260919, opensbi-call-handoff-audit-20260919.
  Source-based profile remains red; no further production RTL repair inferred from
  the PC alone. No commits; retired fetch supplies remain excluded.

- [x] Retired-PC bank contract (2026-09-19): transport snapshot at time327613 saved
  0x7380, an instruction continuation, not the unfinished instruction at0x737e.
  Later handoff saved0x73f0 with decode/IQ empty, skipping the call continuation.
  PC bank now consumes retired next PCs (ordered per hart) and architectural
  redirects, not speculative fetch cursors. Branch targets retained for SMT even
  without DebugEn; no value/address special cases. Existing PC storage reused,
  retirement mux/adder switching increases; physical timing/power not measured.
  RESTART_ARCH_PC fails before and under private overwrite mutation, passes after;
  checker-negative fires. NH1 inert, zero PC, two-port ordering/distinct-hart and
  redirect priority covered. Live-port synth27 cells, no latches/SCC. Artifacts:
  smt-retired-pc-{before,after,quality,fault}-20260919. RVC/norvc reset rendezvous
  plus negative still pass (smt2-startup-retired-pc-20260919). Broader macro,
  cancellation, privilege and FP qualification remains separate.
- [~] NATURAL dual-hart HSM verdict still OPEN, not a cookie failure to mask.
  User-approved source profile6b2bad99... on model3b4fec56... executes both harts
  through natural enumeration and per-hart stack setup: counts325,919/5,447,462,
  SP0=80047f30, SP1=80045db0 at8M. No successful supervisor payload store;
  strictDualPassed=false. Hart0 enters sbi_hart_hang after reading init_count_offset
  as0 atPC800008cc/address80042008; prior hart1 store atPC80000800 wrote0x80 there.
  Hart1 remains active in firmware; its recorded breakpoint is the semihosting
  feature probe, not by itself a fatal verdict. Next: reproduce and localize this
  cross-hart visibility mismatch (STQ→WT wbuffer/fixup→load) before any repair.
  Source and replay runners retain exact ELF/model/runtime identities; current
  strict oracle additionally demands supervisor-mode seen/completion stores.
  16 tooling tests pass; SMT2 lint1 warning, defaults8/54, full-core slang skipped.
  No commits; no retired frontend inputs; original soft-ladder image unmodified.

- [x] WT retained-copy freshness increment (2026-09-19): natural ELF6b2bad99...
  recorded no intervening write between shared init_count_offset store0x80 and
  peer load0. Word watch matches2,458,292 reference retirement lines. Actual store
  accepted/committed/drained1455531/32/33; ACK1455540 dropped the normal copy while
  full fixup queue retained older0 (forward0200 atload1459074/75).
  Refresh an existing same-word fixup at ACK regardless of capacity/cache hit;
  merge byte masks, retain a concurrently retiring update, and preserve unrelated
  copies in same-cycle export. Intermediate slot0 export failed its new control.
  No new state/clock/reset/ISA/DTS/permission/DFT change; existing Depth gate and
  zero-depth behavior retained. Added comparisons/merge/selection affect ACK and
  forwarding timing/activity; physical STA/power remains unqualified.
  Depth2/4 lowered-RTL simulation:8 positives +8 checker negatives; four private
  faults (capacity/bytes/retire/export) fail. This is directed simulation, not full
  cache or unbounded formal qualification. Artifacts wt-fixup-quality-20260919 and
  wt-fixup-fault-{capacity,bytes,retire,export}-20260919. Upstream notices preserved;
  tooling MIT attribution checked. Documented licensing diag is unavailable in
  current CLI (unknown id); manual policy/tier/header checks used, no automated
  licensing pass claimed. SMT2 build returns to1 known WIDTHCONCAT warning.
- [~] Natural profile after freshness repair: model532dc9a2..., same ELF6b2bad99...
  now refreshes atACK1455540 and returns0x80 atload1459074/75. Hart0 reaches the
  normal sbi_hsm_init wait (PC8000f72e), not sbi_hart_hang. At8M cycles counts are
  325,952/5,447,347; strictDualPassed=false, no supervisor payload verdict. Hart1
  remains active in libfdt. Next discriminate primary cold-boot progress/loop
  arguments before increasing the cap or changing firmware. Evidence:
  opensbi-fixup-preserve-dual-20260919, opensbi-hsm-wait-audit-20260919.
  Sixteen tooling tests and CRLF-aware scoped diff/Python checks pass. Core SMT2
  synthesis via verify --synth --target g6lc64_smt2 passes (31 warnings; not STA).
  Previous12-cycle WT-tag proof/checker/cover controls pass again at depths0/2/4
  (wt-tag-fixup-regression-v2-20260919), including the zero-depth branch.
  Broad verify --lint --formal --synth --remote --allow-skips completed RED:
  lint8/54 at baseline and both default synthesis targets pass;10 formal tasks pass.
  Rename ERROR is stale ckpt_ptr_q references at props lines124/150. Fetch-IQ ABC
  reports an assertion failure atframe3, then witness reconstruction fails with a
  z3 BrokenPipeError; cover also errors. Do not relabel that BMC failure as a tool-only
  issue. Logs and raw witness: verification-errors-v2-20260919. Configured smoke
  scripts retain local/installer execution; broad simulation/compliance is not
  claimed. Timed WT leaf UNOPTFLAT remains separate.
  No commits; no fetch_A/smt_legacy model inputs or firmware byte changes.

- [x] AMO commit-ready versus data-ready (2026-09-19): source16M trace reached
  sbi_hsm_hart_start_finish, then LR's placeholder0 was forwarded to BNE before its
  architectural2 result committed. Generic two-hart LR/SC mini reproduces it in
  RVC/norvc (410/420 cycles). issue_read_operands now masks AMO result availability
  after both stored and same-cycle WB selection, behind RVA. Consumer waits for
  committed RF data; no new state/clock/reset/ISA/DTS or LR flush change. New decode
  gate affects issue readiness; no physical timing claim. RVC/norvc pass597/594,
  RS2 and ALU-consumer variants pass, negatives fire. SMT2 and default lint/synth
  pass with recorded warnings; strict standalone slang remains skipped.
- [x] Directed source-built OpenSBI/HSM completion (2026-09-19): the AMO-repaired
  modelcb3aead6... reached primary S-mode and sent the HSM IPI, but existing PMP
  assertion pmp_entry.sv:81 stopped it at12,731,487 cycles. No assertion was disabled.
  Private Verilator split_var control for lzc index_nodes/sel_nodes removes packed-
  array scheduling feedback without changing RTL, vendor files or warning waivers.
  Strict PMP transition checks pass; checker-negative and size-fault controls fail.
  Independent NAPOT match proofs pass PLEN32/56, fault controls fail both. This is
  address-match/simulator evidence, not all-mode PMP or physical qualification.
  Full modelc421aedc... with unchanged ELF6b2bad99... matches ALL18,502,243 retained
  retirement lines before the old assertion stop, then reaches strictDualPassed=true
  at12,765,628 cycles. Hart counts333,635/8,932,406; both supervisor seen flags and
  checked peer result precede explicit tohost success. Artifact:
  opensbi-counter-split-dual-20260919/output/results.json. Compiler control SHA
  be176b279ada076a3459d8bd6509e0946ccf0994d5c35a092bede308bba8c8ff is pinned/copied there.
  Opt-in build recipe uses VERILATOR_TEST_FLAGS=<retained split-counter.vlt>;
  SOURCE_REVIEW_COMPILER_CONTROL verifies the generated input and binds its hash.
  The original soft-ladder ELF remains unchanged, and is not this success oracle.
- [x] Timed WT-tag build blocker resolved for the pinned split-control recipe:
  WT_TAG_COMPILER_CONTROL supplies the private optimization, with UNOPTFLAT still
  an error. Fixture A/B requests now use distinct word offsets in the same cache
  index so accepted response identity is unambiguous. Five positives, five checker
  negatives and five restored-selector faults match at depths0/2/4. Artifacts:
  wt-tag-timed-split-{after,fault}-20260919. No vendor or repo waiver edit. Default
  build policy is NOT changed by this experimental control.
  Superseded by the follow-up below: rename elaboration is repaired; fetch-IQ,
  compliance, generalized liveness and product/physical qualification remain open.
  No further commits.
- [x] OoO ownership continuation (2026-09-19): the current SMT2 pass is OoOEn=0,
  not backend qualification. Reproduced cancelled WB reaching rename busy, IQ
  wakeup and bypass despite suppressed PRF writes. Shared data-valid qualification
  rejects cancelled/exception WB; ROB completion remains separate. Four positives,
  four negatives and four restored-defect controls pass; dispatch16/rename22/LSQ24
  and both illegal hart/FP guards re-pass. Fixed LSQ runtime-bound lane-mask loop
  to iterate constant XLEN byte lanes. Generic live-port area91,242->88,501 cells,
  state6,250 unchanged, zero latches/SCCs. No mapped timing/power or IPC claim.
- [x] Cancelled retirement side effects (plan Phase2, component scope): raw commit
  acknowledgement could poison the committed map, free an owned register and retire
  a replacement checkpoint via a stale cancelled tag. commit_arch now qualifies
  map/free/checkpoint/store effects by the existing cancellation mask, while ROB
  retirement still drains drops. Cases15–17 fail before repair. Both commit lanes
  (including older live + younger cancelled in one cycle) pass six positives and
  six checker negatives; six individual map/free/checkpoint faults fail. Evidence:
  ooo-drop-{before,after,map,free,checkpoint,regression,wb}-20260919;
  ooo-drop-dual-{after,map,free,checkpoint}-20260919. Final generic area86,824 cells,
  state6,250 unchanged, no latches/SCCs. SMT2 fresh regates remain byte-identical to
  passing modelc421aedc...; firmware/scheduler/ISA/DTS/guards unchanged.
- [x] Rename formal harness now reads ckpt_cnt_q and checks ckpt_head_q, rather than
  the removed ckpt_ptr_q. Existing12-step BMC passes; a false-x0 checker has a
  four-step SAT witness. SBY negative witness reconstruction attempts remain archived
  (missing yices, then z3 timeout); neither is passed off as a successful trace.
- [~] Broad follow-up collected:11 formal PASS tasks, fetch-IQ failed/unresolved
  after its assertion witness and cover were interrupted following19+ minutes.
  Default lint8/54 and synthesis32/5 warnings remain; standalone slang skips.
  No full formal/compliance gate is green. Preserve raw IQ witness for diagnosis.
- [ ] Execute the updated plan-ea69493e7a14829a Phases0–9. Next: baseline dual-runnable
  per-hart service/saturation metrics (without boot-policy retuning), actual late
  CSR/AMO PRF data delivery, full-core/TID lifetime closure, then reviewed per-hart
  namespaces and FP register classes. Coldboot retirement imbalance is not a fairness
  metric. Keep predictor, stream/hierarchy, coherence and physical promotion gates
  separate; preserve original hypotheses and failed controls. No new commits.

- [x] Phase1 initial symmetric service baseline (2026-09-19): SMT_BALANCE in the
  existing dual-active fixture checks512 iterations/2,048 ordered body retirements
  per hart, result publication and explicit termination. RVC/norvc and solo0/solo1
  pass; shared/solo RVC text is identical, active data mask differs. Result fault
  is rejected and observer-off replay matches exactly. Unit suite19 passes, with
  empty/drop/duplicate/reorder/wrong-hart controls. Artifact:
  smt2-balance-ordered-20260919. Shared ROI5709/5708 cycles, observed service split
  49.9264%/50.0736%, max body-retirement gap76, weighted speedup0.90234 and worst
  slowdown2.21795x versus solo. Balanced observation is NOT throughput improvement,
  a starvation bound, saturation or Linux qualification. Modelc421aedc... unchanged.
- [x] Phase1 service/handoff/RTT attribution (2026-09-19): read-only observers
  `smt_sched_trace` (g6lc_thread_select.sv) and `smt_rtt_trace` (cva6.sv), both inside
  translate_off, verified by source inspection; synthesized-netlist equivalence and
  physical timing/area were not proved by that inspection.
  smt2-balance-attr-final-20260919 on model 2ce91d639b964cfb…: served 2834/2831,
  ready-denied 2831/2834, never-not-ready 0/0, longest denial 68, quiesce 332 (5.86%),
  **83 starvation handoffs, 0 quantum, 0 miss, 0 abort**, drain wait exactly 3 cycles
  each. The nominal quantum 128 is inert here; the starvation limit is the operative
  control, since it counts waiting cycles and wins first. Cache RTT is still UNMEASURED
  (register-only body; observer alive with 23 events, 0 in-window samples). Boot
  preserved: opensbi-attribution-dual-v3-20260919 strictDualPassed=true at the identical
  12,765,628 cycles and 333,635/8,932,406 retirements; startup and LR/SC regressions pass
  on the same model; 27 unit tests.
- [x] Defect: `core/id_stage.sv` had an UNGATED `[id-dbg]` $display writing ~134 MB into
  every run log, hiding real output and costing the verdict reader time/memory. Now behind
  plusarg `id_dbg_trace` (allowlisted). The earlier claim that it caused or contributed
  to the collector's rc255 is unproven; that run's harness remained alive after the
  connection failed. Keep the log-volume finding separate from transport failure.
- [x] Added opt-in `SOFT_LADDER_BUILD_VLT_ARGS` (default empty) to soft-ladder-build-harness.sh
  so a reviewed Verilator control (the pinned split_var .vlt) can be bound to one candidate
  build without changing default build policy or any waiver.
- [ ] Defect, NOT fixed: `testharness_proxy.py build --vthreads N` is silently ignored for
  non-AI flavours (only plumbed as AI_MATRIX_VERILATOR_THREADS). It produced a 12-thread
  model that the qualification runner correctly rejected. Use
  `--env SOFT_LADDER_VERILATOR_THREADS=1`. Either plumb the flag or make it refuse.
  Likewise the private Verilator runtime must be selected with `--env VERILATOR_ROOT=...`
  or the model silently links the stock runtime and fails the runtime-header gate.
- [x] Shared-core measurement correction (2026-09-19): core capacity is not equal
  thread counts or selected-cycle shares. SMT_ASYM uses atomic last-publisher
  completion so neither hart polls after finishing. Both role orders, RVC/norvc,
  matched solo controls on both harts, exact64/0 own load counts and observer-off
  replays pass (smt2-core-capacity{-norvc,}-20260919).12 positives/2 result negatives/
  4 observer-equivalence controls;36 tooling tests. Fixed the oracle's ignored
  foreign-role body and RTT outstanding-at-window-end accounting with failing tests.
  RVC finite-batch ratios0.92859/0.92649; norvc0.92574/0.92733 versus matched serial
  solo ROIs, so no throughput promotion. The earlier swapped compute tail5743 cycles
  was polluted by a finished hart0 reporter spinning; corrected RVC tail ends at
  3782 ROI cycles. No hardware policy changed. Seven-cycle RTT is not a cache-hit
  oracle (retained hit=00/no-forward lookup samples); no cache-level claim follows.
- [ ] Strict verification remains incomplete after the shared-core review: default
  remote lint8/54 and synth32/5 warning passes; SMT2 lint1/synth31 passes (SMT2 lint
  warnings lack a configured baseline). Standalone-slang checks are unavailable on
  the builder, not accepted as passes. Fetch-IQ formal remains separately open.
- [x] Phase1b counter-ownership probe MEASURED (2026-09-19), artifact
  smt2-pmu-ownership-20260919: SMT_PMU writes distinct mhpmevent3 selectors in a
  handshaked order. Hart1 reads back1 (hart0's) and hart0 reads back2 (hart1's), so
  mhpmevent3 is SHARED; mscratch reads back0x100/0x101, proving the CSR bank works.
  The banked-hypothesis arm and the value-corruption arm both fail as required
  (3 arms, 1 positive + 2 failing-capable controls). Source: g6lc_smt_csr_bank muxes
  perf_addr/data/we by active_hart_i into ONE perf_counters and broadcasts
  scountovf/lcofi to all banks. RISC-V makes mhpmcounterN/mhpmeventN per-hart, so
  this is a CONFORMANCE GAP at NrHarts>1 and a blocker for advertising any PMU or
  fairness hint. Also: any HPM CSR write suppresses all counting that cycle; Sscofpmf
  filtering uses the active hart's privilege on a shared counter; either hart can
  clear a shared OF. mcycle/minstret are banked (minstret gated by commit hart_id),
  but mcycle counts elapsed cycles in every bank and is NOT per-hart service.
- [x] Gap CLOSED (2026-09-19): perf_counters banks generic_counter/mhpmevent/OF/
  MINH/SINH/UINH by a new `hart_i` index sized from the existing CVA6Cfg.NrHarts (no
  new config field; NH=1 unchanged), emits per-hart scountovf/lcofi, and g6lc_smt_csr_bank
  routes element h to bank h instead of broadcasting. Only the owning bank increments,
  so a peer's HPM CSR write no longer suppresses this hart's counting. Chosen over the
  legal read-only-zero option, which would leave the second Linux CPU without counters.
  Exact added state (NH-1)*MHPMCounterNum*(64+8+4) = 456 flops at NH=2; mapped area,
  timing and power NOT measured. Evidence smt2-pmu-banked-v2-20260919 (model
  80ad8af0...): countersArePerHart=true, banked signature (h0=1,h1=0) — hart0 keeps its
  own write, hart1 never sees it — with the shared signature (2,1) as the failing
  control. My initial (0,0) expectation was wrong and the run corrected it. Boot
  preserved: opensbi-pmubank-dual-20260919 strictDualPassed=true, 12,765,628 cycles,
  333,635/8,932,406. Four workload regressions pass, 36 unit tests, and lint/synth
  warning counts unchanged on g6lc64_smt2 (1/31), cv64a6_imafdc_sv39 (8/32), cv32a65x (54/5).
- [x] RV32 user-mode `hpmcounterNh` read repaired (2026-09-19, by inspection): the range
  test used `>` so hpmcounter3h (0xC83) never matched, and the index subtracted the
  MACHINE base CSR_MHPM_COUNTER_3H (0xB83) from a USER address, giving
  0xC84-0xB83+1 = 258 — far outside the [1..MHPMCounterNum] counter array. LIVE, not
  latent: `cv32a6_imac_sv32` is XLEN=32 with PerfCounterEn=1 and RVZihpm=1. That target
  now lints clean remotely (85 warnings; no recorded baseline, so this is a pass and NOT
  a no-regression comparison). RV64 is unaffected: the corrected branch body is guarded
  by `riscv::XLEN == 32`, and the only other statement it reaches sets
  `read_access_exception`, which perf_counters declares and assigns but never reads or
  drives to a port — the architectural exception for RV64 hpmcounterNh comes from
  csr_regfile. No directed RV32 counter test exists; adding one needs an RV32+Zihpm
  simulation profile and is not covered by the current SMT2 flow.
- [x] mcycle semantics checked against the spec of record, NOT a defect: "The mcycle CSR
  counts the number of clock cycles executed by the processor core on which the hart is
  running." Counting core cycles in every hart's bank is therefore conformant; it simply
  cannot be read as that hart's service share. minstret ("instructions the hart has
  retired") is per-hart and is gated by commit hart id, which matches.
- [x] Event attribution MEASURED (2026-09-19), artifact smt2-pmuevt-attrib-20260919:
  SMT_PMUEVT has both harts select "load accesses" in their own mhpmcounter3 and run
  quotas of 256 and 768 loads in a window spanning many handoffs. Measured deltas are
  EXACTLY 256 and 768 — own-hart only, no cross-hart inflation, and no dual-commit
  undercount in this dependent loop. Bounds (not an exact count) are asserted because
  the event ORs commit ports; the ~1024 shared/cross-attributed arm fails, as does the
  corruption arm. So banking the selector is backed by correct per-hart counting.
- [x] Cross-switch attribution MEASURED CLOSED (2026-09-19), artifact
  smt2-pmumiss-isolation-20260919: SMT_PMUMISS has hart0 stride 64 times past the 32 KiB
  D$ while hart1 issues NO memory access but runs long enough to be scheduled throughout.
  hart0 = 64 D$ misses, hart1 = EXACTLY 0; the arm accepting a nonzero hart1 fails, so a
  leak would be caught. Matches the RTL: wt_dcache_missunit pulses miss_o on
  mshr_allocate and g6lc_icache on the accepted ifill — miss INITIATION, not refill
  completion — and the drained handoff needs an empty scoreboard plus no pending stores
  before switching, so a demand memory op cannot span a switch. A one-cycle handoff
  boundary remains un-probed rather than proven impossible.
  Side result: 64 misses for 64 strided accesses confirms the asym workload's stride
  defeats the cache, so its ~7-cycle RTT is a fast-served MISS, not a hit — agreeing
  with the independent WT lookup hit=00 evidence.
- [ ] **FULL-CORE OoO DOES NOT SYNTHESIZE (2026-09-19) — found by building the legal
  baseline.** Added `core/include/g6lc64_ooo_int_config_pkg.sv` (OoOEn=1, NrHarts=1,
  all FP formats cleared so FpPresent=0): the FIRST full-core OoO configuration that
  legally elaborates, since g6lc64_ooo trips !(OoOEn && FpPresent) and _server also
  trips the hart guard. Registered: .licensing-tiers (R), REUSE.toml (Thales template
  derivative group), diag-ooo-int-lint, warningBaselineRemote g6lc64_ooo_int=11.
  LINT PASSES (11 warnings, no guard). SYNTHESIS FAILS: 435 `check -assert` problems,
  a combinational cycle between `issue_read_operands.issue_ack` and
  `i_ooo_dispatch.i_iq.issue_ack_i`.
  LOOPS ARE REAL, not artefacts of the cheap check: the gate runs check -assert after
  only `proc; opt -fast`, and yosys advises -force-detailed-loop-check to rule out
  false positives. That precise run (a one-off check -assert -force-detailed-loop-check,
  ~30 min; the synth gate itself was left unchanged) reported 497 problems — MORE than 435 — so the finding survives the
  strictest available check.
  MECHANISM: g6lc_iq reads issue_ack_i[grants] INSIDE its selection loop (low ack sets
  grants=NrIssuePorts to "preserve age order"), while issue_read_operands derives
  issue_ack_o[p] from the entry the IQ selected and forces ack[p]=0 when ack[p-1] is
  low under SuperscalarEn. Selection depends on ack; ack depends on selection.
  PRE-EXISTING AND STRUCTURAL, not from this package or the commit-mirror repair: the
  component fixture synthesizes at zero SCCs precisely because tb_g6lc_review_dispatch
  ties issue_ack_i to 2'b11, so the loop cannot form there. The documented
  "a fixture PASS cannot replace this" case, now demonstrated.
  FIXED (same day): select-then-confirm, NOT a registered ack. g6lc_iq presents the
  oldest ready candidates as a pure function of queue state (advance `grants`
  unconditionally) and consumes issue_ack_i only in a separate removal block driving
  next-state, so the ack leaves the selection cone. No issue cycle lost.
  Removal drops EXACTLY the acked ports, not a prefix. A prefix rule was written first
  and was WRONG: with an earlier port un-acked it would keep an entry whose own port
  WAS acked, which the consumer already took — duplicate issue next cycle. The
  randomised IQ fixture (scenario 4, deliberately non-prefix ack patterns) caught it.
  Exact-ack removal is correct for any pattern and assumes nothing about the consumer,
  which matters since NrIssuePorts can exceed 1 with SuperscalarEn=0. Under
  SuperscalarEn behaviour is unchanged (issue_read_operands already zeroes ack[p] when
  ack[p-1] is low); dropping "stop scanning after a non-ack" only widens SELECTION.
  RESULT on g6lc64_ooo_int: lint 11 warnings (baseline), synth CLEAN (2 warnings) —
  was 435 problems / 497 detailed. Fixture regressions: 24/24 IQ cases pass including
  the randomised ack scenario; dispatch default set, 11-14, 15-17 and scenario 19 pass
  with REVIEW_RTL_LATERESULT_FAULT=1 still failing as required.
  The tb reference model was updated to the new contract (present up to NP candidates;
  remove exactly the acked ones).
  STILL NOT a finished product: no independent-reference comparison, no boot, no FP.
  Guards reframed: Phase 5 makes g6lc64_ooo ELABORATE; it was never what stopped the
  integrated core from SYNTHESIZING.
  NOTE: an external write at 17:29 clobbered this entry once; re-applied.
- [x] PHASE 4 STEP 1 LANDED (2026-09-19): per-hart rename namespaces in g6lc_rename.
  New NR_HARTS parameter (default 1). map_q/amap_q are [hart][arch]; hart_i per
  dispatch port and commit_hart_i per commit port. free_q/busy_q UNCHANGED and SHARED
  (shared pool is what makes SMT cheaper than two cores; busy is a property of a
  physical register). Checkpoints record their owning hart (ckpt_hart_q) so recovery
  restores only that hart's map, AND ckpt_alloc is marked only for same-hart
  allocations — otherwise a peer hart's allocation after this branch would be squashed
  by this branch's mispredict, reintroducing the aliasing through the RECOVERY path
  rather than the map. x0 never consults the map, so physical 0 stays the shared zero;
  reset gives hart h physicals 31*h+1..31*h+31 and the pool starts at 31*NH+1.
  NR_HARTS=1 reproduces the old bindings exactly (map[0][i]=i, pool from 32) —
  g6lc64_smt2 rebuilds BYTE-IDENTICAL (ba1f8f6a722829aa…).
  PER-HART CHECKPOINT RINGS also landed: ckpt_head_q/ckpt_cnt_q are one ring per hart
  over a static slice (CKPT_PER_HART = CKPT_DEPTH/NH). A shared ring cannot support
  per-hart flush or independent recovery — removing one hart's checkpoints punches a
  hole a head/count pair cannot represent. Capacity/alloc/retire/unwind all per hart;
  the resolving hart comes from ckpt_hart_q[level], so no mispredict-hart input is
  needed. mispredict_level_i is an ABSOLUTE slot while head/count are slice-relative,
  so the unwind converts first. Note: slang rejects `slots_h[hart_i[p]]++` (variable-
  indexed unpacked-array assignment target), so the per-hart group count is derived by
  counting do_ckpt over ports instead — the formal build caught that.
  Verified: rename/dispatch/drop/late-result fixtures pass; rename formal proof passes
  and its checker-negative still yields a counterexample (mutation site re-pointed
  from dut.map_q[0] to dut.map_q[0][0], since the index now means hart0's x0);
  g6lc64_ooo_int lint 11 at baseline and synth clean.
  OWNERSHIP + PER-HART FLUSH landed: owner_q[phys] records the owning hart (set at
  allocation, seeded to the reset bindings). It is what makes flush_hart_i[h] possible
  — the shared freelist records no owner, so a hart park/reset/trap could not otherwise
  tell which registers to reclaim. Per-hart flush restores that hart's map from its own
  amap, returns every physical it owns that its committed map no longer references, and
  clears its checkpoints, leaving the peer live. Ownership is stale on a FREE register,
  which is harmless (allocation overwrites; flush only reclaims non-free).
  TESTED AT NrHarts=2 WITHOUT RELAXING THE GUARD: g6lc_rename is package-free, so
  tb_g6lc_review_rename instantiates it at NR_HARTS=2 (REVIEW_RTL_RENAME_SMT=1,
  -GNR_HARTS=2 -GPRF_ENTRIES=80 -GPRF_W=7; wider PRF needed since 31 committed
  physicals per hart no longer fit in 40). Scenarios 11/12/13 = namespace isolation /
  independent recovery / per-hart flush, with negative controls RENAME_HART_ALIAS,
  RENAME_PEER_SQUASHED, RENAME_HART_FLUSH_SPILL. All 6 cases match — first genuine
  NrHarts>1 evidence in the OoO path. Remaining 3 planned tests (no double allocation,
  per-hart commit, per-hart late-WB) need IQ/ROB/LSQ hart tagging.
  Three rename fault-injection sites had to be re-pointed after the rewrite (leak
  accumulation now hart-qualified; release fault now clamps the per-hart retire count);
  each was caught by its own control failing, not by inspection.
  FULL-CORE RE-VERIFIED AFTER THE RENAME REWORK: g6lc64_ooo_int lint 11 warnings at
  baseline and synth CLEAN (2 warnings) with per-hart maps, per-hart checkpoint rings,
  ownership and per-hart flush all in place — so none of the Phase 4 work reintroduced
  a combinational cycle. Docs updated: sku-matrix.mdx and core/out-of-order.mdx now
  list g6lc64_ooo_int and state plainly that g6lc64_ooo / _server are REFUSED at
  elaboration (FP guard / FP+hart guards), with the baseline marked as a bring-up and
  verification profile rather than a qualified product. branding-g6lc.test.ts requires
  the new package; 219 build-platform tests pass.
  GUARD UNTOUCHED: check_cfg still refuses OoOEn && NrHarts>1 and the fixture negative
  still fails to build. Remaining before the guard can move: IQ/ROB/LSQ hart tagging,
  per-hart cancellation, and physical-register OWNERSHIP for per-hart flush.
- [ ] PHASE 4 (NrHarts>1) SCOPED + VERIFICATION PLAN (2026-09-19), grounded in
  g6lc_rename state. Guard still refuses OoO+SMT and the fixture negative confirms it
  after every change in this pass (REVIEW_RTL_ILLEGAL=smt, -GHARTS=2, must fail to
  build — it does; fp likewise). A per-hart test CANNOT be written yet because
  g6lc_rename has no hart signal to address, so this is the spec to implement against.
  STATE: map_q[31:0] and amap_q[31:0] are ONE namespace -> must go per hart (this is
  the aliasing); free_q and busy_q are shared and STAY shared (a shared physical pool
  is the point of SMT, and busy is a property of a physical register); ckpt_map_q
  must be per hart or hart-tagged so a hart-1 mispredict cannot roll back hart 0;
  rs1_i/rs2_i/rd_i and commit_rd_i need an accompanying hart id.
  HARD PART = PER-HART FLUSH: the shared freelist records no owner, so parking or
  resetting one hart cannot reclaim its physicals without new ownership state. Do NOT
  split the freelist to dodge this — that gives up the shared-pool utilisation that
  justifies SMT.
  TESTS Phase 4 must satisfy, each with a failing control: (1) namespace isolation —
  both harts write their own x5 and read back their own value (fails today by
  construction; headline gate); (2) independent recovery — hart-1 mispredict leaves
  hart 0 untouched; (3) no double allocation from the shared freelist; (4) per-hart
  commit updates only that hart's architectural map; (5) per-hart flush reclaims
  exactly that hart's physicals (needs the ownership state); (6) per-hart late-WB
  invariant carried from the TID-reuse finding — a cancelled hart-1 result must never
  complete, wake or supply data for hart 0, so each FU's suppression must hold PER
  HART, not just per core.
- [ ] PHASE 5 STEP 1 LANDED (2026-09-19): split FP register class in g6lc_rename behind
  FPRF_ENTRIES/FPRF_W (0 = disabled, bit-identical). fmap_q/famap_q per hart,
  ffree_q/fbusy_q as their own pool/busy table, fprs1_o/fprs2_o/fprd_o/fprd_old_o on
  their own ports (the classes index different files, so one shared tag would force
  the consumer to re-derive the class). Separate fwb_*/ffree_*/commit_is_fpr_i paths.
  CHECKPOINTS STAY SHARED: splitting the FILES is not splitting the CONTROL — a branch
  is one program-order event, so one checkpoint snapshots both maps and recovery
  restores both; ckpt_falloc mirrors ckpt_alloc per pool.
  The split is vindicated by the diff: every integer path guards rd!=0/prd!=0 and
  reserves physical 0, while EVERY FP path deliberately has no such guard — f0 is an
  ordinary writable register, its pool starts at 0, its writeback clears busy for
  physical 0, and its committed map covers all 32 entries. A unified file would have
  threaded that exception through shared logic.
  Capacity is per pool, so an FP-heavy group cannot stall out integer allocation.
  rs3 ADDED to rename (rs3_i/is_fpr_rs3_i -> fprs3_o/rs3_ready_o); the caller supplies
  rs3_i from result[4:0] since there is no rs3 field. CLASS-CONFUSION GUARD: the
  intra-group bypass matched rs1_i[p]==rd_i[e] on the architectural NUMBER alone, so
  once FP exists an integer producer could satisfy an FP consumer (x5 vs f5 share a
  number, different registers). do_alloc/do_falloc already separated the PRODUCERS;
  the consumer side now carries !is_fpr_rsN and the FP bypass matches do_falloc. The
  FP bypass omits the rd!=0 filter — an f0 producer must be visible to an f0 consumer.
  FP CLASS TESTED AT FPRF_ENTRIES>0, not merely proven inert when off:
  REVIEW_RTL_RENAME_FP=1 with -GFPRF_ENTRIES=64 -GFPRF_W=7 (again without relaxing
  !(OoOEn && FpPresent)). Scenarios 20/21/22/23 = class isolation (x5 vs f5) /
  f0-is-real / FP recovery restores the pre-branch map / rs3 renames + FP writeback
  clears busy on FP physical 0; negative controls RENAME_FP_CLASS, RENAME_FP_F0,
  RENAME_FP_RECOVER, RENAME_FP_RS3. All 8 cases match. Written BEFORE the dispatch FP
  PRF on purpose: ~370 lines whose only prior evidence was "FP-off unchanged", and
  building the PRF on untested rename logic would compound any error.
  VERIFIED: rename + NR_HARTS=2 + dispatch fixtures pass; rename formal proof passes
  with its checker-negative still failing; g6lc64_smt2 rebuilds BYTE-IDENTICAL.
  NOT DONE (guard stays): FP PRF + rs3 read ports in g6lc_ooo_dispatch, the we_fpr
  commit mirror, FLen-vs-XLEN width, fflags ordering. check_cfg still refuses
  OoOEn && FpPresent.
- [ ] PHASE 5 STEP 2 LANDED (2026-09-19): FP PRF + rs3 path in g6lc_ooo_dispatch.
  Class selectors from is_rd_fpr/is_rs1_fpr/is_rs2_fpr/is_imm_fpr with rs3_a from
  result[4:0]. need_rd NOW INCLUDES FP destinations (it previously excluded them
  outright — that is what "no FP register class" meant in practice), and f0 is not
  exempt the way x0 is. Added tid_is_fpr_q/tid_fprd_q/tid_fold_q per trans_id: a
  writeback carries only a trans_id, so this tells the completion path which file to
  write and which busy bit to clear (wb_value_valid / fwb_value_valid split on it).
  FP PRF has THREE read ports TOTAL muxed to the lowest issue port holding a renamed
  FP op, mirroring the in-order fp_raddr_pack[2:0]. Added issue_op_c_o/valid because
  the rs3 VALUE cannot ride back in result. FP tags added to the scoreboard entry in
  BOTH cva6.sv and the G6LC_SCOREBOARD_ENTRY_T macro (two definitions that must stay
  in sync) plus the dispatch fixture's own minimal copy — the build found all three.
  ** BYTE-IDENTITY INVARIANT LOST, replaced by a stronger check. ** Widening
  scoreboard_entry_t changes every config's netlist including OoOEn=0: g6lc64_smt2 now
  builds to 5a17785f8f309547… instead of ba1f8f6a722829aa…. That invariant had been
  the cheap proof that OoO work cannot disturb SMT2, so losing it matters. Replaced by
  re-running the dual-hart boot gate on the NEW model: strictDualPassed=true,
  333,635/8,932,406 retirements, 12,765,628 cycles — all IDENTICAL. Behaviourally
  neutral, proven not assumed.
  STEP 2b ALSO LANDED: issue_read_operands prefers ooo_op_c_i for operand_c_regfile
  when the op is renamed and is_imm_fpr, mirroring a/b. GPR rs3 (CVXIF offload, Zacas
  AMOCAS rd-as-source) deliberately untouched — only the FP third operand is renamed.
  g6lc64_ooo_int after all of it: lint 11 at baseline, synth CLEAN.
  HONEST LIMIT: g6lc64_ooo_int has FpPresent=0, so its FP PRF elaborates with ONE
  entry and the FP paths are inert. The synth shows the new code does not break the
  integer config or reintroduce a loop; it does NOT show that an FP-enabled full core
  synthesizes, and nothing can until the guard moves. Hence the module-level FP tests
  at FPRF_ENTRIES=64.
  OPEN COST: the four tags are unconditional (following the p_rs1/p_rs2/p_rd
  precedent), so every scoreboard/IQ/ROB entry grows 32 bits even where FP OoO can
  never be used. Conditional widths on (OoOEn && FpPresent) would recover that and
  restore byte-identity, at the cost of conditional-width casts. Optimisation — should
  be measured, not assumed.
- [x] **CORRECTION (2026-09-19): the "testbench blocker" below was MY TARGET CHOICE,
  not an infrastructure blocker.** Makefile picks TB_CPP by target NAME: g6lc* ->
  corev_apu/tb/g6lc_tb.cpp, everything else -> ariane_tb.cpp. g6lc_tb.cpp is ALREADY
  config-aware (G6LC_TB_BANKED defined only when NrHarts>1; G6LC_TB_H1(expr) evaluates
  hart-1/gen_smt reads only on banked builds and compiles to 0 otherwise, with a
  comment warning that a bare hart-1 read silently aliases hart-0 when non-banked).
  Only ariane_tb.cpp has unguarded SMT2/AI probes, and AGENTS-todo ALREADY records
  that ("non-g6lc cv* targets still can't use its hierarchy probes (needs same pass or
  -DG6LC_TB_NO_HIER)") — so this was a KNOWN documented limitation of the cv* path that
  I rediscovered and initially overstated as a new, wider blocker. Every g6lc* target,
  including g6lc64_ooo_int, already builds its testbench at NrHarts=1.
  AND the control needed no new target: g6lc64_smt2 has RVF=1/RVD=1, is in-order
  (OoOEn=0) and already has a validated model.
- [x] **FP TEST IS A QUALIFIED ORACLE (2026-09-19).** run_ooo_fp_review.py on the
  in-order FP model (g6lc64_smt2): PASS "*** SUCCESS *** (tohost = 0) after 2308
  cycles". Negative control FP_REVIEW_NEGATIVE=1 perturbs ONE expected constant — the
  FMA result, a check reachable only if the FP path really ran — and the run FAILS
  ("*** FAILED *** (tohost = 1) after 1747 cycles", different cycle count). The
  negative matters more than the pass: a program that traps before its first check, or
  whose FP ops never execute because mstatus.FS was left clear, exits 0 just as
  convincingly. Runner extracts tohost from the linked binary rather than hard-coding
  it and requires an explicit SUCCESS verdict.
- [ ] **FP ON THE OoO PATH DOES NOT WORK YET (2026-09-19) — reproducible timeout.**
  FP+OoO model built behind a temporary local guard relaxation (guards restored and
  verified; g6lc64_ooo refuses again). TWO defects found:
  (1) PRE-EXISTING CONFIG DEFECT, not FP: the model aborted at time 0 with
  "load_unit.sv:745: DcacheIdWidth parameter is not wide enough to encode pending
  loads". g6lc64_ooo and g6lc64_ooo_int set DcacheIdWidth=1 with NrLoadBufEntries=8
  (needs 3). g6lc64_smt2 ALREADY carries the fix and the explanation ("G1n: hang-7
  raised NrLoadBufEntries to 8; 1-bit D$ rid truncated") — it was never propagated to
  the OoO packages, and nothing caught it because those configs could never reach
  simulation (the assertion is translate_off, so lint and synth pass regardless).
  Both set to 3. Exactly the defect class a runnable baseline exists to find.
  (2) MY ORACLE WAS BROKEN, and the NEGATIVE CONTROL caught it: after the fix both the
  positive AND the negative reported "*** SUCCESS *** (tohost = 0) after 2000000
  cycles" — the cycle CAP. On timeout the driver still prints SUCCESS, so a hang is
  textually indistinguishable from a pass. Without the negative control this would
  have been reported as "FP works on OoO". run_ooo_fp_review.py now requires the
  retired cycle count to be strictly below the cap.
  RESULT WITH THE FIXED ORACLE: in-order FP (g6lc64_smt2) PASS 2,308 cycles; FP+OoO
  (g6lc64_ooo) TIMEOUT at 2,000,000 cycles — does not complete.
  ROOT CAUSE LOCATED (2026-09-19), and it is a gap in THIS Phase-5 work.
  Discriminators: integer test on integer OoO PASS 1,109 cy; integer test on the
  FP-ENABLED OoO model PASS 1,172 cy; FP test on the same model TIMEOUT. So neither FP
  presence nor the OoO path is broken — FP INSTRUCTIONS trigger it. (An earlier reading
  blamed a hang at npc=0x10040; that was a MISREAD — those [boot] lines are a capped
  early-cycle trace, not the stall point.)
  DEFECT: g6lc_iq is wired .wb_valid_i(wb_value_valid), and step 2 redefined that
  signal as INTEGER completions only (`&& !tid_is_fpr_q[...]`), routing FP completions
  to rename's FP busy table via fwb_valid_i but NEVER to the IQ's wakeup. An IQ entry
  waiting on an FP producer is never woken, never issues, and the ROB head never
  retires -> deadlock, exactly the observed timeout.
  FIX APPLIED — DEADLOCK CLEARED. g6lc_iq now takes FPRF_W, fwb_valid_i/fwb_prd_i,
  per-entry FP source tags (fprs1/2/3) and per-source class bits (fpr_rs1/2/3), plus an
  rs3_rdy term. Each source wakes from its own class: integer on wb_prd_i WITH the
  !=0 no-destination guard, FP on fwb_prd_i WITHOUT it (FP physical 0 is real). Same
  split applied to the same-cycle dispatch capture so a new waiter cannot miss an FP
  pulse. FP+OoO went from TIMEOUT at 2,000,000 cycles to completing in ~920.
  SECOND DEFECT NOW EXPOSED UNDERNEATH: the program completes but fails its FIRST
  check. Test extended to report the failing block as its exit code:
  in-order FP SUCCESS 2,420 cy; FP+OoO FAILED (tohost=1) 920 cy = BLOCK 1, the FP
  dependency chain (a straight fadd.d sequence — the simplest FP rename/wakeup case).
  The SAME TAGGED BINARY passes in-order, so the test and its constants are sound and
  the fault is in the OoO FP path.
  BLOCK 1 DIAGNOSED AND FIXED (2026-09-19): FP OPERANDS WERE READ FROM THE WRONG FILE.
  Dispatch assembled op_a/op_b from the INTEGER PRF only, and issue_read_operands
  carried an explicit !(FpPresent && is_rs1_fpr(...)) exclusion sending every FP source
  to the ARCHITECTURAL f-register file, which by construction holds no in-flight
  renamed value -> a dependent fadd.d read a stale operand. Step 2 had wired the FP
  file's THIRD read port to op_c and left rs1/rs2 on the integer path.
  Fix: deliver FP sources from the FP physical file on the same op_a/op_b ports (with
  FP writeback bypass, same for op_c) and drop the exclusion so the renamed value is
  preferred for BOTH classes.
  STRUCTURAL DECISION: the FP file has THREE read ports for the whole group, so at most
  one issue port can read FP operands per cycle; a second FP consumer in the group is
  HELD BACK rather than issued unreadable operands. The gate is applied to the IQ's RAW
  valid, not issue_valid_o — fp_port_sel derives from the raw valid, so gating the
  output would close a combinational loop through the signal being computed.
  RESULT: block 1 PASSES. Evidence is indirect but sound — the negative control, whose
  mutation is in BLOCK 2, now reports FAILED (tohost=2), so it executed block 1's
  checks and got past them; before the fix it could not.
  THIRD DEFECT REMAINS AND IT IS NONDETERMINISTIC. Added FP_REVIEW_STOP_AFTER=N bisect
  (truncates after block N) — needed because a hang produces NO exit code, so unlike a
  wrong result it cannot name its own block. Sweep does NOT converge:
    stop2 SUCCESS | stop3 FAILED block3 | stop4 SUCCESS | stop5 FAILED exit 1337 |
    stop6 FAILED block4
  Blocks 1-2 pass consistently (incl. the chained FMA whose rs3 is an in-flight renamed
  producer). Beyond that the SAME block passes or fails depending only on what code
  FOLLOWS it — the signature of a scheduling-dependent race, not a deterministic logic
  error. EXIT 1337 IS THE SHARPEST DATUM: not a block id, so s11 — an INTEGER register
  — was corrupted. The fault is not confined to the FP class; it leaks into integer
  state.
  ** MY OWN INSTRUMENTATION WAS WRONG FIRST. ** The block id was CARRIED in s11 and
  read at exit — in a test whose purpose is hunting register corruption. Exit 1337
  proved s11 itself corruptible, so every block attribution was suspect. Test now
  materialises the id AT each failure site (fail1:..fail7:, li a0,N); nothing carries
  it through the code under test. Re-run with trustworthy ids gives a DIFFERENT and
  still inconsistent picture:
    stop2 FAILED block2 | stop3 FAILED BLOCK 1 | stop4 FAILED block2 |
    stop5 SUCCESS | stop6 SUCCESS
  Even block 1 fails under one truncation while the two LONGEST variants pass.
  ** THE EARLIER "block 1 now passes" CONCLUSION IS WITHDRAWN ** — it rested on the
  corrupted carrier. Corrected test still passes in-order (SUCCESS 2,322 cy), so the
  oracle is sound; only the OoO attribution was wrong.
  THREE HYPOTHESES ELIMINATED (do not re-derive):
  1. FP destination also consumes an integer physical — DISPROVED by reading
     g6lc_rename: allocation is mutually exclusive (`if (FP…) … else if (…)`).
  2. tid_is_fpr_q goes stale so an integer op is treated as FP at commit (skipping its
     map update and predecessor free) — DISPROVED by directed assertion
     OOO_COMMIT_CLASS_STALE comparing tracked class vs committing opcode: NEVER FIRES.
  3. FP physical 0 / f0 mishandled — DISPROVED in software: rewriting block 3's f0 to
     f20 reproduces the failure BIT FOR BIT (same verdict, same 1,010 cycles).
  ** CAUSE IS NOT FP — THE OoO MEMORY PATH HANGS ON ITS OWN (2026-09-19). **
  Discriminator: run an existing INTEGER test that exercises memory on every model.
    ooo_ilp_chain (pure ALU): in-order PASS 2,315 | ooo_int PASS 1,109 | ooo+FP PASS 1,172
    ooo_mem_dep  (ld/st):     in-order PASS 2,168 | ooo_int TIMEOUT 400k | ooo+FP TIMEOUT 400k
  ooo_mem_dep hangs on the INTEGER-ONLY OoO config — no FP in the design or the
  program. The defect chased through the FP test is PRE-EXISTING IN THE OoO MEMORY
  PATH, not introduced by Phase 5. Never observed because this core had never executed
  a program until today, and ooo_ilp_chain is pure ALU work (which is why the first OoO
  execution looked healthy).
  THIS EXPLAINS THE NONDETERMINISM: the FP test is full of memory traffic (la/fsd/fld +
  runtime), so truncating it changes the load/store pattern and with it whether the
  memory defect is hit. "Same block passes or fails depending on what follows" is what
  a memory-ordering stall looks like through a test not designed to isolate one.
  CONSEQUENCES: (a) the two FP fixes stand on their own evidence (IQ FP wakeup turned a
  hard hang into a completing run; FP operands were demonstrably read from the
  ARCHITECTURAL f-regfile) — both real defects in code I wrote; (b) NO FP correctness
  verdict can be drawn from the current FP runs in EITHER direction while the memory
  path is broken underneath; (c) NEXT TARGET = ooo_mem_dep on g6lc64_ooo_int: FP-free,
  deterministic, reproducible, on a config that is LEGAL TODAY and needs no guard
  relaxation. Fix that before resuming FP bring-up.
  MINIMAL REPRODUCTIONS (verif/tests/custom/ooo/ooo_mem_min.S, -DSTAGE=n, one construct
  per stage) on g6lc64_ooo_int:
    S1 store only .................. PASS 865 cy
    S2 store + load a different line  PASS 860 cy
    S3 store + load SAME address .... PASS 866 cy
    S4 two stores, load the OLDER ... FAILED, WRONG DATA, 891 cy
    S5 store/load in a loop ......... HANG at 200,000
  S1-S3 passing is as informative as S4 failing: stores retire, loads complete, and
  same-address store-to-load forwarding is CORRECT. The defect needs TWO LIVE STORES.
  S5 is a SEPARATE failure (repeated LSQ allocate/free deadlocks) — recorded as two
  defects until evidence links them.
  HYPOTHESIS DISPROVED: S4 stores to 8(sp)/16(sp) which share a cache line, suggesting
  line-granular forwarding. NOT SO — the LSQ hazard query uses same_word(...) plus a
  byte-lane overlap test, so two different words cannot collide there. That same code
  documents it is only the HAZARD decision: "the LSU store_buffer owns the byte-exact
  data forward (full PA + be, both queues, commit handoff)". NEXT LOOK = the LSU
  store_buffer data path, not the queue.
  CHARACTERISED TO ONE CYCLE (2026-09-19). S4 compared two registers so either could
  be at fault; splitting the check and varying ONLY the gap between load and consumer
  isolates it:
    S4  two stores, ld, consumer IMMEDIATELY after ... FAILS
    S10 ONE store,  ld, consumer immediately after ... PASS
    S8  two stores, ld, ONE nop, consumer ............ PASS
    S9  two stores, ld, two nops, consumer ........... PASS
    S6/S7 two stores, ld, multi-instr `li`, consumer . PASS
  The fault needs BOTH a second live store AND a zero-cycle gap before the consumer,
  and ONE independent instruction hides it. That is a ONE-CYCLE EARLY-WAKEUP: with two
  stores live, a load's result reaches its consumer exactly one cycle before it is
  correct.
  WARNING FOR FUTURE PASSES: S6/S7 passed only because `li` of a 64-bit immediate
  expands to several instructions and silently supplied the gap. The apparent "store
  proximity doesn't matter" reading from S7 is therefore NOT evidence either way — the
  gap, not the addressing, was doing the work.
  MECHANISM READ FROM SOURCE: the LSQ computes a PRECISE data-availability gate
  (stl_stall_o: matching older store with !data_v, or an older store whose address is
  unresolved). g6lc_ooo_dispatch computes `mem_stall = md_stall || stl_stall` and then
  passes **.mem_stall_i(1'b0)** to the IQ — the precise gate is CALCULATED AND
  DISCARDED. That is deliberate and documented: feeding it back closes a combinational
  loop (stl_stall <- ld_qaddr <- issue_valid_o <- the gate). The comment argues the
  IQ's per-entry AGE gate covers it (a load is held while any OLDER store is live in
  st_live_mask_i).
  THE MEASUREMENT SAYS THAT SUBSTITUTION IS NOT EQUIVALENT. The age gate is a coarse
  ORDERING proxy: it clears when the older store leaves the live mask, whereas
  stl_stall tracks when the store's DATA is visible to the load path. With one store
  those edges coincide closely enough; with TWO draining, the mask clears one cycle
  before the store_buffer handoff makes data visible, and a load whose consumer is
  immediately adjacent reads the stale value — exactly the "two live stores AND a
  zero-cycle gap, one nop hides it" signature.
  FIX SHAPE: NOT re-enabling stl_stall at select (that is the loop the comment rightly
  refuses). It must act AFTER select — suppress the load's completion/writeback when
  stl_stall says data was not available and let it re-issue, or register the gate and
  hold the consumer's wakeup by a cycle. Both are real design work with a timing cost;
  both gate on this five-instruction reproduction.
  ** TESTED AND REFUTED (2026-09-19). ** The hypothesis predicted that a one-cycle
  more conservative age gate would fix S4, so each store was held live an extra cycle
  (st_live_mask | st_live_mask_q; loads only, so it cannot stall the store drain).
  RESULT WAS WORSE: S3 PASS 866 -> FAILED tohost=0x40002000; S10 PASS 866 -> FAILED
  0x40002000; S4 still FAILED; S5 still HANG. Two previously-passing stages broke and
  the exit value is not a program exit code, so the intervention introduced a
  DIFFERENT fault rather than exposing the original. REVERTED, and the baseline
  re-measured to confirm exact restoration (S3 PASS 866, S4 FAILED, S10 PASS 866).
  So "the age gate clears one cycle early" does NOT survive contact with the design.
  FOURTH HYPOTHESIS ELIMINATED BY TEST rather than argument (with FP-physical double
  allocation, stale tid_is_fpr_q, f0/physical-0). THAT PATTERN IS THE CONCLUSION: the
  OoO memory path is not yielding to source-level reasoning. NEXT STEP = WAVEFORM
  evidence from the five-instruction S4 reproduction (the cycle at which the load's
  data is sampled vs when the store's data becomes visible), NOT a fifth guess.
  ** TRACED (2026-09-19): THE PROTECTION WINDOW ENDS AT COMMIT, BUT VISIBILITY LAGS. **
  Temporary $display probe in g6lc_lsq (SINCE REMOVED — the testharness whitelists
  plusargs so it could not be gated) recorded what the queue actually decides. S4:
    814 ST alloc slot=0 id=15
    816 ST upd   slot=0 id=15 addr=...21d8 data_v=1 data=aaaaaaaabbbbbbbb
    817 ST upd   slot=1 id=16 addr=...21e0 data_v=1 data=ccccccccdddddddd
    818 ST free  slot=0 id=15        <-- store leaves the LSQ
    819 ST free  slot=1 id=16
    820 LD query id=17 addr=...21d8 -> stall=0 fwd=0 data=0
  The load queries the SAME ADDRESS as store id=15, two cycles after it was freed. No
  match => forwards nothing, stalls nothing, goes to memory.
  Stores are freed from the LSQ AT COMMIT, but a committed store's data is still in the
  LSU store_buffer and has not reached the cache. The LSQ's protection window closes at
  commit while VISIBILITY lags behind it, and nothing covers the gap.
  ACCOUNTS FOR EVERYTHING, including what killed the earlier hypotheses: two live
  stores = two store_buffer entries = longer drain, so the load beats it; zero gap =
  load immediately behind; one nop = the cycle the buffer needed. Also explains why
  extending the live mask FAILED — the store is already GONE from the mask's source
  when the load queries, so lingering changes the wrong edge.
  TWO CORRECTIONS TO THAT READING, both from source:
  (a) the trace's `data=0` is NOT the load's result — it is stl_data_o, the LSQ's own
      forward value, and g6lc_ooo_dispatch leaves that port UNCONNECTED
      (`.stl_data_o ()`), exactly as the LSQ comment says (observability only). The
      trace shows what the QUEUE concluded, not what the load received.
  (b) that also RULES OUT the next obvious candidate — that the OoO path completes
      loads from the LSQ forward instead of the store buffer's. It does not; only
      stl_forward_o propagates, and only as observability.
  So the data path is the LSU's in BOTH configs, and store_buffer's
  page_offset_matches_o scans BOTH the speculative and commit queues plus the incoming
  store, which on the face of it should cover the post-commit window in either core.
  WHY THE OoO CORE NEVERTHELESS READS STALE DATA IS NOT YET EXPLAINED — the LSQ trace
  narrowed WHERE to look without settling the mechanism.
  ** THE IN-ORDER/OoO COMPARISON IS CONFOUNDED BY NrHarts (2026-09-19). ** Three
  store-to-load forwarding protections in store_buffer.sv are gated on
  `CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1`: the fwd_keep marking on a spec entry
  a live load forwarded from; the companion rule that such an entry must drain rather
  than be cancelled (G1ah); and the g1ao_hold fallback that re-supplies data when the
  byte merge finds nothing. Their comments date them to the SMT2 work.
    g6lc64_smt2   (the "in-order control"): SuperscalarEn=1 NrHarts=2 -> ACTIVE
    g6lc64_ooo_int(the subject)           : SuperscalarEn=1 NrHarts=1 -> DISABLED
  So control and subject differ in NrHarts as well as OoOEn, and that difference gates
  exactly the store-to-load machinery under suspicion. EVERY "passes in-order, fails
  in OoO" STATEMENT ABOVE IS CONFOUNDED — the discriminating variable may be NrHarts,
  not out-of-order execution.
  ** CONFOUND TESTED — THE OoO CONCLUSION SURVIVES (2026-09-19). ** Clean control =
  g6lc64_ooo_int with ONLY OoOEn flipped to 0: identical NrHarts=1, SuperscalarEn=1,
  identical everything else, so the store_buffer protections stay DISABLED IN BOTH
  ARMS and the single free variable is out-of-order execution.
    stage  | OoOEn=1        | OoOEn=0 (same config)
    S3     | PASS 866       | PASS 900
    S4     | FAILED         | PASS 902
    S5     | HANG           | PASS 1,041
    S10    | PASS 866       | PASS 900
  Both failures disappear when OoOEn alone is cleared. The NrHarts gating IS a real
  methodological hazard (the earlier g6lc64_smt2 comparison genuinely was confounded)
  but it is NOT the cause: with a single-variable control the defects are in the
  OUT-OF-ORDER PATH, and the original conclusion stands on evidence rather than on the
  accident of which baseline was convenient.
  S5 is PROMOTED from "may or may not share a cause" to a SECOND OoO DEFECT: it too
  passes in-order on the identical configuration.
  ** LOCALISED (2026-09-19): THE STORE BUFFER FORWARDS THE WRONG DATA UNDER OoO. **
  Temporary load_unit probe (SINCE REMOVED) logged forward inputs for every load on
  BOTH arms of the OoOEn-only control. Same address ...21d8, same test, same binary:
    in-order (passes): pom=1 fwd_v=1 fwd_be=full fwd_data=aaaaaaaabbbbbbbb  CORRECT
    OoO      (fails) : pom=1 fwd_v=1 fwd_be=full fwd_data=0000000000000001  WRONG
  HAZARD DETECTION IS NOT BROKEN — both arms match the page offset and raise a
  full-coverage forward. What differs is the VALUE the store buffer supplies: the OoO
  load is correctly told "an older store covers your bytes" and then handed the wrong
  bytes.
  THIS INVALIDATES THE FRAMING USED FOR SEVERAL ROUNDS: ordering, wakeup timing, and
  the age-gate-vs-stl_stall question all ask whether the load is HELD LONG ENOUGH,
  when the load is held correctly and simply receives bad data. It also explains why
  one nop hides it — with a cycle of slack the entry is no longer read in the state
  that produces the bad merge.
  ** RETRACTED (2026-09-19): "the first store never reaches the store buffer" IS
  WRONG. ** It came from a `grep … | tail -10` truncated at the TOP, which cut off the
  line that disproves it. Re-reading the SAME log in full:
    817 PUSH paddr=21d8 data=aaaaaaaabbbbbbbb tid=15
    818 PUSH paddr=21e0 data=ccccccccdddddddd tid=16
  BOTH STORES ARE PUSHED, correct addresses, correct data. An independent store_unit
  FSM probe agrees: st_valid=1 at 818 with paddr=21d8 and again at 819 with
  paddr=21e0. Nothing is dropped in dispatch, lsu_bypass, or store_unit.
  ** THE LOAD READS THE WRONG ADDRESS — STALE BASE REGISTER (2026-09-19). ** Reading
  the load-unit log WITHOUT truncation also removes the forwarding story. There is NO
  LSU access to 21d8 anywhere near the test. What there is:
    LSQ queries the test load (tid17) at 0x800221d8  <- correct
    LSU access one cycle earlier          0x80022218
    RESULT tid=17 data=0x1 follows it
  The test opens with `addi sp, sp, -64`:
    before the addi: sp=0x80022210 -> 8(sp) = 0x80022218
    after  the addi: sp=0x800221d0 -> 8(sp) = 0x800221d8
  0x80022218 IS 8(sp) COMPUTED WITH THE PRE-DECREMENT sp. The load's base register is
  STALE: it read sp from before the stack adjustment, addressed a different word and
  returned whatever lived there. The STORES used the CORRECT sp — which is why they
  land at 21d8/21e0 and the load misses both.
  SO THIS IS NOT A STORE-TO-LOAD FORWARDING DEFECT AT ANY LEVEL. It is a RAW HAZARD ON
  THE LOAD'S rs1 THAT THE OoO OPERAND PATH DOES NOT HONOUR; the "full-coverage forward
  of 0x1" is a CORRECT forward for a DIFFERENT address.
  Explains the reproduction shape better than any previous theory: the two stores are
  not the cause but the TIMING, spacing the load from `addi sp` enough to expose the
  window — equally why one nop changes the outcome.
  TWO PATHS COMPUTE THIS LOAD'S ADDRESS AND THEY DISAGREE: dispatch's AGU (LSQ query,
  correct) vs issue_read_operands' operand_a (used by the LSU, stale). That
  disagreement is the defect, squarely in the OoO operand delivery this work touched.
  ** CONFIRMED (2026-09-19). ** Probe re-run carrying the trans_id ON THE ACCESS LINE,
  so the load is identified explicitly rather than by adjacency:
    821 ACCESS tid=17 vaddr=0x80022218   <- stale, pre-decrement 8(sp)
    822 RESULT tid=17 data=0x1
  tid17 is the same load the LSQ queried at 0x800221d8. The two address paths PROVABLY
  disagree for one architectural instruction.
  STATUS: ROOT CAUSE ESTABLISHED. The OoO load path delivers a STALE rs1 to the LSU
  while dispatch's AGU uses the correct value. Everything downstream — "wrong
  forwarded data", the two-store dependency, the one-nop sensitivity — follows from a
  load issued against the WRONG ADDRESS.
  ** FIXED (2026-09-19): THE SCOREBOARD FORWARD WAS OVERRIDING RENAMED OPERANDS. **
  Both paths read the SAME signal (op_a_agu), so they could only diverge downstream —
  and they do, in issue_read_operands:
      if (forward_rs1[i]) fu_data_n[i].operand_a = rs1_res[i];   // ~line 928
  The operand MUX takes operand_a_regfile (which correctly prefers the OoO PRF value)
  and then lets the LEGACY SCOREBOARD FORWARD OVERWRITE IT. Renamed ops were
  explicitly opted in:
      if (CVA6Cfg.OoOEn && issue_instr_i[i].ooo_renamed) begin
        // still allow scoreboard forward for same-cycle precision if valid
        if (rs1_has_raw[i] && rs1_valid[i]) forward_rs1[i] = 1'b1;
  The scoreboard is an IN-ORDER structure that does not track renaming, so its idea of
  "the latest producer of sp" can be STALE for a renamed op — and it wins the MUX.
  Exactly the measured symptom (load got the pre-addi sp).
  Removing that opt-in fixes it:
    S3 PASS 866 -> PASS 866 | S4 FAILED -> ** PASS 878 ** | S5 HANG -> HANG (still) |
    S10 PASS 866 -> PASS 866;  ooo_ilp_chain unchanged 1,109 (no regression).
  IN-ORDER PATH UNAFFECTED, verified BEHAVIOURALLY not by inspection: change sits
  inside if (CVA6Cfg.OoOEn && …), and the qualified SMT2 dual-hart OpenSBI boot on a
  freshly built model gives strictDualPassed=true, 333,635/8,932,406 retirements,
  12,765,628 cycles — IDENTICAL to reference.
- [ ] ** OoO DEFECT 2 (LOOP HANG): CAUSE CONFIRMED — THE IQ AGE GATE DEADLOCKS
  (2026-09-19). ** Isolation in four cheap runs; neither ingredient alone hangs:
    loop, no memory .............. PASS 959
    loop, STORE only ............. PASS 956
    loop, LOAD only .............. PASS 956
    loop, STORE+LOAD same addr ... HANG
  Trigger is DEPTH, not the dependence: 2 iters PASS 869 | 3 iters PASS 877 |
  4 iters HANG | 16 iters HANG. Four iterations is ~28 instructions + prologue against
  NrScoreboardEntries=32 — THE WINDOW FILLS.
  CONFIRMED BY INTERVENTION: disabling the IQ older_st age gate (UNSOUND — removes
  memory ordering; diagnostic only, reverted immediately) makes both complete:
    4-iteration loop  HANG -> PASS 852
    16-iteration loop HANG -> PASS 934
  MECHANISM IMPLIED: a load is held because some store looks OLDER by the circular
  compare
    (TRANS_ID_BITS'(s) - commit_ptr_i) < (q_chain[e].sbe.trans_id - commit_ptr_i)
  while IN-ORDER COMMIT cannot retire that store ahead of the load — neither makes
  progress. A raw modular subtraction only orders correctly while every live trans_id
  lies within ONE WINDOW of commit_ptr; once the loop spreads them around the circle a
  YOUNGER store compares as OLDER. Explains the depth threshold and why BOTH a store
  and a load are needed (the load's own stall is what fills the window).
  ** …AND THE STATE DUMP OVERTURNED THAT READING (2026-09-19). ** Before designing a
  fix, the queue was dumped periodically while stuck:
    [iqd] 40014 cnt=0 commit_ptr=4 st_live=00000000
    [iqd] 60014 cnt=0 commit_ptr=4 st_live=00000000
  THE IQ IS EMPTY AND NO STORE IS LIVE. Nothing is held by the age gate at all — the
  pipeline is fully DRAINED with commit_ptr frozen at 4, and the harness reports "a
  core ran and then stopped retiring" with max INTRA-RUN retirement gap of only 20
  cycles. The core executed, then stopped dead.
  SO THE AGE-GATE CONCLUSION DOES NOT SURVIVE: an empty queue cannot be deadlocked by
  a gate that only blocks queue entries. The disabling experiment CHANGED GLOBAL
  TIMING AND MASKED the fault rather than removing its cause — same as one nop masked
  defect 1. A passing result from an intervention is NOT proof of mechanism when the
  intervention perturbs timing everywhere.
  WHAT THE DUMP DOES ESTABLISH: the hang is NOT in the IQ, NOT in store-to-load
  ordering, NOT in the LSQ — all idle.
  THREE FURTHER PROBES CLOSED IT OUT. The LSQ LOAD queue is empty too (no outstanding
  load). And dispatch reports:
    disp_valid=01 ack=00 can_go=0 ren_stall=0 rob_full=1 iq_full=0 lsq_block=0 flush=0
  ** THE FRONT END IS OFFERING INSTRUCTIONS; DISPATCH REFUSES BECAUSE THE ROB IS
  FULL ** — with IQ empty, both LSQ queues empty, nothing in flight. Four iterations
  is ~28 instructions + prologue against a 32-entry window: exactly where a ROB that
  never frees entries wedges.
  CHAIN: scoreboard head (commit_ptr=4) never completes -> commit never acks ->
  g6lc_rob retires on retire_ack_i(commit_ack_i) so it never frees -> rob_full ->
  dispatch blocks -> pipeline drains and stays drained.
  SO THE DEFECT IS an instruction that ISSUES AND EXECUTES but whose COMPLETION NEVER
  REACHES THE COMMIT POINT. Dumping the scoreboard head names it EXACTLY:
    [sbd] head=4 issued=1 cancelled=0 done(valid)=0 fu=4 op=18 pc=0x800001ec
  fu=4 is CTRL_FLOW and op=18 is NE -> this is the loop's bnez BACK-EDGE.
  ** A BRANCH WAS ISSUED AND NEVER COMPLETED. ** It sits issued, not cancelled, never
  marked valid/done, so commit can never pass it.
  FITS EVERY CONSTRAINT: the loop is the only construct executing the same backward
  branch repeatedly; >=4 iterations is where the predictor first mispredicts it; and a
  stuck branch explains a DRAINED pipeline far better than any memory-ordering story —
  the memory ops all finished, which is why IQ and both LSQ queues are empty.
  STRUCTURAL MISMATCH FOUND WHILE CHASING THIS — REAL, BUT NOT THE CAUSE.
  issue_read_operands derives port-p eligibility from issue_instr_i[p-1]:
      for (p = 1; p < NrIssuePorts; p++) begin
        fus_busy[p] = fus_busy[p-1];
        fus_busy[p].csr = 1'b1;
        unique case (issue_instr_i[p-1].fu)     // <- the PREVIOUS PORT
          CTRL_FLOW: if (SuperscalarEn) fus_busy[p] = '1;
  That is IN-ORDER multi-issue logic assuming the ports hold instructions ADJACENT IN
  PROGRAM ORDER. The OoO IQ presents ANY two ready entries, so the port-1 mask is not
  a sound filter under OoOEn. The FLU (branch/CSR/mult) is port-0 only, so with FLU
  ready fus_busy[1].ctrl_flow=0 — a branch granted to port 1 would be acked, dropped
  from the queue, and never executed. Matches the observed issued && !done branch.
  ** TESTED AND IT IS NOT THE CAUSE. ** Restricting FLU-only ops to slot 0 and
  serializing after a branch (NrIssuePorts=2, so the guard WAS live) changed nothing:
  S5/S15 still hang, ooo_mem_dep still times out, S4 still passes at 878. REVERTED —
  an unvalidated issue restriction costs bandwidth for no measured benefit.
  Recorded as a LATENT SOUNDNESS RISK for when OoO + superscalar issue are both live.
  ** THE FLU RETIRES ONE trans_id PER CYCLE; OoO CAN PRESENT TWO (2026-09-19). **
  Extrapolating the branch path end to end (IQ -> issue_read_operands -> ex_stage ->
  branch_unit -> flu_* -> scoreboard) exposes a sharper mismatch, and the RTL states
  the invariant itself. issue_read_operands emits PER-PORT vectors (alu/branch/csr/aes
  _valid_o); ex_stage combines them:
      assign one_cycle_select = alu_valid_i | branch_valid_i | csr_valid_i | aes_valid_i;
      assign flu_valid_o = |one_cycle_select | mult_valid;        // ONE valid
      flu_trans_id_o = one_cycle_data.trans_id;                    // ONE trans_id
      if (|branch_valid_i) flu_trans_id_o = branch_data.trans_id;  // branch wins
  VECTOR IN, SCALAR OUT. If two FLU-bound one-cycle ops are selected in the same
  cycle, ONE trans_id is written back and the OTHER COMPLETION IS LOST — and a lost
  completion is exactly an entry left issued && !done, which wedges commit, fills the
  ROB and drains the pipeline. That IS the measured state.
  ex_stage documents the invariant: "If port0 is ALU and a later port is also
  one-cycle, ALU0 must write port0's tid … Port1+ ALU uses ALU2 / FPU_WB." The design
  assumes AT MOST ONE FLU-BOUND ONE-CYCLE OP PER CYCLE, achieved by routing port-1 ALU
  to ALU2 and by the in-order fus_busy chain serialising the rest. The OoO IQ selects
  any two ready entries and breaks it — same root as the port-eligibility mismatch,
  one level deeper.
  ** UNFINISHED CHECK ON THE EARLIER EXPERIMENT: ** forcing branches to slot 0 should,
  by this analysis, have let the branch win the FLU (fus_busy[1]='1' after a port-0
  CTRL_FLOW blocks the sibling). It did not clear the hang — but I concluded "the fix
  failed" from the hang PERSISTING WITHOUT RE-PROBING WHICH INSTRUCTION WAS STUCK. If
  this analysis is right the stuck entry should have CHANGED (to the sibling one-cycle
  op that lost the FLU) — a different defect surfacing, not the same one persisting.
  RE-RUN THE SCOREBOARD-HEAD DUMP WITH THAT GUARD IN PLACE; it distinguishes them.
  THAT THEORY ALSO FAILS ON A CLOSER READ: fus_busy[p]='1' is applied after an ALU OR
  a CTRL_FLOW on port p-1 under SuperscalarEn ("One ALU issue/cycle under SS until
  dual-WB clean on OpenSBI"), and fu_busy[i] gates issue_ack[i]. So
  issue_read_operands ALREADY serialises to one FLU-bound op per cycle whatever the IQ
  presents — two FLU completions cannot be selected together. FIVE hypotheses down.

- [x] ** CONFIRMED BY CONFIGURATION: THE HANG IS AN OoO x DUAL-ISSUE INTERACTION
  (2026-09-19). ** Instead of a sixth site-specific theory, the CLASS was tested:
  integer OoO with NrIssuePorts=1 and SuperscalarEn=0, everything else unchanged.
    test                         2-issue OoO        single-issue OoO
    stage 4 (two stores)         PASS 878           PASS 942
    stage 5 (16-iter loop)       HANG               PASS 1,069
    stage 15 (4-iter loop)       HANG               PASS 938
    ooo_mem_dep                  TIMEOUT 400,000    PASS 1,151
    ooo_ilp_chain                PASS 1,109         PASS 1,380
    stages 3,10,11,12,13,14,16   pass               pass
  EVERY stage and BOTH directed tests pass at single issue. The defect is NOT in the
  OoO core proper — rename, IQ, ROB, LSQ and the memory path all behave — but in the
  interaction between OoO selection and issue/execute structures that assume the two
  ports carry PROGRAM-ORDER-ADJACENT instructions. The two catalogued mismatches
  (fus_busy[p] from issue_instr_i[p-1]; scalar flu_valid_o/flu_trans_id_o behind a
  vector one_cycle_select) are members of that class though neither alone is the
  trigger.

- [x] ** FIXED: iq_issue_valid USED BEFORE ITS DECLARATION in g6lc_ooo_dispatch. **
  The IQ instantiation consumes it ~70 lines above where the FP work declared it.
  Verilator accepts this; SLANG DOES NOT — so SYNTHESIS OF g6lc64_ooo_int WAS BROKEN
  by the FP-operand work and the breakage was INVISIBLE TO EVERY SIMULATION RUN.
  Declaration moved up. g6lc64_ooo_int now passes LINT (10 warnings, baseline 11) and
  SYNTHESIS (clean, 2 warnings) again. Lesson: simulation cannot gate synthesis; the
  verify sweep must be run after RTL edits, per AGENTS.md section 0.2.

- [ ] ** PRE-EXISTING, FOUND BY THE SINGLE-ISSUE EXPERIMENT, NOT YET FIXED: **
  issue_read_operands.sv:1304/1337/1341 index raddr_pack[2] UNCONDITIONALLY in the
  Zacas CASQ phase-1 path. With NrIssuePorts=1 the pack is [1:0] and elaboration
  fails ("cannot refer to element 2"). So SINGLE-ISSUE OoO SIMULATES CORRECTLY BUT
  CANNOT BE SYNTHESISED until that indexing is bounded — which is why the config is
  left at 2-issue rather than shipped as the working baseline.
  FIX SHAPE: guard the CASQ phase-1 writes on (NrIssuePorts*OPERANDS_PER_INSTR > 2),
  or size the pack by OPERANDS_PER_INSTR rather than assuming a second issue port.
  SQUARELY PRE-EXISTING OoO, NOT PHASE 5 FALLOUT: S5 hung before the operand fix, the
  ROB completes on wb_valid_i matched by trans_id (untouched by any FP edit), and
  there is NO FP in this configuration at all.
  LESSON (twice now): "age gate deadlocks" and before it "store-to-load forwarding"
  were both adopted from a plausible mechanism PLUS ONE SUPPORTING EXPERIMENT THAT
  PERTURBED TIMING GLOBALLY. The state dumps, which OBSERVE rather than perturb, have
  been right every time.
  Defect 1's fix is UNAFFECTED: it was confirmed by a targeted tid-tagged measurement
  and by stage 4 passing, not by a timing perturbation.
  METHOD NOTE: every conclusion in this investigation that came from a tail/head
  truncated grep must be re-checked against the FULL log. Second self-inflicted
  measurement error this session, after the s11 block-id carrier.
  --- superseded text below ---
  ** (superseded) UNDER OoO THE FIRST OF TWO CLOSE STORES NEVER REACHES
  THE STORE BUFFER. ** Push probe on store_buffer's speculative-queue insert, both
  arms of the OoOEn-only control, identical binary:
    in-order (passes): PUSH 21d8 <- aaaaaaaabbbbbbbb (tid24) AND 21e0 <- cccc.. (tid25)
    OoO      (fails) : PUSH 21e0 <- ccccccccdddddddd (tid16) ONLY
  THE FIRST STORE IS LOST — not mis-ordered, not mis-forwarded, not early: it never
  arrives. The LSQ had it correctly (slot0 id15 addr=21d8 data_v=1 data=aaaa..), so it
  resolved inside the OoO queue and was dropped on the way to the LSU.
  EXPLAINS EVERYTHING: wrong forwarded data (buffer never held aaaa.., so a later load
  merges the stale 0x1 with full coverage); needs two live stores (with one there is
  nothing to drop); one nop hides it (separating them lets both through); plausibly
  the S5 loop hang (repeated drops); and why EVERY ordering-side hypothesis failed —
  the load path was working correctly all along.
  The earlier "LSQ protection window closes at commit" reading is NOT the cause: a
  real property of the queue, but the defect is UPSTREAM of it.
  FIRST CANDIDATE MECHANISM TESTED AND ELIMINATED: dispatch IS correctly per-port
  (agu_valid[p], st_data[p], st_data_id[p] are vectors; the only scalar, vaddr_x, is
  written and consumed inside one loop iteration). But the LSU has a single memory
  pipe and the IQ select loop constrains only LOADS (behind older stores) — nothing
  stops it granting two memory ops in one cycle. Looked like the drop.
  Adding a one-memory-op-per-cycle grant to the IQ changed NOTHING: S4 still failed at
  EXACTLY 894 cycles, S5 still hung, byte-identical to baseline. Identical cycle counts
  => the gate NEVER FIRED => the two stores were never granted in the same cycle.
  REVERTED.
  So the store is lost between a correctly-presented dispatch handshake and the
  store_buffer push, and NOT because two memory ops competed for the pipe.
  DISPATCH PRESENTS BOTH STORES CORRECTLY (AGU probe, since removed):
    816 AGU p=0 st=1 addr=21d8 tid=15 | st_data_v=1 data=aaaaaaaabbbbbbbb
    817 AGU p=0 st=1 addr=21e0 tid=16 | st_data_v=1 data=ccccccccdddddddd
    820 AGU p=0 st=0 addr=21d8 tid=17   <- the load
  Both presented, both on PORT 0, on CONSECUTIVE CYCLES, each with valid addr+data.
  Only tid=16 reaches the store buffer.
  SHARPENS THE TRIGGER AND CORRECTS THE EARLIER GUESS: not two memory ops in one cycle
  competing for one pipe — TWO STORES ON BACK-TO-BACK CYCLES, AND THE FIRST IS LOST.
  The survivor is the SECOND, which is what an overwritten staging register does, not
  what an arbiter does.
  SO THE LOSS IS INSIDE THE LSU STORE PATH, between agu_valid/st_data_v at the
  dispatch boundary and valid_i at store_buffer — load_store_unit / store_unit.
  TWO STRUCTURAL FACTS BOUND THAT SPAN (read from source):
   * store_unit IS A TWO-CYCLE FSM: IDLE asserts pop_st_o + translation_req_o and goes
     to VALID_STORE; it cannot absorb a second store on the very next cycle.
   * BACKPRESSURE EXISTS IN PRINCIPLE: lsu_ready_o is NOT constant — it comes from the
     lsu_bypass queue (consumes pop_ld/pop_st, emits lsu_ctrl_o + ready_o), and
     issue_read_operands genuinely honours it (!lsu_ready_i sets fus_busy[0].load/
     .store, which gates issue_ack).
  OPEN CONTRADICTION: both stores were ACKED by issue (that is what makes agu_valid
  fire in dispatch), so lsu_ready_i was HIGH on both cycles — yet only one reached the
  buffer. Either the bypass queue reported ready when it could not hold the store, or
  it accepted both and lost one internally.
  THE QUEUE RESOLVES THE CONTRADICTION AND IS NOT THE CULPRIT. lsu_bypass.sv:
    assign empty = (status_cnt_q == 0);  assign ready_o = empty;
  ready_o means EMPTY, not HAS SPACE, and status_cnt_q is REGISTERED. So both observed
  cycles are legitimate:
   816: queue empty, ready high, store1 accepted; store_unit is in IDLE so it asserts
        pop_st the SAME cycle -> push and pop cancel, count stays 0, ready stays high.
        Store1 is now INSIDE store_unit, in VALID_STORE.
   817: ready still high, store2 accepted INTO THE QUEUE; store_unit busy in
        VALID_STORE so it does not pop -> count rises, ready drops afterwards.
  Both stores legitimately in flight: STORE1 HELD IN store_unit, STORE2 IN lsu_bypass.
  Nothing overwritten; no ready signal lied. THIS INVERTS the earlier "overwritten
  staging register" reading.
  RELOCATES THE LOSS PRECISELY: the store that REACHES the buffer is STORE2 (via the
  queue). STORE1 — the one store_unit had already accepted — IS THE ONE THAT
  DISAPPEARS. So the defect is inside store_unit's VALID_STORE handling: not
  arbitration, not the queue, not backpressure.
  FINAL PROBE (one module, one state): store_unit's FSM for store1 — does it reach the
  st_valid push at all, and if not, which of translation / store-buffer-space / flush
  diverts it?
  HARNESS DEFECT ALSO FIXED: a FAILED verdict was reported as timedOut because the
  timeout test keyed on the absence of a SUCCESS cycle count. A completed failing run
  is not a stall; conflating them hides the wrong-result signal the bisect depends on.
  Guards restored/verified after each measurement; IQ + dispatch fixtures pass, FP-off
  path unchanged.
  WHY THE MODULE TESTS MISSED IT: rename's busy table WAS updated correctly, and that
  is all those tests observe. The IQ wakeup path only exists at integration.
- [ ] Superseded framing (kept for the record): corev_apu/tb/ariane_tb.cpp is
  hard-bound to the g6lc64_smt2 hierarchy. Found by attempting the
  in-order FP control run (cv64a6_imafdc_sv39): the build fails at C++ compile with
  "Variane_testharness___024root has no member named …" for probes that exist only in
  that configuration — i_smt_thread_select.gen_smt.active_q;
  csr_regfile_i.gen_banked.gen_csr[0/1].i_csr.{mepc_q,mtvec_q,mcause_q,wfi_q};
  i_ariane_regfile.gen_banked.gen_hart_bank[0/1].i_rf_bank.mem; the
  i_sram.gen_cut[0]…i_tc_sram.sram cut names and the dual-hart b1/b2/b3, ra1/sp1/s01
  locals derived from them.
  The file ALREADY guards optional features this way (#if defined(G6LC_HAVE_LITEDRAM),
  #if VM_TRACE) — the SMT2 probes were just never put behind one, because dual-hart is
  the only config ever simulated through this harness.
  CONSEQUENCE IS WIDER THAN PHASE5: it blocks the FP control run, the FP OoO bring-up,
  AND the outstanding "full-core OoO baseline vs an independent reference" item — all
  three need a model for a non-SMT2 target.
  FIX (bounded, follows existing precedent): put the SMT2 hierarchy probes behind a
  G6LC_HAVE_SMT2-style define supplied by the build for that target. Shared testbench
  work — do it deliberately, not folded into an FP change.
- [x] MEASURED (2026-09-19): THE FP-ENABLED FULL CORE ELABORATES AND SYNTHESIZES.
  Guard temporarily disabled LOCALLY, measurement taken, BOTH sites restored and
  verified (g6lc64_ooo refused again, no TEMPORARY markers left). Shipped legality
  contract unchanged — evidence to inform the decision, not the decision.
  g6lc64_ooo (RVF=RVD=1, OoOEn=1): lint 10 warnings NO GUARD FIRED; synth CLEAN
  (32 warnings). FIRST TIME g6lc64_ooo HAS EVER ELABORATED — before Phase 5 it could
  not pass check_cfg, so it had never been linted or synthesized at all. The split FP
  class, FP PRF, rs3/op_c path and widened sbe hold at full-core scale with no
  combinational loop.
  SECOND GUARD FOUND: the refusal is enforced in TWO places — check_cfg AND an
  elaboration $error inside g6lc_ooo_dispatch (gen_err_ooo_fp). Only the first was
  known when Phase 5 was scoped. The dispatch guard's message is now FACTUALLY STALE
  ("FP destinations are not renamed or tracked" — they now are). Both must be updated
  together; the note above them is what caused them to be found rather than bypassed.
  GUARD MESSAGES REWRITTEN in BOTH copies (check_cfg + g6lc_ooo_dispatch):
  NrHarts>1 was "no per-hart rename namespace" -> now "OoO IQ/ROB/LSQ are hart-blind:
  aliases memory ordering and forwarding"; FpPresent was "no FP register class" -> now
  "FP register class is implemented but unqualified: no FP simulation or reference
  comparison". A guard that misstates its reason is how a stale refusal outlives the
  work AND how the real remaining risk gets lost — the hart case is sharper: per-hart
  rename exists and is tested, but IQ/ROB/LSQ are hart-blind, so a load can be ordered
  against and FORWARDED FROM the peer hart's speculative stores, which is a different
  and more dangerous defect than a shared rename map. The refusal harness matches on
  this text, so the rewording failed the illegal-config negatives immediately rather
  than passing against a different guard; expectations updated to 'hart-blind' and
  'implemented but unqualified'.
  JUSTIFICATION FOR THE GUARD HAS CHANGED though the guard stays: no longer "there is
  no FP register class" but "the FP class exists, elaborates and synthesizes, but has
  never been simulated, booted, or compared against an independent reference". Weaker
  and much more specific — that is what the next step must close.
- [x] PHASE 5 STEP 4 RESOLVED (2026-09-19), both halves without new datapath.
  fflags ORDERING IS CORRECT BY CONSTRUCTION: flags are not applied at execute; they
  ride in the sbe as ex.cause[4:0] and commit_stage writes them to the CSR at COMMIT,
  ORing port0/port1 in program order for a dual commit. OoO does not reorder commit
  (the ROB retires in order), so the accumulation point is already ordered.
  FLen > XLEN IS UNREACHABLE and now stated rather than latent: the OoO FP writeback
  narrows the XLEN bus (fprf_wdata = wb_data_i[FLen-1:0]), so an FP result wider than
  the integer datapath cannot be delivered. RV32+D is legal RISC-V but no configured
  target does it (every RV32 package has RVD=0), and THE IN-ORDER PATH HAS THE
  IDENTICAL CONSTRUCT (fp_wdata_pack = wdata_i[FLen-1:0]) — pre-existing, not
  introduced here. Added `assert (!(Cfg.OoOEn && Cfg.FpPresent && Cfg.FLen > Cfg.XLEN))`
  rather than inventing a 64-bit-result-on-32-bit-bus mechanism for a config nobody
  builds; widening the writeback bus is the fix if RV32+D is ever wanted. All existing
  targets lint at their recorded baselines with it in place (cv64a6 8, cv32a65x 54,
  g6lc64_ooo_int 11, g6lc64_smt2 1), so it excludes nothing that exists.
  REMAINING = THE GUARD ITSELF. Every listed prerequisite is addressed, but relaxing a
  legality guard is a deliberate decision: FP evidence is MODULE-LEVEL ONLY and no
  full-core FP config has ever elaborated, let alone booted. Moving the guard STARTS
  that qualification; it must not be recorded as completing it.
- [x] PHASE 5 STEP 3 RESOLVED AS "NOT NEEDED" (2026-09-19) — better than adding the
  port. The FP PRF needs NO commit-write mirror: the integer mirror exists only
  because commit_stage SUBSTITUTES a value at commit (csr_rdata_i for CSR,
  amo_resp_i.result for AMO) that never reaches wb_data_i. Neither CSR nor AMO has an
  FP destination (is_rd_fpr excludes both), and for an FP destination commit_stage
  writes plain commit_instr.result — the value the execute writeback already delivered
  to the FP PRF. So no FP value is produced at commit and no FP write port is needed,
  which matters because PRF ports are the measured area driver.
  The soundness rests on the two classes being mutually exclusive at commit, enforced
  by an if/else on is_rd_fpr in commit_stage — SOMEONE ELSE'S code, so it is pinned by
  a translate_off assertion in dispatch (OOO_COMMIT_CLASS) rather than a comment: if it
  broke, the integer mirror would silently write the integer PRF for an FP destination.
  STEP 2 CONSTRAINTS VERIFIED IN SOURCE BEFORE CODING (neither is guessable):
  (1) rs3 has NO field of its own — its architectural index rides in
  `sbe.result[4:0]`, read by issue_read_operands as issue_instr_i[i].result[4:0].
  is_imm_fpr covers FADD:FSUB as well as FMADD:FNMADD and vector pack ops (upstream
  comment: "ternary operations encode the rs3 address in the imm field, also
  add/sub"), so this is the COMMON case for FP compute, not an FMA corner. The
  overload is disjoint by FU, which is what makes it workable: the dispatch AGU uses
  sbe.result as the IMMEDIATE but only for fu==LOAD/STORE, and FP loads (FLD:FLB) are
  is_rd_fpr WITHOUT being is_imm_fpr. Consequence: dispatch must rename result[4:0]
  through the FP map and deliver the VALUE on a new issue_op_c_o path (the op_a/op_b
  analogue), with issue_read_operands preferring it over operand_c_regfile — the value
  cannot ride back in `result`, which still holds the register number.
  (2) The in-order FP regfile has THREE READ PORTS TOTAL, not three per issue port:
  fp_raddr_pack is [2:0], muxed to whichever issue port holds the FP op, so only one
  FP instruction reads per cycle today. DECISION: mirror that in the OoO FP PRF (3
  ports, muxed) rather than 3 per issue port. Measured PRF port cost (one write port =
  7,681 cells, ~8.9%) makes the wide version expensive, and widening it would smuggle
  a PERFORMANCE change in alongside a correctness feature. Dual-issue FP is a separate,
  measurable decision.
- [ ] PHASE 5 SCOPED (2026-09-19) from verified source, not guessed. g6lc_rename.sv has
  NO FP notion (no is_rd_fpr/fpr/FpPresent); rename, busy table and freelist treat all
  destinations as one integer class. Items: (1) rename keys on {is_fpr, rd} = 64 arch
  entries, and the `prd != 0` / physical-0-means-no-destination convention must become
  class-aware because integer x0 is hardwired zero while FP f0 is an ordinary writable
  register; (2) FMA needs rs3 — issue_read_operands already has rs3/rs3_fpr/operand_c,
  but g6lc_ooo_dispatch reads only NP*2 operands, so the PRF needs NP*3 read ports on
  top of the commit write port just added; (3) THE NEW COMMIT MIRROR COVERS we_gpr_i
  ONLY — commit_stage drives a separate we_fpr_o, so FP destinations would not be
  mirrored; deliberate while FP is refused at elaboration, but part of Phase 5; (4) FP
  is FLen wide vs XLEN PRF — equal for RV64D, not for RVF-only RV64, so widen or split;
  (5) fflags ordering vs OoO retirement needs its own check.
  OPEN DESIGN CHOICE, settle before coding: unified PRF (one freelist/write-port set,
  but widened entries and the f0 exception threaded through shared logic) vs split
  int/FP files (keeps the integer path bit-identical, which matters since OoOEn=0 must
  stay bit-identical and the integer OoO path is the one under test, at the cost of a
  second freelist and recovery structure).
- [ ] DECISION (2026-09-19, user): do NOT add an integer-only OoO config; the
  elaboration guard stays as the intended refusal and a legal full-core OoO baseline
  waits for Phase5. Ordering: `g6lc64_ooo` already has NrHarts=1, so the hart guard
  passes and the ONLY failure is `assert(!(OoOEn && FpPresent))` (RVF=RVD=1). So
  PHASE 5 ALONE makes g6lc64_ooo legal and unblocks the full-core OoO baseline;
  Phase 4 per-hart namespaces are needed for g6lc64_ooo_server (NrHarts=2) and for
  mixed residency, not for this target. Independent paths, either order.
- [x] **OoO DEFECT CONFIRMED AND REPAIRED (2026-09-19): CSR and LR results never reached
  the PRF under OoOEn=1.** REPAIR: g6lc_ooo_dispatch mirrors the architectural commit
  write into the PRF; issue_stage feeds it the same we_gpr_i/wdata_i the architectural
  regfile gets, keyed by commit_prd[c] — the committing instruction's OWN physical
  register, NOT a trans_id (keying on trans_id would reintroduce the aliasing the
  TID-reuse invariant prevents). g6lc_prf gives the highest write port priority, so the
  mirror is appended after the execute writebacks and architectural truth wins a clash.
  Mirrors every committed write rather than decoding CSR/AMO, so the contract is
  future-proof. No exclusivity proof existed for reusing a WB port at commit, so a port
  was added and its cost MEASURED: one mirror port = 94,505 generic cells vs 97,439 for
  one-per-commit-port (paired measurement; previously recorded baseline 86,824), state
  6,250 bits and 0 latches/SCCs in all. Only commit port 0 can carry a commit-produced
  value, so PRF_MIRROR=1 except under RVZacas (0 here) — saves 2,934 cells.
  VERIFIED: scenario 19 passes; REVIEW_RTL_LATERESULT_FAULT=1 restores the defect and it
  fails again; scenarios 11-14, 15-17 and the default dispatch set with negatives pass;
  TID-reuse probe unchanged; g6lc64_smt2 rebuilds BYTE-IDENTICAL (ba1f8f6a722829aa…), so
  the OoOEn=0 path and the dual-hart boot gate are untouched.
- [x] Original finding, for history (2026-09-19): CSR and LR results never reach the PRF
  under OoOEn=1. Artifact ooo-lateresult-confirmed-20260919 (matched=true vs expected error
  DISPATCH_LATERESULT), tb_g6lc_review_dispatch scenario 19 via REVIEW_RTL_LATERESULT=1:
  producer writes back only placeholder 0x0BAD, commit supplies architectural 0x1234,
  and the renamed consumer READ 0x0BAD. Reachability verified end to end — including
  issue_read_operands selecting `(OoOEn && ooo_renamed) ? ooo_op_a_i : rdata`, so the
  PRF operand overrides the architectural regfile read. Chain: (1) g6lc_ooo_dispatch writes the
  PRF only from the execute writeback bus (`prf_wdata[w]=wb_data_i[w]`), with NO
  commit-time PRF write; (2) commit_stage substitutes the architectural result at
  COMMIT into the ARCHITECTURAL regfile (`wdata_o[0]=csr_rdata_i` for CSR,
  `=amo_resp_i.result` for AMO), overriding commit_instr.result and never touching
  wb_data_i; (3) EVERY dispatched instruction is renamed
  (`ooo_renamed = can_go && dispatch_valid_i[p]`, no CSR/AMO exclusion) and renamed
  consumers read operands from the PRF; (4) no commit flush covers it — flush_commit_o
  is asserted for SC and RMW but EXPLICITLY NOT for LR
  (`if(!is_amo_lr(op)) flush_commit_o=...`), and not for CSR at all.
  Result: a consumer renamed against a CSR read or an LR destination gets the
  execute-stage placeholder with no flush to squash it. Same defect class as the
  in-order LR bug already fixed; the in-order fix does NOT cover the OoO path.
  Unlike the TID-reuse item below this is real on all three counts: fixture-confirmed
  mechanism, verified reachability chain, and a masking invariant actively searched for
  and found explicitly absent for exactly CSR and LR.
  Repair direction once confirmed: deliver the architectural result to the PRF, either
  as a real late writeback on the existing bus or a commit-time PRF write; do not add a
  PRF write port without proving an existing one cannot be reused.
- [x] **Supersession (2026-09-20): the following reachability conclusion was
  incomplete.** The live firmware and bypass/load-unit reproducer demonstrate
  cancelled pre-grant loads surviving TID reuse. The queue repair and bounded
  checks are in the current reviewed increment above; all-FU coverage stays open.
- [x] **Historical CORRECTED (2026-09-19): the TID-reuse finding below is a LATENT CONTRACT
  DEPENDENCY, not a live defect.** FU survey shows no current writeback source can
  produce the injected stimulus: `load_unit` keeps a STICKY per-slot `ldbuf_flushed_q`
  (set for all slots on flush, for TID-matching slots on cancelled_mask_i) and frees a
  slot ONLY when its response actually returns, so a flushed load's slot cannot be
  reallocated while outstanding; `mult`/`serdiv` gate on `~flush_i`; ALU/branch/CSR have
  no in-flight state; CvxifEn=0 in g6lc64_ooo_config_pkg. The load unit therefore
  already implements repair option 2 one level down, which makes option 2 redundant at
  dispatch and option 1 (generation tag on every FU writeback) unjustified.
  REAL FINDING = hidden coupling: dispatch qualifies writebacks only with
  `!cancelled_mask_i[wb_id_i[w]]`, released when the id is dropped, so it depends on an
  unstated invariant — NO FU MAY PRESENT A WRITEBACK FOR A FLUSHED/CANCELLED trans_id,
  enforced with state that survives the mask's release. Dispatch structurally CANNOT
  detect the reuse case (the new owner is also awaiting a writeback), so only an
  end-to-end generation tag could; that is the cost of relaxing the invariant.
  ACTION: invariant now documented; re-check it for any new writeback source (CVXIF,
  accelerator, Phase 4 mixed residency with per-hart cancellation). Scenario 18 is kept
  as a contract probe recorded as an expected failure, not a passing gate.
- [ ] Probe retained (2026-09-19): late writeback after trans_id reuse.
  Artifact ooo-tidreuse-confirmed-20260919 (matched=true against expected error
  DISPATCH_TIDREUSE). New `tb_g6lc_review_dispatch` scenario 18, selected by
  REVIEW_RTL_TIDREUSE=1. g6lc_ooo_dispatch qualifies writebacks only with
  `!cancelled_mask_i[wb_id_i[w]]`, indexed by trans_id; once a cancelled id is dropped
  and reallocated, its cancel bit clears and a late result for the OLD owner is
  indistinguishable from the NEW owner's completion. Measured: stale 0xDEAD woke the
  new owner's consumer AND was supplied as its operand. Worse than a spurious wake —
  the dropped victim's physical register is correctly freed and reallocated (scenario
  16 proves that), so the stale result lands on the live owner's own register. My first
  setup assertion demanded those registers differ; that was wrong and was removed.
  Repair options, NEITHER implemented: (1) carry an allocation generation on the
  writeback — exact, non-stalling, but widens every FU writeback interface; (2) do not
  reuse a trans_id while a result for it may be outstanding — no interface change and
  no new PRF port, but stalls id reuse and needs a bounded guarantee that every issued
  FU operation returns or is positively killed, else it can deadlock. Option 2 preferred
  on interface grounds once the drain guarantee is established.
  OoOEn=0 remains default, so this is a PROMOTION BLOCKER, not a shipping defect.
- [x] Memory-service sweep MEASURED (2026-09-19), artifacts smt2-memsweep-d{16,64,256}
  -20260919 and -rtt-d{16,256}-: SMT2_REVIEW_MEM_DEPTH retargets the memory role
  (stride 1024 over a 256 KiB buffer, expected sum recomputed per depth). Ratios
  0.9557/0.9551 -> 0.9286/0.9265 -> 0.9028/0.9057 at depth 16/64/256, i.e. sharing gets
  MONOTONICALLY WORSE with memory pressure, the opposite of the textbook SMT
  expectation. RTT rules out interference: median AND max load latency are 7 cycles in
  every configuration (depth 16 or 256, shared or solo, 16/189/256 paired samples), so
  latency does not grow — only the serialised stall time does, unoverlapped.
  Sizes the Phase 4 prize: ~7 idle cycles x 256 iterations is ~1800 cycles of idle
  issue inside a 6853-cycle shared run. Existing switch-on-miss cannot take it —
  MISS_STALL_THRESH is 32 SUSTAINED stall cycles with a 16-cycle blackout, so a 7-cycle
  stall never qualifies; lowering it would not help since a drained handoff costs ~3
  cycles plus refetch and would drain straight back. Only mixed residency can.
  PHASE 1 CLOSED.
- [x] Idle-sibling + per-hart IPI wake MEASURED (2026-09-19), artifact
  smt2-ipi-wake-20260919: SMT_IPI parks hart1 in WFI (MSIE set, mstatus.MIE clear so it
  resumes in place), runs hart0's 512-iteration body beside it, wakes the peer via its
  own CLINT MSIP at 0x02000004, and has hart0 assert its OWN mip.MSIP stays clear so
  per-hart routing is checked. Oracle refuses a halted peer retiring measured work
  (unit test proves it bites). Result: 2082 vs 2061 cycles = 1.0102x, peer retired 0,
  IPI woke only the target. 40 tooling tests.
  PHASE 1 SET COMPLETE — cost is located: halted sibling 1.01x (free), spinning 2.16x
  (-> 1.37x with the hint), runnable ~2x with batch 0.90-0.93 and zero overlap. The
  penalty is time-slicing a RUNNABLE sibling, not SMT structure, so only Phase4 mixed
  residency and the landed yield hint have anything to win.
- [x] Zihintpause YIELD HINT IMPLEMENTED + qualified (2026-09-19), model ba1f8f6a...,
  artifacts smt2-pausehint-lock-{nohint,hint-v2}-20260919 and
  smt2-pausehint-inert-oldmodel-20260919. id_stage recovers PAUSE (0x0100000F; the
  decoder folds it into a NOP) and pulses a per-hart hint; g6lc_thread_select holds a
  sticky per-hart yield request, cleared on that hart's next ACTIVATION TRANSITION (a
  plain active-cycle clear would erase the hint in the cycle it is set), and hands the
  core to an UNPAUSED ready peer. Ranked below anti-starvation so it cannot deny the
  service floor; needs an unpaused peer so two yielding harts cannot ping-pong;
  advisory only. Gated by existing ZihintpauseEn && NrHarts>1 — no new config field.
  Result: holder section 4462 -> 2837 cycles, 2.1618x -> 1.3719x, mutual exclusion
  still proven. NO-OP CONTROL: pre-change model d3b95654 on identical source gives
  4462/2148/2064/2066 exactly, so the RTL is inert without hints. Boot preserved at
  12,765,628 cycles with 333,635/8,932,406. Lint/synth unchanged (smt2 1/31, cv64a6
  8/32, cv32a65x 54/5); 38 tooling tests. Residual 1.37x is the starvation floor by
  design. Note: drain_reason widened 3->4 bits, so the [smt-sched] trace and its parser
  and fixtures moved to 4-bit reasons with `yield` as the new MSB.
  NOT done: WFI-based yield, any Linux/firmware use, no scheduling default changed.
- [ ] ORDERING (2026-09-19, evidence-driven): biased fetch, RS/IQ partitioning, leftover
  front-end slots and FU issue fallback are now **Phase4-gated** in the plan. Three
  paired batches bound the current design — symmetric 0.902, compute/memory 0.929/0.926,
  dependency-limited 0.8985 — so the canonical SMT win case is the worst, with zero
  instruction-level overlap and every handoff already on anti-starvation. Do NOT tune
  those mechanisms before Phase4 mixed residency; a gain measured now is an artifact.
  Only the yield/pause hint precedes Phase4 (lock holder pays 2.3456x for a waiter that
  produces nothing, recoverable by admission control alone). Sequence: yield/pause hint
  -> Phase4 mixed residency -> redistribution mechanisms + QoS.
- [x] Dependency-limited pairing MEASURED (2026-09-19), artifact
  smt2-dep-ceiling-v5-20260919: SMT_DEP reuses the asym oracle with roles `dep` (three
  multiplies chained through one register per iteration) and `ind` (same instruction
  count, independent destinations), 512 iterations, solo controls per role per hart.
  Premise holds: solo dep=4123 cycles vs ind=3108 for 2560 body retirements = 0.62 vs
  0.82 IPC, so genuine issue slack exists. Batch ratio 0.8985 in BOTH role orders —
  worse than compute/memory (0.929/0.926). ROI windows overlap 6872 of 8048 cycles
  while instruction-level overlap is zero.
  KEY NEGATIVE RESULT: the canonical SMT win case returns nothing, so biased fetch,
  quantum or starvation-limit tuning cannot capture idle issue slots; that needs both
  harts RESIDENT and issuing at once (Phase 4 mixed residency). Only the yield/pause
  hint from the lock result pays off before Phase 4.
- [x] Lock holder vs spinning sibling MEASURED (2026-09-19), artifact
  smt2-lock-holder-v2-20260919: SMT_LOCK gives both harts one AMO lock and identical
  512-iteration critical sections with same-hart solo controls. The oracle checks the
  sections are DISJOINT (mutual exclusion) and times them; a unit test proves it
  refuses overlapping sections. Mutual exclusion holds (hart0 550-5395, hart1
  5451-7598). hart0's section is 4846 cycles contended vs 2066 solo = 2.3456x slower
  purely because the peer spins and produces nothing (~57% of capacity wasted);
  hart1's later section is 2148 vs 2066 (1.0397x) since the peer had finished, so the
  asymmetry is spinning, not a general sharing tax. Conclusion for policy: equalizing
  sibling service is the wrong objective; a low-IPC hart may be a lock HOLDER to
  protect while a spinning WAITER should yield. A yield/pause-aware admission hint
  (explicit zihintpause/WFI, never inferred spin patterns or lock addresses) should
  precede any IPC- or RTT-derived throttle. Not implemented. 38 tooling tests.
- [ ] PMU residuals before any hint ABI: mcycle is elapsed time, not per-hart service
  (conformant, see above); SBI PMU mapping and counter save/restore across context
  switches are unqualified; an RV32+Zihpm profile is still needed to give the RV32
  hpmcounterNh read fix a directed test. A translate_off assertion
  in perf_counters now fails loudly if a committing hart differs from the attributed
  hart — the Phase4 tripwire, since `commit_sel` still uses one commit_instr_i.hart_id
  for every commit port and is valid only while a group stays single-hart.
- [ ] Phase1b software hints: audit current ONE physical-core perf_counters block,
  which has no hart-indexed counter/selector bank and no scheduler-reason inputs.
  Qualify ownership, privilege/inhibit/overflow, programming races, task switches
  and SBI PMU mappings before advertising eligible-unselected/accepted-work/coarse-
  pressure hints. Sim-only observers are not software-accessible counters. Keep
  hints coarse, privileged and optional; no new CSR/SBI number or ABI in this pass.
- [ ] Intra-core policy path (active plan B1/Phases4/6/8/9): biased safe-boundary
  fetch, minimum RS/IQ reservations plus elastic free credits, then opportunistic
  whole groups and separately qualified mixed-lane/FU fallback. QoS limits new
  admission only, preserving response/store/invalidation drain and progress floors.
  Linux sees sibling logical CPUs sharing capacity, not two independent cores;
  evaluate useful per-core throughput and tail bounds rather than equal task counts.
- [ ] Adaptive extension to plan Phase6 is analysis only: bounded/hysteretic policy
  over legal candidates, static fallback, minimum service/credits, and no throttling
  of completions/store/invalidation drain. Current coarse handoff cannot hide an
  outstanding load before drain. Measure readiness, real switch reason and RTT/MLP
  before policy changes; hybrid starvation and quantum use different units/precedence.
  Add asymmetric cache/lock/IPI phases, validate actual Linux SMT topology, timers,
  shootdowns, PMA/fences and FP context at their dependency gates. No adaptive RTL,
  new policy default, firmware change or claimed cache-RTT speedup in this increment.

## Balanced core performance foundation (2026-09-14)

Priors: `architecture/router-core-upgrade-program.md`, `architecture/l2-l3-cache/README.md`,
`architecture/multi-threading/testharness-proxy.md`, and the approved P0–P3 plan.
User objective: balanced single-core latency and multicore throughput/area, preserving SMT.
The original first candidate was optional L2 round-robin replacement. The
2026-09-16 effort-ranked priorities below supersede that implementation order;
RR remains default-off and no production-default or SMT-scheduler change is implied.

### Active reassessment: stability-balanced speed/area (2026-09-16)

The user-local `plan-ea69493e7a14829a.md` is revised in place; its original
RR-first plan and early conclusions are preserved as superseded history.
Current IQ/frontend/corrector hashes and SMT2/stream8 packages match the scoped
promotion records. Promotion into the working RTL is complete; no repeat edit,
cacheability/RR default-on change or new multicore speedup is implied.

Immediate decision order, flexible when evidence changes:

1. **Single-core supply:** measure the warm I-cache request interval before
   implementing a registered overlap/buffering candidate. Current IDLE/READ
   service is one window per two cycles; the nine-instruction RVI locality loop
   takes `9 × 2 × 8192 + 14` cycles. Target interval 2→1, not a promised 2× CPU
   gain. Preserve hit latency, request/response identity, kills/replay and SMT2;
   never blindly restore READ-state ready and its old combinational loop.
2. **Multicore stability:** reproduce held AR/AW owner/ID changes under stalls,
   one-free-slot AW eligibility, full-target invalidation admission, per-target
   coalescing and selected-source acknowledgments. The multi-target coalescing
   case needs N≥3 at the source-excluding hub; L3-source conflicts are L3-enabled
   prerequisites. Two invalidation-leaf triggers are now reproduced/repaired
   below; remaining hub/inclusive cases are not fresh end-to-end failures.
3. **Low-cost area screen:** prove serialized L2 demand occupancy and compare
   current MSHR depth against 4 and 2. Do not assume depth 1 is a clean parameter
   choice: public index widths and full-event semantics need separate review.
4. **Memory service / storage:** compare matched post-predictor cacheability and
   CPU-visible latency/backpressure, while studying tag-SRAM ports and obtaining
   approved macros. Do not mix tag conversion with nonblocking control or RR.
5. **Later growth:** provider/slot completeness and measured SMT overhead precede
   wider issue, nonblocking L2, scheduler retuning or more prefetch capacity.
   Keep N=1/T=1, N=1/T=2 and N>1/T=1 objectives separate; preserve the existing
   dual-active RVI/mixed-C integer gate at every relevant integration.

The E1–E6 rows below remain evidence/work families, not an inflexible sequence.
No mapped Fmax/area/power or multicore scaling gain is inferred from these targets.

### Effort-ranked priorities (2026-09-16; evidence and work families)

User decision: prioritize the current performance/area opportunities over the
older feature plan. Make existing capacity useful and cheaper before growing
capacity. F0–F5 remain qualification gates, not a requirement to execute every
historical experiment before taking the next bounded improvement.

| Priority | Work and current state | Discriminator / completion condition |
|---|---|---|
| E1 — IQ structural order | Circular head retained; reduced-envelope binary induction and all 12 covers now pass, alongside prior leaf/synthesis/SMT2 and BMC evidence | Storage/pointer and CF-target relations are asserted, not assumed. Four-step base plus two-step induction covers the live 4-bank/depth-8, 2-target, 2-hart/2-issue, 32-bit ASIC/non-RVH model. Explicit no-flush full drain and negative controls pass. Broader production-width, parameter, FPGA and RVH proof coverage remains open; raw-opcode throttling is separate. No DUT/scheduler change in this proof pass. |
| E2 — useful cacheability | Short/larger controls pass; cached scan ROI regresses 35.77%; checked locality shows equal cycles and about one I-cache miss event per loop | Keep cacheability isolated. Validated tracing finds repeated killed wrong-path FAIL-line refills after a persistently mispredicted not-taken check. Response-aligned lookup alone failed to remove steady-state misses (213,012 cycles). The combined response-aligned lookup/absolute-corrector repair is retained after six leaf geometries/negatives, selector proof, SMT2 references, broader stream8 controls and synthesis. Locality improves about 30.77%; unchanged-policy hot-scan improves 4.66%. Corrector costs +99 generic leaf cells, no state growth. Mapped timing/power, full FPGA/provider and release qualification remain open; PH_BHT's separate registered port is unchanged. Validation work can hide short data latency; locality is not a pure latency benchmark. Future latency/backpressure must affect CPU-visible memory, not the island-only timing model. WT admission, production correctness and physical gates remain open; no automatic RR/MSHR/cacheability change. |
| E3 — production L2 tags | Architecture/macro study; technology inputs blocked | Compare resettable flop tags with a synchronous tag-SRAM organization through the existing memory seam. Resolve lookup, victim probe, install and address-match invalidation arbitration together. Require library/SRAM views, test access and timing constraints before quoting physical savings. Start obtaining these inputs in parallel with E1/E2. |
| E4 — SMT work efficiency | Deferred until switch-cost evidence | Measure reason/hold counts, discarded/refetched work, switch-to-useful-issue latency and per-hart fairness. The package uses quantum 128 / starve 64; hybrid starve can preempt quantum. Reassess legacy tail/register-specific holds against the repaired restart contract, never remove them solely from a cookie result. |
| E5 — L2 concurrency or right-sizing | Depth two promoted in SMT2/stream8 after matched production-shaped qualification | The top serializes through response and does not drain merged waiters. Prove live occupancy, then screen depths 4/2 against current depth; depth 1 needs public-width/full-event review. More MSHRs/banks alone do not create MLP. Nonblocking service waits for shared-path correctness and measured latency/occupancy. Do not combine it with tag-SRAM or replacement-policy changes. |
| E6 — policy/features | Deferred, RR default-off | Representative cacheable hot/conflict/streaming/pointer-chain controls, including losing cases, precede RR promotion. Wider issue, larger predictors, prefetch growth and frequency increases need an observed bottleneck and matched cost evidence. |

Efficiency is checked work per ROI cycle at fixed configuration/frequency,
with per-hart fairness and matched mapped cost; cookie polling times and
instruction counts across different encodings are not throughput metrics.
Preserve the validated runtime header identity and immutable source/ELF inputs.
Reuse unchanged controls; run narrow leaf/proof screens before one integrated
candidate gate, rather than repeatedly rebuilding all named packages.

Release requirements are not deleted by reprioritization: natural firmware,
traps/WFI/wakeup, release/acquire/LR-SC/AMO, production geometry and FP isolation
remain open. The SMT2 package enables F/D while its FP register file is unbanked;
a documentation-only FDT closeout node is not a hardware isolation mechanism.
Physical STA/DFT/P&R/power remains blocked on approved technology inputs.

### Warm-fetch / invalidation follow-up (2026-09-16)

- [x] Analyze the immutable bounded core-0 trace: 24,804 cycles, 12,402 requests/
  responses/IQ transfers/allocations/retirements; uniform two-cycle request spacing,
  one-cycle accepted-request response, no misses or mispredictions in that window.
  Source identity and missing-row/wrong-PC negatives pass. No new full-ROI run.
- [x] Reproduce mixed-target admission and coalesce/sole-pop loss in the original
  invalidation leaf. Retain a shared per-target eligibility repair without new
  state, clock, stage, interface or config. Five N/depth variants and negatives
  pass; N3/D2 eight-step local formal and both covers pass. Generic cells change
  1900→1860 (N3/D2), 6528→6623 (N4/D4), with state unchanged. No physical claim.
- [ ] Complete source-bound remote platform verification: host dry-run selected
  local executables and all SKIPs; the immutable remote tree lacks build-platform
  CLI. No default config/tool changes or automated licensing PASS are implied.
- [x] Reproduce five live-hub failures in `review-hub-before-20260916`: held AR/AW
  payload, held AR ID after slot release, AW one-slot credit, and accepted-write
  invalidation loss (3 completed, 2 delivered). Basic response control passes;
  an observed-data mutation is caught. Hub RTL remains unchanged.
- [x] Repair held AR/AW owner/slot reservation and phantom read credit. OT4/OT1
  positive/negative tests and eight-step local formal checks pass; N1 identity
  is unchanged. Generic N2/OT4 cost: 2760→2808 cells, 326→342 state cells.
  Invalidation-loss remains a real failing case, not a qualifying negative.
- [ ] Design lossless invalidation intent/commit and visibility handling. Current `aw_fire`-activated ready cannot
  be wired into AW grant without a feedback dependency. Preserve separate tests.
- [ ] Close hub invalidation reservation/retention and inclusive source
  acknowledgment/eviction handling; extend held-AXI qualification beyond the
  scoped tests before end-to-end multicore promotion.
  The one-core SMT2 identity path remains unchanged, not freshly re-run here.
- [ ] Add cycle-level IQ occupancy/readiness and backend-stall observations before
  implementing request overlap; absence of a transfer is not an empty/stall label.

Priors/results: `architecture/core-fetch/README.md`, `architecture/multi-core/README.md`,
`review-fetch-supply-analysis-20260916`, `review-inval-before-20260916`,
`review-inval-after-20260916`, `review-inval-quality-20260916`.

### Serialized-L2 area candidate (2026-09-16)

- [x] Measure depths16/8/4/2 with fixed 4 KiB/four-way/two-bank/RR0 geometry in
  (latency,stall-period) profiles (6,0)/(24,3). All phases and timestamped accepted
  transactions match; totals31108/61659 cycles, peak live MSHR one, 1348 completed
  allocations. Observer off/on/repeat and eight occupancy mutations are checked.
- [x] Paired synthesis: 16→2 removes874 sequential cells; generic cells23953→18913
  in fully mapped512 B/two-way and33647→28840 in 4 KiB/four-way excluding its two
  unchanged data macros. Metadata is excluded; no physical or whole-core claim.
- [x] Prove the one-live/slot-zero/no-waiter invariant by two-step binary induction
  at depths16/2 in a 512 B/two-way fixture; reach live/completion and catch checker
  mutation. This is not complete data equivalence or all-geometry qualification.
- [x] Qualify depth2 at 256 KiB/eight-way/four-bank geometry and matched named
  integrations with current hub/invalidation RTL on both sides. SMT2 preserves all
  13 records per model; stream8 preserves ten positives plus its expected negative
  per model, including ROI cycles and retirement traces. Current package fields
  now select depth2 and match tested candidate hashes exactly; other defaults,
  generic MSHR capability, cache policy and scheduling remain unchanged.
- [ ] Keep full platform/physical/ISA/FP/coherence qualification open. The matched
  sizing pass does not resolve the hub's remaining invalidation-retention failure.

Evidence: `architecture/l2-l3-cache/README.md`, `review-l2-size-20260916`,
`review-l2-size-assessment-20260916`, `review-l2-occupancy-v2-20260916`.
The initial measurement pass made no production change. The subsequent qualified
package promotion is recorded in `review-l2-size-integrations-20260916` and
`review-l2-integration-evidence-20260916`; no new throughput gain is claimed.

### Broad RTL review follow-up (2026-09-16)

- [x] Repair OoO IQ false wakeup, dispatch/WB coincidence and exact-group capacity;
  independent queue tests and watched-readiness induction qualify the leaf.
  Generic IQ fixtures reduce13,866→13,074 and60,370→53,260 cells, not whole-core area.
- [x] Repair matching-full MSHR admission and concurrent waiter retention/order;
  D2/4/8 controls and ten-step symbolic checks pass. State unchanged; standalone
  logic grows125/100 cells in the measured D4/D8 fixtures.
- [x] Mask inclusive ready by actual per-core source selection; source seam plus
  real inclusive leaf controls and formal pass. Eviction retention remains open.
- [x] Correct the latent TAGE decay period; prediction-output equivalence passes.
  Usefulness remains inactive in the top; do not claim accuracy or physical-state savings.
- [x] Fresh four-file-overlay SMT2/stream8 models match all24 frozen depth-two
  records, including timing and operand/retirement identity. No OoO/L3 enable.
- [x] Resolve reproduced live OoO store self-block: `mem_stall_i` now gates LOAD
  only, since a store sets `older_st` at dispatch and so blocked its own
  issue→AGU→WB resolution. Six live-path records pass (ALU, store, two stores,
  load-ordering guard) with two injected controls failing. Load conservatism is
  deliberately unchanged.
- [x] Rewrote both core review fixtures onto a free-running clock with defined
  drive/sample points (stimulus at the falling edge; combinational handshakes
  sampled just before the rising edge, since that edge consumes `issue_valid_o`).
  Every default-optimisation result is unchanged, so the earlier stimulus was not
  in fact racing.
- [x] Abandoned `-O0` as an RTL-vs-tooling arbiter: it flips even the isolated,
  directly-driven LSQ forwarding contract (`LSQ_STL_FORWARD fwd=0`), so it cannot
  adjudicate anything here. The earlier conclusion that the dispatch fixture is
  untrustworthy rested on that invalid reference and is withdrawn.
  `REVIEW_RTL_NOOPT=1` is retained only to reproduce the observation.
- [x] Settled the dispatch allocation-id question with an independent elaborator:
  slang/yosys proves `alloc_ids[p] == dispatch_sbe_i[p].trans_id` with 0 errors
  and 0 warnings, so the zero `alloc_id_i` in simulation is a **Verilator
  artefact, not an RTL defect**. `DISPATCH_STORE_WB_RETIRE` stays expected-fail
  to track the artefact and must not be read as an RTL result.
- [x] **Repaired a real LSQ defect the artefact had masked:** commit released the
  lowest-valid-index store while writeback had already released that store by id,
  so commit freed a different, still-pending store and an unresolved older store
  went invisible to load ordering. Release is now by `trans_id` across all commit
  ports (previously only port 0, so higher-port stores leaked their entry).
  6/6 isolated records, three live controls, dispatch unchanged at 7/7.
- [x] **Found and fixed a real combinational loop:** `ld_qaddr -> LSQ CAM ->
  stl_fwd -> issue_op_a_o -> ld_qaddr`. The load CAM query address came from the
  operand that the query's own forward overwrites. Address generation now uses a
  pre-forward `op_a_agu`; the forward applies only to the issued operand. Needed
  splitting `always_comb` blocks in `g6lc_lsq` and `g6lc_ooo_dispatch` because
  dependency analysis is per block. Loop count 2 -> 1, dispatch unchanged 7/7.
- [x] **Fixed the rename admission loop** `can_go -> i_rename.valid_i -> stall_c
  -> ren_stall -> can_go`: capacity now computed in its own block from ungated
  intent plus the registered free list (state updates still gated by `enable_i`),
  and the redundant `& {NP{can_go}}` on `valid_i` dropped. **Elaborator reports
  2 combinational loops -> 0**; dispatch suite unchanged 7/7.
- [x] Hypothesis that the loops explained the simulator oddities: **partially
  vindicated after all.** With the first two loops removed neither symptom
  changed, but ungating `valid_i` from `can_go` in the admission rework removed
  the last circular settle — and with it the `alloc_id_i`→0 artefact. Scenario 6
  now retires by genuine id match; dispatch 6/7/8 are real passes.
- [x] `alloc_id_i`→0 artefact: **gone** (see above). The slang/yosys proof of
  `alloc_ids == trans_id` stood throughout and is now corroborated by
  simulation. Still open, simulator-side only: `-O0` divergence on trivial
  fixtures.
- [x] **Rename recovery: two defects reproduced then repaired.**
  (a) `RENAME_OLDER_LOST` — pre-group checkpoint discarded a rename *older* than a
  same-group branch. Capture now happens after the first branch in the group
  renames. (b) `RENAME_BUSY_RESURRECT` — reinstating the busy snapshot re-marked a
  register whose writeback had already happened (never repeats, so its consumer
  waited forever); reinstating the free snapshot likewise leaked registers freed
  after the checkpoint. Restore now **repairs** instead: squashed set
  `ckpt_free & ~free` is exactly the post-branch allocations, so only those are
  returned and only those have busy cleared. `ckpt_busy_q` deleted as a result —
  net **state reduction** of PRF_ENTRIES x CKPT_DEPTH flops (576 at PRF=72/CKPT=8).
  `review-rename-recovery-fix-v1` 6/6 with three live controls; dispatch 7/7;
  still zero combinational loops.
- [x] Rename recovery, resolving-branch identity: added `mispredict_level_i` so
  recovery unwinds to the branch that actually resolved, consuming that checkpoint
  and discarding all younger ones in one step. Out-of-range means "youngest", so
  tying it high (what dispatch does today) reproduces the previous behaviour
  exactly. Scenario 3 shows correct unwind at level 0 and its control reproduces
  the old defect (`RENAME_STALE_LEVEL`). 8/8 rename records, four live controls,
  dispatch 7/7, zero loops.
- [x] **Retirement width repaired (was reachable).** `num_commit` special-cased
  `NrCommitPorts==2` and otherwise counted only port 0, while the commit loop
  clears `issued` on every acknowledged port — so a four-port build retired up to
  four entries per cycle but advanced the commit pointer by at most one,
  desynchronising the scoreboard FIFO. `g6lc64_ooo_server` sets `NrCommitPorts=4`,
  so this was live. Now a width-generic popcount; the port-1-only validity
  assertion is generalised to all ports. Non-regression: 24/24 frozen
  SMT2/stream8 records with `core/scoreboard.sv` overlaid.
- [x] Directed four-port retirement/TID-conservation test landed:
  `review-commit4` kind, 3/3 records (ordering + payload markers, pointer
  wraparound with live wrapped entries, live negative control). Two Verilator
  5.008 workarounds documented in the runner.
- [x] **Hub accepted-write invalidation loss repaired.** The invalidation was
  generated combinationally from `aw_fire` and dropped when the bus was not ready,
  so writes completed with no invalidation (`HUB_INV_LOSS`). A registered
  retention slot now holds the obligation until the bus takes it; admission
  consults only registered occupancy plus the incoming `aw.cache[1]`, never
  `inv_ready`/`aw_fire`, so the loop that made the earlier attempt unsafe is
  avoided. One slot suffices because admission is refused while occupied.
  15/15 hub records, negative control live, scenario 5 passes.
- [x] Landed the `check_cfg` legality asserts rejecting `OoOEn=1` with
  `NrHarts>1` or `FpPresent`. These are `translate_off` sim-time asserts, so lint
  and synthesis are unaffected and the protected `OoOEn=0` packages pass: 24/24
  frozen SMT2/stream8 records with `core/include/config_pkg.sv` **and**
  `core/scoreboard.sv` overlaid. `g6lc64_ooo_server` trips them deliberately.
- [x] Coherence producer side repaired: `g6lc_l3_inclusive_inv` gained
  `evict_ready_o` (`!pend_q`, tied high when disabled), `g6lc_l2_top`/
  `g6lc_l3_top` propagate `l2_evict_ready_i` (the S_TAG offer re-pulses every
  stalled cycle, so gating the commit transition converts it into a held
  handshake), and `g6lc_cluster` wires it to the active producer. 18/18 incl
  records, HUM hold scenario, 24/24 integration.
- [x] **OoO + SMT2 + FP aliasing gated:** `check_cfg` rejects `OoOEn=1` with
  `NrHarts>1` or `FpPresent` (translate-off, sim-time). Per-hart map/free/busy
  namespaces and an FP register class remain open as a redesign.
- [x] Rename recovery remainder — **done**: per-port checkpoints
  (`do_ckpt[p]`/`ckpt_slot_c[p]`/`ckpt_id_o[p]`, capture after each branch's own
  rename, ptr advances by group branch count, over-capacity groups stall), and
  the tag path closed via a dispatch-side `tid_ckpt_q[trans_id]` table —
  `bp_resolve_t.trans_id` already identifies the resolver, `issue_stage` feeds
  `mispredict_id_i`, dispatch drives `mispredict_level_i`. Older-branch unwind
  verified through the issued physical register (scenario 9 + control). Also
  fixed a formal-found race: `free_i` now clears `busy` too (a freed reg is
  never awaiting a producer), closing a `free&busy` exclusivity violation when
  a commit free raced a restore (abc-bmc3 frame-3 cex). Evidence: rename 14/14,
  dispatch 14/14, rename prove PASS (12 frames).
- [ ] Lesson worth keeping: a signal computed only from registered state still
  inherits its **`always_comb` block's** dependencies. Three separate loop paths
  here were closed only by moving `older_store_pending_o`, `ld_full_o`/`st_full_o`
  and `op_a_agu` into their own blocks.
- [x] LSQ store age — **repaired**: `older_store_pending_o` (renamed
  `store_pending_o`) reported any in-flight store, so a load could block behind
  a younger one. Age is now the scoreboard's circular `trans_id` order anchored
  at `commit_pointer_q[0]` — `g6lc_lsq` gained `commit_ptr_i`+`st_live_mask_o`
  and its CAM forwards the youngest matching *older* store and stalls only on
  unresolved/data-less *older* stores; `g6lc_iq` gates loads on
  `st_live_mask_i`+`commit_ptr_i`; `issue_stage` supplies the pointer.
  Evidence: isolated LSQ suite 12/12 (age/stall/wraparound, controls live) + IQ
  gate formally proven under slang/yosys (`iq-age`: `issue ⟺ no older live
  store`) + integrated dispatch 14/14 as real evidence — the `alloc_id_i`→0
  artefact disappeared with the admission-loop rework, so scenarios 6/7/8 are
  no longer artefact-pinned.
- [x] LSQ store lifetime precondition now met: with age-aware ordering and
  all-port commit draining, moving the release point from writeback to commit
  no longer risks the older-load/younger-store deadlock. The move itself
  remains a separate change.
- [x] Land same-line L2 hit-under-miss: merged readers are accepted during a fill
  and drained with their own id/beats; waiter payload stores the in-line offset
  only (+170 flops at depth 2 vs +634 for a full address). Leaf 8 shared-line
  readers 50→42 cycles; different-line control unchanged; 32/32 existing L2
  records phase-identical to a matched baseline; MSHR proofs still pass.
- [ ] Real nonblocking L2/L3: still one outstanding fill (8 distinct-line misses
  remain 176 cycles / 8 fills, no MLP). Needs concurrent fills with response
  routing/reordering, waiter error propagation and write interleaving.
- [x] Rename admission feedback, branch-correlated recovery, committed-map
  preservation, and wide-commit counting contracts — all reproduced and closed
  (entries above). Hart/FP ownership is gated by the `check_cfg` legality
  assert pending the namespace redesign.
- [x] Predictor per-slot PC ownership (per-slot base row/column + tagged
  provider for TAGE and ITTAGE) and fetch-vs-resolve fold ownership
  (`folded_update_i`) — `review-tage-ctx-v2` 10/10 with live negatives, decay
  6/6 non-regression.
- [x] Prediction-time checkpoints — `g6lc_bp_ckpt` reworked to predict-time
  per-CF-slot pushes (`bp_push_cf`), per-resolve pops, restore-drains-younger,
  full push+pop single-advance conservation, and `desync_o` overflow gating.
  Update folds now hash the popped prediction-time snapshot (`fold_src`),
  closing the recency gap; arch-GHR shifts the actual outcome on every resolve
  (no stale-head restore); RAS restore gets the branch's own predict-time
  stack. `review-ckpt-v2` 8/8 with live negatives, `review-int-ckpt-v3`
  integration 24/24 (smt2 13/13 cycle-identical; stream8 matched with
  timing-legible rdcycle/report deltas — comparator now splits a
  PC/encoding-only arch digest and arch-binding vs timing-legible report
  fields). Residuals documented: window-granular RAS snapshot; non-`is_*`
  CF (ZCMT) over-pop until next drain.
- [x] STQ/cancellation reconciliation — the OoO LSQ no longer injects store
  data into `operand_a` (it destroyed `vaddr = imm + operand_a`); the LSU
  store_buffer owns the byte-exact forward (full PA + BE, spec+commit
  queues). LSQ is ordering-only: `stl_stall` on older unresolved-address or
  byte-overlap-without-data stores, real footprints via
  `extract_transfer_size(sbe.op)` both directions (new `ld_query_size_i`),
  `agu_size` hardcode removed. `stl_forward`/`stl_data` kept as
  fully-covered observability for the PMU probe. `fwd_keep`/G1ao are
  SuperscalarEn&&NrHarts>1-gated, unreachable under OoOEn.
  `review-lsq-be-v2` 24/24 (byte-overlap, cancel, flush; live negatives),
  dispatch 14/14.
- [x] Cacheable refill errors — `g6lc_l2_top` gains `fill_err_q`: accumulated
  over the whole refill, it gates `tag_write`/data install at `S_MISS_INSTALL`
  and serves the saved code to the requester (and waiters it drains) at
  `S_HIT_RESP`; `bank_conflict` can't deadlock (b_req gated). `l2-leaf` phase
  `fill_error_no_install` verifies SLVERR+DECERR → no install + retry, in
  4w/rr1 and 2w/rr0+stall geometries. Residual: single-master bench, waiter-
  on-errored-fill drain proven by construction only. (Eviction retention and
  hub write visibility were already closed earlier.)
- [~] P1 warm fetch — `+fetch_supply` measured supply binding (supply-cap-v2:
  19791/19791 take cycles refused, all `iqrdy=1`, 19788 `iquse=0`; accept gap
  locked at II=2; `iq_stall=7`/`empty=13`/`be_stall=5`). Implemented `W1`
  registered overlap in `g6lc_icache`: READ hit-response asserts `dreq_o.ready`
  and stays in READ on `dreq_i.req` (array read launches same cycle via
  `vaddr_d`→`cl_index` → II=1, hit latency unchanged). `ready` is a
  `cl_hit`/state cone — all registered inputs; no combinational ready feedback
  (Verilator clean, no convergence warning). Miss/flush/inv/kill/atrans-wait
  stay serialized. **Integration qualified** `review-int-overlap-v8` 24/24
  (all timing-legible: archpc sequence on ordered streams, archms multiset on
  merged-hart dasm, per-hart `h`-split operand digest, cookie-value binding).
  supply-cap-v3 re-measurement in flight (early rows: sustained
  `req&rdy&rsp&take`, `iquse`≈9–10 vs ~4 ceiling).

Reviewed paths, measurements and artifact tags: `architecture/remaining-upgrade-sequence.md`.
Full OoO production wording is superseded by explicit qualification blockers.

### IQ proof follow-up (2026-09-16)

- [x] Preserve all original safety assertions/input assumptions and add asserted
  bank status/pointer, watched-storage and live-CF/target-FIFO relations.
- [x] Close binary-state unbounded safety in the reduced FW64/RVC, four depth-eight
  banks, two-entry target FIFO, two-hart/two-issue, XLEN/VLEN/GPLEN32 ASIC envelope:
  explicit four-frame base and two-step induction pass in
  `review-iq-sat-binary-20260916`. The copied instruction-bit fault is detected.
- [x] Reach all 12 cover predicates within 28 steps, with an unreachable negative.
  The added no-flush drain witness is full at step 11 and empty at step 27 with
  no intervening flush. The old full-to-empty predicate could use a flush.
- [x] Preserve historical BMC/timeout records and the user's timeout/hash/incremental
  runner controls. Add explicit, guarded SAT modes; do not label the default
  SBY PDR/SMT timeouts as passes. Binary proof does not qualify X-propagation.
- [ ] Extend IQ proof qualification to production-width/parameter tuples, FPGA
  storage and hypervisor metadata; full SMT/ISA/physical gates remain separate.

### Predictor follow-up qualification (2026-09-16)

- [x] Retain response-aligned asynchronous BHT/BTB selector paths and absolute
  corrector semantics after six independent leaf geometries/negative controls,
  symbolic selector proof/negative, thirteen SMT2 execution records, broader
  stream8 controls and full-core synthesis smoke. FPGA selector phase, state
  capacity, cacheability, RR and ISA/DTS are unchanged; PH_BHT's separate
  registered port is outside this repair.
- [x] Verify retained non-comment source against the tested model and rerun
  corrector tests. Minimal 32/64-bit, SMT2 and stream8 lint/strict elaboration pass.
  Corrector leaf costs 99 additional generic cells (192 state bits unchanged).
  Locality improves about 30.77%; unchanged-policy hot-scan improves 4.66%.
- [ ] Complete mapped timing/power with approved physical inputs; extend remaining
  provider/FPGA, natural-firmware, ISA/FP/ordering and IQ proof qualification.
  No release-sign-off claim follows from the scoped predictor checks.

### Runtime reasoning methodology (2026-09-16)

- [x] Draft `AGENTS-rt-learning-philosophy-AGI.md` from the coding philosophy and
  actual reasoning-workflow/heuristics/logics sources. It defines evidence-bounded
  analysis segments, refutable pattern memory and preliminary capability evaluation;
  it is not an implemented learner or an AGI claim.
- [x] Add the requested preliminary mechanism-analysis instruction to
  `AGENTS-coding-philosophy.md` §2.10: scope, interface/ownership/lifetime contracts,
  facts versus hypotheses, competing predictions, rejection conditions and the
  earliest faithful check before choosing an implementation direction.

### Flattened completion gates (2026-09-15 review; supersedes experiment ordering below)

Treat the historical P0–P3 entries below as an evidence ledger, not a serial
implementation checklist. RTL present, bounded diagnostic PASS, named-package
functional qualification, and performance/area promotion are distinct states.
No stage closes merely because its implementation or a proof file exists.

| Gate | Current state | Completion criterion / next action |
|---|---|---|
| F0 — reproducible evidence | Partial | Immutable source closure including submodules/generated bootrom, target/config/tool/flags/ELF/executable hashes, bounded execution, separate PASS/FAIL/timeout/crash verdicts. Use VT1 and `+debug_disable`; `env -i` is a control, not a memory-safety fix. Reject cookie-free `SUCCESS(tohost=0)`. |
| F1 — instruction supply correctness | Seven targeted repairs; integer trace gate passes, broader gate open | Check accepted bytes/PC/hart/exception/prediction as one transaction. Independent FIFO reference must cover sparse masks, partial acceptance, stalls, wrap, flush and backward branches. Repair current RTL, not an obsolete historical selector. |
| F2 — SMT2 functional gate | Dual-active integer diagnostics pass; broader gate open | Full checked-work on freshly built compressed and uncompressed ELFs; then two active harts with disjoint work/checksums, release/acquire, traps, WFI/wakeup and LR/SC. NWORKERS=1 on a two-hart package is not a two-active-hart pass. Natural OpenSBI remains a separate gate. |
| F3 — integrated efficiency | Diagnostic evidence only | Retain existing interfaces, reset/clock strategy and `CVA6Cfg` geometry; prefer removing redundant ranking/mux/state over adding heuristics. Compare checked work/cycles, generic cells/storage and timing cones on identical configurations before/after; no area/STA claim from line counts or generic cells. |
| F4 — L2 policy decision | Default-off candidate | Preserve completed leaf/equivalence/AMO evidence at its stated scope. Rerun paired core/SMT/cluster controls after F1; representative hot, streaming, pointer-chase and conflict workloads must expose actual cacheable traffic. Record regressions as well as wins. |
| F5 — release qualification | Open | Close source/build/run binding gaps, production-geometry mapped or explicitly compositional equivalence, concurrent invalidation/error/atomic coverage, required formal covers, then mapped SRAM/DFT/STA/power. No RR default-on or SMT2 SKU promotion before these gates. |

**Review corrections:** `7e6c19c54` introduced an I-cache index skew already
fixed by `9fbab3044`. Its minimum-PC queue selector has since been replaced by
age selection. Historical hybrid failures and current `tohost=3` do not prove
one uninterrupted root cause. An unchanged log ending at a probe cutoff does
not prove simulator livelock; process matching must not match its own command.
The bisect payload copied from `smt2-norvc-vt1` visibly contains compressed
instructions in the recorded disassembly, so directory names cannot establish
a `-norvc` control. Recheck ELF hashes, symbols, code and build recipes.

**Formal review blocker:** `g6lc_fetch_iq_props.sv` and
`g6lc_fetch_realign_props.sv` narrow `NH=2` to a one-bit `HARTW'(NH)=0` in an
assumption. No hart satisfies that bound after reset. Their prior PASS claims
must be treated as vacuous until corrected and reachable covers rerun. The IQ
order harness additionally assumes prefix-valid inputs although the live
frontend can prefix-filter slots; it checks DUT sequence metadata, not an
independent conservation/order model. These are verification defects to repair,
not grounds to waive the live interface cases.

**Efficiency scope:** the stream8 e8k-overlay result (374,177→325,980 ROI
cycles; 18,787→13,318 L2 misses) remains a recorded RR-favourable measurement,
not a production cacheability or performance claim. Do not narrow execute
regions, merge stream8 and SMT2 packages, disable assertions or add
register/value/opcode-specific workarounds to obtain a passing result.

### Review implementation and evidence (2026-09-15)

- [x] Reproduce the current sparse-input IQ defect against an independent
  accepted-stream model. Fix `core/fetch_B/instr_queue.sv` by compaction,
  origin-slot consumption mapping and slot-rank timestamps. Remote 2/I1/H1,
  4/I2/H2 and 8/I2/H2 fixtures pass (548 / 1,103 / 1,462 accepted entries).
  Before, dual-issue skipped a hidden older entry at t=35.
- [x] Compare identical live-port IQ synthesis fixtures: 25,618→22,354 generic
  cells (−12.7%), 5,954 sequential cells unchanged, no latches/check problems.
  This is logic-cost screening, not physical area or critical-path sign-off.
- [x] Local diagnostic `verify --target g6lc64_smt2 --lint`: 256 warnings within
  the existing budget; strict elaboration clean. Remote full-core builds use
  unique copied source/Mdirs, VT1, fixed seed and direct cookie verdicts.
- [x] Isolate the remaining N1 verdict failure: verified-norvc finishes with
  both checksums `0xc000`, sets PASS (`a0=1`), then executes the fall-through
  FAIL write (`a0=3`). Repair `core/fetch_B/frontend.sv` to filter current-cycle
  bytes against the current response/pending target, not `present_exp_q` from
  the previous response. No new state/cycle/config/ISA/DTS or scheduler change.
- [x] Byte-identical payload A/B: models `0993083d…`→`44096c6f…`; historical
  `f14a140c…` FAIL→PASS @131,072; verified-norvc `baad8f97…` FAIL→PASS
  @137,216; fresh RVC `555f7c14…` PASS→PASS @131,072. Artifacts:
  `remote-runs/review-identical-serial-20260915/` (diagnostic, not strict
  qualification). Do not describe `tohost=3` here as proved memory corruption.
- [~] Two-active-worker qualification now uses typed allocation-generation,
  issue/ALU/LSU/writeback/retirement traces, not transient GPR snapshots. Original
  no-IPI N2 remains an activation-negative control; no boot/scheduler gate changed.
  The first proved loss discarded IQ PCs 0x68/0x6c but saved transport PC 0x70.
  `restart_frontier` now preserves the oldest owning decode/IQ token. A cookie
  PASS after this fix was false assurance: the independent model found a later
  foreign-hart misprediction corrupting the incoming recovery filter. Active
  recovery/controller flushes now route by owner; inactive redirects update
  their own PC bank, with global scoreboard/LSU/training resolution retained.
  The RVI witness now passes 13,696 retirements and 25,774 operand checks;
  1,025 known load values are checked and one peer-flag value is not asserted
  against global commit order. RVC then exposed an uncleared split target:
  response 0x58 accepts target 0x56, but window-only completion misses it and
  later replays 0x56 instead of branch target 0x52. `accepted_target` uses
  actual consumed instruction PCs. Model `7037f685…` now writes PASS for the
  byte-identical 48 KiB/hart RVI and RVC ELFs at 282,624 / 270,336 cookie polls;
  independent post-fix traces pass for both encodings (13,696 RVI / 14,202 mixed
  C/I retirements, each 25,774 operand checks, 1,025 checked known loads and one
  peer-flag value outside the memory-order oracle). Both have nine matching
  baseline/off/on witness fingerprints and positive/mutated-trace controls.
  Do not equate this integer diagnostic scope with full SMT, natural firmware
  or physical qualification.
- [x] Realigner bounded closure: widened hart bounds, top-level inputs and
  equivalent bounded checker index. Eight-frame BMC plus five covers PASS,
  including hart-1 carry completion and switching with live carry. Scope remains
  FW64/H2/VLEN32, aligned inputs and emitted low halfwords, not full qualification.
- [~] Independent IQ formal now has free inputs, arbitrary sparse/PC packets,
  ghost occupancy and a watched accepted-entry PC/instruction/hart oracle.
  Both cover and ten-frame BMC timed out at 120 s (`review-iq-independent-order-20260915`);
  no final safety verdict. Raw-opcode non-interference remains a separate
  contract conflict; its prior frame-3 counterexample is not waived.
- [x] Recover and repair full-core synthesis failure: three replay/realigner/
  I-cache response-valid combinational loops. Register retry/address feedback,
  retain response-cycle IQ acceptance and align exception/retry metadata. Final
  full-core SMT2 smoke: zero check problems, 32,487 coarse RTLIL cells (not
  comparable to the mapped IQ-only count; not physical area).
- [x] Repair architectural redirect completion on current IQ acceptance. The
  accepted target branch's prediction previously cleared the registered response
  before completion, losing its target. Byte-identical `mini_fetch_redirect_chain.S`
  ELF `829fbeaa…` changes no-verdict→PASS on `44096c6f…`→`3aa9014d…`.
  Both fresh N1 checked-work encoding controls remain PASS. No scheduler change.
- [x] Prove restart selection, redirect-owner routing and actual target
  acceptance with reachable covers in `g6lc_fetch_smt.sby` (default formal
  list). `smtbmc --unroll z3` removes the SMT cover solver bottleneck without
  weakening assertions. Bank tests cover owner, invalid source, valid zero PC,
  reset, single-hart identity and inactive/coincident redirects. The cold
  `mini_fetch_split_redirect.S` passes on the pre-fix model and is a control,
  not a negative witness; the warmed dual-hart RVC program is the live negative.
- [x] Validate observer-off/on controls before interpreting traces; private
  generation counters never drive RTL. The independent reference checker also
  passes a single-worker positive and detects an in-memory operand mutation.
  E: filled during a large pull; remote evidence stayed intact. User approved
  new local artifacts on C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/.
  Proxy per-run/destination pulls and nonzero transfer failures have six tests.
- [x] Renew default-cacheability RR controls using the earlier fetch snapshot,
  VT1 and byte-identical payloads. SMT2 N1 RR0/RR1 PASS at 137,216 cookie polls;
  stream8 N1 RR0/RR1 PASS at 167,936; stream8 hot+scan both PASS at 464,896.
  Warm+scan report: both 275,593 cycles, L2 misses 4 and L1D misses 0; no RR
  performance gain established. `review-renewed-rr-controls-20260915` retains
  build/model/ELF/overlay records and raw counters. RR stays default-off.
- [ ] Physical/STA/DFT/P&R/power qualification: `tech status/check` confirms no
  PDK content, no active technology, no tech-spec and `physicalDesign.flow=none`.
  Need an approved library/SRAM bundle, corners and constraints; no guessed
  process mapping or frequency promotion. Production geometry/cluster/AMO and
  natural firmware remain independent release gates.
- [x] F0 host-runtime correction/revalidation: stream8 RR-on crashed in
  `getenv` before guest execution. A hardware watchpoint identifies a generated
  initialization write into `environ`; Verilator 5.008 `VL_CONSTHI_W_*X` uses
  an absolute zero-fill index on an already shifted pointer. A guarded-buffer
  test gives 18 mismatches before / zero after the private header correction.
  User approved a run-local runtime copy and matched model rebuilds; installed
  tools and RTL are untouched. Native results require this revalidation even
  when their old binaries did not crash. First rebuild failed because a
  command-line VPATH suppressed Make's runtime search paths; the corrected
  invocation supplies VPATH through the environment. Four matched models now
  rebuild and all six RR controls pass: SMT2 N1 137,216 / 137,216, stream8 N1
  167,936 / 167,936, hot+scan 464,896 / 464,896 cookie polls; ROI counters remain
  275,593 cycles / four L2 misses / zero L1D misses on both stream8 legs.
  Corrected-runtime full-core replays also pass both 48 KiB/hart encodings.
  Independent revalidation passes 13,696 RVI / 14,202 mixed C/I retirements,
  with the same operand/load checks and nine matching baseline/off/on witness
  fingerprints per encoding. Corrected baseline `5a10acc1…`, observer
  `528b720c…`, private runtime-header SHA `dfbc2c4a…`; original installation
  remains unchanged. The permanent reference checker is `run_operand_analysis.py`
  (byte-identical to the old ignored `analyze_*.py` scratch copy).
- [ ] Close F0 gaps: tracked-only manifests omit submodule contents and some
  build inputs; include generated bootrom and source closure, reject drift.
  C++ commit trace assumes 16 scoreboard entries but this SMT2 model has eight.
  Proxy `py --env` quoting fails for values containing spaces. Use scoped
  transport actions without shared-tree deletion or broad process killing.

Licensing/philosophy review: retain all upstream notices on fetch RTL;
formal collateral keeps its existing tier-R terms and recorded authorization;
new diagnostic scripts/benches/minis are MIT. No licensing controls changed.
The documented `diag run licensing` command is unavailable (`Unknown`), so no
automated licensing PASS is claimed. Current configs/tiers and retained notices
were reviewed; no GPL link-set member or licensing control changed. Broader
build-platform tests report 217 pass / 1 skip / 1 fail: the unchanged branding
test expects `g6lc_core_types.svh` to declare a matching module/package and
matches `module moved` in its comment (including a generated formal copy).
This pre-existing test/header mismatch is not waived or altered here. Generic logic improves without new state;
full RTL/SMT/physical completion remains subject to F0–F5, not these checkmarks.

Etienne Cimon explicitly authorized tier-R contributions in this session:
“I, Etienne Cimon, give tier-R contribution authorization for all code base changes as necessary”.
This records the supplied authorization, not a claim that a signed CLA document was found.

- [~] P0: strict target-specific qualification, positive/negative evidence checks, complete build provenance.
  **Host side landed (2026-09-14):** `verify --sim --qualification <profile>` resolves
  `verify.qualifications` targets to remote-proxy suites only, refuses skips /
  lint fallbacks / dry-run / missing manifests, and requires exactly one terminal
  `G6LC_EVIDENCE` record whose suite/target/top/kind/runId and
  source/config/executable sha256 match the expected identity
  (`build-platform/src/tests/runner.ts`). `testharness_proxy.py build
  --manifest-out <repo-rel>` writes the schema-1 manifest (603-source digest set,
  canonical digests verified byte-identical to the TS side by interop test);
  `soak --run-id/--tag/--pull/--expect-exe-sha256` and `run --run-id/
  --expect-exe-sha256` bind a run to the manifested binary. First producer:
  `verif/regress/remote/qualify-soft-ladder-osbi.sh` + suite `qual-soft-ladder-osbi`
  + profile `smt2-cookie` — classifies the pulled soak log (run-id file,
  trapdump, cookie `51b1babe`, no `51b1dead`) and emits the terminal record.
  Verified: 16/16 qualification tests, `tsc --noEmit`, proxy `doctor` rc=0
  (Verilator 5.008 + xpack 14.2.0 remote), CLI refusal on missing manifest.
  **First real qualified run (2026-09-14, run `48f4e481`):** `build B
  --manifest-out remote-runs/builds/work-ver-smt2-fw64-B.manifest.json`
  produced the manifest (exe `894ea012…`, 603 sources); `verify --sim
  --qualification smt2-cookie --target g6lc64_smt2` bound run-id, checked the
  remote exe sha256, pulled `remote-runs/qsl-48f4e481/`, and classified the
  log as **FAIL — 3/4 checks**: run-id and trapdump present, no `51b1dead`,
  but **no `51b1babe` cookie**. The log's `*** SUCCESS *** (tohost = 0)` was
  correctly NOT counted; residual signature is the known O3/SL-C state
  (`plat_hc=80, coldboot_done=0, mcause=0x2 @ mepc=0x80013898`, hart 1 never
  started). This is the machinery working: a residual is an honest red, not a
  qualified pass.
- **g6lc_tb.cpp NrHarts-agnostic probes (2026-09-14):** the testbench hardcoded
  banked-SMT hierarchy (`gen_banked.gen_csr[h].i_csr`,
  `gen_hart_bank[h].i_rf_bank`, `i_smt_thread_select.gen_smt`), so NO g6lc*
  target with NrHarts==1 could compile a harness — including g6lc64_stream8.
  `Makefile` now derives `-DG6LC_TB_BANKED` from the target pkg's `NrHarts`
  field; `G6LC_TB_CSR/RF(core,h,sig)` macros pick `gen_banked`/`gen_single`
  paths and `G6LC_TB_H1(expr)` drops hart-1/DCE'd reads (g1ao_hold_*,
  issue_entry_*_id_issue, gen_smt.active_q) to 0 when non-banked. The SMT/SS
  `idsb` debug block is `#if G6LC_TB_BANKED`-only. Banked smt2 rebuild produced
  the identical exe sha256 (894ea012…) — macro expansion is bit-equivalent.
  ariane_tb.cpp keeps its existing `G6LC_TB_NO_HIER` escape (AI builds);
  non-g6lc cv* targets still can't use its hierarchy probes (needs same pass
  or -DG6LC_TB_NO_HIER).
- **First qualified PASS (2026-09-14, run `dd705dad`):** `verify --sim
  --qualification perf-foundation --target g6lc64_stream8` — fresh
  `work-ver-stream8` build (manifest exe `7e27de94…`), 4/4 minis
  (amocas_w/d/q + stream_plane) bound per-run-id and exe-sha, pulled-log
  classification 12/12, terminal `G6LC_EVIDENCE` accepted by the gate.
  New suite `qual-stream8-minis` + wrapper
  `verif/regress/remote/qualify-stream8-minis.sh`; profile `perf-foundation`
  = stream8 minis (rtl-cluster) + smt2 cookie soak (rtl-core control).
  **Still open in P0:** isolated-build-dir support for candidate experiments,
  the concurrent-worktree cache-key gap, and ariane_tb banked-path parity.
- [~] P1: deterministic L2 leaf and short checked-work metrics; non-vacuous formal covers.
  **Leaf diagnostic strengthened (2026-09-14):** `verif/tb/l2/tb_g6lc_l2.sv`
  and `run-l2-tb.sh`: independent expected/backing memories, ID/data/length and
  stable-response assertions, exact accepted/completed-work and memory traffic,
  unique misses/fills, all-way/burst hits, reset, WT masks, quiescent invalidation,
  NC/exclusive bypass and adversarial hot/scan traces. Final four-way pair:
  `remote-runs/l2-sram-final-rr{0,1}`, local Verilator 5.020, 13 phases PASS,
  1,493 reads + 83 writes each. Latency=0/stall-every=3 pair also PASS; eight-way
  RR/stall-every=5 PASS. All are explicitly **local diagnostic exceptions**, not
  remote strict qualification. Final simulations keep source/executable hashes.
  **Correction:** the initial bench's seed default was converted incorrectly;
  `0x600df00d` is now exact. Earlier random counts are superseded. The initial
  memory model shared the expected write state and mishandled held responses;
  it was repaired before accepting these stronger diagnostic results.
  **Warning correction:** Verilator LATCH (`found_inv`, `mst_r_ot_d`, `wi`) and
  word-level UNOPTFLAT reports do not alone establish physical latches/loops.
  Both generic Yosys/slang fixture syntheses report zero check problems and no
  latches. Bench waivers are signal/file-scoped; vendor SRAM read-output reset
  warnings remain visible. No production-geometry or STA conclusion follows.
  **Open:** concurrent invalidations/errors. MSHR-full/merge/waiter and
  bank-conflict are covered by the units leaf (serialized-top zeros remain
  not passes). Rename covers reached locally (yices). Isolated-Mdir RR-on
  candidate core runs remain gated.
- [~] P2: default-off L2 replacement candidate; L3 legacy and SMT behavior preserved.
  Config wiring is complete (`L2RoundRobinEn` in user/built structs → build_config
  → cluster → RR_EN), all 27 explicit target defaults zero. Fixed malformed
  `bit\'(0)` fields introduced by the earlier interrupted script; they were not
  pre-existing. Three check_cfg negative tests reject no-L2, one-way and
  non-power-of-two-way enables; SMT2- and stream8-derived positive config tests pass.
  **SRAM correction:** removed the experimental per-set flop array. Metadata
  is now one-port/one-cycle `tc_sram`, read on accepted cacheable AR; invalid-first
  initializes after tag reset, successful installs advance. No new FSM stage,
  clock/reset or SMT/issue/retirement change. L3 still uses the default-off policy.
  **Elaboration:** 20/21 active target config-package diagnostics pass;
  `cv64a60ax` fails on existing missing `RVZiCbom/RVZiCboz/RVZiCbop` initializers
  (its only semantic diff here is the new default-off field). Archived/UVM
  literals updated but not included in that active-target sweep.
- [~] P3: paired measurements, required remote stability evidence, synthesis/timing and architecture updates.
  Final four-way latency=6 cycles legacy→RR: hot_scan 12,096→9,024;
  lfsr 9,840→8,640; **protected_hot 1,152→1,920 (regression)**;
  diagnostic total 30,315→26,811. Not a core/multicore performance claim.
  Generic 4 KiB fixture synth PASS (`l2-synth-rr{0,1}`): two→three pre-map
  memories; 120,844→121,015 generic mapped cells, no latches. Data SRAM mapping
  dominates these counts; they are not physical-area percentages. Default-off
  netlist equivalence, production geometry, remote SMT and STA/DFT/power remain open.
  **Bypass follow-up (2026-09-14):** reproduced R-hold failure from copied
  baseline `l2-drain-before/run-30YFmOGc`, then repaired independently of RR:
  preserve the S_BYPASS_R ready signal and clear AR outstanding only on a final
  R handshake. No state/stage/reset/config/DTS change; applies to enabled L2/L3.
  Expanded tests: 5 bypass requests/13 accepted R beats (single/burst/final stalls,
  exclusive EXOKAY, SLVERR/DECERR); three synthetic ATOP R-before/with/after-B
  schedules; following fill/hit and early-short-last injection guard. No real
  AMO arithmetic/reservation or new-AR-before-delayed-ATOP claim.
  Local 4-way RR off/on PASS (1,501 reads, 86 writes; original 13 phase counts
  unchanged), plus 8-way RR/latency0/stall3 PASS. Generic synth PASS:
  120,846/121,017 cells (+2 vs before fix), 2/3 memories, zero latches/problems.
  Remote pinned Verilator 5.008 PASS for both policies:
  `l2-leaf-20260914T234313-4bd9099b1be4` and `l2-leaf-20260914T234448-fec52bccce2d`.
  The initial remote attempt FAILED on unsupported GENUNNAMED; warning-name
  capability probing and vendor-scoped WIDTH restored compatibility, no SVA waiver.
  New non-cleaning runner snapshots inputs into a fresh run-* directory and
  always enables bypass/ATOP tests. Proxy `l2-leaf` uploads ten allowlisted
  inputs, verifies hashes remotely, pulls/classifies logs and emits
  `leaf-result.json` with strictQualification=false. No shared repo sync, cleanup
  or harness killing. Snapshot-host test and focused suites: 24/24, tsc clean.
  **Still gated:** real AMO/SMT/cluster integration and formal non-vacuity.
  RR remains default-off and must be compared against the corrected AXI baseline.
  Architecture/cache guide and both traceability maps now distinguish RTL
  presence, bounded diagnostics and unqualified integration; bank/channel
  mapping corrected to `(set * ways + way) % banks` rather than address bits.
  Host checks: 23/23 config + qualification tests; tsc clean; scoped RTL diff-check clean.
  Licensing pass: active contributor/policy/tier map verified; prior tier-R
  authorization retained; upstream notices and existing outbound offers preserved,
  testbench/scripts remain MIT. The earlier bulk script normalized AI-package
  line endings; `git diff --ignore-space-at-eol` confirms only the new field is
  semantic. The file-edit tools normalize supplied CRLF too, so EOL-only churn
  remains visible in its raw diff.
  **Full verification incomplete:** default `verify --formal-jobs 1 --formal-tasks 1`
  reached the legacy smoke suite's unanticipated `make clean`/`make clean_all`,
  deleting matching local generated outputs before the run was stopped. No
  tracked-file deletions were found; prior ignored-artifact contents cannot be
  reconstructed from git. No automatic restoration was attempted. Rerun only
  with explicit cleanup approval or an isolated disposable checkout. The full
  gate is NOT reported green; see build-platform/AGENTS.md §11.
  **Non-cleaning follow-up:** the unbounded
  `verify --lint --synth --target g6lc64_stream8` attempt was explicitly stopped
  while native Yosys was still active; synthesis is **incomplete**, not PASS or
  an RTL counterexample. Its actual top was `cva6`, not the L2/cluster boundary.
  A separate `verify --lint --target g6lc64_stream8` completed: Verilator PASS
  under the configured budget (278 warnings), strict slang elaboration clean.
  No simulation/cleanup stage was rerun. Full-core smoke isolation and fresh
  SMT controls remain open.
  **Replacement checks (2026-09-15 artifacts):** independent testbench tags,
  valid bits and per-set next-way state now check every lookup, installed way/set
  and victim address, including a reset/fill/invalidate-nonzero-way/refill case.
  Remote Verilator 5.008 PASS: `l2-leaf-20260915T001658-72af040d10a6` (RR off),
  `l2-leaf-20260915T001701-554d8da2815c` (RR on), and
  `l2-leaf-20260915T001821-86549ac21b77` (8-way RR, latency0/stall3).
  Four-way checks: 1,484 lookups each; off 1,341 installs/1,243 evictions, mask1;
  on 1,122/1,013, maskf. Eight-way victim maskff, 1,432 lookups. Corrupting the
  expected victim address fails immediately (`l2-policy-oracle-negative/run-daboFKUZ`).
  Proxy classification now rejects empty/inconsistent counts, missing cases,
  incorrect policy masks, failed runs and duplicate pass records; explicit
  environment pins prevent inherited L2TB_EXTRA from changing the experiment.
  **Scoped RR-off equivalence:** `L2TB_MODE=equiv` uses immutable Git blob
  `5be075b1a01ff754da384c3dd129fd58c33733fa`, applying only the validated two-line
  bypass correction to the copied golden engine. Yosys 0.68+1, memory-mapped,
  async-reset-normalized model, common 64-bit AXI inputs and 2 data banks.
  256 B/two-way and 512 B/four-way fixtures pass, respectively 9,151 and 11,675
  comparison points with none unproven (`l2-equiv-short/run-p9hU86oH`,
  `l2-equiv-4way-small/run-GC6b0TBD`). Final default 512 B/four-way mode rerun
  PASS: `l2-equiv-final/run-1blQPZgt`; negative FAIL:
  `l2-equiv-final-negative/run-ZG0cGREl`. Inverting the gate's hit output fails
  specifically at hit_o (`l2-equiv-short-negative/run-YSRsaZAE`). No zero-point
  proof or unchecked assumptions about new memory concurrency are accepted.
  SAT-only/alternative-preprocessing trials and 4 KiB equivalence exceeded the
  120-second budget; an equiv_struct trial introduced invalid internal matches
  and was rejected, not waived. The retained flow uses opt_merge plus short-cone
  SAT; larger/production-geometry equivalence is still open. No core RTL or
  production config changed in this verification tranche.

- **Next tranche (2026-09-15), still before any performance promotion:**
  larger-geometry RR-off equivalence, isolated core checked-work, and real
  AMO/SMT/cluster controls. Named packages stay split (`g6lc64_stream8` T=1
  N=2 single-issue; `g6lc64_smt2` T=2 N=1 dual-issue; `g6lc64_ooo_server`
  requests I=4/C=4 but `scoreboard`/`commit_stage` still retire two ports).
  Do not merge stream8×SMT2. RR remains default-off.
  - Equivalence: `L2TB_EQ_MEM=bbox` keep-hierarchy blackboxes uniquified
    `g6lc_l2_tag*`/`data*`/`mshr*`/`tc_sram*` so flop tags do not explode SAT.
    This is **controller/port** RR-off vs the bypass-corrected pre-RR engine,
    not a tag-flop netlist proof. Yosys 0.33:
    4 KiB/4-way **2054 proven / 0 unproven** (`run-ChPtb8Vc`);
    16 KiB/4-way **PASS** (`run-kLWpIH6I`);
    256 KiB/8-way **2057 proven / 0 unproven** (`run-zisQrCl4`,
    `--unroll-limit=16384`). Hit-output inversion leaves exactly `hit_o`
    unproven (NEG_RC=1). Collect 4 KiB **13828/0** (`run-DIR7V5Rx`, 275 s);
    earlier `run-i0I3V69g` timeout is superseded, not waived. Mapped flop-tag ladder (proxy now sets
    `YOSYS` to testharness `toolchains/formal/bin/yosys`): 1 KiB/4-way
    **16670/0** (`l2-equiv-...T024028-e033a6cf2074`); 2 KiB/4-way
    **26625/0** (`...T024114-1720ee26a8cf`); 4 KiB/4-way **46468/0**
    (`...T024234-ca4166f3968a`, 300 s); 8 KiB/4-way **86023/0**
    (`...T025605-591f32129130`, 490 s / 600 s budget). Earlier 4 KiB
    mapped 120 s budget was a miss, not a waiver. 8 KiB map is opt-in,
    not in the default ladder. Collect 8 KiB timed out at 600 s
    (`l2-equiv-20260915T081911-d252c1621712`); 16 KiB timed out at 900 s
    (`l2-equiv-20260915T072626-2597c1ae5355`) — incomplete, not waived.
    Proxy `l2-equiv --mem map|bbox`. Testharness formal/bin has yosys/sby,
    no yices; `/usr/bin/z3` exists.
  - Isolated overlay: `verif/regress/isolated-config-overlay.py` copies one
    config package, rewrites only allowlisted `L2RoundRobinEn`, and derives
    a flist. `SOFT_LADDER_ISOLATED=1` plus `SOFT_LADDER_OVERLAY=...` refuse
    production Mdir *basenames* (`work-ver-stream8`, `work-ver-smt2-fw64-B`)
    even when `SOFT_LADDER_VERLIB` is an absolute remote path. Qualification
    manifests must be exact production filenames, not `*work-ver-stream8*`.
    N=1/N=2 overlays are experimental, not Linux SKUs.
  - Checked-work payload: `mini_checked_work.S` (48 KiB, NWORKERS=2).
    Compiled `remote-runs/checked-work/mini_checked_work.elf`. RR-off
    cluster **control** on production `work-ver-stream8`: tag
    `checked-work-stream8-n2`, **154,170 cycles**, kernel `tohost=1`
    (mini pass; fail is 3). Harness prints `FAILED (tohost = 1)` because
    non-zero tohost is HTIF-fail; classify from the kernel code, not that
    line. Isolated RR-on candidate: Mdir `iso-stream8-rr1` (production
    names refused by basename), overlay `L2RoundRobinEn` 0→1
    (`overlaySha25612=d0f9c87f67fd`), warm-seeded from `work-ver-stream8`.
    Manifest exe `ec650f20…` (603 sources; production stream8 stays
    `7e27de94…`). Same ELF, tag `checked-work-stream8-n2-rr1`, kernel
    `tohost=1` after **154,170 cycles** — identical to the RR-off control.
    Sequential fill/verify is not a replacement-sensitive working set;
    this is a functional isolated-candidate envelope, not a speedup.
    `qualify-checked-work` CONTROL PASS. Production packages stay RR
    default-off. Sidecar `G6LC_METRICS_SIDECAR` is compiled only into new
    harnesses.
  - Candidate-on SMT pairing (not a package merge): production
    `work-ver-smt2-fw64-B` exe `894ea012…`. Isolated `iso-smt2-rr1` has
    live `gen_l2...gen_rr...i_metadata` (RR-on netlist), exe `a76e218c…`,
    overlay `L2RoundRobinEn` 0→1 (`overlaySha25612=326ed3f46c85`).
    N=2 timed out 400k `tohost=0` (only `trace_hart_0`; `wait_workers`).
    N=1 compressed tohost spun on `c.li`/`c.j` after fill/verify.
    Uncompressed tohost RR-off **CONTROL PASS**
    `checked-work-smt2-n1-norvc` **129,455 cy** `tohost=1`; fully
    uncompressed body `...-norvc-body` **135,616 cy** `tohost=1`.
    Isolated RR-on **livelock** in verify: 400k and **2,000,000 cy**
    `tohost=0`, fetch stuck dual-issuing the two loop addis (16-bit or
    32-bit) and never the `bnez`. A nop between addis only shifted the
    stuck pair (`...-rr1-nop`). Stream8 I=1 RR-on still PASSes. This is
    SMT2 I=2 fetch after long-latency miss, exposed by RR-on; not L2
    data corruption (`tohost` never 3). Fetch dual-issue repair is
    follow-on (needs new approval). Cookie soak was not re-run.
  - Real AMO at the L2 leaf: `+amo-arith` (always on in the runner) computes
    ADD/SWAP/CAS.W and LR/SC reservation in the memory model, then checks
    WT self-inval readback. Remote Verilator 5.008 **PASS**
    `l2-leaf-20260915T012151-99c14472e3e2` (RR off, 4-way/4 KiB): policy
    1,484/1,341/1,243 mask=1 plus
    `AMO arith add=1 swap=1 cas_hit=1 cas_miss=1 lrsc_ok=1 lrsc_fail=1`.
    First attempt `...T011700-0930b1b14318` failed on an inline SC AW
    timeout; SC now uses the existing write driver with lock/BRESP. This is
    still a leaf control, not cluster AMO through `g6lc_axi_lrsc`.
    Cluster minis on production `work-ver-stream8` vs `iso-stream8-rr1`:
    AMOCAS.W 550/550, D 704/704, Q 998/998, `mini_stream_plane` 2138/2138
    (SUCCESS `tohost=0`). All-set hot+scan `mini_l2_hot_scan.S` (512 sets,
    16 rounds, HTIF exit 0 from kernel `tohost=1`) **384,179 / 384,179** cy.
    Identical cycles. Leaf A/B (4-way/4 KiB): RR-off 31,108 cy / 143 hit /
    1,348 miss (`l2-leaf-...T075756-9ce569078d49`) vs RR-on 27,604 cy /
    362 hit / 1,129 miss (`...T075827-c740d8b7af0d`); `hot_scan` 12,096→
    9,024, `protected_hot` 1,152→1,920. Pin-level mix is not a core win.
    Generic synth (not STA): RR-off 2 `$mem_v2`/1,257 cells vs RR-on 3
    `$mem_v2`/1,281 cells (`...T080459-9e4346fd0dee`,
    `...T080517-a300dbaed132`). 8-way leaf A/B: 26,256 vs 26,080 cy
    (`...T080935-67c68349c896` / `...T081003-a0436a16ea1d`); hot_scan win
    cancelled by protected_hot. Best P0–P4 area/perf: keep RR off. Cookie
    soak not re-run as a performance claim.
  - MSHR/bank-conflict **leaf** (not serialized top): `L2TB_MODE=units`
    instantiates `g6lc_l2_mshr` (DEPTH=4, MAX_WAITERS=2) and `g6lc_l2_data`
    (2 banks) directly. Remote Verilator 5.008 **PASS**
    `l2-leaf-20260915T020340-df5db8e21fd8`:
    `mshr_full=1 merge=1 merge_full=1 waiter=1 bank_conflict=1 bank_ok=1`.
    Units compile uses `tb_g6lc_l2.vlt` (LATCH `wi`, vendor WIDTH). Drive
    at negedge like `axi_read`. Top still leaves `merge_full_o` unconnected
    and `waiter_pop_i=0`; mapped RR-off equiv includes the MSHR netlist, so
    the ready formula was not changed. First units attempt failed `-Wall`
    (`...T014409-f4c25b090d2e`).
  - Rename covers: `g6lc_ooo_rename_cover.sby` PRF=40. Local yices **PASS**
    1 s, depth 8: alloc step 2, dual-alloc step 2, ckpt/mispredict step 3,
    `stall_o && free_q==0` step 6. Path-check only. Testharness has no
    yices; a yices+z3 race ERROR-kills z3. Remote z3-only
    (`verif/regress/remote/run_ooo_rename_cover.py`) TIMEOUT 90 s, 0 traces
    (`rename-cover-z3-2`). BMC rename stays in `verify.formalTasks` (abc+z3).
  **Still open:** mapped production-geometry (256 KiB) flop-tag equivalence,
  16 KiB collect (900 s timeout, not waived), smt2 full checked-work
  regression (fetch-B/icache defect bisected to `7e6c19c54`; RR
  exonerated — see vt1 table below). Remote rename cover is TIMEOUT (not a gate). Cluster AMOCAS on isolated
  stream8 RR-on is a functional envelope with 0 cycle delta, not a win.
  Isolated stream8 RR-on is a functional envelope. SMT2 N=1 RR-off
  control passes; N=2 waits for hart 1. **Performance promotion is still
  NOT QUALIFIED.**

- **Deterministic vt1 resolution (2026-09-15, second sitting):** the
  earlier `384,179/384,179` identical-cycle result was a confounder —
  the scan buffer sat inside `ExecuteRegionDramLen` (WB-only path), so
  L1/L2 never saw the traffic. Isolated e8k overlays set
  `ExecuteRegionDramLen 0x40000000→0x8000` (data cacheable) plus
  `L2RoundRobinEn 0→1` for the RR leg. `mini_l2_hot_scan_pmu.S` reports
  PMU words at `report` (DRAM offset `0x1080`). Paired
  `--threads 1` runs, identical tree (L2 `3a1e788c…`), identical ELF,
  `+debug_disable`, cookie exit `off=0x1000 val=1`:
  rr0 `cyc=374,177 l2m=18,787 l1m=18,857 lds=20,483 dac=20,524` vs
  rr1 `cyc=325,980 l2m=13,318 l1m=18,857 lds=20,483 dac=20,524`
  (−12.9% ROI cycles, −29.1% L2 misses; ~8.7 cy/avoided miss on a
  deliberately RR-favourable hot+scan). Genuine core-level RR signal,
  NOT promotion evidence.
- **vthreads=12 is not qualification-grade:** the same vt12 exe
  completed at 912,938 cy once then hung at ~397k on rerun; smt2
  showed nonconverge/livelock variants. All anomalies vanish under
  `--threads 1`; guest-visible PMU counters are bit-identical across
  schedulers, so vt12 divergence lived in scheduler/observer paths.
- **smt2 "RR livelock" retracted:** all smt2 traffic is
  `AxCACHE=0010` → rejected by the L2 cacheability predicate → RR
  logic is functionally dead on smt2. `iso-smt2-rr0-vt1` and
  `iso-smt2-rr1-vt1` both PASS at 22,964 cy on the 8 KiB
  `mini_checked_work_n1_8k.elf`. The vt12 livelock was a scheduler
  artifact, not RTL — but see the full-ELF finding below.
- **Full `mini_checked_work.elf` (48 KiB) fails on the current tree,
  RR-independent, bisected to `7e6c19c54` (2026-09-15 third sitting):**
  same ELF, same observer (`+debug_disable`, cookie exits val=1/3,
  `--threads 1`, `env -i` — see env crash note):

  | build | tree | result |
  |---|---|---|
  | `work-ver-smt2-fw64-B-vt1` (Aug-30 exe) | `2c7dd4870` | `tohost=1` @131,072 |
  | `base-smt2-vt1` (fresh `@2c7dd4870`) | `2c7dd4870` | `tohost=1` @143,360 |
  | `mid7-smt2-vt1` | `7e6c19c54` | fetch-loop at entry → `_hang` |
  | `mid6/mid5/mid4` | `4885b41f6`/`ccedfbfce`/`aee0b36c3` | trap/park |
  | `mid3` | `fedf3f2b7` | cause=6 (store-misaligned) @t=336 → `_hang` |
  | `mid2` | `becdd9f92` | `tohost=3` @143,360 |
  | `mid` | `348343e37` (= `ac820a3d6~1`) | `tohost=3` @143,360 |
  | `iso-smt2-nodrain-vt1` | HEAD minus drain tweak | `tohost=3` @143,360 |
  | `iso-smt2-vt1` | HEAD RR=0 | `tohost=3` @131,072 |
  | `iso-smt2-rr1-vt1` | HEAD RR=1 | `tohost=3` @~131k |

  `tohost=3` is the kernel's verify-mismatch verdict: a load returns
  different data than the fill store wrote. First bad commit is
  **`7e6c19c54` "Fix remote testharness exclusivity, DI pass detection,
  and bootrom s0 load"** — the `g6lc_icache` two-cycle-hit rewrite
  (`cl_index`/`dreq_o.vaddr` → `vaddr_q`, `dreq_o.ready` removed from
  the READ-hit branch, `kill_s2`→`kill_s1`, `vaddr_q` reset to
  `boot_addr_i`) plus `instr_queue`/`frontend`/`issue_read_operands`/
  `g6lc_issue_barrier` changes and the `addi s0, x0, 1` bootrom
  workaround. Its own message names an "SMT FDT-compensation commit
  filter" that can suppress immediate loads — exactly the mechanism
  for a corrupted `li`/`mul`/`add` chain producing a bad store address
  (misaligned trap at `fedf3f2b7`) or bad stored data (`tohost=3` at
  HEAD). Symptom drifted with the 8-31 afternoon fetch churn; the
  defect did not. **Neither `L2RoundRobinEn` nor the drain tweak is
  implicated** — the nodrain build fails identically and all smt2
  traffic bypasses L2. The fully-uncompressed `-norvc` variant also
  fails `tohost=3` @131,072 on current-tree vt1 (`smt2-norvc-vt1`,
  ELF sha1 `a5a04d6d…`), so the defect is NOT RVC-realigner-specific;
  the earlier `-norvc` PASS was vt12/older-tree evidence. This is a
  fetch-B/icache or issue/commit-path regression tracked in
  `architecture/core-fetch/NEGATIVE.md`; it blocks any smt2
  checked-work claim and any SMT gate, independent of L2 work.
- **Current-tree smt2 vt1 exe startup crash (env-dependent):**
  `iso-smt2-vt1` and a fresh production-config vt1 build segfault in
  `getenv("G6LC_METRICS_SIDECAR")` under the proxy's full environment;
  `env -i` runs cleanly. `__environ` is valid but a later environ
  entry points at unmapped memory — generated-model/host-layout
  interaction, not RTL. rr1-vt1 does not crash; treat rr0 verdicts as
  requiring `env -i` until reduced.
- **Harness observer traps (recorded so they are not re-debugged):**
  `debug_req` fires at t≈511 after `DmiDelCycles=500`; under vt1 it
  parks the hart in bootrom `_hang` with no debugger → use
  `+debug_disable` for standalone workloads. `rvf_tracer` reports
  `tohost_addr=0` for this ELF and `dtm->done()` never fires, so the
  only trustworthy exits are soak/cookie rules
  (`exit cookie off=<dram_off> val=<tohost_val>` polls the DRAM array
  directly). `log mem off=` takes DRAM-relative offsets, not VAs.
  Rule text belongs in `CVA6_TRACE_SPEC`, not `CVA6_TRACE`.

Candidate RTL is present but **performance promotion is NOT QUALIFIED**. No new
Linux boot, SMT stability, physical sign-off or production-geometry equivalence
claim is made; the small-fixture RR-off equivalence result above is separately scoped. Concurrent APU work and its verification records are separate.

Baseline issue found while landing P0 (pre-existing, not caused by these edits):
`bun test` → `branding-g6lc.test.ts` fails on the two `g6lc_core_types.svh`
headers — the stem check scans `.svh` macro includes and finds no module/package
declaration (`found [moved]` is a regex false-positive on a comment word). Either
exempt `.svh` includes from the stem rule or rename the headers; deferred as a
test-semantics decision, unrelated to the qualification path.

## API-neutral APU completion review (2026-09-15)

**Current-state authority:** review of `d74010111d7f9d78e32e75fd64f4ea07c3323fcc`.
Older P0/P1/P2 entries below are historical slice evidence where superseded here.
The local APU plan `plan-5ddc97674e5bf9b0.md` is flattened into gates A0–A7,
not another chronological cookie series. `architecture/uncore/apu-*` now
separates bring-up mechanisms, actual guarantees and deployment blockers.

- [x] Review both the APU plan and recoverable-BIOS plan
  `plan-c06f2ee19717de0d.md`. Define independent platform-managed and optional
  BIOS-managed loading of one persistent S-mode service. Only an image/status/
  handoff adapter is common; no BIOS crate dependency, shared journal writer or
  synchronized update cycle. `apu-firmware-domain.md` owns the contract.
- [x] Distinguish firmware-instance readiness, graphics owner/queue epochs and
  Linux boot-attempt health. APU cookie/heartbeat is not Linux acknowledgement,
  BIOS candidate confirmation, watchdog ownership or permission to autoboot.
  Optional graphics failure leaves serial/recovery usable. No BIOS code changed.
- [x] Reproduce and fix AXI4 source retention in `g6lc_apu_th`: twelve failing
  checks became **12 cases / 60 checks / 221 clocks, errors=0**. AW and AR hart
  tags are captured at accepted address handshakes and held through the adapter;
  both source-change directions and delayed W are tested, including side effects.
- [x] Reproduce and fix native Fetch admission: 26 failing checks became
  **29 cases / 61 checks / 2,646 clocks, errors=0**. Shader privilege applies
  to BR/NOP/HALT as well as Issue-stage ops; undefined opcodes and high register
  bits fault without RF writes. A valid job recovers after decode failure.
- [x] Reproduce and fix firmware-RAM read errors: six failing checks became
  **8 cases / 842 checks / 2,479 clocks, errors=0**. Rejected ARs return exactly
  ARLEN+1 beats (17 and 256 included, on/off); all misaligned 64-bit reads reject.
- [x] Firmware-RAM write follow-through: initial tests reproduced **170 failed
  checks**. Expanded suite passes **49 cases / 5,699 checks / 5,372 clocks**:
  AW-first/W-first/coincident arrivals, 2/16/256-beat rejected bursts on/off,
  captured AW metadata, stable B/ID, missing-data stalls, early/missing WLAST
  quarantine, coordinated reset, sparse/zero strobes and guard-byte preservation.
  Enabled/disabled 4-KiB strict leaf lint and generic synthesis pass, including
  exactly one retained pre-map `$mem_v2` enabled and zero disabled. Existing LEN
  state is reused; lane-mask admission adds no valid-write latency or new clock.
  ApuOff, ExecEn and FeatureVirgl/DTS grants are unchanged. This is not full-PA
  protection, a complete AXI target, formal proof or Linux/GLES2 functionality.
  Focused remote run `cf49f2` exited 0; CVA6 cookie remains **14 checks / 1,835
  clocks**, `0x600D000A`, with five existing core SELRANGE warnings. Test-map
  entry records the RAM/TB blob identities and logs. General verify was rechecked
  in dry-run only: still selects local/core suites, not executed APU qualification.
- [x] Earlier review: all directed suites in the combined APU runner passed
  before the write follow-through (not a fresh all-suite result for that slice):
  transport/control, three read/two write profiles, SG64/128, storage/queue/
  memory/system, grant/attach/compositor/domain, exec/mailbox and firmware
  diagnostics. Firmware cross-compilation is **skipped** on the builder (no
  RISC-V gcc); checked-in hex/host tests are not freshly compiled firmware proof.
- [x] Close the remote review rerun `5a1d1f` (exit 0): compositor **64 cases /
  513 checks / 3,071 clocks**, CVA6 cookie **14 checks / 1,835 clocks**,
  `0x600D000A`. Native/compositor lint and generic synthesis screens completed:
  exec **25,430 cells / 3,888 sequential bits**, enabled 4-KiB compositor
  **156,122 cells / 40,178 sequential bits**. These are per-fixture screens,
  not a new all-fixture area baseline, memory-retention proof or STA.
  Initial combined run stopped at upstream FPnew package width warnings;
  `apu_axi.vlt` scopes LITENDIAN/WIDTHEXPAND to that package only. Existing
  runner waivers remain; CVA6 still emits five SELRANGE warnings in
  `core/issue_read_operands.sv` (1303, 1375, 1424), and Slang reports upstream
  unreset SRAM read-data warnings. Do not call this warning-free full-core lint.
  Local run log: `%LOCALAPPDATA%/Temp/devin.exe-overflows/`
  `shell-5a1d1f-85d08c19fdc81f85/content.txt`; remote artifacts under
  `/tmp/g6lc-apu-virtio-mmio`. No firmware cross-compile or Linux boot is inferred.
- [ ] General build-platform gate remains **dry-run only**, not PASS:
  `verify --lint --formal --sim --synth --target g6lc64_stream8 --dry-run`
  selects local Verilator and unrelated core suites. Resolve remote routing/
  APU registration separately; do not edit concurrent qualification settings.

**Remaining gates (not implied by the implemented corrections):**

- [x] A1 epoch across the AXI4 buffer. `g6lc_apu_axi4_lite` latches the
  admission epoch at AW/AR accept, and the lite wrapper stamps that epoch
  while the beat is presented. A guest reset during a split control write
  returns SLVERR and leaves queue select unchanged. Direct lite masters still
  stamp the live epoch. Remote 2026-09-22: th **13 cases / 73 checks / 271
  clocks**, sys 5/148/669, soc 16/44, attach 4/32/77, axi-lite 318/1601.
  `g6lc_apu_th_fixture` synth, no latches: Enable=0 **124 cells / 16
  flip-flops**; Enable=1 **24,294 / 2,797**.
- [x] A1 firmware-RAM physical window. `in_win` and the SRAM index use the
  full 64-bit offset from `FirmwareRamBase`. Sign-extended
  `0xffffffff90000000` and bit-32 `0x190000000` reads and writes are SLVERR
  and leave the canonical word unchanged. A wrapping span is rejected.
  Remote 2026-09-22: **49 cases / 5,710 checks / 5,389 clocks**, errors=0.
  4 KiB synth, no latches, one `$mem_v2` enabled and zero disabled: Enable=0
  **245 cells / 16 flip-flops**; Enable=1 **105,946 / 32,940**. Not a source
  grant and not a re-run of the CVA6 cookie.
- [x] A1 mapping publication. `g6lc_apu_storage` keeps one flop per resource
  slot. Lookup, duplicate detection, and invalidate match that bit, not the
  SRAM valid flag and not `SimInit`. Reset and the invalidate pin clear the
  bits. A warm reset hides a mapping that is still sitting in SRAM, and a
  word written only into the array is not returned. Remote 2026-09-22:
  **32 cases / 150 checks / 590 clocks**, errors=0. Disabled fixture is
  ports only. Enabled pre-map `memory_collect` keeps 2 memories; synth is
  **1,270 cells / 89 flip-flops**. The clock-gate latch is the existing
  power cell. Lease-aware retire is still open.
- [x] A1 reserved-hart check for control and firmware RAM. The compare
  takes the supplied hart. Firmware RAM captures it at AW/AR accept, so a
  later pin change does not retag the beat. Hart 0 is SLVERR and leaves
  the canonical word unchanged. PROT `3'b111` with a nonzero AXI id still
  completes for hart 1, and privileged PROT does not admit hart 0. Remote
  2026-09-22: grant **18 checks / 12 clocks**; fwram **52 cases / 5,739
  checks / 5,479 clocks**, errors=0. 4 KiB fixture synth, no latches:
  Enable=0 **245 cells / 16 flip-flops**; Enable=1 **106,018 cells /
  32,941 flip-flops**, one `$mem_v2` before mapping. The CVA6 cookie was
  not re-run.
- [x] A1 per-master provenance before cluster aggregation. `g6lc_apu_src_guard`
  finishes a non-firmware hart's RAM or control transaction locally, so
  the hub never sees it. The firmware hart is a wire. A sign-extended
  alias is not treated as the window. Remote 2026-09-22: **4 cases / 31
  checks / 60 clocks**, errors=0. Synth, no latches: firmware hart is
  **6 ports / no cells**; application hart is **2,193 cells / 29
  flip-flops**. `g6lc_apu_xbar_hart` takes the crossbar's prepended port
  index. The cluster port is the firmware hart. Debug and DMA are hart 0.
  The master's low ID bits are not a hart. **5 checks**, errors=0. The
  CVA6 cookie was not re-run.
- [ ] A1: L2 line-fill requests are not tagged with a hart. Window traffic
  from a non-firmware hart does not reach the cache. A fill that the
  firmware hart itself caused is still that hart's traffic.
- [x] A1 exec cancel completion. `g6lc_apu_exec_bind` turns an accepted op
  into a held completion with status CANCELLED instead of returning to idle.
  A completion that already finished stays unchanged until acknowledged.
  A disabled exec op is not ready. The mailbox keeps a handed-off job busy
  until that completion, and records CANCELLED for a GO that was never
  accepted. Remote 2026-09-22: **5 cases / 26 checks / 45 clocks**,
  errors=0. Bind fixture synth, no latches: disabled ports only; enabled
  **25,829 cells / 4,006 flip-flops**.
- [x] A1 xbar drain pins. `g6lc_apu_xbar` exports device-reset and
  queue-stop and takes backend idle and teardown-done. A firmware ACK
  does not drop a pin while the selected queue is busy, or while device
  reset is waiting on teardown. Enable=0 holds both requests at 0.
  `g6lc_apu_th_load` still drives idle and done high, so the cookie path
  is unchanged. Remote 2026-09-22: **5 cases / 29 checks / 84 clocks**,
  errors=0. Xbar fixture synth, no latches: Enable=0 **124 cells / 16
  flip-flops**; Enable=1 **23,361 / 2,477**.
- [x] A1 truthful exec geometry. An enabled device must name 4 threads,
  8 registers, 16 instruction words, and 64 data words. The cluster arrays
  and the debug/job indices are those widths. Register counts 0/4/16/32,
  DMEM counts 0/16/32/128/256, and thread counts 0/2/8 are illegal whether
  or not exec is selected. A disabled device is still legal. Register 7
  takes a poke and register 0 stays zero; DMEM words 0 and 63 read zero
  after reset. Memory plus exec stays illegal. Remote 2026-09-22:
  **5 cases / 43 checks / 9 clocks**, errors=0. Exec fixture synth, no
  latches: Enable=0 ports only; Enable=1 **25,430 cells / 3,888
  flip-flops**. `tc_sram`, program bounds, context scrub, and DFT remain
  open.
- [x] A1 lease-aware retire. A mapping slot and the command snapshot stay
  published while `child_idle_i` is low. Insert, invalidate, and command
  release wait for that pin. A one-cycle invalidate or release is applied
  once the child is idle. The memory wrapper ties the pin to read, write,
  and SG idle. The SG table stays visible through invalidate until its
  list reader and fragment DMA are idle and the unit is not mid-query.
  Remote 2026-09-22: storage **36 cases / 170 checks / 668 clocks**;
  SG entries=64 **122 cases / 6,593 checks / 11,352 clocks**; errors=0.
  Storage post-synth: disabled ports only; enabled **1,296 cells / 91
  flip-flops**. SG post-synth, no latches: disabled ports only; enabled
  **58,237 cells / 13,266 flip-flops**, one memory before mapping.
  Command DMA now uses the published slot. Scatter-gather and the used
  ring still take raw maps.
- [x] A1 AXI4-Lite burst drain and split-write errors. A rejected write
  accepts every `AWLEN+1` beat before B, and a rejected read returns every
  `ARLEN+1` beat with RLAST only on the last. B is withheld while write
  data is outstanding. A WLAST that does not match the count quarantines
  the bridge until reset. A split store keeps the low half's error when
  the high half returns OKAY. Remote 2026-09-22: **9 cases / 47 checks /
  95 clocks**, errors=0. Bridge fixture synth, no latches: Enable=0
  **234 cells / 16 flip-flops**; Enable=1 **1,606 cells / 266
  flip-flops**. Not a general downsizer.
- [x] A1 narrow, 4 KiB, exclusive, and ATOP policy on firmware RAM.
  A narrow read is one size-aligned beat. A byte store does not write.
  A 64-bit fill that crosses a 4 KiB page is SLVERR for every beat; a
  fill that ends on the boundary completes. Exclusive lock and ATOP do
  not modify SRAM and never return EXOKAY. AtomicLoad, AtomicSwap, and
  AtomicCompare also return one R. `fault_o` stays high with no response
  while a mismatched WLAST is outstanding. Reset clears it, the store
  has not landed, and the next store completes. Remote 2026-09-22:
  **56 cases / 5,799 checks / 5,631 clocks**, errors=0. 4 KiB fixture
  synth, no latches: Enable=0 **274 cells / 17 flip-flops**; Enable=1
  **106,176 cells / 32,943 flip-flops**, one `$mem_v2` before mapping.
  `g6lc_apu_th_load` forwards `ram_fault_o`. The CVA6 cookie was not re-run.
- [x] A1 supervisor for a quarantined firmware-RAM master.
  `g6lc_apu_fault_sup` asserts `reset_o` on the clock after `ram_fault_o`
  and holds it until the pin is low. There is no timeout. The module's
  own reset is the pad `rst_ni`. That request gates `rstgen`, so
  `ndmreset_n` resets the crossbar and the RAM together. SRAM is not
  cleared. A legal store does not request reset. A mismatched WLAST
  produces no B, the old word stays, and the next store completes. A
  fault that stays high keeps reset asserted. Enable=0 holds the request
  at 0. Remote 2026-09-22: **3 cases / 18 checks / 54 clocks**, errors=0.
  Fixture synth, no latches: Enable=0 **4 ports / no cells**; Enable=1
  **1 cell / 1 flip-flop**. The CVA6 cookie was not re-run. L2 line fills
  are still not tagged.
- [x] A1 scheduler for memory and exec together. `g6lc_apu_sched` is one
  mailbox. Each op is presented to the memory client or to exec, and not
  to both in the same cycle. A mapping insert and lookup complete, a
  local LDI/HALT job peeks 10, and the mapping is still there afterward.
  Exec does not read the mapping. No DMA runs in that proof profile.
  `ApuHarness` keeps exec and the memory clients off. `ApuSchedBoth` is
  not the boot config. Remote 2026-09-22: **4 cases / 107 checks / 161
  clocks**, errors=0. Fixture synth, no latches: Enable=0 **10 ports /
  no cells**; Enable=1 **28,966 cells / 4,839 flip-flops**. The exec-only
  compositor is unchanged: **64 cases / 518 checks / 3,071 clocks**.
  The CVA6 cookie was not re-run.
- [x] Command DMA pins the published slot. `APU_MEM_CMD_DMA` looks up
  resource, context, and epoch and reads that mapping. The mailbox base
  is not the address. An unknown id and a stale epoch issue no read. A
  pin dropped while idle makes the next command DMA of that id fail
  closed. A command-read word already on the bus stays until it is
  taken. Exec `LD`/`ST` stays local DMEM. Scatter-gather and the used
  ring still take raw maps. Remote 2026-09-22: **10 cases / 19 checks /
  227 clocks**, errors=0. Mem fixture synth: Enable=0 **35 ports / no
  cells**; Enable=1 **48,788 cells / 12,119 flip-flops**, final netlist
  has no latch cells. The CVA6 cookie was not re-run.
- [x] One-sample triangle coverage. `g6lc_apu_cover` reports covered or
  not and the integer edge weights for one point. Weights sum to the
  signed area. A top or left edge of the counterclockwise winding is
  included; a bottom edge and a diagonal are not. Moving one vertex
  across the sample flips coverage and leaves the color word unchanged.
  A zero-area triangle misses. `CoverEn` stays 0 on the shipped profiles
  and does not legalize virgl. The unit is not in the testharness.
  Remote 2026-09-22: **9 cases / 78 checks / 40 clocks**, errors=0.
  Fixture synth, no latches: Enable=0 **8 ports / no cells**; Enable=1
  **22,506 cells / 174 flip-flops**. The CVA6 cookie was not re-run.
- [x] One RGBA8 pixel from coverage weights. `g6lc_apu_frag` writes
  byte0 red at `y * stride + x * 4`. Channels round half up. A miss and
  a fault leave the stored bytes unchanged. The 4×2 image is
  `32'hFF0000FF` at `(0,0)`, `32'hFF404080` at `(1,0)`, and zeros
  elsewhere. `FragEn` stays 0 and does not legalize virgl. The unit is
  not in the testharness and is not the HDMI buffer. Remote 2026-09-22:
  **8 cases / 41 checks / 309 clocks**, errors=0. Fixture synth, no
  latches: Enable=0 **12 ports / no cells**; Enable=1 **21,762 cells /
  527 flip-flops**. The CVA6 cookie was not re-run.
- [x] One unfiltered texel into that pixel. The texel image is the single
  RGBA8 at `(0,0)`. A covered sample stores it at `y * stride + x * 4`.
  Any other coordinate is a fault. A coverage miss does not fetch. The
  texel `32'hFF80FF40` lands at `(2,0)` and leaves the blend and solid
  pixels unchanged. No filter and no wrap. `TexelEn` stays 0 and does
  not legalize virgl. The TEX opcode still returns `-26`. Remote
  2026-09-22: **12 cases / 58 checks / 331 clocks**, errors=0. Fixture
  synth, no latches: Enable=0 **12 ports / no cells**; Enable=1
  **22,141 cells / 559 flip-flops**. The CVA6 cookie was not re-run.
- [ ] A1: immutable command/program storage beyond the held snapshot, and no
  stale program data left readable across reset. Slot publication and the
  idle lease pin are already in.
- [ ] A2: real pinned OpenSBI → S-mode service and Linux. Current DTS next-mode=3,
  direct reset, cookie, `fw_ready=#1` / synthesis constant and UART/CLINT/PLIC
  stubs do not prove this. Add verified loader/BSS/traps/cache sync/protection,
  service-ready and failed-image/restart behavior; reserve hart/memory in Linux.
- [ ] A3: standard virtqueue/virgl decoder. The host and CVA6 share
  `g6lc_apu_tgsi_compile` for this subset (2026-09-22, tgsi-cc 14 checks /
  21,093 clocks, cookie `0x600D000B`). `IN`/`OUT`/`CONST` aliasing,
  vec4/write-mask semantics, and mandatory Mesa limits remain unsatisfied.
  `RESOURCE_CREATE_2D` payload decode and the fence echo are in
  (2026-09-22, vgpu cmd 10 cases / 41 checks / 44 clocks). One local
  used element and its interrupt are in. One local avail descriptor
  is walked and supplies that command. One backing entry is stored
  for an existing resource. One read of that entry is in the
  resource. A descriptor chain, the guest-memory used ring, and draw
  remain open.
  The TEX opcode still returns `-26`.
- [x] One local used element and its interrupt. The element is stored
  before `used.idx` advances. IRQ rises with the index and falls on ack.
  A cancel before the index does not publish. After a fenced
  `RESOURCE_CREATE_2D`, descriptor 4 length 24 is element 0 and the index
  is 1. Queue length 8. No avail walk and no guest-memory write.
  `UsedEn` stays 0. Remote 2026-09-22: **5 cases / 31 checks / 37
  clocks**, errors=0. Fixture synth, no latches: Enable=0 **16 ports /
  no cells**; Enable=1 **1,342 cells / 613 flip-flops**. The CVA6 cookie
  was not re-run.
- [x] One local avail descriptor. The driver may publish only the next
  index. A walk returns that descriptor's 40-byte command. `NEXT`,
  `WRITE`, and `INDIRECT` fault and do not consume the slot. A length
  other than 40 faults the same way. A later post is not reached while
  that fault stays at the head. Descriptor 4's `RESOURCE_CREATE_2D`
  decodes to `OK_NODATA` with the fence and resource 7, and the local
  used ring publishes that id as element 0. No chain and no guest-memory
  read. `AvailEn` stays 0. Remote 2026-09-22: **17 cases / 77 checks /
  93 clocks**, errors=0. Fixture synth, no latches: Enable=0 **10 ports /
  no cells**; Enable=1 **7,731 cells / 3,356 flip-flops**. The CVA6
  cookie was not re-run.
- [x] One resource-attach backing entry. `RESOURCE_ATTACH_BACKING`
  stores one memory entry when the resource already exists,
  `nr_entries` is 1, and the length is `width * height * 4`. A second
  attach returns `ERR_UNSPEC` and does not replace it. An unknown id,
  a zero or misaligned address, a wrapping range, and any other
  command type store nothing. Resource 7 keeps `64'h8800_1000` for 32
  bytes. The unit does not read guest memory. `BackEn` stays 0.
  Remote 2026-09-22: **19 cases / 138 checks / 99 clocks**, errors=0.
  Fixture synth, no latches: Enable=0 **12 ports / no cells**;
  Enable=1 **8,782 cells / 363 flip-flops**. The CVA6 cookie was not
  re-run.
- [x] One read of the stored backing entry. `TRANSFER_TO_HOST_2D`
  copies that entry into the resource when the rectangle is the whole
  resource and the offset is 0. A mismatched or failed response does
  not change the image. The 4×2 resource keeps 32 bytes from
  `64'h8800_1000`. The 1×1 resource keeps 4 bytes and clears the rest.
  There is no guest write. `XferEn` stays 0. Remote 2026-09-22:
  **13 cases / 121 checks / 91 clocks**, errors=0. Fixture synth, no
  latches: Enable=0 **24 ports / no cells**; Enable=1 **10,086 cells /
  974 flip-flops**. The CVA6 cookie was not re-run.
- [ ] A4: handle-only protected LSU on top of the memory/exec scheduler,
  vertex fetch, interpolation across a primitive, and a filtered sampler.
  One-sample coverage, one RGBA8 pixel, and one unfiltered texel are in.
  Context isolation and a cache-visible common surface remain open.
  Current local storage is resettable arrays, not tc_sram. Exec geometry
  now matches that file. DFT claims remain open.
- [ ] A5: unchanged Linux/Mesa EGL/GLES2 shader/data-dependent output on RTL,
  no software fallback, raw+PPM evidence; BIOS same-device scene and quiesced
  client handoff. Optional BIOS-managed provisioning is a separate integration
  test, not a second firmware. Linux health stays with the BIOS plan's live gate.
- [ ] A6/A7: full advertised feature/error/exhaustion/CTS coverage, non-vacuous
  formal safety/liveness, AI/APU/config coexistence, gaming after correctness,
  HDMI/DP scanout and actual STA/CDC/DFT/MBIST/power/board qualification.

**Review checklist:** separately ApuCfg-gated; no new clock/reset/CDC or CPU/AI
change. Source latching adds two HartIdWidth banks without bus latency; decode
checks remain before existing stage registers; RAM uses its existing LEN counter
and SRAM seam. Timing/area are screening only. No DTS/capability/ISA grant changed.
Tier/header review is manual: active Etienne Cimon is the recorded rights holder;
RTL keeps tier R, tests keep MIT, upstream notices and GPL-free link separation
are unchanged. Existing QEMU whitespace findings are unrelated and left intact.

## API-neutral APU P0 groundwork (2026-09-14)

Priors/status: `g6lc_bios/architecture/DISPLAY.md` §API-neutral APU and
`g6lc_bios/AGENTS-todo.md`. EGL remains client-side; proposed hardware uses an
independent uncore gate and unchanged virtio-gpu/virgl drivers, with resident
command firmware but no CPU rendering.

- [x] First BIOS protocol slice: eight regression tests, corrected feature/bind/
      clear fields and full capset-v1 response sizing; no fictitious GLSL grant.
- [x] Follow-up P0 tests cover request/fence/error bounds and u16 queue wrap;
      seventeen wire/model tests now present, plus picker-arm publication order.
      The tracked external replay validates 11 requests and two fences, with
      corrected Y_0_TOP orientation: 307,200 exact pixels on llvmpipe and D3D12.
      This remains external-reference, not full virtqueue, Linux-driver or RTL evidence.
- [x] OpenWrt 24.10.2 / Linux 6.6.93 boots through `g6lc_qemu` to a working
      shell using a temporary ttyS0 inittab overlay. Guest sees GPU device 0x0010.
- [x] Graphics-enabled remote OpenWrt/QEMU now executes the unchanged guest
      virtio-gpu + Mesa virgl path over modern virtio-mmio. QEMU 10.0.0 has
      OpenGL/virgl/GBM/vhost-user; the headless host uses `vhost-user-gpu` with a
      surfaceless-EGL shim. Guest evidence includes `+virgl`, two capsets,
      `/dev/dri/renderD128`, `gbm-window`, renderer `virgl (LLVMPIPE...)`, stable
      pixel FNV-1a `0x3d667145`, `G6LC_EGL_GLES2_DRIVER=virgl`, rc 0. This is
      host software-rendered virgl evidence, not RTL/APU hardware execution.
- [x] Actual unchanged Mesa/Linux command traffic is archived and strict-checked:
      normal capture `g6lc_qemu/out/remote-gfx/gfx-20260914T203512Z/capture`
      (`result=PASS`), with API/capset/resource/transfer/submit/fence events and
      binary command buffers retained.
- [x] Opt-in negative ioctl probing now runs through the unchanged guest driver:
      `remote-gfx-probe.py --negative` uses `g6lc-virgl-negprobe`; capture
      `gfx-20260914T203421Z/capture` passes `--expect-errors`. Backend `EINVAL`
      is observed for invalid resource creation, out-of-bounds transfer, unknown
      virgl opcode and truncated command; queue ioctls/fences can still report
      success, so the device contract must model asynchronous rejection.
- [x] The richer opt-in GLES2 audit workload now runs through the same unchanged
      driver stack: `gfx-audit-20260914T213500Z/capture` passes strict
      validation and archives texture upload/sampling, sampler views/states,
      fragment constants, indexed drawing, scissor state, state binds,
      transfers/readback, cleanup and nine typed fences. This expands the
      observed command inventory without changing Mesa, Linux or QEMU.
- [x] Close P0: `g6lc_bios/architecture/DISPLAY.md` now freezes the reduced
      `gles2-min` device contract and its context/resource, fence/error,
      reset, DMA/cache and protected-firmware obligations. The unchanged
      Linux/Mesa path passed the richer audit with all optional virgl masks
      clear (`gfx-20260914T221515Z`) and passed expected-error probing
      (`gfx-20260914T221551Z`); `gles2-xfer` retains only `VIRGL_CAP_TRANSFER`
      as an optional diagnostic (`gfx-20260914T221800Z`). The separate BIOS
      package gate is green (`python tools/g6b.py check`, including the
      previous picker/JIT device-frame test). This is still llvmpipe-backed
      compatibility evidence, not RTL or hardware acceleration.
- [ ] P1/P2 independently gated APU execution and protected firmware.
- [ ] P3 real unchanged Linux/Mesa GLES2 shader-to-RTL readback, plus BIOS client.
- [ ] P4 feature conformance/gaming measurements; P5 separate HDMI and DP scanout.
- [x] HDMI line-buffer leaf, not P5. `g6lc_hdmi_scanout` and `g6lc_hdmi_linebuf`,
      `HdmiEn` default 0, independent of `ApuOff` / `ExecEn` / `MatrixEn`.
      Remote `verif/tb/hdmi/run-hdmi-scanout.sh` rc=0: scanout 8 checks /
      307200 pixels; line buffer 4 checks / 307200 pixels; disabled line
      buffer issues no AR. `HdmiEn=0` is ports only. `HdmiEn=1` scanout is
      328 cells / 42 flip-flops; line buffer is 67133 cells / 32846
      flip-flops after generic map with no SRAM macro and no latches.
      The line-buffer leaf stops at the pixel port. Not simpledrm-on-hardware
      and not a 3D surface.
- [x] HDMI TMDS symbol leaf, not P5. `g6lc_hdmi_tmds` encodes the scanner
      pixel into parallel 10-bit symbols: HSYNC/VSYNC in blanking, eight
      video-preamble characters, two video guard characters, then the active
      pixels. No audio or data island. The symbol leaf stops before the shift. Remote
      `tb_g6lc_hdmi_tmds` rc=0: 6 checks / 307200 pixels. `HdmiEn=0` is
      ports only. `HdmiEn=1` is 1597 cells / 324 flip-flops, no latches.
      Not a board PHY and not a 3D surface.
- [x] HDMI 10× shift, not P5. `g6lc_hdmi_ser` sends bit 0 of each TMDS
      symbol on `load_i`, then bits 1..9, on the bit clock. Single-ended.
      Remote `tb_g6lc_hdmi_ser` rc=0: 4 checks / 307200 pixels / 384044
      words. `HdmiEn=0` is ports only. `HdmiEn=1` is 60 cells / 30
      flip-flops, no latches. No PLL and no differential pair.
- [x] HDMI simple-framebuffer model, not P5 and not a booted guest.
      `corev_apu/hdmi/g6lc-simplefb.dtsi` is opt-in: `0x8ef00000` /
      `0x96000`, 640×480, stride 1280, `r5g6b5`, `no-map`, below the AI
      pool. No board DTS includes it. `simplefb_model.py` rc=0: 16 checks
      / 307200 pixels. The byte at `base + y*stride + x*2` is the pixel
      the line buffer bursts.

No core or AI RTL, ISA, DTS or production capability mask changed in the P0 pass.

## API-neutral APU P1 transport review

Priors: the frozen `gles2-min` contract in `g6lc_bios/architecture/DISPLAY.md`,
`AGENTS-corev-apu.md`, and the APU rows in the implementation/test maps.

- [x] Independently gated `corev_apu/apu/g6lc_apu_top.sv`, transport and native
  package, plus `corev_apu/include/g6lc_apu_cfg_pkg.sv`. Default `ApuOff` is
  inert; `ApuP1Transport` offers VERSION_1/RING_RESET only. No virgl/EDID,
  capset, physical scanout or software-rendering fallback is enabled.
- [x] Review against virtio 1.3 CSD01 sections 2.1, 2.6 and 4.2.2 reproduced
  25 failing checks before repair: queue reset/stop/re-enable, status monotonicity,
  inactive/failed completion acceptance, power-of-two/alignment/extent guards,
  shared-memory discovery and configuration legality. SHM selector/length words
  now use 0xac/0xb0/0xb4; absent lengths/bases are all ones.
- [x] Add explicit backend reset/stop request-acknowledge handshakes, queue-enable
  qualification, full 64-bit fence/32-bit context metadata, and set-over-clear
  priority for interrupt and notification collisions. NEEDS_RESET generates a
  config interrupt when DRIVER_OK was set; malformed bus accesses do not mutate
  registers. Queue reconfiguration after reset works with DRIVER_OK still set.
- [x] Remote Verilator 5.008: `PASS tb_g6lc_apu_virtio_mmio cycles=636
  checks=4236 errors=0`, exit 0. Includes 2,048 queue-size and 2,049 configured-depth
  checks, delayed acknowledgements, same-cycle reset/completion, stop-read stalls,
  high addresses/fences/context, and a continuously checked ApuOff copy.
  AI/issue-width checks are configuration-helper independence, not SoC coexistence.
- [x] Strict enabled RTL lint at AddrWidth=12/16/64 plus disabled-top lint;
  assertions enabled in simulation. Remote Yosys/slang `synth -noabc` and
  `check -assert`: enabled transport 13,964 generic cells / 819 sequential bits,
  no latches; ApuOff zero cells (asserted). These are not mapped area or STA results.
- [ ] Attach the now-verified AXI/control wrapper to trusted SoC source/PMP routing,
  address/IRQ/DTS discovery and PMU. The wrapper enforces `apu_soc_legal`, but
  fabric/domain routing is not implemented. Firmware reservations currently
  require two physical cores and NrHarts=1; SMT service-domain partitioning is not
  implemented. Private RAM must be aligned, at least 256 KiB, and disjoint from MMIO.
- [x] Resource-checked DMA read/write leaves and bounded SG walker are present as
  default-off standalone units (`g6lc_apu_dma_{read,write}.sv`, `g6lc_apu_sg.sv`).
- [x] Immutable command snapshot SRAM, protected mapping table and used-ring
  publisher are present (`g6lc_apu_storage.sv`, `g6lc_apu_queue.sv`); remote
  Verilator/lint/synth for SG+storage+queue is the close-out of this slice.
- [ ] Integrate the leaves under control, native execution and resident firmware.
- [ ] Full SoC APU/AI/config matrix, formal safety/liveness, stock-driver shader
  execution, PDK timing/CDC/DFT/power qualification. Full build-platform `verify`
  was only dry-run/preflighted here; its configured core suites do not include APU.
  The documented `diag run licensing` id is absent in the current catalog; this
  slice's tier/header and GPL-free flist review is manual, not an automated pass.

**Backend contract:** all sidebands are synchronous to clk_i and must be protected
by the eventual fabric/domain integration; port names alone are not protection.
`queue_enable_o` authorizes new work, not `vq_state_o.ready` alone. On a held
`fw_queue_stop_req_o[q]`, the backend must stop new work, drain all existing queue
memory responses and invalidate pending completions before acknowledging. Queue
reset releases its mapping only after that acknowledgement. A QueueReady=0 stop
retains its configuration; reading QueueReady stalls through rvalid_o until the
backend drains, so the future bus adapter must hold the request. Ordinary register
accesses remain single-cycle. `fw_reset_req_o` stays high until `fw_reset_ack_i`
certifies all device DMA is drained and resource/context/program state invalidated;
status does not report reset complete earlier. Never tie these ACKs high once a
real asynchronous work source exists. `used_valid_i/used_ready_o` reports an already
retired, memory-visible used entry, not a queue of commands to DMA; last-used
metadata is debug state, not a lossless completion FIFO. The producer holds its
payload while stalled and discards cancelled completions before reset ACK.

**Timing/DFT note:** one clock and the existing async-assert/sync-deassert reset
contract; no new CDC, gated clocks or memories in this slice. Two queue CSR banks
are flops, not bulk storage. testmode is threaded but scan/ATPG is not qualified.
64-bit extent checks and status qualification are combinational control cones;
register the future AXI boundary and qualify them against the inferred 1.25 GHz /
12FFC target before integration. No CPU/AI pipeline, ISA, DTS or global flist change.

Reproduce from Windows PowerShell, using the existing authenticated WSL proxy:

```powershell
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py sync
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py --timeout 240 shell env APU_SYNTH=1 bash /opt/testharness/repo/verif/tb/apu/run-virtio-mmio.sh
```

The runner consumes `corev_apu/apu/Flist.apu`; lint/build/sim/synthesis logs live
under remote `/tmp/g6lc-apu-virtio-mmio` (override `APU_VIRTIO_OUT`). Warnings
are fatal except unused/timescale, testbench width-widening/clock-style and SVA
reset-observation categories; RTL lint does not suppress width warnings. Do not use a dry-run's
“Gate passed” line as execution evidence.

### P1 AXI/control boundary follow-up

- [x] `g6lc_apu_axi_lite.sv` exposes independent guest/control AXI-Lite ports
  (64-bit addresses, 32-bit data), reusing the unchanged `axi_lite_to_reg` bridge.
  It checks full addresses before offset decoding; neither port aliases the other.
  Default private aperture is `0x40002000/0x1000`, separately configured and checked
  against guest MMIO and firmware RAM. This is not yet a live SoC/DTS allocation.
- [x] Per-AW/per-AR authorization and the control epoch travel through the bridge
  with each accepted request. `PROT` is not authentication. Denied or stale control
  requests complete with SLVERR and zero read data, without register side effects.
  Epoch changes on device-reset or queue-stop entry invalidate buffered requests
  and snapshots; the counter saturates and locks control/ACKs on exhaustion until
  external reset. Exhaustion still needs a dedicated runtime/formal proof.
- [x] `g6lc_apu_control.sv`: queue/fence/context snapshots, notifications and a
  separate level firmware IRQ; firmware reset/stop acknowledgement registers.
  Reset requires firmware acknowledgement, all backend queues idle, and backend
  resource teardown complete. Per-queue stop requires firmware ACK plus that
  queue's idle signal. A guest's stalled QueueReady read does not block control.
- [x] Remote Verilator 5.008: **318 AXI/control checks / 1,601 clocks / errors=0**;
  raw transport recheck **4,240 checks / 636 clocks / errors=0** (four new aperture
  legality checks). Covers buffered authorization changes, stale queued writes,
  snapshot consistency, 64 authorization/strobe/skew cases, independent AW/W
  arrival, B/R stalls, hardware reset with pending responses, disabled endpoints,
  and firmware ACK with a busy backend. The first stall check exposed out-of-step
  coroutine/unpacked-array request propagation in the TB; packed bus arrays fixed
  the observed handshake timing without weakening the assertion or changing RTL.
- [x] Enabled/disabled wrapper lint (no first-party width waivers) and remote
  Yosys/slang flattened `synth -noabc`, `check -assert`, no-latch checks pass:
  enabled **19,944 generic cells / 2,287 sequential bits**; disabled **522 cells /
  162 sequential bits**. Unlike the raw zero-cell off top, the AXI endpoint retains
  response bookkeeping so accepted transactions finish, but contains no APU state.
- [ ] Integrator supplies trusted AW/AR grants from source/domain routing, not from
  Linux-controlled fields, and holds them with the relevant address until handshake.
  Admission-time grants remain attached to accepted transactions; later grant changes
  are not retroactive revocation. Quiesce/reset before switching ownership.
- [ ] Integrate the checked DMA leaves and single-bank SG controller below with
  private control, immutable command buffers and virtqueue used-ring publication. This control
  test still models drain/teardown rather than memory traffic or rendering.
  Full SoC/core configuration coverage,
  OpenSBI domains/PMP, full-width AXI adaptation, formal liveness and STA remain open.

Control ABI is `ACTRL_*` in `corev_apu/apu/include/g6lc_apu_pkg.sv`. STATUS bits:
0 reset request, 2:1 queue stop, 4:3 notification pending, 6:5 queue enabled,
8:7 backend idle, 9 snapshot valid. SNAPSHOT=1 captures selected queue geometry
and last-used metadata; invalid snapshot data reads fail. EPOCH and SNAP_EPOCH
must agree around a multiword read. Already-produced AXI responses remain stable
across later reset events; software must check epoch/validity and retry SLVERR.
Any new stop/reset epoch invalidates prior software acknowledgements, so firmware
must re-read pending bits and re-acknowledge after completing the current teardown.

Run the previous proxy command with **`APU_AXI=1 APU_SYNTH=1`**. The optional
`Flist.apu_axi` adds only the existing PULP bus/FIFO/arbiter dependencies and new
APU wrapper/control/package; it does not enter the global production flist.
Artifacts are under remote `/tmp/g6lc-apu-virtio-mmio/axi`. Scoped `apu_axi.vlt`
waives only known upstream EOFNEWLINE, AXI-package width and arbiter unsigned
warnings; the root blanket corev_apu/vendor waiver is not used. Tier R/T headers
and GPL-free dependencies were manually reviewed; upstream notices are unchanged.

Timing: bridge request/response FIFOs register the fabric boundary; new 32-bit
control epoch comparison/increment and 64-bit aperture checks are control cones,
not CPU pipeline changes. One clock/reset domain, testmode threaded to APU state;
upstream bridges retain their own DFT behavior. No SRAM or ICG is added here.
Cell counts are untechmapped screening, not STA, scan/ATPG or power qualification.

### P1 resource-checked DMA read leaf

- [x] `corev_apu/apu/g6lc_apu_dma_read.sv`: standalone 64-bit AXI read master,
  gated by `Enable && DmaReadEn` (all supplied production/transport profiles remain
  read-disabled). Captures request and trusted mapping before validation; checks
  resource ID, context, read permission, epoch, nonzero/bounded length, offset and
  complete mapping containment in a configured physical window. No refused request
  issues AR. The root window must exclude guest/control MMIO and firmware RAM;
  hardware coherency grants are refused for this non-coherent leaf.
- [x] One outstanding burst, configured 1..256-beat cap, INCR with ID 0 and
  non-cacheable/non-exclusive attributes. Registered planning limits bursts to 4 KiB;
  naturally aligned 1/2/4-byte head/tail reads avoid accessing bytes outside the
  request. Stream bytes are packed low with contiguous keep bits, zero unused lanes,
  relative offsets and last on successful full payload. Completion echoes full
  64-bit tag and resource/context/epoch plus the exact delivered-byte count.
- [x] Cancellation/runtime disable stops fresh bursts but never withdraws an
  asserted AR. Accepted bursts drain; stalled published data and completion stay
  stable. SLVERR/DECERR stops further bursts and reports failure after drain.
  Wrong RID, early/missing RLAST or unsolicited responses quarantine the master:
  no fresh requests and idle remains false until a coordinated fabric reset.
- [x] Remote Verilator 5.008 with assertions, strict first-party RTL lint, and
  Yosys/slang flattened generic synthesis/no-latch/structural checks pass:

  | Physical window / burst cap | DMA cases | Checks | Clocks | Generic cells |
  |---|---:|---:|---:|---:|
  | 0x80000000 / 16 | 295 | 159,208 | 33,000 | 5,698 |
  | 0x280000000 / 1 | 293 | 227,649 | 47,460 | 5,678 |
  | 0x280000000 / 256 | 295 | 156,424 | 33,576 | 5,687 |

  Each reports errors=0 and rc=0; enabled profiles have 751 sequential bits.
  Disabled leaf has zero cells (asserted) and no bus/data/completion activity.
  Counts include per-cycle invariants, not that many independent workloads.
  Cases include every byte alignment with lengths 1..33 around a page boundary,
  64 KiB reads, last-resource-byte access, invalid IDs/permissions/epochs/extents,
  invalid root configurations, request-input changes after acceptance, AR/R/data/
  completion stalls, partial-delivery bus error, runtime disable and protocol faults.
  Early-last/mid-burst pause cases are inapplicable to the one-beat profile.
- [x] Same remote invocation rechecks transport (4,240 checks) and AXI/control
  (318 checks), including their existing lint/synthesis gates. No CPU, AI, BIOS,
  performance-tooling or global production flist changes were made in this slice.
- [ ] Attach this leaf to protected mapping tables, actual queue/command staging,
  the checked DMA writer and bounded SG engines, control reset/stop aggregation and the SoC
  fabric. Row/stride/resource-lifetime validation and immutable command SRAM are
  not implemented by the contiguous read leaf. Rendering remains absent.
- [ ] Prove full mapping lifecycle, cache ownership/IOMMU/physical-window policy,
  independent source/PMP routing, formal safety/liveness, STA/DFT/power and the
  unchanged Linux/Mesa path. The memory responder here is a verification model,
  not SoC DRAM/cache coherence or a Linux DMA integration proof.

**DMA handoff contract:** `mapping_i` is a protected per-context mapping, never
user-supplied authority. It is sampled with the request; its pages and permission
lifetime must stay pinned until idle. Changing the input for another lookup does
not revoke an in-flight mapping. To revoke, assert cancel (or disable admission),
drain data/completion and bus responses, then release the mapping. Flush unaccepted
upstream work before re-enabling admission after reset/revocation. The root window
is a second hardware bound, not an IOMMU or a substitute for context authorization.

Stream data is provisional until an OK completion; on any error/cancellation,
discard the whole command snapshot, including its already delivered prefix. Failed
streams need not emit last. A protocol-error completion is a diagnostic, **not**
permission to free backing: bus_fault stays set and idle stays low. Missing bus
responses never get converted into successful drain by a timeout. `rst_ni` may
clear outstanding state only with a coordinated fabric reset; ordinary device/
queue reset must use cancel and wait for idle. Already-published completions stay
stable even if cancel arrives later. Consumers must keep draining while cancelling.
All liveness claims depend on explicit bus and consumer progress.

Reproduce via the existing WSL testharness proxy with
`APU_DMA=1 APU_AXI=1 APU_SYNTH=1` on `verif/tb/apu/run-virtio-mmio.sh`.
Remote artifacts: `/tmp/g6lc-apu-virtio-mmio/dma-{0-16,1-1,1-256}`.
The reader is in the optional `Flist.apu_axi`, not instantiated by the control top
or any global target. No new virtio graphics/DMA feature bit is advertised.

Timing/DFT: separate registered admission, burst planning and AR stages; one
registered stream beat, no bulk FIFO or SRAM yet. 64-bit bounds/addition and byte
lane selection are local control/data cones. Same clock/reset, testmode retained,
no new CDC or ICG. Generic cell counts are screening, not mapped area, throughput,
STA at the inferred 1.25 GHz/12FFC operating point, or scan/power qualification.
Tier-R RTL and tier-T tests retain their established licensing; no upstream code
was changed. The concurrent balanced-core performance work remains separate.

### P1 resource-checked DMA write leaf

- [x] `g6lc_apu_dma_write.sv`: default-off, 64-bit AXI writer sharing the bounded
  resource/context/epoch/extent checker with the read leaf, but requiring write
  permission and its own `DmaWriteEn/DmaWriteMaxBytes`. Write-only configurations
  do not depend on read resources. Both directions require the configured root
  window to exclude MMIO/control/firmware RAM; neither grants hardware coherency.
- [x] Accepts packed 1..8-byte chunks with contiguous low keep bits, exact relative
  offsets and exact final last. Invalid chunks fail before any byte of that chunk
  is written. One naturally aligned 1/2/4/8-byte AXI transaction at a time, ID 1,
  INCR, LEN=0, exact WSTRB and zero unused data lanes. AW and W are independently
  held/accepted, so a slave that waits for WVALID before AWREADY makes progress.
  No AW extent crosses the request or 4 KiB boundary; packet aggregation and
  multi-beat write bursts are intentionally not implemented yet.
- [x] Waits for B before advancing or completing. Cancellation/runtime disable
  preserves already offered AW/W, drains B, and discards unissued buffered bytes.
  SLVERR/DECERR terminate after the response; early/wrong-ID/unsolicited B enters
  quarantine until coordinated fabric reset. Missing B never becomes successful
  drain via a timeout. Full 64-bit tag and resource/context/epoch are preserved.
- [x] Remote Verilator 5.008 and strict first-party lint pass; Yosys/slang generic
  flattened synthesis and no-latch/structural checks pass:

  | Window / input chunk size | Cases | Checks | Clocks | Generic cells |
  |---|---:|---:|---:|---:|
  | 0x80000000 / 8 | 298 | 456,689 | 80,169 | 5,712 |
  | 0x280000000 / 3 | 298 | 1,246,216 | 283,317 | 5,708 |

  Enabled writer has 766 sequential bits; disabled zero cells asserted. Checks
  include per-cycle invariants and byte/guard comparisons, not that many distinct
  workloads. Covers all byte alignments with lengths 1..33 at page boundaries,
  64 KiB writes, high addresses, invalid authority/extents/chunks, partial writes,
  AW-first/W-first stalls, a WVALID-dependent AWREADY slave, missing B, source
  starvation, late cancel, runtime disable and protocol faults. A harmless Slang
  static-local-initializer warning in the TB was removed and the writer gates rerun.
- [x] Shared-checker refactor rechecked against all three read profiles, transport
  (4,240 checks) and AXI/control (318 checks), including lint/synthesis. Their
  results and generic cell counts are unchanged. No new warning waiver was added.
- [ ] Integrate reader/writer with protected mapping tables, bounded SG walking,
  immutable command/program SRAM, virtqueue used-ring ordering and SoC reset/IRQ/
  DMA routing. These memory-model tests do not cover a combined read→write copy,
  cache coherence, actual DRAM, firmware domains, rendering, formal proof or STA.

**Write lifetime contract:** accepted chunks are irrevocable once their writes
are offered to AXI. Completion `bytes` counts strobed bytes accepted on W, **not**
confirmed memory commits on a failing bus. A cancelled/failed destination can
contain a partial prefix; it must remain invalid and must not be published for
scanout or trusted as a complete reply. Keep mapping and backing pinned through
idle, and flush unaccepted source chunks before reusing the stream for another
job. A malformed later chunk does not roll back earlier writes. Wrong/early B is
not a trustworthy retirement event: bus_fault stays set and idle stays low until
fabric reset. B completion alone is not proof of CPU cache visibility; establish
the platform DMA/cache contract before issuing virtio used/fence notifications.

Run the existing proxy runner with
`APU_DMA_WRITE=1 APU_DMA=1 APU_AXI=1 APU_SYNTH=1`. Writer artifacts are under
remote `/tmp/g6lc-apu-virtio-mmio/write-{0-8,1-3}`. This remains an optional leaf
in `Flist.apu_axi`, not instantiated in the control top or any production SoC.
No new graphics capability or strict core-qualification evidence is claimed.

Timing/DFT: registered admission, one 64-bit input chunk and registered AW/W
payloads; small per-byte alignment/strobe selection and local counters. Same
clock/reset and testmode seam, no new SRAM/ICG/CDC. Counts are generic screening,
not mapped area, sustained bandwidth or 1.25 GHz/12FFC timing/scan/power sign-off.
Tier-R RTL and MIT verification headers are retained; upstream, BIOS and the
concurrent strict-qualification/core-performance work were left untouched.

### P1 SG walker, mapping table, command snapshot and used-ring

Priors: frozen `gles2-min` contract; DMA read/write handoff/lifetime contracts above.

- [x] `g6lc_apu_sg.sv`: default-off bounded SG walker behind `Enable && SgEn`.
  Fetches a 16-byte guest list through the checked DMA reader into `tc_sram`
  (Latency=1), rejects empty/overlapping/out-of-backing entries, then fragments
  a logical transfer across entries without refetching the list. Child DMA
  completions are leased until idle. Cancellation does not retract an offered
  fragment. Remote runner flag `APU_SG=1`.
- [x] `g6lc_apu_storage.sv`: protected resource mapping table (`MaxResources`)
  and one immutable command snapshot (`MaxCmdBytes`) in `tc_sram`. Insert
  refuses duplicate resource IDs; lookup checks context/epoch/write permission;
  invalidate by slot/resource/context/all. Command bytes stream in 8-byte-aligned
  beats and cannot be mutated until release. Optional `tc_clk_gating`
  (`IS_FUNCTIONAL=0`) on the SRAM clocks. Combinational `apu_xfer_check` covers
  box/stride/layer overflow against backing.
- [x] `g6lc_apu_queue.sv`: used-ring publisher. Writes `virtq_used_elem` then
  `used.idx` through the DMA writer. The idx store is publication; a failed or
  cancelled idx must not be treated as a completed used entry. Does not pulse
  the transport `used_valid` sideband.
- [x] Remote Verilator 5.008, errors=0, rc=0:

  | Leaf | Result |
  |---|---|
  | SG Entries=64 | 122 cases / 6,593 checks / 11,352 clocks |
  | SG Entries=128 | 122 cases / 6,589 checks / 25,009 clocks |
  | storage | 25 cases / 120 checks / 429 clocks |
  | used-ring | 9 cases / 41 checks / 166 clocks |

  Transport recheck 4,240 checks / 636 clocks. Lint+generic synth pass.
  Disabled SG/storage/queue fixtures have zero cells (asserted). Enabled
  storage 1,127 generic cells / 80 sequential bits (command array inferred;
  mapping array is simulation-proven). Enabled queue 8,453 cells / 938
  sequential bits, no latches. Enabled SG 64-entry 58,231 cells after the
  table is mapped to FFs in this screening (128-entry 89,116); not mapped
  area or STA. Leaves remain outside the control top and production flist.
- [x] Firmware-facing backend `g6lc_apu_mem.sv` binds storage, SG, DMA and
      used-ring behind one op port and one AXI master. Registered AR grant
      before RVALID; command-DMA completion drain; SG fragment accept-then-DMA.
      Remote `tb_g6lc_apu_mem`: 7 cases / 12 checks / 164 clocks (insert,
      lookup, used-ring, command-DMA fill/release, SG load, SG read xfer).
      `APU_MEM=1 APU_SYNTH=1` rc=0. Not on the AXI-lite wrapper or testharness.
- [ ] Attach backend AXI to the control wrapper; SoC address/IRQ/DTS; native
      execution.

### P2 testharness firmware RAM I$ fills

Priors: `architecture/uncore/apu-firmware-ram.md`,
`architecture/uncore/apu-testharness-load.md`. Opt-in `+define+G6LC_APU` only.

- [x] `g6lc_apu_fwram` 64-bit INCR read fills (`size=3`, `len<=15`, window
      contained). Stream8 CVA6 I$/D$ lines are `size=3 len=1`. Writes stay
      single-beat. WRAP / `len>15` / window-crossing SLVERR and drain.
      Remote `run-soc.sh` rc=0: **`tb_g6lc_apu_fwram` 5 cases / 306 checks /
      1,386 clocks**; screening synth 4 KiB enabled 105,439 / 32,938
      sequential, disabled 166 / 15. Mini-hart `run-hart.sh` still 186 /
      3,077, cookie `0x600D000A`. Not a CVA6 fetch. FPGA/Altera maps and
      SMT OpenSBI unchanged. No FeatureVirgl.
- [x] Directed CVA6 fetch of preloaded `apu_fw.hex`: one `ariane`
      (`g6lc64_stream8`, `hart_id=1`, boot `0x90000000`) against
      `g6lc_apu_fwram`. Remote `run-cva6-fetch.sh` rc=0:
      **`tb_g6lc_apu_cva6_fetch` 5 checks / 279 clocks** (I$ `size=3
      len=1` INCR + commit PC). Not testharness PerCoreBoot, not OpenSBI.
- [x] Dual-core fetch at testharness PerCoreBoot PCs: two `ariane`
      (`g6lc64_stream8`), core 0 ROM `0x10000` spin, core 1 firmware RAM
      `0x90000000`. Remote `run-cva6-dual-fetch.sh` rc=0:
      **`tb_g6lc_apu_cva6_dual_fetch` 4 checks / 279 clocks**. Not
      `g6lc_cluster`, not OpenSBI, not `+define+G6LC_APU` testharness.
- [x] `g6lc_cluster` PerCoreBoot shared mem: `NR_CORES=2`, L2/L3 off, core 0
      ROM `0x10000`, core 1 firmware RAM `0x90000000`. Remote
      `run-cva6-cluster-fetch.sh` rc=0: **`tb_g6lc_apu_cluster_fetch` 4
      checks / 283 clocks**. Not testharness `+define+G6LC_APU` xbar/DRAM
      hole, not OpenSBI.
- [x] Testharness compositor xbar + DRAM hole: cluster mem through
      last-match-wins ROM + DRAM lo/hi + RAM idx 12. Compositor boot PCs
      and `fw_ready`. Remote `run-cva6-th-fetch.sh` rc=0:
      **`tb_g6lc_apu_th_fetch` 14 checks / 283 clocks** (decode hole vs
      aliased steal, RAM-port I$ fill, DRAM poison not hit, both commits).
      Not full testharness UART/PLIC/DRAM/L2, not OpenSBI.
- [x] TGSI immediates via native `LDC` (next IMEM word is the 32-bit
      payload). Host compiler accepts `IMM[n] FLT32` and inline
      `{0,0.5,1,2}` (and negatives). TEX/IF/src0 register-negate still
      fail closed. Compiler not in `apu_fw.elf` / `apu_tgsi_fw.elf`.
      Remote `run-exec.sh` rc=0: **`tb_g6lc_apu_exec` 12/29/886**;
      **`PASS tgsi_check`**; tgsi_fw later 188/3,486 cookie `0x600D000B`.
      Exec synth enabled 23,329 / 3,888 sequential, disabled zero cells.
- [x] Optional DMA initiator: compositor exports the DMA AXI master
      (idle when `DmaReadEn=0`). Directed read through DRAM lo
      `0x80000000`; firmware RAM is not DMA backing. Testharness ties the
      port; FPGA/Altera `NrSlaves` unchanged. Remote `run-dma-init.sh`
      rc=0: **`tb_g6lc_apu_dma_init` 10 checks / 19 clocks**. xbar 3/17/30;
      th_load 3/21/16.
- [x] Testharness OpenSBI-visible map + opt-in domain DTS: 14-rule
      `+define+G6LC_APU` last-match (Debug..GPIO, DRAM lo, guest, ctrl,
      RAM, DRAM hi) locked to compositor exports and hart-1 boot.
      `ariane-g6lc-apu.dts` includes the overlay on stream8 and points
      `possible-harts`/`boot-hart` at CPU1. Default DTBs and
      `build-opensbi-smt2.sh` unchanged. Not UART/PLIC/DRAM/L2, not an
      OpenSBI firmware payload. Host `osbi_check` PASS. Remote
      `run-th-osbi.sh` rc=0: **`tb_g6lc_apu_th_osbi` 27 checks / 4
      clocks**; th_load screening synth 4 KiB enabled 127,687 / 35,127
      sequential, disabled 275 / 27.
- [x] CVA6 firmware hart runs resident image to cookie: cluster
      PerCoreBoot, L2/L3 off, control MMIO through `g6lc_apu_axi4_lite`
      into `g6lc_apu_fw` (`ExecEn=1`). `ApuHarness.ExecEn` stays 0.
      Remote `run-cva6-cookie.sh` rc=0: **`tb_g6lc_apu_cva6_cookie` 14
      checks / 1,835 clocks**, cookie `0x600D000A`. fw synth enabled
      46,854 / 7,131; disabled 522 / 162. Not OpenSBI, not TEX.
- [x] Memory plus exec is rejected, not a silent memory win.
      `apu_mem_exec_split` fails a resource table or a DMA read combined
      with `ExecEn`; each client alone stays legal. The illegal wrapper
      branch raises `bus_fault` and errors the mailbox. Remote
      `run-th-exec.sh` rc=0: **64 cases / 518 checks / 3,071 clocks**.
      4 KiB screening: disabled 355 cells / 28 flip-flops; enabled
      156,263 / 40,180. No latches. Not a combined scheduler.
- [x] Testharness compositor exec bind: `g6lc_apu_sys` `ExecEn && !MemEn`
      mailbox + `g6lc_apu_exec_bind`. AXI4 control TID+IADD peek 10/11.
      `ApuHarness.ExecEn` stays 0. Remote `run-th-exec.sh` rc=0:
      **`tb_g6lc_apu_th_exec` 38 cases / 271 checks / 1,601 clocks**
      (shader MOV + packed `size=3` IDX+DATA). Screening synth 4 KiB
      enabled 155,234 / 40,114 sequential; disabled 275 / 27.
- [x] CVA6 cookie through compositor: cluster PerCoreBoot into
      `g6lc_apu_th_load` `gen_exec` (not sidecar `g6lc_apu_fw`). Remote
      `run-cva6-th-cookie.sh` rc=0: **`tb_g6lc_apu_cva6_th_cookie` 14
      checks / 1,835 clocks**, cookie `0x600D000A`. Same cycle count as
      the sidecar cookie TB. `ApuHarness.ExecEn` stays 0.
- [x] CVA6 TGSI MOV job through compositor: `apu_tgsi.hex` to cookie
      `0x600D000B`. Peek CPL0 is address-dependent on mailbox GO/STAT.
      Aligned AXI4 `size=3` stores split on `g6lc_apu_axi4_lite` (CVA6
      this image issues `size=2`). Compiler not resident. Remote
      `run-cva6-tgsi.sh` rc=0: **`tb_g6lc_apu_cva6_tgsi` 14 checks /
      2,081 clocks**, cookie `0x600D000B`. `run-th-exec.sh` (APU_SYNTH=0)
      **38 cases / 271 checks / 1,601 clocks**. Screening synth 4 KiB
      enabled 155,234 / 40,114 sequential; disabled 275 / 27.
      `ApuHarness.ExecEn` stays 0. Not OpenSBI, not TEX.
- [x] CVA6-resident TGSI compile image: `apu_tgsi_cc.elf` (compiler +
      job linked; not `apu_fw.elf`). On-hart walk TEX-fail then MOV
      opcode; job emits frozen MOV+HALT. fwram `in_win`/`last_match` on
      `addr[31:0]`; D$ `lbu` size=0/1; mailbox `sw` (no `sd` merge).
      Remote `run-cva6-tgsi-cc.sh` rc=0: **`tb_g6lc_apu_cva6_tgsi` 14
      checks / 10,511 clocks**, cookie `0x600D000B`. Directed fwram
      **6/317/1,421**. Screening synth 4 KiB enabled 153,932 / 40,114
      sequential; disabled 275 / 27. `ApuHarness.ExecEn` stays 0. Not
      OpenSBI, not TEX.
- [x] CVA6 hart 0 fetches DRAM lo at the OpenSBI load address
      `0x80000000` through the compositor hole; hart 1 stays on firmware
      RAM. Testharness default app boot stays ROM `0x10000`.
      `build-opensbi-smt2.sh` unchanged. Remote `run-cva6-osbi-boot.sh`
      rc=0: **`tb_g6lc_apu_cva6_osbi_boot` 13 checks / 286 clocks**.
      Host `osbi_check` PASS. th_load screening synth 4 KiB enabled
      127,297 / 35,275 sequential; disabled 275 / 27. Not UART/PLIC/L2,
      not a real OpenSBI ELF, not TEX.
- [x] CVA6 hart 0 at DRAM lo stores `0x41` to UART `0x10000000` through
      the compositor. Stub UART, not 16550/PLIC/L2. Hart 1 firmware RAM.
      Remote `run-cva6-osbi-uart.sh` rc=0: **`tb_g6lc_apu_cva6_osbi_uart`
      12 checks / 288 clocks**, byte `0x41`. Host `osbi_check` PASS.
      th_load screening synth 4 KiB enabled 127,297 / 35,275 sequential;
      disabled 275 / 27. `build-opensbi-smt2.sh` unchanged. Not a real
      OpenSBI ELF, not TEX.
- [x] CVA6 hart 0 at DRAM lo stores MSIP=1 to CLINT `0x02000000` through
      the compositor. Stub CLINT, not a real timer, not PLIC/L2. Hart 1
      firmware RAM. Remote `run-cva6-osbi-clint.sh` rc=0:
      **`tb_g6lc_apu_cva6_osbi_clint` 12 checks / 288 clocks**, word
      `0x1`. Host `osbi_check` PASS. th_load screening synth 4 KiB
      enabled 127,297 / 35,275 sequential; disabled 275 / 27.
      `build-opensbi-smt2.sh` unchanged. Not a real OpenSBI ELF, not TEX.
- [x] CVA6 hart 0 at DRAM lo stores priority=1 to PLIC `0x0C000004`
      through the compositor. Stub PLIC, not a real interrupt controller,
      not L2. Hart 1 firmware RAM. Remote `run-cva6-osbi-plic.sh` rc=0:
      **`tb_g6lc_apu_cva6_osbi_plic` 12 checks / 290 clocks**, word
      `0x1`. Host `osbi_check` PASS. th_load screening synth 4 KiB
      enabled 127,297 / 35,275 sequential; disabled 275 / 27.
      `build-opensbi-smt2.sh` unchanged. Not a real OpenSBI ELF, not TEX.
- [x] Headless DMEM color readback: mailbox `APU_MEM_EXEC_DPEEK`. Shader
      `ST` of `1.0f` to DMEM[0] peeks `0x3f800000`. Remote `run-th-exec.sh`
      rc=0: **`tb_g6lc_apu_th_exec` 45 cases / 324 checks / 1,916 clocks**.
      Screening synth 4 KiB enabled 155,978 / 40,114 sequential; disabled
      275 / 27. `ApuHarness.ExecEn` stays 0. Not raster, not DRAM, not
      Linux/Mesa, not TEX.
- [x] Scanline-fill microprogram: BR loop `ST` `1.0f` to DMEM[0..3];
      `DPEEK` tile readback, DMEM[4] empty. Remote `run-th-exec.sh` rc=0:
      **`tb_g6lc_apu_th_exec` 64 cases / 513 checks / 3,071 clocks**.
      Screening synth 4 KiB enabled 155,978 / 40,114 sequential; disabled
      275 / 27. Not triangle coverage, not DRAM, not Linux/Mesa, not TEX.
- [ ] TEX still rejected; L2 and a real OpenSBI ELF payload still open.
- [ ] P3 unchanged Linux/Mesa GLES2 shader-to-RTL `glReadPixels` still open.

Reproduce:

```powershell
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py sync
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py --timeout 3600 shell --cmd-file verif/tb/apu/run-cva6-tgsi.cmd
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py --timeout 3600 shell --cmd-file verif/tb/apu/run-cva6-tgsi-cc.sh
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py --timeout 3600 shell --cmd-file verif/tb/apu/run-cva6-osbi-boot.sh
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py --timeout 3600 shell --cmd-file verif/tb/apu/run-cva6-osbi-uart.sh
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py --timeout 3600 shell --cmd-file verif/tb/apu/run-cva6-osbi-clint.sh
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py --timeout 3600 shell --cmd-file verif/tb/apu/run-cva6-osbi-plic.sh
wsl --cd /mnt/e/cva6 -e python3 verif/regress/remote/testharness_proxy.py --timeout 3600 shell --cmd-file verif/tb/apu/run-th-exec.sh
```

No FeatureVirgl/EDID advertisement, no EGL in RTL, no testharness attachment.
Concurrent BIOS native-service work is untouched.

## BIOS autoboot and Svelte UI (2026-09-11)

Completed UI-and-boot pass: `g6lc_bios/AGENTS-todo.md` and
`g6lc_bios/architecture/BROWSER-RUNTIME.md` carry the scope and verification.
Undeclared modelled boot media, retained picker rows, static-fallback raster
selection, and the JS/Rust menu-data ABI mismatch are fixed and regression-tested.
Package check/regress and real-QEMU VGA-intent/virtio-gpu boot selection passed.
UI/boot verification is separate; native QEMU browser integration remains open.
No RTL/ISA/DTS change or silicon-validation claim is involved.

## AI policy codec compartment (2026-09-04)

Priors: `architecture/ai-matrix/README.md` §10; implementation/test/coverage maps;
`corev_apu/ai_island/README.md`. This is a parallel isolated control experiment,
not a change to the I3-before-I2 ordering or the production GEMM traversal.

- [x] Frozen eight-codeword metadata encoder, collision-free coarse feature
  signature, work-count votes/dwell, dual decode, exact-zero-gated residual skip,
  repeat-or-successor hints, bounded miss cooldown and event strobes; gate through
  `AiCfg.PolicyCodecEn`, off in production.
- [x] Remote Verilator scoreboard, default/min/max parameters, noisy sparse,
  routed/dense and mixed batches, parameter and metadata sweeps, INT8 software
  tuple consumer, plus seedable assumed LLM/diffusion matrix shape walks.
- [x] Local Yosys enabled/disabled synthesis and 12-step bounded safety with
  reachable work/commit/hold/warm/skip/hit/miss witnesses (not induction/STA).
- [x] Format-aware benefit refinement (§11): native INT4/INT8/FP8/FP16/BF16/FP32
  metadata normalization, same-format fallback, balanced multi-input/output slot
  topology, compact metadata and runtime benefit gate. Steering now uses full
  16-bit `m/n/k` retention and a `(m+n)*rowbytes(active_k) >= read_bytes` benefit
  guard (simpler than a full product-based compute model and preserves the same
  SRAM128/SRAM512 balanced-mix results). Remote default/extremes and seed 123 pass,
  including 380 ticking scheduling-model fixtures per steering build, native INT4
  rounding, strict unsupported-SP24 checks and 28 matched-format workload pairs.
  Default balanced mix: 38.24% modeled time saved at SRAM128, 3.56% at SRAM512;
  best fixed code still slightly better. Per-state/format usage, negative results,
  static comparisons and percentages are in `efficiency.json`.
  Recorded default-wrapper synthesis is 626 generic cells / 113 sequential / zero
  latches for the codec wrapper, and 1,222 generic cells / 167 sequential / zero
  latches for the enabled steering wrapper, with 26 steering assertions at a 12-step
  bound and reachable applied topology; disabled wrappers have zero cells. Matching
  report: `build-platform/workspace/build/ai-policy-codec-20260905T134537Z-865a53bca276/results.json`.
  These generic counts are not physical area or an estimate for a future array.
  Remote native-trace replay also passes: future-array modeled sums are live
  14,588→9,420; software-fixture SRAM128 72,134→52,056 and SRAM512 59,846→45,912.
  These are scheduling-model gains, not production FP GEMM support or measured
  array MAC/s; `PolicyBenefitEn` remains default-off.
- [x] Bind a real metadata producer and one policy consumer at a time to the
  sequencer, including tail/storage/format guards, per-context flush, bank/address
  validation, island PMU counters, and dense fallback. First consumer wired:
  `g6lc_ai_policy_steer` now lives inside `g6lc_ai_island_top`, fed from the
  descriptor/GEMM job (m/n/k/numfmt) with format-known gating and `gemm_err` flush,
  and exposes the selected policy plus steering events as sticky PMU words at
  `0x0190..0x019C` (`g6lc_ai_island_cfg_pkg`).  First safe traversal consumer now
  connected: `policy.prefetch_depth` drives `g6lc_ai_gemm_seq.ar_max_i` (clamped to
  `MaxAROut`) so the GEMM can cap its outstanding AR count per policy. The consumer
  is gated by `AiCfg.PolicyCodecEn` and off by default, preserving the dense
  numerical fallback.  Build flists and
  the standalone `ai-island-veri` smoke were updated to include dot-product and
  policy packages; the smoke now passes after fixing the descriptor `version`
  field in `sim_main.cpp` (it was still using the obsolete v1 while the engine
  expects v2, causing `ST_BAD_VER` for every non-disabled descriptor).  A
  live `EnableDmaFetch=1` smoke is now implemented: `verif/regress/ai-island-dma.sh`
  runs `verif/tb/ai_island/tb_g6lc_ai_island_dma.sv` with an AXI stub memory, a
  DMA-fetched v2 GEMM descriptor, policy codec/steering explicitly enabled, and
  checks that the sticky policy words at `0x0190..0x019C` are non-zero while the
  GEMM completes with `ST_OK`. After wiring the `ar_max_i` consumer,
  `ai-island-dma`, `ai-island-policy-walk`, `ai-island-veri`, `ai-pe-dot-float`,
  `run-gemm-backend`, `run-gemm-stripe`, `run-gemm-channels`, and
  `run-gemm-backend-class1` (nch=1/2/4/8, with AR-max consumer-off/consumer-on
  numerical equivalence) all PASS.
- [x] Implement optional per-group 3-bit topology subcode (§11.6) as a cancellable
  steering sidecar; frozen primary codes and live traversal unchanged. Five remote
  profiles PASS (13,574 standalone cases/build plus full original-output equivalence
  and cancellation checks). Generic enabled synthesis 4,881 cells / 340 sequential /
  zero latches, disabled zero; fixed-INT4-fixture 36-step control proof passes.
  Build-platform typecheck and seven config tests pass. Full `verify` was attempted
  but stopped after making no further progress at its native SymbiYosys launch;
  this pass does not establish whole-repository lint/formal/sim/synthesis success.
  The documented `diag run licensing` command currently returns `Unknown: licensing`;
  tier/header/REUSE retention was reviewed manually without changing licensing policy.
- [ ] Promote subcode selection only after evidence beats the existing allocator.
  The 105 handcrafted prefill/decode/routed/diffusion tile fixtures all retain
  subcode 0 at read128/read512 and lose the 32-cycle evaluation tax; this is not
  a captured-model calibration or a live GEMM MAC/s improvement. Evidence and
  source hashes: `ai-policy-subcode-20260906T121408Z-82b41477e961`; architecture §11.6–§11.7.
  Feedback reports explicitly remain `NOT_QUALIFIED`; equal-weight modeled MAC/cycle
  deltas are -0.132168% (read128) and -0.147716% (read512), not additional speedup.
- [x] Revalidate codec-first control at seed123/default/min/max after the sidecar
  addition: `ai-policy-codec-20260906T121255Z-2a22cc633240` PASS. Purity/sticky decode
  re-encode at 0.10%; mixed prefill/decode hint accuracy 99.27%; adversarial all-class
  accuracy 0% and ragged diffusion 72.60% remain reported, not masked as successes.
  Control accuracy does not establish optimization throughput or captured-model PGO.
- [x] Capture actual pretrained SmolLM2-135M and held-out Pythia-70M execution
  with pinned safetensors, FP32/BF16 prefill/cache decode and 63/64-token alignment
  cases. Eight captures contain 6,200 matrix records, lowered conservatively into
  84,720 independent tiles with exact MAC conservation. Offline candidate-7 tuning
  uses calibration only; weight/model split leakage is rejected. New capture and
  calibration suite passes 57 tests; bounded replay validates sampled metadata/cost
  cases against actual subcode RTL, not numerical tensors or AXI memory traffic.
  Reports: `policy-calibration-final-{128,512}-20260906.json` under the build workspace;
  methodology, revisions and limitations in architecture §11.8.
- [ ] Improve measured useful MAC/s beyond the existing allocator before promotion.
  Captured-data tuning retains `0x4420ca` and regresses from search overhead; fixed
  serial-service ceilings at read128 are 1.238630x calibration / 1.125685x holdout,
  so +500% (6x) is not supported. Masked-tail oracle hypotheses (1.214351x/1.105900x)
  require new bank/tail/numerical proofs and are not gains of the current RTL.
- [x] Add host-only higher-level motif fitting over ordered captures, calibration-only
  structural-template ranking and nested frozen-group/subcode parameters. Exact
  geometry/evidence guards remain mandatory. Warm-up, hold, cooldown, normalized
  realized-gain/spread rejection and stale/duplicate/tax controls are tested;
  capture/calibration/motif host suite now passes 114 tests. Final ordered report:
  `policy-motifs-window-final-20260906.json`, 32/51 templates, 312/382 calibration
  versus 10/58 held-out group-window matches; useful-MAC coverage 99.8300% versus
  0.4944%, zero actual performance-qualified claims. This is not generalization
  or measured MAC/s proof.
- [x] Add `PolicySubcodeCacheEn` (requires subcode enable, production off): exact
  completed-result reuse returns in one cycle versus 32-cycle misses. Five cache
  profiles and two seeds pass full-key, cancellation, epoch and primary-equivalence
  checks. Generic cache overhead 593 cells / two sequential cells, no latches;
  72-step fixed-INT4 cache-control proof reaches a hit (not arbitrary-key numerical
  proof). The cache reduces evaluator latency only; group/mux/array behavior stays
  unchanged. Scoped evidence: `ai-policy-subcode-20260906T132220Z-e638dd091632` and
  `ai-policy-subcode-synth-20260906T132132Z-356d75ad3869`.
- [x] Add measured MAC/s tuning feedback for the one policy knob with a live
  consumer: opt-in `+measure` AR-depth sweep in `tb_g6lc_ai_gemm_backend` (default
  off, existing directed run still `PASS ... nch=1 2 4 8 dpf=0,1` with zero MEASURE
  lines) plus `policy_measure.py`/`test_policy_measure.py` (35 tests PASS) producing
  `g6lc.policy-measure.v1`. Digests identical at every depth; depth 2 beats depth 1
  on all seven formats by `+5.263%` worst case, up to `+7.143%` MAC/cycle.
- [ ] DECISION NEEDED (measured regression, do not silently "fix"): `policy_decode`
  gives `POLICY_DECODE`/`POLICY_ROUTED`/`POLICY_SPARSE` `prefetch_depth=2'd1`, and
  `ar_max_eff` honors 1 literally against live `MaxAROut=2`, so the policy consumer
  measurably slows exactly those codes versus the dense fallback. Options: retune
  those depths (breaks the frozen group table), treat depth as a floor/hint in the
  consumer mapping (changes the consumer, not the codec), or raise `MaxAROut`.
  Left unchanged pending direction; measured on a small fixture only.
- [x] Found and fixed a defect in my own measurement: A/B ARs are bounded by m/n,
  so the 2x2x16 sweep capped inflight ARs at 2 and every depth >= 2 was identical
  hardware. All earlier depth >= 2 numbers (+19.6% in-sample, +1.00% CV) were
  noise and are retracted. Sweep now 8x8x16 (1024 MACs, ~68% of PeLanes=8 peak,
  depths 1..8 reachable) with repeated passes so the noise floor is measured.
- [x] Re-swept the whole live-knob space on the corrected fixture. Depth response
  is monotonic (deeper always better): DRAM class depths 1..8 give -40.2, -19.1,
  -12.6, -6.2, -3.0, -2.9, -1.5, 0% versus policy-off. Live class depth 1 costs
  -8.15% with a 0% noise floor. Cross-validated per-format tuning loses -1.01%
  mean with all four folds negative.
- [x] Corrected the mapping claim: island_top requested 1+prefetch_depth, so cap 1
  was unreachable. Real exposure was 0% at live MaxAROut=2 and -19.1/-12.6/-6.2%
  on MaxAROut=8 parts. The earlier -8.15% depth-1 figure is withdrawn.
- [x] Removed the AR-cap consumer: gemm_ar_max is unconditionally MaxAROut.
  prefetch_depth stays PMU-visible advice with nothing consuming it. Island DMA
  regression PASS (*** SUCCESS *** 170 cycles).
- [x] Added run-gemm-scaling.sh (PE_LANES/AR_PROVISION, defaults = shipped values).
  Measured: AR provisioning 2/4/8 gives exactly 0% at every lane width; lanes
  8->16 gives +52.9%, 16->32 a further +23.8% (+89.2% cumulative), all nine
  configs golden-clean. INT8 saturates at 16 lanes because k=16 completes a
  reduction in one cycle. PeLanes=4 is invalid (SplitArId needs lanes >= beat).
- [x] Chip-surface efficiency: per-lane throughput falls -23.6% (16 lanes) and
  -52.7% (32 lanes) versus 8 lanes. At equal 32-lane arithmetic, one wide engine
  measures 6.662 MAC/cyc (+89.2%) while four 8-lane clusters project 14.083
  (+300.0%), a 2.11x replication advantage. Operand bandwidth 5.45 B/cycle for
  four clusters against ~8 B/cycle per 64-bit port fits; eight clusters would not.
- [x] CLUSTER LINEARITY IS NOW TESTED AND FALSE ON A SHARED PORT. The decisive
  experiment is built: `tb_g6lc_ai_gemm_concurrent.sv` runs N gemm_seq instances
  through the real N+1-port axi_mux into one dram_backend. N={1,2,4}, nch={1,4},
  seven formats, 8x8x16, serial versus concurrent with golden C=k re-checked
  after BOTH phases; all PASS. N=1 is exactly 1.000x, checking the harness itself.
  Four-engine speedup is 1.48x (INT4) to 2.43x (FP32) at one channel, i.e. 37-61%
  efficiency, not 4.00x. Per-engine PMU inflates roughly 1.8x and engines retire
  in a staggered cascade: one mux/backend port serialises the transactions.
  Channel count matters ~1%, so the scarcity is transactions, not bandwidth.
  Shared-B mode is bit-identical to private weights in all 22 comparisons: no
  coalescing exists, so weight reuse needs a read multicast or tile cache.
  This DISCOUNTS the old 4.00x-for-4x projection by roughly half at four-way
  sharing, and inverts the idle-lane story: narrow formats gain LEAST from
  engine replication (INT4 1.48x) yet have the MOST idle lanes. For narrow
  formats the payoff therefore points to intra-engine lane groups sharing one
  frontend, not more engines; that payoff is still unmeasured. Class-0 SRAM sim
  cycles only: a contention answer, not MAC/s, silicon, or real DRAM queueing.
- [ ] CLUSTERS ARE NOT IMPLEMENTED: Clusters/ClustersEnabled exist only in
  island_cfg_legal and the CAP window; island_top instantiates one gemm_seq. The
  +300% figure is 4x a measured single cluster, not a measured four-cluster
  system. Implementing replication (plus per-cluster descriptor/queue fan-out and
  re-measured bandwidth on a steady-state fixture) is the actual +300% work item.
- [x] Priced the format return now that the datapath elaborates. Coarse generic
  cells (relative proxy; full synth still stalls in SAT sharing then ABC):
  8 lanes 383,575; 16 lanes 619,197 (1.61x); 32 lanes 1,146,467 (2.99x);
  64 lanes 2,416,615 (6.30x). FP32 16x16 buys 4.20x throughput for 6.30x area,
  so throughput-per-area falls 1.000 -> 0.964 (32 lanes) -> 0.667 (64 lanes).
  Four 8-lane clusters reach the same 4x for 4.00x area, i.e. replication is
  ~1.58x cheaper in area than ganging. Conclusion: replicate for throughput, gang
  only where single-job latency outweighs area, and use format-driven grouping so
  narrow formats do not pay for width they cannot use.
- [x] RESOLVED (was a blocker): read_slang could not elaborate
  g6lc_ai_gemm_seq (line 1164 loop bounded by runtime mac_step; unroll limit
  exhausted at 12000, host memory exhausted at 200000). Fixed by bounding the
  loop with the PeLanes parameter (mac_step <= PeLanes on that branch), verified
  behaviour-neutral: directed PASS and byte-identical measured cycles.
  Harness: verif/tb/ai_island/tb_g6lc_ai_gemm_area.sv, whose first version fed the
  AXI response back from the request and let synthesis constant-fold the MAC
  arrays away (2838 -> 3079 cells from 8 to 64 lanes); those figures are retracted
  and the AXI pair now crosses the boundary as real ports.
- [x] Logic-depth proxy measured (ltp on coarse netlists): 1493/1540/1583/1626
  levels at 8/16/32/64 lanes, ~+43 per doubling (one reduction-tree stage), +8.9%
  total. Treat as weak: untechmapped ripple arithmetic, no ABC. Selecting the
  pipelined float dot moves the path by four levels while adding +55% cells
  (596,485 at 8 lanes, 3,753,800 at 64), so the deep path is not in the dot.
  tb_g6lc_ai_gemm_area gained a DotPipe parameter for that comparison.
- [ ] TOOLING GAP (blocks every area/timing decision about widening): mapped
  synthesis does not converge under the available open flow, even for the block
  that actually scales. Isolating g6lc_ai_pe_dot_float and synthesising it alone
  still fails: ABC times out at 900 s for Lanes=8, and Lanes=64 blows up in the
  SAT-based share pass. So there is no mapped cell count, no gate depth and no STA
  for the arithmetic array at any width, and the coarse generic proxy
  (383,575 -> 2,416,615 cells for 8 -> 64 lanes) is the only area evidence that
  exists. Deciding whether to buy lane ganging needs a commercial flow, or a
  mapping recipe cheap enough to converge; do not settle it from the proxy alone.
- [ ] Full synth/timing for the datapath is still open: with a sound harness Yosys
  stalls in SAT resource sharing (554k variables at 16 lanes) and then in ABC, so
  only coarse generic cells exist and there is no STA/frequency evidence. A
  commercial frontend or a much cheaper mapping recipe is needed before any
  technology area or timing claim.
- [x] Built the remote-only research basis verif/regress/ai-gemm-codec-basis.py
  (dispatches through testharness_proxy, refuses local runs): six provisioning
  points (PeLanes 8/16/32 x MaxAROut 2/8) x five codec shape classes x seven
  formats x every legal AR depth, twice each. 2,100 records, digests stable at
  every depth, status=PASS. Evidence:
  remote-runs/ai-gemm-codec-basis-20260906T165957Z-718434a9a9d1.
- [x] MEASURED CODEC RETURN: shape is flat (best point identical across all five
  shape classes for all seven formats => a shape-keyed codec captures nothing,
  consistent with the AR consumer being removable at zero cost). Format is not:
  INT4 wants 8 lanes (0% from wider), INT8/FP8 want 16 (+0.94..+69.6%),
  FP16/BF16 want 32 (+12.9..+177.8%), FP32 wants 32 (+38.8..+188.2%). AR 8 never
  wins. So the codec's productive output is format-driven lane grouping, and the
  positive-return path to +300% is that (up to +188%) combined with the 2.11x
  cluster replication advantage.
- [x] Closed the open end of the format table: an 8/32/64-lane run
  (ai-gemm-codec-basis-20260906T172019Z, status=PASS) shows FP32 wins at 64 lanes
  for every shape class, +320.0% on 16x16 (2352 -> 560 cycles) and +203.6% on 8x8,
  while INT4 still gains nothing past 8 and INT8/FP8 nothing past 16. The
  "twice the element width in lanes" rule is now measured across its whole range.
  +300% is measured-exceeded for FP32 by lane ganging alone, no clusters needed.
  policy_dot_lanes_log2/policy_lane_groups_log2 and their pinned assertions
  already encode this; the basis runner now takes --lanes/--ar and refuses point
  sets that omit the shipped baseline or use non-power-of-two/<8 lane counts.
- [ ] Needs RTL that does not exist: selectable lane gang/split so narrow formats
  split a wide array into independent groups (more concurrent jobs) and wide
  formats gang lanes for one job. Until then the +188% is a return of
  hypothetical provisioning, since lanes are fixed at elaboration.
- [ ] Register ai-gemm-codec-basis in build-platform test suites and the Makefile
  once the lane-grouping consumer exists; it is currently a research runner.
- [ ] SUB-CODE HYPOTHESIS (analysis, not a result; architecture/ai-matrix
  README has the argument). The current sub-code loses for three independent
  measured reasons: the optimum is shape-independent so its 8-candidate shape
  search scans a flat space; the search costs 4,880 cells + 340 flops + 593 cache
  cells and a 32-cycle tax that is the measured cause of the 0.998x on captured
  traces; and nothing consumes its output. The decision that does carry return is
  a lookup, not a search - four lane values from a 3-bit format input - so a
  combinational table is tens of cells and zero cycles, recovers ~5,470 cells and
  makes the repeat cache pointless. The search is what fails, not the concept.
- [ ] CORRECTION to the fitted rule: policy_dot_lanes_log2 is k=16-specific.
  mac_step = 2*PeLanes (INT4) or PeLanes/bytes, and a reduction ends when
  mac_step >= k, so usable lanes = fmt_row_bytes(k) = the operand row in bytes.
  At k=16 that equals twice the element width, which is why the fit reproduced
  8/16/32/64. Scope notes added to the package and the pinned assertions.
- [x] DECIDING EXPERIMENT RUN (run-gemm-ksweep.sh, +measure_k, MaxDim=64, integer
  formats, 492 records, golden-clean). The k_bytes rule holds 6/6: INT4 best lanes
  8/16/32 at k=16/32/64 and INT8 16/32/32(capped, predicts 64). The optimum does
  move with k, so the decision is genuinely runtime-varying and the earlier
  element-width fit was a k=16 coincidence.
- [x] ...but the same data kills the obvious use: choosing gang width per job is
  worth +0.0% versus provisioning wide, because surplus lanes idle at identical
  cycles (INT4 k=16 is 66 cycles at 8, 16 and 32 lanes alike). A knob whose wrong
  settings cost nothing cannot earn anything by being set right.
- [x] V/A-Turbo SV recipe calculations: `va_turbo_select` implements ten supported
  selection predicates in a 32-ID namespace (native fallback, integer-zero product
  skip, FP16/BF16/INT8 conversion plans, paired/four-output/independent/occupancy
  grouping and validated operand reuse). K-byte demand, tail count, banks and
  accumulator limits are calculated with bounded shifts/comparisons. Runtime
  level, compiled-consumer mask, profile approval and window validity gate apply.
  Remote five cache-off/on profiles PASS with 18,473 swept cases plus directed
  guards (`ai-policy-subcode-20260907T012755Z-43d44da4f6cb`). Selector synthesis:
  540 generic cells, no sequential cells/latches; disabled wrapper zero.
- [x] V/A-Turbo arithmetic + error bounds for all 32 recipes (architecture
  va-turbo.md §9). Each ID declares a bound KIND: EXACT (zero), REL (per-product
  relative), FULL (integer quantisation, whose per-element error is ABSOLUTE so no
  relative per-product bound exists and the reference is full scale K*maxA*maxB),
  or NONE (unusable, bounds to 100%). Derived from 2u+u^2 with u=2^-(p+1): FP16 977
  ppm, BF16 7,828, FP8 E4M3 128,906, E5M2 265,625; INT8 2/254+1/254^2 = 7,887 and
  INT4 2/14+1/196 = 147,908 full scale; Mitchell sup ma*mb/((1+ma)(1+mb)) = 1/4 =
  250,000 ppm for THIS formulation (the textbook 11.1% is the log-domain variant
  and is not interchangeable). Recipes 21/27/28/30/31 report the UNCORRECTED
  supremum so a correction factor is never assumed. Bound = eps*kappa with kappa a
  REQUIRED input; missing or sub-unity kappa fails closed. Level is 625 ppm per
  step; admission needs the analytic AND the caller's supplied bound.
- [x] MEASURED BOUND VALIDATION (policy-approx-bounds.json): 12/12 candidates hold
  with 3.3x-36.5x slack at Frobenius-matched kappa (3.292 relative, 85.681 full
  scale), so the composition is sound and conservative.
- [x] FINDING: a per-element bound is VACUOUS. Worst-case per-element kappa is
  47,637 (relative) and 639,792 (full scale) because single output elements nearly
  cancel, so every bound saturates to 100% and "holds" becomes trivially true. A
  bound and its observation must share a granularity; the earlier all-saturated
  run was a vacuous pass, not validation.
- [x] FIXED, and it was my own design error: the level ladder was linear in
  sixteenths of a percent (625 ppm/step, 9,375 ppm at level 15), which is a RANGE
  error rather than a tuning choice. Useful budgets span FP16's ~1,000 ppm to a
  logarithmic multiply's 250,000 ppm, so a 625-ppm step spent all fifteen codes in
  the first decade and could not express the rest; measured INT8 error (18,527
  ppm) sat outside the whole range, making the ENCODING the blocker. Replaced with
  a geometric ladder at the same 4 bits: 100 ppm doubling per step, saturating at
  100%, level 0 still off. `error_bound_q4` is a ladder index, rounded up. The
  suite now asserts the ladder is strictly increasing and that every declared eps
  is expressible by some level.
- [x] ARITHMETIC GATES CORRECTED AGAIN, and the previous "12/12 holds" reading is
  withdrawn. A sample cannot prove a bound. Found and fixed: RNE table entries that
  rounded DOWN (E4M3 needs 128,907 not 128,906, and p=16..23 were zeroed), a final
  eps*kappa that truncated, truncation recipes carrying a round-to-nearest bound
  (toward-zero truncation is 2u-u^2 with u=2^-p, roughly 2x larger), recipe 26
  claiming a bound with no derivation, and saturation at 100% turning an
  out-of-budget candidate into an admissible one. `20'hfffff` is now an
  invalid/overflow sentinel above the maximum budget that a waiver may NOT
  override; REL additionally requires `relative_domain_valid`, because the normal
  relative-error formula does not cover subnormal/underflow/overflow conversion.
  Evidence: remote FAILED first at E4M3 (`ai-policy-subcode-20260907T033251Z-f86e57c24c7e`),
  then PASSED (`...T034054Z-8edb3d5bfd7c`); host adds 25 tests.
- [x] THE RECORDED 310,931 ppm INT8 BOUND WAS NOT RTL-MATCHED. The host scaled the
  whole epsilon by flatness, including the constant 1/(4L^2) term. Corrected: raw
  311,550 ppm, upward Q8 metadata giving 312,489 ppm at level 13. INT4 and 2-bit
  truncation now exceed 100% and are REFUSED rather than clipped into range. FP16
  and both FP8 formats came back `unqualified_arithmetic_premises` on these tiles,
  which is a real finding, not a pass: those conversions leave the normal domain
  the bound assumes. My earlier claim that usable INT8 and worst-case guarantees
  are universally incompatible was too strong; it holds for this sample only.
- [x] FIRST EXACT THROUGHPUT CONSUMER LANDED AND MEASURED: recipe 16 resident-B.
  `g6lc_ai_gemm_seq.ReuseBEn` (default off) skips ST_LB when the retained key
  (ptr_b, n, k, ldb, numfmt, 32-bit epoch) matches; M is deliberately NOT part of
  the B key. Residency publishes only after a successful job and is refused on
  error, invalidation, wrapped range or C/B overlap. Measured eng=1/nch=1
  (`ai-gemm-reuse-20260907T035117Z-6c1a1a1cf00c`): warm 1.12x-1.18x with operand
  read beats EXACTLY halved at m=n (INT8 378->328 cy, r 64->32; FP16 698->616,
  r 128->64; FP32 1338->1192, r 256->128), cold prime charged separately, and 21
  directed safety cases passing. `reuse_b_i` is a LEASE, not coherence: the caller
  must hold B immutable and advance the epoch or invalidate before any writer,
  ownership change or epoch wrap.
- [x] REUSE AND CONCURRENCY COMPOSE, and the reuse gain GROWS with contention.
  Measured at one, two and four engines on the same shared port
  (`ai-gemm-reuse-20260907T044438Z-6694e3e3bcc6`, `...T045844Z-2464ca922d94`):
  INT8 reuse 1.152x -> 1.255x -> 1.358x, FP16 1.133x -> 1.230x -> 1.374x, FP32
  1.122x -> 1.216x -> 1.355x. Four-engine concurrency then improves from 2.077x
  to 2.448x (INT8), 2.374x to 2.879x (FP16) and 2.433x to 2.936x (FP32), i.e.
  51.9-60.8% of ideal 4x becomes 61.2-73.4%, for a combined serial-cold to
  concurrent-warm 2.821x / 3.262x / 3.296x. The mechanism is the one the earlier
  measurement identified: the beats reuse removes are exactly the contended
  resource, so the levers multiply rather than overlap. Operand read beats halve
  at every engine count and every C element is still checked. One shared-port
  fixture with repeated same-weight jobs; not MAC/s, not silicon, not inference.
- [x] PLAN COMPOSITION LANDED (`va_turbo_compose`): the 32 recipes stack, and the
  measured cycle model says how. Fitting the per-job cycles against work terms gives
  `cycles ~= steps + beta(fmt)*read_beats + 11` with `steps = m*n*ceil(k_bytes/PeLanes)`
  and beta = 1.14/1.28/1.56/2.13 for FP32/FP16/INT8/INT4, measured straight off the
  residency sweeps (FP32 669->523 over 128 beats, INT8 189->139 over 32) with the +11
  falling out identically for both. beta RISES as the format narrows because traffic
  hides under compute and a narrow job has less compute to hide it under. Narrowing
  cuts steps AND beats, residency only beats, zero-skip only steps, grouping only
  retirement -- which is the whole composition rule. MEASURED STACK: FP32->INT8
  narrowing plus both operands resident is 139 cycles against 669 = 4.813x, and
  3.540 x 1.359 = 4.81 exactly. Note WHICH residency figure: composing with FP32's
  1.279x predicts 4.53x and understates it, so the stack is mildly
  super-multiplicative.
- [x] NO LOOPBACK SEQUENCER, for two structural reasons. (1) Narrowing COLLAPSES:
  exact representability is transitive downward, so FP32->BF16->FP8 is identical to
  FP32->FP8, and iterating gains nothing beyond picking the narrowest exact target
  once -- `va_turbo_compose(a, a) == a` is an exact law in the implementation.
  (2) Every lever strictly decreases a monotone quantity (k_bytes, then steps, then
  beats), so a staged pipeline terminates by construction and there is nothing for a
  cycle detector to detect. `va_turbo_plan_t` was already resource-orthogonal, which
  is why recipe 17 could hard-code lossless+resident-B in ONE plan; compose
  generalises that rather than adding 30 more hard-coded pairs.
- [x] THE ORDERING HAZARD, caught by construction. Both residency keys in
  `g6lc_ai_gemm_seq` include the format (ptr/n/k/ldb/FMT/epoch, lines 554 and 643), so
  a narrowing that changes numfmt is a residency MISS BY CONSTRUCTION. Composing them
  is refused unless the caller asserts the resident tile is already at the target
  format -- convert ONCE at load, then reuse across many jobs. A planner that narrowed
  INSIDE a reuse window would silently destroy the residency it was stacking with.
  Also enforced: conflicts refused not resolved (two targets, two group geometries),
  per-product error terms ADD so stacking cannot launder error, the budget is re-gated
  from the REQUEST rather than inherited, and the window is RECOMPUTED from the
  endpoint because mac_step is a property of the final format.
- [x] A REAL CORRECTION COMPOSITION EXPOSED: lossless exactness depends on the TARGET,
  not on both ends. The previous rule required both source and target integer, so
  FP32->INT8 on integer-valued data was reported REL at 1 ppm even though an INT8 job
  accumulates in EXACT integers and returns the exact dot product. The source's
  accumulation domain is irrelevant once `lossless_proven` holds -- the source run is
  not the one executed. Now `policy_integer_format(target)`: exact pairs go from 1 to
  9 of 17, the measured 4.81x stack becomes an EXACT plan, and the selector got
  SMALLER (4,619 -> 4,567 cells, one comparison removed).
- [x] AREA, and it changes the next recommendation. One selector 4,567 cells; two
  selectors + compose 12,521; so compose is ~3,387 cells (a LOWER bound, since any
  sharing Yosys found between the two selectors shifts more onto compose), 0
  sequential, 0 latches, and zero until instantiated. That cost is dominated by
  RE-DERIVING the error bound (36- and 44-bit multiplies the selector already
  contains). So composing REQUESTS -- set the target and reuse flags on one request,
  run select ONCE -- would get the bound for free, but needs the selector's class
  dispatch to stop being an exclusive if/else-if chain. The non-exclusive dispatch
  refactor therefore now has a MEASURED justification (~3.4k cells) rather than a
  stylistic one; plan-side compose is the low-risk step that works today.
- [x] REQUEST-SIDE COMPOSITION BUILT (`va_turbo_stack_request`), and measurement then
  REVERSED MY OWN RECOMMENDATION TWICE. Both reversals are constraints on any future
  planner, so both are recorded rather than tidied away.
  (1) Carrying the earlier stage's EPSILON and summing it into `arith.eps_ppm` before
  the `eps * kappa` multiply was wrong twice over: the earlier bound had ALREADY been
  scaled by its own kappa, so a second multiply scales it twice (conservative since
  kappa >= 1, but wrong in form), AND a summed epsilon makes the multiplicand
  data-dependent, de-constanting the per-recipe multiply that 32 folded constants
  otherwise collapse to. ABC stalled >31 MINUTES at 0.1% CPU on a top that had been
  synthesising in seconds. Fixed by carrying the finished stage's BOUND
  (`prior_bound_ppm`) and adding it AFTER the multiply: correct, and synthesis back to
  16s. Costs the selector +339 cells (4,567 -> 4,906).
  (2) With that fixed the request-side top STILL stalled ABC (>13 min at 1.5% CPU vs
  31s plan-side), and the reason is structural: `select -> fold -> select` is ONE
  combinational cone of ~2x the depth, while plan-side keeps two selections PARALLEL
  and joins at the end. So plan-side composition is the COMBINATIONAL form and
  request-side stacking belongs BEHIND A REGISTER or in software, where the two
  selections are separated in time. `prior_bound_ppm` is retained precisely because
  it is what makes that pipelined/software form possible.
  Consequence: the non-exclusive dispatch refactor is NOT justified by this
  measurement after all -- it would only help a form that should not be combinational.
  The request-side top is kept for simulation and excluded from the synthesis gate,
  with the reason recorded at the exclusion site so CI cannot silently hang on it.
- [ ] Next on this line: the C-port widening -- which narrowing is what makes worth
  building, since narrowing pushes the engine from compute-bound to retire-bound --
  and a pipelined (registered) stacking path if multi-stage selection is ever wanted
  in hardware rather than in the host planner.
- [x] DECODE RESIDENCY MEASURED, and it corrected two of my own claims. Remote
  `ai-gemm-reuse-20260908T010220Z-bddf7872d7ad` PASS: a new DECODE experiment (m=1)
  runs alongside the square DUAL one in the SAME run. FP32 decode resident-B 158->85 =
  1.859x and resident-both 158->75 = 2.107x, against the square tile's 1.1225x/1.2792x --
  so decode residency is 1.53-1.66x LARGER, confirming that a square tile is the least
  favourable shape for recipe 16. INT8 1.806x/2.074x, FP16 1.837x, INT4 1.773x.
- [x] CORRECTION 1, a real model fix: the work terms must be CEIL'd. Every square-tile
  point has an integral beta*beats so it was invisible; at m=1 every fractional case
  landed on .125 and measured exactly one cycle higher -- a partial beat costs a whole
  cycle. With ceil(steps + beta*beats) + 11 the model is exact on all 16 new decode
  points, which is out-of-sample at a new SHAPE rather than just new beat counts.
- [x] CORRECTION 2: "the largest opportunity in the catalog" was overstated. At 8 lanes
  the decode gain SATURATES near 2x and the cap is steps + c, not traffic: for INT4 the
  constant alone is 58% of the resident-both time, which is why INT4 has the WORST decode
  ratio (1.773x) despite B being the same 8/9 of its traffic. Resident-A is worth ~1.068x
  at decode, so at m=1 "residency" means "resident B" and the A-side has no decode story.
- [x] The two figures reconcile in closed form: at m=1 both steps and beats grow linearly
  in n, so the ratio CONVERGES to 1 + beta*(row_bytes/8)/ceil(row_bytes/lanes) -- 2.14x
  for FP32 at 8 lanes (measured 1.859x, approaching from below) but 10.12x at 64 lanes.
  The ceiling RISES as lanes shrink the step term, which is why the same mechanism gives
  ~2.1x on the 8-lane corner and much more on the 256-lane SKU where ceil(rb/lanes)==1.
  B's share is `n/(m+n)` and nothing else -- measured 888/1000 for ALL formats, since
  row_bytes and beta cancel, so it is a property of the shape alone.
- [x] LATENT LOADER BUG FOUND while probing n=16: at JOB_N=16/JOB_K=8 the harness sets
  lda=ldb=k, giving INT4 a 4-byte row stride, and the loader does not read
  non-8-byte-aligned rows back correctly. All-ones fixtures PASS (uniform data cannot
  detect a shifted read); the first SIGNED INT4 tile fails golden. Guarded rather than
  papered over. Also: JOB_M/N/K are now parameters, the m*n-even assumption is gone
  (job_write_beats), and MaxDim guards now cover m and n rather than only k.
- [x] n=16 NOW MEASURED. The blocker was the harness's fixed 512 B B sub-slot, which
  correctly refused FP32 at n=16,k=16 (needs 1,024 B). The slots are now DERIVED from the
  geometry with a 512 B floor per region, so OFF_B/OFF_C/SLOT come out 0x200/0x400/0x600
  exactly as before and every multi-engine address is unchanged -- verified byte-identical
  on the default run, and NWORDS only grows when a larger geometry needs it. Measured
  FP32 decode n=16: cold 298, resident-B 153 = 1.948x, both 143 = 2.084x, against
  predictions of 1.980x/2.122x -- right to ~1.6%. B share 941/1000 = 16/17 exactly.
  INT8 1.961x, INT4 1.971x, FP16 1.953x. `run-gemm-concurrent.sh` now takes
  JOB_M/JOB_N/JOB_K so the geometry axis is no longer manual-invocation only, and it
  rejects JOB_K%16 != 0 while INT4 is in the tables (the row-stride guard).
- [x] RESIDUAL MECHANISM NARROWED BY THREE REFUTATIONS. Sweeping m at fixed n=32 and
  sweeping PeLanes at m=1 killed every structural explanation, and corrected the one I
  had published. (1) NOT C write beats: the first reading was 0.75*(w-4), which fits
  perfectly at m=1 only because w == n/2 there; across m = 1/8/16/32 the write beats
  grow 32x (16 -> 512) while the residual stays at +9/+12. (2) NOT compute hiding: the
  same sweep grows steps 32x (256 -> 8,192) with the A-resident residuals pinned. (3)
  NOT C bank conflicts: C is banked by j % PeLanes so a collision must vanish once
  PeLanes >= n, and at PeLanes 8/16/32 with n=32 the residual is +9/+12 at EVERY one,
  including PeLanes == n. So the law is `alpha*(n-8)` with alpha 0.375 (B streams) /
  0.5 (B resident) -- a function of n ALONE, which is also why the square 8x8 tile fits
  the base model exactly: it sits at the law's root rather than violating it. One
  pattern survives: the states whose A operand STREAMS drop below the law at large m
  (+9 -> +6, +12 -> +9) while A-resident states stay on it, so A traffic hides part of
  it. Naming it needs RTL instrumentation (a stall counter), not more black-box sweeps.
- [x] RESIDUAL PINNED over four n. n = 8/16/24/32 x 4 formats x 4 residency states = 64
  measured points. It is EXACTLY linear and format-independent with TWO slopes, both
  zero at n=8: `0.375n - 3` while B streams (cold, warm_A) and `0.5n - 4` once B is
  resident (warm_B, both) -- i.e. `0.75*(w-4)` and `1.00*(w-4)` in write beats, w = n/2.
  With the correction the model is EXACT on all 64 points. The two slopes are the
  informative part: C writes are MORE exposed when B is resident, i.e. when no read
  traffic is left to hide them behind, which is what a write buffer draining against
  reads looks like and is the first write-side evidence in this work. Still labelled
  EMPIRICAL and kept OUT of the base model, because it does not extend to the square
  tile: 8x8 has 32 write beats and the same rule wants +21, yet it measures exactly 0
  both cold and both-resident. So exposure depends on something these points do not
  separate (m, or C bank sequencing at m=1), and one story covering both would be
  fitting eight numbers.
- [x] THE RATIO CONVERGES, as the closed form required. FP32 resident-B 1.859x ->
  1.948x -> 1.982x -> 2.000x at n = 8/16/24/32 with diminishing steps, all below the
  2.141x ceiling and approaching from below. Resident-BOTH moves the other way and
  settles at ~2.07x, because with no operand reads left the ratio is set by `steps + c`
  rather than traffic -- the same cap that makes INT4 the worst decode case.
- [x] A PRE-EXISTING ASSUMPTION THE AXIS EXPOSED, now bounded with its reason: JOB_N
  below 8 fails, and confusingly (JOB_N=4 reports a golden mismatch at `C row0 col4`, a
  column the nominal tile does not have). The directed suites perturb the shape with
  LITERALS (n=6,7 m=4 k=8) to test which fields are part of the reuse key, and several
  deliberately do NOT re-stage, so they rely on the nominal staging already covering the
  larger shape -- at 8x8, B rows 4 and 5 exist because eight were staged. The axis is
  now asserted at JOB_M,JOB_N >= 8 and JOB_K >= 16 rather than letting a smaller
  geometry produce a mismatch that reads like an RTL bug.
- [x] LOSSLESS NARROWING LANDED: the exact traffic lever FP32 never had. Bit-preserving
  FP32 had exactly ONE implemented speedup (recipe 16 residency, 1.279x) because the
  two exact levers that could help it -- lossless repack 1/3/17 and zero-skip 2 --
  were locked to integer formats by `policy_integer_format(r.numfmt)`. That GATE, not
  the arithmetic, excluded FP32 from every exact optimisation in the catalog. The
  property that matters is only "every element round-trips into a strictly narrower
  container exactly", which holds for weights trained narrow and widened, quantised
  values parked in a float container, or 4-bit weights in an INT8 container. Then the
  products are the SAME real numbers and the target format's per-product epsilon does
  not apply: the only difference is the wider `mac_step` regrouping the FP32
  accumulator folds, so the error site moves from per-PRODUCT to per-WINDOW and the
  bound becomes the accumulation epsilon (1 ppm) instead of the storage epsilon.
  Measured: FP32->BF16 5.803 ppm vs 7,828 (1,349x tighter), FP32->FP16 0.323 vs 977
  (3,025x), FP16/BF16->FP8 exactly 0.000 ppm (an E4M3 product is <=8 significant bits,
  so a window of 8 still fits FP32's 24 and the accumulation is exact), and INT8->INT4
  BIT-IDENTICAL by construction (same integers, exact 640-bit reduction, integer
  accumulator with no rounding site) -- reported as VA_ARITH_EXACT eps=0, while any
  float accumulator gets VA_ARITH_REL at 1 ppm. NOT bit-identical for the float pairs,
  and saying otherwise would be wrong; it is a ~1,350-3,000x smaller difference than
  the approximate conversion saving the identical traffic. In one trial the narrowed
  run beat native FP32 (0.000 vs 0.385 ppm) because fewer windows means fewer roundings.
- [x] NOT FP32-ONLY, deliberately: 17 strictly narrower ordered pairs over the seven
  known formats (FP32 to six, FP16/BF16 to four each, INT8/E4M3/E5M2 to INT4), with
  measured speedups 1.917x / 1.847x / 1.734x. `VA_LOSSLESS_NARROW` sweeps all 64
  (src,dst) combinations and admits exactly those 17. Equal-width pairs are refused on
  purpose -- FP16 <-> BF16 saves no beats, so attaching a bound to it would be
  claiming a plan that buys nothing.
- [x] AREA AND RETURN, isolated by swapping package+testbench as a pair against HEAD:
  selector 4,002 -> 4,619 cells (+617, +15.4%), still 0 sequential and 0 latches, and
  the disabled wrapper still zero. That is +8.2% of one 7,530-cell GEMM engine, so
  FP32->FP16 returns 11.2x per %area -- the same league as residency's 14.7x against
  0.8x for lane widening. Throughput needs NO new RTL measurement: a narrowed job is an
  ordinary native job at the target format, so its cycles are the already-measured
  native figure.
- [x] WITNESSED IN RTL. The GEMM harness runs each pair twice on one engine (same
  logical matrix at source and target format), proves per-element exactness on both
  tiles BEFORE either run, poisons C between them and compares every C word.
  Remote `ai-gemm-reuse-20260907T194820Z-3bf33be6b3dc` PASS:
  INT8->INT4 189->109 (1.733x) beats 32->16 max_diff=0 BIT-IDENTICAL;
  FP32->BF16 and FP32->FP16 669->349 (1.916x) beats 128->64 max_diff=0.
  Cycles and beats match the predicted native figures exactly and the byte ratio is
  asserted, not eyeballed. All four originally-outstanding items are now closed:
  the proof producer (`ai_tensor.lossless.prove`), the harness consumer mask bit
  (`LOSSLESS_MASK`), the paired measurement, and ai-tensor exposure
  (`lossless.plan`, quality ~0.007 ppm instead of the storage epsilon).
- [x] TWO CORRECTIONS THE MEASUREMENT FORCED, both mine. (1) "Equal-width pairs are
  refused" was overstated: it holds for the NARROWING arm only. Recipe 1's
  pre-existing integer repack arm still admits an equal-width integer request
  (INT4->INT4 gives `apply=1`, `convert=0`, `lossless_narrowed=0`, EXACT, eps 0),
  which is correct -- a repack claiming no traffic saving is a legitimate exact plan,
  just not a narrowing. Float sources with an equal-width target stay refused because
  the repack arm is integer-only. An assertion firing on the first run caught this,
  and the harness now models both arms. (2) The float pairs measured 0 ULP, which
  QUALIFIES rather than confirms the 5.803/0.323 ppm host figures: the harness
  operand path is integer-only, so every product and partial sum sits far inside
  FP32's 24-bit significand and no fold rounds at all -- and regrouping folds that
  round nothing cannot move the result. The test was NOT tuned to produce a number;
  the bound stays at the declared 1 ppm with a comment saying the observed 0 is a
  property of these operands, not of the recipe.
- [x] THE REGROUPING CLAIM IS NOW WITNESSED IN RTL, and it needed no fractional
  operand path -- that blocker was pessimism about the HARNESS, not about the
  arithmetic. `mantissa * 2^exponent` with POSITIVE exponents only is still a whole
  number, and a wide enough ladder makes the accumulator round mid-reduction. The
  mantissa is bounded by the target's explicit mantissa bits (BF16 <= 127, FP16
  <= 1023) so exactness is preserved and proven element by element, and
  `mantissa << max_exp` stays inside the target's finite range (FP16 1023<<6 =
  65,472 <= 65,504). Remote `ai-gemm-reuse-20260907T202101Z-6f8842a4669a` PASS:
  wide_exponent FP32->BF16 max_diff 32 ULP with 38/64 elements differing,
  FP32->FP16 5 ULP with 19/64, both bit_identical=0 -- while INT8->INT4 stays
  BIT-IDENTICAL at wide magnitudes (0 ULP, 0/64), which is the strong prediction:
  integer accumulation has no rounding site at any scale. The small-integer class
  is retained as the control and still reports 0 everywhere.
- [x] THE MAGNITUDE PROVES IT IS REGROUPING, NOT LOST BITS. 32 ULP is <= 3.8 ppm on
  the worst element; dropping even ONE BF16 mantissa bit perturbs an element by
  2^-8 relative and moves a same-order C element by >= 2^-9 = 1,953 ppm = 16,384
  ULP. The observation is ~512x below that floor, so the 256 ULP bound (8x the worst
  observation) separates "the accumulator regrouped" from "the operands changed",
  which is the only distinction the experiment must make. NOTE the metrics are not
  interchangeable: the host 5.803/0.323 ppm are Frobenius-norm ratios over the tile,
  these are worst-element ULP distances -- same scale, different quantity.
- [ ] Still outstanding: no PRODUCTION consumer mask bit for 1/3/17 (the harness has
  one; enabling it in `g6lc_ai_island_top` needs a descriptor field to carry the
  proof, i.e. an ABI change), and zero-skip (recipe 2) is still integer-gated, the
  other exact FP32 lever the same argument applies to.
- [x] FITTING IS COMPLETE: every format now carries a bound, native FP32 included.
  Native FP32 is the ONE candidate the windowed kappa may legitimately multiply,
  because nothing perturbs its products (exact 48-bit significand product, exact
  640-bit reduction) so its only roundings are the 2W-1 sites AT window
  boundaries. Measured against an EXACT RATIONAL reference, not float64: eps 1
  ppm, bound 10 ppm, level 1, measured **0.0672 ppm** -- FP32 accumulation is not
  the accuracy limiter at K=16, which is what makes narrowing worth taking on
  accuracy grounds. Full table in `architecture/ai-matrix/va-turbo.md` §13:
  FP16 level 6, BF16 9, INT8 12, FP8 E4M3 13, E5M2 14, Mitchell 14, mantissa
  10/8/6/4 at 7/9/11/13; INT4 and 2-bit truncation refused with a stated reason
  rather than a zero. 52 host tests pass.
- [x] FP32 QUALIFIES FROBENIUS-MATCHED, NOT PER-ELEMENT, AND THE BLOCKER WAS A
  FIELD WIDTH. The worst-ELEMENT windowed kappa is 962.3 and its bound (962 ppm)
  sits inside budget level 4, but `kappa_window_q8` was Q8.8 in 16 bits and
  saturates at 255.996, so it failed closed on metadata rather than on
  arithmetic -- the wrong reason to refuse. Widened to 24 bits (65,535.996),
  selector wiring only. At a 1 ppm epsilon even the widest kappa the field holds
  gives 65,536 ppm, so the accumulation term is bounded by ~6.55% by
  construction and can never be what refuses a plan.
- [x] MY OWN ACCUMULATION BOUND DOUBLE-COUNTED. `va_turbo_accum_bound_ppm`
  multiplied by the site count on top of a kappa that ALREADY sums all 2W-1 site
  magnitudes over |R|, over-stating the term by 2W-1 -- a 15x error at K=16,
  window 2 (135 ppm where the model says 10). It now charges eps*kappa once and
  keeps `sites` only as the validity guard, with a test asserting independence
  from the site count above that guard.
- [x] THE 640-BIT ALIGNMENT DROP IS DEAD CODE, AND NOW PROVABLY SO.
  `fp_dot_product_aligned` returns zero when a shift reaches FP_DOT_MAXW, which
  would drop the LARGEST term in a window -- a wrong answer, not a rounding.
  `block_exp` is the MINIMUM lane exponent so the shift is non-negative, and the
  product exponent spans [-298,208] for FP32 and [-266,240] for BF16: worst case
  506 + 48 product bits + 8 bits of 256-lane headroom = 562 of 640. Unreachable
  for every supported format, but NOTHING CHECKED IT, so a future MAXW reduction
  or wider-exponent format would have reached it silently. Now a per-cycle
  simulation invariant in `g6lc_ai_pe_dot_float` plus directed worst-case-spread
  vectors (max normal squared beside min subnormal squared in one window) for all
  five float formats; 5,024 checks pass. An output-only check could never catch
  this: the dropped term is below the ULP of the surviving one, so the rounded
  answer is identical either way.
- [x] REMAINING ASYMMETRY, recorded not fixed: the measured column is now exact
  while `kappa_windowed` still comes from float64 partial sums, so the BOUND is
  now the weaker side. And the per-format ppm figures are from a seeded
  FP32-resident fixture at the shipped shape, not the pinned model snapshot,
  which is absent on this host.
- [x] THE MOVING-WINDOW BOUND IS REAL BUT DOES NOT RESCUE THE PER-PRODUCT TERM,
  and my premise going in was wrong. The datapath does re-center: the float dot
  is block floating point per step (block_exp from that step's lanes, exact
  640-bit reduction, ONE rounding), so a K-long dot carries 2*ceil(K/mac_step)-1
  roundings, not K. But every non-exact recipe perturbs the PRODUCT before the
  reduction, and for a per-product perturbation eps*sum|p_i| is TIGHT, so
  intra-window cancellation is NOT free and the element-level kappa is the truth
  rather than pessimism. Substituting a windowed kappa is measurably unsound:
  INT8 measures 37,134 ppm against a windowed 6,419 (5.8x violation) and INT4
  332,762 against 86,101 (3.9x). The selector therefore ADDS the post-reduction
  accumulation term and never replaces the per-product one, and honours a claimed
  window only when it equals `va_turbo_window_log2(numfmt, lanes)` -- a window
  the hardware does not implement would UNDER-state the bound. What windowing
  legitimately buys is the previously unmodeled accumulation term: 3 sites at
  kappa 3.04 instead of 31 at kappa 17.1, a real 5.6x on THAT term, which is a
  few ppm and moves no level.
- [x] THE PREMISES DID LOOSEN, VIA THE ABSOLUTE FLOOR, NOT THE WINDOW. FP16 and
  both FP8 formats were refused outright because their operands leave the normal
  range and a relative-only model says nothing about subnormals. The standard
  mixed bound |fl(x)-x| <= u|x| + eta/2 ADDS a term, so it is sound exactly where
  the relative bound was inapplicable: FP16 now qualifies at level 5, FP8 E4M3
  and E5M2 at level 13. E4M3's bound is ~22.7% and the FLOOR dominates it
  (59,737 ppm of 6%, eta=2^-9 against the tile scale) -- a real result about
  E4M3. Cost of honesty: every already-admitted candidate's bound got slightly
  WORSE (BF16 10,152 -> 10,161, INT8 510,889 -> 510,894, Mitchell
  324,219 -> 324,232) because the FP32 accumulation term the old report listed as
  "not modeled" is now included; no level moves and a test locks the direction.
  `mantissa_truncated:*` stays unqualified on a different premise entirely
  (`fp32_input_rounding_not_modeled`), which no floor excuses.
- [x] THE TRADE-OFF IS NOW EVALUABLE, NOT ENABLED. FP32 -> FP16 halves operand
  read beats, measured 669 -> 349 cycles per job (1.92x) on the class-0 model,
  and FP16 finally has a bound (level 5) to weigh it against. Still no
  approximate consumer in the datapath, and these are float64 reference proxies
  on a seeded fixture -- not model quality. Two proxy gaps recorded: float64
  partial sums are rounded while the RTL reduction is exact, and
  `fp_dot_product_aligned` ZEROES any product whose alignment shift reaches 640,
  which the proxy does not model -- a >640-bit exponent spread silently drops a
  product in hardware. Wants a directed RTL test.
- [x] BOTH OPERANDS RESIDENT IS THE BEST SPEEDUP-PER-AREA LEVER MEASURED. Resident
  A mirrors resident B under the same recipe 16 with an INDEPENDENT key (ptr_a, m,
  k, lda, numfmt, own epoch; `n` absent exactly as `m` is absent from the B key),
  so a job may hit neither, either or both. One engine, identical work, every C
  element checked: INT8 189 -> 164 (A) / 164 (B) / **139 both** = 1.359x, FP32
  669 -> 596 / 596 / **523** = 1.279x, and operand read beats reach **ZERO**
  (32 -> 0, 128 -> 0) so only C writes remain. The comparison that matters:
  1.359x on ONE engine equals the 1.358x resident B alone needed four contended
  engines to reach. Cost +184 cells (+2.44%) and +22 FF over the 7,530-cell
  baseline, zero latches, giving 14.7x return per %area against 0.8x for
  8 -> 16 lanes and 0.0x for 16 -> 32. 32 directed A cases pass and VA_TURBO=0
  reports 1.000x with no hits.
- [x] TWO DEFECTS IN MY OWN A IMPLEMENTATION, caught by the harness and not by my
  review. (1) The A skip keyed off `cacheable_q`, but A decides in ST_CHK where
  that register has just been cleared by the start handshake, so the skip was DEAD
  CODE while the PMU arm -- using the combinational term -- still reported a hit:
  a hit flag that disagreed with the FSM. (2) `pmu_reuse_b_hit_o` fired only on
  `ST_LA -> ST_MAC`, so with both residencies (which goes `ST_CHK -> ST_MAC`) it
  under-reported exactly when the engine saved the most traffic. Both now derive
  from the same term the FSM uses, so flag and behaviour cannot diverge.
- [x] INTRA-ENGINE LANE GROUPING IS REFUTED, and the blocker is the C side. One
  element is written on its last reduction step (single `c_w_req`/`c_w_addr`/
  `c_w_data`), so an engine retires at most ONE element per cycle whatever the
  lane count; and idle lanes exist exactly when `k_bytes < PeLanes`, which is
  exactly when a reduction already finishes in one step. The two conditions are
  mutually exclusive, so there is no configuration with spare lanes AND retire
  headroom. Measured on current RTL: INT8 k=16 at PE_LANES=16 and 32 is
  byte-identical (250 baseline / 200 warm / 125 cold), while 8 -> 16 lanes does
  pay (189 -> 125 per job). Grouping is a C-side widening (more write ports and
  accumulators), not free use of idle lanes. Profitable directions stay: operand
  reuse, and larger k where lanes bind (INT8 k=64: 668 -> 284 cycles, 8 -> 32).
- [x] OPPORTUNISTIC HIT RATE MEASURED, and it is linear. Mixed eight-job streams
  where misses genuinely change B identity: INT8 1.034x / 1.070x / 1.110x /
  1.130x at 2, 4, 6, 7 hits of 8, with read beats falling exactly linearly
  (256 -> 144); FP32 1.028x -> 1.105x. Each hit saves 25 of 189 cycles (13.2%)
  for INT8 and 73 of 669 (10.9%) for FP32, and measured speedup matches
  `1/(1-0.132h)` to three decimals. So the headline 1.36x needs BOTH ~100% hits
  and multi-engine contention; a realistic 50% hit rate on one engine is +7%.
  The harness asserts the hit count equals the intended count and re-checks C
  after every job.
- [x] THE BUILD WAS SERIAL AND `-j` COULD NOT FIX IT -- a parallelism claim needs
  a CPU percentage next to it, and mine did not have one. Measured 101% CPU on a
  3,712 s four-engine build while passing `-j 12 --build-jobs 12
  --verilate-jobs 12` and `MAKEFLAGS=-j12`. Host `make` parallelises fine
  (36 s -> 3 s synthetic), and `VM_PARALLEL_BUILDS` was already 1. The real cause
  was MY testbench: with `--timing` every task inlines into the one `initial`
  block, which Verilator emits as a single `VlCoroutine` that
  `--output-split-cfuncs` cannot split, and eighteen literal `run_experiment`
  calls produced a 321,102-line function in one 27.4 MB translation unit. Driving
  the experiments from a table (identical order and arguments) halved it to
  145,977 lines: 1-engine build 215 s -> 42 s, 4-engine 3,712 s -> 68 s, 4-engine
  total 3,740 s -> 100 s (54x on the build). Verilate is 1.5-2.7 s and simulation
  2-20 s, so the object build was the entire cost. Table-driving the directed
  cases is the next step and is not needed for correctness.
- [x] BUILD NO LONGER SELF-LIMITS: the remote compile was pinned at `-j 2`, which
  is what made the four-engine build hit the 1800 s cap and look like a failure.
  It now saturates the remote cores (`--jobs 0` default, 12 used) with a
  persistent ccache kept OUTSIDE the per-run directory, since a cache inside the
  run tree is cold on every dispatch. `run-gemm-concurrent.sh` defaults to
  `nproc` on the same terms.
- [x] THE ALL-ONES FIXTURES WERE HIDING TWO REAL DEFECTS. (1) Operand banks were
  sized `ceil(MaxDim/PeLanes)` while A/B addresses count BYTES, so at MaxDim=16,
  PeLanes=8 an FP32 row 0 byte 16 aliased row 1 byte 0. Now
  `ceil(MaxElementBytes*MaxDim/PeLanes)` with a runtime width reject; the island
  picks 1 byte integer-only and 4 with IslandFpEn, so the integer production
  allocation is unchanged. (2) The first signed run FAILED
  (`exp=0000000d got=ffffffff`) on a harness bug where packed negative elements
  sign-extended across their neighbours. Every C element is now checked against an
  independent reference, C is poisoned between phases, and an RRESP error is
  injected. A speedup measured with all-ones data and partial checking is not a
  speedup.
- [x] TWO OF MY OWN FULL CONSTANTS WERE UNSOUND: 7,887 and 147,908 ppm were
  understated against the exact 7,889.52 and 147,959.18, i.e. bounds that could be
  exceeded. Corrected, and every division in the quantisation bound now rounds UP
  (a bound rounded down is not a bound); the suite asserts the rounding direction,
  not just the values.
- [x] FLATNESS TIGHTENING LANDED AND MEASURED. The FULL reference no longer
  hardcodes "every element at the maximum": it takes fa = sum|a|/(K*max|a|) so the
  bound is K*A*B*[(fa+fb)/(2L) + 1/(4L^2)], with an absent or out-of-range value
  falling back to the worst case fa+fb=2 rather than anything optimistic. Measured
  fa+fb = 0.920 of 2.0, tightening FULL kinds 2.17x: INT8 675,768 -> 310,931 ppm,
  slack 36.5x -> 16.8x, required level 14 -> 13.
- [x] DESIGN QUESTION SETTLED: real but insufficient. Level 13 still authorises
  41% error for a recipe whose real error is 1.85%, because the residual
  conservatism is error CANCELLATION across the reduction, which a worst-case
  bound may not assume away. A worst-case full-scale guarantee and a usable INT8
  path are incompatible on real data, so the trade is now EXPLICIT and AUDITABLE
  rather than resolved by loosening the bound: `worst_case_waived` waives the
  analytic gate only, the measured bound still applies, and the plan reports
  `bound_waived` so an empirical promise never looks like a proven one. Tested
  that a waiver cannot bypass the measured bound, accuracy evidence or kappa, and
  is never reported for an exact recipe.
- [ ] SUPERSEDED, kept for the trail: REMAINING CONSERVATISM IS THE FULL KIND. Measured gap
  between the level the analytic bound demands and the level a tight bound would
  demand: FP16 7 vs 3 (9.5x), BF16 10 vs 7 (6.2x), mantissa-8 9 vs 7 (3.9x),
  FP8 E4M3 14 vs 11 (8.2x), Mitchell 15 vs 12 (6.0x), INT4 15 vs 13 (3.3x), and
  INT8 14 vs 9 (36.5x). The REL kinds at 3.6x-9.5x are the ordinary price of a
  worst-case bound; INT8 is the outlier because the FULL reference
  K*max|a|*max|b| assumes every element hits worst case AND that the result norm
  is small against that product. Authorising level 14 would permit 82% error to
  admit a recipe whose real error is 1.85%. Next tightening is specific: replace
  the FULL reference with actual operand norms (sum|a|, sum|b|), which needs norm
  metadata from the caller and should move INT8 from level 14 toward level 9. DO
  NOT widen the bound to make INT8 pass; that would make the gate lie.
- [ ] Connect qualified V/A plans to actual consumers and window ownership before
  claiming acceleration. No precision conversion, multi-output arithmetic, new
  runtime ABI or approximation quality was implemented in the selector pass.
  Reserved recipes stay unsupported; existing subcode search stays intact.
- [x] S0 DONE (verif/tb/ai_island/policy_approx.py, artifact
  policy-approx-s0-pythia.json): 48 real activation-by-weight tiles from pinned
  pythia-70m-deduped through a real forward pass, 8x8x16, exact float64 reference
  and exact accumulation. Format narrowing (the only lever that changes k_bytes):
  FP16 2x groups for 2.96e-04 p95 error = 67.6 gain per 1% error (best by an order
  of magnitude, and 10x more accurate than BF16 at the same k_bytes); INT8 4x for
  1.49e-02 (2.7); FP8 E4M3 4.89e-02 and E5M2 9.62e-02, i.e. INT8 is 3.3x/6.5x more
  accurate at EQUAL concurrency so one-byte narrowing should prefer INT8; INT4 8x
  for 2.49e-01 = 25% tile error, almost certainly unusable, so the INT4 4x
  headroom found earlier is largely unreachable.
- [x] S0 KILLED LEVER 2: 8-bit mantissa truncation errs 3.22e-03 versus BF16
  3.18e-03 - same error, but truncation keeps 4-byte storage so it buys no
  concurrency; narrowing strictly dominates it. Mitchell logarithmic multiply is
  8.2x less accurate than INT8 and also buys no lanes; on this evidence do not
  build it. Mantissa truncation stays defensible only where FP32 range is required
  and storage cannot narrow.
- [ ] REVISED TARGET after S0: sub-code carries a per-job precision_class over
  {FP32, FP16, INT8} plus groups_log2. The approximate-multiplier topologies that
  motivated the analog framing are dominated and drop out of the plan. Caveats:
  tile Frobenius error is a proxy not perplexity; one model and one prompt;
  FP8/INT8/INT4 measured WITH per-tile scaling which flatters them; accumulation
  exact so accumulator-width effects uncovered.
- [ ] PLANNED UPGRADE (plan only, nothing implemented; architecture README has the
  staged table). Precision is the lane-demand knob because usable lanes = k_bytes,
  so each halving of element width halves k_bytes and doubles hostable groups:
  2x concurrency per precision step, derived from the measured rule. Approximate
  topologies are combinational (mantissa-truncated and Mitchell-style logarithmic
  products) with EXACT wide accumulation so error does not compound. Sub-code
  becomes the experiment harness, carrying (groups_log2, precision_class) instead
  of a candidate index, reusing the existing hysteresis/feature-hash/PMU/gating.
  Stages: S0 accuracy harness on CAPTURED matrices (no RTL, and it can disqualify
  everything - do this first); S1 per-group accumulators and measured concurrency;
  S2 approximate multiplier options; S3 lookup replaces the search (recovers
  ~5,470 cells, 32-cycle tax -> 0); S4 promotion on paired performance AND accuracy
  evidence. Area favours this direction: approximate multipliers are smaller than
  exact ones, unlike lane ganging which cost 6.30x area for 4.20x.
  Risks to hold onto: approximation breaks the bit-exact digest invariant every
  measurement so far relied on, so exact modes must keep exact checks and
  approximate modes need error bounds; the all-ones fixture cannot measure
  accuracy (no cancellation, no dynamic range) so S0 must use the capture corpus;
  the concurrency assumption is still untested and gates the whole numerator; and
  tile Frobenius error is a proxy, not a model-quality claim.
- [ ] REFINED SUB-CODE TARGET: the value is the idle lanes, not the gang width.
  Per-tile k is bounded by MaxDim, so at MaxDim=16 on a 32-lane array INT4 leaves
  24 of 32 lanes idle (4x concurrency), INT8/FP8 leave 16 (2x), FP16 saturates and
  FP32 wants more than 32. Monetising that needs per-group accumulators and
  descriptor slots (the multi-output capability), and the split factor varies per
  job because format does. Sub-code reduces to a combinational
  (format, tile-k) -> groups_log2 lookup. Caveat: this is a utilisation argument
  on a small fixture, and it inherits the same untested concurrency assumption as
  the cluster case.
- [ ] Sub-code/group tuning has zero throughput leverage while nothing consumes
  the codec output. Do not tune it for performance. It becomes productive only
  with a provisioning consumer that RAISES a bound - cluster count or lane
  grouping - which is worth a measured 2.11x and is the natural fit for the
  eight-state code plus 3-bit subcode.
- [ ] 300% VERDICT: not reachable by parameters. Measured ceiling at this tile
  geometry is ~+89% and already saturating, with utilisation falling 68->52->26%
  of peak as lanes widen. A 4x class needs three coupled changes, none a knob:
  (1) raise MaxDim/k so wide lanes stay fed, (2) operand bandwidth past the
  64-bit beat (wider beats or more channels) since 32 INT8 lanes want ~32 B/cycle,
  (3) multiple output accumulators, i.e. the multi-output datapath the topology
  model assumed. Needs a micro-architecture plan, area/power budget and a
  steady-state fixture with k >> lanes before any number is quoted.
- [ ] ASSESSMENT (structural, not just empirical): AR-depth steering CANNOT beat
  no steering. prefetch_depth only lowers the cap below MaxAROut (0 = fallback),
  and measured throughput increases monotonically with depth, so the optimum is
  "do not cap" = policy-off. Ceiling versus no steering is 0%; the shipped table
  spends -8.15% on decode/routed/sparse. The 11-66% topology class needs a
  multi-output MAC array that does not exist, so no parameter tuning reaches it.
  Ranked next steps: (1) stop capping AR depth (or delete the consumer), (2) find
  a knob that can raise a bound rather than only lower one, (3) invest in
  PeLanes/multi-output datapath for double-digit gain. Do not enable
  PolicySubcodeEn/CacheEn for throughput: advisory sidecar off the GEMM critical
  path (0% MAC/s), models at 0.998x.
- [ ] Re-run the AR-depth sweep through the remote testharness proxy; the current
  artifacts come from local WSL Verilator and are diagnostic-grade dispatch.
- [ ] Extend the sweep to large tiles/`MaxAROut=8` DRAM classes so depth evidence
  is not limited to one small job per format.
- [ ] Qualify motif proposals with matched real array counters and held-out workload
  benefit; no such timing was supplied. The full post-cache `verify --lint --sim
  --synth` attempt failed in the general smoke harness on generated SRAM/SMT C++
  member references and was stopped after broad generated-output cleanup. Git
  reported no tracked deletions. Review cleanup/proxy routing before rerunning
  that broad gate; do not treat it as SoC sign-off.
- [ ] Expand to representative prompt/model distributions, pretrained diffusion
  and routed-MoE captures, then replay numerical operands through RTL memory/PEs.
  QEMU inference/descriptor execution remains separate; QEMU wall-clock speed is
  not island throughput evidence. Live floating grants and production gates stay off.
- [ ] Resolve prior full-core synthesis blockers (`alu` range select and
  issue/commit declaration ordering) and the two moved-core-type branding test
  failures before whole-repository sign-off. PDK STA, DFT/`testmode_i` audit,
  physical area/power and full compliance remain open; focused greens are not
  a fresh full-SoC verification result.

## AI numeric evaluation and floating arithmetic continuation

Priors: `architecture/ai-matrix/numeric-formats-datapath.md`, AI policy §10–§11,
`g6lc_qemu/architecture/AI_BRIDGE.md`, `ai-tensor/architecture/ABI-CONTRACT.md`.

- [x] Reconcile descriptor-v2/k-major packing and native-byte execution; public
  matmul B layouts are converted at the packing boundary. `ai-native-eval`
  cross-checks B3 execution, canonical FP32 NaNs and strict grant/SP24 refusal:
  84 requests/profile, live mask 3 executes 16/rejects 68, software fixture
  executes 82/rejects 2, with 17 negative checks each. Prior artifact:
  `build-platform/workspace/build/ai-native-eval-20260905T025618Z-5ab2c5772ab6`.
  Registered WSL host-only rerun also passes with the rebuilt Linux binary:
  `build-platform/workspace/build/ai-native-eval-20260905T040500Z-1d4e625d85c4`.
- [x] Register and verify `ai-desc-formats`: actual engine legality, rejection
  and effective INT4 alias grant/handoff, not just helper tests. Recorded PASS:
  3,072 helpers, 1,024 wide-mask cases, 1,024 engine cases, 4 starts, mask 3,
  enums 0..7. Artifact and suite loci: `AGENTS-specs-to-tests.md`.
- [x] Implement/verify standalone `g6lc_ai_fp_mac` + `g6lc_ai_fp_pkg`: exact
  FP8/FP16/BF16 widening and separate RNE FP32 multiply then add, flags and
  cancellation/backpressure; no fused/reassociated reduction or FTZ.
  FpPipeRegs 1/2/3/5 measure scalar latency 4/6/8/12 and II 6/8/10/14 cycles,
  with 141,587 widening probes and about 40k scalar transactions per variant.
  Generic scalar synthesis: 8,234 cells / 428 sequential / zero latches,
  disabled zero; 17 widening properties plus 8 control assertions with a
  12-step control bound (not induction or full arithmetic proof).
- [x] Package checks: `g6q.py check` PASS (607 workspace tests, including 170 VM
  plus 1 ignored; independence/fmt/clippy pass). Full `ait.py test` PASS:
  external cosim ping/job, 5 ABI + 10 IR + 48 RT, Python unittest Ran 16 with
  1 NumPy skip, 22 QEMU UIO tests and torch smoke. Build-platform typecheck and
  13 focused tests pass. Software rejects invalid C/done destinations and
  device overlays and preserves sticky completion errors.
- [x] FP8/FP16/BF16/FP32 block-floating dot product PE: extended
  `corev_apu/ai_island/g6lc_ai_pe_dot_float.sv` with generic per-lane decode,
  product, block-exponent alignment, 640-bit reduction tree and RNE FP32 conversion.
  Verified by `verif/tb/ai_island/run-pe-dot-float.sh` (Verilator 5.x) with
  `pe_dot_float_main.cpp`: 5,018 Lanes=4 directed/random checks vs exact `double`
  oracle pass. Yosys `read_slang` elaborates `g6lc_ai_pe_dot_float` with zero errors/warnings;
  `synth -noabc -top g6lc_ai_pe_dot_float -flatten` reports zero problems and zero latches.
  `g6lc_ai_pe_dot_float_pipe` also `read_slang`s and `synth -noabc -top ... -flatten`s with
  zero errors/warnings, zero CHECK problems and ~7,900 flops / ~115k generic cells (Lanes=4)
  after narrowing the mantissa product to 24×24. `AiIslandDtypeMask` / `AiIslandPeImplMask` remain `16'h0003`. No
  fused/reassociated reduction, no FTZ, no new clock/reset.
- [x] Integrate the floating dot-product PE into `g6lc_ai_gemm_seq` loader/accumulator
  and validate full-system grants; production `IslandFpEn` stays off and live
  island grant/PE masks stay 3 (INT8/INT4). Scalar FP and software formats are
  not floating GEMM support or ISA F/D conformance. This increment adds neither
  fused requantization nor non-GEMM arithmetic; existing spine operations are
  unchanged.
  - Landed `g6lc_ai_pe_dot_float_pipe.sv` (parameterized by `Lanes`, Latency =
    `$clog2(P2)+4`) and wired it into `g6lc_ai_gemm_seq` behind `DotPipeFloat`.
  - Fixed the back-to-back transaction hazard: stage-2 product and block-exp/flag
    metadata are now registered, and a stage-3 block-exp/flag register feeds the
    reduction-tree metadata pipeline. This keeps data, block exponent and special-
    value flags aligned for consecutive starts with different `numfmt` and data.
  - Added a `dot_pending_q` outstanding-transaction counter and gated `can_trail`
    and `ST_MAC` exit on it, preventing the C-flush path from overtaking pipelined
    dot results. Pipelined dot output is captured directly in the main `sum_*` registers.
  - `verif/tb/ai_island/run-gemm-backend.sh` (nch={1,2,4,8}, dpf=0,1) PASSES across
    INT4/INT8/FP8/FP16/BF16/FP32. `run-pe-dot-float.sh` (Lanes=4) passes 5,018 checks;
    `run-pe-dot-float-pipe.sh` passes 5,028 checks for both Lanes=4 (latency 6) and
    Lanes=8 (latency 7); a Verilator Lanes=256 lint-only build also passes. Stage-1/2/3
    local variables were split into `always_comb` next-state logic so `read_slang` and
    `synth -noabc -top g6lc_ai_pe_dot_float_pipe -flatten` report zero errors/warnings.
    The `s2_prod_q` array is loaded in a `generate` loop to avoid Verilator 5.008
    `BLKLOOPINIT` on delayed assignments inside procedural for loops. Width-casting
    fixes in `g6lc_ai_fp_pkg.sv` also cleared
    `verif/regress/ai-fp-mac.py` (FpPipeRegs 1/2/3/5, ~40k scalar transactions).
    Timing impact: adds one outstanding-transaction counter and muxed `sum_*` update
    path in `g6lc_ai_gemm_seq`; the dot pipe itself is a new multi-cycle reduction
    tree whose latency grows with `log2(PeLanes)+4`.
- [ ] Bind descriptor metadata/per-context flush to a real policy consumer and
  PMU; prove tile/bank/tail behavior, then measure real RTL memory traffic.
  Keep host execution, emulator wall time, scheduling models and RTL timing
  separate. Recorded evidence above is scoped/historical, not fresh full-SoC
  sign-off; readiness gates and I3-before-I2 ordering remain unchanged.

## Current phase
**SMT2 × AI attunement:** soft-ladder DI residual + dual-hart topology **and** ai-tensor /
PyTorch staged track (branch **`smt2-ai-tensor-linux`**).
Program spine: `architecture/remaining-upgrade-sequence.md` §0/§4 · residual matrix
`AGENTS-build-platform.md` §5–§7 · live RTL table `architecture/README.md` ·
**soft ladder** `architecture/multi-threading/soft-ladder/` ·
**topology** `architecture/multi-threading/fdt-topology-soft-ladder.md` ·
**AI×SMT track** `architecture/multi-threading/smt2-ai-tensor-linux.md` ·
**multi-threading map** `architecture/multi-threading/README.md` (AI attunement §) ·
**MT harness of record** `architecture/multi-threading/testharness-proxy.md` (proxy-only Spike/soak/peel) ·
**Linux-boot scale** `architecture/multi-threading/linux-boot-scale.md` (OpenSBI × fetch_B combos × envelopes).

### Landed plane (state + priors to retrieve)

| Track | State | Priors / architecture / progress |
|-------|--------|----------------------------------|
| **Zacas AMOCAS.W/D** | `RVZacas` on `cv64a6_server_math{,_v}`, `cv64a6_ooo_server`, `cv64a6_imafdc_sv39`; decode + 3rd-op RF + `amo_alu` + WT/HPDCache/AXI CAS | Spec: `agents/spec/riscv-spec-I-5.9-zacas.html` · `#ext:zacas` · impl row `AGENTS-specs-to-impl.md` (Zacas) · tests `AGENTS-specs-to-tests.md` (mc-stream / gaps) · packages under `core/include/*config_pkg.sv` |
| **Directed multicore suite** | `testlist_mc_stream` — stream, AMOCAS, st-fwd, fence, CAS lock, **CF×stream**, CAS×stream, mispred×stream | `architecture/multi-core/README.md` · `architecture/l2-l3-cache/README.md` · U6/p6 notes in `remaining-upgrade-sequence.md` · `verif/tests/testlist_mc_stream.yaml` · asm `verif/tests/custom/multicore/` |
| **Spike soak** | `stability-regress` + `mc-spo-spike` / `mc-spo-soak` / `kvm-h-spike` | Scripts `verif/regress/mc-spo-{spike,soak}.sh` · suite registry `build-platform/src/config/defaults.ts` · host residual `AGENTS-build-platform.md` §4–§5 |
| **RTL mini golden** | `mc-mini-veri` hard PASS AMOCAS.W/D (no soft-skip); **cataloged** in `defaults.ts` | `verif/regress/mc-mini-veri.sh` · `mini_amocas_{w,d}.S` · suite id `mc-mini-veri` · TB `corev_apu/tb/ariane_tb.cpp` · Zacas impl row |
| **RTL full CRT residual** | imafdc **9/9** + `g6lc64_server_math` L2 **9/9** (DeepSpec STQ); dual-hart-ci residual revalidated (lint soft when host-skewed; dual-park ELF; R3 skippable) | suite id `mc-spo-veri` · `verif/regress/mc-spo-veri.sh` · FSE: `architecture/speculative-execution/` · `agents/guides/AGENTS-speculation.md` |
| **FTQ / frontend** | Mispredict reseed + demand fixes for bare-metal green | Guide `agents/guides/AGENTS-branch-prediction.md` · scaffold `architecture/branch-prediction/README.md` · RTL `core/frontend/{frontend,cva6_ftq}.sv` |
| **Structural FO4** | sparse_ex/frontend residual close @ **2.5 GHz** (screening ≠ STA) | Package `sv-timing/AGENTS.md` · `sv-timing/architecture/MONOREPO-SOAK.md` · `FREQUENCY-CLOSURE.md` · host `AGENTS-build-platform.md` §6.1 / §7 · plan `architecture/build-platform-opensta-from-timing.md` · philosophy §2.8 in `AGENTS-coding-philosophy.md` |
| **R3a dual-hart OpenSBI** | `fw_payload` + WSL SUCCESS; **R3b gate** `r3b-linux-image` (Image external) | `architecture/multi-threading/smt2-bringup.md` · `smt-linux-rootfs.md` · `dts-linux-smt.md` · `software/smt2-linux/` · suites `smt-linux-*` / `opensbi-linux-boot` · `AGENTS-dts-validation.md` |
| **Soft ladder (DI OpenSBI residual scaffold)** | **P0 done** + **I4dn kept**. Default and `PEEL_FDT_GETPROP=1` **SUCCESS**. Combined still `12eb2`. New `mini_fdt_namelen_walk` Spike+Variane **PASS**; `mini_fdt_opensbi_blob` Variane **PASS** — 12eb2 is stock OpenSBI `next_tag` binary, not the reconstructed nest. I4cd/I4ce reverted. Soft getprop stays. | `ITERATION` I4dn · `mini_fdt_namelen_walk.S` |
| **FDT topology plan** | `NrCores`×`NrHarts` (threads/core), stream vs SMT `cpu-map`, issue width non-DT; gates before `/proc/cpuinfo` **and before multi-thread PyTorch** | `fdt-topology-soft-ladder.md` · `ariane-smt2.dts` · `ariane-stream8.dts` |
| **SMT2 × ai-tensor / PyTorch** | Soft pytorch **PASS** (Device virt-card). Fast track live. Multi-thread host workers **blocked** on soft-ladder hold cookie + SL-C + Linux Image. AI CSR banked on SMT. | `smt2-ai-tensor-linux.md` · `multi-threading/README.md` · `ai-tensor/AGENTS.md` · HARD `ai-matrix/hard-tests.md` |
| **Ara / RVV** | Attach + DTS + directed; **VRF/cosim gate** `ara-vector-cosim` (live lmul opt) | `architecture/ara-vector-attach.md` · `agents/guides/AGENTS-vector.md` · `agents/vendor/AGENTS-vendor-ara.md` · `agents/spec/riscv-spec-I-9-vector.html` · suite `ara-vector-path` |
| **H / KVM** | U9 + **H-edge Spike+RTL 3/3** (`kvm-h-spike` / Variane server_math) | `architecture/server-math-hypervisor.md` · remaining-upgrade Phase B · `agents/spec/riscv-spec-II-5.*-hypervisor*.html` · impl Hypervisor row · `verif/tests/custom/kvm_h/` · suite `kvm-h-tests` |
| **`g6lc_qemu` emulation** | **Q1–Q2 landed; Q3–Q9 in progress.** QEMU virt + generated `g6lc-soc` OpenSBI/U-Boot/EDK2/OpenWrt **boot green** (hypothesis). AI DESC/CPL join + virt_ai_card; `ai_host_transport` **unpinned**. **Never Variane evidence.** Snapshot: `architecture/current-stage.md`. Design asks F1–F15: `g6lc_qemu/architecture/RTL_FEEDBACK.md` §2.1. | `architecture/g6lc-qemu/README.md` · `staging.md` · `u-boot-edk2-boot-architecture.md` · package `g6lc_qemu/AGENTS-todo.md` |
| **`g6lc_bios`** | **B0–B52 landed; recovery P0–P2 QEMU-proved (journal + A/B stub protection).** Firmware flash/slot-select, wasm/DOM `RuntimeContext`, and Linux health helper remain open. Never Variane, never `-netdev`. | `architecture/g6lc-bios/README.md` · `g6lc_bios/AGENTS.md` · `g6lc_bios/architecture/PLAN.md` · `g6lc_bios/architecture/KERNEL-RV.md` |
| **U-Boot / EDK2 loader architecture** | **U0/U1/U2 QEMU virt green; E0–E3 QEMU virt green; E1 RTL SEC-ABI green (E2/U2 not RTL).** `g6q fw build --loader edk2` wraps upstream `OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc`. Remote `edk2-stable202511` + BaseTools + user-local `iasl` **OK**; CODE 8 MiB / VARS 768 KiB. **Isolation:** post-sync B with SL-W `wbuffer_all` SIGSEGV'd `mini_must_pass` (rc=139, t=275). HEAD dcache `work-ver-smt2-fw64-B-headiso` oracle green, `mini_edk2_sec` **PASS**, `mini_stq_flush_fwd` FAIL (gate-6). IQ width casts were not the crash. SL-W crash-fix (unsigned fixup index + power-of-two `WbufferAllDepth`) **`work-ver-smt2-fw64-B-slwfix` oracle green, `mini_edk2_sec` PASS** (6.5 s); `mini_stq_flush_fwd` **PASS** (`slw-gate6-noprop`, no sim probes): checked-miss ACK pushes fixup, miss keeps the entry, same-PA coalesce. E2 no longer gated on this mini. `apply_edk2_pflash` floors `-m` to 4 GiB and prefers generic-virt OpenSBI (`out/fw/fw_dynamic-generic-virt.bin`, no `FW_FDT_PATH`) over a g6lc-FDT `fw_dynamic` (that hung silent on virt). CpuDxe SATP green after `RiscVInterrupt.S` `s0` smash fix (`g6lc_qemu/patches/edk2-riscv-sstatus-no-stack.patch`). Smbios `INST_ACCESS_PAGE_FAULT` was `SupervisorModeTrap` `addi sp,-140` vs C `UINT64[35]` (xpack PP default ilp32); trap-frame ×8 + `PP_FLAGS -mabi=lp64` → `addi sp,-280`. QEMU 8.2.2 virt DEBUG: `SATP mode 10`, Bds, **UEFI Interactive Shell v2.2**. Virtio ESP `FS0:` + `BOOTRISCV64.EFI` (`E2-VIRTIO-ESP`) via `g6q run --loader edk2 --machine g6lc-virt --drive fat:rw:out/loader-run/esp`. E3 OpenWrt EFI stub green on EDK2. **U2 green**: `g6q run --loader u-boot --os openwrt` → U-Boot `bootefi` → `Linux version 6.6.93`; `--smp 2` → 2 CPUs and `procd`. **U3a/U3b/U3-FIT/U3-SPI green**: `--machine g6lc-soc` → `bootefi` DRAM PE (procd) and `bootm` of `g6lc-efi.itb` from NOR (`CPUINFO-DONE`). **U3-Shell virt green**: `--os efi-shell --machine g6lc-virt` → `UEFI Interactive Shell v2.2`. Soc SPI Shell `StartImage` hangs; soc `bootefi hello` ASCII green. **E2-PCI**: EDK2 Shell `pci` on GPEX (root complex) vs `virt_ai_card` (endpoint stand-in); `ai_host_transport` unpinned. SD still open. `mini_fdt_next_tag_lbu` PASS (`slw-fdt-regress`). | `architecture/g6lc-qemu/u-boot-edk2-boot-architecture.md` · `architecture/dcache-ack-before-check.md` §2.1 · `g6lc_qemu/AGENTS-todo.md` · `g6lc_qemu/pins.toml` |

Standing disciplines remain active (`AGENTS.md` §0.4–§0.6). Keep
`AGENTS-specs-to-{impl,tests,coverage}.md` in lockstep on ISA-visible / suite edits
(Zacas already **partial W/D** in the working-tree maps).

### Practical next (edge of implementation — ordered)

Do **not** reopen soft-skip CAS or re-litigate green mini RTL unless a hard fail reappears.
Isolation ladder (narrow → wide): `mc-mini-veri` → `mc-spo-spike` → `mc-spo-veri` → OpenSBI/Linux
(see also diagnosis intent in `AGENTS-build-platform.md` residual soaks;
`verif/regress/AGENTS-regress-scripts.md`).

**Active edge (residual scaffold + SMT topology) — build-platform home, RTL-max:**

Phases: **P0** platform register → **P1** directed mini → **P2** B1 RTL → **P3** osbi climb/peel → **P4** retire soft → **P5** B2 policy only → **P6** generalize.
Full map: `architecture/multi-threading/soft-ladder/README.md`.

**Resume order (review pass 2026-08-29).** The O3 residual is **not a fetch class** and the S1
table already proves it — so the next three items are ordered off that fact, not off another G1\*
letter: **SL-W** (D$ ACK-before-check) → **AI-2** (config-integrity on `g6lc64_server_math_v`, the
Linux-boot bar package itself) → **SL-R**(1) (`geo()` wiring). Both of the first two are now
**specified rather than open-ended**: SL-W has a micro-arch note
([`architecture/dcache-ack-before-check.md`](architecture/dcache-ack-before-check.md)) with the
untried design axis and six acceptance gates, and AI-2 has a diagnosed root cause plus a 2-line fix
(pin `ACCEL` to issue port 0 via the unused `fus_busy_t.accel` field). Neither was landed: SL-W needs
proxy evidence, and AI-2 touches the dual-issue throttle that `core-fetch/SPEC.md` §9.6 freezes until
R6–R11. The L1–L4 module extract likewise stays gated behind the R4 pin (`SPEC.md` §8).

Landed in that pass, inspection-verifiable only: the `core/fetch_B` duplicate drop (SL-R) and the
`VoidKeepEn` / `VoidKeepTag` naming (SL-W) — both uncompiled or bit-identical, so neither needs a
re-soak. **Nothing in that pass is claimed green:** the host had no `verilator` and no
`TH_REMOTE_HOST`, and evidence is proxy-only (`AGENTS.md` §0.8).

| # | Item | Phase | Status / next action |
|---|------|-------|----------------------|
| **SL-0** | **Register residual suites in build-platform** | P0 | **Done.** Optional `soft-ladder-di` + `soft-ladder-osbi` in `defaults.ts` (not `defaultSuites`); diag `diag-soft-ladder-paths`; maps in `AGENTS-specs-to-tests.md` / `AGENTS-build-platform.md` / `AGENTS-regress-scripts.md`. |
| **SL-P** | **Proxy-only MT evidence** | B3 | **Normative.** Spike ISS, Variane soaks, peels, TRACE, I4dp 200M-cap: `verif/regress/remote/testharness_proxy.py` only. S1 battery: `verif/regress/remote/s1-linux-boot-regress.sh`. SYNC includes pin / default-mk / peel_both (not refused held). Classify from `runs/<tag>/run-*.log` (rc=255 ≠ fail). Added `di` subcommand to `testharness_proxy.py` for parallel remote directed-mini regression (compile locally, run remote harness with thread pool). Plan: `architecture/multi-threading/testharness-proxy.md`. I4dn kept; I4cd/I4ce/I4cf stay reverted. |
| **SL-N** | **Linux-boot scale (named envelopes)** | P6 | **Plan landed.** [`linux-boot-scale.md`](architecture/multi-threading/linux-boot-scale.md): OpenSBI O0–O8, `smt_legacy` oracle only, fetch_B **four combos** (no fifth, no `core/frontend` churn). Live bar: `_v` N=2 T=2 V=1 and `ooo_server` N=4 T=2 I=4 (I4dp). smt2 still lacks natural FDT, `RVH`, RVV, `NrCores>1`. `NrHarts>2` blocked on `CVA6_MAX_SMT_HARTS=2` + PLIC `S≤8`. Do not merge packages. |
| **SL-A** | **iter-013 / S4 fetch_B/IQ leftover — CLOSED as IAF/test-address** | P1–P2 | **Closed (2026-08-30).** The `mini_fdt_nt_ptr0` failure was an instruction-access fault, not a fetch_B/IQ leftover bug. The FDT stub at `0x8001e030` is outside the `g6lc64_smt2` execute region (`0x80000000` length `0x1e000`). Fixed by moving `.text.fdt` to `0x8001d000` in `verif/tests/custom/multicore/mini_fdt_nt_ptr0.{S,ld}`; `mini_fdt_nt_ptr0` now passes on `work-ver-smt2-fw64-B` and in the remote `di` suite. No RTL change. The historic OpenSBI `mepc=0` `sbi_hart_hang` path remains a separate residual if `fdt_next_tag` jumps to a non-execute address. |
| | **Linux boot greens to preserve (I4dp)** | P3 | `g6lc64_server_math_v` (NrHarts=2) and `g6lc64_ooo_server` (4×2 = **8 logical harts**) both reach harness `tohost = 0` at the 200M-cycle cap via the proxy on `ovh_calltorch`. 8-hart payload path: `corev_apu/bootrom/ariane-ooo-server.dts` + `G6LC_DTS`/`G6LC_DTB`/`G6LC_SMT2`/`OPENSBI_SRC` in `build-opensbi-smt2.sh`; `tohost` `0x80041730`. Harness tohost is **not** soft-ladder SUCCESS — classify from `runs/<tag>/run-*.log`, since a long `run` can return rc=255 on SSH drop. Any B1 candidate must keep both. |
| | Bisects **all negative** | P2 | Dual-commit; STQ-nofwd; force SI; ALU cancel-exempt — same pin; **reverted**. |
| | Directed (P1) | P1 | **5/5 green** FDT shape + `mini_fdt_next_tag_lbu` on fw64/slfix. |
| | **P2 RTL + TB** | P2 | **Landed through I4ay:** I4au cookie green; I4ax/y keep `lui t0`/`auipc t1` (did not fire). I4av/w rewind **reverted**. TB hangpc; **`work-ver-smt2-slfix`**. |
| | **Oracle discipline** | P2 | Pin md5 **`bc7ed11dab17454fd147e4927ba07fef`** (backup `*.pin-bc7ed11d.elf`). Held: rebuild with `rebuild_held_from_pin.sh` only — **do not** `mk_plat_skip` from current diag (`8169b747…` → cold-regress `plat_hc=80`). |
| | **Cookie chase I4f–g** | P2 | Cave OK. Stock: **`sbi_hart_init` CSR probes**. Soft-skip → platform **`c.jalr a5`** (irqchip@`17e0`→FDT). **Hold green:** `SOFT_HART_INIT`+plat peels → **`51b1babe`**. |
| | **Track hold** | P2 | **`hold` dual-confirm green** held `8b6b310e…` on slfix (`plat_hc=2` BANR). `mini_csr_expected_trap` + **`mini_csr_pmp_probe` PASS**. |
| **Next** | P1 | OpenSBI 7ba still Branch (hangj 766 is leftover jal **bp_valid**; TRACE n7b8@20431 then n7c0@20438 then n7ba@20440; later_br_01 MINI-FAIL FDT 23 @1184 G1iz class — do not re-land; sib8_fetch MINI-FAIL FDT hang @400000 G1jd class — do not re-land; hi8_npc_fetch MINI-FAIL lottery 4 @362 G1ja / FDT 57 @445 G1jd — do not re-land; lo11_npc00 MINI-FAIL sib P0 fail 1 @407 / FDT 0x10 @423 — do not re-land (jalr-target `[2:1]==11`); lo_pc_npc00 HOLD-FAIL plat_hc=80 mepc 0xb0/2 — do not re-land; ljx0_off / ljx0_pc / ljx0_bp hygiene; sib_lo_s2 MINI-FAIL lottery 2 @420 / FDT 50 @545 (G1jp) — do not re-land; lo_ld_stay HOLD-FAIL 51b1c001 — do not re-land; lo_ld_lo11 hygiene; hi8_lo11 MINI-FAIL FDT 57 @445 (G1jd) — do not re-land; load_flush_next16 hygiene; ld_until_01 MINI-FAIL FDT 106 @409 (G1lm) — do not re-land; leftover_off_npc00 hygiene; leftover_slot0_off_npc00 MINI-FAIL sib printed 4 @448 / lottery hang @400000 / FDT 17 @413 — do not re-land; load00_vs_off16 hygiene; leftover_nx8_npc00 hygiene; leftover_hi8_s2 MINI-FAIL FDT 24 @201516 (G1hu) — do not re-land; load00_vs_lj hygiene; leftover_lo8_s2 hygiene; load00_lo8_s2 hygiene; slfix `2db4dea7`/`f5f908e4`); idle_sib16 / idle_load_sib HOLD-FAIL 51b1c001 G1jw class — IDLE user[33] into G1hj closed; leftover_blocks_01 + G1hj consume-PC-match + is_mispredict spare + stash_keep16 + stash_keep_pc + load_flush_keep + plus2_stay + line_hi8_stay hygiene — G1hj never captures 7ba; slfix `55aa90c6`/`dad4695c` cookie t=83968). P3 @518 P4 @597. skip-range HOLD-FAIL. c.jalr skip-arm HOLD-FAIL. skip_next MINI-FAIL. Not G1mg. Not G1gn. Not G1iz/G1jh/later_br_01. Not G1jb. Not idle_sib16. Not idle_load_sib. Not sib8_fetch. Not hi8_npc_fetch. Not lo11_npc00. Not lo_pc_npc00. Capture 7ba bits from valid 7b0 16B sibling without IDLE user[33] and without rewriting leftover fetch. G1mf kept (SB result-valid 00 LOAD into g1lo; cookie t=83968; 7ba unchanged — last SB 00 LOAD is not 7b0, or 7b0 is not yet sbe.valid; slfix `64f6c38e` / `850ebd78`). G1mf kept. G1me kept. G1md kept. G1mc kept. G1mb kept. G1ma kept. G1lz kept. G1ly kept. G1lx kept. G1lw kept. G1lv kept. G1lu kept. G1lt kept. G1ls kept. G1lr kept. G1lq kept. G1lp kept. G1lo kept. G1ln kept. G1lm MINI-FAIL. G1ll kept. G1lk reverted. G1lj kept. G1li kept. G1lh kept. G1lg kept. G1lf kept. G1le kept. G1ld kept. G1lc kept. G1lb kept. G1la kept. G1kz kept. G1ky kept. G1kx kept. G1kw kept. G1kv kept. G1ku kept. G1kt kept. G1ks kept. G1kr kept. G1kq kept. G1kp kept. G1ko kept. G1kn kept. G1km kept. G1kl kept. G1kk kept. G1kj kept. G1ki HOLD-FAIL restored G1kh. G1jo keep (replay !kill_s1 at npc 00 fired; cookie t=83968). Fetch-steal at npc 01 closed (G1iz/G1jc/G1jg/G1jh). Sibling [31:16] any-stash closed (G1jj). IDLE sibling-pair into G1hj closed (G1jw). All-npc-00 kill_s2 closed (G1jp). npc-00 flush_i kill_s1 closed (G1jr/G1js). G1fx npc +2 all-compressed closed. G1lx/G1lw/G1lv/G1lu/G1lt/G1ls/G1lr/G1lq/G1lp/G1lo/G1ln/G1ll/G1lj/G1li/G1lh/G1lg/G1lf/G1le/G1ld/G1lc/G1lb/G1la/G1kz/G1ky/G1kx/G1kw/G1kv/G1ku/G1kt/G1ks/G1kr/G1kq/G1kp/G1ko/G1kn/G1km/G1kl/G1kk/G1kj/G1kh/G1kg/G1kf/G1ke/G1kd/G1kc/G1kb/G1ka/G1jz/G1jy/G1jx/G1jv/G1ju/G1jt/G1jq/G1jo/G1jn/G1jm/G1jl/G1jk/G1ji/G1jg/G1jc/G1jb/G1ix/G1iw/G1iu/G1it/G1ir/G1iq/G1ip/G1io/G1il/G1ik/G1ij/G1ii/G1ih/G1ie/G1id/G1ic/G1ib/G1ia/G1hz/G1hy/G1hx/G1hw/G1hv/G1ht/G1hs/G1hr/G1hq/G1hp/G1ho/G1hn/G1hm/G1hl/G1hk/G1hj/G1hi/G1hh/G1hg/G1hf/G1hd/G1hc/G1hb/G1ha/G1gy/G1gx/G1gw/G1gu/G1gs/G1gq/G1gp/G1gm/G1gl/G1gk/G1gj/G1gi/G1gh/G1gg/G1ge/G1gd kept. Do not re-land G1ew/G1es/G1eo/G1eh/G1ec/G1eb/G1dr/G1fb/G1fc/G1fk/G1fm/G1fx/G1fz/G1gf/G1gn/G1go/G1gr/G1gt/G1gv/G1gz/G1he/G1hu/G1if/G1ig/G1im/G1in/G1is/G1iv/G1iy/G1iz/G1ja/G1jd/G1je/G1jf/G1jh/G1jj/G1jp/G1jr/G1js/G1jw/G1ki/G1lk/G1lm/lo11_npc00/+8 hold. Do not lower `SMT_COLD_EXCL`. Soft getprop stays. Not G0/W1/G6/G1i/G1z/G1aa/G1ab/G1ac/G1af/G1aj/G1ak/G1ap/G1as/G1at/G1ax/G1bb/G1bd/G1bi/G1bk/G1bn/G1bo/G1bq/G1br/G1bs/G1bt/G1bu/G1bw/G1by/G1bz/G1cd/G1ce/G1cf/G1cg/G1ch/G1cj/G1ck/G1cl/G1cn/G1co/G1cu/G1db/G1dg/G1dr/G1dw/G1dy/G1eb/G1ec/G1eh/G1eo/G1es/G1ew/G1fb/G1fc/G1fk/G1fm/G1fx/G1fz/G1gf/G1gn/G1go/G1gr/G1gt/G1gv/G1gz/G1he/G1hu/G1if/G1ig/G1im/G1in/G1is/G1iv/G1iy/G1iz/G1ja/G1jd/G1je/G1jf/G1jh/G1jj/G1jp/G1jr/G1js/G1jw/G1ki/G1lk/G1lm. **Do not start I4cg.** Do not land D$ fill. |
| | Priors | | g1gi–gm peel `7e280d82` / `a0d82504` · jal-x0 squash `cb3802ff` / `72829707` · leftover slfix `7af3e3c8` / `2707526e` · E9 `e396f136` / `47c636b1` · E4 FE `9aa3360c` / `8fe2d083` · E4 `8d0ee26d` / `27221419` · E8 `e87ba20c` / `e673a237` · E7 `c162608c` / `b7faf8e8` · E6 `6f90de0f` / `4412d136` · G1mf slfix `64f6c38e` / `850ebd78` · G1me `dce70345` / `b810edbb` · G1md `5f743837` / `656c7884` · G1mc `9b9e0aa0` / `1af85acb` · G1mb `ff2c6aaf` / `049e7041` · G1ma `99feee68` / `6cb66364` · G1lz `24bca058` / `d9bb33dd` · G1ly `672f5c89` / `2e9c569b` · G1lx `76330b85` / `0ed5c1eb` · G1lw `e16fd998` / `8b0e7f35` · G1lv `9de0cf5c` / `2c5b0389` · G1lu `ba656512` / `7e270547` · G1lt `0c7273bb` / `720bd125` · G1ls `28430b85` / `c6ecb315` · G1lr `e8df2ac5` / `aac00289` · G1lq `64cd8bd2` / `edde23b1` · G1lp `6f9629d0` / `8417ade6` · G1lo `7aa89110` / `80c2a735` · G1ln `f7f9b8b0` / `e15f1291` · G1ll `93a79414` / `cb4dc600` (G1lm reverted) · G1lj `673cd1d8` / `cf66549f` (G1lk reverted) · pin `bc7ed11d` |
| **SL-W** | **D$ ACK-before-check — general fix for the L1-stale class** | P2 / S1 | **Queue RTL landed; default disabled (`WtDcacheFixupDepth=0`), PMU wired, full-queue wbuffer hold in place.** Post-ACK fixup queue lives in `wt_dcache_wbuffer.sv` (parameterized by `CVA6Cfg.WtDcacheFixupDepth`), explicit `inv_req_o`/`inv_ack_i` port through `wt_dcache`→`wt_dcache_mem`, shared tag-read and word-write port priority `check_wr > fixup retire > ACK writeback`, refill ordering via `wr_cl_vld_d/q`, full-queue bypass/invalidate fallback, and `VoidKeepEn`/`VoidKeepTag` containment preserved for depth=0. PMU events `DCACHE_WBUF_VOID_ACK/FIXUP_WRITE/FIXUP_INVAL/FIXUP_FULL` wired to `perf_counters.sv` group 5 (`MHPMGrpSLW`). Core lint PASS (imafdc 265 / cv32a65x 58 warnings); smt2 lint (optional) clean with `WtDcacheFixupDepth=2` and `WtDcacheFixupVoidKeepEn=0` except the two pre-existing Verilator internal `Different default drivers` on `we_gpr_commit_id`. Gate-6 run (`g6lc64_smt2` with `WtDcacheFixupDepth=2` and `WtDcacheFixupVoidKeepEn=0`) on `ovh_calltorch` builds clean (0 warnings, 0 errors). `wt_dcache_mem.sv` fixup forwarding was fixed: `wbuffer_rdata`/`wbuffer_ruser`/`wbuffer_be` now use `wbuffer_all[wbuffer_hit_idx]` instead of `wbuffer_data_i[wbuffer_hit_idx]`, so fixup-queue entries are selected correctly when both wbuffer and fixup contain a hit. `mini_fdt_next_tag_lbu` now **PASS** (the L1-stale `0x8` vs `0x4` signature is resolved). `mini_fdt_lenp_sw`, `mini_csr_pmp_probe`, `mini_amoadd_w_spin`, `mini_csr_expected_trap`, `mini_dual_cmv_s3` also pass. A per-word `wbuffer_collision` mask in the miss unit was tried and reverted: it stalls FDT paths. Complete-word `wbuffer_fwd_hit_o` (`wt_dcache_mem` → every rd-port ctrl) is the replacement axis: a full XLEN word in wbuffer/fixup completes the load as a hit so a miss refill cannot overlay stale DRAM. Not yet proxy-run on `mini_stq_flush_fwd` (last FAIL was exit-code at ~`0x800000b0` before this landing). Remaining FDT/stq tests (`mini_fdt_s2_nest`, `mini_fdt_check_prop_nest`, `mini_fdt_a0_is_fdt`, `mini_fdt_namelen_walk`, `mini_fdt_nt_frame32`, `mini_fdt_nt_stock`, `mini_fdt_nt_cpus`, `mini_stq_alias_jal`, `mini_fdt_nt_osbi`) timeout or exit. SL-W gate-6 is partially validated; `mini_stq_flush_fwd` is the next narrow residual. Local WSL Verilator build (5.020) hits an internal fault after duplicate-module warnings, not an RTL error — this is the Debian 5.020 behavior the Makefile already warns about; a pinned 5.008 build or the remote proxy is needed. The S1 pin class is `wt_dcache_wbuffer` freeing a TX on a write ACK that races its own tag check: the clean bytes never reach the L1 data array, a stale way survives, and a later load reads pre-store data (`s1-tight-hold-trace`: `g1ao_hold` dead, DRAM=`lenp`, 2nd `ld s3` retires `0x12b2a`). Kept containment is `nackinv` + a **workload-scoped** VOID-keep window, now named `VoidKeepEn` / `VoidKeepTag` in `wt_dcache_wbuffer.sv` (header note 3 + declaration; bit-identical rename, `VoidKeepEn=0` restores stock upstream ACK handling — **no re-soak needed**). Every address-agnostic variant is logged **reverted**: `ackinv`, `voidchk2`, `keep`/`keepv`/`keep1..7`/`keepnz`/`keepcoal`/`keeppend`, `snoopd*`, `wr1`, `nackhit*`, `nack2*`. **Micro-arch note landed:** [`architecture/dcache-ack-before-check.md`](architecture/dcache-ack-before-check.md) — it classifies every logged tag by *which* mode it broke, names the one untried design axis (a **post-ACK L1 fixup queue** owning no write-buffer state, ordered against refill, falling back to *invalidate* when full so correctness stops depending on queue capacity), records why capacity/TTL sweeps cannot work, and adds **gate 6: pin + hold still green with `VoidKeepEn = 0`** as the test that a fix is general. The split it turns on — **(a) staleness**, an ACK'd-but-unchecked word must either land in L1 or invalidate that line; **(b) forward progress**, holding words keeps `txblock`/`valid` set and starves `wr_ack` / `empty_o`, which is what hangs h0 in the FDT_PROP walk (`s1-h0-keep-hang-trace`: not an LSU stall, `nextoff=0` walk never ends). A fix must close (a) without re-entering (b); note also that (a) is a **write-through coherence** defect that outlives this firmware. **Gates (proxy-only):** pin `bc7ed11d` cookie `51b1babe`, hold `8b6b310e` cookie + BANR, `mini_fdt_*` battery, and I4dp `_v` + `ooo_server` 200M `tohost=0`. Do **not** widen the window as a substitute (0x80040–0x80045 already reverted). Priors: `linux-boot-scale.md` S1 · `wt_dcache_wbuffer.sv` note 3. |
| **SL-R** | **Fetch-plane compartmentalization** | P6 / cleanup | **Duplicate drop landed.** `core/fetch_B/` carried 16 uncompiled predictor copies (`bht`, `bht2lvl`, `btb`, `ras`, `g6lc_bp_*`, `g6lc_ftq`, `g6lc_fdip`, `g6lc_loop_buffer`; 2043 L) on no flist, no script and no `REUSE.toml` entry — byte-identical to the compiled `core/frontend` copies apart from CRLF and mojibake in 6 of them, i.e. a silent "edited the wrong copy" trap. Removed; the directory is now exactly the six `Flist.fetch_B` files (**2364 L**). Mirrors the earlier `core/smt/` drop; all five flists re-checked to resolve. **Landed (1):** `fetch_geo_t` / `geo()` now drives the synthesized supply (`frontend.sv`, `instr_realign.sv`, `instr_queue.sv`) and `g6lc_fetch_dbg.sv` as a bit-identical localparam substitution. Added `log2_slots` and `hart_idx_w` to `fetch_geo_t` so `IdxW` and `HidW` share the same source. `VALUES.md` §3 updated. Build-platform `diag run {core,smt2,residual,ooo,apu}` PASS path/cap checks; Verilator lint skipped (`verilator` not installed locally). Ungated until `tools install sim` or proxy. **Open (2):** the L1–L4 extract into `g6lc_fetch_{align,window,order,redirect}` stays **gated behind the R4 pin** (`SPEC.md` §8, `core-fetch/README.md` status) — do not start it while S1 is open. Priors: `core-fetch/{README,SPEC,VALUES}.md` · `Flist.fetch_B`. |
| **SL-B** | Peel soft getprop + real printf | P3–P4 | **Pin printf dual-confirm.** Getprop natural. Pin peel-printf `39b9dcc2` + plat-ops `7d670268` cookie **`51b1babe`+`51b1d000` t=131072**. Hart-only leftover-RVI `@12ad8` (FDT_PROP `addi@12ad6` straddle; `a0=0x82200638`). BANR + `SOFT_HART_INIT` stay on held `8b6b310e`. Do not replace pin/held. |
| **SL-C** | Topology truth (smt2) | P6 / topology |
|| **SL-X** | **SMT2 product closeout / FDT compensation** | P6 | **Open.** Cookie green (SL-A/B/C) is a gate, not product completeness. Track and retire: `SMT_COLD_EXCL`/`SMT_FIRST_ACT_EXCL`, dual-commit same cycle, banked BHT/BTB, FP/vector register banking, idle-thread clock gate, `Zawrs`/wait-for-peer, `SMT2` default SKU, and FDT `smt,*` compensation properties. Central checklist: `architecture/multi-threading/smt2-product-closeout.md`. **FDT compensation retired (landed).** The `smt,*` node is now documentation only; enforcement moved from firmware run time to DTB build time in `software/smt2-linux/scripts/dts_to_dtb.py` (`CLOSEOUT_ISA_TOKENS`; fails the DTB build if a `cpu@` advertises a closed-out token, `--strip-closeout` to mutate a temp DTS instead, `--no-closeout-check` to skip). Deleted `scripts/patch_opensbi_smt_compensation.py`, dropped its call from `build-opensbi-smt2.{sh,ps1}`, and restored vendored `platform/generic/platform.c` to stock (147 inserted lines removed; only the `patch_opensbi_g6lc_clint.py` CLINT/PLIC edits remain). Three reasons: (1) **dead** — `ariane-smt2.dts` never advertised `zawrs`; (2) **actively broken** — the rewriter called `sbi_malloc()` from `fw_platform_init()` (`fw_base.S:115`), ~250 instructions before `sbi_init`→`sbi_heap_init` (`fw_base.S:367`), so `hpctrl` was zeroed BSS and `sbi_list_for_each_entry` dereferenced `NULL+0x18` → `fault_load mtval=0x18` → `_start_hang`; this was the OpenSBI-on-QEMU hang; (3) **cost a source-anchor fork** of upstream. Also corrected the `smt,zawrs` semantics: `core/decoder.sv:315-334` **does** decode `WRS.NTO`/`WRS.STO` under `ZawrsEn` and retires them as `WFI` (conforming — Zawrs lets `WRS` terminate for any reason); what is open is only the SMT wait-for-peer wake plus the "no `sbi_send_ipi_and_wait`" firmware policy. **Residual conform item:** the B1 generated DTB derives `zawrs` from `ZawrsEn=1` and so advertises it, while the handwritten `ariane-smt2.dts` conservatively omits it — reconcile via `g6q conform` capability `wait-on-reservation`, do not paper over it. | **Side `ipi-tab` dual-confirm** `3314827d`: cookie **`51b1babe`+`51b1d000`** and **`sp1=0x80045f10`** (`s3-ipi-tab6`/`6b`). In-line MSIP after cookie `sw`. Pin/hold still babe `sp1=0` (no MSIP). Not VOID-keep widen. Not G1dg. Do not replace pin/held. |
| **S4** | `_v` Image / I4dp hygiene | P6 | **R3b SKIP**. Execute-uncached + BHT + **FtqDepth=0** + **RAS=16** + **`bp_fire&&cf_consumed`** + **same_win `bp_pend` misp-retarget** (ttl=7). L2 **`live[]`** + **`slot_keep_link`**. fetch_B IQ **DEPTH=8**. **`leftover_retake`**. **leftover-complete slot0 push** (I7 exception; hygiene PASS including osbi). **`replay_addr = icache_vaddr_q`** (rest PC on slot0 push). **Leftover jal Jump (G1do B)**. **`leftover_update` kill_s1**. fetch_dbg **contiguous-run** SVA. **12c56 IAF closed.** **12958 illegal closed.** 8M: **`plat_hc=4` `coldboot_done=1`**. WFI `@eef4` is **`sbi_hart_hang` after `sbi_trap_redirect` failed (-2)**; mtvec t=2456818 ra=`12994` **mepc=0** (fetch/jump to 0, cause>11). Bare TB has a bootrom at 0, so the exact `mepc=0` class is reproduced via `soft-ladder-opensbi-soak.sh` with `PEEL_FDT_NEXT_TAG=1` (natural `fdt_next_tag` hangs without `0x51b1babe`). Directed mini `verif/tests/custom/multicore/mini_fdt_nt_ptr0` reproduces the same fetch_B/IQ leftover with `tohost=122928` (`mepc` lower 32 = `0x1E030`, `ra=0x80012994`) on the stale `work-ver-smt2-fw64-B` binary (2026-08-25). A fresh rebuild (`work-ver-smt2-fw64`, Verilator 5.008) from current source with the stock `common/link_verilator.ld` appeared to pass `mini_fdt_nt_ptr0` (`tohost=0`), but that ELF does not place `offset_ptr`, the `c.jr a0` and the FDT at the S4 fixed VAs and therefore does not exercise the residual. Re-linking with `verif/tests/custom/multicore/mini_fdt_nt_ptr0.ld` (the intended S4 layout) on the same fresh binary (`work-ver-smt2-fw64-B`, byte-identical to `work-ver-smt2-fw64`) still fails with `tohost=122928`. The S4 `c.jr a0`/`fdt_offset_ptr` residual is therefore **reproducible on current source**, and the stale-binary caveat is removed. OpenSBI `PEEL_FDT_NEXT_TAG=1` on the fresh build still `CLASSIFY=FAIL`, hanging at `npc0=0x80004a50` (`plat_hc=80`, `coldboot_done=0`, ~1M cy) rather than the historical `mepc=0`; the jump-to-0 class may have shifted or the mini catches a narrower form of the same FDT-walk/redirect issue. leftover_drop hold **MINI-FAIL**. leftover_drop replay_addr **SIGSEGV**. pipe_keep **MINI-FAIL**. leftover_replay_hold **MINI-FAIL**. stale_ret_ok **SIGSEGV**. redirect_pend take **MINI-FAIL**. Not G1aa. Not I4v. Pin `bc7ed11d` kept. Landed `d05660170`. |
| **SL-D** | Stream plane vs SMT | P6 | Orthogonal stream8 (`N=2,T=1,I=1`); recover layer 2 off. Do not merge with smt2 DI until FDT trusted. Stream I=2 / RVV / H: `CONTRACT.md` §6 (Phase 4b; AI-2; §6.5 `RVH` on smt2 is package+DTS+H-edge, not G1\*). |
| **SL-E** | Optional DTS generator | later | Third topology / N>2 stream forces generator (`CONTRACT.md` §8.3). All-feature + `NrCores` scale: union soak per named envelope, not G1\* re-read. |
| **SL-F** | **Fetch_B unaligned I$ data alignment** | P2 | **Proxy build done; fix does not fully resolve residual.** The pre-shift removal was reverted to the original `frontend.sv` pre-shift contract; the fetch `leftover_branch_bp_fire` is the landed fetch_B change. Remote B-harness (`work-ver-smt2-fw64-B`, 12-thread, Verilator 5.008) builds clean and DI is 12/16 best pass but flaky; the remaining failures are not a fetch pre-shift issue. Trace of `mini_fdt_next_tag_lbu` points to a **scoreboard/issue/branch ordering** problem around `c.addi16sp` + `c.sdsp`/`c.ldsp`/`c.jr` at 2-byte aligned function boundaries. OpenSBI `PEEL_FDT_GETPROP=1 PEEL_FDT_NEXT_TAG=1` still fails at `npc0≈0x800138a8`. See `architecture/multi-threading/soft-ladder/b1-rtl-residuals.md` §Fetch_B unaligned I$ data alignment. |
| **SL-T** | **SMT2 × ai-tensor / PyTorch** | parallel + after SL-C | **Active on `smt2-ai-tensor-linux`.** Driver: `smt2-ai-tensor-track.sh` (`fast`→`di`→`hold`→`peel`→`dual`→`tensor`→`mt-soft`→`hard`). T4 soft pytorch **green**. T5 dual workers need SL-C + Image. AI CSR banked. Map: `smt2-ai-tensor-linux.md`. |

Soft-ladder SUCCESS = trapdump **`51b1babe` only** (not harness tohost SUCCESS) — suite metadata.
Harness preference: **`work-ver-smt2-slfix`** (iter-013 / S4) for hold/cookie; `fw64` is PEEL-pin reference only.
Oracle: `SOFT_LADDER_SKIP_BUILD=1`; pin md5 **`bc7ed11dab17454fd147e4927ba07fef`**. Holding cookie: `SOFT_LADDER_ELF=software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf` or rebuild with `SOFT_HART_INIT=1`.

### 2026-08-31 bootrom / DI validation residual

- Fixed `core/cache_subsystem/g6lc_icache.sv` active-region non-convergence: use registered `vaddr_q` for cache index, MMU/PMP request, and I$ response address; remove same-cycle `dreq_o.ready` from the `READ` hit path; gate hit/refill output with `kill_s1` instead of `kill_s2` to break the `vaddr_d → cl_index → cl_hit → dreq_o.ready → vaddr_d` combinational loop through `frontend.fetch_address`/`kill_s2`/`spec_req`. Added `boot_addr_i` input and reset `vaddr_q` to it. B flavour builds on `ovh_calltorch` with **0 warnings / 0 errors**.
- Fixed `corev_apu/bootrom/gen_rom.py` packed-array word order and regenerated `bootrom.S` with extra nops and a `fence` before `jr s0` to separate dependent `slli`/`jr` and drain the pipeline. `soft-ladder-build-harness.sh` regenerates the bootrom before Verilation.
- Rebuilt `work-ver-smt2-fw64-B` (B flavour) clean on `ovh_calltorch`.
- Implemented a `commit_stage.sv` FDT-compensation filter for `x8`/`x1`/`x10` unaligned/page-0 ALU writes (`G1lc/I4as/I4cc`) so the bootrom `li s0,1; slli s0,1,31` now produces the `0x80000000` jump target; bootrom `jr s0` now reaches DRAM `_start` (`npc0=0x80000000`) for both DI and OpenSBI images.
- OpenSBI soak (`fw_payload_r3a_c15_plat_skip.elf`) still **CLASSIFY=FAIL**, but the failure signature has moved: the bootrom completes and OpenSBI runs until `mepc0=0x8000a9a8`, `mcause0=0x2`, `mtval0=0x693af0f`, `wfi0=1`, not the earlier `npc0=0x1004c` `_hang` at `wfi`. This points to a residual in the SMT2 issue/RF/forwarding or commit path after the bootrom, not a pure bootrom stall. Same symptom reproduced on `work-ver-smt2-slfix` and `work-ver-smt2-fw64-legacy`.
- Remote DI suite now runs through `verif/regress/remote/testharness_proxy.py di` in **consecutive single-worker mode** with a pre-flight `_no_overlap_guard`: it refuses to start if any `Variane_testharness` or `soft-ladder` process is already running on the remote host. Overlapping DI runs are the root cause of flakiness seen earlier (e.g. `mini_fdt_lenp_sw` failing only when two harnesses ran concurrently).
- **Methodology turn (2026-08-31, second pass).** The three reasoning documents —
  [`AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`](architecture/multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md) (foundation),
  [`AGENTS-g6lc-opensbi-dev-heuristics.md`](architecture/AGENTS-g6lc-opensbi-dev-heuristics.md) (method) and
  [`AGENTS-smt2-opensbi-dev-logics.md`](architecture/multi-threading/AGENTS-smt2-opensbi-dev-logics.md) (instance) —
  name the previous pass's own changes as the live failure instance (workflow §9.2, heuristics H6 retrospective).
  Acted on rather than argued with. Work moved **left** on the feedback-latency ladder (L6/L7 → L0/L1/L2/L3)
  and the two red lines were reverted:
  - **Reverted `core/commit_stage.sv` commit value filter** (§E "drop `x8` unless 8-byte aligned; drop `x1` if
    result < 4 KiB"). It took a control decision from a data value (visibility **channel 5**) and was not
    expressible over any closed tuple — the tell that it was a filter, not a contract. The `SuperscalarEn &&
    NrHarts>1` gate did not launder it (P5: identity is necessary, not sufficient).
  - **Reverted the cancelled-writeback forces** on both commit ports (§E "force GPR write for cancelled
    CTRL_FLOW/LOAD", `G1s`/`G1an`) — a squashed operation performing an architectural write is **channel 1**.
  - **Kept** one Zacas port-ownership guard, re-anchored from `SuperscalarEn && NrHarts>1` onto `RVZacas`,
    the parameter that actually explains it (I28), and restated without a register number.
  - **Reverted `corev_apu/bootrom/bootrom.S`** to the stock sequence (`li s0,1; slli; csrr; la; jr s0`).
    Both the `addi s0, x0, 1` rewrite and the `nop`×5 + `fence` pipeline-drain padding were firmware edited to
    accommodate RTL (P1 inverted). The bootrom is our own code, which is what made the edit feel free.
  - **New L1 check:** `CVA6_MAX_SW_HARTS=8` + `assert (NrCores * NrHarts <= CVA6_MAX_SW_HARTS)` in
    `config_pkg`. The factors were bounded separately while the PLIC context budget scales with the *product*,
    so `NrCores=8, NrHarts=2` elaborated cleanly and would only fail when the wrong CPU took an interrupt under
    Linux. All in-tree packages pass (`ooo_server` is exactly 8).
  - **New L2 rung:** `core/fetch_B/formal/` (`align` I3/I5, `order` I2/I7, `redirect` I8) over the pure functions
    already in `g6lc_fetch_pkg`, mirroring `core/ooo/formal/`; wired into `verify.formalTasks` +
    `diag-fetch-formal-paths`.
  - **Red lines mechanized:** new `source-scan` diagnostic kind + `diag-isa-red-lines` / `diag-fw-accommodation`,
    both in the default `core` compartment. Self-tested against a five-violation fixture (5/5 fired, then clean).
    Pre-existing debt is **waived with a note and counted**, not hidden — 20 recorded entries today.
  - **Oracle controls:** `mini_must_pass` / `mini_must_fail` preflight the DI suite in both the shell runner and
    the proxy; a wrong answer in either direction aborts the run before any test.
  - **Hatch ledger:** `soft-ladder/inventory.yaml` gains the H7 `hatches:` schema, a repayment schedule, and the
    seven artifacts that repaid this pass.
- **Third pass — L3 layer contracts (M4) and the R11 hart-count contract.**
  - **M4 landed.** `core/fetch_B/g6lc_fetch_dbg.sv` is bound into `frontend` and already asserted I1/I2/I7-partial,
    but the bind omitted the realigner's carry state, so I3/I5 could not be checked at all. Added
    `leftover_valid_i` / `leftover_pc_i` / `leftover_lo_i` (the halfword observed hierarchically as
    `i_instr_realign.carry_instr_q`, so the synthesizable port list is unchanged for a `translate_off` check) and
    five assertions on the **emission**: slot0's PC is the carried PC, slot0's low half is un-rewritten (I2), and
    the completed slot0 is RVI with `ilen==4` (I5). The *enable* conditions are deliberately not re-checked here —
    the realigner builds them from the same `g6lc_fetch_pkg` functions the new L2 formal proves, so asserting them
    at this tap would be a tautology. **OpenSBI anchor:** `include/sbi/sbi_csr_detect.h:17` arms mtvec and executes
    a possibly-illegal `csrr`, and `lib/sbi/sbi_expected_trap.S:23` advances `mepc` by a **fixed 4** — sound only
    because `csrr` is always 4-byte RVI. A completion that emits a 16-bit fragment at the probe address turns a
    legal probe into an illegal instruction *and* mis-advances `mepc` (the R3(c) obligation), and would otherwise
    surface ~10M cycles later as an unrelated hang.
  - **I23 bound observed, not enforced.** `hold_age_q` was computed and only printed; it now `$warning`s once per
    run when it exceeds `geo.hold_max`. Deliberately a warning and deliberately latched: silently releasing a hold
    is itself a recorded negative (`NEGATIVE.md` §1, unbounded vs early lift), and an assertion that fires every
    cycle is noise rather than blame locality.
  - **R11 / I25 pushed to build time.** `software/smt2-linux/scripts/dts_to_dtb.py` now enforces that the number of
    `cpu@` nodes **OpenSBI would actually count** equals `NrCores × NrHarts` of the owning config package. The three
    counting conditions mirror `platform/generic/platform.c:172-184` exactly (parseable `reg`; `hartid <
    SBI_HARTMASK_MAX_BITS` = 128 per `include/sbi/sbi_hartmask.h:23`; enabled per `lib/utils/fdt/fdt_helper.c:245`,
    i.e. `status` absent or beginning `okay`/`ok`). `platform.hart_count` is the FDT walk's only durable output, so
    a mismatch is never diagnosed by firmware — it appears as a hart that never leaves the HSM wait or an interrupt
    delivered to a context that does not exist. New `DTS_CONFIG_PKG` pairing table, `--expect-harts`,
    `--config-pkg`, `--no-hart-count-check`, and a standalone `--check-all-harts` sweep.
  - **Defect found by that check, reported not changed:** `corev_apu/bootrom/ariane-ai.dts` advertises **one**
    countable `cpu@` (and its CLINT `interrupts-extended` references only `CPU0_intc`) while
    `core/include/g6lc64_ai_config_pkg.sv` sets `NrCores=2`, i.e. **S=2**. OpenSBI would set `plat_hc=1` and core 1
    would never be started. Resolution is an owner decision — either add the second `cpu@`/intc and its CLINT+PLIC
    contexts, or drop the AI package to `NrCores=1` — so it is recorded rather than unilaterally patched. The other
    five mapped DTS/package pairs agree (`ariane.dts` 1, `smt2` 2, `stream8` 2, `server_math_v` 4, `ooo_server` 8).
- Corrected the proxy and the local `soft-ladder-di-regress.sh` pass detection: a DI test only passes when the harness log shows `tohost = 1` (or `tohost = 0x1`). The previous logic treated the harness `*** SUCCESS *** (tohost = 0)` timeout as a pass, which inflated the 15/16 and 16/16 reports. **T9 (invalidate backwards) applies:** every DI count recorded before this fix came from the old classifier and is not comparable — re-measure or annotate before citing, especially where one was used to *eliminate* a hypothesis. With the corrected detection, the full consecutive DI suite is currently **0/16 PASS**:
  - `mini_amoadd_w_spin`, `mini_csr_expected_trap`, `mini_csr_pmp_probe`, `mini_dual_cmv_s3`, `mini_fdt_s2_nest`, `mini_fdt_check_prop_nest`, `mini_fdt_next_tag_lbu`, `mini_fdt_a0_is_fdt`, `mini_stq_flush_fwd`, `mini_fdt_namelen_walk`, `mini_fdt_nt_frame32`, `mini_fdt_nt_stock`, `mini_fdt_nt_cpus`, `mini_stq_alias_jal`, `mini_fdt_nt_osbi` all time out with `tohost = 0` (or hang at the bootrom `_hang`/`0x0` fetch loop).
  - `mini_fdt_lenp_sw` reaches its `fail:` path and the `rvfi_tracer` terminates the simulation (`rc=1`, `tohost=0`).
- The bootrom `s0` symptom that motivated the filter is **unexplained, not fixed**: with the accommodation in place the B harness still stalled with `npc=0x10000` and `s0=0x0` for 64+ cycles, and legacy/slfix showed the same. That is H4 territory — the symptom was never made deterministic, so the three successive attributions to it are unfalsifiable and none is recorded as a conclusion.
- Next (ordered by ladder position, not by symptom):
  0. **Grow the battery along the axis the firmware supplies (T4).** M5 shows the residual's defining co-factor — a
     live peer hart — is present in 5 of 113 minis. Before any further attribution, add live-peer variants for the
     W1 minis that already pin the class single-hart, and one `W5 × thread-select` mini
     (`lib/sbi/sbi_init.c:196` `wait_for_coldboot`: peer spins on `__smp_load_acquire` until the boot hart
     releases). A mini that passes eliminates a shape, never a class.
  1. **H4 determinism before attribution.** Establish whether the bootrom `npc=0x10000` / `s0=0` stall is stable across three runs at `verilator --threads=1` with the observer binds off. If the outcome depends on simulator scheduling, the race/X *is* the bug and it outranks any functional hypothesis. Do not attribute until it is stable.
  2. **T2 promise location, not component.** With a stable symptom, name the first false promise on `I$ → realign → IQ → issue → EX → commit`, and instrument *that* boundary. `g6lc_fetch_dbg` already asserts I1 (bytes==memory); I3/I5/I7 have no boundary SVA yet (M4).
  3. **Run the new formal first.** `verify --formal` now covers I2/I3/I5/I7/I8. A counterexample there is seconds and names the tuple; it is strictly cheaper than any harness run and must be exhausted before a soak.
  4. Only then the OpenSBI residual (`mepc0=0x8000a9a8`, `mcause0=0x2`) — as a **gate**, not a search signal.
- Deliberately **not** doing: another peel, another hold-ELF cycle, or another TRACE hunt for this class. H7 blocks a second unrepaid use, and the repayments for this class landed above.
- **M5 landed, and its result reframes the residual.** `verif/tests/custom/multicore/ARCHETYPES.yaml` classifies all
  113 minis (+2 controls) by archetype W1–W7, owning layer, invariants, and the co-factors each actually supplies;
  the matrix and a real/structural verdict for all 64 empty cells are in
  [`soft-ladder/README.md`](architecture/multi-threading/soft-ladder/README.md) §"Archetype x layer coverage (M5)".
  Counts are of **existence, not passing** (H3/T9). Three findings that matter more than the counts:
  1. **Cross-hart is essentially untested.** Only **5 of 113** minis run a live peer hart
     (`mini_fetch_straddle`, `mini_fdt_ro_probe`, `mini_fdt_nt_osbi`, `mini_stq_press_smt`, `mini_ipi_hart1_sp`);
     the other 60 hart-aware minis merely *park* `mhartid!=0`. W5 (release/acquire) has one mini total and it is
     single-hart, so `W5 × thread-select` — R2′'s own stated Home — is **empty**. This is P2/T4 exactly: the SMT2
     residual is a `T=2` property, and the battery samples the `T=1` face of the cube. It also explains why a
     green DI suite has never predicted the firmware outcome.
  2. **`W3 × L4-redirect` is empty** although `R3 ≡ R5` makes redirect one of the *two* real capability gaps.
     Nothing pins I11/I19 for a function-pointer table (`include/sbi/sbi_platform.h:265` is `if (ops->f) return
     ops->f(...)` for every service).
  3. **`W2 × L1-align` and `W2 × issue` are empty**, and both are named verbatim in R3: no mini places a CSR probe
     at a straddling address (clause c — the blind `mepc += 4`), and no mini owns "`csrrw mtvec` must not
     dual-issue with the CSR it is arming" (clause d, `stall_csr_older`). The whole `csr` layer column is zero.
  Distribution is also lopsided: `W1 × LSU` (68) and `W6 × amo` (16) hold 84 of the 106 classified minis.
  Lower-confidence classifications are flagged per-entry in the YAML (`mini_hpd_*` W1-vs-W3 ~70%; the 68 `W1 × LSU`
  homes ~75%, resolved via the blame router's data signature since R4's Home is explicitly ambiguous).
- Migration items from the heuristics §5 table: **M1–M6 are now landed.** M7 ("capability work resumes on proven ground") is the state this reaches, not a task. Open follow-ups it exposes, in ladder order:
  1. `ariane-ai.dts` vs `g6lc64_ai_config_pkg.sv` hart-count mismatch (above) — an owner decision, and the first real defect the new L1 checks caught.
  2. `core/scoreboard.sv` still consults the A-path `g6lc_sb_keep` list; waived-with-note in `diag-isa-red-lines`. Owed artifact is a squash-window contract at the EX→commit boundary.
  3. ~~The `.sby` files are unrun on this host~~ **Discharged.** All three fetch proofs **PASS by k-induction**, and `verify --formal` is **7/7** including the four `core/ooo` tasks. What it took, and what is now landed in the build platform:
     - **Distro Yosys is unusable for this repo.** Ubuntu 24.04 ships 0.33, whose classic frontend rejects `ai_cfg_t'(0)` in `config_pkg.sv` (`TOK_USER_TYPE`) and also rejects package-to-package `import`. The fix is not to edit `config_pkg` to suit a tool — it is a real SystemVerilog frontend. sv-elab/slang is **integrated into Yosys from v0.67**, so no plugin is needed; `core/ooo/formal/g6lc_ooo_rob.sby` had a stale `plugin -i slang` line that is now a hard error, and it was removed.
     - **Engine choice dominates.** `g6lc_fetch_order` is **0.27s** under `abc pdr` and **does not converge in 240s** under `smtbmc z3`. All three `.sby` now race both engines. Separately, a 32-bit free `n` in the order props made the solver reason over 2^32 loop bounds; narrowing it to 4 bits is the real fix (the tuple is the port list).
     - **The props were stateless**, so `initial assume (!rst_ni)` was both dead weight and rejected by slang. Removed.
     - **Build platform now provisions this**: `tools install formal` source-builds Yosys+SymbiYosys (`build-platform/scripts/install-formal.sh`, CMake/Ninja, `-j` cores) into `workspace/tooling/formal`, adopting an existing install when it already has `read_slang`. Windows delegates to WSL via the new `platform/wsl.ts`, matching the Spike pattern. `eda.ts` resolves oss-cad → managed → PATH, decides integrated-vs-plugin slang from the artifact rather than the suite name, and runs tasks concurrently (`--formal-jobs`, `--formal-tasks`).
     - **Do not run solvers with their workdir on `/mnt`.** DrvFs is slow for the many small files sby writes, and an 8-core build plus a solver crashed the WSL VM repeatedly. `verify.formal.workdirRoot` exists for this, and the WSL path uses a `$HOME` workdir.
     - Oracle checked in both directions (H3 applied to the gate itself): injecting one false property makes the gate report 1/7 failed; removing it returns 7/7.
  4. `core/ooo/formal/g6lc_ooo_{rename,cancel}` pass on the Windows OSS CAD suite but were never observed to complete under the WSL build — same z3-slowness class as the order proof. If they ever stall in CI, add `abc bmc3` to their engine list before touching the props.
  5. **SMT fetch contracts proven (gate now 8/8).** `core/fetch_B/formal/g6lc_fetch_smt.sby` proves the three multi-threading contracts that SPEC §4/§5 state in prose and that each have a recorded failure behind them: **R1/I4** `packet_hart` (a switch must not retag an in-flight packet as the incoming hart — a parked hart legitimately runs with `sp==0`, so mislabelled provenance is indistinguishable from "not ready yet"); **I8** `commit_for_hart` (TRACE t=200082 had `src=4` reseeding fetch with hart0's target while `h=1`, stealing hart1's bootrom `jr s0`); **I10** `snap_pc` (bank the address the I$ accepted, not the fetch-ahead `npc`). `en_restore`/`en_smt` are **free inputs**, so one run proves the T=1 and T>1 envelopes together.
  6. **Envelope collapse landed.** The order proof now runs at the geometry ceiling `N=8` instead of a package's `N=4`. A narrower `INSTR_PER_FETCH` is the same proof with upper slot inputs tied off, and tying an input off can only remove counterexamples — so `FW=32/64/128` are covered by one run. This is the `C` factor of the width ledger going to 1: raising `geo.issue`, `geo.harts` or `FETCH_WIDTH` becomes a re-run in seconds, not a re-soak in hours. Do not specialise a proof down to a package geometry; that weakens it.
  7a. **Two existing ooo proofs were silently VACUOUS.** `g6lc_ooo_{freelist,rename}.sby` used the classic
     `read -formal` frontend while their properties reference DUT state hierarchically (`dut.free_q`,
     `dut.busy_q`, `dut.ckpt_ptr_q`, `dut.map_q`). The classic frontend cannot resolve a cross-module
     reference: it silently declared wires *literally named* `dut.free_q`, warned "implicitly declared" and
     "used but has no driver", and left five assertions checking dangling nets instead of the design — while
     reporting PASS. This is the H3 class applied to formal: **a pass that is not evidence.** Both are now on
     `read_slang`, which resolves the references or errors, and both pass with **zero** dangling-wire warnings,
     so the assertions are real for the first time. `g6lc_ooo_cancel` has no hierarchical refs and was
     unaffected; `g6lc_ooo_rob` already used `read_slang`. Lesson worth keeping: **any proof that reaches into
     a DUT must use `read_slang`**, never `read -formal`.
  7b. **Remote formal landed, and it is the fast path.** `verify --formal --formal-remote` runs the whole
     suite in one remote shell on the builder — **10 tasks in ~11 s** on 12 cores. Engine choice mattered more
     than the host: adding `abc` alongside z3 took the suite from 128 s (with two z3-bound tasks dying on
     `BrokenPipeError`) to 11 s. Details and the four traps in `build-platform/AGENTS.md` §4.6.2b.
  7c. **Two proof shapes worth reusing.** (a) *Live module over pure function* — when a rule quantifies over
     module state or over the I$ line, instantiate the real module (as `core/ooo/formal` already did) instead of
     concluding the rule is not L2-expressible. That closed I1/I2/I4, which SPEC §10 had wrongly recorded as
     "L3 is leftmost feasible". (b) **Self-composition for non-interference** — a rule of the form "X must not
     depend on Y" cannot be witnessed by any single execution. Run two copies, vary only Y, assert the
     observable agrees. That is how I6 is proven, and it is the right shape for **every** ISA red line in
     `firmware-boot-principles.md` §E, which are all "must not decide from a value" claims. Today those are
     policed by a `source-scan` tripwire (`diag-isa-red-lines`); a self-composition proof would make them
     properties instead of greps.
  7. **Ladder map is now explicit.** [`core-fetch/SPEC.md`](architecture/core-fetch/SPEC.md) §10 records, for every fetch invariant, which rung checks it today, with what artifact, at what envelope, and whether it is worth moving left. That table is the work queue for this plane, and it replaces guessing about coverage.

### O1c / O2 attempt (2026-08-31) — both produced hard information, neither landed as planned

**O1c (I9 at L2): blocked by a real combinational loop, not by tooling.** The live-frontend harness was
built and *elaborates cleanly* — `read_slang --allow-use-before-declare` over 27 files (all four
`parameter type` structs reconstructed; every predictor, the realigner and the queue resolve). It then
fails at SMT model construction with **"Found logic loop in module g6lc_fetch_hold_props"**, so no
proof can be built over `frontend.sv` today. Files are kept at
`core/fetch_B/formal/g6lc_fetch_hold.{sby,props.sv}` (not in `formalTasks`) because the harness is
correct and only the design blocks it.

Chasing that produced the finding that matters: **`verify.lintArgs` carries `-Wno-UNOPTFLAT`
project-wide, which hides the entire circular-combinational-logic class.** Re-enabling it (Verilator
honours the last `-W` flag) gives **11 reports, 8 of them in the active fetch plane**:

| Locus | Signal |
|---|---|
| `core/fetch_B/frontend.sv:153` | **`fetch_address`** |
| `core/fetch_B/frontend.sv:197` (×3) | regularized nodes on that cone |
| `core/fetch_B/g6lc_fetch_pkg.sv:167` | **`kill_s2`** |
| `core/fetch_B/instr_queue.sv:117` | `address_overflow` |
| `core/fetch_B/instr_queue.sv:126,173` | rotate/regularize nodes |
| `core/decoder.sv:118`, `core/csr_regfile.sv:257`, `core/load_unit.sv:439` | outside fetch |

`fetch_address` ↔ `kill_s2` is **the same loop class the 2026-08-31 icache fix broke** — that fix cut
the path through the cache (`vaddr_d → cl_hit → dreq_o.ready → vaddr_d`), but the frontend-internal
cycle remains. New optional diagnostic **`diag-smt2-comb-loops`** keeps the class visible without
touching the main gate's baseline. Not ratcheted yet: treat it as a report and do not add a loop on
top of it. UNOPTFLAT can be a false positive for bit-sliced signals, but yosys refusing to build an
SMT model is independent corroboration that at least one is real.

**O2 (live-peer battery): blocked upstream, and the M1 oracle controls proved it in one run.** Before
writing minis, the cheapest discriminator (P6) was to ask whether the DI path can produce a PASS at
all. It cannot. The **first ever execution** of the oracle controls, remotely on the B harness:

```
mini_must_pass -> fail (expected pass)
mini_must_fail -> fail (expected fail)
ORACLE INVALID -- H3 'Oracle Validity First' precondition is not met
Suite NOT run: per-test results would be meaningless.
```

`mini_must_pass` is **three instructions** that unconditionally write `tohost=1`, so the failure is
upstream of every test's logic. The trace is unambiguous and **deterministic** (not flaky): the core
spins at `pc=0x10044 instr=ffdff06f` — `jal zero,0x10040`, the **bootrom `_hang` loop** — until the
cycle cap, on every test.

Three consequences:
1. **Adding minis is pointless until this is fixed.** The `W5 × thread-select` gap is real, but no new
   directed test can be validated while every test dies in the bootrom. O2 is *gated on O3*, not
   merely ordered after it.
2. **The controls earned their keep immediately.** They converted "16 mysterious failures" into one
   sentence about the bootrom, and they aborted the suite instead of reporting 16 meaningless verdicts.
3. **This is the H4 determinism O3 wanted.** The symptom is now stable and reproducible, which is the
   precondition for attributing it. Note it also confirms the reverted commit filter was *masking*
   this defect by forcing `s0`'s write rather than fixing it — exactly what H6 predicted.

### Workflow to O4, inferred (2026-08-31) — and one instrument defect fixed on the way

O4 is not workable directly; it sits behind O3. The dependency chain, cheapest step first:

```
O4  OpenSBI residual, as a gate
 └── O3  bootrom must reach DRAM (jr s0 -> 0x80000000)
      └── which layer loses the jump?
           └── cheapest discriminator (P6): A/B pair on mini_must_pass
                ├── legacy green + B red -> fetch_B; one fix also unblocks O1c and O2
                └── both red             -> generic core (issue/commit/link), different owner
```

**Instrument defect found and fixed first — the committed generated bootrom was a commit behind its
source.** `corev_apu/bootrom/bootrom.{sv,h}` are *generated* from `bootrom.S` by `gen_rom.py`, and they
are **checked in**. When `bootrom.S` was reverted to stock in `f2bbcad63`, the artifacts were left at
`7e6c19c54` (the accommodation image with interleaved `nop`s). Verilator compiles the `.sv`, not the
`.S`, so the in-tree image silently disagreed with its own source. Both are now regenerated and in
sync (diff is exactly the accommodation→stock image). **Standing hazard worth remembering: a generated
artifact that is checked in can disagree with its source, and here the artifact is what ships into the
simulation.** `soft-ladder-build-harness.sh` does regenerate it during a remote build (with the right
`RISCV_GCC`), which is why remote runs were not as stale as the tree — but anything that Verilates the
tree directly would have used the wrong ROM.

**A retraction.** On the first pass I read `fetch_addr=0x10044 instr=ffdff06f` as the core fetching a
*different 8-byte window* than the PC claimed — i.e. an I$/I1 violation. **That was wrong**, and it was
wrong because it was measured against the mismatched image above: `ffdff06f` sits at `0x10050` in the
accommodation build. After a clean rebuild the spin site moves to `0x1004c`, which *is* `wfi` in the
correct image. There is no evidence of an I$ window mismatch. (T9: when the instrument changes, the
record moves — including my own reading of it from 40 minutes earlier.)

**O3 stands, now on a trustworthy instrument.** Freshly built B harness, bootrom regenerated from stock
`bootrom.S` (verified by disassembly: `li s0,1; slli s0,s0,0x1f; csrr; auipc; addi; jr s0` at
`0x10000`-`0x10014`, `_hang` at `0x10040`):

```
mini_must_pass -> fail (expected pass)      # three instructions, tohost=1
mini_must_fail -> fail (expected fail)
ORACLE INVALID -- suite NOT run
spin: fetch_addr=0x1004c   (wfi, inside _hang)
```

So `jr s0` at `0x10014` does not reach `0x80000000`, and the hart ends parked in `_hang`. That is a
real bootrom→DRAM hand-off defect on current source, measured with a matched ROM for the first time.

**A/B pair run — result: NOT fetch_B.** `mini_must_pass` fails on **both** `--flavour B` and
`--flavour legacy`. By the blame router's step 0 (`logics.md` §3, `ab.legacy_red && ab.B_red`) that is
*"generic core (issue / STQ / CSR / commit) or B2 firmware policy"*. So the `fetch_address`/`kill_s2`
combinational cone from O1c, while a real hygiene defect that still blocks the I9 proof, is **not** the
cause of O3. That hypothesis is retired rather than left hanging.

**The M1 control is itself valid** — checked before trusting its verdict, since a failing positive
control can equally mean a broken control (H3 applied to the control). `mini_must_pass` links and
assembles exactly as intended: `_start` at `0x80000000`, `tohost` at `0x80001000`, body =
`csrr t0,mhartid; bnez t0,park; li t0,1; auipc/addi t1,tohost; sw t0,0(t1); j .`, with hart!=0 parked in
`wfi`. Nothing about the test is wrong; the machine does not write `tohost`.

**O3's framing was too narrow: the behaviour is test-dependent, and some tests DO reach DRAM.** On the
same freshly built B harness:

| Test | Where it ends |
|---|---|
| `mini_must_pass` | `fetch_addr=0x1004c` — `wfi` inside the **bootrom** `_hang`; never leaves ROM |
| `mini_amoadd_w_spin` | fail (timeout) |
| `mini_csr_expected_trap` | `dec_pc=0x800000cc`, `fetch_addr=0x800000ce instr=00000000 is_illegal=1` — **in DRAM**, fetching zeros past its code |

So "the bootrom never reaches DRAM" is wrong as a general statement: `mini_csr_expected_trap` executes
at `0x800000cc`. Two distinct signatures are in play, and they must not be merged into one story:
(a) a hart that stays parked in the bootrom, and (b) a hart in DRAM fetching `00000000` and taking an
illegal-instruction trap. Whether (a) is hart-1-parked-legitimately versus hart-0-stuck is **not yet
established** and is the next thing to determine — the `id-dbg` line does not identify the hart, so the
first step is per-hart attribution, not another hypothesis.

### ROOT CAUSE FOUND: the retire stream executes bytes that do not match the PC (2026-08-31)

Following the ordering (read the counterexample before theorising) led to the actual defect, and it
**reverses two of my own earlier conclusions**. Both retractions are recorded because the reasoning that
produced them was wrong in an instructive way.

**Retraction 1 — "exception delivery is broken" is FALSE.** The RVFI trace shows instructions retiring
normally and an `ILLEGAL_INSTR exception` being *reported and taken*. Exceptions work. The earlier
`mcause=0` readings came from an `id-dbg` probe that does not observe committed CSR state; I treated a
silent probe as evidence of absence.

**Retraction 2 — the "wrong fetch window" reading I retracted on 2026-08-31 was RIGHT.** I withdrew it
because it had been measured against a mismatched bootrom image. The observation was sound; only its
instrument was bad. Re-measured against a *verified* ELF, it holds.

**The evidence.** `~/trapdisc/t_ecall.elf`, `.text` 0x44 bytes, one clean LOAD segment at 0x80000000
(readelf-confirmed, so nothing is missing from memory):

| Addr | ELF contains | RVFI actually retired |
|---|---|---|
| `0x80000008` | `auipc t0,0x0` | `auipc` — matches |
| `0x8000000c` | `addi t0,t0,36` | `addi` — matches |
| `0x80000010` | **`csrw mtvec,t0`** (`30529073`) | **`f14022f3` = `csrr t0,mhartid`** — the bytes from `0x80000000` |
| `0x80000014` | **`li s0,0`** (`4401`) | **`02029c63` = `bnez`** — the bytes from `0x80000004` |

So the machine is fed bytes from address `A` while reporting PC `A + 0x10`.

**This is not a tracer artifact — the architectural effect follows the BYTES, not the PC.** Two
independent confirmations: (a) `csrr` wrote `x5 = 0`, i.e. a CSR *read* really executed where the ELF
has a CSR *write*; and (b) the subsequent trap vectored to `0x00010048` (bootrom `_hang`) instead of
`handler` at `0x8000002c`, which is only possible if **`csrw mtvec` never executed**. The wrong
instruction was not merely mis-reported, it was *committed*.

**That is an I1/I2 violation** — "decode is a function of bytes and address alone" — at the
instruction-supply boundary, and it explains every symptom of the last two days at once: the bootrom
never completing `jr s0`, `mini_must_pass` failing, `mini_csr_expected_trap` running off the end of its
`.text` into zeros, and all 16 DI minis failing. One defect, many faces.

**Why none of the 11 proven contracts could catch it — and this is the important structural lesson.**
Every fetch proof takes `data_i` as a *free* input and proves the realigner/queue are faithful to
whatever they are handed. That is exactly the right contract for those modules, and it is exactly why it
is blind here: **no contract ties `data_i` to the memory content at `vaddr`.** The promise "the bytes
returned for a fetch of address A are the bytes at A" has no owner. A green 11/11 gate and a core that
executes the wrong instructions are therefore perfectly consistent — the gate never claimed otherwise.
That missing promise is now the highest-value contract in the repository, ahead of I9.

**The missing promise now has an owner, and it is validated in both directions.** `+fetch_i1_check`
(`core/id_stage.sv`, sim-only, + `g6lc_dram_peek64` DPI in `corev_apu/tb/g6lc_tb.cpp`) checks at the
*delivery* point — the `(address, instruction)` pair decode actually consumes — so one sentence covers
the I$, the realigner and the queue. Positive control: it fires on `~/trapdisc/t_ecall.elf`. Negative
control: silent without the flag. Its output **quantifies** the defect:

| addr | delivered | should be | bytes actually come from |
|---|---|---|---|
| `0x80000010` | `f14022f3` | `30529073` | `0x80000000` |
| `0x80000014` | `02029c63` | `00734401` | `0x80000004` |
| `0x80000020` | `30529073` | `fe430313` | `0x80000010` |

**The data stream lags the address stream by exactly `0x10` — two 8-byte fetch windows at
`FETCH_WIDTH=64`.** Not a random corruption, not an off-by-one: a constant two-window lag, which is a
pipeline-depth signature (a response register pair sampled one stage too late, or an FDIP/FTQ entry
retired against the wrong window) rather than an addressing or decode fault.

Three instrument traps were hit building this, all worth remembering because each looks exactly like
"the check found nothing":
- `g6lc_fetch_dbg.sv` is **commented out of `Flist.cva6`** (line 252) while present in `Flist.fetch_B`;
  the B build uses `Flist.cva6`, so a checker placed there is never compiled. Hence the move to
  `id_stage.sv`, which is in the build and already hosts the `[id-dbg]` probe.
- A plusarg absent from the C++ **allowlist** (`g6lc_tb.cpp:84`) is handed to HTIF, which rejects it and
  kills the run *before* the checker arms. A rejected plusarg and a clean check are indistinguishable
  from the outside.
- A comment line beginning with the linter's own name is parsed as a directive and fails elaboration.

**Next, in order:**
1. ~~Write the I1-at-supply contract~~ **Done** (above), and it did what the ordering predicted: it
   localised the defect to a constant two-window lag in one 9-second run, having cost less than any of
   the hypotheses it replaced.
2. Only then localise: the `0x10` shift is a whole number of fetch windows, so suspect the I$
   response/`vaddr` pairing (the registered-`vaddr_q` path touched by the earlier convergence fix) or
   FDIP/FTQ replay serving a stale window. `id-dbg` already prints `fetch_addr`, so pair it with the
   returned data and diff against the ELF.
3. Re-run the A/B pair afterwards: both flavours failing is consistent with a shared I$/supply defect
   rather than a fetch_B-specific one, which fits this root cause better than it fits the earlier
   decode-plane hypotheses.

### Roadmap analysis: O4 → soft-ladder → SMT2 → multi-threading → g6lc_qemu (2026-08-31)

Asked for a large architectural pass toward *Linux + hypervisor boot and stable runtime* on the maximal
envelope (8-wide OoO, 8 cores, stream plane, L1–L3, RVV). The honest answer is that **the feature
parameterization is not the bottleneck and new feature RTL is not the right next code**:

- `check_cfg` already carries a dense legality envelope for U1–U6 — `OoOEn`/`SliceOoOEn` exclusivity,
  `NrIssuePorts` 1..8, `NrCores` 1..8 with the `NrCores × NrHarts` product bound, `L2En`/`L3En`
  dependency and power-of-two shape checks, prediction-fabric legality, `RVH → RVS`, prefetch/D$ type
  gating. Adding more asserts there would be duplication, not progress.
- What is missing is **contracts on the planes those features run through**. Every one of the 11 proven
  contracts is in the fetch plane. Decode, issue, commit, the exception path, the LSU and the coherence
  fabric have **zero**. That is not a documentation gap; it is why a green formal gate coexists with a
  core that cannot deliver an illegal-instruction trap.

So the ordering is forced, and it is *narrower* than the feature list:

| Stage | Gate | Why it must come first |
|---|---|---|
| **now** | exception delivery works at all | RVH/Linux/RVV all assume precise traps. A hypervisor is *built* out of traps (`sret`/`mret`, two-stage faults, `hideleg`). Building RVV or L3 on a core that drops exceptions is building on sand. |
| then | **O4** OpenSBI residual | Reachable only once `sbi_hart_detect_features`' CSR probes can trap. Its recorded signature must be **re-derived**, not reused (T9). |
| then | soft-ladder / SMT2 live-peer battery (**O2**) | Needs a valid oracle, which needs a machine that can report PASS. |
| then | multi-threading beyond T=2 | I18/I20/I22/I23 per-hart isolation contracts, none of which exist yet outside fetch. |
| last | `g6lc_qemu` B0–B3 | It *consumes* the model (DTS/PMU/device contracts). A generator fed by an unverified core propagates the error into the tooling. |

**Concrete pass made toward this, rather than feature scaffolding:**

1. **A real latent bug, found by trying to elaborate the decoder formally** (`core/decoder.sv:1758`).
   `riscv_pkg` declares instruction fields at their bit positions — `atype_t.rd` is `[11:7]`, `rs2` is
   `[24:20]` — so the AMOCAS.Q odd-pair guard `instr.atype.rd[0] || instr.atype.rs2[0]` indexed **bits
   that do not exist**. Verilator resolves an out-of-range index to X/0 and says nothing, so *the check
   never fired* and an odd-pair AMOCAS.Q was accepted instead of reported illegal. slang rejects it
   outright. Fixed to `rd[7]`/`rs2[20]`. This is the push-left thesis in miniature: the proof paid for
   itself before it ran.

2. **`core/include/g6lc_core_types.svh`** — the modularity seam. SV packages cannot be parameterized, so
   every pipeline struct lives as a `localparam type` in `core/cva6.sv`, unreachable from any harness not
   instantiated under `cva6`. Consequence: each props file **hand-copies** the layouts
   (`g6lc_fetch_hold_props.sv` reconstructs four, "layout-identical … by hand and by hope"). A props file
   whose `scoreboard_entry_t` has drifted still elaborates, still passes, and is checking a different
   machine. The header follows the convention the codebase already uses for exactly this
   (`rvfi_types.svh`, `cvxif_types.svh`: cfg-as-macro-argument). `cva6.sv` adoption is deliberately
   deferred — it must be shown netlist-identical first (I27 applied to a refactor) — and until then the
   header is documented as a copy that must track `cva6.sv`. One tracked copy beats N untracked ones.

3. **`core/formal/g6lc_trap_deliver.{sby,props.sv}`** — the first exception-plane contract, live-DUT
   (not a policy model: the `ooo` proofs are self-contained models and would have reproduced the
   *intent* rather than the code, which is how the CVXIF hole survived). Two tasks by design, so the
   proof has its own oracle: `ok` (CvxifEn=0) must pass, `bug` (CvxifEn=1) carries `expect fail` and is
   the machine-checked statement that the withheld `ex.valid` is real and the new `check_cfg` guard is
   load-bearing.

   **Status: elaborates clean (0 errors, 0 warnings) but `ok` FAILS, so it is NOT wired into
   `verify.formalTasks`.** All three assertions fail together, which points at the structure rather than
   at any one property — and the structure is the find: **`instruction_o` is driven by four separate
   processes** (`always_comb : decoder` :192, `always_comb : sign_extend` :1879, the continuous
   `assign instruction_o.valid` :1961, and `always_comb : exception_handling` :1963), i.e. one packed
   struct variable with four drivers. That is exactly why `decoder.sv:118 instruction_o` appears in the
   `UNOPTFLAT` circular-combinational report, and it is strong corroboration for **O3e**. Not yet proven
   to be *the* cause of the missing trap — the counterexample trace has not been read — so it is logged
   as corroboration, not as a verdict.

### Fastest path to O4, inferred from OpenSBI source (2026-08-31)

Rather than treat O4 as "run the soak again", the path was derived by lifting the failing directed mini
to its archetype and reading the OpenSBI witness for it (H1 → §2 archetypes → logics §2 R-table).

**`mini_csr_expected_trap` is a verbatim transcription of OpenSBI's R3 probe.** Disassembly of the
built ELF against the firmware source leaves no ambiguity:

| Mini | OpenSBI witness |
|---|---|
| `csrrw t1, mtvec, t0` (arm, saving old mtvec) | `include/sbi/sbi_csr_detect.h:17` `csr_read_allowed` |
| `.word 0xfff022f3` = `csrr t0,0xfff` (illegal CSR) | the maybe-illegal probe itself |
| `csrw mtvec, t1` (restore), inline, repeated twice | same, and `lib/sbi/sbi_hart.c:771` repeats it dozens of times |
| `expected_handler`: `csrr mepc; addi +4; csrw mepc; mret` | `lib/sbi/sbi_expected_trap.S:23` — the **blind fixed +4** |

**Its failure, measured on the freshly built B harness with a matched ROM:** `mcause=0` and `mepc=0`
for the full 200k cycles, i.e. **no trap ever fires**. The illegal CSR access at `0x80000020` does not
except; execution then continues past the restore, and does not even take the
`bne s0,t3,fail` at `0x8000002e` (which must be taken, since `s0` cannot hold the `0xe601` cookie a
handler never wrote). `tohost` is never written by either the pass path or the `fail` path, and the core
ends fetching zeros at `0x800000cc` — `0x38` bytes, i.e. **14 × 4**, past the `0x94`-byte `.text`.

**So the gate on O4 is the W2 archetype — precise trap — and it is not in the fetch plane.**

```
O4  OpenSBI fw_payload reaches the cookie
 └── requires sbi_hart_detect_features() to complete            lib/sbi/sbi_hart.c:771
      └── which repeats csr_read_allowed() dozens of times      include/sbi/sbi_csr_detect.h:17
           └── which REQUIRES a precise illegal-instruction trap
               plus a handler whose blind mepc+=4 is sound      lib/sbi/sbi_expected_trap.S:23
                └── mini_csr_expected_trap is exactly that, and no trap fires at all
                     └── Home (logics §2, R3): "precise trap", `stall_csr_older` (**issue**, not fetch)
                          └── corroborated independently by the A/B pair: fails on BOTH flavours
```

Three things line up, which is why this is worth acting on rather than another hypothesis:
1. **A/B said "not fetch_B"** — and R3's Home is issue/commit, not fetch. Independent agreement.
2. **All 11 proven contracts are fetch.** None touches trap delivery, so none of them could have caught
   this — which is exactly why the pin survived a green formal gate.
3. **M5 already flagged this cell as empty**: `W2 × issue` and `W2 × commit` have **zero** minis, and
   R3's clauses (c) and (d) were recorded as having no owner. The coverage matrix predicted the gap
   before the failure was understood.

**Discriminator run (T3), and it picks the file: exception delivery, not CSR legality.** Two minis were
built differing in *one word* — an illegal **instruction** (`.word 0x00000000`) versus an illegal **CSR
access** (`.word 0xfff022f3`), everything else identical:

| Probe | `mcause` / `mepc` | Reached DRAM? |
|---|---|---|
| illegal **instruction** | `0` / `0x0` | **yes** — executing `0x80000018`…`0x80000026` |
| illegal **CSR access** | `0` / `0x0` | **yes** — executing `0x80000024`…`0x80000034` |

**Neither raises a trap.** The confound was checked before drawing the conclusion (both minis share
`mini_must_pass`'s shape, which never leaves the ROM, so "no trap" could have meant "no execution"):
they *do* execute in DRAM, so `mcause=0` is a real absence of trap delivery and not an absence of
instructions.

Because the failure is **identical for both**, it is *not* the CSR-legality path. The suspect is the
generic **exception delivery / trap-entry path** — `core/commit_stage.sv` and `core/controller.sv` —
and **not** `core/csr_regfile.sv`. One 20-second experiment eliminated a file that would otherwise have
been the obvious place to start reading.

This also reframes O1c: I9 is "trap entry to `mtvec` is held until decode consumes it", and on this
evidence a trap entry is never *generated* in the first place. The I9 hold contract is downstream of a
defect in raising the exception at all, so proving I9 would not have caught this either.

#### A real static defect found by reading that path — and an honest negative on the fix

Reading `is_illegal → ex.valid → trap` end to end found a genuine ISA violation, independent of whether
it causes the symptom above:

| Step | Locus | Behaviour when `CvxifEn` |
|---|---|---|
| 1 | `core/decoder.sv:1838-1844` | illegal instr → `fu = CVXIF`, `op = OFFLOAD` |
| 2 | `core/decoder.sv:1976` | **`ex.valid` is withheld** — `if (!CVA6Cfg.CvxifEn)` — so the coprocessor may claim the encoding first |
| 3 | `core/issue_read_operands.sv:288` | `cvxif_req_allowed = (issue_instr_i[0].fu == CVXIF)` — **port 0 only**, with its own `TODO check only for 1st instruction ??` |
| 4 | `core/cvxif_fu.sv:61,69` | `x_valid_o` and `x_exception_o.valid` are both just `x_illegal_i` |

So on a **multi-issue** core an illegal instruction landing on any port `!= 0` gets `fu=CVXIF`, no
`ex.valid`, no CVXIF transaction, and `cvxif_fu` never returns valid: **it neither traps nor retires**,
and the machine wedges. Three G6LC configs shipped that combination — `g6lc64_smt2` (2-wide),
`g6lc64_ooo` (2), `g6lc64_ooo_server` (4) — while *every* upstream config has `NrIssuePorts: 0`. The
unsound pairing is therefore ours: the superscalar targets inherited `CvxifEn=1` from the upstream
default without the offload path ever being extended past port 0.

Fixed as a parameter red line rather than a waiver (I28: a parameter gate must not legitimize an ISA
violation): `check_cfg` now `$fatal`s on `CvxifEn && NrIssuePorts > 1`, and the three targets take the
knob to baseline (`CvxifEn = 0`) since none has a coprocessor to offload to.

**But it did not fix the symptom, and that is recorded as a negative result, not quietly dropped.**
Rebuilt and re-ran both probes: still `mcause=0`, still no trap. The rebuild is *confirmed* to have
taken effect — the harness shrank `3736872 → 3718216` bytes as the CVXIF FU and example coprocessor
dropped out of the model — so this is a real negative, not a stale instrument (which had already caught
me twice today, see below).

**Therefore a second, independent defect blocks exception delivery.** The leading suspect now converges
with O1c: `core/decoder.sv:118 instruction_o` appears in the `UNOPTFLAT` circular-combinational report,
and `instruction_o.ex.valid` is *precisely* the field that fails to work. `core/csr_regfile.sv:257
update_access_exception` is in the same report, which would equally explain the illegal-CSR arm. A
non-convergent `instruction_o` cone is a mechanism that produces "decode says illegal, nothing traps"
for both probes at once. That is the next hypothesis, and it makes the comb-loop cleanup a correctness
prerequisite rather than hygiene.

**Do not** re-measure the recorded O4 signature (`mepc0=0x8000a9a8`, `mcause0=0x2`) as evidence yet: it
was taken on RTL that still carried the commit value filter, so per T9 it is not comparable to anything
current. Re-derive it only after the W2 gate passes.

### Objectives (ordered by ladder position, not by symptom)

The cheap rungs are now real, so the ordering rule from
[`AGENTS-coding-philosophy.md`](AGENTS-coding-philosophy.md) §2.9 applies literally: spend the next
increment at the **leftmost stage that can express the rule**, and treat firmware as a gate.

| # | Objective | Rung | Why now |
|---|---|---|---|
| ~~**O1a**~~ | ~~I12 explicit sequential step + the window algebra~~ | L2 | **Done.** `g6lc_fetch_geo.sby` proves `nxt == base + W`, `nxt > pc`, `!same_win(pc, nxt)`, and that `win_base`/`win_tag`/`same_win`/`hw_off`/`ilen_of`/`rvi_prefix` all agree — **swept over 6 envelope points** (FW 32/64/128/256 × RVC, plus 64/128 without RVC). Gate is now **9/9**. |
| ~~**O1b**~~ | ~~I4 per-hart leftover, I6 head-selection independence~~ | L2 | **Done.** Both closed by proving against **live modules** instead of pure functions. `g6lc_fetch_realign.sby` instantiates the real realigner and proves **I1/I2** no-fabricate (emitted halfword == `data_i` at that slot's own address) and **I4** per-hart carry isolation. `g6lc_fetch_iq.sby` proves **I6** by **self-composition**: two live `instr_queue` copies, identical control, different raw `instr_i`, identical `ready_o`/`consumed_o`/`replay_*`/`fetch_entry_valid_o`/`.address`. Gate is now **11/11** (~18 s remote). |
| **O1c** | **I9** bounded trap hold | L2 | **Blocked, and the blocker is the finding.** The harness elaborates; `frontend.sv` has a circular combinational cone (`fetch_address` / `kill_s2`) that stops yosys building an SMT model. Fix the loop first -- then this proof is a re-run, not new work. |
| **O2** | Grow the battery along the **live-peer** axis | L4 | **Gated on O3, not merely after it.** `mini_must_pass` (3 instructions) fails: every test spins in the bootrom `_hang` loop at `0x10044`. No directed test can be validated until that is fixed. |
| **O3** | Bootrom `_hang` spin - why `jr s0` never reaches DRAM | L6 prep | **Now the critical path, and now deterministic.** Every DI test, including a 3-instruction one, ends spinning at `pc=0x10044 instr=ffdff06f` (`jal zero,0x10040`). H4 is satisfied, so attribution is finally admissible. Prime suspect is the `fetch_address`/`kill_s2` combinational cone from O1c: a non-convergent frontend and a bootrom that never completes its jump are consistent. |
| **O4** | OpenSBI residual (`mepc0=0x8000a9a8`, `mcause0=0x2`) | L6 | Only as a **gate**, and it is unreachable until O3 lands: the machine never leaves the bootrom, so the OpenSBI signature recorded earlier was itself measured on a different (filtered) RTL. Re-measure it after O3 before citing it. Never a search signal. |
| ~~**O3a**~~ | ~~A/B pair on `mini_must_pass`~~ | L4 | **Done. Result: not fetch_B** — fails on both flavours, so the blame router points at the generic core or firmware policy. Retires the comb-loop-causes-O3 hypothesis. |
| **O3b** | Per-hart attribution of the `mini_must_pass` signature | L4 | `id-dbg` does not print the hart, so "hart 1 parked correctly" cannot be told from "hart 0 stuck". Still open, but **no longer the critical path** — O3c is cheaper and sits directly on the O4 chain. |
| ~~**O3c**~~ | ~~illegal instruction vs illegal CSR discriminator~~ | L4 | **Done. Both fail identically with `mcause=0`, and both execute in DRAM** (confound checked). So it is **not** CSR legality: the suspect is generic exception delivery — `commit_stage.sv` / `controller.sv`, not `csr_regfile.sv`. |
| ~~**O3d'**~~ | ~~read the illegal→`ex.valid`→trap path~~ | L4→RTL | **Done, with a real find and an honest negative.** Found and fixed a genuine ISA violation (CVXIF offload is port-0 only while the decoder withholds `ex.valid`; unsound on all three multi-issue G6LC targets, now a `check_cfg` `$fatal` + knob to baseline). It did **not** fix the symptom: still `mcause=0` after a confirmed rebuild. |
| ~~**O3e**~~ | ~~is the `instruction_o` cone why `ex.valid` never asserts?~~ | L2/RTL | **Wrong question — retracted.** `ex.valid` *does* assert and exceptions *are* taken; the RVFI trace shows `ILLEGAL_INSTR` reported and vectored. The four-driver `instruction_o` struct is real and still blocks the L2 decode proof, but it is a **proof-model** obstacle, not the boot defect. |
| **O5** | **THE defect: retire stream executes bytes offset `0x10` from the reported PC** | L3→RTL | I1/I2 violation at instruction supply, confirmed architecturally (`csrw mtvec` never executed, so the trap vectored to the bootrom instead of the handler). Explains the bootrom stall, `mini_must_pass`, the run-off-the-end, and all 16 DI failures as one defect. Repro: `~/trapdisc/t_ecall.elf`, 9 s. |
| ~~**O5a**~~ | ~~the missing promise: delivered bytes == memory at the delivered address~~ | L3 | **Done and validated both ways.** `+fetch_i1_check` in `core/id_stage.sv` + `g6lc_dram_peek64` DPI. Fires on the repro, silent without the flag. Quantified the defect to a **constant `0x10` (two-window) lag of data behind address**. |
| ~~**O5b**~~ | ~~find the one-line skew~~ | RTL | **FIXED** in `core/cache_subsystem/g6lc_icache.sv` (I4xk): `cl_index` must use `vaddr_d`, not `vaddr_q`. The array read is launched in IDLE in the same cycle the request arrives, so indexing with the *previous* address read the previous line. `ICACHE_OFFSET_WIDTH=4`, hence a skew of exactly one 16-byte line = the observed `0x10`. Verified: `+fetch_i1_check` reports **0 violations** on all four reproducers, with the oracle already proven able to fire. |
| ~~**O5d**~~ | ~~a second, downstream defect~~ | L4 | **It was the classifier, not the core.** The harness prints `dtm->exit_code()`, not the raw tohost word: HTIF uses bit0 as "done" with bits[31:1] as the code, so writing `tohost=1` prints `(tohost = 0)` and writing `3` prints `(tohost = 1)`. The "tohost = 1 is pass" rule matched the FAILING run. Fixed in both `soft-ladder-di-regress.sh` and the proxy. |
| ~~**O6**~~ | ~~re-measure the battery with a valid oracle~~ | L4 | **Done. First trustworthy baseline: 3/16.** Every DI number recorded before 2026-08-31 went through a broken classifier and/or a line-skewed fetch and is **void** — the 15/16, the 16/16 and the 0/16 were all measuring the instrument. |
| ~~**O7**~~ | ~~triage the 8 exit-code failures~~ | L4 | **Done.** All 8 reach their own `fail*` label, so all 8 are real rejections: codes 1,1,1,3,1,16,1,2 at `fail`/`fail_exit`/`fail_pop`/`fail_phase`. `mini_csr_expected_trap` (the direct OpenSBI `csr_read_allowed` witness) was traced to root cause — see O7a. |
| **O7a** | **PARTIALLY FIXED (net +1, one regression — read O7b before building on it).** `present_exp_q` is now cleared on redirect in `core/fetch_B/frontend.sv`. **Gained:** `mini_csr_expected_trap` (the direct OpenSBI `csr_read_allowed` witness) and `mini_amoadd_w_spin` now PASS. **Lost:** `mini_fdt_lenp_sw` PASS → timeout. Baseline 3/16 → **4/16**. Both seed variants were measured — `npc_d` and `'0` — and both show the same trade, so the regression is caused by re-basing the filter at all, not by the seed value. Kept because the OpenSBI witness is on the coldboot critical path, but it is a **trade with an open regression, not a clean fix.** | RTL |
| ~~**O7m**~~ | ~~age-ordered output selection is now in the RTL (superseded by O7p).~~ | RTL | **Done.** Round-robin residual addressed: `instr_queue.sv` now uses a global `push_seq` age and greedy oldest-first selection; the `mini_fdt_next_tag_lbu` failure at `0x8000014e` is the S1/SL-W store→load stale L1 class, not a queue-order bug. Oracle controls remain valid. The O7p residual is tracked as SL-W gate-6. |
| **O7n** | **REVERTED: delayed queue flush on predicted-taken CF issue.** | RTL | Commit `d2ad30200` added a queue-local flush one cycle after a predicted-taken branch/jump/ret was issued. It advanced `mini_fdt_next_tag_lbu` from 470 to 509 cycles, but made branch-heavy minis run so slowly that several hit the 4000/40000 cycle limit. Reverted in `9aa85ff6d`. The idea is architecturally sound for in-order, but the per-CF bubble cost is too high for this suite. |
| ~~**O7o**~~ | ~~program-order output with per-entry push sequence — landed in RTL.~~ | RTL | **Done in RTL; FIFO data-order proven.** Age-select + `push_seq` landed. `cva6_fifo_v3_order.sby` **PASS** locally and on `verify --formal --formal-remote` (12/12, 14 s): live `cva6_fifo_v3` (FALL_THROUGH=0, FPGA_EN=0, DEPTH=4) pops in insertion order against a shadow queue, and two copies with identical control / different payloads agree on empty/full/usage. That discharges the old `push_seq_range_ok` assume. Stimulus had to be top-level ports — read_slang was connecting undriven internals as per-instance `1'x`, so the two copies were not sharing control. Engine is `abc bmc3` + `smtbmc z3` (yices is not on the testharness PATH). `g6lc_fetch_iq_order.sby` asserts `pseq_monotone` without that assume and is **not** in the default `verify.formalTasks` until it PASSES (`head_select_ordered` still FAILs at step 3). |
| **O7l** | **CONFIRMED by direct observation: `instr_queue` emits the YOUNGEST entry of a group first. Nothing is dropped — order is inverted.** | RTL | New `+iq_trace` probe (`core/fetch_B/instr_queue.sv`, the old `[iq-dbg]` was gated to `$time()<100`). Around the return: `t=421 isq=00 dsq=0001 push=0011 cons=0011 full=0000 rdy=1` accepts `0x40`,`0x44`; `t=423 isq=10 dsq=0001 push=1100 cons=0011` accepts `0x48`,`0x4c`. The output pointer `dsq` sits at `0001` with `fire=00` from t=409 to t=427 while `a0=0x8000003e` (decode stalled). On the first fire, **`t=428 a0=0x8000004c`** — the youngest of the four — and only at `t=430` does `a0=0x80000040` appear, by which time `t=431 fl=1 mp=1` flushes it because the mis-ordered branch already resolved. **All four entries were accepted with `full=0000` and `rdy=1`, so nothing is dropped at the input; the selection order at the output is inverted.** This is I6 clause 1, the clause `g6lc_fetch_iq.sby` does not prove. Next: `idx_is_q`/`idx_ds_q` are independent rotating pointers and the push mapping is `rotate_left(valid, idx_is_q)` (line 175) — the bug is in how a *multi-slot push while the output pointer is parked* maps slots onto FIFOs relative to `idx_ds_q`. Fix candidates must preserve I7 (all-or-nothing push) and the leftover slot0 escape. |
| **O7k** | **REFINED by reading: not the input side. `instr_queue` OUTPUT ORDER is the violation — and it is I6 clause 1, which no proof covers.** | RTL | `instr_queue.sv:158` `ready_o = ~(\|instr_queue_full) & ~full_address` **is** occupancy-derived, and there is a correct I7 overflow path (`instr_overflow` → push none → replay, lines 176-186). With `iqr=1` at both pushes no FIFO was full, so `0x40`/`0x44`/`0x48` **did enter** the queue. Yet retire goes `0x3e → 0x4c`: since this core retires in order, `0x4c` was *issued before* three older entries. **That is a program-order violation at the queue output — the one-hot output select `idx_ds` advancing further than the number of entries actually consumed** (`[iq-dbg]` already exposes `idx_ds_q`/`idx_ds_d`). Entries then die in the flush when the mis-ordered `bne` at `0x4c` branches to `fail_pop`. **Proof gap worth recording:** I6 is stated as "IQ order is program order AND must not depend on opcode/rd/FU", but `g6lc_fetch_iq.sby` proves only the *second* clause, by self-composition on value-independence. **Clause 1 — program order itself — has never been proven**, which is exactly the clause being violated. Next: probe `idx_ds_q`/`idx_ds_d` against `consumed_o` and `fetch_entry_fire` per cycle, and give clause 1 its own contract. |
| ~~**O7j**~~ | ~~input-side overwrite: ready asserted while head stalled~~ | RTL | **Superseded by O7k** — the mechanism was wrong (`ready_o` is occupancy-derived and I7 backpressure is correct); the *localisation to `instr_queue`* stands. | The two existing probes together pin it, no new instrumentation needed. `[id-dbg]` (queue output to decode) shows `fetch_addr=0x8000003e` **stuck at the head from t=409 through t=426+** — the same entry `00004285` (`li t0,1`) for 17+ cycles, so decode is stalled and not consuming. `[win]` shows that during exactly those cycles the frontend pushed the windows for `0x40` (t=421) and `0x48` (t=423), both `take=1 vmask=0011`, **with `iqr=1` (`instr_queue_ready`) asserted**. Retire then goes `0x3e → 0x4c`, skipping `0x40`, `0x44`, `0x48`. **Hypothesis with a mechanism: `instr_queue` asserts ready while it cannot actually accept, so pushes during a decode stall overwrite entries that were never consumed — a silent drop instead of backpressure.** This is an I6/I7 violation (program order and "a dropped window drops all slots") and it is where the ~9 `fdt_*`/`stq_*` failures should be re-tested, since every one of them stalls decode behind a call/return. Next: probe `instr_queue` push/pop indices and `ready_o` vs occupancy — the existing `[iq-dbg]` is gated to reset cycles only (`t=1..9`) and prints no addresses, so it needs widening. |
| **O7h** | **RELOCATED: the post-`ret` drop is DOWNSTREAM of fetch. The frontend presents the instructions; they never retire.** | RTL | The `+fetch_win_trace` window-lifecycle probe (new, `core/fetch_B/frontend.sv`) settles it. Around the return in `mini_fdt_next_tag_lbu`: `t=407 vaddr=0x80000138 bpf=1 k2=1 npc=0x8000003e` (the `ret` redirect); `t=409 vaddr=0x8000003e vmask=0001` (target slot, retires); **`t=421 vaddr=0x80000040 vmask=0011`** and **`t=423 vaddr=0x80000048 vmask=0011`** — both windows *taken* with two valid slots each, i.e. `0x40 bne`, `0x44 auipc`, `0x48 addi`, `0x4c bne` were all **presented to the queue**, with `iqr=1` (no backpressure) throughout. The retire trace shows only `0x3e` and `0x4c`. **So fetch delivers them and the instruction queue / decode / issue / commit path loses them.** Three prior attributions (O7a filter, O7f return path, O7g) were all in the fetch plane and all wrong about the location. Next: instrument `instr_queue` push/pop and the `id_stage` → issue handshake, not fetch. |
| **O7i** | Probe hazard worth remembering: a concatenated `$display` format string silently produced a NO-OP probe | L0 | `$display({"...", "..."}, ...)` compiled cleanly — `fwt_en` appears in the generated model — but the format string never reached the binary and the probe printed nothing. Indistinguishable from "nothing to report". Use a single string literal. Sixth instrument obstacle this session; the ledger of instrument-vs-machine defects is now 6:4 against the machine. |
| **O7g** | **RETRACTION: the prefix filter is NOT the mechanism behind the post-`ret` drop** | RTL | Tested the assumption instead of re-seeding it a third time. Making `slot_ge_expected` fully permissive (`G6LC_NO_PREFIX_FILTER`, now a kept switch) changes the battery **not at all** — 4/16, same tests, same modes. So (a) the filter is not load-bearing for this suite, and (b) it is **not** what drops `0x40`/`0x44`/`0x48` after a predicted `ret`. **The O7f observation stands; the O7f attribution is withdrawn.** Note this does not undo O7a: clearing the filter on architectural redirects was independently worth +2 tests, so the filter *was* the mechanism on the `mret`/flush path while something else is the mechanism on the predicted-return path. Two distinct slot-drop mechanisms, not one. Left ACTIVE: "not load-bearing for 16 minis" is weak grounds for deleting a mechanism whose comment cites OpenSBI walk scenarios absent from this suite. **Next suspects for the post-`ret` drop, in order:** `bp_fire` clearing `icache_valid_q` (frontend.sv:~871) and so discarding the return target's own registered window; `icache_take` never registering it; or `kill_s1`/`kill_s2` killing it in flight. All three are observable by extending the existing `id-dbg` probe with `icache_take`/`kill_*`/`bp_fire` rather than by another guess. |
| **O7f** | ~~shared cause is the call/return path~~ — **observation stands, attribution withdrawn (see O7g)** | RTL | Tracing `mini_fdt_next_tag_lbu` (the shallowest failure) found instructions being dropped after `ret`, exactly the O7a class but on a *predicted return* rather than an architectural redirect. Evidence: the callee epilogue retires (`ld s0/s3/s4` at `0x8000012e`-`0x132`), the return lands on `0x8000003e` (`li t0,1`) which retires, and the **next retired instruction is `0x8000004c`** — so `0x40` (`bne a0,t0`), `0x44` (`auipc t0`) and `0x48` (`addi t0,t0,188`) never retire. `t0` therefore keeps `1` from the `li`, and `bne s2,t0` compares `0x80001100` against `1`, branches to `fail_pop`, and the mini reports code 1. **The mini's logic is correct; three instructions disappeared.** Note `0x8000003e` is at offset 6 — the last halfword of its window — so the return target is maximally unaligned, the same shape as the `mret` case. This **overturns O7e**: the nine `fdt_*` minis do share a cause after all, because they all use `jal`/`ret` call-return pairs ("callee saves s2/s3 like OpenSBI"), and the differing fail depths are just where each mini's first post-return check happens to sit. My O7a fix does not cover this because it only re-bases `present_exp_q` on `flush_i \|\| is_mispredict \|\| bp_fire`, and a correctly-predicted RAS return is none of those. |
| ~~**O7e**~~ | ~~grouped-cause hypothesis is weak~~ | L4 | **Overturned by O7f** — the shared cause is control flow, not data. The three primitive eliminations still stand and were what made the O7f trace unambiguous. | Three eliminations, each one probe: (1) supply — 0 I1 violations across all 18 minis; (2) sub-word memory — `lbu`×8 offsets, `lhu`×4, `lwu`×2, byte/halfword store→load forwarding, 18/18 pass; (3) integer/BE primitives — signed `lb`/`lh`/`lw` sign-extension, `slli`/`srli`/`srai`, `addiw`/`addw`/`sllw`/`srlw`/`sraw`, and a manual 32-bit byte swap, 14/14 pass. Both probes kept on the builder as reusable primitive checks. **Two further facts argue against one shared cause:** the `fdt_*` minis each carry their OWN blob in `.rodata` (`fdt_struct`, `fdt_blob`), so there is no shared external data dependency; and they fail at very different depths (codes 1, 3, 16 — `mini_fdt_a0_is_fdt` reaching phase 16 means most of its walk works). Nine tests sharing a *name* is not nine tests sharing a *defect*. Next: trace the shallowest failure (`mini_fdt_next_tag_lbu`, code 1 at `fail_pop`, 6 s) rather than probing for more common primitives. |
| **O7c** | **Grouped sweep result: the remaining 12 failures are NOT fetch and NOT sub-word memory** | L3 | One instrumented sweep of all 18 minis with `+fetch_i1_check`: **0 I1 violations everywhere**, so instruction supply is clean for every test and no remaining failure is a fetch-supply defect. Then one 7-second directed probe killed the leading shared-primitive hypothesis: `lbu` at all 8 offsets, `lhu` at 0/2/4/6, `lwu` at 0/4, and store→load forwarding at byte and halfword granularity **all pass**. Nine of the twelve are `fdt_*` walkers, so a shared cause remains likely, but it is not sub-word load/forward and it is not supply. Next candidates by shared shape: big-endian reassembly via shifts/ORs, and the `fdt_next_tag` pointer-walk control flow. |
| **O7d** | **Honest cost of O7a that the pass-count hid: it moved 2 tests from exit-code to timeout** | RTL | Full ledger vs the 3/16 baseline — gained `mini_amoadd_w_spin` and `mini_csr_expected_trap` (exit-code → PASS); lost `mini_fdt_lenp_sw` (PASS → timeout); **`mini_fdt_s2_nest` and `mini_fdt_namelen_walk` went exit-code → timeout**, and `mini_fdt_nt_stock` went timeout → exit-code. A timeout carries **less** information than a rejection (no failing check identified, 400k cycles instead of 6k), so mode regressions are a real cost even when the pass count improves. Net: +2 pass, −1 pass, 2 modes worse, 1 mode better. Kept for the OpenSBI witness, still not done. |
| **O7b** | **Resolve the O7a regression properly: bound the valid slot count instead of filtering by pc** | RTL | Clearing the filter for one window admits the *tail* slots of the shifted window — `icache_data` is shifted left by `shamt`, so the top `shamt` halfword slots hold data from beyond the window end. Previously the `pc >= present_exp_q` filter removed them as a side effect; that is why both an over-high seed and a cleared seed break something. The principled fix is I2 itself: after an unaligned entry the realigner must present exactly `slots - shamt` valid slots and fabricate nothing past the window end, at which point the prefix filter is no longer load-bearing for redirects. That deserves a formal contract (the existing realign proof takes `data_i` free and so cannot see slot-count fabrication). |
| **O7a-detail** | evidence for the above | RTL | Traced in `mini_csr_expected_trap`. The bootrom and the whole R3 sequence now work — trap at `0x80000020` with correct cause and `mepc`, handler runs, cookie set, `mret` — but execution resumes at the **next 8-byte (FETCH_WIDTH) boundary** instead of at `mepc`: `mepc=0x80000024` → resumed `0x80000028`; `mepc=0x80000042` → resumed `0x80000048`. The skipped `csrw mtvec,t1` and `lui t3,0xe` are why `t3` becomes `0xe601+0x601=0xec02` and the cookie `bne` is taken. **Aligned redirects work** (`jr s0` → `0x80000000`, trap → handler at `0x80000060`), so the rule is: an unaligned redirect loses the partial window. I3/I7 class. **OpenSBI impact is direct**: `lib/sbi/sbi_expected_trap.S` returns to `mepc+4`, which is rarely window-aligned, so every `csr_read_allowed` probe in `sbi_hart.c` would silently skip the instruction after it. |
| **O8** | The 5 timeouts (hang, no verdict) | L4 | `mini_fdt_nt_frame32`, `mini_fdt_nt_stock`, `mini_fdt_nt_cpus`, `mini_stq_alias_jal`, `mini_fdt_nt_osbi`. All four `fdt_nt_*` hang together, so treat them as one shape, not four bugs. Lower information per run (400k cycles each) — work O7 first. |
| **O5c** | Wire `+fetch_i1_check` into the DI suite once O5b lands | L3 | It is the strongest oracle in the repo and belongs in every regression, but only after the known violation is fixed — otherwise every run drowns in expected violations and the check gets switched off. |
| **O3f** | Harden the build against stale-model builds | L0 | Three stale-instrument traps hit in one session (committed `bootrom.sv` behind `bootrom.S`; the output-cache key in `testharness_proxy.py:823` omits `core/include/*config_pkg.sv`; `grep Verilating` is not a valid "did it elaborate" probe because Verilator is silent on success). Each cost more than the analysis it interrupted. |
| **O3d** | Pin the precise-trap contract at L2 — the first proof outside the fetch plane | L2 | `W2 × issue` and `W2 × commit` are empty cells (M5). All 11 proven contracts are fetch, which is precisely why a green formal gate could not catch this. |

Deliberately **not** queued: another peel, hold-ELF cycle, or TRACE hunt for this class (H7 blocks a
second unrepaid use), and any specialisation of a proof to a package geometry (weakens it).

**AI matrix card (`Xg6lcai`) + licensing — live track (not scaffold-only):**

Phases **P0** scaffold → **P1** CVXIF T0/T1 → **P2** observability/DFT → **P3** T2 descriptor engine →
**P4** decouple `EnableAccelerator` → **P5** PCIe endpoint + virtio → **P6** torch backend.
Parallel **island track I0–I4** (throughput silicon, does not renumber P0–P6):
`architecture/ai-matrix/scaling-100tops.md` §11.
**Progress table + HARD map:** `architecture/ai-matrix/README.md` §0 · `architecture/ai-matrix/hard-tests.md`.
Transport: `architecture/uncore/pcie-endpoint.md`.

| # | Item | Phase | Status / next action |
|---|------|-------|----------------------|
| **AI-0** | ~~Tier decision: withhold the AI delta (tier P case 2)?~~ | P0 | **CLOSED — NOT ADOPTED. The AI plane rides the normal open path (tier R, dual-licensed); NOTHING IS BLOCKED.** Three findings: (1) the boundary is not clean — the delta necessarily lands in `csr_regfile.sv`/`decoder.sv`/`perf_counters.sv` (tier R) and `config_pkg.sv`/`build_config_pkg.sv`/`cva6.sv` (tier **U**, Apache-2.0 WITH SHL-2.0), so only leaf modules were ever separable; (2) it inverted its own rationale — the stated moat was the descriptor engine + verification collateral + software stack, but `verif/tests/custom/ai/**` and `software/**` are tier T (**MIT**), so it withheld the easy-to-copy MAC array and gave away the hard part; (3) it bought a freeze, not a moat. Terms are **left to the reader in the LICENSE files**: integrators take CERN-OHL-S-2.0, operators read `LICENSE.GSys-Commercial` §3.7 (AI/datacentre in-house, unchanged and undiminished — it was always a *scope*, not a right depending on the carve-out). Tier P case 2 stays **defined but classifies no path**; `E-PWITHHELD` now guards *conveyance*, not creation, and is dormant. Priors: `architecture/ai-matrix/README.md` §7 · `AGENTS-licensing.md` → *Applied case*. |
| **AI-L** | **Counsel review of the licensing pass** | P0 | **Open.** Review `LICENSE.GSys-Commercial` §3.7 (AI/datacentre in-house scope over the whole tier-R corpus) + §4.1(ii) + §4.5, `NOTICE` §2(e), and the tier-P split. Also decide whether to pursue a `LicenseRef-GSys-OHL-SN` service-use variant (AGPL-for-hardware) — **deliberately not adopted**: it would forfeit CERN-OHL-S identity and compatibility. Both `LICENSE.GSys-Commercial:15-18` and `TRADEMARKS.md:7-8` already require counsel. |
| **AI-L2** | ~~Consolidate tier R into tier P / squash post-fork history~~ | — | **Considered and rejected — do not reopen without an explicit rights-holder decision.** The open path stays as-is (tier R remains dual-licensed). History rewriting could not achieve the goal in any case: `origin/master` is published, and a grant made in a published version is irrevocable regardless of later history. Reasoning recorded in `AGENTS-licensing.md` → *internal-production / service-use gap*. |
| **AI-1** | Seam: CVXIF `COPRO_G6LC_AI` (option B) | P1 | **Live green on `ai-matrix-p1`.** Full T0/T1 + PMU/RVFI + acc `tc_sram` + aiperm + queue T0 + island MMIO. **`ai-matrix-veri` 10/10 PASS**. Still open: MBIST, FO4, smt2 ownership, PLIC. |
| **AI-P3** | T2 descriptor engine + SoC attach | P3 | **Done for spine.** AXI + sideband + PLIC-8 + DMA fetch/store + `wr_cpl_en`. Suite green. GEMM compute is **AI-S3 / I1-lite** (below). |
| **AI-E2** | **Three pre-implementation contract corrections** | P0 | **Applied to `isa-encoding.md`; review open.** Surfaced only by the scaling review, all made before any implementation exists (so not version bumps): (1) **INT4 had no encoding** — `dtype[13:12]` is fully allocated, so `aicfg[21:20]` `ew` and `[22]` `sp24` were carved from reserved space, reading `0` on parts that lack them; (2) **the T2 descriptor was not self-describing** — it inherited dtype from a mutable CSR, which is a race for a ms-long engine and undefined for host-side doorbell submission, so type now travels in `flags[14:8]` and the engine may not read `aicfg`; (3) **no QoS/preemption contract** — added §7.1 (bounded work quantum, restartability at a `k` boundary, priority classes in `flags[19:16]`, per-queue isolation, watchdog). |
| **AI-E** | **Freeze the `Xg6lcai` ISA / CSR / descriptor contract** | P0 | **Drafted — `architecture/ai-matrix/isa-encoding.md` (version 1), review open.** custom-2 (`0x5B`); custom-3 is taken by the CVXIF example. CSRs `0x800-0x803` (URW), `0x5C0-0x5C2` (SRW), `0x7C8` (MRW) — verified clear of `CSR_ICACHE/DCACHE/ACC_CONS` at `core/include/riscv_pkg.sv:655-658`. Normative for **both** seams; a seam that needs an encoding change is a defect in the doc, not a fork. Review targets: operand-class table (§2), s32→s8 round-half-to-even rule (§3.5), descriptor layout (§7). |
| **AI-E3** | **`mstatus.xs` is READ-ONLY — contract defect, corrected pre-implementation** | P0 | **Applied to `isa-encoding.md` §4/§5/§6; review open.** Version 1 said to "un-hardwire `mstatus.xs`" and let software write it. The privileged spec (`specs/riscv-spec.html:72955-73090`) says `mstatus` has "the FS[1:0] and VS[1:0] **WARL** fields and the XS[1:0] **read-only** field"; that "**every additional extension with state provides a CSR field that encodes the equivalent of the XS states**"; and that XS "reports the **maximum** status value across all user-extension status fields". XS is a *summary, never a control*. Also: "in harts without additional user extensions requiring new state, the XS field is read-only zero" — so today's hardwire is **spec-required, not a bug**. Correction: allocate **`aistatus[7:6]` = `ais`** (Off/Initial/Clean/Dirty, URW) as the extension's own status field; `mstatus.xs` becomes a read-only summary of it; the illegal-instruction gate tests **`ais`**, not `xs`. Caught before any RTL existed, so no version bump (cf. AI-E2). |
| **AI-X** | **`mstatus.xs` read-only summary driven from `aistatus.ais`** | P1 | **Done.** CSR `aistatus.ais` drives `mstatus.xs`/`vsstatus.xs`; coprocessor reads `ais` over sideband and rejects issue when Off; Dirty pulses from exec write back into `aistatus`. |
| **AI-2** | **`g6lc64_server_math_v` violates the superscalar/accelerator assert** | — | **Open, pre-existing, independent of AI work.** Package sets `SuperscalarEn: bit'(1)` / `NrIssuePorts: unsigned'(2)` (`core/include/g6lc64_server_math_v_config_pkg.sv:103-104`) **and** `RVV: bit'(CVA6ConfigVExtEn)` with `CVA6ConfigVExtEn = 1` (`:122`, `:44`); `EnableAccelerator` is *derived* from `RVV` (`core/include/build_config_pkg.sv:37`), so the mutex assert at **`core/cva6.sv:2414`** (`!(SuperscalarEn && EnableAccelerator)`, "Accelerator is not supported by superscalar pipeline") is violated by construction. Survives only because the assert is `translate_off initial` (so it needs Verilator `--assert` to fire) and Ara is normally a stub — a real sim should `$fatal` at t=0. Blocks option D; **shared** with the vector track. **Queued 2nd in the SL resume order** (above), because the offending package is `g6lc64_server_math_v` — the *full-stack Linux-boot bar* that `linux-boot-scale.md` §1 says smt2 work must not regress. That makes the three obvious moves all unacceptable as-is and the decision, not the edit, is the open work: dropping `SuperscalarEn`/`NrIssuePorts=2` changes the I4dp-green package; dropping `RVV` defeats it; promoting the assert into `check_cfg` makes it fail elaboration and takes the golden boot with it. **Investigated 2026-08-29 — the mutex is REAL and structural, and the fix is 2 lines.** The accelerator issue seam is single-port *by construction*: `issue_stage.sv:229-230` hands `acc_dispatcher` only port 0 (`issue_instr_o = issue_instr_iro[0]`, `issue_instr_hs_o = issue_instr_valid_iro[0] & issue_ack_iro[0]`) and `cva6.sv:2139` hands it only `fu_data_id_ex[0]`. Meanwhile **nothing stops an `ACCEL` op from being acked on port 1**: the `fu_busy` case (`issue_read_operands.sv:459-485`) has no `ACCEL` arm, so `fu_busy` is always `0` for it; the per-port force-busy block (`:389-394`) forces only `.csr`/`.cvxif` for `p>=1`; and the FU-valid case (`:1023-1061`) sets no FU valid for `ACCEL` at all. An accelerator instruction acked on port 1 is therefore never dispatched to Ara and never written back, so its scoreboard entry never completes and **commit deadlocks**. This has nothing to do with Ara being a stub, so "narrow the assert for the stub path" is dead. **Cheap correct fix that none of the earlier framings saw:** make the already-declared-but-never-used `fus_busy_t.accel` field (`:157`) live — add `fus_busy[p].accel = 1'b1;` beside the existing `.csr`/`.cvxif` lines at `:392-394`, and `ACCEL: fu_busy[i] = fus_busy[i].accel;` to the case at `:459-485`. That pins every accelerator op to port 0, where `issue_instr_o` and `fu_data_id_ex[0]` are correct, making `SuperscalarEn && EnableAccelerator` legal **by construction** — no `_v` config change, no `I=1` re-soak, no loss of RVV — after which `cva6.sv:2414` is narrowed with a recorded reason instead of being violated. **Deliberately NOT landed here:** that block *is* the dual-issue throttle, `core-fetch/SPEC.md` §9.6 says "do not touch the issue throttle (RC1/RC4) until R6–R11", and it would touch both I4dp-green Linux boots. Land after S1 behind gates: I4dp `_v` + `ooo_server` 200M `tohost=0`, `ara-vector-cosim`, `ara-vector-path`, `mc-spo-veri`. |
| **AI-3** | T2 descriptor engine address-checking | P3 | **Landed in spine.** `g6lc_ai_addr_check` per-queue `[base,limit)` + R/W; engine checks ptr_a/b/c/scale/done before accept. Standalone smoke rejects OOR and W-only. Still open: scrub/bank-partition between queues; bind checker in front of real DMA master. |
| **AI-S0** | ~~Size the 100-TOPS class~~ | I0 | **Done — `architecture/ai-matrix/scaling-100tops.md`.** Froze the definition (100 TOPS ≙ dense INT8, peak, 2 ops/MAC, no sparsity/INT4 multiplier); derived DRAM BW = (2/T)×MAC-rate ⇒ 391 GB/s at blocking T=256; machine balance ≈125 MAC/byte. Reversed three draft positions: chiplets **deferred** behind a die-size gate, island knobs **out of** `cva6_cfg_t`, on-die SRAM **8–32 MB** not 32–128 MB. |
| **AI-S1** | ~~SKU decision: latency/decode vs throughput/serving~~ | I0 | **Closed — BOTH, STAGED: latency SKU first, throughput SKU by cluster replication** (`scaling-100tops.md` §5.1). Rationale: at `T=512` the throughput SKU needs only 195 GB/s of GEMM bandwidth, while the latency SKU must buy ~400 GB/s anyway for batch-1 weight streaming — **so the expensive subsystem is built and measured first and covers both**, and adding compute later is pure cluster replication. Track order changes to I1 → I3 → (latency tape-out) → I2. Five binding conditions in §5.1: `T`/accumulator/DRAM frozen at I1; cluster is the only replication unit and the NoC cut line is set at I1; capability window ships at I1; cluster-**cooperative** blocking from the first cluster (independent per-cluster blocking collapses effective `T` to 64 and demands ~1.6 TB/s); both SKUs quoted with §12 metrics. |
| **AI-S2** | Seam decoupled from throughput target | I0 | **Recorded.** ~99.7% of island arithmetic never crosses a core seam, so the card SKU may ship on **seam B**; option D is now a small-SKU/latency feature. **Consequence: AI-2 is off the card's critical path** (still blocks the vector track). `README.md` §2 amendment. |
| **AI-S3** | Island RTL: cluster → memory → (latency SKU) → NoC/N clusters → PD | I1, I3, I2, I4 | **I1 partial + I3-lite live; HARD + host green.** AccTile/PeLanes 256; CPL FIFO multi-claim; peak 256³ **83.7k cy**. **I3:** LiteDRAM vendored+generated; **DramChannels** is a **shared DRAM-slave** stripe (cores + L2 + `NrCores` + island), not `cva6_cfg_t`, not I2. Live N=1 class 0 (identity). Class-0 N=2 SRAM: `G6LC_AI_DRAM_SIM_CHANS_2` / `AiIslandSimChans2`. Class-1: `G6LC_AI_DRAM_CLASS1` (19 GB/s) / `G6LC_AI_DRAM_CHANS_2` (38 GB/s). GEMM INCR is capped to the 64 B stripe when N>1 (N=1 MaxBurstBeats=255 unchanged). Stability plan: `architecture/uncore/dram-channel-scaling.md`. HARD **narrow** / **ci 27/27** / **peak**. **`tensor virt-impl --impl hard --suite narrow --require-hard` PASS**. Class-0 N=2/4/8 SRAM + class-1 N=1/2/4/8 LiteDRAM smokes **PASS**. Wrap **id6 1445 cy** native gearbox (**NrArSlots/NrAwSlots=8**, eight AR/AW live / 9th backpressure, mixed AW+AR, L1 16 B, WRAP SLVERR, AXI held until `init_done`); testharness live cookie pulp atomics (1 AR/AW); S4/CLASS1 `g6lc_axi_lrsc` eight regular AR/AW + LR/SC snoop; class-1 PHY N=1/2/4/8 **375/416/448/453 cy** (N=1 two IDs on one wrap). Island GEMM **PASS** class-0 N=1 **175 cy** / N=2 **356 cy** / N=4 **405 cy** / N=8 **503 cy**, class-1 N=1 **336 cy** / N=2 **681 cy** / N=4 **821 cy** / N=8 **1162 cy** (golden C=16, CAP match, wide `lda=64` all-NCH occupancy). Class-1 N=8 PHY **PASS 408 cy**. S5 occupancy CAP decode **PASS** 47 cy (testharness wired; GEMM PMU stays aggregate). `AiIslandDdr4x{2,4,8}Bringup`; testharness `CHANS_{2,4,8}` / `SIM_CHANS_{2,4,8}`. Directed class-1 `--sim` 256-beat stream **2048 beats / 2085 cy = 7858 milli-GB/s (98% of 8 GB/s fabric)** — 80% gate **closed**. GEMM class-1 N=1/2/4/8 **336/681/821/1162 cy** (N=1 identity ch0-only). Testharness CLASS1 slave uses the same wrap/MaxAROut. DTS↔CAP `0x38` **PASS** (live 1/6; CLASS1 N=2 is 2/6). Nameplate `island_cfg_legal` **PASS** (refuse 400 / NoC-8 / N=3). Variane opt-in: `AI_ISLAND_DRAM_CLASS1=1` / `CHANS_{2,4,8}=1` → work-ver-ai-d{1,2,4,8}. **CLI (OoO-shaped):** `diag run ai`, `test --ai`, `test --ai --channels 4 --ai-dram 1`, `test --ai-remote` (ai-dt), `test --ai-qemu` / `g6q --ai` (not Variane), `--from-timing` on test/diag/tensor. **S4 Variane `ai-dt` PASS:** `test --ai-remote` → `tohost=1` after **2899 cycles** (`g6lc_axi_atomics_wrap`) (`remote-runs/s4-mshr-xbar/run-ai-dt.log`). Post-loop `getenv("CVA6_TRAP_DUMP")` SIGSEGV was TB, not RTL (classify now prints SUCCESS first). `work-ver-ai-dt` 38 Mi, jobs=1 `-O0`. CLASS1 ELF preload is LiteDRAM **native** (`G6LC_LITEDRAM_PRELOAD` + wrap `pl_*`; cluster held; `gen_sim_axi.i_sram` not elaborated). Variane **`ai-d1` PASS:** `S4_FLAVOUR=ai-d1` → `tohost=1` after **5363 cycles** (`run-ai-d1.log`; preload 20 native words). Variane **`ai-d2` PASS:** N=2 stripe → `tohost=1` after **5758 cycles** (`run-ai-d2.log`). Variane **`ai-d4` PASS:** N=4 → `tohost=1` after **5762 cycles** (`run-ai-d4.log`). Variane **`ai-d8` PASS:** N=8 → `tohost=1` after **5821 cycles** (`run-ai-d8.log`). CLASS1 {1,2,4,8} closed. S4 parks hart 1: `ai-dt` **2620 cy**, `ai-d1` **4246**, `ai-d2` **4520**, `ai-d4` **4553**, `ai-d8` **4582**. Dual-core stripe+occupancy **830/900/582 cy** on `ai-d2`/`ai-d8`/`ai-sc{2,4,8}`. All-N occupancy **1328/889 cy** on `ai-d8`/`ai-sc8` (CAP `0x38` N, `0x70+4*i`). Exclusive `amoadd.d` **484/668/861 cy** on `ai-dt`/`ai-d1`/`ai-d8`. `g6lc_axi_lrsc` in front of AMOS; address-only reservation. Isolated lrsc **130 cy**; wrap-stack SC **PASS 104 cy** (split-ID included). Exclusive Variane **PASS `ai-dt` 552** / CLASS1 **`ai-d1` 781** / **`ai-d2` 945** / **`ai-d4` 941** / **`ai-d8` 941 cy** — CLASS1 exclusive {1,2,4,8} closed. Dual-core snoop **PASS `ai-dt` 16667** / CLASS1 **`ai-d1` 17137** / **`ai-d2` 17137** / **`ai-d4` 17163** / **`ai-d8` 17187 cy** — CLASS1 snoop {1,2,4,8} closed. Live `ai-d1` **vthreads=12** rebuild **1334 s** **41.7 Mi**. Live `ai-d2` **vthreads=12** **42.9 Mi**. Live `ai-d4` **vthreads=12** **47.4 Mi**. Live `ai-d8` **49.1 Mi** vthreads=12. Class-0 stripe exclusive **`ai-sc2`/`ai-sc4` PASS 620 cy** / snoop **16686 cy** (`g6lc_axi_atomics_wrap` + `DRAM_EXCL_AW=8`; cookie pulp `dram_aw_out` stays 1). `ai-sc8` still older Mdir. Dual-core OpenSBI soak stays on the class-0 cookie path — **not** I2, **not** 400. **Q6 emulator close (2026-09, host-verifiable):** the in-guest plane is now real rather than bookkeeping. (a) **`g6q-vm` computes the GEMM** — new `crates/g6q-vm/src/gemm.rs` reads A/B from guest memory and writes `C` (`ldc = n`, s8×s8→s32) with every op/status/tile bound taken from the ingested model; F12's tile bound is enforced and returns the package's own `ST_ERR`, a sub-byte/sparse request the CAP window does not grant returns an error instead of quietly running dense s8. (b) **Control surface** `CTL`/`STATUS`/`DOORBELL`/`CPL` ingested from `REG_OFF_*` and implemented, so a guest drives a job end-to-end through MMIO alone (`a_guest_can_drive_a_gemm_entirely_through_the_published_mmio_window`, C = golden). (c) **Four ingest defects fixed** — the reader could not parse the live packages at all (`RTL_FEEDBACK.md` §2.2): named constants in SKU literals, symbolic cap-window case labels, `CAP_BLOCK_*_SHIFT`/`AiIslandDtypeMask`, `FLAG_*_SHIFT` accessors. Every F-row that said "published" was untested until this. (d) **A derived-vs-published collision** — status was placed at `desc_base + desc_bytes` = `0x180` = `PMU_OFF_R_BEATS` (§2.3). (e) **`ai-tensor` gains the `qemu-uio` backend** (`python/ai_tensor/qemu_uio.py`, 19 protocol tests) — CAP discovery, AI-3 region program, latch, doorbell, IRQ/poll, DONE-claim-before-PLIC-complete, host tiling beyond AccTile. (f) **Guest enablement**: `ariane-ai.dts` gains the `generic-uio` fallback compatible, a `no-map` operand carve-out and `memory-region`; OpenWrt gains `CONFIG_UIO`/`CONFIG_UIO_PDRV_GENIRQ`/`CONFIG_OF_RESERVED_MEM` + `uio_pdrv_genirq.of_id` (patch re-verified with `git apply --check`). Gates: **`python tools/g6q.py check` is GREEN — it was red at HEAD** (independence + fmt + clippy + workspace test). `cargo test --workspace` **560 pass / 0 fail in parallel and serial**; at HEAD the same command is **531 / 6** serial plus a parallel-only Windows file race (two `loader::tests` sharing `out/loader-run/esp-openwrt`, now serialised by a test mutex). Also cleared en route: 3 pre-existing `g6q-cli` clippy errors. `ai-tensor` qemu-uio **19/19**, independence + C-ABI lockstep OK; DTS validator no new findings (its one FAIL is the pre-existing vendor `xg6lcai` token); `ai-tensor` independence + C-ABI lockstep OK. **Not Variane evidence** (`AGENTS.md` §0.8: no verilator on this host). Still open for I2: emitted-QEMU-C `sysbus_connect_irq` for the island, and `0x110`/`0x114`/`0x118` as localparams. |
| **AI-5** | **`cv32a65x` lint baseline is stale — pre-existing, NOT AI** | — | **Open, unrelated to this track; do not attribute it to AiCfg.** `verify --lint` reports **190 warnings vs baseline 146** (`build-platform/src/config/defaults.ts:1185`) and fails the gate; `cv64a6_imafdc_sv39` drifts the other way (410 vs baseline 483, passes). Attribution measured with the platform's exact `lintArgs`: the entire AI config surface accounts for **0** warnings — the only `config_pkg`-family citation is the pre-existing `build_config_pkg.sv:287` `AXI_USER_EN` WIDTHEXPAND. Top contributors are `core/ooo/g6lc_rob.sv` (**27**), `cva6_hpdcache_if_adapter.sv` (**17**), `csr_regfile.sv` (**16**) — i.e. U5 OoO + cache work. The baseline comment itself says it was last re-measured 2026-08-06; commits have landed since. Action: re-measure and ratchet both baselines, or fix `g6lc_rob.sv`'s ASCRANGE/WIDTHEXPAND. |
| **AI-S4** | Card power/thermal envelope | I4 / P5 | **Open.** Estimated 60–80 W typical / 100–150 W peak ⇒ the 75 W slot budget is insufficient: 8-pin aux, boot-time power negotiation, and a mandatory DVFS/throttle cap loop. `architecture/uncore/pcie-endpoint.md` §3.1. All figures unmeasured — replace at I4. |
| **AI-X1** | **LR/SC single-reservation defect on every multi-channel / class-1 DRAM build** | I3 | **Fix landed and PROXY-VERIFIED with a valid oracle.** Variane `ai-dt`: fixed netlist (`NRes=NR_HARTS=2`) **SUCCESS `tohost=1` 16602 cy**; pre-fix netlist (`+define+G6LC_AI_LRSC_SINGLE_RES` ⇒ `NRes=1`, verlib `work-ver-ai-1res`) **FAILED `tohost=9` 16580 cy** = `fail_lrsc`, hart 0's `sc.d` refused with nothing having written its address. So the defect reproduces on the real netlist, the new gate detects it, and the fix resolves it. Regression: `ai-dual-core-excl` **PASS 16667 cy**, bit-identical to the recorded baseline, so the same-address snoop path is unchanged. Second DRAM path confirmed: on `ai-sc2` (class-0 stripe N=2, demux + `DRAM_EXCL_AW=8`) disjoint **PASS 16617 cy**, snoop **PASS 16686 cy** (again matching its baseline), numfmt **PASS 1316 cy**. The remaining six flavours differ only in `MaxOut`/channel count, which are orthogonal to `NRes`. The `ifdef` seam is kept deliberately — rediscovering this negative costs a 22-minute harness rebuild. `g6lc_axi_lrsc` held **one global reservation**, so two harts reserving *different* addresses destroyed each other's: `lr.d A` / `lr.d B` / `sc.d A` fails forever, with no guest-side remedy. Selected on **any** `G6LC_AI_EXCL_MULTI` build (all `G6LC_AI_DRAM_*` / `SIM_CHANS_*` / `TIMING` defines), so it blocked OpenSBI/Linux spinlocks and `__atomic` CAS on exactly the configurations AI-S3 introduces. **`ai-dual-core-excl` could not see it** — one line in play, so a global reservation passes. Now an `NRes`-entry address-keyed table sized from `NR_HARTS`; address-keyed because HPDCACHE LDEX/STEX use different AXI IDs, so there is no hart id at this seam. `NRes=1` reproduces the old behaviour for bisection. New gate `ai-dual-core-lrsc-disjoint` (`verif/tests/custom/ai/ai_dual_core_lrsc_disjoint_smoke.S` + `verif/regress/remote/ai-dual-core-lrsc-disjoint.sh`) fails with `tohost=9` on the defect. Detail: `architecture/uncore/dram-channel-scaling.md` §5.2 rule 7a. Also open: `corev_apu/coherence/g6lc_lr_sc_tracker.sv` is a *second* monitor on the hub path — the two must not both claim the reservation on one build. |
| **AI-X2** | **Numeric formats FP32 / BF16 / FP16 / FP8 / INT8 / INT4 as one config parameter** | I1 / P1 | **Contract/config + INT8/INT4 GEMM landed; standalone scalar FP verified, floating GEMM integration open.** `ai_cfg_t.FormatMask` (core plane) and `AiIslandDtypeMask` → `CAP_OFF_DTYPE_MASK` (island plane) are bitmaps over **one** enumeration, `config_pkg::AI_FMT_*`, so consumers share the format encoding rather than a translation table; descriptor grants use the effective format after legacy INT + EW=1 resolves to INT4. Request field is `numfmt`: `aicfg[25:23]`, descriptor `flags[22:20]`, both from reserved space with `AI_FMT_INT == 0`. Descriptor `ContractVersion` is now **2** for k-major B (AI-X9); stale version-1 descriptors are refused, not reinterpreted. Island **fails closed** with new `ST_BAD_FMT = 8` in `ST_PARSE` (before any operand fetch); core plane keeps §3.1 downgrade-on-grant. The two differ deliberately: a descriptor may come from a host process that never reads a grant word, and demoting BF16 to INT8 returns plausible wrong numbers. `check_cfg` pins mask↔`Int4En`↔`Sparse24En` agreement, requires `AI_FMT_INT`, requires `RVF` for any float and `RVD` for FP32. **Live island grant and PE implementation masks are INT8/INT4 only** (`AiFmtMaskInt8Int4`, `16'h0003`); floating grants remain blocked on loaders/array integration despite the standalone scalar FP primitive. **Emulator + host stack support seven native encodings in software** (`g6lc_qemu/crates/g6q-vm/src/numfmt.rs`): INT8, INT4 (two per byte), FP8 E4M3, FP8 E5M2, FP16, BF16, FP32, with integer accumulation in `i32` and float in `f32` to match the 32-bit `C` the ABI defines. The emulator **still refuses what the design refuses** — it gates on the ingested `CAP_OFF_DTYPE_MASK`, so the live SKU computes INT8/INT4 only, like the RTL; the wider software fixture is an explicit hypothesis, not a new hardware capability. Host side: `ai_tensor_abi::NumFmt`, `DType`→`numfmt` lowering with `Gemm::lower_checked` refusing against discovered caps, and `ai_tensor.c_abi` dtype mapping that **raises** on an unmapped framework dtype rather than approximating it. Verified: `g6q check` GREEN, 15 format-arithmetic + 6 GEMM-level Rust tests, 10 IR tests, 38 Python tests; `ai-tensor` 67 pass / 1 pre-existing virt-card failure (reproduced at HEAD). Per-format MAC ratios (INT4 2×, FP16/BF16 ½, FP32 ¼ of dense INT8) exist as a **modelled** table only and may not be quoted as throughput. Datapath in RTL remains the open item. Verified: `g6q check` GREEN (ingest re-parses all edited packages); Variane `ai-dt` **elaborates and Verilates clean**, so the new `check_cfg` asserts and the `ST_PARSE` arm are live; **`ai-numfmt-grant` PASS 1310 cy** proving the refusal actually fires — `AI_FMT_INT`→`ST_OK`, `BF16`→`ST_BAD_FMT`, `FP32`→`ST_BAD_FMT`, `AI_FMT_INT`→`ST_OK` again. Two-sided, so no separate negative control is needed, and it does not soft-pass on a trap. Docs: `isa-encoding.md` §3.1a. Remaining: PE datapath per format, `ai-tensor` dtype→`numfmt` lowering, per-format TOPS reporting kept separate from dense INT8. |
| **AI-X8** | **Odd `n` returned a wrong trailing C element — accepted, `ST_OK`, plausible garbage** | I1 / P0 | **FIXED and verified: `ai_gemm_s8_oddn_smoke` PASSES 1369 cy (was `tohost=13`).** Fix: the C store now decides pair-vs-single **per ROW** (`can_pair = !n_q[0]`) instead of per position, in *both* the ST_MAC trail store and ST_STC, so a row never transitions pair→single midway and never needs two AW transactions. Cost: an odd-`n` C row takes `n` beats instead of `ceil(n/2)`; C store is overlapped with MAC and odd `n` is rare, so this is the cheap side of the trade. **The race itself was never root-caused to a line** — the fix removes the construct rather than explaining it, which is exactly why all four bisection fixtures stay in the suite: if the underlying hazard is still live it resurfaces the next time the store path is reshaped. Original finding and bisection below. **REPRODUCED and scoped by experiment.** Found while building the operand-layout oracle for AI-X9. `m=2, n=3, k=4` completes with `ST_OK` and the correct ticket, and returns `C[0][0]=70` ✓, `C[0][1]=80` ✓, **`C[0][2]` wrong** — i.e. only the trailing element of an odd-length row. This is the fail-silent class the descriptor package is explicit about avoiding, and `ST_CHK` does not refuse it: it checks `n != 0`, `n <= MaxDim`, `ldb >= n` only, so odd `n` is *accepted* and computed wrongly. **Why nothing caught it:** every pre-existing AI GEMM golden has an even `n` (2, 4, 16, 64, 128, 256). **Scope narrowed by three runs on one unchanged `ai-dt` netlist:** `ai_gemm_s8_n1_smoke` (n=1 → `can_pair` false always, single-i32 path *only*) **PASSES 1204 cy**; `ai_gemm_s8_asym_smoke` (m=2 n=4 k=6, pair path only) **PASSES 1407 cy**; `ai_gemm_s8_oddn_smoke` (n=3, one pair *then* one single) **FAILS `tohost=13` 1320 cy**. So neither store path is broken in isolation — the defect is in the **pair → single transition**: the `stc_elem`/`stc_j` cursor accounting and the shared `aw_sent_q`/`w_sent_q` flags when the last pair does not divide the row and the row therefore needs two AW transactions. A read-latency explanation is **excluded**: both paths drive `w.data` in the same cycle as the C tile read, so the even-`n` pair path would fail too. Second live candidate: the trail-store hazard predicted in `numeric-formats-datapath.md` §5.1, since F0b-2's delayed C write lands a row's last element one cycle after its issue and for odd `n` that element is carried by a separate later AW at the row boundary. New fixtures `verif/tests/custom/ai/ai_gemm_s8_{asym,oddn,n1}_smoke.S` + one shared runner `verif/regress/remote/ai-gemm-asym.sh <test>` with per-check exit codes (3=status, 5=trap, 7=ticket, 9+2e=C[e], 31=timeout) so a failure localises without a waveform. **Do not close this by forbidding odd `n`** — that hides a datapath defect behind a legality check. |
| **AI-X10** | **Multi-channel B load corrupted C when an operand row straddled an AXI beat** | I1 / P0 | **Self-inflicted by the AI-X9 rewrite, found and fixed in the same session.** The shared AR-slot bookkeeping retires a burst's column cursor with a per-state bound. `ST_LA` bounds against `k_bytes`; `ST_LB` still bounded against `n_q`, which was correct while B was row-major (its rows ran along j) and **wrong** the moment AI-X9 made `col` a byte offset along `t`. The slot then rolled its row at the wrong point and corrupted C. Only reachable on `SplitArId` builds (`NrChannels > 1` **and** `PeLanes >= BytesPerBeat`, e.g. `ai-sc2`) **and** only when a row stride does not divide `BytesPerBeat`, so no power-of-two fixture can produce it — which is why the whole earlier flavour sweep was blind to it. **Bisected in three 20 s runs on two flavours:** `ai_gemm_s8_asym_smoke` (m=2 n=4 k=6, both strides = 6) PASS on `ai-dt` / **FAIL `tohost=13`** on `ai-sc2`; every power-of-two fixture PASS on both; and the new `ai_gemm_s8_astraddle_smoke` (same shape, `ldb` padded to 8 so **only A** straddles) **PASS on both** — which is what proved the untouched `ST_LA` was innocent and the fault was in the new `ST_LB`. Fix: both load states now bound against `k_bytes`, since `col` is a byte offset along the row in both. **Lesson worth keeping:** the layout change was verified on a single-channel flavour and looked complete; the defect lived entirely in the multi-channel path, and the fixture that exposed it is the first non-power-of-two shape the suite ever had. Non-power-of-two dims belong in the standing suite, not just in bring-up. **Swept on `ai-d8` after the fix** (8-channel class-1 LiteDRAM, the widest `SplitArId` config): 8/8 PASS — smoke 1738, asym 2092, astraddle 2093, oddn 1968, s4 1716, s4_oddk 1716, 4x4 2587, n1 1547 cy. So the fix holds across N=1 (`ai-dt`), N=2 (`ai-sc2`) and N=8 (`ai-d8`). |
| **AI-X9** | **Operand layout: B is now k-major; the ABI break that makes the format path common** | I1 / F | **LANDED and verified.** `ContractVersion = 2`; `g6lc_ai_gemm_seq.sv` went **1677 → ~1520 lines** (the change removes code, as predicted): `ST_LB` now mirrors `ST_LA` (burst along `t`, row cursor `j`), and the oct-drain (`beat_q`/`beat_lane_q`/`beat_left_q`), the `b_w2..b_w8` fan-out and the B tile's `NumPorts(8)` are **deleted** — 1R1W like A. New `CAP_OFF_LAYOUT = 0x4C` publishes `a_k_major`/`b_k_major` so software discovers the layout instead of inferring it from a version it may not read; mirrored as `mmio::CAP_LAYOUT` host-side. Emulator: B row base `t*stride` → `j*stride`, element index `j` → `t`, `ldb < n` → `ldb < k`; `read_elem` needed no change (already index-based). 17 fixtures bumped to version 2, `ldb` corrected where `n != k`, `mat_b` transposed in the data-bearing ones. **Measured on one `ai-dt` netlist:** `smoke` **1212 cy** and `lda` **1212 cy** (both identical to the row-major baseline), `4x4` **1612 cy** (was 1673 — *faster*, the §8.7 tall-skinny case since k=8 > n=4), `asym` **1375**, `oddn` **1369**, `n1` **1154**, `m1n3` **1218**, and `64x64` **93,194 cy bit-identical to the baseline with 0 assertions**; `g6lc_qemu` workspace **583/583**, `ai-tensor-abi`+`ir` **15/15**. **The 64×64 result settles the throughput question by measurement:** the 8-port B tile and the oct-drain were deleted and the large-fixture cycle count did not move by one cycle, so the six extra write ports per bank on the island's largest SRAM were buying nothing. `smoke` accepting a version-2 descriptor is itself proof the netlist carries the change — a stale build answers `ST_BAD_VER`. Analysis and rejected alternatives below. **Analysed and decided; documented.** `architecture/ai-matrix/numeric-formats-datapath.md` §8. F1's MAC slice landed and then blocked in the *load* path, and the resolution turned out to be an ABI change. Precise constraint: **a sub-byte format forces the packing axis to equal the reduction axis** (two INT4 nibbles in one byte must feed the same `C[i,j]`, so they must be consecutive `t`); every ≥1-byte format is indifferent. So this is a sub-byte problem, not a general format problem, and "one common path" is a benefit the ABI change *buys*. Three candidates weighed: (i) in-loader nibble transpose — ABI-free but ~2× B load latency, cancelling INT4's point; (ii) 2×2 INT4 micro-tile — full 2× and ABI-free, but needs two accumulators and 2× C writes, reopening exactly the protocol F0b-1/F0b-2 cleaned up; (iii) **B supplied k-major** (`B'[j,t]`, `ldb = k`). **(iii) chosen because it removes code**: the B *tile* is already k-contiguous (`b_bank_addr(t,j) = j*KPerBank + t/PeLanes`), so only the memory traversal changes, and streaming along `t` makes B's loader structurally identical to A's — deleting the oct-port drain (`beat_left_q`/`beat_lane_q`/`beat_q`, `b_w2..b_w8`) and dropping the B tile from `NumPorts(8)` to `2`, a real saving on the island's largest SRAM. Throughput is byte-identical (`k` bursts of `row_bytes(n)` → `n` bursts of `row_bytes(k)`), better for tall-skinny, `MaxAROut`-mitigated for wide-flat. **The ABI break is smaller than it looks:** `torch.nn.Linear.weight` is stored `[n,k]` row-major and `F.linear(x,W) = x @ Wᵀ`, so k-major B *is* the layout the caller already has — the current contract is the one forcing a transpose of every Linear weight. General GEMM keeps `OP_LAYOUT` (opcode 3, already reserved and already accepted). **Versioning:** the `AI_FMT_INT == 0` no-break reflex does **not** apply — live grants are INT8-only, every `ldb` consumer is in-tree, the island is pre-tape-out — so `ContractVersion` goes to **2** with one path, rather than a `FLAG_BT` bit that would leave two loaders forever. **Precondition met:** the suite was layout-blind (large fixtures fill `mat_b` with all ones; small ones are square), so a wrong transpose passed everything. `ai_gemm_s8_asym_smoke` (m=2 n=4 k=6, distinct B values, would give `C[0][0]=91` instead of `301` under the wrong layout) now exists and **PASSES on the pre-change row-major RTL 1407 cy**, so it is proven before it is asked to prove anything. Remaining: `ST_LB` traversal swap + deletions, `ldb_q < n_q` → `< k_q`, `ContractVersion = 2`, transpose `mat_b` in the three data-bearing fixtures, `g6q-vm/src/gemm.rs` B index `t*ldb + j` → `j*ldb + t`, `ai-tensor-abi` `Gemm::new` `ld_ab = k \| (k << 16)`, publish the layout in the capability window, and re-measure `ai_gemm_s8_64x64_smoke` against its **93,194 cy** baseline. |
| **AI-X7** | **Hardware numeric formats: analysis + F0a/b (tree + pipeline + accumulator split) landed; the INT8 baseline did not close timing** | I1 / F | **F0a/F0b verified; F1 INT4 COMPLETE and verified end-to-end; standalone scalar FP widening/MAC now verified, floating GEMM/F2–F5 array integration still open (see continuation above).** F1 landed in four slices: **F1-PE** (2*Lanes reduction, two sign-extended nibbles per byte through the existing signed 8×8 cell), **F1-sequencer** (`t` advances by `2*PeLanes`, lane p reads byte `(t/2)+p`, invalid nibble masked on an odd-k tail), **AI-X9** (k-major B, which is what made a sub-byte format expressible at all), and **F1-load** (both loaders count `t` in **bytes** against `k_bytes = fmt_row_bytes(k)`, so a packed row is fetched at its real length instead of 2× over-fetched). Grants raised in lockstep to `16'h0003` (`AiFmtMaskInt8Int4`) in **both** `AiIslandDtypeMask` and `AiIslandPeImplMask`; the `grant ⊆ implemented` elaboration assert is the build-time proof they did not drift. Verified: `ai_gemm_s4_smoke` **1230 cy** (operands span the INT4 endpoints −8..7, `−8×−8=+64` present so a sign-extension slip shows, and 3 of 4 golden C values are **negative**) and `ai_gemm_s4_oddk_smoke` **1230 cy** (k=3, so the second byte is half padding; the pad nibbles are deliberately non-zero and would give `C[0][0]=47` instead of `5` if the mask were missing). All seven INT8 fixtures keep their **exact** cycle counts, which is expected by construction since `k_bytes == k_q` for INT8. Both INT4 fixtures also **PASS on `ai-sc2`** (1146 cy). **MEASURED, and the answer is negative:** `ai_gemm_s4_64x64_smoke` is the INT4 twin of the INT8 64×64 (byte-identical descriptors except `flags.numfmt`, same all-ones operands, same golden C=64 across all 4096 elements) and runs **93,177 cy vs 93,194 cy — a 17-cycle, 0.02% difference.** Halving the operand bytes bought essentially nothing, for three reasons that are all correct behaviour: (1) the MAC cost is identical by construction, since at `PeLanes ≥ 64` one issue covers all of `k=64` for both formats and INT4's extra lanes sit *idle* at this k; (2) the load is **latency**-bound not byte-bound — both formats issue the same 64 AR transactions per operand and INT4 only shortens each burst, which barely helps at `MaxAROut = 2`; (3) the 93k wall clock is mostly boot/setup/poll/check, not GEMM. So §2's "INT4 = 2×" is an argument about a **DRAM-bandwidth-saturated** regime, and a 64×64 SRAM-resident tile is not in it. Honest claim: *INT4 halves operand traffic, a bandwidth-regime win not observable on these fixtures.* **Nothing here licenses an "INT4 throughput" number.** `ai_gemm_fmt_pmu_smoke` would sharpen this via the island's own `AI_PMU_CY` (0x188) with a strictly-faster oracle, but needs `S4_TIME_OUT=3000000` and has produced no number yet. **Byte-counting loads are what unblock F2–F5:** FP8 needs *no* load change (1 byte/element), and BF16/FP16/FP32 need one line in `fmt_row_bytes` each, leaving only the MAC-side gather and the multiplier. Original F0a/F0b record below. `architecture/ai-matrix/numeric-formats-datapath.md`. Three findings reorder the work: **(1)** `g6lc_ai_pe_dot` reduced with a **linear chain of `Lanes` 32-bit adders** — 256 deep at live `PeLanes`, ~25 ns, order **39 MHz** against a 1.0 GHz island clock, so the *existing INT8 datapath* was off by >10×. Now a balanced tree, depth 8, bit-identical by associativity of two's-complement wrapping addition. **(2)** Equal MAC rate is **bandwidth-bound, not multiplier-bound**: bytes/MAC = `2w/T`, so at `T=256` and 50e12 MAC/s, INT4 needs 195 GB/s (2× INT8 throughput possible), INT8/FP8 391 (1×, the LPDDR5 balance point), BF16/FP16 781 (½), FP32 1563 (¼). **(3)** Multiplier cost is **significand** width, so BF16's 8-bit significand is exactly the existing signed 8×8 cell while FP16 needs 11×11 — order F1 INT4 → F2 FP8 → F3 BF16 → F4 FP16 → F5 FP32, with block-floating-point accumulation into the same integer tree. **F0b-2 done:** `sum_q <= pe_sum`; drain computes `acc_d = (first_q ? '0 : acc_q) + sum_q` and writes `C` at `(sum_i_q, sum_j_q)` if `last_q`; indices advance at issue rate. Verified: `ai_gemm_s8_smoke` **1212 cy**, `ai_gemm_s8_4x4_smoke` **1673 cy**, `ai_gemm_s8_lda_smoke` **1212 cy**, `ai_gemm_s8_64x64_smoke` **93,194 cy** — all with 0 assertions and **identical** small-fixture counts to F0b-1 (the pipeline is fully hidden). `g6lc_ai_pe_dot` no longer has `acc_i`/`acc_o`. Grants stay `16'h0001`; timing closure is `sv-timing`'s later pass. |
| **AI-X5** | **`--assert` was missing from `verilate_command`, so EVERY assertion in the design was dead in the Verilator flow** | P0 / gate | **FIXED and verified — assertions now compile in and enforce.** `Makefile` gains `verilator_assert ?= --assert` (overridable with `verilator_assert=` to bisect a firing assertion against the old unchecked behaviour). Evidence on `ai-dt` rebuilt with the flag: **build OK** (no compile-time fallout), and with assertions live `ai-numfmt-grant` **PASS 1310 cy**, `ai-dual-core-lrsc-disjoint` **PASS**, `ai-dual-core-excl` **PASS 16667 cy** — the last still bit-identical to its pre-`--assert` baseline, and **zero assertions fired** in any run. So `check_cfg` (including the AI-X2 `FormatMask` rules) and every `translate_off` parameter guard now execute and pass on `g6lc64_ai`. Notably `g6lc_axi_lrsc`'s duplicate-reservation invariant runs **every cycle** during the disjoint test and never fires, which positively confirms the table never holds two entries for one address — the property AI-X1's fix depends on. Flavour **`B`** measured too: **BUILD OK warnings=0 errors=0** and an OpenSBI soak with **zero assertions fired**, so the default-on flag is safe for the non-AI path as well. **Still to do:** `legacy` and the `_v`/`ooo_server` envelopes, which have never had their assertions checked either; `verilator_assert=` is the escape hatch if one turns a green flavour red. Original finding below. |
| **AI-X5a** | *(original finding, kept for the record)* | — | **Pre-existing, voided a documented discipline.** `Makefile:729` builds `verilate_command` with `-Wall`, `--x-assign 0`, `--converge-limit`… but **no `--assert`**, and Verilator ignores `assert` statements unless it is passed. Proven directly with a 5-line probe on the pinned Verilator 5.008: the identical module reports `PROBE: module ran` (assert skipped) without the flag and `%Error: Assertion failed ... GUARD FIRED` with it. **Consequences:** `config_pkg::check_cfg` — which `AGENTS.md` §0.2 makes the mandatory mechanism for config legality ("new behavior sits behind a `cva6_cfg_t` field with a `check_cfg` legality assert") — **never executes**, so an illegal config elaborates and runs silently. Same for every `//pragma translate_off … initial assert` parameter guard: `g6lc_axi_lrsc` `MaxOut`/`NRes` range and its duplicate-reservation invariant, `g6lc_ai_dram_backend` / `g6lc_ai_dram_channels` channel legality, `g6lc_ai_litedram_wrap`'s no-LiteDRAM `$error`, and the new `g6lc_ai_island_top` grant ⊆ `AiIslandPeImplMask` guard. These are documentation, not enforcement, which is exactly what heuristic **H6 (red-line executability)** forbids. **Fix is one line** (`--assert` into `verilate_command`) but must be its own pass: it will surface however many latent assertion failures the design has accumulated while nothing was checking, and could turn currently-green flavours red. Until it lands, no "guarded by `check_cfg`" claim may be cited as enforced. Note the AI-X2 `numfmt` gate does **not** depend on this — it is proven bidirectionally by real descriptor traffic (`+define+G6LC_AI_TB_OVERGRANT` grants BF16 the PE cannot do, and `ai-numfmt-grant` then **FAILS `tohost=5`** "BF16 was not refused", verlib `work-ver-ai-overgrant`). |
| **AI-X6** | **Flavour `B` had been unbuildable since the DRAM backend landed — the whole OpenSBI / soft-ladder line was blocked** | SL / P0 | **FIXED and verified.** `ariane_testharness` no longer instantiates `axi2mem`/`sram` inline; it instantiates `g6lc_ai_dram_backend`, and that is **not** behind an `ifdef`, so `ariane_testharness.i_sram` stopped existing for **every** flavour. `ariane_tb.cpp` was updated for the AI flavours (`G6LC_TB_NO_HIER` → `i_dram_backend.gen_sim_axi.i_sram`); **`g6lc_tb.cpp`, which flavour `B` and `legacy` use, was not**, so `B` failed to compile with `'class Variane_testharness___024root' has no member named ...i_sram...` (plus a `b1/b2/b3 not declared` cascade). The remote's last successful `B` was **2026-09-01**, predating the backend, so nobody had rebuilt it — and since all SMT2/OpenSBI/dual-hart evidence comes from flavour `B`, that line was silently dead. Fix is a pure prefix change (`i_dram_backend__DOT__gen_sim_axi__DOT__`); the suffix including `gen_mem_user` is the same `sram` module and `AXI_USER_EN` is still forwarded, so `MEM_USER` stays a genuinely separate user-bit memory rather than being aliased to `MEM` — aliasing would have overwritten data with user bits. Also fixed 4 stale `i_axi2mem` probe references behind `CVA6_MC_PC_PROBE_COMPILE` (rotted the same way, not in the default build, so untested). Verified: `B` **BUILD OK warnings=0 errors=0**, and the OpenSBI soak runs to its documented O3 residual (`plat_hc=0x80`, `coldboot_done=0`, `mcause=0x2` illegal at `mepc=0x80013898`, `mtval=0x862a9a4f`, hart 1 never started) — i.e. **restored, not fixed**; SL-C stays red exactly as recorded. |
| **AI-X4** | **The AI unit-TB family cannot build on the pinned Verilator 5.008** | I3 / P1 | **Open, pre-existing, and it invalidates recorded numbers.** `#0` procedural settle points are rejected (`%Error-ZERODLY: #0 delays do not schedule process resumption in the Inactive region`): **15** in `tb_g6lc_axi_lrsc.sv`, **5** in `tb_g6lc_ai_atomics_aw.sv`, **19** in `tb_g6lc_ai_litedram_wrap.sv`. So `ai-dram-atomics`' recorded cycle counts came from a different tool and are not reproducible on the proxy. **Two cheap substitutions were tried and both FAIL identically** — `#0`→`#1` and `#0`→`@(negedge clk)` each hit `hs_ar` "timeout AR" at **t=4145000**, deep in the sequence and after the 8-deep AR-backpressure scenario, not at the first handshake. Same timestamp for both ⇒ the settle point is not the discriminator; the R/B drain accounting (`got`, `nr`/`nw`, the `r_go`/`b_go` gating of `mem.r_valid`/`mem.b_valid`) depends on resuming **pre-NBA**, so `nar` never falls back below `MaxOut` and starves the next `hs_ar`. Recorded per P7 so this is not re-derived at full price: the fix is to **restructure the drain loops around a defined sampling point**, not to swap a delay. Until then `verif/tb/ai_island/run-lrsc-oracle.sh` reports **SKIP** with the reason rather than a verdict, and the citable exclusive-monitor evidence is harness-level (AI-X1). Detail in the header of `tb_g6lc_axi_lrsc.sv`. |
| **AI-X3** | **Two SKUs now have two operating points** | I1 | **Landed (doc).** `AGENTS-configuration.md` had only the router class, so the island's `ClockKhz = 1_000_000` matched **neither** the 1.25 GHz core target nor the 1.5 GHz `scaling-100tops.md` §7 figure its 98.3 TOPS is derived from — an unanchored clock makes every TOPS headline unfalsifiable. New §1.0a pins the AI-card SKU (latency 1.0 GHz vs throughput 1.5 GHz, clusters, DRAM class, power) and §1.0b writes down the `sv-timing --target-mhz` → `--from-timing` loop with the gates that must hold before a raised target may be recorded. Binding rules: island clock is a config field never a literal; the **core** clock does not move with the island clock; FO4 screening is not STA and may not be cited as closure. |

---

1. ~~**Register residual suites in build-platform**~~ **done** — `mc-mini-veri` + `mc-spo-veri`
   in `defaults.ts` (`optional: true`, not in `defaultSuites`); listed by `test --list`;
   Spike Zacas soft-skip remains honest (RTL mini = CAS golden). Maps:
   `AGENTS-specs-to-tests.md`, `AGENTS-build-platform.md` §4/§6.

2. ~~**Full CRT `mc-spo-veri` green**~~ **done (imafdc + server_math L2)** —
   - **imafdc** `FORCE_IMAFDC=1`: **9/9** hard PASS (log `mc-spo-veri-full-smoke.log`).
   - **`g6lc64_server_math`** (HPDCACHE_WT + L2, `NrCores=2`, bare-metal single-hart CRT):
     **9/9** hard PASS after same `DeepSpecEn=1` STQ deepen (log
     `mc-spo-veri-server-math-full.log`). Compact linker + Verilator 5.008.
   Root cause was STQ `DEPTH_COMMIT=4` (hang ≥40 B fill→verify). Dual-hart live CRT
   optional on multi-hart packages; smt2 dual_park LIVE_HARD greened (hold+grace).
   **Priors:** `mc-spo-veri.sh` · `mini_stream_plane.S` · `store_buffer.sv` ·
   `cv64a6_imafdc_sv39_config_pkg.sv` · `g6lc64_server_math_config_pkg.sv`.

3. **H-edge directed diagnostics** (10 narrow + CF) — **Spike 3/3 hard green** (suite
   `kvm-h-spike`: h_edge_diag + kvm_h_stress + hlv_hsv_smoke). Covers hedeleg WARL,
   VTSR/VTVM/VTW cause 22, VS ecall to M (cause 10) + MPV sticky, dual VS re-entry.
   Spike footgun: default PMP denies S/VS fetch until TOR open (or PMP CSRs absent —
   illegal swallowed). **Spike + RTL Variane 3/3 hard green** on g6lc64_server_math (~1.5–2k cycles).
   SPV and tval/tinst polish optional if later litmus fails. Extends U9 + kvm-h-tests.
   **Priors:** verif/regress/kvm-h-spike.sh · verif/tests/custom/kvm_h/h_edge_diag.S ·
   architecture/server-math-hypervisor.md · Phase B · agents/spec/riscv-spec-II-5.* ·
   Hypervisor row in AGENTS-specs-to-impl.md · suites kvm-h-spike / kvm-h-tests.

4. **Stability battery + regress isolation map** — **landed**: isolation map
   `verif/regress/AGENTS-regress-scripts.md` (axes: target / ISS vs RTL / stack height / feature)
   + composed suite `stability-regress` (`verif/regress/stability-regress.sh`).
   Profiles: `artifact` | `spike` | `full` | **`stream8`** (spike + mini CAS on
   `work-ver-stream8` + `kvm-h-veri` + `stream8-smoke` live). FO4 optional outside this battery.
   **Priors:** `AGENTS.md` §0.2 · `AGENTS-specs-to-tests.md` · `AGENTS-build-platform.md` §4–§5 ·
   `mc-spo-*.sh` · `kvm-h-spike.sh` · `mc-mini-veri.sh`.

5. **Dual-ISS Spike+Verilator tandem polish** — **landed**: suite `dual-iss-regress`
   (tohost golden: mini_tohost + mini_jumps; optional `DUAL_ISS_H=1` for h_edge_diag;
   `DUAL_ISS_MODE=trace` via cva6.py). Zacas never dual-ISS golden. Mismatch triage in
   `verif/regress/AGENTS-regress-scripts.md` §7.
   **Priors:** `verif/regress/dual-iss-regress.sh` · `verif/sim/cva6.py` ·
   `AGENTS-build-platform.md` §5 · `AGENTS-specs-to-tests.md` · `defaults.ts`.

6. **R3b Linux `Image`** — **gate landed** (`r3b-linux-image`): contract always;
   soft-skip without external Image; `CVA6_R3B_BUILD=1` embeds Image via
   `build-opensbi-smt2.sh --linux`. Full shell//proc/cpuinfo still lab when Image present.
   **Priors:** `verif/regress/r3b-linux-image.sh` · `fetch-linux-image-hint.sh` ·
   `smt-linux-rootfs.md` · `software/smt2-linux/` · `smt-linux-r3-cosim` · `opensbi-linux-boot`.

7. **OpenSBI VRF + `CONFIG_RISCV_ISA_V` + Ara cosim** — **gate landed**:
   `software/vector/` (opensbi-vrf.md + linux.config-fragment) + suite `ara-vector-cosim`
   (soft skip/misa on Variane; live `v_memcpy_lmul` via `ARA_COSIM_LIVE=1` + server_math_v rebuild).
   Full multi-task OpenSBI VRF + kernel still lab when Image/_v TB provisioned.
   **Priors:** `verif/regress/ara-vector-cosim.sh` · `software/vector/` ·
   `architecture/ara-vector-attach.md` · `AGENTS-vector.md` · `testlist_ara_vector.yaml`.

8. ~~**AMOCAS.Q deferred**~~ **done (functional)** — `zacas-policy` hard green 4/4:
   odd-pair illegal + W/D/Q mini on Variane; plan `architecture/zacas-amocas-q.md`.
   Decode/pair RF/128b multi-beat RMW/dual WB; Spike never CAS golden.
   **Priors:** `verif/regress/zacas-policy.sh` · `mini_amocas_{w,d,q,q_illegal}.S` ·
   `software/zacas/` · `architecture/zacas-amocas-q.md` · maps Zacas rows.

9. **Lab-only FO4/STA** — **host re-validated** (`s9-lab-gate`: doctor + lab-run fixture +
   retune guard). Still **lab-blocked**: S3b-lab `fo4-v1.toml` retune from **real** STA;
   S4b OpenROAD+LEF under `pd/pdk/`; full `./build.sh verify` when tools provisioned
   (`S9_FULL_VERIFY=1`). Do **not** retune FO4 from synthetic fixture STA.
   **Priors:** `verif/regress/s9-lab-gate.sh` · `architecture/build-platform-opensta-from-timing.md`
   · `AGENTS-build-platform.md` §7 · `sv-timing/architecture/STA-HANDOFF.md` ·
   `architecture/build-platform-workspace-lifecycle.md` · `AGENTS-technology.md` ·
   verify gate `AGENTS.md` §0.2 / `build-platform/AGENTS.md` §4.6.

10. ~~**Dual-hart residual re-validation**~~ **done (host residual)** - suite
   `dual-hart-ci`: artifacts + boot-path + dual-park ELF compile; rootfs preflight with
   `SMT2_SKIP_R3=1` / `DUAL_HART_SKIP_R3=1` by default; smt2 lint soft-skips when only
   Windows OSS CAD PE is present under WSL (hard: `DUAL_HART_REQUIRE_LINT=1` + Linux-native
   `verilator_bin`). Optional `DUAL_HART_PARK_SPIKE=1` + bare dual-park. **Live smt2 Variane green** (boot hold + DRAM grace + peer switch fixes): bare
   `mini_tohost` + `smt_dual_park` + `smt_peer_tohost` on `work-ver-smt2`. R3 Linux cosim still lab/Image-external.
   **Priors:** `verif/regress/dual-hart-ci.sh` · `smt_dual_park.S` · `smt-linux-rootfs.sh` ·
   `architecture/multi-threading/smt2-bringup.md`.

11. ~~**Optional growth stream8-class**~~ **promoted (config + DTS + smoke)** —
    package `g6lc64_stream8` (NrCores=2, RVZacas, DeepSpec, L2, H; C-light),
    `ariane-stream8.dts`, suite `stream8-smoke` (optional). **Live RTL green** on
    Linux Verilator 5.008 (`work-ver-stream8`): AMOCAS.W/D/Q + stream plane SUCCESS;
    lint via `linux-eda-suite` / `$HOME/tools/verilator-v5.008`; **full CRT `mc-spo-veri` 9/9** + **H-edge Variane 3/3** (`kvm-h-veri` on work-ver-stream8).
    Branding/publication only if a rebrand branch merges here.
    **Priors:** `architecture/stream8-class.md` · `g6lc64_stream8_config_pkg.sv` ·
    `verif/regress/stream8-smoke.sh` · `multi-core/README.md` · `AGENTS-configuration.md`.

12. **Soft ladder DI OpenSBI (active)** — promote binary peels → B1 RTL / B2 firmware / B3
    harness. Oracle moved `tmp-dual-ci` → `software/smt2-linux/soft-ladder/`.
    Peels landed: spin, cmpx, CSR, c.mv, fdt_match, malloc, strlen (FETCH_WIDTH=64).
    **Open:** `b1-fdt-lenp-store` / `PEEL_FDT_GETPROP` (iter-014). Soft getprop default. S4 residual closed as IAF/test-address (iter-013). Current 12-thread B pin is `fdt_ro_probe_` at `0x800125d8`/`0x80012638` with `a5=0x8001e000` (pre-load value, `lbu` not retired); `--threads=1` build (`work-ver-smt2-fw64-B-vt1`) gives a clean `npc0=0x800138d8` (second half of 32-bit `beqz s4` at `fdt_getprop_by_offset+0x24`, `0x800138d6`, `addr[1:0]=10`), proving the residual is a `core/fetch_B/instr_realign` 32-bit fetch-word straddle. With `CVA6_TRACE=1` the 1-thread 2M pin moves to `npc0=0x800137b0` (`bltu s1,s2` in `fdt_path_offset_namelen`), showing the failure is highly sensitive to observer / Verilator evaluation order. `mini_fdt_rdxrs1` (rd==rs1 FDT header load) and new `mini_fdt_ro_probe` (direct `fdt_ro_probe_` blob call) both PASS, so the failure is contextual and timing-sensitive. `+fetch_snap` (sim-only `translate_off` observer) masks the `fdt_ro_probe_` hang and moves it to a later `fdt_path_offset_namelen` loop, suggesting an uninitialized-signal / Verilator evaluation-order race in `core/fetch_B` or a load-unit handshake sensitive to it. `work-ver-smt2-fw64-legacy` build fixed and `mini_fdt_nt_osbi` passes on it, but `PEEL_FDT_NEXT_TAG=1` on legacy fails later in `sbi_heap_init` (`npc0=0x8000f3f8`, partial cookie `0x51b1c001`).
    Bisects all negative (reverted): dual-commit, STQ-nofwd, force SI issue — same pin.
    **I4au soaked** — natural `fdt_next_tag` cookie `51b1babe` dual-confirm.

**2026-08-30 pass (b1-fdt-lenp-store residual):** Targeted `core/fetch_B/frontend.sv`
`leftover_branch_bp_fire` (bp_fire && serving_unaligned && slot0 is Branch) preserves
the carry on a predicted-taken split conditional branch so a mispredict-fallthrough can
rebuild the RVI. Rebuild `work-ver-smt2-fw64-B-vt1-trace`; DI improves from 11/16 to
13/16 (new passes: `mini_fdt_check_prop_nest`, `mini_fdt_namelen_walk`); the same two
pre-existing fails (`mini_csr_expected_trap`, `mini_stq_flush_fwd`) remain. The
`PEEL_FDT_GETPROP=1 PEEL_FDT_NEXT_TAG=1` OpenSBI soak on 12-thread B-trace moves from
`npc0=0x80012640` to `npc0=0x80013792` (`fdt_path_offset_namelen` loop) with
`a0=0xaf5`. A 1-thread B build (`SOFT_LADDER_VERILATOR_THREADS=1`) reproduces the
original `npc0=0x80012640` / `a0=0xaf5` / `ra=0x80013792` pin. `CVA6_TRACE_FILE` with
`log gpr` shows `a0` being assembled as `0xaf5` (FDT totalsize) from bytes while `a5`
flips from `0x2f` to `0x8001e000`, indicating the `fdt_ro_probe_` split-jal entry is
not completing `c.mv a5,a0` before the first `lbu` uses `a5`. The residual is therefore
a **split-jal / split-branch realignment race in `instr_realign.sv`** rather than a
simple branch-predict kill. Next: inspect `instr_realign.sv` `carry_ok`/`leftover_next`
against the `fdt_ro_probe_` entry (`0x80012544`, 8-byte block offset 4) and the jal to
it (`0x8001378e`/`0x80012ece`, 6 mod 8 split). Local `./build.sh verify` attempted but
unavailable (missing Verilator); remote build + DI + soak is the current evidence.
**Update:** A pre-shift removal + `instr_realign` `hw[cur + hw_first]` offset trial was
reverted. The original pre-shift contract is restored; remote DI is 11/16 with the
targeted `mini_fdt_lenp_sw`, `mini_fdt_nt_frame32`, `mini_fdt_nt_stock` now passing.
Residual failures: `mini_csr_expected_trap`, `mini_fdt_check_prop_nest`,
`mini_fdt_next_tag_lbu`, `mini_stq_flush_fwd`, `mini_fdt_namelen_walk`.
    **PEEL `129f8`/mcause=4** (a0=9). **I4cf last keep** (s5↔a0; peel unchanged). **I4ca reverted.** **I4x / fdt `c.mv` families exhausted.** **Next:** `architecture/multi-threading/soft-ladder/COMPLETION.md` stage 0 (`mini_fdt_a0_is_fdt` then G0). Do not start I4cg.
    Suites: `soft-ladder-opensbi-soak.sh`, `soft-ladder-di-regress.sh`.
    **Priors:** `architecture/multi-threading/soft-ladder/*` · `smt2-bringup.md` ·
    `fdt-topology-soft-ladder.md` · `core/{issue_stage,frontend/frontend,scoreboard,commit_stage}.sv`.

13. **Multi-threading topology (cpu-map / cpuinfo / threads-per-core)** — plan landed
    (`fdt-topology-soft-ladder.md`): `S = NrCores × NrHarts`; smt2 = 1×2 SMT; stream8 = 2×1;
    issue width not DT-visible. **Blocked on soft-ladder SL-A/B** before trusting `plat_hc`
    or `/proc/cpuinfo`. DTS: `ariane-smt2.dts` / `ariane-stream8.dts`; RTL mhartid/CLINT already
    `N×T`. After FDT natural: `plat_hc==2`, R3/R3b, cpuinfo count; then stream residual;
    optional DTS generator for hybrid N×T (S≤8).
    **Priors:** `dts-linux-smt.md` · `smt-linux-rootfs.md` · `software/smt2-linux/` ·
    `AGENTS-dts-validation.md` · `g6lc_cluster.sv` · `ariane_testharness.sv`.

## Standing disciplines (apply every pass, per applicability)
Six **co-equal** upkeep rules; run each pass when it applies (none overrides the SoC prime directive):
1. Keep `agents/spec/INDEX.md` spec statuses current.
2. Log todos here in `AGENTS-todo.md`.
3. Apply the contributor-licensing policy (`AGENTS-licensing.md`) — **code edits only**; never for
   `AGENTS*`/`agents/**`/`specs/**`/`docs/**`. Requires `.active-contributor` + `.licensing-policy` or errors.
4. Apply the coding-philosophy checklist (`AGENTS-coding-philosophy.md`) using the target SoC context
   in `AGENTS-configuration.md` — **all code edits**; include a timing-impact note, review &
   validation checklist, `.dts`/spec/config alignment note, and SoC-context compatibility statement
   when applicable.
5. Maintain spec traceability (`AGENTS.md` §0.6): update `AGENTS-specs-to-impl.md` on ISA-visible RTL
   edits, `AGENTS-specs-to-tests.md` on test-suite/testlist edits, and re-derive `AGENTS-specs-coverage.md`.
6. Maintain Linux device-tree cross-validation (`AGENTS.md` §0.6): for device-tree-visible RTL/config
   changes, run `build-platform/scripts/fetch-linux-dts.{sh,ps1}` (sparse/blobless checkout), follow
   the procedure in `AGENTS-dts-validation.md`, and update the matching row.

**Open upkeep finding (review pass 2026-08-29, discipline 3).** `.licensing-tiers` carries no rule
for `core/Flist.*`, so the LibreCore-authored flists resolve to the default `U **` ("someone else's
property") while their own headers declare `MIT` (`Flist.fetch_B`, `Flist.fetch`, `Flist.smt_legacy`)
or `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` (`Flist.g6lc`). Nothing is mislicensed today —
`DEFAULT_TO_FILE_LICENSE` means the declared header governs — but the tier map does not *classify*
them, which is precisely the case the `U **` default exists to surface, and `Flist.g6lc` asserting
tier-R terms from a tier-U path is `E-TIERCONFLICT`-adjacent. Resolution is to add the rule
(`T core/Flist.*` beside the existing `T vendor/ara/Flist.ara`, plus `R core/Flist.g6lc` if that one
is genuinely tier R), **not** to rewrite the headers down to the default. `.licensing-tiers` is
policy, so this is a rights-holder decision and was deliberately left unedited.

## Phases
1. [x] Create `AGENTS.md` main guider.
2. [x] Create `agents/spec/INDEX.md` substructure guider.
3. [x] Create first 4 per-purpose guides (`branch-prediction`, `l2l3-cache`, `ram-memory`, `speculation`).
4. [x] Exemplar spec sub-files (RVWMO, PMA, PMP, Sv39).
5. [x] Spec-complete pass — write all remaining `agents/spec/*.html` files.
6. [x] Update `agents/spec/INDEX.md` rows from `pending` to `done` as files land.
7. [x] SoC-readiness prime directive — `AGENTS.md` section 0 + `agents/guides/AGENTS-soc-readiness.md`, grounded in verified loci (`tc_clk.sv`, `tc_sram.sv`, `cva6_fifo_v3.sv`, `config_pkg.sv`, CVXIF, `verif/`), wired into substructure map + navigation.
8. [x] Deep-review pass — added direct spec quotations, exact `file:line` CVA6 loci, and `.dts` linkages to all `agents/spec/*.html` sub-files.
9. [x] Contributor-licensing governance — `AGENTS-licensing.md` + `.active-contributor{,.example}` + `.licensing-policy{,.example}`; referenced from `AGENTS.md` section 0.4 and substructure map; active contributor `Etienne Cimon`, policy (source of truth `.licensing-policy`) `DEFAULT_TO_FILE_LICENSE` + `ALLOW_PERSONAL_LICENSE`/`PERSONAL_LICENSE=LicenseRef-Proprietary` + `SELECT_MOST_PERMISSIVE` (fallback) + `ADD_CONTRIBUTOR_NAME`: net-new contributor files → proprietary/Etienne Cimon (`LICENSE.Proprietary`), fallback Solderpad `Apache-2.0 WITH SHL-2.1`. Bulk relicense of Etienne Cimon MIT → `LicenseRef-Proprietary` applied 2026-07-31.
10. [~] Optional additional purpose guides (`AGENTS-fpu.md`, etc.) as feature work requires.
    - [x] `agents/guides/AGENTS-vector.md` (U10ᵇ RVV/Ara; wired into `AGENTS.md` §2/§3).
11. [x] Coding-philosophy / target-SoC-configuration governance — `AGENTS-coding-philosophy.md` +
    `AGENTS-configuration.md`; referenced from `AGENTS.md` section 0.5, substructure map, and carry-over
    checklist; co-equal with licensing and SoC prime directive.
12. [~] Build platform (`build-platform/`, Bun + TypeScript) — cross-platform toolchain/test
    orchestration driven by the repo-root `.config.ts`; bootstrappers `build.sh`/`build.ps1`; root
    pointer `AGENTS-build.md` → `build-platform/AGENTS.md`. Code is **LicenseRef-Proprietary / Etienne Cimon** per
    `.licensing-policy` (full text `build-platform/LICENSE`).
    - [x] Scaffold (package.json/tsconfig/bunfig/.gitignore), zero-runtime-deps design.
    - [x] Config surface: `.config.ts` + typed `schema.ts` + `defaults.ts` + `load.ts` (merge/validate).
    - [x] Platform layer: `os.ts`, `exec.ts` (Bun.spawn), `shell.ts` (pwsh/bash/zsh + runBashScript).
    - [x] Workspace: `layout.ts` + `discovery.ts` (glob discovery + size/mtime change-detection manifests).
    - [x] CLI: `doctor`, `config`, `clean`, `tools`, `setup`, `build`, `test` + rich help; `context.ts`/`childEnv`.
    - [x] Tooling: `locations.ts`, `detect.ts` (host probes incl. detect-only VCS/Questa/Vivado/OpenROAD), `submodules.ts` (git sync).
    - [x] `bun test` bridge to `verif/regress` suites (`tests/runner.ts`), opt-in exec via `CVA6_BUILD_RUN_HW=1`.
    - [x] Validated: `bunx tsc --noEmit` clean; `bun test` green (2 pass / 1 skip); `doctor`/`config`/`setup --dry-run` run.
    - [x] Tool install recipes (`tooling/recipes.ts`): verilator + spike reuse `verif/regress/install-*.sh`; riscv-gcc prebuilt fetch; iverilog via package manager.
    - [x] OS package bootstrap (`packageManagers.ts`: choco/apt/dnf/pacman/zypper/brew), gated by `--allow-system-install`/`platform.allowSystemInstall`.
    - [x] Python venv provisioner (`python/venv.ts`) → `workspace/tooling/python-venv` (pinned inline reqs + repo `requirements.txt`).
    - [x] `setup --install` orchestrates prerequisites → venv → recipes (validated via `--dry-run`; typecheck clean, `bun test` green).
    - [x] Regression catalog: all `verif/regress` scripts modelled as grouped suites (`defaults.ts`) with tools/submodule/UVM/openSource metadata.
    - [x] `test` selection + preflight: `--list` / `<id>` / `--suite` / `--group` / `--all` / `--open-source`; missing-dep suites skip (not fail); `DV_TARGET` wired.
    - [x] Cross-OS CI `.github/workflows/build-platform.yml`: verify matrix (win/ubuntu/mac) + on-demand ubuntu open-source smoke.
    - [x] Prereqs rounded out (apt/dnf `curl`/`wget`/`automake`, apt `python3-venv`) so the package manager covers what pip/bun don't.
    - [x] `status` command (one-glance setup/params: SoC target + toolchain provisioning + core→uncore→board→foundry
      subsystems) + top-level source-able `setenv.sh`/`setenv.ps1` that bootstrap Bun, `bun install`, expose the
      `cva6-build` command (wrapping `build.sh`/`build.ps1`), and print `cva6-build status`. Root `README.md` gains the
      agentic-first, build-platform-led "core → product" vision + getting-started. Validated: `bash -n setenv.sh` OK,
      `setenv.ps1` parses, `tsc --noEmit` clean, `bun test` 49 pass/1 skip.
    - [x] Production-suite catalog: `ooo-l3-tests`, `server-math-tests`, `kvm-h-tests`, `dual-hart-ci`,
      `smt-linux-*`, `spec-deep-*` (optional/lengthy; not in `defaultSuites`).
    - [x] SoC envelope aligned with `AGENTS-configuration.md` §1.1 (1250 MHz / 0.8 V / tsmc12ffc-class).
    - [x] `verify.formalTasks` ← U5 OoO scaffolds (`core/ooo/formal/{freelist,rob,cancel}.sby`); per-task workdirs.
    - [x] Wire `discovery.ts` change-detection into `build` (core RTL + flists; skip verilate when unchanged; `--force`).
    - [x] `status` surfaces verify targets / formal tasks / opt-in production packages + suites.
    - [ ] Optional Windows VS Build Tools provisioning (config flag present; provisioning logic TODO).
    - [ ] Physical-design flow (OpenROAD/SiliconCompiler/PDK) off `pd/synth` (currently detect-only).
    - [x] Sim stage reliability on Windows: `resolveBashBinary()` prefers Git for Windows over Cygwin
      when both exist; `runBashScript` / `runRegressScript` / doctor / status surface flavor.
    - [x] `verify --sim` preflight (`simPreflight.ts`): bash/riscv-gcc/verilator/make (+ spike/WSL
      warnings); fails closed when required tools missing (dry-run still plans suites).
    - [x] `timings lab-run`: one-shot sta_smoke materialize → fo4-golden → sta-handoff; probe matrix
      entries for lab-run / sta-handoff / verify --sim.
    - [x] `lab-report.json` + `lab-report.md` from lab-run; CI `build-platform.yml` runs
      `timings lab-run` on win/ubuntu/mac and asserts report artifacts.
    - [x] `timings doctor` — package/FO4 model inventory, PD tools, sim preflight, S3b-lab
      retune checklist; CI runs doctor + lab-run.
    - [x] Offline S3a self-test: synthetic `opensta_paths.rpt` fixture injected by lab-run
      (overlap_score > 0 without OpenSTA binary); `--no-sta-fixture` / `--inject-sta-fixture`.
      CI asserts numeric overlap_score on win/ubuntu/mac; unit test `injectStaFixture fills…`.
    - [x] **Host offline track closed** (S0–S3a fixture, S4a scaffold, doctor, lab-report).
      Next is lab-only (S3b-lab FO4 retune, S4b LEF) or RTL residual.
    - [x] **S3b-lab host propose** — `timings retune-propose` + `retunePropose.ts`; auto after
      `lab-run`; flags synthetic fixture so operators never retune fo4-v1 from offline S3a;
      CI asserts `retune-proposal.{md,json}`.
    - [x] **Structural FO4 monorepo soak (package-first, no build-platform):**
      `sv-timing/tools/monorepo_soak.py` + `svt.py monorepo-soak` on real `core/` sparse flists;
      `architecture/MONOREPO-SOAK.md`; coding philosophy §2.8 + review checklist.
    - [x] **Soak → from-timing → OpenSTA path:** `--correct/--emit` package + recipe;
      `verif/regress/monorepo-soak-from-timing.{sh,ps1}`; first WSL run sparse_ex
      analyze 106 paths / FO4 441.5→99 dry-run; emit integrity reparse still open (P15).
    - [x] Plan of record: granular workspace **clean** + **`--from-timing`** soak hand-off —
      `architecture/build-platform-workspace-lifecycle.md` (artifact taxonomy, subcommands, age
      filters, allowlisted `work-ver`, timings validate contract; keeps `sv-timing/` independent).
    - [x] **C0** `clean status` inventory (purpose map, sizes/ages, allowlist guard) +
      `src/workspace/clean.ts`; bare `clean` keeps today’s `workspace/build` behaviour.
    - [x] **C1** Purpose subcommands (`diag|verify|formal|timings|cache|manifests|downloads|man|dts`)
      + `--older-than <Nd|Nh|Nm>` + `--target`/`--compartment` (child expand) + rich `--help`;
      unit tests `test/clean.test.ts`.
    - [x] **C2** Opt-in `clean sim` (repo-root `work-ver/` allowlist) + `tooling`/`all`/`firmware`/`workspace`
      require `--yes`; refuse paths outside allowlist.
    - [x] **T0** `timings validate --from-timing <dir>` — structural check of portable.f + analyze/correct
      JSON (+ optional `--require-emit`); `validateTimingsOutDir` / `resolveFromTimingDir` in
      `tooling/timings.ts`.
    - [x] **T1** Plumb `--from-timing` into `test` / `diag` preflight (env `CVA6_FROM_TIMING` /
      `FROM_TIMING` via `runSuite` options); structure gate fails the command before suites/diags run.
      Default soaks still exercise **live** RTL (no emit flist swap). Suite scripts consume env
      (`svt_maybe_from_timing` / `Test-SvtFromTiming`).
    - [x] **T1b** `timings compile|analyze|correct --output|-o <dir>` materializes a full package
      (`portable.f`, report JSON, `param-map.json`, `ir.sqlite`, `stamp.json`, optional `corrected/`);
      `resolveTimingsOutputDir` + post-compile validate.
    - [x] **T2** Expert `--use-emit` on `test` / `build` / `verify` (default off) via
      `applyFromTimingFlags` → `CVA6_TIMINGS_EMIT_FLIST`; never auto-merges into `core/` (sv-timing NG4).
      Lint/synth remain on live RTL.
    - [x] **T3a** `stamp.json` on compile + `clean --execution all|last|failed|ok` (stamp-aware
      package select under timings/diag children).
    - [x] **T3b** Soak dashboards: `timings summary|dashboard`, `summarizeTimingsPackage`,
      `soak-dashboard.json`; auto-print after compile/validate and `test --from-timing` (structural FO4 only).
    - [x] **Docs** Top-level `AGENTS-build-platform.md` command structure + residual open list;
      `AGENTS-build.md` points there; Zacas/RVV status reconciled in specs maps + sub-files.
    - [x] **OpenSTA plan** `architecture/build-platform-opensta-from-timing.md` (S0–S5); host S0
      `timings sta-handoff` + `tooling/staHandoff.ts` (review-only `seeds.sdc`, `fo4_paths.csv`,
      `correlate.json`); suite `timings-sta-handoff`; `clean sta`; probe `opensta`/`sta`.
    - [x] **Broader FROM_TIMING** — `mc-spo-soak` validates package; optional `SVT_STA_HANDOFF=1`.
    - [x] **Bench correlate scaffold** — `timings correlate --bench <id>` → `bench-correlate.json`.
    - [x] **S1** Yosys synth smoke from portable.f / emit flist → `sta-handoff/.../synth/netlist.v`
      (soft-skip without yosys; OSS CAD suite preferred).
    - [x] **S2** OpenSTA when `sta`/`opensta` + liberty (`--liberty` / `CVA6_LIBERTY` / pd drop);
      `opensta/paths.rpt` + stub TCL without liberty.
    - [x] **S3a** FO4↔STA overlap score in `correlate.json` (`parseOpenStaPathReport`).
    - [x] **S3b** FO4 golden check (`timings fo4-golden check|write`, `fo4Golden.ts`,
      fixture `fo4-golden.json`); suite hard-check on sta_smoke. Lab retune of fo4-v1.toml still open.
    - [x] **S4a** OpenROAD `floorplan.tcl` scaffold when netlist exists; run if `openroad` on PATH
      (soft-fail without LEF).
    - [x] **sta_smoke fixture** — pure-Verilog `comb_adder` + analyze.json for S1 CI path;
      `materializeStaSmokePackage`; suite `timings-sta-handoff` hard-requires S0, soft S1–S4.
    - [x] **Bench metrics** — `benchMetrics.ts` / `timings parse-bench-log`; dhrystone_smoke + coremark
      tee logs + `timings correlate --file` when `CVA6_FROM_TIMING` set.
    - [ ] **S3b-lab** Retune `sv-timing/resources/fo4-v1.toml` from **real** STA (host
      `retune-propose` is done; package edit still lab-side).
    - [ ] **S4b** OpenROAD with real LEF/lib open-PDK study (lab).
13. [x] Malleability scaffold + spec traceability (additive; no RTL moved). Chose "additive scaffold"
    over a physical refactor to honor the §0 SoC prime directive (§0.3: never churn the working RTL
    hierarchy / break flists).
    - [x] `architecture/` non-compiled scaffold: blueprint `README.md` (target layout + migration plan +
      promotion path) + extension-point READMEs for `branch-prediction/`, `speculative-execution/`,
      `multi-threading/`, `multi-core/`, `l2-l3-cache/`, `spec-extensions/`. Not referenced by any flist.
    - [x] `AGENTS-specs-to-impl.md` — spec chapter ⇄ CVA6 RTL map (Parts I/II/III + microarch), status
      vocabulary, maintenance contract.
    - [x] `AGENTS-specs-to-tests.md` — spec chapter ⇄ build-platform suites + `verif/tests/testlist_*.yaml`
      (forward + reverse index + honest coverage gaps).
    - [x] `AGENTS-specs-coverage.md` — derived, status-only coverage summary (no file references).
    - [x] Registered as standing discipline in `AGENTS.md` §0.6 + substructure map; `verif/README.md`
      points to build-platform as the single test orchestrator (docs-level consolidation, no source moves).
14. [x] Linux RISC-V device-tree cross-validation (additive; no submodule). Avoided full kernel submodule
    because of size and Windows case-collision issues; instead added sparse, blobless fetch scripts and a
    cross-validation doc.
    - [x] `build-platform/scripts/fetch-linux-dts.sh` + `.ps1` — fetch `arch/riscv/boot/dts` + bindings YAML
      into git-ignored `build-platform/workspace/linux-dts/`, with manifest + ref/SHA reproducibility.
    - [x] `AGENTS-dts-validation.md` — DT node ⇄ Linux binding ⇄ spec anchor ⇄ CVA6 RTL/`config_pkg` ⇄
      CVA6 `.dts` cross-reference, generic reference DTS list, agent workflow, maintenance contract.
    - [x] Wired into `AGENTS-coding-philosophy.md` §4.9, review checklist §5, non-negotiable rules §6.2.
    - [x] Registered as standing discipline in `AGENTS.md` §0.6 + substructure map + §6 `.dts` linkage.
15. [~] Motherboard layer (`corev-mb/`) + `mb` configure flow (additive; no RTL moved, nothing in a
    flist). Board around the die: selecting one board adapts core/uncore config + fetches vendor IP +
    generates a **non-compiled** board package. Code is **LicenseRef-Proprietary / Etienne Cimon** per `.licensing-policy`.
    - [x] Config surface: `MotherboardConfig`/`PcbPartsConfig` in `build-platform/src/config/schema.ts`
      + `defaults.ts` (`activeBoard:null` default → existing configs/CI untouched) + `load.ts` validation.
    - [x] pcbparts.dev MCP client `build-platform/src/tooling/pcbparts.ts` (all 14 tools, cache-first,
      network only with `--online`) + Python mirror `corev-mb/lib/pcbparts_mcp.py` (stdlib-only).
    - [x] Board engine `build-platform/src/tooling/motherboard.ts`: `board.json` load/validate, CPU⇄board
      compat check, vendor-id resolve, `<id>_board_pkg.sv` + `board.mk` generation, overlay writer, scaffolder.
    - [x] CLI `mb` command (`list/select/check/create/design/expand/parts/test`) + registry; value flags
      added in `args.ts`. `select` = the SoC+MB "configure" step (overlay + `vendor sync` + generate).
    - [x] genesys2 reference: `corev-mb/boards/genesys2/board.json` (matches `ariane_xilinx.sv` GENESYSII),
      `AGENTS-mb-genesys2.md` contract, `corev-mb/architecture/genesys2/README.md` target.
    - [x] SKiDL flow `corev-mb/lib/` (`soc.py`, `interfaces.py`, `erc.py`) — custom boards only; skidl-optional.
    - [x] Analysis-only targets (described, NOT included): `corev-mb/architecture/{bpi-f3,milkv-jupiter,milkv-titan}/`
      (SpacemiT K1/M1 feature sets + honest CVA6 gaps: RVV, multi-core, LPDDR4 PHY, USB3).
    - [x] `AGENTS-motherboard.md` governance + `AGENTS.md` §0.5 board-counterpart note + §2 substructure rows.
    - [x] `AGENTS-mb-skidl.md` — board design-philosophy (PCB counterpart to `AGENTS-coding-philosophy.md`):
      pcbparts.dev part selection + power-rail planning + SoC-pin↔PHY mapping + physical-positioning/layout
      intent + ERC loop + per-domain playbooks + carry-over checklist (custom boards). Cross-reffed from
      `AGENTS-motherboard.md` §7/§8, `AGENTS.md` §2, `corev-mb/lib/README.md`.
    - [x] Tests `build-platform/test/motherboard.test.ts`; `bunx tsc --noEmit` clean; `bun test` green.
    - [ ] Promote a board → real `corev_apu/fpga/src` top-level importing the generated package + flist entry.
    - [ ] LPDDR4/USB3 controller gaps + RVV/multi-core deltas for SpacemiT-class boards (see architecture docs).
16. [~] Technology-optimization pass (opt-in; additive, no RTL moved, nothing in a flist). Adapts CVA6 to
    a foundry process by binding proprietary, high-level abstraction layers (memory compilers, ICG /
    retention / level-shifter cells, power kits, hard macros) at the existing PDK-swap seam, macro-protected
    behind `CVA6_TECH_OPT`, with the PDK **omitted-under-NDA**. Build-platform code is **LicenseRef-Proprietary / Etienne
    Cimon** per `.licensing-policy`; docs/READMEs are out of licensing scope.
    - [x] Config surface: `TechnologyConfig`/`TechnologyPdkMode` in `build-platform/src/config/schema.ts`
      + `defaults.ts` (`optimizationPass:false`, `pdkMode:"omitted"` → existing configs/CI untouched) +
      `load.ts` validation (mode, guard-macro identifier, spec globs, nda-needs-activeTechnology invariant).
    - [x] Engine `build-platform/src/tooling/technology.ts`: two-key ignition (`assessPass`), `*.tech-spec.md`
      detection (`detectSpecDocs`), PDK presence, read-only `planAdaptation`, SoC-readiness `readinessGates`,
      per-technology `scaffoldTechnology` (gitignored drop-in).
    - [x] CLI `tech` command (`status/specs/plan/check/init`) + registry; value flags `--tech`/`--pdk`;
      `check` exits 3 when enabled-but-not-ready. Tests `build-platform/test/technology.test.ts`.
    - [x] Protected NDA drop-in root `pd/pdk/` (git-ignored except READMEs + `manifest.example.json` + the
      per-dir `.gitignore`), per-area `pd/pdk/{core,corev_apu}/`, `technology.example/` template. Verified
      `git add -n` stages only the 9 scaffold files; NDA content (`*.lib/.lef/.gds`, drops) stays ignored.
    - [x] Governance `AGENTS-technology.md` + agentic playbook `agents/guides/AGENTS-technology-optimization.md`;
      `AGENTS.md` §0.7 standing rule (high-level workflow) + substructure map + §3 navigation rows.
    - [x] Validated: `bunx tsc --noEmit` clean; `bun test` green (49 pass / 1 skip).
    - [ ] Add a guarded RTL wrapper at the `tc_sram`/`sram_cache` seam for a concrete target library
      (worked example only in the guide; deferred until a real PDK drop is available).
17. [~] **Router-core upgrade program** — efficiency-ranked plan (OpenWRT/Linux router core + staged
    multi-issue OoO). **Priors / live progress (open these before editing checklist rows):**
    `architecture/router-core-upgrade-program.md` · `architecture/README.md` (live RTL table +
    programs of record) · `architecture/remaining-upgrade-sequence.md` (§0 done/open, §4 next +
    prior spine) · Current phase table above (landed + prior paths). Those docs supersede older
    checklist rows below when they conflict; open residual items point back to Practical next §N.
    - [x] Program document + `architecture/out-of-order/` extension point + programs-of-record table.
    - [x] **SoC envelope** — `AGENTS-configuration.md` §1.0/§1.1/§2.2 filled (1.25 GHz / 0.80 V /
      12 nm FFC-class inferred from shelf router silicon; open-PDK study path only). Build-platform
      `soc.*` defaults + `.config.ts` aligned.
    - [x] **Per-change verification gate** — `cva6-build verify [--lint|--formal|--sim|--synth]`
      (`build-platform/src/cli/commands/verify.ts` + `src/tooling/eda.ts`). OSS CAD Suite 2026-07-24
      under gitignored `build-platform/workspace/tooling/oss-cad-suite/`.
      - lint / elab / synth as before; baselines ~483 / 138 on primary targets (ratchet as warnings drop).
      - [x] `verify.formalTasks` = U5 OoO freelist + ROB + cancel (`.sby` use `read -formal`).
      - [ ] sim stage still host-dependent (needs bash + riscv-gcc + spike provisioned).
    - [x] **U1–U4, multi-issue, U7ᵃ/ᵇ/ᶜ, U6.0–U6.2, U8ᵃ, U9.x H/Sstc, U10 C-light** — see architecture
      live RTL table (TAGE_LITE, FTQ/FDIP, way-pred, slice-OoO gated, L2/L3, SMT, multi-core hub,
      PMU groups, server-math package, multi-context PLIC).
    - [x] **U5 full OoO** — production gated (`OoOEn`); packages `cv64a6_ooo` + `cv64a6_ooo_server`;
      suite `ooo-l3-tests` (optional).
    - [x] **U10ᵇ Ara** — package `_v`; `vendor sync ara` → `upstream/` + `Flist.ara` (**vendored**);
      sim/synth flist append still open for live vector.
    - [x] `vendor sync ara` + `vendor/ara/Flist.ara` (catalog status **vendored**; sim flist append open)
    - [x] L3 victim → L2 tag match-inval + TB `INCLUSIVE_L3=L3En` (L1 inclusive already present)
    - [x] p6 stream plane × multicore suite `mc-stream-tests` (artifacts + lint; cva6.py when ready)
    - [x] `ServerPrefetchEn` on `cv64a6_server_math` (2-core stream plane without L3)
    - [x] `verify.extraFlists` / `extraFlistsByTarget` + `topByTarget` + suite `ara-vector-path`
    - [x] Arm Ara for `cv64a6_server_math_v` (Flist.ara + typed top); **lint PASS**
    - [x] `ariane` EnableAccelerator path + `cva6_ara_attach` + optional wide AXI dwc/mux
    - [x] Residual gates green (lint path): ara/mc-stream/dual-hart/formal
    - [x] `CVA6_ARA_ATTACH=1` live Ara Verilator lint green (deps + cva6_shim; slang skipped)
    - [x] Spec status maps + `riscv-spec-I-9-vector.html` for RVV/Ara **partial** attach
    - [x] Formal vs **live** freelist + ROB RTL (ROB via yosys-slang; BMC depth 16 **PASS**);
      cancel remains policy model
    - [x] Live multi-port rename formal (`cva6_ooo_rename.sby`): free∩busy=∅, x0 map,
      dual-issue bypass, alloc≠0; rename package-free `NR_WB` API; **PASS** + `cv64a6_ooo` lint
    - [x] dual-hart-ci hardened (boot-path + dual-park ELF + rootfs R3-skippable + smt2 lint soft-skip when PE-only/WSL host-skew)
    - [x] smt-linux-rootfs R2a (payload+DTB when CROSS_COMPILE) + clearer R3/OpenSBI path
    - [x] mc-stream toolchain probe (riscv-gcc/spike) with clear lint fallback
    - [x] Windows managed xPack install (`toolchain.riscvGcc.prebuiltUrl.windows` + zip recipe)
    - [x] Dual-hart R3a OpenSBI `fw_payload.elf` built natively (Cygwin make + cygwrap)
    - [x] R3 suite soft-gates sim: **PASS R3a** when firmware present; R3 cosim = Linux/WSL
    - [x] `installSpike` WSL/Linux via `build-platform/scripts/install-spike.sh`
      (adopts `~/tools/spike`, cmake4/cstdint patches, managed `workspace/tooling/spike`)
    - [x] `cva6.py` pre-defined targets include `cv64a6_smt2` / ooo / server_math packages
    - [x] Windows cva6.py portability: `dv/lib.py` bash `-lc`, GCC version parse (xPack),
      `.elf` directed tests, ISS path `str.replace`, conditional Spike/Verilator checks
    - [x] R3 suite: full env setup + soft-pass R3 on native Windows (path mix); force via
      `CVA6_FORCE_WIN_CVA6PY=1` / hard-fail `CVA6_REQUIRE_R3_SIM=1`
    - [x] build-platform **install profiles**: `tools install <sim|dual-hart|opensbi|all>`
      + `setup --install --profile …` (`installProfiles.ts`; OpenSBI scripts wired)
    - [x] Managed Spike installed under `workspace/tooling/spike` (Linux ELF; run via `wsl`)
    - [x] R3 RTL cosim path on **WSL**: `smt-linux-r3-cosim.sh` + Verilator `cv64a6_smt2`
      model; `fw_payload.elf` → Variane **SUCCESS** (~6.5M cycles); suite auto-WSL on Windows
    - [x] **probe** CLI: categorical boxes (host/pkg/utils/tools/env/diag/commands/install),
      residuals, install playbook; wired into doctor/setup post-snapshot
    - [x] **diag** CLI + `config.diagnostics`: compartmentalized tests with **per-test
      Verilator configs** (`lintWithSurface`); probe `diag` tab
    - [x] Docs: `AGENTS-build.md`, `build-platform/README.md`, `build-platform/AGENTS.md`
      §4.6 probe→install→diag→verify operator workflow
    - [x] U10ᵇ software contract (non-BP): `AGENTS-vector.md`, `ariane-server-math-v.dts`,
      directed `v_memcpy_{skip,lmul}` / `v_misa_v` + `testlist_ara_vector.yaml`; ara-vector-path
      gates artifacts
    - [x] Zacas AMOCAS.W/D (`RVZacas`): decode + 3rd-op RF + `amo_req.operand_c` + `amo_alu`
      + HPDCache/WT CAS pack; packages server_math{,_v}/ooo_server + imafdc baseline; narrow
      tests in `testlist_mc_stream` (zacas_w/d, spo st-fwd, fence drain, cas lock handoff,
      CF×stream, CAS×stream, mispred×stream) + suite `mc-spo-soak`
    - [x] Multi-core spo **Spike** soak (`mc-spo-spike`) + harden narrow CAS/stream asm
    - [x] Verilator **mini** bare-metal hard gate (`mc-mini-veri`: tohost/jumps/AMOCAS.W/D);
      FTQ reseed + I$/missunit/AMO path fixes for green Variane
    - [x] Structural FO4 residual cuts on sparse_ex/frontend at **2.5 GHz** (`sv-timing`;
      screening only — not STA). Host clean/`--from-timing` track closed offline
    - [x] Full CRT RTL cosim (`mc-spo-veri`) — imafdc **9/9** + `g6lc64_server_math` L2 **9/9**
      (DeepSpec STQ). Dual-hart live CRT optional. → **§2 done**;
      priors: `mc-spo-veri.sh`, `mini_stream_plane.S`, `g6lc64_server_math_config_pkg.sv`
    - [x] Register `mc-mini-veri` + `mc-spo-veri` in `defaults.ts` → **§1 done**;
      priors: `build-platform/AGENTS.md` §4, `AGENTS-specs-to-tests.md`
    - [x] H-edge Spike + RTL Variane 3/3 (hedeleg WARL, VT*→22, MPV, dual VS ecall)
      → **§3 done** (kvm-h-spike + monorepo-soak/run-h-edge-veri.sh on server_math TB)
      priors: verif/regress/kvm-h-spike.sh, h_edge_diag.S, architecture/server-math-hypervisor.md,
      Phase B, agents/spec/riscv-spec-II-5.*, Hypervisor impl row
    - [x] `verif/regress/AGENTS-regress-scripts.md` + `stability-regress` battery → **§4 done**;
      priors: `AGENTS.md` §0.2, `AGENTS-build-platform.md` §4–§5, `AGENTS-specs-to-tests.md`
    - [x] Dual-ISS Spike+Verilator residual (`dual-iss-regress` tohost 2/2; +H 3/3) → **§5 done**;
      priors: `verif/regress/dual-iss-regress.sh`, `AGENTS-build-platform.md` §5
    - [x] R3b Linux Image **gate** (`r3b-linux-image` soft-skip without Image; LINUX_IMAGE build path) → **§6 gate done**;
      full rootfs shell still external/lab when Image available
      priors: `verif/regress/r3b-linux-image.sh`, `smt-linux-rootfs.md`, `software/smt2-linux/`
    - [x] OpenSBI VRF contract + Linux `CONFIG_RISCV_ISA_V` fragment + `ara-vector-cosim` soft path → **§7 gate done**;
      live lmul rebuild optional (`ARA_COSIM_LIVE=1`)
      priors: `software/vector/`, `verif/regress/ara-vector-cosim.sh`, `AGENTS-vector.md`
    - [x] AMOCAS.Q **functional** + odd illegal + W/D/Q hard mini (`zacas-policy`) → **§8 done**;
      priors: `software/zacas/README.md`, `mini_amocas_q_illegal.S`, `mc-mini-veri`, zacas maps


## What "done" means for a spec sub-file
A sub-file is **done** when it contains:
- Canonical deep-link `../specs/riscv-spec.html#<anchor>` and source line.
- One or two paragraphs of Logisplain summary (goal, spec grounding, mechanical dissection, conceptual linkage).
- A **Pseudo-SystemVerilog synthesis notes** block if the subchapter implies hardware structure, otherwise a note that it is pure ISA decode/execute.
- A **CVA6 status** line: `implemented` / `partial` / `absent` + concrete `file:line` locus or `locus TBD`.

A file is **deep-reviewed** when every claim is traceable to a spec quote and every CVA6 locus has been
verified against the actual source.

## Pending high-priority sub-files (domain order)
Tick as completed. Each is `agents/spec/<filename>`.

### Vol I
- [x] `riscv-spec-I-1.4-memory.html`
- [x] `riscv-spec-I-1.6-traps.html`
- [x] `riscv-spec-I-2.1-rv32i.html`
- [x] `riscv-spec-I-2.2-rv64i.html`
- [x] `riscv-spec-I-3.2-ztso.html`
- [x] `riscv-spec-I-4.1-zifencei.html`
- [x] `riscv-spec-I-4.9-ziccif.html`
- [x] `riscv-spec-I-4.10-ziccid.html`
- [x] `riscv-spec-I-4.11-ziccrse.html`
- [x] `riscv-spec-I-4.14-zicclsm.html`
- [x] `riscv-spec-I-4.15-zic64b.html`
- [x] `riscv-spec-I-4.17-cfi.html`
- [x] `riscv-spec-I-4.18-zihintntl.html`
- [x] `riscv-spec-I-4.19-zihintpause.html`
- [x] `riscv-spec-I-4.20-cmo.html`
- [x] `riscv-spec-I-5.1-a.html`
- [x] `riscv-spec-I-5.2-zalrsc.html`
- [x] `riscv-spec-I-5.3-za128rs.html`
- [x] `riscv-spec-I-5.4-za64rs.html`
- [x] `riscv-spec-I-5.5-zawrs.html`
- [x] `riscv-spec-I-5.6-zaamo.html`
- [x] `riscv-spec-I-5.7-zalasr.html`
- [x] `riscv-spec-I-5.8-zabha.html`
- [x] `riscv-spec-I-5.9-zacas.html`
- [x] `riscv-spec-I-5.10-zama16b.html`

### Vol II
- [x] `riscv-spec-II-3.4-reset.html`
- [x] `riscv-spec-II-3.5-nmi.html`
- [x] `riscv-spec-II-4.1-supervisor-csrs.html`
- [x] `riscv-spec-II-4.2-supervisor-instructions.html`
- [x] `riscv-spec-II-4.3-sv32.html`
- [x] `riscv-spec-II-4.5-sv48.html`
- [x] `riscv-spec-II-4.6-sv57.html`
- [x] `riscv-spec-II-5.1-hypervisor-modes.html`
- [x] `riscv-spec-II-5.2-hypervisor-csrs.html`
- [x] `riscv-spec-II-5.3-hypervisor-instructions.html`
- [x] `riscv-spec-II-5.4-mlevel-csrs-hypervisor.html`
- [x] `riscv-spec-II-5.5-two-stage-translation.html`
- [x] `riscv-spec-II-5.6-hypervisor-traps.html`
- [x] `riscv-spec-II-6.1-smstateen.html`
- [x] `riscv-spec-II-6.2-smcsrind.html`
- [x] `riscv-spec-II-6.3-smepmp.html`
- [x] `riscv-spec-II-6.4-smcntrpmf.html`
- [x] `riscv-spec-II-6.5-smrnmi.html`
- [x] `riscv-spec-II-6.6-smcdeleg.html`
- [x] `riscv-spec-II-6.7-smdbltrp.html`
- [x] `riscv-spec-II-6.8-smctr.html`
- [x] `riscv-spec-II-6.9-priv-cfi.html`
- [x] `riscv-spec-II-6.10-pointer-masking.html`
- [x] `riscv-spec-II-7.1-svnapot.html`
- [x] `riscv-spec-II-7.2-svpbmt.html`
- [x] `riscv-spec-II-7.3-svadu.html`
- [x] `riscv-spec-II-7.4-svinval.html`
- [x] `riscv-spec-II-7.5-svvptc.html`
- [x] `riscv-spec-II-7.6-svrsw60t59b.html`
- [x] `riscv-spec-II-8.1-ssqosid.html`

### Vol III
- [x] `riscv-spec-III-1-intro.html`
- [x] `riscv-spec-III-3-rva20.html`
- [x] `riscv-spec-III-4-rva22.html`
- [x] `riscv-spec-III-5-rva23.html`
- [x] `riscv-spec-III-6-rvb23.html`

## Low-priority / ISA-arithmetic sub-files (done as chapter-level summaries)
- Vol I chapters 1 (terminology), 6 (FP), 7 (compressed), 8 (bitmanip), 9 (vector), 10 (packed), 11 (crypto), 12 (matrix), appendices A-E.
- Vol II chapters 1 (intro), 2 (CSRs), 3.1-3.3 (M-level), 9 (Sh), 10 (listings), appendix A.
- Vol III chapter 2 (RVI20).

## Backlog of code-side unknowns to verify
- [x] Exact `file:line` for `FENCE.I` sequencing in `core/controller.sv` — verified (`:121-136`, etc.).
- [x] Exact `file:line` for `Zic64b` cache-line size assertion vs `DcacheLineWidth` — verified (`core/include/config_pkg.sv` line widths are 16/32 bytes; Zic64b not satisfied).
- [x] Exact `file:line` for PMP CSR read/write in `core/csr_regfile.sv` — verified (`:857-960` read, `:1839-1936` write).
- [x] Exact `file:line` for LR/SC reservation state in `core/load_store_unit.sv` and D$ — verified (LSU/AMO buffer/WT/HPDcache paths).
- [x] Extension presence audit (re-verified against live RTL / packages):
  - **Absent** (this tree): `Ztso`, `Zabha`, `Zama16b`, `Svvptc`, `Svrsw60t59b`, in-core RVV VRF (AMOCAS.Q **implemented**).
  - **Partial / config**: **Zacas AMOCAS.W/D** (`RVZacas`); **RVV via Ara attach**; H U9.0–U9.2;
    L2/L3/multi-core hub; SMT2.
  - **Authoritative status tables:** `AGENTS-specs-to-impl.md` · `AGENTS-specs-coverage.md` ·
    sub-files via `agents/spec/INDEX.md` · program snapshot `architecture/remaining-upgrade-sequence.md` §0.
- [x] Spike Zacas cosim remains **unavailable** (ISS); hard-gate CAS on RTL mini / `zacas-policy`.
  → **§8**; priors: `software/zacas/README.md`, `mc-mini-veri.sh`, `zacas-policy.sh`.
- [x] `g6lc64_server_math` L2 bare-metal CRT 9/9 (DeepSpecEn=1; NrHarts=1 / NrCores=2).
  → **§2**; logs `mc-spo-veri-server-math-full.log`. Dual-hart live park greened on smt2 (`a0c410f3d`).
- [x] H-edge Spike + RTL Variane litmus 3/3 (hedeleg WARL, virt-instr 22, VS ecall/MPV,
  dual re-entry). SPV residual optional.
  → **§3 done**; priors: h_edge_diag.S, kvm-h-spike.sh, run-h-edge-veri.sh,
  architecture/server-math-hypervisor.md, agents/spec/riscv-spec-II-5.*-hypervisor*.html.

## AI-matrix open (sideband dual-poll) — **closed**
- Was misdiagnosed as a CVXIF `rs_valid` wedge. Root cause: **sideband `ai.enq` races MMIO desc updates** (`fence` does not wait AXI BRESP; kick is a core wire). Same-addr load-back can STLF and still race. Second enq reused the prior good latch → poll OK; test `fail` used even `a0=2` → HTIF syscall hang (timeout). Fix: drain via a *different* island reg after desc/region MMIO before `ai.enq`; odd HTIF fail codes. Covered by `ai_enq_sideband_smoke` phase-2 + `ai_dual_enq_poll`.

## Soft-ladder cleanup / retirement (2026-08-22)

Retired incomplete/unrelated artifacts outside the `smt_legacy` / `fetch_B` tracks. Moved to `.aside-untracked-20260812-115339/soft-ladder-retired-20260822/` before deletion where safe:

- **Moved aside:** `architecture/g6lc_fetch_dbg.sv` (stray copy), `architecture/multi-threading/soft-ladder/firmware-boot-principles.md` (duplicate of tracked `architecture/firmware-boot-principles.md`), `software/smt2-linux/soft-ladder/cf1_e1_di1_vs_smt2.sh`, `software/smt2-linux/soft-ladder/cf1_e1_raw.sh`, `software/smt2-linux/soft-ladder/_mini_out/` (old mini/fetchb debug logs and scripts), `core/smt/g6lc_ex_id.sv` (untracked duplicate; `core/smt` still holds tracked `g6lc_fetch_{pkg,dbg}.sv`).
- **Removed old Verilator build dirs:** `work-ver-smt2-fetchb`, `work-ver-smt2-fw64b/c/d/e/f`, `work-ver-smt2-new`, `work-ver-smt2-si`, `work-ver-smt2-si-c14`, `work-ver-smt2-slstd`, `work-ver-smt2-slfix.bak-i4bb`.
- **Removed old build products/logs:** `software/smt2-linux/soft-ladder/build/*.log`, `*.nohup`, empty `di-*/soak-*` dirs, and stale `fw_payload_r3a_c15_plat_skip.*.elf` variants (`held-nobyoff`, `peel-getprop`, `pmp8cut`, `cold-regress-20260811`). Kept current `pin-bc7ed11d.elf`, `held.elf`, `fw_payload_r3a_c15_plat_skip.elf`, and `fw_payload_diag.elf`.

**Kept in place:**
- Current harness dirs: `work-ver-smt2`, `work-ver-smt2-fw64`, `work-ver-smt2-fw64-B`, `work-ver-smt2-fw64-legacy`, `work-ver-smt2-slfix`.
- `core/fetch/` — untracked future handoff-B frontend per `architecture/firmware-boot-principles.md`. Not part of `smt_legacy`/`fetch_B`; left for Phase 2/capability work (do not delete without explicit go-ahead).

**Next:** continue `b1-fdt-lenp-store` as a `core/fetch_B/instr_realign` 32-bit RVI straddle residual; build a directed mini that reproduces the `npc0=0x800138d8` misalignment. Legacy harness build is now fixed.

## Build-platform / SMT2 × ai-tensor / g6lc_qemu continuation (2026-08-30)

- Fixed `core/smt/` → `core/smt_legacy/` path drift in the SMT2 track scripts:
  - `verif/regress/smt2-ai-tensor-track.sh` (regfile, CSR bank, issue barrier)
  - `verif/regress/dual-hart-ci.sh` and `dual-hart-ci.ps1`
  - `verif/regress/smt-linux-boot-path.ps1`
- `smt2-ai-tensor-track.sh fast` green except `g6lc64_smt2 lint` (no local verilator).
- `smt2-ai-tensor-track.sh hold` and `peel` both reach the `51b1babe` cookie on `work-ver-smt2-slfix` (with the held / pin ELF).
- `smt2-ai-tensor-track.sh tensor` and `mt-soft` pass (PyTorch Device virt-card + sequential dual invoke).
- `smt2-ai-tensor-track.sh di` runs 6/7 FDT minis; the one `mini_fdt_next_tag_lbu` false `tohost=1` FAIL is the known Verilator/HTIF `exit_code` convention in `corev_apu/tb/g6lc_tb.cpp` (DTM branch prints `*** FAILED *** (tohost = 1)` even though `tohost=1` is the pass value), not an RTL failure.
- g6lc_qemu:
  - `g6q run --backend qemu --target g6lc64_smt2 --expect SMT2-OSBI-OK` boots the generated B1 machine.
  - `--tcg-tuning tuned` and `--icount 1` both reach the same boot gate (Q8).
  - `g6q diag --uarch-out out/uarch.json` writes model-derived D2 counters (Q7).
  - `g6q run --record out/smt2-trace.json --timeout 45 --expect SMT2-OSBI-OK`
    reaches the OpenSBI boot gate and writes a valid 1.5 GB RecordFile (Q5/D1).
    The B2 trace plugin now batches records per hart (64 Ki records) and uses a
    `GMutex` for thread-safe MTTCG flushes; fixed the earlier
    `g_ptr_array_add: assertion 'rarray' failed` crash by lazy-initialising the
    instruction array in `g6lc_tb_trans`.
  - `g6q run --backend qemu --plugin ...-pmu.so,out=smt2-pmu.json` reaches the
    boot gate and writes a 6.8 KB PMU counter artifact (Q7 D2).
  - `g6q run --backend native --image smoke.bin` runs a bare-metal UART payload
    and prints `OK`; `--record` + `--replay` round-trip with no divergence (Q3/Q5).
- SMT2 soft-ladder:
  - `smt2-ai-tensor-track.sh fast` passes 21/22; only `g6lc64_smt2 lint` fails
    (no local Verilator).
  - `soft-ladder-opensbi-soak.sh` with `work-ver-smt2-slfix` + pinned ELF reaches
    `CLASSIFY=SUCCESS cookie 51b1babe` at t=83968 cycles.
  - The `work-ver-smt2-fw64-B` harness does not reach the cookie within 12 M
    cycles / 1800 s; `work-ver-smt2-slfix` completes in <60 s. Frontend/harness
    divergence to be investigated on the RTL SMT2 track.
  - `smt2-ai-tensor-track.sh peel` (PEEL_FDT_GETPROP=1) and `hold` (held
    oracle) both pass 21/0 and reach the cookie at t=83968 on
    `work-ver-smt2-slfix`.
- SMT2 dual-hart:
  - `smt2-ai-tensor-track.sh dual` passes all artifact/preflight gates; only
    `g6lc64_smt2 lint` fails (no Verilator).
  - `dual-hart-ci.sh` with `DUAL_HART_LIVE=1` on `work-ver-smt2-slfix` passes
    live `smt_dual_park`, `smt_peer_tohost`, `smt_dual_active`,
    `smt_dual_concurrent`, and `smt_dual_wfi_timer`.
- AI tensor / mt-soft:
  - `smt2-ai-tensor-track.sh tensor` passes 21/0 (Device virt-card cases only
    because PyTorch is not installed).
  - `smt2-ai-tensor-track.sh mt-soft` passes 21/0 (sequential dual invoke).
- SMT2 soft-ladder DI:
  - `smt2-ai-tensor-track.sh di` passes 6/7 mini FDT tests on
    `work-ver-smt2-slfix`; `mini_fdt_next_tag_lbu` prints
    `*** FAILED *** (tohost = 1)` due to the known Verilator/HTIF `exit_code`
    convention in `corev_apu/tb/g6lc_tb.cpp`, not an RTL failure.
- AI tensor hard (RTL):
  - `smt2-ai-tensor-track.sh hard` passes 21/0: `tensor virt-impl --impl hard`
    on `g6lc64_ai` with `work-ver-ai` passes both soft (Device/PyTorch) and hard
    (Verilator RTL) phases; `ai_island_mmio_smoke` and `ai_gemm_s8_smoke` both
    SUCCESS.
- SMT2 fetch divergence:
  - The passing `work-ver-smt2-slfix` harness is built with `core/Flist.cva6`
    (A/legacy fetch); the failing `work-ver-smt2-fw64-B` harness is built with
    `core/Flist.fetch_B` (B fetch). Same ELF, same timeout: cookie on `slfix`,
    no cookie on `fw64-B`. Old `work-ver-smt2` is stale and prints plusarg help.
- DTS / boot path:
  - Fixed `corev_apu/bootrom/ariane-smt2.dts` `smt-product-closeout` node: added
    `reg = <0x0 0x0 0x0 0x0>;` and `@0` unit address to silence `dtc` warnings.
    `smt-linux-boot-path.sh` passes with no warnings.
- SMT2 fetch_B S4 residual:
  - Reproduced the fetch_B/IQ leftover pointer-liveness bug with
    `verif/tests/custom/multicore/mini_fdt_nt_ptr0.S` on `work-ver-smt2-fw64-B`:
    `tohost = 122928` (`0x1E030`) after 514 cycles, matching
    `architecture/multi-threading/soft-ladder/ITERATION.md` iter-013.
  - Real OpenSBI context with `PEEL_FDT_NEXT_TAG=1` on `work-ver-smt2-fw64-B` also
    fails to reach the `51b1babe` cookie within 2 M cycles / 300 s; trapdump shows
    `0x51b1c001` cave value and `plat_hc=2`/`coldboot_done=0`.
  - `work-ver-smt2-slfix` (2026-08-21 build) does not reproduce the same S4 mini
    signature (`tohost = 76180`/`ra`), confirming the local harness is stale
    relative to the ITERATION.md baseline.
  - `g6lc_fetch_dbg` (`+fetch_snap`) trace: `c.jr a0` at `0x80012994` is
    resolved with `a0=0x8001e030` but the frontend issues `fetch_addr=0x80000000`
    (boot address) immediately after; the eventual `0x8001e030` demand returns
    all-zero data. Root cause narrowed to `JumpR` prediction / BTB-pend state in
    `core/fetch_B/frontend.sv` or the I-Cache refill for the redirected target.
    Caveat: the `work-ver-smt2-fw64-B` binary is dated 2026-08-25 and may predate
    the `core/fetch_B` duplicate drop / current `btb` source; the `btb` prediction
    of `0x80000000` for an unexecuted `c.jr a0` is unexpected for a cold BTB and
    must be reproduced on a fresh build.
- `python tools/g6q.py check` remains green.

---

### AI-X11 — post-F1 commit state (2026-09-04)

- **Committed** F1-sequencer/F1-load, AI-X8 (odd-n store), AI-X9 (k-major B ABI), AI-X10 (multi-channel straddle), the INT4 golden/odd-k/shape/PMU fixtures, and the g6lc_qemu/ai-tensor ABI sync to master as `ee407cea6`.
- **`ai_gemm_s8_32x32_smoke` PASS on `ai-d8`** (63,860 cycles, 333 s wall) — the k-major B layout and INT8 path are correct for m=n=k=32 on 8-channel class-1 LiteDRAM. This rules out a generic 32×32 stall in the current harness.
- **Still open:** the `ai_gemm_fmt_pmu_smoke` 32×32 INT4-vs-INT8 cycle comparison fixture. The `ai-dt` harness was stale; the `ai-d8` run was killed too early because the 32×32×32 single job took ~5.5 minutes and the two-job PMU fixture was expected to need ~10–15 minutes. A new `ai-d8` run with `S4_TIME_OUT=300000` is in progress.
- **Still open:** wider-flavour soak (`ai-sc4`/class-1) and a full Rust workspace test run to confirm the k-major / INT4 changes did not regress the emulator or host ABI.
- **Licensing pass:** `.licensing-tiers` updated so `corev_apu/ai_island/**`, `corev_apu/include/g6lc_*.sv`, and `core/include/g6lc_*.sv` are tier R, `ai-tensor/**` and root `AGENTS-*.md` are tier T. `.gitignore` now excludes `corev_apu/ai_island/generated/` and `trace.spec`.

### AI-X11a — function-call probe for the multi-job hang (2026-09-04 continued)

- Re-ran `ai_gemm_s8_32x32_smoke` and a ticket-51 twin `ai_gemm_s8_32x32_t51` on `ai-dt`: both PASS in **26,723 cycles**, confirming a single 32×32×32 INT8 job still completes and the ticket value is not the issue.
- Built `ai_gemm_s8_32x32_t51_fn` (same descriptor, same data, but wrapped in a `jal`/`ret` `submit` function) and ran on `ai-dt` with `S4_TIME_OUT=50000`: it **timed out at 50,000 cycles with `tohost=0`**. Disassembly confirms the function is correctly formed (`sw zero, AI_DESC+0x4` present, `ret` to `<pass>`). Re-running with `S4_TIME_OUT=100000` to see if it is just slower.
- Built `ai_gemm_two_s8_probe` and `ai_gemm_two_s8_probe2` (sequential two-job, claim, status-read) to isolate the second doorbell. Both runs with `time_out=100000` returned `rc=255` early; the remote `Variane_testharness` process kept running and had to be killed. Likely the long `max-cycles` run is losing the proxy tail (`--tail 30` does not capture the end) and/or SSH timeout. This means the previous "two-job timeout" may partly be a harness/proxy artifact, not proven RTL.
- The `t51_fn` failure is the cleanest new signal: a single job wrapped in a function **does not complete in the same cycle budget as the in-line version**. Re-run with `S4_TIME_OUT=100000` **confirmed timeout at 100,000 cycles**, so it is a genuine hang, not a tight budget. Candidate root causes being checked:
  1. The `submit` function uses `slli t0, t3, 8; sw t0, AI_DOORBELL` while in-line uses `li t0, 0x3300; sw t0, AI_DOORBELL` — same value, different reg allocation.
  2. `ret` (`c.jr ra`) returns to `<pass>` at `0x8000004e`, which is a backward/close return; possible CVA6 return-stack or `c.jr` decode interaction.
  3. The pass/fail/trap labels at `0x4e/0x5e/0x6e` are immediately before the `submit` function; the `j fail`/`j trap` branches from inside `submit` are short backward jumps. No obvious misalignments.
- `ai_gemm_two_s8_inline` (two jobs, but still using a `jal`/`ret` to a `run_job` function) **also timed out at 100,000 cycles**. That means the `jal`/`ret` pattern by itself is enough to hang, and the earlier two-job result is confounded by the function.
- `ai_gemm_two_s8_nofn` (two sequential 32×32 INT8 jobs, **fully in-line, no `jal`/`ret` at all**) **PASS** on `ai-dt` in **20,178 cycles**. This disambiguates the bug: the **second doorbell and completion FIFO work correctly**; the failure is the `jal`/`ret` function-call pattern in this test context.
- In-lined `ai_gemm_fmt_pmu_smoke.S` (removed `submit`, `check_status`, `check_ticket`, `check_c` functions, unrolled both jobs) and re-ran on `ai-dt` with `S4_TIME_OUT=100000`: **PASS in 50,953 cycles**, `tohost=1`. The INT4 job's `AI_PMU_CY` is strictly less than the INT8 job's, so the cycle-count oracle is satisfied.
- In-lined `ai_gemm_two_s8_smoke.S` the same way and re-ran on `ai-dt`: **PASS in 50,948 cycles**, `tohost=1`. Both multi-job INT8 fixtures are now green.
- Deleted temporary diagnostic fixtures: `ai_gemm_s8_32x32_t51.S`, `ai_gemm_s8_32x32_t51_fn.S`, `ai_gemm_two_s8_probe.S`, `ai_gemm_two_s8_probe2.S`, `ai_gemm_two_s8_inline.S`, `ai_gemm_two_s8_nofn.S`. The retained fix is in `ai_gemm_fmt_pmu_smoke.S` and `ai_gemm_two_s8_smoke.S`.
- **Committed to local master** as `5d9f35e95`.
- `ai_gemm_s8_64x64_smoke` on `ai-d8` **timed out at 200,000 cycles** (765 s). The 8-channel class-1 harness is substantially slower for the 64×64 fixture; a `S4_TIME_OUT>=400000` run is required. This is a harness speed/timeout issue, not a functional failure — the same ELF passes on `ai-dt` in 93,194 cycles.
- The wider-flavour sweep (`ai-d8`, `ai-sc4`, `ai-sc8`) for the 64×64 and large-format fixtures is therefore **blocked by simulation wall-clock**, not by RTL. It needs either longer timeouts, a narrower channel config, or a reduced-size smoke for CI.
