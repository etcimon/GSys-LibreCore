# `image/*` — storage images: load/store, atomics, format reinterpretation, mutable/extended usage, host image copy, queue transfer, subresource layout (136,625 cases, 30 lists)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/image/*.txt`; tests in
`external/vulkancts/modules/vulkan/image/vktImage*.cpp`. Owner W4 (sampler/storage path,
Xfer, layouts) with W2 (objects). Gates CTS-2 (`load-store`, `store`, `qualifiers`,
`image-size`, `subresource-layout`, `sample-texture`, `format-reinterpret`, `mutable`,
`extended-usage-bit*`, `texel-view-compatible`, `misaligned-cube`, `general-layout`),
CTS-3 (`atomic-operations`, `load-store-lod`, `load-store-multisample`, `depth-stencil-*`,
`concurrent-copy`, `queue-transfer`, `device-scope-access`), later (`host-image-copy` 1.4,
`swapchain-mutable` W9, `astc-decode-mode`, `extend-operands-spirv1p4`, `nontemporal`,
`2d-array-compatible`, `mismatched-*`, `non-uniform-offset-sample`).

## Inventory (lists and counts)

| list | cases | list | cases |
|---|---:|---|---:|
| `host-image-copy` | 73289 | `image-size` | 108 |
| `extended-usage-bit-compatibility` | 13248 | `depth-stencil-separate-access` | 81 |
| `mutable` | 10118 | `extend-operands-spirv1p4` | 81 |
| `texel-view-compatible` | 8640 | `qualifiers` | 56 |
| `atomic-operations` | 6208 | `depth-stencil-descriptor` | 42 |
| `format-reinterpret` | 5944 | `general-layout` | 29 |
| `subresource-layout` | 3537 | `non-uniform-offset-sample` | 24 |
| `load-store` | 3446 | `nontemporal-operand` | 21 |
| `swapchain-mutable` | 3240 | `2d-array-compatible` | 12 |
| `store` | 3012 | `sample-texture` | 8 |
| `queue-transfer` | 1965 | `misaligned-cube` | 5 |
| `load-store-lod` | 702 | `sample-cubemap` | 1 |
| `mismatched-write-op` | 464 | | |
| `device-scope-access` | 390 | | |
| `mismatched-formats` | 306 | | |
| `load-store-multisample` | 252 | | |
| `extended-usage-bit` | 216 | | |
| `concurrent-copy` | 216 | | |
| `astc-decode-mode` | 164 | | |

## Architectural logic

