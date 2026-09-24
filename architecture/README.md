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
| `core-fetch/` | Instruction supply: frozen A = `core/frontend` + `core/smt` pkg/dbg; default B = `core/fetch_B/`; g1\* oracle in `core/smt_legacy/` | Microarchitectural, in-core | `firmware-boot-principles.md`, `core-fetch/SPEC.md`, `core-fetch/SMT-LEGACY.md` |
| `current-stage.md` | **WIP snapshot (2026-09):** SMT2 / QEMU firmware / 100 TOPS / PCIe stand-in vs OoO·H·RVV·stream, plus the graphics lane | Scaffold status only | this file · `uncore/apu-graphics.md` · `AGENTS-todo.md` Current phase |
| `multi-threading/` | Simultaneous multithreading (U6.1) | **Landed (fine-grain banks)**; QEMU virt/soc dual-hart OpenSBI/Linux **green** (not Variane evidence); live RTL gap is SL-C topology + R3b Image + product closeout | `agents/guides/AGENTS-soc-readiness.md` · **execution:** `multi-threading/testharness-proxy.md` · **snapshot:** `current-stage.md` |
| `multi-core/` | Multi-hart tiles, coherence, interrupt scaling. DRAM `DramChannels` is a **shared slave** under L2 (`uncore/dram-channel-scaling.md`), not a per-core port | SoC integration | `agents/guides/AGENTS-l2l3-cache.md`, `-soc-readiness.md` |
| `l2-l3-cache/` | Memory-side L2 / SoC L3 (LLC) | SoC integration (not an L1 edit) | `agents/guides/AGENTS-l2l3-cache.md` |
| `spec-extensions/` | Further RISC-V ISA features (V, Zvk, Sv57, CFI, …) | Spec-anchored | `agents/spec/INDEX.md` + relevant guide |
| `ai-matrix/` | INT8 matrix acceleration (`Xg6lcai`) for a PCIe CPU+AI card | **Live P1–P3 / I1-lite** (0.512 TOPS fixture @ 256 MAC/cycle×1 GHz); QEMU/EDK2 stand-in join, transport **unpinned**; next **I3 measure (shared DramChannels) → I2 clusters** (`RTL_FEEDBACK.md` F9–F14) | `ai-matrix/README.md` §0 + `hard-tests.md` + `scaling-100tops.md` + `uncore/dram-channel-scaling.md` + `current-stage.md` + `g6lc_qemu/architecture/RTL_FEEDBACK.md` |
| `sv-timing/` | Structural FO4 precompile package pointer (host = build-platform `timings`) | Tooling / host adapter | `sv-timing/AGENTS.md`, `AGENTS-host.md` |
| `g6lc-qemu/` | Generated emulation (stock-QEMU / QEMU C / native Rust) + SV diagnosis | **Q1–Q2 landed; Q3–Q9 in progress.** QEMU virt/soc OpenSBI+U-Boot+EDK2+OpenWrt **green** (hypothesis, never Variane evidence). AI push path = packed DESC + virt_ai_card; `ai_host_transport` unpinned | `g6lc-qemu/README.md` · `g6lc-qemu/staging.md` · `current-stage.md`; package `g6lc_qemu/AGENTS.md` |
| `g6lc-bios/` | S-mode BIOS rewrite of TempleOS/ZealOS specs; profiles embedded→full; kernel HTTP endpoints; OpenWrt/self flash; settings ± USB; Botan-spec TLS | **Setup page landed** (`9b5c140`): one shell document, live `http-serve` session, IP omitted from SNI. `g6b elf` / `g6b gr`. Never Variane evidence; no `-netdev`; no SvelteKit | `g6lc-bios/README.md`; `g6lc_bios/architecture/SETUP.md` · `PLAN.md` · `KERNEL-API.md` |
| `ai-tensor/` (package at repo root) | PyTorch/TensorFlow **backend** for `Xg6lcai` / `ai_island` (host software; not RTL) | **Live** soft virt-card + HARD virt-impl | `ai-tensor/AGENTS.md`; `tensor virt-impl --impl hard --suite narrow` |
| `uncore/apu-graphics.md` | Default-off graphics device: SoC box, private virtio prefix, lab surface, separate HDMI scanout | **Default `ApuOff`; testharness `ApuHarness`.** The ceiling is read back. The scene header and the 960-byte execbuffer are fetched. The DRAW_VBO at byte 908 is recognized and not executed. Its 24 NDC floats are read and not transformed. The viewport and the scissor are both the 640 by 480 rectangle. The clear color is `32'hFF1A0D0D` on one color buffer, surface 1. The vertex buffer is stride 24, offset 0, resource 3, from an inline write of 96 bytes. The fragment sampler view at byte 632 names handle 5. The sampler state at byte 616 names handle 6. The vertex elements at byte 608 name handle 4. The fragment shader at byte 596 names handle 3. The vertex shader at byte 584 names handle 2. The rasterizer bind at byte 576 names handle 9. The depth-stencil bind at byte 568 names handle 8. The blend bind at byte 560 names handle 7. The rasterizer object at byte 520 names handle 9. Its eight state words are 0. The depth-stencil object at byte 496 names handle 8. Its four state words are 0. The blend object at byte 448 names handle 7 and color word `32'h78020010`. The sampler-state object at byte 408 names handle 6, wrap word `32'h00002292`, and max LOD `32'h42000000`. The sampler view at byte 380 names handle 5, resource 1, format `32'h02000002`, and swizzle `32'h00000688`. The vertex-element object at byte 340 names handle 4, with format 31 at offset 0 and format 29 at offset 16. The fragment-shader object at byte 176 names handle 3. The vertex-shader object at byte 24 names handle 2. The surface object at byte 0 names handle 1, resource 4, and format 2. Guest descriptors at `64'h8800E100` link the header, the 960-byte execbuffer, and the 24-byte response. Avail index 1 at `64'h8800E200` names descriptor 0. The completed-opcode list at `64'h8800E300` is count 0 and capset id 0. The virgl capset stays refused. A 64 by 64 guest window at `64'h88020000` is 512 beats of clear word `32'hFF1A0D0D`. The guest response at `64'h8800A800` is `OK_NODATA` with fence `64'h1122334455667788`. The used element at `64'h8800E400` is descriptor 0 and length 24. The used index at `64'h8800E480` is 1. The used-buffer interrupt reason at `64'h8800E500` is `32'h1`. Ack lowers the pin. The guest ack at `64'h8800E510` is `32'h1`, and the status word at `64'h8800E500` is then `32'h0`. All 512 beats of the window are that clear word. That window is copied to `64'h88030000`, a 64 by 64 rectangle of 16384 bytes. `(1,0)` is byte 4 and row 1 starts at byte 256. The clear word sits in memory as the bytes 0D 0D 1A FF, so byte 0 is red. Row 1 at `64'h88030100` starts with that same red byte. `(1,1)` is byte 260, `(2,3)` is byte 776, and `(0,63)` is byte 16128. `(63,0)` is byte 252 at `64'h880300E0`. `(7,0)` is byte 28, lane 7 of `64'h88030000`. `(8,0)` is byte 32 and `(15,0)` is byte 60, both in `64'h88030020`. `(56,0)` is byte 224, lane 0 of `64'h880300E0`, and `(63,0)` stays byte 252, lane 7 of that beat. `(16,0)` is byte 64 and `(23,0)` is byte 92, both in `64'h88030040`. `(24,0)` is byte 96 and `(31,0)` is byte 124, both in `64'h88030060`. `(32,0)` is byte 128 and `(39,0)` is byte 156, both in `64'h88030080`. `(40,0)` is byte 160 and `(47,0)` is byte 188, both in `64'h880300A0`. `(48,0)` is byte 192 and `(55,0)` is byte 220, both in `64'h880300C0`. `(63,63)` is byte 16380, lane 7 of `64'h88033FE0`. The shader is not run. Neither shader is run. No framebuffer is painted. No blend is applied. No depth test is run. No triangle is walked. The shader is not run. No vertices are fetched. No texture is bound. Avail still rejects `NEXT`. A5 screenshot open. Command and surface units are untracked | `uncore/apu-graphics.md` · `uncore/README.md` · `uncore/hdmi-display.md` · `current-stage.md` |

