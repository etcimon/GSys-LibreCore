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

### 7.4a The build of record (2026-10-13)

The flat server model of the §7.5 table's left column — fork compiler (`tools/verilator`
gitlink), `build-platform/scripts/verilator-split-loops.vlt`, `--threads 4`, `-O2`,
**3,131 / 3,109 cycles/s** on the 300 k boot segment, **3,379 with C++ PGO** (§4b.2) — is now
the default build, every measured win of §4–§4b included and nothing that measured zero:
`toolchain.verilatorFlavour: "g6lc"` and `simulation.verilator: {recipe: harness, pgo: true,
splitVlt: true, opt: "-O2", threads: 4}` in the build platform (`./build.sh build` runs the
harness), `SOFT_LADDER_VERILATOR_FLAVOUR=g6lc`, the split-loops `.vlt`, `SOFT_LADDER_BUILD_OPT=-O2`
and `SOFT_LADDER_BUILD_PGO=1` (instrumented build → the in-repo `ooo_fp_ooo.S` probe run to
completion and to the cycle cap → `-fprofile-use`, `__Syms` at `-O1`) on by default in
`verif/regress/soft-ladder-build-harness.sh`, the fork runtime in the review runners' qualified
set (`runtimeFlavour: g6lc-fork@<pin>`), and the T16/T21 drivers' `T16_VLT_ROOT` /
`T16_SPLIT_VLT` defaults (`T16_PGO=1` keeps the drivers' boot-segment-trained PGO and turns the
harness round off). Not in the default because they measured nothing: Verilator's `--prof-pgo`
`profile.vlt` re-partition, the hierarchical core, the sleep gate as a simulation lever, and
the §7 opt-in passes.

**Measured with the complete default set** (`ooocoh-t25-server-hpgo-mt4-build2` = fork
`453031b66`, split `.vlt`, `-O2`/slow `-O1`, harness PGO on the `ooo_fp_ooo` probe — 376
profiles, MT4; 300 k boot segment, idle host, alternating, same RTL as the two comparison
models):

| model | cycles/s | user time | per-core RVFI |
|---|---:|---:|---|
| `t23j` reference (fork, split, no PGO, pre-T24 RTL) | 3,132 / 3,084 | 362 s | d509318c e3a792fa 02596841 29e8fc13 |
| `t25-fork` (same, T24 RTL, no PGO) | 3,044 / 2,974 | 373 s | 54555abf e3a792fa 02596841 29e8fc13 |
| **`t25-hpgo` (the default)** | **6,612 / 6,593** | **160 s** | 54555abf e3a792fa 02596841 29e8fc13 |

**×2.2 from the harness PGO round alone**, 2.3× less CPU, traces identical to the no-PGO model
of the same RTL (core 0 differs from `t23j` only by the T24 store-order fix's 14-instruction SMT
interleave shift). Against the pinned upstream build of the T21 era (924 cycles/s on this
segment) the default is now ×7.1. Single core (`g6lc64_ooo`, 200 k spin, same probe-trained
PGO): 15.0 k → 19.4 k cycles/s (+30 %), 11 probes / FP suite / wprp Spike-exact and
cycle-identical. The harness PGO on the server is also better than the T21 driver's
boot-segment-trained PGO model (3,379): the probe exercises the OoO/FP/LSU paths every core
shares, and the training is deterministic and in-repo. The pinned upstream v5.008 stays as
`pinned` for cross-checks (~2,100 cycles/s on the same model) and as the fallback when no fork
prefix is installed. Rules that follow from §7: an exactness run (RVFI per core on the segment,
the probe battery) accompanies every fork bump; the opt-in passes (`-fsoa`, `-fprio`, `-fwake`,
`-fdirty`, `-fclk-skip`, `-fsplit-plan`, `--unroll-roll-narrow`) stay off; a config that the
fork miscompiles is built with `pinned` until fixed (T25 was the one such case, see
`AGENTS-todo.md`).

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

## 8. Causal execution-cache review (2026-10-13; experimental, not promoted)

This continuation preserves the negative results in §6.2 and §7.1; it does not treat
those passes as successful prior work. The relevant tree is `tools/verilator`, not
`tools/verilate`. The fork compiles ASTs into scheduled C++; the simulation is not
walking an AST red-black tree each cycle. A runtime red-black tree would introduce
pointer chasing and ordered lookup into an instruction-fetch-bound path. The useful
part of the proposal is instead a **compile-time writer-to-consumer dependency index**
whose runtime representation is direct validity-bit stores and guarded contiguous
execution groups. There is no learned-path completeness assumption or hash-only hit.

### 8.1 Implemented contract under the existing `-fclock-skip` opt-in

`V3ClkSkip.cpp` now separates consecutive runs of statements even when they belong to
the same inlined instance. A guard executes immediately before its run, not in the
function prologue. The run's read set includes every branch's dependencies; only a
preceding whole-variable assignment inside that same run discharges a live-in read.
Read-before-write feedback is refused. Thus a parent/child/parent ordering stays in
that order and has three independent validity decisions.

A whole-model assignment index connects every supported internal writer to the
cached groups that consume its variable. It also invalidates a group's retained
outputs when another group/function writes them. Whole, partial, and dynamic-index
stores invalidate conservatively at variable granularity. Whole packed scalar stores
up to 64 bits capture the old value, execute the original RHS exactly once, then
invalidate only on an actual change. Partial/dynamic/wide stores retain unconditional
invalidation. This sacrifices some hits rather than risking a false clean bit.
The pass runs after `V3Clock` and lifetime/NBA alias cleanup, so its writer index refers
to the resulting storage, and emits instrumentation in deterministic source traversal
order. External/untracked inputs retain exact packed-value comparisons and snapshots at the
execution site. Public/forced/DPI-written or otherwise untracked outputs, impure
operations, non-packed data and feedback are not cached. First-use validity is reset
explicitly by `_eval_static`, independent of randomized initialization. Cache state
is per model, not process-global, and normal sensitivity/convergence logic remains
responsible for scheduling; invalidation itself never fabricates a sensitivity event.

Threaded models, timing-enabled models, opaque raw-C statement models and models
with residual hierarchical `AstVarXRef` references take the original scheduler without
caching. The latter is a fail-closed guard against the missed-XRef class of defect in
§7.1. Cold settle functions are not cached: invalidating their never-reused entries
would add hot-path work with no cycles/s benefit. No cross-thread atomicity or delayed-event proof
is claimed. The existing flag remains excluded from `-O<n>` and from the production
build recipe. This is an initial conservative implementation, not a replacement for
all scheduler scans, and not a full-model qualification.

### 8.2 Performance hypothesis and falsification gate

