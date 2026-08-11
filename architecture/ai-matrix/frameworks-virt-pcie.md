# Framework tests via virtual PCIe AI board (`virt-ai-pcie`)

**Status:** hostless CI path landed · **Board:** `corev-mb/boards/virt-ai-pcie`  
**Core config:** `g6lc64_ai` (ai_island package) · **Host CLI:** `cva6-build tensor …`  
**Package:** `ai-tensor` (no Cargo path dep into monorepo)

This document is the **test map** for validating that **ai-tensor** implements the
software side of **ai_island** features (INT8 GEMM, AccTile, multi-ticket claim,
soft UIO / eventfd, CAP geometry) **through** the virtual PCIe card path that
stands in for the real endpoint (virtio-SSH + BAR4 bulk + UIO).

Related:

| Doc | Role |
|---|---|
| [`board-uio-eventfd.md`](board-uio-eventfd.md) | PLIC-8 / DONE claim / UIO contract |
| [`../uncore/pcie-endpoint.md`](../uncore/pcie-endpoint.md) | Real PCIe BAR / virtio plan |
| [`../../corev-mb/boards/virt-ai-pcie/board.json`](../../corev-mb/boards/virt-ai-pcie/board.json) | Board machine spec |
| [`../../ai-tensor/architecture/FRAMEWORKS.md`](../../ai-tensor/architecture/FRAMEWORKS.md) | Framework attach design |
| [`../../ai-tensor/architecture/HOST.md`](../../ai-tensor/architecture/HOST.md) | build-platform spawn boundary |

---

## 1. What is under test

```text
  PyTorch (optional) / Device API
           │
           ▼
  ai_tensor.Device(backend=virt-card)
           │
     ┌─────┴──────────────────────┐
     │ local                      │ tcp
     ▼                            ▼
 VirtualUioDevice           HostClient ──TCP──► CardAgent
 soft UIO + eventfd         VirtualPcieLink     VirtualUioDevice
 virt://virt-ai-pcie/…                          (card side)
           │                            │
           └────────────┬───────────────┘
                        ▼
              INT8 GEMM ref (ai_island contract)
              AccTile caps · multi-ticket · board_id
```

**Island features exercised (software model of RTL):**

| Feature | How the test hits it | RTL / contract locus |
|---|---|---|
| INT8 GEMM → i32 C | `gemm_s8` / torch `int8` matmul | OP_GEMM, Desc64, `ai_gemm_s8_smoke` |
| AccTile 256 geometry | `Device.caps()` + optional host tile stream | CAP AccTile / I1 freeze |
| Multi-ticket sequential | tickets 20–22 / FIFO claim order | CPL FIFO + DONE @0x10C |
| Soft UIO path | `AI_TENSOR_UIO=virt://virt-ai-pcie/island0` | board-uio-eventfd soft-sticky |
| Virtual PCIe / SSH stand-in | `--virt-mode tcp` CardAgent | pcie-endpoint virtio-SSH |
| Core package selection | `--core g6lc64_ai` → `AI_TENSOR_CORE` | `g6lc64_ai_config_pkg` + island |

Live HARD RTL remains `tensor rtl-hard` / `run-ai-matrix-hard-suite.sh` on
`work-ver-ai` — **orthogonal** to this hostless frameworks gate.

---

## 2. Select configuration (board + ai_island core)

### 2.1 Preferred: build-platform `tensor` (no mb required)

```bash
# from monorepo root (build-platform)
bun run src/cli/index.ts tensor pytorch \
  --board virt-ai-pcie \
  --core g6lc64_ai

# full hostless gate (virt smoke + frameworks + pytorch)
bun run src/cli/index.ts tensor regress \
  --board virt-ai-pcie \
  --core g6lc64_ai

# optional timings preflight (same semantics as diag --from-timing)
bun run src/cli/index.ts tensor pytorch \
  --board virt-ai-pcie \
  --core g6lc64_ai \
  --from-timing workspace/build/sv-timing/host-g6lc64_ai
```

`--board` loads `corev-mb/boards/<id>/board.json` `ai{}` and exports
`AI_TENSOR_BOARD_ID`, `AI_TENSOR_BACKEND=virt-card`, `AI_TENSOR_UIO`, AccTile pins.  
`--core` sets `AI_TENSOR_CORE` / `CVA6_CORE_CONFIG` to the **ai_island** package
(`g6lc64_ai`). Defaults for `pytorch`/`regress`/`frameworks`: board
`virt-ai-pcie`, core `g6lc64_ai` when unset.

### 2.2 Optional: `mb select` then tensor

```bash
bun run src/cli/index.ts mb select virt-ai-pcie
# writes corev-mb/boards/virt-ai-pcie/generated/ai-tensor.env (+ dtsi/profile)
source corev-mb/boards/virt-ai-pcie/generated/ai-tensor.env   # if present
bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai
```

