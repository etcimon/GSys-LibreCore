# AGENTS-specs-coverage.md — RISC-V spec coverage summary

A **status-only** summary of which RISC-V specification chapters CVA6 implements and tests. This is the
headline view: it deliberately carries **no file references and no line numbers** — a chapter marked
*Implemented & tested* means the behavior exists in RTL *and* is exercised by the test flow, nothing more.

- This file is **derived**, not authored: a chapter's status comes from `AGENTS-specs-to-impl.md`
  (does the RTL implement it?) and `AGENTS-specs-to-tests.md` (does a suite exercise it?). To find the
  *where*, open those two maps; this file intentionally omits it.
- Chapter numbering and anchors follow `agents/spec/INDEX.md`.

> **Standing discipline (see `AGENTS.md`).** Re-derive the affected rows here whenever
> `AGENTS-specs-to-impl.md` or `AGENTS-specs-to-tests.md` changes. Do not hand-edit a status without a
> corresponding change in one of those two source maps.

---

## Precise misalignment and instruction recovery — qualification open

The original load-offset assertions are currently restored. The earlier alignment-qualified
checks were tautological for the tested offset width and cannot support a preserved-detection
claim. Historical trap and wrong-path tests remain useful captured evidence, but current-source
qualification requires non-vacuous precise-exception and bad-completion controls with explicit
configuration-dependent trap-value expectations.

A frontend kill-persistence candidate has local frozen-program before/after evidence, not full
transaction-lifetime or cross-hart qualification. Request replacement, same-address refetch,
response/kill overlap and independent observer coverage remain open. Failure with out-of-order
execution disabled does not establish general backend exoneration.

The repeated PMP assertion stop is now attributed to an omitted, already-qualified compiler control
rather than to core RTL. Two models from one unmodified source state, differing only in that control,
were soaked on identical frozen firmware: the controlled model completed the protected dual-hart
workload at the historical length and retirement counts, and the uncontrolled model stopped at the
recurring cycle. No protection logic or assertion was weakened. Attributions previously drawn from
recipe-mismatched builds are void.

The controlled model has runner-certified protected-workload observations. These are non-regression
results, not a measurement of fetch-recovery activation. Same-model replay and host-tooling
regressions do not add independent ISA coverage. Early termination remains unowned; complete LR
read/address visibility, precise recovery and broad memory ownership remain open. No architecture,
physical or guarded-feature status advances from qualification-tooling changes alone.

## FP OoO behaviour and the fetch-target-queue replay defect (2026-09-21)

**FP out-of-order behaviour has Spike-compared directed evidence on a qualification-only build; the
production guard stays.** The suite found a real frontend defect on every FTQ-enabled configuration
(a queue replay did not flush the FTQ, and a prefetch response could be consumed as supply —
skipping a window or livelocking); both causes are fixed with the protected configuration untouched
and exact, and the directed reproducer now passes on every affected configuration.
The FPU ownership mutation is caught at leaf level but is structurally unreachable at core level
in this geometry; the bar for lifting the single-hart FP guard is not yet decided.

## OoO issue queue structure and fetch proof repair (2026-09-21)

**Structurally leaf-qualified; behaviour unchanged by construction and by measurement.** The issue
queue no longer moves entries; every directed and firmware result is cycle-identical. The structural
timing screen improved the payload path, and the cascaded grant brought the select cone below where
the compacting design stood (module max 23.97 → 16.0). Both fetch proofs that had been failing pass
again with corrected environments; the hart-switch-vs-pending-redirect selector contract is now an
explicit open obligation rather than an implicit assumption.

## Fetch-response ownership and precise load misalignment (2026-09-21)

**Proven at the frontend boundary and exercised on firmware; two older fetch proofs found
failing.** Fetch responses are owned by request token rather than address, with a bounded proof
against an independent ledger and a mutation witness; the frozen failing layout passes. Misaligned
loads are checked for precise single delivery with kill and tval semantics instead of aborting the
simulator. Two pre-existing fetch proofs (redirect hold, queue non-interference) fail on HEAD and
remain open.

## OoO CSR table, store reservation and load bypass (2026-09-21)

**Leaf-qualified and exercised on the integer-OoO firmware vehicle; not release-qualified.** CSR
accesses issue without freezing the fixed-latency unit, stores issue out of order behind a
dispatch-time slot reservation, and loads pass resolved stores and, with the predictor, unresolved
ones, with replay proven end-to-end. In-order behaviour is unchanged. Timing and full-core
qualification remain open.

## OoO age key and memory-order replay (2026-09-21)

**Leaf-proven and directed; full-core path inert until loads may bypass stores.** One
program-order key is shared by the issue queue, load/store queue and store buffer; the load/store
queue detects a load that read before an older overlapping store resolved and the pipeline can
replay it from commit. Formal evidence is non-vacuous (assert counts recorded); a pre-existing ROB
proof that had checked nothing was corrected. Full-core bypass, store-buffer liveness assertion and
timing remain open.

