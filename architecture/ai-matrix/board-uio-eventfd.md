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
| **virt-ai-pcie soft UIO** | Virtual PCIe board CI | `AI_TENSOR_UIO=virt://…`, `Device(virt-card)`; see [frameworks-virt-pcie.md](frameworks-virt-pcie.md) |
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

## 6. Motherboard (`mb`) integration

Custom boards can opt into the same hardware contract via optional `board.json`
`ai{}`. Genesys2 and other non-AI boards stay unchanged (no `ai` key →
`MbAi_En=0`). Engine: `build-platform/src/tooling/ai-board.ts` (defaults +
generators) hooked from `motherboard.ts` on validate / package / select.

### 6.1 `board.json` `ai{}` schema

| Field | Default | Notes |
|---|---|---|
| `enabled` | `true` if object present | `false` suppresses all AI artifacts |
| `mmioBase` / `mmioSize` | `0x40000000` / `0x1000` | `AiIslandBase` window |
| `plicSource` | `8` | PLIC ID for island IRQ |
| `accTile{M,N,K}` / `macsPerCycle` | `256` | I1 geometry |
| `queues` / `queueDepth` / `nocWidth` | `1` / `8` / `64` | DTS advertisement |
| `profileId` | `island-p3-v1` | ai-tensor profile pin |
| `primaryUio` | first `uio-mmio` id | Connector id for `AI_TENSOR_UIO` |
| `features[]` | island-p3-v1 set | Copied into generated profile TOML |
| `uioConnectors` | one `island0` uio-mmio if omitted | **Keyed by id** |

Example connector map (see `corev-mb/boards/ai-card/board.json`):

```json
"ai": {
  "enabled": true,
  "uioConnectors": {
    "island0": { "kind": "uio-mmio", "path": "/dev/uio0", "target": "island0" },
    "island0_irq": { "kind": "eventfd", "target": "island0" }
  }
}
```

Allowed `kind` values: `uio-mmio`, `eventfd`, `devmem`, `soft-sticky`. Soft
warn if `core.config` is not `g6lc64_ai`.

### 6.2 Generated artifacts (`mb select` / `writeGeneratedArtifacts`)

All under `corev-mb/boards/<id>/generated/` (**gitignored**, non-compiled):

| File | Content |
|---|---|
| `<id>_board_pkg.sv` | `MbAi_En`, `MbAi_MmioBase`, `MbAi_PlicSource`, per-connector enables |
| `<id>_ai.dtsi` | `ai-matrix@base` fragment with `g6lc,board-id`, geometry, `uio-primary` |
| `<id>_ai.profile.toml` | board-local ai-tensor profile (`board_id`, `uio_primary`, PLIC, features) |
| `ai-tensor.env` | shell exports for discovery (below) |

Generic node shape (docs only): `architecture/ai-matrix/dts/g6lc-ai-matrix.dtsi`.
Golden full tree remains `corev_apu/bootrom/ariane-ai.dts`.

### 6.3 `AI_TENSOR_BOARD_ID` discovery

After `mb select <ai-board>`:

```bash
source corev-mb/boards/<id>/generated/ai-tensor.env
# export AI_TENSOR_BOARD_ID=<id>
# export AI_TENSOR_UIO=/dev/uio0
# export AI_TENSOR_MMIO_BASE=0x40000000
# export AI_TENSOR_PLIC_SOURCE=8
```

`AI_TENSOR_BOARD_ID` is the `board.json` `boardid`. UIO path comes from the
primary connector (`primaryUio` or first `uio-mmio`). Custom boards get UIO
connectors **by id** so multi-island cards can name `island0`, `island1`, …

### 6.4 Scaffold

```text
mb create my-ai --ai --class custom   # g6lc64_ai + starterAiSpec + ai0 interface
mb select my-ai                       # emit package + AI artifacts
```

Example committed board: `corev-mb/boards/ai-card/` · target doc:
`corev-mb/architecture/ai-card/README.md`.

---

## 7. Virtual board / `virt-ai-pcie`

Hostless stand-in for the **PCIe endpoint CPU+AI card** (no kernel, no real
PCIe, no PCB). Board class is `virtual`; primary connector is **soft-sticky**.

| Item | Value |
|---|---|
| Board | `corev-mb/boards/virt-ai-pcie/board.json` |
| Architecture target | `corev-mb/architecture/virt-ai-pcie/README.md` |
| Userspace driver | `ai-tensor/tools/virt_ai_card/` (`VirtualUioDevice`, `VirtualEventFd`) |
| Transport | `VirtualPcieLink` localhost TCP (virtio-net/SSH + BAR4 bulk model) |
| Primary UIO path | `virt://virt-ai-pcie/island0` |
| IRQ path | `virt://virt-ai-pcie/island0_irq` (eventfd) |
| Smoke | `python3 ai-tensor/tools/virt_ai_card/smoke.py` · `monorepo-soak/run-virt-ai-card.sh` |

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

Claim order is identical to §2: wait → **claim DONE @0x10C** → clear/rearm.
Promotion to a lab board switches `island0` to `uio-mmio` `/dev/uio0` and enables
a real PCIe endpoint (`architecture/uncore/pcie-endpoint.md`).

`mb select virt-ai-pcie` emits the same AI artifact set with
`AI_TENSOR_UIO=virt://virt-ai-pcie/island0`.

---

## 8. Related pins

| Artifact | Role |
|---|---|
| `ai-tensor/profiles/island-p3-v1.toml` | mmio_base, plic_source=8, backend linux-uio |
| `architecture/ai-matrix/completion-fifo.md` | DONE claim = pop |
| `architecture/ai-matrix/isa-encoding.md` | descriptor / FLAG_IRQ |
| `architecture/ai-matrix/dts/g6lc-ai-matrix.dtsi` | generic DTS node template (not on flist) |
| `build-platform/src/tooling/ai-board.ts` | `AI_BOARD_DEFAULTS` + generators |
| `corev-mb/boards/ai-card/board.json` | example custom AI board |
| `corev-mb/boards/virt-ai-pcie/board.json` | virtual PCIe AI card (soft-sticky CI) |
| `ai-tensor/tools/virt_ai_card/` | VirtualUioDevice + TCP host/card agents |
| `verif/tests/custom/ai/ai_irq_plic_smoke.S` | PLIC-8 directed |
| `monorepo-soak/run-ai-tensor.sh event-fd-soak` | hostless EventFd CI |
| `monorepo-soak/run-virt-ai-card.sh` | hostless virt-ai-pcie smoke |
