# Native Rendering Object Identity

GSys LibreCore now retains bounded render-pass values and generation-checked
framebuffer attachment identity. This is an upstream dependency of native
graphics pipeline/draw admission, not a renderer. Draw replay remains refused;
default GPU refusal, diagnostic compute opt-ins and zero Vulkan capsets stay.

## Values And Ownership

Native creation validates a single color subpass, up to four supported color
attachments, single samples and bounded load/store/layout enums. Input,
resolve, depth/stencil, preserve and dependency structures, nonzero flags/chains
and custom allocators remain refused. The full admitted attachment values and
color references are retained, not only the legacy reduced keep words.

Render-pass compatibility within this profile compares referenced formats and
sample counts under the same context/device, not raw object IDs or load/store/
layout values. Unused references remain distinct from used references.

Framebuffers retain the render-pass snapshot by value after original handle
destruction/reuse. Attachments capture canonical view/image/memory generations,
view/image metadata and memory binding. Creation checks color usage, format,
identity swizzle, single-mip/layer 2D views, dimensions and logical allocation
bounds. Memory rebinding or view/image ID reuse cannot redirect an operand.

The operand resolver returns bounded owned attachment spans, references and a
validation callback. It checks current context/device/generations/provenance/
backing but neither pins objects nor publishes work. A future draw executor
must acquire transactional object/backing leases and rerun guards before use.

No per-subresource layout tracker, attachment load/store execution, render-pass
automatic transitions, shader/attachment interface validation or draw semantics
are implemented by this identity increment.

## Evidence

432 frozen checks pass14.597s from
`~/.cache/librecore/apu/native-execution.zpw21u8k`;102 hashes unchanged and all
live/alias inputs match. Fifteen new cases cover values/compatibility,
render-pass/framebuffer/view/image reuse, rebinding, post-resolution mutation,
smaller extents, four attachments, unsupported counts/formats/scopes, color
usage and explicit begin-render-pass replay refusal.

Initial testing corrected a stale-generation exception expectation, not the
implementation. Creation-refusal subcases use fresh contexts because a failed
stream intentionally faults its context. The four-attachment fixture initially
placed its last span beyond the5001-byte logical memory allocation; diagnostics
confirmed only that binding was absent. Moving the span inside bounds fixed the
test without weakening binding or framebuffer checks.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=100 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Graphics stage/state snapshots, attachment execution, broader images/sync/stock
feedback remain open. RTL retained-unmap owner/alias/capacity and full capability/
software/hardware/CTS/formal/synthesis/physical/WSI qualification remain independent.
