# Residual soft-ladder → build-platform scaffold (DI OpenSBI → RTL)

> **Purpose:** Turn the R3a dual-issue OpenSBI *binary* soft ladder
> (`software/smt2-linux/soft-ladder/mk_plat_skip.py`, cont.33–51 in `../smt2-bringup.md`) into a
> **build-platform-resident residual testing scaffold** that (1) is reusable beyond this one
> OpenSBI peel, and (2) **maximizes long-term promotion into RTL** (`core/**` + directed `verif/`).
>
> Binary ELF rewrites are **temporary evidence**, never silicon or product policy.

Cross-cutting: `../../../agents/guides/AGENTS-soc-readiness.md` §0 · `AGENTS-coding-philosophy.md` ·
`AGENTS-build-platform.md` · `build-platform/AGENTS.md` · `verif/regress/AGENTS-regress-scripts.md`.
G1 genericity / least-coupled SMT2: `CONTRACT.md`.

---

## 0. North star (read first)

| Principle | Meaning |
|-----------|---------|
| **Home = build-platform** | Durable gates live as **optional suites / diags** in `build-platform/src/config/defaults.ts` (+ `verif/regress/*` drivers). Not as ad-hoc shell history or `tmp-*` oracles. |
| **Generic residual scaffold** | Same axes as the rest of residual work: **plane** (spike/veri) · **package/target** · **stack height** (bare → OpenSBI → Linux) · **SUCCESS contract** · **peel matrix** for isolation. Soft-ladder is one *profile* of that scaffold. |
| **RTL first, soft last** | Every residual class is tried as **B1 directed mini → RTL fix → peel** before any permanent B2 firmware soft. Soft nops/shims only buy time to *find* the RTL bug. |
| **SUCCESS is suite metadata** | Soft-ladder green = trapdump cookie **`51b1babe` only** (not harness tohost SUCCESS). Encode that in suite docs / soak exit criteria, not tribal knowledge. |
| **Proxy is the harness of record** | Spike, Variane soaks, peels, TRACE, and I4dp Linux-cap runs go through `verif/regress/remote/testharness_proxy.py` only. Plan: [`../testharness-proxy.md`](../testharness-proxy.md). Classify from `runs/<tag>/run-*.log`. |
| **Oracle retires** | `mk_plat_skip.py` shrinks as peels land; end state is stock or **source** OpenSBI profile + RTL that runs it under DI. |
| **Boot stage is the progress unit** | Residual *classes* say what to repair; **boot stages F0–F6** say what to attempt next, gated by an A/B pair (`smt_legacy` g1\* oracle vs `fetch_B`). See `firmware-boot-principles.md`. |

---

## 1. Three buckets (unchanged roles, revised ownership)

| Bucket | What belongs here | Long-term home | Binary ladder role |
|--------|-------------------|----------------|--------------------|
| **B1 — RTL / DI residual** | Dual-issue atomics, LR/SC, CSR expected-trap, FDT/`lenp`, dual `c.mv`, structure-walk hazards | `core/**` + directed minis under `verif/tests/` | Soft nops/shims = **temporary evidence** only |
| **B2 — Firmware policy** | Intentional domain cut, console policy, platform profile — *not* atomics/FDT correctness | OpenSBI platform / `software/smt2-linux/` **source** `#ifdef` / Kconfig | Binary stubs **prototype** source policy only |
| **B3 — Sim / harness / suite contract** | Cookies, trapdump, peel env knobs, timeout vs cookie SUCCESS | **`build-platform` suites + diags** · `verif/regress/*` · TB hooks | Stay out of production boot ROM |

**Rule:** A soft site may sit in the binary ladder only until its bucket owner has a **tracked** promotion item in `inventory.yaml` with status ≠ `ladder-only`. Prefer **B1 status `rtl-fixed`** over any long-lived soft.

---

## 2. Revised practical order (build-platform scaffold + RTL-max)

Do **not** skip phases. Earlier phases make later ones cheaper and keep silicon honest.

