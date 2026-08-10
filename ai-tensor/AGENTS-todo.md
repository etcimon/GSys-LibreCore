# ai-tensor — live todo / phase state

Update this file every implementation pass. Architecture concepts: `architecture/README.md`.
Roadmap re-scoped 2026-08-10 against live I1/I3-lite island (AccTile/PeLanes=256, PMU/CAP,
trail C-store, multi-out AR). See architecture analysis: contract → real device → frameworks.

## M0 — Architecture scaffold

- [x] `AGENTS.md` — purpose as PyTorch/TF backend for island
- [x] `architecture/` conceptual docs (DESIGN, ABI, RUNTIME, FRAMEWORKS, VERSIONING, HOST)
- [x] Pointer rows in monorepo `architecture/README.md` / `ai-matrix/README.md`
- [x] `tools/ait.py` bootstrap (doctor / test / build-native)
- [x] `profiles/sim-v0.toml` pin file

## M1 — ABI crate

- [x] `crates/ai-tensor-abi` — Desc64, completion word, MMIO constants
- [x] Unit goldens for pack/roundtrip / header bytes
- [x] **Phase A1:** CAP window word map + PMU @0x180–0x18C + `CapRegs` decode
- [ ] Optional `tools/gen_abi_from_md.py` (hand-sync OK for now)

## M2 — IR + sim runtime

- [x] `ai-tensor-ir` GEMM lower
- [x] `ai-tensor-rt` + **sim** (AI-3, ref INT8 GEMM, completion word)
- [x] CLI: `doctor`, `pack-gemm`, `sim-gemm`
- [x] **Phase A2:** `Caps` AccTile*/MacsPerCycle/NocWidth/PMU; sim defaults match island_p3
- [x] **Phase A3:** IR max-tile enforce + host-side `tile_gemm` iterator

## M3 — Python

- [x] `python/ai_tensor` high-level API (native optional, pure-Python fallback)
- [x] PyO3 crate `ai-tensor-py` (`ai_tensor_native`) for optional native sim
- [x] Surface Caps / max_tile / PMU in Python device API
- [ ] cbindgen `include/ai_tensor.h` (C ABI file) — optional; PyO3 covers M4 path

## M4 — PyTorch (high-level, pre-RTL)

- [x] `ai_tensor.torch_ops.gemm_s8` / `check_close_to_torch` (no libtorch link in Rust)
- [x] `python/examples/torch_island_smoke.py`
- [x] Auto-tile large matmul via host tile_gemm when m/n/k > AccTile
- [ ] Official `torch.ops` C++ extension package (later; not required for sim bring-up)

## Phase A — Contract lock (hostless; absorbs I3-lite discovery)

- [x] A1 CAP/PMU in abi
- [x] A2 Caps + sim fake CAP values (AccTile=256, NocWidth=64)
- [x] A3 IR tile limits + tiling helper
- [x] Profiles: `sim-v0` features + `island-p3-v1.toml` pin stub
- [ ] Dual oracle note: optional monorepo `ai-matrix-veri` when host present

## M5 — Linux / real island (capability-driven)

- [x] SoftIsland MMIO model: CAP/CTL/regions/desc latch/doorbell/DONE/PMU
- [x] `MmioDevice`: CAP→Caps, AI-3 program, latch + fetch submit, poll+clear DONE, PMU
- [x] CLI `mmio-gemm` + doctor CAP probe
- [x] Feature `linux-mmio` stub for future UIO map (not default CI)
- [ ] Real UIO/VFIO map of Variane `0x4000_0000` on Linux board
- [ ] PLIC-8 IRQ wait path (level clear before complete)
- [ ] Cosim/replay against Variane harness (optional)
- [x] Python Caps / PMU surface + torch meta
- [ ] `tools/check_independence.py`

## M6+ — TF / production RT

- [ ] TensorFlow custom op (same Desc64 path)
- [ ] Multi-tile desc stream for large framework GEMM on single queue
- [ ] IRQ wait; multi-queue; claim+completion-DMA policy soak
- [ ] Host adapter: `cva6-build tensor doctor|test|probe` (see HOST.md)

## Open design notes

- **Completion DMA vs PLIC claim:** island soak keeps `CTL.wr_cpl_en=0` for pure claim tests;
  package must expose caps and ordering when both are enabled.
- **Sim vs RTL GEMM:** sim runs a **reference INT8→i32** matmul so PyTorch can validate the
  software path before island executes real GEMM; profile may set `compute_ref=false` for
  pure spine (status-only) mode.
- **Bus micro-arch (trail C-store, multi-out AR, oct-drain):** stays in RTL; host only discovers
  AccTile/NocWidth/PMU. Do not reimplement bus tricks in software “optimizers.”
- **64b NoC floor:** 256³ ~83.7k cy on TB; software tiling cannot beat MAC+A+B bus floor.
- **Wider NoC:** new profile when monorepo fabric is 128b; no ABI major.
