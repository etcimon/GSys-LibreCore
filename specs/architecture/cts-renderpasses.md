# `renderpasses` — render pass 1/2, subpasses, input attachments, load/store/resolve, dynamic rendering (79,748 cases) + `imageless-framebuffer` (6)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/renderpasses.txt`
(`vk-default/imageless-framebuffer.txt`); tests in
`external/vulkancts/modules/vulkan/renderpass/vktRenderPass*.cpp`. Owner W4 (cmdexec
attachment resolve, rast loadOp/storeOp, Xfer resolve). Gates CTS-2 (`renderpass1`,
`renderpass2` core families), CTS-3 (`dynamic_rendering` at 1.3, imageless framebuffer at
1.2).

## Inventory

| `dEQP-VK.renderpasses.` | cases | what |
|---|---:|---|
| `renderpass2` | 32314 | the KHR_create_renderpass2 / 1.2 form of everything below + depth/stencil resolve, separate layouts, attachment aspects |
| `renderpass1` | 19668 | `suballocation` 11159 / `dedicated_allocation` 7777: the generated matrix of simple/formats/attachment/attachment_allocation/attachment_write_mask/multisample/multisample_resolve/subpass_dependencies/… ; `fragment_density_map` 301, `custom_resolve` 258, `dithering` 94, `depth_stencil_write_conditions` 54, `remaining_array_layers` 12, `nested_command_buffers` 8, `multiple_subpasses_multiple_command_buffers` 2, `no_draws` 1 |
| `dynamic_rendering` | 27766 | the same semantics under vkCmdBeginRendering (+ local read, 1.4) |
| `imageless_framebuffer` | 6 | 1.2 core imagelessFramebuffer |
| **total** | 79754 | |

## Architectural logic