## OoO FP result ownership (2026-09-21)

**Directed repair; qualification remains partial.** A cancelled floating-point or serial-divide
operation could return its result after its transaction ID was reused. The FPU wrapper and the
multiply/divide unit now retain ownership until the raw result drains, suppress cancelled results,
and clear ownership on a full flush because both units discard in-flight work then. Boundary
fixtures show the defect before repair, detection of restored defects, and preserved replacement,
flush-then-replacement and older-survivor completion. Strict combinational-loop structural checks,
full-core reachability and FP/MULT+OoO promotion remain open.

## OoO load cancellation lifetime (2026-09-20)

**Directed repair; broader qualification remains partial.** A queued, not-yet-granted
cancelled load could outlive scoreboard TID reuse and complete a different
instruction. A live queue/load-unit reproducer fails before repair, passes afterward,
and detects removal of retained cancellation. Controls preserve older responses,
full flush and the in-order configuration. An eight-step queue check with an
independent reference passes, its cancellation/drain cover is reached, and a
retention mutation produces a counterexample. A frozen firmware replay gets past
the original access-fault endpoint; full boot, all-FU late-result coverage, unbounded
proof and physical timing remain separate gates. No feature guard is promoted.

## OoO memory ordering (2026-09-20)

**Directed qualification only.** Same-address store-to-load forwarding and
store-to-store visibility order now have discriminating positive tests, negative
controls, an in-order control and leaf fixtures under OoO. A liveness case that
previously deadlocked completes. Cross-hart memory ownership, AMO/LR-SC ordering
against speculative stores, wider misalignment cases and timing closure for the
added comparators remain open; this is not general RVWMO conformance.

## FP/CSR lifetime and coarse dual-hart increment (2026-09-19)

**Directed and bounded qualification, not production promotion.** FP committed
mapping, writable physical zero, hart-local reclaim and commit-time CSR/AMO operand
availability have discriminating tests and directed single-hart Spike comparisons.
WFI recovery and speculative-store flush/cancel lifetime have before failures and
positive/negative component controls. A guarded integer two-hart OoO rendezvous and
LR/SC consumer profiles pass under coarse handoff. Mixed residency, broad ISA/FP and
memory-order qualification, late-ID reuse, firmware/reference completion and physical
sign-off remain open. Existing feature refusals are not removed.

## OoO issue/recovery conservation status (2026-09-19)

**Directed two-issue integer repair; broader qualification remains partial.**
A surviving older instruction no longer disappears when a younger redirect
suppresses execution. Recovery/wakeup/cancellation/flush controls and exact-binary
before/after runs cover the formerly hanging four/sixteen-iteration store/load
loops and memory-dependence test. All sixteen staged probes pass; the ILP control
is unchanged. Completion is distinct from timeout and instrument failure. No
issue-width reduction, age-order relaxation, FP/hart guard removal or full ISA,
SMT, physical-timing or unbounded-progress promotion follows. Bounded live recovery
safety, a reached cover and restored-defect counterexample are qualified at their
reduced geometry; broader fixture regressions and live-port structural synthesis
pass. Standalone strict elaboration is still unavailable. A separate branch-chain
test return-address bug is corrected and discriminates positive/negative outcomes
on both execution modes.

## Issue-order increment status (2026-09-18)

**Partial; no architectural coverage promotion.** The same-group dependency
barrier now uses dynamic lane order rather than numerical PC order. Directed
one/two-hart and two/four-port positives, checker negatives, a restored-defect
control and small live-port synthesis qualify that leaf repair. They do not
qualify full SMT/OpenSBI completion or general per-hart liveness.

## WT response-identity increment status (2026-09-18)

**Partial; no architectural coverage promotion.** A response-tag selection defect
has a scoped repair and directed 12-cycle bounded checks across three fixup
geometries, reached covers and both checker/RTL fault controls. The isolated timed
leaf flow is not qualified. Same-hart stale-load evidence is localized, but full
WT-cache ordering/coherence and multi-hart firmware completion remain open.

## Reset-time SMT increment status (2026-09-19)

**Partial; no full SMT ISA promotion.** Two-hart reset rendezvous, mixed/uncompressed
code, atomic publication and WFI handoff have directed evidence with negative
controls. Conservative quiescent switching replaces unsafe cross-hart drain; leaf
synthesis is clean. Both harts execute the frozen diagnostic firmware, but its
forced topology and stubbed FDT prevent healthy secondary initialization. Natural
source-profile HSM completion remains a separate gate, not implied by its cookie.

## Architectural resume increment status (2026-09-19)

**Partial; no full dual-hart boot promotion.** Retirement-owned resume replaces
speculative cursor snapshots for the drained SMT path, with directed/mutation and
small synthesis evidence. The natural OpenSBI profile reaches both per-hart stacks,
but a subsequent shared initialization-data visibility failure still prevents the
strict HSM/S-mode payload verdict. Counts and firmware activity are not completion.

