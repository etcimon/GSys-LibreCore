# CVA6 architecture research drafts

This file collects the research answers produced for the question: *what would it take to move CVA6 beyond a single-issue in-order CPU, toward a Spacemit M1-class core, and eventually to out-of-order execution, and what RISC-V spec coverage would be expected along the way?*

These are **drafts and roadmaps**, not RTL. They follow the `architecture/` scaffold contract: no file here is compiled or referenced by `core/Flist.cva6`, `core/Flist.cva6_gate`, or any verification/synthesis file list. Use them as the starting point for a micro-architecture + verification plan before any code lands.

---

## 1. Next additions to move CVA6 beyond single-issue in-order and toward a Spacemit M1-class core

The Spacemit M1/X60 is an **8-stage, dual-issue in-order** RV64GCVB/RVA22 core with **256-bit RVV1.0**, a **2 TOPS AI/NPU extension**, **per-cluster L2**, and **8 cores in two clusters**. You do not need out-of-order to rival it, but you do need width, vectors/AI, a real memory hierarchy, and multi-core.

CVA6 already has the config hooks for the first step.

### 1.1 Immediate next step: enable and harden the 2-wide superscalar in-order path

The config surface is already in place in `core/include/config_pkg.sv`: `SuperscalarEn`, `NrIssuePorts`, `NrCommitPorts`, `NrALUs`, `ALUBypass`, `NrWbPorts`. All current per-target packages set `SuperscalarEn: 1'b0` (e.g. `core/include/cv64a60ax_config_pkg.sv`).

**What to do:**

- Create a new target config (or flip an existing one) with `SuperscalarEn: 1`, `NrIssuePorts: 2`, `NrCommitPorts: 2`, `NrALUs: 2`, `ALUBypass: 1`.
- Harden the width-aware logic that is already parameterized:
  - `core/issue_stage.sv` / `core/issue_read_operands.sv` — dual issue/arbitration, operand read/forwarding.
  - `core/scoreboard.sv` — `NR_SB_ENTRIES` and `trans_id` tracking for two in-flight instructions.
  - `core/ex_stage.sv` — dual `alu_valid_o`/`mult_valid_o`/`lsu_valid_o`, FU ready gating.
  - `core/id_stage.sv` and `core/frontend/instr_queue.sv` — two decoded instructions per cycle.
  - `core/commit_stage.sv` / `core/ariane_regfile_ff.sv` — two commits/write ports.
- Add/update `check_cfg` assertions in `core/include/config_pkg.sv`.
- Add a build-platform regression suite in `verif/regress/` / `build-platform/src/tests/`.

This alone makes CVA6 **more than single-issue in-order**, matching the X60 baseline.

### 1.2 Then add the M1-differentiating features

- **Branch prediction** — replace/augment `core/frontend/bht.sv`/`bht2lvl.sv` with a larger BTB/RAS, gshare, and eventually TAGE. Config surface is `BPType`/`BTBEntries`/`RASDepth` in `core/include/config_pkg.sv`.
- **Vector extension + AI/DSA** — CVA6 has an `RVV` bit but no vector RTL. Use the existing `core/cvxif_fu.sv` / `core/acc_dispatcher.sv` seam to attach an Ara vector unit or a custom AI coprocessor; add custom instructions via CVXIF. For M1-like AI, add a tightly-coupled memory (TCM) in `corev_apu/` near the accelerator cluster.
- **Memory-side L2/LLC** — do not edit L1. Insert an L2 between `core/cache_subsystem/axi_adapter.sv`/`wt_axi_adapter.sv` and `corev_apu/axi_mem_if/`; keep 64 B block size aligned with `Zic64b`. See `architecture/l2-l3-cache/README.md`.
- **Multi-core cluster** — wrap multiple CVA6 cores in `corev_apu/`, add MESI/MOESI coherence, scale `corev_apu/clint`/`rv_plic` to N harts, and give each core a unique `mhartid`. See `architecture/multi-core/README.md`.
- **Deeper speculation / memory dependence prediction** — widen `NrScoreboardEntries`, `NrLoadBufEntries`, `MaxOutstandingStores` per `architecture/speculative-execution/README.md`; improve store-to-load forwarding and load replay accuracy.

### 1.3 Do not jump to OoO yet

A full out-of-order rewrite is a massive cost/schedule risk and is **not required** to rival the X60/M1 (which is in-order). It also violates `AGENTS.md` §0.3’s anti-pattern of “over-scoped OoO/wide-vector/heavy-speculation additions without a micro-arch and verification plan.” Stay superscalar-in-order while you scale width, vector/AI, caches, and core count.

### 1.4 Verification / SoC readiness for every step

Per `AGENTS.md` §0.2, each step needs:

- Config-gated (`check_cfg`), minimal-config-safe builds.
- Directed test + `build-platform` / `verif/regress` suite.
- RVFI/PMU events, DFT scan preservation.
- Updated `AGENTS-specs-to-impl.md` / `AGENTS-specs-to-tests.md` for ISA-visible changes.
- Area/power/timing note and backend-friendly `tc_sram`/`tc_clk_gating` usage.

---

## 2. Staged path from the M1-class roadmap to a production out-of-order CVA6

Once the dual-issue superscalar, vector/AI, L2, and multi-core work is **stable**, moving to out-of-order execution is the next order-of-magnitude IPC jump. CVA6 already has some speculation plumbing (`SpeculativeSb`/`cancelled` bits in `core/scoreboard.sv`, `NrIssuePorts`/`NrCommitPorts`, branch mispredict flush in `core/controller.sv`), but issue and commit are still FIFO-driven (`issue_pointer_q`/`commit_pointer_q` in `core/scoreboard.sv`). OoO requires decoupling *dispatch* from *issue* from *commit*.

Do not start this until the superscalar/vector/cache/multi-core pieces are verified and the in-order config still elaborates cleanly — it is a multi-year, multi-million-gate change.

### 2.1 Phase 0 — Harden speculative in-order execution (the pre-OoO runway)

This phase builds the recovery mechanisms OoO will later depend on, without yet re-ordering issue.

- **Extend the speculative scoreboard** in `core/scoreboard.sv` — the `cancelled` bit and `SpeculativeSb` path already let you squash younger-than-branch instructions; harden this so loads, stores, CSR ops, and CVXIF transactions are rolled back precisely.
- **Improve speculative memory execution** in `core/load_unit.sv`, `core/store_buffer.sv`, `core/lsu_bypass.sv`, `core/amo_buffer.sv`: store-to-load forwarding, load replay on alias/mispredict, and memory-dependence prediction.
- **Deepen buffers** (`NrScoreboardEntries`, `NrLoadBufEntries`, `MaxOutstandingStores`, `WtDcacheWbufDepth`) and ensure the flush fan-out from `core/controller.sv` clears every new speculative structure atomically.
- **Branch predictor checkpointing** in `core/frontend/frontend.sv` and `core/controller.sv` so a mispredict can restore the frontend without a full pipeline flush.

### 2.2 Phase 1 — Register rename + Physical Register File (PRF)

This is the first architectural change that enables true OoO completion.

- **New `core/rename_stage.sv`** between `core/id_stage.sv` and `core/issue_stage.sv`: map `rd`/`rs1`/`rs2` to physical registers, allocate/free PRF entries, maintain a rename map table, and checkpoint it on branches.
- **Replace/augment `core/ariane_regfile_ff.sv`** with a larger physical register file (e.g. 64–128 entries) with enough read/write ports for the target width (`NrRgprPorts`, `NrWbPorts`, `NrCommitPorts`).
- Branch/exception recovery must restore both the rename map and the free list; this is the hardest correctness block and should be formally verified before issue-queue work starts.

### 2.3 Phase 2 — Reorder Buffer (ROB) and issue queue / reservation stations

- **Evolve `core/scoreboard.sv` into an ROB**: entries allocated in program order at dispatch, results written out-of-order, in-order commit from the head. `commit_instr_o`/`commit_drop_o`/`commit_ack_i` become ROB-head interfaces.
- **Add `core/issue_queue.sv`** (or per-FU reservation stations, e.g. `core/rs_alu.sv`, `core/rs_lsu.sv`) that hold renamed instructions until their operands are ready and a matching FU is free.
- **`core/issue_read_operands.sv`** becomes the wakeup/select/forward/bypass network: it reads the PRF, listens to writeback tags, and issues to `core/ex_stage.sv`.
- **`core/ex_stage.sv`** functional units stay largely the same, but write back with physical tags instead of architectural register numbers.

### 2.4 Phase 3 — Out-of-order Load-Store Unit

Often the longest pole of the project.

- **Convert `core/load_store_unit.sv` into an LSQ**: loads issue when no older aliasing store exists; stores sit in the queue until commit; store-to-load forwarding; speculative loads replayed if an older store's address resolves later.
- Keep `core/store_buffer.sv` / `core/amo_buffer.sv` as the commit-ordered path to memory, so `fence`, `fence.i`, `sfence.vma`, AMOs, and LR/SC still enforce RVWMO precisely.
- Add memory-dependence prediction and a non-blocking D$ with MSHRs if not already present.

### 2.5 Phase 4 — Branch and speculation recovery for OoO

