# Residual soft-ladder → build-platform scaffold (DI OpenSBI → RTL)

> **Purpose:** Turn the R3a dual-issue OpenSBI *binary* soft ladder
> (`software/smt2-linux/soft-ladder/mk_plat_skip.py`, cont.33–51 in `../smt2-bringup.md`) into a
> **build-platform-resident residual testing scaffold** that (1) is reusable beyond this one
> OpenSBI peel, and (2) **maximizes long-term promotion into RTL** (`core/**` + directed `verif/`).
>
> Binary ELF rewrites are **temporary evidence**, never silicon or product policy.

Cross-cutting: `../../../agents/guides/AGENTS-soc-readiness.md` §0 · `AGENTS-coding-philosophy.md` ·
`AGENTS-build-platform.md` · `build-platform/AGENTS.md` · `verif/regress/AGENTS-regress-scripts.md`.

---

## 0. North star (read first)

| Principle | Meaning |
|-----------|---------|
| **Home = build-platform** | Durable gates live as **optional suites / diags** in `build-platform/src/config/defaults.ts` (+ `verif/regress/*` drivers). Not as ad-hoc shell history or `tmp-*` oracles. |
| **Generic residual scaffold** | Same axes as the rest of residual work: **plane** (spike/veri) · **package/target** · **stack height** (bare → OpenSBI → Linux) · **SUCCESS contract** · **peel matrix** for isolation. Soft-ladder is one *profile* of that scaffold. |
| **RTL first, soft last** | Every residual class is tried as **B1 directed mini → RTL fix → peel** before any permanent B2 firmware soft. Soft nops/shims only buy time to *find* the RTL bug. |
| **SUCCESS is suite metadata** | Soft-ladder green = trapdump cookie **`51b1babe` only** (not harness tohost SUCCESS). Encode that in suite docs / soak exit criteria, not tribal knowledge. |
| **Oracle retires** | `mk_plat_skip.py` shrinks as peels land; end state is stock or **source** OpenSBI profile + RTL that runs it under DI. |

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
  │ P1  Directed isolate   Bare / mini tests that pin the residual class     │
  │     under DI (g6lc64_smt2 / work-ver-smt2-fw64*). Suite: soft-ladder-di. │
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
| **P1 before P2** | Minis are the **RTL promotion vehicle**: if a mini cannot hit the pin, the OpenSBI failure is stack-size/context (still B1 investigation), not “accept soft forever.” |
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
| Package / harness | `SOFT_LADDER_HARNESS=work-ver-smt2-fw64`, `DV_TARGET=g6lc64_smt2` | Topology + FETCH_WIDTH / DI package |
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
| **I2 Repro** | Prefer **directed mini** under DI; else PEEL path with pin (mepc/mcause/mtval) | Repro in `ITERATION.md` |
| **I3 Fix** | **Prefer `core/**` (B1).** Harness-only if B3 contract; firmware only if intentional B2 policy | Diff limited to owner layer |
| **I4 Verify** | Minis green on cataloged suite path; then osbi cookie if stack-relevant | Gate green |
| **I5 Retire** | Remove `mk_plat_skip` site(s); inventory `rtl-fixed` / `source-landed` | Soft site gone or documented policy |
| **I6 Log** | Append `ITERATION.md`; next id or stop | — |

### Per-bucket verify gates

| Bucket | Minimum gate |
|--------|----------------|
| **B1** | Directed mini under **DI** via `soft-ladder-di` (or equivalent); no *new* soft nop for that op as the “fix” |
| **B2** | Source rebuild **without** binary patch; cookie green *or* explicit intentional soft in inventory |
| **B3** | Suite docs + soak exit code match SUCCESS definition; cookies not required in production image |

### Safety rails

1. **No silent soft→source.** Every retired binary patch lists RTL/source commit or inventory note.
2. **One residual class per iteration** (e.g. FDT getprop, not getprop+domain+printf).
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
| `CONT-FULL-MAP.md` | All cont.2–51 → bucket, soft, RTL status, peel checklist |
| `inventory.yaml` | Living soft-site registry (status + loci) |
| `ITERATION.md` | Append-only iteration log + active iteration |
| `b1-rtl-residuals.md` | B1 deep map → core files / directed tests |
| `b2-firmware-policy.md` | B2 OpenSBI/platform profile sketch (P5) |
| `b3-sim-harness.md` | B3 SUCCESS / suite / peel knobs (P0+P3) |
| `monorepo-soak-integration.md` | monorepo-soak × cont.## apply/skip + RTL sync set |

Upstream narrative: `../smt2-bringup.md` (cont.33–51).  
Topology: `../fdt-topology-soft-ladder.md` (depends on FDT walk / peel trust).  
Oracle (temporary): `software/smt2-linux/soft-ladder/` on authoritative tree.

---

## 6. How to start the next unit of work

```text
1. P0 if needed: ensure soft-ladder-di / soft-ladder-osbi are listed optional in
   build-platform defaults.ts and documented in AGENTS-regress-scripts.md
2. inventory.yaml → highest priority open B1 id
3. I2: directed mini on DI harness (work-ver-smt2-fw64*) before inventing more softs
4. I3: RTL in core/** ; verify minis; then osbi natural or PEEL bisect
5. I5: shrink mk_plat_skip; inventory status
6. Only if residual is true product policy → B2 source profile (P5)
```

Active iteration and backlog: `ITERATION.md`.  
Queue edge: `AGENTS-todo.md` (SL-A…E + platform registration).