## WT retained-copy increment status (2026-09-19)

**Partial.** Directed lowered-RTL checks and mutation controls cover same-word
freshness across normal-buffer ACK and retained fixup lifetime, including full
capacity, byte masks, checked hits and concurrent retirement. No full RVWMO,
cache/coherence, physical-timing or dual-hart firmware qualification follows.

## Directed source-profile HSM completion (2026-09-19)

**Directed profile passes; broader coverage remains partial.** The pinned natural
OpenSBI profile reaches both supervisor contexts and explicit checked completion.
AMO consumers no longer use early placeholder writeback. An opt-in compiler array-
splitting control removes the PMP simulation stop while preserving the entire
retained architectural prefix and all assertions. NAPOT address-match proofs and
negative controls pass; no permissions, firmware barriers or warning waivers change.
This is not general PMP/SMT/RVWMO/FP/OoO, Linux, liveness or physical qualification.
The rename elaboration defect is now corrected and its existing12-step BMC passes;
fetch-IQ's assertion/witness failure remains open. OoO result/drop ownership has
separate directed controls and live-port synthesis, not full-core qualification.
SMT2 boot remains OoOEn=0; it does not promote hart/FP namespaces or imply balanced
service while both harts are runnable.

## Shared-core SMT measurement refinement (2026-09-19)

**Measurement qualified within its directed scope; no ISA or Linux promotion.**
Both role orders and both encodings check fixed compute/memory work with same-hart
solo controls, last-publisher completion and observer equivalence. Reporter polling
is no longer mistaken for productive sibling work. Core-time, selected residency,
accepted-work claims and load RTT are kept distinct; outstanding requests are measured
at the ROI boundary. Ratios below one do not justify a throughput gain. Software PMU
hint ownership, mixed-hart OoO arbitration, broader memory service and physical PPA
remain unqualified; the prior HSM profile stays the boot anchor.

## SMT hardware performance counter status (2026-09-19)

**Conformance gap found by directed measurement, then repaired and re-measured.**
mhpmeventN/mhpmcounterN and the Sscofpmf OF/LCOFI state were shared between SMT harts
where the ISA requires per-hart CSRs; each hart observed the other's selector write
while the architecturally banked mscratch control behaved correctly. They are now
banked per hart and the overflow report is routed to the owning hart only. The same
probe carries both polarities, so the pre-repair signature is the post-repair failing
control. Zicntr mcycle/minstret were already banked, though mcycle measures elapsed
cycles rather than per-hart service. Counting is per-hart too, not just the
selector: with both harts counting load accesses over very different quotas across many
handoffs, each counter matched its own hart's work exactly. A separate RV32 user-mode
high-word read defect was repaired by inspection. Cross-switch attribution is also
measured clean: with one hart taking cache misses and the other issuing no memory
access at all, the idle-memory hart's miss counter stays exactly zero, consistent with
both miss events pulsing at initiation rather than refill. Still unqualified: SBI PMU
mapping and counter save/restore, so scheduling-hint exposure to firmware or Linux
remains blocked, and the RV32 high-word read fix has no directed test.

## P0–P2 continuation status

**Partial; no architectural coverage promotion.** The source maps now record a
leaf-tested prediction-checkpoint desync lifetime repair. Full predictor membership,
OoO checkpoint/committed-state recovery, LSQ capacity, nonblocking-cache ordering
and coherence remain open. Reproduced comparator blind spots withdraw the later
warm-overlap architectural-preservation claim; they do not prove that the changed
RTL corrupted its workloads. Earlier independent source/trace-bound tests and
formal results keep their scope. Full SMT2/OpenSBI, platform and physical gates
remain unqualified. Concurrent-fill accounting and blocked-install safety now
have directed positive/fault-control evidence and small synthesis checks, but
that does not establish complete cache response ordering, coherence or atomics.

Read-response ownership, held-AR arbitration and write/atomic B/R lifetime are now
leaf-repaired with reproduced pre-change failures, and the sequential leaf
regression is restored after correcting a stale fill-id oracle. The cache stack
simulates across a register slice, and server-prefetch response ownership is
repaired. Coverage effects are confined to memory-side response handling: no ISA
chapter status changes, and coherence, inclusive invalidation, atomics semantics,
prefetch effectiveness, production geometry and physical closure remain open.

Invalidation-source ownership is repaired, and on the OoO side rename checkpoints now
retire at commit and LSQ admission uses group credits, each with a fault control that
reproduces the original defect. These are leaf/fixture results: OoO remains
config-gated with the hart and floating-point legality assertions in force, so no
ISA-chapter coverage changes. Committed-map recovery, enabled memdep feedback,
per-hart namespaces and the FP register class stay open.

## Instruction-supply review status (2026-09-15)

