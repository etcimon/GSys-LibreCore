# Board UIO / eventfd bring-up — Xg6lcai island

**Status:** contract scaffold (hostless CI green; **live board open**)  
**Code:** `ai-tensor` `EventFdWait` / `UioIrqWait` · island PLIC-8 · MMIO `0x4000_0000`  
**DTS:** `corev_apu/bootrom/ariane-ai.dts`  
**Profile:** `ai-tensor/profiles/island-p3-v1.toml`

This document freezes the **board host path** for completions: how Linux (or a
bare userspace harness) maps the island, waits on IRQ, and claims DONE. It does
**not** ship a kernel driver yet.

---

## 1. Hardware contract (Variane / g6lc64_ai)

| Item | Value | Locus |
|---|---|---|
| MMIO base | `0x4000_0000` | `ariane_soc::AiIslandBase` / GPIO window |
| Window size | 4 KiB | CAP + CTL + doorbell + regions + desc + PMU |
| PLIC source ID | **8** | `irq_sources[7] = ai_irq` → PLIC ID 8 |
| Level IRQ | assert while `!cpl_empty && head.irq` | `g6lc_ai_island_top` / CPL FIFO |
| Claim | write `1` to DONE `@0x10C` | pop FIFO head; re-arms if next head.irq |
| CAP geometry | AccTile/Macs 256, queues 1 | `g6lc_ai_island_cfg` / CAP window |

Directed SoC smoke: `ai_irq_plic_smoke` (claim DONE **before** PLIC complete).

---

## 2. Host wait modes (ai-tensor)

| Mode | When | Env / feature |
|---|---|---|
| SoftSticky | Hostless CI | default |
| EventFd (soft) | Hostless EventFd API shape | `EventFdWait::soft()` / CLI `event-fd-soak` |
| EventFd (linux) | Board driver feeds eventfd | `linux-mmio`, `AI_TENSOR_EVENTFD=<fd>` |
| UIO | `/dev/uio*` map + IRQ read | `linux-mmio`, `AI_TENSOR_UIO=/dev/uio0` |
| `/dev/mem` | privileged phys map | `AI_TENSOR_MMIO_BASE=0x40000000` |

**Ordering (always):**

1. Submit with `FLAG_IRQ` if using IRQ wake  
2. Wait (UIO/eventfd/poll sticky)  
3. **Claim DONE** (clear level source)  
4. PLIC complete / UIO re-enable  
5. If CPL FIFO head still has IRQ, level re-arms — wait again  

Never PLIC-complete while DONE sticky still holds an IRQ-flagged head.

---

## 3. Device tree

`ariane-ai.dts` advertises:

- CPU `riscv,isa-extensions` includes **`xg6lcai`**  
- Node `ai-matrix@40000000` with `compatible = "g6lc,ai-matrix"`,  
  `reg = <… 0x40000000 … 0x1000>`, `interrupts = <8>`  
- Geometry properties for userspace discovery (must match CAP when live)

**Rule:** never boot this DTS on a package with `AiMatrixEn=0` (GPIO window is
an error slave; advertising `xg6lcai` would lie).

Cross-check procedure: `AGENTS-dts-validation.md` when Linux binding lands.

---

## 4. Kernel / UIO sketch (future driver)

Target userspace surface (M5/M6):

```text
/dev/g6lcai0          # or UIO: /dev/uioN + sysfs maps
  mmap CAP/CTL window @ 0x4000_0000
  eventfd / poll for IRQ (PLIC 8)
  ioctl: claim, program region, submit latch|fetch
```

Minimal **UIO platform** bind (conceptual):

1. Platform device from `g6lc,ai-matrix` OF node  
2. `uio_pdrv_genirq` or custom `uio` with `irq_handler` on PLIC 8  
3. Userspace: `AI_TENSOR_UIO=/dev/uio0` + `MappedWindow::open_linux`  
4. Prefer custom eventfd handoff for multi-process g6lcai later  

Driver must **not** auto-claim DONE; host runtime owns claim/pop FIFO.

---

## 5. Board bring-up checklist

- [ ] Boot `g6lc64_ai` (or FPGA bitstream) with island MatrixEn  
- [ ] Load `ariane-ai.dts` (or overlay) so `/proc/device-tree` shows `ai-matrix`  
- [ ] Confirm CAP version word `@0x00 == 1` via `/dev/mem` or UIO map  
- [ ] Directed: `ai_island_mmio_smoke` / `ai_irq_plic_smoke` on lab harness  
- [ ] Userspace: `AI_TENSOR_MMIO_BASE=0x40000000 cargo run -p ai-tensor-cli -- mmio-gemm`  
- [ ] IRQ path: `wait_policy=irq` profile + UIO or eventfd wire  
- [ ] Multi-claim: submit N FLAG_IRQ jobs, ordered claim 20→21→22 semantics  
- [ ] Never advertise xg6lcai without MatrixEn  

Hostless stand-ins already green: SoftIsland EventFd FIFO soak, SoC HARD peak
GEMM, PLIC smoke ELFs.

---

## 6. Related pins

| Artifact | Role |
|---|---|
| `ai-tensor/profiles/island-p3-v1.toml` | mmio_base, plic_source=8, backend linux-uio |
| `architecture/ai-matrix/completion-fifo.md` | DONE claim = pop |
| `architecture/ai-matrix/isa-encoding.md` | descriptor / FLAG_IRQ |
| `verif/tests/custom/ai/ai_irq_plic_smoke.S` | PLIC-8 directed |
| `monorepo-soak/run-ai-tensor.sh event-fd-soak` | hostless EventFd CI |
