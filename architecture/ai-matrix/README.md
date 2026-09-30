# Extension point: AI matrix acceleration (`Xg6lcai`)

**Status:** **live RTL + host stack (P1–P3 / I1 partial)** · **Code prefix:** `g6lc_ai` / `Xg6lcai` ·
**Licensing:** tier **R** (open, dual-licensed — §7) · **Config package:** `g6lc64_ai`

Feature-domain for INT8 matrix acceleration on LibreCore: PCIe **CPU+AI card** with application-class
cores and a matrix island sharing one address space. Read `../README.md` (scaffold contract) and
`../../AGENTS.md` §0 first. Transport: `../uncore/pcie-endpoint.md`.

| Doc | Role |
|---|---|
| [`isa-encoding.md`](isa-encoding.md) | Frozen ISA / CSR / Desc64 contract |
| [`scaling-100tops.md`](scaling-100tops.md) | I0–I4 sizing; §4.2–4.3 shared `DramChannels` (cores + island); **next: I3 measure → I2 clusters** |
| [`va-turbo.md`](va-turbo.md) | Exact reuse on `AiCfgVaTurboTest` only. Live `VaTurboEn` stays 0. Not a TOPS step. Completion path: ownership/epoch, then an error bound before any level above 0 |
| [`log-2026-09.md`](log-2026-09.md) | September 2026 state: live 512-MAC geometry, carried port and DRAM claim, and the directed exact-reuse schedule. Live `VaTurboEn` stays 0 |
| [`hard-tests.md`](hard-tests.md) | **HARD suites + directed ELF catalog + green results** |
| [`frameworks-virt-pcie.md`](frameworks-virt-pcie.md) | soft virt-ai-pcie + `tensor virt-impl` soft→HARD→timing |
| [`completion-fifo.md`](completion-fifo.md) | CPL FIFO RTL + multi-claim |
| [`board-uio-eventfd.md`](board-uio-eventfd.md) | PLIC-8 / UIO / eventfd board contract |
| [`../../ai-tensor/AGENTS.md`](../../ai-tensor/AGENTS.md) | Host ML backend package |

**Host gates (build-platform)** — same shape as OoO (`diag run ooo`, `test --suite ooo-l3-tests`, `--from-timing`):

```text
diag run ai                                                      # paths + optional g6lc64_ai lint
test --ai                                                        # config / matrix / island directed
test --ai --channels 4 --ai-dram 1                               # x4 DDR4 LiteDRAM stripe + wrap TB
test --ai --ai-ghz 1.25 --from-timing <fo4-pkg>                  # Cas=14 timing SKU + FO4 preflight
test --ai-remote                                                 # I3 S4 testharness_proxy (ai-dt)
test --ai-qemu                                                   # g6lc_qemu Linux/emulation (NOT Variane)
tensor pytorch --board virt-ai-pcie --core g6lc64_ai             # soft
tensor virt-impl --impl hard --suite narrow --require-hard       # soft + SV HARD
tensor rtl-hard --suite narrow|smoke|ci|peak                     # SV only
g6q --ai doctor                                                  # higher-level ingest host
remote --ai build                                                # proxy flavour ai-dt
```

> Architecture docs under this tree remain **non-flist** design of record. Live RTL lives under
> `core/` (CVXIF plane) and `corev_apu/ai_island/` (T2 island) — see §3 and [`hard-tests.md`](hard-tests.md).

**Scaling plan of record: [`scaling-100tops.md`](scaling-100tops.md)** — what changes when the target
is the 100-TOPS class rather than 1–5 TOPS. It supplies the bandwidth-first sizing model, the
core-attached/island plane split (§1.1 below), the closed SKU decision (latency first,
throughput by cluster replication), and the island track I0–I4 (§8). Read it before
sizing anything.

> **Scaffold contract.** Nothing in this file is compiled. No path here is referenced by
> `core/Flist.cva6`, any `verif/` flist, or any `pd/` script. This document *reserves* seams and
> records decisions; it moves no RTL.

## Table of contents
0. **AI RTL feature progress (current)**
1. Intent, the three-tier model, and the two-plane split at scale
2. Seam decision (evidence-based) — **the load-bearing section**
3. Code map / loci as they exist today
4. Config knobs
5. ISA + CSR surface
6. Software / SBI / Linux / `.dts`
7. Licensing — the open path, terms left to the reader
8. Phasing and acceptance
9. Invariants and pitfalls

---

## 0. AI RTL feature progress (current)

Honest status of **implemented silicon/software**, not the scaffold-only state of early P0.

| Feature / plane | Locus | Progress | Verification |
|---|---|---|---|
| **CVXIF seam B** `COPRO_G6LC_AI` | `core/` + `ariane.sv` | **Live** | directed CSR/T0/T1 suite |
| **Config** `g6lc64_ai` / `AiMatrixEn` | `core/include/*` | **Live** | package elaborate + veri target |
| **CSR** `aicfg` / `aistatus.ais` → `mstatus.xs` | `csr_regfile` | **Live** | `ai_csr_*` / illegal-when-off |
| **T2 island MMIO** @ `0x4000_0000` | `corev_apu/ai_island/` | **Live** | **HARD** `ai_island_mmio_smoke` ~1144 cy |
| **CPL FIFO** multi-claim | `g6lc_ai_cpl_fifo` | **Live** | `ai_cpl_fifo_multi_claim` HARD |
| **PLIC-8 IRQ** | island top + SoC | **Live** | `ai_irq_plic_smoke` |
| **Desc DMA fetch/store** | island engine | **Live** | `ai_desc_fetch_*` / enq/fetch smokes |
| **I1-lite INT8 GEMM** AccTile/PeLanes **512** (`AI_LIVE_MACS`) | island compute | **Live (lite)** | small golden on the 512-lane sequencer 822/902 cy; 256³ ~83.7k cy is the previous array |
| **PMU / CAP geometry** | CAP + PMU windows | **Live** | cap/bw_pmu smokes |
| **I3-lite bus** (trail C-store, multi-out AR, …) | island fabric | **Live** | scale gemm + PMU |
| **NoC width 64b** | island | **Floor (live)** | define-on island DMA is 512 bits; channel stays 64 |
| **I2 multi-cluster / NoC/QoS** | island package | **Not started** | F8 present/enabled + bitmap published; still measure I3 BW first |
| **I3 full memory bandwidth model** | DRAM/channels | **I3-lite live; DRAM I3 opt-in** | class 0, 8 GB/s, N=1, Cas=0 default; SoC `master[DRAM]` shared with cores/L2; opt-in class-1 N=1/2/4/8 and class-0 `SIM_CHANS_{2,4,8}`; GEMM class-1 N=8 **1162 cy** wide all-NCH occupancy; 400 is class 2 |
| **PCIe EP + virtio (P5)** | uncore | **Virtual only** | `virt-ai-pcie` TCP + EDK2 GPEX RC witness; transport **unpinned** |
| **ai-tensor host** sim/SoftIsland/virt-card | `ai-tensor/` | **Live** | golden + queue/event-fd soaks |
| **PyTorch soft path** | `torch_ops` + virt-card | **Live** | `test_torch_virt_ai_island` (torch optional) |
| **soft→HARD virt-impl** | build-platform `tensor` | **Live** | `virt-impl --impl hard --suite narrow` **PASS** |
| **Kernel UIO/eventfd** | Linux driver | **Open** | contract in board-uio-eventfd |
| **I4 PD / UPF / thermal** | backend | **Open** | — |

**Next program step (scaling):** the class-1 80% of `min(nameplate, 8 GB/s fabric)` floor
is already closed. The live array is already 512 MAC/cycle; do not raise `AI_LIVE_MACS` or add channels on that port. The second DRAM ingress,
`g6lc_ai_dram_join`, sits above the stripe. With `G6LC_AI_DRAM_ISLAND_PORT` the island
DMA is 512 bits and the join narrows it onto the 64-bit channel. The island
at that width completes an 8×8×8 INT8 GEMM onto the 64-bit channel
(`tb_g6lc_ai_island_wide`). The same define elaborates and links `g6lc64_ai`
under Verilator 5.036; stock 5.020 faults before elaboration, and the linked
model has not been booted. Unset, slave port 2
stays the 64-bit crossbar. That define does not raise the measured 8 GB/s ceiling:
C stores, descriptor fetches, and the completion word are still 8-byte beats.
The island PMU bills those C handshakes at 8 bytes, so `0x18C` does not
treat a C store as a 512-bit beat. Operand reads use the full port beat, so
a one-byte row on that 512-bit port occupies 64 bytes. The core sideband
applies the same descriptor-fetch check as the doorbell. A non-default
throughput struct, `AiIslandThroughputSku`, is the elaboration of I2 (8
clusters), a 4096-MAC cluster, and the float format codes except structured
2:4. Its peaks are parameter sketches (98.3 INT8 TOPS, 24.6 FP32 TFLOPS, and
the width-scaled rows beside them). The live package is a 2.048 TOPS nameplate
(512 MAC/cycle × 2 GHz), INT8|INT4, and class 0 at 16 GB/s on the 64-bit port.
VA-turbo does not multiply that MAC rate. The sequencer box is 1024×512×512.
The VA panels are 512×512, 512×256, and 1024×128. MAC issue stays 512.
Class 2 still has no PHY; `Class2Model` is an off-by-default rate
socket. V/A-Turbo is not this step. The directed schedule is recorded in
[`log-2026-09.md`](log-2026-09.md).
Design asks: [`../../g6lc_qemu/architecture/RTL_FEEDBACK.md`](../../g6lc_qemu/architecture/RTL_FEEDBACK.md)
§2.1 / §3.3. Snapshot: [`../current-stage.md`](../current-stage.md).
Detail: [`hard-tests.md`](hard-tests.md) §5 · [`scaling-100tops.md`](scaling-100tops.md) §11.

---

## 1. Intent and the three-tier model

"Custom AI instructions" is not one mechanism. Three tiers with different latency and trap contracts:

| Tier | Mechanism | Latency | Traps | Work |
|---|---|---|---|---|
| **T0** synchronous | CVXIF FU (`core/cvxif_fu.sv`) | 1–4 cyc | precise, in-pipeline | tile config, requant/activation fuse, small dot-products, queue doorbell, `ai.poll` |
| **T1** long-latency | accelerator seam (`core/acc_dispatcher.sv`), scoreboard writeback | 10s–100s cyc | precise via scoreboard | INT8 tile MMA into accumulator banks |
| **T2** asynchronous | memory-resident descriptor rings + MMIO doorbell + completion IRQ, in `corev_apu/` | µs–ms | device errors, not exceptions | full GEMM/conv/attention blocks, weight prefetch, layout transforms |

T2 is the *instruction management* layer proper: the core must never block commit on a large GEMM.
T0/T1 exist for the low-latency, control-adjacent work (sampling, MoE routing, small experts) that is
the entire reason to put application-class cores on the card.

### 1.1 Two planes, not three tiers of one unit

Above roughly 5 TOPS the three tiers stop being one unit. T0/T1 and T2 become **different silicon on
different sides of the core boundary** (`scaling-100tops.md` §3):

| | **Core-attached plane** (T0 + T1) | **Island plane** (T2) |
|---|---|---|
| Location | `core/`, at the CVXIF (B) or accelerator (D) seam | `corev_apu/`, a device on the fabric |
| Size | **fixed and small** — one 8×8×8 tile unit, ~0.1–0.3 TOPS | scaled — N clusters, up to ~100 TOPS |
| Sized by | `ai_cfg_t` in `cva6_cfg_t` (§4) | island package + MMIO capability window (§4.1) |
| Job | latency: sampling, routing, small/dynamic shapes, requant fusion | throughput: bulk GEMM/conv/attention |

**The core-attached tile geometry must not grow with the TOPS target.** Growing it lengthens
`ex_stage`-adjacent cones and buys throughput that belongs in the island.

**The advantage this design sells is locality, not peak FLOPs.** Matrix work and irregular fallback
share one address space with no host round-trip and no separate device allocator. Anything that
breaks that (a private accelerator memory, a copy-in/copy-out API) discards the premise.

## 2. Seam decision

Four options were costed against the RTL. Evidence:

| Fact | Locus |
|---|---|
| CVXIF and the accelerator port are **mutually exclusive at elaboration** | `core/cva6.sv:1138-1140` |
| `EnableAccelerator` is **derived from `RVV`**, not a user knob | `core/include/build_config_pkg.sv:37` |
| Both seams cost the **same** 5th writeback port | `core/include/build_config_pkg.sv:38` |
| The accelerator path is **single-issue only** | `core/cva6.sv:2214-2219` |
| The accelerator path owns an **MMU port** | `core/load_store_unit.sv:417-423` |
| …a high-priority **dcache port** | `core/cache_subsystem/wt_dcache.sv:196` |
| …and receives **PMP config** from the CSR file | `core/csr_regfile.sv:202-205` |
| CVXIF has **operands in / result out only — no memory path** | `core/cvxif_fu.sv:49-53` |
| The accelerator path needs a first-pass decoder; the shipped one is a **stub that `$error`s** | `core/cva6_accel_first_pass_decoder_stub.sv:30-32` |
| CVXIF already has a **config-selected instantiation seam** (`copro_type_t`) | `core/include/config_pkg.sv:93-97`, `corev_apu/src/ariane.sv:159-188` |
| Ara upstream is **tier U** — cannot be edited (`E-UPSTREAMWRITE`); only the 3-file shim list overrides | `vendor/ara/cva6_shim/README.md:6-13` |

| | **A** inside Ara | **B** CVXIF | **C** unified arbiter | **D** decouple `EnableAccelerator` |
|---|---|---|---|---|
| Needs RVV/Ara on flist | **yes** | no | no | **no** |
| Multi-issue allowed | **no** | **yes** | after rework | no until `cva6.sv:2216` resolved |
| Own MMU + dcache port | yes | **no** | yes | **yes** |
| Tier-U edits | **yes (fork)** | none | none | none |
| Touches issue/commit | no | no | **yes** | no |
| Effort | large | **small** | very large | medium |

**Decision: B for P1–P2, D for production. A and C rejected.**

> **Amended by the scaling review (`scaling-100tops.md` §3).** At 100 TOPS ~99.7% of the arithmetic
> never crosses a core seam, so **the seam choice is decoupled from the throughput target**. The card
> SKU may ship on **seam B**; option D remains on the roadmap for the small/embedded SKU (native
> `ai.ldt` with no DMA engine) and for T1 latency. Consequence: **AI-2** is no longer on the card's
> critical path.

- **A rejected**: buys a memory port at the price of a tier-U Ara fork, mandatory RVV, *and*
  single-issue — while the card SKU wants `stream8`-class multi-issue.
- **C rejected**: arbitrating two offload ports inside issue/commit is the `AGENTS.md` §0.3
  "breaking module boundaries" anti-pattern, for a benefit not currently needed.
- **D** is not an arbiter; it is one derivation plus a knob:
  `EnableAccelerator = CVA6Cfg.RVV || CVA6Cfg.AiAccelEn`, with `check_cfg` enforcing
  `!(AiAccelEn && RVV)` and `!(AiAccelEn && CvxifEn)`. The MMU/dcache/PMP-visible seam without RVV and
  without touching Ara.

### 2.1 The decisive technical point

INT8 GEMM is **load-bound, not MAC-bound**. CVXIF has no memory port, so under **B** every tile
arrives through core loads, consuming issue slots and L1 bandwidth in exactly the cycles the control
thread wants. **Therefore under B the T2 descriptor/DMA engine is mandatory, not optional**; T0
instructions only handle config, requant, small dots and doorbells. State this in any P1 review — a
CVXIF-only matrix unit with no DMA is bandwidth-starved by construction.

### 2.2 Migration invariant

Keep the **instruction encoding, the CSR map and the T2 descriptor ABI identical across B and D.**
Then the seam migration is invisible to the toolchain, the kernel driver and the PyTorch backend, and
the software stack built in P6 is not rewritten. This is the property worth designing for now.

### 2.3 Blocking pre-existing conflict

`core/include/g6lc64_server_math_v_config_pkg.sv` sets **both** `SuperscalarEn=1 / NrIssuePorts=2`
(`:99-101`) and `RVV=1` (`:118`), which violates `core/cva6.sv:2216`. It survives only because that
assert is a `translate_off initial` block and the target normally elaborates against a **stub** Ara —
a real simulation should `$fatal` at time 0. This is **shared blocking work** between the vector track
and option D, and is the single largest hidden cost in the phasing below. Tracked in `AGENTS-todo.md`.

