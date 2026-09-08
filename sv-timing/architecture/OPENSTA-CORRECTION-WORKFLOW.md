# OpenSTA correction workflow (clock-aware `always_ff`)

| Field | Value |
|---|---|
| **Status** | Package workflow (review-only). OpenSTA is **host-owned**. |
| **Related** | [`STA-HANDOFF.md`](STA-HANDOFF.md), [`AUTO-CORRECT-CORE-API.md`](AUTO-CORRECT-CORE-API.md), host `architecture/build-platform-opensta-from-timing.md` |
| **Hard rule** | Structural FO4 is **not** STA. Crates never link OpenSTA (KD0). Never auto-`set_max_delay`. |

This is how sv-timing **keeps a clock-aware scratch** for every `always_ff`, emits
ordering comments from that board, and how a host validates those comments with
[OpenSTA](https://github.com/The-OpenROAD-Project/OpenSTA).

---

## 1. Timing basis on the sequential scratch

Comb `ParallelScratch::schedule` is an unclocked FO4 board. `always_ff` must
**not** use that board. `schedule_for_region` binds [`ClockDomain`]:

```text
period_ns = 1000 / f_MHz          # this capturing clock
B         = period_ns * 1000 / fo4_ps * (1 - margin)
ready_cycle k = k-th posedge/negedge of clock_name after reset
```

For `q <= d; r <= q;`, both RHS expressions sample pre-edge state; `r` does not
consume the newly scheduled write to `q`. A blocking temporary (`t = d + a;
q <= t;`) has different semantics. The current IR does not retain that assignment-kind
distinction. Dependency-bearing sequential boards therefore keep their costs and clock
metadata but set `procedural_ok=false`; no scratch-derived timing reduction, JIT fallback
or staged factorization annotation is authorized. Independent NBA RHS cones remain
parallel. `ceil(M/B)` is a proposed partition count, **not** the implemented number of
clock edges or permission to insert latency. `ClockDomain.sequential` stays true even
if the clock net is unresolved.

Fill (`fill_design_parallel_timing`) walks **IR regions first** and stores the
full `ParallelScratch` on `ModuleParallelTiming.regions[id]` (ops **and**
`clock`). A later `TimingPath` on the same `region_id` must not replace that
board with `schedule(path.nodes)`. Factorize / JIT read the kept scratch.

---

## 2. What sv-timing emits (review-only)

`factor_always_ff_regions` (correct loop, after first measure) injects comment
blocks into emit (`always_ff factorize` snippets). They are **not** RTL
rewrites of the original process. Typical seed:

```text
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.250000  B=10.000 FO4
//   create_clock -name clk_i -period 0.250000 [get_ports clk_i]
// order expect: state_q  ready_cycle=1  ready_fo4=1.000
// OpenSTA: report_timing -from clk_i -to state_q
// always_ff @(posedge clk_i or negedge rst_ni) begin
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
// end
```

Engineer maps `clk_i` / `state_q` onto **elaborated netlist** names before
running STA. Hierarchical SV names are hints, not liberty pins.

---

## 3. Where OpenSTA lives

| Location | Role |
|---|---|
| `python tools/svt.py fetch-opensta` | Shallow clone of OpenSTA. Dest: `$SVT_OPENSTA_DIR`, else host `build-platform/workspace/tooling/opensta` when that tree exists, else `sv-timing/.tools/opensta` (gitignored). |
| Host `timings sta-handoff` / `lab-run` | Existing S0–S2 handoff (`seeds.sdc`, optional Yosys, optional `sta`). Soft-skip without binary/liberty. |
| sv-timing crates | **No** OpenSTA path, crate, or FFI. |

Build OpenSTA on the host (CMake + C++). The binary is usually named `sta`.
Liberty is host-supplied (`CVA6_LIBERTY` / PD drop) — never committed.

---

## 4. Correction loop with traces

```text
1. Analyze / correct with --trace-log (algo-trace.jsonl)
   → ParallelScratch fill; always_ff factorize Annotate edits.

2. Review emit snippets: clock name, edge, period, order-expect vars.
   Confirm GateInfo.clock_name matches the process sensitivity.

3. Host synth (Yosys/DC) of original or corrected sources → netlist.

4. OpenSTA (when sta + liberty present):
     read_liberty <lib>
     read_verilog <netlist>
     link_design <top>
     create_clock -name clk_i -period <period_ns> [get_ports clk_i]
     check_setup -verbose
     report_checks -path_delay min_max -format full_clock_expanded
   Map launch/capture pins and clock domains from the elaborated netlist; a clock
   name alone is not a data startpoint. Review I/O delays, uncertainty, generated
   clocks, reset recovery/removal and justified exceptions before interpreting slack.
   Compare constrained paths, not procedural statement order, with the structural
   estimates. Neither FO4 partition counts nor module-name heuristics authorize
   `set_multicycle_path`. Functional equivalence is a separate check.

5. Do **not** retune fo4-v1.toml from a synthetic/fixture STA report.
   Real-liberty residuals may inform a later cost-model PR only.
```

Traces: `algo-trace.jsonl` (`run.start` / `measure`) plus the factorize
`emit_snippet`. Source of the clock is `design.parallel_timing[mod].regions[id].clock`.

---

## 5. Independence / skip

- `cargo test --workspace` inside `sv-timing/` needs no OpenSTA, no liberty,
  no monorepo `workspace/` path.
- Missing `sta` / liberty → skip STA; FO4 ranking and clock-aware comments
  still run.
- Soft-skip is success for CI without PD tools.

---

## 6. Change policy

Dropping `ClockDomain` from an `always_ff` scratch, replacing it with
`ClockDomain::combinational`, or writing `set_max_delay` from FO4 is a
DESIGN.md + `AGENTS-todo.md` event. Keep the sequential board.
