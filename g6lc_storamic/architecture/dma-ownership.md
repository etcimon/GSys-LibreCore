# Shared AXI DMA Ownership

## Failure And Boundary

The single-beat Storamic adapter time-shares an upstream AXI master port.
Before handing that port to DMA it must retire both accepted transactions and
already-visible stalled address offers. Data has no AXI4 master tag: passing
an unowned upstream W beat into a shared slave can associate it with DMA AW.

Frozen original `storamic-all-1fe2db051de4` records upstream W accepted with
no upstream AW, followed by DMA grant. The legal independent-channel slave
then writes `cafe1234abcd5678` (upstream payload) to DMA address `0x9000`,
not its intended upstream address `0x1000`, and stalls. This is an actual
data-integrity failure, not a fixture acknowledgement or a stale signal guess.

The original five-case snapshot `storamic-all-ce8f4030de7a` also rejects:
- held AW withdrawn when DMA requests ownership;
- held AR withdrawn at the same boundary;
- 256 write addresses wrapping the eight-bit outstanding count to zero;
- 256 read addresses doing likewise.

Earlier generation failure `9baf5dffb0e3` is a bench-only mixed blocking/
nonblocking packed-response driver defect. The bench now publishes one
whole-vector response from registered state and separate combinational readiness;
strict diagnostics are unchanged. That failure is not an RTL verdict.

## Correctness Fix

`corev_apu/storamic/g6lc_storamic_dma_axi.sv` retains its type-injected ports,
DMA phase FSM and optional invalidation protocol.

- W may flow against an accepted AW or an AW currently visible downstream.
  W with neither address owner is backpressured.
- A signed nine-bit AW-minus-WLAST credit permits `-1` for WLAST accepted
  against a visible but not-yet-accepted AW. That offer cannot admit a second
  unmatched burst.
- Separate stalled-AW/AR flags keep VALID and payload visible until handshake,
  including during DMA drain. The upstream master retains its own payload
  until its actual handshake; no new address/data buffer is added.
- Existing eight-bit write/read counters block address admission at 255
  instead of wrapping. At full capacity, a retirement opens a slot next cycle.
- DMA grant and `inflight_o` include data credit and stalled address ownership.
  Accepted upstream W bursts and held B/R responses continue draining.

WVALID never depends combinationally on AWREADY. Waiting for *accepted* AW
before exposing W would deadlock a legal slave that waits for WVALID before
asserting AWREADY. An offered AW supplies progress without giving up ownership.

## Directed And Formal Method

`vdma-ownership` independently runs seven SV profiles with rejecting oracles:
0. W before any AW, DMA request, exact final memory payloads.
1. Stalled AW across DMA request, then write/response completion.
2. Stalled AR followed by held R across DMA request, then completion.
3. Write-credit capacity; 256 offers admit only 255 and retain ownership.
4. Read-credit capacity with the same requirement.
5. W-leading traffic to a slave whose AWREADY waits for WVALID.
6. WLAST accepted before its visible AW, then DMA drain and completion.

Cases 3/4 deliberately keep the admitted transactions pending: they prove
bounded admission/ownership, not eventual service. Legacy `vdma` retains
concurrent four-beat upstream traffic, payload/strobe checks and both
invalidation modes.

The new `vdma-ownership-formal` uses public-interface scoreboards. It constrains
only a single-beat upstream protocol environment: source payload/VALID stability,
single-beat shape and no unsolicited slave responses. DMA request withdrawal,
backpressure, AW/W order and multiple pending transactions remain free.
It checks downstream AW/W/AR stability, no unowned W, no DMA grant with upstream
debt and inflight retention. Sticky covers exercise offered-W ownership,
stalled AW, held R and subsequent drain. Safety/cover/oracle depths are
16/8/8/8/14/12. This bounded single-beat proof is not unrestricted burst liveness.

The first corrected snapshot `storamic-all-c07bbf15bd60` passes all seven new
profiles and both legacy DMA modes. The final `storamic-all-ad66348d684f`
passes all thirteen selected stages with source-post identity: the seven
profiles and their seven rejecting oracles, both legacy DMA modes, all six new
formal queries, writer save/restore/reset profiles and existing endpoint/
writer/device/ring formal and synthesis checks.

Original-RTL replay `storamic-dma-original-78662284` uses the exact final
bench/harness/runner and differs only in the frozen pre-fix adapter. All seven
profiles reject; the unchanged formal safety query produces a genuine SAT
counterexample, not an infrastructure/parse failure. These failed stages are
negative evidence, not positive passes.

All 110 packaged code/runner files match the current source closure. Twenty
simulator builds train with rc0, rebuild profile-use and verify their runtime.
Repository `tools/verilator` compiler PGO/loop-unroll and repository
`tools/yosys` identities remain frozen; no training run is qualification.
Local 113 Python tests, seven platform checks, typecheck, four configured
lint steps and 103-file licensing/source audit pass. Compact evidence is
`dma-final-26.json`/`FINAL-SV-26.md` in the contained `storamic-policy-19`
build workspace.

## SoC Readiness Review

This is a mandatory AXI correctness fix inside the existing optional binding,
not a new feature requiring a CVA6Cfg bit. Native/default-off configuration and
ISA/CSR/discovery/PMA/PMP/DTS/Linux interfaces do not change. No authority,
provider-ready or cache synchronization acknowledgement is manufactured.

Eleven scalar flop bits (nine-bit credit/two stalled flags) use the existing
clock and asynchronous active-low reset. No array, macro, clock/reset/power
domain, raw vendor cell or new pipeline stage is introduced. Registered-credit
comparisons and offer gating feed the upstream valid/ready mux; there is no
new ready-to-valid feedback. Generic synthesis/lint remain latch/SCC clean.
No technology timing, 8-FO4/5-GHz, power or scan/ATPG closure is inferred.
Generic active writer composition grows by 41 cells (3044 to 3085), still with
four SRAM-model memories. Off/invalid layout remain 93 cells/no memories.
All three cases have zero latches and SCCs.

Existing `inflight_o` exposes the newly retained ownership to checkpoint/policy
observers. This is not a new CPU instruction or PMU feature. Existing invalidation
ports and scan-visible common-domain state remain in place; full backend/DFT
verification remains an open product gate.

Native C3/C4/C5/C6 authority/topology/cache/fabric bindings, strict CPU scheduling,
physical persistence, aggregate/compliance/default-netlist and Linux qualification
remain open regardless of these component results.
