# Storamic Transaction Origin (ST-025C2B, Component Candidate)

This is optional CPU data-origin transport, not an enabled native checkpoint
authorization provider. Production target packages still request neither
Storamic nor checkpoint activation. The native attach interlock still rejects
an unbound checkpoint request.

## Source And Lifetime

`g6lc_storamic_origin_supported` restricts capture to requested Storamic primary
and I/O roles, one hart, non-OoO, non-virtualized WT operation, no accelerator
and `COPRO_NONE`. An empty CVXIF interface is not itself an enabled writer.
The cluster prefix alone cannot distinguish scalar requests from an attached
accelerator sharing that upstream path. SoC multi-core/shared-master topology
still needs a separate qualification; one hart per CPU is not one cluster writer.
`load_store_unit` encodes the
effective data privilege (`ld_st_priv_lvl_i`, including MPRV effects), not the
instruction's ambient machine mode or a later live CSR value. The encoding
travels in the LSU descriptor before bypass allocation.
The existing execute-stage debug-mode signal is now passed into that capture
and explicitly supplied to the encoder. Debug-issued traffic is unknown even
when effective privilege is machine. This is issue-time qualification: a later
debug transition neither promotes a queued debug request nor retags an already
accepted firmware request at the AXI boundary.

Only ordinary scalar loads/stores acquire a tag. Other operations, unsupported
execution profiles, debug-mode issue, implicit PTW accesses and accelerator
requests are untrusted.
The core cache-port mux explicitly clears tags on unsupported/non-CPU paths.

Store staging, speculative allocation, commit and WT buffering retain the
descriptor's tag. Narrow packed control registers use the existing allocation,
head and commit events; they do not widen store-buffer data storage. Tags on
flushed slots have no validity of their own and are overwritten on slot reuse.
Read controllers capture at request grant. The WT adapter FIFO carries the tag
with its descriptor, independent of AXI address/data channel completion order.

## Encoding And Admission Boundary

Under the optional transport:

| Effective Data Origin | AXI PROT |
| --- | --- |
| Machine scalar data | `001` |
| Supervisor scalar data | `011` |
| User scalar data | `010` |
| Debug-mode issue, irrespective of privilege | `000` |
| Unknown/legacy, unsupported or virtualized | `000` |

This assigns the AXI secure/nonsecure distinction according to the proposed
Storamic trust-domain policy; it is not a universal RISC-V/AXI equivalence.
Only explicitly PMA-uncacheable ordinary data traffic retains provenance through
WT. Cache disable alone does not qualify merged RAM traffic. Cacheable traffic,
instruction fetches and AMOs do not acquire machine authority.

WUSER remains payload metadata, including converted AMO operands. Neither AWUSER
nor WUSER supplies this origin.

`PROT == 001` alone MUST NOT authorize a native command. Integration still needs
an unforgeable trusted-master route/identity, preservation through every bridge,
transaction-aligned service capture, a qualified descriptor/policy epoch, every
enabled writer, and cache/reservation/device synchronization. The service's
native authorization input is not bound to this transport yet. A default-off
post-crossbar route candidate now captures prefix/origin/policy qualification
before the existing native bridge drops PROT; its component contract and
limitations are in `storamic_checkpoint_service.md`. Its fixture tests are not
full-CPU or native-provider qualification.

## Full CPU Elaboration Diagnostic

`build-platform/workspace/build/storamic-cpu-07/` now contains a
platform-resolved frozen closure for the configured `cv64a6_imafdc_sv39`
target: 264 manifest files and 276 hashed inputs including headers/generated
wrapper. The collector uses the existing `PlatformContext`, tool-path resolver
and `writeFlatManifest`; it does not substitute a handwritten CPU source list.

`snapshot-r3` / `elab-r3` pass full genuine `cva6` hierarchy elaboration with
origin transport off and on. A wrapper-level supported-profile assertion
requires the enabled configuration to satisfy
`g6lc_storamic_origin_supported`; a deliberate unsupported-profile oracle
rejects with `STORAMIC_CPU_ELAB_UNSUPPORTED_PROFILE`. Source and helper MIT
header/tier audits pass. Earlier source snapshots remain separate.

This is local Yosys/Slang elaboration with unconnected external CPU ports,
not a boot fixture, functional privilege/provenance test, default-netlist
identity proof, full-CPU synthesis/timing/DFT pass or approved aggregate gate.
The enabled wrapper requests the existing CPU configuration bits only; it
does not instantiate a native service, create a provider or remove refusal.
Native crossbar composition, executed M/S/U traffic, cache/reservation/device
synchronization and authoritative policy/descriptors remain independent gates.