If `p` is the fraction of original runtime actually removed and `h` is the added
invalidation/guard overhead as a fraction of original runtime, the best-case speedup
is `1 / (1 - p + h)`. A further 10× requires **p - h >= 0.9**. Removing only the
~4.5% trigger evaluation share in §6 cannot deliver that; even eliminating it entirely
would yield about 1.047×. A cache must skip the payload logic, not just its dispatch.
The evidence to collect is guard coverage/hit rate, emitted invalidation volume,
Ir/cycle, I1 misses/cycle and cycles/s on the same design/workload/compiler recipe.
Dense writes can make this implementation slower. A sparse synthetic win, if any,
is not a boot-model win or a 100%-scenario proof.

### 8.3 Evidence and integration limits

The initial remote preflight found 12 logical CPUs, ~102 GiB available RAM, load ~16
and more than 12 active compiler/synthesis workers. No additional full-model job was
launched and no unrelated job was killed. Compiler/leaf work is an explicitly local
WSL diagnostic in `build-platform/workspace/build/vlt-causal-20261013/`; it does not
replace the proxy-only LibreCore battery. Final results for this experiment are
recorded below when available. Earlier artifacts and unsuccessful runs are retained.

Licensing review: repository contributor/policy/tier configs are present; the existing
Verilator files stay tier U with their LGPL/Artistic or CC0 notices unchanged. This
change is by Etienne Cimon and makes no new RTL license claim or link-set change.
The root-documented `diag run licensing` command currently reports `Unknown: licensing`;
notice preservation and the scoped diff therefore require a manual check. No licensing
policy was changed. RTL timing, synthesis, DFT, ISA/config/DTS and RISC-V spec-map changes
are not applicable: this pass changes compiler scheduling and its own regression only.

### 8.4 Local result — useful sparsity gain, not 10× or full-core evidence

The extended `test_regress/t/t_clock_skip.v` runs 1,000 cycles with parent/child/parent
propagation, unchanged intervals, gated clocks, 128-bit state and both constant and
dynamic partial writes. With gate/DFG folding disabled to retain the dependency
boundaries, the original `V3ClkSkip.cpp` from fork HEAD `453031b66` fails at **cycle 7**
(`64e70b38` instead of `36306bbc`). Cache-disabled control and the repaired cache pass.
This is a reproduced negative witness for §7.1, not just a test that happened to pass.

Local diagnostic matrix (`leaf_review.py` in the artifact directory): six randomized
initialization seeds each (`1,2,3,42,123,2147483647`), all passing for the repaired
cache, cache-off control, non-inlined hierarchy, `--public-flat-rw` fallback,
`--threads 2` fallback, default optimizations with `--x-initial-edge`, and the cached
model under AddressSanitizer + UndefinedBehaviorSanitizer. These are **42 leaf runs**,
not the full upstream Verilator suite. `--debug-check` was enabled while generating
models; the Perl test driver is syntax-clean, but local models were built by the
isolated diagnostic harness rather than the upstream Perl/make driver. The original
negative is retained in `closed-old/`. The first public-model diagnostic failed to
compile because the diagnostic's C++ command omitted `include/vltstd`/DPI runtime;
`closed-public/` supplies those dependencies and passes. Failed artifacts were not
overwritten. An external-input synthetic case exercises 64 exact input comparisons
and passes its independent C++ reference checks.

Synthetic fixture (`cache_bench.py`): 32 lanes, each with a gated register and 32
rotate/multiply/add rounds; one lane written per cycle (sparse) versus every lane
written per cycle (dense), shared side state changed every 1,024 cycles. No PGO.
The C++ reference checks every output for the first 2,048 cycles; full-run checksums
also match (diagnostic checksums, not architectural trace qualification). This is a
mechanism test, **not LibreCore RTL**. GCC `-O2`, local WSL; 1,000,000 cycles per run,
control/cache/cache/control repeated twice, with no other diagnostic compilation
running during these timed alternations. `bench-measurements.json` records individual
runs and binary hashes; generated-model records also carry compiler hashes.

| activity | control median time | cache median time | cycles/s ratio | eval Ir/cycle, control → cache |
|---|---:|---:|---:|---:|
| sparse | 0.797159 s | 0.206355 s | **3.863×** | 5,726.27 → 2,641.73 (−53.9%) |
| dense | 0.779771 s | 0.804958 s | **0.969×** (3.1% slower) | 5,822.17 → 6,082.41 (+4.5%) |

Ir uses Valgrind 3.22 callgrind over 20,000 cycles, collection restricted to
`*eval_step*`. Both models fit the simulated instruction cache (494/693 total I1
misses, effectively cold misses only); **this does not demonstrate a reduction of
the core's 1 MB/cycle instruction-fetch footprint**. The compiler reports 32 cached
execution groups and 1,216 static invalidation edges for the final synthetic model;
that edge count includes cold initialization stores, not just per-cycle work.
Unconditional invalidation was first tried and measured much less useful; the scalar
change filter avoids invalidation from unchanged writebacks. Filtering/cold-settle
experiments and their raw results remain in separate artifact subdirectories.

Reproduction artifacts: `build-platform/workspace/build/vlt-causal-20261013/` contains
`leaf_review.py`, `cache_bench.py`, `measure_bench.py`, the HEAD source archive and
`build_baseline.py`, generated C++, logs, JSON identities and callgrind output.
The compiler was built out-of-tree using CMake/Ninja with `FLEX_INCLUDE=/usr/include`,
`-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS_RELEASE=-O1`, target `verilator_bin`,
`--parallel 4`; generated models use `-O2`. The persistent regression entry is
`tools/verilator/test_regress/t/t_clock_skip.pl` (`--vlt` and `--vltmt` on a configured
fork build). No managed compiler prefix or qualification runtime was replaced.
After the final residual-XRef fallback and formatting review, the compiler was rebuilt
(SHA256 `4cba16d61a1de3ff697785ce1a03605751bd4da5ff4a6ba4cd8cbd55b023367a`).
`verify_emission.py` regenerated all seven leaf variants plus the three synthetic
models: **all 135 generated C++/header files were byte-identical** to the tested
versions (`emission-check.json`). This ties the final source to those local results
without relabelling a different generated model as tested.

**Decision:** retain as an opt-in prototype, not a production speedup. A further 10×
has not been reached. The documented dominant `_nba_sequent` work is deliberately
outside this pass; skipping that requires a separate state-transition/idempotence
contract, not assuming that a clock edge is irrelevant. The remote preflight was
repeated and still found load ~18 on 12 CPUs with >12 active compiler/synthesis
workers. Full-model proxy RVFI/probe/FP/anchor equivalence, coverage of additional
language effects and a matched real-model Ir/I1/cycles/s comparison remain open.

