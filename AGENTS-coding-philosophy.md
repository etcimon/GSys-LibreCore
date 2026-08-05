# AGENTS Coding Philosophy

> **North star:** We write RTL that is correct by construction, verifiable, timing-clean, and
> SoC-ready. Every change must be justifiable against timing, power, area, testability, performance,
> and ecosystem impact.

`AGENTS` is both the name of this repository's agent-guider family and a mnemonic for the mindset
required when touching CVA6: **Abstract, Guided, Engineered, Non-negotiable, Timing-aware,
Systematic**. This document is a living architectural and engineering manifesto. It explains the
thought patterns that lead to proper changes in a SystemVerilog SoC project whose end product is
real silicon, booted into Linux, and integrated on a chip.

It sits beside (never above) `AGENTS.md` Section 0 (SoC prime directive), `AGENTS-licensing.md`
(contributor licensing), `AGENTS-configuration.md` (target SoC context),
`agents/guides/AGENTS-soc-readiness.md` (eight-pillar playbook), `AGENTS-dts-validation.md`
(Linux device-tree cross-validation), and — for the uncore / SoC-integration layer — `AGENTS-corev-apu.md`
(the `corev_apu` controller/PHY SystemVerilog preconditions, with `AGENTS-vendor.md` +
`AGENTS-core-platform-vendor-actives.md` for how controller/PHY IP is fetched and mapped). It is a
**standing workflow rule** for every code change: read it, reason through it, check
`AGENTS-configuration.md` for the current target constraints, and document the declared trade-offs
before submitting RTL.

---

## 1. Core purpose

CVA6 is not a simulator. It is synthesizable IP, taped out on real processes, booted into Linux, and
used as a CPU core in SoCs. That changes how we write code:

- Correctness is necessary but never sufficient. A feature must also be synthesizable, timing-clean,
  verifiable, observable, power-aware, and documented.
- A "good enough for simulation" change is not good enough for tape-out. Synthesis, DFT, P&R, power,
  and signal-integrity concerns must be first-class inputs to the design decision. The target values
for those concerns live in `AGENTS-configuration.md`; the RTL config packages
(`core/include/config_pkg.sv`, `core/include/cv*a6*_config_pkg.sv`) must match that SoC context.
- Every edit should be defensible in a design review with a waveform, a timing report excerpt, a
  compliance-test result, and a `.dts`/config/spec alignment note.

> **Rule:** If you cannot explain the timing, verification, and ecosystem impact of a change — with
> numbers grounded in `AGENTS-configuration.md` — do not commit it.

---

## 2. Foundational principles

### 2.1 Correctness before performance — but never silently sacrifice correctness for performance
Performance is a constraint, not an excuse to weaken memory-ordering, exception precision, or
privilege checks. If a faster micro-architecture ever trades off correctness, the trade-off must be
explicit, reviewed, and gated by a config knob. CVA6's in-order commit, ordered store buffer, and
precise exception model (`core/commit_stage.sv`, `core/scoreboard.sv`) exist because correctness
comes first.

### 2.2 Timing is a first-class citizen
Every non-trivial change must be accompanied by reasoning about its impact on critical paths,
setup/hold margins, and clock domains. A change that is functionally correct but closes timing by
accident is not acceptable; the timing intent must be stated. Before adding logic, ask:

- Does it sit on an existing critical path? (ALU, branch resolution, TLB hit, cache tag read, cache
  hit mux, commit control)
- Does it widen a datapath or increase fanout?
- Does it cross a clock domain without proper CDC?
- Does it add a new reset or require reset sequencing?

### 2.3 Modularity and configurability
New behavior must be **optional** and **parameterized** through `config_pkg::cva6_cfg_t` and the
per-target config packages (`core/include/cv*a6*_config_pkg.sv`). Do not hard-code features into
modules. Structural types enter modules via `parameter type ...` injection. If a feature cannot be
disabled without editing source code, it is not ready.

### 2.4 Verification parity
If you add logic, you must add or update the tests that prove it. This means:

- A directed test in `verif/tests/`.
- Compliance with the existing RISC-V regression in `verif/regress/`.
- Formal properties or coverage updates where applicable.
- For new instructions/CSRs, a toolchain-level or assembly test that confirms encoding and
  discovery.
- A synthesis smoke to confirm the change is still synthesizable (`./build.sh verify --synth` or `bun build-platform/src/cli/index.ts verify --synth`).

When the toolchain is incomplete, use the build-platform loop first: `probe` /
`probe install` → `tools install` / `setup --install` → `diag run` (focused
per-package Verilator surfaces) — then full `verify`. See `AGENTS-build.md`.

The runnable wrapper for this discipline is `./build.sh verify` / `.\build.ps1 verify`
(or `bun build-platform/src/cli/index.ts verify`; implemented in
`build-platform/src/cli/commands/verify.ts`). It sweeps lint across every configured target
(`--lint`), runs configured formal tasks (`--formal`), executes simulation suites (`--sim`), and
performs the synthesis smoke (`--synth`) from a single invocation. Run it after every RTL change;
do not wait until the end of a feature to discover an elaboration or synthesis regression.

### 2.5 Silicon reality bias
Avoid simulation-only constructs in the logic path. `initial` blocks, `force`/`release`, and
file I/O are forbidden in synthesizable code. Use `//pragma translate_off` / `//pragma translate_on`
for assertions and debug-only code. Think about synthesis, P&R, DFT, power gating, and yield from
day one.

### 2.6 Explicit over implicit
Prefer clean `always_ff` / `always_comb` separation, named signals, and comments that explain intent.
Do not hide state updates in nested ternary chains. Do not rely on subtle priority encoders that a
reviewer cannot trace. If a signal is intentionally a "don't care" under some conditions, say so.

### 2.7 Target SoC context is the decision frame
Every code change is evaluated against the target SoC, not against an abstract ideal. Before writing
RTL, read `AGENTS-configuration.md` for the current target and confirm that the change is compatible
with its frequency, voltage/power, process node, memory subsystem, software stack, and DFT/verif
strategy. If the target changes, update this file and the affected RTL config packages together.

### 2.8 Structural FO4 soak on real RTL (package-first timing loop)

Timing-aware development is not only “think about FO4 in the PR note.” When the independent
`sv-timing/` package is present next to this monorepo, agents and humans run a **sparse structural
FO4 soak against real SystemVerilog** under `core/` (and thin uncore glue when useful). The goal is
to keep the **analyzer honest on production-shaped RTL**, not to claim STA sign-off.

**How to run (no build-platform required for the package loop):**

```bash
cd sv-timing
python tools/svt.py monorepo-soak --list
python tools/svt.py monorepo-soak                  # sparse EX + frontend (+ soft uncore)
python tools/svt.py monorepo-soak --profile sparse_ex
# Auto-correct validity + from-timing package (toward OpenSTA; emit is review-only):
python tools/svt.py monorepo-soak --profile sparse_ex --correct --emit --allow-latency
# Scale experiment (tighter budget): ~32 FO4 @ 1250 MHz → ~20 FO4 @ 2000 MHz (fo4_ps=20, margin 0.2)
python tools/svt.py monorepo-soak --target-mhz 2000 --profile sparse_ex --correct --emit --allow-latency
# Optional host (from repo root, after soak wrote a package):
./build.sh timings validate --from-timing build-platform/workspace/build/sv-timing/monorepo-soak/sparse_ex
./build.sh timings sta-handoff --from-timing …/sparse_ex --try-tools
bash verif/regress/monorepo-soak-from-timing.sh
```

**Budget model (shared with host timings):**  
`budget_fo4 = (1000/target_mhz × 1000 / fo4_ps) × (1 − margin)`. Defaults `fo4_ps=20`, `margin=0.2`.  
Primary FO4 (after path_class, excluding soft multi-cycle mul/div) is what “closes” means for single-cycle screening.

**Package algorithms agents should know (fix package first):**

