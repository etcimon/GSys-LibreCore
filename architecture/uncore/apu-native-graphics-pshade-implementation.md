# Native graphics fragment-shader stage

Status: implemented, host-native-model evidence only.  No rasterization,
ROP/framebuffer write, `vkCmdDraw*` submission, capset advertisement, RTL,
CTS, Linux or physical qualification is claimed or enabled.  Draw records
still fail replay admission atomically; zero capsets remain advertised.

## Scope

`corev_apu/apu/tools/vn_graphics_pshade.py` adds the third draw-pipeline
stage as an executor runtime operation, mirroring `vn_graphics_shade.py` for
the fragment execution model:

- `FragmentShade` — frozen operation carrying an immutable FS-in record
  image (`records`, bytes, multiple of the 144-byte record stride, at most
  `MAX_RECORDS` records), the fragment shader's code tuple, optional push
  words (<= 32), a per-`Model` batch bound (`batch`, default/max 256), a
  per-record helper-invocation bitmask (`helpers`, 64-bit) and the primitive
  front-facing bit (`front`, 0/1).
- `FragmentShadeRuntime` — cooperative `advance(budget)`:
  1. builds one `shader.spirv_model.Model` per batch over a flags-bit2
     graphics work record `{stage=Fragment EM, count, in_base=0,
     out_base=nin*4, vbase=front, inst=0, nin}` followed by the input-record
     words and the two-word helper mask (`helpers >> batch_start`, low 64
     bits — matching the model's per-batch lane window);
  2. steps live invocations one instruction per round-robin turn
     (`run_inv(i, single=True)`) with rendezvous barrier release, identical
     to the VS stage;
  3. on batch completion copies `gcnt * RECORD_STRIDE` output words into
     the accumulated `color` image.
- `TransferExecutor` accepts `FragmentShade` beside `Compute`/`Fetch`/
  `Shade`; `_turn` retires it with
  `job.fshade_stats[op] = {records, steps, batches, robust, color}`.

## Admission guards (constructor-time, before any work is published)

- Record image must be `bytes`, non-empty, stride-aligned and within
  `MAX_RECORDS * 144` bytes.
- SPIR-V magic/bounded word count, push-word count/range, `batch` bound,
  `helpers` range, `front` in {0,1}.
- `spirv_scan.Scanner` must accept the module and report execution model
  Fragment; any `DescriptorSet`/`Binding` decoration is refused —
  descriptor resources (textures/samplers/UBOs) are not yet admitted for
  graphics shading.
- Per-batch `Model` construction validated (`gfx == GFX_FS`,
  `gcnt == batch count`); failures become job faults.

## Record ABI exercised

- FS-in records (144 B): `FragCoord` builtin at slot 0, `Location l`
  varyings at `16*(1+l)` — produced today only by callers/tests; the raster
  stage that generates them from VS-out records is still open.
- FS-out records (144 B, `ATTR_STRIDE`): `Location l` color outputs at
  `16*l`; `FragDepth` builtin lands at slot 8 word 0 with the model's
  `fs_late` tail write when the module kills/demotes or writes depth.
- `FrontFacing` resolves through the work record `vbase` bit 0;
  `HelperInvocation` through the per-batch helper mask; killed lanes keep
  private/function stores but suppress device-visible stores (model rule).

## Budgets and faults

- `MAX_STEPS = 1<<20` instructions per operation; `STEP_QUANTUM = 512`
  per cooperative turn; `BATCH_MAX = 256`.
- Model `robust` accesses counted per batch into `fshade_stats`; faults
  (`m.fault`), model construction failures and budget exhaustion fault the
  job; FS input is immutable caller bytes so the runtime holds no memory
  owners (`owners = {}`).

## Evidence

- `test_vn_graphics_pshade.py` (5 tests): color passthrough record order,
  FragCoord builtin + multi-batch ordering, helper/front admission, record
  shape/stage/descriptor/oversize refusal.  Modules are hand-assembled in
  the test (no corpus binaries — the frozen cohort ships sources only).
- Frozen native cohort `native-pshade-01`: 591 tests PASS in 15.454 s,
  `sources_unchanged: true`; `PASS: host-native-model; no RTL/CTS
  qualification`.

## Not claimed

Rasterization/primitive assembly, FS-in record generation, descriptor
bindings for graphics stages, ROP/blend/writeback to attachments,
`DrawPlan` -> operation conversion, `vkCmdDraw*` replay, synchronization,
capsets, CTS, RTL and physical qualification all remain open.  This stage
is reachable only as an executor runtime operation from native tests; no
wire command produces it yet.
