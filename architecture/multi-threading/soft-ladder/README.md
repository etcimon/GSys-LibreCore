# Soft-ladder promotion (DI OpenSBI → codebase)

> **Purpose:** Convert the R3a dual-issue OpenSBI *binary* soft ladder
> (`software/smt2-linux/soft-ladder/mk_plat_skip.py`, cont.33–51 in `../smt2-bringup.md`) into a
> **safe, iteration-focused** path that lands fixes in the right layer — not as
> permanent ELF rewrites.

Cross-cutting: `../../../agents/guides/AGENTS-soc-readiness.md` §0 (tape-out),
`AGENTS-coding-philosophy.md`, licensing on code edits.

---

## 1. Three buckets

| Bucket | What belongs here | Long-term home | Binary ladder role |
|--------|-------------------|----------------|--------------------|
| **B1 — RTL / DI residual** | Dual-issue atomics, LR/SC, CSR expected-trap race, FDT/`lenp` store misalign, dual `c.mv` clobber | `core/**` (+ directed `verif/`) | Soft nops/shims are **temporary evidence**, never silicon policy |
| **B2 — Firmware policy** | Soft domain cut, soft printf, soft switch_mode payload, soft console/platform ops, optional single-hart lock elision | OpenSBI platform / `software/smt2-linux/` bring-up profile (`#ifdef` / Kconfig) | Binary stubs **prototype** source policy |
| **B3 — Sim / harness only** | Success/hang cookies, trapdump caves, lottery hart0 force, tohost timeout SUCCESS policy | `verif/`, TB, soak scripts | Stay out of production boot ROM |

**Rule:** A soft site may sit in the binary ladder only until its bucket owner has a **tracked** promotion item in `inventory.yaml` with status ≠ `ladder-only`.

---

## 2. Practical promotion order (do not skip)

```text
  ┌─────────────────────────────────────────────────────────────┐
  │ 0. Inventory   soft site → bucket → status → owner locus    │
  └───────────────────────────┬─────────────────────────────────┘
                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ 1. B1 RTL first   fix DI blockers that force soft atomics   │
  │    AMO/spin → LR/SC cmpxchg → CSR expected-trap → FDT lenp  │
  │    → dual c.mv   (each delete a class of mk_plat_skip nops) │
  └───────────────────────────┬─────────────────────────────────┘
                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ 2. B3 harness   stabilize cookies/trapdump/regress so RTL   │
  │    and firmware peels have a single SUCCESS definition      │
  └───────────────────────────┬─────────────────────────────────┘
                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ 3. B2 firmware  OpenSBI/platform source profile mirrors     │
  │    remaining intentional softs; drop hard-coded VAs         │
  └───────────────────────────┬─────────────────────────────────┘
                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ 4. Retire binary patcher   stock or profile ELF greens      │
  │    without mk_plat_skip; keep peels as history only         │
  └─────────────────────────────────────────────────────────────┘
```

**Why this order:** B1 fixes raise the floor for *all* software. B3 makes progress measurable. B2 is policy once the core is honest. Never promote B2 soft atomics as permanent if B1 is still open.

---

## 3. Safer iteration structure

Each iteration is a **closed loop** (one primary residual or one peel class):

| Step | Action | Exit criterion |
|------|--------|----------------|
| **I1 Scope** | Pick one `inventory.yaml` id; state bucket + hypothesis | id marked `in_progress` |
| **I2 Repro** | Minimal directed test *or* unpatched ELF path that hits the pin (mepc/mcause/cookie) | Repro documented in iteration log |
| **I3 Fix** | Edit only the owner layer (RTL *or* firmware *or* harness) | Diff limited to that layer |
| **I4 Verify** | Bucket-specific gate (below) | Gate green |
| **I5 Retire** | Remove matching `mk_plat_skip` site(s); update inventory status | Soft site `retired` or `source-landed` |
| **I6 Log** | Append row to `ITERATION.md` | Next id chosen or stop |

### Per-bucket verify gates

| Bucket | Minimum gate |
|--------|----------------|
| **B1** | Directed bare-metal or existing regress that exercises the op under **DI** (`g6lc64_smt2` / Variane dual-issue); no new soft nop for that op |
| **B2** | OpenSBI (or profile) rebuild **without** binary patch for that site; DI cookie still green *or* documented intentional soft |
| **B3** | Soak/regress script documents SUCCESS definition; cookies not required in production image |

### Safety rails

1. **No silent soft→source.** Every retired binary patch lists the source/RTL commit or inventory note.
2. **One residual class per iteration** when possible (e.g. only AMO locks, not AMO+domain+printf).
3. **Binary ladder stays optional.** Prefer rebuild-from-source once B2 profile exists.
4. **Hard-coded VAs are debt.** B2 source must use symbols/functions, not `0x8000….`
5. **Concurrent SUCCESS 200155** (or current soak baseline) is not regressed without an explicit note.
6. **Spike is never Zacas golden** (existing monorepo rule); DI atomics golden is Variane/RTL.

---

## 4. Files in this directory

| Path | Role |
|------|------|
| `README.md` (this file) | Buckets, order, iteration loop |
| `CONT-FULL-MAP.md` | **All cont.2–51** → bucket, soft, RTL status, peel checklist |
| `inventory.yaml` | Living soft-site registry (status + loci) |
| `ITERATION.md` | Append-only iteration log + active iteration |
| `b1-rtl-residuals.md` | B1 deep map → core files / test ideas |
| `b2-firmware-policy.md` | B2 OpenSBI/platform profile sketch |
| `b3-sim-harness.md` | B3 cookies, TB, regress hooks |
| `monorepo-soak-integration.md` | monorepo-soak/* × cont.## apply/skip + RTL sync set |

Upstream narrative: `../smt2-bringup.md` (cont.33–51). Binary oracle: `tmp-dual-ci/mk_plat_skip.py` (authoritative tree `E:\cva6` during lab).

---

## 5. How to start the next iteration

```text
1. Open inventory.yaml → pick highest priority status=open B1 id
2. Copy ITERATION.md template → fill I1–I2
3. Implement I3 in core/ or verif/ only
4. Run I4 gate; I5 delete soft site from mk_plat_skip when safe
5. Append I6 row
```

Active iteration and backlog: see `ITERATION.md`.