| Mechanism | Role |
|-----------|------|
| `path_class` (exclusive / independent-LHS / dense / atomic) | Deflates raw statement-order sums; detector version in cache signatures |
| BalanceMux | Latency-neutral: hot-arm expr staging + origin RHS rewrite; optional one-hot OR tree; sticky FO4 credit |
| Relocation plan T0–T3 | JSON cards drive correct worklist; T3 arch multi-cycle is suggest-only |
| Emit | Review-only under `corrected/`; never auto-merge into `core/` |

Package design and fix priority: `sv-timing/architecture/MONOREPO-SOAK.md`,
`FO4-ALGORITHM-UPGRADES.md`, `RELOCATION-ANALYSIS.md`. Host optional gates also exist under
`verif/sv-timing-tests/` and `AGENTS-build-platform.md` §2.6 / §6.1; the **inner development cycle**
for tool correctness is the package soak above.

**Artifact hygiene (do not confuse host vs package):**

| Bulk | Remove with |
|------|-------------|
| Host monorepo-soak / timings packages | `./build.sh clean timings` (or `clean build`) |
| STA handoff seeds | `./build.sh clean sta` |
| Cargo `sv-timing/target` | `./build.sh clean svt` **or** `cd sv-timing && python tools/svt.py clean` |
| Contained rustup/cargo `.tools` | `./build.sh clean svt-tools --yes` **or** `python tools/svt.py clean --all` |

**Normative fix priority (do not invert):**

| Priority | When | Where to change |
|----------|------|-----------------|
| **1 — Package** | Parse/lower/FO4/emit/path rank wrong or panics on real files | `sv-timing/crates/**` + `fixtures/` + goldens |
| **2 — Contract** | Flist/param-map incomplete for a sparse slice | `verif/sv-timing-tests/flists/`, param-maps, soak profiles |
| **3 — RTL (rare)** | Tool is already trustworthy on that language shape **and** the code has a real logic, reset, latch, combo-loop, or coding-philosophy violation | `core/**` / uncore with full §0 SoC checklist, licensing, verify |

**Rules of engagement:**

1. **Structural FO4 is screening, not silicon sign-off.** Prefer STA (or lab handoff) for WNS/TNS;
   never “fix” production RTL solely to make an FO4 number look closed. Do **not** retune
   `fo4-v1` from synthetic STA fixtures—only from real STA + host `retune-propose` (S3b-lab).
2. **Reproduce package bugs under `sv-timing/fixtures/`** when possible so independence (`cargo test`,
   `svt.py check`) stays green without the monorepo.
3. **Sparse over full-core.** Use the maintained sparse flists (EX, frontend, issue/LSU, thin uncore
   glue)—not a full `Flist.cva6`—unless you are deliberately stress-testing host expanders.
4. **RTL edits remain SoC-grade.** A rare RTL fix from this loop still needs config-gating, synth
   cleanliness, verification parity (§2.4), and a timing-impact note (§3.7)—the soak finding is the
   *trigger*, not a waiver of §0.
5. **Auto-correct emit is review-only.** Never auto-merge corrected trees into `core/`; treat emit as
   a hypothesis to re-implement cleanly in-source when the fix is real.
6. **Scale honestly.** Raising `--target-mhz` tightens budget FO4; residual exclusive/LSU cones may
   still estimate ~1.4–1.7 GHz after latency-neutral rewrites—call for multi-cycle / microarch (T3),
   not more FO4 credit games.

**Development cycle (summary):**

```text
edit package (or rare RTL) → svt.py test/check → monorepo-soak on real core/*.sv
  → classify failure → package fix first → re-soak → only then RTL if still proven
```

This cycle is co-equal with other standing disciplines when the change touches timing structure,
auto-correct, or datapath/control that FO4 is meant to screen. It does **not** replace `verify`
(lint/sim/synth) or formal.

---

## 3. Abstract timing-analysis practices

This section is the heart of the philosophy. For each common change pattern, reason about timing
before writing code. All numbers and constraints in this section must be grounded in the current
`AGENTS-configuration.md` target context.

### 3.1 When adding a new pipeline stage
- **Justify the latency.** Is the extra cycle acceptable for the workload? Does it change the
  branch-misprediction penalty, exception latency, or memory speculation depth?
