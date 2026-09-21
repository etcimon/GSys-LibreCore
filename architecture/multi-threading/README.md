# Extension point: multi-threading (SMT)

Cross-cutting: `../../agents/guides/AGENTS-soc-readiness.md`. Program: U6.1 in
`../router-core-upgrade-program.md`.

**AI attunement (co-equal with soft-ladder):** dual-hart correctness is not only about
`cpuinfo` — it is the software-visible substrate for **multi-thread host + island AI**
work (`ai-tensor` / PyTorch / virt-ai-pcie / HARD). Map:
[`smt2-ai-tensor-linux.md`](smt2-ai-tensor-linux.md) · queue: `AGENTS-todo.md` **SL-T** / **AI-S3**.

## Guarded OoO continuation (2026-09-19)

The user has reopened SMT2+OoO development. A run-local **integer-only OoO** model
now passes the existing atomic reset/election/release rendezvous with the preserved
coarse-handoff scheduler:664 cycles,47/73 retirements; the frozen wrong-result arm
fails at630 and observer off/on agrees. LR/SC RS1/RS2 and ALU consumer profiles also
pass, with a failing negative. The repository's multi-hart and FP OoO refusals stay
active; this is neither mixed-residency overlap nor a supported firmware/Linux SKU.

Prerequisite repairs include hart-qualified dispatch/commit rename, FP lifetime and
physical-zero storage, commit-time CSR/AMO wakeup, precise WFI parking, and excluding
legacy speculative-store retention/replay from OoO. The WFI and store defects were
separate: clearing the parked window allowed handoff, then correcting full-flush
store lifetime removed an orphan which displaced later store commits. Complete
source pins, before/after observations, timing/DFT limitations and remaining gates
are in `../out-of-order/README.md`. The existing in-order OpenSBI anchor is preserved
and regated, not reclassified as OoO evidence.

## Intent
N hardware threads over shared pipeline resources; per-hart arch state; fair arbitration.
When AI is enabled, those threads must also own **isolated AI CSR sideband state** and
must not corrupt FDT/OpenSBI under dual-issue before Linux can host concurrent tensor
workers.

## Current state (codebase)
| Item | Status |
|------|--------|
| `NrHarts` in `cva6_cfg_t` | **Live** — legal values 1 or 2 (`check_cfg`); default **1** |
| `SmtPolicy` / `SmtFetchQuantum` / `SmtStarveLimit` | **Live** — RR / switch-on-miss / hybrid (default hybrid) |
| Pipeline `hart_id` tagging | **Live** — `fetch_entry_t` + `scoreboard_entry_t.hart_id`; decoder stamps active hart |
| Banked RF | **Live** — `core/smt/g6lc_smt_regfile.sv` (NrHarts=1 → single `ariane_regfile`) |
| Dual PC bank | **Live** — `core/smt/g6lc_smt_pc_bank.sv` + frontend restore |
| Banked CSR | **Live** — `core/smt/g6lc_smt_csr_bank.sv` (commit by `hart_id`; priv mux by active; **AI aicfg/ais sideband banked**) |
| Fine-grain switch | **Live** — IF + unissued flush only; EX drains; BP preserved |
| Per-hart WFI halt | **Live** — sticky `smt_hart_halt` from `halt_csr` |
| Per-hart RAS | **Live** — `ras.sv` banks when `NrHarts>1` |
| Per-hart GHR | **Live** — `g6lc_bp_ghist` + gshare GHR banks |
| Shared BHT/BTB | Shared tables (cross-hart pollution possible) |
| `g6lc_thread_select.sv` + `g6lc_hart_state.sv` | **Live** under `core/smt/` — inventory [`../core-fetch/SMT-LEGACY.md`](../core-fetch/SMT-LEGACY.md) |
| Soft-ladder DI residual | **Active** — Variane cookie `51b1babe` is the SUCCESS pin; QEMU dual-hart OpenSBI/Linux is **not** that pin. SL-C topology + R3b Image still open. Snapshot: [`../current-stage.md`](../current-stage.md). Perf-foundation SMT **control** is `qual-soft-ladder-osbi`. 2026-09-15 reviewed state: full 48 KiB N1 checked-work passes with current fetch fixes, including renewed RR0/RR1 controls. Explicitly IPI-activated RVI and mixed C/I integer checked-work now pass independent retirement/operand checks; original no-IPI N2 does not activate hart 1. This does not close natural firmware or the broader SMT ISA envelope. Historical bisect/VT12 attributions do not establish the current root cause. See the completion gate below, `../core-fetch/NEGATIVE.md` §12 and `AGENTS-todo.md`. FPR remains unbanked. |
| QEMU SMT2 firmware | **Green as hypothesis** — `g6q run` OpenSBI/U-Boot/EDK2/OpenWrt `--smp 2` on virt and generated soc | Never cite as Variane |
| AI / PyTorch host path | **Live soft** on `g6lc64_ai` + virt-ai-pcie + EDK2 DESC join; **SMT2 multi-thread pytorch** after SL-C + Image |

### Fetch_B-only issue-order increment (2026-09-18)

The nine shared SMT modules now live in `core/smt/`; the relocation alone preserved
source bytes and the SMT2 executable hash. Active manifests and generated model input
lists exclude `fetch_A` and `smt_legacy`. The source-boundary check has rejection controls.
A separate barrier repair uses issue-lane order rather than PC magnitude for same-group
SP dependencies. Leaf positives, oracle negatives, restored-defect controls and a
live-port synthesis smoke pass; the previously blocked call now retires in firmware.
After the issue-order repair alone, the unchanged workload still timed out without its
cookie (900-second wall limit, 9,019,026 cycles of a requested 12M). The next increment
below supersedes that cookie result, not the two-active-hart qualification boundary.
Artifacts and scope are recorded in `../../AGENTS-todo.md`.

### Completion cookie reached; second-hart qualification remains open (2026-09-18)

