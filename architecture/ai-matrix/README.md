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
core-attached/island plane split (§1.1 below), the SKU question that is still open, and the island
track I0–I4 (§8). Read it before sizing anything.

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
| **I1-lite INT8 GEMM** AccTile/PeLanes **256** | island compute | **Live (lite)** | **HARD** gemm_s8 1067 cy; 256³ ~83.7k cy peak |
| **PMU / CAP geometry** | CAP + PMU windows | **Live** | cap/bw_pmu smokes |
| **I3-lite bus** (trail C-store, multi-out AR, …) | island fabric | **Live** | scale gemm + PMU |
| **NoC width 64b** | island | **Floor (live)** | wider NoC deferred |
| **I2 multi-cluster / NoC/QoS** | island package | **Not started** | F8 present/enabled + bitmap published; still measure I3 BW first |
| **I3 full memory bandwidth model** | DRAM/channels | **I3-lite live; DRAM I3 opt-in** | class 0, 8 GB/s, N=1, Cas=0 default; SoC `master[DRAM]` shared with cores/L2; opt-in class-1 N=1/2/4/8 and class-0 `SIM_CHANS_{2,4,8}`; GEMM class-1 N=8 **1162 cy** wide all-NCH occupancy; 400 is class 2 |
| **PCIe EP + virtio (P5)** | uncore | **Virtual only** | `virt-ai-pcie` TCP + EDK2 GPEX RC witness; transport **unpinned** |
| **ai-tensor host** sim/SoftIsland/virt-card | `ai-tensor/` | **Live** | golden + queue/event-fd soaks |
| **PyTorch soft path** | `torch_ops` + virt-card | **Live** | `test_torch_virt_ai_island` (torch optional) |
| **soft→HARD virt-impl** | build-platform `tensor` | **Live** | `virt-impl --impl hard --suite narrow` **PASS** |
| **Kernel UIO/eventfd** | Linux driver | **Open** | contract in board-uio-eventfd |
| **I4 PD / UPF / thermal** | backend | **Open** | — |

**Next program step (scaling):** freeze AccTile/`T`/CAP; **measure I3 bandwidth** against
`scaling-100tops.md` §4 (F13 writeback, not input-only `2/T`) on the **shared** DRAM slave
(cores already use it; do not make `DramChannels` island-private); then **I2 cluster
replication** without regressing narrow/ci HARD on the single-cluster path. Do not wait on
KVM, full OoO, or a pinned PCIe BAR. Design asks: [`../../g6lc_qemu/architecture/RTL_FEEDBACK.md`](../../g6lc_qemu/architecture/RTL_FEEDBACK.md)
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
| **I1** | **one** island cluster: PE array, `tc_sram` banks, sequencer, capability window. Freezes `T`, accumulator geometry, DRAM class and the NoC cut line **for both SKUs**. **Landed (partial):** AccTile*=256 / PeLanes=256 + I3-lite bus + PMU + CPL FIFO; HARD narrow/ci/peak green; full PE/`tc_sram` density still open | P3 |
| **I3** | memory system sized to the §4 model; **measured** bandwidth (**next critical gate**) | I1 |
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

## 10. Frozen workload-policy codec compartment

**GSys LibreCore development scope:** `g6lc_ai_policy_codec` is an independently
verified control compartment, not a new accelerator datapath. RTL lives beside
T2 at `corev_apu/ai_island/`, not in a relocated `core/ai_island/`. Its gate is
`CVA6Cfg.AiCfg.PolicyCodecEn` in `core/include/config_pkg.sv`; `check_cfg` requires
`MatrixEn` and a nonzero queue count. All production packages default it off.
The compartment accepts the nested `AiCfg` parameter. Its dedicated verification
wrapper enables it; **the production island top does not instantiate it yet**.
Neither the existing GEMM traversal nor the descriptor ABI changes.

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
but not yet wired to island MMIO counters. Core RVFI/debug and `.dts`/ISA/Desc64
remain unchanged because the production datapath is untouched. Synthesis,
unbounded formal/coverage closure, physical scan, real consumer wiring, PMU
binding and measured area/power/timing remain promotion gates, not inferred from
a synthetic score. The existing open tier-R licence applies; verification tooling
is tier T. `config_pkg.sv` retains its upstream notices; no licensing tier,
security policy or compliance control was weakened.

### 10.5 Reproducible checks and feedback record

```text
bun build-platform/src/cli/index.ts test ai-policy-codec
wsl --exec python3 /mnt/e/cva6/verif/regress/ai-policy-codec.py --seed 123 --parameters default
python verif/regress/ai-policy-codec.py --synth-only --yosys <existing-yosys-executable>
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