- **Show the new critical path.** Either prove the stage is off the existing critical path or attach
  a synthesis excerpt showing slack.
- **Discuss retiming.** Can the new stage absorb existing combinational logic to close timing without
  increasing latency? If so, document the planned retiming boundary.
- **Example commit note:** "Adds a 1-cycle ECC correction stage after the data RAM read. Slack on the
  D$ tag-compare path improves from +40 ps to +180 ps; no extra branch penalty because correction is
  post-commit."

### 3.2 When widening datapaths or adding parallel units
- **Analyze fanout.** A 128-bit datapath can create high-load nets on control signals (valid, ready,
  kill). Consider buffering or registering the control separately.
- **Analyze routing congestion.** Parallel multipliers, vector units, or wide accelerators need their
  own placement region and a clean floorplan interface.
- **Prefer registered outputs.** New functional blocks should drive flops, not feed a large
  combinational cloud directly. The output register location is a deliberate timing decision.
- **Example commit note:** "Widens the CVXIF result path to 128 bits; result valid is registered at
  the CVXIF boundary to avoid fanout on the issue-stage control path."

### 3.3 When adding control logic or muxes
- **Small muxes:** `always_comb` with `if-else` or ternary is acceptable. Keep priority encoders
  shallow and document the priority order.
- **Large muxes:** Consider a balanced tree or, if timing demands it, a registered stage before the
  mux select.
- **Standard-cell instantiation:** Only instantiate a specific standard cell when you must control
  exact timing, area, or power (e.g., a clock gater or a custom scan flop). Document why and attach
  the library reference.
- **Example commit note:** "Replaces the priority mux in `controller.sv` with a balanced select tree;
  saves 120 ps on the flush path."

### 3.4 When touching the frontend or branch logic
- **Misprediction penalty:** Never increase the branch-resolution delay without explicit
  justification. A 1-cycle branch-resolution change can be a 5–10% performance loss.
- **Predictor update paths:** BTB/BHT/RAS updates must not create a loop from resolution back to fetch
  in the same cycle. If you add an update signal, check it is flopped before consumption.
- **Fetch redirection timing:** `flush_i` and `resolved_branch_i` paths must be clean; redirection
  should not be re-generated combinational over long distances.
- **Example commit note:** "Adds CFI shadow-stack validation; validation result is flopped before the
  branch unit, so it does not extend the branch-resolution cycle."

### 3.5 When adding custom extensions or accelerators
- **Treat them as pipeline islands.** Custom compute should prefer the CVXIF coprocessor boundary
  (`core/cvxif_fu.sv`, `core/acc_dispatcher.sv`) so the in-core pipeline timing is untouched.
- **Analyze new stall sources.** A coprocessor that stalls the issue stage can create back-pressure
  on the frontend. Define ready/valid contracts and buffer depths explicitly.
- **Analyze new memory ports.** New memory traffic can increase D$ port contention or add AXI
  ordering requirements. Document the memory-side contract.
- **Example commit note:** "Adds a CVXIF-based custom MAC unit; issue handshake is decoupled from the
  integer pipeline and uses a 2-entry response FIFO."

### 3.6 Cross-module optimization awareness
- Synthesis can merge logic across module boundaries. Do not rely on module boundaries to hide
  timing; they are hierarchy, not barriers.
- If you intentionally prevent cross-boundary optimization (`dont_touch`, `keep_hierarchy`), document
  why (e.g., a net must be observable for debug or a module must be a placement region).
- **Example commit note:** "Marks the `rvfi_probes` chain as `dont_touch` so the verification team can
  rely on stable signal names for formal connectivity checks."

### 3.7 Timing-impact note template
For non-trivial changes, include a short timing-impact note in the commit or PR. The numbers must be
grounded in the current `AGENTS-configuration.md` target (frequency, corner, voltage, process node):

```
Timing impact:
  - Change: adds comparator and 2:1 mux on the D$ tag path.
  - Path: load-store unit -> D$ tag compare -> hit mux.
  - Target (from AGENTS-configuration.md): 1.2 GHz @ TT 0.8V, <process node>
  - Synthesis (corner Y): +90 ps worst-case delay, slack remains +210 ps.
  - If the path becomes critical on denser targets, the comparator should be registered.
```

