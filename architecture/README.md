# CVA6 architecture scaffold — extension points for future growth

This tree is a **scaffold and blueprint**, not RTL. It exists so that the *preconditions* for larger
development — more branch prediction, deeper speculative execution, multi-threading (SMT), multi-core,
an L2/L3 cache hierarchy, and further RISC-V spec features — are organized, discoverable, and ready to
grow into, **without touching working silicon today**.

> ### Scaffold contract (read first)
> - **Nothing here is compiled.** No file under `architecture/` is referenced by `core/Flist.cva6`,
>   `core/Flist.cva6_gate`, any `verif/` flist, or any synthesis / `pd/` script. Adding or removing a
>   file here **cannot** break elaboration, simulation, synthesis, or the tape-out flow.
> - **No existing RTL was moved.** The real, shipping hierarchy remains exactly where it is under
>   `core/`, `corev_apu/`, `core/include/`. This directory *describes and reserves* where future work
>   lands; it does not relocate current work. (Physically relocating RTL was explicitly deferred — see
>   "Promotion path" below.)
> - **`.md` only.** Documentation follows its tier (`DOCS_UNDER_TIER`); `architecture/**` is tier T
>   (MIT) and carries no inline SPDX header, and these READMEs change no code contract.
> - **One exception to "docs decide nothing":** `ai-matrix/README.md` §7 records a licensing tier
>   decision. It closed on the **open path** — the AI plane is tier **R**, dual-licensed like the rest
>   of the LibreCore delta — so it blocks no file creation. It is recorded there because a *different*
>   answer would have been irreversible once published.

---

## Why a scaffold instead of a refactor

`AGENTS.md` §0 (the SoC / tape-out prime directive) and §0.3 (cost-driver anti-patterns) are explicit:
CVA6 is silicon IP, and *"breaking module boundaries"* / churning the hierarchy *"kills timing closure
and floorplanning."* A blind directory refactor of a core that is elaborated by explicit flists,
synthesized, and taped out is a top-tier anti-pattern. The malleability the project wants is therefore
delivered the safe way: a **navigable map of extension points** plus a **documented target layout and
migration plan**, so a future feature has an obvious, low-friction home and a checklist to enter the
build cleanly — while the current build stays byte-for-byte intact.

Each subdirectory is a **feature-domain extension point**. Its `README.md` states, in one page: the
growth intent, the sanctioned integration seam, the current code loci it hooks into, the `CVA6Cfg`
knobs it extends, the spec anchors it must respect, and the SoC-readiness gates it must pass. They
deliberately **do not restate** the feature guides in `agents/guides/` — they point to them.

---

## Map of extension points

| Directory | Growth axis | Nature | Primary guide |
|---|---|---|---|
| `branch-prediction/` | More / smarter predictors (gshare, TAGE, loop, indirect) | Microarchitectural, in-core | `agents/guides/AGENTS-branch-prediction.md` |
| `speculative-execution/` | **FSE** deep window + recovery plan (`full-speculation-architecture.md`, `UPDATE-PLAN.md`); `DeepSpecEn` S1 | Microarchitectural, in-core | `agents/guides/AGENTS-speculation.md` |
| `out-of-order/` | Slice-OoO (MLP) then full rename/ROB/LSQ multi-issue OoO | Microarchitectural, in-core | `agents/guides/AGENTS-speculation.md` + `router-core-upgrade-program.md` |
| `core-fetch/` | Instruction supply: frozen A = `core/frontend` + `core/smt` pkg/dbg; default B = `core/fetch_B/`; g1\* oracle in `core/smt_legacy/` | Microarchitectural, in-core | `firmware-boot-principles.md`, `core-fetch/SPEC.md` |
| `multi-threading/` | Simultaneous multithreading (hart-state replication) | New micro-arch (green-field) | `agents/guides/AGENTS-soc-readiness.md` |
| `multi-core/` | Multi-hart tiles, coherence, interrupt scaling | SoC integration | `agents/guides/AGENTS-l2l3-cache.md`, `-soc-readiness.md` |
| `l2-l3-cache/` | Memory-side L2 / SoC L3 (LLC) | SoC integration (not an L1 edit) | `agents/guides/AGENTS-l2l3-cache.md` |
| `spec-extensions/` | Further RISC-V ISA features (V, Zvk, Sv57, CFI, …) | Spec-anchored | `agents/spec/INDEX.md` + relevant guide |
| `ai-matrix/` | INT8 matrix acceleration (`Xg6lcai`) for a PCIe CPU+AI card | **Live P1–P3 / I1 partial** — CVXIF plane + `ai_island` T2; next **I3 BW → I2 clusters** | `ai-matrix/README.md` §0 progress table + `hard-tests.md` + `scaling-100tops.md` + `frameworks-virt-pcie.md` + `uncore/pcie-endpoint.md` |
| `sv-timing/` | Structural FO4 precompile package pointer (host = build-platform `timings`) | Tooling / host adapter | `sv-timing/AGENTS.md`, `AGENTS-host.md` |
| `ai-tensor/` (package at repo root) | PyTorch/TensorFlow **backend** for `Xg6lcai` / `ai_island` (host software; not RTL) | **Live** soft virt-card + HARD virt-impl | `ai-tensor/AGENTS.md`; `tensor virt-impl --impl hard --suite narrow` |

