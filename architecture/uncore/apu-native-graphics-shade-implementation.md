# Native graphics vertex-shader stage

Status: implemented, host-native-model evidence only.  No rasterization,
fragment shading, framebuffer write, `vkCmdDraw*` submission, capset
advertisement, RTL, CTS, Linux or physical qualification is claimed or
enabled.  Draw records still fail replay admission atomically; zero capsets
remain advertised.

## Scope

`corev_apu/apu/tools/vn_graphics_shade.py` adds the second draw-pipeline
stage as an executor runtime operation, consuming the `Fetch` record image
inside the same job so shader inputs observe earlier queued writes exactly
once:

- `Shade` — frozen operation carrying a `Fetch` plus the vertex shader's
  immutable code tuple (specialized SPIR-V words), optional push words
  (<= 32) and a per-`Model` batch bound (`batch`, default 256, max 256).
- `ShadeRuntime` — cooperative `advance(budget)`:
  1. advances the nested `FetchRuntime` until records are complete;
  2. builds one `shader.spirv_model.Model` per batch of at most `batch`
     invocations over a flags-bit2 graphics work record
     `{stage=Vertex EM, count, in_base=0, out_base=nin*4, vbase=0, inst=0,
     nin}` followed by the input-record words and a zero helper mask;
  3. steps live invocations one instruction per round-robin turn
     (`run_inv(i, single=True)`), releasing barrier waiters only at full
     rendezvous, mirroring `Model.run()` graphics semantics;
  4. on batch completion copies `gcnt * VARY_STRIDE` output words into the
     accumulated `vary` image and starts the next batch.
- `TransferExecutor` accepts `Shade` beside `Compute`/`Fetch` (same runtime
  table, owner pinning, budget accounting); `_turn` retires it with
  `job.shade_stats[op] = {records, steps, batches, robust, vary}`.

## Admission guards (constructor-time, before any work is published)

- SPIR-V magic/bounded word count, push-word count/range.
- `spirv_scan.Scanner` must accept the module and report execution model
  Vertex; any `DescriptorSet`/`Binding` decoration is refused — descriptor
  resources are not yet admitted for graphics shading.
- Per-batch `Model` construction is validated (`gfx == GFX_VS`,
  `gcnt == batch count`); model/scan failures become job faults, never
  partial results.

## Record ABI exercised

- VS-in records (144 B, `ATTR_STRIDE`): locations 0–7 at `16*loc`, slot 8
  `{VertexIndex, InstanceIndex, 0, 0}` at +128 — written by `Fetch`.
- VS-out records (144 B, `VARY_STRIDE`): `Position` builtin at slot 0,
  `Location l` varyings at `16*(1+l)`; collected per batch in invocation
  order into `ShadeRuntime.vary`.
- `VertexIndex`/`InstanceIndex` resolve through the model's slot-8 record
  path; `vbase`/`inst` header fields stay 0 for the VS stage.

## Budgets and faults

- `MAX_STEPS = 1<<20` instructions per operation; `STEP_QUANTUM = 512`
  instructions per cooperative `advance` turn; `BATCH_MAX = 256`
  invocations per `Model` wave.
- Model `robust` out-of-bounds record accesses are counted per batch and
  surfaced in `shade_stats`; instruction faults (`m.fault`), model
  construction failures and budget exhaustion fault the job and release
  all owner pins through the existing executor retirement path.

## Evidence

- `test_vn_graphics_shade.py` (6 tests): attribute+`VertexIndex` varying
  outputs against a hand-assembled `vs_passthru`-equivalent module (no
  corpus binaries — the frozen cohort ships sources only), indexed-fetch
  builtin feed, multi-batch record ordering, wrong-stage/descriptor
  refusal, indirect-argument + lease/retirement ordering.
- Frozen native cohort `native-shade-03`: 586 tests PASS in 16.092 s,
  `sources_unchanged: true`; `PASS: host-native-model; no RTL/CTS
  qualification`.
- `shader/shader_vectors.py::read_spv` file-handle leak fixed (the cohort
  runs `-W error::ResourceWarning`).

## Not claimed

Rasterization, primitive assembly, fragment shading, render-target writes,
`DrawPlan` -> operation conversion, `vkCmdDraw*` replay, synchronization,
capsets, CTS, RTL and physical qualification all remain open.  This stage
is reachable only as an executor runtime operation from native tests; no
wire command produces it yet.


## Buffer-descriptor vertex shade (implemented)

 now carries resolved  operands (kind 6 UBO /
7 SSBO) end-to-end:  ->  ->
 ->  ->  ->
.   is a hybrid wave memory: descriptor binding
ranges route to  (read for kind 6/7, write only for kind 7)
while vertex inputs, varying outputs and scratch stay in an internal store.
Descriptor  bases are biased by  (0x10000000) into a high
word range disjoint from the low record image so the two cannot alias; the
bias is bounded at admission so biased addresses always fit the 32-bit header
word.  The Model header emits real binding rows plus per-binding init-word
placeholders (consumed but not stored because live memory is supplied) so the
trailing graphics wave section stays aligned.  Shader-side admission now
permits / storage descriptors and requires each decorated
(set,binding) to be covered by a provided operand; 
image/sampler descriptors and fragment-stage bindings remain refused.

Evidence:  grew to 8 tests — a hand-assembled
UBO-reading vertex module folds a device-memory int into 
(observed in every vary record), plus unbound/wrong-set refusal.  Full local
 sweep: 731 tests PASS.  Remote cohort evidence pending; host-native
model only — no RTL/CTS/stock/hardware qualification.

## Buffer-descriptor vertex shade (implemented)

`Shade.bindings` now carries resolved `ShaderBinding` operands (kind 6 UBO /
7 SSBO) end-to-end: `GraphicsBindings.resolve` -> `DrawPlan.stage_bindings` ->
`vn_graphics_draw_replay._push` -> `DrawExec.vs_bindings` -> `Shade` ->
`ShadeRuntime`.  `GfxMemory` is a hybrid wave memory: descriptor binding
ranges route to `state.aperture` (read for kind 6/7, write only for kind 7)
while vertex inputs, varying outputs and scratch stay in an internal store.
Descriptor `ad` bases are biased by `GFX_DESC_BIAS` (0x10000000) into a high
word range disjoint from the low record image so the two cannot alias; the
bias is bounded at admission so biased addresses always fit the 32-bit header
word.  The Model header emits real binding rows plus per-binding init-word
placeholders (consumed but not stored because live memory is supplied) so the
trailing graphics wave section stays aligned.  Shader-side admission now
permits `UNIFORM`/`SBUF` storage descriptors and requires each decorated
(set,binding) to be covered by a provided operand; `UNIFORMCONST`
image/sampler descriptors and fragment-stage bindings remain refused.

Evidence: `test_vn_graphics_shade` grew to 8 tests - a hand-assembled
UBO-reading vertex module folds a device-memory int into `Position.w`
(observed in every vary record), plus unbound/wrong-set refusal.  Frozen
native cohort `native-gfxubo-01` on ovh_calltorch: 716 tests PASS in 19.144 s,
`sources_unchanged: true`, cohort `native-execution.zolkoufm`; local
`test_vn_*` sweep 731 PASS.  Host-native model only - no RTL/CTS/stock/
hardware qualification.
