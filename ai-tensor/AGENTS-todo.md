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
- [x] Python golden suite + Profile/`Device.from_profile` (lockstep with Rust goldens)
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
- [x] Dual oracle: package offline sim+SoftIsland; external harness + lab `AI_TENSOR_RTL_CMD`

## M5 — Linux / real island (capability-driven)

- [x] SoftIsland MMIO model: CAP/CTL/regions/desc latch/doorbell/DONE/PMU
- [x] `MmioDevice`: CAP→Caps, AI-3 program, latch + fetch submit, poll+clear DONE, PMU
- [x] CLI `mmio-gemm` + doctor CAP probe
- [x] Feature `linux-mmio` stub for future UIO map (not default CI)
- [x] MappedWindow (file-backed) + linux-mmio UIO/`/dev/mem` open (feature-gated)
- [ ] Board-validated UIO map on live Variane/FPGA
- [x] SoftIsland FLAG_IRQ sticky + DONE clear (PLIC mirror discipline)
- [x] IRQ wait abstraction (`irq.rs`: SoftSticky + UioIrqWait under linux-mmio; PLIC-8 contract)
- [x] Host EventFd wait abstraction + hostless soft soak / FIFO re-arm (EventFdWait, CLI event-fd-soak)
- [x] Monorepo spawn: run-ai-tensor.sh event-fd-soak (+ queue-soak includes it)
- [x] Board contract + DTS: monorepo architecture/ai-matrix/board-uio-eventfd.md + ariane-ai.dts
- [ ] Host PLIC-8 eventfd/UIO **live board** wait (kernel driver + /dev/uio* or eventfd wire)
- [x] Offline cosim goldens (sim+SoftIsland) + `golden-check` CLI
- [x] Rust `run_gemm_s8_auto` AccTile streaming
- [x] Monorepo spawn `monorepo-soak/run-ai-tensor.sh`
- [x] External cosim harness `tools/cosim_harness.py` + `AI_TENSOR_COSIM_CMD` protocol
  (ping + gemm job + suite; optional `AI_TENSOR_RUN_RTL` / `AI_TENSOR_RTL_CMD`)
- [x] Wire `ait.py {golden,cosim,test}` + `run-ai-tensor.sh cosim`
- [x] Lab RTL adapter: `monorepo-soak/run-ai-tensor-rtl.sh` + `tools/rtl_smoke.py`
  (soft default; `AI_TENSOR_RTL_HARD=1` → ai-matrix-veri subset)
- [x] Lab HARD smoke (reuse `work-ver-ai`): `ai_island_mmio_smoke` + `ai_gemm_s8_smoke` **PASS**
  (`monorepo-soak/run-ai-tensor-rtl-hard.sh`, 2026-08-10)
- [x] HARD suite CI post-FIFO (run-ai-matrix-hard-suite.sh ci) 27/27 on work-ver-ai
- [x] Peak HARD GEMM 128x128 (21.9k cy) + 256x256 (83.7k cy) on work-ver-ai (AI_MATRIX_HARD_SUITE=peak)
- [x] Python Caps / PMU surface + torch meta
- [x] `tools/check_independence.py` + `ait.py check`

## M6+ — TF / production RT

- [x] TensorFlow high-level Python (`tf_ops` + example; TF optional)
- [ ] TensorFlow C++ custom op / XLA (out-of-tree; use `include/ai_tensor.h`)
- [x] C ABI header `include/ai_tensor.h` (Desc64 / completion / MMIO lock)
- [x] Multi-tile desc stream (`stream.rs`: Queue, plan/run, zero-copy A/B lda/ldb)
- [x] `run_gemm_s8_auto` → stream path; CLI `stream-gemm`
- [x] WaitPolicy (Poll/IrqThenPoll/DmaThenClaim/ClaimOnly) + `soak_multi_queue` + CLI `queue-soak`
- [x] Host adapter: `cva6-build tensor status|doctor|test|golden|cosim|queue-soak|rtl`
- [x] `Device(backend=virt-card)` + `VirtCardSession` (local VirtualUioDevice / TCP CardAgent)
- [x] Structured PyTorch suite `python/tests/test_torch_virt_ai_island.py` (ai_island features via virt-ai-pcie)
- [x] Host: `tensor pytorch|frameworks|regress --board virt-ai-pcie --core g6lc64_ai [--from-timing DIR]`
- [x] Monorepo soak: `run-ai-tensor-pytorch.sh` / frameworks / regress
- [x] Docs: monorepo `architecture/ai-matrix/frameworks-virt-pcie.md` + HOST/FRAMEWORKS updates
- [x] Stream + WaitPolicy (`run_gemm_s8_stream_with_policy` / CLI `stream-policy`)
- [x] Stream + SubmitMode latch/fetch (`run_gemm_s8_stream_ex` / `Device::submit_fetch`)
- [x] Single-queue sequential depth soak (`depth.rs` / CLI `depth-soak`)
- [x] SoftIsland completion **history ring** + `soak_history_poll` / CLI `history-soak`
- [x] Profile `wait_policy` + `submit_mode` pins + `to_wait_policy` / `to_submit_mode`
- [x] Host `ProbeReport` JSON (`probe` / `doctor --json`) + Python `probe_dict`
- [x] `schemas/probe.v1.json` schema pin
- [x] `HostRuntime` job queue (Rust + Python) — profile submit/wait, drain FIFO
- [x] CLI `host-run` + monorepo `tensor probe`
- [x] NumPy high-level path (`numpy_ops` + example)
- [x] Python `c_abi` + `tools/check_c_abi.py` lockstep with `include/ai_tensor.h`
- [x] `frameworks/torch/README.md` (high-level landed; C++ later)
- [x] Island CPL FIFO RTL (`g6lc_ai_cpl_fifo` + top; SoftIsland claim=pop head)
- [ ] Multi-outstanding **compute** (engine still one-at-a-time; FIFO holds finishes)

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
