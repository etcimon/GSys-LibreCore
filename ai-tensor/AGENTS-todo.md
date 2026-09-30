# ai-tensor — live todo / phase state

Update this file every implementation pass. Architecture concepts: `architecture/README.md`.
Roadmap re-scoped 2026-08-10 against live I1/I3-lite island (AccTile/PeLanes=256, PMU/CAP,
trail C-store, multi-out AR). See architecture analysis: contract → real device → frameworks.

## 2026-09-28 — Submission/completion correctness review (in progress)

- [x] Reproduced eight new Python protocol cases (12 failing outcomes with qid subtests)
  and four Rust MMIO regressions before their fixes. Existing focused Python (32) and
  Rust runtime (74) tests passed on the starting working tree.
- [x] UIO uses the split queue map, validates qids before MMIO, requires DONE plus the
  expected ticket/DSTATUS, and retains pending buffer ownership through timeout. IRQ
  submissions set FLAG_IRQ and rearm only after claiming. Ticket exhaustion is refused.
- [x] Added explicit `Device::poll_completion(ticket, claim)` to separate observation
  from consumption. DMA/IRQ/eventfd waiters no longer double-pop the next completion;
  legacy MMIO poll remains consuming for compatibility. Latch/fetch refuse tickets
  outside the 23-bit doorbell field before side effects.
- [x] `ait.py test` discovers all pytest tests and checks ABI lockstep. New queue/ticket
  constants are aligned in C/Python/Rust. `ait.py test --no-harness` passes: Rust workspace
  101 tests, pytest 289 passed / 5 skipped / 11 subtests, golden/queue checks and NumPy/
  PyTorch smokes. This does not qualify the native extension, TensorFlow, guest execution
  or RTL. No dependencies were installed; inherited dead-code warnings remain.
- [x] Remote no-DMA spine qid regression: four reproduced failures before preserving all
  qid bits; after-run `ai-spine-qid-after-20260928-r2` passes in 446 cycles and detects its
  negative oracle. Strict process-loop and declaration-order findings were repaired;
  Yosys reports 1,412 generic cells, zero latches/SCCs. Not GEMM/physical qualification.
- [x] Fractional-clock bandwidth arithmetic now multiplies at kHz precision before
  rounding whole GB/s and saturates u32 overflow, matching the SV helper. New Rust/Python
  tests reproduced the 500-MHz zero-rate bug; updated 1.5-GHz sizing expectations use the
  correct 768 GB/s for a hypothetical 512-byte port. This is not measured hardware BW.
  Full `ait.py test` rerun passes 102 Rust tests and 289 pytest cases / five skips.
- [~] DMA qid/status, PMU overflow and two full-FIFO completion-loss cases repaired with
  diagnostic before/after evidence. Pending descriptors own their bytes; refused/failing
  fetch completions retain their ticket/status. `architecture/ai-matrix/log-2026-09.md`
  records exact tags and the no-DMA synthesis gate. Six aggregate-AXI strict lint findings
  remain; diagnostics are INCOMPLETE, not hardware qualification.
- [x] User recovered disk capacity; the preserved runtime identity was revalidated from
  a local manifest copy. Signed 2x1/2x3 and AXI backpressure regressions now execute:
  mutable ARID and premature C reads were reproduced/fixed, with 56 exact checks and
  909 stalled observations passing for each float-pipe setting. Not physical qualification.
- [x] Reduced DMA synthesis is CHECK/latch/SCC clean after declaration-order repair.
  Active fetches retain qid/ticket across later doorbells, with a reproduced failure and
  passing after-run. FIFO depths 1/3/16 pass; depths 3/16 additionally have inductive safety,
  negative controls and full-replacement cover. These remain leaf/reduced-geometry results.
- [x] User-selected iterative compatible PMU candidate passes 272 arithmetic cases and
  all rate aliases; variable-latency read leaves computational completion unchanged.
  Structural rate check has no mul/div/mod/latch/SCC cells; mapped timing remains open.
- [~] Optional command FIFO now has an island/APB candidate (CAP/mode/receipts/credits,
  protected writes, immutable queued tuples, VALID/READY seam). All production CommandDepth
  defaults remain0. Remote enabled tests cover full capacity, rejection, blocked sideband,
  and two real asymmetric GEMMs with full-u32 tickets; reduced synthesis is latch/SCC clean.
- [x] Python `QueuedMmioSession` adds explicit capability negotiation and pointer/lease
  submission: known refusal releases no accepted owner, ambiguous receipts/I/O failures
  retain leases, foreign heads are not claimed and timeout does not permit reuse.
  Seven directed cases pass; C/Python/Rust constants match across 47 macros.
- [x] Core `ai.enq` now holds VALID until island READY and returns the ticket on acceptance;
  `ai.poll` trusts only the island when attached. Leaf `--enq` lane passes strict lint
  after the accumulator read request was extracted from the FSM process (15 results).
- [x] Rust `SoftIsland`/`MmioDevice` model the command extension (default absent); three
  tests cover absence, receipts/lock/identity with real GEMMs and held dispatch. B3 emulator
  ingests `CommandDepth`/version/flags/`REG_OFF_CMD_*` and implements the window; two
  device tests plus the package parse test pass. `g6q.py check` is red only on pre-existing
  clippy/fixture debt in the user's in-progress `gemm.rs`/`exec.rs`/`tensor_eval` changes.
- [x] Strict aggregate-AXI lint closed on the reduced DMA gate without waivers (registered
  DMA boundary `g6lc_ai_axi_cut`, bit-split AXI copies, sim-stripe slice, two vendor
  `isolate_assignments` with a re-proven negative probe); all directed cases and synthesis pass.
  Cycle baselines shifted with the added register stages (PMU fixture 2354 cycles).