```text
LOGIC IMG-L1 · Storage image load/store on every storage format, type and mip/layer
  CLAIM       imageLoad/imageStore (OpImageRead/OpImageWrite) on 1D/2D/3D/cube/array/
              buffer images for every format with STORAGE_IMAGE support (the required
              list: R32 float/int/uint, RGBA8/16/32 families, R16G16B16A16, RG32 … and the
              shaderStorageImageExtendedFormats set when advertised), with and without
              format qualifiers (shaderStorageImageRead/WriteWithoutFormat), at any
              mip (load-store-lod) and layer, `coherent`/`volatile`/`restrict` qualifiers,
              imageSize/imageSamples queries, multisample storage images with sample
              index, mismatched-format access rules (texel-view-compatible classes).
  SOURCE      image.load_store.*, store.*, load_store_lod.*, load_store_multisample.*,
              qualifiers.*, image_size.*, mismatched_formats.*, mismatched_write_op.*,
              texel_view_compatible.*, extend_operands_spirv1p4.*, nontemporal_operand.*.
  MECHANISM   5b storage images (2D/2D-array, 12 formats, fetch/read/write); G3d adds
              1D/3D/cube/buffer dims and the extended format set (format table
              generation: each storage format needs a decode/encode pair); without-format
              reads/writes = the record's format drives the conversion (already the
              case) — advertise the two features once every storage format is handled.
  REQUIRES    Formats: generated table completeness (PIPE-H3); image-buffer dimension =
              texel buffers (API-L3); the texel cache must be coherent with stores
              (today dispatch-scoped: invalidate on store or write-through — verify for
              load-after-store in one dispatch across lanes: the slab/LSU is serial, the
              texel cache is read-only per dispatch? → a store followed by a load of the
              same texel in the same dispatch must see it: write-through + invalidate).
  FORBIDS     Caching texels across a store without invalidation; silent format
              mismatch "success" that returns garbage where the spec defines results.
  CHECK       image.load_store.basic_format.* (CTS-2), store.*, qualifiers.*,
              image_size.*, then lod/multisample (CTS-3).
  COST        format table; cache coherence logic.
  FEEDS       TEX-L1, API-L3; CTS-2.
  STATUS      not-run

LOGIC IMG-L2 · Image atomics
  CLAIM       imageAtomic{Add,Min,Max,And,Or,Xor,Exchange,CompSwap} on R32 int/uint (and
              R32 float add/min/max/exchange with the EXT; 64-bit with the EXT) storage
              images, including on sparse/3D/array/cube images, with the result values
              exact.
  SOURCE      image.atomic_operations.* (6208).
  MECHANISM   G3a-i's atomic RMW extended to the image address path (W_TX address →
              the same W_AT* RMW through the LSU) — formats R32_UINT/SINT only in core.
  REQUIRES    IMG-L1 address path; serialization point for cross-wave atomics (one LSU).
  FORBIDS     Non-atomic RMW across lanes/waves in any parallel texture unit (the
              atomic must go through the memory-side serialization, not a cache).
  CHECK       atomic_operations.{add,min,max,and,or,xor,exchange,compare_exchange}.
              2d.r32ui.* first (CTS-3).
  COST        none now; the L2-side atomic unit later (W5.6).
  FEEDS       MM-L1, GLSL-L5; CTS-3.
  STATUS      not-run

LOGIC IMG-L3 · Mutable formats, extended usage, format reinterpretation, subresource layout
  CLAIM       VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT images viewed with compatible formats
              (same texel block size class) read/write the raw bits consistently
              (format-reinterpret, mutable); EXTENDED_USAGE_BIT allows usage only valid
              for a view format; texel-view-compatible (compressed ↔ uncompressed views
              of the same block size, EXT/1.3 maintenance2); vkGetImageSubresourceLayout
              reports the LINEAR layout exactly (row/array/depth pitch, offset) for
              host access; general layout usable for everything; 2D views of 3D images
              (2D_ARRAY_COMPATIBLE); misaligned cube arrays.
  SOURCE      image.mutable.*, format_reinterpret.*, extended_usage_bit*.*,
              texel_view_compatible.*, subresource_layout.*, general_layout.*,
              2d_array_compatible.*, misaligned_cube.*.
  MECHANISM   One device layout per format class (5b: layer-major, 64-B aligned pitch)
              — views reinterpret bits trivially; the *view's* format in the record
              already drives decode (5b); subresource layout = the same formula as the
              device layout (true today); 3D images need depth slices in the layout
              with 2D views selecting a slice (layer = slice).
  REQUIRES    3D layout = array of slices (then 2D_ARRAY_COMPATIBLE is free); block-
              compressed layouts for texel-view-compatible.
  FORBIDS     A tiled/swizzled OPTIMAL layout that differs from LINEAR without a
              layout-aware copy path (if a tiled layout is ever introduced for
              performance, LINEAR must stay exactly the reported layout and OPTIMAL must
              be invisible except through copies).
  CHECK       mutable.*, format_reinterpret.*, subresource_layout.* (CTS-2).
  COST        none with the linear layout; a tiled layout is a W4.5 Pareto item
              (bandwidth) with a real correctness cost here.
  FEEDS       TEX-L3 (block views), API-L5; CTS-2.
  STATUS      not-run

LOGIC IMG-L4 · Depth/stencil as descriptors, queue transfers, concurrent copies, device-scope access
  CLAIM       Depth and stencil aspects sampled/stored separately through views;
              separate depth-stencil layouts (1.2); queue family ownership transfers
              for images (with one family: NotSupported variants) and concurrent
              copies from several queues; device-scope coherent access (memory model
              device scope through images).
  SOURCE      image.depth_stencil_descriptor.*, depth_stencil_separate_access.*,
              queue_transfer.*, concurrent_copy.*, device_scope_access.*.
  MECHANISM   Aspect-selective records (depth plane vs stencil plane of D24S8/D32S8
              layouts — PIPE-L2's layout decision determines whether a stencil view is a
              strided byte plane or a separate plane; a separate S8 plane makes both
              views trivial), one queue family today.
  REQUIRES    PIPE-L2 layouts; W8.7 queues for transfer variants.
  FORBIDS     —
  CHECK       depth_stencil_descriptor.* (CTS-3).
  COST        layout choice.
  FEEDS       PIPE-L2; CTS-3.
  STATUS      not-run

LOGIC IMG-L5 · Host image copy (1.4 core)
  CLAIM       vkCopyMemoryToImage/ImageToMemory/ImageToImage on the host for images
              created with HOST_TRANSFER usage, with the layouts the device lists as
              host-copyable, and vkTransitionImageLayout; identical results to device
              copies.
  SOURCE      image.host_image_copy.* (73,289 — the largest list in this family).
  MECHANISM   In the Venus model a host copy is performed by the guest driver
              (Mesa) into a mapped allocation *if* the image memory is host-visible and
              the layout is LINEAR-equivalent — our one device layout is exactly
              linear, so the renderer's job is to (a) report the layout truthfully
              (`vkGetImageSubresourceLayout2`) and (b) accept HOST_TRANSFER usage; the
              1.4 spec permits the copy to be a "host-side" operation using the
              reported layout only when the memory is host-visible… — the detailed
              Venus mapping (vn_image.c at the pin) must be read before designing.
  REQUIRES    1.4 ladder; W2 host-visible everything (device-local images are not
              host-visible — the spec's host copy on device-local memory implies a
              renderer-side copy command).
  FORBIDS     Pretending device-local images are host-copyable without a path.
  CHECK       at 1.4.
  COST        a renderer-side copy entry (Xfer) if Venus forwards it.
  FEEDS       INFO-L2 ladder (1.4 mandatory hostImageCopy).
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION IMG-X1 · NotSupported by truthful absence
  CONDITION   host_image_copy.* (1.4), swapchain_mutable.* (WSI), astc_decode_mode.*
              (ASTC + EXT), extend_operands_spirv1p4.* (before 1.2),
              load_store_multisample.* beyond advertised counts, atomic float/64-bit
              EXTs, queue_transfer/concurrent_copy multi-family variants,
              shaderStorageImageMultisample/ReadWithoutFormat/WriteWithoutFormat/
              ExtendedFormats while false, image dims/types not yet implemented (1D/3D/
              cube until G3d — these are *required*: see IMG-L1).
  RESULT      NotSupported.
  TRUTH       profile lines.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Leaving 3D/cube/1D unimplemented (core).

EXCEPTION IMG-X2 · Mismatched format access
  CONDITION   Reading/writing a storage image through a view whose format does not
              match the shader's declared format where the spec allows it (same
              bit-width classes, maintenance2 texel-view rules) or forbids it (UB).
  RESULT      Defined results for the allowed classes (bit reinterpretation); any
              result for the forbidden ones.
  TRUTH       spec + the `mismatched_*` tests' expectations (they test the allowed set).
  MECHANISM   record-format-driven conversion.
  CHECK       mismatched_formats.*, mismatched_write_op.*.
  FORBIDS     Faulting on a mismatch.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| IMG-H1 Format table | CTS-2 | high | generated decode/encode for the full storage list | — |
| IMG-H2 Dims | G3d | high | 1D/3D/cube/array layouts (slice = layer) | — |
| IMG-H3 Cache coherence on store | CTS-2 | high | write-through + invalidate in the texel cache | — |
| IMG-H4 Image atomics | CTS-3 | medium | RMW through the image address path | — |
| IMG-H5 Stencil plane | PIPE-L2 | medium | separate S8 plane layout | — |

## Performance / area / scalability

Storage-image traffic shares the texel cache; store-heavy compute (post-processing) is
bandwidth-bound → write coalescing per wave (same line) is correctness-preserving when
lanes write disjoint bytes (byte enables) and the store order within a lane is kept. A
tiled OPTIMAL layout is the one optimization here with correctness strings attached
(IMG-L3 FORBIDS).