- **`core/controller.sv`** must flush exactly instructions younger than the mispredicted branch, restore the rename map, and redirect the frontend using a saved branch checkpoint.
- **Precise exceptions**: exceptions are recorded in the ROB and taken only when that instruction reaches the ROB head, so all younger speculative state is discarded cleanly.
- `core/csr_regfile.sv` and `core/commit_stage.sv` must only apply CSR/fence side effects at commit.

### 2.6 Phase 5 — Widen and integrate vector/AI

- Scale fetch/decode/dispatch/issue/commit to 3- or 4-wide; add more ALUs, multipliers, branch units, and LSU ports.
- Bring the vector/AI unit (Ara or a CVXIF coprocessor attached via `core/cvxif_fu.sv`/`core/acc_dispatcher.sv`) into the ROB/issue queue as a long-latency functional unit, with vector register renaming.
- The multi-core coherence/LLC work from the M1 roadmap now has to feed multiple OoO cores.

### 2.7 Expected infrastructure around an OoO CVA6

- **Config gating**: add `OoOEn`, `RobEntries`, `PrfEntries`, `LsqEntries`, `IssueQueueEntries`, etc. to `core/include/config_pkg.sv` and `check_cfg`; keep an `OoOEn==0` in-order path that is bit-identical to today. Update per-target packages in `core/include/cv*config_pkg.sv`.
- **Verification**: this is bigger than the RTL change. Add directed tests for rename rollback, WAW/WAR, precise exceptions, branch recovery, store-to-load forwarding, and RVWMO litmus; extend `verif/core-v-verif`, `verif/tests/testlist_*.yaml`, `verif/regress/*.sh`, and `build-platform/src/tests/runner.ts`; add formal properties for ROB ordering, issue-queue correctness, and rename-map consistency.
- **Performance modeling**: use `perf-model/model.py` and `perf-model/cycle_diff.py` to size ROB/PRF/LSQ and validate IPC against Spike *before* freezing RTL.
- **Synthesis / backend**: the PRF read and issue-queue wakeup/select are the critical paths; use `tc_sram` for big arrays, `tc_clk_gating` for power, and consider pipelining select/wakeup. Floorplan PRF close to issue/execute, and budget area for ROB + LSQ.
- **Debug / observability**: extend `core/cva6_rvfi.sv`/`core/cva6_rvfi_probes.sv` to expose ROB indices, physical register tags, and mispredict recovery; add PMU events in `core/perf_counters.sv` for ROB full, issue stalls, rename stalls, LSQ replays, and mispredict penalty cycles.
- **Documentation / traceability**: update `architecture/speculative-execution/README.md`, create an `architecture/out-of-order/` scaffold if desired, refresh `AGENTS-specs-to-impl.md` (microarchitecture sections), `AGENTS-specs-to-tests.md`, and re-derive `AGENTS-specs-coverage.md`.

### 2.8 Bottom line

The path is **speculative in-order hardening → rename/PRF → ROB/issue queue → OoO LSU → branch/exception recovery → widen/vector/multi-core**, with verification, performance modeling, and backend planning running alongside each step. Do not attempt the OoO rewrite until the M1-class in-order features are proven and a written micro-architecture + verification plan exists — `AGENTS.md` §0.3 explicitly flags over-scoped speculation as a 3-10x cost driver.

---

## 3. RISC-V spec parts CVA6 neglects but an advanced OoO/vector/multi-core CPU is expected to cover

Source of record: `AGENTS-specs-coverage.md` and `AGENTS-specs-to-impl.md` in the repo root, with anchors in `agents/spec/INDEX.md`.

### 3.1 Part I — Unprivileged ISA (big-ticket gaps)

- **Vector `V` / `Zve*`** — `Not implemented` (only a CVXIF/accelerator seam exists at `core/cvxif_fu.sv`/`core/acc_dispatcher.sv`). An M1-class/AI core is expected to expose RVV1.0, ideally VLEN ≥ 128/256.
- **Control-Flow Integrity `Zicfilp` / `Zicfiss`** — `Not implemented`. Modern application-class CPUs increasingly require CFI for security hardening.
- **Compare-and-swap `Zacas`** — `Not implemented`. Expected in high-performance multi-core systems for lock-free algorithms.
- **Ztso total store ordering** — `Not implemented`. Optional, but relevant if you want to run x86/TSO-legacy workloads efficiently.
- **Vector crypto `Zvk*`** — `Not implemented`. Goes hand-in-hand with vector extension.
- **Half-precision FP `Zfh`** — `Partial`. Important for AI/ML inference efficiency.
- **Misaligned access `Zicclsm`** — `Partial`. A performance/compat issue in OoO cores with wide memory paths.
- **Cache-management ops `Zicbom`/`Zicboz`/`Zicbop`** — `Partial`. Critical once you add L2/L3 and coherent multi-core.
- **Other atomics `Zawrs`, Za128rs/Za64rs/Zabha/Zaamo/Zalasr** — `Partial` or absent. Multi-core OoO needs a complete atomic story.
- **Bit-manip crypto `Zbc` / `Zbk*`** — `Partial` (scalar crypto `Zkn`/`core/aes.sv` is also partial). Expected for crypto/AI kernels.
- **Matrix / Packed SIMD** — `Not implemented`. Matrix is still emerging; Packed SIMD is largely superseded by `V`.