- [x] Stage-2 phase/stall counters (`PMU_OFF_PHASE_*`, `PMU_OFF_STALL_*`) and a measured
  reduced-geometry breakdown: loads and MAC are sequential (44% load share at 8x8x16),
  MAC is output-serial (~97% of phase ideal), AR depth shortens only loads; recorded in
  `architecture/ai-matrix/log-2026-09.md`. Not live-512/silicon evidence.
- [x] `ai_tensor.torch_backend`: `AiTensorLinear` (prepacked k-major weight, AccTile
  M/N/K blocking, exact INT8 K-split, ordered-FP refusal), `AiTensorConv2d` (im2col),
  `replace_linear` swap report with counted explicit fallback, optional
  `torch.ops.ai_tensor.gemm`, GPT-2 `Conv1D` folding. 10 tests incl. a tiny BERT layer,
  a conv block and a GPT-2 greedy decode loop (KV cache) matching tokens exactly; virtual
  backends only, random weights, no model-quality claim.
- [ ] B1 generated QEMU device parity, full-SoC `g6lc64_ai` rebuild with the new producer
  ports and AXI cut, malformed/error-drain, backend-bench TB mux lint, full-SoC/physical closure.
- [x] First pinned-model qualification: `tools/qualify_llm.py` on distilgpt2@2290a626 with an
  inferred budget (ppl +10 %, top-1 90 %). W8A8 K-group-128 with float lm_head PASSES
  (ppl -0.1 %, top-1 0.973, 24/24 blocks offloaded); per-row W8A8 fails (+56 %), and the
  tied lm_head is the sensitive layer. Records in `fixtures/qual/`, checked by
  `test_qual_records.py`. Virtual evidence; budget pending ratification.
- [x] Accumulate mode (`flags.accmode == 01`, grant `CAP_ACCMODE` 0x94, ABI ext 2.2.0):
  seeded ordered reduction in Python/Rust references, engines, constants (51 macros) and
  `torch_backend` float K-chaining. distilgpt2 FP32 fully offloaded: top-1 1.000, ppl
  identical to 4e-6. RTL `ST_LC`/seed path landed in `g6lc_ai_gemm_seq`, grant flipped to 1:
  backend 112-check chained-vs-long + negative control PASS on both float pipes, island gate
  PASS strict/synth, `qemu-uio` carries the seed (3 tests).
- [x] Full-SoC `g6lc64_ai` rebuilt (isolated copy) with all new ports; before/after suite vs a
  pre-change baseline. Fixed the one regression (`ai.poll` head-only -> sideband retired
  watermark, leaf 18 results) and 12 stale ELFs (v1 descriptors, old geometry/nameplate,
  row-major B tile). 28/30 default cases PASS; `ai_irq_plic_smoke` and the latched-doorbell
  completion-identity anomaly (`ai_gemm_tile_2x2_smoke`) are pre-existing and open.
- [x] SoC anomaly root-caused by waveform: g6lc64_ai has two cores and the AI ELFs had no
  mhartid guard -> both harts drove every MMIO doorbell/claim/PLIC claim (second AW came
  from core 1 through the hub). Test-suite defect, not RTL; hart-0 guard added to 44 ELFs.
  Explains `ai_gemm_tile_2x2_smoke`, `ai_cpl_fifo_multi_claim` layout sensitivity and
  `ai_irq_plic_smoke` claim=0. SoC re-run: tile_2x2 PASS (20,471 cy), multi_claim PASS,
  irq_plic PASS (892 cy), queue_doorbell PASS -> directed SoC suite 30/30 on guarded ELFs.
- [x] Dividers gone: `$div` 3 -> 0 (`dram_beats_in_stripe` shift; the last two were 64-bit
  overflow-guard dividers in `ai_operand_span`/`ai_result_span` -> 68-bit product test);
  `$mul` 48 -> 38; island gate `ai-flat-island-20260929-r3` strict lint 0, 11,686 cells.
- [x] VA-Turbo bounded approximation measured: FP8 E4M3/E5M2 grouped and BF16/FP16 cast
  recipes in `torch_backend`; `tools/va_select.py` ladder with calibration/held-out gating.
  distilgpt2 selection: INT8 g128 blocks + FP16 lm_head = 0.369x FP32 bytes, ppl -0.1/-0.3 %,
  top-1 0.973/0.9745. FP8 worse than INT8 at equal bytes here. Virtual evidence.
- [x] Quick bench + execution-path analysis: `verif/regress/ai-ops-bench.sh` (local WSL,
  63 s, both float pipes, 156 records) + `ai_bench_report.py`; `ai_bench_gemm.S` per-format
  SoC bench with the island `+ai_pmu_trace` record; build-platform suites `ai-ops-bench`,
  `ai-ops-bench-soc`. Findings: MAC at byte-lane rate (INT8/FP8 1x, FP16/BF16 1/2, FP32
  1/4, INT4 2x), loads latency-bound at small K / bandwidth-bound at live K, odd-N stores
  stall the MAC. Area: runtime element-size divides/multiplies -> shifts, cycle-identical.
- [x] Bench matrix assets: `ai_bench_gemm.S` [fmt x MxNxK (auto-tiled, accmode K-split) x
  {mmio, ai.enq/ai.poll} x {cold, reuse_a, reuse_b}], `ai_bench_t0.S` [dot4, dot4a, mma,
  mvta+mvacc], bench SKU model (`G6LC_AI_TB_BENCH_SKU`: island VaTurboEn + IslandFpEn +
  all-format grant), `ai-matrix-veri.sh AI_MATRIX_BENCH=1` harvester, `ai_bench_report.py
  --soc`, `+measure_reuse` in the local backend bench (residency hits on all 7 formats).
