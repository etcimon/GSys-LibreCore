# `dynamic-state` — dynamic pipeline state across pipeline kinds (671 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/dynamic-state.txt`; tests in
`external/vulkancts/modules/vulkan/dynamic_state/vktDynamicState*.cpp`. Owner W4 (cmdexec
state snapshot, rast). Gate CTS-2 for `monolithic.*`; the pipeline-library / shader-object
variants are NotSupported by absence of VK_EXT_graphics_pipeline_library / VK_EXT_shader_object.

## Inventory

| prefix (`dEQP-VK.dynamic_state.`…) | cases |
|---|---:|
| `monolithic` (`vp_state`, `rs_state`, `cb_state`, `ds_state`, `general_state`, `compute_transfer` 124, `inheritance`, `discard`, `clear`, `line_width`, …) | 185 |
| `pipeline_library` / `fast_linked_library` | 61 / 61 |
| `shader_object_unlinked_spirv` (`compute_transfer` 124) / `shader_object_*` | 184 / 60 ×3 |
| **total** | 671 |

## Architectural logic

```text
LOGIC DS-L1 · Every 1.0 dynamic state is applied at draw time from the last set command
  CLAIM       Viewport, scissor, line width, depth bias, blend constants, depth bounds,
              stencil compare/write masks and reference are read at each draw from the
              most recent vkCmdSet* (per command buffer, including after pipeline
              switches between pipelines that make the state static/dynamic, and across
              secondary command buffers per the inheritance rules); static state comes
              from the pipeline; the two never mix for one state.
  SOURCE      dynamic_state.monolithic.{vp_state,rs_state,cb_state,ds_state,
              general_state,inheritance,discard,clear,…}.*;
              vktDynamicStateVPTests.cpp, RSTests, CBTests, DSTests, GeneralTests,
              InheritanceTests.
  MECHANISM   cmdexec keeps the current dynamic values in its draw snapshot (G1c: vp/sc;
              G2a: blend constants, depth reference) — extend to line width, depth bias,
              depth bounds, stencil masks/reference (front/back), and a per-state
              "dynamic in the bound pipeline" mask so a pipeline bind restores static
              values; secondaries inherit nothing except what the spec says (state is
              undefined at secondary begin unless inherited by extension).
  REQUIRES    Stencil (RAST-L3), depth bias/bounds (DRAW-L2), line width (RAST-L1 wide
              lines are optional — width 1 only without wideLines).
  FORBIDS     Applying dynamic values when the pipeline declares the state static (the
              tests switch pipelines to catch exactly that).
  CHECK       dynamic_state.monolithic.vp_state.*, cb_state.*, ds_state.* (CTS-2).
  COST        snapshot words only.
  FEEDS       PIPELINE-L*; CTS-2.
  STATUS      not-run

LOGIC DS-L2 · Dynamic state has no effect on compute/transfer
  CLAIM       Setting graphics dynamic state around dispatches and copies neither
              affects them nor is affected by them (`compute_transfer` 124).
  SOURCE      dynamic_state.monolithic.compute_transfer.*.
  MECHANISM   The snapshot belongs to the graphics draw path only.
  REQUIRES    —
  FORBIDS     Shared state registers between dispatch and draw records.
  CHECK       the family (CTS-2).
  COST        none.
  FEEDS       CTS-2.
  STATUS      not-run

LOGIC DS-L3 · Extended dynamic state (1.3 core subset; EXT 1/2/3 optional)
  CLAIM       1.3 core: cull mode, front face, primitive topology, viewport/scissor with
              count, vertex input binding stride, depth test/write/compare/bounds enable,
              stencil test enable and op, rasterizer discard, depth bias enable,
              primitive restart enable set dynamically.
  SOURCE      the `general_state` / `rs_state` extended cases gated on the feature;
              pipeline.monolithic.extended_dynamic_state (cts-pipeline.md).
  MECHANISM   same snapshot mechanism; the draw record's static fields become "from
              pipeline or from dynamic" per state.
  REQUIRES    1.3 ladder.
  FORBIDS     —
  CHECK       at 1.3 (CTS-3).
  COST        snapshot words.
  FEEDS       Zink (extended dynamic state is a large Zink performance lever); CTS-3.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION DS-X1 · NotSupported by truthful absence
  CONDITION   pipeline_library.*, fast_linked_library.* (VK_EXT_graphics_pipeline_
              library), shader_object_* (VK_EXT_shader_object), extended dynamic state
              cases at 1.1, wideLines/depthBounds/depthBiasClamp features where false.
  RESULT      NotSupported.
  TRUTH       profile lines; EXT_graphics_pipeline_library is a UE/Zink performance
              feature to evaluate in W8 (shader stutter), not a correctness gate.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     —
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| DS-H1 Complete the 1.0 set | CTS-2 | high | the remaining dynamic fields + the static/dynamic mask on bind | stencil/bias cards not landed (land them first) |
| DS-H2 1.3 set | ladder | medium | per-state source selector | — |

## Performance / area / scalability

State is words in the draw record; the only throughput note is that a tile engine must
snapshot dynamic state per draw into the bin stream (CTS-P3), which sizes the bin record.