## 3. Code map (today)

| Layer | Locus | Note |
|---|---|---|
| CVXIF FU | `core/cvxif_fu.sv` | result/exception forwarding only |
| CVXIF coprocessor example | `core/cvxif_example/`, `include/cvxif_instr_pkg.sv:56-64` | mask/match pattern; squats **custom-3** (`0x7B`) |
| **Xg6lcai CVXIF coprocessor (P1)** | `core/cvxif_g6lc_ai/` | mask/match custom-2 `0x5B`; T0 + tile/acc RF + multi-cycle MMA; T2 stubs |
| Coprocessor selection enum | `core/include/config_pkg.sv:93-97` | `COPRO_G6LC_AI` present |
| Coprocessor instantiation | `corev_apu/src/ariane.sv` `gen_COPRO_G6LC_AI` | instantiates `g6lc_ai_coprocessor` |
| Accelerator dispatcher | `core/acc_dispatcher.sv`, genblock `core/cva6.sv:1905` | option D target |
| First-pass decoder stub | `core/cva6_accel_first_pass_decoder_stub.sv`, flist `core/Flist.cva6:194` | replace for option D |
| Accelerator decode hooks | `core/decoder.sv:168-171, 1854-1857, 1939-1942` | `is_accel` overrides decode |
| Writeback port count | `core/include/build_config_pkg.sv:38` | 5th port shared by both seams |
| PMU | `core/perf_counters.sv` group 4 (`MHPMGrpAI`) | see §5.1 |
| RVFI | `core/cva6_rvfi.sv`, `rvfi_types.svh` | `aicfg`/`aistatus` probes + UVMT assigns |
| Island top / GEMM / capability window | `corev_apu/ai_island/g6lc_ai_island_top.sv`, `g6lc_ai_gemm_seq.sv`, `g6lc_ai_cap_window.sv` | T2 DMA, 256-MAC tile, CAP at `0x4000_0000` |
| SoC DRAM slave | `corev_apu/src/g6lc_ai_dram_backend.sv`, `g6lc_ai_dram_channels.sv` | one slave today; class 0 N=1 is `axi2mem`, N>1 and class 1 stripe |
| Second ingress | `corev_apu/src/g6lc_ai_dram_join.sv` | cluster + island above the stripe. Default off (`G6LC_AI_DRAM_ISLAND_PORT`) |
| Testharness DMA port | `corev_apu/tb/ariane_testharness.sv` slave[2] | island DMA. Define peels a 512-bit port onto the join and that `g6lc64_ai` model links under Verilator 5.036; unset, it stays on the 64-bit xbar |

## 4. Config knobs (proposed — `cva6_cfg_t` + `check_cfg`)

| Knob | Meaning | Legality rule |
|---|---|---|
| `AiMatrixEn` | master enable | requires `CvxifEn` (B) **xor** `AiAccelEn` (D); never with `RVV` |
| `AiAccelEn` | use the accelerator seam (option D) | `!(AiAccelEn && RVV)`, `!(AiAccelEn && CvxifEn)` |
| `AiTileM/N/K` | native tile geometry | powers of two |
| `AiAccBanks`, `AiAccDepth` | accumulator SRAM | `AiAccBanks >= NrHarts` when SMT |
| `AiQueues`, `AiQueueDepth` | T2 rings | 0 disables T2; T0/T1 still legal |
| `AiRequantEn`, `AiSparseEn` | optional op groups | independent, so a minimal AI SKU stays small |
| `AiTileLdEn` | native `ai.ldt`/`ai.stt` | **0 under seam B** (no memory port), 1 under seam D; discoverable, not an encoding change |
| `AiUmodeEn` | allow U-mode issue | requires `aiperm` |

### 4.1 Island sizing stays out of `cva6_cfg_t`

**Decision (`scaling-100tops.md` §8).** Cluster count, MACs per cluster, per-cluster SRAM, NoC width,
DRAM channels and QoS classes are **uncore** parameters. Putting them in `cva6_cfg_t` would tax ~24
core config packages with fields no core module reads.

| Parameter class | Home |
|---|---|
| Seam, tile geometry, accumulator banks, ring count/depth, op-group gates | `config_pkg::ai_cfg_t` — **unchanged** |
| Clusters, MACs/cluster, cluster SRAM, NoC, DRAM channels, QoS classes | `corev_apu/include/g6lc_ai_island_cfg_pkg.sv` (tier **R**) |
| Runtime discovery of island geometry | MMIO **capability window** + the `g6lc,ai-matrix` DTS node |

This is what keeps the frozen contract invariant across SKUs: `ai.setcfg` describes only the
core-attached plane, so one binary runs on the 5-TOPS and the 100-TOPS part.

Package of record: `core/include/g6lc64_ai_config_pkg.sv` (tier **R**), riding `g6lc64_stream8`
numbers (`NrCores=2`, L2, Zacas — `../stream8-class.md`) plus `AiMatrixEn=1`. Every knob defaults
**off** in all existing packages.

> **Config churn warning.** `cva6_user_cfg_t` is populated by *named struct literals* in 13+ packages;
> a missing member is an elaboration error. Group the AI knobs into one nested `ai_cfg_t` field so
> each package gains exactly one line.

## 5. ISA + CSR surface

Vendor extension, discovery token `xg6lcai`. Encodings in **custom-2 (`0x5B`)** — custom-3 is already
occupied by the CVXIF example (`core/cvxif_example/include/cvxif_instr_pkg.sv:56-64`).

| Group | Mnemonics | Notes |
|---|---|---|
| Config | `ai.setcfg rd, rs1` | `vsetvli`-shaped; writes `aicfg`, **returns granted geometry** — software must read back |
| Tile move | `ai.ldt`, `ai.stt`, `ai.mvacc` | strided; accumulator↔GPR/VRF moves |
| Compute | `ai.mma.s8/u8/su8/us8`, `ai.dot4.s8` | `s8×s8→s32` accumulate; `dot4` is the T0 short form |
| Post-op | `ai.requant`, `ai.act` | s32→s8, per-channel scale + zero-point, optional activation fuse |
| Queue mgmt | `ai.enq`, `ai.poll`, `ai.qfence` | T2 doorbell / completion from user mode, no syscall |
| Sparse assist | `ai.gathr`, `ai.expsel` | INT8 row gather + MoE expert-select reduction |

CSRs (custom range, in `core/csr_regfile.sv`): `aicfg` `0x801` (geometry/dtype), `aistatus` `0x802`
(busy, dirty, error, ownership, **`ais[7:6]`**), `aiscale`/`aizp` (requant), `aiqbase`/`aiqctl`
(**S-mode only**; U-mode gets a mapped doorbell page), `aiperm` (per-privilege issue enable).
**Note:** `0x800` is `CSR_FTRAN` — never host `aicfg` there.

**Extension state (AI-X, landed).** `aistatus.ais` is the extension’s own Off/Initial/Clean/Dirty
field; `mstatus.xs` / `vsstatus.xs` are a **read-only** summary of `ais` when `AiCfg.MatrixEn=1`.
Illegal-instruction on issue tests **`ais`**, not a writable XS. Full contract in `isa-encoding.md`
§5. **Accumulators must be flushed or ownership-checked on context switch** — stale INT8 activations
of another tenant are a real cross-tenant leak on a multi-tenant inference card.

### 5.1 PMU group 4 + RVFI (landed)

`mhpmeventN` packing is `{group[7:5], idx[4:0]}` (`ariane_pkg`: `MHPMEventGrpWidth=3`,
`MHPMEventIdxWidth=5`). Group **`MHPMGrpAI = 4`** is reserved for Xg6lcai; indices are stable once
published:

| `mhpmevent` | idx | Event | Source |
|---|---|---|---|
| `0x80` | 0 | AI op complete (any result_valid) | `ai_pmu_op` |
| `0x81` | 1 | AI MMA complete | `ai_pmu_mma` |
| `0x82` | 2 | AI post-op (requant / relu / gelu) | `ai_pmu_post` |
| `0x83` | 3 | AI T0 complete (setcfg/getcfg/dot4/mv*/enq/…) | `ai_pmu_t0` |
| `0x84` | 4 | AI busy cycle (level → cycle count) | `ai_pmu_busy` |

Probes are generated in `g6lc_ai_exec` (class pulses with `valid_q`; busy is `exec_busy`), threaded
copro → `ariane` → `cva6` → `perf_counters`, gated on `AiCfg.MatrixEn`. Tie-offs when the copro is
absent. Directed smoke: `verif/tests/custom/ai/ai_pmu_group4_smoke.S`.

**RVFI:** `RVFI_PROBES_CSR_T` / `RVFI_CSR_T` carry `aicfg`/`aistatus`; `csr_regfile` drives
`rvfi_csr_o.*_q`; `cva6_rvfi` uses `CONNECT_RVFI_SAME(MatrixEn, …)`; UVMT
`RVFI_CSR_ASSIGN`/`UVM_CONFIG_DB_SET` for both.

**Tile loads are the one behavioural difference between the seams.** CVXIF has no memory port, so
`ai.ldt`/`ai.stt` are not executable under option B and the compiler must synthesise them from scalar
loads plus `ai.mvta`; under option D they use the accelerator MMU port. This is exposed as the
separately discoverable `AiTileLdEn` (`isa-encoding.md` §3.3, §8) rather than as an encoding change.

**SMT2 interaction is not optional.** With `NrHarts=2` the matrix unit is shared: per-hart
`aicfg`/`aistatus`, and accumulators **banked per hart** (`AiAccBanks >= NrHarts`) rather than
ownership-locked, so an AI-heavy hart cannot starve the control hart. A lock-based alternative needs a
fairness counter and a watchdog.

## 6. Software / SBI / Linux / `.dts`

| Artifact | Role |
|---|---|
| `corev_apu/bootrom/ariane-ai.dts` (tier **R**) | base ISA + vendor token `xg6lcai` in `riscv,isa-extensions`; a `g6lc,ai-matrix` node with tile geometry, accumulator banks, queue count, T2 register window + IRQ |
| OpenSBI | extension-state enable + save/restore; an SBI call for T2 queue reset on hart teardown |
| Linux | `g6lcai` driver: owns `aiqbase`, allocates rings, `mmap`s a doorbell page + ring per process, completions via `eventfd` |
| Toolchain | `.insn`/inline-asm intrinsics in `libg6lcai` first; binutils/LLVM vendor-extension patch later |
| PyTorch | `PrivateUse1` device `g6lc`, kernels via `TORCH_LIBRARY_IMPL`; dense INT8 → T2, small/dynamic → T1, everything else CPU **in the same memory, zero copy** |

**Alignment rule** (mirrors `agents/guides/AGENTS-vector.md:94-95`): package `AiMatrixEn` ⇔ CSR
presence ⇔ DTS `xg6lcai` ⇔ SBI state handling ⇔ runtime discovery. **Never advertise `xg6lcai` on a
tree with `AiMatrixEn=0`.** Cross-validate the DTS per `AGENTS-dts-validation.md`.

Runtime discovery must be dynamic — `hwprobe`-style ioctl plus
`/sys/devices/.../g6lcai/{tile_m,tile_n,tile_k,acc_banks}` — so the partitioner never hard-codes
geometry.

## 7. Licensing — the open path, terms left to the reader

**Decision recorded (AI-0, closed):** the AI plane rides the **normal open path**. Everything here is
tier **R** — `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` — exactly like the rest of the LibreCore
delta. **Nothing in this domain is blocked on a licensing decision.**

| Path | Tier | Outbound |
|---|---|---|
| `core/cvxif_g6lc_ai/**`, `core/g6lc_ai_*.sv`, `core/include/g6lc_ai_*.sv` | **R** | `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` |
| `corev_apu/ai_descriptor/**`, `corev_apu/ai_island/**`, `corev_apu/src/g6lc_ai_*.sv` | **R** | same |
| `core/include/g6lc64_ai_config_pkg.sv`, `corev_apu/include/g6lc_ai_island_cfg_pkg.sv`, `corev_apu/bootrom/ariane-ai.dts` | **R** | same |
| `verif/tests/custom/ai/**`, `verif/tests/testlist_ai_matrix.yaml` | **T** | `MIT` |
| this document | **T** | `MIT`, no inline header (`DOCS_UNDER_TIER`) |

**Terms are left to the reader in the LICENSE files, not pre-resolved per path.** An integrator takes
`CERN-OHL-S-2.0`. An operator who wants closed modifications for its own tape-out, marking relief on
fleet die, indemnity, patent assurance or support reads `LICENSE.GSys-Commercial` — whose **§3.7
addresses AI and datacentre in-house production by name**. Election is the licensee's; the repository
does not make it for them.

**Why the withheld-tier carve-out was drafted and then not adopted.** `CERN-OHL-S-2.0` reciprocity
triggers only on Conveyance (§1.13, §4), so an AI company that fabricates this card and deploys it
solely in its own datacentres owes no royalty and no source disclosure. Withholding the AI delta as
tier P case 2 was the one compulsory lever against that. It was rejected on three findings:

1. **The boundary is not clean.** The delta necessarily lands inside shared files that cannot be
   withheld: `core/csr_regfile.sv`, `core/decoder.sv`, `core/perf_counters.sv` (tier **R**) and
   `core/include/config_pkg.sv`, `core/include/build_config_pkg.sv`, `core/cva6.sv` (tier **U**,
   `Apache-2.0 WITH SHL-2.0`). Only leaf modules are separable, and contorting the RTL to change that
   is the `AGENTS.md` §0.3 module-boundary anti-pattern.
2. **It inverted its own rationale.** The stated moat was the descriptor engine, the verification
   collateral and the software stack — yet `verif/tests/custom/ai/**` and `software/**` are tier **T**
   (**MIT**). The carve-out withheld the easily reimplemented MAC array and gave away the
   hard-to-reproduce collateral.
3. **It bought a freeze, not a moat** — blocking all AI RTL behind an unanswerable strategic question.

Full reasoning: `AGENTS-licensing.md` → *Applied case: the AI matrix plane rides the open path*. The
commercial offer is undiminished: §3.7 was always a **scope** over the tier-R corpus, never a right
that depended on the carve-out.

**What survives from the rejected posture** — two rules that remain good practice:
- **Withhold the implementation, never the interface.** Config surface, packages, DTS and tests stay
  open under any future posture, so a tier-R-only integrator can always elaborate, discover and verify
  the seam.
- **Publication is the irreversible step, not creation.** Tier P case 2 stays defined in
  `.licensing-tiers` as an available mechanism classifying no path; `E-PWITHHELD` now guards conveyance
  and is dormant.

## 8. Phasing and acceptance

| Phase | Deliverable | Gate |
|---|---|---|
| **P0** | this scaffold + `isa-encoding.md` + `../uncore/pcie-endpoint.md` + licensing surface + todo rows | docs only, no flist |
| **P1** | option **B**: `AiMatrixEn`, T0/T1 `ai.mma.s8` + `ai.requant` behind `COPRO_G6LC_AI`; `g6lc64_ai` package; directed tests | **Landed** — `ai-matrix-veri` green on `work-ver-ai` |
| **P2** | PMU events, RVFI probes, DFT threading, accumulator `tc_sram` | **Mostly landed:** PMU group 4 + RVFI + acc `tc_sram` + **aiperm gate** + queue T0 stubs + `testmode_i` threaded to acc bank. Still open: MBIST macro bind, FO4 note |
| **P3** | T2 descriptor engine in `corev_apu/ai_island/` | **Spine + SoC MMIO + PLIC-8 + DMA + I1-lite GEMM.** AXI@`0x4000_0000` when `MatrixEn`. Suite includes `ai_gemm_s8_*` goldens. Full PE/`tc_sram` cluster still I1. |
| **P3** | T2 descriptor engine in `corev_apu/` + address-check + IRQ + `corev_apu/tb` model | formal ring safety + DMA-reject test |
| **P4** | option **D**: decouple `EnableAccelerator`, real first-pass decoder, resolve `cva6.sv:2216` | RVV compliance stays green |
| **P5** | PCIe EP + virtio + host driver + IPv6 plane + sshd on card | host enumeration on FPGA |
| **P6** | torch `PrivateUse1` backend, `/dev/g6lcai`, partitioner, `card-*` CLI | end-to-end INT8 serve over SSH |

**Island track (parallel, does not renumber P0–P6)** — full detail in `scaling-100tops.md` §11:

**SKU decision (closed): both, staged — latency SKU first, throughput SKU by cluster replication**
(`scaling-100tops.md` §5.1). The two SKUs share one cluster, one memory system, one capability window
and one software stack.

| # | Deliverable | Depends on |
|---|---|---|
| **I0** | TOPS definition, bandwidth model, plane split, staged SKU decision | — (done: `scaling-100tops.md`) |
| **I1** | **one** island cluster: PE array, `tc_sram` banks, sequencer, capability window. Freezes `T`, accumulator geometry, DRAM class and the NoC cut line **for both SKUs**. **Landed (partial):** `T` and `AI_LIVE_MACS` are 512, frozen until bytes/cycle rise; I3-lite bus + PMU + CPL FIFO; full PE/`tc_sram` density still open | P3 |
| **I3** | memory system. **Measured:** class 0 and class-1 N=1..8, fabric-bound at 8 bytes/cycle (80% floor closed on the 1 GHz accounting). Nameplate is 16 GB/s. **In RTL, define off:** second ingress at 512-bit island / 64-bit channel. **Remaining:** class 2. Not more MACs | I1 |
| — | **latency SKU tapes out** (1–2 clusters, ~12–25 TOPS) | I3, I4 |
| **I2** | NoC + N clusters + per-cluster gating + QoS arbitration (**after I3 measure**) | I3 |
| **I4** | floorplan, UPF domains, thermal cap loop, STA | I1, re-run after I2 |

**HARD map:** [`hard-tests.md`](hard-tests.md). **Host multi-phase:** [`frameworks-virt-pcie.md`](frameworks-virt-pcie.md) §2.1a.

**Ordering rule:** the bandwidth target is fixed *and measured* before the cluster count grows. This is
affordable because at `T = 512` the 100-TOPS SKU needs only ~195 GB/s, while the latency SKU must buy
~400 GB/s regardless for batch-1 weight streaming — **one memory system serves both**, so the staged
order builds the expensive subsystem first and makes the classic "MAC array ahead of the memory system"
failure structurally impossible.

Promotion checklist per `../README.md` and `AGENTS.md` §0.2: config-gated · synth-clean · timing-aware
· backend-friendly (`tc_sram` / `tc_clk_gating`) · verified · DFT · observable · ecosystem-safe ·
documented · philosophy-checked. Plus, for this domain: **licensing tier confirmed before first
commit**.

Verification surface to create alongside the RTL: `verif/tests/custom/ai/` with
`ai_setcfg_readback.S`, `ai_mma_s8_golden.S`, `ai_requant.S`, `ai_smt2_ownership.S`,
`ai_queue_doorbell.S`, `ai_illegal_when_off.S`; `testlist_ai_matrix.yaml` with the vector soft-skip
idiom so non-AI packages stay CI-safe; a bit-exact numerical reference (INT8 rounding mismatches are
the top silent model-accuracy bug).

## 9. Invariants and pitfalls

- **Never** add a matrix datapath inside `ex_stage`/`execute`. Attach at a sanctioned seam.
- Accumulator arrays go through `tc_sram`; gating through `tc_clk_gating`; the matrix block is one
  placement island with its own clock-gate and power region.
- Pipeline the MAC tree (≥3 stages for an 8×8×8 INT8 tile at server frequency); do not lengthen
  `ex_stage` combinational cones.
- **T2 DMA must be address-checked** (IOMMU stage or a device-side region-check unit programmed by
  S-mode). An unchecked DMA master reachable from a mapped doorbell page is privilege escalation from
  any user process. This lands with P3, not after.
- T2 completion ordering must be an explicit release/acquire contract documented beside `aiqctl`;
  RVWMO applies.
- Thread `test_en_i` / `testmode_i` through the matrix block and the descriptor engine; accumulator
  SRAMs need BIST hooks.
- Add a PMU event per feature (tile issues, accumulator conflict stalls, requant ops, queue occupancy,
  T2 stall-on-DRAM) — the PyTorch partitioner's cost model has no other input.
- Do not advertise `xg6lcai` in a DTS whose package has `AiMatrixEn=0`.
- Peak INT8 throughput will not match a GPU. The design is sold on control, irregularity and locality;
  if the partitioner is weak, workloads degrade to CPU-only and the premise fails.
- **Never quote a peak TOPS figure without the arithmetic intensity it is sustained at.** Batch-1 LLM
  decode needs ~1 TOPS against ~400 GB/s; saturating a 100-TOPS part needs a batch near 128
  (`scaling-100tops.md` §5). Sizing the MAC array for a workload the memory system cannot feed is the
  defining failure mode of this class of design.
- A T2 descriptor at island scale can own the engine for milliseconds. Bounded work quantum,
  restartability at a reduction boundary, per-queue priority and a watchdog are **security and QoS
  requirements**, not tuning (`isa-encoding.md` §7.1).
- Island telemetry belongs in the MMIO capability/counter window, not `core/perf_counters.sv` — the
  core PMU cannot observe an uncore device.
- **Island outputs are not coherent by position.** The island joins the fabric *below* the cluster
  (xbar `slave[2]` / the DRAM join), so its writes — C tiles, completion words, descriptor status —
  reach DRAM without passing the coherence hub, the L2/L3 or any WT L1. A line a core already
  holds is stale after the island wrote it. Two contracts exist, published at `CAP_OFF_COH` (0xA0)
  bit 0:
  - `AiCfg.DmaInvalEn = 1` (the canonical `AiCfgIsland` plane, `g6lc64_ai`): every completed
    island write is turned into an `inval` on the eWT CMO engine's writer port
    (`g6lc_ai_inval_queue` → `g6lc_cmo_engine` `NR_WRITERS`), i.e. the same L1-broadcast + L2/L3
    tag-clear path `cbo.inval` takes. The invalidation is issued only after the write's B (the
    data is in DRAM — an inval before landing would let a core re-fetch and re-cache the old
    line), one per touched 64 B line with same-line coalescing, and a job's `gemm_done` /
    `wr_done` are held until every line it wrote has been invalidated everywhere. So: **completion
    visible ⇒ no stale copy of that job's outputs anywhere in the hierarchy**, with no software
    maintenance. `ai_coh_stale` is the directed proof (read the line, run the job, re-read).
  - `AiCfg.DmaInvalEn = 0`: the Linux non-coherent-DMA model — software `cbo.inval`s the output
    range after completion (`ai_coh_stale_sw` is that arm; the ai-tensor UIO path must do it when
    the CAP bit is clear).
  Inputs are the other direction and already ordered: core writes are write-through at every
  level and `fence` waits for their B, which the L2 returns only from memory, so a descriptor or
  operand written before the doorbell is in DRAM when the island fetches it.
- **One ticket stream per island.** `ai.enq` tickets are allocated by the island
  (`SbTicketAlloc`, returned on `sb_enq_ticket_o` in the acceptance cycle) and every core's kick
  reaches it through the cluster's round-robin sideband arbiter (`g6lc_ai_enq_arb`). A per-core
  counter would make `ai.poll`'s retired watermark meaningless with two producers; a lone core
  counting its own accepted kicks proposes exactly the value the island allocates, which is why
  the single-core evidence is unchanged.

## 10. Frozen workload-policy codec compartment

**GSys LibreCore development scope:** `g6lc_ai_policy_codec` is an independently
verified control compartment, not a new accelerator datapath. RTL lives beside
T2 at `corev_apu/ai_island/`, not in a relocated `core/ai_island/`. Its gate is
`CVA6Cfg.AiCfg.PolicyCodecEn` in `core/include/config_pkg.sv`; `check_cfg` requires
`MatrixEn` and a nonzero queue count. All production packages default it off.
The compartment accepts the nested `AiCfg` parameter. Its dedicated verification
wrapper enables it; the production island top instantiates it as an
observable-only consumer with no downstream scheduling effect. Neither the
existing GEMM traversal nor the descriptor ABI changes.

### 10.1 Method: compile policy, do not train a profiler

Treat an operator walk as a small policy language. Offline reasoning groups
recurring matrix workloads into eight codewords; runtime encoding compresses
metadata into one of those words, and two combinational decoders expand the
committed word and its frozen successor into steering tuples. This is a
**hand-authored, frozen PGO hypothesis**, not a profile measured from a model,
a learned classifier, an adaptive transition matrix, or eight physical arrays.
No reward, weight, histogram or table is learned in RTL. Revision of the tables
is an offline source change with a fresh validation run.

The metadata contract is one accepted tile-work record per cycle:

- Unsigned 16-bit logical `m/n/k`; buckets are 0 for 0–1, 1 for 2–8, 2 for
  9–64, 3 for 65–65535. A separate nonzero-shape bit distinguishes empty work.
  Larger operators must be lowered into representable tiles before this seam.
- Three-bit opcode class: 0 dense, 1 attention, 2 routed, 3 convolution-derived
  matrix, 4 movement, 5 reduction, 6–7 unknown. These are **internal semantic
  tags**, not descriptor opcode numbers and not QoS priorities. The producer
  must lower and tag operators; a GEMM descriptor alone does not reveal attention
  or routed-expert semantics.
- Two-bit compute/movement balance: 0 movement-bound, 1 mixed, 2 compute-bound;
  3 is conservatively normalized to mixed. This is a producer-supplied estimate
  of reuse versus bytes moved, not a runtime divider or a cycle measurement.
- Eight INT8 sample bytes, with validity: a balanced zero-count tree reduces
  them to a single `>=6/8 zeros` residue. This is neither an exact sparsity map
  nor proof that an unsampled operand is zero.
- Shape continuity compares the three buckets with the previous accepted work
  in the same batch. Idle cycles are not observations.

The 14-bit packed feature signature is a **collision-free coarse feature hash**:
all classifier inputs are retained, rather than XOR-folded. Changed raw dimensions
within a bucket or residue noise below the threshold do not retrigger encoding.
`eval_o` marks new-signature encoding; repeated-signature confirmations reuse
its cached candidate without rerunning the classifier. This is evaluation
silence, not a claim of zero switching in the metadata logic.

Classifier precedence is invalid/unknown/move/reduction → movement;
explicit attention → attention; explicit routed → routed; short M with N/K at
least bucket 2 → decode; high residue with continuous, compute-bound M at least
bucket 2 → sparse; remaining movement-bound → movement; N bucket greater than M
→ wide; M greater than N → tall; otherwise bulk. Explicit routed tags cannot be
inferred merely from zeros. The residue may misclassify dense work; correctness
must not depend on classification accuracy.

### 10.2 Codebook and decompression

`include/g6lc_ai_policy_pkg.sv` is the source of the encoder, successor map and
17-bit `policy_t`. Tile dimensions below are preferred maxima, not claims that
the existing sequencer supports these traversals. Consumers must clamp each to
actual storage, shape, dtype and tail-mask constraints.

| Code | Consecutive-work class | Dataflow | Tile M×N×K | Residual check | Prefetch depth | Successor |
|---|---|---|---|---|---|---|
| 000 | bulk | reduction-stationary (0) | 64×64×64 | off | 2 | attention |
| 001 | wide | input-reuse (1) | 16×256×64 | off | 3 | bulk |
| 010 | tall | weight-reuse (2) | 256×16×64 | off | 2 | wide |
| 011 | decode | weight-reuse (2) | 1×128×256 | off | 1 | decode |
| 100 | attention | reduction-stationary (0) | 32×32×64 | off | 2 | wide |
| 101 | routed | weight-reuse (2) | 8×32×128 | off | 1 | decode |
| 110 | sparse candidate | input-reuse (1) | 32×64×128 | exact-zero only | 1 | wide |
| 111 | movement | movement (3) | 8×64×8 | off | 3 | bulk |

The descriptor here is **only an internal three-bit policy word**, never bits
stolen from Desc64, `flags.prio`, `numfmt`, `aicfg`, or an ISA encoding. Tuple
packing is `{dataflow[1:0], m_log2[3:0], n_log2[3:0], k_log2[3:0],
sparse_check, prefetch_depth[1:0]}`. Both decode paths are case tables, not SRAM.

### 10.3 Commit, silence, speculation and ownership

`valid_i && ready_o` accepts a record; code, tuple, work-valid and event strobes
are available after that edge. There is no downstream backpressure in this
control compartment. A consumer with stalls must buffer/align the record and
its policy, or only present work when it can consume the following cycle.

The first accepted record after reset, flush, disable, batch-last, or an explicit
batch-first commits immediately. Thereafter a changed class needs **three
consecutive accepted votes** (`HoldWork`) and **four accepted records since the
previous commit** (`DwellWork`). Counters saturate and count work, not clocks.
Returning to the incumbent clears votes; changing challenger restarts them.
Repeated identical signatures still advance votes. Thus no class gains historical
credit over another, short noise bursts do not take over, and a sustained fitting
challenger is not silenced indefinitely. This is policy stability/equal treatment,
**not inter-queue scheduling fairness**. A genuine prefill→decode phase change can
commit within a batch; the code is not locked until batch completion.

The second decoder uses a frozen **repeat-or-successor** rule: predict the
committed word itself when bucketed shape continuity holds and the raw candidate
agrees with that word; otherwise use the successor column above. This distinction
is essential: operator walks describe transitions between operators, whereas most
next-tile hints belong to repeated tiles inside an operator. Both paths are
constant policy, not learned transition frequencies. The selected next word is
registered on accepted work, even when hint issue is suppressed; idle holds it.
`next_addr_i` is a **caller-supplied next-tile address hint**, accompanied by
validity; the codec cannot infer a future tensor pointer from a shape. It latches
that address and its bank bits `[6 +: BankBits]`, assuming 64-byte interleaving
for this hint interface. It issues no bus request, claims no permission check,
and never uses a prediction to select architectural data. Downstream must redo
address/length/permission and physical bank-map checks before use. Batch-last
suppresses new hints. First/last flags have no effect without accepted work;
flush and runtime disable synchronously invalidate all policy/prediction state.
One instance serves one ownership context: the integrator must flush on a
queue/tenant switch or provide separate instances. There is no implicit global
cross-tenant history and no unbounded context table.

An issued hint is compared with the **next raw candidate**, not the hysteretic
committed code. Prediction misses, or `mispredict_i` on that resolution, cancel
new hints on that record and the next two accepted records (`CooldownWork`).
The map does not learn. Idle gaps neither consume the cooldown nor resolve a
prediction. Hit/miss pulses count only hints actually issued. Forced batch
boundaries discard the previous prediction without scoring it.

`policy.sparse_check` only requests an exact residual-zero check. Actual
`residual_skip_o` additionally requires `exact_zero_i` for that accepted,
nonempty residual block. That proof must come from the numeric consumer; a
sample or a sparse code alone can never drop a MAC. This compartment's numeric
contract is INT8 integer zero, not floating-point zero/NaN semantics or a new
structured-sparse format grant.

### 10.4 Feedback ladder and remaining integration gates

Runner: `verif/regress/ai-policy-codec.py` (or registered suite
`test ai-policy-codec`) dispatches through the remote testharness proxy, uploading
only the compartment sources. `tb_g6lc_ai_policy.sv` and `policy_main.cpp` exercise
purity/silence, all-class walks, noisy false sparsity, routed/dense bursts,
injected prediction tax, mixed prefill/sticky-decode batches, boundaries,
config-off and numerical reference consumption. Record evaluation/commit counts,
class occupancy, fit rate, actual hint hit/miss denominator, and cost sensitivity
including mispredict tax. Distinguish exact-code agreement from compatible-policy
fit: neither is a measured speedup. Parameter extremes and randomized boundary
traffic must be tested alongside representative operator walks.

The separate shape-derived synthetic walks lower assumed 128/256×4096×4096
prefill, 1/4-row decode and 11008-wide projections, explicitly tagged experts,
and 320/1280-channel diffusion-style matrices into <=256-axis records, including
ragged tails. Seeded INT8 patches supply noisy residues; unmaterialized full
operands never claim `exact_zero`. Reports conserve useful MACs and distinguish
resident-C traffic from worst-case K-partial spill traffic. These walks are held
out from table tuning in this pass: their fit is reported, not forced to pass an
accuracy threshold. They are **assumed shapes, not captured model traces**.

Next: collect ordered real-model matrix metadata and
bytes moved from the host ML lowering layer; freeze a calibration/held-out split,
compare dense baseline versus codec at equal memory bandwidth and arithmetic,
and revise the offline tables only against the calibration split. Then bind
supported tuple fields to the real sequencer one at a time, preserve dense
fallback/tail masks, and run remote HARD GEMM numerical/AXI regressions. Do not
advertise unsupported dataflows or skip formats through CAP.