## Integration And Verification Status

The native binding is unqualified and must remain behind the existing
refusal interlock. `run_origin.py` freezes local component inputs under
`build-platform/workspace/`, records hashes and runs rejecting oracles without
contacting or cleaning a remote host.

The earlier `storamic-origin-04` component bundle records:

- Shim: 36 checks each with transport off/on and two rejecting oracles.
- Actual LSU bypass/store-unit/store-buffer queue: 52 checks, including PTW
  delay, changing effective privilege, M/S/U ordering, held requests and flush
  followed by slot reuse; its rejecting oracle fails as intended.
- Full WT data-cache component: 88 checks each off/on, plus rejecting oracles.
  This profile uses single-hart, non-OoO WT with fixup depth zero. Cache disable
  does not promote PMA-cacheable RAM to trusted I/O. Stored/read descriptors stay
  stable while the source fields change and memory admission is stalled.
- Adapter: 48 positive cases and 48 independent protection-oracle rejections
  across origin/allocate off/on, ordinary/cacheable/I/O/atomic/instruction
  classes, and all eight descriptor encodings.
- Direct-buffer formal diagnostic: depth-8 pointer/tag stability under legal
  ready/commit and ordinary-store handshakes, two retirements reachable at step
  6, and the deliberately incorrect pointer assertion rejected at step 5.
  Origin values remain unrestricted. This is local diagnostic evidence.
- All 37 tracked target packages elaborate with checkpoint/source transport
  off. This does not replace full-CPU elaboration or compliance.

The earlier timed failure was isolated at the fixture response boundary: its
field-wise grant drive did not reach the child buffer. A scalar-driven response
record fixes forwarding; assertions now check the child grant and next pointer
before the edge. No RTL retirement rule was relaxed. Grant-dependent AMO
invalidation is now a separate process in the adapter, removing its process-level
request/grant dependency without changing the request protocol.

The initial formal diagnostic's internal `anyseq` variables did not establish
reachable traffic with this frontend. Explicit top-level inputs fix the harness;
the earlier safety-only result is superseded, not promoted.

The cache compiler control splits acyclic LZC/forward-tree arrays and the packed
memory-request record; LATCH/UNOPTFLAT diagnostics remain errors. No scalar
feedback warning is waived. Early cache synthesis passes for both profiles:
1,765 / 1,798 coarse RTLIL cells, with no latches or combinational SCCs. These
are pre-technology-mapping component figures, not silicon area or timing.

Frozen sources, receipts, earlier failed attempts and proof diagnostics are
retained under `build-platform/workspace/build/storamic-origin-04/`. Full-core
default-netlist identity, CPU integration, PMU/debug, scan/ATPG, timing and power
qualification remain open.

The aggregate dry run plans 25 steps and executes none. Full CPU, compliance,
native persistence, physical fault and Linux qualification remain open.

### Debug-Issue Capture Follow-Up

`storamic-debug-12/origin-r1` passes 54 positive profiles and 55 rejecting
oracles. The profile bench exhausts all 16 privilege/virtual/debug contexts
(28 checks including supported-configuration tests). Shim off/on each pass
37 checks. The real bypass/store-unit/store-buffer queue passes 76 checks,
including an accepted debug request retained as unknown after debug exit,
and an accepted machine firmware request retaining its tag after debug entry.
The separate incorrect-debug-authority oracle rejects.

`storamic-cpu-07/snapshot-r5` / `elab-r5` repeats configured full hierarchy
elaboration off/on with the actual execute-stage-to-LSU debug binding and the
unsupported-profile oracle. This remains elaboration, not instruction/debug
entry/exit execution or native authority qualification.

### Interpreter Diagnostic Boundary

The independent RTLIL interpreter attempt
`storamic-cpu-interpreter-13/exec-r4` was interrupted without a final execution
verdict; generated-C++ attempts retain their compilation timeout receipts.
Later configured instruction execution is recorded separately below.

The test-only netlist wrapper adds default-off `IntegerDiagnostic`, matching the
existing event-driven fixture: RVF/RVD are disabled before `build_config`, while
the genuine scalar CPU, CSR, LSU, queues and WT cache remain. The runner labels
this derived profile explicitly and will not reuse a model from a different
profile or without a recorded RTLIL artifact digest. Matching source hashes
alone do not authenticate an otherwise unrecorded generated model.