```text
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ P0  Platform home   Register residual suites + SUCCESS/peel contract     │
  │     in build-platform (optional; not defaultSuites). Generic knobs.      │
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ P1  Directed isolate + OpenSBI fail-code class   Bare / mini tests *or*  │
  │     a single OpenSBI soak with a stable fail-code (mepc/mcause/mtval)    │
  │     that identifies the residual class. The OpenSBI path is the          │
  │     authoritative test when minis pass but the combined firmware does not.│
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ P2  B1 RTL fix       core/** (+ config gate if needed). One residual     │
  │     class per iteration. Re-run minis; only then consider peel.          │
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ P3  Stack climb      OpenSBI residual suite (soft-ladder-osbi): natural  │
  │     path first; PEEL_* only as bisect. Cookie SUCCESS is authoritative.  │
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ P4  Retire softs     Drop matching mk_plat_skip sites; inventory →       │
  │     rtl-fixed / source-landed. Grow generic residual profile, not oracle.│
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ P5  B2 only if policy  Source OpenSBI/platform profile for intentional   │
  │     softs (domain/console). Never use B2 to hide open B1 RTL bugs.       │
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ P6  Generalize       Scaffold applies to other OpenSBI/Linux residuals   │
  │     (topology truth, stream plane, R3b) with same suite axes.            │
  └──────────────────────────────────────────────────────────────────────────┘
```

### Why this order

| Phase | Why |
|-------|-----|
| **P0 first** | Without a cataloged suite, work reverts to lab-only scripts and the binary oracle becomes the “product.” Build-platform is how residual gates stay discoverable (`test --list`, preflight tools, optional). |
| **P1 before P2** | Minis are the first attempt. If a mini is green but the natural OpenSBI path still fails with a *reproducible fail-code*, that fail-code is the class; do not force an artificial mini regression. OpenSBI is the integration test; only then consider permanent softs. |
| **P2 before peel** | Peeling without RTL locks in soft debt and invalidates topology / `plat_hc` truth. |
| **P3 after RTL** | Full OpenSBI is the **integration** gate, not the first place to invent permanent softs. |
| **P5 last for firmware** | B2 is policy once the core is honest; it must not become a second binary ladder in source form. |
| **P6** | Soft-ladder succeeds when it is *no longer special* — just another residual profile on the platform. |

### Mapping old buckets → new phases

| Old step | New phase |
|----------|-----------|
| 0 Inventory | Continuous; feeds P1–P4 (`inventory.yaml`) |
| 1 B1 RTL first | **P1 + P2** (isolate then fix) — still the main work |
| 2 B3 harness | **P0 + P3** (suite contract *before* and *as* stack climb) |
| 3 B2 firmware | **P5** only |
| 4 Retire binary patcher | **P4** continuous + completion when B1 open set is empty |

---

## 3. Build-platform scaffold contract (generic)

Target shape (implement / keep aligned with `defaults.ts` + `AGENTS-regress-scripts.md`):

| Suite id (planned / existing script) | Stack | Role | SUCCESS |
|--------------------------------------|-------|------|---------|
| `soft-ladder-di` → `verif/regress/soft-ladder-di-regress.sh` | bare minis | B1 isolation under DI | mini PASS / tohost per mini contract |
| `soft-ladder-osbi` → `verif/regress/soft-ladder-opensbi-soak.sh` | OpenSBI soft or stock ELF | Integration residual + peel bisect | **cookie `51b1babe` only** |
| `diag-soft-ladder-paths` | path-check | Scripts + README + oracle present | residual compartment |

**P0 status:** suites + path diag are registered in `build-platform/src/config/defaults.ts` (`optional: true`, not in `defaultSuites`). List with `./build.sh test --list` / `diag list`.

**Generic knobs** (env today; document as suite contract; prefer not hard-coding VAs in new code):

| Knob class | Examples | Scaffold meaning |
|------------|----------|------------------|
| Package / harness | Remote `work-ver-smt2-fw64-B` via proxy (`SOFT_LADDER_HARNESS` on the builder), `DV_TARGET=g6lc64_smt2` | Topology + FETCH_WIDTH / DI package. **Do not** cite a local WSL Mdir. |
| **Fetch flavour** | `SOFT_LADDER_FETCH=legacy` (A, g1\* oracle) · `SOFT_LADDER_FETCH=B` (`core/fetch_B`) | Same config/ELF both sides — an A-green/B-red pair is a **fetch** divergence by construction (`firmware-boot-principles.md` F-P2). Never falls back across flavours. |
| Stack height | bare mini · soft OpenSBI · stock OpenSBI · Linux | Climb only after lower green |
| SUCCESS mode | cookie `51b1babe` · hang `51b1dead` · tohost (minis only) | Suite metadata; osbi ≠ mini |
| Peel matrix | `PEEL_FDT_GETPROP`, `PEEL_SPIN`, … | **Bisect only** — default path maximizes natural ops |
| Soft evidence | default soft getprop (until P2 done) | Tracked in inventory; not suite pass criteria forever |