- [x] SoC bench matrix, first points (bench SKU, 512 lanes, cycles not timing): INT8 1x512x512
  cold 34,136 cy (B stream 1.01 cy/beat) -> reuse_b resident **846 cy (40.3x)**; 1x256x1024
  K-split: accumulate block +2.2 % (C seed 388 cy); ai.enq/ai.poll path == MMIO path
  (34,128 / 846). Remaining FP32 points + T0 ops run in `ai-bench-matrix-20260929-r7`.
- [ ] Record the completed r7 matrix (FP32 decode points, T0 cycles/op) in the log.
- [x] K-split-to-residency: flat panel mapping in `g6lc_ai_gemm_seq` (per-job power-of-two
  row pitch, byte-capacity K box, `CAP_OFF_BANK_{A,B}_BYTES`), `Caps.max_k`/`fits` byte box,
  `AiTensorLinear` one-job K for flat-panel parts. `+review_flat` PASS 19 checks (both
  pipes), measure sweep cycle-identical on 156 records; pytest 334. A 256x1024 INT8 panel is
  one job / one resident key; `reuse_b` hits without a K-split. **SoC measured**
  (`ai-bench-flat-20260929-r1`): 1x256x1024 INT8 cold 33,812 (one job, was 34,595 in two)
  -> resident **778 cy, lb=0 (43.5x)**; before: no hit.
- [x] `g6lc_qemu` sources `bank_a_bytes`/`bank_b_bytes` (B3 + generated B1 parity); two
  reader defects fixed (function in constants block, conditional `command_queue` arm).
- [x] Two-slot resident-B directory (`ReuseBSlots=2`): alternating N panels both hit,
  big panel takes the bank; `+review_slots` 16 checks both pipes, 156-record identity;
  VA island synth +54 cells / +141 bits vs one slot; strict lint 0.
- [ ] Deferred with measured basis: row-merged AR bursts (<1 % at 1.002-1.008 cy/beat on
  >= 64-beat rows), odd-N stores (even hidden sizes). Incremental row pointers are done
  by the flat pitch (row address is a shift). Reopen if skinny-K or odd-N workloads appear.
- [x] Flat SoC points recorded: FP32 1x256x1024 resident 2,700 cy (49.8x); KBOX=512 control
  no hit; T0 table (dot4 4.07, mma 7.07 cy/op loop-inclusive).
- [x] Slots SoC proof point: INT8 1x768x512 (512 + 256 panels) resident **1,304 cy, both
  panels hit (39.3x)**.
- [x] Intra-row trail store (`TrailMinPairs`/`TrailMinCols`): m=1 store tail hidden behind
  the MAC; 1x32x16 bench 94 -> 76 cy; 156 records identical; all directed cases bit-exact.
  SoC re-measure in `ai-bench-trail-20260929-r1`.
- [x] Diffusers unblocked: `diffusers==0.39.0` (optional pin), `tools/qualify_diffusion.py`,
  tiny-pipeline ladder records (INT8 60.4 dB > FP8 48.7 dB, BF16 71.3, INT8+conv2d 41.6);
  `segmind/tiny-sd` pretrained: INT8 g128 FAIL (MAD 0.0205), **INT8 g64 PASS 35.0 dB**,
  BF16 PASS 48.5 dB -> diffusion recipe of record INT8 K-group 64.
- [x] SoC with intra-row trailing: INT8 1x512x512 resident 846 -> **590 cy (57.4x)**.
- [x] B1 parity: `g6lc-g6lc64_ai` boots OpenSBI, queue smoke PASS on the real-repo model
  (emitter symbol namespacing, ai-matrix node, field-wise payload, hart-0 park).
- [ ] Record the 768 / FP32 trail points when `ai-bench-trail-20260929-r1` lands; make
  `g6q_remote.py` check ssh/rsync exit codes (false green).
- [ ] Framework: pinned pretrained LLM (decode loop, KV cache untouched) and one Diffusers
  pipeline through `replace_linear`, with offload ratio and quality metrics; INT8 path
  quality budget; persistent buffers instead of per-call byte packing on `qemu-uio`.
  Production geometry and feature gates are unchanged. Remote capacity was initially
  occupied; first dispatch additionally failed because Git Bash converted Linux arguments.
  Use process-local
  `MSYS_NO_PATHCONV=1` / `MSYS2_ARG_CONV_EXCL=*` on native Bun gateway calls carrying Linux
  PATH/destination arguments. Failed runs remain distinct from simulation results.
- [ ] Complete the approved operator-first program: measured live-512 characterization,
  SRAM/datapath/formats, persistent QEMU/RTL bridge, framework/model gates, bounded
  approximation and bandwidth-led scaling. No production VA-Turbo or floating grant promotion.

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
- [x] **`qemu-uio` backend** (`python/ai_tensor/qemu_uio.py`) — the in-guest path named in
  the monorepo's `architecture/g6lc-qemu/ai-island.md` §5, which until now existed only in
  prose. `Device("qemu-uio")` and an env default (`AI_TENSOR_UIO=/dev/uioN` **plus**
  `AI_TENSOR_DMA_BASE`; a `virt://` path still means `virt-card`).
  Geometry is read from the **CAP window**, never from the DT helper properties — that is the
  rule on hardware and it is what keeps one binary valid across SKUs.
  Operand memory is explicit: the island DMAs A/B/C, so `AI_TENSOR_DMA_BASE` is *required*
  rather than defaulted, because guessing a DMA base is the same class of error as guessing an
  MMIO base. `MmioWindow` / `IrqSource` / `DmaMemory` are protocols, so the submission
  sequence is testable off-target while the real path uses `mmap` + a blocking UIO read.
