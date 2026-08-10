# Extension point: AI matrix acceleration (`Xg6lcai`)

**Status:** scaffold (P0) · **Code prefix:** `g6lc_ai` / `Xg6lcai` · **Licensing:** tier **R** (open, dual-licensed — §7)

Feature-domain extension point for INT8 matrix acceleration on LibreCore, targeting a PCIe
**CPU+AI card**: real application-class cores and a matrix engine sharing one address space, running
Linux locally, reachable over IPv6-over-PCIe. Read `../README.md` (scaffold contract) and
`../../AGENTS.md` §0 first. Transport side: `../uncore/pcie-endpoint.md`.

**Frozen interface contract: [`isa-encoding.md`](isa-encoding.md)** — opcodes, operand classes, CSR
addresses, trap rules and the T2 descriptor ABI. It is normative for **both** seam options and must
not diverge between them (§2.2). §5 below is a summary; that document is the source of truth.

**Host ML backend (separate package):** [`../../ai-tensor/AGENTS.md`](../../ai-tensor/AGENTS.md) —
PyTorch / TensorFlow attachment to this contract and to live `corev_apu/ai_island`. Architecture
cross-connect and version pins: [`../../ai-tensor/architecture/VERSIONING.md`](../../ai-tensor/architecture/VERSIONING.md).
Not on any flist; does not replace this scaffold.

**Scaling plan of record: [`scaling-100tops.md`](scaling-100tops.md)** — what changes when the target
is the 100-TOPS class rather than 1–5 TOPS. It supplies the bandwidth-first sizing model, the
core-attached/island plane split (§1.1 below), the SKU question that is still open, and the island
track I0–I4 (§8). Read it before sizing anything.

> **Scaffold contract.** Nothing in this file is compiled. No path here is referenced by
> `core/Flist.cva6`, any `verif/` flist, or any `pd/` script. This document *reserves* seams and
> records decisions; it moves no RTL.

## Table of contents
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
| **I1** | **one** island cluster: PE array, `tc_sram` banks, sequencer, capability window. Freezes `T`, accumulator geometry, DRAM class and the NoC cut line **for both SKUs**. **Landed (partial):** AccTile*=256 / PeLanes=128 multi-bank C + I3-lite dual-write B + multi-beat AR + PMU BW; full Macs/NoC/DRAM open | P3 |
| **I3** | memory system sized to the §4 model; measured bandwidth | I1 |
| — | **latency SKU tapes out** (1–2 clusters, ~12–25 TOPS) | I3, I4 |
| **I2** | NoC + N clusters + per-cluster gating + QoS arbitration | I3 |
| **I4** | floorplan, UPF domains, thermal cap loop, STA | I1, re-run after I2 |

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
