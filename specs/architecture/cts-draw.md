# `draw` — draw commands, instancing, indirect, dynamic rendering, viewport/scissor state (29,392 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/draw.txt`; tests in
`external/vulkancts/modules/vulkan/draw/vktDraw*.cpp`. Owner W4 (rast + cmdexec draw
assembly, G3c). Gates CTS-2 (`draw.renderpass.*` core families), CTS-3 (`dynamic_rendering`
at 1.3), W8 (`multi_draw`, `shader_viewport_index`, `shader_layer`).

Also in this file: `depth` (8 cases, `vk-default/depth.txt` — depth bias / out-of-range /
FS depth clamp, same module).

## Inventory (`cts_ledger.py tree --group draw --depth 3 --min-cases 20`)

| prefix (`dEQP-VK.`…) | cases |
|---|---:|
| `draw` | 29392 |
| &nbsp;&nbsp;`draw.dynamic_rendering` | 16955 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…primary_cmd_buff / complete_secondary_cmd_buff / partial_secondary_cmd_buff` | 12005 / 2536 / 2394 |
| &nbsp;&nbsp;`draw.renderpass` | 12437 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…multi_draw` | 9024 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…instanced` | 1016 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…ahb_external_format_resolve` | 517 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…indirect_draw` | 360 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…basic_draw` | 331 (draw 40, draw_indexed 49, draw_indirect 120, draw_indexed_indirect 120, misc 2) |
| &nbsp;&nbsp;&nbsp;&nbsp;`…vertex_attribute_divisor` | 288 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…indexed_draw` | 203 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…multiple_clears_within_render_pass` | 144 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…depth_clamp` | 118 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…discard_rectangles` | 72 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…non_line_with_params` | 60 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…shader_viewport_index` | 49 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…explicit_vertex_parameter` | 38 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…output_location` | 30 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…multiple_interpolation` | 28 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…shader_draw_parameters` | 24 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…scissor` | 22 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…linear_interpolation` | 21 |
| **total** | 29392 |

`draw.dynamic_rendering.primary_cmd_buff.*` repeats the renderpass families (basic_draw
163, indexed_draw 160, indirect_draw 352, instanced 1016, multi_draw 9024, vertex_attribute_
divisor 432, depth_clamp 118, scissor 22, shader_* …) under vkCmdBeginRendering, plus
`inverted_depth_ranges`, `negative_viewport_height`, `zero_viewport_height`,
`offscreen_viewport`, `shader_layer`, `implicit_sample_shading`, `concurrent`.

## Architectural logic