A separate WT D-cache tag-response ownership repair in `wt_dcache_wbuffer.sv` removes
an observed stale stack reload. It selects the registered normal-lookup tag using the
previous accepted request's `check_en_q`, not current pending work. The unchanged ELF
`1a8bd52a...` reaches `51b1babe` and companion `51b1d000` at **1,693,696 cycles**, with
`plat_hc=2`, `last_hartidx=1`, `coldboot_done=1` and the banner marker. Model `d22bbbdc...`,
corrected runtime `dfbc2c4a...`, VT1/seed1 and generated fetch_B-only inputs are retained
in `remote-runs/smt2-progress-cookie-20260918`. The earlier model `99dc42f3...`,
without progress-counter instrumentation, repeats the cookie at the identical cycle
and final pins (`smt2-wttag-cookie-repeat-20260918`).

**Do not equate topology enumeration with execution.** The opt-in typed progress
summary counts 1,301,234 non-dropped retirements for hart 0 and zero for hart 1.
That model's `cva6.sv` masked unseen secondaries until IPI activation. On the same model,
`mini_ipi_hart1_sp.S` terminates with hart counts 256/16 and the secondary stack set.
A private copy replacing only its two IPI stores with equal-sized NOPs does not
terminate and counts 4024/0. Those activation controls validate the observer's
positive direction, not dual-hart completion of this OpenSBI workload.
The boot policy, firmware bytes and success oracle were not relaxed.

### Reset-time execution and natural-profile gate (2026-09-19)

Fetch_B now makes enabled/non-halted harts eligible from reset. The old fixed boot
hold and unseen-until-IPI masking are excluded from its compiled behavior. A registered
handoff request quiesces decode admission and waits for scoreboard and committed
store/write-buffer drain before changing active context. Admission is also stopped
for a halted SMT hart. These conditions replace boot timing assumptions with a
pipeline ownership boundary; in-flight data-miss overlap is deliberately reduced.
The reset election/publication mini passes mixed C/I and norvc (642/643 cycles),
with its result-corruption control firing. Scheduler controls and synthesis are
recorded in `../../AGENTS-specs-to-tests.md`.

**Correction to the old topology interpretation:** the frozen `1a8bd52a...` payload
forces hart_count=2 and stubs FDT property access to NULL. With both harts scheduled,
it reaches the shared cookie at1,902,592 cycles and counts1,262,228/123,436 retirements,
but hart1 reads `[0,0]` from the hart-ID table, fails its lookup and enters
`_start_hang` before assigning its stack. This is not healthy dual-hart completion.
Artifacts: `smt2-both-harts-cookie-20260919`, `smt2-hart-map-audit-20260919`,
`smt2-payload-policy-audit-20260919`.

The user selected a separate source-built profile rather than another byte-patched
fixture. `run_opensbi_source_review.py` builds pinned OpenSBI v1.5 with the existing
platform/toolchain adaptations, natural FDT/startup/HSM code and the strict S-mode
payload. The old image remains unchanged as a regression. Strict HSM/payload
completion is pending; neither a banner nor a cycle-cap SUCCESS substitutes for it.
The first source build (`opensbi-source-dual-v3-20260919`, ELF `6b2bad99...`) is red
at8M cycles despite both harts retiring. The exact same ELF on the retained held-hart
model writes a correct `[0,1]` hart table and count2; the dual-active run instead
loses a call continuation across a handoff. A typed snapshot selects transport
`0x800073f0` with empty decode/IQ, and execution resumes mid-instruction. The
transport/restart boundary is the next investigation; no PC-specific repair is
permitted. These source-profile results do not promote the startup candidate to
production qualification.

The next correction makes the existing PC bank retirement-owned for fetch_B's
quiescent path. Architectural redirects override retired successors; speculative
transport/halfword continuation addresses cannot replace them. The before test and
private overwrite mutation fail, while bank positives, checker negatives and
live-port synthesis pass (27 cells, no latch/SCC). The same natural ELF on model
`3b4fec56...` now reaches distinct initialized stacks and counts325,919/5,447,462
retirements at8M cycles, but still has **no strict supervisor payload completion**.
Hart0 reads zero from the shared init-count-offset word after a 0x80 store and enters
`sbi_hart_hang`; hart1 continues firmware. That is the next visibility investigation,
not permission to add a firmware fence or force a value. See
`opensbi-architectural-pc-dual-20260919` and `opensbi-natural-init-audit-20260919`.

The subsequent WT fixup freshness repair makes that load return0x80 at the same
cycle and moves hart0 into the normal `sbi_hsm_init` wait, rather than its error hang.
An older retained copy had survived a newer ACK because the fixup queue was full.
Existing-copy refresh, byte preservation, same-cycle export and coalescing/retirement
controls are in `run_wt_fixup_review.py`; see `../dcache-ack-before-check.md` for scope.
`opensbi-fixup-preserve-dual-20260919` records325,952/5,447,347 retirements at8M cycles
on model532dc9a2... with the exact same ELF. **Strict supervisor payload completion
is still absent.** Hart1 remains active in libfdt; primary cold-boot progress is the
next discriminator. No firmware workaround or broader architectural promotion.

### Source-built dual-hart completion (2026-09-19)

**The strict OpenSBI/HSM supervisor payload now passes at12,765,628 cycles.**
The fixed ELF6b2bad99... runs on modelc421aedc... with retirement counts333,635 and
8,932,406. Both logical harts publish their supervisor-mode seen flags, the HSM
peer publishes its checked result, and the primary writes explicit tohost success.
This is not a cycle-cap verdict or the old shared soft-ladder cookie. Artifact:
`remote-runs/opensbi-counter-split-dual-20260919/output/results.json` from repo root.

