# `rasterization` — primitives, fill rules, culling, provoking vertex, depth bias, conservative, tile image (15,079 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/rasterization.txt`; tests in
`external/vulkancts/modules/vulkan/rasterization/vktRasterizationTests.cpp` (+ order attachment
access, tile image, depth bias control files). Owner W4 (rast, G3c). Gate CTS-2 for the core
families; CTS-3 for the multisample variants; CTS-4 for the EXT families.

## Inventory (`cts_ledger.py tree --group rasterization --depth 2`)

| `dEQP-VK.rasterization.` | cases | what |
|---|---:|---|
| `depth_bias_control` | 8100 | VK_EXT_depth_bias_control (representation/exact) |
| `shader_tile_image` | 5498 | VK_EXT_shader_tile_image |
| `conservative` | 343 | VK_EXT_conservative_rasterization |
| `rasterization_order_attachment_access` | 280 | VK_EXT_rasterization_order_attachment_access |
| `primitives` + `primitives_multisample_{2,4,8,16,32,64}_bit` | 219 + 6×54 | triangles/strips/fans, lines/strips (incl. wide), points (incl. large), with MSAA variants |
| `provoking_vertex` | 63 | first/last provoking vertex (EXT) incl. transform feedback |
| `culling` | 43 | cull modes × front face × topologies |
| `interpolation` + `interpolation_multisample_*` | 30 + 6×7 | basic interpolation / projected / flat per topology |
| `primitive_size` | 26 | point sizes / line widths |
| `frag_side_effects` | 20 | fragment side effects under culling/discard/early tests |
| `flatshading` | 15 | flat interpolation per topology |
| `depth_bias` | 13 | depth bias with depth formats |
| `discard` | 12 | rasterizer discard |
| `polygon_as_large_points` | 10 | polygon mode point with large points |
| `fill_rules` + `fill_rules_multisample_*` | 5 + 6×5 | top-left fill rule, no double-hit on shared edges, clipped/projected |
| `line_continuity`, `maintenance5`, (`line_stipple` in primitives) | 2, 4 | |
| **total** | 15079 | |

## Architectural logic

