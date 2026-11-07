# Native Graphics Pipeline Identity

GSys LibreCore now retains immutable vertex/fragment pipeline identity on the
native diagnostic path. This is not semantic draw-state admission or a renderer.
Default GPU refusal, transfer-only shader refusal and zero Vulkan capsets remain.

## Stages And Provenance

Snapshots retain canonical VS/FS module generations, selected entries, specialized
code, original module words, pipeline-layout values and render-pass compatibility
values. Layout/render-pass destruction and raw-ID reuse do not redirect them.
The original wire packet is retained separately from the parked57-word legacy
state. Unkept wire fields are not assumed supported for execution.

Admission is bounded to one pipeline, VS plus FS, subpass0, no cache/base
derivative, nonzero flags/chains or custom allocator. Stage order is normalized
only for legacy allocation; original wire order/provenance remain immutable.
Specialization uses exact per-stage pointer/blob ranges and the existing strict
scalar parser/folder without weakening its trailing-word checks.

The resolver validates context/device, parked state, canonical module handles,
parked extents, pins and original words. Destroyed modules remain pinned for the
pipeline lifetime; reused wire IDs cannot substitute new modules. Compute
resolution still rejects graphics pipelines. Returned references do not publish
draw work.

## Evidence

442 frozen checks pass37.769s from
`~/.cache/librecore/apu/native-execution.90lhm29b`;104 hashes unchanged and all
live/alias inputs match. Ten new cases cover selected stages, reverse order,
module/layout/render-pass reuse, missing entry/wrong stage, compute refusal,
state/module tampering and independent VS/FS specialization.

The first run exposed an identity-parser error: graphics entry names arrive as
BLOB, not only PTR. Focused decoder traces confirmed correct module execution
models/names. Accepting both name encodings repaired the parser without changing
the tests' semantic expectations.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=102 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Full graphics state/interface, vertex/attachment operands, execution, fault and
retirement integration remain before draw admission. Wider images/sync/stock
feedback, RTL retained-unmap owner/alias/capacity and full capability/software/
hardware/CTS/formal/synthesis/physical/WSI qualification remain independent.

Bounded fixed-state validation now follows
`apu-native-graphics-fixed-state-implementation.md`; full draw admission remains
separate from both identity and that limited profile.
