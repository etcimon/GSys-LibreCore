# virt-ai-pcie — virtual PCIe AI card (hostless)

**Status:** custom · **class:** `virtual` · **skidl:** omitted (no PCB)  
**Spec:** `corev-mb/boards/virt-ai-pcie/board.json`  
**Driver:** `ai-tensor/tools/virt_ai_card/` (userspace UIO/eventfd, pure Python)

Hostless stand-in for the **PCIe endpoint CPU+AI card** described in
`architecture/uncore/pcie-endpoint.md` and `architecture/ai-matrix/README.md`.
It exercises the same AI island MMIO / DONE-claim / eventfd discipline as a real
board (`architecture/ai-matrix/board-uio-eventfd.md`) without kernel modules,
hard PHY, or a real PCIe link.

---

## 1. Intent

| Real card (P5/P6) | This virtual board |
|---|---|
| PCIe endpoint + BAR0/2/4 | `VirtualPcieLink` localhost TCP (JSON framing) |
| virtio-net + SSH workload push | host_client → card_agent job protocol |
| BAR4 bulk tensor mmap | in-process buffer or socket copy |
| `/dev/uio0` + eventfd | `VirtualUioDevice` + `VirtualEventFd` (soft-sticky) |
| `g6lc64_ai` + island RTL | SoftIsland-like pure-Python INT8 GEMM on doorbell |

Use it for **CI smoke** of the host/card data path and claim order before a
lab FPGA/ASIC board is wired. It is **not** a timing model and not a flist
entry.

---

## 2. BAR / virtio / SSH simulation map

| Logical BAR / device | Real outline | Virtual model |
|---|---|---|
| BAR0 (64 KB) | mgmt + AI CAP window | `VirtualUioDevice` 4 KiB CAP/CTL map @ `0x4000_0000` |
| BAR2 | virtio-pci queues | control messages over TCP JSON (`gemm_s8`, status) |
| BAR4 | bulk DRAM window | `bar4` blob transfer in protocol (list/bytes) |
| virtio-net / SSH | host `g6lc0` + `sshd` | `card_agent` bind + `host_client` connect |
| MSI / PLIC-8 | level IRQ | `VirtualEventFd` counter + DONE sticky |

MMIO offsets match the island contract (CAP @0x00, CTL @0x100, DOORBELL @0x108,
DONE @0x10C, TICKET @0x110, DSTATUS @0x114, REG0 @0x120, DESC @0x140, PMU @0x180).

**Claim order (always):** wait IRQ/eventfd → **claim DONE** (write 1 @0x10C) →
clear/rearm. Never re-arm while DONE head still holds an IRQ-flagged completion.

---

## 3. UIO soft driver (board.json `ai{}`)

Primary connector is **soft-sticky** for hostless CI:

```json
"uioConnectors": {
  "island0": {
    "kind": "soft-sticky",
    "path": "virt://virt-ai-pcie/island0",
    "target": "island0"
  },
  "island0_irq": {
    "kind": "eventfd",
    "path": "virt://virt-ai-pcie/island0_irq",
    "target": "island0"
  }
}
```

After `mb select virt-ai-pcie`:

```bash
source corev-mb/boards/virt-ai-pcie/generated/ai-tensor.env
# AI_TENSOR_BOARD_ID=virt-ai-pcie
# AI_TENSOR_UIO=virt://virt-ai-pcie/island0
# AI_TENSOR_MMIO_BASE=0x40000000
# AI_TENSOR_PLIC_SOURCE=8
```

---

## 4. How to run smoke

```bash
# from monorepo root (stdlib only; numpy optional)
python3 ai-tensor/tools/virt_ai_card/smoke.py
# or
bash monorepo-soak/run-virt-ai-card.sh
# optional adapter
bash monorepo-soak/run-ai-tensor.sh virt-card
```

Expected: 2×2 INT8 GEMM with `C == [[19, 22], [43, 50]]`, exit 0.

---

## 5. Configure flow

```text
mb select virt-ai-pcie
# → pins soc.coreConfig = g6lc64_ai
# → generated/*_board_pkg.sv (MbAi_En=1, soft-sticky kinds)
# → generated/*_ai.dtsi / profile / ai-tensor.env  (non-compiled, gitignored)
```

DTS fragment is still emitted for discovery shape parity; a virtual board does
**not** require a bootable full tree.

---

## 6. Promotion vs real FPGA / card

| Step | Virtual (`virt-ai-pcie`) | Real card |
|---|---|---|
| Transport | TCP JSON | PCIe BAR + virtio + SSH |
| Island | SoftIsland Python | `g6lc_ai_island` RTL |
| IRQ | VirtualEventFd | UIO / eventfd + PLIC-8 |
| PCB | none (`skidl: omitted`) | card edge + aux power (`pcie-endpoint.md` §3.1) |
| Catalog | controllers disabled | `vendor sync verilog-pcie` etc. |

Promotion path: keep `ai.uioConnectors` ids, switch `island0` to `uio-mmio`
`/dev/uio0`, enable PCIe controller on a physical board class (`fpga`/`custom`),
and run the board checklist in `board-uio-eventfd.md` §5.

---

## 7. Related

- `architecture/uncore/pcie-endpoint.md` — BAR layout, virtio/SSH, bulk BAR4  
- `architecture/ai-matrix/board-uio-eventfd.md` — claim order + `mb` AI schema  
- `corev-mb/boards/ai-card/` — non-virtual custom AI example  
- `build-platform/src/tooling/ai-board.ts` — `AI_BOARD_DEFAULTS` / generators  
- `ai-tensor/tools/virt_ai_card/` — VirtualUioDevice, transport, smoke  
