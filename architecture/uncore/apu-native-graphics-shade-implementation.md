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

Dynamic descriptor offsets are likewise exercised end-to-end:
`vkCmdBindDescriptorSets` `pDynamicOffsets` flow through
`GraphicsBindings.resolve` -> `buffer_descriptor(dynamic_offset=...)`, which
bakes `binding_offset + descriptor.offset + dynamic_offset` into the
`ShaderBinding` base at resolve time (honouring
`minUniformBufferOffsetAlignment`=256 and the dynamic layout ordinal).
`test_fragment_dynamic_ubo_offset_draw` binds a UNIFORM_BUFFER_DYNAMIC
(type 8) descriptor with `pDynamicOffsets=[256]` so the fragment UBO read
lands on the float at buffer+256 (0.75) rather than the decoy at buffer+0
(0.25); frozen cohort `native-gfxdyn-01`: 732 tests PASS in 21.554 s
(`native-execution._di52ww_`), `sources_unchanged: true`.

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
`resolve_bindings` probe in `DrawExecRuntime`.  The vertex stage needs no
separate scan gate: `ShadeRuntime` calls the same `resolve_bindings`, so a
`vs_image_program` module (OpTypeImage sampled=1, OpImageFetch at a constant
ivec2, texel.x folded into Position.w) proves vertex-stage image reads land
in the vary records (`test_image_descriptor_fetch_reaches_position_w`).
The combined-image-sampler kind is admitted through the same path:
`vn_graphics_resources` maps `TK['SIMG']` (OpTypeSampledImage) to kind 1, and
`fs_image_program(combined=True)` declares the combined type so a
COMBINED_IMAGE_SAMPLER descriptor carrying a real VkSampler reaches
`OpImageFetch` (which ignores sampler state) end-to-end.  Sampler-bearing
filtered sampling is likewise admitted: `fs_sample_program` emits
`OpImageSampleExplicitLod` (opcode 88, Lod image-operand mask) over the same
kind-1 descriptor, and the Model decodes the VkSampler aux carried in the
binding meta words (smpw0/smpw1) to resolve normalized coordinates through
the shared tx/filter path.  Separate sampler+image pairing uses two
descriptors: `fs_separate_sample_program` binds a SAMPLED_IMAGE (kind 2)
and a SAMPLER (kind 0) and merges them at runtime with `OpSampledImage`
(opcode 86), which the Model resolves by fetching the sampler record
separately from the image record before `OpImageSampleExplicitLod`.
Sampler address-mode variety is exercised by parameterizing the VkSampler
`addressModeU/V/W`: `test_fragment_sampler_address_mode_clamp` binds a
CLAMP_TO_EDGE (mode 2) sampler and samples at normalized u=1.25
(su0=floor(1.25*8)=10, out of range) so the coordinate clamps to texel x=7
rather than REPEAT-wrapping to x=2.  The full four-mode set is now proven
on the same out-of-range coordinate: REPEAT (mode 0) wraps su0=10 to x=2,
MIRRORED_REPEAT (mode 1) folds 10 % (2*8)=10 then mirrors to
2*8-1-10 = x=5 (`test_fragment_sampler_address_mode_mirrored`), and
CLAMP_TO_BORDER (mode 3) substitutes the sampler border colour
(`test_fragment_sampler_address_mode_border`, FLOAT_OPAQUE_WHITE
borderColor=4 -> all channels 1.0 -> covered texels (255,255,255,255)).
Filter variety is exercised through a
`linear` flag on the shared setup that selects LINEAR (1) over NEAREST (0)
for `magFilter`/`minFilter`: `test_fragment_linear_filter_blend` binds a
LINEAR combined-image-sampler and samples at normalized u=0.25, where the
Model's 8.8 fixed-point coordinate `su0=floor((u*w0-0.5)*256)` yields
iu0=1, fu0=128 - an exact 50/50 horizontal weight - so covered texels
blend texel(1,1)=(32,64,32,255) and texel(2,1)=(64,64,48,255) to the
UNORM mean (48/255, 64/255, 40/255, 1.0).  This is the first bilinear
(non-nearest) filter path exercised end-to-end.

