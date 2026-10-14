# `device-group` — single-device groups, DispatchBase, device masks (18 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/device-group.txt`; tests in
`external/vulkancts/modules/vulkan/device_group/vktDeviceGroupRendering.cpp`. Owner W2
(command decode/exec). Gate CTS-1. **Core at Vulkan 1.1** (VK_KHR_device_group promoted):
a one-device group must still implement the group entry points.

## Inventory

| case | |
|---|---|
| `device_group.{afr,sfr}` + `_dedicated`, `_dedicated_peer`, `_sys`, `_tessellated`, `_tessellated_linefill` | alternate-/split-frame rendering patterns over the group's devices |
| `device_group.compute_{alternate,split}_dispatch` + `_dedicated`, `_peer` | compute with `vkCmdDispatchBase` and per-device masks |
| **total** | 18 |

## Architectural logic

```text
LOGIC DG-L1 · A one-device group behaves as a group of one
  CLAIM       vkEnumeratePhysicalDeviceGroups returns one group with one device;
              VkDeviceGroupDeviceCreateInfo with that device is accepted;
              vkCmdSetDeviceMask(1) is accepted anywhere; VkDeviceGroupSubmitInfo /
              CommandBufferBeginInfo / RenderPassBeginInfo (per-device render areas) /
              BindSparseInfo masks of 1 are honoured; VkMemoryAllocateFlagsInfo with
              DEVICE_MASK bit and mask 1 allocates; peer memory features for (0,0) are
              the local features; dedicated allocations under the group flags work.
  SOURCE      device_group.afr*, sfr* (the `_sys` variants allocate system/host memory,
              `_dedicated` use dedicated allocations, `_peer` query peer features).
  MECHANISM   Mesa Venus already forwards the group structures; the decoder must KEEP
              them (device-group pNext structs on allocate/begin/submit) and vnfront must
              accept mask == 1 (anything else is invalid usage for one device); the
              per-device render area of VkDeviceGroupRenderPassBeginInfo overrides the
              render area for device 0 (cmdexec attachment resolve reads it).
  REQUIRES    `_tessellated*` variants need tessellation (W8) → NotSupported until then;
              the rest is pNext acceptance + one render-area override.
  FORBIDS     Refusing the structs as unknown pNext (they are core 1.1); ignoring the
              device render area (it changes the rendered region).
  CHECK       device_group.sfr, afr, *_dedicated, *_sys, compute_* (CTS-1).
  COST        decode rows.
  FEEDS       COMPUTE-L1 (DispatchBase); CTS-1.
  STATUS      not-run

LOGIC DG-L2 · vkCmdDispatchBase offsets the workgroup IDs
  CLAIM       vkCmdDispatchBase(baseX, baseY, baseZ, countX, countY, countZ) runs
              count workgroups whose gl_WorkGroupID starts at the base (NumWorkGroups =
              count) — requires the pipeline created with
              VK_PIPELINE_CREATE_DISPATCH_BASE_BIT.
  SOURCE      device_group.compute_{alternate,split}_dispatch*.
  MECHANISM   The dispatch record carries a base triple; shwave's WorkGroupID builtin
              adds it (today the base is implicitly 0). Pipeline flag accepted.
  REQUIRES    KEEP of the six words; a 3×32-bit base in the work record.
  FORBIDS     Treating DispatchBase as Dispatch (wrong IDs → the split-dispatch test
              writes the wrong halves).
  CHECK       the three compute_* cases (CTS-1); engine vector with a nonzero base.
  COST        three adders on the builtin path.
  FEEDS       CTS-1.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION DG-X1 · Tessellated variants
  CONDITION   `_tessellated`, `_tessellated_linefill` need tessellationShader (and
              fillModeNonSolid for linefill).
  RESULT      NotSupported until W8.
  TRUTH       profile `tessellationShader = false`.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     —
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| DG-H1 Accept the group structs | CTS-1 | high | KEEP + mask==1 acceptance + render-area override | — |
| DG-H2 DispatchBase | CTS-1 | high | base triple in the record, added in the builtin | — |

## Performance / area / scalability

None (control plane). A multi-device group is out of scope for this product.
