# CPU Load Translation Scheduling (C0, Selected Evidence)

The functional `core/load_unit.sv` now computes translation admission separately
from the request/forwarding state machine. Translation admission consumes the
current load and buffer availability; it does not consume the store-hazard
decision. That decision observes the load's physical address, which itself uses
translation admission. Putting both decisions in one combinational process
created a conservative simulator scheduling cycle.

The refactor moves `accept_req` to a shared combinational wire and places the
existing translation assignments in `translation_control`. It preserves IDLE,
SEND_TAG, WAIT_GNT and WAIT_TRANSLATION behavior and the cancellation override.
It does not add flush gating, a register, an interface, a clock/reset, a request
delay or a new configuration requirement. The request FSM and PA capture
register retain their previous semantics.

## Evidence And Its Limits

Receipts are under `build-platform/workspace/build/storamic-cpu-31/`.

| Receipt | Result | Scope |
| --- | --- | --- |
| `storamic-cpu31-963b087c-result` | Original/candidate control projection equivalent; deliberately hazard-gated translation rejected | Two-state combinational proof, all 16 state encodings, all control outputs/next state and all exposed inputs/configuration flags, without assumptions |
| Same receipt | Strict full-core origin off/on diagnostics: 28 → 27 UNOPTFLAT errors in each mode; only `load_pa_now_v` disappears; no new named error | Full configured FP retained, explicit FP representation control, vendor suppression removed in isolated copies; pinned earlier PGO compiler, not qualification of the newer compiler submodule |
| `storamic-cpu31-bf72821e-result` | Original module rejects at the coupled PA/hazard test; candidate passes 31 scenarios and four negative oracles in four PGO models | Actual load unit/bypass, one/four load slots, in-order/OoO/coherent profiles; about 40 seconds |
| Same receipt | Baseline/candidate synthesis: 1,683 → 1,681 generic cells, both 139 FF cells, zero memories/latches/SCCs | Live-port RV64, MMU, OoO, four-slot reference fixture; no technology mapping or STA claim |
| `registered-result`, run `storamic-all-ea64371c9fed` | `load-translation` and `load-translation-synth` pass in about 53 seconds | Promoted raw source snapshot, 119 source hashes, four verified simulator profile-use builds, 31 scenarios, four simulation oracles and a real-loop lint canary |

The projection uses the actual original/candidate control blocks. Transfer-size
extraction and the prior load's cancellation-mask lookup are shared arbitrary
cut values; their implementations are unchanged and are not proved by this
projection. The counterexample changes translation admission to depend on the
page-offset hazard, demonstrating that the comparison observes this contract.
The promoted source matches the tested candidate after newline normalization;
the registered run independently records and verifies the promoted raw bytes.

The new default-off `TRANSLATION_FEEDBACK` fixture parameter and scenario 100
close the PA → store-hazard observation path using ordinary requests. They check
translation while the hazard blocks dispatch, retained PA when the shared
translation port changes owner, STQ forwarding, WAIT_GNT miss/hit capture and
cancellation. Existing scenarios cover response overlap, precise misalignment,
flush, slot reuse and foreign PTW faults.

The standalone fixture compiles only its eight actual dependencies. Other
modules in the shared review test file and unrelated full-CPU DPI declarations
are outside this leaf. LZC node splitting makes its combinational tree visible
to the simulator scheduler; it does not suppress a warning. The exact rule is
also applied to a real self-loop canary, which must produce UNOPTFLAT. LATCH,
UNOPTFLAT and missing-pin diagnostics remain fatal.

The registered profile omits the other 68 registered stages. Source-post hashes
match, and all 104 pulled model/PGO artifacts covered by the four identity
records match their hashes. The host suite passes 122 tests, including independent
stage preparation and shared configuration-package inventory checks.

## Reproduction

Use the existing `storamic-remote-leaf` suite with
`STORAMIC_STAGES=load-translation,load-translation-synth`, a validated runtime
record/header hash and the configured remote gateway. The entry point is
`verif/tb/storamic/run-remote.sh`; `run_remote.py --prepare-only` can inspect the
frozen closure without launching work. Synthesis can run independently without
a C++ runtime. Runtime identity and PGO requirements are unchanged.

The source-derived fixture, representation control and live-port synthesis
wrapper are hashed in the stage manifest. Failed preparation, missing tools,
timeouts, unexpected negative outcomes and identity mismatches do not qualify
the stage. Earlier projection/fixture/linkage failures remain in their original
receipts; they are not RTL failures or successful test coverage.

## Integration And Timing Review

This is a representation correction, with no intended architectural behavior
change. Existing `CVA6Cfg` conditions remain intact. No new state or memory means
no new scan, SRAM, clock-gating, CDC or reset boundary; existing trace/debug/PMU
interfaces remain applicable. There is no ISA, CSR, encoding, DTS, capacity or
native authority change, and no new feature requiring a PMU event.

The synthesis comparison removes one generic mux and one OR cell while retaining
the FF count. This is an early structural check, not a frequency, area, power or
physical timing result. Combinational simulation settling improves at the
identified dependency; service latency and cache handshakes are unchanged.

C0 remains open with 27 diagnostics in this captured compiler/representation
profile. The aggregate/compliance, current compiler qualification, C1, native
provider/drain/cache/fabric, physical media and Linux gates remain separate.
Native checkpoint admission stays disabled.

## Later Diagnostic Refinement

CPU32 (`storamic-cpu32-5301d354-result`) freezes the current CPU closure and
changes only isolated Verilator representation controls. Off/on counts are
27 with the prior control, 21 after splitting tree nodes, 12 after splitting
packed ready chains, and 10 after splitting two FP status structs. There are no
new named UNOPTFLAT errors or other fatal classes. Seven separate real-loop
canaries still reject under the complete control set. Raw and diagnostic
source-post hashes match.

This supports the predicted aggregate-granularity explanation for 17 reported
cycles. These additional controls are not promoted or functionally qualified.
One-bit split notices remain explicit; no warning is suppressed. The ten
remaining dependency reports and current-compiler qualification still require
work. This later diagnostic does not replace the baseline-profile count above.

The aggregate planning check also exposed a host reporting defect: remote
lint/formal/synthesis dry runs were classified as failed because they emitted
no result lines. The EDA runner now returns explicit dry-run skips before
parsing results; real-run missing-result checks remain in place. Its regression
rejects the original implementation. The repaired CLI plans all 25 configured
steps and states that no gate result exists.

Aggregate execution remains open: the inspected remote routes synchronize a
shared checkout, strict remote slang elaboration is unavailable, and local
simulation preflight reports missing required runtime patches. No shared sync
or smoke cleanup was executed. A source-isolated aggregate route and qualified
tools are still needed; a planning receipt does not satisfy those gates.