A Hugging Face model under QEMU can witness lowering and end-to-end functional
behavior via the existing `g6lc_qemu` / `ai-tensor` bridge. Stock QEMU wall time
is **not** island MAC/s; neither the codec nor its penalties currently exist in
that emulator. Obtain ordered traces there or on the host, then replay on RTL
with a validated memory model before quoting throughput. No model weights are
needed for the synthetic development gate.

Timing/review note: the new cone is metadata reduction → small classifier →
short vote/dwell comparators → registered three-bit code, with combinational
current/successor policy decode. It is wholly outside issue/commit and the MAC
reduction path. The island target remains 1 GHz; no STA closure is asserted.
State is bounded flip-flops, no memory macro, new clock, CDC or latch; reset is
async-low. `testmode_i` bypasses only the explicit register-update enable, not
acceptance or policy qualification: `state_d` retains state when no work or
invalidation is present, so testmode must not manufacture functional updates.
Randomized testmode and unconstrained bounded checks exercise that transparency.
This is **not a scan chain or an ATPG result**; scan-flop substitution and scan
shift/capture control remain backend work. No clock-gating cell is instantiated
because no clock is gated. Feature-signature silence and bounded cooldown reduce
needless updates but do not establish a power number. Place the block beside the tile scheduler, not across the array.
PMU/trace event outputs are exposed (`eval`, `commit`, `hold`, prediction hit/miss)
and wired to the island MMIO PMU words at `0x0190..0x019C` as an observable-only
consumer. The first consumer does not drive GEMM traversal, prefetch, address/bank
hints or residual sparse-skip; those remain promotion gates. Core RVFI/debug and
`.dts`/ISA/Desc64 remain unchanged because the production datapath is untouched.
Synthesis, unbounded formal/coverage closure, physical scan, real consumer wiring
and measured area/power/timing remain promotion gates, not inferred from a
synthetic score. The existing open tier-R licence applies; verification tooling
is tier T. `config_pkg.sv` retains its upstream notices; no licensing tier,
security policy or compliance control was weakened.

### 10.5 Reproducible checks and feedback record

```text
bun build-platform/src/cli/index.ts test ai-policy-codec
wsl --exec python3 /mnt/e/cva6/verif/regress/ai-policy-codec.py --seed 123 --parameters default
python verif/regress/ai-policy-codec.py --synth-only --yosys <existing-yosys-executable>
wsl --exec bash /mnt/e/cva6/verif/regress/ai-island-dma.sh
```

The first command uses the configured WSL regression engine and remote proxy;
no source-tree sync/deletion is needed. The last is explicitly local Yosys only,
not local Verilator. Each run preserves source hashes, logs and results under a
unique output directory. Local synthesis snapshots the SV inputs inside
`build-platform/workspace/build/`; remote evidence is pulled to `remote-runs/`.
Neither command downloads a compiler, solver, framework or model.

**2026-09-04 development result (UTC tags on September 5):** default seed
`0x6c706f6c696379`, remote tag
`ai-policy-codec-20260905T002332Z-30230059f41a`: lint + assertion-enabled Verilator
5.008 simulation pass. Default control suite includes 16,384 metadata cases,
30,000 randomized cycles, numerical tuple-consumer checks, and 27,278 additional
shape-derived records; minimum (1/1/0/1) and maximum (15/15/15/8)
Hold/Dwell/Cooldown/BankBits variants also pass directed + randomized checks.
The wrapper uses the actual `g6lc64_ai` nested config with only the codec gate
raised, and genuine `AiCfgOff` for disabled testing. A second-seed run (`123`),
`ai-policy-codec-20260905T002520Z-394c13c409b1`, also passes the full default
scoreboard and shape walks. Local synthesis/formal artifacts are pinned under
`build-platform/workspace/build/ai-policy-codec-20260905T002514Z-9406d2244cf3/`.

A live island DMA smoke, `verif/regress/ai-island-dma.sh`, now fetches a v2 GEMM
descriptor from an AXI stub memory into `g6lc_ai_island_top` with `EnableDmaFetch=1`,
explicitly enables `AiCfg.PolicyCodecEn` in a test-local `ai_cfg_t`, and verifies
that the sticky policy PMU words at `0x0190..0x019C` are non-zero after a
successful `ST_OK` completion. It runs in ~170 cycles under Verilator 5.008 and
leaves dense GEMM traversal, prefetch, address/bank hints and residual sparse-skip
unconnected; those are still promotion gates.

| Assumed shape-derived walk | Committed/raw code agreement | Issued-hint accuracy | Re-encode rate |
|---|---|---|---|
| Dense prefill | 91.80% | 94.57% | 10.58% |
| Dense decode | 99.87% | 99.91% | 10.97% |
| Routed experts | 99.36% | 97.73% | 12.61% |
| Diffusion-derived, ragged | 80.36% | 75.65% | 44.64% |

These are **synthetic metadata outcomes**, not optimal-policy accuracy or MAC/s.
The ragged diffusion result is a real limitation: silence and successor quality
are weaker on changing tails. The adversarial all-class walk has 25% committed
agreement and zero successful hints; bounded cooldown limits, but does not erase,
its penalty. Do not hide these cases behind the high regular-fixture scores.

The first frozen operator-only successor table was falsified by the purity test:
2,000 bulk records produced 0 hits / 500 misses. The repeat-aware rule was first
made a failing regression, then added to RTL; the same fixture now gives
1,995 hits / 1 miss. Regular phase fixtures reach 98.47–100% committed agreement
and 99.14–100% hint accuracy. Independent transition-tax × misprediction-tax
sweeps include scenarios where policy overhead loses to the static baseline.
The score's base/wrong-code costs and hit credit are declared assumptions, not
measurements used to choose an optimum.

Local Yosys 0.67+92 (`--synth-only`) passes enabled/disabled generic synthesis:
**626 cells, 113 sequential cells, zero latches** when enabled; **zero cells**
when disabled. The 12-step SAT check retains 12 assertions and finds independent
reachability witnesses for work, commit, hold, warm, exact-zero skip, hit and
miss. Its initial sampled reset and `async2sync` clock-step model are explicit;
it is bounded safety, not an induction, async-reset sign-off or PDK STA proof.

Broader status: build-platform typecheck and 12 focused config/AI tests pass.
The whole Bun suite reports 135 pass / 1 skip / 1 unrelated branding failure
(`g6lc_core_types.svh` is a macro header, not a matching module/package).
`verify --synth --target g6lc64_ai` still fails on 11 unrelated full-core
range-select/declaration-order errors in ALU/issue/commit paths. The full
lint/formal/sim/synth invocation was inspected in **dry-run only** to avoid
violating proxy-only simulation; it is not a green compliance result. Remote
synthesis is explicitly skipped when that host has no Yosys; the local isolated
result above is separate evidence. No production-array speed test or
Hugging Face/QEMU model benchmark has been performed.

## 11. Format-aware benefit steering and equal-resource efficiency

This extends the §10 compartment, not the production GEMM array. The additional
`AiCfg.PolicyBenefitEn` gate requires `PolicyCodecEn`; both remain **off** in
production. `g6lc_ai_policy_steer.sv` wraps the original encoder without changing
its eight codewords or the Desc64 ABI. Format, dimensions and balance are retained
alongside the code, and a combinational topology decoder considers expected
benefit before applying a multi-input/multi-output grouping.

### 11.1 What the virtual-resource abstraction means

A topology is `(parallel rows, parallel columns, reduction lanes)`, encoded as
power-of-two exponents. Each A value can feed several columns; each B value can
feed several rows. This is a digital broadcast/reduction connectivity model,
**not an analog transistor, a physical transistor count, or additional arrays**.
For each format the invariant is:

```text
parallel_rows * parallel_columns * reduction_lanes == format_service_slots
```

The fixed-dot baseline has one row, one column and all slots along K. A selected
topology redistributes the same slots; it does not get extra MACs, read ports,
external bandwidth or accumulator storage. Preferred row/column exponent caps
for codes 0–7 are `(2,2), (1,3), (3,1), (0,4), (2,2), (1,2), (2,2), (0,0)`.
The decoder reduces these caps until the actual dimensions divide exactly, so
output-lane padding cannot manufacture an apparent utilization improvement.
It also constructs a balanced alternative using the power-of-two divisors of M
and N: at most 16 output lanes, split as evenly between rows and columns as the
shape permits. It chooses this alternative only for greater anticipated input
reuse, or equal reuse with more useful parallel outputs. The K exponent receives
the remaining slot budget. The chosen group still uses exactly the same slots.

The default **assumed service profile** is 512 slots for INT4, 256 for INT8 and
either FP8, 128 for FP16/BF16, and 64 for FP32. `FormatSlotsLog2` parameterizes
these rates; they are neither achieved clocks nor a statement that floating-point
exponent/rounding hardware has the same area as integer MACs. Cross-format area
and latency equivalence require actual datapath synthesis. Current production
`AiIslandPeImplMask` still implements only INT4/INT8.

### 11.2 Format and numerical safety contract

The wrapper uses existing `config_pkg::AI_FMT_*` identifiers: INT8=0, INT4=1,
FP8 E4M3=3, FP8 E5M2=4, FP16=5, BF16=6, FP32=7. Structured 2:4 format 2 has no
resource/metadata layout here and is rejected by `topology.valid=0`. A known
format is **not an execution grant**. The production descriptor engine must still
check its actual capability mask; no mask, ISA, CSR, DTS or opcode is expanded.
In particular, fallback preserves `numfmt` and uses its fixed-dot geometry;
it must never reinterpret a floating-point request as INT8.

A 256-bit sample input carries eight tightly packed native elements, starting
at the least-significant bit. INT4 therefore uses 32 bits, INT8/FP8 64, the
16-bit formats 128, and FP32 256. The wrapper converts them into eight zero or
nonzero proxy bytes for the existing encoder. Both floating zero signs count as
zero metadata; subnormals, infinities and NaNs do not. Upper unused sample bits
must have no effect. Every accepted format change starts a new policy epoch;
idle input changes do not change state. This prevents another format's votes,
shape history or outstanding prediction from affecting the next format.

Floating-point residual skipping is **disabled even when `exact_zero_i` is set**.
A zero multiplicand does not establish `0 * Inf`, NaN propagation, flags or the
sign of a zero accumulation. Integer zero authorization remains unchanged.
The topology does not truncate operands, quantize, enable flush-to-zero, or grant
reassociation. Here, “approximation topology” means approximating the benefit of
a scheduling choice. A future arithmetic implementation must preserve its
numeric contract, including reduction order, or define and validate a separate
explicit numerical-approximation contract before accepting that topology.

### 11.3 Runtime anticipation without a learned profiler

`policy_topology` uses only code, format, dimension alignment, movement balance
and the configured SRAM read budget. Its `gain_16ths` is the floored expected
reduction in **input-read demand** from broadcast, in sixteenths:

```text
gain_16ths = floor(16 * (2*R*C - R - C) / (2*R*C))
```

It is not an estimate of whole-model percentage speedup. The gate requires more
than one output, a non-movement class, at least one M/N dimension of eight, the
configured minimum gain (default 2/16), and either an underfilled baseline K vector
or SRAM read pressure above `ReadBytesPerCycle` (default 128). Movement-bound
balance normally vetoes selection. The refined **decode exception** admits that
balance when the baseline K vector is underfilled or the whole-tile baseline
operand-read demand `(M+N)*rowbytes(active_K)` is at least the SRAM service rate.
Thus a bandwidth-heavy decoder is not assumed incapable of benefiting from local
reuse; the measured whole-tile gain still includes the same external traffic on
both paths. The pressure comparison uses independently byte-rounded native rows,
including odd INT4 K: for example K=511 occupies 256 bytes per row, so
`(1+128)*256` bytes for a 1×128 tile, not `2*256`. A directed boundary test pins
that distinction.
All arithmetic is small masks, shifts, comparisons and fixed-code tables; there
is no runtime search across operators, table training, float arithmetic or
full-matrix cost multiplication. A rejected topology is the same-format baseline.
A useful state is allowed to persist through the existing hysteresis; code usage
is measured, not forced to artificial equal shares.

The wrapper retains full 16-bit `m/n/k` topology metadata (the classifier still
sees raw dimensions). K is only clipped to the active service slot when computing
`active_K`; the retained value keeps the full dimension for the resource model.
A separate full-metadata formal expression and 14,560 boundary cases per steering
build check equivalence. Widening the metadata or service bounds is a parameter
change, not a decoder redesign.

### 11.4 What a verified percentage must compare

The new efficiency test compares **the same shapes in the same format** with
identical service budgets. Comparing FP32 against INT8, giving one path extra
ports, or charging a made-up wrong-class penalty would not measure this feature.
The earlier §10 `100/30` score remains a historical sensitivity experiment and
must not be cited as an efficiency gain.

The timed SystemVerilog resource consumer is a **scheduling model, not the PE**.
For each independent work tile it transfers M A rows and N B rows, then reads and
writes each 32-bit C element once. Native row-byte rounding is used, including
odd INT4 K tails. External service is 8 bytes/cycle in the default profile. Each
compute group consumes `(active_rows + active_columns) * row_bytes(active_K)`
SRAM bytes at the common read rate, with a minimum of one service cycle. It
counts useful products and traffic, rather than awarding policy-label credits.
Both paths assume 16 available partial-accumulator slots and sufficient local
updates for the at-most-16 outputs; no accumulator bank conflict is charged.
SRAM read service is aggregate, conflict-free and coalesced; real bank mapping,
queue arbitration, float pipeline/rounding latency and routing contention are
not modeled. These assumptions must hold before translating a scheduling result
into an implementation estimate. There is no speculative-prefetch credit and no
assumed DMA/compute overlap. The codec path additionally pays one decision cycle
per work record; software batch boundaries delimit logical operators in this
performance trace, not a whole inference session. External service is charged
in an aggregate accounting phase; the consumer emits no AXI transactions and
does not prove read/compute/write ordering.

A separately derived C++ cost calculation is checked against the ticking RTL
consumer on bounded fixtures. Larger assumed model walks use that checked
calculation, not billions of unreported cycle-exact PE operations. Reports must
label this distinction, including for INT4/INT8: the new multi-output PE is not
implemented for those formats either.

For every workload/format and every used code, report both
`100*(1-refined_cycles/baseline_cycles)` time reduction and
`100*(baseline_cycles/refined_cycles-1)` throughput increase. Keep negative and
zero outcomes. Also report applied-record share, cycle/MAC share, utilization,
unsupported formats, best-static affinity and per-tile-oracle gaps. A balanced
summary weights each of the four workload families and seven supported formats
equally after normalizing by its own baseline; raw trace length must not let
prefill or INT4 dominate the blend. A wider-SRAM sensitivity profile must show
how much of a gain depends on the hypothesized read-port pressure.

Timing/silicon review: the wrapper's native-sample normalization precedes the
existing encoder; topology decode starts from registered code and metadata and
stays outside the core issue/commit path. No clocks, latches, memories or physical
MAC arrays are added. Synthesis must measure the extra control cost, while actual
array fanout, accumulator ports, floating-point reduction/rounding, timing,
DFT/ATPG and PMU integration remain separate promotion gates. A good scheduling
percentage alone does not close any of those gates.

### 11.5 Measured development results and limits

**All percentages below are from the validated scheduling model, not production
MAC/s.** Default seed `0x6c706f6c696379`; remote run
`ai-policy-codec-20260905T013624Z-e5b3ada7aef5`, artifact directory
`output/policy-results-uucvt8s9/`. Each steering profile contains `simulation.log`
and machine-readable `efficiency.json`; `results.json` records source hashes and
tool/test status. The timing equations were checked against **380 ticking RTL
fixtures per build**. The full replay covers **190,946 work records** across four
assumed workload families and seven formats. Native samples, format changes,
invalid profiles and 14,560 metadata-boundary cases per build are checked too.

Default profile: 128 B/cycle SRAM reads, 8 B/cycle external service, fixed
same-format slot budgets and one extra codec decision cycle per work record.
Positive entries mean **less modeled time** than the one-output fixed-dot
baseline; they do not compare one number format against another.

