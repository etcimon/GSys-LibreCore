# Extension point: multi-threading (SMT)

Cross-cutting: `../../agents/guides/AGENTS-soc-readiness.md`. Program: U6.1 in
`../router-core-upgrade-program.md`.

**AI attunement (co-equal with soft-ladder):** dual-hart correctness is not only about
`cpuinfo` — it is the software-visible substrate for **multi-thread host + island AI**
work (`ai-tensor` / PyTorch / virt-ai-pcie / HARD). Map:
[`smt2-ai-tensor-linux.md`](smt2-ai-tensor-linux.md) · queue: `AGENTS-todo.md` **SL-T** / **AI-S3**.

## Intent
N hardware threads over shared pipeline resources; per-hart arch state; fair arbitration.
When AI is enabled, those threads must also own **isolated AI CSR sideband state** and
must not corrupt FDT/OpenSBI under dual-issue before Linux can host concurrent tensor
workers.

## Current state (codebase)
| Item | Status |
|------|--------|
| `NrHarts` in `cva6_cfg_t` | **Live** — legal values 1 or 2 (`check_cfg`); default **1** |
| `SmtPolicy` / `SmtFetchQuantum` / `SmtStarveLimit` | **Live** — RR / switch-on-miss / hybrid (default hybrid) |
| Pipeline `hart_id` tagging | **Live** — `fetch_entry_t` + `scoreboard_entry_t.hart_id`; decoder stamps active hart |
| Banked RF | **Live** — `core/smt/g6lc_smt_regfile.sv` (NrHarts=1 → single `ariane_regfile`) |
| Dual PC bank | **Live** — `core/smt/g6lc_smt_pc_bank.sv` + frontend restore |
| Banked CSR | **Live** — `core/smt/g6lc_smt_csr_bank.sv` (commit by `hart_id`; priv mux by active; **AI aicfg/ais sideband banked**) |
| Fine-grain switch | **Live** — IF + unissued flush only; EX drains; BP preserved |
| Per-hart WFI halt | **Live** — sticky `smt_hart_halt` from `halt_csr` |
| Per-hart RAS | **Live** — `ras.sv` banks when `NrHarts>1` |
| Per-hart GHR | **Live** — `g6lc_bp_ghist` + gshare GHR banks |
| Shared BHT/BTB | Shared tables (cross-hart pollution possible) |
| `g6lc_thread_select.sv` + `g6lc_hart_state.sv` | **Live** under `core/smt/` — inventory [`../core-fetch/SMT-LEGACY.md`](../core-fetch/SMT-LEGACY.md) |
| Soft-ladder DI residual | **Active** — Variane cookie `51b1babe` is the SUCCESS pin; QEMU dual-hart OpenSBI/Linux is **not** that pin. SL-C topology + R3b Image still open. Snapshot: [`../current-stage.md`](../current-stage.md). Perf-foundation SMT **control** is `qual-soft-ladder-osbi`. 2026-09-15 reviewed state: full 48 KiB N1 checked-work passes with current fetch fixes, including renewed RR0/RR1 controls. Explicitly IPI-activated RVI and mixed C/I integer checked-work now pass independent retirement/operand checks; original no-IPI N2 does not activate hart 1. This does not close natural firmware or the broader SMT ISA envelope. Historical bisect/VT12 attributions do not establish the current root cause. See the completion gate below, `../core-fetch/NEGATIVE.md` §12 and `AGENTS-todo.md`. FPR remains unbanked. |
| QEMU SMT2 firmware | **Green as hypothesis** — `g6q run` OpenSBI/U-Boot/EDK2/OpenWrt `--smp 2` on virt and generated soc | Never cite as Variane |
| AI / PyTorch host path | **Live soft** on `g6lc64_ai` + virt-ai-pcie + EDK2 DESC join; **SMT2 multi-thread pytorch** after SL-C + Image |

### Fetch_B-only issue-order increment (2026-09-18)

The nine shared SMT modules now live in `core/smt/`; the relocation alone preserved
source bytes and the SMT2 executable hash. Active manifests and generated model input
lists exclude `fetch_A` and `smt_legacy`. The source-boundary check has rejection controls.
A separate barrier repair uses issue-lane order rather than PC magnitude for same-group
SP dependencies. Leaf positives, oracle negatives, restored-defect controls and a
live-port synthesis smoke pass; the previously blocked call now retires in firmware.
After the issue-order repair alone, the unchanged workload still timed out without its
cookie (900-second wall limit, 9,019,026 cycles of a requested 12M). The next increment
below supersedes that cookie result, not the two-active-hart qualification boundary.
Artifacts and scope are recorded in `../../AGENTS-todo.md`.