**Registration rule:** both soft-ladder scripts are **`optional: true`**, **not** in `defaultSuites`, same pattern as `mc-mini-veri` / `mc-spo-veri`. Tools: `riscv-gcc`, `verilator` (+ prebuilt harness when present).

**Diag (optional later):** trapdump cookie check, peel-matrix smoke, or path-check for oracle/ELF — under `diagnostics.tests`, not a hard gate on every `probe`.

---

## 4. Safer iteration structure (RTL-max loop)

Each iteration is a **closed loop** over **one residual class**:

| Step | Action | Exit criterion |
|------|--------|----------------|
| **I1 Scope** | Pick one `inventory.yaml` id; state B1/B2/B3 + hypothesis | id `in_progress` |
| **I2 Repro** | Prefer **directed mini** under DI with **fail-codes**; else PEEL path with pin (mepc/mcause/mtval) | Repro in `ITERATION.md` |
| **I3 Fix** | **Prefer `core/**` (B1), one generic class** from `COMPLETION.md` §2 — not a per-register / per-VA keep. Harness-only if B3; firmware only if intentional B2 | Diff limited to owner layer |
| **I4 Verify** | Minis green on cataloged suite path; then osbi cookie if stack-relevant | Gate green |
| **I5 Retire** | Remove `mk_plat_skip` site(s); inventory `rtl-fixed` / `source-landed` | Soft site gone or documented policy |
| **I6 Log** | Append `ITERATION.md`; next id or stop | — |

### Per-bucket verify gates

| Bucket | Minimum gate |
|--------|----------------|
| **B1** | Directed mini under **DI** via `soft-ladder-di` *or* a stable OpenSBI fail-code reproducible on `work-ver-smt2-slfix`; no *new* soft nop for that op as the “fix” |
| **B2** | Source rebuild **without** binary patch; cookie green *or* explicit intentional soft in inventory |
| **B3** | Suite docs + soak exit code match SUCCESS definition; cookies not required in production image |

### Safety rails

1. **No silent soft→source.** Every retired binary patch lists RTL/source commit or inventory note.
2. **One residual class per iteration** (e.g. FDT getprop, not getprop+domain+printf). From I4cf onward the class is a **generic RTL rule** (`COMPLETION.md` G0–G4), not another `c.mv` / single-opcode keep.
3. **Binary ladder optional.** Prefer rebuild-from-source once B2 profile exists; prefer **RTL** so neither is needed.
4. **Hard-coded VAs are debt.** B2/source and new suite helpers use symbols where possible.
5. **Do not regress concurrent SUCCESS baselines** without an explicit note.
6. **Spike is never Zacas golden**; DI atomics golden is Variane/RTL.
7. **Negative bisect → revert.** Experimental RTL that does not move the pin does not stay in tree.
8. **Soft default is not success.** Cookie with soft getprop is a *holding* gate; peel green is the promotion goal.

---

## 5. Files in this directory

