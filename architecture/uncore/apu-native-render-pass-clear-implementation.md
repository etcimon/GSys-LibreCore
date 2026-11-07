# Native Render-Pass Attachment Clears

GSys LibreCore now executes bounded render-pass attachment clears through the
ordered transfer replay path: both `VK_ATTACHMENT_LOAD_OP_CLEAR` color
attachments inside `vkCmdBeginRenderPass` and explicit `vkCmdClearAttachments`
commands. This is the first graphics execution slice: real memory writes for
color-attachment clears inside the recorded render-pass scope. Drawing, shader
execution, layout transitions, capability advertisement and hardware
qualification remain unadmitted; default GPU refusal and zero Vulkan capsets
are unchanged.

## Execution

`vn_render_pass_replay` consumes `vkCmdBeginRenderPass` and
`vkCmdEndRenderPass` executor records inside `TransferReplay`. Begin resolves
the recording-scoped `BeginPass` snapshot through `vn_render_pass_commands.
operand`, which revalidates recording epoch, render-pass/framebuffer identity,
attachment provenance and memory bindings, and returns generation-checked
`ColorAttachment` operands plus object references. References are remembered
for pinning and the operand validator is registered as an admission guard, so
handle reuse or attachment rebinding after recording fails before work is
enqueued.

For each color attachment whose render-pass loadOp is `CLEAR` and whose index
is covered by `clearValueCount`, the recorded four-word clear value is packed
by `img_clear_texel` using the attachment's pinned device format (UNORM, sRGB,
half/float and integer component rules, BGRA swap) and emitted as one `pattern`
transfer per render-area row at the attachment's 64-byte-aligned pitch. LOAD
and DONT_CARE attachments are skipped; depth/stencil clears remain refused at
capture. `vkCmdEndRenderPass` is consumed as a scope marker with no byte work,
matching the coherent storage model where layout transitions carry no physical
effect.

Pattern operations inherit the existing executor guarantees: per-operation
and aggregate byte budgets, texel-aligned offset/size checks, ordered
retirement, cancellation-safe lease release and sticky device-loss faults.
Clear rows are bounded by the render area validated against framebuffer and
attachment extents at capture; pitch padding between rows is never written.

`vkCmdClearAttachments` is captured only inside an active begin-pass scope. Its
packet is re-decoded from the wire words: per-element `aspectMask` must be the
color bit, `colorAttachment` must reference a used subpass color attachment
without duplicates, clear values are the four color words of each element's
blob, and each `VkClearRect` must have nonnegative origin, positive extent,
`baseArrayLayer` 0 and `layerCount` 1 (framebuffers are single-layer). At
replay each rect is intersected with the render area and skipped when empty;
ops emit in record order so sequential clears resolve deterministically.

## Boundaries

Only clear execution is admitted. Vertex/index fetch, draw plans, shader
stages, rasterization, ordered draw retirement, image synchronization beyond
the existing barrier profile, stock Mesa/Venus feedback and capset promotion
remain open. A command buffer containing any unsupported record — including
draws or dynamic state — still fails admission atomically before any clear is
published, so no partial render pass can commit.

## Evidence

569 frozen checks pass22.433s from
`~/.cache/librecore/apu/native-execution.gaxf5u6h`; all input hashes unchanged
and live/alias inputs match. Sixteen cases cover sub-rectangle and full clears,
pitch-padding preservation, pinned format conversion, sequential pass ordering,
multiple attachments, LOAD/DONT_CARE skips, compute-mode replay, atomic
refusal of unsupported in-pass commands, stale framebuffer and attachment
rebinding guards, explicit clear-attachment rects/targets/layers, render-area
clipping, sequential rect ordering and capture refusals. Two earlier refusal
tests were updated to assert the new clear-execution behavior.

Five-source MIT tier/header/ASCII/syntax/whitespace audit passes. This is
host-native-model evidence only: no RTL, CTS, hardware, stock-software,
PGO-throughput or capability qualification is claimed.
