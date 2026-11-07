# Bounded Native Render-Pass Commands

GSys LibreCore now captures begin/end-render-pass metadata and validates bounded
recording scopes. This does not execute clears, load/store operations or draws.
Default GPU refusal, diagnostic gates and zero Vulkan capsets remain unchanged.

## Identity And Scope

Begin snapshots retain canonical render-pass/framebuffer/device/command-buffer
identity, by-value rendering snapshots, render area and raw clear words.
Framebuffer compatibility compares retained values, not raw render-pass IDs.
The bounded profile also requires matching per-index attachment format/sample
tuples, one subpass and INLINE contents.

The original wire is decoded to validate contents and clear-array structure;
the reduced legacy record omits contents. Exact payload/array counts, color
word widths, chains, required CLEAR attachment indices and nonempty render areas
inside the framebuffer are checked. Clear words remain bit patterns interpreted
by attachment format, not numeric uint32-to-float conversions.

End tokens refer to their begin snapshot. Active scope is derived from typed
records in the current recording list, so reset needs no stale sidecar cleanup.
Nested begins, unmatched ends, open scopes at EndCommandBuffer and next-subpass
commands are refused. Existing legacy record/table ABI is unchanged.

Shared recording identity/validation is extracted from dynamic-state capture.
Operand resolution returns owned attachment spans and framebuffer/image/view/
memory/device/render-pass/command-buffer/pool references. Late validation covers
context retirement, generation reuse, recording reset, rendering identity and
attachment binding changes. No backing data is read/written and no work/object
leases are acquired.

Future replay must acquire references/backing leases transactionally, rerun
guards, apply load/clear/store and dynamic state in command order, and implement
fault-safe execution/retirement. These metadata checks do not publish GPU work.

## Evidence

499 frozen checks pass29.179s from
`~/.cache/librecore/apu/native-execution.rw6ycxrl`;114 hashes unchanged and all
live/alias inputs match. Sixteen new cases cover values/references, by-value
compatibility, generation reuse, rebinding, reset/rerecord, retirement, area/
contents/count/variant refusal, scope balancing, sequential tokens and replay
refusal. Negative subcases use fresh contexts.

The older no-replay fixture now supplies its required clear and closes its
scope. The depth-variant regression mutates the actual encoded union tag:
the pinned encoder always emits its default color tag and ignores other union
member kwargs. Neither decoder nor profile refusal was weakened.

Six-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=112 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Full shader/resources, live vertex/index fetch, dynamic/raster execution and
transactional fault/retirement remain open. Wider images/sync/stock feedback,
RTL retained-unmap owner/alias/capacity and full capability/software/hardware/
CTS/formal/synthesis/physical/WSI gates remain independent.
