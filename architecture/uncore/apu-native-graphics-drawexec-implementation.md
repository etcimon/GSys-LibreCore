# Native graphics draw execution and replay

Status: implemented, host-native-model evidence only.  No blending,
depth/stencil, logic-op, multi-attachment, helper-lane, non-triangle
topology or descriptor-binding draw is claimed or enabled.  Zero capsets
remain advertised; `vkCmdDraw*` admission is bounded to the profile below
and remains subject to the independent capability/CTS gates.

## Scope

Two layers complete the first executable graphics path:

- `corev_apu/apu/tools/vn_graphics_drawexec.py` -- `DrawExec`, a frozen
  executor operation chaining the five stage runtimes inside one job:
  `Fetch` (vertex/index live reads) -> `Shade` (VS waves) -> `Raster`
  (FS-in record generation) -> `FragmentShade` (FS waves) -> `Writeback`
  (single color attachment).  `DrawExecRuntime.advance` advances the
  current stage under the caller budget, constructs the next runtime when
  a stage retires, and publishes per-stage statistics on the job
  (`fetch_stats`, `shade_stats`, `raster_stats`, `fshade_stats`,
  `writeback_stats`, `drawexec_stats`).
  - Eager admission probes instantiate each stage profile before any work
    is published; descriptor-using shaders are refused at scan
    (`OpDecorate` Binding/DescriptorSet rows on interface variables).
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
    refuses any stage carrying descriptor bindings.
  - `_scissor` intersects the recorded scissor with the render-pass area;
    an empty intersection yields no operation but still remembers all
    plan references and registers `plan.validate` as an admission guard.
  - `_color_target` requires exactly one active render-pass color output
    matched by exactly one FS color location, resolved to its framebuffer
    attachment for owner/offset/pitch/format.
  - Direct, indexed and indirect (`vkCmdDrawIndirect`,
    `vkCmdDrawIndexedIndirect`) forms map onto `Fetch` operands;
    indirect argument bytes are read at execution time through the
    bounded `BufferOperand` extent.
  - Viewport floats are re-packed through `<6I`/`<6f` to preserve the
    recorded bit pattern; raster state maps `front_face`/`cull` into the
    raster masks.
  - `flat`/`nopersp` masks are zero because the shared SPIR-V scanner
    rejects `Flat`/`NoPerspective`/`Centroid` decorations at scan time --
    only smooth perspective varyings are admitted, so the masks are
    exact, not approximations.

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
  descriptor requirements refuse before any operation is published.

## Evidence

- `test_vn_graphics_drawexec.py` (3 tests): end-to-end triangle writes
  exact attachment texels, multi-triangle ordering and per-stage stats,
  admission refusals.
- `test_vn_graphics_draw_replay.py` (5 tests): FragCoord-derived texels
  through the wire/replay path, empty effective scissor, draw outside
  render pass refusal, two-draw record order, descriptor-requiring
  shader refusal.
- Stale boundary tests updated (`test_vn_vertex_operands`,
  `test_vn_graphics_dynamic`, `test_vn_graphics_bindings`): state-only
  command buffers now admit an empty replay job instead of raising
  `unsupported replay`.
- Frozen native cohort `native-drawreplay-05` (cohort
  `native-execution.vah9c9ct`): 616 tests PASS in 18.032 s on
  `ovh_calltorch`, `sources_unchanged: true`;
  `PASS: host-native-model; no RTL/CTS qualification`.

## Not claimed

Blending, depth/stencil, logic ops, MRT/multi-attachment, helper lanes,
non-triangle topology, flat/nopersp/centroid interpolation (scanner-
rejected), descriptor bindings in draws, push-constant sharing across
stages beyond the per-stage words, ordering guarantees versus other
attachments or concurrent work, RTL/CTS/physical qualification, and any
capability advertisement.  `vkCmdDraw*` replay is admitted only inside
the bounded profile; stock capability gates remain closed pending
independent approval.
