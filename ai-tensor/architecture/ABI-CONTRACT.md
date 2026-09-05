# ABI contract (software view)

**Normative upstream:** [`architecture/ai-matrix/isa-encoding.md`](../../architecture/ai-matrix/isa-encoding.md)  
**Live MMIO notes:** [`corev_apu/ai_island/README.md`](../../corev_apu/ai_island/README.md)  
**This document:** what `ai-tensor` **implements and tests**, not a second ISA.

---

## 1. Ownership

| Layer | Authority |
|---|---|
| Opcode map, CSR addresses, trap rules, descriptor field layout | Monorepo **isa-encoding** (pin in VERSIONING) |
| Byte image of `desc_t` / `make_completion` | Must match `g6lc_ai_desc_pkg` when pin tracks that RTL |
| Framework tensor strides / NHWC vs tiled | **IR only** — lowered *into* the fixed descriptor |

If software needs a bit the ISA does not have, that is an **isa-encoding change**, not a torch hack.

---

## 2. Surfaces `ai-tensor-abi` must cover

### 2.1 T2 descriptor (64 bytes)

Logical fields (see isa-encoding §7 and island pkg):

- `version`, `op` (GEMM, CONV2D, LAYOUT, PREFETCH, …)
- `flags` (IRQ, priority, dtype/accmode/ew as defined upstream)
- `m`, `n`, `k`, `ld_ab`
- `ptr_a`, `ptr_b`, `ptr_c`, `ptr_scale`, `ptr_done`

**API:** `Desc64::pack` / `unpack`, builders with checked ranges, endianness = LE.

### 2.1a Desc64 v2 native scalar operands

The active descriptor version is **2**. Version 1 is rejected by the execution paths;
`Desc64::unpack` remains a lossless byte parser, not an execution adapter. Native A is
`A[m][k]` row-major and native B is **`B[n][k]` k-major**: the dot product reads
`A[i][t] * B[j][t]`. Both default leading dimensions are **K**, so
`ld_ab = k | (k << 16)`, never `k | (n << 16)`. Leading dimensions count **elements**,
not bytes. Each INT4 row starts on a byte boundary, low nibble first, with an unused high
nibble for odd K. Strided footprint is `(rows-1)*row_bytes(ld)+row_bytes(k)`; trailing
padding after the last logical row need not be present. C is packed row-major 32-bit LE.

The existing `gemm_s8` matrix interfaces continue to mean `A[m,k] @ B[k,n]` and explicitly
pack/transpose B at the native boundary. Raw byte interfaces never transpose or cast.
Strides must be at least K and fit the two u16 fields. Zero dimensions, truncated operands,
invalid AI-3 permissions, physical-memory extents and completion pointers are rejected
before any computed C write. Inputs may alias C in the software reference because the
whole result is computed before committing C; this is not a hardware aliasing guarantee.

| `flags[22:20]` | Native input | C32 semantics |
|---|---|---|
| 0 | signed INT8 | wrapping two's-complement i32 |
| 1 | signed packed INT4 | wrapping two's-complement i32 |
| 2 | SP24 | **unsupported even with the grant bit set** |
| 3 | FP8 E4M3 | ordered binary32 |
| 4 | FP8 E5M2 | ordered binary32 |
| 5 | IEEE FP16 | ordered binary32 |
| 6 | BF16 | ordered binary32 |
| 7 | IEEE FP32 | ordered binary32 |

FP widening is exact. E4M3 exponent 15 is finite except mantissa 7 (NaN); E5M2 uses
IEEE infinity/NaN encodings. FP8 signed zeros and subnormals are preserved by decoding.
BF16 widens by shifting bits 16 places; FP16 is exactly widened. Starting from +0,
each product rounds to f32 RNE, then each addition rounds separately to f32 RNE, in
increasing K order: **no FMA and no f64 reduction**. Every NaN C output is canonical
`0x7fc00000`. Native FP K-splitting is refused rather than changing reduction order.

`Caps.dtype_mask` preserves CAP `0x28`; ungranted formats report `ST_BAD_FMT=8`.
Default hardware-like software caps remain `0x0001`. The explicit software-reference-v2
profile grants `0x00fb` because the reference computes all seven scalar formats. It is
not a hardware/RTL grant, performance claim, or physical PCIe contract.

Existing historical code comments describing v1 are retained; this section and the explicit
v2 profile pins supersede their old row-major B/version-1 descriptions.

### 2.2 Completion word

Upstream: `{ reserved[15:0], status[15:0], ticket[31:0] }`.  
**API:** `Completion::from_u64`, status enum aligned with `ST_OK`, `ST_BAD_PTR`, …

### 2.3 MMIO control (profile-dependent offsets)

Documented in island README / `g6lc_ai_island_top`; package stores offsets in **abi + profile**:

| Range / off | Role |
|---|---|
| `0x0000..0x00FF` | CAP window (RO) — version, clusters, MacsPerCycle, ClockKhz, SramBytes, AccTile log2 pack, DRAM nameplate+meas, queues, dtype |
| `0x0100` | CTL: enable, **`wr_cpl_en`** |
| `0x0104..0x0114` | status / doorbell / done / ticket / dstatus |
| `0x0118/0x011C` | `desc_ptr` lo/hi (DMA fetch when doorbell[31]) |
| `0x0120+` | region program window |
| `0x0140..0x017F` | descriptor latch (16×32b) |
| `0x0180..0x018C` | **PMU** R beats / W beats / cycles / sustained milli-GB/s (sticky last GEMM) |

**API:** `mmio::*` constants, `CapRegs::from_words` / `decode_acc_tile`, `PmuSnapshot`.

### 2.4 T0 custom-2 (optional module)

Encodings for `ai.enq`, `ai.poll`, … as tables in abi. Used only when caps say T0 is available;
frameworks still build the **same** `Desc64` for pointer enqueue.

### 2.5 CSRs (discovery / privilege)

`aistatus` / `aicfg` / `aiperm` — primarily for kernel/SBI and advanced userspace; not required for
M2 sim GEMM.

---

## 3. Invariants

1. **Single pack path** — all backends call `ai-tensor-abi` (or the C ABI that wraps it).
2. **Self-describing jobs** — dtype and related fields live in the descriptor/flags per upstream
   contract; the engine must not depend on a mutable host CSR race (isa-encoding / scaling review).
3. **Null `ptr_done`** — means no completion-word write; status still via poll/MMIO/IRQ as caps allow.
4. **Golden tests** — fixtures checked against pin revision; breaking golden ⇒ pin bump or bug.

---

## 4. Versioning touchpoints

See [`VERSIONING.md`](VERSIONING.md):

- `abi_rev` — semantic version of this package’s pack format + status codes.
- `isa_doc_rev` — monorepo isa-encoding git blob / tag.
- `island_doc_rev` — `ai_island` README / RTL tag for MMIO.

Frameworks depend on **`abi_rev`**, not on monorepo paths.