| Format | Prefill time saved | Decode time saved | Routed-expert time saved | Diffusion-like time saved |
|---|---:|---:|---:|---:|
| INT8 | 56.69% | 11.03% | 28.88% | 52.09% |
| INT4 | 47.68% | 10.53% | 24.68% | 44.75% |
| FP8 E4M3 | 56.69% | 11.03% | 28.88% | 52.09% |
| FP8 E5M2 | 56.69% | 11.03% | 28.88% | 52.09% |
| FP16 | 62.61% | 11.30% | 31.36% | 58.27% |
| BF16 | 62.61% | 11.30% | 31.36% | 58.27% |
| FP32 | 66.05% | 11.44% | 30.58% | 61.96% |

Per-code accounting below pools the 190,946 records; this is **not** the
equal-weight family/format blend. “Record share” is the committed code's share
of all records; “applied” is the fraction within that code that actually enables
multi-output grouping. Cycle and useful-MAC shares are also in the JSON.

| Code / class | Record share | Applied within class | Modeled time saved | Modeled throughput increase |
|---|---:|---:|---:|---:|
| 0 bulk | 41.43% | 99.82% | 60.43% | 152.69% |
| 1 wide | 3.35% | 100.00% | 15.37% | 18.16% |
| 2 tall | 0.96% | 100.00% | 59.28% | 145.60% |
| 3 decode | 35.84% | 100.00% | 11.09% | 12.47% |
| 4 attention | 0.11% | 41.90% | 53.61% | 115.55% |
| 5 routed | 9.74% | 82.62% | 30.45% | 43.79% |
| 6 sparse candidate | 8.17% | 100.00% | 61.18% | 157.63% |
| 7 movement/fallback | 0.40% | 0.00% | -0.00118% | -0.00118% |

No sparsity speed credit is taken: every performance record sets exact-zero
proof false and conserves useful MAC count. The sparse-class gain above is
broadcast grouping, **not dropped arithmetic**. No target percentage of code
usage is enforced; low-usage classes remain visible rather than being inflated.

Equal-weight 4-family × 7-format normalization gives **38.24% modeled time
reduction / 61.93% normalized throughput increase**. This is an explicit
benchmark mix, not a claim of equal real-world demand or a 50/50 LLM/image split.
Increasing SRAM service to 512 B/cycle reduces those figures to **3.56% / 3.69%**.
Most INT8/FP8/16-bit/FP32 dense cases then have approximately zero benefit and
small decision-overhead regressions; INT4 retains useful lane-fill gains. Thus
port pressure is a hypothesis that materially determines the answer.

**Do not attribute the entire gain to eight-state adaptation.** The best
retrospectively chosen **fixed code with the same shape-aware topology decoder**
is code 3 here. Its normalized time is 0.616153 versus 0.617565 for the dynamic
codec: dynamic is still about **0.23% slower**. At 512 B/cycle it is about 0.067%
slower. These comparisons include the codec's decision cycle but give the static
comparator zero decision cost: they are comparisons to an untaxed diagnostic
lower bound. The report also charges **both paths one decision cycle per record**;
dynamic is still 0.225% slower at 128 B/cycle and 0.064% slower at 512 B/cycle.
The current evidence therefore supports the balanced allocator and format-aware
reuse gate much more strongly than extra classifier sophistication.
Future dataflow, prefetch and exact sparse consumers must justify their
incremental cost against this stronger fixed-code baseline, not only fixed-dot.

The first benefit implementation vetoed nearly all movement-bound decode work:
INT8 decode regressed by 0.00926%, with no grouping applied. Test-first refinement
of the decode exception and balanced alternative raised it to **11.03% time
saved**. The balanced mix improved from 34.69% to 38.24% time saved. Those changes
were evaluated on the development fixtures; further seeds/families are checks,
not evidence of a captured-model calibration/held-out split. Final second-seed
run `123` (`ai-policy-codec-20260905T013623Z-50c820a701f5`) also passes, over
185,122 records: normalized time reductions are 35.67% and 3.54% at 128 and
512 B/cycle respectively. A later local steering run with the full 16-bit `m/n/k`
retention and the `(m+n)*rowbytes(active_K) >= read_bytes` gate passes over
190,946 records, giving 38.24% and 3.56% signed time reduction at 128 and
512 B/cycle (artifacts `build-platform/workspace/build/ai-policy-efficiency-final`
and `ai-policy-efficiency-final-512`). SP24 is checked by the complete reference
scoreboard, including opcode/sample-change silence, rather than exempted from code
checks.

Local Yosys 0.67+92 artifacts:
`build-platform/workspace/build/ai-policy-codec-20260905T134537Z-865a53bca276/`.
The codec wrapper (`tb_g6lc_ai_policy`) synthesizes to **626 generic cells,
113 sequential cells, zero latches**; the enabled steering wrapper
(`tb_g6lc_ai_policy_steer_on`) synthesizes to **1,222 generic cells,
167 sequential cells, zero latches**; disabled wrappers have zero cells. Metadata
compression alone reduced 1,274 / 167 to 1,211 / 139, removing **28 state bits**
without changing topology results; exact INT4 row rounding adds two generic
cells. The original codec remains 626 / 113.
A 12-step bounded proof passes **26 steering assertions**, including exact
agreement with a full-metadata topology expression, plus the original 12 codec
assertions; reachable witnesses include applied topology. These are bounded
safety/equivalence checks, not inductive liveness, PDK area/timing or ATPG.

Next gates: materialize the shared-array input broadcast and partial-accumulator
resources, preserve numeric ordering/rounding or specify an explicit error budget,
then replay captured model work against the real memory/PE pipeline. Do not
increase FP grants, claim silicon speed, or remove the fixed-code comparator on
the strength of this model. The broader full-core synthesis gate still has the
unrelated errors recorded in §10.5.

### 11.6 Per-group 3-bit subcode evaluator

`g6lc_ai_policy_subcode` adds an optional advisory search behind
`AiCfg.PolicySubcodeEn` (requires benefit steering; all production gates remain
off). The frozen primary 3-bit policy is unchanged. A separate 3-bit candidate
index is interpreted within bulk, decode, routed or sparse-candidate groups;
other classes return the existing topology without evaluation.

| Subcode | Candidate output grouping R x C |
|---|---|
| 0 | Existing format-aware topology, retained on ties |
| 1 | Same-format single-output baseline |
| 2 | 1 x 16 |
| 3 | 2 x 8 |
| 4 | 4 x 4 |
| 5 | 8 x 2 |
| 6 | 16 x 1 |
| 7 | Group parameter: defaults bulk 2 x 4, decode 1 x 8, routed 1 x 4, sparse 4 x 2 |

The last candidate is encoded in four six-bit `GroupShapeLog2` entries (low
entry bulk, then decode, routed, sparse; row log in bits 5:3, column log in 2:0).
`FormatStepCycles` supplies a four-bit minimum service interval per format;
`FormatMinReductionLog2` bounds the reduction width of alternatives. These are
compile-time service hypotheses, not trained or measured format capacities.
At runtime, exact retained shape and native row packing select the best legal
candidate. Slots are conserved: `R*C*D = 2**slots_log2`, with at most 16 outputs.
This increment accepts evaluation dimensions 1..256; larger shapes, unknown
formats and malformed baseline geometry return an unevaluated fallback.
M/N must divide the candidate grouping exactly; K tails use byte-rounded rows,
including odd INT4 K. No sparse arithmetic credit or floating reassociation is
introduced. A sparse candidate uses the same dense cost accounting.

Evaluation serializes eight candidates through PREP, SERVICE, TOTAL and COMPARE:
32 cycles after the standalone input handshake. Native read service and
format minimum issue interval determine full and partial K-step cost; registered
products then form the tile compute-service estimate. External traffic is
identical across candidates and is added separately in performance reports.
An alternative is selected only when its compute cost plus all 32 evaluation
cycles, `SwitchCycles` (default 2), and `MinSavingsCycles` (default 2) is strictly
less than the existing allocator's compute cost. Fallback still pays evaluation
cost; the tests must report that regression rather than erase it.

The steering integration is a cancellable shadow evaluator: primary ready/work,
code, topology and residual/hint semantics remain unchanged. A newly accepted
record cancels any older subcode search or held result; the most recent record
is evaluated once its primary policy is available. Full-rate input can therefore
starve shadow evaluation. The standalone ready/busy/valid interface is the seam
for a future backpressured consumer. Subcode results and costs have separate
observation ports, not new MMIO or descriptor bits. The island leaves those
ports unused: **this is implemented selection RTL, not a multi-output PE or a
live GEMM speedup**. Existing PMU topology words still describe the primary path.

Timing/review: candidate construction and three arithmetic/comparison stages are
separated by registers, outside core issue/commit and AXI address generation.
The new cost multipliers, variable shifts and metadata fanout need synthesis and
PDK timing review; no GHz claim follows from cycle counts. No new clock/reset,
latch, memory macro, permission path or numerical datapath is added. State uses
the existing active-low reset and testmode convention; flush/disable clears all
retained state. ISA/DTS/format grants are unchanged. Actual broadcast wiring,
accumulator banks, pipeline drain, real-model calibration, STA and DFT remain
promotion gates. `ai-policy-subcode` owns the scoped scoreboard and matched
MAC/cycle evaluation; synthetic fixtures are not captured model inference.

Verification (2026-09-06): remote artifact
`ai-policy-subcode-20260906T120534Z-59ac4379a07d/output/policy-subcode-results-6ekram31`
passes five parameter profiles, each with 13,574 standalone cases and actual
steering-output equivalence (1,172 accepts, 444 results, 712 cancellations).
The independent 64-bit reference walks K fragments rather than copying the
RTL closed-form cost. Maximum geometry, all format slot budgets, strict margin
boundaries, idle mutation and cancellation at every search age are exercised.
Arithmetic bounds for legal candidates are at most 17,408 service cycles per
group and 251,658,240 compute cycles per tile (256 cubed times the maximum
15-cycle service interval), fitting the 15-bit service and 28-bit cost state.
Local artifact `ai-policy-subcode-synth-20260906T115809Z-e9b58abe2d73`
reports 4,881 generic cells / 340 sequential cells / zero latches, disabled zero,
and four control assertions through 36 steps with reachable completion. That
proof fixes INT4 16x16x17 geometry and leaves controls arbitrary; it is not a
full arithmetic or steering-integration formal proof.

**Performance counterevidence:** all 105 named handcrafted tile fixtures retain
subcode 0 at both 128 and 512 B/cycle; the existing allocator already wins among
these candidates. With the 32-cycle search charged, throughput deltas across
formats are negative:

| Tile fixture family | Read128 MAC/cycle change | Read512 MAC/cycle change |
|---|---:|---:|
| Prefill | -0.052056% to -0.014289% | -0.052056% to -0.014289% |
| Decode | -0.811839% to -0.114361% | -0.834420% to -0.117958% |
| Routed experts | -0.155885% to -0.026876% | -0.226501% to -0.047079% |
| Diffusion matrices | -0.049739% to -0.014185% | -0.052877% to -0.017801% |

Randomized geometry diagnostics do exercise profitable alternatives, including
single-output and group-specific candidates in parameter tests, but are not a
real-model workload distribution. Reports keep those diagnostics separate from
`workload_fixtures`. Do not add these results to the earlier fixed-dot savings:
this experiment compares incrementally against the existing allocator and does
not establish further workload speedup. Keep the gate off; calibration should
next test bank/port costs and amortization opportunities before adding consumers.

### 11.7 Codec-first feedback methodology

The primary runtime path remains metadata encode -> registered 3-bit code ->
two combinational policy decodes, not the multi-cycle subcode search. Single-cycle
accepted metadata contains shape buckets, semantic opcode, eight-element sparse
residue, shape continuity and balance. The exact coarse-feature signature avoids
hash collisions; unchanged signatures silence the encoder while accepted-work
votes still advance hysteresis. Defaults HoldWork=3, DwellWork=4 and CooldownWork=2
are frozen hypotheses, not learned frequencies. Strategy equity means uniform
hold/dwell rules for consecutive fitting classes, not equal quotas or a guarantee
of accurate predictions on deliberately alternating classes.

The primary and repeat-or-successor decoders produce advisory geometry, dataflow,
sparse-check and prefetch tuples. Successor hints use a caller-supplied address;
they cannot infer a pointer, grant permission or issue speculative memory traffic
by themselves. Integer residual skip additionally requires exact proof; sample
zeros alone never authorize dropped arithmetic. Format epochs, flush and disabled
operation preserve context boundaries. No named accelerator algorithm is assumed.

Feedback has separate axes: classification/prediction accuracy, modeled useful
MAC/cycle, and measured memory/PE cycles. The runner's `performance_feedback`
section now explicitly reports `NOT_QUALIFIED`, equal family/format normalized
costs and a no-regression/strict-improvement model screen. Positive, tie, regression
and invalid-count controls test this reporting boundary. Even a passing synthetic
screen cannot assert held-out captures, a live PE consumer or physical timing.
No result automatically changes a production gate or fits a runtime table.

Fresh seed-123 remote control run
`ai-policy-codec-20260906T121255Z-2a22cc633240` passes default/minimum/maximum
hold/dwell/cooldown/bank parameters, directed false-sparse and class walks,
16,384 metadata combinations, 30,000 random cycles and 26,446 shape-derived
records. Selected default-profile observations (control metrics, not speed):

| Scenario | Re-encode rate | Committed/raw agreement | Resolved-hint accuracy |
|---|---:|---:|---:|
| Pure bulk | 0.10% | 100.00% | 99.95% |
| Sticky decode | 0.10% | 100.00% | 100.00% |
| Mixed prefill/decode | 1.12% | 98.66% | 99.27% |
| Routed experts | 1.36% | 98.75% | 99.30% |
| Decode with injected misses | 0.10% | 100.00% | 87.57% |
| Adversarial all-class alternation | 100.00% | 25.00% | 0.00% |
| Ragged shape-derived diffusion | 46.24% | 78.97% | 72.60% |

The poor adversarial/ragged cases remain visible. Historical arbitrary
transition/mispredict cost units are sensitivity tests, not MAC/s estimates.
Next real-world validation must capture framework operator order, native formats,
actual routing and source/model revision, lower into legal tiles, and hold out
models before fitting parameters. A Hugging Face model executed in QEMU can
validate descriptor/grant/numerical behavior and produce replay metadata; QEMU
wall-clock token/s measures that emulator/software setup, not island MAC/s.
RTL replay supplies bus/PE-cycle evidence, and multiplying MAC/cycle by a stated
clock remains a projection until timing is established. No captured-model or
Hugging Face/QEMU inference benchmark was run for this refinement.

### 11.8 Captured pretrained-model calibration (2026-09-06)

This pass advances the capture gate beyond the synthetic fixtures in §11.7;
it does not add a live array or a QEMU inference throughput measurement.
`capture_policy_model.py` records original dispatched PyTorch linear, matmul,
mm/addmm/bmm and baddbmm operations, module paths, native operand shapes/strides,
linear weight transposition, batch multiplicity, dtype and eight-element samples.
It executes each original operation once. Bias/scaling and non-matrix operations
are identified separately, not counted as extra GEMM MACs. Prefill and four
single-token cached forwards must produce finite logits; token/output digests
are recorded without publishing prompt text or generated text in the artifact.
This is a forward-execution check, not an independent model-quality assessment.

After explicit user approval, a contained environment was provisioned at
`build-platform/workspace/tooling/policy-capture/`: WSL Python 3.12.3,
PyTorch 2.6.0+cpu, Transformers 4.46.3, Diffusers 0.32.2, NumPy 2.2.2,
huggingface-hub 0.28.1 and safetensors 0.5.2. Its environment/model provenance,
wheel hashes and exact package pins remain in the ignored workspace. Capture
itself never installs or downloads, uses offline local snapshots and
`trust_remote_code=False`, and requires complete safetensors weights. No global
packages or production config were changed.

| Role | Pretrained model | Immutable revision |
|---|---|---|
| Calibration | HuggingFaceTB/SmolLM2-135M (Llama) | `93efa2f097d58c2a74874c7e644dbc9b0cee75a2` |
| Held out | EleutherAI/pythia-70m-deduped (GPTNeoX) | `e93a9faa9c77e5d09219f6c868bfc7a1bd65593c` |

Eight final captures cover each model in FP32/BF16 with the short development
prompt, plus matched 63- and 64-token BF16 prompts. A 32-token ceiling yielded
23 actual SmolLM2 tokens and 24 Pythia tokens; these were not mislabeled as 32.
SmolLM2 records 1,360 matrix operations per run, Pythia 190. Each BF16 run also
contains five genuinely FP32 rotary operations. Native dtypes are retained, not
projected onto INT8/INT4. The live island still grants INT8/INT4 only.
No pretrained diffusion or routed-MoE capture is claimed by these two dense LMs.