### 3.2 Part II — Privileged ISA (gaps that hurt an advanced SoC)

- **Sv57 paging** — `Not implemented`. Needed for very large physical memories (server/AI-class).
- **Smctr / privileged CFI** — `Not implemented`. Control-transfer records + privileged CFI are expected alongside unprivileged CFI.
- **Hypervisor `H` extension** — `Partial`. Advanced multi-core chips with virtualization need full H support.
- **Sv* page attributes `Svnapot`/`Svpbmt`/`Svadu`/`Svinval`** — `Partial`. Memory-hierarchy and TLB-efficiency features an OoO multi-core CPU should complete.
- **Non-maskable interrupts `Smrnmi` / NMI** — `Partial`. Needed for robust server/SoC behavior.
- **Supervisor-level counters/PMU `Sscofpmf` and other `Ss*`** — `Partial` / absent. Advanced observability and virtualization require complete S-mode counter support.
- **Sstc supervisor timer** — `absent` (corrected 2026-07-24: there is no `stimecmp` in `core/`, and `core/include/riscv_pkg.sv:132` marks `menvcfg.STCE` *"not implemented"*). High-value, low-cost for Linux; scheduled as U7ᵃ in `router-core-upgrade-program.md`.

### 3.3 Part III — Profiles

- **RVA22** — `Partial / config-dependent`. Spacemit X60 advertises RVA22; CVA6 is missing several RVA22-mandated pieces (vector, complete Zic*, CFI, etc.).
- **RVA23 / RVB23** — `Not implemented`. These add `V`, more `Sm*`/`Ss*`, and bitmanip mandates.

### 3.4 Microarchitecture (not spec chapters, but expected in an advanced CPU)

- **Out-of-order execution** — CVA6 is in-order. Not an ISA extension, but an M1 rival needs it.
- **L2 / L3 cache** — `absent` as in-core feature; only L1 exists. Multi-core OoO needs a shared hierarchy.
- **Multi-core / SMT** — `absent`.
- **RVWMO verification at scale** — `Implemented (limited test)`. Once OoO and multi-core land, this becomes the highest-risk correctness item and needs extensive litmus/conformance testing.

### 3.5 Headline spec debt

For a competitive, standards-advanced CPU the priority debt is: **Vector, CFI (unpriv + priv), Zacas, Sv57, hypervisor page-attrs, RVA22/23 completeness, and L2/L3/multi-core coherency**. Finish the partial `Zic*` hints and atomics along the way.

---

## 4. Consolidated next-action checklist (research → plan → RTL)

Use this as the starting point for an `AGENTS-todo.md` entry and a micro-architecture plan.

- [ ] Lock a target config and harden 2-wide superscalar in-order (`SuperscalarEn=1`, `NrIssuePorts=2`, `NrCommitPorts=2`, `NrALUs=2`, `ALUBypass=1`).
- [ ] Add directed build-platform/regress tests for dual-issue correctness and `check_cfg` legality.
- [ ] Decide branch-predictor upgrade (BTB/RAS sizing → gshare → TAGE) and update `BPType`/`BHTEntries`/`BHTHist`/`RASDepth`.
- [ ] Prototype vector/AI via `core/cvxif_fu.sv` / `core/acc_dispatcher.sv` (Ara or custom CVXIF coprocessor).
- [ ] Define memory-side L2/LLC insertion at `core/cache_subsystem/axi_adapter.sv` → `corev_apu/axi_mem_if/`.
- [ ] Define multi-core cluster wrapper in `corev_apu/` with coherence and `mhartid` scaling.
- [ ] Only after the above is stable: write the OoO micro-architecture and verification plan (rename/PRF/ROB/LSQ).
- [ ] Prioritize spec coverage: `V`/`Zve*`, `Zicfilp`/`Zicfiss`, `Zacas`, `Sv57`, `Smctr`/priv-CFI, `Svnapot`/`Svpbmt`/`Svadu`/`Svinval`, RVA22/23.
- [ ] Update `AGENTS-specs-to-impl.md`, `AGENTS-specs-to-tests.md`, and re-derive `AGENTS-specs-coverage.md` as each extension lands.