| Path | Role |
|------|------|
| `README.md` (this file) | North star, phases P0–P6, scaffold contract, iteration loop |
| [`../../firmware-boot-principles.md`](../../firmware-boot-principles.md) | **Boot-stage ladder F0–F6** + A/B blame. Decides *which stage* to attempt next. |
| `COMPLETION.md` | Generic classes G0–G5 through SL-C/SL-T. G0 waits on EXTRACT E0. |
| `EXTRACT.md` | **Standing next-action:** designated `core/smt/g6lc_*` extracts **before** G0. E0 = `g6lc_sb_keep`. |
| `CONT-FULL-MAP.md` | All cont.2–51 → bucket, soft, RTL status, peel checklist |
| `inventory.yaml` | Living soft-site registry (status + loci) |
| `ITERATION.md` | Append-only iteration log + active iteration |
| `b1-rtl-residuals.md` | B1 deep map → core files / directed tests |
| `b2-firmware-policy.md` | B2 OpenSBI/platform profile sketch (P5) |
| `b3-sim-harness.md` | B3 SUCCESS / suite / peel knobs (P0+P3) |
| [`../testharness-proxy.md`](../testharness-proxy.md) | **Harness of record:** proxy-only Spike/soak/peel/TRACE/I4dp |
| [`../linux-boot-scale.md`](../linux-boot-scale.md) | OpenSBI O0–O8 × fetch_B four combos × named envelopes (N/T/I/RVV/stream) |
| [`../AGENTS-smt2-opensbi-dev-logics.md`](../AGENTS-smt2-opensbi-dev-logics.md) | **Planning aid:** the inference procedure (OpenSBI `file:line` → obligation → invariant → combo), blame router, `NEGATIVE.md` as a pruner predicate, verdict semantics. Not a gate. |
| `monorepo-soak-integration.md` | monorepo-soak × cont.## apply/skip + RTL sync set |

Upstream narrative: `../smt2-bringup.md` (cont.33–51).  
Topology: `../fdt-topology-soft-ladder.md` (depends on FDT walk / peel trust).  
Oracle (temporary): `software/smt2-linux/soft-ladder/` on authoritative tree.

---

## 6. How to start the next unit of work

```text
0. Read ../testharness-proxy.md — doctor the proxy; no local Variane evidence.
   Read ../../firmware-boot-principles.md — pick the lowest un-green boot stage (F0-F6).
1. Read EXTRACT.md — E0 soaked; E1–E3 combined extract; then G0 on the barrier.
2. P0 if needed: soft-ladder-di / soft-ladder-osbi listed optional in defaults.ts
3. inventory.yaml → highest priority open B1 id (today: b1-s4-fetch-b-iq-leftover)
4. A/B the stage **through the proxy**, then read the blame truth table before touching RTL:
     python3 verif/regress/remote/testharness_proxy.py soak --flavour legacy
     python3 verif/regress/remote/testharness_proxy.py soak --flavour B
   A-green + B-red → core/fetch_B (one L1-L4 combo). A-red → generic class / B2.
   Classify from the soak log, not the proxy rc ([`../testharness-proxy.md`](../testharness-proxy.md)).
5. I2: directed mini with fail-codes; `run <elf> --flavour B --tag b1-… --pull` (stage 0: mini_fdt_a0_is_fdt)
6. I3: ONE generic class from COMPLETION.md §2; hold-safe; SI identity
7. I4: mini green → soak hold cookie → PEEL/nat, all via proxy. Hold-FAIL or peel-identical+mini-green → revert
8. I5: shrink mk_plat_skip only after PEEL cookie (stage 3)
9. I4dp hygiene if the class touches SMT ready / IPI / fetch / STQ (2-hart + 8-hart 200M-cap logs)
10. Only if residual is true product policy → B2 source profile (P5)
```

Active iteration and backlog: `ITERATION.md`.  
Boot stages (F0…F6) and A/B blame: [`../../firmware-boot-principles.md`](../../firmware-boot-principles.md).  
Execution: [`../testharness-proxy.md`](../testharness-proxy.md).  
Completion stages (G0…SL-T): `COMPLETION.md`.  
Queue edge: `AGENTS-todo.md` (SL-A…E + SL-P + SL-N + SL-T).  
Linux-boot scale: [`../linux-boot-scale.md`](../linux-boot-scale.md).

---

## Archetype x layer coverage (M5)

Registry of record: [`verif/tests/custom/multicore/ARCHETYPES.yaml`](../../../verif/tests/custom/multicore/ARCHETYPES.yaml).
Vocabulary: archetypes **W1–W7** from
[`../../AGENTS-g6lc-opensbi-dev-heuristics.md`](../../AGENTS-g6lc-opensbi-dev-heuristics.md) §2;
layers from [`../AGENTS-smt2-opensbi-dev-logics.md`](../AGENTS-smt2-opensbi-dev-logics.md) §2 “Home”
and §4 `owning_combo`; invariants from
[`../../firmware-boot-principles.md`](../../firmware-boot-principles.md) §B.

