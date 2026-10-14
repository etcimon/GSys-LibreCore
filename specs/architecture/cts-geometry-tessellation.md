# `geometry` (199) and `tessellation` (1,103) — geometry shaders, tessellation control/evaluation

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/geometry.txt`,
`vk-default/tessellation.txt`; tests in `external/vulkancts/modules/vulkan/geometry/
vktGeometry*.cpp`, `tessellation/vktTessellation*.cpp`. Owner W8 (plan: "primitive
shader stages combining vertex, geometry and tessellation" 0.84; "hardware tessellation
with adaptive displacement" 0.74). Both features are optional in Vulkan (geometryShader,
tessellationShader); Zink GL 3.2/4.0 require them; UE SM5 uses neither by default (it
requires geometry shaders only for some features) — W1 decides when. Gate CTS-4.

## Inventory

| group | cases | structure |
|---|---:|---|
| `geometry` | 199 | `layered` 100 (render to layers/cube/3D via gl_Layer), `input` 28 (all input topologies incl. adjacency), `instanced` 24 (invocations), `emit` 23 (EmitVertex/EndPrimitive patterns, max vertices), `basic` 14, `builtin_variable` 5, `varying` 5 |
| `tessellation` | 1103 | `tess_io` 568 (per-vertex/per-patch I/O), `invariance` 192 (outer/inner edge invariance rules, primitive set, tessellation coordinate), `misc_draw` 107, `user_defined_io` 54, `winding` 48, `primitive_discard` 44, `shader_input_output` 28, `geometry_interaction` 18, `tesscoord` 18, `common_edge` 12, `limits` 8, `fractional_spacing` 4, `matrix_multiplication` 2 |

## Architectural logic

```text
LOGIC GS-L1 · Geometry shaders
  CLAIM       A geometry stage receives whole primitives (points/lines/triangles with
              adjacency) with per-vertex inputs arrayed, emits up to maxGeometryOutput
              Vertices with EmitVertex/EndPrimitive into points/line strips/triangle
              strips, with instancing (invocations), gl_PrimitiveIDIn/Layer/
              ViewportIndex outputs (layered rendering to array/cube/3D attachments),
              and all built-ins; geometry streams (transform feedback) optional.
  SOURCE      geometry.{basic,input,emit,instanced,layered,builtin_variable,varying}.*.
  MECHANISM   A GS wave consumes assembled primitives (the rast primitive assembler's
              output records) and produces a variable-length output stream into a
              scratch ring that the rast setup consumes instead of VS-out records —
              the same "meshlet" output path MESH-L1 needs (design once: per-primitive
              record + variable vertex lists); gl_Layer → the attachment layer offset
              (MV-L1's layers).
  REQUIRES    W3 wave engine handles variable output counts (budgeted ring space per
              invocation); layered attachments.
  FORBIDS     Expanding geometry on the host (not stock-visible).
  CHECK       geometry.basic.*, emit.*, input.* (CTS-4).
  COST        the output ring and a second setup source; W8.
  FEEDS       MESH-L1, MV-L2, transform feedback; CTS-4.
  STATUS      not-run (NotSupported)

LOGIC TS-L1 · Tessellation control/evaluation
  CLAIM       Patches of up to maxTessellationPatchSize control points, TCS per-vertex/
              per-patch outputs and barrier semantics, the fixed-function tessellator
              generating triangles/quads/isolines with equal/fractional-even/
              fractional-odd spacing, CW/CCW winding, point mode, primitive discard
              (outer level ≤ 0 / NaN), the invariance rules (same outer level → same
              edge vertices across patches; symmetric subdivision), gl_TessCoord/
              TessLevelOuter/Inner builtins, TES outputs to the raster path (or GS).
  SOURCE      tessellation.{tess_io,invariance,misc_draw,user_defined_io,winding,
              primitive_discard,shader_input_output,geometry_interaction,tesscoord,
              common_edge,limits,fractional_spacing,matrix_multiplication}.*.
  MECHANISM   TCS = a wave per patch (control points as lanes, barrier = patch
              rendezvous); the tessellator = a fixed-function generator of (u,v) domain
              points and connectivity per the spec's subdivision algorithm (exact
              integer/fixed-point rules for invariance); TES = a wave per generated
              vertex batch; the output feeds setup like VS-out records. Adaptive
              displacement (plan) = TES sampling a height texture — nothing extra in
              hardware.
  REQUIRES    Patch topology in input assembly; the tessellator's invariance-exact
              arithmetic (the CTS checks bit-exact symmetric edges).
  FORBIDS     A tessellator whose edge vertices depend on patch orientation (breaks
              common_edge/invariance).
  CHECK       tessellation.invariance.*, tesscoord.*, tess_io.* (CTS-4).
  COST        the generator (small but intricate) + two more wave kinds.
  FEEDS       W8; Zink GL 4.0; CTS-4.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION GT-X1 · Features not advertised
  CONDITION   geometryShader / tessellationShader false (today).
  RESULT      NotSupported (all 1,302 cases).
  TRUTH       profile; both optional in Vulkan 1.x — a release decision (Zink levels),
              not a conformance blocker.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Advertising either with a host-side expansion.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| GT-H1 Shared variable-output path | MESH-L1 design | precondition | one output-ring + per-primitive record format for GS/mesh | — |
| GT-H2 Tessellator invariance first | TS-L1 | high | the generator alone against the CTS's reference algorithm (vktTessellationUtil) | — |

## Performance / area / scalability

Both stages multiply primitive work; the plan's "combined primitive stage" is about
scheduling them on the same wave engine with the same output path. Knobs: output ring
bytes per workgroup, tessellator throughput (domain points/clk). Correctness-preserving:
primitive order out of GS/TES is defined (stream order) and must be kept into setup.