```text
LOGIC DRAW-L1 · The four draw calls over every topology and vertex layout
  CLAIM       vkCmdDraw / DrawIndexed / DrawIndirect / DrawIndexedIndirect produce the
              spec's primitives for point/line/strip/fan/list/adjacency topologies (and
              patches when tessellation exists), with firstVertex/firstInstance/
              vertexOffset, instancing, primitive restart (indexed strips with the
              restart index, enable/disable), multiple vertex bindings with per-vertex
              and per-instance rates, and all vertex input formats the device advertises
              (VERTEX_BUFFER_BIT), at any legal vertex/index buffer offset.
  SOURCE      draw.renderpass.basic_draw.*, indexed_draw.*, indirect_draw.*,
              instanced.*, vertex_attribute_divisor.* (EXT/1.4), scissor.*;
              vktDrawSimpleTest.cpp, vktDrawIndexedTest.cpp, vktDrawIndirectTest.cpp,
              vktDrawInstancedTests.cpp, vktDrawScissorTests.cpp.
  MECHANISM   rast draw descriptor + VS batching (G1b/G2a); indirect draws need the
              cmdexec 4/5-word operand fetch (COMPUTE-L2) with drawCount loops and
              stride, and indirectCount (1.2 core drawIndirectCount) reading the count
              buffer; points/lines/adjacency need RAST-L1 (cts-rasterization.md);
              primitive restart needs the index fetch to split strips/fans at the
              restart value (restart index = max for the index type) — strips longer
              than one VS batch (63 vertices) must also carry across batches.
  REQUIRES    Vertex formats: the full required VERTEX_BUFFER list of the format table
              (SNORM/UNORM/USCALED/SSCALED/UINT/SINT/SFLOAT 8/16/32-bit × 1–4 comps,
              A2B10G10R10 packed, …) decoded in the attribute gather; divisor: per-
              binding divisor with the zero-divisor rule.
  FORBIDS     Collapsing instanced draws into one VS pass (instance-rate attributes and
              gl_InstanceIndex differ per instance); ignoring primitive restart in
              non-strip topologies incorrectly (restart applies to list topologies too
              when enabled — in 1.0 that is invalid usage for lists, with
              VK_EXT_primitive_topology_list_restart it is defined).
  CHECK       draw.renderpass.basic_draw.* + indexed_draw.* + instanced.* (CTS-2);
              engine: a restart-strip vector crossing a batch boundary vs the Python
              reference; indirect with drawCount > 1 and a non-tight stride.
  COST        Attribute gather is one memory word per component today (the rast
              micro-sequencer) — a vertex-fetch unit with per-binding streams is the
              W4.5 throughput item; `MaxDrawIndirectCount`.
  FEEDS       RAST-L1, RENDERPASSES-L*, DYNAMIC-STATE-L*; CTS-2.
  STATUS      not-run

LOGIC DRAW-L2 · Viewport and scissor transforms, depth range, depth clamp
  CLAIM       The viewport transform (including negative height — VK_KHR_maintenance1,
              core since 1.1; zero height; viewports partly or fully off-screen;
              minDepth > maxDepth inverted ranges) and scissor rectangles are applied
              exactly; depthClamp clamps z to [min(minDepth,maxDepth), max(…)] instead of
              clipping; without depthClampZeroOne the clamp is to the viewport range.
  SOURCE      draw.*.negative_viewport_height, zero_viewport_height, offscreen_viewport,
              inverted_depth_ranges, depth_clamp.*, scissor.*; depth.* (8: bias_*,
              out_of_range*, fs_clamp*, ez_fs_clamp); vktDrawNegativeViewportHeightTests,
              vktDrawInvertedDepthRangesTests, vktDrawDepthClampTests, vktDrawDepthTests.
  MECHANISM   rast viewport transform in 16.8 fixed point (G1b) + G2b clipper; depth
              clamp = disable the z clip planes and clamp the interpolated z (and
              FragDepth) in the ROP/early-Z; depth bias = slope-scaled + constant bias
              applied to the interpolated z (needs the primitive's max z-slope from
              setup) with the clamp term; `fs_clamp` cases check that a FragDepth
              outside [0,1] is clamped (unless depthRangeUnrestricted).
  REQUIRES    Negative viewport height already legal (1.1) — verify the sign handling of
              the fixed-point transform; depth bias state (static and dynamic) retained
              in the pipeline/dynamic state (W4.1).
  FORBIDS     Clamping z before the depth test when depthClamp is off (that is clipping);
              applying bias to FragDepth-written depth (spec: bias applies to the
              interpolated depth only).
  CHECK       the families above (CTS-2); engine: a triangle crossing the far plane with
              clamp on/off; bias vectors vs the reference formula.
  COST        two FMAs per fragment for bias; one compare for clamp.
  FEEDS       RAST-L*, FRAGMENT-OPS-L*; CTS-2.
  STATUS      not-run

LOGIC DRAW-L3 · Interpolation qualifiers and fragment output locations
  CLAIM       flat/noperspective/smooth, centroid and sample qualifiers interpolate as
              specified (flat takes the provoking vertex's value — the first vertex by
              default); multiple interpolation modes in one shader; fragment outputs
              mapped by Location/Index to attachments, including unused locations and
              component/index aliasing rules.
  SOURCE      draw.*.linear_interpolation, multiple_interpolation,
              differing_interpolation, output_location, implicit_sample_shading;
              vktDrawDifferingInterpolationTests, vktDrawOutputLocationTests.
  MECHANISM   The FS-in record (144 B) carries perspective-correct values today; needs a
              per-location interpolation mode (flat = provoking vertex copy,
              noperspective = linear in screen space, centroid = sample inside coverage
              when MSAA) carried from the FS module's decorations (shmod) into the rast
              interpolator; provoking vertex = first (VK_EXT_provoking_vertex would allow
              last — Zink needs it).
  REQUIRES    Decoration capture in shmod (Flat/NoPerspective/Centroid/Sample on FS
              inputs), a per-location mode table in the draw descriptor.
  FORBIDS     Interpolating flat inputs (even when the values happen to match on test
              geometry).
  CHECK       the families (CTS-2); engine vector: flat colour with a different value per
              vertex.
  COST        a mode nibble per location; one extra 1/w-free path for noperspective.
  FEEDS       GLSL-L*, RASTERIZATION (sample shading); CTS-2.
  STATUS      not-run

LOGIC DRAW-L4 · Dynamic rendering (1.3 core)
  CLAIM       vkCmdBeginRendering/EndRendering render without render pass/framebuffer
              objects: attachments given as image views with load/store ops, resolve
              attachments, render area, layer count, view mask, suspend/resume across
              command buffers, secondary command buffers with inheritance rendering info
              (complete and partial), and the same draw semantics as render passes.
  SOURCE      draw.dynamic_rendering.{primary_cmd_buff,complete_secondary_cmd_buff,
              partial_secondary_cmd_buff}.* (16,955); vktDynamicRenderingTests.cpp.
  MECHANISM   cmdexec attachment resolve at BeginRendering instead of BeginRenderPass
              (same rast loadOp/storeOp path); suspend/resume = the attachment state and
              tile/attachment contents persist across the pair (no implicit store/load);
              inheritance = the secondary's draws use the primary's rendering state.
  REQUIRES    1.3 ladder; W4.1 full state retention (attachment formats/samples per
              pipeline from VkPipelineRenderingCreateInfo).
  FORBIDS     Implementing suspend/resume as end+begin (introduces a store/load that
              changes the result with DONT_CARE ops).
  CHECK       dynamic_rendering.primary_cmd_buff.basic_draw.* first (CTS-3).
  COST        state words; no datapath.
  FEEDS       RENDERPASSES-L*, Zink (prefers dynamic rendering), UE 5.4+; CTS-3.
  STATUS      not-run

LOGIC DRAW-L5 · Multi-draw, draw parameters, viewport index/layer from shaders
  CLAIM       VK_EXT_multi_draw (vkCmdDrawMultiEXT/IndexedEXT with per-draw vertex
              offsets), shaderDrawParameters (gl_BaseVertex/BaseInstance/DrawIndex — 1.1
              feature), shaderOutputViewportIndex/shaderOutputLayer (1.2 features:
              gl_ViewportIndex/gl_Layer from the vertex stage), discard rectangles (EXT).
  SOURCE      draw.*.multi_draw (9024), shader_draw_parameters, shader_viewport_index,
              shader_layer, discard_rectangles, non_line_with_params,
              explicit_vertex_parameter (AMD), ahb_external_format_resolve (Android).
  MECHANISM   Draw parameters = three more VS-in builtin words per draw (slot 8 has
              room); multi-draw = a draw loop in cmdexec with per-draw offsets; viewport
              index/layer = multiple viewports/scissors in the rast state and a layer
              select in the attachment address (maxViewports ≥ 16 for Zink GL 4.1,
              maxFramebufferLayers); discard rectangles = extra scissor-like tests.
  REQUIRES    multiViewport feature for > 1 viewport; layered framebuffers (multiview/
              geometry/layer routing — W8).
  FORBIDS     Emulating multi-draw as separate draws without DrawIndex (the shader
              observes gl_DrawID).
  CHECK       shader_draw_parameters.* (CTS-2 once advertised), multi_draw.* (W8),
              shader_viewport_index/layer (W8).
  COST        viewport array state; layer addressing.
  FEEDS       W8 (multiview, mesh); CTS-2/4.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION DRAW-X1 · NotSupported by truthful absence
  CONDITION   multi_draw.* (EXT_multi_draw), discard_rectangles.* (EXT), explicit_vertex_
              parameter.* (AMD), ahb_external_format_resolve.* (Android), depth_clamp.*
              while depthClamp is false, shader_draw_parameters.* while the 1.1 feature
              is false, shader_viewport_index/shader_layer while the 1.2 features are
              false, vertex_attribute_divisor.* (EXT/1.4) while absent, dynamic_
              rendering.* while at 1.1/1.2, multiview variants, `*_unrestricted` depth
              cases (EXT_depth_range_unrestricted), implicit_sample_shading while
              sampleRateShading is false.
  RESULT      NotSupported.
  TRUTH       Profile lines; dynamic rendering and the 1.2 features flip to required
              with the version ladder (INFO-L2).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Leaving shaderDrawParameters false to dodge gl_DrawID once multi-draw
              exists.

EXCEPTION DRAW-X2 · Invalid-usage latitude not taken
  CONDITION   Index/vertex buffer reads past the bound range (the CTS does not do this
              in draw.*; robustness.* does with robustBufferAccess).
  RESULT      Robust: out-of-range vertex attributes read zero/garbage-but-no-fault
              (robustBufferAccess = true is advertised); index OOB → index 0 + robust
              count (today).
  TRUTH       robustBufferAccess covers vertex input per the spec's robust access rules.
  MECHANISM   rast attribute gather bounds (G1b), index fetch clamp.
  CHECK       robustness.vertex_access.* (cts-robustness.md).
  FORBIDS     A fault/DEVICE_LOST on an OOB attribute while advertising robustBufferAccess.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| DRAW-H1 Topologies + restart | CTS-2 | high | RAST-L1 (points/lines), restart split in the index fetch, strips across batches | — |
| DRAW-H2 Indirect + count | COMPUTE-L2 lands | high | reuse the operand fetch; drawCount loop; count buffer | — |
| DRAW-H3 Vertex formats | basic_draw fails on a format | high | decode the required VERTEX_BUFFER list in the gather (table-driven like the sampler) | — |
| DRAW-H4 Interpolation modes | linear/multiple_interpolation fail | medium | decoration capture + per-location mode | — |
| DRAW-H5 Depth bias/clamp | depth.* / depth_clamp.* | medium | setup slope + bias FMAs; clamp path | — |
| DRAW-H6 Dynamic rendering | 1.3 ladder | later | BeginRendering state path reusing the render-pass attachment resolve | before W4.1 full state retention |

## Performance / area / scalability

Draw throughput = vertex fetch × VS waves × setup × scan × FS waves × ROP. The current
engine serializes all of it in one micro-sequencer (one vertex attribute word per
cycle, one float op in flight). Knobs for W4.5: vertex-fetch streams per binding,
`VsBatch`/`FsBatch`, parallel setup units, tile binning (§9), `ShaderCores`. Correctness-
preserving: primitive order must be preserved per pixel for blending/depth (CTS-P3) —
binning may reorder across tiles, never within a tile's primitive sequence.