**Partial / not SMT2-qualified.** A sparse-packet dual-issue ordering defect is
reproduced and repaired, with independent leaf scoreboarding and generic
synthesis screening. No physical-area, frequency or throughput improvement is
qualified. Earlier live-fetch formal passes included impossible hart bounds;
assertions and reachable covers are being re-established. A same-cycle response/expected-PC repair also makes fresh single-worker
compressed and uncompressed checked-work pass; two-worker controls still
lack a verdict without explicit activation. A further redirect-chain witness
passes after a current-transaction completion repair, full-core synthesis is
clean, and bounded realigner assertions/covers pass in a reduced aligned-input
envelope. Typed retirement/operand checking now validates the explicitly
activated RVI and mixed C/I integer workloads after restart-boundary,
redirect-ownership and split-target acceptance repairs. Matching observer
controls and an injected-error checker control are retained; a cookie PASS
alone had hidden an intermediate instruction loss. A later host-runtime
memory corruption was isolated and corrected in a private runtime; matched
full-workload and reference-trace revalidation passes on that runtime.
Circular IQ simplification subsequently passes expanded independent acceptance/
metadata leaf controls, long no-flush runs, matched generic synthesis and fresh
corrected-runtime dual-hart integer revalidation. Independent IQ twelve-frame
bounded safety is retained as historical evidence. Additional asserted storage
invariants subsequently enable binary-state temporal induction at length two,
and all twelve cover predicates are reached within 28 steps with negative
controls. This closes unbounded ordering safety only in the reduced four-slot,
two-hart, two-issue, 32-bit ASIC/non-hypervisor formal envelope; wider/FPGA/RVH
and full-pipeline proofs remain separate. Physical qualification lacks technology
inputs. No complete base ISA, C-extension, natural-firmware or SMT coverage
status is promoted.

Isolated executable-data cacheability controls show correct table values and
real cached fills/hits in a short witness, and larger checked workloads pass.
The scan/control performance regresses despite warm-hit improvement. Production
cacheability is unchanged; no broader memory, ISA or physical qualification is
inferred from these diagnostics. Checked pointer-locality controls subsequently
pass with fixed load counts and negative controls, but show no measured cycle
gain between cacheability policies. Validated instruction-miss tracing then
identifies repeated killed wrong-path refills. Predictor lookup/corrector
semantics are now repaired and retained after independent leaf/negative checks,
a selector contract proof, SMT2 integer revalidation, broader stream8 controls
and synthesis smoke. Mapped timing/power, full FPGA/provider coverage, natural
firmware and full ISA qualification remain open. No architectural or physical
coverage status is promoted solely from these microarchitectural checks.

The subsequent invalidation-leaf repair rejects partial-target admission and
preserves a new command when a sole old entry departs. Directed/random leaf
checks and local eight-step formal checks pass; no full coherence, RVWMO or SMT
coverage status is promoted. The hub's held AR/AW owner/ID reservation and phantom-read credit are subsequently
repaired with directed and eight-step local checks. Invalidation retention,
visibility and selected-source qualification remain open; no full memory-model
or multicore coverage status follows. Bounded warm-fetch trace analysis also
confirms the existing two-cycle supply interval; it does not qualify a new
pipeline or provide missing IQ/backend stall observations.

Depth-two L2 MSHR sizing is subsequently promoted only in the named SMT2 and
stream8 packages after production-shaped leaf checks, control-occupancy induction
and matched full-model regressions preserve prior results. This is an internal
area/resource-sizing change, not a new ISA, coherence, physical or full-platform
coverage status. Other configurations and the generic MSHR capability are unchanged.

The broad RTL review repairs the OoO IQ readiness/capacity leaf, generic MSHR
merge lifetime, selected inclusive acknowledgments and latent TAGE decay period.
Focused formal and matched protected-profile tests do not close full OoO/L3/
nonblocking coverage: accepted-store self-block is reproduced in live dispatch,
and further rename/LSQ/recovery/hart/FP/retirement contracts remain open. Source
capability labels are not release evidence; see the upgrade-sequence audit map.

## Status legend and derivation

| Status | Derivation (from the two source maps) |
|---|---|
| `Implemented & tested` | RTL implements it (`implemented`/`config`) **and** a suite exercises it. |
| `Implemented (limited test)` | RTL implements it, but coverage is indirect/randomized/config-only. |
| `Partial` | Subset only, hint-only (NOP), or incomplete extension. |
| `Not implemented` | Absent from all shipped configs. |
| `N/A` | Non-normative or microarchitectural (no ISA behavior to certify). |

**Config caveat**: many rows are per-target. A status reflects the *maximal* capability across shipped
configs; a specific build may have less. Use the source maps + the target's profile to confirm.

---

## Non-ISA APU transport