### Completion cookie reached; second-hart qualification remains open (2026-09-18)

A separate WT D-cache tag-response ownership repair in `wt_dcache_wbuffer.sv` removes
an observed stale stack reload. It selects the registered normal-lookup tag using the
previous accepted request's `check_en_q`, not current pending work. The unchanged ELF
`1a8bd52a...` reaches `51b1babe` and companion `51b1d000` at **1,693,696 cycles**, with
`plat_hc=2`, `last_hartidx=1`, `coldboot_done=1` and the banner marker. Model `d22bbbdc...`,
corrected runtime `dfbc2c4a...`, VT1/seed1 and generated fetch_B-only inputs are retained
in `remote-runs/smt2-progress-cookie-20260918`. The earlier model `99dc42f3...`,
without progress-counter instrumentation, repeats the cookie at the identical cycle
and final pins (`smt2-wttag-cookie-repeat-20260918`).

**Do not equate topology enumeration with execution.** The opt-in typed progress
summary counts 1,301,234 non-dropped retirements for hart 0 and zero for hart 1.
That model's `cva6.sv` masked unseen secondaries until IPI activation. On the same model,
`mini_ipi_hart1_sp.S` terminates with hart counts 256/16 and the secondary stack set.
A private copy replacing only its two IPI stores with equal-sized NOPs does not
terminate and counts 4024/0. Those activation controls validate the observer's
positive direction, not dual-hart completion of this OpenSBI workload.
The boot policy, firmware bytes and success oracle were not relaxed.

### Reset-time execution and natural-profile gate (2026-09-19)

Fetch_B now makes enabled/non-halted harts eligible from reset. The old fixed boot
hold and unseen-until-IPI masking are excluded from its compiled behavior. A registered
handoff request quiesces decode admission and waits for scoreboard and committed
store/write-buffer drain before changing active context. Admission is also stopped
for a halted SMT hart. These conditions replace boot timing assumptions with a
pipeline ownership boundary; in-flight data-miss overlap is deliberately reduced.
The reset election/publication mini passes mixed C/I and norvc (642/643 cycles),
with its result-corruption control firing. Scheduler controls and synthesis are
recorded in `../../AGENTS-specs-to-tests.md`.

**Correction to the old topology interpretation:** the frozen `1a8bd52a...` payload
forces hart_count=2 and stubs FDT property access to NULL. With both harts scheduled,
it reaches the shared cookie at1,902,592 cycles and counts1,262,228/123,436 retirements,
but hart1 reads `[0,0]` from the hart-ID table, fails its lookup and enters
`_start_hang` before assigning its stack. This is not healthy dual-hart completion.
Artifacts: `smt2-both-harts-cookie-20260919`, `smt2-hart-map-audit-20260919`,
`smt2-payload-policy-audit-20260919`.

The user selected a separate source-built profile rather than another byte-patched
fixture. `run_opensbi_source_review.py` builds pinned OpenSBI v1.5 with the existing
platform/toolchain adaptations, natural FDT/startup/HSM code and the strict S-mode
payload. The old image remains unchanged as a regression. Strict HSM/payload
completion is pending; neither a banner nor a cycle-cap SUCCESS substitutes for it.
The first source build (`opensbi-source-dual-v3-20260919`, ELF `6b2bad99...`) is red
at8M cycles despite both harts retiring. The exact same ELF on the retained held-hart
model writes a correct `[0,1]` hart table and count2; the dual-active run instead
loses a call continuation across a handoff. A typed snapshot selects transport
`0x800073f0` with empty decode/IQ, and execution resumes mid-instruction. The
transport/restart boundary is the next investigation; no PC-specific repair is
permitted. These source-profile results do not promote the startup candidate to
production qualification.

