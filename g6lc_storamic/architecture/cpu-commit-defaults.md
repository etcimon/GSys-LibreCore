# CPU Retirement Defaults: Bounded C0 Prerequisite

Native Storamic admission remains disabled. This slice repairs combinational
assignment completeness in the existing CPU retirement stage; it does not
implement a native memory, cache, fabric or persistence provider.

## Cause And Correction

The fresh configured CPU closure reproduces four strict latch diagnostics in
the two-port `commit_stage`: port-1 write data, cross-hart/privileged scratch
flags and macro acknowledgement. In particular, a visible CASQ dual response
can suppress the normal port-1 default even when the head is halted, dropped
or invalid and the actual AMO write branch does not execute. The one-port
component is a separate control and compiles without those latch errors.

The correction defaults the complete write-data, GPR-enable and macro-ack
vectors, plus the two scratch flags, at entry to the existing combinational
process. Existing legitimate retirement branches override those defaults.
It neither changes response ownership nor grants permission to retire a
blocked head. Normal dual AMOCAS.Q retains its low/high data and destination.
No source validity, policy epoch, privilege or synchronization acknowledgement
is synthesized.

Configuration remains through `CVA6Cfg` and injected structural types. This
is a correctness fix to existing one-/two-port behavior, not an optional new
ISA feature or a reason to preserve an unsafe old default behind a new flag.

## Verification And Identity

The initial isolated candidate uses the platform-resolved full CPU exception
and scoreboard types. Its one-/two-port PGO simulations and four depth-8
safety/negative queries pass. Those results precede promotion and remain
separate from the public fixture.

Promoted-source snapshot `storamic-all-c9e274ae2823` passes seven selected
stages:

- Public one-/two-port retirement simulations and rejecting assertion oracles,
  covering ordinary payload, halt/drop and late dual-response cases.
- Nine depth-8 formal queries: safety, normal-retire/drop reachability and
  rejecting false properties for both widths, plus two-port dual-write cover.
- Generic synthesis: one port 797 cells, two ports 1231 cells; both zero
  memories, latches and SCCs.
- Policy/writer simulation, formal and synthesis regressions, and the
  dynamically discovered 37-package configuration sweep. The sweep does not
  synthesize or execute 37 CPU implementations.

All 157 packaged code/runner identities match the current tree and post-run
frozen sources. The repository Verilator compiler-PGO/unroll runtime and
repository Yosys fork are pinned. Nine generated simulators have verified
profile-use identities. Two intentionally illegal configuration models abort
before profile emission; their explicit no-profile rebuilds still reject at
the required assertions and are not counted as simulator-PGO evidence.

Original-RTL replay `storamic-commit-original-29-79184b65` uses the unchanged
public fixture and strict warning flags. It rejects at exactly four latch
errors, with source identity retained. This is a compile-rejecting regression,
not an original executable trace or simulator-PGO qualification.

The public fixture supplies minimal conforming injected types and an explicit
RV64GC reference package. The prior full-type experiment strengthens that
component check; neither substitutes for full CPU instruction qualification.

## Silicon And Software Review

- No new state, clock/reset, array, SRAM macro or clock/power domain.
- Async-active-low reset and existing test/scan seams are unchanged. No new
  scan element or clock-gate bypass is required; ATPG qualification is open.
- The change provides constant inactive defaults to existing selection cones,
  not a new stage or long arithmetic path. Generic cell counts are not mapped
  timing, power, area or MCMM closure.
- Existing retirement/RVFI/debug/PMU interfaces remain the observation points;
  no new feature/event or delayed commit pulse is introduced.
- No instruction/CSR encoding, discovery, DTS, PMP/PMA, SBI or Linux ABI change.
  Upstream attribution and licensing are retained verbatim.
- Review checklist: assignment completeness, typed configuration, directed/
  formal/synthesis parity and source/licensing identity checked. Full
  compliance, aggregate simulation, physical and system gates remain open.

## Remaining C0 Work

The older local-tool 11-off/12-on counts are historical and use a different
compiler. The pinned repository fork is version 5.008. Its first fresh strict
run stops at the latch and packed-FP mixed-assignment error limit. An isolated
representation-only FP split removes that blocker, and the defaults candidate
removes the four latches, exposing 28 unwaived scheduling diagnostics in each
origin mode. Zero earlier reported scheduling errors was not a pass.

No FP disabling, warning waiver, production vendor edit or production VLT
overlay follows from these probes. Further work must distinguish bit-level
feedback from packed-aggregate scheduling artifacts with explicit oracles.
See [completion-plan.md](completion-plan.md) and
[native-provider-inventory.md](native-provider-inventory.md).