**N/A for RISC-V ISA coverage; partial subsystem implementation.** Transport,
AXI-Lite control, checked read/write DMA, SRAM SG snapshots, mapping/command
storage, used-ring and mailbox memory integration have directed component
evidence. Optional testharness decode, firmware-RAM fills and CVA6 fetch/cookie
runs establish bring-up, not a protected service. Native arithmetic/control and
local-word output are prototypes, not a hardware graphics pipeline. Review adds
passing adversarial source-retention, decode/privilege and read-error-drain tests.
Native/compositor synthesis screens and the CVA6 cookie were revalidated;
existing core range and upstream SRAM warnings remain. This does not change
the subsystem's partial status. Firmware-RAM write follow-through adds tested
full rejected-burst draining, lane-strobe protection, malformed-WLAST quarantine
and reset recovery; enabled/disabled RAM retention is screened separately from
mapping-table validity. The separate control bridge's burst/error gaps remain.

Production source/RAM protection, full-address/write-bus safety, hardware table
initialization and mapping/program lifecycle, combined memory/exec, compiler
parity, cache coherence and real S-mode/OpenSBI/Linux operation remain open.
Optional BIOS service loading/health is specified, not implemented; service-ready
is not Linux boot confirmation. No unchanged-driver GLES2, combined-copy/context
isolation, full advertised conformance, formal safety/liveness, full SoC
coexistence or physical qualification follows. Disabled and generic synthesis
results are per-fixture only. No architectural coverage status below is promoted.

## Non-ISA L2 replacement experiment

**N/A for ISA certification; bounded leaf diagnostics only.** Default-off
round-robin metadata has local functional and generic-synthesis evidence,
including a workload regression against legacy replacement. Bypass response
holding was reproduced failing and repaired; local/remote leaf checks now pass,
including synthetic ATOP response ordering plus leaf ADD/SWAP/CAS.W and LR/SC
arithmetic/reservation (`+amo-arith`).
Independent replacement-policy checks and small RR-off **mapped** equivalence fixtures
now pass, with negative controls; `memory_collect` is the larger-geometry path
(4 KiB/16 KiB). Neither certifies ISA correctness.
Concurrency, production-geometry mapped equivalence, candidate-on SMT pairing
and physical qualification remain open; no RVWMO, PMA or CBO status is promoted
by these microarchitectural tests. Isolated stream8 RR-on checked-work
(`iso-stream8-rr1`) is a functional envelope, not promotion. Isolated SMT2 RR-on checked-work livelocks in verify (I=2 fetch, 2M cy).
Cluster AMOCAS and SMT cookie soaks remain the named-package controls.

## Part I — Unprivileged Architecture

| Chapter / feature | Status |
|---|---|
| Base RV32I / RV64I | Implemented & tested |
| Address space & memory (1.4) | Implemented & tested |
| Exceptions / traps / interrupts (1.6) | Implemented & tested |
| RVWMO memory model (3.1) | Implemented (limited test; single-hart directed in `spec-deep-tests`) |
| Ztso total store ordering (3.2) | Not implemented |
| Zifencei — FENCE.I (4.1) | Implemented & tested |
| Zicsr — CSR instructions | Implemented & tested |
| Zicntr / Zihpm — counters | Implemented (limited test) |
| M / Zmmul — multiply/divide | Implemented & tested |
| Zicond — conditional zero | Partial |
| Ziccif — fetch atomicity (4.9) | Implemented (limited test) |
| Ziccid — I/D coherence (4.10) | Implemented & tested |
| Zicclsm — misaligned access (4.14) | Partial |
| Zic64b — 64-byte blocks (4.15) | Implemented (limited test) |
| Control-Flow Integrity — Zicfilp/Zicfiss (4.17) | Not implemented |
| Zihintntl — non-temporal hints (4.18) | Partial |
| Zihintpause (4.19) | Implemented (config; limited test) |
| Cache-Management Ops — Zicbom/Zicboz/Zicbop (4.20) | Zicbom partial; **Zicboz full-line multi-beat (U7ᶜ)**; Zicbop HINT |
| A — atomics (5.1) | Implemented & tested |
| Zalrsc — LR/SC (5.2) | Implemented & tested |
| Zawrs — wait-on-reservation (5.5) | Partial (config; WRS→WFI path) |
| Zacas — compare-and-swap (5.9) | Implemented (AMOCAS.W/D/Q config-gated) |
| Other Za* (Za128rs/Za64rs/Zabha/Zaamo/Zalasr) | Partial |
| F / D — floating point (ch6) | Implemented & tested |
| Q — quad float | Not implemented |
| Zfh — half float | Partial |
| C — compressed (ch7) | Implemented & tested |
| Zcmt — table jump | Implemented (limited test) |
| Zcb / Zcmp | Partial |
| Zba / Zbb / Zbs — bit-manipulation (ch8) | Implemented (limited test) |
| Zbc / Zbk* — carry-less / crypto bitmanip | Partial |
| V / Zve* — vector (ch9) | Partial (Ara attach live-lintable; DTS+directed tests; full cosim open) |
| Packed SIMD (ch10) | Not implemented |
| Zkn — scalar crypto / AES (ch11) | Partial |
| Zvk* — vector crypto | Not implemented |
| Matrix (ch12) | Not implemented |

---

## Part II — Privileged Architecture