```text
LOGIC RAST-L1 · Points and lines (all strip/list forms), with the Bresenham/rectangle rules
  CLAIM       Point lists render as axis-aligned squares of PointSize (1.0 without
              largePoints; pointSizeRange otherwise) centered on the vertex; lines render
              per the Bresenham or rectangular rule the device declares (strict/non-
              strict lines property), width 1 (wideLines optional), diamond-exit rule for
              Bresenham, line strips, line adjacency topologies with geometry shaders,
              line stipple (EXT/1.4); polygon mode LINE/POINT (fillModeNonSolid optional
              — Zink needs it); interpolation along lines and gl_PointCoord on points.
  SOURCE      rasterization.primitives.{points,lines,line_strip,lines_wide,
              line_strip_wide,triangles,…}, primitive_size.*, polygon_as_large_points.*,
              line_continuity.*, interpolation.*, flatshading.*;
              vktRasterizationTests.cpp (the CTS's own reference rasterizer with
              tolerances for lines).
  MECHANISM   rast has triangles only. Add: point setup (a quad of two triangles sized
              PointSize at the vertex, with PointCoord = position inside the square),
              line setup as the Vulkan Bresenham definition (the diamond-exit test on
              pixel centers, major-axis stepping) producing coverage directly without
              the triangle edge functions — or the rectangle rule with width 1 (both
              are conformant; declare `strictLines` accordingly); wide lines/points by
              the same rules; polygon modes by rasterizing each triangle's edges/vertices
              as lines/points.
  REQUIRES    Topology decode in the primitive assembler (lists/strips with restart);
              PointSize from the VS (builtin 1 — dropped today; must be kept when
              topology is points); the profile's `strictLines`, `pointSizeRange`,
              `lineWidthRange`, `pointSizeGranularity`, `lineWidthGranularity` truthful.
  FORBIDS     Rendering lines as thin triangles (fails the fill-rule/diamond tests);
              declaring strictLines while implementing the rectangle rule.
  CHECK       primitives.points, primitives.lines, primitives.line_strip,
              primitive_size.points.*, flatshading.* (CTS-2); engine: Bresenham reference
              in Python for a set of lines (the CTS's own `rr` rasterizer is the arbiter).
  COST        a line stepper and a point expander next to the triangle setup; small.
  FEEDS       DRAW-L1, CLIP-L1 (point/line clipping), GLSL-L4 (PointCoord); CTS-2.
  STATUS      not-run (points/lines → UNSUPPORTED today)

LOGIC RAST-L2 · Fill rules, culling, provoking vertex, rasterizer discard, side effects
  CLAIM       Top-left fill rule with no double coverage on shared edges (also under
              MSAA and after clipping/projection); cull front/back/both with CW/CCW front
              face (area sign in framebuffer space with Vulkan's y-down); provoking
              vertex first by default (last with EXT_provoking_vertex) for flat
              interpolation and transform feedback; rasterizerDiscardEnable discards all
              primitives but keeps pre-raster side effects (vertex SSBO writes with
              vertexPipelineStoresAndAtomics); fragment side effects (atomics) happen
              only for rasterized, non-culled fragments (frag_side_effects).
  SOURCE      rasterization.fill_rules*, culling.*, provoking_vertex.*, discard.*,
              frag_side_effects.*.
  MECHANISM   G1b top-left rule and cull; discard = skip setup after the VS batch (VS
              side effects still occur — the VS batch must run even when discard is on,
              if the module has side effects; it does today since VS waves run first);
              provoking vertex = which vertex supplies flat values (DRAW-L3); fill-rule
              correctness after clipping depends on the clipper producing consistent
              fixed-point coordinates for shared edges (G2b fan triangulation — verify
              shared-edge consistency between the two fans of adjacent clipped
              triangles: both must snap identically).
  REQUIRES    Fixed-point snapping (16.8) consistent across primitives (same vertex →
              same snapped position); multisample fill rules per sample.
  FORBIDS     Per-primitive epsilon fudges that break the shared-edge guarantee.
  CHECK       fill_rules.* (basic_quad, clipped_full, clipped_partial, projected) (CTS-2);
              culling.* ; frag_side_effects.*.
  COST        none new.
  FEEDS       FO-L1; CTS-2.
  STATUS      not-run

LOGIC RAST-L3 · Depth bias (core) and depth bias control (EXT)
  CLAIM       depthBiasConstantFactor × r + depthBiasSlopeFactor × m (m = max depth
              slope of the primitive, r = the format's minimum resolvable difference —
              2⁻²³·… for float, 2⁻ⁿ for UNORM), clamped by depthBiasClamp (feature) —
              applied to the interpolated depth before the depth test; EXT_depth_bias_
              control adds explicit representations (least/float/exact).
  SOURCE      rasterization.depth_bias.* (13), depth_bias_control.* (8100, EXT),
              draw.*.depth_bias (DRAW-L2), depth.bias_*.
  MECHANISM   setup computes m from the plane equation (|dz/dx|, |dz/dy| max); r per
              attachment format; two FMAs per fragment; clamp.
  REQUIRES    DRAW-L2 state plumbing (static + dynamic bias); depthBiasClamp feature only
              with the clamp term.
  FORBIDS     Applying bias to shader-written depth.
  CHECK       depth_bias.* (CTS-2); depth_bias_control.* NotSupported until the EXT.
  COST        setup slope math (already have the plane equations).
  FEEDS       DRAW-L2; CTS-2.
  STATUS      not-run

LOGIC RAST-L4 · Multisample rasterization (coverage per sample at standard locations)
  CLAIM       For N ∈ advertised sample counts, coverage is computed per sample at the
              standard sample locations; fill rules and primitive rules hold per sample;
              line/point coverage per sample; `primitives_multisample_*`,
              `fill_rules_multisample_*`, `interpolation_multisample_*` at 2/4/8/16/32/64
              (only advertised counts run).
  SOURCE      the `*_multisample_{N}_bit` families (396 cases).
  MECHANISM   PIPE-L4 (per-sample edge evaluation; the scan's 2×2 quad becomes a
              quad of pixels with N samples each; FS runs per pixel unless sample
              shading).
  REQUIRES    1 and 4 required; 2/8 are Pareto choices (storage × bandwidth).
  FORBIDS     Centroid interpolation outside the covered samples (centroid rule).
  CHECK       *_multisample_4_bit.* (CTS-3).
  COST        N× coverage/depth storage; the tile buffer (§9) is where this becomes
              affordable.
  FEEDS       PIPE-L4, VRS-L1; CTS-3.
  STATUS      not-run

LOGIC RAST-L5 · Rasterization-order attachment access and shader tile image (EXT)
  CLAIM       EXT_rasterization_order_attachment_access: reading the current pixel's
              attachment value in the FS (as input attachment, feedback loop) in
              primitive order; EXT_shader_tile_image: direct tile reads of colour/depth/
              stencil in the FS.
  SOURCE      rasterization.rasterization_order_attachment_access.* (280),
              shader_tile_image.* (5498).
  MECHANISM   Exactly the tile engine's per-pixel primitive order (W8-H1) + the ROP
              exposing the current pixel to the FS (programmable blending's substrate —
              plan W8 "programmable blend via standard shader/local-read").
  REQUIRES    tile engine; the same ordering point as FSI-L1.
  FORBIDS     Serving stale attachment data from a cache across primitives.
  CHECK       at W8 (CTS-4).
  COST        the tile buffer read port into the FS.
  FEEDS       W8 programmable blending, dynamic rendering local read (1.4); CTS-4.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION RAST-X1 · NotSupported by truthful absence
  CONDITION   conservative.*, depth_bias_control.*, shader_tile_image.*,
              rasterization_order_attachment_access.*, provoking_vertex.* (EXT),
              maintenance5.* (1.4), line stipple (1.4 core lineRasterization family),
              wide lines / large points while the features are false, fillModeNonSolid
              cases, multisample variants beyond advertised counts.
  RESULT      NotSupported.
  TRUTH       profile lines; EXT_provoking_vertex and EXT_line_rasterization (all six
              modes!) are Zink's GL 2.1 floor and 1.4 promotes bresenham lines to a
              required feature → RAST-L1 must implement Bresenham properly, not only the
              default rule.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     strictLines mis-declared.

EXCEPTION RAST-X2 · Line/point tolerance
  CONDITION   Line and point rasterization compared against the CTS reference with the
              spec's permitted deviations (Bresenham: exact set of diamonds exited;
              rectangle: coverage within the rectangle).
  RESULT      Pass within the declared rule.
  TRUTH       The rule we declare is the one we implement.
  MECHANISM   —
  CHECK       primitives.lines.*.
  FORBIDS     Switching rules per test.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| RAST-H1 Points + Bresenham lines | CTS-2 | high | point expander, Bresenham stepper (declare strictLines=true only if diamond-exit exact) | — |
| RAST-H2 Shared-edge snapping audit | fill_rules.clipped_* | high | prove identical snapping of shared clipped edges (engine vector with two adjacent clipped triangles) | — |
| RAST-H3 Depth bias | CTS-2 | medium | slope from plane equations + state | — |
| RAST-H4 MSAA | CTS-3 | high | per-sample coverage with standard positions | before the tile buffer design if storage cost is prohibitive — measure |
| RAST-H5 Provoking vertex control | Zink | medium | last-vertex option in the flat path | — |

## Performance / area / scalability

The scan converter is the pixel-rate roofline: today one pixel (quad) per several
cycles in a micro-sequencer. W4.5 targets a stamp rasterizer (4 samples/clk per §9),
hierarchical coverage over tiles, and parallel setup. Correctness-preserving: top-left
rule and fixed-point snapping are properties of the edge-function evaluation and
survive any parallelism; Bresenham lines need their own stepper regardless of stamp
size; per-pixel primitive order within a tile (CTS-P3).
