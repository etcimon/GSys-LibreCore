# `multiview` — single-pass multi-view rendering (694 cases) — **mandatory at Vulkan 1.1**

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/multiview.txt`; tests in
`external/vulkancts/modules/vulkan/multiview/vktMultiViewRenderTests.cpp`. Owner **G3c**
(promoted from W8 on 2026-10-14): CTS-0 `info.device_mandatory_features` failed with
"Mandatory feature multiview not supported", and the source settles why — Mesa Venus
(`vn_physical_device.c`) exposes `VK_KHR_multiview` (with `KHR_shader_draw_parameters`,
`KHR_variable_pointers`, `KHR_device_group`, `KHR_16bit_storage`, `KHR_sampler_ycbcr_
conversion`, …) **unconditionally** for any renderer ≥ `VN_MIN_RENDERER_VERSION` (1.1), and
refuses renderers below 1.1 — so on the stock path `multiview` is an obligation of this
device, not a ladder item. Gate CTS-2 (MV-L1); the geometry/tessellation variants stay W8.

## Inventory

| prefix (`dEQP-VK.multiview.`…) | cases |
|---|---:|
| `renderpass2` (`index` 32 + masks/clear/queries/secondary/readback/point_size/…) | 234 |
| `dynamic_rendering` (`index` 32 + same) | 226 |
| top-level renderpass1 families (`masks`, `vertex_shader`, `fragment_shader`, `geometry_shader`, `tessellation_shader`, `input_attachments`, `instanced`, `input_instance`, `draw_indirect`, `clear_attachments`, `secondary_cmd_buffer`, `secondary_cmd_buffer_geometry`, `point_size`, `multisample`, `queries`, `readback_*`, `depth`, `stencil`, `nested_cmd_buffer`, …) | 234 |
| **total** | 694 |

## Architectural logic

```text
LOGIC MV-L1 · One draw renders every view of the view mask into its own layer
  CLAIM       With a subpass view mask (render pass 2 / dynamic rendering), each draw is
              executed once per set bit; gl_ViewIndex is available in vertex (and
              fragment, tessellation, geometry when those exist) stages; outputs land in
              the attachment layer equal to the view index; correlation masks are hints;
              view-dependent clears, input attachments, occlusion queries (per view when
              multiviewOcclusionQuery is not… — queries count all views together per
              spec), secondary command buffers, instanced and indirect draws, point size
              and multisample all behave per view; maxMultiviewViewCount ≥ 6,
              maxMultiviewInstanceIndex.
  SOURCE      multiview.{masks,vertex_shader,fragment_shader,instanced,input_instance,
              draw_indirect,clear_attachments,secondary_cmd_buffer,point_size,
              multisample,queries,readback_*,depth,stencil,input_attachments,
              index.*}.*, multiview.renderpass2.*, multiview.dynamic_rendering.*.
  MECHANISM   The cheapest correct implementation on this engine is a *view loop in
              cmdexec*: the draw record is issued once per view with a ViewIndex builtin
              word (VS-in slot 8 has a free component) and the attachment layer offset
              applied in rast's address computation (layer stride from the image
              layout); render-pass clears apply to all views; queries accumulate across
              the loop. This preserves primitive order per view and needs no new
              datapath. A later geometry-stage broadcast (W8 "single pass") is a
              throughput refinement, not a semantic change.
  REQUIRES    Layered attachments (framebuffer layers > 1 — maxFramebufferLayers 1
              today) in the attachment resolve and the rast ROP addressing; gl_ViewIndex
              builtin (BuiltIn 4440) in shmod/shwave/model; `multiview` feature +
              VK_KHR_multiview properties.
  FORBIDS     Faking multiview by requiring the application to draw per view (the whole
              point is one draw); dropping views above a hardware count (advertise the
              count you loop).
  CHECK       multiview.masks.*, vertex_shader.*, instanced.*, readback_* first (CTS-2);
              engine: a 2-view draw vs two single draws reference.
  COST        draw issue cost × views (the loop); layer stride adder in rast. The
              single-pass broadcast (W8) removes the VS re-execution cost.
  FEEDS       INFO-L2 (1.1 mandatory), RENDERPASSES-L*, W8; CTS-2.
  STATUS      not-run

LOGIC MV-L2 · Multiview with geometry/tessellation stages
  CLAIM       multiviewGeometryShader / multiviewTessellationShader features (optional):
              gl_ViewIndex in those stages.
  SOURCE      multiview.geometry_shader*, tessellation_shader*, secondary_cmd_buffer_
              geometry.
  MECHANISM   with W8 stages.
  REQUIRES    the stages.
  FORBIDS     —
  CHECK       at W8.
  COST        —
  FEEDS       W8.
  STATUS      not-run (NotSupported by feature)
```

## Exceptions

```text
EXCEPTION MV-X1 · Optional sub-features
  CONDITION   multiviewGeometryShader, multiviewTessellationShader false; dynamic_rendering
              variants at < 1.3; multisample variants beyond the advertised counts.
  RESULT      NotSupported.
  TRUTH       profile lines.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Leaving `multiview` itself false while advertising 1.1 (if INFO-L2's
              hypothesis is confirmed).
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| MV-H1 Decide at CTS-0 | `device_mandatory_features` result | precondition | if multiview is mandatory at 1.1: implement the view loop before CTS-2; else schedule with W8 | — |
| MV-H2 Layers first | MV-L1 | high | layered attachments (framebuffer layers, layer stride) — also needed by `geometry.layered` and cube render targets | — |

## Performance / area / scalability

The view loop multiplies vertex work by the view count; VR-class workloads (2 views)
tolerate it, and the W8 broadcast removes it. Correctness-preserving: per-view primitive
order is per-view; across views there is no ordering requirement, so a tile engine may
interleave views.