The last RTL repair distinguished AMO commit readiness from operand data readiness.
An LR placeholder0 had reached BNE before its real2 result committed. Consumers now
wait for the committed RF value; directed RVC/norvc, RS1/RS2/ALU and negative cases
pass. The following PMP assertion stop was removed by a **private Verilator compiler
control**, not by editing PMP logic or disabling checks: split the lzc index_nodes
and sel_nodes packed arrays with split_var. All18,502,243 retained retirement lines
from the assertion-stopped model match exactly before the successful extension.
PMP logic, assertions, vendor sources and repository warning waivers are unchanged.
The control SHA256 is be176b279ada076a3459d8bd6509e0946ccf0994d5c35a092bede308bba8c8ff;
its exact file and model/ELF/runtime provenance are retained in the run.

Qualification remains scoped: one pinned source profile/seed/VT1, not Linux boot,
all SMT/FP/OoO combinations, unbounded liveness or physical timing sign-off. The
compiler control is opt-in, not a change to default build policy. Rename elaboration
has since been repaired and its bounded task passes; broad formal stays red on the
unresolved fetch-IQ assertion/witness failure. OoO-only ownership repairs preserve
the passing SMT2 executable byte-for-byte, but do not qualify OoO execution or
dual-runnable scheduling balance.

### Phase1 measured service baseline (2026-09-19)

The adaptive-policy investigation begins with a static, fixed-work M-mode benchmark,
not scheduler retuning. `SMT_BALANCE` in `smt_dual_active.S` runs512 checked iterations
per worker with hart-specific ROI markers. `run_smt2_soak_review.py` selects it with
SMT2_REVIEW_STARTUP=1 and SMT2_REVIEW_BALANCE=1. Both encodings pass; solo0/solo1 use
identical RVC instruction bytes to the shared run, differing only in active-mask data.
The oracle checks the complete ordered four-instruction body512 times per hart,
computed results/publications, explicit termination and typed retirement ownership.
Observer-off replay matches the retirement trace and termination cycle exactly.

`smt2-balance-ordered-20260919`: RVC common-window retirement service49.9264%/50.0736%,
2,048 body retirements per hart, ROI5709/5708 cycles; largest observed inter-retirement
cycle gap76 for each hart. Weighted shared/solo speedup0.90234 and worst-hart
slowdown2.21795x. Thus observed service is balanced for this loop, but shared execution
is not a throughput win. No architectural fairness bound, saturation, cache RTT or
Linux qualification is inferred. The result-corruption control fails;19 tooling tests
include empty/dropped/duplicated/reordered/misattributed trace refusals.

#### Service, handoff and load-latency attribution (2026-09-19)

Two read-only simulation observers were added inside `translate_off`. A mechanical
source check confirmed their location; that is not a synthesized-netlist equivalence
proof or timing/area sign-off:

- `core/smt/g6lc_thread_select.sv`, plusarg `smt_sched_trace`: an edge-compressed
  `[smt-sched] state` line (active/ready/dmiss/imiss/block/quiesce/hold/trap/flush)
  plus `decide`/`switch`/`abort` events carrying the switch reason and the drain wait.
  Its cycle counter matches `smt_flow_cycle` in `scoreboard.sv` so the numbers can be
  correlated with retirement cycles.
- `core/cva6.sv`, plusarg `smt_rtt_trace`: `[smt-rtt] req/resp/kill` on the core load
  port, paired by the load-buffer id. Ownership is the scheduler's active hart, since
  the LSU carries no hart id; cross-switch, killed and censored samples are excluded
  rather than attributed.

`smt2-balance-attr-final-20260919` on instrumented model 2ce91d639b964cfb…, RVC arm,
5,665-cycle window: selected 2834/2831, eligible-unselected 2831/2834,
ineligible-unselected 0/0, longest continuous denial 68 cycles each, quiesce 332
cycles (5.86%). These are residency/eligibility measures, NOT accepted work or
utilization; the parser now labels them accordingly. **All 83 handoffs fired on
anti-starvation, with zero quantum switches, zero miss switches and zero aborts**,
and every drain waited exactly 3 cycles (total 249, max 3). Raising the current
quantum alone cannot help this case; shortening it sufficiently could change the
reason mix. These measurements do not attribute refetch loss or fully explain the
2.218x slowdown. The prior stronger causal statement is withdrawn.

The load observer is alive (23 events) but records **zero in-window samples** because
the fixed-work body is register-only, so **cache RTT remains unmeasured** and no
latency conclusion may be drawn from this workload. Asymmetric memory/lock/IPI phases
are what will exercise it.

Boot preservation was re-established on the instrumented model rather than assumed:
`opensbi-attribution-dual-v3-20260919` reports `strictDualPassed=true` at the identical
12,765,628 cycles with identical 333,635/8,932,406 per-hart retirements and identical
firmware/payload/DTB hashes. The reset-rendezvous and LR/SC regressions also pass both
encodings with their negative controls on that same model.

Two codebase defects were found and fixed while doing this: an **ungated** `[id-dbg]`
`$display` in `core/id_stage.sv` was writing ~134 MB into every run's log (now behind
`id_dbg_trace`), and the build harness had no way to pin a reviewed Verilator control,
so `SOFT_LADDER_BUILD_VLT_ARGS` was added (default empty, not a policy change). A third
defect is recorded but not fixed: `testharness_proxy.py build --vthreads` is silently
ignored for non-AI flavours; use `SOFT_LADDER_VERILATOR_THREADS` instead.

The scheduler settings and pinned OpenSBI ELF are unchanged.
Future adaptive policy must rank only legally eligible work, retain a static fallback
and minimum service/credit floors, and never throttle completion/draining obligations.
The drained handoff cannot hide an outstanding load by running the peer before it
finishes. Measure switch reasons/refetch/drain and asymmetric cache/lock/IPI workloads
before choosing policy changes. Linux topology, interrupts, shootdowns, locks and
FP context are separate gates; see the active plan Phase6 adaptive extension.

### Shared-core capacity and software-hint contract (2026-09-19)

Optimize useful work on one physical core, subject to forward-service and latency
constraints, not equal runnable task counts across two presumed independent cores.
Biased fetch first operates at safe handoff boundaries. Elastic RS/IQ reservations
and opportunistic sibling supply require per-hart OoO namespaces, precise recovery
and coherent group allocation before mixed-lane issue. QoS may bound new admission,
not response/store/invalidation draining. Minimum service and a static fallback remain
mandatory; low IPC can identify a lock holder or dependent producer, not disposable work.

