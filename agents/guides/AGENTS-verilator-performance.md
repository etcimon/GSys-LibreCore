# Verilator simulation performance — bottleneck structure, redesigns, methodology

Scope: the Verilated models of the GSys LibreCore testharness (`Variane_testharness`,
pinned Verilator v5.008, builder `ovh_calltorch`). This guide records what the models
actually spend their host instructions on (measured with callgrind, not guessed), which
Verilator-internal structures produce those costs, which redesigns preserve
cycle-accuracy, and how to validate speed work cheaply. It is a tier-T document (MIT);
nothing here changes RTL semantics — the rule for this work is **no RTL edit that does
not translate to a physical improvement**. Simulation speed is bought in the compiler
(Verilator source patches under `build-platform/scripts/verilator-patches/`), in
Verilator directives (`.vlt` control files), in the build recipe, and in the harness C++.

Target reality check: a Linux kernel boot is 1–2 G cycles. The 8-hart server model runs
~1.5–2 k cycles/s (MT4); the single-core `g6lc64_ooo` model ~8 k cycles/s. "A few hours"
for 1 G cycles needs ~100 k cycles/s — 10–50× beyond the current models. The items
below are worth 2–5× combined; the rest must come from running less (1-core boot
configurations, fast-forwarding through Spike to a checkpoint, kernel-side trims) or
from FPGA. Every claim of a speed-up must be re-measured; the numbers here are the
measured baseline and the first measured fixes.

## 1. Measured profile (2026-10-11)

Tooling: valgrind 3.23 built from source on the builder
(`/opt/testharness/toolchains/valgrind`), callgrind restricted to the model evaluation
(`--collect-atstart=no --toggle-collect='*eval_step*'`), s11 FP probe (10,941 cycles),
`g6lc64_ooo` single-core model (2-issue, TAGE_LITE, 64-entry scoreboard).

| metric (per simulated clock cycle) | value | note |
|---|---|---|
| host instructions (`-O2` build, no `-pg`) | **590 k** | upstream CVA6 single-core models are ~100–200 k |
| I1 (32 KB) instruction-cache misses | **32 k** (5.4 % of Ir) | code footprint: 72 MB binary; eval code spans many MB |
| D1 misses | 11 k | wide struct copies, scoreboard/LSQ arrays |
| branch mispredicts | 2.2 k | unrolled CAM/age loops |
| `eval_step` calls | 2 | posedge + negedge |
| `_eval_triggers__act` calls | 8.4 | 4.2 per step — hybrid (loop-breaking) logic |
| `_eval_act` / `_eval_nba` calls | 3.7 / 2.7 | ideal ≈ 1 / 1 per cycle |

Attribution (prof-cfuncs build; the `-pg` `mcount` 23 % discounted):

| share | construct | Verilator structure |
|---|---|---|
| **~29 %** | `VL_CONCAT_WIW` chain assembling the 16,577-bit `forwarding_t` (`issue_stage.sv:523`) | V3Const `replaceAssignMultiSel` merged 64 part-select assigns into one wide CONCAT; V3Premit split it into wide temporaries; V3Expand refused them (`--expand-limit 64` words) → one runtime `VL_CONCAT_W*` per link, each copying the whole 518-word vector — O(n²) |
| ~5 % | `_eval_triggers__act` | 255 any-change triggers on hybrid logic, incl. the AXI xbar `mst_resps` (1,542 words compared and copied to `__Vtrigrprev` every evaluation) |
| ~6 % | `g6lc_iq` comb blocks (l127/l207/l331/l347/l473) | 64-entry CAM / age-matrix loops fully unrolled (`--unroll-count 256`) |
| ~3 % | `cva6_rvfi` / `cva6_rvfi_probes` | per-port RVFI struct packing |
| ~2 % | `_vl_insert_WW` | variable-index part writes into packed arrays (`mem_n[tid].field = …`) |
| ~1 % | `aes` sequential blocks | evaluated every clock although idle |
| ~8 % | `_eval`, `_eval_act`, `_eval_nba` bodies | scheduler dispatch: 1,839 trigger tests guard 362 act functions |

Startup, not eval: the ELF preload through fesvr's `htif_hexwriter_t::read_chunk`
(`std::map<addr, std::vector<char>>`, 15 G Ir + 4.6 G in `_int_malloc`) costs **6.8 s per
run** before the first cycle — irrelevant to a long boot, dominant for the hundreds of
short directed runs in every battery.

Build recipe facts: the pinned `verilated.mk` sets `OPT_FAST = -Os`, and the `OPT=-O2`
the driver passes lands earlier on the command line, so every generated file compiles
at **-Os**. `-DVL_DEBUG` is on; `--assert` is on (wanted — the guards are real).
Measured: `-O2` vs `-Os` on the ooo model — no difference within noise (8.1 k vs
8.4 k cycles/s); the model is bound by code structure and I-cache, not by scalar
optimisation level.

## 2. Bottleneck structures inside Verilator (v5.008 source)

### 2.1 Part-select merge → wide concat chain (V3Const / V3Premit / V3Expand)
`V3Const::replaceAssignMultiSel` (V3Const.cpp:1972) merges two adjacent
`ASSIGN(SEL(var, a), x)`, `ASSIGN(SEL(var, b), y)` into `ASSIGN(SEL(var, a:b), CONCAT)`
without a width bound. Repeated over a generate loop it yields a left-leaning CONCAT of
64+ pieces. `V3Premit` runs **before** `V3Expand` (Verilator.cpp: Clean → Premit →
Expand) and gives every wide sub-expression a temporary, so the chain becomes 64
`ASSIGN(tmp_k, CONCAT(tmp_k-1, piece))`. `V3Expand::expandWide(ASSIGN, CONCAT)` only
expands when `widthWords() <= expandLimit` (64 words); 518-word temporaries fall back to
`VL_CONCAT_WIW/WWW` runtime calls that copy the running vector. The unmerged part-select
assignments would have gone through `expandLhs` → `ASSIGNSEL(const,wide)`
(V3Expand.cpp:517), which emits stores for the touched words only — linear.

**Fix landed (patch 0001)**: refuse the merge when the merged select exceeds
`VL_QUADSIZE` (64 bits). Narrow merges keep their benefit. Accuracy: none at stake — it is
the same assignment set, emitted differently. Carry-over: applies to any design whose
generate loops fill wide packed structs (RVFI bundles, scoreboards, AXI struct arrays,
gate-level netlists assembling buses bit by bit — the netlist case is exactly a chain of
1-bit part selects, so the patch matters more there, not less).

A deeper redesign (not done): make V3Premit/V3Expand flatten a wide CONCAT tree into a
list of (piece, lsb) and emit per-word ORs of the overlapping pieces — linear for any
source shape (user-written `{a, b, c, …}` of wide pieces included). That is the
general fix; the patch covers the compiler-generated case that dominates here.

### 2.2 Hybrid logic from combinational-loop breaking (V3Sched)
`V3Sched::breakCycles` turns every UNOPTFLAT loop into "hybrid" logic sensitive to
*changes* of the loop variables (`ET_CHANGED`), implemented as `__Vtrigrprev` copies
compared word-by-word in `_eval_triggers__act` and as extra act-region iterations until
no trigger fires. 247 suppressed UNOPTFLAT warnings on the single-core testharness;
stats: `size of class: hybrid 47,285` nodes (7 % of the logic). The loops are the
classic false ones through packed aggregates: `axi_xbar.mst_resps`, `dm_axi_m_resp`,
the `axi_demux` r/b muxes and `rr_arb_tree` indices, `fpnew_*` `*_pipe_ready[0:N]`
chains, `wt_dcache_ctrl`/`wbuffer`/`wt_axi_adapter` request structs, `csr_regfile`
read/exception flags, `scoreboard.issue_pointer[NrIssuePorts:0]`, `g6lc_iq.ready`,
`fetch_valid_if_id`, the perf-counter event bundle (`cva6.sv:3077`, through which many
core signals become one pseudo-loop), `decoder.instruction_o`, `lzc` nodes (already
split by the `split-counter.vlt` control).