## 9. Mechanism transfer: Verilator cache lessons → Yosys passes, and back (2026-10-13)

### 9.1 What transfers and what does not

The Verilator work's reusable lesson is not "a cache" but a discipline: **know every writer
of a value, index consumers by what they read, invalidate at the write, never scan to find
out what changed**. Yosys is a compiler, not a cycle simulator, so the hot structure is
different (fixed-point pass loops over RTLIL, not per-cycle eval), but the same costs recur:

| Verilator mechanism measured | Yosys analogue | Status |
|---|---|---|
| Write-side invalidation of consumers (§8.1) | `opt_merge` already rehashes only cells that read a redirected wire (fork `216f5d12a`) | present before this pass |
| Trigger vectors scanned linearly (§2.3) | `wire_cells` subscriber lists scanned linearly on every cell removal (`std::remove`) | **fixed here** — indexed swap-remove |
| Change-filtered stores (§8.1) | hashing only when the design actually changed; `did_something` loop in `opt.cc` | present |
| Deferred bookkeeping until first use | subscriber index built before knowing if any duplicate exists | **fixed here** — built lazily on first merge |
| Memoising combinational cones (§6.2, refuted) | caching `SigMap` canonical chunks across passes | **not attempted** — `rebuild_canon` is already per-pass and the invalidation surface is `module->connect`, which every pass calls |
| Instance-partitioned scheduling (§7.5) | per-module parallelism | already present in `opt_merge`/`opt_clean` thread pools |

The red-black-tree framing from the original prompt does not map onto either tool: Yosys
already uses hashed `dict`/`pool` (O(1) expected) for every index touched here, and an
ordered tree would add pointer chasing with no ordering requirement to exploit.

### 9.2 `opt_merge` subscriber index — implemented and measured

`passes/opt/opt_merge.cc`: `wire_cells` keeps `std::vector<Cell*>` per wire; `cell_wires`
now stores `dict<Wire*, int>` holding each cell's **position** in every subscriber vector.
`unwatch(cell)` swaps the last element into the removed slot, repairs the moved cell's
stored index, and erases the wire entry when empty — O(wires-of-cell) instead of
O(wires × subscribers). The index is populated only once the first duplicate round
actually finds a merge (`pending_wire_uses`), so a design with no duplicates never builds
it. Results are byte-identical RTLIL across every fixture and every thread count.

Measured (`measure_merge.py`, local WSL, `YOSYS_MAX_THREADS=1`, `--perffile` `opt_merge`
pass time, 6 alternating pairs per fixture, median; binaries `yosys-before` =
fork HEAD `38b04c05a`, `yosys` = this change, SHA256 `2b4955af…`):

| fixture | before (ms) | after (ms) | speedup |
|---|---:|---:|---:|
| 32,000 identical `$and` → 1 | 468.2 | 95.3 | **4.91×** |
| 8,000 distinct `$and` (no merge) | 8.15 | 5.61 | **1.45×** |
| 256 × 8-deep chains → 8 (multi-round) | 8.22 | 7.43 | 1.11× |

A `pool<Cell*>` variant was tried first: it helped the dense-duplicate case but was
slower on the no-merge case because of hashing cost on every `watch`; the indexed vector
superseded it. These are synthetic fixtures, not the LibreCore `synth` smoke; the server
synth path spends most of its time elsewhere (§4 Yosys-fork notes), so this is a pass
hygiene win, not a flow-level speedup claim.

Verification: `tests/opt/opt_merge_*.ys` (6 files) × `YOSYS_MAX_THREADS ∈ {1,2,4}` = 18
runs pass, including `equiv_opt -assert` on the new 512-cell chain fixture added to
`opt_merge_chain.ys`; `gtest-kernel` 115/115 pass. The local build is component-
restricted (no ABC/slang/`logger`), so `tests/various/check_wide_and_loop.ys` could not
run here — it is an earlier uncommitted test and is not evidence from this pass.

### 9.3 Back to Verilator: bit-range-aware invalidation for sparse activity

The transfer back is the same precision argument. §8.1 subscribed a cached group to
**every** writer of a variable it reads. A 1024-bit packed bank where each of 32 lanes
reads its own 32-bit slot therefore invalidated all 32 readers on any lane's write —
measured as the cache being **10% slower than no cache** on that shape (`range-before`).
`V3ClkSkip.cpp` now carries a `BitRange` per read and per writer (constant `AstSel`
chains folded; a dynamic index widens to the whole variable), and `subscribe` skips
writers whose range is disjoint from the group's read range (stat
`Clock skip disjoint subscriptions`). Change-filtering also extends to constant partial
stores up to 64 bits.

Measured (`measure_range.py`, 1,000,000 cycles, 12 alternating runs, median,
`REVIEW_AGGREGATE=1` fixture, all three models checksum-identical):

| activity | control (no cache) | before (variable-granular) | after (range-aware) | after vs control | after vs before |
|---|---:|---:|---:|---:|---:|
| sparse (1 lane/cycle) | 0.775 s | 0.858 s | **0.208 s** | **3.73×** | 4.13× |
| dense (32 lanes/cycle) | 0.815 s | 0.900 s | 0.924 s | 0.88× | 0.97× |

Static edge count on the fixture: 2,208 → 1,216 invalidation edges; 992 disjoint
subscriptions skipped. The dense penalty (−12%) is unchanged in kind from §8.4 and is
the honest cost of write-side bookkeeping when everything changes every cycle.

### 9.4 A pre-existing runtime defect the fixture exposed

Extending `t_clock_skip.v` with a 192-bit bank and a dynamic 8-bit indexed write
(`state[idx*3 +: 8]`) made the **cache-disabled control** fail at cycle 269. The cause is
not the cache: `_vl_insert_WI`/`_vl_insert_WW` in `include/verilated_funcs.h` clamp
only via `cleanmask` when the write ends inside the top word, so a write whose
`hbit >= rbits` with `lbit` still in range wrote into `iowp[hword]` **past the array**
(here, into the next struct member). The `V3Unknown` bound guard (`__Vlvbound`) only
excludes indices whose *lsb* is out of range. Fix: clamp `hbit` to `rbits-1` and return
early when `lbit >= rbits`. A guarded-buffer test in `t_math_imm2.cpp` (8 widths × 10
array sizes × every lsb including past-the-end) fails before and passes after, also
under ASan/UBSan. This is the same defect family as the `VL_CONSTHI_W_*X` overflow in
§4a and changes the runtime header hash (`d49a56d2…`); any model built against the
previous fork header should be re-identified. Reset-value randomisation made this
reproduce in the default seed only; the six-seed matrix is what caught it.

