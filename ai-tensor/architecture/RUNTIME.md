# Runtime model

**Implements:** device lifecycle for island T2 (and optional T0).  
**Backends:** sim (mandatory), linux (optional), cosim/replay (optional).

---

## 1. Objects

| Object | Role |
|---|---|
| **Caps** | CAP window + profile: AccTileM/N/K, MacsPerCycle, NocWidth, `wr_cpl_en`, `compute_ref`, `t0_enq`, … |
| **PmuSnapshot** | Last-job R/W beats, cycles, milli-GB/s (MMIO 0x180–0x18C or sim fake) |
| **Device** | One island instance (or sim) |
| **Buffer** | Host memory registered / mapped for AI-3 |
| **Region** | Programmed `[base, limit)` + R/W on a queue |
| **Queue** | Logical qid; isolation/QoS later (I2+) |
| **Job** | Packed `Desc64` + ticket + submit mode |
| **Completion** | Ticket + status (+ optional word at `ptr_done`) |

---

## 2. Submit modes (same desc)

| Mode | Mechanism | When |
|---|---|---|
| **MMIO latch** | Write desc words + doorbell (bit31=0) | Bring-up, small tests |
| **MMIO fetch** | `desc_ptr` + doorbell bit31 | Descriptor in DRAM |
| **T0 enq** | `ai.enq` / sideband; rs1=0 latch, rs1≠0 fetch | Low-latency control path |

Runtime chooses mode from **Caps + profile**, not from framework type.

---

## 3. Wait modes

| Mode | Use |
|---|---|
| **Poll** | MMIO done sticky / `ai.poll` / completion word spin |
| **IRQ** | PLIC source (e.g. ID 8 on Variane) or MSI; level rules: clear source before complete |
| **Hybrid** | IRQ wake + read completion word |

**Software `WaitPolicy`** (`policy.rs` / CLI `queue-soak`):

| Policy | Use |
|---|---|
| `Poll` | Default spin on `poll(ticket)` |
| `IrqThenPoll` | FLAG_IRQ jobs; wait `irq_pending` then claim |
| `DmaThenClaim` | `wr_cpl_en=1`: spin completion word @ `ptr_done`, then `claim_done` |
| `ClaimOnly` | Island claim soak with `wr_cpl_en=0` (no DMA word) |

**Ordering:** when both DMA and PLIC/IRQ are enabled, preferred order is **DMA word visible →
fence → claim DONE / clear IRQ**. Island directed tests may keep `wr_cpl_en=0` for pure claim.

**Queues:** the sim pin advertises Queues=1. RTL queue 0 stays at `0x0120`. Later queues
start at `0x01A0` (stride `0x20`) so they do not cover the descriptor latch at `0x0140` or the
PMU at `0x0180`. SoftIsland returns `ST_BAD_QID` for a qid the CAP does not advertise. Hostless
**sim** keeps 4 soft regions for isolation soak.

**IRQ wait** (`irq.rs`):

| Mode | When |
|---|---|
| `SoftSticky` | CI / SoftIsland — poll `irq_pending` then claim DONE |
| `Uio` | `linux-mmio` + `/dev/uio*` — blocking read event count |
| EventFd | Hostless soft counter + board PLIC eventfd (EventFdWait); claim before re-enable |

Island_p3 Variane: **PLIC source 8**. Always **claim DONE before PLIC complete** (level re-arm).
Stream path accepts `WaitPolicy` via `run_gemm_s8_stream_with_policy` and
`SubmitMode::{Latch,Fetch}` via `run_gemm_s8_stream_ex` / `Device::submit_fetch`.

**Queue depth / CPL FIFO:** CAP queue_depth bounds SoftIsland history and matches island
g6lc_ai_cpl_fifo (oldest-first claim). Engine is still single-outstanding; FIFO holds finishes.
EventFdWait + head.irq re-arm after claim (soak_eventfd_fifo_multi).

**Completion history (SoftIsland):** ring of last queue_depth completions with per-entry IRQ;
poll(ticket) after head advances (soak_history_poll). RTL DONE claim = pop FIFO head.



**Host probe:** `ProbeReport::to_json` / CLI `probe` / `doctor --json` — CAP, PMU, IRQ contract,
profile wait/submit pins for monorepo discovery. Schema: `schemas/probe.v1.json`.

**HostRuntime:** framework-facing FIFO of GEMM jobs; drain uses profile `submit_mode` +
`wait_policy` and multi-tile stream. Engine still one-at-a-time; queue is host-side only.
CLI: `host-run --jobs N`.

---

## 4. Backend trait (conceptual)