**Measured sequencing constraint.** Three paired batches now bound what arbitration can
achieve on the current drained handoff: symmetric 0.902, compute/memory 0.929/0.926 and
dependency-limited **0.8985** — the canonical SMT win case is the worst of the three,
even though solo IPC of 0.62 vs 0.82 proves the slack is real. Instruction-level overlap
is identically zero because only one hart issues at a time, and attribution shows all 83
handoffs already firing on anti-starvation rather than quantum. So biased fetch, RS/IQ
partitioning, leftover front-end slots and FU issue fallback have **no headroom to
capture and are gated behind the Phase 4 mixed-resident subgate**; an apparent gain
measured before it would be an artifact. The one exception is a yield/pause hint, where
the lock result shows a spinning waiter costs the holder 2.3456x for nothing — that is
recoverable by admission control alone. Order the work: yield/pause hint, then Phase 4
mixed residency, then the redistribution mechanisms and QoS rate control.

The existing DT describes thread0/thread1 under core0. Software-visible fairness hints
are still a design gate, and the counter-ownership question is now MEASURED rather than
inferred (`smt2-pmu-ownership-20260919`, SMT_PMU mode). With a handshaked write order,
hart1 reads back hart0's mhpmevent3 selector and hart0 reads back hart1's; a per-hart
design would show zero on both, and that hypothesis arm fails as required. mscratch
still reads back per hart, so the CSR bank works and this is not a fixture artifact.

Source agrees: `g6lc_smt_csr_bank` builds one `csr_regfile` per hart but muxes
perf_addr/perf_data/perf_we by `active_hart_i` into a SINGLE core-level
`perf_counters`, broadcasting scountovf/lcofi back to every bank. So one hart's
selector write clobbers its peer's; counts mix both harts because the event sources
are core-wide commit/cache signals; any HPM CSR write suppresses counting for all
counters that cycle; Sscofpmf privilege filtering applies the active hart's privilege
to a shared counter; and an overflow raises LCOFI in both harts, either of which can
clear OF. RISC-V defines mhpmcounterN/mhpmeventN as per-hart CSRs, so this is a
conformance gap at NrHarts>1 and a blocker for any advertised PMU or fairness hint,
not a cosmetic omission. mcycle/minstret ARE banked and minstret is gated by
`commit_instr_i.hart_id`, but mcycle advances in every bank every cycle: it is elapsed
time, never that hart's selected or accepted service. A forward risk for mixed-hart
work is that `commit_sel` uses ONE `commit_instr_i.hart_id` for all commit ports,
which holds only while the drained handoff keeps each group single-hart.

**Repaired (2026-09-19), same probe as the discriminator.** `perf_counters` now banks
generic_counter/mhpmevent/OF/MINH/SINH/UINH by a new `hart_i` index dimensioned from
the existing `CVA6Cfg.NrHarts`, so no config field is added and NH=1 collapses to the
previous single bank. scountovf/lcofi became per-hart vectors routed to the matching
CSR bank rather than broadcast, and since only the owning bank increments, a peer's
HPM CSR write no longer suppresses this hart's counting. Per-hart banking was chosen
over the legal read-only-zero alternative because that leaves the second Linux CPU
with no counters at all. Added state is exactly (NH-1)*MHPMCounterNum*(64+8+4) = 456
flops at NH=2; mapped area, timing and power are NOT measured here.

`smt2-pmu-banked-v2-20260919` on model 80ad8af04fa1491115ac1a3543c15bea6027992af82bc31f730ebd59bfb86113
reports countersArePerHart=true with the banked signature (h0=1, h1=0): hart0 still
reads back its OWN earlier write while hart1 never sees it, so isolation holds in both
directions. The shared signature (2,1) is now the failing control. The first banked
expectation of (0,0) was wrong and the measurement corrected it — hart0 legitimately
keeps its own value. Boot preservation re-checked on the repaired model:
`opensbi-pmubank-dual-20260919` strictDualPassed=true at the identical 12,765,628
cycles with identical 333,635/8,932,406 retirements. The asymmetric, balance, startup
and LR/SC regressions pass, 36 tooling tests pass, and lint/synthesis warning counts
are unchanged on g6lc64_smt2 (1/31), cv64a6_imafdc_sv39 (8/32) and cv32a65x (54/5).

The final source (after a separate RV32 read fix below) was re-validated end to end on
model d3b95654062fc27156360c9b612bbb13adcf1a7db4abce19c228557867dd3a93:
`opensbi-final-dual-20260919` strictDualPassed=true at 12,765,628 cycles with
333,635/8,932,406 retirements, and `smt2-final-{pmu,asym,balance,startup,lrsc}-20260919`
all pass.

A separate defect in the same file was repaired by inspection: the RV32 user-mode
`hpmcounterNh` read used `>` so hpmcounter3h (0xC83) never matched, and its index
subtracted the MACHINE base 0xB83 from a USER address, giving 258 into a [1..6] array.
This is live rather than latent — `cv32a6_imac_sv32` is XLEN=32 with PerfCounterEn=1
and RVZihpm=1 — and that target now lints clean remotely (85 warnings, no recorded
baseline, so a pass rather than a no-regression comparison). RV64 is unaffected: the
branch body is `riscv::XLEN == 32` guarded and its only other statement sets
`read_access_exception`, which perf_counters never reads or drives to a port. No
directed RV32 counter test exists; adding one needs an RV32+Zihpm simulation profile.

mcycle was checked against the spec of record and is NOT a defect: it counts "clock
cycles executed by the processor core on which the hart is running", so counting core
cycles in every bank is conformant — it simply is not a per-hart service metric.
minstret counts "instructions the hart has retired" and is gated by commit hart id.

