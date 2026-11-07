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
(set,binding) to be covered by a provided operand.

Evidence: `test_vn_graphics_shade` grew to 8 tests - a hand-assembled
UBO-reading vertex module folds a device-memory int into `Position.w`
(observed in every vary record), plus unbound/wrong-set refusal.  Frozen
native cohort `native-gfxubo-01` on ovh_calltorch: 716 tests PASS in 19.144 s,
`sources_unchanged: true`, cohort `native-execution.zolkoufm`; local
`test_vn_*` sweep 731 PASS.  Host-native model only - no RTL/CTS/stock/
hardware qualification.

## Image/sampler descriptor shade (implemented)

`resolve_bindings` now accepts `ImageBinding` operands alongside
`ShaderBinding`: kind 0-3 UNIFORMCONST image/sampler descriptors produce the
Model's 10-word binding rows (5-word base entry with the `1<<24` image flag
plus 5 meta words) via `ShaderRuntime._image_row`, which reuses the compute
path's format/footprint/sampler validation.  Image `ad` bases get the same
`GFX_DESC_BIAS` treatment; `GfxMemory` routes image reads to the aperture and
admits writes only for storage images (kind 3) alongside SSBO (kind 7).
Shader-side admission maps `UNIFORMCONST` storage to the bound image
(set,binding) pairs and `UNIFORM`/`SBUF` to buffer pairs; `UNIFORMCONST`
reached the fragment stage through `_fragment_scan` and the eager
`resolve_bindings` probe in `DrawExecRuntime`.

Evidence: `test_vn_graphics_draw_replay` gained three image draws -
`test_fragment_sampled_image_fetch_reaches_framebuffer` (constant ivec2
coordinate), `test_fragment_per_pixel_image_fetch` (ivec2 derived from
FragCoord.xy via OpCompositeExtract + OpConvertFToS + OpCompositeConstruct),
and `test_fragment_storage_image_write` (a STORAGE_IMAGE kind 3 bound via
`OpTypeImage(sampled=2)`; `OpImageWrite` stores a constant red texel at the
same FragCoord-derived coordinate, and the aperture bytes under the bound
image are checked - covered texels become red while uncovered keep their
pattern).  The fetch draws prove each covered framebuffer texel equals its
own (x,y)-encoded image texel; the store draw proves the previously
unexercised kind-3 `GfxMemory` write admission end-to-end.  Local
`test_vn_*` sweep 737 PASS.  Frozen native cohorts on ovh_calltorch:
`native-gfximg-01` 720 tests PASS in 20.465 s (`native-execution.y6y3xap5`),
`native-gfximgpix-01` 721 tests PASS in 20.582 s
(`native-execution.nssux4bd`), and `native-gfximgstore-01` 722 tests PASS in
21.914 s (`native-execution.5axy_z9z`), all `sources_unchanged: true`.
Host-native model only - no RTL/CTS/stock/hardware qualification.