- [x] **19 protocol tests** (`python/tests/test_qemu_uio_backend.py`) against a register-accurate
  fake island that actually multiplies: CAP discovery across two SKUs, **AI-3 region programmed
  before the doorbell**, **descriptor latched before the doorbell**, **DONE claimed before the
  PLIC is completed** (a level-set source re-arms otherwise), completion word naming
  ticket+status, PMU sticky read, host tiling beyond AccTile (F12), and the refusals —
  oversize shape, undersized DMA window, disabled island, absent queue, `virt://` path,
  missing `AI_TENSOR_DMA_BASE`.
- [ ] Board-validated UIO map on live Variane/FPGA
- [ ] ai-tensor staged into a riscv64 initramfs for a real in-guest run (needs a cross build;
  the guest kernel side is now enabled — `CONFIG_UIO`/`CONFIG_UIO_PDRV_GENIRQ` and the
  `generic-uio` fallback compatible + `no-map` operand carve-out in `ariane-ai.dts`)
- [x] SoftIsland FLAG_IRQ sticky + DONE clear (PLIC mirror discipline)
- [x] virt_ai_card `FLAG_IRQ = 1<<2` matches `isa-encoding.md` §7 / ingested `flags_layout.irq_bit`; packed DESC flags and ESP `FLAGS.TXT` `irq_bit_ok`. Null `ptr_*` (`PTR.TXT` `ptr_null`); bulk is BAR4 names, not invented addresses.
- [x] Packed `ld_ab = k|(n<<16)` matches `pack_desc64`; ESP `DESC.TXT` `ld_ab_ok`. Dense INT8 `dtype_s8s8` / `ew_byte` / `sp24=false` (`int4_not_in_headline`). Doorbell cluster from ingested `queue_cluster_map`.
- [x] virt_ai_card doorbell checks `ld_ab` against `n,k` (ST_ERR on mismatch). ESP `SCHED.TXT` `within_quantum`; qid→qos; FLAGS `fence_clear` / `priority_default` (`isa-encoding.md` §7.1).
- [x] virt_ai_card rejects `qid >= queues` and desc `version` other than 1 (`ST_ERR`). ESP `STAT.TXT` `qid_bound`.
- [x] virt_ai_card unknown `op` → `ST_BAD_OP`; doorbell while CTL.enable=0 → `ST_DISABLED`. ESP `OP.TXT` `op_ok`; `CTL.TXT` `disabled_rejected`.
- [x] CTL re-enable after disable restores `ST_OK` (`reenable_ok`).
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
- [x] virt_ai_card BAR4 `raw_hex` + `bar4_put_bytes("DESC")` copies a packed image into UIO DESC@0x140;
  `stage_gemm_s8(..., desc=)` checks m/n/k words against A/B. Not a pinned PCIe BAR.
- [x] virt_ai_card `mmio_rd`/`mmio_wr` on the existing 4 KiB UIO window (CAP + DESC); hello `mmio_size=0x1000`.
- [x] BAR4 A/B stage into card DRAM; host doorbell + DONE claim over MMIO; BAR4 get C.
- [x] `irq_wait` / `irq_clear` over TCP (eventfd MSI stand-in); claim order wait → DONE → clear.
- [x] Structured PyTorch suite `python/tests/test_torch_virt_ai_island.py` (ai_island features via virt-ai-pcie)
- [x] Host: `tensor pytorch|frameworks|regress --board virt-ai-pcie --core g6lc64_ai [--from-timing DIR]`
- [x] Virtual implementation multi-phase: `tensor virt-impl` / `--impl soft|hard|full` / `--rtl-hard`
  (soft Device/PyTorch → SV HARD work-ver-ai → sv-timing FO4 via `--from-timing`/`--use-emit`)
- [x] Monorepo soak: `run-ai-tensor-pytorch.sh` / `run-ai-tensor-virt-impl.sh` / frameworks / regress
- [x] Docs: monorepo `architecture/ai-matrix/frameworks-virt-pcie.md` §2.1a + HOST/FRAMEWORKS updates
- [x] Monorepo HARD catalog + progress table: `architecture/ai-matrix/hard-tests.md`, README §0
- [x] Working gate: `tensor virt-impl --impl hard --suite narrow --require-hard` (soft+SV PASS)
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

## Native scalar reference / descriptor v2 pass

