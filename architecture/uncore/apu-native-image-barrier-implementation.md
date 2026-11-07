# Native Coherent Image Barriers

GSys LibreCore's opt-in native transfer profile now captures and replays bounded
color-image barriers. This is host-model execution, not hardware/profile
admission. Default GPU refusal and zero Vulkan capsets remain unchanged.

## Capture, Validation And Retirement

- Add image-barrier keep fields only to the in-memory native decoder profile.
  The pinned profile/command files and RTL tables remain unchanged.
- Capture at most16 image barriers, exact declared/payload counts and no
  extension chains. Convert every raw image ID to its canonical generation at
  recording time, including nonfinal array elements, so object-ID reuse cannot
  redirect a previously recorded barrier.
- The shared recorder now preserves barrier payloads when supplied; the default
  profile supplies none. Existing legacy wire/reply IDs, roles, kinds and slot
  layouts remain checked by the native-extension regression.
- Validate transfer/host/top/bottom/all-command stages, transfer/host/memory
  access masks, color subresource ranges, explicit or REMAINING mip/layer
  counts, allowed layout enums and IGNORED queue-family ownership.
- Reject buffer/mixed-memory scopes, shader/attachment access/layouts,
  ownership transfers, dependency flags and unsupported image types/formats.
  Resolve and retain image/parent and backing generations before execution.
- Typed zero-byte barrier operations retain backing under the shared operation
  budget and executor leases, without hiding a copy or discarding byte work.
  In this linear coherent transfer model GENERAL/transfer layouts share the
  same physical storage: prior copies complete in order and no cache/format
  conversion is needed. This is not a logical old-layout validation layer.

## Evidence

220 frozen checks pass in13.371s from
`~/.cache/librecore/apu/native-execution.aahm34cy`; all78 hashes remain unchanged
and live inputs match. Ten new cases cover transition/upload/readback order,
barrier-only leases/no writes, generation reuse, unsupported scopes, array
capture, default-profile isolation, count mismatch, capture bounds and rejection
of a malformed barrier operation carrying byte work.

Nine-source MIT tier/header/syntax/whitespace audit passes. New code is ASCII;
existing Unicode comments in the golden model are preserved. Native/default-
PGO presence checks pass without install/build/training. Strict warning/error
receipts and fail-closed timeouts remain enabled. Host time is not simulator
throughput, RTL/CTS evidence or stock-software qualification.

## Review And Remaining Work

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset, SRAM/
DFT/PMU or timing-cone change. Pinned hardware tables, upstream notices, link
sets and PGO policy are untouched; no spec-index or capability promotion.
Core/Storamic work is preserved and changes remain uncommitted.

Still open: clears/blits/resolves/depth/3D and broader image operations; shader
execution and full barrier/synchronization semantics; stock execution-error/
feedback retirement; RTL unmap retention/capacity/alias reconciliation. Truthful
capset admission and software/hardware/CTS/aggregate/formal/synthesis/physical/
WSI/timing/area/power/silicon qualification remain separate gates.

Color-clear follow-up is now implemented in the native host profile under
`apu-native-image-clear-implementation.md`; the other gates remain open.

## Graphics-Scope Barrier Follow-Up (native-gfxbarriers-02)

The non-compute barrier profile now admits the bounded graphics stage/access
surface needed to order draw execution against transfers and shader reads:

- Stage mask gains vertex-input/vertex-shader/fragment-shader/early+late
  fragment/color-attachment-output draw stages (0x78E) on top of the existing
  transfer/host/top/bottom/all-commands mask; tessellation, geometry, compute
  and callback stages remain refused outside the compute profile.
- Access mask gains INDIRECT_COMMAND_READ, INDEX_READ, VERTEX_ATTRIBUTE_READ,
  UNIFORM_READ, SHADER_READ/WRITE, COLOR_ATTACHMENT_READ/WRITE; depth/stencil
  attachment and input-attachment accesses remain refused.
- Stage/access compatibility is now per-profile: shader accesses pair with
  compute/fragment/vertex/all-graphics/all-commands stages, vertex/index/
  attribute reads pair with vertex-input+vertex-shader, uniform reads with
  shader stages, color-attachment accesses with fragment/early/late/
  color-attachment-output, indirect-command reads with draw-indirect/
  all-commands, transfer/host/memory accesses keep their prior pairings.
- Image layout whitelist gains COLOR_ATTACHMENT_OPTIMAL (2) and
  SHADER_READ_ONLY_OPTIMAL (5) for the graphics profile only; the compute
  profile is unchanged.
- Layout/access compatibility now covers color-attachment accesses (layout
  GENERAL or COLOR_ATTACHMENT_OPTIMAL only) and rejects color-attachment
  accesses inside SHADER_READ_ONLY_OPTIMAL; shader read/write layout rules are
  unchanged.
