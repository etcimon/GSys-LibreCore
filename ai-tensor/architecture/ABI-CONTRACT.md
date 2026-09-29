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

### 2.2a Optional command-queue extension v1

The candidate queued profile consumes the design-side contract in
`architecture/ai-matrix/completion-fifo.md`; it does not change Desc64 v2.
CAP `0x0090` is zero when unavailable, otherwise `{depth[15:0], version[7:0], flags[7:0]}`.
Version1 flags7 advertise presence, descriptor-pointer commands and the VALID/READY seam.
The live hardware defaults still advertise zero until integration qualification.

MODE is `0x0f20`; pointer low/high, full-u32 ticket and qid staging are `0x0f24..0x0f30`.
SUBMIT `0x0f34` attempts admission once. CREDITS `0x0f38` is advisory. Receipt ticket/code
at `0x0f3c/0x0f40` distinguishes accepted0, full/contention1, disabled2; accepted/rejected
MMIO attempt counters are `0x0f44/0x0f48`. No completion is owed for a rejected attempt.
AI-3/CTL/legacy doorbell/reuse-policy writes are locked while MODE=1; rejected writes
raise APB slave error and cannot mutate the queued protection context. Mode changes
require all accepted commands, active work and completion records to drain.

C/Python/Rust constants are checked in lockstep. `QueuedMmioSession` is an explicit,
single-owner pointer/lease API, not an implicit replacement for the legacy session or a
multi-process DMA driver. The caller supplies immutable descriptor/operand storage and
keeps the session alive until every lease is returned. This API requires monotonically
increasing accepted tickets without wrapping. A verified full receipt permits retry of
that unaccepted ticket; an ambiguous receipt or I/O failure retains its lease and blocks
new submission until resolved. Timeouts and foreign FIFO heads do not release leases.
This is protocol coverage, not guest-QEMU execution evidence; core-instruction producer
and emulator implementation remain separate qualification gates.

### 2.3 MMIO control (profile-dependent offsets)

Documented in island README / `g6lc_ai_island_top`; package stores offsets in **abi + profile**:

| Range / off | Role |
|---|---|
| `0x0000..0x00FF` | CAP window (RO) — version, clusters, MacsPerCycle, ClockKhz, SramBytes, AccTile log2 pack, DRAM nameplate+meas, queues, dtype |
| `0x0100` | CTL: enable, **`wr_cpl_en`** |
| `0x0104..0x0114` | status / doorbell / done / ticket / dstatus |
| `0x0118/0x011C` | `desc_ptr` lo/hi (DMA fetch when doorbell[31]) |
| `0x0120` | queue 0 region window (0x20 bytes; perm write commits) |
| `0x01A0+(q-1)*0x20` | queue `q≥1` region. Not `0x0120+q*0x20` — that address is the descriptor latch |
| `0x0140..0x017F` | descriptor latch (16×32b) |
| `0x0180..0x018C` | **PMU** R beats / W beats / cycles / sustained milli-GB/s (sticky last GEMM) |

**API:** `mmio::*` constants, `CapRegs::from_words` / `decode_acc_tile`, `PmuSnapshot`.

The MMIO doorbell carries only **23 ticket bits** (`[30:8]`); bit 31 selects descriptor
fetch. This is narrower than the 32-bit completion ticket. Rust latch/fetch submission
rejects tickets above `0x007fffff` before changing the latch or allocating a descriptor.
The Python UIO session allocates tickets 1 through that maximum and refuses exhaustion
rather than wrapping into a previous identity. Reopening requires the caller to have drained
and quiesced the device; it is not a hardware reset or generation protocol.

C/Python/Rust lockstep checks include the queue-0/tail offsets and doorbell ticket maximum.
Python `queue_region(qid)` follows the split region map; queue 1 must never program DESC.
No descriptor version or field meaning changed in these protocol repairs.

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

## Accumulate mode (`flags.accmode == 01`) — extension, ABI 2.2.0

- Request: `flags[11:10] = 01`. Semantics: each output's ordered reduction starts from the
  i32 (integer formats) or f32 (float formats) word already stored in C, then proceeds
  exactly as `accmode == 00`. Integer results are therefore `C + A·B` exactly; float results
  equal one long ordered reduction over the concatenated K blocks, bit for bit.
- Grant: CAP word `0x0094` (`CAP_ACCMODE`), bit 0. Software MUST read it; a device without
  the bit completes `accmode == 01` with `ST_BAD_FMT` and must not demote to overwrite.
  The live island (`AiIslandAccmodeGrant = 1`), the software reference and the
  `software-reference-v2` device grant it. `accmode == 1x` remains reserved (`ST_BAD_FMT`).
- Hardware note: the RTL reduces each K step through a PE lane tree, so a chained K-split
  equals one long job bit for bit when every block boundary is a multiple of the lane
  count (the live AccTile K = 512 = lane count, which the `torch_backend` blocking uses).
  The software reference is sequential and exact for any split. An accumulate job loads
  the C tile first (m*n*4 extra read bytes) and does not overlap stores with the MAC.
- Descriptor layout, version and every other field are unchanged (reserved encoding enabled
  behind a new RO grant word), so this is an extension, not a version bump.
- Python: `Device.gemm_native(..., c_init=)`; Rust: `numfmt::gemm_native_acc`,
  `check_desc_engine_acc`, `Caps.accumulate`; C: `AI_TENSOR_CAP_ACCMODE`,
  `AI_TENSOR_ACCMODE_ACCUMULATE`. `torch_backend` chains float K blocks through it.

## Operand bank capacity (`CAP_BANK_A_BYTES` 0x98, `CAP_BANK_B_BYTES` 0x9C)

Read-only words giving the island's A and B operand bank capacity in bytes. A part that
publishes both non-zero boxes a job by **panel bytes**, not by `AccTileK`:

    pitch_bytes(k) = next_pow2(ceil(row_bytes(k) / macs_per_cycle)) * macs_per_cycle
    accepted iff  m <= AccTileM, n <= AccTileN, k <= 65535,
                  n * pitch_bytes(k) <= CAP_BANK_B_BYTES, m * pitch_bytes(k) <= CAP_BANK_A_BYTES

so a 256 x 1024 INT8 weight panel is one job (the same bytes as 512 x 512) and one
`FLAG_REUSE_B` key. A part publishing 0 keeps `k <= AccTileK`. Software: `Caps.fits`,
`Caps.max_k`; `accmode 01` still chains K beyond the banks. Refusal is `ST_ERR` at the
engine's geometry check, before any operand traffic.
