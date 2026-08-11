<div align="center">

# GSys LibreCore

**A source-available, Linux-capable RISC-V application-class processor — and the agentic build platform that carries it from core to silicon.**

[![RTL: CERN-OHL-S-2.0](https://img.shields.io/badge/RTL-CERN--OHL--S--2.0-0a6b7c?style=flat-square)](LICENSE.CERN-OHL-S)
[![Tooling: MIT](https://img.shields.io/badge/tooling-MIT-0a6b7c?style=flat-square)](LICENSE.MIT)
[![Commercial licence](https://img.shields.io/badge/commercial_licence-available-cb007b?style=flat-square)](LICENSE.GSys-Commercial)
[![Derived from CVA6](https://img.shields.io/badge/derived_from-OpenHW_CVA6-666?style=flat-square)](docs/heritage.md)

[Licensing](#licensing) · [Quick start](#quick-start) · [What's in the core](#what-is-in-the-core) ·
[Build platform](#the-build-platform) · [Commercial licence](#commercial-licence--contact) ·
[Contributing](#contributing) · [Heritage](docs/heritage.md)

</div>

---

**GSys LibreCore** (shorthand **LibreCore**, code prefix **`G6LC`**) is a 6-stage RISC-V core that
boots Linux, with an optional out-of-order backend, coarse-grain SMT, TAGE-class branch prediction,
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
> [`remaining-upgrade-sequence.md`](architecture/remaining-upgrade-sequence.md)):
>
> | Plane | Status | Docs |
> |---|---|---|
> | **Branch prediction (U1)** | **Landed** — TAGE_LITE fabric (`g6lc_bp_*`), gshare/loop/ITTAGE/statcor/ckpt; primary 64b target; further growth (full TAGE-SC, multi-level BTB) open | [`branch-prediction/`](architecture/branch-prediction/) |
> | **Speculative execution (FSE)** | **S0–S6 landed** — `DeepSpecEn` depth plane, SpeculativeSb cancel, BP ckpt restore, younger LSU cancel, SMT same-hart cancel, `spec-deep-tests`; default packages stay shallow | [`speculative-execution/`](architecture/speculative-execution/) |
> | **Multi-issue** | **Live** — `SuperscalarEn` / `NrIssuePorts` 1–8 (auto 1 or 2); dual-issue production path; wider issue on OoO server packages | issue/ID/EX + config |
> | **Slice-OoO (U4) / full OoO (U5)** | U4 **off** by default (`SliceOoOEn=0`); U5 **production-gated** (`OoOEn`) — rename/ROB/IQ/LSQ/PRF/memdep, cancel-mask recovery; `g6lc64_ooo` + `g6lc64_ooo_server` | [`out-of-order/`](architecture/out-of-order/) |
> | **SMT (U6.1)** | **Fine-grain live** — dual PC/CSR/RF/RAS/GHR banks, hybrid thread select; default `NrHarts=1` identity; OpenSBI dual-issue soft-ladder residuals remain | [`multi-threading/`](architecture/multi-threading/) |
> | **Multi-core (U6.2)** | **Live** — `NrCores` 1…8, `g6lc_cluster`, coherence hub, scaled CLINT/PLIC; L1 inv adapters | [`multi-core/`](architecture/multi-core/) |
> | **L2 / L3 / stream PF** | L2 **done**; L3 + server multi-stream prefetcher **done (config-gated)**; inclusive back-inval live | [`l2-l3-cache/`](architecture/l2-l3-cache/) |
> | **Stream plane** | **Stream8 class green** — `g6lc64_stream8`, `mc-spo-veri` 9/9, AMOCAS W/D/Q, H-edge 3/3; optional suite (not default CI) | [`stream8-class.md`](architecture/stream8-class.md) |
> | **AI matrix / island (`Xg6lcai`)** | **P1–P3 / I1 partial live** — CVXIF + `ai_island` T2 @ `0x4000_0000`, AccTile 256, CPL FIFO, HARD narrow/ci/peak green; **ai-tensor** soft virt-ai-pcie + `tensor virt-impl` soft→HARD; **next I3 BW measure → I2 clustering** | [`ai-matrix/`](architecture/ai-matrix/) · [`hard-tests.md`](architecture/ai-matrix/hard-tests.md) |
>
> Defaults keep **netlist identity** for small targets: `OoOEn=0`, `SliceOoOEn=0`,
> `NrHarts=1`, `L2En=0` / `L3En=0`, `DeepSpecEn=0`, `AiMatrixEn=0`. Production profiles opt in via
> `g6lc64_{smt2,ooo,ooo_server,server_math,stream8,ai}_config_pkg.sv`.
>
> **Toward production-ready (honest estimate, not a tape-out gate):**
>
> | Scope | ~% | What “100%” means |
> |---|---:|---|
> | **Config-gated RTL planes above** (BP + FSE + multi-issue + OoO + SMT + multi-core + L2/L3/stream) | **~75%** | Features present, identity-safe off, directed/optional suites green on primary packages |
> | **Full product / ship readiness** (default CI on advanced packages, DI OpenSBI soft-ladder retired, full Linux image handoff, Ara cosim, STA/FO4 lab, publication/ID registers) | **~55–60%** | Partner could take an advanced config to silicon without known open residuals |
>
> The ~15–20 point gap is mostly **verification depth & software residuals** (soft-ladder
> freelist / dual-`c.mv` / FDT; full Linux R3b; RVV live cosim; default-on advanced CI),
> not missing microarchitecture scaffolds. Router program detail:
> [`router-core-upgrade-program.md`](architecture/router-core-upgrade-program.md).
>
> Publication blockers — counsel review of the commercial licence and CLAs, trademark clearance, and
> the JEDEC/RISC-V-International identification registers — are tracked openly in
> [`AGENTS-todo.md`](AGENTS-todo.md). Do not tape out against this tree without reading them.

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

Royalties are payable to Etienne Cimon; commercial relationships are administered through
**GlobecSys Inc. ("GSys")**. See [Commercial licence & contact](#commercial-licence--contact).

### Three things stated up front

Because you would otherwise discover them the hard way:

1. **~37% of the product surface is still upstream-sized.** Comparing **tracked blob sizes** of
   `origin/master` against this tree on the claim surface only —
   **RTL SystemVerilog under `core/` + `corev_apu/`**, plus **`sv-timing/`**, **`build-platform/`**,
   and **`docs/website/`** (no logs, no gitignored workspace, no whole-repo noise):

   | Slice | `origin/master` | HEAD | origin ÷ HEAD |
   |---|---:|---:|---:|
   | **Claim surface** (RTL SV + `sv-timing/` + `build-platform/` + `docs/website/`) | 2.54 MiB / 197 files | 6.85 MiB / 826 files | **~37%** |
   | RTL SV alone (`core/` + `corev_apu/` `*.sv`/`*.svh`/`*.v`/`*.vh`) | 2.54 MiB / 197 files | 3.08 MiB / 263 files | ~82% |

   So **~63% of that surface is LibreCore growth** — almost all of it `sv-timing/`,
   `build-platform/`, and `docs/website/`, which have **no** `origin/master` counterpart. The
   remaining **~37%** is upstream CVA6/Ariane material (ETH Zurich, University of Bologna, Thales
   DIS, CEA, Univ. Grenoble Alpes/Inria/TIMA, OpenHW Group, SiFive, lowRISC, PlanV, PULP Platform,
   UC Regents) under permissive Solderpad/Apache/BSD terms. **You already hold that upstream
   material for free, from its authors** — the commercial licence does not sell it
   ([`LICENSE.GSys-Commercial` §4.2](LICENSE.GSys-Commercial)). What is purchased is the LibreCore
   delta. (RTL-only, the same method is still ~82% origin-sized — useful for auditors who only
   care about the processor tree.) Recompute with `python3 monorepo-soak/size-claim-scopes.py`.
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
git clone --recurse-submodules <this-repo>
cd librecore

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
| **Coarse-grain SMT** | `core/smt/` — per-hart state, CSR and PC banks, register file, thread select |
| **Branch prediction** | `core/frontend/g6lc_bp_*` — TAGE, ITTAGE, gshare, loop predictor, statistical corrector, checkpointing; plus FTQ, FDIP and a loop buffer |
| **Caches** | way prediction, RRIP/DRRIP replacement, HPDcache victim selection |
| **Coherent uncore** | `corev_apu/{coherence,l2_cache,l3_cache}/` — coherence hub, snoop filter, LR/SC tracker, invalidation bus, L2, inclusive L3, server prefetcher |
| **Vector** | Ara RVV attach at the accelerator boundary (`g6lc_ara_attach`) |
| **ISA extensions** | Zba/Zbb/Zbs, Zicbom/Zicboz, Zacas, hypervisor (H), Sstc |

Profiles are selected by config package — `core/include/g6lc64_{smt2,ooo,ooo_server,server_math,server_math_v}_config_pkg.sv`
— alongside the upstream `cv{32,64}a6*` targets, which are unchanged.

A performance model lives in `perf-model/`. Ecosystem pointers: [`RESOURCES.md`](RESOURCES.md).

<img src="docs/03_cva6_design/_static/ariane_overview.drawio.png"/>

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
| **Static timing** | `g6lc-build timings` (Rust analyser in `sv-timing/`) | [`sv-timing/AGENTS.md`](sv-timing/AGENTS.md) |
| **Select / build a board** | `g6lc-build mb list` → `mb select <id>` | [`AGENTS-motherboard.md`](AGENTS-motherboard.md) |
| **Bring in uncore IP** | `g6lc-build vendor list` → `vendor sync <id>` | [`AGENTS-vendor.md`](AGENTS-vendor.md) |
| **Adapt to a foundry** | `g6lc-build tech status \| plan \| check` | [`AGENTS-technology.md`](AGENTS-technology.md) |

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

Also use these channels for CLA submission, trademark questions, and security reports.

> Royalties are payable to **Etienne Cimon**. Commercial relationships are administered through
> **GlobecSys Inc. (GSys)**; the contracting entity and structure are at the rights holder's
> discretion and are fixed in the executed agreement.
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
`g6lc-build diag run`. Full detail in [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Repository layout

| Path | Contents |
|---|---|
| `core/` | the CPU IP — pipeline, frontend, `ooo/`, `smt/`, caches, MMU, `include/` config packages |
| `corev_apu/` | SoC / uncore — coherence, L2/L3, CLINT/PLIC, FPGA platform, bootrom, testbench |
| `build-platform/` | the Bun + TypeScript build platform (MIT) |
| `sv-timing/` | Rust static-timing analyser (MIT) |
| `corev-mb/` | motherboard layer around the die |
| `verif/` | verification — `regress/` suites, `tb/`, `tests/`, `core-v-verif/` (vendored) |
| `software/` | OpenSBI / Linux reference software and payloads |
| `vendor/` | vendored third-party IP (Ara, PULP tech cells, …) |
| `architecture/` | design notes and non-compiled scaffolding |
| `agents/`, `AGENTS*.md` | the agent-facing guide layer |
| `docs/`, `tutorials/` | documentation, including [`docs/heritage.md`](docs/heritage.md) |

Files and directories under `core/` are for the core **only** and must not depend on the APU.

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
