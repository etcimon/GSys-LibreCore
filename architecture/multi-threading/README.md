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
| Banked RF | **Live** — `core/smt_legacy/g6lc_smt_regfile.sv` (NrHarts=1 → single `ariane_regfile`) |
| Dual PC bank | **Live** — `core/smt_legacy/g6lc_smt_pc_bank.sv` + frontend restore |
| Banked CSR | **Live** — `core/smt_legacy/g6lc_smt_csr_bank.sv` (commit by `hart_id`; priv mux by active; **AI aicfg/ais sideband banked**) |
| Fine-grain switch | **Live** — IF + unissued flush only; EX drains; BP preserved |
| Per-hart WFI halt | **Live** — sticky `smt_hart_halt` from `halt_csr` |
| Per-hart RAS | **Live** — `ras.sv` banks when `NrHarts>1` |
| Per-hart GHR | **Live** — `g6lc_bp_ghist` + gshare GHR banks |
| Shared BHT/BTB | Shared tables (cross-hart pollution possible) |
| `g6lc_thread_select.sv` + `g6lc_hart_state.sv` | **Live** under `core/smt_legacy/` — inventory [`../core-fetch/SMT-LEGACY.md`](../core-fetch/SMT-LEGACY.md) |
| Soft-ladder DI residual | **Active** — Variane cookie `51b1babe` is the SUCCESS pin; QEMU dual-hart OpenSBI/Linux is **not** that pin. SL-C topology + R3b Image still open. Snapshot: [`../current-stage.md`](../current-stage.md). Perf-foundation SMT **control** is `qual-soft-ladder-osbi`. 2026-09-15 reviewed state: full 48 KiB N1 checked-work passes with current fetch fixes, including renewed RR0/RR1 controls. Explicitly IPI-activated RVI and mixed C/I integer checked-work now pass independent retirement/operand checks; original no-IPI N2 does not activate hart 1. This does not close natural firmware or the broader SMT ISA envelope. Historical bisect/VT12 attributions do not establish the current root cause. See the completion gate below, `../core-fetch/NEGATIVE.md` §12 and `AGENTS-todo.md`. FPR remains unbanked. |
| QEMU SMT2 firmware | **Green as hypothesis** — `g6q run` OpenSBI/U-Boot/EDK2/OpenWrt `--smp 2` on virt and generated soc | Never cite as Variane |
| AI / PyTorch host path | **Live soft** on `g6lc64_ai` + virt-ai-pcie + EDK2 DESC join; **SMT2 multi-thread pytorch** after SL-C + Image |

### Current completion gate (2026-09-15 review)

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