Multi-level (mipmap) images are admitted through a descriptor-binding ABI
extension: `ImageBinding` gained a `mips` field (view levelCount, default
1) that `image_descriptor` populates after relaxing the single-level
`levels == 1` bound to `1 <= levels <= mips - baseMip`, computing `size`
as the full accessible mip-chain footprint (`img_layer_bytes` over every
level) while `offset` stays the base-mip byte offset.  `ShaderRuntime.
_image_row` validates `1 <= mips <= 16`, checks the binding covers the
whole chain, and encodes the level count into the packed format word
(`mdim = mips` in bits 8..11) so the Model's already-mip-aware `img_walk`
sees `lvl = mdim & 0xF` levels.  `fs_sample_program(lod=...)` emits an
explicit LOD operand and `_image_fetch_setup(mips=..., max_lod=...)`
builds a `VkImage`/`VkImageView` with `mipLevels = levelCount = mips`,
fills mip0 with the (x,y) pattern and every mip>=1 solid green, and sets
`VkSamplerCreateInfo.maxLod` high enough that the Model's `le` clamp
(`min(max(le,min44),max44)`) does not pin LOD to mip0.
`test_fragment_mipmap_explicit_lod` binds a 2-level COMBINED_IMAGE_SAMPLER
(dtype 1) and samples at u=v=0.5, LOD=1.0, nearest filter: the Model
selects mip1 (`m0 = (le+8)>>4 = 1`, `m0 = min(m0, lvl-1)`) and returns the
solid-green texel rather than the mip0 (x,y) pattern - proving the mip
count now reaches the sampled-image meta end-to-end.

Trilinear (fractional-LOD blend across two mips) rides the same ABI:
`_image_fetch_setup` gained `mip_linear` (VkSamplerMipmapMode.LINEAR)
and `mip_color` (the RGBA fill for every mip>=1) parameters.
`test_fragment_trilinear_filter_blend` binds a LINEAR min/mag + LINEAR
mipmap sampler over a 2-level image and samples at u=0.4375, v=0.375,
LOD=0.5: mip0 lands on a single texel (fu0=fv0=0 -> texel(3,1)=(96,64,64,
255)) while mip1's solid (0,192,0,255) fill collapses its bilinear
footprint to that colour, and `le=8 -> m0=0,m1=1,fw=128` yields an exact
50/50 mip blend -> (48,128,32,255), all integers so the 16-bit
fixed-point accumulate + UNORM8 round-trip is exact.  Gather is likewise
proven: `fs_gather_program` emits `OpImageGather` (opcode 96) over the
same kind-1 descriptor.  The model's gather operand order is
ResultType, ResultId, SampledImage, Coordinate, Component (an SSA id
whose value `& 3` selects the channel), ImageOperands mask (0 = none);
`OpImageGather` forces the linear coordinate path and returns a vec4
whose component `gi` is the `comp` channel of the 2x2 footprint texel at
SPIR-V corner `gi` (order `(i0,j1),(i1,j1),(i1,j0),(i0,j0)`), landing
directly in the RGBA framebuffer channels.  `test_fragment_image_gather`
samples at u=0.35, v=0.4 (8.8 coord -> iu0=2, iv0=1 -> footprint
x{2,3},y{1,2}) with comp=0 (R = x*32): texels (2,2)=64, (3,2)=96,
(3,1)=96, (2,1)=64 -> framebuffer (64,96,96,64), no filtering.
Projective sampling is likewise proven: `fs_proj_sample_program` emits
`OpImageSampleProjImplicitLod` (opcode 91) over a vec3 coordinate
`(u,v,d)`; the model's projective forms divide `coord.xy` by the last
component before sampling (operand order ResultType, ResultId,
SampledImage, Coordinate, ImageOperands mask - absent here so the
implicit-LOD path runs with wc=5).  `test_fragment_projective_sample`
uses u=0.6, v=0.7, d=2.0 -> divided coord (0.3,0.35) -> nearest mip0
texel(2,1)=(64,64,48,255); the undivided (0.6,0.7) would hit texel(4,2)
=(128,128,96,255), so the observed value proves the perspective divide
ran.  Interpolation qualifiers now reach the raster stage:
`spirv_scan` admits the `Flat`/`NoPerspective` decorations (previously
`FAULT['DECOR']`), records them per fragment-Input variable, and exposes
`flat_mask`/`nopersp_mask`; `GraphicsPipeline` snapshots carry the masks
and `DrawExec` forwards them to `Raster`, which already implemented the
provoking-vertex copy and the perspective-off arm.
`test_fragment_flat_varying_uses_provoking_vertex` draws a triangle with
distinct per-vertex colors under a `Flat`-decorated vcol input: every
covered fragment carries v0's color.rgb and v0's VertexIndex alpha (0.0)
rather than the smooth three-vertex blend.  `NoPerspective` rides the
same mask path: `fs_program(nopersp=True)` decorates vcol and
`test_nopersp_decoration_reaches_scan_mask` proves it surfaces as
`nopersp_mask` bit0, while
`test_nopersp_varying_uses_screen_space_weights` exercises the raster
nopersp arm directly - clip w=[1,2,1] with NDC preserved by scaling x,y
by w yields identical coverage/lam but persp=11.613 vs nopersp=11.875 at
pixel(0,0).  A full end-to-end NoPerspective draw still needs a
w-varying vertex shader (`vs_program` pins Position.w=1.0 so
persp==nopersp there).  Depth-reference (dref) sample ops stay queued.