`policy_calibration.py` checks hashes/schema, rejects overlapping model IDs or
weight fingerprints between calibration and holdout, conserves useful MACs and
aggregates exact <=256-axis tile multiplicities. Linear weights remain [N,K] in
the source record and are explicitly interpreted as transposed. Samples are not
propagated to unrelated tiles; no sparsity or prefetch credit is inferred.
Raw metadata codes drive the existing topology baseline with balance=1: this
is not a replay of full codec hysteresis. Independent K tiles read/write C each
time, with identical traffic and serial external/local service for all candidates.
Autotuning searches 15 legal shapes for candidate 7 in each eligible group using
calibration counts only. Unobserved routed/sparse groups keep their defaults.
Margins, format slots, bandwidth and evaluation tax are not tuned to inflate gain.

Final reports: `build-platform/workspace/build/policy-calibration-final-{128,512}-20260906.json`.
The calibration set contains 5,440 source records / 69,140 independent tiles;
the held-out set 760 source records / 15,580 tiles. Both bandwidth profiles retain
`GroupShapeLog2=0x4420ca`: none of the candidate-7 substitutions wins this fit.
The target +500% throughput means 6x the existing allocator, not a rebased naive
kernel. Results relative to the subcode-disabled existing allocator are:

| Same-resource profile | SmolLM2 tuned MAC/cycle ratio | Pythia held-out ratio | Ideal fixed-service ceilings (SmolLM2 / Pythia) |
|---|---:|---:|---:|
| SRAM 128 B/cycle, external 8 B/cycle | 0.999020x | 0.999242x | 1.238630x / 1.125685x |
| SRAM 512 B/cycle, external 8 B/cycle | 0.998766x | 0.999132x | 1.000542x / 1.000264x |

Thus **6x is ruled out under these fixed-traffic, serial-service assumptions**;
the search currently regresses through overhead. Bounds are not universal
hardware limits: changing residency, bandwidth, overlap or arithmetic resources
would be a different implementation and must be measured separately.

Captured priorities differ from synthetic record shares. On SmolLM2, raw wide
code 1 is only 14.79% of tiles but 86.86% of useful MACs and 48.64% of baseline
cycles; decode is 67.48% of tiles but 8.35% of MACs and 47.76% of cycles. Optimizing
record frequency alone misses the dominant compute work. No routed/sparse
frequency is invented for these captures.

An explicitly non-deployable masked-output-tail oracle identifies a narrower
opportunity: 1.214351x SmolLM2 and 1.105900x Pythia at read128 if partial output
groups could share the array with ideal bank/port service and free selection.
It conserves native MACs and is checked against a separate fragment loop, but is
not used to fit/export subcodes and is not supported by the current selector's
M/N-divisibility guards. This supports investigating tail-masked broadcast and
accumulator banks, not claiming a measured 21.44%/10.59% improvement.

Reproducible entry points (capture requires the approved isolated interpreter):

```text
capture_policy_model.py --model-id <id> --revision <sha> --cache-dir <local-hub-cache> --out <capture.json> --dtype bf16 --prefill-tokens 64 --decode-steps 4 --prompt <development-text>
policy_calibration.py --calibration <SmolLM2 captures...> --held-out <Pythia captures...> --out <report.json> --replay-out <replay.json> --read-bytes 128
python verif/regress/ai-policy-subcode.py --parameters default --replay <replay.json>
bun build-platform/src/cli/index.ts test ai-policy-calibration
```

The bounded replay is metadata/cost checking against actual subcode RTL, not
full numerical tensor or AXI DMA replay. Source capture hashes and canonical
replay hashes bind the stages, while structural validation alone cannot
authenticate a third party's self-reported model execution. Production gates
remain off pending net benefit, live consumers, numerical/permission proofs,
bank/tail verification and timing/DFT evidence.

### 11.9 Agent-assisted motif fitting and bounded reuse

Higher-level pattern recognition belongs in the host capture/autotune layer;
it is not restricted to local scalar counters and does not add a learned model
to RTL. The capture now retains ordered non-matrix operators with exact links to
matrix records, rather than attempting to infer epilogue/gather ordering from
aggregate counts. Full geometry, native format, operator/module provenance and
layout residues remain available. Shape/stride agreement is only a reuse-axis
hypothesis, never proof of tensor identity, bank placement or data residency.
Static slice/view operations must not be promoted into irregular gather evidence.

The host motif pass proposes nested subcode parameters over the frozen eight
group codes. Its logical descriptor is the pair `{group[2:0],subcode[2:0]}`:
six internal bits, not a new Desc64 encoding or a replacement for the frozen
primary 3-bit policy. Recognized prefill/decode sequences, repeated projection
and attention structure, or ordered epilogue/gather families supply context;
they do not grant unimplemented fused arithmetic or new memory operations.
Uncaptured routed experts and image-generation models remain explicitly absent.
Only parameter choices expressible by the existing candidate geometry fabric
can be exported. Group encoding, successor map, policy muxes and arithmetic
contracts remain unchanged.

Warm-up, hysteresis, exact feature signatures, paired evidence and rejection
windows are host supervision in this pass. Inferred benefit and externally
provided measured useful-MAC/cycle evidence are distinct. Missing measurements,
format/work/profile mismatch, stale or duplicated pairs, topology/mispredict
penalties or net regression must prevent qualification or reject a retained
proposal. Model/synthetic feedback exercises this logic but is not array timing.
A rejected proposal can be refitted or replaced by baseline in the host ledger;
there is no new runtime-writable codebook interface or on-die motif-window engine.
Timing, numerical/permission checks and actual consumer support still gate any
production promotion, even when paired evidence is structurally valid.

The deliberately narrow RTL companion is an optional exact-match last-completed
subcode-result cache. It memoizes deterministic topology evaluation, not a motif
classifier or a learned history table. Reuse must match the complete shape,
format, eligible group and baseline topology under the same compiled parameters.
Unfinished searches cannot become cache entries; reset, disable, flush and batch/
format epochs invalidate reuse. A fresh record cancels any older response while
preserving only a valid completed entry within the allowed epoch. Cache-disabled
behavior and all primary codec outputs must remain equivalent. This targets
repeated evaluation latency only; it does not establish a new array MAC/s gain.

Implemented host entry point: `policy_motifs.py`. Defaults are a 16-record window,
eight-record warm-up, two consistent windows before retention, two-window cooldown
and a 32-template catalog. `MinRealizedGain16ths=8` requires measured fractional
saving to reach at least half the predicted fractional saving; with
`MaxGainSpread16ths=8`, the largest normalized saving across retained windows must
not exceed 1.5 times the smallest. Inclusive boundaries and exact rational
comparisons avoid treating different workload sizes as inconsistent raw-cycle
counts. Taxes are additional cycles not already included in measured elapsed
cycles. No supplied measurement means no qualified performance claim.

A separate structural template key excludes literal model/layer names while
preserving format, phase, raw group, buckets, R/C residues modulo 16, canonical
matrix families and run-collapsed reuse sequences. Exact geometry, layouts and
source identity remain in feature/evidence guards. Calibration-only opportunity
ranking chooses catalog entries by predicted saving, then baseline cycles, useful
MACs and support; there is no first-arrival bias or equal-share quota. A template
hit cannot bypass full-shape legality or exact paired evidence.

Actual ordered-capture report `policy-motifs-window-final-20260906.json` admits
32 of 51 calibration templates. It matches 312/382 calibration group-windows
(99.8300% useful-MAC coverage), but only 10/58 held-out group-windows (0.4944%
useful-MAC coverage). Epilogue adjacency is observed as a structural hypothesis;
irregular gathers are not observed and routed bursts remain uncaptured. All
admitted subcode hints are baseline 0, `GroupShapeLog2` stays `0x4420ca`, and
qualified measured claims remain zero. This is limited structural transfer, not
mostly accurate cross-model performance prediction or a demonstrated lift.

The RTL cache uses `AiCfg.PolicySubcodeCacheEn`, requiring `PolicySubcodeEn` and
defaulting off. Eligible misses complete in 32 cycles; exact completed-result
hits in one cycle. The retained winner is reused conservatively, not upgraded
because the lookup is cheaper. The hit cost includes one lookup cycle plus the
conditional switching cost. `cancel_i` separates response cancellation from
true epoch invalidation; accepted first/format-change/after-last records flush
in steering. `subcode_cache_hit_o` is response-qualified observation; primary
ready/work/code/policy outputs remain unchanged. The live descriptor producer
still treats each GEMM as an epoch, so this does not enable cross-job cache reuse.

Remote cache tests pass five service/parameter profiles: 1,556 hits and 1,623
misses/rejections per profile, interrupted searches at every age, key changes,
format/batch invalidation and original-output equivalence. Yosys artifact
`ai-policy-subcode-synth-20260906T132132Z-356d75ad3869` reports 4,880 generic cells /
340 sequential with cache off versus 5,473 / 342 with cache on, zero latches;
whole evaluator off is zero cells. The incremental cost is 593 generic cells and
two sequential cells, not technology area. A 72-step fixed-INT4 control proof
with K=17/18 reaches a hit and checks five assertions; arbitrary full-key and
numerical cache correctness remain simulation evidence, not induction. A broader
numerical formal attempt timed out. Host capture/calibration/motif tests pass
114 cases, including false sparsity, forced group/subcode walks, stale feedback,
taxes, warm-up/steady transitions, gain consistency, rollback and split isolation.

### Measured AR-depth feedback (first real RTL cycle evidence)

`tb_g6lc_ai_gemm_backend` gained an opt-in `+measure` sweep (default off, existing
checks and PASS line unchanged) that runs the same GEMM per numeric format at
every legal AR depth and reports free-running RTL cycles, sequencer PMU counters
and result digests. `policy_measure.py` validates that log into the
`g6lc.policy-measure.v1` artifact and computes MAC/cycle with exact rational math.

Result digests are identical at every depth, so AR depth never changes arithmetic.
The first artifacts (`policy-measure.json`, `policy-measure-class1.json`) used a
2x2x16 fixture and are superseded: see the fixture defect below. Their depth-1
versus depth-2 direction held up, but their magnitudes and every depth >= 2
comparison did not.

This is the project's first measured rather than modeled throughput evidence, and
it is a **regression finding about the existing policy table**, not a gain:
`policy_decode` maps `POLICY_DECODE`, `POLICY_ROUTED` and `POLICY_SPARSE` to
`prefetch_depth=2'd1`, and `g6lc_ai_gemm_seq.ar_max_eff` honors that literally,
so those three codes request the measurably slower depth while codes at depth 2
or 3 resolve to 2. Depth 0 and depths above `MaxAROut` fall back to `MaxAROut`.

**Fixture defect found and corrected — earlier depth results were invalid.**
`g6lc_ai_gemm_seq` issues an A-phase AR only while `ar_i_q < m_q` and a B-phase AR
only while `ar_j_q < n_q`, so inflight ARs are bounded by `m` then `n`, not by
`ar_max_eff` alone. At the original 2x2x16 sweep geometry no more than two ARs
could ever be inflight, so **every depth >= 2 was the same hardware** and the
observed spread at depths 3-8 was memory-page noise. That fixture also ran at only
about 20% of peak. The sweep now uses 8x8x16 (1024 useful MACs, depth up to 8
genuinely reachable, about 68% of the `PeLanes=8` peak) and repeats each pass so
the noise floor is measured rather than assumed.

On the corrected fixture the depth response is **monotonic — deeper is always
better** — which is the expected latency-hiding physics, not a tuning curve:

| Depth | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| DRAM class vs policy-off | -40.2% | -19.1% | -12.6% | -6.2% | -3.0% | -2.9% | -1.5% | 0% |

- Live class (`MaxAROut=2`, noise floor exactly 0%): depth 1 costs **-8.15%**;
  depth 2 *is* policy-off and is optimal.
- DRAM class (`MaxAROut=8`, repeat-pass noise floor 2.8% mean / 25% worst):
  policy-off is optimal. Cross-validated per-format tuning loses **-1.01% mean
  with all four folds negative**. Five of seven formats show exactly 0% headroom;
  the two apparent small wins (`+4.35%`, `+1.37%`) sit below the noise floor.

**Correction to the mapping.** `g6lc_ai_island_top` requested
`1 + prefetch_depth`, not `prefetch_depth`, so the shallowest cap any code could
ask for was 2 and depth 1 was never reachable. The real exposure was therefore:
no-op at the live `MaxAROut=2` (every code clamps to 2), and on `MaxAROut=8`
DramClass parts `-19.1%` for DECODE/ROUTED/SPARSE (cap 2), `-12.6%` for
BULK/TALL/ATTENTION (cap 3) and `-6.2%` for WIDE/MOVEMENT (cap 4). An earlier
`-8.15%` figure quoted a depth-1 case that cannot occur and is withdrawn.

**Consumer removed.** `gemm_ar_max` is now unconditionally `IslandCfg.MaxAROut`.
`policy.prefetch_depth` remains visible in the PMU word as advice, but nothing
consumes it, so the AR path is identical to no policy steering. The island DMA
regression still reports `*** SUCCESS *** ai-island DMA (170 cycles)`.

**Raising a bound instead of lowering one.** A provisioning sweep
(`run-gemm-scaling.sh`, `PE_LANES`/`AR_PROVISION`, both defaulting to the shipped
values so an unset build is byte-identical) measures where throughput actually
comes from. AR provisioning 2/4/8 at one channel gives **exactly 0%** at every
lane width, confirming outstanding-AR depth is not the binding constraint here.
Lane width is:

| Lanes | INT8 cycles | MAC/cycle | Share of peak | All-7-format total |
|--:|--:|--:|--:|--:|
| 8 | 188 | 5.45 | 68.1% | 2036 cycles |
| 16 | 124 | 8.26 | 51.6% | 1332 cycles (+52.9%) |
| 32 | 124 | 8.26 | 25.8% | 1076 cycles (+89.2% cumulative) |

All nine configurations keep their golden C, so these are like-for-like. INT8
saturates at 16 lanes: with `k=16` a reduction already completes in one cycle, so
further lanes have nothing to reduce, and only formats with more than one byte per
element still gain at 32. `PeLanes=4` is not a valid point at all (it deadlocked
the directed phase, since `SplitArId` depends on `PeLanes >= BytesPerBeat`).

**On the 300% target: not reachable by parameter tuning, and not by lanes alone.**
Measured headroom at this tile geometry is about `+89%`, and it is already
saturating. A 4x class of gain needs three things together, none of which is a
knob: `k` (and `MaxDim`, currently 16) large enough that wide lanes stay fed;
operand bandwidth beyond the 64-bit/8-byte beat, since 32 INT8 lanes want ~32 B
per cycle; and multiple output accumulators, which is exactly the multi-output
datapath the topology model assumed and the RTL does not have. Widening lanes
without the other two only lowers utilisation, which is visible above as 68% ->
52% -> 26% of peak.

### Chip surface efficiency: wider engine versus more clusters

Per-lane efficiency (measured throughput divided by arithmetic width) falls hard
as the single engine widens, because `k=16` stops feeding the lanes:

| Lanes | All-format MAC/cyc | Per lane | INT8 MAC/cyc | Per lane | Per-lane vs 8 |
|--:|--:|--:|--:|--:|--:|
| 8 | 3.521 | 0.4401 | 5.447 | 0.6809 | 0% |
| 16 | 5.381 | 0.3363 | 8.258 | 0.5161 | **-23.6%** |
| 32 | 6.662 | 0.2082 | 8.258 | 0.2581 | **-52.7%** |

Comparing the two ways to spend the same 32 MAC lanes of silicon:

| Spend | Measured MAC/cyc | vs 8-lane baseline |
|---|--:|--:|
| One 32-lane engine | 6.662 | +89.2% |
| Four 8-lane clusters | 14.083 | **+300.0%** |

**Replication is 2.11x more efficient than widening at equal arithmetic area,**
and four clusters is exactly the +300% target. The reason is structural: a
cluster keeps per-lane efficiency at the measured 0.4401, while widening one
engine past `k` throws half of it away. Small-surface replication therefore beats
a large monolithic datapath here, and it also avoids the `PeLanes >= BytesPerBeat`
constraint that makes narrow lanes illegal.

