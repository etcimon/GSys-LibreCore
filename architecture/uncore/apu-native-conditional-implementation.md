# Native Conditional-Rendering Replay

GSys LibreCore's opt-in native profile now replays bounded
`vkCmdBeginConditionalRenderingEXT`/`vkCmdEndConditionalRenderingEXT`
records as ordered executor operations that gate draw execution on a
32-bit predicate word read from a pinned `VkBuffer`. This is host-model
execution, not hardware/profile admission. Default GPU refusal and zero
Vulkan capsets remain unchanged.

## Semantics

- `vkCmdBeginConditionalRenderingEXT` validates the record shape
  (`imm[0]`=flags, `imm[1:3]`=offset u64, `handle[0]`=buffer; spare
  immediates/handles/payload refuse), resolves the buffer canonically
  through `remember()` (generation-qualified, device-checked, pinned for
  the job's lifetime), requires `VK_BUFFER_USAGE_CONDITIONAL_RENDERING_BIT`
  (0x200) in `native_usage`, admits only flag bit 0
  (`VK_CONDITIONAL_RENDERING_INVERTED_BIT_NV`), requires the predicate
  offset to be 4-aligned with at least 32 bits inside the buffer extent,
  and refuses nesting (`images.cond` already open) before emitting one
  `CondBegin` op.
- `vkCmdEndConditionalRenderingEXT` requires an empty record and an
  open region, clears the replay-side marker and emits one `CondEnd`
  op. End-without-begin, nested begin and a region left open at submit
  end all refuse atomically at record time.
- `CondBeginRuntime` validates the predicate address at enqueue through
  the same `_extent` path as `Transfer` (owner identity, live entry,
  bounds, aperture range), pins the buffer owner for the job's lifetime,
  and at its stream position publishes `(absolute predicate address,
  inverted)` into `executor.cond[context]`.
  `CondEndRuntime` removes the entry at its stream position, so the
  gate exists exactly between the two ordered ops.
- `DrawExecRuntime.advance` re-reads the 32-bit predicate word through
  the memory aperture once per draw command, at the draw's position in
  the stream (the spec's per-command model): the draw executes iff
  `(word != 0) != inverted`. A failing predicate marks the runtime done
  with zero published stage work - no fetch/vertex/raster/fragment/
  writeback records, no framebuffer mutation, no fabricated fragment
  count. The check runs before the stage chain, so gated draws consume
  their operation slot but publish nothing.
- Because gating lives inside `DrawExecRuntime`, every admitted draw
  spelling (`vkCmdDraw`, `vkCmdDrawIndexed`, indirect variants that
  lower to `DrawExec`) is gated uniformly, and the predicate observes
  ordered buffer updates: an earlier `vkCmdUpdateBuffer`/`vkCmdCopy*`
  retires before the draw's turn and its bytes are visible to the
  re-read.
- Conditional regions may span command buffers inside one submit batch
  (the `images.cond` marker and `executor.cond` entry both live on the
  shared submit state), matching the occlusion-query pairing model.
- Commands the bounded profile cannot gate truthfully refuse while a
  region is open rather than silently executing: `vkCmdClearAttachments`,
  `vkCmdDispatch` and `vkCmdDispatchIndirect` raise
  `ValueError('conditional rendering does not gate ...')` at record
  time. Compute `vkCmdDispatch*` is additionally outside the graphics
  profile's conditional surface.

## Evidence

662 frozen checks pass in 17.9s from remote cohort `native-condrender-01`
(cohort `native-execution.cxlrj2vt`, sources unchanged); all input hashes
remain unchanged and `sources_unchanged` is true. Five new cases in
`test_vn_graphics_draw_replay.py` cover: predicate nonzero renders the
draw end-to-end (texel equality plus `cond_stats` begin/end records),
predicate zero discards the draw (zero raster records, attachment keeps
the pass clear), inverted flag renders on a zero word, per-draw
predicate re-read across an ordered `vkCmdUpdateBuffer` (first draw
executes, second is discarded - proving stream-position evaluation, not
a latched value), and pairing/operand refusals (end-without-begin,
nested begin, unclosed at submit end, missing
`VK_BUFFER_USAGE_CONDITIONAL_RENDERING_BIT`, misaligned and
out-of-extent offsets). Earlier cohorts remain green: 657
(`native-occquery-01`) plus this increment's decoder regeneration to
155 commands, 0 unfit.

## Gated clears and dispatches (follow-up)

The extension's gated-command set is draws, `vkCmdClearAttachments`,
`vkCmdDispatch` and `vkCmdDispatchIndirect`; copies, blits and other
transfer commands stay ungated. The bounded profile now admits all
three remaining gated commands:

- `vkCmdClearAttachments` rows are emitted as `Transfer('pattern',
  ..., conditional=True)` operations (`vn_render_pass_replay._emit`
  `gated=True` only for the clear-attachments path; loadOp clears and
  every other transfer keep `conditional=False`). At execution the
  transfer path samples the open region's predicate once per operation
  and caches the decision on the job (`TransferJob.gates` keyed by
  operation index), so a failing predicate advances `job.position` to
  `op.size` with zero aperture writes while ordered stream position is
  preserved. All rows of one command evaluate identically because no
  other command's ops interleave inside the emission.
- `vkCmdDispatch`/`vkCmdDispatchIndirect` compile to `Compute`
  operations executed by `ShaderRuntime`. Its `advance()` samples the
  predicate once at the first turn (`_gate` latch), before the indirect
  argument fetch or any shader step; a failing predicate marks the
  runtime done with zero published work. Direct and indirect dispatches
  share the gate.
- The replay-time refusal for the three names inside an open region
  (`images.cond` check in `vn_transfer_replay`) is removed; pairing,
  operand and submit-end checks are unchanged.

Evidence: `test_vn_compute_replay.py` gains predicate-zero (no work,
`word()==0`) and predicate-nonzero (`word()==5`) dispatch cases;
`test_vn_render_pass_clear.py` gains gated/ungated clear-attachments
cases asserting patterned memory survives a zero predicate and the
clear texel lands on a nonzero one. 146 adjacent tests pass locally;
remote frozen cohort `native-condgate-01`
(`native-execution.93obyz8i`) reports 672 tests PASS in 18.8s with
`sources_unchanged: true` (+4 over the 668 statistics cohort).

## Boundaries

- Copies, blits, fills and updates are not gated, matching the
  extension; only draws, attachment clears and dispatches consult the
  predicate.
- The predicate is a single 32-bit word per begin; `offset` is a byte
  offset into the bound buffer (VUID-aligned), not a word index.
- `VK_CONDITIONAL_RENDERING_INVERTED_BIT_NV` is the only admitted flag;
  the buffer must carry `VK_BUFFER_USAGE_CONDITIONAL_RENDERING_BIT`.
- Nested or overlapping regions, regions spanning submit batches, and
  predicate buffers bound to images or host-visible-only memory remain
  outside the profile.
- Pipeline-statistics query pools (mask `0x87` admitted),
  transform-feedback indexed queries (`index != 0`), `vkWaitForEvents`
  (absent from the pinned vk.xml) and all capability/CTS/physical gates
  remain open; zero capsets, host-model evidence only, uncommitted.