**115 `*.S` files: 2 H3 oracle controls (`mini_must_pass`, `mini_must_fail`, no archetype by
construction) + 113 suite minis.** Of the 113, **106 carry a primary archetype** and **7 carry
none** — those seven are stream/bring-up work that no §2 archetype describes, and they are counted
separately so the matrix is not inflated.

| Archetype | L1-align | L2-accept | L3-order | L4-redirect | LSU | issue | commit | csr | amo | thread-select | none | **total** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **W1** structure walk | 8 | 1 <br>`mini_win_prefix` | 1 <br>`mini_nt_nested_jal` | 0 | 68 | 1 <br>`mini_jal_sd_ra` | 0 | 0 | 0 | 0 | 0 | **79** |
| **W2** self-armed trap probe | 0 | 0 | 0 | 4 <br>`mini_csr_expected_trap`, `mini_csr_pmp_probe`, `mini_trap_cause`, `mini_amocas_q_illegal` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **4** |
| **W3** indirect dispatch | 1 <br>`mini_sib_cjalr` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **1** |
| **W4** byte-string walk | 1 <br>`mini_strlen_rvc` | 0 | 0 | 0 | 1 <br>`mini_dual_cmv_strlen` | 0 | 0 | 0 | 0 | 0 | 0 | **2** |
| **W5** release/acquire | 0 | 0 | 0 | 0 | 1 <br>`mc_spo_fence_drain` | 0 | 0 | 0 | 0 | 0 | 0 | **1** |
| **W6** atomic ticket / reservation | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 16 | 0 | 0 | **16** |
| **W7** election / self-relocation | 1 <br>`mini_jalr_bnez_lottery` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 2 <br>`mini_ipi_hart1_sp`, `mini_wfi_noipi_hart1` | 0 | **3** |
| *(no archetype)* | 0 | 1 <br>`mini_long` | 0 | 1 <br>`mini_jumps` | 2 <br>`mc_stream_plane`, `mini_stream_plane` | 0 | 2 <br>`mc_spo_cf_stream`, `mc_spo_mispred_stream` | 0 | 0 | 0 | 1 <br>`mini_tohost` | **7** |
| **total** | **11** | **2** | **1** | **5** | **72** | **1** | **2** | **0** | **16** | **2** | **1** | **113** |

The eight W1 × L1-align minis are `mini_fdt_a0_is_fdt`, `mini_fetch_straddle`, `mini_fdt_nt_ptr0`,
`mini_fdt_nt_stock_pad`, `mini_fdt_nt_osbi_cutli`, `mini_fdt_nt_osbi_tightva`,
`mini_bnez_jal_split`, `mini_jal_beqz_win`. The 68 W1 × LSU minis are the `fdt_nt_osbi*`,
`hpd_*`, `ecall_list_*`, `stq_*` and freelist families.

**Shape of the table, in one sentence:** 13 of 77 archetype × layer cells are occupied, and two of
them (`W1 × LSU`, `W6 × amo`) hold 84 of the 106 classified minis, so the battery is deep on two
cells and one-deep or empty everywhere else. That is the H1 dividend not yet taken: `W1 ≡ W4` and
`W3 ≈ W2` mean the empty cells are fewer *contracts* than they look, but they are still untested
geometries.

### Gaps — every (archetype, layer) pair with zero minis

64 empty pairs. **real** = nothing exercises it and something should; **structural** = the
archetype's contract family (§2) does not cross that layer, so the empty cell is correct.

**L1-align** (3 empty)

- `W2 × L1-align` — **real, and the highest-value single cell.** R3 clause (c) says the blind
  `mepc += 4` is sound only because `csrr` is always a 4-byte RVI, so a realigner presenting a
  16-bit fragment at the probe's address turns a legal probe into an illegal instruction *and*
  mis-advances `mepc`; no mini places a CSR probe at a straddling address.
- `W5 × L1-align` — **structural.** The handshake's contract family is cross-hart ordering plus a
  bounded fetch grant; it makes no mixed-length fetch demand of its own.
- `W6 × L1-align` — **structural.** AMOs are always 4-byte RVI and the lock bodies are a handful of
  instructions, so no 2-byte boundary question arises.

**L2-accept** (6 empty)