```text
LOGIC RP-L1 · Attachment load/store/clear semantics and layouts, per aspect
  CLAIM       loadOp LOAD/CLEAR/DONT_CARE and storeOp STORE/DONT_CARE (and NONE, 1.3)
              for colour, depth and stencil aspects independently (stencil ops separate),
              clear values of every attachment format class (float/int/uint/depth/
              stencil), render area subsets (contents outside the render area untouched
              by clears and unaffected by DONT_CARE), layered framebuffers and
              `remaining_array_layers`, image layouts and transitions declared by the
              pass (initial/final/subpass layouts — one device layout, so transitions are
              free but must not be *required* for correctness), attachment write masks,
              unused attachments (VK_ATTACHMENT_UNUSED), multiple subpasses in one or
              several command buffers (secondary with RENDER_PASS_CONTINUE), no-draw
              passes, nested command buffers (EXT).
  SOURCE      renderpasses.renderpass1.{suballocation,dedicated_allocation}.{simple,
              formats,attachment,attachment_allocation,attachment_write_mask,
              subpass_dependencies,…}.*, depth_stencil_write_conditions.*,
              remaining_array_layers.*, no_draws, multiple_subpasses_multiple_command_
              buffers; vktRenderPassTests.cpp.
  MECHANISM   G1c attachment resolve at BeginRenderPass + rast CLEAR work (G2a depth);
              needs: LOAD = no-op on our in-place attachments (correct by construction —
              no tile buffer yet; with a tile buffer LOAD = tile fill), DONT_CARE = no-op
              (allowed), stencil clears (PIPE-L2), int/uint clear values (format table),
              render-area-bounded clears (`vkCmdClearAttachments` too), layers,
              write-mask-respecting storeOp (DONT_CARE must not be used to skip a STORE
              of another aspect), multiple subpasses (RP-L2).
  REQUIRES    Full pipeline/pass state retention (W4.1) — today 22 ObjPay words for the
              pipeline and a 13-word pass; a pass with N attachments × M subpasses needs
              a variable payload (ObjPay extents already variable).
  FORBIDS     Treating DONT_CARE as CLEAR or LOAD (observable via the test's "garbage
              must remain garbage" checks? — no: DONT_CARE contents are undefined, so any
              value passes; but a *clear* of an unrelated aspect is a bug).
  CHECK       renderpass1.suballocation.simple.*, formats.*, attachment.* (CTS-2);
              engine: a two-subpass vector.
  COST        state words; clears are Xfer/ROP work.
  FEEDS       PIPE-L2 (stencil), API-L5 (ClearAttachments); CTS-2.
  STATUS      not-run

LOGIC RP-L2 · Subpass dependencies, input attachments and self-dependencies
  CLAIM       A later subpass reads an earlier subpass's colour/depth/stencil output as
              an input attachment at the same pixel (subpassLoad / OpImageRead on
              SubpassData with the fragment's coordinate, per sample for multisample
              input attachments); subpass dependencies with stage/access masks (incl.
              BY_REGION) order the accesses; self-dependencies with
              vkCmdPipelineBarrier inside the subpass allow feedback (reading the pixel
              just written); preserve attachments keep contents across subpasses that
              do not use them.
  SOURCE      the subpass_dependencies / input attachment matrices in renderpass1/2;
              binding_model.shader_access.*.input_attachment.*;
              multiview.input_attachments.
  MECHANISM   Input attachment = a descriptor record pointing at the attachment image
              with the current layout; the FS reads it at (FragCoord.xy + offset, layer)
              through the image path (OpImageRead with Dim=SubpassData → coordinate =
              fragment position) — a small addition to shwave's image read (5b) plus the
              record kind; dependencies are free in the serialized engine today (one
              subpass completes before the next starts) but must become real pipeline
              fences in a tile engine (BY_REGION = the tile's own pixels — the classic
              TBDR win).
  REQUIRES    The input-attachment descriptor type in F5 records; per-sample input
              attachments with MSAA.
  FORBIDS     Reading input attachments through the sampler path with filtering; running
              a dependent subpass before the producer completed in a parallel engine.
  CHECK       the input-attachment families (CTS-2); engine: two-subpass G-buffer-like
              vector.
  COST        none now; the tile engine's subpass merging is a bandwidth win later.
  FEEDS       BM-L1 (input_attachment type), W4.5 tile engine; CTS-2.
  STATUS      not-run

LOGIC RP-L3 · Multisample resolve attachments (colour; depth/stencil with renderpass2)
  CLAIM       pResolveAttachments resolve each sample of a multisample colour attachment
              into a single-sample image at subpass end (average, or per the resolve
              mode for depth/stencil in renderpass2: SAMPLE_ZERO/AVERAGE/MIN/MAX as
              advertised by the depth-stencil resolve properties), sRGB in linear space,
              integer formats take sample 0, custom resolve (1.4-era EXT) optional.
  SOURCE      renderpass1/2 multisample_resolve.*, renderpass2 depth_stencil_resolve.*,
              custom_resolve.* (EXT), api.copy_and_blit.resolve_image.
  MECHANISM   PIPE-L4 MSAA storage + an Xfer resolve kernel (average in f32, encode) run
              at subpass end by cmdexec; depth/stencil modes as advertised
              (supportedDepthResolveModes/StencilResolveModes — SAMPLE_ZERO is required
              when the feature is present at 1.2).
  REQUIRES    MSAA (RAST-L4).
  FORBIDS     Resolving in encoded sRGB space; resolving outside the render area.
  CHECK       multisample_resolve.* at 4 samples (CTS-3).
  COST        a resolve pass per attachment (tile-local later).
  FEEDS       PIPE-L4; CTS-3.
  STATUS      not-run

LOGIC RP-L4 · Dynamic rendering and imageless framebuffers
  CLAIM       (1.3) vkCmdBeginRendering with the same attachment semantics incl. resolve
              modes, suspend/resume, secondaries, local read (1.4: reading attachments
              in the same rendering with input-attachment-like semantics after
              vkCmdPipelineBarrier); (1.2) imageless framebuffers bind the views at
              BeginRenderPass through VkRenderPassAttachmentBeginInfo.
  SOURCE      renderpasses.dynamic_rendering.* (27,766), imageless_framebuffer.* (6).
  MECHANISM   DRAW-L4; imageless = the framebuffer object holds only extents/usages and
              the views arrive with the begin record (cmdexec attachment resolve takes
              views from the record instead of the framebuffer payload).
  REQUIRES    1.2/1.3 ladder.
  FORBIDS     —
  CHECK       at 1.2/1.3 (CTS-3).
  COST        state path only.
  FEEDS       Zink, UE; CTS-3.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION RP-X1 · NotSupported by truthful absence
  CONDITION   fragment_density_map.* (EXT), dithering.* (EXT_legacy_dithering),
              custom_resolve.*, nested_command_buffers.* (EXT), performance_counters_
              by_region.*, dynamic_rendering.* and imageless_framebuffer.* before their
              versions, multisample families beyond advertised counts, formats not
              advertised as attachments.
  RESULT      NotSupported.
  TRUTH       profile lines / version ladder.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Advertising attachment support for a format without storeOp/loadOp/clear
              support for it.

EXCEPTION RP-X2 · Undefined contents latitude
  CONDITION   DONT_CARE loads/stores, unused attachments, contents outside the render
              area after DONT_CARE.
  RESULT      Any contents (the tests only check defined regions); a tile engine may
              skip the memory traffic entirely (the intended win).
  TRUTH       spec: undefined.
  MECHANISM   —
  CHECK       —
  FORBIDS     Relying on it to skip a STORE the application requested.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| RP-H1 Variable pass state | W4.1 | precondition | N attachments × M subpasses payload; render area; layers | — |
| RP-H2 Input attachments | CTS-2 | high | SubpassData read path + descriptor kind | — |
| RP-H3 Stencil aspects | PIPE-L2 | high | separate stencil load/store/clear | — |
| RP-H4 Resolves | RAST-L4 | medium | Xfer resolve kernel at subpass end | before MSAA exists |

## Performance / area / scalability

Render passes are the TBDR contract (§9): subpass dependencies with BY_REGION let the
tile engine keep G-buffers on chip; DONT_CARE lets it skip loads/stores. Knobs: tile
size, MRT/sample capacity per tile, bin list budget. Correctness-preserving: a subpass
boundary is an ordering point for the whole tile; input-attachment reads see the
producer's final value for that pixel (CTS-P3).