Cost: ~5 % in trigger evaluation plus the re-run of hybrid functions in the 1.9
act iterations per step. Fix without RTL: a `.vlt` control with `split_var` for the
aggregates in the loops (Verilator splits the variable into fields/elements internally;
semantics unchanged). Verilator rejects some (`SPLITVAR` warning) — ports used whole,
variables passed to functions — those need a different cut (the `isolate_assignments`
metacomment, or accepting the hybrid). A compiler redesign worth more: **automatic
splitting of packed aggregates that appear in a comb loop** (V3SplitVar driven by
V3Sched's cycle report) — accuracy-preserving by construction, and it is what every
user ends up doing by hand.

### 2.3 Trigger vectors and the eval loop (verilated_types.h, V3Sched)
`VlTriggerVec` is `std::array<bool, N>`; `any()` is a linear scan, `set()` a per-flag
OR, and the generated `_eval_triggers__act` evaluates all ~400 trigger expressions
every iteration (edge detect = compare against `__Vtrigprevexpr`, change detect =
XOR-reduce of every word plus a copy). Redesign options (all accuracy-neutral):
bit-packed trigger vectors with a single 64-bit `any()`; write-side dirty marking for
change triggers (set a flag where the variable is written, instead of comparing the
whole aggregate after the fact) — larger codegen change, removes the 1,542-word
compare+copy of `mst_resps`; or simply eliminating the hybrid class (2.2), which makes
the change triggers disappear.

### 2.4 Code volume and the instruction cache
5.4 % I1 miss rate per instruction is as expensive as the instructions themselves.
Sources: `--unroll-count 256 --unroll-stmts 131072` (64-entry loops over packed arrays
are fully unrolled because packed-array element access needs constant indices);
`-output-split-cfuncs 0` (no function splitting → huge functions, fine for locality but
no cold/hot separation); `--assert` adds a branch per immediate assertion (hundreds in
the OoO blocks); `-DVL_DEBUG` adds `Verilated::debug()` tests on debug paths. Levers,
in order of expected value: profile-guided optimisation of the C++ (`-fprofile-generate`
→ training run → `-fprofile-use -fprofile-correction`: hot/cold splitting and layout,
typically 10–30 % on Verilated models), `-march=native` (vector copies/ANDs of wide
words; small), unroll limits closer to the default (code size vs per-iteration dynamic
bit selects — measure), a fast-build variant without `-DVL_DEBUG` (keep `--assert`).

### 2.5 Wide-word arithmetic and host intrinsics (verilated_funcs.h)
All wide operations are scalar loops over 32-bit `EData` words: `VL_ASSIGN_W`,
`VL_AND/OR/XOR_W`, `VL_EQ_W`, `VL_REDOR_W`, `VL_SHIFTL/R_WWI` (word shift + bit shift
through `_vl_insert_WW`), `VL_CONCAT_W*`. GCC at `-O2/-O3` turns the copy/AND/OR/XOR
loops into vector code or `memcpy`; with `-march=native` into AVX2/AVX-512. The
dependency-carrying ones (shifts by non-multiples of 32, inserts at arbitrary offsets,
the per-link concat) do not vectorise. Explicit intrinsics (Highway/xsimd as a portable
layer, or AVX2 `_mm256_alignr_epi8`/`_mm512_permutex2var` for cross-word shifts,
`_mm256_cmpeq_epi32` + `movemask` for equality/change detection) would help those —
but after 2.1 the wide-op share of this model is ~5 %, so intrinsics are a second-order
lever here. Where SIMD would pay structurally is 2.6.

### 2.6 Array-of-struct scans (the OoO CAMs) — the structural lever for SIMD
The issue queue, LSQ, ROB, scoreboard and the predictor tables are scanned every cycle
(64 entries × compare/age/ready). Verilator unrolls them into 64 scalar bodies with
bit extraction from packed vectors; the host executes ~hundreds of instructions per
entry. A Verilator redesign that lowers *packed arrays indexed by a loop variable* into
word-aligned per-field unpacked arrays (struct-of-arrays) would keep the loops as loops
over contiguous `uint32_t`/`uint64_t` fields — exactly what the C++ auto-vectoriser
needs (8–16 compares per AVX instruction), with no RTL change and bit-exact results.
This is the "better data structures" item: it is a lowering pass (an extension of
V3SplitVar toward "split packed arrays into unpacked per-field arrays when every access
is per-element"), not a library. Effort is high (weeks), payoff is the one that could
be ×2 on OoO-class designs.

### 2.7 Multithreading (V3Partition, verilated_threads.h)
`--threads N` partitions the eval into MTasks by a static cost model
(`V3InstrCount`) and runs them on a spinning thread pool (`VlMTaskVertex`
`waitUntilUpstreamDone` → `std::this_thread::yield()`). The server MT4 model shows
~390 % CPU but only ~1.5–2× over one thread: partition imbalance and the per-MTask
synchronisation. `--prof-pgo` (run with `+verilator+prof+exec+start+1`, feed
`profile.vlt` back) replaces the static costs with measured ones — the cheapest
multithreading win. Hierarchical blocks (`/*verilator hier_block*/` on the core wrapper —
a metacomment, not RTL) give per-core compilation units and natural partitions, and cut
rebuild time for the 4-core model.

### 2.8 Harness C++
Preload: write the ELF segments straight into the simulated memory array instead of
through the hexwriter map (6.8 s → <1 s per run). Per-cycle DPI (`SimJTAG`/`SimDTM`
ticks): not visible in the profile when JTAG is disabled; keep it that way for speed
runs.

## 3. Gate-level and SDF carry-over

What carries over as-is: everything that reduces per-evaluation instructions in
Verilator's codegen (2.1, 2.3, 2.4, 2.7) applies equally to a post-place-and-route
netlist compiled with the same Verilator — a netlist is the extreme case of 2.1 (buses
assembled from 1-bit nets) and of 2.4 (code volume: one function body per cell
cluster). `split_var` controls written for RTL aggregates do **not** carry over (the
netlist has no aggregates); the netlist has no false loops of that kind either, so 2.2
is moot there. 2.6 is RTL-shaped and does not apply to a netlist.

What Verilator cannot do: **SDF back-annotation is not supported** (no `$sdf_annotate`;
`specify` blocks are ignored, `SPECIFYIGN`). Verilator's `--timing` executes `#`
delays and event controls with its own timing scheduler, but a gate-level model with
per-cell `#(rise,fall)` delays derived from SDF means millions of delayed events per
cycle — orders of magnitude slower than zero-delay, and not what Verilator is built
for. Honest plan: gate-level **functional** (zero/unit-delay) regressions in Verilator,
using the same harness and the fast models' build recipe (patched compiler, PGO); SDF
timing simulation of selected blocks in an event-driven simulator (Icarus for small
blocks, a commercial simulator for the full netlist), driven from the same test
payloads so the two agree on the architectural trace. Any SDF→`#delay` conversion tool
for Verilator should be treated as an experiment, not a qualification path.

The design-side implication is the one that matters for "improvements that carry over":
keep sim-only probes under `translate_off`, keep assertions `--assert`-gated, and keep
the harness independent of RTL hierarchy names where possible (gate-level flattening
renames everything) — probes that reach into hierarchy (`i_frontend.gen_tage_lite…`) are
RTL-only by nature and must be `ifdef`-able out of a netlist build.

## 4. Methodology — large passes with minimal validation

- **Measure in instructions, not seconds.** callgrind Ir/cycle on the s11 probe is
  deterministic and immune to builder load; wall-clock cycles/s on a 200 k-cycle run
  confirms. The A/B gate for a compiler/recipe change is: Ir/cycle down, and the
  retirement trace of the probe byte-identical (the probe's `trace_rvfi` sha) — a
  compiler change that alters RTL semantics shows up there first.
- **One short exactness battery per compiler change**, not the boots: the 11 frozen
  probes + FP suite on `g6lc64_ooo` (Spike retirement-exact, 15 min), one int2_l3
  directed set. The strict boots and anchors are run once per *landed* compiler
  version, not per experiment.
- **Compile less**: ccache fronts the C++ (`SOFT_LADDER_BUILD_OBJCACHE=ccache`); a
  Verilator-only change (patch, `.vlt`) invalidates everything, so batch such changes;
  recipe-only changes (`OPT_FAST`, `-march`, PGO) recompile but re-verilate nothing;
  single-core models (85 files, 3 min) for codegen experiments, the MT4 server (420
  files, 40–60 min) only for the final measurement.
  *Measured (builder, 2026-10-12, `g6lc64_ooo`, `-O2`):* one persistent
  path-independent cache (`CCACHE_DIR=/opt/testharness/cache/ccache`, `hash_dir=false`,
  `CCACHE_BASEDIR=<run dir>`, 60 GB, sloppiness `include_file_ctime,include_file_mtime,
  pch_defines,time_macros`) — cold 58/58 misses, ≈ 90 s; a rebuild of the same
  generated sources from another run directory 37/58 hits (the `__Syms`/harness units
  miss on their embedded paths); the first MT4 server build after the fork landed:
  27,231 hits / 34,373 misses over 61,604 compiler calls. **Clang 18** (`T16_CXX=clang++-18`,
  which also passes `--compiler clang` to Verilator): the bfd linker under the clang
  driver does not resolve `libriscv.so`'s `yaml-cpp` references from `-lyaml-cpp`
  (undefined `YAML::detail::node_data::end()` and the `YAML::Exception` vtable);
  `-rdynamic -Wl,--whole-archive,<spike>/lib/libyaml-cpp.a,--no-whole-archive` on the
  link line fixes it (integration workaround, kept in the driver). Clang cold build
  ≈ 93 s vs GCC ≈ 90 s, s11 RVFI identical; `mold` is not installed on the builder
  (`SOFT_LADDER_BUILD_LINKER=mold` falls back to the system linker), `ld.lld` exists.
  Build-speed knobs are not a simulation-speed lever: the C++ of a server model is
  dominated by the few 30 MB units (`__Syms`, the big `_nba_sequent` files) that no
  cache or linker shortens.
- **Identity**: the Verilator work lives in the fork `github.com/etcimon/verilator`,
  branch `g6lc` (based on the pinned `v5.008`), pinned as the submodule
  `tools/verilator`; `build-platform/scripts/install-verilator-g6lc.sh` builds the pinned
  commit into `/opt/testharness/toolchains/verilator-v5.008-g6lc` (version string
  `5.008 (mod)`) and assembles a runtime dir (pinned headers + fork `verilator_bin`)
  that the build driver selects with `T16_VLT_ROOT` (the pinned `verilator` wrapper
  runs `$VERILATOR_ROOT/bin/verilator_bin`). A model built that way carries
  `recipe.verilatorRoot` in its manifest; qualification records say which compiler
  built the model.
- **Yosys fork**: the synthesis-speed changes live in `github.com/etcimon/yosys`,
  branch `g6lc`, pinned as the submodule `tools/yosys` (not under `tools/verilator`).
  `build-platform/scripts/install-yosys-g6lc.sh` builds that gitlink into
  `/opt/testharness/toolchains/yosys-g6lc`. `tools install formal` builds the same
  checkout into `workspace/tooling/formal` and adds SymbiYosys. Verif prefers the
  g6lc binary when it is installed, then `toolchains/formal/bin/yosys`.
  Landed, and checked against Yosys's own tests (not a CVA6 timing run): `SigMap`
  stores a whole-wire connection as one alias and keeps a constant tie-off visible
  past the union-find root; `check` builds a bit-level loop graph only for wires
  that sit in a wire-level cycle; `opt_merge` joins a removed output in one `add`
  and rehashes only cells that read a redirected wire. `opt -fast` still runs until
  `opt_dff` stops changing the design. The server synth smoke stays
  `proc; opt_clean; stat; check -latchonly`.

## 4a. What the first compile/bisect of the redesign taught (2026-10-11)

- **The pinned "review-private" runtime is not upstream 5.008.** Its `verilated_funcs.h`
  differs in exactly one place: the eight `VL_CONSTHI_W_*X` helpers zero-fill the upper
  words relative to the *array base*; upstream 5.008 (`VL_C_END_`) indexes from the
  offset pointer `o = obase + VL_WORDS_I(lsb)` and writes `VL_WORDS_I(lsb)` words past the
  end of the array. In this design that is the 19,257-bit `check_cfg` task local
  (`VlWide<602>` on the stack): the overflow smashes the caller frames up to the process
  environment (`getenv` in `main()` faults) or silently corrupts state, depending on the
  frame layout. Any model built from unpatched 5.008 headers carries it; the fork now
  carries the fix as `VL_C_END_HI_` in `include/verilated_funcs.h`.
- **Bisect by overlay, not by reasoning.** Five single-change compilers
  (`vlt-A1`…`vlt-C`) built in parallel and five 3-minute single-core models found two
  real bugs in one round: (1) V3Premit lowering must use `widthMin()` for concat offsets
  and leaf widths (`width()` is the padded physical width of narrow operands — the last
  leaf wrote past the variable); (2) a SenExprBuilder flag shared across the trigger
  functions must re-add its pre-update per round (`m_hasPreUpdate`), otherwise the `act`
  function reads a stale flag computed by `stl` and the hybrid logic never re-triggers
  (design hangs in the bootrom).
- **Exactness gate**: the s11 FP probe's `trace_rvfi_hart_00.dasm` sha (`de4f42cfe7cb`)
  is identical for the pinned compiler, for the const-argument-only compiler, for the
  narrowed-sensitivity-only compiler, and for the full redesign (`vltwt3`).
- **First numbers (callgrind Ir per cycle on s11, eval only, `-O2`)**: pinned 590 k;
  V3Task constant-argument substitution alone **489 k (−17 %)** — the per-call copies of
  the configuration struct (`__Vfunc_*__Cfg`, 602 words each) are gone and the region
  checks fold; full redesign **482 k (−18 %)**, `VL_CONCAT_WIW` calls 133 → 0, `expand
  limited` 173 → 77, 37 wide concat assigns (360 leaves) lowered. The concat chain's
  Ir share at `-O2` was small (vectorised copies) — its cost is memory traffic (43 ×
  2 KB per evaluation), which the wall-clock and D1 numbers measure, not Ir. I1 misses
  rose 352 M → 399 M (constant folding duplicates code at call sites).
- **Bench battery** (`verif/regress/remote/simperf_bench.sh`, launched by
  `t21/launch-simperf.sh`): per model — s11 and `ooo_wrongpath_replay` under callgrind
  (Ir/cycle, I1 misses/cycle, eval only), a 300 k-cycle spin for cycles/s with startup
  subtracted, optional boot segment, and the Verilator structure counters. Results
  (`g6lc64_ooo`, `-O2`, builder load ≈ 4):

  | model | s11 Ir/cyc | s11 I1/cyc | wprp Ir/cyc | wprp I1/cyc | spin cycles/s (sequential A/B ×2) |
  |---|---|---|---|---|---|
  | pinned 5.008 | 590,041 | 32,165 | 635,998 | 37,514 | 13,257 / 13,251 |
  | + V3Task const args only (`vltC`) | 489,046 | 34,852 | 582,823 | 43,792 | — |
  | full redesign (`vltwt3`) | 482,150 | 36,512 | 582,535 | 46,311 | **13,838 / 13,850 (+4.4 %)** |

  Reading: instructions −18 % / −8 %, instruction-cache misses +13 % / +23 %, wall-clock
  +4.4 % on the low-activity spin. The model is instruction-cache bound; the Ir savings
  only convert into time once the code layout is fixed — profile-guided optimisation
  (`-fprofile-generate` on s11+spin, then `-fprofile-use -fprofile-correction`, hot/cold
  splitting) is the next recipe step, and the A/B must move to a datapath-heavy segment
  (OpenSBI boot window) rather than the spin.

## 4b. Second pass — scheduler structure from the trigger trace (2026-10-11)

Instrument first (RT-H1): the harness allowlist now passes every `+verilator+…` runtime
option (`g6lc_tb.cpp`), so a `VL_DEBUG` model dumps its active triggers with
`+verilator+debug` and a `--prof-exec` model records the execution profile; the fork's
scheduler brackets every act/nba iteration with `EVAL_LOOP_BEGIN/END` records so
`verilator_gantt` shows pass counts and their cost (5.008 never emitted them).

Trigger activity over 2,500 cycles (5,000 eval steps) of the s11 probe, `g6lc64_ooo`:

| model | `_eval_triggers__act` | `_eval_act` | `_eval_nba` | hybrid firings | distinct act triggers |
|---|---|---|---|---|---|
| fork compiler, narrowed sensitivities | 22,972 (4.6/step) | 11,133 (2.2/step) | 6,839 | 26,516 | 324 |
| + `verilator-split-loops.vlt` (91 vars split) | 21,481 | 9,644 | 6,837 | 16,400 (−38 %) | 114 |

What the trace named: the clock fires once per cycle, but `scoreboard.issue_pointer`
(hybrid) fires 2,545 times — every cycle plus re-iterations — followed by `g6lc_iq.ready`,
`instr_queue.fire_prefix`, `frontend.fetch_address`, the two decoder `instruction_o`
structs and the AXI demux/mux arbiters. Each firing is one more act pass. A
`@(negedge clk_i)` trigger fires 2,500 times: it came from one sim-only probe
(`instr_queue.sv` `[iq]` trace block, `translate_off`) and forced a full act/nba pass on
every negedge step of every run — sampled on the posedge now. The remaining big hybrids
cannot be split by control file: `issue_pointer` and `g6lc_iq.grant` are indexed
dynamically, `g6lc_iq.ready/g/rem` are referenced hierarchically by the `cva6.sv`
probes (SPLITVAR "accessed from another module via a dot").

Effect on the bench (s11, eval only): Ir/cycle 482 k → **388 k (−34 % vs the pinned
590 k)**, I1 misses/cycle 36.5 k → **27.2 k (−15 % vs pinned)** — the first change that
reduced code-cache pressure, because fewer passes touch fewer functions per cycle.

### 4b.1 Two compiler changes that finish the job (fork, `vlt-wt-compile-5/7`)

The trace said which variables still could not be split and why: `issue_pointer[num_issue]`,
`hw[cur]`, `fmt_in_ready[dst_fmt_i]` are *run-time indexed* reads ("bit range cannot be
determined statically"), and a dozen `v[i]` accesses inside `for (int i …)` loops were
refused for the same reason because **upstream runs V3SplitVar before V3Unroll** — the
index is still the loop variable when the split pass looks at it.

1. **`Verilator.cpp`: unroll before split.** `V3Unroll::unrollAll` + `constifyAllLint` now
   run right after `V3Begin::debeginAll` (FORs are WHILEs by then) and before
   `V3SplitVar::splitVariable`; the later unroll call finds nothing left. Same final code,
   loop-indexed accesses are constant selects at split time.
2. **`V3SplitVar.cpp`: element reads with a run-time index become a mux.** A read
   `SEL(var, idx*W, W)` of a variable of `N*W` bits (N ≤ 16; V3Width's form for `v[idx]`
   on a packed array, with the SEL/EXTEND/CCAST width wrappers looked through) no longer
   blocks the split: the plan forces the N element boundaries and the read is rewritten
   `idx==N-1 ? e[N-1] : … : idx==0 ? e[0] : '0` over the element variables (indices the
   index width cannot reach are left out; an out-of-range index reads zero where the
   original read X). Micro-test `/tmp/splt/t.sv` on the builder: no UNOPTFLAT left,
   simulation PASS.

| model (2,500 cycles, 5,000 steps) | split vars | hybrid class | `_eval_triggers__act` | `_eval_act` | `_eval_nba` |
|---|---|---|---|---|---|
| pinned 5.008 | 29 | 47,285 | — | — | — |
| fork + narrowed sens. | 29 | 40,765 | 22,972 | 11,133 | 6,839 |
| + split .vlt (`split5`) | 92 | 34,529 | 16,471 | 7,137 | 4,334 |
| + unroll-before-split (`wt5`) | 115 | 10,515 | 15,909 | 6,743 | 4,166 |
| + dynamic-index mux (`wt7`) | 121 | **10,226** | **14,352** | **5,261 (1.05/step)** | **4,091** |

`wt7`: s11 and `ooo_wrongpath_replay` RVFI traces byte-identical to the pinned model; the
act region now runs once per evaluation step (it ran 2.2 times), and the hybrid triggers
left are the testharness encoder's gated clocks and a few 1-bit true loops. s11 Ir/cycle
`wt5` 350,560 (−41 % vs pinned), I1 24,829/cycle (−23 %).

Bench (`simperf_bench.sh`, callgrind Ir and I1 misses per cycle, eval only) and the
sequential wall-clock A/B on the 300 k-cycle spin (builder load ≈ 7, two alternations):

| model | s11 Ir/cyc | s11 I1/cyc | wprp Ir/cyc | wprp I1/cyc | spin cycles/s |
|---|---|---|---|---|---|
| pinned 5.008, `-O2` | 590,041 | 32,165 | 635,998 | 37,514 | 13,908 / 11,078 |
| fork `wt7` + split .vlt | **270,342 (−54 %)** | **19,020 (−41 %)** | **331,885 (−48 %)** | **24,947 (−33 %)** | 23,256 / 20,979 (×1.7–1.9) |
| `wt7` + PGO (`T16_PGO=1`) | — | — | — | — | **49,423 / 39,894 (×3.5–3.6)** |

PGO is trained on s11 + the spin, so its spin figure is favourable; the Ir/I1 columns are
layout-independent and hold for any workload. Both PGO models are RVFI-exact on s11 and
`ooo_wrongpath_replay`.

### 4b.2 Owed-before-adoption battery (2026-10-11, fork `wt7`/`wt9`, runtime header `5daf4f78…`)

Bookkeeping first: the three review runners (`run_ooo_fp_review.py`,
`run_mc_int2_review.py` directed route, `run_opensbi_source_review.py`) hard-pin the
qualified private runtime (`dfbc2c4a…`). They now accept a model whose runtime header
hash is **declared** in `REVIEW_EXPERIMENTAL_RUNTIME_SHA256` and record
`runtimeQualified=false` (+ the hashes) in every result — such runs are retirement /
performance evidence, never qualification evidence. `t21s-build.sh` writes the real
runtime header into the manifest (it used to copy the qualified constant). The batch
launchers (`t13-fpsuite.sh`, `probes-t21f.sh`, `t20/directed-ooo.sh`, `t17/boot.sh`,
`osbi-launch-t21q.sh`) forward the variable.

| gate | model | result |
|---|---|---|
| 11 frozen probes (m04/m20/m32–m37 Spike retirement compare, s11, ilp, dep) | `ooocoh-t21s-ooo-vltwt7-split-pgo-build` | all `pass`, `retirementsMatch=True`, cycles identical to the T21 pinned references (`d=0`; s11 −136 is the T21e predictor delta shared with the pinned model) |
| FP suite 11 stages × (pos, neg) | same | 11/11 pos pass, 11/11 neg fail-as-expected, `retirementsMatch=True`, cycles identical (s10/s11 carry the known T21e deltas) |
| `ooo_wrongpath_replay` | same | matched, 10,323 cycles |
| server MT4 300 k-cycle 8-hart OpenSBI segment | `ooocoh-t21s-server-vltwt3-split-mt4-build` vs pinned `ooocoh-t21i-server-mt4-build` | per-core RVFI traces **byte-identical**; wall 207.9 s → 100.1 s, **1,443 → 2,996 cycles/s (×2.08)**, idle builder |
| anchors: `g6lc64_ooo_int2_l3` ring-16 24 M (`ooocoh-t21s-int2l3-wt9-r16-24M-c`), `g6lc64_smt2_ooo_int` strict mixed (`…smt2int-wt9-osbi-c`), `g6lc64_smt2` (`…smt2-wt9-osbi-c`), reference firmware of the T21i anchors re-used | `*-vltwt9-split-build` | **PASS 18,357,056 / 10,472,823 / 12,391,556 cycles — identical to the pinned anchors; every RVFI trace byte-identical** (`b58a6368…`/`62650353…`, `3d103a38…`, `0d6e9edb…`). int2_l3 wall ≈ 46 min for 18.36 M cycles (≈ 6.6 k cycles/s, loaded builder) against ≈ 4 h pinned. (The proxy `py` waiter of the int2_l3 run died at 1,318 s with rc=255 while the simulator kept running under its `timeout` wrapper — harvested from `output/trial/`; cause not established.) |

Datapath-heavy timing A/B (the OpenSBI boot window, not the spin): `g6lc64_ooo_int2_l3`
(2 cores + L2/L3, single thread), 400 k cycles of the dual-hart boot, alternating runs on
a quiet builder (load ≈ 2): pinned **4,996 / 4,994 cycles/s**, fork `wt9` + split .vlt
**9,392 / 9,335 cycles/s (×1.88 wall, ×2.08 after the ≈ 8 s preload)**, no PGO.

**Server MT4 execution profile** (`--prof-exec`, `wt3`-split model, 100 evals of the boot
segment, `verilator_gantt`): 58 MTasks, **all-thread efficiency 16 %, measured speedup 1.9
with 4 threads (predicted 3.1)**; the longest MTask ran 3.77 M ticks against a predicted
164 k (`log(p2e) = −3.1`), mean `log(p2e) = −2.0` — the static cost model under-estimates
the real MTask costs ~7× with a 2× spread, so the partition is unbalanced. That is what
Verilator's own `--prof-pgo` is for (measured MTask costs → `profile.vlt` → re-partition):
`ooocoh-t21s-server-vltwt9-split-profpgo-mt4-build` (`--prof-exec --prof-pgo`) is
building to produce the profile; the final server model then takes `profile.vlt` through
`T16_EXTRA_VLT` plus the C++ PGO. Host note: the builder is an EPYC 4244P (6 cores / 12
threads); a 4-thread model shares it with the builds.

**`wt7` + C++ PGO server model** (`ooocoh-t21s-server-vltwt7-split-pgo-mt4-build`,
finished by `pgo-finish-remote.sh`; the `__Syms` object compiled at `-O1` with the profile
to bound the phase-2 time — the `-O2` compile of that 30 MB file was killed after 1 h):
300 k boot cycles, same load (≈ 4, a build compiling alongside), sequential:

| model | wall | cycles/s | vs pinned |
|---|---|---|---|
| pinned T21i MT4 | 324.5 s | 924 | — |
| fork `wt3` + split .vlt | 112.2 s | 2,673 | ×2.9 |
| fork `wt7` + split .vlt + C++ PGO | **88.8 s** | **3,379** | **×3.66** |

RVFI traces identical across the three. Its gantt: 54 MTasks, 323 region iterations per
100 evals (3.2 act/nba passes per eval — the HPDCACHE loops are not in the control file
yet; `vlt_autosplit.py` on a server `--report-unoptflat` is the next structural step),
all-thread speedup still **1.9 of 4** (predicted 3.4; worst MTask `log(p2e) = −3.3`): the
thread partition, not the per-thread code, is now the server's largest single loss.

Verilator-PGO step: `ooocoh-t21s-server-vltwt9-split-profpgo-mt4-build` (`--prof-pgo`)
ran the 300 k segment (RVFI exact) and wrote `profile.vlt` with the measured cost of each
of the 54 MTasks (`/opt/testharness/runs/prof-profvlt-server/profile.vlt`; costs span
1.6–9.7 G ticks against predictions of ~0.1–0.2 M). The control file also grew by the 38
server loops `vlt_autosplit.py` found with the first 71 entries applied (HPDCACHE request
structs, `axi_xbar.mst_reqs/slv_resps`, `g6lc_cluster` req/resp, `g6lc_smt_csr_bank`,
TAGE `t_index/any_hit/t_tag`, ALU internals; `g6lc64_ooo` with the 109-entry file: 137
split vars, hybrid 10,226, s11/wprp exact). The final server model
`ooocoh-t21s-server-vltwt9-final-pgo-mt4-build` = `wt9` + 109-entry .vlt + `profile.vlt`
(`T16_EXTRA_VLT`) + C++ PGO (phase 2 now compiles `__Syms` at `-O1` first).

**Result of the final model** (300 k boot segment, idle builder, alternating with the
`wt7`+PGO model): final **3,265 / 3,254 cycles/s** vs `wt7`+PGO 3,318 — **the
`profile.vlt` re-partition and the 38 extra splits bought nothing measurable** (RVFI
identical). Its gantt: still 54 MTasks, all-thread speedup **2.0** (predicted 3.3),
longest-thread efficiency 18.8 % — the critical-path thread is *busy* only a fifth of the
eval time, so the loss is synchronisation/dependency waiting between 54 coarse MTasks
(≈ 2 region iterations per eval, each with its barriers), not cost mis-prediction. The
trigger trace on the server (2,000 cycles): 3.0 trigger evaluations, 1.13 act and 0.86
nba passes per step; the remaining hybrids are core-0 frontend `fetch_address/demand_req/
pf_req/kill_s2`, `g6lc_iq.ready` (dynamic index), `fetch_valid_if_id`, the xbar/L2/L3
`slv_resp_o` port structs and `alu2.result_o`; cores 1–3 (idle harts) fire nothing — and
are still evaluated every cycle (lever 2 below). Next for the partition: finer MTasks
(`--threads-max-mtasks` sweep), 8 threads on the 12-thread host, `hier_block` per core so
each core is one coarse unit with a private critical path; each is a server rebuild
(≈ 2 h with PGO) and should be measured without PGO first.

One more compiler defect found by the int2_l3 build (not by `g6lc64_ooo`): V3Premit's
concat lowering reached a `createDeepTemp` assignment (`__Vtemp = CONCAT`) — those are
visited after all when created while a lowered leaf is being processed — and the
unaligned part-select stores then read a word of the statement temporary before any
assignment to it (`V3Subst.cpp:135` internal error). Fix: never lower into a
`STMTTEMP` destination (`wt9`, `vlt-wt-compile-9`); an A/B knob
`VERILATOR_NO_CONCAT_LOWER=1` stays in the fork for bisecting. `g6lc64_ooo` `wt9` is
s11/wprp-exact.

A Verilator quirk worth knowing: V3SplitVar is **not monotone in its input** — removing
the *refused* entries from the control file made a dozen other variables unsplittable
(92 → 52 splits, hybrid 34,529 → 42,667) on the same RTL. Keep refused entries in the
file; they cost a SPLITVAR warning and nothing else.

Artifacts of this pass: `build-platform/scripts/verilator-split-loops.vlt` (hand-curated
from `--report-unoptflat`, 65 entries, `T16_SPLIT_VLT=1` in `t21s-build.sh`);
`verif/regress/remote/vlt_autosplit.py` (turns a `--report-unoptflat` log into the
control file — the two-pass "auto-split" flow for other configurations such as the
HPDCACHE server); `+rvfi_notrace` (tracer writes off for kernel-length runs, tohost
detection kept); PGO recipe in the driver (`T16_PGO=1`: instrumented build → s11 +
spin training → `-fprofile-use -fprofile-partial-training` recompile).

## 5. Status and next measurements

| item | state |
|---|---|
| callgrind toolchain on the builder | done |
| fork commit `1878fd75` (no wide MultiSel merge) | fork + submodule pinned; compiler built on the builder; model `ooocoh-t21s-ooo-vltp2-build` (`T16_VLT_ROOT`) still shows the 16,577-bit chain — the merge also happens in the DFG (below) |
| fork commit `706fb1cd` (DFG `canonicalizePacked` coalescing bounded at 64 bits) | pushed; compiler rebuild from this pin launched on the builder; model not yet rebuilt |
| **uncommitted redesign in `tools/verilator` (working tree)** — compiles (`verilator-v5.008-g6lc-wt`, `vlt-wt-compile-4`), model `ooocoh-t21s-ooo-vltwt3-build` **s11 retirement-exact** | V3Premit: wide `ASSIGN(var, CONCAT-tree)` lowered to one part-select assignment per leaf (`widthMin()` positions). V3Expand: wide `==`/`!=` and `|`/`&`/`^` reductions above `--expand-limit` stay runtime calls. `verilated_funcs.h`: `VL_EQ_W` via `memcmp` above 8 words; **`VL_CONSTHI_W_*X` overflow fixed (`VL_C_END_HI_`)** — the pinned private runtime's one patch, now in the fork. `verilated_types.h`: `VlTriggerVec` bit-packed with a bool-lvalue proxy. `V3SenExprBuilder`: wide change-detected signals compare once into a module-level `__Vtrigchgexpr` flag recomputed per trigger function, `__Vtrigrprev` copied only on change. `V3SchedAcyclic::fixCuts`: hybrid sensitivity narrowed to the constant bit ranges the logic reads. `V3Task`: constant actuals (incl. parameter structs) substituted into inlined bodies instead of copied into a temporary. Owed before adoption: the 11 frozen probes + FP suite + anchors with this compiler, PGO recipe, a datapath-heavy timing A/B, the MT4 server build. |
| `.vlt` split_var for the hybrid loops | **done** — `build-platform/scripts/verilator-split-loops.vlt` (`T16_SPLIT_VLT=1`), 71 entries incl. the refused ones (V3SplitVar is not monotone; keep them); generator `verif/regress/remote/vlt_autosplit.py` |
| fork: unroll before split (`Verilator.cpp`), dynamic-index element reads as a mux (`V3SplitVar.cpp`), act/nba loop records under `--prof-exec` (`V3Sched.cpp`) | **done** (`vlt-wt-compile-7/9`); model `ooocoh-t21s-ooo-vltwt7-split-build` s11 + wprp RVFI-exact; hybrid class 47,285 → 10,226, act passes 2.2 → 1.05 per step |
| fork commits | **seven commits on the fork's local `g6lc` branch** (`2321008fa` include fixes … `83d24ed6e` prof-exec records, on top of `706fb1cd7`); **not pushed**, submodule pointer in the main working tree moved but not committed. The builder's `verilator-v5.008-g6lc-wt` is built from the same sources (`vlt-wt-compile-9`). |
| PGO recipe (`-fprofile-generate/-use`) in the driver | **done** — `T16_PGO=1` in `t21/t21s-build.sh` (instrumented build via CXXFLAGS/LDFLAGS, s11 + spin training, `-fprofile-use -fprofile-partial-training` recompile); model `ooocoh-t21s-ooo-vltwt7-split-pgo-build` RVFI-exact, spin ×3.5 vs pinned |
| sim-only RTL hygiene for the scheduler | `instr_queue.sv` `[iq]` probe sampled on posedge (the model's only negedge logic — one act+nba pass per negedge step gone); `g6lc_iq.ready_dbg` view so the cva6.sv probe no longer pins `ready` whole; `+rvfi_notrace`; `+verilator+…` pass-through |
| server (`g6lc64_ooo_server`, MT4) with the fork + split .vlt + `--prof-exec` | `ooocoh-t21s-server-vltwt3-split-mt4-build` (fork `wt3` generation): 300 k-cycle OpenSBI segment **1,443 → 2,996 cycles/s (×2.08)**, per-core RVFI byte-identical to the pinned model. `wt7`+PGO server (`ooocoh-t21s-server-vltwt7-split-pgo-mt4-build`): phase-1 link through the `__Vilp` resume path lacked the instrumentation (driver fixed: `LINK=g++ -fprofile-generate=…` on the resume make — LDLIBS/LDFLAGS carry the libraries and must not be overridden); finished by `t21/pgo-finish-remote.sh` on the builder (43 profiles from 2 × 150 k boot cycles), phase-2 recompile in flight — harvest: `tail /opt/testharness/runs/ooocoh-t21s-server-vltwt7-split-pgo-mt4-build/output/driver.log`, then `q-srvab.sh` (300 k A/B) and the gantt (`+verilator+prof+exec+start+…`) |
| harness preload rewrite | not yet |
| Verilator 5.03x A/B | not yet (pinned 5.008 stays the qualification compiler) |
| struct-of-arrays lowering (2.6) | assessment only |

## 6. After the fork: where the next 10× would have to come from (2026-10-11)

Instrument first. Callgrind with cache and branch simulation on the final single-core
model (`ooocoh-t21s-ooo-vltwt7-split-pgo-build`, s11, 10,941 cycles, eval only):

| per simulated cycle | pinned 5.008 | fork + .vlt + PGO | what it says |
|---|---|---|---|
| instructions | 590 k | **253 k** | −57 % |
| L1I misses | 32.2 k | **15.9 k** | 1 miss per 15.9 instructions ≈ **one per 64-byte line** |
| L1D misses | 10.7 k | 2.6 k | data is not the problem |
| LL misses | ~0 | 5 | everything fits L2/L3 |
| conditional branches / mispredicts | — | 21.1 k / 691 | ≈ 3.3 % mispredict rate |

One L1I miss per cache line means **no instruction-cache reuse inside a simulated
cycle**: the model streams ≈ 15.9 k lines ≈ **1.0 MB of distinct code per cycle** from L2
(text 6.9 MB single core, 90.8 MB server MT4). That is the signature of cycle-based
straight-line simulation of a large design, and it is what bounds the IPC (≈ 1.5
measured): the host is fetch-bandwidth bound, not ALU bound. PGO's large gain came from
packing the hot paths (fewer partially used lines); AVX/intrinsics cannot help a
front-end-bound loop. The remaining 253 k instructions are 28 % + 19 % in the two merged
`_nba_sequent` functions (the per-cycle sequential logic of the OoO core: IQ/scoreboard/
ROB/cache arrays unrolled per entry), 14 % + 4 % in the two big `_nba_comb` functions,
4.5 % trigger evaluation, 1.5 % `$sformatf` (the RVFI tracer; off with `+rvfi_notrace`).

Server MT4 (`--prof-exec` gantt): 4 threads deliver **1.9–2.0×** (predicted 3.3–3.4) and
`profile.vlt` did not move it (§4b.2): the partition is synchronisation-bound (54 coarse
MTasks, the critical-path thread busy 19 % of the eval), so lever 1 below is about
granularity and per-core hierarchy, not cost calibration.

### 6.1 The three levers that are each worth more than 1.5× (ranked by evidence)

1. **Parallelism that exists in the design but not in the partition** (server only).
   `profile.vlt` re-partition measured: no gain (synchronisation-bound). Then:
   hierarchical blocks per core (`hier_block` on the `g6lc_cluster` core instances through
   the control file; no RTL change) so the partitioner works on four equal units plus the
   uncore, and 8–12 threads on this 12-thread host. V3Partition's cost model
   (`V3InstrCount`) should also learn the measured ratio (mean `log(p2e) = −2`). Estimated
   ×1.5–1.8 on top of the current server speed.

2. **Not simulating idle cores** (the RTL change that *does* have a physical benefit).
   In the 8-hart OpenSBI boot one hart works while seven sit in the HSM `wfi` loop; in a
   Linux boot the secondary harts idle until SMP bring-up. Verilator still evaluates all
   four cores every cycle. A **core-level clock gate** (`tc_clk_gating`, enable = any hart
   of the core not in `wfi`, or an interrupt / debug request pending — computed from the
   ungated CLINT/PLIC/debug signals) is standard low-power design, a real power feature
   for the SoC, and in Verilator it removes the gated core's `always_ff` *and* the
   combinational functions guarded by that clock's trigger from every cycle in which the
   clock does not toggle. Expected: 1.5–3× on the server boot depending on how long the
   secondary harts idle; no change on the single-core profiles. Needs: the wake-up
   contract (interrupt pending must re-enable the clock before the hart samples it),
   formal of the gate enable, and the anchors re-qualified (cycle counts change only if
   wake-up adds latency — design it so it does not).

   **Implemented (2026-10-12, uncommitted):** `CVA6Cfg.CoreSleepGate` (user cfg +
   `check_cfg`: exclusive with `EnableAccelerator`; default 0 in every package, 1 in
   `g6lc64_ooo_server`). `core/csr_regfile.sv` exports `wfi_wake_o` — the `wfi_ctrl`
   wake condition recomputed from the raw interrupt lines, the Sstc comparators
   (`stimecmp_hit_d` from the ungated `rtc_time_i`) and the stable `mie_q`/`mip_q`
   bits, i.e. valid while the hart's clock is stopped (`mip_q` itself needs an edge);
   the SMT bank ORs it over harts; `cva6`/`ariane` export `core_wfi_all_o`
   (`&hart_halt`) and `core_wake_o`. `g6lc_cluster` keeps an ungated per-core AXI
   in-flight count (AW/AR issued vs B/R-last returned) and drives the existing
   functional ICG with `rel & ~(wfi_all & noc_idle & ~wake & ~debug & ~l1_inval &
   ~cmo_done & ~island_cpl)`; a `[sleep]` probe (translate_off) reports gated cycles
   and entries per core; sim-only assertions guard the count against underflow and
   saturation. Lint clean on `g6lc64_ooo_server` and `g6lc64_ooo`. Witness test
   `verif/tests/custom/multicore/mc_sleep_gate_wake.S` (M timer, Sstc timer,
   cross-core IPI wake, other cores parked): passes on the gate-less pinned model
   (tohost 1, 17,083 cycles; RVFI `5b4c34…`/`a0d36a…` are the exactness reference).
   **First measurements** (`ooocoh-t21t-server-{gate,nogate}-mt4-build2`, fork, split
   .vlt, MT4, same overlay, flag 1/0): the no-gate model reproduces the pinned witness
   byte for byte (`5b4c34…`/`a0d36a…`, 17,083 cycles). The gate model passes the witness
   (tohost 1, no trap, the `csr_regfile` wake-coverage assertion silent) with **core 0
   gated for 15,930 of 17,058 cycles (2 entries) and core 1 for 26 cycles (1 entry)**;
   its core-0 trace differs only in the `mtime` values read after each WFI: the first
   wake lands one mtime tick later, the second one tick earlier than without the gate —
   wake-up timing moves by a few cycles in either direction because the frontend of an
   ungated halted core keeps prefetching/speculating through the WFI loop, which the gate
   stops; architecturally invisible, so cycle counts of boots with WFI phases will shift
   slightly. The 300 k boot segment then exposed a harness interaction: the testharness
   pulses the *core* reset during its ELF preload while the uncore keeps running, so an
   AR issued before the pulse returns to a reset core and the in-flight count
   underflowed (my assertion stopped the run at 479 ns). Fix: the count saturates at 0
   (orphans are reported, not counted) and at 255 (a saturated count stays "busy"); model
   `ooocoh-t21t-server-gate-mt4-build3` carries it.
   **48 M strict boots, gate vs no-gate, run concurrently (`ooocoh-t21t-server-{gate,
   nogate}-osbi-48M-c`):** both hit the launcher's 4 h wall budget before the verdict —
   gate at **28 M** cycles, no-gate at **27 M** (≈ 1,944 vs 1,875 cycles/s with two MT4
   models sharing the 12-thread host). So on the 8-hart OpenSBI boot the gate's sleep
   saving (≈ +8 % in the parked phase, measured by trace growth) only just outweighs its
   awake penalty (−17 %): **net ≈ +4 %**. As a *simulation* lever it is marginal with the
   current partitioner; the reason is structural — a gated core's combinational functions
   stay in trigger classes shared with the uncore and are evaluated every cycle, only the
   `always_ff` work disappears, and the derived clock costs the partition. It stands as a
   power feature (that was its design rationale) and as the hook a better partition would
   exploit. No verdict (timeout ≠ failure): a single-model run with an 8 h budget, or the
   strict single-thread model, is still owed for the qualification record.

3. **Shrinking the instruction footprint per cycle** (compiler). Three concrete paths:
   - **Keep replicated loops rolled.** The builds use `--unroll-count 256 --unroll-stmts
     131072` (defaults 64 / 30): every per-entry loop over the IQ/ROB/scoreboard/caches is
     straight-line code — 64 copies of the same body, each executed once per cycle. A
     rolled loop costs dynamic indexing per iteration but is one copy in the cache. Cheap
     A/B first (defaults, then intermediate values) on the `g6lc64_ooo` bench; note it
     interacts with unroll-before-split (rolled loops keep their index dynamic, so the
     affected variables fall back to the dyn-mux path or stay whole).
   - **Data-driven evaluation of replicated structures (SoA, §2.6).** The step beyond
     rolling: emit the per-entry logic once as a loop over a struct-of-arrays, so an IQ
     wake-up compare is 64 iterations of a 20-instruction body (vectorisable) instead of
     1,280 straight-line instructions. This is the one place AVX would pay — after the
     footprint problem is solved, not before. A V3-level pass (recognise identical
     generate/for bodies differing only in the index, keep them as a loop over array
     element views) — large, and the most valuable long-term Verilator redesign for
     designs of this size.
   - **Function layout by trigger**: functions executed only when a rare trigger fires
     (debug, flush, exceptions) should not be interleaved with the per-cycle path; PGO
     does most of this, `-freorder-blocks-and-partition` is already on with `-fprofile-use`.

   **Measured (refuted for plain rolling):** `VERILATOR_UNROLL_STMTS=2000 / COUNT=64`
   (fork knob; the build flow pins `--unroll-stmts 131072` after the user arguments)
   keeps the 48 largest loops rolled — text 6.9 → 6.6 MB, s11 **Ir/cycle 270 k → 446 k
   (+65 %)**, L1I misses/cycle 19.0 k → 19.8 k (unchanged), RVFI exact. The rolled bodies
   were not where the per-cycle code volume is; the ≈ 1 MB/cycle is spread over the
   non-loop sequential logic. `--unroll-stmts 30` (Verilator's default) first hit an internal
   fault in the fork — bisected with `--debugi-V3SplitVar 5` under `stdbuf -o0` (the
   crash lost the buffered log tail): the dyn-mux rewrite registered the same `SEL`
   twice when it is the index of an unpacked-array write (`mem_n[issue_pointer[i]]`)
   and replaced it twice; fixed (dedup at registration + refusal of indices that
   reference another split candidate). With that fixed, `--unroll-stmts 30` stops on a
   genuine Verilator limitation in this design (`BLKLOOPINIT`: non-blocking array
   assignment inside a loop the testharness writes), so the build flow's large unroll
   limits are required, not a tuning choice. Rolling is out;
   the SoA pass remains the only compiler path to a smaller footprint, and its gain must
   be assumed smaller than estimated above until measured.

### 6.2 What does not pay (measured or structural)

- **AVX/intrinsics in the runtime**: the hot wide copies are already vectorised by the
  compiler; the model is fetch-bound. Only useful after 3 moves the bottleneck.
- **Caching evaluation results across cycles** (memoising cones): inputs change every
  cycle in the active core; the only cheap "skip" is the clock gate of lever 2.
- **Lower `-O`**: `-Os` and `-O2` were already the same speed before PGO (fetch bound).
- **Newer Verilator (5.03x)** alone: same straight-line model; worth an A/B for its
  scheduler, not as the 10×.

### 6.3 Composite estimate

Server, from the current ×3.7: partition ×1.5–1.8 · idle-core gating ×1.5–3 · footprint
(SoA only, unproven) ×1–2 → **×2.3–10.8**, i.e. the 10× is reachable only with all
three at their optimistic ends, and the middle one is an RTL feature (with a genuine
power benefit) rather than a simulator change. Single core, from ×1.9–3.5: footprint and partition only → ×2–4. A kernel boot
of 1–2 G cycles at the resulting 15–40 k cycles/s on this 6-core host is 7–37 hours;
"a few hours" additionally needs a faster dedicated host (×2 single-thread, 16+ cores
for lever 1) or a shorter boot (kernel config), both outside the simulator.

## 7. Evaluation of fork commit `63c0953ce` — "sliced tables and O(1) host structures" (2026-10-12)

Main-repo commit `7f9edfdad` pinned the fork at `63c0953ce` (+4.5 k lines: `V3Soa`,
`V3Prio`, `V3Wake`, `V3ClkSkip`, `V3SplitPlan`, `V3Dirty`, V3Table slicing, an MTask
predecessor bitmask, hash-map `V3DupFinder`/`V3Param`, all six new passes **on by
default**). It was evaluated the only way this guide admits: exactness first, then
callgrind, then wall clock — `g6lc64_ooo`, s11 probe (10,941 cycles), `-O2`, the
109-entry split `.vlt`, compiler `verilator-v5.008-g6lc-wt2` built from the pin.

### 7.1 Exactness — the pinned compiler miscompiles the core

| model | result |
|---|---|
| defaults (all six passes on) | **does not fetch**: `npc = 0` forever, RVFI empty, 2 M-cycle cap hit; s11 and wprp |
| first attempt | did not even compile: `V3Soa` converted `bht_prediction_shifted` while the `cva6.sv` probes still read it as a packed vector through a hierarchical reference (`AstVarXRef` is not an `AstVarRef`; the collector missed it) — fixed, the collector now keys on `AstNodeVarRef` |
| `-fno-*` on the command line | **ineffective**: the build flow appends `-O3` after the user's arguments and `-O<n>` re-enabled every flag — the first bisect round was void. Fork now honours `VERILATOR_FNO=soa,prio,…` after all parsing (same family as `VERILATOR_UNROLL_*`) |
| one pass off at a time (`VERILATOR_FNO`) | only **`clock-skip` off** restores the trace (`de4f42cfe7cb`, 10,941 cycles); every other single-off still hangs |
| all six off | exact — the always-on parts (hash maps, MTask mask, `V3Delayed` loop shadow, headers) are clean on this model |

Why `V3ClkSkip` is unsound (read, not guessed): it is not the per-core skip of lever 2
but a generic memoisation of per-instance combinational statements — each group is
guarded by "any input differs from its shadow copy". The shadow compare (`__Vclkskip*_r`)
is computed in a **prolog at the top of the function**, so an input that an *earlier
statement of the same function* updates (parent → child port chain, the normal case
after inlining) is compared **before** it changes; the child group is skipped with stale
outputs. `otherWrites` only refuses inputs written by *ungrouped* statements of the same
function, not by other groups. It also assumes every variable the group writes is
written only by that group, which part-select writes across functions violate. It is
exactly the "memoising combinational cones" entry of §6.2, and its measured effect is a
core that never leaves reset. Opt-in only (`-fclock-skip`), not part of `-O<n>`.

### 7.2 Cost — the remaining passes do not buy a distinction

callgrind, eval only, instructions / L1I misses per simulated cycle (all rows RVFI-exact):

| configuration | Ir/cycle | I1 miss/cycle | Δ Ir |
|---|---:|---:|---:|
| all six off (= `wt9` + hash maps + MTask mask) | 267,200 | 18,715 | — |
| five on, clock-skip off | 356,716 | 24,387 | **+33 %** |
| … and `split-plan` off | 277,452 | 19,036 | +3.8 % |
| … and `table` off (slicing) | 350,671 | 24,114 | +31 % |
| … and `soa` / `prio` / `wake` / `dirty` off (each) | 355–357 k | 24.3–24.5 k | no change |
| `soa`+`prio`+`wake`+`dirty` only (`wt2` compile-4 defaults) | 273,001 | 18,833 | +2.2 % |
| `split-plan` **instead of** the hand `.vlt` | 353,283 | 24,178 | +32 % |

- **`V3SplitPlan`** is the regression: it marks every splittable variable in every
  combinational cycle (`attrSplitAuto`) and over-splits far past the 109 hand entries
  (hybrid class 10,206 → 8,103 but +80 k instructions per cycle: more pieces, more
  statements, more code). As an automatic replacement for the `.vlt` it is as bad. It is
  not a substitute for the evidence-driven list; opt-in.
- **Table slicing** (`-ftable-slice`): 2,237 slices / 2,265 tables on the single core for
  +6 k Ir/cycle — the decoders it tables are not where the code volume is, and the LUT
  loads displace the data that *is* hot. Opt-in.
- **`V3Soa`** converts 56 arrays, none of them hot: `--debugi-V3Soa 4` lists
  `gen_lzc.index_lut`, FPU `fmt_*` slices, TLB `*_match[16]`, `older_t[24]` (the IQ age
  matrix, good) — and 13,800 refusals: 7,278 "blocked" (ports, split_var targets,
  public) and 6,530 "dtype" (already unpacked or struct). The IQ/scoreboard entry arrays
  are read whole (`issue_instr_o = mem_q[ptr]`, `q_d = q_q`) so the "every access is
  per element" precondition never holds for them. The two loops it keeps rolled are the
  `g6lc_ftq.sv` reset/flush loops, which then take the new `V3Delayed` shadow path
  (correct in the directed check, O(table) copy per edge in general).
- **`V3Prio`** lowers 51 lzc/one-hot loops to `VL_LZC_*`; **`V3Wake`** finds one site;
  **`V3Dirty`** arms one signal. −1 k, 0, 0 Ir/cycle respectively.
- **`-fsoa -fprio -fwake -fdirty` together: +2.2 % instructions** — slightly worse than
  without, for added compiler surface. Opt-in.

Decision (fork, after the pin): all six passes are **opt-in** (`-fsoa -fprio -fwake
-fdirty -fclock-skip -fsplit-plan -ftable-slice`, excluded from the `-O<n>` sweep), the
`V3Soa` XRef fix and the `VERILATOR_FNO` knob are in, the eight new `test_regress` cases
pass their flag explicitly. What stays on by default — hash-map `V3DupFinder` (still
`sameTree`-checked, earliest insert wins), `V3Param` maps, the MTask predecessor
bitmask — is exact on the single core (s11 268,344 Ir/cycle vs 268,345: identical
code) and on the server: `ooocoh-t22g-server-wt2-mt4-build` vs
`…t21t-server-nogate-mt4-build2` (same RTL and `.vlt`, 300 k-cycle 8-hart OpenSBI
segment, alternating, builder at load 3–5) **2,246 / 2,071 vs 2,122 / 2,239 cycles/s,
per-core RVFI byte-identical** — the bitmask wait is neutral within the run-to-run
noise of a loaded host (the earlier idle-host figure for this pair was ≈ 3,100). It
stays: one atomic load and an AND per wait instead of a yield loop is the right
primitive for the finer partitions of lever 1, it just does not move the current
54-MTask partition.

### 7.3 What the claimed structures would need to become real

The summary that motivated the commit is right about the target (packed CAM/age arrays
as host tables and bitmasks) and wrong about the mechanism being a drop-in pass. On this
design the hot arrays are reached only through whole-entry reads, port boundaries and
the split_var list; a struct-of-arrays lowering that pays must (a) split *fields* of a
packed struct array into separate element tables (true SoA, so `q_q[e].prs1` is a
`uint8_t` load and `q_d = q_q` becomes per-field copies), (b) rewrite whole-array reads/
writes into element loops instead of refusing them, and (c) keep the clocked scan rolled
without the O(table) shadow copy (per-element NBA commit list, not a full copy). That is
a new pass with its own exactness battery, and its gain is still bounded by the 1 MB/cycle
fetch footprint analysis of §6 — the honest expectation is the "×1–2 unproven" of §6.3,
not the 1.5–2× quoted in the summary.

### 7.4 Footprint attribution and the rolled-loop experiment (2026-10-12)

Where the 133 MB of generated C++ (88.5 MB fast path, 7.05 MB compiled text) of
`g6lc64_ooo` comes from, measured on `ooocoh-t22g-ooo-def5-build` by instance scope of
the first signal on each generated line (`t21/q-fp3.sh`, `q-fp4.sh`, `q-fp6.sh`):

| scope | MB | what it is |
|---|---:|---|
| `_nba_sequent__TOP__1` (one function) | 32.6 | every `always_ff` of the core plus the comb logic that depends only on flops, straight-line |
| `issue_stage_i/gen_full_ooo/i_ooo_dispatch` | 16.5 | the IQ: `q_wake`/`q_chain` ready logic 4.5 MB (DEPTH × NR_SB_ENTRIES `ooo_age_older` copies, DEPTH × NR_WB wake compares), `older_q/older_d/rank` 3.5 MB (DEPTH² age matrix per port) |
| `ex_stage_i/lsu_i` | 7.8 | `i_pmp_data_if` 2.4 + `gen_mmu` 2.2 (PMP NAPOT checks and the `pmp_entry.sv:63/93` assertion loops: 16 entries × 54 address bits × 3 checkers; 1,512 `VL_STOP_MT` copies), store buffer queues 0.8 |
| `i_axi_xbar` | 5.3 | per-port/per-slave muxing |
| `fpu_gen` | 2.8 | fpnew per-lane logic |
| cache subsystem | 3.6 | 352–408 unrolled `__Vdlyvset/lsb/dim/val` array-NBA slots |

Per-RTL-line attribution is not available: 5.008 emits no `// at file:line` decoration
(only `$display` sites carry one). The template census of the 32.6 MB function (strip
numbers, count repeats) shows the duplication directly: the top 45 statement shapes are
26 % of it and they are per-entry copies (`older_q[k]` × 1,074, PMP `pmpaddr_q` tests ×
1,254, assertion blocks × 1,512, …).

**Cost-aware unrolling** (`--unroll-roll-narrow N`, `--unroll-roll-min-trips T`, fork
`V3Unroll::rolledBodyIsCheap`): a loop stays rolled when trips × body nodes > N, every
dynamic part-select in the body is ≤ 64 bits, it touches no `split_var` variable and its
array NBAs are one-dimensional. Array NBAs inside a loop kept this way go through a new
**per-element commit queue** in `V3Delayed` (`rewriteLoopQueue`: per array and loop a
queue of (index, mask, value) sized trips × statements, pushed in the body, drained in
the NBA region in push order, closed at loop exit so later NBAs to the array commit after
it) — this replaces the O(table) shadow copy of `63c0953ce` and is the "per-element NBA
commit" of §7.3. Measured, `g6lc64_ooo`, s11, all RVFI-exact:

| variant | loops kept rolled | text | Ir/cycle | I1 miss/cycle | spin (loaded host, alternating) |
|---|---:|---:|---:|---:|---|
| default (all unrolled) | 0 | 7.05 MB | 267,200 | 18,715 | 19.8 k / 16.6 k |
| `--unroll-roll-narrow 1000` | 359 | 5.77 MB (−18 %) | 363,763 (+36 %) | 17,573 (−6 %) | 17.5 k / 19.7 k |
| `--unroll-roll-narrow 300` | 516 | 5.64 MB (−20 %) | 375,101 (+40 %) | 17,206 (−8 %) | — |

The footprint falls as intended but the instruction count rises faster than the misses
fall: an unrolled iteration lets V3Const/V3Gate fold its constant index (one word test,
dead `o != e` branches gone), a rolled one computes the word and shift and runs every
branch. Within the noise of a host at load 19 the wall clock is unchanged. So rolling is
not a lever on this model either — the §6 reading stands: the 1 MB/cycle is the design's
logic, executed every cycle, not loop copies. Both knobs stay opt-in (default off); the
commit queue is the correct mechanism whenever a loop with array NBAs is kept rolled for
any reason (it also retires the BLKLOOPINIT limitation for such loops; exact with 38
queues active at threshold 1, and `t_soa_array` now takes it). Min-trips 16 instead of 4
changes nothing (337 loops, 363,456 Ir, 17,510 misses).

Two more footprint items from the census, measured the same way:

- **PMP assertion loops** (`pmp_entry.sv:63/93`, the G6LC NAPOT canonical check: 16
  entries × 54 bits × 3 checkers, 1,512 `VL_STOP` blocks): rewritten sim-only as a
  `$countones` trailing-ones count and one mask compare. Text 7.05 → 6.33 MB (−10 %),
  **Ir +2.2 %, I1 misses +2 %** — the per-bit `if`s were cheap and mostly skipped, the
  word form is not cheaper. **Reverted** (no simulation gain, and RTL edits need a
  physical reason).
- **Constant tables** (fork `589bb8c7c`): the 64-bit merge cap on adjacent part-select
  drivers (the fix for the quadratic concat chain) also kept common_cells' lzc
  `assign index_lut[j] = j` from folding into one constant — 8,719 runtime references in
  the model. Constant parts now merge at any width (V3Const `replaceAssignMultiSel`, DFG
  `canonicalizePacked`): references 8,719 → 0, text −0.6 %, Ir −0.1 %. Kept (default on,
  exact): correct, free, invisible on the clock.

Net of the tangent: every footprint mechanism §7.3 asked for now exists (rolled scans,
per-element NBA commit, constant tables; field-level SoA remains unbuilt because the
whole-entry reads make it a rewrite, not a lowering) and none of them moves the wall
clock on this core, because what the core executes per cycle is its logic, not its
code copies. The §6.3 "×1–2 unproven" for footprint is now "measured ≈ ×1.0"; the
levers that remain are the structural ones of §6.1 (per-core skip, partition).

### 7.5 The hierarchical core, measured (2026-10-12)

Lever 1 of §6.1 as Verilator offers it: the core as a `hier_block`
(`corev_apu/src/g6lc_core_hb.sv`, closed over the target package because hier blocks take
no type/struct parameters; `verilator_config.vlt`; `+define+G6LC_CORE_HB`;
`--hierarchical`). Three fork defects stood in the way and are fixed (`adb3dfcf9`,
`819db5b8d`): the child re-parsed every `-f` line with a `${VAR}` (verbatim-vs-substituted
compare in `allArgsStringForHierBlock`) and `-Wno-MODDUP` then deleted package copies
under live import pointers; the runtime dir lacked `bin/verilator` for the child make;
V3Reloop appended `__Vilp` after its first use when the merged copies sit in `_eval`'s
`initsp` (the `__Vsampled` copies). The testbench reaches a core's public internals through
`Verilated::hierModelFind` (the wrapper registers each child under its `%m` scope).

| | flat (`t23j`) | hierarchical (`t24h` build6) |
|---|---:|---:|
| build (4–5 jobs, verilate + compile) | 52 min | **33 min** |
| C++ files / text | 377 / 86.9 MB | **99 / 25.8 MB** |
| `mc_multi_writer_line` | 83,356 cycles | 83,356 cycles |
| 300 k boot segment, per-core RVFI | d509318c e3a792fa 02596841 29e8fc13 | identical |
| 300 k boot segment, MT4, alternating | 3,131 / 3,109 cycles/s | **1,467 / 1,477** |
| user time | 362 s | 790 s |

Exact, three times smaller, a third faster to build — and 2.1× slower to run, with 2.2×
the CPU work. The reason is the primitive, not the partition: a `--lib-create` child is
driven by a wrapper whose `always @*` calls `combo_update` (a full child `eval()`) on any
input change and whose `always @(posedge clk or negedge clk)` calls `seq_update` on both
edges, so a core's combinational region runs two to three times per cycle where the flat
schedule ran it once, and the DPI marshals every port each call. Nor would a gated core
rest: `rtc_time_i` (the mtime counter) is an input of every core and changes every cycle,
so the input-change check fires regardless of the clock. The per-instance skip that §6.1
wants is therefore not reachable through hierarchical Verilation; it needs an
instance-partitioned scheduler inside one model (per-instance trigger sets and eval
functions, called from the top eval under a liveness test), which is a new V3Sched/V3Order
feature, not a flag. The hierarchical build stays available as an opt-in for its build-time
and exactness properties.