`startup-int-r1` completes 40 interpreter cycles in both origin modes, including
33 post-reset cycles, with no assertion failure. Startup mode leaves overall
qualification incomplete and does not run the program completion gate. Normal
program mode still requires `done`, no failure, all five write/four read checks
and the rejecting oracle. Neither diagnostic mode nor Yosys interpretation
replaces the configured strict compiler, debug execution, native topology or
authorization-provider gates.

### Configured Instruction Matrix

`storamic-cpu-interpreter-13/configured-execution-r1` collects six passing
configured-target cases: off/on at response delays 0/16, plus a rejecting
origin oracle for each enabled setting at delay 16. Every positive completes
five writes and four reads through the genuine `cv64a6_imafdc_sv39` CPU,
CSR/LSU/queues/WT cache path. The configured FPU is retained, not replaced by
the integer diagnostic. The program checks M, S, U and MPRV with MPP=S; it does
not test floating-point instructions or establish complete MPRV/MPP coverage.

`verif/tb/storamic/collect_cpu_execution.py` refuses incomplete, startup-only,
integer-only or partial matrices. It checks source/ROM/RTLIL/script/log hashes,
consistent source/tool/program identity, both full-profile model generation
receipts, exact software probe counts and named assertion rejection. The
altered-model oracle independently rejects a modified RTLIL copy before any
tool invocation. No archived failure is replaced by these later results.

The receipt explicitly keeps strict RTL compile, debug execution and native
qualification false. Two-state zero initialization is recorded. Actual CPU
debug entry/exit and adversarial queued mode changes remain required, alongside
the unresolved strict compiler gate, trusted topology and platform providers.
This CPU AXI latency sweep does not close native `FLASH_RSP=16`, persistence,
CPU/DMA/atomic, physical or Linux qualification.

### Extended MPRV Matrix

`storamic-cpu-schedule-14/extended-execution-r1` adds MPRV/MPP=U and
MPRV/MPP=M to the existing MPP=S case while instructions still execute in M.
Origin off/on and response delays 0/16 pass four complete programs, each with
seven writes/six reads, plus two rejecting origin oracles. The configured
CPU, including its FPU, is unchanged; only the test firmware and optional
host expectations are extended. No floating-point instructions are tested.

`g6lc_cpu_origin_program.py` preserves the original ROM byte-for-byte when
the extra mode is absent. Six generator tests independently decode the mode,
effective privilege, readback branches and failure path. Nine collector
tests retain the original five-write/four-read gate and exercise the new
exact-count, complete-matrix, host-mode and model-origin rejection checks.
Extended collection explicitly links reused CPU artifacts to the original
full-profile generation receipts, allowing only the host firmware/environment
to differ. The current default host also completes the original program.
A separate wrong-MPP=U expectation rejects specifically at the third write,
after two successful probe reads. The phase-specific observer and its
complement jointly preserve the original `!failed` assertion.

This extends supported MPP coverage, not complete privilege or debug
qualification. Real debug entry/exit, adversarial queued transitions, strict
compiler scheduling, trusted topology and genuine platform owners remain open.
The fresh strict baseline still reports 11 errors off and 12 on; the isolated
CSR experiment changes neither count, and no production RTL edit is inferred.

### Genuine M-Mode Debug Entry And Return

`storamic-cpu-debug-15/debug-execution-r1` passes six configured CPU cases:
origin off/on at response delays 0/16, four complete programs and two
rejecting debug-origin oracles. Each positive requires six writes/four reads,
three debug writes/two debug reads, DCSR request-cause/saved-M checks and a
DPC in the interrupted firmware range. The configured FPU remains present;
no floating-point instructions are tested.

The separate debug wrapper drives the real external request input. It keeps
the target's debug base/halt/exception addresses at 0/0x800/0x808. The handler
uses ordinary CSR instructions and DRET, not forced state. Debug-origin data
must be unknown (`000`), even though debug executes with M privilege; after
DRET, M data must again be `001` when transport is enabled. The oracle
deliberately expects trusted M at the first debug write and must reject at
`debug_origin_observer`.

