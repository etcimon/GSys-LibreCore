# Native graphics draw execution and replay

Status: implemented, host-native-model evidence only.  The bounded draw
profile now admits all six input-assembly topologies (POINT/LINE/
LINE_STRIP/TRIANGLE_LIST/TRIANGLE_STRIP/TRIANGLE_FAN), polygonMode
FILL/LINE/POINT, late-z depth (D32) plus D24S8 stencil (all ops,
compare/write masks, reference), single- and per-attachment-MRT blending
(UNORM8 RGBA/BGRA, all factors/ops, blendConstants, colourWriteMask,
logicOp), up to four colour targets, texture/sampling (combined and
separate image+sampler, mips/LOD/trilinear/border/depth-compare/gather),
occlusion and multi-subpass, instancing and direct/indexed/indirect
draws (instanced draws assemble primitives per instance — the raster
resets grouping every `fetch.args[0]` records so strip/fan/list windows
never straddle an instance boundary; and primitiveRestartEnable on
indexed draws — the fetch stage marks index-width sentinels as break
records and the raster assembles primitives break-aware per run),
fragment discard and quad derivatives.  MSAA, PATCH_LIST/geometry, non-UNORM8 blend/logicOp
formats, wide lines and multi-viewport stay refused; zero capsets remain
advertised and
`vkCmdDraw*` admission stays bounded to the profile below, subject to the
independent capability/CTS gates.

## Scope

Two layers complete the first executable graphics path:

- `corev_apu/apu/tools/vn_graphics_drawexec.py` -- `DrawExec`, a frozen
  executor operation chaining the five stage runtimes inside one job:
  `Fetch` (vertex/index live reads) -> `Shade` (VS waves) -> `Raster`
  (FS-in record generation) -> `FragmentShade` (FS waves) -> `Writeback`
  (up to four colour attachments under one shared gate).
  `DrawExecRuntime.advance` advances the
  current stage under the caller budget, constructs the next runtime when
  a stage retires, and publishes per-stage statistics on the job
  (`fetch_stats`, `shade_stats`, `raster_stats`, `fshade_stats`,
  `writeback_stats`, `drawexec_stats`).
  - Eager admission probes instantiate each stage profile before any work
    is published.  Buffer (`UNIFORM`/`SBUF`), image and sampler
    (`UNIFORMCONST`) descriptor binds are admitted per stage through the
    shared `resolve_bindings` helper: `DrawExec.vs_bindings`/
    `fs_bindings` carry the resolved `ShaderBinding` operands into
    `Shade`/`FragmentShade`, which emit real Model binding rows under the
    `GFX_DESC_BIAS`/`GfxMemory` aperture model.  An unbound decorated
    descriptor refuses at admission (the FS binding coverage is probed
    eagerly in `DrawExecRuntime.__init__`, matching the vertex stage).
  - Intermediate record images (varyings, FS-in records, FS-out colors)
    are immutable byte snapshots handed between stages; no stage reads
    another stage's live state.
  - A culled or fully clipped draw (`raster.records` empty) retires
    without constructing the FS/writeback runtimes.
  - When the FS declares `FrontFacing`, mixed facing across fragments is
    refused (`mixed front-facing exceeds native profile`) because the
    work-record ABI carries one front flag per batch, matching the
    `RasterShade` composite guard.
  - Owners pinned at enqueue: every fetch buffer owner plus the
    writeback destination owner, so leases cover the whole chain before
    the first advance.