After the fix, the full leaf matrix on the extended fixture passes: cache/control/
public/MT-fallback/non-inlined/`--x-initial-edge`/ASan — 7 variants × 6 seeds = 42
runs; HEAD `V3ClkSkip.cpp` still fails at cycle 7 on the same fixture
(`slices-old-fixed`). `verify_emission.py` confirms all 9 final models' generated
C++ (151 files) are byte-identical to what was tested with compiler `e5b48210…`.

### 9.5 Real-model qualification pass (2026-10-13, builder at load 6–11)

The builder dropped to load ~6 later in the day, so the owed full-model evidence was
collected through the proxy with the throughput rules of §0.8 (private compiler prefix,
single-thread models, 6 compile jobs sized against the live MT4 census runs, nothing
killed; `remote_causal_ab.py`, run tags `causal-ab-ooo-20261013b` and `…d`). Compiler:
the fork pin `453031b66` plus this working tree's patch, built on the builder into
`/opt/testharness/toolchains/verilator-v5.008-g6lc-causal` (runtime header
`d49a56d2…`, the same hash as the local tree). Models: `g6lc64_ooo`, remote tree
`90d99b70c`, `--threads 1`, split `.vlt` on, no PGO, `-O2`.

**Runtime header fix is behaviour-preserving on the real core.** The `ctl` model
(`-fno-clock-skip`, i.e. header change only) retires the s11 probe in **10,941 cycles
with RVFI SHA256 `de4f42cfe7cb…`** — the reference hash this guide has carried since the
pinned 5.008 compiler (§4a) — and the wrong-path-replay probe in 10,311 cycles with a
stable trace (`b1632a101ff3…`). Ir/cycle (callgrind, eval only, no PGO): s11 874,598,
wprp 1,083,951; I1 misses/cycle 50,758 / 64,415. These are the first real-core numbers
on this tree's RTL and are **not** comparable to the PGO rows in §7.5.

**First attempt refused the model.** Run `…b` built the cache model and the pass
reported `Clock skip unsupported model 1`: the §8 fail-closed guard refused any model
containing `AstCStmt`/`AstUCFunc`/`AstVarXRef`, and the testharness has DPI marshalling
text (`SimJTAG`, `read_elf`, …). Reading `V3LinkDot.cpp:2954` showed the `VarXRef`
case was dead code: every hierarchical reference is rewritten into a scoped `AstVarRef`
at scope creation, so the §7.1 "probe into i_frontend" class is an ordinary indexed read
by the time this pass runs. The guard was narrowed to per-variable untracking: every
variable referenced under a `CStmt`/`CExpr`/`UCFunc` is untracked (exact compare if
read, refused as a cached output), and only threads/timing remain model-wide, each now
named in the stats. `t_clock_skip.v` gained a non-inlined scope with hierarchical probes
into it and asserts that no model-wide refusal fires; it passes under the upstream
driver in `--vlt` (cache active) and `--vltmt` (threads → refused) with
`$Self->{sim_time} = 12000` (the default 1100 timed out the 1,000-cycle fixture).

**Second attempt (`…d`) caches the real core — and shows the dense-activity shape.**
Stats on `g6lc64_ooo`: 730 scopes, 13,099 execution groups, **6,181,042 invalidation
edges** after 4,931,510 disjoint subscriptions were skipped, 50,939 change-filtered
stores, 11 external compares, 57,267 validity/shadow members in the root class. The
`DepSet` sources grew from 4.33 MB (ctl) to 5.13 MB (+18%), and the C++ compile went
from 81 s to over 20 min with 2.8 GB `cc1plus` peaks. On a core where §4b.2 names
instruction-fetch bandwidth as the bottleneck, +18% hot code is the predicted loss
regardless of what the Ir/cycle row says; exactness and Ir/cycle for `…d` are recorded
in `remote/causal-ab-ooo-20261013d/results.json` when the run completes (see
`AGENTS-todo.md` for the harvested figures).

**Breadth evidence collected while the builder worked (local WSL, staged
`VERILATOR_ROOT` from the CMake build via `stage_regress.sh`):** 133 upstream
`test_regress` tests in the math / select / split-var / SoA / prio / wake / table /
concat / assign families → **126 pass, 5 fail, 2 skip** (no coroutines, no `vcddiff`).
Four failures (`t_math_repl_bad`, `t_math_repl2_bad`, `t_select_bad_tri`,
`t_select_lhs_oob`) reproduce identically with the HEAD-`V3ClkSkip.cpp` baseline
compiler: they are `V3Width`/`V3Number` internal errors on the error-recovery path of
lint-only `*_bad` tests and a SELRANGE emission difference — pre-existing in the fork
tree, outside this change set, logged in `AGENTS-todo.md`. The fifth was the
`sim_time` default above, fixed. Yosys: a full-component build (minus ABC/slang, which
are not installed locally) ran the whole `tests/opt` directory: **88/96 pass**; the 8
failures reproduce byte-for-byte with HEAD's `opt_merge.cc` object linked into the
same binary (`yosys-before-full`), so they are pre-existing (`sat -verify` proofs in
`opt_expr_*`, two `opt_share`/`opt_balance_tree` selection asserts, one missing
`synth_ice40` component). `check_wide_and_loop.ys` passes on the full build;
`gtest-opt` 12/12.

### 9.6 Default status, per change