- `W2 × L2-accept` — **real.** “The probe is delivered whole” is an explicit W2 clause and I7 is
  exactly the rule that a dropped window drops all of its slots; nothing tests a probe window drop.
- `W3 × L2-accept` — **real but low value.** Window acceptance at an indirect target is the same
  rule `mini_win_prefix` already exercises; a dedicated mini would mostly re-prove it.
- `W4 × L2-accept` — **structural.** `W1 ≡ W4` as a contract family, so `mini_win_prefix` already
  covers it; the empty cell is a labelling artifact, not a hole.
- `W5 × L2-accept` — **real.** A tight spin-acquire loop is precisely the shape in which a
  permanently dropped window is invisible until the soak times out.
- `W6 × L2-accept` — **structural.** The AMO contract is forward progress at the `amo_buffer`, not
  window acceptance.
- `W7 × L2-accept` — **structural.** Election is a handful of reset-time instructions.

**L3-order** (6 empty)

- `W2 × L3-order` — **real.** I6 says head selection must not depend on opcode; CSR ops are the most
  likely thing to be special-cased and no mini pins packet order around one.
- `W3 × L3-order` — **real.** Same argument for `jalr`, which is the other opcode a scheduler is
  tempted to filter.
- `W4 × L3-order` — **structural** (`W1 ≡ W4`; `mini_nt_nested_jal` covers the family).
- `W5 × L3-order` — **structural.** Cross-hart ordering is RVWMO at the LSU, not packet order.
- `W6 × L3-order` — **real but narrow.** An AMO's position in a packet is an I6 question and is
  untested, but no recorded negative points at it.
- `W7 × L3-order` — **structural.**

**L4-redirect** (6 empty)

- `W1 × L4-redirect` — **real.** The blame router's “target was architecturally correct but never
  fetched” branch is a structure-walk symptom; several W1 minis touch I11 but every one of them is
  filed under L1-align or LSU, so no W1 mini owns redirect priority.
- `W3 × L4-redirect` — **real, and one of the two named capability gaps.** `R3 ≡ R5` collapses
  expected-trap and platform ops *at the redirect layer*, yet W3's single primary mini is filed
  L1-align. Nothing pins “a mispredicted `jalr` always recovers to the architectural target,
  never filtered by value or PMA” (I11/I19) for a function-pointer table.
- `W4 × L4-redirect` — **structural** (`W1 ≡ W4`).
- `W5 × L4-redirect` — **structural.** A spin loop's only redirect is its own backward branch.
- `W6 × L4-redirect` — **real but narrow.** Squash-versus-reservation is filed under `amo`; the
  redirect-priority half is not posed separately.
- `W7 × L4-redirect` — **real.** I8's “SMT restore vs trap” ordering and I10's next-PC banking are
  the I4y/I8 family; `mini_jalr_bnez_lottery` is L1-align, so W7 has no redirect-priority mini.

**LSU** (4 empty)

- `W2 × LSU` — **real but narrow.** `mini_csr_pmp_probe` does store `mcause`/`mtval` through `a3`
  into a stack `trap_info`, but no mini owns the question of that store being visible to the
  restored code.
- `W3 × LSU` — **real.** The defining act of indirect dispatch is *loading* the pointer;
  store-to-load forwarding of a function pointer (as opposed to a data pointer) has no mini.
- `W6 × LSU` — **real.** “The reservation is not clobbered by an unrelated store” is an STQ-boundary
  statement, and all 16 W6 minis run without store pressure.
- `W7 × LSU` — **real.** “A hart's stack does not exist until its own path writes it” is an LSU
  claim; both W7 thread-select minis check readiness, not the first store to a fresh stack.

**issue** (6 empty)

- `W2 × issue` — **real, and named in the R-table.** R3 Home includes `stall_csr_older` *(issue, not
  fetch)* and clause (d) “`csrrw mtvec` must not dual-issue with the CSR it is arming”.
  `mini_csr_expected_trap` carries the `dual_issue` co-factor but is filed L4-redirect, so the issue
  clause has no owner.
- `W3 × issue` — **real but narrow.** Operand-readiness for an indirect target register is untested.
- `W4 × issue` — **structural** (`W1 ≡ W4`; `mini_jal_sd_ra` covers the family).
- `W5 × issue` — **structural.**
- `W6 × issue` — **real.** `mini_lrsc_d`'s own header names the LR→SC issue barrier blocking an
  intervening store, but the mini is filed `amo`; the issue-layer clause has no owner.