| Chapter / feature | Status |
|---|---|
| Privilege levels M / S / U (ch1) | Implemented & tested |
| Control & Status Registers (ch2) | Implemented & tested |
| Reset (3.4) | Implemented (limited test) |
| Non-Maskable Interrupts (3.5) | Partial |
| Physical Memory Attributes — PMA (3.6) | Implemented & tested |
| Physical Memory Protection — PMP (3.7) | Implemented & tested |
| Sv32 paging (4.3) | Implemented & tested |
| Sv39 paging (4.4) | Implemented & tested |
| Sv48 paging (4.5) | Implemented (limited test) |
| Sv57 paging (4.6) | Not implemented |
| Supervisor instructions — SFENCE.VMA (4.1-4.2) | Implemented & tested |
| Hypervisor H extension (ch5) | Partial |
| Smepmp — PMP enhancements (6.3) | Implemented & tested |
| Smstateen (6.1) | Implemented (limited test) |
| Smrnmi (6.5) | Partial |
| Smctr / priv-CFI (6.8, 6.9) | Not implemented |
| Svnapot (7.1) | Implemented (config; limited test) |
| Svpbmt (7.2) | Partial (config; PTE/PBMTE; LSU PMA TBD) |
| Svadu / Svinval (7.3–7.4) | Partial / not implemented |
| Sstc — supervisor timer (8.8) | Implemented (config; limited test) |
| Sscofpmf (8.9) | Implemented (config; limited test) |
| Sh — hypervisor extensions (ch9) | Partial |
| Privileged listings / rationale (ch10, appA) | N/A |

---

## Part III — Profiles

Profiles are checklists of mandated extensions; a target satisfies one only if its config enables every
required feature above. Status is therefore per-target.

| Profile | Status |
|---|---|
| RVI20 | Implemented & tested (base targets) |
| RVA20 | Partial (config-dependent) |
| RVA22 | Partial (config-dependent) |
| RVA23 | Not implemented (requires V + newer Ss*/Sm*) |
| RVB23 | Not implemented (requires V + bitmanip mandates) |

---

## Microarchitecture (no normative chapter — certified by behavior, not conformance)