The baseline showed real debug mode and a saved DPC, but fetched the normal
trap vector. `arch_src_sel` incorrectly prioritized the exception indication
over the debug redirect accompanying that same transition. Debug now has
highest redirect priority. A frozen-baseline rejection, unrestricted Boolean
selector proof, updated formal safety/induction, nine reachable covers and
the real CPU round trip support the correction. Non-debug priorities retain
their previous behavior; no input assumption or scheduling waiver is added.

`g6lc_collect_cpu_debug_execution.py` requires the complete six-case matrix,
exact counters, both ROMs, source/tool/model/script identities, matching CPU
generation receipts and the priority proof. A completed model-generation
stage can survive an interrupted later execution, but an incomplete program
cannot count as a positive case. The original non-debug wrapper/model
artifacts remain unchanged.

Timing/readiness note: this bug fix changes the existing combinatorial
selector priority, not its interface, state, clock or reset. Trap selection
now explicitly yields to debug; this does not establish physical path delay
or PPA closure. Existing `DebugEn` gating and all config/PMA/PMP/DTS/ISA
contracts remain unchanged. DFT/scan, SRAM boundaries and PMU interfaces gain
no state or feature. Fresh strict Verilator diagnostics still fail 11/12.
The platform lint/synthesis invocation lacks a final verdict and is not
promoted. Shared-cleanup aggregate stages were not run.

This is M-mode external-debug round-trip evidence only, not broader debug,
queued-transition, native authority, physical, four-state reset or Linux
qualification. Native checkpoint admission remains disabled.

### Supervisor/User Debug Entry And Return

`storamic-cpu-debug-privilege-16/collected-s-r1` and `collected-u-r1` add two
independently collected six-case matrices. They retain the configured CPU,
LSU, queues, cache and FPU, reusing only exact source/tool/profile/model
identities. Each profile covers origin off/on and response delays 0/16,
four complete six-write/four-read programs and two rejecting debug-origin
oracles. The two-state initialization boundary remains explicit.

The firmware's test-only PMP setup allows its ROM/probe accesses; MRET with
MPP=S/U enters the actual lower privilege at `0x80000180`. External debug
must save the corresponding privilege in DCSR and a DPC in
`[0x80000180,0x80000200)`. Debug loads/stores remain unknown (`000`).
Architectural DPC update and DRET resume at `0x80000100`; resumed traffic
must identify S (`011`) or U (`010`) when transport is enabled.

`EntryPrivilege` parameterizes only the verification host. Generator default
M ROMs remain byte-identical and the new host's M regression passes. The
collector accepts legacy M receipts, but S/U require matching explicit
receipt metadata and execution-script parameters. Runner artifact hashes
are checked as well as source, tool, model, ROM, scripts and counters.
One profile cannot be relabeled as another by editing only its metadata.

The initial 2,000-cycle delayed runs do not complete; 3,000-cycle retries
pass without changing firmware, models or assertions. The initial S
origin-off zero run times out; complete 1,000-cycle zero retries are used for
both profiles. All initial evidence remains preserved. These are test
budgets, not device latency or native `FLASH_RSP=16` qualification.

No production RTL, config, PMA/PMP policy, state/clock/reset, scan/PMU,
CSR/DTS/ISA capability or physical timing changes result from this extension.
Combined debug/MPRV, breakpoint/step, virtualization/SMT and adversarial
queued-mode transitions remain open; no native authority is granted.

### Queued Transactions At Debug Entry

`storamic-cpu-debug-queue-17/collected-r1` adds 20 configured CPU cases:
M AW/W/B holds at origin off/on and read delays 0/16, including six rejecting
RTL debug-origin oracles, plus S/U origin-enabled B holds at delay 16.
Fourteen positives retain all six writes/four reads, debug three/two and
two CSR checks. The test pauses the first firmware write for 192 cycles at
the selected boundary and requests genuine external debug, then completes
the handler and architectural DRET. No internal state is forced.

`tb_g6lc_storamic_cpu_debug_queue_interpreter.sv` is separate from the prior
host. It holds AW acceptance, W acceptance or B publication; it checks
valid/payload stability under AW/W backpressure, original transaction order,
issuing-context origins and resumed traffic. It does not infer origin from
live privilege. The CPU wrapper/model and previous evidence remain unchanged.

The execution script exports only read-only debug/protocol output aliases
after loading and flattening the pinned model. The instrumented netlist,
original model, source closure, runner, ROMs, scripts, tool and VCD all have
recorded identities. `g6lc_collect_cpu_debug_queue.py` accepts only the exact
instrumentation command sequence: extra connections/forcing are rejected
even if their script digest is updated.

