# Bounded Native Graphics Shader Interfaces

GSys LibreCore now validates specialized VS/FS I/O declarations before native
pipeline allocation. This builds on immutable identity and fixed-state profiles,
not draw execution or complete shader/resource admission. Default GPU refusal,
diagnostic gates and zero Vulkan capsets remain unchanged.

## Declarations And Linking

The bounded profile requires one float32 vec4 Position output, standalone or in
a Position-only builtin block. VertexIndex/InstanceIndex scalar integer inputs
and fragment FragCoord/FrontFacing/HelperInvocation have explicit type checks.
Depth, dropped point/clip/cull builtins, compound location I/O and graphics
workgroup variables remain refused.

All declared I/O must occur in the selected entry list; duplicate entry IDs,
locations, builtins and builtin/location aliases fail closed. This is a
conservative declaration profile, not reachability analysis or full SPIR-V
validation. Broader builtin blocks need a separately justified increment.

Vertex input numeric classes match declared attribute formats. Missing vertex
format components may use the Vulkan default-component rule; this metadata
check does not implement vertex fetching. The format-class table covers the
native vertex whitelist.

VS-to-FS varyings require matching float32 scalar/vector shapes at each consumed
location. Fragment color declarations require floating types and active subpass
color locations. Integer/flat/complex interpolation and broader output behavior
are outside this profile. Unused vertex declarations remain metadata, not work.

Validation consumes existing specialized scan results rather than rescanning or
changing the shared RTL scanner. Typed interface snapshots retain no memory
operands, acquire no work leases and do not prove shader execution or writes.

## Evidence

462 frozen checks pass36.223s from
`~/.cache/librecore/apu/native-execution.ijf5qd64`;108 hashes unchanged and all
live/alias inputs match. Twelve new cases cover typed baseline/linking/vertex
formats, missing/mismatched varyings, undeclared attributes, numeric classes,
duplicate locations, Position shape, fragment color types/ranges, selected-entry
I/O membership, whitelist coverage and Position-only blocks.

The first run exposed an invalid block fixture: it decorated both the variable
and member as Position. Scanner metadata confirmed both decorations. Removing
the variable decoration repaired the fixture without relaxing the validator.
Refusals check fresh contexts, no pipeline, no module pins and no work leases.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=106 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Full shader/resources, vertex/index/attachment/dynamic operands, execution/fault/
retirement and broader graphics remain open. Wider images/sync/stock feedback,
RTL retained-unmap owner/alias/capacity and full capability/software/hardware/
CTS/formal/synthesis/physical/WSI gates remain independent.