| Feature | Status |
|---|---|
| Branch prediction (BHT / PH_BHT / BTB / RAS) | Implemented & tested |
| Speculative execution (in-order, precise traps) | Implemented & tested |
| L1 caches (I$ + D$) | Implemented & tested |
| L2 / L3 cache | Not implemented |
| Multi-threading (SMT) | Partial (U6.1 SMT2 config; dual-hart Linux lab open) |
| Branch prediction fabric (U1 TAGE/GSHARE/…) | Implemented (config; limited test) |
| Decoupled front-end (U2 FTQ/FDIP/loopbuf) | Implemented (config; limited test) |
| Multi-issue width 2–8 (superscalar) | Implemented (config; dual-issue tested) |
| Slice-OoO (U4) | Implemented (off by default) |
| Full OoO (U5) | Implemented (config; gated; formal scaffolds) |
| L2 cache (U6.0 SoC AXI) | Implemented (config; off by default) |
| SMT / multi-core (U6.1–U6.2) | U6.1 implemented (fine); U6.2 hub/SF/inv for `NrCores` 1–8 (default 1); dual-hart Linux lab open |
| Multi-core | Partial (parameterized 2–8; N=1 identity; stream plane suite) |
| Hypervisor (RVH) | U9.0–U9.2: vstimecmp/STCE/VSTIP/htimedelta/guest TIME; VS litmus; G-stage PTW; PLIC 16-ctx; HFENCE/HLV |
| AVX-like / server math | CBO full-line + RVB + server package; `_v` + Ara attach live-lintable |
| RVV / Ara (U10ᵇ) | Partial: live Ara lint + purpose guide + `v` DTS + directed tests; SBI/cosim open |
| CVXIF coprocessor interface | Implemented & tested (mutex with RVV accelerator) |
| AI workload policy codec (microarchitecture) | Partial: standalone control/format-aware benefit RTL, full 16-bit `m/n/k` retention, `(m+n)*rowbytes(active_k) >= read_bytes` benefit guard, production gates off, native-trace replay and independently checked scheduling model; on/off generic synthesis and bounded safety/reachability. First consumer is an observable island PMU wired into `g6lc_ai_island_top` with metadata/flush/PMU and format-known gating, now exercised by `ai-island-dma` and `ai-island-policy-walk`. First safe traversal consumer added: `policy.prefetch_depth` drives `g6lc_ai_gemm_seq.ar_max_i` (clamped to `MaxAROut`) so the GEMM can cap its AXI outstanding AR count per policy; gated by `AiCfg.PolicyCodecEn` and off by default, preserving the dense numerical fallback. Tile/bank/tail proof, STA and measured array MAC/s are still open; I3 before I2 unchanged. |
| V/A-Turbo recipe selector + exact resident-B consumer | Partial: selection arithmetic corrected and one EXACT execution consumer verified. Corrections: upward RNE ceilings (E4M3 128907), separate toward-zero truncation bound, recipe 26 analytically unavailable, an invalid/overflow sentinel a waiver cannot override, upward-rounded eps*kappa, and a new relative-domain prerequisite for REL. Sample validation is empirical only: INT8 RTL-matched 312,489 ppm (level 13), INT4 and 2-bit truncation exceed 100% and are refused, FP16/FP8 are unqualified because those tiles leave the normal conversion domain. First consumers: `ReuseBEn` and its mirror `ReuseAEn`, two INDEPENDENT keys of recipe 16 (ptr_b/n/k/ldb and ptr_a/m/k/lda, each with numfmt and its own epoch), published only after success, refused on error/invalidation/wrapped range/operand-C overlap, with sticky PMU hits. Both resident drives operand read beats to ZERO (only C writes remain): INT8 189 -> 139 cycles (1.359x) and FP32 669 -> 523 (1.279x) on ONE engine, matching what resident B alone needed four contended engines to reach, for +184 cells (+2.44%) and +22 FF with zero latches -- 14.7x return per %area against 0.8x for 8 -> 16 lanes and 0.0x for 16 -> 32. Measured eng={1,2,4}: warm reuse 1.12x-1.18x at one engine rising to 1.35x-1.37x at four, because the beats it removes are the contended resource; concurrency then improves from 52-61% to 61-73% of ideal 4x, so the two levers compose to 2.82x-3.30x from serial-cold to concurrent-warm. Operand read beats exactly halved at m=n, cold prime charged separately, 21 directed safety cases passing, a VA_TURBO=0 control showing no change, and a real signed-data harness bug caught before it could flatter the result. Also fixes an operand byte-bank alias that all-ones fixtures had hidden. Isolated GEMM synthesis 7,526 -> 7,631 cells, 62 -> 74 sequential, zero latches; the full `--ai` core synth gate fails in untouched core files. Opportunistic mixed streams give throughput linear in hit rate (INT8 +3.4%/+7.0%/+11.0%/+13.0% at 2/4/6/7 hits of 8, matching `1/(1-0.132h)`), so the 1.36x headline requires both ~100% hits and contention. Intra-engine lane grouping is REFUTED: one element is written per last reduction step, so the engine is retire-bound exactly where lanes are idle, and INT8 k=16 at 16 versus 32 lanes is byte-identical; grouping would be a C-side widening, not free use of idle lanes. Accuracy fitting is now complete across every format including native FP32 (per_window site, exact-rational reference, eps 1 ppm / bound 10 ppm / measured 0.0672 ppm, level 1), with FP16 at level 6, BF16 9, INT8 12, FP8 13/14 and INT4 refused with a stated reason. FP32 qualifies Frobenius-matched only: the per-element bound (962 ppm) was refused by a Q8.8 field saturating at 255.996, now widened to 24 bits. Two corrections landed: the accumulation term no longer multiplies by the site count (a 15x double-count), and the FP_DOT_MAXW alignment drop is now a checked invariant (worst case 562 of 640) rather than an unverified assumption. Lossless narrowing (1/3/17) is no longer integer-gated, which gives bit-preserving FP32 its first exact traffic lever beyond residency: 17 strictly-narrower pairs, `EXACT`/eps=0 for INT8->INT4 (bit-identical) and 1 ppm accumulation epsilon where a float accumulator regroups, measured 0.000-5.803 ppm against approximate twins at 977-265,625 ppm for the identical traffic saving, +617 selector cells (+15.4%, 0 sequential, 0 latches) for 11.2x return per %area. Still selector-only: no consumer mask bit, no `lossless_proven` producer, no paired GEMM run. Approximate consumers, runtime ABI, PMU/MMIO readback, STA and model-quality evidence remain open. |
| AI per-group topology subcode (microarchitecture) | Partial: the only live policy consumer (AR cap) was measured harmful-or-neutral and removed, so policy steering is now throughput-neutral by construction; the measured positive return is format-driven lane grouping (encoded, no consumer) worth up to +320% at 6.30x area versus 4.00x for cluster replication, with no STA for any width; gated advisory RTL and actual steering-output equivalence pass five parameter profiles; optional exact-result cache verifies one-cycle hits versus 32-cycle misses, epoch invalidation and bounded cache-control reachability; bounded eight-candidate search with native costs and explicit evaluation overhead. Enabled/disabled generic synthesis and fixed-fixture bounded control proof pass. Named synthetic tile fixtures do not improve over the existing allocator; feedback explicitly separates correctness PASS from performance NOT_QUALIFIED. Real-model calibration, live PE consumer, physical timing/DFT and measured MAC/s remain open; production default off. |
| Captured-model policy calibration | Partial: real pretrained dense-LM CPU execution captured with immutable source/weight hashes and native formats; ordered host motif templates and paired-evidence rejection windows tested, with limited held-out structural transfer and zero admitted actual timing claims; disjoint-model offline tuning, exact tile accounting and sampled controller-RTL cost replay pass. No net speedup qualified; 6x target excluded by current fixed-service assumptions. Diffusion/MoE captures, numerical DMA/PE replay and physical MAC/s remain open. |
| AI scalar floating arithmetic (not ISA F/D) | Partial: exact widening plus separate RNE FP32 multiply/add primitive verified with flags, backpressure and cancellation; measured scalar latency/II, generic synthesis, widening properties and bounded control checks only (not induction). Production IslandFpEn off; no floating GEMM loaders/array/grant integration or new ISA F/D conformance evidence. |
|| AI floating block-floating dot product (not ISA F/D) | Lanes=4 combinational `g6lc_ai_pe_dot_float` and pipelined `g6lc_ai_pe_dot_float_pipe` (Lanes=4/8/256) verify: per-lane decode, product, block-exponent alignment, 640-bit balanced reduction and RNE FP32 conversion; 5,018/5,028 Verilator checks pass for FP8/FP16/BF16/FP32. Pipelined dot now registers stage-2 product/metadata and a stage-3 block-exp/flag register, so back-to-back starts with different `numfmt`/data keep data and metadata aligned; `pe_dot_float_pipe_main.cpp` stresses this plus half/alt-valid masks and 1-ULP BFP-vs-float rounding tolerance. `run-gemm-backend.sh` PASSES for nch={1,2,4,8} and `dpf=0,1` across INT4/INT8/FP8/FP16/BF16/FP32. Yosys `read_slang` + `synth -noabc -top g6lc_ai_pe_dot_float -flatten` and the same for `g6lc_ai_pe_dot_float_pipe` (Lanes=4) both report zero errors/warnings and zero CHECK problems. `fp_dot_product` now uses a 24×24 mantissa product (down from 32×32), reducing the pipelined dot pipe from ~128k to ~115k generic cells. Lanes=256 is an elaboration/lint gate. Live grant/PE masks remain INT8/INT4 only; not an ISA F/D extension. |
| AI native-format descriptor/host interop | Partial: descriptor-v2 k-major packing and B3 native-byte functional evaluation verified; actual RTL engine mode legality, effective INT4 alias grants/handoff and rejection tested. Live grant/PE masks remain 3 (INT8/INT4 only); software fixtures are not hardware capabilities or throughput. Invalid C/completion destinations, device overlays and sticky completion errors covered in software; this increment adds no fused requantization or non-GEMM arithmetic. |
| Custom `Xg6lcai` island (I3-lite) | Partial: CAP/GEMM/PMU directed (`ai-matrix-veri`); wrap AR/AW=8; S4 `g6lc_axi_lrsc` eight regular AR/AW; CLASS1 {1,2,4,8} Variane PASS; S4 parks hart 1 (`ai-dt`/`ai-d{1,2,4,8}`); dual-core stripe ELF on N>=2; all-N occupancy `ai-d8`/`ai-sc8`; exclusive `amoadd.d` `ai-dt`/`ai-d1`/`ai-d8`; CLI `test --ai` / `diag run ai` / `test --ai-remote`; class-1 nameplate not measured; QEMU higher-level only |
| RVFI trace / debug triggers / PMU | Implemented & tested |

