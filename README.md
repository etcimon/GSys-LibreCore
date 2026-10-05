<div align="center">

# GSys LibreCore

**A source-available, Linux-capable RISC-V application-class processor — and the agentic build platform that carries it from core to silicon.**

<img src="superprocessor.jpg" alt="GSys LibreCore — artistic rendering of a RISC-V processor die" width="760"/>

[![RTL: CERN-OHL-S-2.0](https://img.shields.io/badge/RTL-CERN--OHL--S--2.0-0a6b7c?style=flat-square)](LICENSE.CERN-OHL-S)
[![Tooling: MIT](https://img.shields.io/badge/tooling-MIT-0a6b7c?style=flat-square)](LICENSE.MIT)
[![Commercial licence](https://img.shields.io/badge/commercial_licence-available-cb007b?style=flat-square)](LICENSE.GSys-Commercial)
[![Derived from CVA6](https://img.shields.io/badge/derived_from-OpenHW_CVA6-666?style=flat-square)](docs/heritage.md)
[![Docs](https://img.shields.io/github/actions/workflow/status/etcimon/GSys-LibreCore/deploy-docs.yml?branch=master&label=docs&style=flat-square)](https://etcimon.github.io/GSys-LibreCore/)

**Repository:** [github.com/etcimon/GSys-LibreCore](https://github.com/etcimon/GSys-LibreCore) ·
**Documentation:** [etcimon.github.io/GSys-LibreCore](https://etcimon.github.io/GSys-LibreCore/)

[Licensing](#licensing) · [Quick start](#quick-start) · [What's in the core](#what-is-in-the-core) ·
[Build platform](#the-build-platform) · [Commercial licence](#commercial-licence--contact) ·
[Contributing](#contributing) · [Heritage](docs/heritage.md)

</div>

---

**GSys LibreCore** (shorthand **LibreCore**, code prefix **`G6LC`**) is a 6-stage RISC-V core that
boots Linux, with an optional out-of-order backend, two-thread SMT2, TAGE-class branch prediction,
and a coherent multi-core L2/L3 uncore. It is a derivative of the
[OpenHW Group CVA6](https://github.com/openhwgroup/cva6), itself descended from the PULP Platform
*Ariane* core from ETH Zurich and the University of Bologna.

It ships with an unusual amount of surrounding machinery: a self-contained **Bun + TypeScript build
platform** that provisions its own toolchain and drives lint, formal, simulation, regression, board
bring-up, vendored uncore IP and foundry/PDK adaptation from one typed control surface; a **Rust
static-timing analyser** (`sv-timing/`); and a layered set of `AGENTS*.md` guides that make every
level of the stack legible to an AI agent.

> **Status.** Active development, pre-release. The core boots Linux under OpenSBI in simulation.
>
> **Architecture / performance-plane readiness** (plan of record under
> [`architecture/`](architecture/), especially
> [`architecture/README.md`](architecture/README.md) live RTL summary +
> [`remaining-upgrade-sequence.md`](architecture/remaining-upgrade-sequence.md)).
> Evidence tiers: **leaf** — the unit compiles and its directed tests pass;
> **gate** — leaf evidence plus a clean isolated lint/synthesis archive gate;
> **integration** — the feature composes with its neighbours in a directed
> multi-block testbench; **boot** — a pre-silicon boot milestone is green;
> **deferred** — tracked, not done. Tiers name the evidence scope actually
> obtained; they are not a readiness percentage.
>
> | Plane | Tier | Status | Docs |
> |---|---|---|---|
> | **Branch prediction (U1/U2)** | gate | **Landed** — TAGE_LITE fabric (`g6lc_bp_*`), gshare/loop/ITTAGE/statcor/ckpt, FTQ/FDIP/loop buffer; primary 64b target; further growth (full TAGE-SC, multi-level BTB) open; no STA yet | [`branch-prediction/`](architecture/branch-prediction/) |
> | **Speculative execution (FSE)** | integration | **S0–S6 landed** — `DeepSpecEn` depth plane, SpeculativeSb cancel, BP ckpt restore, younger LSU cancel, SMT same-hart cancel, `spec-deep-tests`; default packages stay shallow | [`speculative-execution/`](architecture/speculative-execution/) |
> | **Multi-issue** | gate | **Live** — `SuperscalarEn` / `NrIssuePorts` 1–8 (auto 1 or 2); dual-issue production path; wider issue on OoO server packages | issue/ID/EX + config |
> | **Full OoO backend (`OoOEn`)** | gate | U4 `SliceOoOEn` off by default; U5 **live** — rename/ROB/IQ/LSQ/PRF/memdep, cancel-mask recovery; `g6lc64_ooo_int` is the bring-up/verification baseline, `g6lc64_ooo_int2` is a legal target at the M1d ring-8 window while `g6lc64_smt2_ooo_int`/`g6lc64_ooo_int2_l3` adopted the deterministic ring-16 window (`NrScoreboardEntries=16`, `BPCkptDepth` 16 — T10d/N1b; the M3 ring-32/TAGE/FTQ uplift was measured and not adopted — T9f); T9g/M4 lifted the FP guard for single-hart and drained-handoff OoO — `g6lc64_ooo` is legal single-hart FP and `g6lc64_ooo_int2_l3` is RV64GC+B — while `g6lc64_ooo_server` stays an opt-in/unqualified target (mixed-residency FP and `COH_FILTERED` legs) | [`out-of-order/`](architecture/out-of-order/) |
> | **SMT2 over OoO (`NrHarts=2`)** | boot | **Mixed residency production** on `g6lc64_smt2_ooo_int` (T9d/M2 — probe matrix, isolation mutations, drained-overlay exactness and strict boots re-baselined on the eWT tree; T10d/N1b adopted ring 16 — mixed boot PASS 10,459,588 cycles and the FO4 screen closes at 31.0 — while the T9f/M3 ring-32 window bundle stays off); in-order `g6lc64_smt2` runs the drain-friendly fine-grain switch; multi-core mixed residency stays qualification-gated (`G6LC_OOO_SMT_MIXED_QUALIFY`) and `int2`/`int2_l3` keep the drained handoff; OpenSBI dual-issue soft-ladder residuals remain | [`multi-threading/`](architecture/multi-threading/) |
> | **OoO coherence (`COH_OOO`)** | integration | Promoted 2026-09-24 for the `g6lc64_ooo_int2` envelope (2 WT cores × 2 harts, L2, no L3): SRAM sharer-signature filter, hub response ownership/ordering repairs, accepted-physical-address load validation through retirement; the composed hub + real-L2 bench excludes the stale-refill counterexample; same-id R ordering guard, local AMO/CAS apply-event coverage, PMU group-2 events, credit-consistent L2 MSHR depth and the signature-SRAM DFT plan followed. Post-boot repairs (2026-09-25): writers acquire signature presence, WT repair copies are invalidation-bounded, NC ACKs stay out of the repair queue, CLINT MSIP read lanes fixed — the directed cross-core shared-line and four-hart boot/release programs pass in the isolated two-core route. Deferred: matched multicore firmware/compliance runs, in-order WT re-runs, foundry macro/MBIST insertion, STA/power/area — [`AGENTS-todo.md`](AGENTS-todo.md) | [`core/ooo/AGENTS-ooo-contract.md`](core/ooo/AGENTS-ooo-contract.md) · [`multi-core/`](architecture/multi-core/) |
> | **Multi-core cluster / L2 / L3** | boot | `NrCores` 1…8, `g6lc_cluster`, coherence hub, scaled CLINT/PLIC, L1 inv adapters; L2 done (concurrent fills, hit-under-miss merging, killed-fill retention, OoO-gated write fairness); L3 + server stream prefetcher config-gated. 2026-09-26: WT cores now allocate in the L2 (`WtAxiAllocEn` — the shim was modifiable-only, measured 0 hits before), inclusion is a package policy (`L3InclusiveEn`), tags can live behind `tc_sram` (`L2TagSramEn`), and the non-inclusive-L3 packages `g6lc64_ooo_int2_l3` / `g6lc64_smt2_l3` pass their strict SMT2 OpenSBI boots. 2026-09-27: `L2WriteUpdateEn` merges an eligible write-through into a resident L2/L3 line instead of purging it — boot L2 misses ~103k→~1.5k, strict boots 17,993,674 / 18,244,344 / 13,814,448 cycles, latency-40 boots −11.5 % / −13.2 % with the first boot-workload `l3_hit`; disabled packages stay bit-identical. M1a adds end-to-end CBO: a `cmo_*` core sideband + `g6lc_cmo_engine` broadcast/match-invalidate L1/L2/L3 for `cbo.inval` (the old WT decode hung the store buffer), `clean`/`flush` gate on the L2/L3 write-idle trackers, `cbo.zero` drains as a commit-queue burst; allocation/write-update/CMO are now on for every eWT package (smt2/smt2_ooo_int anchors re-baselined) and `CohMaxOutstanding` is measured at 8 on the int2 packages. 2026-09-28: `L2PostedWriteEn` posts writes and bypass reads through L2/L3 trackers — hits and misses are served while writes drain (B still comes from memory, routed per-id), `wr_stall` on the mixed credits burst is 0 at OT8, and the L40 write/read kernel drops to 518,507/543,093 cycles. M1d then puts every postable write on one reserved downstream write id `WR_ID`, so AXI same-id ordering preserves the merge order and the different-id same-line AW hold (the measured ~100 % of posted-write holds) disappears for posted-vs-posted pairs. 2026-09-29: M5 adds a demand-miss-trained L2 stream/stride prefetcher (`L2PrefetchEn`) — scan/write-read kernels gain 8–13 %, pointer chase is neutral, but both strict boots pay ~+0.3 %, so it ships **off** pending a burst-throttling policy | [`multi-core/`](architecture/multi-core/) · [`l2-l3-cache/`](architecture/l2-l3-cache/) |
> | **Stream8** | leaf | `g6lc64_stream8`, `mc-spo-veri` 9/9, AMOCAS W/D/Q, H-edge 3/3; optional suite (not default CI) | [`stream8-class.md`](architecture/stream8-class.md) |
> | **AI island (`Xg6lcai`)** | integration | **FP island shipped on `g6lc64_ai`** (2026-09-30: seven formats INT8/INT4/FP8×2/FP16/BF16/FP32, 512 MAC/cycle, flat-panel byte-capacity banks, two-slot VA-Turbo residency, accumulate mode, wide C store); measured on the SoC model: decode `1×512×512` INT8 cold 34,136 cycles / resident 590 (57×), B stream at 1.00 cycles/beat; scaling ladder V1 wide port (leaf 60.4 B/cycle, SoC point owed) → V2 column array (RTL, OutCols 1/2/4 verified) → V3/V4 `g6lc_ai_cluster_dispatch` (RTL + island-top elaboration, leaf-verified; nameplates 49/98 TOPS are **derived**); bounded formal on the flat-panel arithmetic; oracle-controlled SoC suite; `g6lc64_smt2_ai` two-hart AI package runs the AI subset; **island on any package** (2026-10-01): `+define+G6LC_AI_OVERLAY` or a generated `<pkg>_ai` pin, coherent outputs by construction (`AiCfg.DmaInvalEn` -> CMO writer port, CAP `0xA0`), every core enqueues (arbiter + island ticket stream), CVXIF at the commit head under OoO -- leaves + mutations green, SoC discriminators queued; **ai-tensor** PyTorch/Diffusers backend with qualified INT8/BF16 recipes and a calibrated cost model | [`ai-matrix/`](architecture/ai-matrix/) · [`scaling-100tops.md`](architecture/ai-matrix/scaling-100tops.md) · [`log-2026-09.md`](architecture/ai-matrix/log-2026-09.md) |
>
> Defaults keep **netlist identity** for small targets: `OoOEn=0`, `SliceOoOEn=0`,
> `NrHarts=1`, `L2En=0` / `L3En=0`, `DeepSpecEn=0`, `AiMatrixEn=0`. Profiles opt in via
> `g6lc64_{smt2,smt2_ooo_int,ooo_int,ooo_int2,server_math,server_math_v,stream8,ai}_config_pkg.sv`;
> `g6lc64_ooo` (single-hart FP) and `g6lc64_ooo_int2_l3` (drained multi-hart FP) are
> `check_cfg`-legal since T9g/M4; `g6lc64_ooo_server` and FP under mixed residency
> stay refused/opt-in (`G6LC_OOO_FP_QUALIFY` leg). Remaining verification depth and software
> residuals (soft-ladder freelist / dual-`c.mv` / FDT; full Linux handoff; RVV live cosim;
> default-on advanced CI) are tracked in the router program:
> [`router-core-upgrade-program.md`](architecture/router-core-upgrade-program.md).
>
> Publication blockers — counsel review of the commercial licence and CLAs, trademark clearance, and
> the JEDEC/RISC-V-International identification registers — are tracked openly in
> [`AGENTS-todo.md`](AGENTS-todo.md). Do not tape out against this tree without reading them.

---

## Start here (new contributors)

1. **[`AGENTS.md`](AGENTS.md) §0** — tier boundaries, governance, and the
   SoC-readiness checklist every change must satisfy.
2. **[`AGENTS-coding-philosophy.md`](AGENTS-coding-philosophy.md)** — the
   engineering rules the RTL follows: correctness before performance, config
   gating, reset/clock discipline, verification parity.
3. **The layer guide for your area:**
   - OoO / coherence — [`core/ooo/AGENTS-ooo-contract.md`](core/ooo/AGENTS-ooo-contract.md)
     (the contract), then [`core/ooo/AGENTS-ooo-plan.md`](core/ooo/AGENTS-ooo-plan.md)
     (the working plan).
   - SMT2 / OpenSBI — the reasoning guides under
     [`architecture/multi-threading/`](architecture/multi-threading/).
   - Timing — [`sv-timing/AGENTS.md`](sv-timing/AGENTS.md), then
     [`sv-timing/ALGORITHMS-EXPERTS.md`](sv-timing/ALGORITHMS-EXPERTS.md).
   - Measured optimizations — [`AGENTS-optimization-tool.md`](AGENTS-optimization-tool.md).
   - Tooling — [`build-platform/AGENTS.md`](build-platform/AGENTS.md).
4. **Traceability files** — [`AGENTS-specs-to-impl.md`](AGENTS-specs-to-impl.md)
   and [`AGENTS-dts-validation.md`](AGENTS-dts-validation.md) record which spec
   chapter and device-tree node each ISA-visible change answers to.
5. **[`AGENTS-todo.md`](AGENTS-todo.md)** — the deferred-obligation ledger:
   what is knowingly not done, and what evidence would close it.

---

## Licensing

LibreCore is **dual-licensed**, and the split is deliberate.

### The open path — free, royalty-free, forever

The RTL is offered under the **[CERN Open Hardware Licence v2 — Strongly Reciprocal](LICENSE.CERN-OHL-S)**
(`CERN-OHL-S-2.0`). You may use, study, modify, simulate, prototype on FPGA and tape out, at no
charge and with a royalty-free patent grant (§7.1). There is one condition, and it bites only when
you **ship a Product**:

> Your recipients either receive the **Complete Source**, or are told where to find it (§4), and your
> modifications stay under the same licence (§3.3(d)).

**That is the point: the delivered processor is inspectable.** Unlike software copyleft, CERN-OHL-S
§1.5 defines a "Product" to include physical objects, so reciprocity reaches the die and the
bitstream — not just the RTL.

Things people expect to be encumbered and are not:

- **Private development is entirely unencumbered.** §4's obligations run to *recipients*; there is
  no recipient until you Convey. Internal simulation, FPGA bring-up and silicon exploration owe
  nothing.
- **Contractors are covered.** §5 lets you hand source or products to design houses, verification
  vendors and DFT/backend teams working on your behalf under confidentiality.
- **No registration, no notification, no fee.** Forking and complying requires nobody's permission.

Tooling, build platform, timing analysis, documentation, verification scripting and reference
software are plain **[MIT](LICENSE.MIT)**.

### The commercial path — when reciprocity does not work

If you cannot satisfy §4 — most commonly because you integrate **proprietary soft IP** on the same
die (CERN-OHL-S §1.7(b)(i) requires an "Available Component" to be a *physical part*, so closed RTL
falls inside the Complete Source you would have to publish), or because a **foundry NDA** forbids
publishing your PDK adaptation — a royalty-bearing **[GSys Commercial License](LICENSE.GSys-Commercial)**
is available. It also carries the warranty and IP indemnification that CERN-OHL-S §6 explicitly
disclaims.

Royalties are payable to Etienne Cimon, who owns the **GSys** brand (**not** a
trademark). Commercial relationships are administered through **Multimedia
Protection Inc.**, the contracting entity. **GlobecSys Inc.** is a separate
corporation and is not the contracting entity. See [Commercial licence & contact](#commercial-licence--contact).

### Three things stated up front

Because you would otherwise discover them the hard way:

1. **~25% of the product surface is still upstream-sized.** Comparing **tracked blob sizes** of
   upstream `openhw/master` against this tree on the claim surface only —
   **RTL SystemVerilog under `core/` + `corev_apu/`**, plus **`sv-timing/`**, **`build-platform/`**,
   and **`docs/website/`** (no logs, no gitignored workspace, no whole-repo noise). Measured
   2026-09 via `git ls-tree -r -l` on the claim surface, against `openhw/master` `a962460e`:

   | Slice | `openhw/master` | HEAD | upstream ÷ HEAD |
   |---|---:|---:|---:|
   | **Claim surface** (RTL SV + `sv-timing/` + `build-platform/` + `docs/website/`) | 2.54 MiB / 197 files | 10.33 MiB / 942 files | **~25%** |
   | RTL SV alone (`core/` + `corev_apu/` `*.sv`/`*.svh`/`*.v`/`*.vh`) | 2.54 MiB / 197 files | 6.45 MiB / 585 files | ~39% |

   So **~75% of that surface is LibreCore growth** — almost all of it `sv-timing/`,
   `build-platform/`, and `docs/website/`, which have **no** upstream counterpart. The
   remaining **~25%** is upstream CVA6/Ariane material (ETH Zurich, University of Bologna, Thales
   DIS, CEA, Univ. Grenoble Alpes/Inria/TIMA, OpenHW Group, SiFive, lowRISC, PlanV, PULP Platform,
   UC Regents) under permissive Solderpad/Apache/BSD terms. **You already hold that upstream
   material for free, from its authors** — the commercial licence does not sell it
   ([`LICENSE.GSys-Commercial` §4.2](LICENSE.GSys-Commercial)). What is purchased is the LibreCore
   delta. (RTL-only, the same method is still ~39% upstream-sized — useful for auditors who only
   care about the processor tree.)
2. **Reciprocity binds the LibreCore delta only.** Upstream CVA6 stays permissive and can always be
   fetched pristine from `openhwgroup/cva6`.
3. **Two files we could have claimed, we didn't.** `core/include/ariane_pkg.sv` (+39 lines in 806)
   and `corev_apu/clint/clint.sv` (+8 in 264) carry LibreCore modifications too small to justify
   relicensing someone else's file. They remain wholly under ETH Zurich's Solderpad licence. The
   measurements are in [`AGENTS-licensing.md`](AGENTS-licensing.md).

### Per-file map

Licensing is **tier-directed**: every file resolves to a tier via
[`.licensing-tiers`](.licensing-tiers), governed by [`AGENTS-licensing.md`](AGENTS-licensing.md),
with machine-readable provenance in [`REUSE.toml`](REUSE.toml).

| Tier | Contents | Licence |
|---|---|---|
| **R** | LibreCore-original RTL + reference device trees | `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` |
| **T** | build platform, `sv-timing`, verification scripting, docs, reference software | `MIT` |
| **U** | upstream / third-party material — **unchanged, verbatim** | Solderpad, Apache-2.0, BSD-3-Clause |
| **F** | FPGA zero-stage bootrom — a **separate GPL work**, excluded from both LibreCore licences | `GPL-2.0-or-later` |

Also: [`NOTICE`](NOTICE) (Source Location + the product-marking requirement) ·
[`TRADEMARKS.md`](TRADEMARKS.md) (the GSys die mark, granted as a badge of compliance) ·
[`docs/heritage.md`](docs/heritage.md) (lineage and attribution).

---

## Quick start

The build platform installs its own toolchain. You need `git` and a shell; it fetches Bun itself.

```sh
git clone --recurse-submodules https://github.com/etcimon/GSys-LibreCore.git
cd GSys-LibreCore

source ./setenv.sh          # Windows PowerShell:   . .\setenv.ps1
g6lc-build status           # SoC target + toolchain + workspace, at a glance
```

`g6lc-build` is the brand-forward name; **`cva6-build` remains a permanent equivalent alias**, since
it is baked into the agent guides, verification scripts and CI.

```sh
g6lc-build probe            # full host capability matrix + install playbook (installs nothing)
g6lc-build tools install sim   # provision Verilator, Spike, Icarus, RISC-V GCC into workspace/
g6lc-build diag run         # fast compartmentalised gates (lint/paths/caps)
g6lc-build verify           # the real gate: lint sweep + formal + sim + synth smoke
g6lc-build test --open-source   # every suite runnable on the open-source toolchain
```

Everything installed or produced lands under `build-platform/workspace/` (gitignored). Nothing is
written outside the repo.

The wrappers also work with no shell setup: `./build.sh test --list` (Windows: `.\build.ps1 test --list`).

### Remote gates

`g6lc-build verify --lint --synth --remote --target <pkg>` regenerates the
isolated gate scripts `build-platform/workspace/build/remote/remote-{lint,synth}.sh`;
`python verif/regress/remote/run_ooo_coherence_gate.py --root . --prepare <zip>`
captures an isolated source snapshot into an archive; and
`g6lc-build remote py -- <runner> --tag <tag> ...` executes it on the remote
test harness and pulls artifacts back. Remote runs are isolated uploads — the
shared mirror is never rsynced.

### Booting Linux under OpenSBI

```sh
g6lc-build tools install dual-hart      # RISC-V GCC + OpenSBI (SMT2 dual-hart)
bash verif/regress/opensbi-linux-boot.sh    # functional boot gate (Spike)
bash verif/regress/smt-linux-r3-cosim.sh    # RTL co-simulation boot (needs Verilator; Linux/WSL)
```

The manual (non-build-platform) flow described in [`tutorials/`](tutorials/) remains fully supported.

---

## What is in the core

Baseline: a 6-stage, single-issue, in-order RV64 core implementing I, M, A, C with M/S/U privilege
levels, separate TLBs, a hardware PTW, branch prediction and external debug — enough to boot a
Unix-like OS. It has configurable size, and the original design goal was short critical paths.

LibreCore adds, all **config-gated and optional** so minimal targets still elaborate:

| Area | What |
|---|---|
| **Out-of-order backend** | `core/ooo/` — ROB, RAT, physical register file, freelist, issue queue, LSQ, memory-dependence predictor, rename/dispatch; 2- and 4-issue profiles, cancel-mask mispredict recovery |
| **SMT** | `core/smt/` — SMT2: two hardware threads (`NrHarts`) per core with per-hart PC/CSR/RF/RAS/GHR banks and a drain-friendly fine-grain switch (`SmtPolicy` RR / switch-on-miss / hybrid); on OoO profiles residency switches by drained handoff or mixed residency — **mixed is production** on single-core `g6lc64_smt2_ooo_int`, multi-core stays qualification-gated |
| **Branch prediction** | `core/frontend/g6lc_bp_*` — TAGE, ITTAGE, gshare, loop predictor, statistical corrector, checkpointing; plus FTQ, FDIP and a loop buffer |
| **Caches** | way prediction, RRIP/DRRIP replacement, HPDcache victim selection |
| **Coherent uncore** | `corev_apu/{coherence,l2_cache,l3_cache}/` — coherence hub, LR/SC tracker, invalidation bus, L2, inclusive L3, server prefetcher; four `coh_policy_t` policies — `COH_WRITE_INVAL`, `COH_BROADCAST`, `COH_FILTERED` (tagged snoop filter, default when `NrCores>1`), `COH_OOO` (SRAM-backed signature filter for the OoO fabric) |
| **OoO coherence** | `COH_OOO` — the load tag/check stage exports the accepted physical address with its TID/hart/size; the LSQ keeps that record until retirement and replays a not-yet-retired load whose line was modified by a remote core, a sibling hart or a local committed store, through the existing precise cancel path (PMA non-idempotent loads never replay) |
| **Vector** | Ara RVV attach at the accelerator boundary (`g6lc_ara_attach`) |
| **ISA extensions** | Zba/Zbb/Zbs, Zicbom/Zicboz, Zacas, hypervisor (H), Sstc |

Profiles are selected by config package — alongside the unchanged upstream
`cv{32,64}a6*` targets, `core/include/` carries the LibreCore set:
`g6lc64_smt2` (in-order SMT2), `g6lc64_ooo_int` (single-hart integer OoO
bring-up/verification baseline), `g6lc64_smt2_ooo_int` (SMT2 over the integer
OoO backend, mixed residency), `g6lc64_ooo_int2` (two WT cores with an allocating
L2 and `COH_OOO`), `g6lc64_ooo_int2_l3` and `g6lc64_smt2_l3` (the same two shapes
plus a non-inclusive 1 MiB L3 with SRAM-backed tags; qualification-only),
`g6lc64_server_math` (in-order H+Sstc math/KVM host with HPDCACHE
and L2), `g6lc64_server_math_v` (the same plus RVV through the Ara attach),
`g6lc64_stream8` (stream8 class), `g6lc64_stream8_l3` and
`g6lc64_server_math_l3` (the two in-order packages plus the same
non-inclusive 1 MiB L3; M6),
`g6lc64_ai` (Xg6lcai AI island), and
`g6lc64_ooo` / `g6lc64_ooo_server` — FP-on-OoO packages: `g6lc64_ooo` is legal
single-hart FP since T9g/M4, `g6lc64_ooo_server` remains opt-in/unqualified.

A performance model lives in `perf-model/`. Ecosystem pointers: [`RESOURCES.md`](RESOURCES.md).

<img src="docs/03_cva6_design/_static/ariane_overview.drawio.png"/>

---

## AI optimization path and current status

The AI-island optimization work treats runtime decisions as a **compressed policy
codec**, not a learned profiler. Shape buckets, opcode class, native sparsity
samples, continuity and compute/movement balance select one of eight 3-bit
codewords. Hysteresis and feature-signature silence limit reevaluation; current
and successor decodes provide tile/dataflow/prefetch choices and discardable
address/bank hints. Skipping still requires an independent exact-zero proof.

| Layer | Current status (2026-10-01) | Evidence boundary |
|---|---|---|
| T2 GEMM (`g6lc64_ai`) | **FP island shipped**: INT8, INT4, FP8 E4M3/E5M2, FP16, BF16, FP32 (grant `0x00FB`, SP24 refused); 512 lanes; flat-panel byte-capacity banks (A 2 / B 1 / C 2 MiB); two-slot resident-B directory; accumulate mode; intra-row trail + wide C store | Verilator SoC model of the built geometry (cycles, not timing): `1×512×512` INT8 cold 34,136 / resident 590; `1×768×512` two panels both resident (39×); 8-lane bench 226 records seven formats, both float pipes |
| Scaling ladder | V1 wide port plumbing (join upsizer, 512-bit channel; leaf: 60.4 B/cycle island stream); V2 `OutCols` column array (RTL, 1/2/4 verified, island gate strict lint 0); V3/V4 `g6lc_ai_cluster_dispatch` (RTL, island top elaborates Clusters 1/2/4, 2- and 4-cluster C bit-identical to the single engine) | V1 SoC point not yet measured; V2 measured on the bench only; V3/V4 leaf only — 16.4 / 49.2 / 98.3 TOPS are **nameplates**, decode stays bytes-bound |
| Verification | oracle controls (`ai_must_pass`/`ai_must_fail`, `ORACLE INVALID`), bounded formal on the flat-panel/stripe/slot arithmetic (mutation fails), C1–C4 run-time contracts, directed leaves per lever, `+ai_pmu_trace` records | a pass is positive evidence only with the controls in the run; remote runs serialized one harness at a time |
| SMT2 + AI | `g6lc64_smt2_ai` (two harts, dual issue, per-hart AI banks) builds; `ai_dot4`/`mma`/queue/MMIO smokes pass; two-hart bench `HARTS=1` control: 4 decode jobs, 135,931 wall cycles (33,872 each); DTS ready; strict boot admitted | boot not run (~24 h at the FP-island model's ~140 cycles/s); `HARTS=2` rerun owed (ELF queue-1 region fixed); sideband `ai.enq` hang on the two-hart core under triage |
| Island on any configuration | `+define+G6LC_AI_OVERLAY[_INT]` splices `config_pkg::AiCfgIsland` + CVXIF into any package; pinned `g6lc64_{ooo_int2_l3,stream8_l3,smt2_ooo_int}_ai` packages + DTS (drift-tested); `AiCfg.DmaInvalEn` invalidates every island write through the CMO engine after its B and holds completion until done (`CAP_OFF_COH`); `g6lc_ai_enq_arb` + island-allocated tickets; CVXIF issues only at the commit head under OoO; `IslandFpEn` no longer needs RVF/RVD | L0 lint sweep + SoC-top lint clean; leaves with oracle negatives and RTL mutations PASS (`ai-matrix-directed` 226/3/1, the 3 are pre-existing LiteDRAM-wrap items); SoC `ai_coh_stale`/`ai_mc_enq`/OoO AI subset **not yet run**, DMA-invalidation cost unmeasured |
| Host software (`ai-tensor`) | PyTorch `AiTensorLinear`/`Conv2d` + Diffusers; qualified recipes (LLM INT8 g128 + FP16 head; UNet INT8 g64 or BF16); `cost_model` calibrated on the measured points; QEMU B1 contract emulator boots OpenSBI and passes the queue smoke | virtual evidence (PSNR/perplexity, bytes), never RTL timing |
| Policy codec / benefit steering | Isolated, verified RTL; off in production | control decisions, not throughput |

The balanced LLM/diffusion-shaped **scheduling fixtures** report modeled time
reductions of **38.24% at SRAM128** and **3.55% at SRAM512** against their matched
baseline. Per-format/state usage, negative results and the slightly better
retrospective fixed-code comparison are retained. These figures are neither
measured MAC/s nor a benchmark of a real LLM or diffusion model.

`IslandFpEn` is **on** for `g6lc64_ai` since 2026-09-30 (the core-side T0 tile stays INT8);
`PolicyCodecEn`/`PolicyBenefitEn` and `VaTurboEn` remain off in production. Open on the
ladder: the V1 SoC measurement, full-geometry synthesis of a cluster SKU, cross-job B
prefetch (designed), the strict `g6lc64_smt2_ai` boot, and the SoC runs of the coherence /
multi-core / OoO discriminators on a clean remote model. Every ladder figure is derived
from measured per-beat/per-issue costs until a SoC point exists at that geometry; PDK
timing, DFT/ATPG and full-SoC compliance remain separate gates.

Start with the [scaling note](architecture/ai-matrix/scaling-100tops.md) (the 100-TOPS
definition, the plane split and the batch-1 trap), the running
[log](architecture/ai-matrix/log-2026-09.md) (every measured/derived/void result with its
instrument), the [island status](corev_apu/ai_island/README.md),
[ai-tensor](ai-tensor/README.md), the [B3 evaluation](g6lc_qemu/README.md#native-tensor-evaluation-and-optimization),
and the docs-site page [AI Island](https://etcimon.github.io/GSys-LibreCore/corev-apu/ai-island).
Local checks in minutes: `test ai-ops-bench` (8-lane bench, seven formats), `test ai-scale-ladder`,
`verify --formal` (flat-panel proof), `verif/regress/ai-matrix-directed.sh`; SoC runs use the
remote proxy with the oracle controls in the suite.

---

## The build platform

More than a CPU: this repository is the anchor of an **agentic-first, build-platform-led flow** that
carries a RISC-V design from *core* to *finished product* — CPU ⇄ uncore ⇄ motherboard ⇄ foundry.

A self-contained Bun + TypeScript platform ([`build-platform/`](build-platform/)) is the spine. One
typed control surface ([`.config.ts`](.config.ts)) parameterises the whole SoC; one command drives
every layer. It has **zero runtime dependencies** and works on Windows, Linux and macOS.

| Layer | Command | Guide |
|---|---|---|
| **Develop the CPU** | `g6lc-build verify` / `test` / `diag run` | [`AGENTS.md`](AGENTS.md) |
| **Static timing** | `g6lc-build timings` (Rust analyser in `sv-timing/`; FO4 estimates only — see [`sv-timing/ALGORITHMS-EXPERTS.md`](sv-timing/ALGORITHMS-EXPERTS.md)) | [`sv-timing/AGENTS.md`](sv-timing/AGENTS.md) |
| **Remote test harness** | `g6lc-build remote py -- <runner>` (isolated upload + artifact pull) | [`verif/regress/remote/`](verif/regress/remote/) |
| **Select / build a board** | `g6lc-build mb list` → `mb select <id>` | [`AGENTS-motherboard.md`](AGENTS-motherboard.md) |
| **Bring in uncore IP** | `g6lc-build vendor list` → `vendor sync <id>` | [`AGENTS-vendor.md`](AGENTS-vendor.md) |
| **Adapt to a foundry** | `g6lc-build tech status \| plan \| check` | [`AGENTS-technology.md`](AGENTS-technology.md) |

Full command set: `status`, `doctor`, `probe`, `diag`, `man`, `setup`, `tools`,
`vendor`, `mb`, `tech`, `build`, `test`, `verify`, `timings`, `tensor`, `clean`,
`config`, `remote`, `g6q`, `g6b` — the registry is
[`build-platform/src/cli/registry.ts`](build-platform/src/cli/registry.ts).

All of it is **opt-in and additive** — the defaults leave the classic CVA6 core and flow exactly as
they were. SoC / tape-out readiness is a first-class rule, not an afterthought: see
[`AGENTS.md` §0](AGENTS.md).

The `AGENTS*.md` layer is unusual and worth knowing about if you use AI tooling: it routes a question
like *"where does branch prediction live, in the spec and in the code?"* to a small set of spec
anchors and exact `file:line` loci instead of a whole-repository scan.

---

## Commercial licence & contact

**You do not need to contact anyone to use LibreCore.** The open path requires no registration, no
notification and no fee. Please don't buy something you already have — read
[`LICENSE.GSys-Commercial` §2](LICENSE.GSys-Commercial), which lists what the free licence already
gives you.

Get in touch if you want to ship closed silicon, keep your modifications private, need warranty and
IP indemnification, or want support and roadmap influence.

<div align="center">

### 💬 [**cimons.com**](https://cimons.com) — live chat

### ✉️ [**etcimon@globecsys.com**](mailto:etcimon@globecsys.com) — commercial licensing

</div>

When emailing about a commercial licence, it speeds things up considerably if you say:

- which LibreCore version or commit you are building from;
- whether you intend to **modify** the Covered Source, and roughly where;
- whether the Product will contain **proprietary soft IP** on the same die;
- your target process / foundry, and whether PDK adaptation is under NDA;
- expected volume and whether you need indemnification.

Also use these channels for CLA submission, naming questions, and security reports.

> Royalties are payable to **Etienne Cimon**, who owns the **GSys** brand (**not** a trademark).
> Commercial relationships are administered through **Multimedia Protection Inc.**, the
> contracting entity. **GlobecSys Inc.** is a separate corporation and is not the contracting
> entity. The structure of the executed agreement is otherwise at the rights holder's discretion.
> [`LICENSE.GSys-Commercial`](LICENSE.GSys-Commercial) is an **offer document** — it grants nothing
> until a separate written agreement is signed, and it is pending counsel review
> ([`AGENTS-todo.md`](AGENTS-todo.md) B1).

---

## Contributing

**Most contributions need no paperwork.** The licensing split decides:

| You are changing | Licence | You sign |
|---|---|---|
| **Tooling, docs, verification scripting, reference software** (tier T) | MIT, inbound = outbound | **Nothing** — just `git commit -s` (DCO) |
| **RTL and reference device trees** (tier R) | `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` | A CLA — [`CLA/ICLA.md`](CLA/ICLA.md) or [`CLA/ECLA.md`](CLA/ECLA.md) |

The RTL needs a CLA because the commercial path cannot exist without the right to sublicense. We ask
for a **licence, not an assignment** — you keep your copyright — and §2.3 of the CLA binds us to keep
your contribution available under `CERN-OHL-S-2.0` forever. Your consideration is acknowledgement in
[`CONTRIBUTORS`](CONTRIBUTORS); there is no revenue share. That asymmetry is real, and
[`CONTRIBUTING.md` §2](CONTRIBUTING.md) states it plainly rather than leaving you to find out later.

Two hard rules when touching **upstream** files: never alter a copyright line, SPDX identifier or
attribution notice (retention is a *condition* of our licence — Apache-2.0 §4(c), Solderpad §4), and
prefer adding a new file over editing an upstream one. New code is named `g6lc_*`; see
[`AGENTS-branding.md`](AGENTS-branding.md).

Before opening a PR: read [`AGENTS.md` §0](AGENTS.md), then run `g6lc-build verify` and
`g6lc-build diag run`; for config-package changes also run the isolated archive gate
`g6lc-build verify --lint --synth --remote --target <pkg>`. Full detail in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Repository layout

| Path | Contents |
|---|---|
| `core/` | the CPU IP — pipeline, frontend, `ooo/`, `smt/`, caches, MMU, `include/` config packages |
| `corev_apu/` | SoC / uncore — coherence, L2/L3, CLINT/PLIC, FPGA platform, bootrom, testbench |
| `build-platform/` | the Bun + TypeScript build platform (MIT) |
| `sv-timing/` | Rust static-timing analyser (MIT) |
| `corev-mb/` | motherboard layer around the die |
| `verif/` | verification — `regress/` suites (incl. `regress/remote/` isolated harness runners), `tb/`, `tests/`, `core-v-verif/` (vendored) |
| `software/` | OpenSBI / Linux reference software and payloads |
| `vendor/` | vendored third-party IP (Ara, PULP tech cells, …) |
| `architecture/` | design notes and non-compiled scaffolding |
| `optimization/` | measured-optimization ledger — tasks and applied notes behind `AGENTS-optimization-tool.md` |
| `g6lc_bios/` | BIOS / boot firmware work |
| `g6lc_qemu/` | vendored QEMU snapshot and native tensor evaluation notes |
| `ai-tensor/` | AI tensor software experiments |
| `quantum_ai/` | quantum-AI bridge notes and code |
| `monorepo-soak/` | monorepo soak tests |
| `spyglass/` | Spyglass lint/CDC collateral |
| `pd/` | physical-design collateral and the `pd/pdk/` foundry drop-in seam (gitignored) |
| `tools/` | helper scripts and pinned tool sources (`spike`, `verilator-v5.008`) |
| `specs/` | hardware specification documents |
| `riscv-compilers/`, `riscv-dev/` | agentic bootstrap scaffolds for third-party submodules (see below) |
| `agents/`, `AGENTS*.md` | the agent-facing guide layer |
| `docs/`, `docs/website/`, `tutorials/` | documentation — [`docs/heritage.md`](docs/heritage.md) and the Next.js + Nextra docs site, published to [etcimon.github.io/GSys-LibreCore](https://etcimon.github.io/GSys-LibreCore/) by `.github/workflows/deploy-docs.yml` |

Files and directories under `core/` are for the core **only** and must not depend on the APU.

### Agentic bootstrap for submodules — `riscv-compilers/` and `riscv-dev/`

Two optional scaffolds let you drop a third-party project in as a git submodule and get an **agent-legible
development surface for it**: `riscv-compilers/` for compilers and toolchain components, `riscv-dev/` for
libraries and runtimes. An agent reads the checkout, writes architectural notes addressed to the next change —
loci, invariants, extension points, open questions — into `<submodule>/architecture/`, derives a self-contained
`AGENTS.md` family and queue beside them, and records the project's *own* build-and-test command as the gate for
"done". After that the submodule is developed through its own in-tree documents and the scaffold is out of the
picture.

By default nothing is committed: the surface is written into the checkout and left **untracked**, excluded
through the submodule's own local exclude file, so you can harness it privately without adding anything to that
project's history or to this repository. Advancing a project's **RISC-V support** — codegen, ABI, capability
detection, porting — is one supported use, engaged only when a submodule's recorded affinity or your prompt asks
for it; nothing is target-driven by default. Start at
[`riscv-compilers/README.md`](riscv-compilers/README.md) or [`riscv-dev/README.md`](riscv-dev/README.md), each
of which carries a ready-to-run promotion prompt.

---

## Tutorials

* **[Running Simulations](tutorials/running_sim.md)**
* **[ASIC Implementation](tutorials/asic.md)**
* **[FPGA Implementation and running an OS](tutorials/fpga.md)**
* **[Instruction Tracing](corev_apu/instr_tracing/README.md)**

---

## Acknowledgements

LibreCore exists because a large number of people published serious engineering work under licences
that permitted it: the **OpenHW Group**, **ETH Zurich** and the **University of Bologna** (the CVA6
and Ariane cores), **Thales DIS design services SAS**, **CEA** and **Univ. Grenoble Alpes / Inria /
TIMA Laboratory** (HPDcache), **PlanV Technologies**, the **PULP Platform**, **lowRISC**, **SiFive**,
and the **Regents of the University of California**. Full attribution is in [`NOTICE`](NOTICE) §4 and
in the files themselves.

"CVA6", "CORE-V" and "OpenHW" are marks of the OpenHW Group; "RISC-V" is a registered trademark of
RISC-V International. No affiliation or endorsement is claimed — see
[`TRADEMARKS.md`](TRADEMARKS.md) and [`docs/heritage.md`](docs/heritage.md).