The next correction makes the existing PC bank retirement-owned for fetch_B's
quiescent path. Architectural redirects override retired successors; speculative
transport/halfword continuation addresses cannot replace them. The before test and
private overwrite mutation fail, while bank positives, checker negatives and
live-port synthesis pass (27 cells, no latch/SCC). The same natural ELF on model
`3b4fec56...` now reaches distinct initialized stacks and counts325,919/5,447,462
retirements at8M cycles, but still has **no strict supervisor payload completion**.
Hart0 reads zero from the shared init-count-offset word after a 0x80 store and enters
`sbi_hart_hang`; hart1 continues firmware. That is the next visibility investigation,
not permission to add a firmware fence or force a value. See
`opensbi-architectural-pc-dual-20260919` and `opensbi-natural-init-audit-20260919`.

The subsequent WT fixup freshness repair makes that load return0x80 at the same
cycle and moves hart0 into the normal `sbi_hsm_init` wait, rather than its error hang.
An older retained copy had survived a newer ACK because the fixup queue was full.
Existing-copy refresh, byte preservation, same-cycle export and coalescing/retirement
controls are in `run_wt_fixup_review.py`; see `../dcache-ack-before-check.md` for scope.
`opensbi-fixup-preserve-dual-20260919` records325,952/5,447,347 retirements at8M cycles
on model532dc9a2... with the exact same ELF. **Strict supervisor payload completion
is still absent.** Hart1 remains active in libfdt; primary cold-boot progress is the
next discriminator. No firmware workaround or broader architectural promotion.

### Source-built dual-hart completion (2026-09-19)

**The strict OpenSBI/HSM supervisor payload now passes at12,765,628 cycles.**
The fixed ELF6b2bad99... runs on modelc421aedc... with retirement counts333,635 and
8,932,406. Both logical harts publish their supervisor-mode seen flags, the HSM
peer publishes its checked result, and the primary writes explicit tohost success.
This is not a cycle-cap verdict or the old shared soft-ladder cookie. Artifact:
`remote-runs/opensbi-counter-split-dual-20260919/output/results.json` from repo root.

The last RTL repair distinguished AMO commit readiness from operand data readiness.
An LR placeholder0 had reached BNE before its real2 result committed. Consumers now
wait for the committed RF value; directed RVC/norvc, RS1/RS2/ALU and negative cases
pass. The following PMP assertion stop was removed by a **private Verilator compiler
control**, not by editing PMP logic or disabling checks: split the lzc index_nodes
and sel_nodes packed arrays with split_var. All18,502,243 retained retirement lines
from the assertion-stopped model match exactly before the successful extension.
PMP logic, assertions, vendor sources and repository warning waivers are unchanged.
The control SHA256 is be176b279ada076a3459d8bd6509e0946ccf0994d5c35a092bede308bba8c8ff;
its exact file and model/ELF/runtime provenance are retained in the run.

Qualification remains scoped: one pinned source profile/seed/VT1, not Linux boot,
all SMT/FP/OoO combinations, unbounded liveness or physical timing sign-off. The
compiler control is opt-in, not a change to default build policy. Rename elaboration
has since been repaired and its bounded task passes; broad formal stays red on the
unresolved fetch-IQ assertion/witness failure. OoO-only ownership repairs preserve
the passing SMT2 executable byte-for-byte, but do not qualify OoO execution or
dual-runnable scheduling balance.

### Phase1 measured service baseline (2026-09-19)

The adaptive-policy investigation begins with a static, fixed-work M-mode benchmark,
not scheduler retuning. `SMT_BALANCE` in `smt_dual_active.S` runs512 checked iterations
per worker with hart-specific ROI markers. `run_smt2_soak_review.py` selects it with
SMT2_REVIEW_STARTUP=1 and SMT2_REVIEW_BALANCE=1. Both encodings pass; solo0/solo1 use
identical RVC instruction bytes to the shared run, differing only in active-mask data.
The oracle checks the complete ordered four-instruction body512 times per hart,
computed results/publications, explicit termination and typed retirement ownership.
Observer-off replay matches the retirement trace and termination cycle exactly.

`smt2-balance-ordered-20260919`: RVC common-window retirement service49.9264%/50.0736%,
2,048 body retirements per hart, ROI5709/5708 cycles; largest observed inter-retirement
cycle gap76 for each hart. Weighted shared/solo speedup0.90234 and worst-hart
slowdown2.21795x. Thus observed service is balanced for this loop, but shared execution
is not a throughput win. No architectural fairness bound, saturation, cache RTT or
Linux qualification is inferred. The result-corruption control fails;19 tooling tests
include empty/dropped/duplicated/reordered/misattributed trace refusals.

