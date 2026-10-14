# `binding-model` — descriptor sets, updates, copies, indexing models (146,920 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/binding-model.txt`; tests in
`external/vulkancts/modules/vulkan/binding_model/vktBindingModel*.cpp`. Owner W2 (descriptor
storage F5/3d-c) with G3b (residency) and W5 (bindless/BDA). Gates CTS-1 (`shader_access`,
`descriptor_copy`, `descriptor_update.samplerless`), CTS-3 (`descriptorset_random`,
`buffer_device_address`), later (`descriptor_buffer`, `mutable_descriptor`, `descriptor_heap`).

## Inventory (`cts_ledger.py tree --group binding-model --depth 3 --min-cases 20`)

| prefix (`dEQP-VK.`…) | cases |
|---|---:|
| `binding_model` | 146920 |
| &nbsp;&nbsp;`binding_model.buffer_device_address` | 4716 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…set0 / set3 / set7 / set15 / set31` | 672 / 2016 / 672 / 672 / 672 |
| &nbsp;&nbsp;`binding_model.descriptor_buffer` | 5432 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…sparse_binding_buffer / sparse_residency_buffer / traditional_buffer` | 1807 / 1807 / 1818 |
| &nbsp;&nbsp;`binding_model.descriptor_copy` | 289 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…compute / graphics / graphics_uab` | 99 / 111 / 75 |
| &nbsp;&nbsp;`binding_model.descriptor_heap` | 431 |
| &nbsp;&nbsp;`binding_model.descriptor_update` | 123 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…acceleration_structure / samplerless` | 60 / 60 |
| &nbsp;&nbsp;`binding_model.descriptorset_random` | 35148 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…sets4 / sets8 / sets16 / sets32` | 14106 / 7014 / 7014 / 7014 |
| &nbsp;&nbsp;`binding_model.mutable_descriptor` | 14310 |
| &nbsp;&nbsp;`binding_model.shader_access` | 86412 |
| &nbsp;&nbsp;&nbsp;&nbsp;`…primary_cmd_buf / secondary_cmd_buf` | 45896 / 40516 |
| **total** | 146920 |

## Architectural logic

```text
LOGIC BM-L1 · Every descriptor type is readable by every stage through every binding shape
  CLAIM       Uniform/storage buffers (static and dynamic offsets), uniform/storage texel
              buffers, sampled images, storage images, samplers, combined image samplers
              and input attachments deliver the bound resource to the shader for single
              descriptors, contiguous and discrete arrays, multiple sets, and from both
              primary and secondary command buffers, in compute and every graphics stage.
  SOURCE      dEQP-VK.binding_model.shader_access.{primary,secondary}_cmd_buf.
              <type>.<stage>.<arrangement>.* (86,412); vktBindingShaderAccessTests.cpp.
  MECHANISM   32-byte descriptor records in aperture memory (§12.1 F5, 5b image half),
              `vkUpdateDescriptorSets` resolution at update time, LSU/texture fetch of the
              record by {set, binding, index} with the 8-entry record cache; dynamic
              offsets from the `BindDescriptorSets` payload; secondary command buffers
              via API-L4's EXECUTE record.
  REQUIRES    Texel-buffer descriptors (API-L3 / TEXELBUF-L1), input attachments
              (RENDERPASSES-L*: a fragment reads the current framebuffer pixel through
              an INPUT_ATTACHMENT record = image view + the fragment's coordinate),
              ≥ 4 bound sets honoured per stage, dynamic offset alignment limits.
  FORBIDS     Resolving descriptors at record time (breaks update-after-record
              semantics the test checks via "update then re-submit"); a binding-shape
              special case (contiguous vs discrete is a layout detail, not a path).
  CHECK       shader_access.primary_cmd_buf.{uniform_buffer,storage_buffer,
              *_dynamic,sampled_image,storage_image,sampler,combined_image_sampler}.
              compute.* first (CTS-1), then the graphics stages and secondary buffers.
  COST        Record fetch is one 32-byte read per distinct descriptor per wave today;
              the cache size and a per-dispatch prefetch are the knobs (W3.3 LSU).
  FEEDS       UBO-L*, SSBO-L*, IMAGE-L*, TEXTURE-L*; CTS-1.
  STATUS      not-run

LOGIC BM-L2 · Descriptor copies and samplerless updates are exact
  CLAIM       vkUpdateDescriptorSets copy entries move whole records between sets,
              bindings and array elements (including across types where allowed by
              VK_EXT_mutable only), and image descriptors updated without a sampler
              (samplerless: sampled/storage image, input attachment) are valid.
  SOURCE      dEQP-VK.binding_model.descriptor_copy.{compute,graphics,graphics_uab}.*,
              descriptor_update.samplerless.*; vktBindingDescriptorCopyTests.cpp,
              vktBindingDescriptorUpdateTests.cpp.
  MECHANISM   F5 copies are 32-byte moves through the pump's mp port; samplerless
              updates fill only the image half of the record (5b).
  REQUIRES    Copies preserve the poison bit semantics (a copied invalid record stays
              invalid, the destination set's poison is recomputed); `graphics_uab`
              (update-after-bind) needs DESCRIPTOR_INDEXING (BM-L4).
  FORBIDS     Re-resolving the source resource during a copy (copy the record bytes).
  CHECK       descriptor_copy.compute.*, descriptor_update.samplerless.* (CTS-1).
  COST        none beyond F5.
  FEEDS       CTS-1.
  STATUS      not-run

LOGIC BM-L3 · Randomised layouts at 4/8/16/32 sets
  CLAIM       Arbitrary legal combinations of set count, binding types, array sizes,
              inline uniform blocks, dynamic descriptors and (where advertised)
              descriptor-indexing flags produce correct shader reads.
  SOURCE      dEQP-VK.binding_model.descriptorset_random.sets{4,8,16,32}.*;
              vktBindingDescriptorSetRandomTests.cpp.
  MECHANISM   maxBoundDescriptorSets (4 today; UE RT wants ≥ 9, 1.4 minimum 7) → the
              cmdexec `dset[]` state and the record-fetch tag {set, binding} widths;
              inline uniform blocks (1.3 core) are a payload-backed descriptor type.
  REQUIRES    Parameterized set count (`MaxSets`) through cmdexec/vnfront/shwave tags;
              per-set binding-row table beyond 16 rows (BM-X2).
  FORBIDS     Clamping set indices; silently truncating binding counts.
  CHECK       sets4.* (CTS-1 subset: the non-indexing cases), sets8/16/32 after the
              parameter lands (CTS-3).
  COST        Tag widths in the record path; the binding-row CAM depth.
  FEEDS       BM-L4; CTS-3.
  STATUS      not-run

LOGIC BM-L4 · Bindless: descriptor indexing, buffer device address, descriptor buffers
  CLAIM       Non-uniform dynamic indexing into descriptor arrays with
              update-after-bind, partially-bound and variable-count flags (1.2 core
              feature descriptorIndexing); 64-bit buffer device addresses usable from
              shaders (1.2 core bufferDeviceAddress, capture/replay optional);
              VK_EXT_descriptor_buffer (descriptors placed by the application in
              memory — the pinned UE SM6 profile needs it, Mesa 26.0.8 Venus does not
              expose it yet).
  SOURCE      binding_model.buffer_device_address.set*.*, descriptorset_random (indexing
              cases), descriptor_buffer.*, descriptor_update.acceleration_structure.*;
              cts-descriptor-indexing.md for dEQP-VK.descriptor_indexing.*.
  MECHANISM   Descriptor records are already memory-resident with dynamic-index fetch
              (F5) — update-after-bind is therefore natural (the record is read at use);
              BDA needs the GPU virtual address of memory objects (W5.2 stable VA) and
              an LSU load/store path keyed by address rather than descriptor; descriptor
              buffers need the record format to be an application-visible layout
              (descriptor sizes/alignment properties) — our 32-byte record can be that
              layout if the image/sampler halves are stable and documented.
  REQUIRES    W5 VA model for BDA; W1 ledger entry for descriptor_buffer's Venus
              availability (release gate on official packages).
  FORBIDS     Faking BDA with a host-side translation (not stock-visible); emulating
              descriptor buffers by copying into our records at bind time without the
              correct update visibility semantics.
  CHECK       buffer_device_address.set0.* once BDA lands (CTS-3); descriptor_buffer.*
              and descriptor_heap.* stay NotSupported until advertised.
  COST        VA translation in the LSU path (TLB) — the W5 Pareto item.
  FEEDS       W5, W8 (bindless GPU-driven), UE SM6; CTS-3/4.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION BM-X1 · NotSupported by truthful absence
  CONDITION   mutable_descriptor.* (VK_EXT_mutable_descriptor_type), descriptor_buffer.*
              (VK_EXT_descriptor_buffer), descriptor_heap.* (the 1.4.6 heap extension),
              descriptor_update.acceleration_structure.* (ray tracing),
              descriptorset_random cases that require descriptorIndexing / inline
              uniform blocks / sets > maxBoundDescriptorSets, buffer_device_address.*
              (1.2 feature) at apiVersion 1.1.
  RESULT      NotSupported.
  TRUTH       Each is a profile line; BDA/indexing/inline-uniform-block flip to required
              at 1.2/1.3 (INFO-L2 ladder) — then BM-L4 is the owning card.
  MECHANISM   Profile ROM.
  CHECK       ledger not-supported column; the W1 ledger version table.
  FORBIDS     Advertising descriptorIndexing before update-after-bind visibility is
              proven (BM-L4) — the record cache must never serve a stale record across
              an update that the spec orders before the use.

EXCEPTION BM-X2 · Device limits on layout shape
  CONDITION   A layout exceeds our documented limits: > 16 binding rows per set (ObjPay
              row table), > 128 B push constants, > 4 sets.
  RESULT      vkCreateDescriptorSetLayout → VK_ERROR_OUT_OF_DEVICE_MEMORY (documented,
              §11 F5); sets > limit → the application cannot bind them (limit advertised).
  TRUTH       Legal only while the advertised limits say so; the 1.4 minima (7 sets,
              256 B push constants, maxPerStageDescriptor* ≥ 16/… ) make the current
              numbers release blockers (plan W10.2).
  MECHANISM   vnfront layout parse; profile limits.
  CHECK       shader_access cases that use many bindings; maintenance3_check.
  FORBIDS     Advertising a limit above the mechanism.

EXCEPTION BM-X3 · Poisoned sets
  CONDITION   An update references a destroyed/unbound resource or an out-of-range
              element.
  RESULT      The update returns nothing (per spec, no error); a later dispatch/draw
              using the poisoned set is DEVICE_LOST (our documented behaviour) — the CTS
              never does this deliberately in binding_model; robustness.* does (and
              expects robust results, not device loss) — see cts-robustness.md.
  TRUTH       Spec: using an invalid descriptor is undefined behaviour unless
              robustBufferAccess2/nullDescriptor; DEVICE_LOST is a permitted undefined
              outcome but a poor one — ROBUSTNESS-L* replaces it with zero-reads for
              the null-descriptor feature.
  MECHANISM   vnfront poison bit (aux[31]), cmdexec dispatch assembly.
  CHECK       ue_cneg_* engine vectors; robustness.* later.
  FORBIDS     Treating a poisoned record as a valid zero-size buffer silently in a
              non-robust context (it must be visible as device loss or robust zero, not
              as wrong data).
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| BM-H1 Compute first | CTS-1 | high | `shader_access.primary_cmd_buf.*.compute.*` for the buffer/image types already implemented | texel buffers / input attachments (own cards) |
| BM-H2 Secondary buffers | API-L4 lands | high | rerun the same cases under `secondary_cmd_buf` | — |
| BM-H3 Sets parameter | sets8+ needed | medium | `MaxSets` parameter through the tag widths; profile `maxBoundDescriptorSets` follows the elaborated value | the ObjPay row table is the real limit (fix BM-X2 first) |
| BM-H4 Bindless | 1.2 ladder | later | BDA on the W5 VA model | before the VA model exists |

## Performance / area / scalability

Descriptor fetch is on the per-wave critical path of every shader: the record cache (8
entries, dispatch-scoped) and the LSU serialization are the first roofline items (W1.5
counter: descriptor misses per wave). Knobs: record-cache entries, prefetch of a set's
rows at dispatch, `MaxSets`, binding-row table depth. Correctness-preserving: caching
records across a `vkUpdateDescriptorSets` that the spec orders before the use is not
(update-after-bind visibility = invalidate on update or on the ordering point).