---

## Headline

AI continuation results do not promote normative ISA coverage or whole-SoC
readiness: policy/scalar gates remain off in production, floating GEMM integration
is absent, and prior full-core synthesis/branding blockers, DFT/test-mode audit,
PDK STA, physical area/power and full compliance remain open. Package, standalone
RTL and historical SoC results retain their separate scopes.

Fully covered (implemented **and** tested): the RV64GC / RV32 base (I/M/A/F/D/C), CSRs and M/S/U
privilege, FENCE.I and I/D coherence, PMA, PMP (with Smepmp), Sv32/Sv39 paging, and the core
microarchitecture (branch prediction, precise speculation, L1 caches, CVXIF, observability).

Implemented (config / limited test): Sstc, Sscofpmf, Zihintpause, Svnapot; partial Zawrs / Zicboz /
Zicbop / Svpbmt; U1–U4 micro-arch, multi-issue width, U6.0 L2 (off by default).

Not implemented (and therefore untested by design): Ztso, CFI, Packed SIMD, vector crypto
(`zvk*`), Matrix, Sv57, Smctr/priv-CFI, Svinval. **Partial:**
**Zacas** AMOCAS.W/D/Q (`RVZacas`, `zacas-policy` / `mc-mini-veri`); **RVV/V** via Ara attach
(live lint + DTS + directed `ara-vector-path`; OpenSBI VRF + cosim open); dual-hart Linux lab;
L2/L3/multi-core hub as config-gated SoC work. See `AGENTS-specs-to-impl.md` for authoritative
RTL status; sub-files `agents/spec/riscv-spec-I-5.9-zacas.html` and
`agents/spec/riscv-spec-I-9-vector.html`; `architecture/` for promotion paths.
