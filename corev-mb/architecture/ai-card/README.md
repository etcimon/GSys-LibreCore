# ai-card — development target (custom AI island)

Example **custom** board that factors the Xg6lcai AI island onto the `mb`
motherboard layer: `g6lc64_ai` core config, default UIO connectors, and
generated host artifacts (`*_ai.dtsi`, profile TOML, `ai-tensor.env`).

- Spec: `corev-mb/boards/ai-card/board.json`
- Workflow: `AGENTS-motherboard.md` · Host path: `architecture/ai-matrix/board-uio-eventfd.md`
- Golden DTS: `corev_apu/bootrom/ariane-ai.dts` · Template: `architecture/ai-matrix/dts/g6lc-ai-matrix.dtsi`

## 1. Intent

Prove that a custom board can opt into AI island defaults via optional
`board.json` `ai{}` without changing genesys2 or core/uncore RTL. Selecting the
board pins `soc.coreConfig` to `g6lc64_ai` and emits non-compiled artifacts under
`corev-mb/boards/ai-card/generated/` (gitignored).

## 2. Core preconditions

| Item | Value |
|---|---|
| Config package | `g6lc64_ai` (`core/include/g6lc64_ai_config_pkg.sv`) |
| XLEN | 64 |
| Vendor ISA token | `xg6lcai` (advertise only when `AiMatrixEn=1`) |
| Island MMIO | `0x4000_0000` / 4 KiB |
| PLIC source | 8 |

## 3. UIO connectors (`ai.uioConnectors`)

| Id | Kind | Role |
|---|---|---|
| `island0` | `uio-mmio` | Primary CAP/CTL map → `AI_TENSOR_UIO=/dev/uio0` |
| `island0_irq` | `eventfd` | Completion IRQ handoff → `AI_TENSOR_EVENTFD` |

Custom boards name connectors by id; generators pick the primary uio-mmio path
for `AI_TENSOR_BOARD_ID` discovery.

## 4. Configure flow

```text
mb select ai-card
# → overlay pins g6lc64_ai
# → generated/ai_card_board_pkg.sv   (MbAi_En=1, MbAi_MmioBase, …)
# → generated/ai_card_ai.dtsi
# → generated/ai_card_ai.profile.toml
# → generated/ai-tensor.env
source corev-mb/boards/ai-card/generated/ai-tensor.env
```

Scaffold another AI board: `mb create my-ai --ai --class custom`.

## 5. Gaps / promotion

Scaffold only — no FPGA/ASIC top, no kernel driver, no flist entry. Promotion
requires a board top that imports the generated package, a full `.dts` (or
include of the fragment into `ariane-ai.dts` shape), and the SoC-readiness gates
in `AGENTS-motherboard.md` §5.