Host **workspace lifecycle** (granular `clean`, cache-like diag/formal/timings outs, `--from-timing` soak hand-off) is documented in [`build-platform-workspace-lifecycle.md`](build-platform-workspace-lifecycle.md) — not an RTL extension point; still scaffold-only (no flist).

---

## Programs of record

| Document | Scope |
|---|---|
| `build-platform-workspace-lifecycle.md` | **Host plan:** granular `cva6-build clean` (purpose/age) + `--from-timing` validate/consume for soaks/diag/sim; workspace artifact taxonomy. |
| `build-platform-opensta-from-timing.md` | **Host plan:** precompiled timings packages → SDC seeds → Yosys/OpenSTA/OpenROAD validation + FO4↔STA correlate loop (S0–S5). |
| `router-core-upgrade-program.md` | Active 8-upgrade program (perf/W-ranked). **Progress ~U6.2 partial:** U1–U4, multi-issue, U7ᵃ/ᵇ, U6.0–U6.1, U6.2 multi-core 1–8 hub; H + AVX-like sequenced in `remaining-upgrade-sequence.md`; U5 remain. |
| `remaining-upgrade-sequence.md` | Post-U6 queue: multi-core, H/Sstc, U10, Ara, **U5 OoO + L3/PF** |
| `out-of-order/README.md` | U4 slice + **U5.0–U5.2** status |
| `l2-l3-cache/README.md` | L2 done; **L3 + server prefetcher** |
| `ai-matrix/scaling-100tops.md` | **Sizing plan:** frozen TOPS definition, bandwidth-first model (`BW = 2/T × MAC-rate`), core-attached vs island plane split, chiplet deferral gate. **SKU decided (AI-S1): both, staged** — latency SKU first (I1→I3), throughput SKU by cluster replication (I2), one memory system serving both. |
| `ai-matrix/hard-tests.md` | **HARD / directed ELF map:** narrow\|smoke\|ci\|peak surfaces, green results, I0–I4 coverage vs clustering next step. |
| `ai-matrix/frameworks-virt-pcie.md` | Host multi-phase: soft virt-ai-pcie → SV HARD → optional `--from-timing`. |
| `ara-vector-attach.md` | U10ᵇ Ara/RVV flist + `server_math_v` package contract |
| `firmware-boot-principles.md` | Handoff then fetch-as-A: I1–I28, peels/P1–P4 for capabilities |
| `core-fetch/` | Fetch spec; frozen A is `core/frontend`; workspace B is `core/fetch_B` |
| `multi-threading/smt2-bringup.md` | U6.1 SMT2 enable + dual-thread Linux/OpenSBI checklist |
| `multi-threading/soft-ladder/` | Evidence (tag `g1-archive`). A/`smt_legacy` soak notes; **`CONTRACT.md`** envelopes |
| `server-math-hypervisor.md` | U9/U10 detail: vstimecmp, server config, RVV enable order |
| `Architecture-research-todo-drafts.md` | Earlier research roadmap that the program above refines for a power-bound target. |

## Live RTL summary (not scaffold)

| Area | Where it lives | Default |
|------|----------------|---------|
| U1 prediction fabric | `core/frontend/` (compiled) + copies in `core/fetch_B/` (not on flist) | TAGE_LITE on primary 64b target |
| U2 FTQ / FDIP / loop buffer | `core/frontend/` | On primary 64b target |
| Fetch oracle (`smt_legacy`) | `core/smt_legacy/` + `g6lc_{present,sib_cjalr,…}` | opt-in `Flist.smt_legacy` |
| Fetch frozen A / workspace B | A: `core/frontend` + `core/smt` pkg/dbg; B: `core/fetch_B/` + `Flist.fetch_B` | default B; pin R4 FDT walk / R6–R11 |
| U3 way-pred / RRIP | `core/cache_subsystem/g6lc_way_predictor.sv`, `g6lc_rrip_repl.sv`, hpdcache | Target-dependent |
| U4 slice-OoO | `core/cva6_slice_*.sv` | **Off** (`SliceOoOEn=0`) |
| U5 full OoO | `core/ooo/*` | **Production gated** (`OoOEn`; identity when 0) |
| Multi-issue 2–8 | config `NrIssuePorts` + issue/ID/EX | Auto 1 or 2 from `SuperscalarEn` |
| U6.0 L2 | `corev_apu/l2_cache/` | **Off** (`L2En=0`) |
| U7ᵃ/U7ᵇ ISA | decoder / csr / MMU / store | Primary enables most; Zicbom needs HPDCACHE |

---

## Proposed target layout (blueprint — NOT yet applied)