The hardware/modelc421aedc..., scheduler settings and pinned OpenSBI ELF are unchanged.
Future adaptive policy must rank only legally eligible work, retain a static fallback
and minimum service/credit floors, and never throttle completion/draining obligations.
The drained handoff cannot hide an outstanding load by running the peer before it
finishes. Measure switch reasons/refetch/drain and asymmetric cache/lock/IPI workloads
before choosing policy changes. Linux topology, interrupts, shootdowns, locks and
FP context are separate gates; see the active plan Phase6 adaptive extension.

### Historical completion gate (2026-09-15 review)

Use the F0–F5 plan in `../../AGENTS-todo.md`. Historical cookies and NWORKERS=1
results are not proof of two active harts. The current sparse-input IQ defect
has a reproduced failing leaf test and a compaction repair; full-core SMT2
still needs closure. With queue compaction alone, fresh RVC N=1 passed but norvc N=1 failed.
A second repair aligns the prefix filter's expected PC with current-cycle
response bytes: now both N=1 variants pass (131,072 / 137,216 cycles), while
both N=2 variants still have no verdict by 500,000. Historical ELF names were misleading
(the `smt2-norvc-vt1` copy contains compressed code). Keep these envelopes
separate. Current `WtDcacheFixupDepth=2`, so the prior zero-depth exclusion of
WT fixup logic does not apply to HEAD.

Live IQ/realigner formal had an impossible narrowed hart-range assumption and
undriven stimulus; prior green labels are withdrawn pending repaired assertions
and reachability. Generic queue screening improves cell count without adding
state, but is neither physical area nor SMT2 promotion. Natural OpenSBI,
per-hart work/isolation, release/acquire, traps, WFI and atomics remain gates.

Follow-up: original N2 checked-work has no IPI and leaves hart 1 masked by the
current boot contract; RF/done-word evidence confirms it is not a dual-active
run. The existing IPI-start mini passes. Typed, generation-tagged traces locate
three subsequent boundary defects: banking transport PC past discarded ID/IQ
instructions; a foreign-hart resolution updating incoming recovery state; and
split-target completion tested against the response window rather than the
accepted instruction PC. These are repaired without changing boot/switch policy,
keeping queues alive or adding bank state. Resolution still reaches scoreboard,
LSU and predictor training; recovery is routed to the owning hart.

Final model `7037f685…` writes PASS for the byte-identical 48 KiB/hart RVI and
mixed C/I workloads at 282,624 / 270,336 cookie polls. More importantly, the
4 KiB/hart independent reference checks pass 13,696 / 14,202 retirements and
25,774 operand checks each. One cross-hart flag value is outside the local
memory-order assertion. Observer-off/on fingerprints match, and both positive
and injected-error checker controls pass. A cookie PASS after the first repair
had hidden another sequence loss; that intermediate result is not qualification.

Targeted restart/owner/acceptance proofs and covers, bank tests, SMT2/minimal
lint and full-core synthesis pass. Independent IQ proof still times out. Natural
firmware, broader ISA/FP/trap/atomic/concurrency coverage and physical gates stay
open. Matched revalidation against the private, canary-checked Verilator
runtime also passes these integer traces and full-workload replays; use baseline
`5a10acc1…` / observer `528b720c…` and the recorded runtime header identity.
The installed Verilator 5.008 header is unchanged and still needs correction
before it can be trusted for new native runs. Evidence and exact scope:
`../core-fetch/README.md`, typed-trace section.

### Model: fine-grain SMT (drain-friendly)
On thread switch: flush **IF** and drop **unissued** decode; restore banked NPC; **do not** clear scoreboard/EX or BP. Outgoing-hart ops retire with CSR/RF keyed by instruction `hart_id`. Active fetch hart owns RAS/GHR bank and privilege mux. See `smt2-bringup.md`.

### Contention optimisations (where dual-hart contentions bite)
1. **Switch-on-D$/I$-miss** (`SMT_SWITCH_ON_MISS` / hybrid) — sticky miss state in `g6lc_hart_state` forces an immediate peer switch when the peer is ready.
2. **Fetch quantum RR** (`SmtFetchQuantum`, default 4) — bounds unfair share of IF bandwidth.
3. **Anti-starvation** (`SmtStarveLimit`, default 16) — force switch if a ready peer has been idle that many cycles.
4. **Banked integer RF** — per-hart private 32-entry banks eliminate cross-hart write-port conflicts.
5. **L2 MSHR merge + data banks (U6.0)** — sized for dual-hart MLP.
6. **Boot-crutch retirement (`SMT_COLD_EXCL`, `SMT_FIRST_ACT_EXCL`)** — temporary; not a product feature. Retire when `plat_hc==2` and `coldboot_done==1` are stable on natural OpenSBI.