```text
probe() -> Caps
map/unmap(Buffer)
program_region(qid, range, perm)
submit(Job) -> ticket
poll(ticket) -> Option<Completion>
wait(ticket | irq, timeout) -> Completion
```

- **sim:** no OS; direct job path (no register protocol).
- **mmio-soft (`SoftIsland`/`MmioDevice`):** hostless register model — CAP probe, AI-3 region
  commit on perm write, desc latch, doorbell (latch or fetch), DONE claim clear, PMU sticky.
- **mapped-file / linux:** `MappedWindow` file-backed for CI; feature `linux-mmio` opens
  UIO or `/dev/mem` (`AI_TENSOR_UIO`, `AI_TENSOR_MMIO_BASE=0x40000000`). SoftIsland models
  FLAG_IRQ sticky cleared with DONE (PLIC claim discipline).
- **cosim:** offline dual oracle (sim + SoftIsland) always; optional external process via
  `AI_TENSOR_COSIM_CMD` → `tools/cosim_harness.py` (JSON stdin). Live Verilator/ELF is
  lab-only (`AI_TENSOR_RTL_CMD`), never a crate path dep.
- **stream:** multi-tile desc stream (`run_gemm_s8_stream`) — full A/B resident, AccTile
  jobs with strided `lda`/`ldb`, sequential tickets on one `Queue`; host accumulates C.

---

## 4a. Native scalar reference APIs

```python
from ai_tensor.numfmt import gemm_native, pack_bits, decode_bits
c32 = gemm_native(a_bytes, b_kmajor_bytes, m, n, k, numfmt,
                  lda=None, ldb=None, dtype_mask=0x00fb)
```

This stable dependency-free API returns **bytes**, not converted Python floats or ints.
`pack_bits(rows, numfmt, ld=None)` packs already-known native bit patterns without defining
new quantization/overflow rules. `decode_bits(bits, numfmt)` exposes exact widening for
reference tests. All binary inputs/outputs are little-endian; native FP32 arrays may be
supplied via a framework byte view without a numeric conversion.

`Device('software-reference-v2').gemm_native(a, b, m, n, k, numfmt, lda=None, ldb=None)`
uses the same contract with caps/tile checks. `Device('sim')` remains conservative unless
software-reference caps are explicitly selected. `QemuUioSession.gemm_native` stages the
native bytes, submits the v2 descriptor through the existing latch/MMIO route and returns
C32 bytes. It reads the dtype grant mask from CAP `0x28` and does not grant FP itself.
`run_gemm_native(dev, m, n, k, a, b, fmt, lda, ldb, ticket)` is the Rust equivalent,
returning `(Vec<u8>, Completion)`; SimDevice and SoftIsland share one `numfmt` module.

This is a functional reference, not a cycle/timing model or a full QEMU guest. Model
loading, JSON evaluator glue and generated g6lc_qemu evaluation belong to consumers
outside this package. Generic byte paths never demote to INT8. Legacy explicit S8
framework convenience functions retain their intentional int8 conversions. Virt-card's
matrix convenience transport remains S8-only and rejects non-INT descriptors; its native
byte API is not implemented. Generic native methods report that limitation rather than
reinterpret bytes. Native non-S8 multi-tile/streaming and FP hardware loader integration
remain separate work.

## 5. Memory profiles

| Profile | Description |
|---|---|
| `shared-va` | Card story: CPU and island share PA/IOVA; pin user pages |
| `identity-bringup` | Bare maps; tests only |
| `bounce` | Explicit copies (last resort / discrete memory SKU) |

Default for framework docs: **`shared-va`**. Fail closed if region programming missing.

---

## 6. Error model

Map island statuses to a small stable enum for frameworks (`Ok`, `BadPtr`, `Disabled`, `Timeout`,
`UnsupportedOp`, …). Do not leak raw MMIO bit soup into Python.

---

## 7. Independence

Runtime **sim** must not `include!` monorepo paths. Linux backend may read sysfs/DTS at runtime.
Profiles load MMIO offsets from package data files generated or copied under the VERSIONING pin.

## 9. Cosim / goldens

- **Offline (CI):** `run_builtin_suite()` runs package-local INT8 vectors on **sim** and
  **SoftIsland**; CLI `golden-check`.
- **Auto-tile:** `run_gemm_s8_auto` streams AccTile blocks when m/n/k exceed CAP.
- **External:** set `AI_TENSOR_COSIM_CMD` to a host command; default CI leaves it unset.
- **Monorepo:** `bash monorepo-soak/run-ai-tensor.sh test` spawns this package only.