- [x] Align Python/C/IR/runtime to Desc64 v2: A `[m][k]`, native B `[n][k]`, both default leading dimensions K in elements; reject v1 rather than reinterpret it. Existing profile filenames retained with new explicit v2 IDs/pins; old `t2_desc_v1` profiles are refused.
- [x] Shared first-party Rust `numfmt` and pure-Python `ai_tensor.numfmt` references for INT4/INT8/FP8 E4M3/E5M2/FP16/BF16/FP32, ordered non-fused f32 and wrapping i32 C32 outputs; SP24 unsupported even with bit 2 granted.
- [x] Preserve S8 matrix API mathematics through explicit B packing; validate native buffers/strides/AI-3 and memory extents (including completion pointer) before computed C writes. `Caps.dtype_mask` preserves discovered grants; default mask remains 0x0001.
- [x] `run_gemm_native`, `Device.gemm_native`, and `QemuUioSession.gemm_native`; CAP 0x28 dtype discovery; `software-reference-v2.toml` explicitly grants 0x00fb only for reference computation. No C binary caps layout changes.
- [x] Generic torch/NumPy `gemm` preserves matching dtypes via raw byte views and explicit B transpose; unsupported dtypes/backends/FP K-splitting are refused, never demoted. Known-bit packing helper avoids defining new quantization rules.
- [x] Strengthened C/Python/Rust descriptor version and NumFmt constant check. Added dependency-free reference tests and QemuUio raw protocol tests to `ait.py test`.
- [x] Virtual S8 wrapper remains functional: v2 pin, non-INT descriptor refusal, refreshed descriptor per tile (including ragged edges), and failed completion no longer returns stale C. Its native byte transport remains unimplemented.
- [x] Validation: `doctor`, `check-independence` (27 C/Python macros plus Rust comparisons), `cargo test --workspace --exclude ai-tensor-py` (58 tests), optimized `cargo test -p ai-tensor-rt --release` (43), `ait.py test --no-harness`, Python reference unittest (15, one NumPy skip), QemuUio unittest (22), virtual torch unittest (11), virtual local/TCP smoke, and pytest `python/tests` (85 passed, one NumPy skip). PyTorch generic FP16/BF16/FP32 and FP8 byte paths tested without NumPy. `git diff --check` passed.
- [x] Parent PyO3 validation: `cargo check -p ai-tensor-py --offline` passes with the existing Python 3.11 interpreter selected by `PYO3_PYTHON`. Python 3.14 is correctly refused by pinned PyO3 0.22.6; its version check was not bypassed. Extension build/import under the user's chosen interpreter remains separate from typechecking.
- [x] External local harness: fixed quoting of interpreter/script paths in `ait.py`; full `ait.py test` passes with Git's `usr/bin` on the child PATH so `sh` is available. Ping and numerical job results are exercised, not skipped. The root `ai-native-eval` host adapter also compares actual B3 descriptor execution to this package under live and software-fixture grants; no QEMU guest/hardware execution is claimed.
- [x] Descriptor-mode closure: `check_desc_format` is wired before layout/compute in SimDevice and SoftIsland. Unsupported dtype/accmode/EW/SP24 combinations return `ST_BAD_FMT` with C unchanged, and INT/EW1 aliases check the effective INT4 grant. Backend regression spans masks 1/2/3/0xfb. RT now passes 48 tests. Virtual S8 rejects unsupported arithmetic flags rather than evaluating them as signed INT8.
- [ ] Optional framework/runtime coverage: NumPy and TensorFlow are absent; NumPy generic tests skip explicitly and TF remains S8-only. No new dependencies were installed.
- [ ] Remaining: native virt-card bytes transport, generic TF, non-S8 multi-tile streaming, and FP hardware loader integration. Historical source comments are retained; ABI-CONTRACT v2 text supersedes old row-major B descriptions.

Software-only timing/DFT review: no RTL, core grants, codepolicy, DTS/config or physical PCIe contracts changed. MIT/Etienne Cimon headers retained or added to first-party code/config; Markdown kept header-free. No out-of-package Rust dependencies. Intermediate failures (missing APIs in new red tests, Rust moved-value/format-argument compile errors, stale virtual ragged-tile C) were corrected and rerun; the remaining denied/unsupported validations above are not soft-passed.

## 2026-09-08 — V/A-Turbo approximation as a measured trade-off (`ai_tensor.va_turbo`)

- [x] Approximation is no longer modelled as an admit/refuse gate. `python/ai_tensor/va_turbo.py`
  exposes two independent axes — a **throughput** estimate from measured RTL cycles, and a
  **quality** score measured by emulating the recipe's arithmetic on the caller's own torch
  tensors — plus `plans()`, `pareto()` and `autotune()`. Design: `architecture/APPROXIMATION.md`.
- [x] **The hardware-execution gate is the load-bearing honesty here.** The island RTL has no
  approximate execution consumer, so every plan carries `executable_on_hardware`: `True` only
  for `native-fp32` and the recipe-16 residency plan, `False` for all twelve approximate
  recipes. The API can *predict* up to 6.14x (INT4) but can only *execute* **1.279x** today
  (FP32 with both operands resident, measured). Nothing in the module or the doc may imply
  otherwise, and a test asserts an autotuned approximate plan still reports False.
- [x] All seven formats are MEASURED at m=n=8, k=16, PeLanes=8, NCH=1, one engine, class-0 SRAM:
  INT8 189, INT4 109, FP8 E4M3 189, FP8 E5M2 189, FP16 349, BF16 349, FP32 669 cycles/job,
  from the `signed=1` lines (the fixture that checks every C element). BF16 and E5M2 were
  briefly carried as `inferred_from_k_bytes` and then promoted after re-reading the log — the
  inferred values had matched exactly, which validates the equal-traffic rule but is not a
  reason to keep quoting a derived number. `INFERRED_TRAFFIC_TWIN` is now empty by result, and
  a test injects an entry so the flagging path cannot rot while unused.
- [x] `autotune` optimises **the axis the caller left free**: a quality budget maximises speed,
  but `min_speedup` alone maximises QUALITY among the recipes that reach it. The first
  implementation maximised speed in both cases, which returned INT4 at ~190,000 ppm when INT8
  at ~9,000 ppm also cleared 3x — spending accuracy nobody offered. Fixed and pinned by a test
  that asserts the property against the recipe set, not a recipe name.
- [x] Two results worth keeping visible: mantissa truncation and Mitchell score a **1.000x**
  cycle speedup (they narrow no storage, so they buy no operand traffic — they are area/depth
  levers, and recipe 19 exists to keep that visible), and INT8 beats FP8 E4M3 at *identical*
  traffic (~9,000 vs ~34,600 ppm on the fixture). Format choice at a given speedup is not
  arbitrary.