`g6lc_cpu_debug_queue_trace.py` samples pre-edge AXI handshakes and post-edge
CPU debug-mode changes. The actual ordering is profile-dependent:

- Zero-delay M AW/W holds finish the firmware B response before debug entry.
- At read delay 16, M enters debug with firmware AW/W still held; its already
  captured origin remains normal firmware, not unknown debug.
- M/S/U B holds retain the prior firmware transaction across debug entry.

Ten crossings and four observed drain-order cases pass. This does not imply
all writes must drain before entry, or that every queue class may cross.
Named RTL wrong-debug-origin oracles reject in six cases. A separate false
live-origin trace rule rejects in all six enabled crossing cases; these are
counterfactual trace checks, not modified-RTL semantic tests.

No production RTL, configuration, clock/reset/state, timing/PPA, scan/PMU,
PMA/PMP/ISA/CSR/DTS capability or native activation changes. This evidence
does not cover debug-origin traffic pending across DRET, combined MPRV/debug,
other queue classes, virtualization/SMT, physical timing or strict compiler
qualification. Native ownership, descriptors and genuine synchronization
providers remain required.

### Debug-Issued Responses Across DRET

The independent `storamic-cpu-debug-return-18/collected-r1` matrix passes
12 complete configured-CPU programs and six named RTL debug-origin oracles.
Each M/S/U profile covers origin off/on and read delays 0/16.
`g6lc_cpu_debug_return_program.py` adds one debug store after the last
verification load/fence and before DPC update/DRET. Normal firmware images
stay unchanged; the earlier six-write debug images and gates are untouched.

`tb_g6lc_storamic_cpu_debug_return_interpreter.sv` requires seven writes/four
reads, debug four/two and two CSR checks. It checks the additional word at
offset 28 in the upper 32-bit data lane, then withholds its B response for
384 cycles without withdrawing an offered response. All existing DCSR/DPC,
data ordering, AW/W stability, unknown debug-origin and resumed-origin checks
remain active.

`g6lc_cpu_debug_return_trace.py` verifies actual mode exit lies strictly
between that debug write's W and B handshakes while its response is pending.
All 12 positives cross. The transaction's bound origin remains unknown
across return; subsequent traffic carries M/S/U origin. Six enabled trace
oracles reject the false rule that current firmware privilege relabels the
old debug transaction. These are trace predicates, not modified-RTL tests.

`g6lc_collect_cpu_debug_return.py` rejects partial/six-write programs, missing
profiles or generation records, changed artifacts, hidden forcing commands,
unrelated assertion failures and programs that finish only after draining
the response before DRET. The original pinned CPU model is unchanged; only
read-only simulation output aliases expose its actual mode. No probe feeds
stimulus, privilege or native authorization.

Seventy-six Python tests, seven platform checks, typechecking and scoped
MIT/source identities pass. No new production logic/state/clock/reset,
timing/PPA, scan/PMU, configuration, PMA/PMP/ISA/CSR/DTS capability or native
activation occurs. This is one return-direction response boundary, not
qualification of all queues, combined debug/MPRV, breakpoint/step,
virtualization/SMT, four-state reset, strict scheduling, physical or Linux
behavior. Genuine policy/writer/descriptor/synchronization owners remain
required.

## Silicon And Software Notes

No instruction, CSR, discovery capability, DTS range or Linux ABI is added.
There is no new clock, reset domain or pipeline latency. New tag state uses the
existing asynchronous-active-low reset strategy and is ordinary scan-visible
control state, with no clock gating to bypass. Existing data arrays and SRAM
macro boundaries are unchanged.

Debug exclusion adds one local control input to the narrow descriptor encoder
inside the existing configuration-constant supported-origin branch. It adds
no tag width, queue state, clock, reset, SRAM or pipeline stage. Default-off
source transport still takes its existing no-origin branch. Review covers the
real `cva6` debug signal through `ex_stage` to LSU acceptance, fail-closed
encoding and queued origin retention. Debug entry/exit execution, configured
timing, scan/ATPG and native policy revocation remain independently unqualified.

The added cones are narrow privilege/opcode qualification, tag gathering and
PMA qualification, not new data/READY feedback. Area, timing, power, scan/ATPG,
debug/PMU integration and full-core default-netlist identity still require
measurement; no physical closure or default-netlist identity is claimed.