**Event attribution measured (`smt2-pmuevt-attrib-20260919`).** Banking the selector
does not by itself prove the counts are per-hart, so `SMT_PMUEVT` has both harts select
"load accesses" in their own mhpmcounter3 and run very different quotas (256 and 768)
in a window spanning many handoffs, reading the counter either side. Measured deltas
are exactly 256 and 768 — each hart counts only its own loads, with no cross-hart
inflation, and the exactness also shows no two loads retired in the same cycle in this
dependent loop. The test asserts bounds rather than an exact count because the event
ORs the commit ports, so a dual-commit would legitimately undercount; the arm expecting
the shared/cross-attributed value near 1024 fails, as does the corruption control.

**Cross-switch attribution closed (`smt2-pmumiss-isolation-20260919`).** The load probe
above uses commit-derived events and cannot expose a long-latency event charged to the
successor, so `SMT_PMUMISS` tests that directly: hart0 strides 64 times past the 32 KiB
D$ while hart1 issues NO memory access but runs long enough to be scheduled throughout.
Measured hart0 = 64 D$ misses, hart1 = exactly 0. The arm that would accept a nonzero
hart1 count fails, so the probe really would detect a leak. This agrees with the RTL:
`wt_dcache_missunit` pulses `miss_o` on `mshr_allocate` and `g6lc_icache` pulses on the
accepted ifill, i.e. at miss INITIATION, not refill completion — and the drained handoff
additionally requires an empty scoreboard and no pending stores before switching, so a
demand memory instruction cannot span a switch at all. A one-cycle boundary at the
handoff itself remains un-probed rather than proven impossible.

Side result worth keeping: hart0 taking 64 misses for 64 strided accesses confirms that
the asymmetric workload's stride really does defeat the cache, so the ~7-cycle load RTT
recorded there is a fast-served MISS, not a hit. That is two independent measurements
(WT lookup hit=00, and the D$-miss counter) agreeing.

Not closed: mcycle remains elapsed cycles rather than per-hart service (conformant, see
below); and SBI PMU mapping plus counter save/restore across context switches remain
unqualified. A translate_off assertion now fails loudly
if a committing hart ever differs from the attributed hart, which is the Phase4
tripwire for mixed-hart retirement. Firmware hint exposure still needs those gates. Prefer a small programmable pool of elapsed,
accepted-work, eligible-unselected and coarse-pressure events, with window ratios in
software. Avoid per-station detail, duplicated full PMUs and an unrestricted priority
ABI. The plan's B1/Phases1b/4/6/8/9 specify the implementation and Linux interaction path.

Measurement repairs in the existing SMT_ASYM fixture/runner:

- Hart0 formerly spun on the peer's done flag while hart1 parked. Completion now uses
  an atomic last-publisher election; either early finisher parks and the last publisher
  verifies every active worker's exact result and done flag. This is a benchmark fix,
  not a hardware speedup. The swapped compute ROI changes5743->3782 cycles in RVC.
- Both role orders have matched solo controls on BOTH harts and identical text within
  each encoding. The report separates the common window, per-hart ROI and physical-core
  batch span; it never sums overlapping sibling times as a core-time denominator.
- Scheduler output now says selectedCycles, eligibleUnselectedCycles and
  ineligibleUnselectedCycles. No arbitrary50/50 threshold or accepted-service claim.
  RTT outstanding/age is sampled at the window end, not after later responses finish.
- The role-PC oracle now rejects execution of an unassigned role even when it lies
  outside the expected role's address span. Directed negative/unit tests reproduce
  that blind spot and the RTT horizon bug before repair.

Artifacts: smt2-core-capacity-20260919 and smt2-core-capacity-norvc-20260919. Each has
six positive arms and one result-corruption negative; both shared arms also match an
observer-off retirement trace and termination cycle. All positive memory ROIs have
exactly64 measured loads; compute ROIs have zero own loads.36 tooling tests pass.

| Encoding / role order | Shared batch cycles | Sum of matched solo ROIs | Batch ratio solo/shared |
|---|---:|---:|---:|
| RVC compute0/memory1 | 3767 | 3498 | 0.92859 |
| RVC memory0/compute1 | 3782 | 3504 | 0.92649 |
| norvc compute0/memory1 | 3784 | 3503 | 0.92574 |
| norvc memory0/compute1 | 3784 | 3509 | 0.92733 |

All ratios are below1: this finite seeded workload does not justify pairing for
throughput. It is not a steady-state saturation or physical-power result. A7-cycle
load RTT is NOT a hit oracle: retained WT lookup samples for such requests show
hit=00/no forwarding, while some1-cycle returns use seed-store forwarding. No cache
level is assigned from latency, and byte span alone ignores set/way conflicts.

This increment changes only tests/analysis/docs and reuses the qualified2ce91d... model
and pinned firmware. It does not rerun or broaden the recorded OpenSBI proof. Licensing:
existing tier-T MIT attribution retained; no new link set. Timing/area/DFT/ISA/DTS:
unchanged by this increment; hardware hint/policy promotion still needs their full gates.

### Memory-service sweep: the penalty grows with memory pressure (2026-09-19)

`SMT2_REVIEW_MEM_DEPTH` retargets the asymmetric memory role (stride 1024 over a
256 KiB buffer, expected sum recomputed per depth) so the miss count can be swept while
everything else is held fixed.

| Memory depth | Shared | Serial solo | Ratio |
|---:|---:|---:|---:|
| 16 | 2954 / 2962 | 2823 / 2829 | **0.9557 / 0.9551** |
| 64 | 3767 / 3782 | 3498 / 3504 | **0.9286 / 0.9265** |
| 256 | 6853 / 6838 | 6187 / 6193 | **0.9028 / 0.9057** |

**Sharing gets monotonically worse as memory pressure rises** — the opposite of the
textbook SMT expectation that more misses mean more overlap opportunity.

The RTT observer rules out the obvious explanation: median and max load latency are
**7 cycles in every configuration** — depth 16 or 256, shared or solo (16, 189 and 256
paired samples). Latency does not grow, so this is not cache interference between the
harts' working sets. It is simply that the memory role's serialised stall time grows
with depth and none of it is overlapped.

