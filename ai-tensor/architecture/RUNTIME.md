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

**Ordering note (platform-specific):** completion DMA store and PLIC claim can interact on some
bring-up configs. Caps should expose whether claim-after-DMA is trusted; recommended sequence when
both enabled: ensure store finished → `fence` → claim. Island directed tests may disable `wr_cpl_en`
for pure claim soaks.

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

- **sim:** no OS; models AI-3 reject, ST_OK, completion write, virtual IRQ.
- **linux:** map island BAR/window; optional eventfd for IRQ.
- **cosim:** pipe to Verilator harness (slow gold).

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
