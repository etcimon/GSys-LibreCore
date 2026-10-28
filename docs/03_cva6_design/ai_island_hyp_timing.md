# Experimental AI-island timing and transaction ownership

The GSys LibreCore r31–r39 timing pass applies to the experimental APU overlay
under `build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/`. Production
`corev_apu/` remains the architectural reference. The source, caller and gate
record is `analysis/nine-module-r31-r39.md` in that overlay; its JSON companion
links the reported paths to their operators and direct caller connections.

## Pipeline contracts

- Floating dot decode occupies a new registered stage. The integer result and
  GEMM tag pipelines gain the matching cycle; issue throughput stays one per cycle.
- C-bank seed responses are captured before bank selection. Store-fetch cadence
  and the two-set FP32 accumulator recurrence retain their existing contracts.
- Policy ranking has a separate decision stage. Descriptor byte-tail arithmetic
  uses the existing sequential-multiply window. Published policy cost estimates
  remain distinct from the evaluator's actual elapsed cycles.
- Integer and floating reductions use explicit arithmetic trees. Normalization
  factors common result fields without changing the align/normalize interface.
- A two-entry AW admission buffer retains ownership until its descriptors enter
  the invalidation queue. Deferred B credits cover responses arriving before that
  transfer. Idle includes the admission slots and deferred credits.

## Shared AXI response ownership

The island request mux prioritizes completion stores, GEMM and descriptor fetch.
The response presented to each client is qualified by the same selection. An
inactive client's input skid can otherwise capture a valid response even though
its READY is absent from the selected master request. That captured descriptor
response can later be consumed as a GEMM operand.

The r39 counterexample contains two descriptor-ID responses consumed by GEMM
before its first GEMM-ID response. The repaired routing prevents those captures.
This is the island's serialized-client contract; a general interconnect with
concurrent owners needs transaction/ID-based response routing.

With DMA invalidation enabled, completion publication also waits for the write
responses and corresponding invalidations to drain. The island DMA bench tracks
B completion by cache line and checks that the final invalidation covers each
line's last completed write before a completion becomes visible.

## Evidence and limits

`verif/regress/remote/run_ai_hyp_gemm_review.py` packages a hash-checked source
closure and runs selected cases on the qualified private Verilator runtime.
The island fixture supports its normal geometry and a small 8×8×8 geometry,
with DMA invalidation independently enabled. Separate dot-product, policy,
protocol and FP32 reference checks cover their respective interfaces.

The frozen delay-v45 reports are structural screening measurements. In
particular, generated reduction levels are not fully composed into complete
operand-to-result arrivals. Module maxima, path counts and independent-LHS
bundles do not establish physical timing closure. Synthesis, area/power, DFT,
full-core/Linux and physical timing qualification require separate evidence.

These transforms add no ISA encoding, CSR, DTS requirement, clock domain or
memory-macro interface. Added state uses the existing asynchronous active-low
reset and existing testmode/clock conventions. Decode/seed registers, queue
credits and parallel arithmetic are area/power trade-offs for backend review.

## r40/r41 subcode and GEMM reductions

The r40 policy-subcode pass moves the index-to-shape geometry into a
SHAPE preparation state and computes the winning threshold at RANK in
parallel (`subcode-gemm-r40-r41-results.json`): **44.55 → 30.40** FO4,
43/67 → 31/81 over-budget paths. The shared multiplier's completion is
now qualified by pending/owned state, so a cancelled evaluation cannot
consume the previous job's product; an abort may wait for outstanding
multiplier work to drain. The fixed 32-cycle cost-model charge remains
a separate accounting term — SHAPE adds one cycle per candidate, and
the actual evaluator latency is longer than the model credit.

The r41 GEMM pass bounds the receive count arithmetic
(`receive_room_n`/`receive_limit`/`receive_fits`) and replaces the
C-bank read-mux priority loops with an indexed wiring table;
**46.95 → 38.70**, 196/378 → 194/392. Cache-hit publication, the
store-fetch cadence and the invalidation barrier are unchanged.

The current island leaves the subcode result ports unconnected; the
completed-result oracle that verifies them is bench-only. These
transforms add no ISA encoding, CSR, DTS requirement, config knob,
clock domain or SRAM-macro interface. All values remain structural
screening estimates, and the aggregate verification gate is open
(rc=1: missing hyp config package, default core smokes, synth
command).