That also locates the opportunity precisely. Each iteration stalls ~7 cycles waiting
for its load, 256 times at the deepest point — roughly 1800 cycles of idle issue inside
a 6853-cycle shared run. The existing switch-on-miss policy cannot claim any of it:
`MISS_STALL_THRESH` is 32 *sustained* stall cycles with a 16-cycle blackout, so a
7-cycle stall never qualifies. Lowering that threshold would not help either, since a
drained handoff costs ~3 cycles plus refetch and the peer would have to drain straight
back. Only mixed residency can use a 7-cycle hole, which is the Phase 4 argument again,
now with a size attached to it.

### Idle sibling and per-hart IPI wake (2026-09-19)

`SMT_IPI` (SMT2_REVIEW_IPI=1) parks hart1 in WFI with MSIE set and mstatus.MIE clear
(so it resumes in place rather than trapping), runs hart0's fixed 512-iteration body
beside it, then wakes the peer through its own CLINT MSIP slot at 0x02000004. hart0
checks its OWN mip.MSIP stays clear, so per-hart IPI routing is asserted rather than
assumed. The oracle additionally refuses any run in which the halted peer retires
measured work; a unit test feeds it exactly that to prove the check bites.

`smt2-ipi-wake-20260919`: hart0 takes **2082 cycles with the sibling halted vs 2061
solo — a 1.0102x cost**, the halted peer retired zero body instructions, and the IPI
woke only its target.

This completes the Phase 1 picture and locates the cost precisely:

| Sibling state | Cost to the running hart |
|---|---|
| Halted in WFI | **1.01x** — effectively free |
| Spinning on a lock | 2.16x, recoverable to 1.37x with the PAUSE hint |
| Genuinely runnable | ~2x per hart, batch 0.90-0.93, no overlap gain |

So the shared-core penalty comes entirely from time-slicing a *runnable* sibling, not
from SMT structure: an idle sibling already costs nothing and needs no new mechanism.
That is why the remaining upside is mixed residency (Phase 4) plus the yield hint, and
not admission tuning.

### Zihintpause yield hint (2026-09-19, implemented)

The lock result below identified the one arbitration mechanism worth building before
mixed residency. `id_stage` now recovers the PAUSE encoding (`fence w,0` = 0x0100000F,
which the decoder otherwise folds into a NOP) and pulses a per-hart hint;
`g6lc_thread_select` keeps a sticky per-hart yield request, cleared when that hart is
next activated, and hands the core to an **unpaused** ready peer.

Three properties are built in rather than tuned:

- **Ranked below anti-starvation**, so a yield can never deny the service floor. The
  existing starve limit still forces a yielding hart back in.
- **Requires an unpaused peer**, so two yielding harts fall through to the normal
  policy instead of ping-ponging.
- **Advisory only** — it never gates readiness, and a wrong-path PAUSE can cost the
  hinting hart a voluntary yield but never correctness.

It is gated by the existing `ZihintpauseEn` and `NrHarts > 1`; no new config field.

`smt2-pausehint-lock-{nohint,hint-v2}-20260919` on model ba1f8f6a..., same source but
for the PAUSE word in the waiter's spin loop:

| Waiter spin loop | Holder section | Solo | Slowdown |
|---|---:|---:|---:|
| plain | 4462 | 2064 | 2.1618x |
| with PAUSE | **2837** | 2068 | **1.3719x** |

Mutual exclusion still holds in both. The residual 1.37x is the anti-starvation floor
doing its job: the waiter is still periodically admitted by design.

**No-op control:** the pre-change model (d3b95654...) running the identical source with
no PAUSE reproduces 4462/2148/2064/2066 exactly, so the RTL is inert when software
never hints. Boot preserved on the hint model: `opensbi-pausehint-dual-20260919`
strictDualPassed=true at the identical 12,765,628 cycles and 333,635/8,932,406
retirements. Lint/synth unchanged on g6lc64_smt2 (1/31), cv64a6_imafdc_sv39 (8/32) and
cv32a65x (54/5); 38 tooling tests pass.

Not claimed: no Linux or firmware use of the hint, no adaptive policy, no change to any
scheduling default, and the residual holder cost is not tuned.

### Dependency-limited worker: the forfeited SMT upside (2026-09-19)

A hart stalled on a dependency chain leaves issue slots idle, which is the classic case
SMT exists to exploit. `SMT_DEP` (SMT2_REVIEW_DEP=1) reuses the asymmetric oracle with a
new role pair: `dep` chains three multiplies through one register per iteration, `ind`
executes the same instruction count with independent destinations. Both run 512
iterations, with solo controls for each role on each hart.

`smt2-dep-ceiling-v5-20260919` confirms the premise — solo, `dep` takes 4123 cycles and
`ind` 3108 for the same 2560 body retirements, i.e. **0.62 vs 0.82 IPC**, so the
dependency chain really does leave slack.

| Pairing | Shared | Serial solo | Ratio |
|---|---:|---:|---:|
| dep0 / ind1 | 8048 | 7231 | **0.8985** |
| ind0 / dep1 | 8055 | 7237 | **0.8985** |

**None of that slack is recovered.** The pairing is not merely below 1, it is *worse*
than the compute/memory pairing (0.929/0.926), because time-slicing adds handoff cost
without ever letting the sibling issue into the stalled hart's idle slots. The ROI
windows overlap in wall-clock time (6872 of 8048 cycles) while instruction-level
overlap stays zero, since only one hart issues at a time.

This quantifies the ceiling of the current drained handoff rather than a tuning
shortfall: no fetch weighting, quantum or starvation-limit change can capture idle
issue slots, because capturing them requires both harts to be resident and issuing at
once. That is the Phase 4 mixed-residency prerequisite, and this is its measured
motivation.

### Lock holder versus spinning sibling (2026-09-19)