### 3.8 Start from the target SoC configuration
All of the patterns above are abstract. Their concrete interpretation depends on the target SoC
captured in `AGENTS-configuration.md`:

- **Frequency** tells you whether a 2:1 mux added to the D$ tag path is harmless or a critical-path
  violation.
- **Process node and library** tell you whether a balanced mux tree is faster than a priority encoder.
- **Voltage domains and DVFS** tell you whether a new clock or reset requires CDC/isolation analysis.
- **Power budget** tells you whether a new vector unit must be clock-gated per-lane or can share a
  single gate.
- **Thermal envelope** tells you whether a wide parallel comparator is acceptable or will create a
  hotspot.
- **Memory subsystem** tells you whether a new cache prefetcher is useful or will oversubscribe the
  DRAM bandwidth.
- **Software stack** tells you whether a new CSR/instruction needs `.dts`, SBI, and toolchain support.
- **DFT / MCMM** tell you whether new flops must be scan-reachable and which corners must be checked.

Before writing RTL, fill in the `AGENTS-configuration.md` decision-framework questions. If a proposed
change fails any of those questions, stop and resolve the conflict before proceeding.

---

## 4. Good practices catalog

### 4.1 Reset strategy consistency
Use only the **asynchronous-assert, synchronous-deassert, active-low reset** strategy already used
throughout CVA6:

```systemverilog
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (~rst_ni) begin
    // reset
  end else begin
    // next state
  end
end
```

Never add a new clock or asynchronous reset without explicit CDC/reset-synchronization analysis and
a note in the change log. The only sanctioned latch is the ICG cell in
`vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv:47-49`.

### 4.2 Clock gating insertion
Use `tc_clk_gating` (`tc_clk.sv`) for all new gated clock domains. Ensure the enable signal is
glitch-free and arrives from an `always_ff` output. Distinguish **functional gating** from
power-only gating (`IS_FUNCTIONAL==0`). The `testmode_i` / `test_en_i` inputs must be respected for
scan and ATPG.

### 4.3 Avoid inferred latches and combinational loops
Every `always_comb` block must have a complete, default assignment for every output. Run lint and
synthesis checks for inferred latches. Check for unintended combinational loops by inspecting the
synthesis report's feedback paths.

### 4.4 Naming conventions
- `_q` for registered state, `_d` for next-state, `_n` for combinational next value.
- `_i` / `_o` for module inputs/outputs.
- `_stageN` for pipeline-stage-qualified signals where the cross-stage contract matters.
- `_en` / `_we` / `_req` / `_ack` / `_valid` / `_ready` for control; never invent a new convention
  silently.

### 4.5 Assertions and cover properties
Add `assert`/`assume`/`cover` for invariants and corner cases. Use `//pragma translate_off` to guard
sim-only assertions only when they cannot be synthesized; otherwise prefer
`ifdef VERILATOR`/`ifndef SYNTHESIS` patterns consistent with the rest of the codebase. Assertions
are documentation and a safety net.

### 4.6 DFT readiness
- Propagate `test_en_i` and `testmode_i` through new stateful logic.
- Preserve scan and ATPG observability; do not gate or mux out scan-visible flops without a DFT
  review.
- Keep scan chains clean by avoiding `generate`-only flops that disappear in test mode unless
  explicitly intended.

### 4.7 Power intent
Annotate power intent (UPF or equivalent) for new clock domains, power islands, or isolation cells.
If a feature can be fully disabled, ensure the clock gate and reset are structured so the block is
static in the disabled configuration.

### 4.8 Exception and speculation safety
- All exceptions must be **precise**: the architectural state at commit is consistent with the
  instruction stream.
- All speculative side effects (loads, stores, cache operations, predictor updates, coprocessor
  requests) must be squashable by `flush_i` / `flush_unissued_instr_o` / `resolved_branch_i`.
- Never let a speculative operation allocate a non-recoverable resource.