Today `core/` is a flat directory of ~50 `.sv` files plus a few subfolders (`frontend/`,
`cache_subsystem/`, `cva6_mmu/`, `pmp/`). As the feature set grows, a **grouped-by-pipeline-stage**
layout scales better for navigation, floorplanning, and ownership. The table below is the *proposed*
target; it is a plan of record, applied only if/when the project chooses the "relocate RTL" escalation.

| Proposed group | Would contain (today's files) | New room for |
|---|---|---|
| `core/frontend/` | `frontend.sv`, `bht*.sv`, `btb.sv`, `ras.sv`, `instr_*` | `frontend/prediction/` (new predictors) |
| `core/decode/` | `decoder.sv`, `compressed_decoder.sv`, `macro_decoder.sv`, `zcmt_decoder.sv` | new ISA decoders |
| `core/issue/` | `issue_stage.sv`, `issue_read_operands.sv`, `scoreboard.sv`, `raw_checker.sv` | wider issue |
| `core/execute/` | `ex_stage.sv`, `alu*.sv`, `mult*.sv`, `serdiv.sv`, `branch_unit.sv`, `fpu_wrap.sv`, `aes.sv`, `cvxif_fu.sv` | `execute/speculation/`, new FUs |
| `core/commit/` | `commit_stage.sv`, `controller.sv`, `csr_buffer.sv` | precise-trap widening |
| `core/mem/` | `load_store_unit.sv`, `load_unit.sv`, `store_unit.sv`, `store_buffer.sv`, `amo_buffer.sv`, `lsu_bypass.sv` | memory speculation |
| `core/cache/` | `cache_subsystem/` | `cache/l2/`, `cache/coherence/` |
| `core/mmu/`, `core/pmp/` | `cva6_mmu/`, `pmp/` | more `Sv*` modes |
| `core/csr/` | `csr_regfile.sv`, `perf_counters.sv`, `trigger_module.sv` | new CSR groups |
| `core/smt/` | `g6lc_fetch_{pkg,dbg}` only (supply copies removed) | fetch A package; banks live in `core/smt_legacy/` |
| `core/multicore/` *(new)* | — | tile wrapper, coherence hub |
| `core/ooo/` *(new)* | — | slice queues, rename/ROB/IQ/LSQ |
| `core/rvfi/` | `cva6_rvfi*.sv` | trace for new features |

A migration would be **mechanical but wide**: it renames paths in `core/Flist.cva6`,
`core/Flist.cva6_gate`, every `verif/` flist, `pd/` synthesis file lists, and any `` `include`` search
paths — with a full re-elaboration + regression + gate-level check per `AGENTS.md` §0.2. It is
intentionally **out of scope** for this scaffold pass.

---

## Promotion path — turning a scaffold dir into real RTL

When a feature graduates from "planned" to "implemented", it leaves this tree and enters `core/` (or
`corev_apu/`) through a sanctioned seam. The steps are the union of the relevant `agents/guides/*`
playbook and the `AGENTS.md` §0.2 carry-over checklist:

1. **Config-gate it** in `core/include/config_pkg.sv` (`cva6_cfg_t` + `check_cfg` legality) and the
   per-target packages — the feature must be optional so minimal configs still elaborate.
2. **Implement** the module(s) in the real `core/` location behind a `generate` gated on the new knob,
   at the sanctioned seam (CVXIF for custom compute; `tech_cells_generic` for arrays/gating; the
   memory-side AXI boundary for L2/L3).
3. **Register** the new files in `core/Flist.cva6` (and gate flist / `verif/` flists as needed).
4. **Verify + test**: add a directed test and a build-platform suite (see `AGENTS-specs-to-tests.md`),
   keep the compliance regression green, update formal/coverage, thread DFT (`test_en_i`/`testmode_i`).
5. **Observe**: add RVFI/trace, a debug trigger where relevant, and a PMU event.
6. **Document**: update the relevant `agents/guides/*`, `AGENTS-specs-to-impl.md`, and re-derive
   `AGENTS-specs-coverage.md`; record area/power/timing impact per `AGENTS-coding-philosophy.md`.

---

## How this ties into the rest of the repo

- **Feature playbooks**: `agents/guides/AGENTS-*.md` — the *how* for each domain.
- **Spec anchors**: `agents/spec/INDEX.md` + `agents/spec/*.html` — the *what the ISA requires*.
- **Spec ↔ RTL map**: `AGENTS-specs-to-impl.md` (repo root) — kept current on every `.sv` change.
- **Spec ↔ tests map**: `AGENTS-specs-to-tests.md` (repo root) — kept current on every suite change.
- **Coverage summary**: `AGENTS-specs-coverage.md` (repo root) — derived status, no file refs.
- **Build / test orchestration**: `build-platform/` (run `bun` from `build-platform/`) — the single entry point that
  provisions the toolchain and runs the suites those docs reference.
- **Structural timing**: `sv-timing/` (standalone package) + optional host
  `cva6-build timings` — see `sv-timing/AGENTS.md` and monorepo pointer
  `architecture/sv-timing/`.
- **Human docs**: `docs/website/` (Next.js site) mirrors worktree + build-platform +
  sv-timing; Sphinx under `docs/01_…` remains for classic manuals.