- [ ] Open: `convert-fp8-e5m2` has `id=None` because no `va_turbo_arith` slot carries the E5M2
  epsilon; left unset rather than guessed. Quality figures are proxies on synthetic fixtures,
  not model-quality results — a real network has to be run before any accuracy claim is made
  about a model. And the whole approximate surface stays prediction-only until the RTL grows a
  consumer.
- Verified: 177 pytest pass (1 skipped), `tools/check_independence.py` ok, `c_abi` lockstep ok.
  KD0 respected — no monorepo import; the bound formulas were read from the monorepo and
  re-derived locally rather than imported.

## 2026-09-08 (later) — the three deferred items, and one correction to the last pass

- [x] **The "no approximate execution consumer" framing was wrong, in the direction that
  understated the hardware.** The engine runs ALL SEVEN formats natively (that is where the
  measured 189/109/189/189/349/349/669 cycles come from), and a conversion recipe's whole gain
  is narrower STORAGE. So the approximation happens once, in software, on the way in, and an
  ordinary native GEMM follows: **no new RTL is needed to collect those speedups.** What has
  no consumer is approximate ARITHMETIC — truncation, Mitchell, in-place quantise — and those
  measure exactly 1.000x, so a consumer for them would be area for zero throughput. Classes
  are now `exact-native` / `exact-residency` / `native-narrowed` / `needs-rtl-consumer`, split
  by storage rather than by exactness.
- [x] `executable_on_hardware` is a checked predicate, not a constant: a `native-narrowed`
  recipe needs the active profile to advertise the format. `sim-v0`/`island-p3-v1` grant
  `0x0001` (INT8 only), `software-reference-v2` grants `0x00fb`. This caught a bug in my own
  gate — applying the mask check only to narrowed recipes claimed the EXACT FP32 path ran on
  a backend that answers `ST_BAD_FMT: numfmt 7 not granted by 0x1`. It applies to every
  recipe now.
- [x] `execute()` makes the predicted narrowing speedups real: convert, submit a NATIVE
  descriptor at the narrower format through the existing path, return the backend's own
  `meta` as evidence. Measured `convert-int8` on the sim backend: `status=0`, ~9,100 ppm
  against the FP32 reference versus ~9,000 ppm predicted by `emulate` — the two paths agree.
  INT8/INT4 return the scale rather than folding it away, because the island returns integer
  accumulators and raw INT32 presented as an FP32 answer is how a quantised path lies.
- [x] **End-to-end quality through a real architecture** (`va_turbo_net`): every matmul of a
  transformer stack routed through the recipe, everything the island does not accelerate left
  in FP32, logits scored. Error grows as roughly **depth^0.21** (R^2 0.95-0.99), so 12x the
  depth costs ~1.7x the error — per-layer error does NOT compound multiplicatively, and a
  single-tile bound is a conservative proxy. Decisions separate the formats much more sharply
  than norms do: FP16/BF16 change no top-1 decision, INT8 changes 1.6% for 3.54x, INT4
  changes 40% for 6.14x. Weights are seeded Xavier, NOT a trained checkpoint, so this is
  error propagation through a real architecture and not a model-accuracy claim.
- [x] **FP8 E5M2 gap closed in the RTL, not guessed here.** No recipe could reach its epsilon:
  4/5/7 pin FP16/BF16/E4M3, recipe 18's map covered only FP16/BF16/INT8, and code 3 returned
  INT8 as a target while `va_turbo_arith` gave the same code `VA_ARITH_NONE` — a target and an
  arithmetic that disagreed. Code 3 now carries E5M2 (eps 265,625 = `round_eps_ppm(2)`) and
  both FP8 targets require scale metadata. `convert-fp8-e5m2` is `id=18, approx_param=3`.
- [ ] Still open: a trained checkpoint for a real accuracy claim (none on this host); the
  `native-narrowed` path is verified against the sim/software backends, not silicon; and
  `execute()` converts on the host, so a production path would want the conversion done where
  the weights are stored rather than per call.
- Verified: 191 pytest pass (1 skipped), `check_independence.py` ok, `c_abi` lockstep ok;
  remote `ai-policy-subcode` PASS including the new `VA_E5M2_TARGET` checks.

## 2026-09-08 (later still) — lossless narrowing, the exact traffic lever

- [x] `python/ai_tensor/lossless.py`: the producer the RTL recipe needed. `prove(a, b, target)`
  is a **bit-pattern** comparison, not a tolerance — a "nearly exact" round trip is an
  approximate conversion wearing an exact label — and reports how many elements failed.
  Integer targets check integrality plus range, which is what makes `INT8 -> INT4` real:
  4-bit weights held in an INT8 array. `best_target` returns the NARROWEST exact target,
  since the point is the largest saving the data allows; full-precision tensors return
  `None`, which is a correct answer and not a failure.
- [x] `windowed_matmul` models the cost honestly: one RNE per window plus the accumulator
  fold, and NO rounding for integer formats because the RTL accumulates integers exactly.
  So the reported error is REGROUPING, never storage error. Measured on BF16-origin
  weights: 1.917x at ~0.007 ppm against the approximate FP16 twin's 977 ppm — ~130,000x
  tighter at identical traffic, windows 32 -> 16.
- [x] `INT8 -> INT4` reports `bit_identical=True` and the float pairs report `False`, with a
  test asserting the latter: claiming bit-identity for a regrouped accumulation would be
  this module's worst failure mode.
