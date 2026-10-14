# `ubo` (13,240) and `ssbo` (12,225) — buffer block layouts, access, physical storage buffers

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/ubo.txt`, `vk-default/ssbo.txt`;
tests in `external/vulkancts/modules/vulkan/ubo/vktUniformBlockTests.cpp` and
`ssbo/vktSSBOLayoutTests.cpp`. Owner W3 (shmod layout tables, shwave LSU) with W2 (descriptor
records). Gate CTS-1.

## Inventory

| `dEQP-VK.ubo.` | cases | | `dEQP-VK.ssbo.` | cases |
|---|---:|---|---|---:|
| `single_basic_type` | 3384 | | `layout` | 5275 |
| `random` | 2250 | | `phys` (physical storage buffer / BDA) | 5275 |
| `single_basic_array`, `2_level_array`, `3_level_array`, `instance_array_basic_type` | 1512 each | | `readonly` | 1662 |
| `unsized_array` | 972 | | `unsized_array_length` | 12 |
| `multi_basic_types`, `multi_nested_struct` | 120 each | | `corner_case` | 1 |
| `single_struct*`, `single_nested_struct*`, `2_level_struct_array` | 72 / 54 | | | |
| `link_by_binding` | 4 | | | |

Each ubo/ssbo case is a block declaration (std140/std430/scalar, row/column major, matrix
strides, arrays of arrays, nested structs, instance arrays, unsized trailing arrays)
exercised in vertex, fragment and "both" shaders, comparing every member read (and SSBO
write) against the host layout.

## Architectural logic

```text
LOGIC UBO-L1 · std140/std430 layouts are honoured member by member
  CLAIM       Offsets, array strides, matrix strides and row/column majorness declared by
              the SPIR-V decorations (Offset, ArrayStride, MatrixStride, RowMajor/
              ColMajor) are the only source of addresses for block members; nested
              structs, arrays of arrays, instance arrays (block[N] with per-instance
              descriptors), unsized trailing arrays with OpArrayLength (SSBO), 8/16-bit
              and scalar block layout only with their features; UBO reads of every
              basic type incl. bool and (u)int vectors; SSBO reads and writes incl.
              `readonly`/`writeonly` blocks and atomics on members.
  SOURCE      ubo.*, ssbo.layout.*, ssbo.readonly.*, ssbo.unsized_array_length.*,
              ssbo.corner_case.
  MECHANISM   shmod member table (offset/mstride/flags per member, G3a-i natural layout
              for undecorated structs), shwave LSU address = base + Σ decorated offsets
              (AccessChain), matrix row-major handling (W_MS/W_LS matrix paths read
              column rows — RowMajor needs the transposed stride walk), OpArrayLength =
              (descriptor size − offset) / stride from the record; instance arrays =
              descriptor array index selects the record.
  REQUIRES    RowMajor matrices in blocks (verify: 4b matrices are column rows in RF;
              a RowMajor member must be loaded with stride = MatrixStride per *row*);
              bool members as 32-bit; maxUniformBufferRange ≥ 16384 honoured by the
              record size; descriptor array of blocks (instance_array) via F5 index.
  FORBIDS     Deriving layout from the GLSL type instead of the decorations (the random
              cases decorate oddly but legally).
  CHECK       ubo.single_basic_type.* and ssbo.layout.basic_*.* in compute… (these are
              vertex/fragment tests — they need the draw path: run under CTS-2 for the
              graphics variants; the `ubo`/`ssbo` groups have no compute variant — the
              engine corpus's compute vectors cover layouts until then).
  COST        none (address arithmetic).
  FEEDS       GLSL-L1, BM-L1; CTS-1/2.
  STATUS      not-run

LOGIC SSBO-L2 · Physical storage buffers (BDA) — ssbo.phys
  CLAIM       With bufferDeviceAddress, blocks accessed through 64-bit device addresses
              (PhysicalStorageBuffer storage class, OpConvertUToPtr, pointer arithmetic,
              Aligned memory operands) behave like descriptor-bound SSBOs.
  SOURCE      ssbo.phys.* (5275).
  MECHANISM   BM-L4 (W5 VA model + address-keyed LSU path).
  REQUIRES    1.2 ladder.
  FORBIDS     —
  CHECK       at CTS-3.
  COST        the VA path.
  FEEDS       BM-L4.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION UBO-X1 · Feature-gated layouts
  CONDITION   scalarBlockLayout (1.2 feature; Zink wants it or 1.2), 8/16-bit storage
              cases, bufferDeviceAddress (ssbo.phys), storageBuffer16BitAccess.
  RESULT      NotSupported.
  TRUTH       profile lines; scalar layout is an address-arithmetic-only change (cheap to
              adopt early).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     —

EXCEPTION UBO-X2 · Robust reads
  CONDITION   Reads past the bound range (not in these groups; robustness.*).
  RESULT      Zero per robustBufferAccess.
  TRUTH       advertised.
  MECHANISM   LSU record size check.
  CHECK       robustness.buffer_access.*.
  FORBIDS     —
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| UBO-H1 RowMajor + nested arrays audit | CTS-1 | high | engine vectors for RowMajor mat3x2 arrays / arrays of structs of arrays vs the model; fix the stride walk | — |
| UBO-H2 Scalar layout | Zink | medium | accept the ScalarBlockLayout alignments (no new mechanism) | — |

## Performance / area / scalability

UBO reads are the hottest loads in real shaders (per-draw constants): a broadcast path
(wave-uniform address → one fetch for all lanes) and a small uniform cache are W3.3
items; correctness-preserving because the address is provably uniform (same
descriptor, constant offset) — not value-based.
