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

**Queues:** CAP island_p3 advertises Queues=1; MMIO region window is only q0 (`0x0120`) before
desc latch (`0x0140`). SoftIsland returns `ST_BAD_QID` for foreign qids. Hostless **sim** keeps
4 soft regions for isolation soak.

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