Evidence: `test_vn_graphics_draw_replay` gained nine image draws -
`test_fragment_sampled_image_fetch_reaches_framebuffer` (constant ivec2
coordinate), `test_fragment_per_pixel_image_fetch` (ivec2 derived from
FragCoord.xy via OpCompositeExtract + OpConvertFToS + OpCompositeConstruct),
and `test_fragment_combined_image_sampler_fetch` (OpTypeSampledImage kind 1
with a VkSampler-bound COMBINED_IMAGE_SAMPLER descriptor producing the same
per-pixel texels as the kind-2 fetch), `test_fragment_explicit_lod_sample`
(OpImageSampleExplicitLod at normalized coord (0.3125,0.375)=texel(2,1)
centre, LOD 0, nearest VkSampler -> uniform covered texels),
`test_fragment_implicit_lod_sample` (OpImageSampleImplicitLod opcode 87,
zero derivatives -> base mip -> same texel),
`test_fragment_separate_sampler_image_sample` (kind2 image + kind0 sampler
merged by OpSampledImage then explicit-LOD sampled -> texel(2,1)),
`test_fragment_sampler_address_mode_clamp` (CLAMP_TO_EDGE sampler, u=1.25 ->
texel(7,1) not wrapped x=2),
`test_fragment_sampler_address_mode_mirrored` (MIRRORED_REPEAT sampler,
u=1.25 -> su0=10 -> mirror to texel(5,1)),
`test_fragment_sampler_address_mode_border` (CLAMP_TO_BORDER sampler +
FLOAT_OPAQUE_WHITE borderColor=4, u=1.25 -> border (255,255,255,255)),
`test_fragment_linear_filter_blend` (LINEAR combined sampler, u=0.25 ->
su0=384, iu0=1, fu0=128 -> 50/50 bilinear blend of texels (1,1)+(2,1) ->
UNORM mean (48,64,40)),
`test_fragment_mipmap_explicit_lod` (2-level COMBINED_IMAGE_SAMPLER,
u=v=0.5 LOD=1.0 nearest -> mip1 solid green, not the mip0 (x,y) pattern),
`test_fragment_trilinear_filter_blend` (LINEAR mipmap sampler, u=0.4375
v=0.375 LOD=0.5 -> mip0 texel(3,1) + solid mip1 50/50 -> (48,128,32,255)),
`test_fragment_image_gather` (OpImageGather opcode 96, comp=0 R-channel,
u=0.35 v=0.4 -> footprint x{2,3},y{1,2} -> RGBA (64,96,96,64)),
`test_fragment_projective_sample` (OpImageSampleProjImplicitLod opcode
91, vec3 coord (0.6,0.7,2.0) -> divided (0.3,0.35) -> texel(2,1)
(64,64,48,255)),
`test_fragment_flat_varying_uses_provoking_vertex` (Flat-decorated vcol
input over a distinct-color triangle -> every covered fragment = v0's
color.rgb + v0 VertexIndex alpha 0.0, not the smooth blend),
`test_nopersp_decoration_reaches_scan_mask` (NoPerspective vcol ->
nopersp_mask bit0) and
`test_nopersp_varying_uses_screen_space_weights` (raster nopersp arm:
w=[1,2,1] NDC-preserved -> persp 11.613 vs nopersp 11.875),
plus
`test_fragment_storage_image_write` (a STORAGE_IMAGE kind 3 bound via
`OpTypeImage(sampled=2)`; `OpImageWrite` stores a constant red texel at the
same FragCoord-derived coordinate, and the aperture bytes under the bound
image are checked - covered texels become red while uncovered keep their
pattern).  The fetch draws prove each covered framebuffer texel equals its
own (x,y)-encoded image texel; the store draw proves the previously
unexercised kind-3 `GfxMemory` write admission end-to-end; the mipmap draw
proves the descriptor ABI now carries a multi-level mip count into the
sampled-image meta; the trilinear draw proves the fractional-LOD
two-mip accumulate + fw blend arm; the gather draw proves the opcode-96
footprint/component operand path; the projective draw proves the
coord.xy/d perspective divide; the flat draw proves the FS-Input
interpolation qualifier now reaches the raster varying path, and the
nopersp pair proves the NoPerspective decoration->mask capture plus the
screen-space (non-perspective) interpolation arm.  Local
`test_vn_*` sweep ran 754 tests, all green.  Frozen native
cohorts on ovh_calltorch:
`native-gfximg-01` 720 tests PASS in 20.465 s (`native-execution.y6y3xap5`),
`native-gfximgpix-01` 721 tests PASS in 20.582 s
(`native-execution.nssux4bd`), `native-gfximgstore-01` 722 tests PASS in
21.914 s (`native-execution.5axy_z9z`), `native-gfxvsimg-01` 723 tests
PASS in 20.500 s (`native-execution.n8_r1ss2`), `native-gfxcomb-01`
724 tests PASS in 20.725 s (`native-execution.6yodeq0j`),
`native-gfxsample-01` 725 tests PASS in 21.016 s
(`native-execution.no_22v6j`), `native-gfximplod-01` 726 tests PASS in
20.888 s (`native-execution.3wzcog89`), `native-gfxsep-01` 727 tests
PASS in 19.317 s (`native-execution.edz92krq`), and `native-gfxclamp-01`
728 tests PASS in 20.752 s (`native-execution.3pqmo813`), and
`native-gfxlinear-01` 729 tests PASS in 20.969 s
(`native-execution.eey3xhni`), and `native-gfxaddr-01` 731 tests PASS in
18.759 s (`native-execution.amvegsm4`), and `native-gfxdyn-01` 732 tests
PASS (`native-execution._di52ww_`), and `native-gfxmip-01` 733 tests PASS
in 21.0 s (`native-execution.hwg4luup`), and `native-gfxtrilin-01` 734
tests PASS in 20.0 s (`native-execution.aaadxsp4`), and
`native-gfxgather-01` 735 tests PASS in 21.4 s
(`native-execution.22fa7i0d`), `native-gfxproj-01` 736 tests PASS in
21.2 s (`native-execution.tfz4m7nk`), `native-gfxflat-01` 737 tests
PASS in 21.6 s (`native-execution.hwuix8zk`), and `native-gfxnopersp-01`
739 tests PASS in 20.1 s (`native-execution.5ntfmy6r`), all
`sources_unchanged: true`.
Host-native model only - no RTL/CTS/stock/hardware qualification.