Host **workspace lifecycle** (granular `clean`, cache-like diag/formal/timings outs, `--from-timing` soak hand-off) is documented in [`build-platform-workspace-lifecycle.md`](build-platform-workspace-lifecycle.md) — not an RTL extension point; still scaffold-only (no flist).

---

## Programs of record

| Document | Scope |
|---|---|
| `current-stage.md` | **WIP snapshot:** parallel change sets (SMT2, QEMU firmware, 100 TOPS island, PCIe stand-in, OoO/H/RVV/stream, graphics lane). |
| `uncore/apu-graphics.md` | **Graphics lane:** where the APU code sits, which execbuffer prefix is proven, gates A0–A7, and why a private decoder is not the screenshot. |
| `g6lc-qemu/README.md` | **Host plan:** `g6lc_qemu` generator — configs ⇄ flists ⇄ DTS → four emulation backends + D1 tandem / D2 uarch. Q0–Q9 in `g6lc-qemu/staging.md`. **Never evidence** (see `multi-threading/testharness-proxy.md`). |
| `build-platform-workspace-lifecycle.md` | **Host plan:** granular `cva6-build clean` (purpose/age) + `--from-timing` validate/consume for soaks/diag/sim; workspace artifact taxonomy. |
| `build-platform-opensta-from-timing.md` | **Host plan:** precompiled timings packages → SDC seeds → Yosys/OpenSTA/OpenROAD validation + FO4↔STA correlate loop (S0–S5). |
| `router-core-upgrade-program.md` | Active 8-upgrade program (perf/W-ranked). **U1–U4, multi-issue, U7, U6.0 landed; U6.1 banks landed / product closeout open; U6.2 hub live; U5 OoO production-gated.** H + AVX-like in `remaining-upgrade-sequence.md`. Snapshot: `current-stage.md`. |
| `remaining-upgrade-sequence.md` | Post-U6 queue: multi-core, H/Sstc, U10, Ara, U5 OoO + L3/PF, **QEMU Linux ladder, 100 TOPS I3→I2** |
| `out-of-order/README.md` | U4 slice + **U5.0–U5.2** status |
| `l2-l3-cache/README.md` | L2 done; **L3 + server prefetcher** |
| `ai-matrix/scaling-100tops.md` | **Sizing plan:** frozen TOPS definition, bandwidth-first model (`BW = 2/T × MAC-rate`), core-attached vs island plane split, chiplet deferral gate. **SKU decided (AI-S1): both, staged** — latency SKU first (I1→I3), throughput SKU by cluster replication (I2), one memory system serving both. §4.2–4.3: `DramChannels` is a shared DRAM-slave stripe (cores + `NrCores` + island), not I2 and not `cva6_cfg_t`. |
| `uncore/dram-channel-scaling.md` | **I3 stability plan:** N×19 GB/s DDR4 ladder, fabric ceiling, L2 bank alignment, N=1 identity, dual-port front-end for 400 GB/s without splitting the map. |
| `ai-matrix/hard-tests.md` | **HARD / directed ELF map:** narrow\|smoke\|ci\|peak surfaces, green results, I0–I4 coverage vs clustering next step. |
| `ai-matrix/frameworks-virt-pcie.md` | Host multi-phase: soft virt-ai-pcie → SV HARD → optional `--from-timing`. |
| `ara-vector-attach.md` | U10ᵇ Ara/RVV flist + `server_math_v` package contract |
| `firmware-boot-principles.md` | Handoff then fetch-as-A: I1–I28, peels/P1–P4 for capabilities |
| `multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md` | **Foundation (philosophy):** the reasoning layer under the two below — propositions P1–P7, thought patterns T1–T10 in sentence pseudo-code, the six speculation-visibility channels, the feedback-latency ladder L0–L7, worked `core/` and `corev_apu/` transcripts. |
| `AGENTS-g6lc-opensbi-dev-heuristics.md` | **Methodology (not law):** seven weighted heuristics — archetype lift, contract-before-change (bounded formal over `g6lc_fetch_pkg`), oracle validity, determinism-first, blame locality, red-line executability, escape-hatch budget. Generalizes `multi-threading/AGENTS-smt2-opensbi-dev-logics.md`; aims at removing the need for peel/soak/hold. |
| `core-fetch/` | Fetch spec; frozen A is `core/frontend`; workspace B is `core/fetch_B` |
| `multi-threading/smt2-bringup.md` | U6.1 SMT2 bring-up — dual-thread Linux/OpenSBI checklist; live gap is fetch_B/IQ leftover, not banked state |
| `multi-threading/testharness-proxy.md` | **Harness of record** for SMT Spike/soak/peel/TRACE/I4dp (proxy-only; classify from log) |
| `multi-threading/linux-boot-scale.md` | OpenSBI steps × fetch_B four combos × named envelopes (N/T/I/RVV/stream); `_v`/`ooo_server` Linux-cap bar |
| `multi-threading/soft-ladder/` | Evidence (tag `g1-archive`). A/`smt_legacy` soak notes; **`CONTRACT.md`** envelopes |
| `dcache-ack-before-check.md` | **SL-W micro-arch note:** the WT D$ write-through L1-stale class behind the S1 residual — the two failure modes (staleness vs forward progress), why all ~60 logged candidates hit both, the untried decoupled-fixup axis, and the acceptance gates |
| `server-math-hypervisor.md` | U9/U10 detail: vstimecmp, server config, RVV enable order |
| `Architecture-research-todo-drafts.md` | Earlier research roadmap that the program above refines for a power-bound target. |