`SMT_LOCK` (SMT2_REVIEW_LOCK=1) gives both harts one AMO-based lock and identical
512-iteration critical sections, with same-hart solo controls. The oracle checks the
mutual-exclusion property itself — the two sections must be disjoint in time — and
then measures them; a unit test feeds it overlapping sections to prove it refuses them.

`smt2-lock-holder-v2-20260919`: sections are disjoint (hart0 550-5395, hart1
5451-7598), so AMO mutual exclusion holds between the SMT harts.

| Section | Contended | Solo | Slowdown |
|---|---:|---:|---:|
| hart0 (spun on by peer) | 4846 | 2066 | **2.3456x** |
| hart1 (peer already done) | 2148 | 2066 | 1.0397x |

The holder runs 2.35x slower purely because the waiter is spinning, and the waiter
produces nothing in that time — roughly 57% of the holder's capacity spent on zero
useful work. hart1's near-solo figure confirms the asymmetry is caused by spinning
rather than a general sharing tax.

This is the clearest argument yet that equalizing sibling service is the wrong
objective: total useful work on the core would have been strictly higher had the
waiter yielded. It also refines the earlier note — a low-IPC hart may be a lock HOLDER
that must not be throttled, while a spinning WAITER is exactly who should yield. So a
yield/pause-aware admission hint should precede any IPC- or RTT-derived throttle, and
it must key on an explicit software hint (zihintpause/WFI), never on inferred spin
patterns, lock addresses or kernel PCs. No such hint is implemented.

### Historical completion gate (2026-09-15 review)

Use the F0–F5 plan in `../../AGENTS-todo.md`. Historical cookies and NWORKERS=1
results are not proof of two active harts. The current sparse-input IQ defect
has a reproduced failing leaf test and a compaction repair; full-core SMT2
still needs closure. With queue compaction alone, fresh RVC N=1 passed but norvc N=1 failed.
A second repair aligns the prefix filter's expected PC with current-cycle
response bytes: now both N=1 variants pass (131,072 / 137,216 cycles), while
both N=2 variants still have no verdict by 500,000. Historical ELF names were misleading
(the `smt2-norvc-vt1` copy contains compressed code). Keep these envelopes
separate. Current `WtDcacheFixupDepth=2`, so the prior zero-depth exclusion of
WT fixup logic does not apply to HEAD.

Live IQ/realigner formal had an impossible narrowed hart-range assumption and
undriven stimulus; prior green labels are withdrawn pending repaired assertions
and reachability. Generic queue screening improves cell count without adding
state, but is neither physical area nor SMT2 promotion. Natural OpenSBI,
per-hart work/isolation, release/acquire, traps, WFI and atomics remain gates.

Follow-up: original N2 checked-work has no IPI and leaves hart 1 masked by the
current boot contract; RF/done-word evidence confirms it is not a dual-active
run. The existing IPI-start mini passes. Typed, generation-tagged traces locate
three subsequent boundary defects: banking transport PC past discarded ID/IQ
instructions; a foreign-hart resolution updating incoming recovery state; and
split-target completion tested against the response window rather than the
accepted instruction PC. These are repaired without changing boot/switch policy,
keeping queues alive or adding bank state. Resolution still reaches scoreboard,
LSU and predictor training; recovery is routed to the owning hart.

Final model `7037f685…` writes PASS for the byte-identical 48 KiB/hart RVI and
mixed C/I workloads at 282,624 / 270,336 cookie polls. More importantly, the
4 KiB/hart independent reference checks pass 13,696 / 14,202 retirements and
25,774 operand checks each. One cross-hart flag value is outside the local
memory-order assertion. Observer-off/on fingerprints match, and both positive
and injected-error checker controls pass. A cookie PASS after the first repair
had hidden another sequence loss; that intermediate result is not qualification.

Targeted restart/owner/acceptance proofs and covers, bank tests, SMT2/minimal
lint and full-core synthesis pass. Independent IQ proof still times out. Natural
firmware, broader ISA/FP/trap/atomic/concurrency coverage and physical gates stay
open. Matched revalidation against the private, canary-checked Verilator
runtime also passes these integer traces and full-workload replays; use baseline
`5a10acc1…` / observer `528b720c…` and the recorded runtime header identity.
The installed Verilator 5.008 header is unchanged and still needs correction
before it can be trusted for new native runs. Evidence and exact scope:
`../core-fetch/README.md`, typed-trace section.

### Model: fine-grain SMT (drain-friendly)
On thread switch: flush **IF** and drop **unissued** decode; restore banked NPC; **do not** clear scoreboard/EX or BP. Outgoing-hart ops retire with CSR/RF keyed by instruction `hart_id`. Active fetch hart owns RAS/GHR bank and privilege mux. See `smt2-bringup.md`.

### Contention optimisations (where dual-hart contentions bite)
1. **Switch-on-D$/I$-miss** (`SMT_SWITCH_ON_MISS` / hybrid) — sticky miss state in `g6lc_hart_state` forces an immediate peer switch when the peer is ready.
2. **Fetch quantum RR** (`SmtFetchQuantum`, default 4) — bounds unfair share of IF bandwidth.
3. **Anti-starvation** (`SmtStarveLimit`, default 16) — force switch if a ready peer has been idle that many cycles.
4. **Banked integer RF** — per-hart private 32-entry banks eliminate cross-hart write-port conflicts.
5. **L2 MSHR merge + data banks (U6.0)** — sized for dual-hart MLP.
6. **Boot-crutch retirement (`SMT_COLD_EXCL`, `SMT_FIRST_ACT_EXCL`)** — temporary; not a product feature. Retire when `plat_hc==2` and `coldboot_done==1` are stable on natural OpenSBI.

### Enable
```
core/include/g6lc64_smt2_config_pkg.sv   # NrHarts=2, SMT_HYBRID, L2
# Default packages keep NrHarts=1 (identity netlist path).
# Bring-up: architecture/multi-threading/smt2-bringup.md
```
`mhartid` for thread *h* = `hart_id_i + h`.