- `W7 × issue` — **structural.**

**commit** (7 empty — the column's two minis are unclassified)

- `W1 × commit` — **real.** I13/I15 squash membership *is* the “callee-saved register holds a value
  from a previous call frame” class; `mini_stq_flush_fwd` deliberately mispredicts but is filed LSU.
- `W2 × commit` — **real.** A squashed probe must perform no architectural write; untested.
- `W3 × commit` — **real.** I15 for a mispredicted indirect call; untested.
- `W4 × commit` — **structural** (`W1 ≡ W4`).
- `W5 × commit` — **structural.**
- `W6 × commit` — **real.** `mini_lrsc_d` names “no `flush_commit` after `lr.d`” and is filed `amo`,
  so commit has no W6 owner.
- `W7 × commit` — **structural.**

**csr** (7 empty — the whole column is empty)

- `W1 × csr`, `W3 × csr`, `W4 × csr`, `W5 × csr`, `W6 × csr` — **structural.** None of these contract
  families touch per-hart CSR banking.
- `W2 × csr` — **real.** The probe writes and reads real CSRs; per-hart CSR banking under
  `NrHarts>1` (I22) is what a repeated probe on two *live* harts would test, and no probe mini has a
  live peer.
- `W7 × csr` — **real.** I25 (`mhartid` unique = `hart_id_i + h`) and R9's CLINT `S = N × T` have no
  mini anywhere; `mini_ipi_hart1_sp` writes CLINT `MSIP` but is filed thread-select and never checks
  `mhartid` uniqueness.

**amo** (6 empty)

- `W1 × amo`, `W2 × amo`, `W3 × amo`, `W4 × amo` — **structural.** None of these contract families
  contain an atomic.
- `W5 × amo` — **real.** OpenSBI's release/acquire sits on the same lock primitives as W6, but all
  16 W6 minis are single-hart, so a live releaser paired with an AMO acquirer has no mini.
- `W7 × amo` — **real.** `firmware/fw_base.S:48` is an `amoswap` lottery; no mini runs a *contested*
  `amoswap` election, so the archetype's own witness instruction is untested at its own layer.

**thread-select** (6 empty)

- `W1 × thread-select` — **real.** I23 (every ready hart granted fetch within a bound) during a long
  structure walk is exactly the `mini_fdt_nt_osbi` shape, but that mini is filed LSU.
- `W2 × thread-select` — **real.** A probe repeated dozens of times while a peer is ready is the
  I9-hold-versus-I23-bound conflict in its smallest form; untested.
- `W3 × thread-select` — **structural.**
- `W4 × thread-select` — **structural** (`W1 ≡ W4`).
- `W5 × thread-select` — **real, and the headline gap.** R2′ Home is literally “thread-select bound;
  not fetch”, and W5's only mini is single-hart and filed LSU. The archetype's own home layer has
  zero minis.
- `W6 × thread-select` — **real.** A spinning AMO acquirer must not be able to hold fetch (I23);
  untested.

**none** (7 empty) — `W1`…`W7 × none` are all **structural**: `none` means “no layer under test”, so
an archetype-carrying mini can never legitimately land there.

### Counts are of existence, not of passing

Every number above counts *the existence of a mini in a cell*. None of it is a verdict. Per **H3**,
the DI classifier was corrected on **2026-08-31** (it had read the harness timeout line
`*** SUCCESS *** (tohost = 0)` as a pass), and every DI result recorded before that date was
measured under a superseded verdict and must be re-run or annotated before it is cited. A populated
cell therefore means “a directed program for this shape exists in tree”, not “this shape is green”.
Read together with **T4/P2**: even a genuinely passing mini eliminates a *shape*, never a class —
which is why `ARCHETYPES.yaml` records `missing_cofactors` next to `cofactors` for every entry.
Only five minis run a live peer hart (`mini_fetch_straddle`, `mini_fdt_ro_probe`,
`mini_fdt_nt_osbi`, `mini_stq_press_smt`, `mini_ipi_hart1_sp`); the other 59 hart-aware minis merely
park `mhartid != 0`.