### 4.9 `.dts` / config / spec alignment — cross-validated against upstream Linux
Every ISA-visible feature (instruction, CSR, cache property, memory region, interrupt) must have a
config bit, a spec anchor, and a `.dts` linkage when it is SoC-visible. The three must agree. If the
config says `RVZiCbom` is on but the `.dts` advertises no cache-management capability, one of them is
wrong.

Alignment is not judged against an invented device tree — it is **cross-validated against the actual
upstream Linux bindings and reference DTS**. Before landing a device-tree-visible change, fetch the
Linux RISC-V device-tree source once with `build-platform/scripts/fetch-linux-dts.{sh,ps1}` (a sparse,
blobless checkout into the git-ignored `build-platform/workspace/linux-dts/`), then follow the
procedure in `AGENTS-dts-validation.md`: read the binding YAML (`compatible` enum + required
properties), check a reference DTS (e.g. `sifive/fu540-c000.dtsi`), and confirm CVA6's own `.dts`
(`corev_apu/…/*.dts*`) and RTL match it. This turns the triple into a **four-way check**
(binding ⇄ reference DTS ⇄ CVA6 `.dts` ⇄ RTL) anchored to the spec. A property that is not in the
upstream binding is not Linux-discoverable — treat that as a gating fact, not a detail.

### 4.10 Linux and ecosystem applicability
Before adding a new instruction or CSR, ask: can the toolchain encode it? Can OpenSBI discover it?
Can Linux read it from `misa`, `mstatus`, or device tree? If the answer is no, the change is not
merge-ready. Prefer extending the ISA string and adding the corresponding `.dts` property.

---

## 5. Review & validation checklist

Every non-trivial change must pass this checklist before merge. Check items explicitly in the PR
description or commit message.

- [ ] **Synthesis clean:** `make synth` or equivalent completes with no new errors/latches.
- [ ] **Timing target:** target frequency slack is positive in the reported corner; attach a timing
      report excerpt or a link to the CI run.
- [ ] **SoC-context checked:** the change is compatible with the current `AGENTS-configuration.md`
      target (frequency, voltage, power, process, memory, software, DFT).
- [ ] **No new critical path:** the change does not create a new worst path unless explicitly
      justified with slack or a planned later fix.
- [ ] **Verification updated:** directed tests, regression lists, formal properties, or coverage
      updated to exercise the new logic.
- [ ] **Config-gated:** new behavior is behind a `cva6_cfg_t` bit and `check_cfg` is updated.
- [ ] **Software impact documented:** new instructions/CSRs have encoding, `misa`/ISA-string,
      toolchain, and `.dts` impact documented.
- [ ] **Linux DT cross-validated:** for device-tree-visible changes, the node/`compatible`/properties
      match the upstream Linux binding and a reference DTS, and CVA6's `.dts` + RTL agree
      (procedure in `AGENTS-dts-validation.md`).
- [ ] **Backward compatibility preserved:** existing configs and tests still pass unchanged; any
      deliberate incompatibility is called out and approved.
- [ ] **DFT/scan preserved:** `test_en_i` / `testmode_i` propagated; no new unreachable flops.
- [ ] **Observability:** RVFI probes, debug triggers, or PMU counters updated as appropriate.
- [ ] **Documentation:** `docs/03_cva6_design/` and the relevant `agents/guides/` updated.
- [ ] **Structural FO4 soak (when applicable):** for timing-structure / datapath / auto-correct work,
      ran `python tools/svt.py monorepo-soak` (or a documented sparse profile) on real monorepo SV;
      package fixed first; RTL only if proven (§2.8). Not required for pure docs or unrelated uncore.

---

## 6. Evolution and trade-off documentation

This philosophy will evolve as CVA6 grows (e.g., wider issue, vector support, new cache subsystems).
Evolution is welcome, but it must be **documented and reviewed**.

### 6.1 Accepted technical debt
Technical debt is acceptable only when:
- It is explicitly flagged in a `// TODO:` or GitHub issue with a fix-by milestone.
- It is gated by a config bit so it does not affect production targets.
- A recovery plan (test, timing closure, refactoring) is attached.

### 6.2 Non-negotiable rules
The following are never waived without an architectural review and an explicit exception record:

1. No new `always_latch` except in the sanctioned ICG cell.
2. No new clock or asynchronous reset without CDC/reset-sync analysis.
3. No hard-coded features that bypass `CVA6Cfg`.
4. No instruction/CSR/DT-visible feature without encoding, discovery, and `.dts`/spec alignment
   cross-validated against the upstream Linux binding (`AGENTS-dts-validation.md`).
5. No speculative side effect without a precise flush/squash path.

### 6.3 When violating a principle is acceptable
A principle may be violated only if:
- The violation is necessary for timing closure, area, or a silicon fix.
- The violation is localized and gated.
- A senior designer or maintainer signs off in the PR.
- The exception and its rationale are recorded in `AGENTS-coding-philosophy.md` or `AGENTS.md` if it
  becomes a pattern.

---

## 7. Tone and culture

This document is written by experienced engineers for future contributors. It encourages rigor
without dogma. **Timing-aware** does not mean obsessing over picoseconds in early RTL; it means never
being surprised by timing results later because the impact was considered and documented from the
start.

Ask questions. Pair with a reviewer who understands the target process. Run synthesis early. Write
the timing-impact note before the code is final. Keep the `.dts` ↔ config ↔ spec triple honest. And
remember: the goal is not a feature that simulates, but a core that tapes out, boots Linux, and runs
reliably for years.

---

## 8. Quick reference: where these principles appear in CVA6

| Principle | Concrete CVA6 locus |
|---|---|
| Target SoC context | `AGENTS-configuration.md` |
| Config as source of truth | `core/include/config_pkg.sv`, `core/include/cv*a6*_config_pkg.sv` |
| `always_ff` / `always_comb` separation | `core/cva6_fifo_v3.sv:207-213` |
| Sanctioned ICG | `vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv:47-49` |
| `translate_off` usage | `core/cva6.sv:1884-1889` |
| Memory macro boundary | `vendor/.../tech_cells_generic/src/rtl/tc_sram.sv` |
| CVXIF coprocessor seam | `core/cvxif_fu.sv`, `core/acc_dispatcher.sv`, `core/cva6.sv:337-340` |
| In-order commit / precise exceptions | `core/commit_stage.sv`, `core/scoreboard.sv` |
| Store ordering / speculation | `core/store_buffer.sv`, `core/load_store_unit.sv` |
| Branch / flush timing | `core/frontend/frontend.sv`, `core/branch_unit.sv`, `core/controller.sv` |
| PMP/PMA security boundary | `core/pmp/src/pmp.sv`, `core/include/config_pkg.sv:472-502` |
| RVFI / debug / PMU observability | `core/cva6_rvfi.sv`, `core/cva6_rvfi_probes.sv`, `core/perf_counters.sv` |
| Linux device-tree cross-validation | `AGENTS-dts-validation.md`, `build-platform/scripts/fetch-linux-dts.{sh,ps1}`, `corev_apu/bootrom/ariane.dts` |
| Structural FO4 soak on real RTL (package-first) | `sv-timing/architecture/MONOREPO-SOAK.md`, `python tools/svt.py monorepo-soak [--target-mhz]`, `verif/sv-timing-tests/flists/` |
| Host timings / clean (`svt`, timings packages) | `AGENTS-build-platform.md` §2.6 · §6.1, `./build.sh clean svt`, `architecture/build-platform-workspace-lifecycle.md` |
| Uncore / corev_apu integration preconditions | `AGENTS-corev-apu.md`, `corev_apu/src/ariane.sv`, `corev_apu/fpga/src/ariane_xilinx.sv` |
| Vendored controller/PHY IP (DDR4/PCIe/Ethernet/HDMI/SATA/SD) | `AGENTS-vendor.md`, `AGENTS-core-platform-vendor-actives.md`, `architecture/uncore/`, build-platform `vendor` command |

---

*Last updated: 2026-08-03 — structural FO4 soak §2.8 (path_class / BalanceMux / scale budgets),
host `clean svt` hygiene, and build-platform cross-links. Living document; update when a new
recurring pattern or approved exception emerges.*