## Sanctioned seam
`NrHarts==1` remains behaviourally identity. Optional next / SMT2 product closeout: retire `SMT_COLD_EXCL`/`SMT_FIRST_ACT_EXCL`, dual-commit two harts same cycle, banked BHT/BTB, FP register banking, idle-thread clock gate, `Zawrs`/wait-for-peer, and `SMT2` as a default SKU (not only an experimental package).

## Harness of record (execution)

All SMT / soft-ladder / dual-hart / 8-hart **evidence** (Spike ISS, Variane soaks,
peels, TRACE, I4dp Linux 200M-cap) is produced only through
`verif/regress/remote/testharness_proxy.py`. Plan:
[`testharness-proxy.md`](testharness-proxy.md). Local WSL `work-ver-*` and
`p<N>` scripts are not pins. Classify from `runs/<tag>/run-*.log`, not proxy rc.

**Linux-boot scale** (OpenSBI observation ladder, `smt_legacy` oracle only,
fetch_B’s four combos, named envelopes for N/T/I/RVV/stream):
[`linux-boot-scale.md`](linux-boot-scale.md). Do not merge packages; do not
churn `core/frontend`.

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

### Soft-ladder × SMT RTL seams (iter-013 / S4)

| Mechanism | File | SMT rule |
|-----------|------|----------|
| Younger cancel on mispredict | `core/scoreboard.sv` | Same-hart only when `NrHarts>1`; DI cancels LOADs too |
| Unresolved CF / CSR / **SP** | `core/issue_stage.sv` | Per-hart stall bits — peer thread keeps issuing. I4au: CF also clears on same-hart CTRL_FLOW commit; no arm on `flush_unissued` |
| Banked RF write hart | `issue_read_operands` + `g6lc_smt_regfile` | `whart` from commit instr (never hardwire 0) |
| Banked CSR + AI | `g6lc_smt_csr_bank` | AI aicfg/ais mux by **active** hart; dirty/setcfg to **commit** hart |

DI OpenSBI residual (`PEEL_FDT_GETPROP`) is primarily dual-issue + stack/CF integrity on **hart 0** during coldboot; SMT peer must not share RF/CSR banks or global issue stalls.

## AI attunement (SMT × island × host)

SMT does **not** implement GEMM; it makes multi-hart software and per-hart AI control
state correct. Island compute stays in `corev_apu/ai_island/**` and host stacks in
`ai-tensor/`. Attunement rules:

| Rule | Why |
|------|-----|
| **Per-hart AI CSR banks** | `aicfg` / `aistatus.ais` / dirty-setcfg sideband live in `g6lc_smt_csr_bank` (mux by active fetch; writes gated by commit hart) — no shared sticky AI state across threads |
| **Island is SoC-shared** | MMIO/DMA queues are **not** per-hart RF; concurrency uses descriptor QoS / multi-queue isolation (`ai-matrix/isa-encoding.md` §7.1), not mhartid alone |
| **Soft-ladder before topology trust** | Do not claim dual-hart pytorch/Linux green until FDT/`plat_hc` is honest under DI (`soft-ladder` SL-A…C) |
| **Package split is intentional** | Residual DI: `g6lc64_smt2`. Tensor soft/HARD default: `g6lc64_ai` + `virt-ai-pcie`. Unified dual-hart+AI board is a later package (after SL-C) |
| **TB probes follow hierarchy** | Variane hangpc CSR probes for smt2 use **banked hart0** paths (`gen_banked.gen_csr[0]`); single-hart packages keep `gen_single` in their own rebuilds |
| **Fast iteration** | Suite `smt2-ai-tensor-track` default **fast** — climb only on failure class |

### Doc map (AI-attuned)

| Doc | Role |
|------|------|
| [`smt2-bringup.md`](smt2-bringup.md) | SMT enable + dual-hart Linux CI sketch |
| [`AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`](AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md) | **Foundation (philosophy):** propositions P1–P7, thought patterns T1–T10 in sentence pseudo-code, the six speculation-visibility channels, the feedback-latency ladder L0–L7, and worked `core/` + `corev_apu/` reasoning transcripts. The layer the logics and heuristics docs pull from |
| [`AGENTS-smt2-opensbi-dev-logics.md`](AGENTS-smt2-opensbi-dev-logics.md) | **Planning aid (not law):** OpenSBI source → obligation → invariant → `fetch_B` combo, as heuristic pseudo-code (blame router, negative pruner, verdict semantics, capability navigation) |
| [`smt2-product-closeout.md`](smt2-product-closeout.md) | Post-cookie SMT2 product closeout + FDT `smt,*` compensation properties |
| [`soft-ladder/`](soft-ladder/) | DI OpenSBI residual promotion (B1→B3) |
| [`fdt-topology-soft-ladder.md`](fdt-topology-soft-ladder.md) | `NrCores`×`NrHarts` DTS / cpu-map |
| [`smt2-ai-tensor-linux.md`](smt2-ai-tensor-linux.md) | **Staged T0–T6 track** + speed contract + lab status |
| [`../ai-matrix/hard-tests.md`](../ai-matrix/hard-tests.md) | AI HARD narrow/ci/peak surfaces |
| [`../../ai-tensor/AGENTS.md`](../../ai-tensor/AGENTS.md) | Host PyTorch / Device ABI |

## Invariants
Per-hart precise traps and isolation; RVWMO per and across harts; no starvation (enforced by `SmtStarveLimit` under hybrid).
AI sideband and RF banks remain **per-hart**; island queues remain **SoC-isolated**, not RF-banked.

## Status vs scaffold
**Fine-grain dual-PC + CSR/RF/RAS/GHR banks + drain-on-switch + AI CSR sideband.** Production default remains `NrHarts=1`.  
**SMT2 product closeout is open:** cookie green is a gate, not completeness; the remaining items are listed in `smt2-product-closeout.md`.  
**Linux path:** boot-path + rootfs preflight in-repo; full rootfs needs external images.  
**AI path:** soft pytorch green on virt-ai-pcie; multi-thread host workers gated on soft-ladder topology trust.