- Image usage gates now require COLOR_ATTACHMENT usage for color-attachment
  accesses or COLOR_ATTACHMENT_OPTIMAL layout, and SAMPLED/_STORAGE usage for
  SHADER_READ_ONLY_OPTIMAL, matching the existing shader-access usage rules.
- Typed zero-byte barrier operations still retain backing until ordered
  retirement; memory barriers remain scope-validation-only and emit no byte
  work. Queue-family ownership transfers, dependency flags, multisample and
  every unlisted stage/access/layout stay refused atomically before pins.

Two stale refusal fixtures were updated where the broadened profile now
legitimately admits the transition: a transfer-only image (usage=3) still
refuses shader access and read-only layout, and INDIRECT_COMMAND_READ now
pairs with DRAW_INDIRECT under graphics while a fragment-only stage refuses.
Seven new graphics-barrier cases cover draw-to-transfer ordering, attachment
layout bracketing, sampled read-only layout, vertex/uniform scopes and atomic
refusals. 623 frozen checks pass in 17.956s from remote cohort
native-gfxbarriers-02 (native-execution.s26wbxln); all 137 hashes remain
unchanged. Seven-source MIT tier/header/ASCII/LF/whitespace/syntax audit
passes. Host-model evidence only: no RTL/config/capability change, zero
capsets, draws beyond the bounded profile and stock feedback remain open.

## Per-Image Layout Transition Tracking (native-layouttrack-01)

Image barriers previously validated stage/access/layout compatibility but
never tracked per-image layout state: `oldLayout` was unchecked against the
image's real state and `newLayout` was not recorded. This increment adds
truthful image-layout tracking across barriers, transfer commands and
render passes:

- `vn_golden.py` seeds `entry['layout']` from the wire `initialLayout`
  (`VkImageCreateInfo` imm[13]) at `vkCreateImage`, validated against the
  coherent layout universe {UNDEFINED, GENERAL, COLOR_ATTACHMENT_OPTIMAL,
  SHADER_READ_ONLY_OPTIMAL, TRANSFER_SRC_OPTIMAL, TRANSFER_DST_OPTIMAL,
  PRESENT}; out-of-profile values refuse with VK_ERR_FEATURE before alloc.
- `vn_image_barriers.py` replay now requires each image barrier's
  `oldLayout` to match the tracked layout unless it is UNDEFINED (the
  spec's discard transition, admitted from any state); a valid barrier
  publishes `newLayout` as the image's current layout. Per-image
  granularity: a barrier on any subresource range transitions the whole
  tracked image (subresource-level state is not modelled).
- `vn_image_replay.py` copy/clear commands now require the command's
  `imageLayout`/`srcImageLayout`/`dstImageLayout` operand to equal the
  tracked current layout — the same check validation layers perform —
  for vkCmdCopyImage (both images independently), vkCmdCopyBufferToImage,
  vkCmdCopyImageToBuffer and vkCmdClearColorImage. Copies and clears do
  not transition layout.
- `vn_render_pass_replay.py` performs the implicit render-pass
  transitions at replay: `vkCmdBeginRenderPass` requires every attachment
  image to sit in the render pass's `initialLayout` (UNDEFINED accepts
  any prior state as a discard) and publishes each color-referenced
  attachment's subpass layout; `vkCmdEndRenderPass` re-validates the
  subpass layout (or the unchanged initial layout for unreferenced
  attachments) and publishes `finalLayout`. Layouts come from the
  BeginRenderPass render-pass object, not the framebuffer's compatible
  render pass, matching spec ownership of the transition parameters.
  All attachments validate before any publish so a duplicated attachment
  cannot validate against its own update.

Fixtures that copied or cleared images now declare the matching
`initialLayout` at create (spec-legal) or establish the layout through a
prior barrier; barrier/event fixtures that assumed no persistent state
were corrected to chain `oldLayout`/`newLayout` explicitly. New coverage:
oldLayout mismatch refusal, UNDEFINED discard admission, layout
persistence across recorded submits, copy/clear layout mismatch and
create-time initialLayout seeding/refusal, and render-pass
initial/subpass/final publication plus initialLayout mismatch refusal.

Known remaining gaps: descriptor `VkDescriptorImageInfo.imageLayout` is
still not consulted at update or draw time; subresource-level layout
state is not modelled; `vkGetImageSubresourceLayout` answers are not
layout-aware; queue-family ownership transfers remain refused. Host-model
evidence only: no RTL/config/capability change, zero capsets.

Evidence: 697 local unittest checks pass; remote cohort
`native-layouttrack-01` (`native-execution.rhjh1105`) reports 682 frozen
checks PASS in 19.6s with `sources_unchanged: true` (+7 over the
native-lostdepth-01 cohort — the new layout cases).