- [x] A test bug worth recording: the "nearly lossless must be refused" case originally
  perturbed by `1e-8`, which rounds straight back to the original float32 near 1.0 — so it
  proved nothing and passed for the wrong reason. It now uses `1 + 2^-20`, exactly
  FP32-representable and needing 20 mantissa bits that BF16's 8 cannot hold.
- [x] `PE_LANES` moved into `va_turbo` beside the cycle table rather than duplicated: it is
  part of the configuration those measurements came from, and it sets `mac_step`.
- [ ] Open: no consumer mask bit exists for recipes 1/3/17, so `plan()` says plainly that the
  island will not act on it; the cycle figures are the measured NATIVE ones per format
  because a narrowed job IS a native job; and a paired GEMM run asserting the proof is still
  the missing piece before this is a throughput claim.
- Verified: 203 pytest pass (2 skipped — one is E4M3 data legitimately not being
  E5M2-representable, 3 mantissa bits versus 2, i.e. the proof working),
  `check_independence.py` ok, `c_abi` lockstep ok.

## 2026-09-08 (pipeline) — stacking on the host

- [x] python/ai_tensor/pipeline.py: the host mirror of the RTL `va_turbo_compose`, plus
  the cost model. `cycles ~= steps + beta(fmt)*read_beats + 11` reproduces ALL TEN measured
  points to the cycle (four format totals, six residency points) from one beta per format and
  ONE shared constant. The FP32/INT8 single-operand points are genuine predictions: beta came
  from the 0-vs-full-beats endpoints, so the midpoints fitted nothing, and the constant
  falling out as 11 for both swept formats is why the decomposition is believable rather than
  merely fitted. beta RISES as the format narrows (traffic hides under compute; a narrow job
  has less compute to hide it under), which is why residency is worth MORE after narrowing.
- [x] The measured 4.813x stack (FP32->INT8 + both resident, 139 vs 669) is labelled
  `measured` because BOTH endpoints are in the measured table; one modelled endpoint taints
  the whole ratio, which is tested. Encoded trap: compose with the TARGET's residency gain
  (1.359x), not the source's (1.279x), or the stack is understated as 4.53x.
- [x] The refusals are the point, not the multiplication. Ordering hazard refused by DEFAULT
  (residency keys include the format, so narrow-then-reuse is a guaranteed miss unless the
  tile was already converted), and order-insensitively, since the hazard is a property of the
  pair. Also refused: two conversion targets, two group geometries, widening, and EQUAL width
  (BF16 <-> FP16 saves no beats). Narrowing twice COLLAPSES rather than accumulating. Error
  terms ADD and the budget gates the COMPOSED bound.
- [x] Each lever states what it does not buy: approximate arithmetic 1.000x with its error
  intact, grouping 1.000x with the single-C-port reason, zero-skip cuts the STEP term only
  (a skipped product was still read) and is always `modeled` since no RTL consumer exists.
- [x] Quantified why zero-skip is correctly last: it competes with narrowing for the same
  term. FP32 spends 512 of 669 cycles on steps, INT4 only 64 of 109, so the same skip
  fraction is worth strictly less after narrowing. A test pins the ordering.
- Verified: 218 pytest pass (2 skipped), independence ok, c_abi lockstep ok.
- [x] THE RETIRE CEILING resolves three measured dead ends as ONE mechanism, and says
  what to build. steps = m*n*ceil(row_bytes/lanes) has floor m*n because the RTL
  writes one C element on its last reduction step through a single c_w_req port: one
  C port retires one element per cycle whatever the lane count. So (a) lanes stop
  helping once row_bytes <= lanes, (b) C ports cannot help while groups == 1 since two
  ports need two finished dots, and (c) groups > 1 exists only when lanes > row_bytes,
  which is exactly what NARROWING manufactures. Testing either lever alone therefore
  HAD to measure nothing -- which is precisely what INT4-past-8-lanes (0%),
  16->32-lanes-byte-identical, and grouping-produces-nothing each reported.
- [x] Quantified, doubling from the shipped 8 lanes / 1 port: FP32/FP16/INT8 are
  lane-bound so lanes alone give 1.62/1.58/1.51x and ports alone give exactly 1.000x;
  INT4 is already retire-bound so lanes alone give exactly 1.000x (the measurement,
  reproduced) and only both together give 1.416x. At 64 lanes: FP32 groups=1 so ANY
  number of C ports gives 1.000x (the control that proves the mechanism), INT8 groups=4
  gives 1.623x (125 -> 77 cy), INT4 groups=8 gives 2.057x (109 -> 53 cy).
- [x] Conclusion recorded in rchitecture/ai-matrix/va-turbo.md §17: C-port widening
  is NOT a general throughput lever, it is the second half of narrowing's. Build it only
  jointly with lanes, only for narrowed formats, and only up to the group count -- ports
  beyond groups are pure area, the same trap the 16->32 lane experiment fell into from
  the other side. All of it labelled modeled: no RTL has more than one C port, so the
  2.06x is a prediction and says so.
- Verified: 222 pytest pass (2 skipped), independence ok, c_abi lockstep ok.
## 2026-09-08 (validation) — the model holds out of sample, and it reorders the roadmap

- [x] ITEM 1 DONE, better than hoped. cycles = steps + beta*beats + c was fitted on the
  CONCURRENT tb at PeLanes=8; the i-gemm-codec-basis runs already on disk test it on a
  DIFFERENT tb (gemm_backend +measure) at PeLanes 8/16/32/64. The beat formula is exact
  on 140/140 points, and solving beta at all 16 (format x lane) points of the 8x8x16 job
  gives a spread of EXACTLY ZERO per format, reproducing 1.5625/2.125/1.28125/1.140625 to
  the digit. The two harnesses differ by exactly ONE cycle in the constant (11 vs 10) and
  not at all in beta -- so the constant is harness overhead and beta is the machine.
  beta is LANE-INDEPENDENT, which is why an 8-lane fit predicts 64 lanes.
