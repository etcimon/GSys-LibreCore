# STA handoff — from `sv-timing` structural FO4 to static timing analysis

> **Status:** Normative handoff contract (v1).  
> **Companion:** [`DESIGN.md`](DESIGN.md) (IR + FO4), [`FREQUENCY-CLOSURE.md`](FREQUENCY-CLOSURE.md),  
> [`../AGENTS-host.md`](../AGENTS-host.md) (host CLI).  
> **Hard rule:** structural FO4 is **not** STA sign-off.

---

## 1. What each layer owns

| Layer | Owner | Delivers | Does **not** deliver |
|---|---|---|---|
| **sv-timing analyze** | package | Timing IR, ranked paths, opportunities, expression trees, instance graph | SDF, SPEF, liberty, clock uncertainty, OCV |
| **sv-timing correct** | package (expert) | Allowlisted RTL rewrites + edit trace under `--out-dir` | Proof of functional equivalence under full protocol |
| **Host (`timings`)** | monorepo / SoC flow | Portable `.f`, target MHz, module allowlist, spawn CLI | Foundry PDK binding |
| **STA (PrimeTime, OpenSTA, Tempus, …)** | SoC / PD | Sign-off slack, path reports, SDC, parasitic-aware delay | Source-level auto-correct |

**Handoff direction:** `sv-timing` → human / host review → (optional) correct emit → **sim + lint** → **synthesis** → **STA**.  
Never the reverse: STA does not drive the package CLI in v1.

---

## 2. When to stop trusting FO4 and open STA

Use **sv-timing** when:

- Ranking which RTL clouds are structurally hostile to a target MHz.
- Screening multi-file projects before long synth/STA loops.
- Proposing **InsertReg** / **SplitAssign** candidates with source locations.

Open **STA** when:

- You need a **tape-out / sign-off** slack number.
- Wire load, drive strength, VT corners, or RC extraction matter.
- Multi-cycle paths, false paths, or generated clocks are in play.
- You are validating a corrected netlist after place-and-route.

**Rule of thumb:** if the decision costs silicon or freezes a floorplan, STA wins. If the decision is “which always_comb to split first,” FO4 ranking is enough.

---

## 3. Artifact mapping (package → STA engineer)

### 3.1 Analyze JSON (primary handoff)

Produced by `sv-timing analyze --json-out report.json` or host:

```text
bun run src/cli/index.ts timings analyze --modules <name> --target-mhz <F> --json-out …
```

| JSON field | STA engineer use |
|---|---|
| `disclaimer` | Must remain visible in any dashboard copy |
| `target_mhz` / `budget_fo4` / `fo4_ps` | Structural budget only; map to SDC `create_clock` **period** separately |
| `paths[]` | Candidate critical clouds: `startpoint`, `endpoint`, `total_fo4`, `slack_fo4`, `path_kind`, `primary_loc` |
| `frequency_closure` | Coarse “closes at target?” structural bit — **not** WNS/TNS |
| `modules[]` / `regions[]` | Module-local clouds; clock/reset names from `GateInfo` |
| `instances[]` / `cross_module_paths[]` | Hierarchy hints (`port_bridged` nets) for hierarchical STA path groups |
| `opportunities[]` | Suggested cuts (`insert_reg` / `split_assign`) with `loc.file:start_line` |
| `sta_hints[]` | Review-only path seeds (`from`/`to`/`through`/`sdc_comment`) — **never** auto-`set_max_delay` |

### 3.2 Debug export (optional)

`debug` / `debug_snapshot_pass` paths CSV and IR JSON:

| File | Use |
|---|---|
| `paths.csv` | Sort/filter worst FO4; attach as design review appendix |
| `ir.json` | Tooling / dashboards; includes expression trees when present |
| `names.json` | Name-table audit after auto-correct |

### 3.3 Corrected emit tree

`--emit --out-dir <dir>` writes:

| Artifact | STA / synth handoff |
|---|---|
| `*__svt.sv` | Candidate RTL for re-sim and re-synth |
| `svt_corrected.f` | Portable filelist for host synth/STA scripts |
| `svt_emit_manifest.json` | Source → emit mapping; edit counts |

**Host must not auto-commit** corrected RTL. Re-run compliance sim before STA.

---

## 4. Recommended SoC workflow (CVA6V-EC example)

```text
1. Host flist
   timings flist --target <cfg>
   → workspace/build/sv-timing/host-<cfg>/portable.f

2. Structural screen
   timings analyze --modules <hot> --target-mhz 1250 --json-out analyze.json
   → review paths[], opportunities[], frequency_closure.closes

3. Expert correct (optional)
   timings correct --modules <hot> --allow-latency --emit \
     --out <…/corrected>
   → review edit trace; sim + lint on svt_corrected.f

4. Implementation / PD
   synth (Yosys/DC/…) on original or corrected sources
   → netlist + SDC (host-owned)

5. STA sign-off
   OpenSTA / vendor STA with liberty + SPEF/SDF
   → WNS/TNS/path reports (authoritative)
```

Package step (1–3) can run in CI as **informational**. STA (5) remains the gate for silicon.

---

## 5. Expression AST vs STA delay

`IrNode.rhs_expr` / `lhs_expr` are **source-level expression trees** (idents, literals, binary/unary, ternary, concat, index, call). They densify FO4 (sum of operator nodes) and improve emit fidelity.

They are **not**:

- Liberty cell mappings
- Pin capacitance or wire RC
- Clock-to-Q / setup / hold arcs
- SDF annotated delays

When exporting for STA tools, map **source locations** (`primary_loc`) and **hierarchical instance nets** (`bridge_nets`) — not FO4 numbers — into path groups or `report_timing -from/-to` seeds.

---

## 6. SDC / path-group seeds (informative)

Hosts may generate **review-only** SDC comments from analyze JSON, for example:

```tcl
# Generated from sv-timing path_id=3 — NOT a sign-off constraint
# structural FO4=42.0 slack_fo4=-5.0 @ 1250 MHz budget
# report_timing -from {u_leaf/a_i} -to {y_leaf_o}  ;# engineer must validate names
```

Rules:

1. Never write hard `set_max_delay` from FO4 without human review.
2. Hierarchical names must be resolved against the **elaborated** netlist, not assumed equal to SV instance names.
3. Multi-cycle and false-path constraints stay host/STA owned.

---

## 7. JSON schema notes

- Analyze schema: `schemas/analyze-result.v0.json` / `v1` — extend, do not silently drop `disclaimer`.
- Expression trees serialize under IR debug dumps as tagged `k` enums (`ident`, `binary`, `ternary`, …).
- Future: optional `sta_hints[]` array (`from`, `to`, `through`, `comment`) — deferred until netlist name mapping is formalized.

---

## 8. Checklist before claiming “timing closed”

| Check | Owner |
|---|---|
| `frequency_closure.closes == true` at target MHz | **sv-timing only** (structural) |
| Sim / compliance green on emitted RTL | host verif |
| Synth clean, no multi-driver | host synth |
| STA WNS ≥ 0 at required corner | **STA** |
| SDC complete (clocks, I/O, exceptions) | host PD |

If only the first row is green, the design is **structurally promising**, not timing-closed.

---

## 9. Related package APIs

| API | Role |
|---|---|
| `Expr::parse` / `emit` / `fo4_cost` / `dominant_op_class` | Denser expression IR |
| `attribute_costs` | Uses `rhs_expr` sum when present |
| `frequency_closure` | Structural closes bit |
| `cross_module_paths` | Hierarchy bridge nets for path groups |
| Host `timings {flist,analyze,correct}` | Monorepo entry without linking crates |

---

## 10. Change policy

Any change that weakens the “not STA” disclaimer, auto-applies SDC, or claims WNS from FO4 requires a DESIGN.md delta and an explicit todo note in `AGENTS-todo.md`.