### Enable
```
core/include/g6lc64_smt2_config_pkg.sv   # NrHarts=2, SMT_HYBRID, L2
# Default packages keep NrHarts=1 (identity netlist path).
# Bring-up: architecture/multi-threading/smt2-bringup.md
```
`mhartid` for thread *h* = `hart_id_i + h`.

## Sanctioned seam
`NrHarts==1` remains behaviourally identity. Optional next / SMT2 product closeout: retire `SMT_COLD_EXCL`/`SMT_FIRST_ACT_EXCL`, dual-commit two harts same cycle, banked BHT/BTB, FP register banking, idle-thread clock gate, `Zawrs`/wait-for-peer, and `SMT2` as a default SKU (not only an experimental package).

## Harness of record (execution)

All SMT / soft-ladder / dual-hart / 8-hart **evidence** (Spike ISS, Variane soaks,
peels, TRACE, I4dp Linux 200M-cap) is produced only through
`verif/regress/remote/testharness_proxy.py`. Plan:
[`testharness-proxy.md`](testharness-proxy.md). Local WSL `work-ver-*` and
`p<N>` scripts are not pins. Classify from `runs/<tag>/run-*.log`, not proxy rc.

**Linux-boot scale** (OpenSBI observation ladder, `smt_legacy` oracle only,
fetch_B’s four combos, named envelopes for N/T/I/RVV/stream):
[`linux-boot-scale.md`](linux-boot-scale.md). Do not merge packages; do not
churn `core/frontend`.

## Linux / rootfs track

| Stage | Doc / suite | Status |
|-------|-------------|--------|
| DTS + RTL IRQ path | `dts-linux-smt.md`, `smt-linux-boot-path` | **Landed** |
| Rootfs plan + preflight | `smt-linux-rootfs.md`, suite `smt-linux-rootfs` | **Landed** (R1–R2) |
| OpenSBI SMT2 + dual-hart SBI payload | `software/smt2-linux/` | **Landed** (R3a) |
| Full Linux Image / cva6-sdk | `CVA6_LINUX_PAYLOAD` / `LINUX_IMAGE` | **Lab / optional R3b–c** |

Bring-up: `smt2-bringup.md`. OpenSBI: `software/smt2-linux/README.md`.  
**FDT / cpu-map / threads-per-core plan:** `fdt-topology-soft-ladder.md`
(`NrCores` × `NrHarts`, stream vs SMT, soft-ladder gates before `/proc/cpuinfo`).

### Soft-ladder promotion (DI OpenSBI → codebase)

Binary peels in `software/smt2-linux/soft-ladder/mk_plat_skip.py` are an **oracle**, not the long-term
contract. Promote via three buckets and a closed iteration loop:

| Path | Role |
|------|------|
| `soft-ladder/README.md` | Buckets B1/B2/B3, promotion order, safety rails |
| `soft-ladder/inventory.yaml` | Soft-site registry (status, loci, retire criteria) |
| `soft-ladder/ITERATION.md` | Active iteration + backlog |
| `soft-ladder/b1-rtl-residuals.md` | Core DI residuals (AMO, LR/SC, CSR, FDT, c.mv) |
| `soft-ladder/b2-firmware-policy.md` | OpenSBI/platform source profile sketch |
| `soft-ladder/b3-sim-harness.md` | Cookies / TB / SUCCESS definition |
| `soft-ladder/monorepo-soak-integration.md` | monorepo-soak patches × cont.## × RTL sync |

**Order:** B1 RTL first → B3 harness SUCCESS → B2 firmware profile → retire binary patcher.

### Soft-ladder × SMT RTL seams (iter-013 / S4)

| Mechanism | File | SMT rule |
|-----------|------|----------|
| Younger cancel on mispredict | `core/scoreboard.sv` | Same-hart only when `NrHarts>1`; DI cancels LOADs too |
| Unresolved CF / CSR / **SP** | `core/issue_stage.sv` | Per-hart stall bits — peer thread keeps issuing. I4au: CF also clears on same-hart CTRL_FLOW commit; no arm on `flush_unissued` |
| Banked RF write hart | `issue_read_operands` + `g6lc_smt_regfile` | `whart` from commit instr (never hardwire 0) |
| Banked CSR + AI | `g6lc_smt_csr_bank` | AI aicfg/ais mux by **active** hart; dirty/setcfg to **commit** hart |

