# Bounded Native Dynamic Viewport And Scissor

GSys LibreCore now retains immutable native viewport/scissor command values with
command-buffer recording lifetime guards. This is recording metadata, not raster
state execution or draw replay. Default GPU refusal, diagnostic gates and zero
Vulkan capsets remain unchanged.

## Values And Lifetime

One viewport/scissor at first0 is admitted with exact six/four-word payloads.
Full first/count values are checked before legacy truncation. Viewports preserve
original float32 words after finite-value, positive dimension, pinned dimension/
coordinate-edge and depth-range checks. Reverse depth and negative origins
within the pinned bounds are allowed; negative height remains outside this
bounded profile.

Scissors retain nonnegative rectangles within pinned framebuffer dimensions;
zero extents are permitted. This does not claim the broader Vulkan scissor
range or static/multiple viewport support.

Snapshots retain context/device/command-buffer generations and the recording
list identity. Validation rejects retired/reused buffers, unavailable parents
and command-buffer reset even when the buffer handle itself survives. Later
sets cannot mutate prior payloads. The recording-list reference is an opaque
lifetime identity, not mutable viewport/scissor data.

No object/backing work leases or work publication are added. Future replay must
hold command-buffer/device leases, validate the recording and apply dynamic
state in Vulkan command order. Render-pass state, clipping and actual drawing
remain separate.

## Evidence

483 frozen checks pass21.050s from
`~/.cache/librecore/apu/native-execution.bzs01cqi`;112 hashes unchanged and all
live/alias inputs match. Nine new cases cover exact/immutable payloads, empty
scissor, negative origins/reverse depth, nonfinite/dimension/depth/range refusals,
full first/count checks, reset epochs and explicit replay refusal.
Negative subcases use fresh contexts and publish no work.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=110 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Full shader/resources, render-pass/attachment state, transactional execution/
fault/retirement and broader graphics remain open. Wider images/sync/stock
feedback, RTL retained-unmap owner/alias/capacity and full capability/software/
hardware/CTS/formal/synthesis/physical/WSI gates remain independent.