## Live RTL summary (not scaffold)

| Area | Where it lives | Default |
|------|----------------|---------|
| U1 prediction fabric | `core/frontend/` (compiled) + copies in `core/fetch_B/` (not on flist) | TAGE_LITE on primary 64b target |
| U2 FTQ / FDIP / loop buffer | `core/frontend/` | On primary 64b target |
| Retired fetch supplies | `core/fetch_A/`; historical `Flist.smt_legacy` | Excluded from active builds |
| Active instruction supply | `core/fetch_B/` + `Flist.fetch_B`; shared SMT support in `core/smt/` | fetch_B only; firmware completion remains under qualification |
| U3 way-pred / RRIP | `core/cache_subsystem/g6lc_way_predictor.sv`, `g6lc_rrip_repl.sv`, hpdcache | Target-dependent |
| U4 slice-OoO | `core/cva6_slice_*.sv` | **Off** (`SliceOoOEn=0`) |
| U5 full OoO | `core/ooo/*` | **Production gated** (`OoOEn`; identity when 0) |
| Multi-issue 2–8 | config `NrIssuePorts` + issue/ID/EX | Auto 1 or 2 from `SuperscalarEn` |
| U6.0 L2 | `corev_apu/l2_cache/` | **Off** (`L2En=0`) |
| U7ᵃ/U7ᵇ ISA | decoder / csr / MMU / store | Primary enables most; Zicbom needs HPDCACHE |
| Graphics SoC box | `corev_apu/apu/` via `Flist.apu_soc` (`g6lc_apu_attach` → `g6lc_apu_soc` → `g6lc_apu_sys`) | **Off** (default `ApuOff`; diagnostic testharness `ApuHarness`). Guest `0x40001000` / PLIC 9. Not on the production testharness flist |
| Graphics command and surface units | `corev_apu/apu/g6lc_apu_vgpu_*.sv`, `g6lc_apu_cover.sv`, `g6lc_apu_frag.sv`, `g6lc_apu_rsurf.sv` | **Off**, private flists, not in `g6lc_apu_sys`. The ceiling is read back. The scene header and the 960-byte execbuffer are fetched. The DRAW_VBO at byte 908 is recognized and not executed. Its 24 NDC floats are read and not transformed. The viewport and the scissor are both the 640 by 480 rectangle. The clear color is `32'hFF1A0D0D` on one color buffer, surface 1. The vertex buffer is stride 24, offset 0, resource 3, from an inline write of 96 bytes. The fragment sampler view at byte 632 names handle 5. The sampler state at byte 616 names handle 6. The vertex elements at byte 608 name handle 4. The fragment shader at byte 596 names handle 3. The vertex shader at byte 584 names handle 2. The rasterizer bind at byte 576 names handle 9. The depth-stencil bind at byte 568 names handle 8. The blend bind at byte 560 names handle 7. The rasterizer object at byte 520 names handle 9. Its eight state words are 0. The depth-stencil object at byte 496 names handle 8. Its four state words are 0. The blend object at byte 448 names handle 7 and color word `32'h78020010`. The sampler-state object at byte 408 names handle 6, wrap word `32'h00002292`, and max LOD `32'h42000000`. The sampler view at byte 380 names handle 5, resource 1, format `32'h02000002`, and swizzle `32'h00000688`. The vertex-element object at byte 340 names handle 4, with format 31 at offset 0 and format 29 at offset 16. The fragment-shader object at byte 176 names handle 3. The vertex-shader object at byte 24 names handle 2. The surface object at byte 0 names handle 1, resource 4, and format 2. Guest descriptors at `64'h8800E100` link the header, the 960-byte execbuffer, and the 24-byte response. Avail index 1 at `64'h8800E200` names descriptor 0. The completed-opcode list at `64'h8800E300` is count 0 and capset id 0. The virgl capset stays refused. A 64 by 64 guest window at `64'h88020000` is 512 beats of clear word `32'hFF1A0D0D`. The guest response at `64'h8800A800` is `OK_NODATA` with fence `64'h1122334455667788`. The used element at `64'h8800E400` is descriptor 0 and length 24. The used index at `64'h8800E480` is 1. The used-buffer interrupt reason at `64'h8800E500` is `32'h1`. Ack lowers the pin. The guest ack at `64'h8800E510` is `32'h1`, and the status word at `64'h8800E500` is then `32'h0`. All 512 beats of the window are that clear word. That window is copied to `64'h88030000`, a 64 by 64 rectangle of 16384 bytes. `(1,0)` is byte 4 and row 1 starts at byte 256. The clear word sits in memory as the bytes 0D 0D 1A FF, so byte 0 is red. Row 1 at `64'h88030100` starts with that same red byte. `(1,1)` is byte 260, `(2,3)` is byte 776, and `(0,63)` is byte 16128. `(63,0)` is byte 252 at `64'h880300E0`. `(7,0)` is byte 28, lane 7 of `64'h88030000`. `(8,0)` is byte 32 and `(15,0)` is byte 60, both in `64'h88030020`. `(56,0)` is byte 224, lane 0 of `64'h880300E0`, and `(63,0)` stays byte 252, lane 7 of that beat. `(16,0)` is byte 64 and `(23,0)` is byte 92, both in `64'h88030040`. `(24,0)` is byte 96 and `(31,0)` is byte 124, both in `64'h88030060`. `(32,0)` is byte 128 and `(39,0)` is byte 156, both in `64'h88030080`. `(40,0)` is byte 160 and `(47,0)` is byte 188, both in `64'h880300A0`. `(48,0)` is byte 192 and `(55,0)` is byte 220, both in `64'h880300C0`. `(63,63)` is byte 16380, lane 7 of `64'h88033FE0`. The shader is not run. Neither shader is run. No framebuffer is painted. No blend is applied. No depth test is run. No triangle is walked. The shader is not run. No vertices are fetched. No texture is bound. Avail still rejects `NEXT`. Untracked |
| HDMI scanout | `corev_apu/hdmi/` | **Off** (`HdmiEn=0`). 640×480 `r5g6b5` directed model. Untracked. Outline `uncore/hdmi-display.md` |

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
| `core/smt/` | Shared SMT banks, thread selection and pipeline helpers | Active with fetch_B; no source files loaded from retired directories |
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

- **Graphics lane**: `architecture/uncore/apu-graphics.md` — SoC box versus private virtio fixtures, the proven execbuffer prefix, and gates A0–A7. Leaf counts stay in `uncore/apu-resident-fw.md`.
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