DI OpenSBI residual (`PEEL_FDT_GETPROP`) is primarily dual-issue + stack/CF integrity on **hart 0** during coldboot; SMT peer must not share RF/CSR banks or global issue stalls.

## AI attunement (SMT × island × host)

SMT does **not** implement GEMM; it makes multi-hart software and per-hart AI control
state correct. Island compute stays in `corev_apu/ai_island/**` and host stacks in
`ai-tensor/`. Attunement rules:

| Rule | Why |
|------|-----|
| **Per-hart AI CSR banks** | `aicfg` / `aistatus.ais` / dirty-setcfg sideband live in `g6lc_smt_csr_bank` (mux by active fetch; writes gated by commit hart) — no shared sticky AI state across threads |
| **Island is SoC-shared** | MMIO/DMA queues are **not** per-hart RF; concurrency uses descriptor QoS / multi-queue isolation (`ai-matrix/isa-encoding.md` §7.1), not mhartid alone |
| **Soft-ladder before topology trust** | Do not claim dual-hart pytorch/Linux green until FDT/`plat_hc` is honest under DI (`soft-ladder` SL-A…C) |
| **Package split is intentional** | Residual DI: `g6lc64_smt2`. Tensor soft/HARD default: `g6lc64_ai` + `virt-ai-pcie`. Unified dual-hart+AI board is a later package (after SL-C) |
| **TB probes follow hierarchy** | Variane hangpc CSR probes for smt2 use **banked hart0** paths (`gen_banked.gen_csr[0]`); single-hart packages keep `gen_single` in their own rebuilds |
| **Fast iteration** | Suite `smt2-ai-tensor-track` default **fast** — climb only on failure class |

### Doc map (AI-attuned)

| Doc | Role |
|------|------|
| [`smt2-bringup.md`](smt2-bringup.md) | SMT enable + dual-hart Linux CI sketch |
| [`AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`](AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md) | **Foundation (philosophy):** propositions P1–P7, thought patterns T1–T10 in sentence pseudo-code, the six speculation-visibility channels, the feedback-latency ladder L0–L7, and worked `core/` + `corev_apu/` reasoning transcripts. The layer the logics and heuristics docs pull from |
| [`AGENTS-smt2-opensbi-dev-logics.md`](AGENTS-smt2-opensbi-dev-logics.md) | **Planning aid (not law):** OpenSBI source → obligation → invariant → `fetch_B` combo, as heuristic pseudo-code (blame router, negative pruner, verdict semantics, capability navigation) |
| [`smt2-product-closeout.md`](smt2-product-closeout.md) | Post-cookie SMT2 product closeout + FDT `smt,*` compensation properties |
| [`soft-ladder/`](soft-ladder/) | DI OpenSBI residual promotion (B1→B3) |
| [`fdt-topology-soft-ladder.md`](fdt-topology-soft-ladder.md) | `NrCores`×`NrHarts` DTS / cpu-map |
| [`smt2-ai-tensor-linux.md`](smt2-ai-tensor-linux.md) | **Staged T0–T6 track** + speed contract + lab status |
| [`../ai-matrix/hard-tests.md`](../ai-matrix/hard-tests.md) | AI HARD narrow/ci/peak surfaces |
| [`../../ai-tensor/AGENTS.md`](../../ai-tensor/AGENTS.md) | Host PyTorch / Device ABI |

## Invariants
Per-hart precise traps and isolation; RVWMO per and across harts; no starvation (enforced by `SmtStarveLimit` under hybrid).
AI sideband and RF banks remain **per-hart**; island queues remain **SoC-isolated**, not RF-banked.

## Status vs scaffold
**Fine-grain dual-PC + CSR/RF/RAS/GHR banks + drain-on-switch + AI CSR sideband.** Production default remains `NrHarts=1`.  
**SMT2 product closeout is open:** cookie green is a gate, not completeness; the remaining items are listed in `smt2-product-closeout.md`.  
**Linux path:** boot-path + rootfs preflight in-repo; full rootfs needs external images.  
**AI path:** soft pytorch green on virt-ai-pcie; multi-thread host workers gated on soft-ladder topology trust.