- [x] The lane rule is now DERIVED, not tabulated: optimal_lanes = row_bytes =
  k*bytes_per_element, which reproduces all four measured saturations (INT4 8, INT8 16,
  FP16 32, FP32 64). The policy package's "twice the element width" is this rule at k=16.
  It predicts the optimum MOVES with k (INT4 8->16->32, INT8 16->32->64) -- exactly what
  +measure_k was written to test, and NO k>16 data exists on disk, so that stays a
  prediction shared by the model and the tb comment.
- [x] ITEM 2: the priority INVERTS between prefill and decode, and it reorders the
  roadmap. steps scales with m*n and beats with m+n, so at m=1 the weight matrix B is
  essentially ALL the traffic, re-read per token. At each shape's own optimal lane count,
  FP32 resident-B is worth 1.36-1.49x on square tiles but 5.04x at decode 1x16x16 and a
  projected 91.5x at 1x256x256 (B = 94-100% of traffic vs 50% square). So RECIPE 16 --
  already implemented and verified -- is the largest opportunity in the catalog, and the
  measured 1.279x came from the LEAST favourable shape for it. A square tile at its own
  optimal lane count is exactly balanced (steps == beats, since steps/beats = 4n/lanes
  and lanes = k*bytes gives 1 at n == k), which is why residency caps near 2x there.
- [ ] Therefore the next MEASUREMENT is resident-B at m=1, not more square tiles, and not
  C-ports (a prefill lever worth 1.6-2.1x). Then +measure_k for the general lane rule.
- Verified: 225 pytest pass (2 skipped), independence ok, c_abi lockstep ok.
- [x] ITEM 4 DONE, and it REOPENED a family I had written off. Truncation (21/25/30/31)
  and Mitchell (27/28) measure exactly 1.000x in cycles -- correct, but the conclusion I
  drew was too strong. They are cycle-neutral BY CONSTRUCTION (no operand byte, no
  reduction step changes), so CYCLES ARE THE WRONG INSTRUMENT; their path is
  area -> lanes -> steps. Isolated synthesis of g6lc_ai_pe_dot: 2,868 / 5,867 / 11,834
  cells at 4 / 8 / 16 lanes, i.e. ~735 cells per lane and **78% of the 7,530-cell engine
  at 8 lanes**. The engine is essentially all multiplier, so the area target is LARGE.
- [x] Quantified the trade: the array is linear and dominant, so constant area buys lanes
  in proportion, and lanes cut steps until lanes >= row_bytes. FP32 at k=16: 2x shrink ->
  16 lanes -> 1.62x; 4x -> 32 -> 2.35x; 8x -> 64 -> 3.04x; and then it STOPS (measured:
  32->64 lanes gave FP16 nothing). Ceiling 3.04x, needing an 8x smaller multiplier.
- [x] Verdict: narrowing DOMINATES wherever the data permits -- FP32->INT8 lossless is
  3.54x at ZERO error and FREES area rather than re-spending it. But the niche survives:
  narrowing needs the values to fit the target's RANGE and truncation does not (it drops
  mantissa bits, keeps the FP32 exponent), and 	runcate-10 at 1,953 ppm is 4x more
  accurate than BF16 while preserving FP32 range -- a ladder point no conversion covers.
  Structural tension named: narrowing lowers the lane optimum and leaves a big array
  over-provisioned, truncation keeps row_bytes and makes each lane cheaper. Two routes to
  the same goal; the data decides, not preference.
- [ ] What would settle it: an actual truncated g6lc_ai_pe_dot variant synthesised for
  cells and Fmax. The area above is measured but the shrink factor R is an ASSUMPTION --
  no truncated datapath exists.
- [x] SHRINK FACTOR R MEASURED, and it CLOSES the approximate-arithmetic family. Scope
  correction first: the 78%-of-engine figure was the INTEGER dot, but truncation and
  Mitchell are FLOATING-point, so the relevant module is g6lc_ai_pe_dot_float, whose
  product is one 24x24 multiply per lane (g6lc_ai_fp_pkg.sv:215). Masking the decoded
  mantissas ahead of the SAME package function the datapath calls: 4,094 / 1,257 / 665 /
  558 cells at keep = 23 / 10 / 4 / 1, i.e. shrink 1.00 / 3.26 / 6.16 / 7.34x.
- [x] Those are UPPER BOUNDS and the distinction decides the recipe: only the product
  path shrinks, while the 640-bit alignment and reduction tree do not, so with X
  non-shrinking cells per lane R = (4094+X)/(1257+X) -- 3.26x at X=0, 1.87x at X=2,000,
  1.53x at X=4,094. X could NOT be measured: the whole float dot stalls ABC on the
  640-bit alignment cone (>14 min at 4% CPU), the same pathology that excluded the
  request-side composition top. Bound reported, point value not invented.
- [x] CONCLUSION: the area->lanes ladder needs R >= 8 for its 3.04x ceiling. Even at the
  impossible X=0 truncate-10 gives 3.26x -> about 2.0-2.35x by the measured lane sweep,
  and any real alignment cost lowers it. Lossless narrow FP32->INT8 is 3.540x at ZERO
  error and FREES area instead of re-spending it. So the approximate family cannot beat
  narrowing even on its own best route -- now a measurement, not an argument. Niche
  unchanged: data whose RANGE forbids conversion, where truncate-10 (1,953 ppm) is 4x
  more accurate than BF16 with FP32 range preserved. No production RTL touched.

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
