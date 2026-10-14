# `pipeline/*` — graphics/compute pipeline state: samplers, images, stencil, blend, multisample, vertex input, depth, caches (1,186,094 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass lists `vk-default/pipeline/monolithic/
monolithic.txt` (461,812 — the core set), `pipeline/fast-linked-library.txt` (128,113),
`pipeline/pipeline-library.txt` (118,915), `pipeline/shader-object-*` (453,218 across the
four lists), `pipeline/no-queues.txt` (36); tests in
`external/vulkancts/modules/vulkan/pipeline/vktPipeline*.cpp`. The non-monolithic lists
re-run the same cases through VK_EXT_graphics_pipeline_library / VK_EXT_shader_object
(NotSupported by absence). Owner W4 (rast/ROP/sampler) with W2 (objects). Gates CTS-2
(`sampler`, `image`, `image_view`, `stencil`, `blend`, `depth`, `vertex_input`,
`input_assembly`, `push_constant`, `spec_constant`, `render_to_image`, `timestamp`,
`framebuffer_attachment`, `cache`, `bind_point`, `interface_matching`), CTS-3 (`multisample`,
`dynamic_offset`, `descriptor_limits`, `extended_dynamic_state`), CTS-4 (the EXT families).

## Inventory (monolithic, by sub-group; `cut -d. -f4 … | sort | uniq -c`)

| `dEQP-VK.pipeline.monolithic.` | cases | what |
|---|---:|---|
| `sampler` | 182035 | every VkSamplerCreateInfo field × view type × format: filters, mipmap modes, address modes (incl. mirror-clamp), border colours (incl. custom), LOD bias/min/max, compare, unnormalized coordinates, anisotropy, reduction modes, separate sampler/image |
| `image` | 122912 | sampled-image views of every format × type (1D/2D/3D/cube/arrays) × size × mip/layer ranges, read in shaders |
| `stencil` | 58496 | stencil ops × compare ops × front/back × reference/masks × formats (S8, D24S8, D32S8, D16S8) |
| `image_view` | 27708 | component swizzles, subresource ranges, format reinterpretation |
| `blend` | 12210 | all factor/op combinations × formats incl. dual-source, constant colours |
| `multisample` | 10576 | sample counts, sample shading, alpha-to-coverage/one, sample mask, min sample shading, standard sample locations, resolves |
| `vertex_input` | 10574 | every vertex format × binding/attribute arrangements |
| `depth` | 8521 | depth compare ops × formats × depth bounds × clamp |
| `blend_operation_advanced` | 4652 | VK_EXT_blend_operation_advanced |
| `extended_dynamic_state` | 4027 | 1.3 / EXT1-3 dynamic states |
| `multisample_with_fragment_shading_rate` | 3572 | VRS × MSAA |
| `attachment_feedback_loop_layout`, `depth_range_unrestricted`, `shader_module_identifier`, `pipeline_binary`, `sliced_view_of_3d_image`, `bind_buffers_2`, `push_descriptor`, `color_write_enable(_maxa)`, `logic_op_na_formats`, `creation_cache_control`, `executable_properties`, `creation_feedback`, `shader_stencil_export`, `image_2d_view_3d_image`, `dynamic_vertex_attribute`, `dynamic_control_points` | 2383 / 2028 / 1556 / 33 / 156 / 97 / 76 / 600 / 576 / 18 / 16 / 13 / 6 / 48 / 1 / 3 | extension-gated |
| `interface_matching` 1589, `spec_constant` 1413, `render_to_image` 1325, `bind_point` 1296, `cache` 774, `dynamic_offset` 408, `descriptor_limits` 396, `no_position` 300, `timestamp` 262, `multisample_interpolation` 247, `logic_op` 224, `input_attribute_offset` 224, `input_assembly` 196, `multisample_shader_builtin` 95, `push_constant` 65, `framebuffer_attachment` 50, `pipeline_cache` 14, `misc` 13, `early_destroy` 9, `empty_fs` 8, `max_varyings` 6, `derivative` 3, `matched_attachments` 2 | | core / feature-gated |

## Architectural logic

```text
LOGIC PIPE-L1 · The complete sampler state machine over every view type and format
  CLAIM       VkSampler fields are honoured exactly: mag/min filter (nearest/linear,
              cubic optional), mipmap mode, LOD bias/min/max clamping (λ computed per the
              spec with the image's level count), address modes U/V/W incl. CLAMP_TO_
              BORDER with the six border colours (+ custom border colours when EXT) and
              MIRROR_CLAMP_TO_EDGE (1.2), compare ops for depth formats, unnormalized
              coordinates (with its restrictions), anisotropy (optional) and sampler
              reduction (1.2 optional); for 1D/2D/3D/cube/array views, integer and float
              formats, all required sampled formats; sampled through separate sampler +
              image or combined.
  SOURCE      pipeline.monolithic.sampler.* (182,035), image.* (122,912), image_view.*
              (27,708); vktPipelineSamplerTests.cpp, vktPipelineImageTests.cpp,
              vktPipelineImageViewTests.cpp.
  MECHANISM   5b sampler + G2b implicit LOD + G3a-ii (compare/proj/gather/query) + G3d
              (1D, 3D, cube, cube arrays, mirror-clamp, custom borders, unnormalized,
              anisotropy decision); component swizzle already in the record; format
              reinterpretation = the view's format drives decode (already view-based).
  REQUIRES    The full required sampled-image format list of the spec's format table
              (incl. SNORM, 10/11-bit packed, 16-bit, SRGB variants, D16/D32 for
              sampling, BC/ETC/ASTC if textureCompression* is advertised — BC for
              desktop content); layouts for 1D/3D/cube in the device image layout
              (5b) and in Xfer.
  FORBIDS     Flushing denormals or clamping LOD differently from the spec's λ clamp
              order (bias → clamp [minLod,maxLod] → clamp to levels); treating cube
              seams by clamping each face (seamless cube filtering is required in
              Vulkan).
  CHECK       sampler.view_type.2d.format.r8g8b8a8_unorm.* (CTS-2 start), then per view
              type / format family; image.* and image_view.* per view type.
  COST        The texel-rate roofline (lane-serial sampler, 16-line cache). Cube and 3D
              add address math; anisotropy adds up to 16 taps (optional — Pareto).
  FEEDS       TEXTURE-L*, GLSL-L3, IMAGE-L*; CTS-2.
  STATUS      not-run

LOGIC PIPE-L2 · Stencil, depth and the fragment-test state (front/back)
  CLAIM       Stencil test with all eight compare ops and eight stencil ops for
              fail/pass/depthFail, separate front/back state, reference/compare/write
              masks (static and dynamic), on S8_UINT, D24_UNORM_S8_UINT, D32_SFLOAT_S8_UINT
              and D16_UNORM_S8_UINT as advertised (one of D24S8/D32S8 is required);
              depth test compare ops on D16/D24/D32 (+ D32S8), depth bounds test
              (optional feature), depth write enable, with FragDepth and early tests
              (FO-L1); stencil export (EXT) optional.
  SOURCE      pipeline.monolithic.stencil.* (58,496), depth.* (8,521),
              depth_range_unrestricted.*, shader_stencil_export.*;
              vktPipelineStencilTests.cpp, vktPipelineDepthTests.cpp.
  MECHANISM   G3c: a stencil byte per sample in the depth/stencil attachment layout
              (interleaved D24S8 word, or the separate S8 plane of D32S8 — the layout is
              ours), the stencil ALU (compare, op, masks) in the ROP next to the depth
              test, ordering: stencil test → depth test → stencil op selection
              (sfail / dpfail / dppass) → writes under write masks; early/late like depth.
  REQUIRES    Separate depth/stencil aspect copies/clears (API-L5), attachment layouts
              per format, `image/depth-stencil-separate-access` for separate aspect
              reads later.
  FORBIDS     Collapsing the three stencil op paths (the tests enumerate them all);
              ignoring the write mask on clears (clears are not masked — but stencil
              ops are).
  CHECK       stencil.format.s8_uint.* and d24_unorm_s8_uint.* (CTS-2); engine: one
              vector per op triple with a reference.
  COST        one byte per sample read-modify-write in the ROP; stencil in the tile
              buffer later.
  FEEDS       RENDERPASSES, FO-L1, DS-L1; CTS-2.
  STATUS      not-run

LOGIC PIPE-L3 · Blending, logic ops, colour write enable, dual source
  CLAIM       All blend factors and ops per attachment (independentBlend) for every
              colour attachment format class (UNORM/SNORM/SRGB/float/int — ints do not
              blend), constant colour, dual-source factors (dualSrcBlend optional),
              logic ops (logicOp optional — Zink needs it) on integer/UNORM formats,
              colorWriteMask, VK_EXT_color_write_enable (optional), advanced blend (EXT,
              optional), blending with MSAA per sample.
  SOURCE      pipeline.monolithic.blend.* (12,210), logic_op.*, logic_op_na_formats.*,
              color_write_enable*.*, blend_operation_advanced.*; vktPipelineBlendTests.cpp,
              vktPipelineLogicOpTests.cpp.
  MECHANISM   G2a ROP blending (f32 on fpnew, UNORM/SRGB encode); needs SNORM/float/int
              attachment formats (format table + encode/decode), logic ops (a bitwise
              unit on the encoded values), dual source (FS output location 0 index 1 →
              a second FS-out slot), per-sample blending with MSAA.
  REQUIRES    Required colour-attachment formats with BLEND bit (R8G8B8A8_UNORM/SRGB,
              B8G8R8A8, A8B8G8R8 packed, R16G16B16A16_SFLOAT, A2B10G10R10_UNORM, R16/R16G16
              families, R32* without blend, …) per the format table.
  FORBIDS     Blending in the encoded 8-bit domain for sRGB (blend in linear, encode
              after — G2a already does); rounding differently from the spec's "blend
              results are undefined beyond precision" allowance — but the CTS has
              tolerances; integer formats must not blend.
  CHECK       blend.format.r8g8b8a8_unorm.* (CTS-2) then per format family; logic_op.*
              once logicOp is advertised.
  COST        blend units per ROP lane; logic op is trivial.
  FEEDS       Zink (logicOp, dualSrcBlend for GL 3.3), FORMATS; CTS-2.
  STATUS      not-run

LOGIC PIPE-L4 · Multisampling: coverage, sample shading, masks, alpha-to-coverage, resolves
  CLAIM       rasterizationSamples ∈ framebuffer sample counts (1 and 4 required; 2/8/16
              optional) with standard sample locations; per-sample coverage, depth/
              stencil per sample, sample shading (sampleRateShading optional; minSample
              Shading), gl_SampleID/SamplePosition/SampleMask, alpha-to-coverage and
              alpha-to-one, pSampleMask, resolve attachments (box average in linear
              space, sRGB-aware), sampled multisample images (texelFetch with sample
              index), copies/resolve commands; interactions with VRS (W8).
  SOURCE      pipeline.monolithic.multisample.* (10,576), multisample_interpolation.*,
              multisample_shader_builtin.*, multisample_with_fragment_shading_rate.*;
              vktPipelineMultisampleTests.cpp and friends.
  MECHANISM   G3c RAST-L4: the scan evaluates coverage per sample (edge functions at
              the standard positions), depth/stencil per sample, one FS invocation per
              covered pixel (or per sample under sample shading) writing to all covered
              samples through the sample mask; attachments store samples interleaved per
              pixel in the device layout; resolve in Xfer / at render-pass end.
  REQUIRES    Tile/attachment layout for samples; `fsz_q`/coverage tables per sample in
              rast; FS-out slot 8 word 2 (SampleMask) consumed.
  FORBIDS     Supersampling as the implementation of MSAA for the coverage-only tests
              (invocation counts and sample shading rates are observable);
              non-standard sample positions while advertising standardSampleLocations.
  CHECK       multisample.* at 4 samples first (CTS-3); fragment_operations sample_count
              variants; api.copy_and_blit resolve_image.
  COST        4× depth/stencil/colour storage per pixel; the ROP sample loop; a tile
              buffer makes this cheap in bandwidth.
  FEEDS       VRS-L1, RENDERPASSES (resolves), TEXTURE multisample; CTS-3.
  STATUS      not-run (framebuffer sample counts = 1 today — below the required set)

LOGIC PIPE-L5 · Vertex input and input assembly
  CLAIM       Every vertex format with VERTEX_BUFFER support (the required list) decodes
              correctly for per-vertex/per-instance bindings, offsets up to
              maxVertexInputAttributeOffset, strides up to maxVertexInputBindingStride
              (incl. zero stride), attribute offsets within a binding (input_attribute_
              offset), 16-bit/32-bit indices with primitive restart for each topology,
              all topologies incl. adjacency (geometryShader) and patches (tessellation).
  SOURCE      pipeline.monolithic.vertex_input.* (10,574), input_assembly.* (196),
              input_attribute_offset.*, dynamic_vertex_attribute.*;
              vktPipelineVertexInputTests.cpp, vktPipelineInputAssemblyTests.cpp.
  MECHANISM   DRAW-L1 (rast attribute gather table-driven by format).
  REQUIRES    the format decode table; restart; topologies.
  FORBIDS     —
  CHECK       vertex_input.single_attribute.* then multiple (CTS-2); input_assembly.*.
  COST        format decoders (shared with the sampler's).
  FEEDS       DRAW-L1; CTS-2.
  STATUS      not-run

LOGIC PIPE-L6 · Pipeline creation semantics: spec constants, interface matching, caches, bind points, limits
  CLAIM       Specialization constants in every stage (incl. workgroup size), interface
              matching between stages (locations, components, blocks, arrays, flat/int
              rules, max varyings), pipeline caches (create/merge/data round trip),
              binding compute and graphics pipelines at their bind points independently
              (bind_point: descriptor sets per bind point), push constants per stage
              ranges, descriptor-limit edge cases (maxPerStage/maxDescriptorSet*), no
              position write (no_position), empty fragment shader, early destroy of
              modules/layouts, render_to_image (rendering to each image type/mip/layer
              incl. 3D slices and cube faces via 2D array views), framebuffer attachment
              sizes larger than the render area, timestamps (TIMESTAMP queries per stage
              with timestampPeriod and timestampValidBits — timestampComputeAndGraphics).
  SOURCE      spec_constant.* (1413), interface_matching.* (1589), cache.* (774),
              pipeline_cache.*, bind_point.* (1296), push_constant.* (65),
              descriptor_limits.* (396), no_position.*, empty_fs.*, early_destroy.*,
              render_to_image.* (1325), framebuffer_attachment.*, timestamp.* (262),
              max_varyings.*, derivative.*, misc.*.
  MECHANISM   COMPUTE-L1 (spec constants), GLSL-L5 (linkage/Component), API-L7 (cache),
              cmdexec per-bind-point set state (two `dset[]` banks), QUERY-POOL-L2
              (timestamps need a device timestamp counter — `timestampPeriod` is one
              of the 7 audit findings), layered/3D render targets (MV-L1 layers),
              render area vs attachment size.
  REQUIRES    timestamp counter + period (fixed-frequency cycle counter is fine);
              per-bind-point descriptor state.
  FORBIDS     Sharing descriptor-set state between compute and graphics bind points.
  CHECK       spec_constant.*, bind_point.*, push_constant.*, render_to_image.core.*,
              timestamp.* (CTS-2).
  COST        small.
  FEEDS       QUERY-POOL-L2, COMPUTE-L1; CTS-2.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION PIPE-X1 · NotSupported by truthful absence
  CONDITION   fast_linked_library.*, pipeline_library.* (EXT_graphics_pipeline_library),
              shader_object_* lists (EXT_shader_object), blend_operation_advanced,
              attachment_feedback_loop_layout, depth_range_unrestricted,
              shader_module_identifier, pipeline_binary, sliced_view_of_3d_image,
              bind_buffers_2 / push_descriptor (1.4 core → required at 1.4),
              color_write_enable, logic_op_na_formats, creation_cache_control (1.3),
              executable_properties (KHR), creation_feedback (1.3), shader_stencil_
              export, image_2d_view_3d_image, extended_dynamic_state (1.3 subset
              required at 1.3), multisample_with_fragment_shading_rate (W8),
              dynamic_control_points (tessellation), anisotropy/cubic/reduction sampler
              cases, dualSrcBlend/logicOp/depthBounds/sampleRateShading/alphaToOne
              feature cases while false, sample counts not advertised.
  RESULT      NotSupported.
  TRUTH       profile lines; several flip at 1.3/1.4 (INFO-L2 ladder) and several are
              Zink's GL floor (logicOp, alphaToOne, dualSrcBlend, depthClamp,
              sampleRateShading, multiViewport, custom border colours).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     framebufferColorSampleCounts without 4 (required) — not an exception.

EXCEPTION PIPE-X2 · Precision latitude in the tests
  CONDITION   Blend results, sampler filtering, sRGB conversion, multisample resolve.
  RESULT      The CTS compares with format-precision tolerances (tcu::TextureLevel
              thresholds); exact rounding is not required but monotonic, in-range,
              spec-formula results are.
  TRUTH       Spec: "undefined precision beyond the format"; our f32 pipelines with
              correctly rounded fpnew ops sit inside every tolerance observed so far
              (vkcmp maxdiff ≤ 1 LSB).
  MECHANISM   —
  CHECK       the families' thresholds (a 1-LSB disagreement is a pass; a systematic
              offset is a defect).
  FORBIDS     Tuning results toward the CTS thresholds instead of the spec formula.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| PIPE-H1 Sampler 2D matrix | CTS-2 | high | sampler.view_type.2d over the implemented formats; then address modes/borders/LOD clamps | — |
| PIPE-H2 Stencil | G3c | high | S8 byte plane + the ALU; D24S8 layout | — |
| PIPE-H3 Format table completion | blend/image/vertex_input failures by format | high | one generated format table (decode/encode/blend/vertex) for the whole required list | — |
| PIPE-H4 MSAA 4× | G3c | high | per-sample coverage/depth/colour + resolve | before stencil (do stencil first; MSAA touches it) |
| PIPE-H5 Timestamps + bind points | CTS-2 | medium | cycle counter + period; per-bind-point sets | — |
| PIPE-H6 Cube/3D/1D | G3d | medium | layouts + address math | — |

## Performance / area / scalability

`pipeline.*` is 37 % of the must-pass by count and is dominated by sampler/image
matrices — the texel path is the throughput item (quad-parallel sampler, larger texel
cache, format decoders shared with Xfer; W4.5). Stencil/MSAA size the tile buffer (§9:
tile = colour MRTs × samples + depth/stencil × samples). Knobs: `TexCacheLines`, sampler
units, `MaxSamples`, tile size. Correctness-preserving: seamless cube filtering, exact λ
clamp order and per-sample ordering are not negotiable in any fast path.