`mb select` adapts `soc.coreConfig` to the board’s core (`g6lc64_ai` for
virt-ai-pcie) and generates AI env/profile artifacts — see
`AGENTS-motherboard.md` + `build-platform/src/tooling/ai-board.ts`.

### 2.3 Direct soak scripts

```bash
bash monorepo-soak/run-ai-tensor-pytorch.sh
bash monorepo-soak/run-ai-tensor.sh pytorch
bash monorepo-soak/run-ai-tensor.sh regress
AI_TENSOR_REQUIRE_TORCH=1 bash monorepo-soak/run-ai-tensor-pytorch.sh   # fail if no torch
```

---

## 3. Test artifacts

| Artifact | Role |
|---|---|
| `ai-tensor/python/tests/test_torch_virt_ai_island.py` | **Structured** unittest: GEMM, AccTile stream, multi-ticket, env, local+tcp |
| `ai-tensor/python/examples/torch_virt_card_smoke.py` | Thin smoke example |
| `ai-tensor/tools/frameworks_regress.py` | Multi-framework harness (device/numpy/torch/tf) |
| `ai-tensor/tools/virt_ai_card/` | Virtual UIO, eventfd, CardAgent, HostClient |
| `monorepo-soak/run-ai-tensor-pytorch.sh` | Monorepo adapter for pytorch suite |
| `monorepo-soak/run-ai-tensor-frameworks.sh` | Frameworks harness adapter |
| `monorepo-soak/run-ai-tensor-regress.sh` | Full hostless gate |
| `build-platform` `tensor pytorch\|frameworks\|regress` | Host CLI + `--board`/`--core`/`--from-timing` |

### 3.1 PyTorch suite classes

| Class | Covers |
|---|---|
| `TestAiIslandGemmThroughVirtPcie` | env/core select, 2×2 golden, random match torch.mm, multi-ticket |
| `TestAiIslandAccTileThroughVirtPcie` | single-tile meta; forced multi-tile stream |
| `TestAiIslandVirtualPcieLink` | TCP CardAgent path vs torch |
| `TestAiIslandDeviceEnvPropagation` | `Device.from_env()` + UIO virt:// |
| `TestVirtCardDeviceWithoutTorch` | **Always-on** Device golden local+tcp (CI without torch wheels) |

Without PyTorch installed the Device cases still **PASS** (exit 0).  
`AI_TENSOR_REQUIRE_TORCH=1` or `--require-torch` makes missing torch a hard fail.

---

## 4. Env contract (host → package)

| Variable | Example | Set by |
|---|---|---|
| `AI_TENSOR_BOARD_ID` | `virt-ai-pcie` | `--board` / board.json / `mb select` env |
| `AI_TENSOR_BACKEND` | `virt-card` | board soft-sticky / `--backend` |
| `AI_TENSOR_CORE` | `g6lc64_ai` | `--core` |
| `AI_TENSOR_UIO` | `virt://virt-ai-pcie/island0` | board `ai.uioConnectors` |
| `AI_TENSOR_VIRT_MODE` | `local` \| `tcp` \| `auto` | `--virt-mode` |
| `AI_TENSOR_ACC_TILE_*` / `AI_TENSOR_MACS` | `256` | board `ai{}` |
| `CVA6_FROM_TIMING` / `FROM_TIMING` | timings out-dir | `--from-timing` preflight |
| `AI_TENSOR_REQUIRE_TORCH` | `1` | optional hard torch gate |

Package never path-depends monorepo crates (KD0). Spawn only via soak scripts.

---

## 5. Acceptance

| Gate | Command | Expect |
|---|---|---|
| Device virt-card | `tensor pytorch --board virt-ai-pcie --core g6lc64_ai` | Device local+tcp golden PASS; torch classes if installed |
| Frameworks | `tensor frameworks --board virt-ai-pcie --core g6lc64_ai` | device (+ numpy/torch/tf soft-skip) |
| Full hostless | `tensor regress --board virt-ai-pcie --core g6lc64_ai` | virt smoke + frameworks + pytorch |
| Lab HARD RTL | `tensor rtl-hard` | mmio + gemm_s8 on work-ver-ai (orthogonal) |

**Pass criteria for frameworks path:** all run Device cases green; when torch is
present, every `TestAiIsland*` case matches torch int32 matmul of int8 inputs
and reports `board_id=virt-ai-pcie` with AccTile/Macs 256.

---

## 6. Next (not this gate)

- Live `/dev/uio*` + eventfd on Variane/FPGA (`board-uio-eventfd.md` § kernel)
- `torch.ops.ai_tensor.gemm_s8` C++ extension (`frameworks/torch/`)
- TensorFlow C++ custom op (M6b); XLA custom call later
- Wire real PCIe BAR4 when `verilog-pcie` endpoint is in flist