Bandwidth check at this tile: operands are 256 B per 1024 INT8 MACs, so 8 lanes
consume 1.36 B/cycle and four clusters 5.45 B/cycle against roughly 8 B/cycle for
one 64-bit port. Four clusters fit; eight would not. **Caveat:** this tile reuses
each operand eight times (4 MAC/byte), which is generous - real LLM shapes reuse
less, so per-cluster bandwidth must be re-measured on a steady-state fixture
before committing to a cluster count.

### Pricing the format return: area now measured, and it changes the answer

`g6lc_ai_gemm_seq` now elaborates under Yosys (the operand loop was given a
constant `PeLanes` bound), so lane width can finally be priced. Counts below are
**coarse generic cells** (pre-ABC, memories unmapped, so an absolute cell count is
not a technology area) used purely as a *relative* proxy across lane widths; full
`synth` did not converge here, stalling in SAT resource sharing and then ABC.

| Lanes | Coarse cells | Area vs 8 | FP32 16x16 throughput | Throughput per area |
|--:|--:|--:|--:|--:|
| 8 | 383,575 | 1.00x | 1.00x | 1.000 |
| 16 | 619,197 | 1.61x | - | - |
| 32 | 1,146,467 | 2.99x | 2.88x | 0.964 |
| 64 | 2,416,615 | 6.30x | **4.20x** | **0.667** |

So the measured `+320%` on FP32 is real but **costs 6.30x the arithmetic area**,
and lane ganging loses area efficiency as it widens: break-even holds to 32 lanes
(0.964) and degrades badly at 64 (0.667). Comparing the two routes to the same
`+300%`:

| Route to 4x throughput | Area cost |
|---|--:|
| Lane ganging, 64 lanes | 6.30x (measured) |
| Four 8-lane clusters | 4.00x (linear by construction, needs 4x bandwidth) |

**Cluster replication is about 1.58x cheaper in area than ganging for the same 4x**,
which confirms the earlier per-lane efficiency argument with real cell counts
rather than reasoning. The two remain complementary but their roles are now
precise: replicate clusters to buy throughput, and use format-driven lane grouping
so a wide array is not wasted on narrow formats (INT4 gains nothing from width, so
for INT4 every lane past 8 is pure area). Ganging past 32 lanes should only be
bought where single-job latency matters more than area.

**Logic depth: a weak proxy that does not support a frequency claim.** Yosys `ltp`
on the same coarse netlists gives a longest topological path of 1493 levels at 8
lanes, 1540 at 16, 1583 at 32 and 1626 at 64 - about `+43` levels per doubling,
i.e. one reduction-tree stage, and only `+8.9%` in total from 8 to 64 lanes. Taken
at face value that would mean ganging costs far less in frequency than in area.
It should not be taken at face value: these are untechmapped generic structures
(`opt -fast`, no ABC), so wide arithmetic is still ripple-shaped and real mapping
would restructure it. Selecting the pipelined float dot (`DotPipe=1`) changes the
path by four levels (1497 at 8 lanes, 1630 at 64) while adding **+55% cells**
(596,485 at 8 lanes, 3,753,800 at 64), which shows the deep path is not in the
dot product at all. **No STA, no frequency, and no timing closure evidence exists
for any lane width**, and a 6.3x-area block could still lose at the clock.

This is a tooling limit, not an oversight. Mapped synthesis does not converge
under the available open flow even for the block that scales: synthesising
`g6lc_ai_pe_dot_float` on its own still times out in ABC at 900 s for `Lanes=8`
and blows up in the SAT share pass at `Lanes=64`. The coarse generic proxy is
therefore the only area evidence that exists for the arithmetic array, and the
gang-versus-replicate decision needs a commercial flow (or a mapping recipe cheap
enough to finish) before it is settled on cost.

**The cluster linearity assumption is still an assumption.** The 4.00x-for-4x
figure above is linear *by construction*, and the honest test of it has not been
run. What exists is a weaker, related measurement: giving one engine more memory
parallelism does nothing for it. Across the DRAM-class corpus at the deepest AR
depth, going from one channel to eight moves aggregate cycles by only `-3.8%`,
with per-format scatter from `-16.7%` to `+3.2%` - scatter larger than the effect,
and inside the 2.8%-mean / 25%-worst noise floor of that memory model.

So a single engine at this tile is not bandwidth-starved: it cannot exploit 8x more
memory parallelism, which is consistent with the 1.36 B/cycle it actually consumes
against roughly 8 B/cycle of port. That is **consistent with** headroom for
replication, but it is not the same experiment: it measures one engine's ability
to use parallelism, not contention between several engines sharing one port.
Deciding cluster scaling needs N engines running concurrently against one memory,
which no testbench currently builds.

Two hard limits on the above. First, **multi-cluster is advertised but not
implemented**: `Clusters`/`ClustersEnabled` appear in `island_cfg_legal` and the
CAP window, while `g6lc_ai_island_top` instantiates exactly one
`g6lc_ai_gemm_seq`, so the 4x figure is four times a measured single cluster, not
a measured four-cluster system. Second, **no gate-level area exists for the GEMM
datapath at all**: `read_slang` cannot elaborate `g6lc_ai_gemm_seq` because the
operand-assembly loop at line 1164 is bounded by the runtime `mac_step`, which
exhausts the unroll limit (see `tb_g6lc_ai_gemm_area.sv`). Area here is therefore
reasoned per MAC lane, not measured in cells; published synthesis evidence still
covers only the policy controllers.

### Remote research basis: where the codec has a calculated positive return

`verif/regress/ai-gemm-codec-basis.py` is remote-only (it dispatches through
`testharness_proxy.py` and refuses to run locally). It builds
`tb_g6lc_ai_gemm_backend` at six provisioning points (`PeLanes` 8/16/32 x
`MaxAROut` 2/8) and runs the `+measure` sweep over the codec's own shape classes
(`8x8` bulk, `1x16` decode, `16x1` tall, `2x16` wide, `16x16` large) for all seven
granted formats at every legal AR depth, twice each. Result digests were stable
across every AR depth at every point, so nothing below changes arithmetic.
Evidence: `remote-runs/ai-gemm-codec-basis-20260906T165957Z-718434a9a9d1`,
2,100 measured records, `status=PASS`, Verilator 5.008 on the harness.

**Shape gives the codec nothing; format gives it a lot.** For all seven formats
the winning provisioning point is identical across all five shape classes
(`shape_dependent=false` everywhere), so a shape-keyed runtime choice has no
throughput to capture - which is consistent with the AR-cap consumer having been
removable at zero cost. The optimum does differ by *format*, and `numfmt` is
already a codec feature and a `policy_topology` input:

| Format | Best lanes | Gain versus 8-lane baseline (min - max across shapes) |
|---|--:|---|
| INT4 | 8 | 0% at every shape - wider lanes never help |
| INT8, FP8 E4M3/E5M2 | 16 | +0.94% (tall) - **+69.6%** (16x16) |
| FP16, BF16 | 32 | +12.9% - **+177.8%** (16x16) |
| FP32 | 64 | +39.4% - **+320.0%** (16x16) |

A follow-up 8/32/64-lane run (`ai-gemm-codec-basis-20260906T172019Z`) closed the
open end of that table: FP32 keeps improving to 64 lanes and wins there for every
shape class, reaching **+320.0%** on 16x16 (2352 -> 560 cycles) and +203.6% on
8x8. INT4 still gains nothing past 8 lanes and INT8/FP8 nothing past 16, so the
"twice the element width in lanes" rule now holds across the whole measured range
instead of being extrapolated at its top end. **The +300% target is therefore
measured-exceeded for FP32 by lane ganging alone, with no cluster replication.**

`MaxAROut` 8 never won: AR 2 ties or wins everywhere, confirming again that AR
depth is not a productive codec output.

**This is the productive codec target.** A format-driven lane-grouping decision
has a measured return of up to `+188%` on one engine, before any cluster
replication - and it is precisely the multi-input/multi-output "virtual
transistor" grouping the original objective described. The two directions are
complementary rather than competing: narrow formats (INT4 at 0% gain from
ganging) should *split* a wide array into independent 8-lane groups to run
several jobs at once, while wide formats (FP32 at +188%) should *gang* lanes
together for one job. Combining format-driven grouping with the 2.11x replication
advantage is the credible route past +300%, and both are provisioning decisions
the eight-state code plus 3-bit subcode can express directly.

What this is not: the sweep provisions each point at elaboration time, so the
codec cannot conjure lanes at runtime. Realising the return needs selectable lane
grouping in the datapath (gang/split), which does not exist yet. Until it does,
these are measured returns of *hypothetical provisioning*, not of the shipped
island, and no gate is enabled on their strength.

### Hypothesis: sub-codes can pay, but not as currently built

This section is a hypothesis and a design argument, not a result. It is written
because the measured evidence explains *why* the current sub-code loses and
points at a cheaper form that could win.

**Why the current sub-code cannot win.** It spends a 32-cycle, 8-candidate search
choosing an alternate row/column tile shape. Three measured facts each defeat it
independently:

1. The provisioning optimum is **shape-independent** - identical across all five
   shape classes for every format - so a search over shapes is searching a flat
   space.
2. The search costs `4,880` generic cells and `340` flops, plus `593` cells for
   the repeat cache, and charges a 32-cycle evaluation tax that made captured
   LLM traces come out at `0.998x`, i.e. the tax exceeded the benefit.
3. Nothing consumes the chosen topology, so even a correct choice changes no
   cycles.

**The decision that does carry return is nearly free.** The measured optimum is a
lookup, not a search: `INT4 -> 8`, `INT8/FP8 -> 16`, `FP16/BF16 -> 32`,
`FP32 -> 64` lanes. Four values, expressible in two bits, from a three-bit input.
A combinational table is tens of cells and zero cycles against `4,880` cells and
32 cycles - and it deletes the evaluation tax that is the measured cause of the
`0.998x`. The repeat cache also becomes unnecessary, since a combinational lookup
has nothing to memoise. **The concept is not what fails; the search is.**

**The mechanism, which corrects the fitted rule.** `g6lc_ai_gemm_seq` sets
`mac_step = 2*PeLanes` for INT4 and `PeLanes/bytes` otherwise, and a reduction
completes when `mac_step >= k`. Solving for lanes gives `L >= k/2` for INT4 and
`L >= k*bytes` otherwise - both of which are exactly `fmt_row_bytes(k)`, the
operand row length in bytes. So the general rule is:

> **useful lanes = k_bytes**, the operand row in bytes; beyond that, lanes idle.

At `k=16` that yields 8/16/32/64 for INT4/INT8/FP16/FP32 - precisely the four
measured optima, which is why the "twice the element width" fit appeared to work.
**That fit is therefore `k=16`-specific, and `policy_dot_lanes_log2` is only
validated at `k=16`.** The general rule depends on `k`.

**Why that matters for sub-codes specifically.** `k` is a per-job runtime value.
A decision that depends on `(k, format)` is *not* a static configuration choice,
which is exactly the property the codec needs to be worth having: a fixed build
cannot pick the right lane grouping for every job, but a three-bit sub-code
computed per descriptor can. This is the first identified decision that is both
runtime-varying and tied to measured cycles.

**Efficiency and area path.**

| Step | Area | Latency | Contingency |
|---|---|---|---|
| Replace the candidate search with a `(k, format) -> groups_log2` table | ~tens of cells, recovering ~4,880 + 593 | 32 cycles -> 0 | none; pure simplification |
| Re-purpose the 3-bit field as `groups_log2` (2 bits) + 1 reserved | unchanged encoding | - | none; wire-compatible |
| Add gang/split lane grouping to the datapath | the real cost, unmeasured | - | this is what unlocks any gain |

Only the third step buys anything, and it is the expensive one. The first two make
the codec side almost free and remove the measured reason it currently loses.

**The experiment was run, and the rule holds: 6 of 6.** `run-gemm-ksweep.sh`
(`+measure_k`, `MaxDim=64`, integer formats where the golden C is exactly `k`,
492 records, all golden-clean) sweeps `k` against lane width:

| Format | k | k_bytes | l8 | l16 | l32 | Best | Predicted |
|---|--:|--:|--:|--:|--:|--:|--:|
| INT4 | 16 | 8 | **66** | 66 | 66 | 8 | 8 |
| INT4 | 32 | 16 | 188 | **124** | 124 | 16 | 16 |
| INT4 | 64 | 32 | 348 | 220 | **156** | 32 | 32 |
| INT8 | 16 | 16 | 99 | **83** | 83 | 16 | 16 |
| INT8 | 32 | 32 | 348 | 220 | **156** | 32 | 32 |
| INT8 | 64 | 64 | 668 | 412 | **284** | 32 (capped) | 64 |

The optimum moves with `k` exactly as `k_bytes` predicts, so the earlier
element-width fit was indeed a `k=16` coincidence, and the decision genuinely
varies at runtime.

**But the same data kills the obvious use of it.** Choosing the gang width per job
is worth **`+0.0%`** against simply provisioning wide: extra lanes *idle* at
identical cycles rather than hurting (INT4 at `k=16` is 66 cycles at 8, 16 and 32
lanes alike). A knob whose wrong settings cost nothing cannot earn anything by
being set correctly. So the sub-code's value is **not** in selecting a gang width.

**The whole opportunity is the idle lanes.** The sequencer bounds per-tile `k` by
`MaxDim`, so at the shipped `MaxDim=16` on a 32-lane array:

| Format | k_bytes | Lanes used | Lanes idle | Concurrent groups |
|---|--:|--:|--:|--:|
| INT4 | 8 | 8 | **24** | **4x** |
| INT8, FP8 | 16 | 16 | 16 | **2x** |
| FP16 | 32 | 32 | 0 | 1x (saturated) |
| FP32 | 64 | 32 | 0 | wants more than 32 |

Those idle lanes are only monetisable by running *several jobs at once* in
independent groups - which needs per-group accumulators and descriptor slots, the
same multi-output capability the topology model always assumed. And because
format varies per job, the split factor varies per job, so it is a real runtime
decision rather than a build-time constant.

**Refined answer to "can sub-codes pay?"** Yes, but only in one narrow form: a
combinational `(format, tile-k) -> groups_log2` split factor, worth up to 4x
concurrency on INT4 and 2x on INT8/FP8, and worth nothing on FP16/FP32 which
already saturate. Not by searching shapes, not by choosing gang widths, and not
at all until per-group accumulators exist. The honest caveat is that the payoff
is a *utilisation* argument measured on a small fixture, not an end-to-end
throughput measurement, and it inherits the untested concurrency assumption that
also limits the cluster case.

### Planned upgrade: concurrency plus sub-code-steered approximate compute

**This whole section is a plan.** Nothing in it is implemented and no number in
it is a result except where it cites the measured rule. It is written because the
`k_bytes` finding turns "approximate compute" from a vague idea into an
arithmetic one.

**Why precision is the right knob.** Usable lanes are `k_bytes = k x bytes`, so
element width *is* lane demand. Halving the element width halves `k_bytes` and
therefore doubles the groups a fixed array can host:

| Format | bytes | k_bytes (k=16) | Groups @ L=32 | Groups @ L=64 |
|---|--:|--:|--:|--:|
| FP32 | 4 | 64 | needs >32 | 1 |
| FP16/BF16 | 2 | 32 | 1 | 2 |
| FP8, INT8 | 1 | 16 | 2 | 4 |
| INT4 | 0.5 | 8 | 4 | 8 |

**2x concurrency per precision halving**, derived from the measured rule rather
than assumed. That is the numerator of the "performance gain per accuracy drop"
ratio. The denominator is not measured at all, and measuring it is task one.

**The analog-imitating part, made concrete.** "Combinational data imitating
analog" maps onto approximate multiplier topologies that are pure combinational
logic: mantissa-truncated products, and logarithmic (Mitchell-style) multiply
where a product becomes an exponent add plus a corrected mantissa. Both trade
per-product accuracy for area and depth, like an analog multiplier trades
precision for density. The accuracy-preserving discipline is standard and cheap:
**approximate the products, accumulate exactly** in a wide accumulator, so error
does not compound across the reduction. That single rule is what makes a high
gain-to-loss ratio plausible.

**Sub-code as the experiment harness, which is what it is actually good for.**
The codec already has hysteresis, feature-hash silence, PMU observability,
config gating and a default-off posture - a safe per-job selector that took real
verification effort to build. Re-purposed, the 3-bit sub-code carries
`groups_log2` plus a precision/approximation class instead of a candidate index,
so the same frozen group codes steer an experiment without redesigning muxes.

**Staged plan, ordered so the cheap disqualifier comes first.**