| change | default? | why |
|---|---|---|
| `_vl_insert_WI/WW` clamp (runtime header) | **yes** — it is a correctness fix with no opt-in surface | real-core s11 trace identical to the pinned reference; guarded-buffer test; 126-test subset |
| `opt_merge` indexed subscribers | **yes** — no flag exists; byte-identical RTLIL on every fixture and every `tests/opt` script | 4.9×/1.45×/1.11× on fixtures; LibreCore `synth` smoke still owed |
| `-fclock-skip` range-aware cache | **no** — stays opt-in | 3.7× on the sparse fixture, but the real OoO core is dense: +18% generated hot code, 6.2M invalidation stores, 0.88× on the dense fixture. Default-on would need a model where idle scopes dominate (the server's idle cores — but MT models are refused) |

### 9.7 Real-model verdict on the causal cache (run `…d`, harvested)

The cache model (13,099 groups, 6.18M invalidation edges) is **exact** — s11 and wprp
RVFI hashes identical to `ctl` — and **slower**: Ir/cycle 874,598 → **964,976
(+10.3%)**, I1 misses/cycle 50,758 → **67,747 (+33%)**, the 10.9k-cycle probe 9.4 s →
11.3 s wall, C++ compile 81 s → 36 min. That is the dense-activity shape of §8.4/§9.3
on the real core, measured. `-fclock-skip` stays opt-in; §9.6's table stands.

### 9.8 Still owed

LibreCore `synth` smoke for `opt_merge` on the proxy (no slang locally). FP suite,
wrong-path replay through the review runner, and the 11 frozen probes with the new
header via the normal `run_ooo_fp_review.py` path, not just the two probes above.
Cross-thread invalidation design before the cache can see the server model's idle
cores, which is the only real-model shape where §9.3's sparse gain could apply. A
further 10× on the core model is not reached and is not claimed.

### 9.9 Trace (`--trace-fst`) models segfault at start unless the stack is unlimited (2026-10-14)

`SOFT_LADDER_BUILD_TRACE_COMPACT=1` models of the OoO core (`ooocoh-t28-ooo-slw-fst-build`,
any package with the SL-W fixup queue) died with `SIGSEGV` in
`Variane_testharness___024root___eval_initial__TOP` before the first cycle, with or without
`--fst=`. `gdb` shows a plain stack overflow: the T16 flow builds with `-output-split-cfuncs 0`,
so the trace model's `eval_initial` is one function whose frame exceeds the default 8 MB stack.
`ulimit -s unlimited` before the run fixes it (the FST then dumps normally); the run scripts
(`t21/q-t29-fst.sh`) carry it. The alternative is to leave `-output-split-cfuncs` at its
default for trace builds — not measured for speed, and trace models are never the model of
record, so the ulimit is the recorded workaround.

## 10. Host ISA and word-vector (SIMD) kernels (2026-10-13)

### 10.1 Where SIMD applies, from the real-core profile

`callgrind_annotate` on the `ctl` s11 run (non-PGO, `-O2`, baseline x86-64) puts
21.6% of eval instructions and **54% of all data reads** in
`VlTriggerVec<324>::BitRef::operator bool()` — the per-region trigger-bit tests of
`eval_act`/`eval_nba` (916 + 1,542 `.at()` tests per pass over 1,084 guarded calls),
then `eval_act` body 18.7%, `eval_nba` 8.5%, `VL_ASSIGN_W` 5.4%, trigger evaluation
4.6%, and the largest single comb function 2.7%. The two hot comb functions that
could be read structurally are CAMs: the scoreboard forwarding compare
(`act_comb__TOP__185`: 955 unrolled scalar compares against `rd`, zero loops, zero
wide ops) and the LSQ/ROB match (`act_comb__TOP__343`: 597 compares). Their operands
are **packed** arrays of structs (`iq_entry_t [DEPTH-1:0] q_q` in `g6lc_iq.sv`), so
each compared field is a bit-extract at a ~100-bit stride from one `VlWide` — the
layout a vector compare needs (contiguous narrow elements) is exactly what `V3Soa` /
`split_var` produce and the stock layout does not. Three consequences:

1. **The generated code was compiled for SSE2.** The harness passed no `-march`;
   the builder is a Zen 4 (AVX-512) and the CI floor is AVX2. Everything below
   starts there.
2. **A compiler-side "seek" lowering** (N compares of `arr[i] == key` → one
   `vpcmpeq`+`movemask`) is sound only after a layout pass; on this tree it would
   gather at a 100-bit stride and lose. It is not implemented; it is the next step
   *after* `-fsoa` is qualified, and it is bounded by the ≤6% of Ir those CAMs hold.
3. **The trigger-bit scan is not a SIMD problem** (324 bits = 11 words; the cost is
   2,458 single-bit tests per pass, not the word ops). It wants an inverted
   dispatch in `V3Sched`, a scheduler change outside this pass.

### 10.2 Implemented: word-vector kernels in `verilated_funcs.h`

Portable GCC/Clang vector extension (no intrinsics headers), width chosen by the
`-march` the model is compiled with — 16 words with AVX-512 when
`VL_SIMD_PREFER_512` is set, 8 with AVX2, 4 with SSE2/NEON, scalar under
`VL_DISABLE_SIMD`/`VL_PORTABLE_ONLY`. Unaligned chunks via `memcpy` load/store, scalar
tails, and the original loop retained as the aliasing path. Routed through it:
`VL_ASSIGN_W`/`VL_EXTEND_W*`/`VL_ZERO_W`/`VL_CLEAN_WW` and the copy+zero prologues of
every `VL_CONCAT_W*` and aligned `VL_SHIFTL/R_WWI` (constant-size `memmove`/`memset`,
which the compiler expands to the widest moves it has), `VL_AND/OR/XOR/NOT_W`
(elementwise, aliasing-safe), `VL_EQ_W`/`VL_CHANGEXOR_W`/`VL_REDOR_W` (vector
OR-of-XOR accumulate, no `memcmp` call below 64 words), and the **funnel** kernel
`dst[t] = (src[t] >> a) | (src[t+1] << b)` for the middle words of `_vl_insert_WW`,
`VL_SHIFTR_WWI` and `VL_SEL_WWII` — used only when source and destination are
disjoint, with the boundary words still written by the original masked code.

Correctness evidence: `test_regress/t/t_simd_wide.cpp` cross-checks every kernel
against the pre-SIMD scalar loops for 70 widths × 3 seeds (elementwise with in-place
aliasing, eq/changexor/redor including single-bit differences in each word, extend,
every shift amount, a select grid, an insert grid with the `rbits` clamp, concat).
Passes at 4 words (SSE2), 8 (AVX2), 16 (AVX-512 on the builder), scalar, and under
ASan/UBSan at 8 and 16. The 115-test upstream subset (math/select/concat/assign/
split-var/SoA families) passes with the same 4 pre-existing failures as before.
Runtime header hash is now `ad914f2b…` (was `d49a56d2…` after §9.4).

### 10.3 Implemented: `SOFT_LADDER_BUILD_MARCH` (default `x86-64-v3` for g6lc)

`verif/regress/soft-ladder-build-harness.sh` appends `-march=<value>` to the
generated C++ flags. Default for the g6lc flavour on an x86-64 host with AVX2+BMI2 is
`x86-64-v3`; `native` opts into the build host's full ISA; `none` is the baseline
recipe and stays the pinned flavour's default so the qualification reference recipe
is untouched.

### 10.4 Measured on `g6lc64_ooo` (proxy tag `simd-ab-ooo-20261013b`)

Same compiler binary for all rows; `-O2`, no PGO, `--threads 1`, tree `90d99b70c`.
Callgrind rows are eval-only, deterministic; the s11 wall includes ~5 s of startup
and is only a sanity row (builder shared with an MT4 census run, spins skipped).

| model | header | `-march` | Ir/cycle | I1 miss/cycle | .text | s11 wall | RVFI |
|---|---|---|---:|---:|---:|---:|---|
| ctl | `d49a56d2` | none | 874,598 | 50,758 | 4.47 MB | 9.40 s | `de4f42cf…` |
| ctl-march | `d49a56d2` | x86-64-v3 | **424,291** (−51.5%) | **31,092** (−39%) | 5.66 MB | 8.88 s | identical |
| simd-march | `ad914f2b` | x86-64-v3 | **393,302** (−7.3% vs ctl-march) | 31,220 | 5.69 MB | 7.37 s | identical |
| simd-v4 | `ad914f2b` | znver4 + 512 | n/a (valgrind 3.23 has no AVX-512) | — | 5.61 MB | 7.25 s | identical |

Reading: the ISA floor is the large lever — BMI2 `shrx`/`bzhi` collapse the
shift-and-mask bit extracts the generated code is made of, and the compiler's own
vectoriser takes the constant-size copies — and it halves the instruction stream
with the RVFI stream byte-identical on both probes. The kernels add a further 7% on
top of it. `.text` grows 27% yet I1 misses fall 39%: fewer instructions fetched
outweighs the larger image. The spin-based cycles/s row is owed when the builder is
quiet; the §7.5 PGO numbers were all taken at baseline ISA and should be re-taken
with `x86-64-v3` before any of them is quoted as current.

### 10.5 Second sweep: the rest of the runtime, and the trigger guards (same day)

A pass over every word loop left in `verilated_funcs.h` / `verilated_types.h`:

| item | what changed | result |
|---|---|---|
| `VlTriggerVec::any/set/andNot` | word-vector kernels over the 64-bit words viewed as `EData` | neutral on the core (11 words) |
| `VlWide::operator!=`, `VlUnpacked::neq` | vector OR-of-XOR / `memcmp` for bitwise-comparable element types (`VlIsBitwiseComparable`: integers, `VlWide`, nested unpacked; **not** `double`) | neutral; change-detection paths |
| `VL_EXTENDS_W*`, `VL_SHIFTRS_WWI`, `VL_COND_WIWW`, `VL_REDXOR_W` | sign fills via `memset`, funnel middle words, copy, vector parity | neutral |
| `VL_COUNTONES_I/Q` | `__builtin_popcount` under `__POPCNT__` (the x86-64-v3 floor has it) | one instruction instead of 12 |
| **`-ftrigger-words`** (`V3Clock::createSenseEquation`) | a region guard `at(a) | at(b) | …` over one trigger vector becomes one `wordAny(word, mask)` per 64-bit word touched; single bits keep `at()`; `VlTriggerVec::wordAny` is the one-load-one-test runtime side | **−7.8% Ir/cycle** |

Measured on `g6lc64_ooo` (proxy tags `tw-ab-ooo-20261013` / `…-off`; same compiler
`3e622e33…`, same headers `e900ec45…`/`60e279f8…`, `-march=x86-64-v3`, no PGO; the
off control through `VERILATOR_FNO=trigger-words` because the harness appends `-O3`
after the user flags, §7.3):

| guards | `at()` emitted | `wordAny` emitted | Ir/cycle | I1 miss/cycle | D reads/cycle | .text | RVFI |
|---|---:|---:|---:|---:|---:|---:|---|
| one test per bit (off) | 20,653 | 0 | 393,335 | 31,169 | 130,167 | 5.69 MB | `de4f42cf…` / `b1632a10…` |
| word masks (on, default) | 3,722 | 2,565 | **362,616** | **28,905** | **121,173** | 5.52 MB | identical |

14,366 bit tests folded into 2,565 word tests. The off row also shows the kernel
changes of this sweep are neutral on their own (393,335 vs §10.4's 393,302): the gain
is the guard shape, exactly where §10.1's profile put the cost. Cumulative on this
tree since §10.4's baseline: **874,598 → 362,616 Ir/cycle (−58.5%)**, I1 misses
50,758 → 28,905 (−43%), RVFI byte-identical on both probes at every step.
`-ftrigger-words` is on at `-O1` and above (`-fno-trigger-words` /
`VERILATOR_FNO=trigger-words` to disable); `t_clock_skip.pl` asserts the stat and
`t_simd_wide.cpp` cross-checks `wordAny` against the bit tests.

### 10.6 Wall clock on a quiet builder (spins, proxy tag `spins-ooo-20261013c`)

The builder dropped to load 1 (only the §11 callgrind thread beside it), so the owed
spin rows were taken: the guide's steady-state metric (220k-cycle spin minus the
20k-cycle startup run, s11 ELF with a non-matching tohost), 6 alternating runs per
model, median. Same tree, same compiler lineage, `-O2`, **no PGO**, `--threads 1`.

| model | recipe | cycles/s | vs baseline |
|---|---|---:|---:|
| ctl | old header, baseline x86-64 | 3,571 | 1.00× |
| ctl-march | old header, `-march=x86-64-v3` | 16,644 | 4.66× |
| simd-march | §10.2 kernels, `-march=x86-64-v3` | 17,029 | 4.77× |
| tw-off | §10.5 kernels, `VERILATOR_FNO=trigger-words` | 16,898 | 4.73× |
| **tw** | §10.5 kernels + `-ftrigger-words` (today's default) | **17,927** | **5.02×** |

Spread within a model is ±1.5%. Startup is ~6.5 s on every row, which is why the
10.9k-cycle s11 probe (9.3 s → 7.0 s wall) could not resolve these ratios. The spin
is the idle-loop path and gains far more than the s11 mix's instruction count did
(−58% Ir): the baseline's worst code shape sits on exactly that path. A longer
*mixed* workload (OpenSBI boot on this target) is the next measurement owed before
the 5× is quoted as general; the PGO recipe of §4b.1 has not yet been combined with
`x86-64-v3` either.

### 10.7 Not done, deliberately

No intrinsics in the compiler proper (`V3EmitC`), no CAM lowering (§10.1 item 2), no
AVX-512 default (Intel downclocking and no profiler support; opt-in via
`VL_SIMD_PREFER_512`). The remaining 3,722 single-bit `at()` tests are bits alone in
their word; folding across words would need the inverted dispatch of §10.1 item 3. The
MT build path and the pinned-flavour recipe are unchanged.

### 10.8 Re-base: the §10.4–10.6 models were built without the split `.vlt` (2026-10-14)

The §10.6 ratios did not reappear on the server (`x86-64-v3` + PGO: 6,413/6,598 →
6,837/6,870 cycles/s, +5 %, §7.4a/T27), so the single-core rows were re-measured in one
session next to the T16-built models of the same compiler commit (`t21/q-spins-rebase.sh`,
s11 ELF, 20 k/220 k-cycle subtraction, `--threads 1`; the first table on a quiet builder, the
second at load ≈ 4–5 with two server builds running — best of two reps):

| model | split `.vlt` in `__verFiles.dat` | hybrid class | PGO | cycles/s |
|---|---|---:|---|---:|
| §10 `ctl` (`453031b66` + working tree, baseline ISA) | **no** | 49,158 | no | 3,561 |
| §10 `ctl-march` | no | 49,158 | no | 16,664 |
| §10 `tw` (kernels + word guards + march) | no | 49,158 | no | 17,908 |
| **T25 fork** (`453031b66`, split, baseline ISA) | yes | 10,253 | no | **28,940 / 29,303** |
| **T25 fork + PGO** | yes | 10,253 | yes | **56,120 / 55,736** |
| T28 `453031b66` + split + `x86-64-v3` + PGO | yes | 10,253 | yes | 52,669 (loaded host) |
| T28 HEAD `f7fa71520` (`-hd1`) + split + `x86-64-v3` + PGO | yes | 5,975 | yes | 54,438 (loaded host) |

Every §10 model has `split=0` in its `Variane_testharness__verFiles.dat` and the unsplit
hybrid class (49,158 ≈ the pinned compiler's 47,285), although `remote_causal_ab.py` /
`remote_simd_ab.py` set `SOFT_LADDER_BUILD_SPLIT_VLT=1`; their `SplitVar, Split packed
variables 208` (vs 137 with the control file) says an automatic split ran instead. That is the
regressed baseline behind the 874,598 Ir/cycle of §9.5 (vs 267,200 in §7.2 for the split fork)
and the 3,561 cycles/s: the design ran with the 2.2 act passes per step of §4b. The ISA floor and
the kernels mostly recovered that regression — the absolute best §10 row (17.9 k) is below the
split no-PGO model of the same compiler (29 k) and 3× below the PGO one (56 k). On a correctly
built, PGO'd single core, `x86-64-v3` and the HEAD compiler's kernels/word guards are worth
**≈ 0–5 %** (52.0 k → 52.7 k → 54.4 k, within the loaded-host noise), the same order as the
server's +5 %. The §10.4/10.5 Ir and I1 reductions are real for the unsplit model but should
not be quoted as gains over the build of record until re-taken on a split build; §10.3's
`x86-64-v3` default stands (free, exact), the 5.02× does not. The HEAD compiler's smaller hybrid
class (5,975) is a scheduler improvement to keep once its HPDCACHE regression (T27 `nline`) is
fixed. Methodological note for the next sweep: record `split`/`hybrid`/`--threads` from the Mdir
in every A/B row, and let the spin script fail loudly when `Wall clock time passed` is not found
(`spins.json` carried `cycles_per_s: 0` for every §10.6 row; the table was derived by hand).

## 11. The same question for Yosys (2026-10-13)

### 11.1 Profile first

`perf` is disabled for users on the builder (`perf_event_paranoid=4`), so the fork-built
formal yosys (`c30457480`, with `read_slang`) ran under callgrind on `cva6` for
`cv32a65x` with instrumentation switched on at `hierarchy` (slang's elaboration is not
the kernel under study), `proc; opt_clean; stat`; proxy tags `yosys-prof-cv32-20261013`
(still running at the time of writing; harvest with `pull --tag`) and the mid-run dumps.
Self cost after `hierarchy` + most of `proc` (358 G instructions):

| function | self Ir |
|---|---:|
| `SigMapView::apply(SigSpec&)` | **34.0%** |
| `dict<SigBit,int>::operator[]` | 11.1% |
| `dict<SigBit,pool<Cell*>>::operator[]` | 10.9% |
| `ProcDlatchPass::execute` | 9.0% |
| `SigMap::add` | 5.0% |
| `proc_dlatch_db_t::fixup_muxes`, `ProcRom/Init/Arst` | 2.5–2.7% each |
| malloc/free | ~6% |

So 56% of the proc phase is SigMap / hash-table traffic keyed by `SigBit` — latency-bound
pointer chasing, not a vector shape — and the server smoke's own `Time spent` row
(`prof-synth-stat-server-h`: 39% `opt_clean`, 37% `opt_expr`) says the same about the
rest. `kernel/sigtools.h` is being reworked in this tree (`touched_wires`, range
aliases) and was left alone. The one byte-parallel shape in the path is the four-state
constant arithmetic under `opt_expr`'s `replace_const_cells` (11% inclusive in the
second dump) and the `is_fully_*` predicates every pass calls.

### 11.2 Implemented: `kernel/stateops.h`

Byte-vector kernels over `RTLIL::State` arrays (one byte per bit), same portable
vector-extension idiom as §10.2, 32-byte blocks under AVX2, 16 under SSE2/NEON,
`YOSYS_NO_SIMD` for scalar: `all_in(p, n, c0, c1)` behind `Const::is_fully_zero/ones/
def/undef/undef_x_only` and the `SigSpec` counterparts; `logic(op, …)` and
`logic_not` behind `const_and/or/xor/xnor/not` (two-state lanes take the bitwise
result, a controlling 0/1 wins, anything else is `Sx` — the exact per-bit definitions,
which were one indirect call per bit). `Const` gained one read-only accessor
(`bit_data()`); nothing else in the Const API moved. Test `tests/unit/kernel/
stateopsTest.cc`: every (a, b) state pair in every lane position (vector body at all
alignments and the scalar tail), random vectors with in-place aliasing, every
predicate, and the public entry points including extension/truncation and signed
padding — against the former per-bit code as oracle. `gtest-kernel` 119/119,
`tests/opt` 88/96 and `tests/various` 151/164 with the **same** failure sets as the
pre-change binary (ABC/`synth_ice40`/`sat -verify` environment items), `opt_merge`
battery 18/18 byte-identical.

Micro-benchmark (`bench_stateops.cc`, local SSE2 build, ns per call, kernel vs its own
scalar path): `const_and` 35–97 ns vs 46–139 ns (1.3–1.45×), `const_not` 1.4×, three
predicates 1.3–1.5×, across 8–1024 bits; the floor is the `Const` copies in
`extend_u0`. **Design-level effect is not claimed**: it is bounded by the ≤11% share
above, and a synth-smoke A/B needs the slang-enabled fork build on the proxy (owed).

### 11.3 Second sweep over the remaining `State` loops (same day)

Everything else in `kernel/calc.cc`, `rtlil.cc` and `bitpattern.h` that walks a
`std::vector<RTLIL::State>` was read; the vector-shaped ones went through
`stateops.h`, each with an oracle test against the former code:

| site | before | now |
|---|---|---|
| `const_shl/shr/sshl/sshr/shift/shiftx` (`const_shift_worker`) | a `BigInteger` constructed and compared **per output bit** | int64 offset, one `memcpy` of the in-range span, two fills; amounts beyond both widths (or beyond a machine word) handled by two `BigInteger` compares |
| `const_reduce_and/or/xor/xnor/bool` | sequential fold through a function pointer | one `summarize()` scan (any 0 / any 1 / any other / parity) |
| `const_eq/ne` | per-bit loop with early exit | `eq_status()` block scan |
| `const_eqx/nex` | per-bit loop | `memcmp` |
| `const_mux` (undefined select), `const_bweqx`, `const_bwmux` | per-bit `set()` | lane kernels |
| `BitPatternPool::match` (proc_mux / opt_muxtree cubes) | per-bit loop | `cubes_match()` block scan |

`stateopsTest.cc` grew to 7 tests / 122 in `gtest-kernel`: reductions and `$eq` with
every state in every lane and parity across block boundaries; the shift worker against
the **original BigInteger implementation** on 2,000 random cases (small, around-width,
2^69 and signed-negative amounts, undefined select bits, every public entry point);
the mux family and the pool through its API. `tests/opt` and `tests/various` failure
sets identical to the pre-change binary; `opt_merge` battery 18/18 byte-identical.

Micro-benchmark, same binary lineage, `afaf65697`'s `calc.cc` object vs now (ns per
call, local SSE2 build): `const_shr` **549 → 292 (8 bits), 2,959 → 296 (64),
41,701 → 299 (1024 bits, 140×)**; `const_eq + const_reduce_or` 107 → 89 (8), 386 → 81
(64), 2,655 → 223 (1024). The elementwise rows did not move (same kernel on both
sides). Design-level share remains bounded by the `opt_expr`/`ConstEval` fraction of
§11.1 and is not claimed; `$shiftx` from part-select lowering and parameter arithmetic
are where the shift row shows up.

### 11.4 Into SigMap and the hash tables (same day, uncommitted in `tools/yosys`)

The 56 % of §11.1 was read at the mechanism level before deciding what a vector unit
could do for it. Three things were found; only one was a SIMD shape, and it was not
the one that mattered.

**(a) The alias chain had no path compression.** `SigMapView::apply(SigBit&)` hops
through the alias ranges one bit at a time: each hop is a `dict<Wire*>` lookup plus a
binary search, and a chain of partial connections (`w3[..] <- w2[..] <- w1[..] <- in`,
each a chunk alias) makes every bit of a wide port pay the whole chain; unlike the
union-find there is nothing to compress. The probe (`probe_sigmap.cc`) on a 400-wire ×
256-bit chain fixture: **31.4 hops per bit**, `database.size() == 0` — every
connection had gone into the alias ranges. Bits that one alias covers all land in one
span of its image, so `apply(SigSpec&)` now walks **spans**: a worklist of
(wire, offset, width, output position, depth); each hop is taken once per run of
bits; spans no alias covers take the union-find step per bit; a single-bit span, a
single-bit chunk, an image back on the origin wire (where the per-bit loop's cycle rule
decides) and the 4096-hop budget are replayed by the per-bit loop, so the result is
bit-for-bit the old one. Oracle test `SpanWalkMatchesPerBitLoop`: 60 random modules
(whole, partial, reversed, constant, two-source and self-referencing connections, deep
chains) × 40 multi-chunk queries, every bit compared against `apply(SigBit&)`. It
caught one real bug on the way (a replay that passed the same object as `bit` and
`origin`).

**(b) The union-find key store hashed every (wire, offset).** `idict<SigBit>` is now
`SigBitIdict`: a dense per-wire `std::vector<int>` of entry indices (one `dict<Wire*>`
lookup per wire, an array read per bit, insertion-order indices exactly as before;
constants keep a small hash). `mfp<>` took a third template parameter for the store.
This is what makes the uncovered spans above one lookup per *span*.

**(c) The bucket division.** `dict`/`pool::do_hash` did `hash % prime` — an integer
division on every lookup of every table in Yosys. Now Lemire's multiply-high
(`hash_bucket`); which bucket a key lands in is unobservable (iteration walks the entry
vector), so outputs are unchanged. This is arithmetic, not SIMD, and it is the only
part of the hash tables that was instruction-bound: the rest is one dependent cache
miss per probe, which a wider register does not shorten.

Measured (`check; opt_clean; opt_expr` on the fixtures, same source otherwise, outputs
byte-identical, two runs each):

| fixture | pass | before (ms) | now (ms) |
|---|---|---:|---:|
| 400 × 256, chains of partial aliases | `check` | 435–490 | **133** (3.4×) |
| | `opt_clean` | 151–157 | **79–82** (1.9×) |
| 2000 × 64, deep chains, random cuts (adversarial fragmentation) | `check` | 4,279–5,624 | 3,467–3,591 (~1.3×) |
| | `opt_clean` | 1,208–1,601 | 1,134–1,259 (~1.1×) |

The second fixture is the honest floor: random cuts fragment spans to single bits
after a few hops, where the walk degenerates to the per-bit loop plus bookkeeping; the
single-bit shortcuts are what keep it from losing. `gtest-kernel` 123/123;
`tests/opt`, `tests/various` and the `opt_merge` battery unchanged (see below). The
`cva6`/`cv32a65x` profile of §11.1 has not been re-taken on this binary (owed with the
slang build on the proxy).

**What SIMD could still do here, and was not done:** the uncovered-span loop reads
contiguous `idx[pos]` and could test eight for `-1` at once with a compare+movemask,
and the roots' `parents[]` could be gathered (`vpgatherdd`) — but the per-bit work
there is one array read and one `SigBit` store, so the gain is bounded by a few
percent of a path that just lost its hops; it is not where the next factor is.

### 11.5 Not done

No SIMD in the hash probing itself (one dependent miss per probe; a Swiss-table tag
group would need a second index beside the ordered entry vector to keep iteration
order and RTLIL byte-identity — possible, not measured, not started), no change to
`Const::hash_into` (a different hash would reorder `dict` iteration and with it RTLIL
output — byte-identity is the test oracle here), no AVX-512 path. **`-march` for Yosys
itself, measured and not adopted:** two builds of
the same source and component set (`yosys-march-base` / `yosys-march-v3`,
`-DCMAKE_CXX_FLAGS=-march=x86-64-v3`), 12 alternating runs per fixture, outputs
byte-identical: `opt_merge` pass time −4 % to −9 % (108 → 100 ms on the 32k-duplicate
fixture), process wall within ±5 % (noise). Hash-table and pointer-bound code does not
have Verilator's shift-and-mask shape, so unlike §10.3 the ISA floor is not a lever
here; `install-formal.sh` / `install-yosys-g6lc.sh` keep the compiler's default ISA,
and the `stateops` kernels run at 16 bytes (SSE2) in those builds.