- `corev_apu/apu/tools/vn_graphics_draw_replay.py` -- `operation()`
  converts one `DrawPlan` into a `DrawExec` (or `None` for an empty
  effective scissor):
  - `_push` requires complete vertex(1)/fragment(16) stage bindings and
    carries each stage's resolved descriptor operands
    (`vs_bindings`/`fs_bindings`) into the `DrawExec`; `UNIFORMCONST`
    image/sampler binds are admitted through the texture path.
  - `_scissor` intersects the recorded scissor with the render-pass area;
    an empty intersection yields no operation but still remembers all
    plan references and registers `plan.validate` as an admission guard.
  - `_color_targets` admits up to four active render-pass colour outputs
    (MRT): attachment 0 rides the primary `Writeback` fields and the
    rest become `Writeback.extras`, all written atomically per fragment
    under one shared late-z/bounds/logicOp gate; FS outputs must match the
    active location set exactly.
  - Direct, indexed and indirect (`vkCmdDrawIndirect`,
    `vkCmdDrawIndexedIndirect`) forms map onto `Fetch` operands;
    indirect argument bytes are read at execution time through the
    bounded `BufferOperand` extent.
  - Viewport floats are re-packed through `<6I`/`<6f` to preserve the
    recorded bit pattern; raster state maps `front_face`/`cull` into the
    raster masks.
  - `flat`/`nopersp` masks carry the scanner's `Flat`/`NoPerspective`
    decoration bits into the raster interpolator (provoking-vertex copy
    and screen-space weights respectively); `Centroid` stays refused.

`vn_transfer_replay.py` dispatches `vkCmdDraw`, `vkCmdDrawIndexed`,
`vkCmdDrawIndirect` and `vkCmdDrawIndexedIndirect` records through
`operation()` in recording order inside the active render pass; any
other unsupported record still fails admission atomically with no
partial commit.

## Budgets and faults

- Every stage keeps its own profile bounds (vertex count, batch size,
  `MAX_FRAGMENTS`, step/robust budgets, aggregate executor byte budget);
  `DrawExec.size` accounts for fetch bytes, code/push words, worst-case
  intermediate records and the destination span.
- Context retirement is checked inside each stage runtime; a fault or
  retirement mid-draw releases all pinned owners through the standard
  executor path.
- Draws outside an active render pass, with incompatible pipeline/pass
  state, stale generations, missing stage bindings, multi-output FS, or
  unbound/unsupported descriptor requirements refuse before any operation
  is published.

## Evidence

- `test_vn_graphics_drawexec.py` (3 tests): end-to-end triangle writes
  exact attachment texels, multi-triangle ordering and per-stage stats,
  admission refusals.
- `test_vn_graphics_draw_replay.py`: FragCoord-derived texels through the
  wire/replay path, empty effective scissor, draw outside render pass
  refusal, two-draw record order, descriptor-requiring shader refusal, and
  an end-to-end fragment-UBO draw (`vkCmdBindDescriptorSets` -> `vkCmdDraw`
  -> framebuffer texel equals the bound UBO value on covered pixels).
  Test-shader UBOs use Block-decorated struct form so they satisfy
  `vn_graphics_resources.validate`.
- Stale boundary tests updated (`test_vn_vertex_operands`,
  `test_vn_graphics_dynamic`, `test_vn_graphics_bindings`): state-only
  command buffers now admit an empty replay job instead of raising
  `unsupported replay`.
- Frozen native cohort `native-drawreplay-05` (cohort
  `native-execution.vah9c9ct`): 616 tests PASS in 18.032 s on
  `ovh_calltorch`, `sources_unchanged: true`;
  `PASS: host-native-model; no RTL/CTS qualification`.
- Buffer-descriptor draw increments, frozen cohort `native-gfxdrawubo-01`
  (cohort `native-execution.88gdzair`): 719 tests PASS in 21.162 s on
  `ovh_calltorch`, `sources_unchanged: true`;
  `PASS: host-native-model; no RTL/CTS qualification`.

## Not claimed

MSAA/multisample, PATCH_LIST/geometry/
tessellation topologies, sRGB/UNORM16+/float/INTEGER blend-logicOp-
writeMask formats (the ROP oracles are UNORM8-byte only), the
logicOp+blendEnable precedence combo, wide lines (`lineWidth`>1),
multi-viewport, instancing divisor>1, partial-quad helper-derivative
*values* (covered-neighbour approximation; real HW helper inputs are
undefined), in-model dynamic offsets, push-constant sharing across
stages beyond the per-stage words, ordering guarantees versus other
attachments or concurrent work, RTL/CTS/physical qualification, and any
capability advertisement.  `vkCmdDraw*` replay is admitted only inside
the bounded profile; stock capability gates remain closed pending
independent approval.