| Stage | Work | Needs hardware? | Gate |
|---|---|---|---|
| S0 | Accuracy harness: error of each approximate topology versus exact FP32, on **captured LLM matrices** | No | Reject any topology outside the error budget before any RTL |
| S1 | Per-group accumulators + descriptor slots; measure real concurrency | Yes | Groups must convert to throughput; this is the untested concurrency assumption |
| S2 | Approximate multiplier options behind a parameter, exact wide accumulate | Yes | Latch-free, bounded depth, no new clock |
| S3 | Sub-code emits `(groups_log2, precision_class)`; search replaced by the `(format, tile-k)` lookup | Yes | Recovers ~5,470 cells; 32-cycle tax -> 0 |
| S4 | Promotion: paired performance **and** accuracy evidence on held-out captures | - | Ratio above an explicit threshold, or it stays off |

S0 first is deliberate: it needs no RTL, and if the accuracy loss is
unacceptable the rest of the plan is void. It is also the stage this project can
actually complete today.

#### S0 result: measured on real tensors

`policy_approx.py` ran against the pinned `EleutherAI/pythia-70m-deduped`
(revision `e93a9faa...`) through a real forward pass, taking 48 genuine
activation-by-weight tiles at the shipped `8x8x16` geometry. Reference is exact
`float64` products *and* accumulation; every candidate accumulates exactly.
Artifact: `policy-approx-s0-pythia.json`.

Lever 1, format narrowing - the only lever that changes `k_bytes`:

| Format | k_bytes | Groups @64 lanes | Rel err p95 | Gain per 1% error |
|---|--:|--:|--:|--:|
| FP32 | 64 | 1 | 0 (lossless: the model is FP32) | - |
| FP16 | 32 | 2 | `2.96e-04` | **67.6** |
| BF16 | 32 | 2 | `3.18e-03` | 6.3 |
| INT8 | 16 | 4 | `1.49e-02` | 2.7 |
| FP8 E4M3 | 16 | 4 | `4.89e-02` | 0.8 |
| FP8 E5M2 | 16 | 4 | `9.62e-02` | 0.4 |
| INT4 | 8 | 8 | `2.49e-01` | 0.3 |

Three findings that change the plan:

1. **FP16 is the standout**: 2x concurrency for `0.03%` error, an order of
   magnitude better ratio than anything else, and 10x more accurate than BF16 at
   identical `k_bytes`. If only one precision step is taken, it is this one.
2. **At equal concurrency, INT8 beats both FP8 encodings** - 3.3x more accurate
   than E4M3 and 6.5x than E5M2 for the same one byte per element. Narrowing to
   one byte should prefer INT8 here, which is not what the format list would
   suggest.
3. **INT4 costs `25%` tile error for its 8 groups.** That is almost certainly
   past any usable budget, so the 4x-INT4-concurrency headroom identified
   earlier is largely unreachable on this model.

Lever 2, approximate multipliers, is **dominated** and the study says so:

- 8-bit mantissa truncation lands at `3.22e-03`, statistically the same as BF16's
  `3.18e-03` - but truncation keeps 4-byte storage, so it buys **no**
  concurrency. Whenever the format can be narrowed instead, narrowing strictly
  wins because it buys lanes as well.
- Mitchell logarithmic multiply is `8.2x` less accurate than INT8 *and* buys no
  lanes. On this evidence it should not be built.

So the honest S0 verdict: **the plan survives, but only in a narrower form than
proposed.** The value is a per-job FP32/FP16/INT8 precision choice - which is
exactly a `precision_class` a sub-code can carry - and not the approximate
multiplier topologies that motivated the "analog-imitating" framing. Mantissa
truncation remains defensible only where FP32 range is required and its storage
cannot be narrowed.

Caveats that bound all of the above: tile Frobenius error is a proxy, not a
perplexity result; the operands come from one small model and one prompt, not a
workload distribution; FP8/INT8/INT4 are measured *with* per-tile scaling, which
flatters them relative to an unscaled path; and accumulation is exact everywhere,
so accumulator-width effects are not covered.

**Area works in our favour here, unusually.** Truncated and logarithmic
multipliers are *smaller* than exact ones, and deleting the 8-candidate search
frees roughly 5,470 cells to spend on per-group accumulators. So precision
reduction buys lanes **and** area, which is the opposite of the lane-ganging
trade where 4.20x throughput cost 6.30x area.

**Four risks that must not be glossed over.**

1. **Every measurement so far depended on bit-exact digests.** Approximate
   arithmetic breaks that invariant by design, so this work needs a different
   verification mode: error bounds against an exact reference, not equality. The
   existing suites must keep their exact checks for exact modes.
2. **The all-ones fixture is useless for accuracy.** It has no cancellation and
   no dynamic range, so it would flatter any approximation. S0 must use captured
   matrices, which is why the capture corpus already in the tree matters.
3. **The concurrency assumption is still untested**, shared with the cluster
   case, and it gates the entire numerator.
4. **Accuracy is a model-quality question, not a matrix-error question.** Frobenius
   error on a tile is a proxy; a perplexity-level claim needs an end-to-end run
   that this project cannot currently perform. Report the proxy as a proxy.

### Where sub-codes and groups can and cannot help

Tuning subcode/group parameters cannot move MAC/s today, for a structural reason
rather than a tuning one: nothing consumes their output. The codec's candidate
topologies were already modelled at `0.998x`, and the one output that did reach
hardware (`prefetch_depth`) could only lower a bound and has been removed.

The productive reframing is that the codec needs a consumer that *raises*
provisioning. The remote basis above pins down which feature actually carries the
return: **format, not shape**. Groups keyed on shape buckets measure flat, while a
format-keyed lane-grouping decision measures up to `+188%`, and cluster choice is
worth a further 2.11x at equal area. So the codec's productive form is a
format-and-provisioning selector, not a shape-and-tile selector, and the subcode's
job becomes "how to group lanes for this element width", not "which tile shape to
guess". Until selectable lane grouping or cluster replication exists in RTL,
subcode work still has zero throughput leverage and must not be tuned for
performance - but the target it should be fitted to is now measured rather than
modelled.

**Structural conclusion: the knob cannot win.** `prefetch_depth` can only lower
the cap below `MaxAROut` (0 falls back to `MaxAROut`), measured throughput rises
monotonically with depth, so "do not cap" — which is exactly policy-off — is the
optimum. The ceiling for AR-depth steering versus no steering is **0%**, and the
shipped table spends **-8.15%** on decode/routed/sparse traffic. No parameter
tuning changes this; the sign is fixed by construction. Artifacts:
`policy-measure-live-m8-20260906.json`, `policy-measure-class1-m8-20260906.json`.

Scope limits: one small fixed job per format, one testbench memory model, and
local WSL Verilator dispatch, so this is diagnostic-grade evidence rather than a
proxy-authoritative regression result. It is not silicon, wall-clock or QEMU
throughput, and MAC/s is withheld unless a clock is explicitly declared, in which
case it is a projection. No frozen policy code, mux, gate or RTL default was
changed on the strength of it; the recommendation is a tuning input only.

The full repository verification attempt is not a sign-off result: its smoke
harness failed on generated SRAM/SMT hierarchy member references. It was stopped
after its broad generated-output cleanup was noticed; Git showed no tracked
file deletions. Keep scoped proxy evidence separate from that incomplete gate.

## 12. Native model evaluation and exact floating arithmetic

The next layer connects the independent `ai-tensor` and `g6lc_qemu` packages
through native bytes and a model-derived descriptor, rather than duplicating the
policy classifier in an emulator. `verif/regress/ai-native-eval.py` is the host
adapter; neither package imports the host or the other package into its crates.

### 12.1 One v2 contract, four distinct kinds of evidence

The interoperability path is:

```text
ai-tensor native A/B bytes + semantic opcode-class metadata
  -> g6lc_qemu tensor-eval, using the ingested descriptor layout and grants
  -> B3 descriptor executor -> C32 bytes + status + source/model fingerprint
  -> independent ai-tensor numerical reference and descriptor-byte comparison
  -> successful-job policy-workload trace -> remote RTL policy replay
```

`tensor-eval` is **B3 functional descriptor execution**, not a guest CPU boot,
B1 QEMU device execution, or RTL simulation. Results explicitly stamp
`qemu_guest=false`, `rtl_cycles=false` and `fp_exception_flags=false`. The trace
is input to the existing RTL policy compartment; it is not evidence that the
emulator executed that policy. Replay retains its separate future-array service
profile, not the much slower scalar FP primitive described below.

The data contract is version 2: A `[m][k]`, B `[n][k]`, element-count strides
`lda/ldb >= k`, native row-byte padding and C32 output. `DESC_B_K_MAJOR` now
publishes the layout fact for ingest. The evaluator refuses an unresolved or
false fact instead of guessing from the descriptor version or square shapes.
Python, Rust and C ai-tensor constants are checked together. Conventional
high-level `A @ B` S8 APIs transpose/repack B at the boundary; native-byte APIs
accept k-major B explicitly. Old v1 buffers are not silently reinterpreted.

Keep these measurements separate:

| Layer | What the result establishes | What it does not establish |
|---|---|---|
| ai-tensor/B3 C32 agreement | Exact native-format arithmetic, layout, stride and grant behavior | Guest boot, bus ordering or cycle accuracy |
| B3 host benchmark | Faster emulator evaluation from decoded-operand reuse | Faster silicon or a changed architectural MAC rate |
| Policy trace replay | Real RTL control decisions over functionally evaluated work; scheduling-model comparisons | Numeric PE execution or realized array throughput |
| Scalar FP RTL test | Actual pipeline latency, handshakes, flags and binary32 numerical results | Integrated floating GEMM, vector-array throughput, STA or DFT sign-off |

### 12.2 Software number-format completion

Both software numeric references execute signed INT4/INT8 and FP8 E4M3/E5M2,
FP16, BF16 and FP32. Integer accumulation wraps in i32. Floating products round
to binary32 before an ordered binary32 add; no fused multiply-add or wider sum
is substituted. NaN C words are canonical `0x7fc00000`. SP24 remains unsupported
and ungranted formats are refused before computed C writes.

The supported native T2 arithmetic subset is signed, overwrite-only. Nonzero
`dtype`/`accmode`, reserved EW values, sparse requests and nonzero integer EW on
float requests return `ST_BAD_FMT`, rather than executing a different mode.
Legacy `numfmt=INT, ew=1` is resolved to INT4 for compute and grant checking;
the raw selector remains unchanged for descriptor ingest. Both the real
`g6lc_ai_desc_engine` handoff and software backends enforce this distinction.
A complete C destination and completion-pointer range is validated before B3
memory effects; device overlays are excluded from RAM-only decode reuse, and
failed guest writes remain errors in completion/poll state.

The live-source evaluation uses the **actual published mask `0x0003`**: only
INT4/INT8 execute. A separately named, synthetic software-exploration fixture
publishes `0x00fb` and exercises all seven implemented software formats. It is
never substituted for the live model or used to raise hardware grants.

Public raw-buffer reference:

```python
from ai_tensor.numfmt import gemm_native
c_bytes = gemm_native(a_bytes, b_kmajor_bytes, m, n, k, numfmt,
                      lda=lda, ldb=ldb, dtype_mask=software_or_discovered_mask)
```

Rust SimDevice/SoftIsland share the same-format execution contract. Python
Device and QEMU-UIO paths preserve discovered dtype masks; generic Torch/NumPy
paths preserve native bits. The existing virtual-card native-byte transport,
generic TensorFlow dispatch and non-S8 multi-tile streaming remain open; they
must refuse unsupported paths rather than cast data to INT8. PyO3 compilation
uses a supported interpreter; Python 3.14 is newer than the pinned PyO3 release's
supported range and is not bypassed with a forward-compatibility override.

### 12.3 Exact scalar floating RTL boundary

`corev_apu/ai_island/g6lc_ai_fp_mac.sv` and `include/g6lc_ai_fp_pkg.sv` implement
an `AiCfg.IslandFpEn`-gated scalar operation:

```text
result = RNE(RNE(exact_widen(A) * exact_widen(B)) + acc_fp32)
```

The widening preserves finite values, subnormals and signed zero; the E4M3 maximum
exponent remains finite except for its NaN encoding. The arithmetic reuses the
existing FPnew FP32 unit as **separate MUL and ADD operations**. Results are held
under backpressure; reset, flush and disable cancel in-flight work. Local
NV/DZ/OF/UF/NX flags are outputs, not unsolicited updates to a hart's CSRs.
The original integer reducer is unchanged.

The gate defaults off and requires MatrixEn, a T2 queue, RVF and RVD in
`check_cfg`. It does not expand the island's format grants. Floating loaders,
byte gathering, scalar-result integration into the GEMM sequencer, output-memory
handling and integrated grant/negative tests must land before F2–F5 are complete
at **island** level.

Measured isolated scalar timing:

| FP pipeline registers | Acceptance to visible result | Scalar initiation interval |
|---|---:|---:|
| 1 | 4 cycles | 6 cycles |
| 2 | 6 cycles | 8 cycles |
| 3 (default) | 8 cycles | 10 cycles |
| 5 | 12 cycles | 14 cycles |

These are RTL measurements at the primitive interface, not estimates of a clock
frequency. The default is **one scalar MAC per ten cycles**, not the 64–256
floating operations/cycle hypothesized by the policy resource profile. A future
multi-output scheduler must measure replication/interleaving, storage and
arithmetic ordering before reusing those throughput assumptions.

Each variant checks 141,587 widening probes and approximately 40,000 scalar
transactions, including the two-rounding/FMA discriminator, flags, subnormals,
signed zeros, cancellation and response stalls. Ordered dot sequences are driven
externally in K order. The released SHL-0.51 LZC source is used; no vendor source
or repository waiver is rewritten. Strict first-party lint is checked before
code generation; only the existing, hashed vendor FPnew compatibility baseline
from `verilator_config.vlt` and the Makefile is used, with first-party negative
controls proving it does not hide new RTL errors.

### 12.4 Reproduction and remaining closure

```text
python verif/regress/ai-native-eval.py --binary <built-g6lc-qemu> --replay-policy
bun build-platform/src/cli/index.ts test ai-native-eval
bun build-platform/src/cli/index.ts test ai-fp-mac
bun build-platform/src/cli/index.ts test ai-desc-formats
python verif/regress/ai-fp-mac.py --synth-only --yosys <existing-yosys> --formal all
```

The native binary must match the host running the Python adapter. On Windows the
build-platform's default WSL regression engine needs the Linux binary built with
the existing Linux toolchain, while direct Windows Python uses the `.exe`.
The host adapter emits a **non-compiled discovery manifest** of the real island
sources: the ordinary core-only flist does not include the throughput island.

The initial cross-package run verifies the same 84 requests under both contracts:
**16 execute / 68 reject** against live grants, **82 execute / 2 reject** against
the software fixture. C32 bytes, packed descriptors and native samples match;
only successful jobs enter the policy trace. Seventeen negative checks per
contract cover malformed data, layout disagreement and unsafe trace assertions.
Outputs and source hashes are retained in unique directories under
`build-platform/workspace/build/ai-native-eval-*`.
The registered WSL `ai-native-eval` gate was rerun with the rebuilt Linux binary:
`ai-native-eval-20260905T040500Z-1d4e625d85c4/summary.json` is PASS with the same
84-job results and negative checks. That run is host-only; the earlier
`ai-native-eval-20260905T025618Z-5ab2c5772ab6/summary.json` also contains remote
policy replay. Do not merge their scopes or treat a successful proxy dispatch as
simulation evidence without checking the collected result report.

Actual B1 guest/QEMU execution, full floating GEMM, multi-format array rates,
physical bank/accumulator pressure, timing/DFT and whole-core compliance remain
separate gates. Neither a fast B3 software result nor an isolated FP primitive
completes those integration obligations.

## Open first

| Layer | Path |
|---|---|
| Scaffold contract | `../README.md` |
| Scaling to 100 TOPS | `scaling-100tops.md` |
| Transport | `../uncore/pcie-endpoint.md` |
| Accelerator seam prior art | `../ara-vector-attach.md` · `agents/guides/AGENTS-vector.md` |
| SoC envelope | `../stream8-class.md` · `AGENTS-configuration.md` |
| SoC readiness | `agents/guides/AGENTS-soc-readiness.md` |
| Licensing | `AGENTS-licensing.md` · `LICENSE.GSys-Commercial` §3.7/§4.5 · `.licensing-tiers` |
