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
- **The compiler binary itself** (available, not yet A/B-measured):
  `build-platform/scripts/install-gcc.sh` builds a c/c++-only GCC (`GCC_VER`,
  default 16.2.0) on the builder into `/opt/testharness/toolchains/gcc-<ver>-<tune>`
  — `--with-tune=znver4`, `-march=native` for cc1/cc1plus itself, and
  `make profiledbootstrap` by default (`GCC_PROFILED=0` for a single-stage
  install). The harnesses select it per build with
  `SOFT_LADDER_BUILD_TOOLCHAIN=<prefix>` (hyp8: `HYP8_BUILD_TOOLCHAIN`; proxy:
  `build <flavour> --env SOFT_LADDER_BUILD_TOOLCHAIN=<prefix>`); env.sh's bare
  `CXX=g++`/`CC=gcc` counts as unset, an explicit `CC`/`CXX` path still wins.
  Expect at most low-teens % on cold cc1plus-bound builds — the 30 MB units
  dominate regardless — and zero on ccache hits; a different compiler is a new
  instrument and needs re-qualification before it carries evidence.
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

## 12. V3Case constant-result case → ConstPool lookup tables (2026-11-19)

A second case-lowering path now runs inside `V3Case::caseAll`, ahead of the
existing `replaceCaseFast`/`replaceCaseComplicated` compare-tree lowering
(`tools/verilator/src/V3Case.cpp`, `tryCaseTable`). Motivation from the hyp8
r125-aggregate model: large constant-result decoders such as
`extract_transfer_size` (`core/include/g6lc_core_pkg.sv`) and `ooo_lat_class`
(`core/ooo/g6lc_ooo_pkg.sv`) lower to fully-unrolled bit-test trees — ~1,155 and
~171 inlined instances respectively, contributing several thousand `goto
__Vlabel` branch sites to `.text` on top of the §7 I-cache pressure. A 256×N-bit
`.rodata` table plus one `AstArraySel` replaces the whole tree and deduplicates
across the design through `AstConstPool::findTable` (the same machinery
`V3Table` uses for `always` blocks, which cannot see function-internal cases).

Recognized shape (all arms must agree):

- Index expression width 2–12 bits (table ≤ 4096 entries).
- Every arm is exactly one effective statement — through single-statement
  `begin` wrappers — of one of:
  - `<lhs> = const` (`AstAssign`, same lhs tree on every arm),
  - `<lhs> <= const` (`AstAssignDly`),
  - `return const` (`AstReturn`, kept as `return TABLE[idx]`; requires an
    enclosing `AstNodeFTask` with `isFunction()`),
  - `<fvar> = const; goto exit` — the form `return` actually takes after
    `V3LinkJump` (which runs long before `V3Case`): a blocking assign to the
    function return variable followed by an `AstJumpGo`. Emitted as
    `fvar = TABLE[idx]; goto <first arm's exit label>`. `isFuncExitJump`
    verifies each jump targets a function-exit label by walking the label's
    `JumpBlock` chain to the `AstNodeFTask` (only `JumpBlock`/`JumpLabel`
    nesting may intervene), which rejects `break`/`continue` jumps that
    share the `[assign, JumpGo]` arm shape inside loops. V3LinkJump wraps the
    function body per return, so arms may target *different* label nodes —
    all are semantically the same exit and any one is reused.
- Arm constants are plain 2-state bit-vector `AstConst`s of identical width,
  and that width must equal the assignment lhs / function return width
  exactly (no implicit extension semantics are introduced).
- Labels are plain constants of the index width; duplicates are rejected so
  `CASEOVERLAP` lint semantics are preserved. `casex`, `casez`,
  `case inside`, `notParallel` assertion blocks, and cases inside
  DPI-import/class-method/recursive/constructor tasks are rejected.
- A `default` arm supplies uncovered indices; without one the labels must
  cover all `2^indexWidth` patterns.
- At least 8 distinct labels — smaller cases stay on the cheaper tree path.

Emission: `AstUnpackArrayDType` + `AstInitArray` registered in
`typeTablep`, deduplicated via `constPoolp()->findTable`, then a single
`AstArraySel{tableVarScope, clonedIndexExpr}` feeds a cloned-lhs
`AstAssign`/`AstAssignDly` or an `AstReturn`. The transform runs before
`V3Task` inlining, so replicated function instances share one table.
`V3Slice`/`V3Const`/`V3Simulate` already handle `AstArraySel`-on-`InitArray`
correctly at this pipeline point (verified against `V3Slice.cpp`,
`V3Const.cpp`, `V3Simulate.h`).

Expected coverage on hyp8: the `fu_op`-class decoders (`extract_transfer_size`,
`ooo_lat_class`, latency/pipe lookups) are the canonical targets — small enum
index, uniform constant results, heavy inline replication. Branchy or
state-dependent cases are untouched.

Regression: `test_regress/t/t_case_table.{v,pl}` covers blocking/NBA/return
arms (the return case exercises the post-V3LinkJump assign+JumpGo shape),
full-coverage-no-default, multi-label items, and the reject paths
(few arms, `casex`, mixed lhs, non-constant arm), checking results against
if/else reference functions and asserting the `Cases to lookup tables`
statistic = 6. **Status: PASSED on the remote dev build**
(`t_case_table`/`t_prio_oracc`/`t_prio_lzc` all green); hyp8 verilation
A/B in progress — no speedup claimed until generated-code and runtime
deltas are measured.

### 12.1 Implemented: `V3Prio` or-accumulate loops → one-hot guard + ctz

`tools/verilator/src/V3Prio.cpp` gained `tryOrAccumulate`, a third loop
lowering beside `tryFind`/`tryGrant`, targeting the `mask_to_tag`/
`mask_to_ftag`/`fbank_mask` family in `core/ooo/g6lc_rename_read.sv`
(~700 inlined sites × ~72 bit-tests each in the r125 model). The RTL shape
is `for (i = 0; i < N; i++) if (m[i]) out = out | W'(i);` — a loop that ORs
the index of every set mask bit into `out`.

Recognized shape (all required):

- `matchUpCount` with the bound relaxed from 64 to 4096 trips (`kMaxAccWidth`)
  via a new `maxTrips` parameter; `kMinAccTrips = 8` keeps tiny loops plain.
- Body is a single `if (m[i])` with no else; the condition must be an LSB-first
  bit scan of a plain vector variable. `bitScanAcc` (or-accumulate-only; the
  shared `bitScan` used by find/grant is untouched) sees through the two
  V3Width lowerings of this idiom: `W'(i)` size casts become `SEL(i,0,w)`
  truncations, and dynamic `vec[i]` becomes `AND(rangeGuard, SEL(vec,i,1))`.
  `idxExprVar` accepts a bare index `VarRef` or a zero-lsb `Sel` of it, and
  `idxWideEnough` requires `2^w >= vecWidth` so a truncated index cannot wrap
  inside the loop; `isRangeGuard` accepts only unsigned upper-bound compares
  (`Lt/Le/Gt/Gte` vs constant) that hold for every `i < vecWidth`. MSB-order
  scans and every non-index operand still reject.
- `vecp->width() == trips` — the mask must be exactly the loop bound, so no
  out-of-range or untested high bits exist.
- Then-branch is one blocking `AstAssign` whose lhs is a plain `AstVarRef`
  (`acc`) and whose rhs is `Or(acc, idx)` or `Or(idx, acc)` where the acc side
  is a plain `AstVarRef` and the index side passes `idxExprVar`+`idxWideEnough`
  — no part-selects or expressions (`i + 1`, `i[3:0]`, etc. all reject).

Emission: `if (VL_ONEHOT0_*(m)) acc = acc | VL_CTZ_*(m); else <original
loop>`. For a one-hot mask the loop ORs exactly one index — `ctz(m)`; for an
empty mask `ctz` is 0 and `acc | 0` preserves the pre-loop value, matching
the loop's no-op. `VL_ONEHOT0_*` is true for both empty and single-bit masks,
which is exactly the equivalence domain; multi-bit masks take the untouched
else branch and stay bit-identical. Helper selection is width-tiered:
`VL_ONEHOT0_I`/`VL_CTZ_I` ≤32 bits, `_Q` ≤64, and the word-pointer
`VL_ONEHOT0_W`/`VL_CTZ_W` beyond (`hostCallWI` emits the `(words, data)`
call form; `VlWide::operator WDataInP` makes the argument conversion
implicit). Verilator's clean-upper-bits invariant on wide vars keeps the
extra storage bits of `VL_CTZ_W` reads zero, so indices stay < width.

Because the lowering is guarded rather than proven one-hot, it is exact for
every input — the else branch is the original loop verbatim. The transform
counts under the existing `Optimizations, Priority encoders lowered` stat.

Coverage note: `V3Prio` is opt-in (`-fprio`, `V3Options.h`); the transform
only fires when the flag is on. The hyp8/soft-ladder perf builds currently
leave `-fprio` off (the pre-existing lzc/find/grant bundle measured negative);
this transform targets a different, larger pathology and is the reason to
re-measure `-fprio` on the A/B harness.

Regression: `test_regress/t/t_prio_oracc.{v,pl}` exercises all three helper
tiers (16/48/72-bit masks in `mask_to_tag`-shaped functions plus a 32-bit
`always_comb` loop), zero/one-hot/multi-bit masks, and two reject paths
(descending `m[31-i]` scan, `i + 1` non-index operand) with golden-value
checks and a stat count of 4. **Status: PASSED on the remote dev build**
(`verilator-g6lc-dev`, all three of `t_case_table`/`t_prio_oracc`/
`t_prio_lzc` green); no speedup claimed until an A/B on the hyp8 harness
exists.

**Pass-order caveat (measured, not yet solved):** `V3Prio` runs at stage
`022_prio`, *after* the early `V3Unroll` at `021`. Any loop whose trip count
is ≤ `--unroll-count` is already unrolled before the matcher sees it — the
hyp8/soft-ladder builds use `--unroll-count 256`, so every or-accumulate
loop in the 16–256-bit range dies at 021 and `-fprio` cannot reach them.
Making the transform effective on those builds requires either a lower
unroll count for this loop class (a `V3Unroll` heuristic, e.g. skip
unrolling when the body matches the or-accumulate idiom) or moving the
prio pass earlier — both are open work, and the unroll-count interaction
must be A/B'd since unrolling also has I-cache costs of its own.

Remaining follow-ups (not yet implemented): `__Vsampled__` shadow
copies (~786/eval) need lazy-or-batched sampling in `V3Clock`; function
outlining for high replication × body-size remains the largest I-cache lever.

## 13. objdump → sqlite hot-path forensics on `Variane_testharness` (2026-11-19)

Static generated-C++ census (§7, §12) counts *sites*; this section counts
*executed-structure reachability* — which machine code the per-cycle eval can
touch — by disassembling the shipped ELF into sqlite and querying it.

### 13.1 Pipeline

Artifacts (from `remote-runs.drvfs-bak/hyp8-r125-aggregate-t4/output/model/`):

```
objdump -d --no-show-raw-insn -M intel Variane_testharness > variane.asm   # 2.93M insns
nm -S --defined-only Variane_testharness                 > nm.txt         # 3,417 syms
python3 verif/regress/remote/analyze_objdump_hotpaths.py \
    --asm variane.asm --nm nm.txt --db variane.db --report report.json      # ~17 s
```

`analyze_objdump_hotpaths.py` (committed, MIT tooling) parses the disassembly
into `functions / insns / bbs / calls / func_mnem` tables and computes a
**structural hotness tier** per function by BFS over direct call edges from
eval roots. Tiers: `HOT` (per-eval cone), `STG`, `INIT`, `FINAL`, `COLD`
(unreachable), `LIB` (`.plt`). `.text.unlikely` partitions are forced COLD —
GCC's own hot/cold split is respected. The DB is regenerable (~172 MB);
queries below are plain sqlite3/python.

**Tier caveat that changed the numbers**: with `--threads 4`, sequent/comb
partitions run on worker threads through `VlThreadPool`'s queue — indirect
dispatch invisible to static call graphs. `__Vthread__nba__0/1/2` had *zero*
static callers and were initially COLD along with their entire cones
(~1,250 functions). They are now HOT roots; without that fix HOT was
under-counted by ~4.4 MB. Any static call-graph analysis of an MT model
must seed thread-entry functions explicitly.

### 13.2 Headline statistics (HOT = per-cycle cone)

| Metric | Value |
|---|---|
| HOT functions | 1,999 of 3,168 (63%) |
| HOT `.text` | **12.73 MB of 13.49 MB total (94%)** |
| HOT instructions | 2,777,951 of 2,922,158 (95%) |
| HOT branches (jmp+jcc) | 173,393 |
| HOT basic blocks | ~208K, avg 13.3 insns, **max 21,789** |
| COLD remainder | 984 funcs / 605 KB (`.cold` partitions, `__Syms` ctor, `main`, dump/trace) |

Function-size distribution in HOT: p50 = 293 B, p90 = 15 KB, p99 = 98 KB,
max = **218,752 B** (`___nba_sequent__TOP__131`, 45,675 insns, only 43
branches — a near-branch-free straight-line monster). Top-20 HOT functions
are all `___nba_sequent__TOP__*` / `___stl_*` / `___act_comb__TOP__*`
region functions of 95–218 KB each.

### 13.3 Opcode census (HOT, 2.78M insns)

| Class | Count | Share | Note |
|---|---|---|---|
| `mov` | 797,634 | 29% | incl. state-struct traffic |
| `and`+`or`+`xor` | 756,843 | 27% | bitwise kernels, inlined `_vl_words_*` |
| shifts (`shl/shr/shrx/shlx/shrd`) | 365,329 | 13% | variable part-selects, funnel shifts |
| `movzx` | 119,217 | 4.3% | bit/byte field extracts |
| `cmp`+`test` | 149,521 | 5.4% | compares feeding branches/setcc |
| branches | ~173K | 6.2% | jmp 60K + je 51K + jne 43K + … |
| `sete`/`setcc` family | ~45K | 1.6% | GCC if-conversion (branch→setcc+logic) |
| `call` | 30,895 | 1.1% | see §13.4 |
| SIMD `ymm`/`zmm` insns | 14,278 | 0.5% | AVX2 only; **zero AVX-512, zero xmm-only** |
| indirect `jmp`/`call` | 33 / 10 | — | jump tables are rare; GCC already lowered switches to compare trees |

Memory operands: ~440K state-struct accesses (`[reg+disp]` on the
`___024root` pointer — *not* rip-relative), ~286K stack, ~41K rip-relative.
≈27% of all HOT instructions touch memory — the D-cache side of the same
wall as the I-cache side.

### 13.4 The debug/trace tax — biggest single lever found

Top static call targets inside the HOT cone:

| Callee | Call sites | Role |
|---|---|---|
| `VL_WRITEF` | 5,800 | `$display`/`$write`/`$monitor` formatting |
| `sc_time_stamp` | 5,505 | `$time`/`$realtime` evaluation |
| `Verilated::threadContext` | 5,497 | TLS/context fetch in debug+MT paths |
| `VL_STOP_MT` | 5,380 | `$stop`/`$fatal`/assertion failure path |
| `VL_DBG_MSGF` | 2,355 | `VL_DEBUG_IF` message bodies |
| **subtotal** | **24,537** | **79% of all 30,895 HOT call sites** |

These are mostly *guarded* (debug flag / assertion-fail / display-enable), so
they rarely execute — but their code, guard branches, and call sites are
unconditionally resident in `.text` and in the per-cycle call cone. This is
the concrete machine-level cost of the `-DVL_DEBUG` + `--assert` +
trace-enabled verification build identified in §7-F: a perf SKU compiled
without them sheds the majority of remaining call scaffolding and a large
fraction of the 13.5 MB `.text`. `VL_CVT_PACK_STR_NW` (name packing for
displays, 114 sites) and `VlTriggerVec::BitRef::operator=` (211 sites, the
change-detect writes) are the next tier.

Non-inlined compute helpers still called: `VL_SHIFTL_WWI` funnel shift
(~460 sites across `.constprop`/`.isra` clones — the 365K shift insns'
outline path), `VL_ASSIGNSEL_WQ`/`_vl_insert_WW` part-select writes
(~420 sites), `_vl_words_zero` (42).

### 13.5 What the numbers say about generic improvements

Ranked by measured structural impact, all generic (not hyp8-specific):

1. **Code volume is the wall, not branch count.** 95% of `.text` is in the
   per-cycle cone; the largest functions are *straight-line* (43 branches /
   45K insns). I-cache misses are driven by bytes-touched-per-eval, so the
   wins are transforms that shrink generated code: case→ConstPool LUT
   (§12, kills compare trees), or-accumulate→ctz (§12.1, kills ~72-test
   chains), and **function outlining / dedup of the ~90×-replicated
   `__Vfunc` instances** (25K instances / 282 functions — the single largest
   remaining volume lever).
2. **Debug/trace scaffolding ≈ 79% of call sites.** A `VL_DEBUG`-free,
   `--assert`-free perf flavour is worth more than any single RTL transform
   measured so far — it is a build-config change, zero compiler work.
   `VL_ATTR_COLD` already isolates `.cold` partitions correctly (605 KB
   total), proving the mechanism works when applied.
3. **Shift+extract dominance (17.3% of insns).** `shlx/shrx/andn` prove
   `-march=x86-64-v3` is live. The residual cost is *dynamic* part-selects
   and funnel shifts — exactly what `VL_SHIFTL_WWI`/`_vl_insert_WW` outline
   (~880 combined call sites). Generic target: recognize funnel-shift and
   variable-bit-slice idioms in `V3Slice`/`V3Prio` and emit `shld/shrd`-class
   single-insn forms or `bzhi`/`pdep`-style BMI ops where the pattern is
   provably equivalent; keep the `_W` helper as fallback.
4. **SIMD is nearly absent (0.5%) and that's structural, not a kernel gap.**
   State is accessed as scalar words through the root struct (440K disp-mem
   ops); the `_vl_words_*` AVX2 kernels only fire on ≥256-bit packed ops.
   AVX-512 masked ops would not move this needle — the blocker is AoS→SoA
   data layout (`V3Soa` refuses ~13.8K sites), not instruction selection.
   Confirmed: no hot call site justifies AVX-512 kernels today.
5. **Branch density leaders are settle/comb regions** (`stl_sequent__TOP__37-39`
   at 45–47 branches/KB, `act_comb__TOP__198-200`, `nba_comb__TOP__759`) —
   consistent with the if-chain/decision-tree pathologies the case-table and
   prio transforms target. `jmp`-table density is negligible (33 indirect
   jumps HOT-wide), so LUT-vs-tree trade-offs should assume compare trees,
   not `jmp *`.
6. **BB granularity**: avg 13.3 insns/BB but 157 BBs exceed 1,000 insns and
   one reaches 21,789 — straight-line regions where *no* branch predictor or
   skipping helps; only code-size reduction (outlining/dedup/LUT) shrinks
   their fetch footprint.

### 13.6 Reusable queries

```sql
-- top HOT functions by size
SELECT size, insn_count, n_jcc+n_jmp, name FROM functions
 WHERE tier='HOT' ORDER BY size DESC LIMIT 25;

-- branch-density hotspots
SELECT (n_jcc+n_jmp)*1024.0/size AS per_kb, name FROM functions
 WHERE tier='HOT' AND size>20000 ORDER BY 1 DESC LIMIT 15;

-- debug/trace call-site census
SELECT c.target_addr, COUNT(*), MAX(c.target_name) FROM calls c
 JOIN functions f ON f.addr=c.caller_addr WHERE f.tier='HOT'
 GROUP BY c.target_addr ORDER BY 2 DESC LIMIT 15;

-- opcode mix per tier
SELECT mnem, SUM(count) FROM func_mnem fm JOIN functions f
 ON f.addr=fm.func_addr WHERE f.tier='HOT' GROUP BY mnem
 ORDER BY 2 DESC LIMIT 25;

-- map a function back to its generated .cpp: nm each *.o for the symbol,
-- the .o basename is the DepSet filename.
```

Caveats: tiers are *structural* reachability, not sampled frequencies —
trigger gating inside functions means the dynamically-hot subset is smaller;
`.cold` partitions and `__Vthread__` seeding are the two corrections already
applied. For true per-instruction counts, run `perf record` on the builder
against the same ELF (the archive lacks `.gcno`, so the `.gcda` set is
unusable without the instrumented objects).

## 14. Dynamic-instruction A/B: case-table measured −23% retired insns (2026-11-20)

`verif/regress/remote/perf_ab.sh` runs `perf stat -e
instructions,cycles,branches,branch-misses` on the hyp8 mc model
(`g6lc64_hyp8_mc`, `--threads 4`), same `fw_payload.elf` +
`+max-cycles=40000 +tohost_addr=0xdeadbeef`, alternating baseline-PGO vs
dev-noPGO binaries. Retired instructions are the PGO-independent dynamic-work
metric — profile data changes layout, not the instruction stream — so this
isolates the §12 codegen delta from the earlier wall-clock confound (dev was
built `HYP8_BUILD_PGO=0` while the baseline carried simulation PGO).

Measured (2 reps each; `instructions:u` counts all worker threads):

| metric | baseline-PGO | dev (case-table, no PGO) | delta |
|---|---|---|---|
| instructions | 1.278e12 avg | 0.979e12 avg | **−23.4%** |
| host cycles | 6.36e12 | 3.81e12 | −40% |
| branches | 222.6e9 | 119.1e9 | **−46.5%** |
| branch-misses | 3.468e9 | 3.370e9 | −2.8% |
| branch-miss rate | 1.56% | 2.87% | +1.3pp |

Per-pair deltas (B1/D1 = −27.7%, B2/D2 = −19.0%) bracket rep-to-rep noise
(~2% on baseline, ~10% on dev — MT task partitioning is not perfectly
deterministic under load). The effect is far above noise: **24 tabled cases
removed ~300 billion retired instructions per 40K-cycle run (~7.5M per
simulated cycle, ~23% of all dynamic work)**. The decode trees they replaced
sat in per-cycle instruction-decode paths replicated across 8 harts.

Mechanism check: dev host IPC rose 0.20→0.30 — table loads shortened the
dependency chains that branch trees serialized. Branch-miss *rate* doubled
(1.56%→2.87%) but total misses fell slightly; the compare-tree branches were
well-predicted, so prediction loss is small next to the retired-work win.

Consequences:

- `.text` size and generated-line count were poor proxies — the win came
  from removing dynamic work on hot decode paths, exactly the §13 thesis.
- The transform is generic: any constant-result `case` (enum→field decoders,
  latency/pipe lookups) benefits; it is not hyp8-specific.
- Wall-clock verdict pending the dev+PGO rebuild (`dev_pgo_rebuild.sh`,
  phase-2 `-fprofile-use` done 2026-11-20) — `ab_timing.sh` A/B in flight.
- `-fprio-oracc` (§12.1) verilated on the same model: `Priority encoders
  lowered = 4` → 140 `VL_CTZ_W`/`VL_ONEHOT0_W` sites, all in DepSet
  `h24430560` (the rename/dispatch region). No-PGO build + perf A/B queued.

## APU Compiler/Simulator PGO And Bounded Unroll

APU RTL leaves now provision the `tools/verilator` fork through
`verif/tb/apu/local-verilator.sh`, requiring a validated compiler-PGO receipt.
Compiler and generated-simulator PGO are both ON by default and forced for
remote RTL leaves. Their receipts are separate: the toolchain record requests
simulator PGO; a validated `simulator-pgo.json` proves completed profile-use.
No simulation throughput improvement is inferred without an A/B measurement.

`apu_verilator_pgo.py` uses a private out-of-tree GCC generate/train/use build.
Both passes use identical object paths, ccache is disabled, and profile-use
forces recompilation without cleaning a shared source tree. The fixed small
SV training input exercises full C++ generation with threads 1 and 2; each
training call is capped at 60s. Required core gcov profiles, positive unroll
counters, source/recipe hashes and the actual final binary hash are recorded.
Profile-use failure or receipt mismatch blocks execution; there is no release
fallback. Cold setup has its own default 1200s cap, not a promised test duration.

Actual model commands carry `--unroll-count 256 --unroll-stmts 131072 --stats`.
The fork's late environment overrides are pinned to those same limits and
narrow rolling is disabled, so ambient experiments cannot undo the policy.
The standalone fixture measured three unrolled loops on pinned 5.008.
This verifies that mechanism, not every design loop or cycle accuracy.

The compiler cache keys compiler sources and PGO recipe/training inputs, not
every functional RTL edit. Native SIMD ISA flags are not added. Explicit local
`APU_VERILATOR_PGO=0` selects the old plain cache and is unverified; testharness
RTL leaves force PGO internally. Status and actual cold-build evidence:
`architecture/uncore/apu-pgo-dma-increment.md`.

`apu_sim_pgo.py` additionally auto-builds generated C++ with GCC instrumentation,
runs bounded mechanism training, then forces a profile-use rebuild in identical
object paths. It overrides both CXX and LINK: the compiler's configured runtime
makefile must not inject compiler-training profiles into simulator compilation.
Unroll policy and stats are appended for legacy model builders too.

Source/compiler/recipe/flags/vector identities key private attempts. Accepted
images are immutable; dev validation binds the absolute image from its per-run
receipt. Setup1800s, native phase600s, training60s and validation60s are separate
limits. Missing/stale receipts block; `--check` remains presence-only.

Development edits the mutable tree while detached tests consume frozen source
and tooling. Training/launch are not a PASS or counted CTS coverage. The bridge
workload is idle-only, not representative of guest shader speed. New generic
pipeline evidence is a real standalone infrastructure probe, not device RTL.
Current policy/workloads and limits:
`architecture/uncore/apu-simulator-pgo-implementation.md`.

T2 resource lifetime checks are separate host-model tests, not PGO training
or RTL evidence. Run the DMA/lifetime cohort from copied, hashed Python
inputs while implementation continues in the live tree; no compiler rebuild
is needed. Global backing versus context access and open dispatch gates:
`architecture/uncore/apu-resource-lifetime-increment.md`.

The native control/queue follow-up adds16 short host cases to that frozen
cohort (40 total). These validate lifecycle wire dispatch and preauthorized
scatter/gather, not generated simulator performance or RTL qualification.
`architecture/uncore/apu-native-control-increment.md`.

The runnable native control backend passes58 frozen-source checks, including
the real local IPC process with the existing RTL bridge client. This is host
control-path evidence, not a simulator throughput or Vulkan qualification
claim; compiler-PGO recipes remain unchanged.
`architecture/uncore/apu-native-bridge-implementation.md`.

For bounded native decoder/memory work use apu_native_verify.py: presence-only
--check, frozen source/assets,60-second cohort limit, owned process-group
termination and INCOMPLETE on timeout. Current73 tests pass2.882s; this is not
a simulator throughput measurement or a substitute for PGO-enabled RTL gates.
`architecture/uncore/apu-native-linear-implementation.md`.

Native ring scheduling now shares command/execution-byte and snapshot-read
budgets; waits yield and context retirement prevents stale publication.
The frozen native cohort passes93 checks in4.745s. No Verilator build was
needed for this host-only increment; default compiler/simulator PGO remains
mandatory for actual RTL lanes.
`architecture/uncore/apu-native-ring-implementation.md`.

Native continuation tests freeze inputs while implementation proceeds in the
live tree. Linear/nested waits park; per-poll execution/read budgets and queue
reauthorization bound resumed work. Use the same native verifier and keep
host-model durations separate from generated-simulator throughput/PGO evidence.
`architecture/uncore/apu-native-continuation-implementation.md`.

Native dependency scheduling uses the same bounded frozen lane:119 checks
pass8.762s with60 unchanged hashes. DAG validation precedes child reads;
blocked siblings retain positions/replies while other ready children run.
This is host-model evidence, not simulator throughput or PGO training.
`architecture/uncore/apu-native-dependency-implementation.md`.

The native transfer foundation runs133 frozen checks in7.101s. Chunk/queue/
byte budgets and work leases bound execution independently of live development.
No compiler build/training is needed for this host cohort. Do not infer RTL
throughput, PGO speedup or GPU admission from host byte-copy results.
`architecture/uncore/apu-native-transfer-implementation.md`.

Transfer-only CB/secondary replay uses the same frozen lane:146 checks pass
10.797s,64 hashes unchanged. Planning and execution have separate record,
snapshot, operation and byte limits; ownership guards park rather than spin.
No RTL/compiler build or PGO training is implied by host-model results.
`architecture/uncore/apu-native-replay-implementation.md`.

Explicit transfer-submit diagnostics use the frozen host lane:159 checks pass
8.150s,66 hashes unchanged, including real CLI/bridge retirement and memory I/O.
Do not interpret these durations as RTL throughput or PGO speedup. The default
endpoint still refuses GPU submit; zero capsets and RTL PGO requirements remain.
`architecture/uncore/apu-native-submit-implementation.md`.

Native binary token scheduling adds11 directed cases:170 frozen checks pass
14.423s with68 unchanged hashes. Job preparation and token retention use the
existing bounded queue/operation lane. No RTL/compiler build, PGO speedup or
Vulkan admission is inferred.
`architecture/uncore/apu-native-binary-semaphore-implementation.md`.

Timeline host APIs add12 directed regressions:182 frozen checks pass12.467s,
70 hashes unchanged. Waits save deadlines/generations and cooperate with poll.
This host-only decoder lane neither regenerates RTL nor measures simulator PGO;
queue timeline scheduling remains a separate implementation gate.
`architecture/uncore/apu-native-timeline-host-implementation.md`.

Timeline queue progress uses bounded lane-head selection:197 frozen checks pass
14.198s,74 hashes unchanged. Context byte/turn limits and internal FIFO remain;
no new physical queue or simulator throughput is inferred. Clean receipts reject
unraisable/resource warnings, and timeout stays INCOMPLETE/exit4.
`architecture/uncore/apu-native-timeline-queue-implementation.md`.

Native image rows share the existing bounded operation/byte lane:210 frozen
checks pass12.023s,76 hashes unchanged. Pitch/mip/layer copy evidence does not
establish image-layout, renderer, RTL throughput or PGO qualification.
`architecture/uncore/apu-native-image-copy-implementation.md`.

Native coherent image barriers share operation/lease budgets:220 frozen checks
pass13.371s,78 hashes unchanged. Native capture does not regenerate RTL tables;
coherent host ordering is not a hardware cache/timing/PGO qualification.
`architecture/uncore/apu-native-image-barrier-implementation.md`.

Native clear patterns avoid whole-image host expansion:230 frozen checks pass
30.925s,79 hashes unchanged. Per-record payload bounds and partial-texel chunks
are host semantics, not RTL/PGO throughput or stock-renderer qualification.
`architecture/uncore/apu-native-image-clear-implementation.md`.

Native compute uses32-instruction turns and bounded live I/O:241 frozen checks
pass13.845s,81 hashes unchanged. Wire shaders remain refused; no simulator/PGO
speedup or qualification is inferred. RTL unmap transaction remains open.
`architecture/uncore/apu-native-compute-foundation.md`.

Native buffer provenance/resolution:254 frozen checks pass16.214s,83 hashes
unchanged. Record-word reconciliation is bounded; caller leases/wire shader
admission remain separate. No RTL/PGO throughput or qualification promotion.
`architecture/uncore/apu-native-buffer-descriptor-implementation.md`.

Native layout identity/lifetime:267 frozen checks pass13.820s,85 hashes unchanged.
Bounded snapshots isolate reused IDs and stream views; no hardware hash/record
change or RTL/PGO throughput/qualification claim.
`architecture/uncore/apu-native-layout-lifetime-implementation.md`.

Native pipeline operands:274 frozen checks18.256s,87 hashes unchanged.
No wire dispatch, hardware table or RTL/PGO qualification promotion.
`architecture/uncore/apu-native-pipeline-implementation.md`.

Internal compute replay:299 frozen checks16.776s,89 hashes unchanged. Explicit
compute=True bounds dispatches, descriptor reads and instructions; native-only,
no hardware table, PGO throughput or qualification promotion.
`architecture/uncore/apu-native-compute-replay-implementation.md`.

Diagnostic compute wire:310 frozen checks18.933s,90 hashes unchanged; real
bridge-client shared writes/fences pass. No RTL/PGO or stock software promotion.
`architecture/uncore/apu-native-compute-submit-implementation.md`.

Scalar specialization:325 frozen checks16.343s,92 hashes unchanged;32 map
entries/64 data bytes/4096 code words bound native compilation. Scanner constant
allocation is bounded before materialization. No RTL/PGO qualification claim.
`architecture/uncore/apu-native-specialization-implementation.md`.

Native compute barriers:338 frozen checks16.120s,93 hashes unchanged. At most
16 mixed rows use the existing I/O/operation budgets; no RTL/PGO promotion.
`architecture/uncore/apu-native-compute-barrier-implementation.md`.

Native idle scope:348 frozen checks15.110s,94 hashes unchanged. Queue/device
waits preserve bounded polling and internal FIFO; no RTL/PGO promotion.
`architecture/uncore/apu-native-idle-scope-implementation.md`.

Native indirect compute:364 frozen checks14.006s,95 hashes unchanged.
One12-byte snapshot per dispatch, bounded64-per-axis/256-total invocations;
no RTL/PGO throughput or qualification claim.
`architecture/uncore/apu-native-indirect-dispatch-implementation.md`.

Native fixed buffer arrays:374 frozen checks17.179s,96 hashes unchanged.
Bounded sorted rows and per-element guards retain executor budgets; no RTL/PGO
throughput or qualification promotion.
`architecture/uncore/apu-native-buffer-array-implementation.md`.

Native specialization operations:382 frozen checks17.971s,96 hashes unchanged.
Scalar dependency folding stays within module/ID/constant budgets; default
hardware scanner refusal and separate RTL/PGO gates remain.
`architecture/uncore/apu-native-specialization-op-implementation.md`.

Native image operands:398 frozen checks19.826s,98 hashes unchanged. Resolution
does not pin or execute; bounded owned subviews precede image shader admission.
No RTL/PGO throughput or qualification promotion.
`architecture/uncore/apu-native-image-operand-implementation.md`.

Native compute images:408 frozen checks18.899s,99 hashes unchanged. Shared
transfer/image I/O retains poll/instruction/binding bounds; no RTL/PGO promotion.
`architecture/uncore/apu-native-compute-image-implementation.md`.

Native shader-image barriers:417 frozen checks15.207s,100 hashes unchanged.
Operation/record bounds and backing leases remain; no RTL/PGO promotion.
`architecture/uncore/apu-native-shader-image-barrier-implementation.md`.

Native rendering identity:432 frozen checks14.597s,102 hashes unchanged.
Four-attachment bounds retain logical allocation extents, not rounded padding;
no draw, RTL/PGO throughput or qualification promotion.
`architecture/uncore/apu-native-rendering-identity-implementation.md`.

Native graphics identity:442 frozen checks37.769s,104 hashes unchanged.
Stage specialization remains module/ID bounded; no draw, RTL/PGO throughput
or qualification promotion.
`architecture/uncore/apu-native-graphics-identity-implementation.md`.

Native graphics fixed state:450 frozen checks21.578s,106 hashes unchanged.
Pinned stride/row bounds refuse truncation before allocation; no draw, RTL/PGO
throughput or qualification promotion.
`architecture/uncore/apu-native-graphics-fixed-state-implementation.md`.

Native graphics interfaces:462 frozen checks36.223s,108 hashes unchanged.
Declaration/link bounds reuse specialized scans; no draw, RTL/PGO throughput
or qualification promotion.
`architecture/uncore/apu-native-graphics-interface-implementation.md`.

Native vertex/index operands:474 frozen checks33.942s,110 hashes unchanged.
Full-width offsets/counts and logical spans refuse truncation; no draw, RTL/PGO
throughput or qualification promotion.
`architecture/uncore/apu-native-vertex-operand-implementation.md`.

Native dynamic viewport/scissor:483 frozen checks21.050s,112 hashes unchanged.
Bounded finite payloads and recording epochs add no draw/RTL/PGO throughput or
qualification claim.
`architecture/uncore/apu-native-graphics-dynamic-implementation.md`.

Native render-pass commands:499 frozen checks29.179s,114 hashes unchanged.
Scope/area/clear and epoch guards add no draw/RTL/PGO throughput or qualification
claim; full-wire validation preserves omitted contents.
`architecture/uncore/apu-native-render-pass-command-implementation.md`.

Native graphics resource requirements:516 frozen checks27.683s,116 hashes
unchanged. Exact decorations and bounded per-stage requirements do not promote
binding/execution, RTL/PGO throughput or qualification.
`architecture/uncore/apu-native-graphics-resource-implementation.md`.

Native graphics binding state:536 frozen checks31.259s,118 hashes unchanged.
Record-local bounded state/operand resolution adds no execution/RTL/PGO
throughput or qualification claim.
`architecture/uncore/apu-native-graphics-binding-implementation.md`.

Native graphics draw plans:553 frozen checks17.947s,120 hashes unchanged.
Nonexecuting per-draw composition adds no execution/RTL/PGO throughput or
qualification claim.
`architecture/uncore/apu-native-graphics-draw-implementation.md`.

Native render-pass clears:569 frozen checks22.433s, all hashes unchanged.
Bounded attachment-clear writes add no draw/shader/RTL/PGO throughput or
qualification claim.
`architecture/uncore/apu-native-render-pass-clear-implementation.md`.

## 14. Dynamic profile: scheduler spin dominates worker self-time (perf record, hyp8_mc, devcase-nopgo, zkn_kat)

`perf record -F 1999` attached to a live `Variane_testharness.nopgo` probe run
(389K samples / ~100 s, busy builder — use for *structure*, not absolute %):

| self-time | symbol | note |
|---|---|---|
| ~70% | `__Vthread__nba__0..3` | 4 MT workers; own-code = dep-spin + dispatch, NOT region bodies |
| 7.5% | `VlWorkerThread::workerLoop` | dequeWork spin(50K pause)+mutex+cv per task |
| ~4% | `___eval_nba__0` + triggers/act/eval | main-thread driver, small |
| <0.1% each | ~500 `___nba/sequent/comb__TOP__*` | region bodies — flat, no single hotspot |

Static structure of `__Vthread__nba__2` (5,248 insns / 25 KB): **34 inlined
`pause` spin loops, 82 `sched_yield`/`threadContext` calls, ~200 one-shot
calls to region functions**. The 70% is workers polling `VlMTaskDoneMask`
(16-word atomic done-bitmap, `verilated_threads.h:132-189`): `spinUntil`
acquire-loads dep words + `pause` per iter, `sched_yield` every 50K iters.

Implications (generic, idiomatic-SV level):

1. **Parallelism efficiency is the first-order lever, not codegen shape.**
   Worker self-time is dep-wait, so cycles/s ≈ f(dep-graph critical path).
   `V3Sched`/`V3Order` MTask edge reduction (or partition balance) moves the
   metric more than any emitter tweak. Cheap decisive experiment: verilate
   `--threads 1` vs `--threads 4` same RTL → parallel efficiency directly.
2. **`workerLoop` 7.5%** is spin-then-cv dispatch (`VL_LOCK_SPINS=50000`,
   `verilated.h:151`). Probably near-optimal for μs-scale evals; only worth
   touching if a quiet-box A/B shows wake-latency vs spin-burn trade-off.
3. **Debug/assert scaffolding tax (static)**: each ~17K-insn
   `___nba/stl_sequent__TOP__*` carries ~1,464 guarded call sites
   (`VL_STOP_MT` 366, `sc_time_stamp` 366, `VL_WRITEF` 366,
   `threadContext` ~366) ≈ **~30% of per-cycle function static size** —
   RTL-authored `$display`/`assert` under `--assert`+`-DVL_DEBUG`. Dynamic
   share = guard evals (predictable branches); build-config lever
   (`--assert` off / display plusarg gating), not a Verilator transform.
4. Region bodies are too flat (<0.1% each × ~500) for single-function
   optimization — improvements must be systemic (fewer dynamic insns
   everywhere), reinforcing the instruction-count-first strategy.

### 14.1 oracc build note
`devoracc-ab` verilated OK (`-fprio-oracc`, 4 priority encoders lowered,
`VL_CTZ_W`/`VL_ONEHOT0_W` in generated C++); C++ build running with
`OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2` (mk default is `-Os` — must pass
OPT_* explicitly or the A/B is confounded). A/B vs `devcase-ab .nopgo`
queued in `/tmp/oracc_ab.sh` on `hyp8_zkn_kat.elf` (tohost=0x80001000,
cap=500K) — 4 interleaved probe reps, `perf stat instructions:u,cycles:u,
branches:u,branch-misses:u`.

## 15. GCC 16.2.0 toolchain + first clean transform A/B (fw_payload, 150K cycles)

**GCC 16 installed**: `/opt/testharness/toolchains/gcc-16.2.0-znver4`
(profiledbootstrap, x86-64-v3, znver4). Select via
`HYP8_BUILD_TOOLCHAIN=`/`SOFT_LADDER_BUILD_TOOLCHAIN=` (harness) or
`DEV_PGO_TOOLCHAIN=` (dev_pgo_rebuild.sh, now toolchain-aware).

Single-TU measurement (149K-line `DepSet_h53a8106c__121.cpp`, -O2
x86-64-v3, cold):

| compiler | wall | .text |
|---|---|---|
| gcc 13.3.0 | 47.90 s | 537,845 B |
| gcc 16.2.0 | 41.93 s | 504,465 B (**−6.2%**) |
| gcc 16.2.0 -O3 | 41.87 s | identical to -O2 |

=> **~12.5% faster cold compile, ~6% smaller code** — matches the commit's
low-teens estimate; -O3 adds nothing on Verilator TUs. ccache hits => 0.

**GCC16 model build now running** (`/tmp/gcc16_build.sh`,
`devgcc16-ab/model`): recompiles the *same* devcase verilated sources with
`CC/CXX/LINK=/opt/testharness/toolchains/gcc-16.2.0-znver4/bin/{gcc,g++,g++}`,
flags inherited from the model `.mk` (`-march=x86-64-v3`, `-O2` fast /
`-O1` slow / `-O2` global, `-DVL_DEBUG`, `--assert` sources). Only the
compiler differs vs `devcase .nopgo` => clean compiler-only A/B. Runs
`nice -19 -j6` to fill spare CPU on the oversubscribed box.

Gotcha that killed the first attempt: a `cp -a` of the model dir does
**not** fabricate the `corev_apu`/`verif` symlinks the `.mk` needs for the
DPI/TB `.cc` sources (`SimDTM.cc`, `hyp8_tb.cpp`, …). Create them before
`make`:
`ln -sfn $RSRC/corev_apu corev_apu; ln -sfn $RSRC/verif verif`
where `RSRC=…/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source`.
Without them make fails `No rule to make target 'corev_apu/tb/dpi/SimDTM.cc'`.

**Clean transform A/B — `-fprio-oracc` is a REGRESSION on hyp8**:
`fw_payload.elf`, 150K-cycle cap, `G6LC_METRICS_SIDECAR` guest-retired
identical on both ([4835,0] — firmware mostly stalled; identical state
trajectory => host counters directly comparable):

| binary | instructions:u | cycles:u |
|---|---|---|
| devoracc (case+oracc) | 6,031,816,228,175 | 71,514,673,534,37 |
| devcase .nopgo (case only) | 5,251,914,385,854 | 62,356,637,572,09 |
| **delta** | **+14.8%** | **+14.7%** |

The or-accumulate lowering (onehot-guard + `VL_CTZ_W`/`VL_ONEHOT0_W` +
variable funnel-shift per set bit) costs MORE dynamic work than the
counted loop it replaced — likely because multi-bit masks iterate the
ctz/blsr/shuffle body where the original early-exit-ish scan was cheaper,
and/or GCC had already vectorized the simple loop. Transform stays
opt-in (`-fprio-oracc` only; NOT in `-fprio`) — do not enable by default
without a per-workload win. zkn_kat 4-rep confirmation in flight
(`/tmp/oracc-ab.log`).

### 15.1 oracc zkn_kat confirmation + mechanism hypothesis

`hyp8_zkn_kat.elf`, 500K-cycle cap (tohost unresolvable -> full cap; both
binaries show identical `[equiv]`/`[mc_verdict]` trajectories => same guest
work): rep1 oracc 15.209e12 insns / 72.184e12 cycles:u / 5402s wall vs
case 10.828e12 / 33.901e12 / 2226s — **+40% insns, +113% cycles, 2.4x
wall**. insn/cycle 0.21 vs 0.32 (worse IPC too — serial ctz dependency
chain vs predicted branches). Combined with fw_payload (+14.8%): the
transform is a robust regression on hyp8-scale code.

Mechanism hypothesis (unverified): `-fprio-oracc` fires in V3Prio BEFORE
V3Unroll, converting loops that `--unroll-count 256` would have lowered to
branch-predictable straight-line code into serial
`while(mask){i=ctz;mask&=mask-1;out|=W'(i)}` chains — data-dependent trip
count + serial dependency + blsr/shift per element. A salvage would gate
the transform to loops V3Unroll cannot touch (N > unroll-count) — needs a
fresh build+A/B to validate; left opt-in pending that evidence.

### 15.2 Experiment chain queued (`/tmp/exp_chain.sh`, sequential)

| phase | build | isolates | probe |
|---|---|---|---|
| 1 | `devbase-nopgo-ab` — fork 6fa24f6f (pre-transform), nopgo | case-table alone | fw_payload 150K |
| 2 | `devnodebug-ab` — dev fork, `--assert`+`-DVL_DEBUG` removed | scaffolding tax | fw_payload 150K |
| 3 | `devthr1-ab` — dev fork `--threads 1` | MTask parallel efficiency | fw_payload 150K |

Comparators already exist: `devcase-ab .nopgo` (case-table, t4) and
`devoracc-ab` (case+oracc, t4). Logs `/tmp/exp-chain.log`, probes
`/tmp/m-{base150,nd150,t1150}.json` + `/tmp/fw-*-perf.log`.

## 16. Phase-1 verdict: case-table is a REGRESSION — gated behind -fcase-table (2026-11-20)

`/tmp/exp_chain.sh` phase-1 built `devbase-nopgo-ab` = fork `6fa24f6f`
(pre-transform) with identical harness flags (`-O2/-O1/-O2`,
`x86-64-v3`, threads=4, `HYP8_BUILD_PGO=0`). Stats confirm the only
codegen delta vs `devcase-ab` is the transform itself: unroll counts
identical (895026 iters / 124070 loops), `Cases parallelized` 2499 vs
2475, `Cases to lookup tables` 0 vs 24.

fw_payload 150K-cycle probe, `G6LC_METRICS_SIDECAR` retired identical
([4835,0] both):

| binary | instructions:u | cycles:u |
|---|---|---|
| devbase .nopgo (no transforms) | 3,808,338,356,862 | 19,049,630,467,530 |
| devcase .nopgo (case-table) | 5,251,914,385,854 | 29,582,734,098,543 |
| **delta** | **+37.9%** | **+55.3%** |

**This overturns §14's "−23.4% retired insns" claim.** That earlier A/B
compared baseline-**PGO** vs dev-**noPGO** — it conflated PGO layout
with the transform and likely an older dev state; it was never a clean
case-table isolation. The controlled nopgo-vs-nopgo measurement shows
the 24 lookup tables ADD ~1.44e12 dynamic instructions per 150K cycles
(~9.6K per simulated cycle). Mechanism: the tabled cases sit in
per-cycle decode paths where the compare trees were already
branch-predicted; `table[idx]` costs index arithmetic + a load (plus
any bounds/assert scaffolding in this build) every evaluation, and the
AST shape change (ArraySel vs branch tree) perturbs V3Gate/V3Order
downstream. Static wins (−30% gotos, −0.6% C++ lines, shared .rodata)
did not translate to dynamic wins — reinforcing that retired-instruction
count, not code size, is the metric that matters.

**Action**: `tryCaseTable` is now gated behind opt-in `-fcase-table`
(default OFF), commit `ba2adafb0`, same precedent as `-fprio-oracc`.
`t_case_table.pl` passes `-fcase-table` explicitly. Do not enable by
default without a per-workload win; a future salvage would need
hotness-aware gating (unavailable at V3Case time) or a density/arm-count
heuristic validated on multiple workloads.

oracc zkn_kat reps 1-2 confirm the §15.1 regression (+37%/+40% insns);
reps 3-4 in flight. Phase-2 (no-assert/no-VL_DEBUG) and phase-3
(threads=1) builds proceed on the dev fork — note they still carry
case-table in generated code, so their absolute numbers include the
+38% offset; only their RELATIVE deltas vs `devcase .nopgo` are
meaningful.

### 16.1 Why the tables lost — generated-code mechanism

The 24 tabled cases are NOT simple `case(state)` decoders. They are
scoreboard-forwarding selects in `issue_read_operands` (e.g.
`gen_fwd_slot__BRA__*__KET__fwd_src`): the case index is a **one-hot
vector built from the match comparisons themselves** —

```cpp
__Vtableidx87 = ((tmp0 & (0x1000000U == (0x3f000000U & fwd_o[0x412U]))) << 3)
             | ((tmp1 & (0x10000U  == (0x3f0000U   & fwd_o[0x410U]))) << 2)
             | ... ;                       // all 4 compares ALWAYS evaluated
fwd_src = TABLE_h8c3fbd2e_0[__Vtableidx87]; // then one load
```

The compare-tree form GCC produced for the same logic fuses each
comparison with its branch and **early-exits on first match** — on
biased forwarding data (mostly no-match / one dominant pattern) it
skips the remaining compares, the index assembly, and the load
every evaluation. The table form pays full index construction + a
load unconditionally, in the hottest per-cycle per-operand path
(`TABLE_h8c3fbd2e` alone has 520 read sites across DepSets). That is
the +38% instruction mechanism — not the loads themselves but the
lost early-exit plus downstream AST-shape perturbation.

**Salvage heuristic (future, unvalidated)**: only table cases whose
index is a *cheap pre-existing value* (state/reg/enum signal — no
comparisons or wide logic in `exprp`), never `case({cmp,...})`
one-hot indices. Would keep tables for `case(state)` decoders while
excluding exactly the pattern that regressed. Not implemented — the
flag stays off pending multi-workload evidence either way.

### 16.2 Debug-tax experiment constraint: --assert is load-bearing for TB probes

Phase-2 first attempt (drop `--assert` AND `-DVL_DEBUG`) verilated fine
but `hyp8_tb.cpp` failed to compile: it probes internal model state via
`__PVT__` members (e.g. `i_ooo_dispatch__DOT__i_rob__DOT__head_q`), and
without `--assert` those variables are eliminated as dead — assertions
were their only fanout. **The no-assert configuration is not testable
with this TB** unless the probed signals get `/*verilator public*/`
metacomments or `--public-flat-rw` (both change codegen beyond the tax
being measured).

Revised phase-2 (`/tmp/phase2_retry.sh` v2): keep `--assert`, drop only
`-DVL_DEBUG` — isolates the VL_DEBUG runtime-header tax
(`VL_DEBUG_IF`-gated `VL_DBG_MSGF`/debug blocks compile out; generated
.cpp is identical to devcase). The `--assert` tax itself (VL_ASSERT
checks emitted at verilate time) remains unmeasured — it needs either a
TB that doesn't probe internals or public-signal annotations; logged as
open work. Note `-DVL_DEBUG` is a C++-side define only: it does NOT
change generated .cpp, only which runtime-header inline blocks compile.

## 17. Phase-3 verdict: scheduler spin = 56% of dynamic instructions (2026-11-20)

`devthr1-ab` = dev fork verilated `--threads 1` (serial eval, no MTask
workers) vs `devcase .nopgo` = same fork `--threads 4`. fw_payload 150K,
identical retired [4835,0]:

| | instructions:u | cycles:u | wall |
|---|---|---|---|
| threads=1 | 2.305e12 | 1.113e13 | 38.4 min |
| threads=4 | 5.252e12 | 2.958e13 | ~18 min |
| delta | **−56.1%** | **−62.4%** | ~2.4x slower |

threads=1 also shows IPC≈0.21 — the serial ordered-eval stream is
latency/dependency-bound, not throughput-bound; MT wins wall-clock by
spreading independent regions across cores, not by raising per-core IPC.

**~2.95e12 instructions (56%) in the 4-thread build are pure
synchronization spin**, not useful work — workers polling
`VlMTaskDoneMask`/`dequeWork` while waiting on the dependency critical
path. Yet threads=4 still wins wall-clock ~2.4x: the spin runs on
non-critical cores, so it inflates instruction count without extending
the critical path (PF≈2 + wait overlap). threads=1 has zero spin but all
work is serial.

**The lever**: `VlMTaskDoneMask::spinUntil` only ever `yieldThread()`s
after `VL_LOCK_SPINS` — it NEVER blocks. A worker waiting on a long
dependency burns pause+load+yield forever. Converting long waits to a
condition-variable sleep (signaled by `signal()`) removes the spin
instructions without touching the critical-path worker. Risks: cv
wake latency on critical-path deps, notify storms — mitigate with the
existing `m_waiting`-flag pattern and a spin-then-sleep threshold.

Generated structure confirmed: each `__Vthread__nba__N` inlines many
mtask segments as `[region calls] → signal(own) → wait(pred_mask) →
mtaskId → [next regions]`; waits with small masks return after one
atomic check (~10 insns, negligible) — the cost is ONLY actual spinning
on unready cross-worker deps.

## 18. Scheduler spin→cv-sleep implemented + smoke-validated (2026-11-20)

Commit `410921e33` (`include/verilated_threads.h`). `VlMTaskDoneMask`
was the ONLY hot wait — generated hyp8 uses `mtask_done__nba.wait` ×54 /
`.signal` ×63 and ZERO `VlMTaskVertex::waitUntilUpstreamDone` calls, so
the per-vertex counter path is dead code for this model (left unchanged;
candidate for the same treatment only if a future profile shows it hot).

Mechanism: `spinUntil` still polls `ready()` with `VL_CPU_RELAX()` for
short waits, but after `SLEEP_AFTER_YIELDS=4` yield cycles (~4×50K pause
iters ≈ 0.1–0.3 ms) it calls `blockUntilReady`, which registers in
`m_waiters` under `m_mutex` and sleeps on `m_cv`. `signal()` — which
already runs on every task completion — does one extra atomic load of
`m_waiters` and only takes `m_mutex`+`notify_all` when a sleeper exists
(rare). Lost-wakeup is impossible: the waiter holds `m_mutex` across
registration→`cv.wait` (which atomically releases it), so a `notify_all`
can't slip between the `ready()` check and the sleep; `cv.wait`'s
predicate re-checks `ready()` under the lock so spurious/partial signals
just re-sleep. even/odd polarity is preserved because `ready()` is the
single source of truth and `signal()` notifies on BOTH set (even) and
clear (odd) transitions.

Validation: standalone TU smoke (`/tmp/vt_run.cpp` on the remote,
compiled against `runtime/include`) exercised the exact path — waiter
spun past the yield threshold, slept, stayed asleep through a 30 ms
window (no early wake), woke on `signal(0,true)`, and the odd-cycle
clear-polarity wait returned correctly. `VT_SMOKE_OK`, exit 0. No
deadlock, no missed wakeup, no spurious proceed.

`devcv-ab` = devcase generated sources rebuilt with ONLY this header
(same `-O2/-O1/-O2`, `-DVL_DEBUG`, threads=4) — isolates the scheduler
delta vs `devcase .nopgo` on fw_payload 150K. Building (~68/2535 objs at
launch; box oversubscribed 22 load / 12 cores with devnodebug + user
stgfwd run). Expected: `instructions:u` drops from ~5.25e12 toward the
~2.3–3e12 range (spin removed) while `cycles:u`/wall improves IF cv wake
latency doesn't lengthen the critical path — the open empirical question.

## 19. cv-sleep v1 SEGFAULT -> ccache ODR contamination (2026-11-20)

`devcv-ab` v1 (devcase sources + new cv header, `make` under ccache)
built a binary that **SIGSEGV'd ~40 s into the fw150 probe**:
`___act_sequent__TOP__0+30` doing `testb $0x1,0x1001b2f8(%rbp)` where
`rbp = *(vlSelf+0x171a8)` was a garbage pointer. gdb bt: main thread,
`eval_step -> ___eval_settle -> ___eval_stl -> ___act_sequent__TOP__0`.

**Root cause — stale-object ODR, not a logic bug.** `VlMTaskDoneMask`
gained `m_mutex`/`m_cv`/`m_waiters` (~+100 B), changing
`sizeof`/member offsets in `___024root`. ccache served ~39%-hit rate
(153547/396914 cumulative; cache 99.84% full) — it returned devcase's
OLD-header `.o` for TUs whose preprocessed hash it judged unchanged, so
the model class layout disagreed across objects → the `vlSymsp`-class
pointer member was read at the wrong offset → wild deref. devcase
`.nopgo` ran the identical probe cleanly, isolating the delta to the
header+build, and the header code itself passed the standalone threaded
smoke (`VT_SMOKE_OK`).

**Lesson for incremental A/B builds**: any change to a verilated runtime
header that alters a *class layout* used inside the generated model
(`VlMTaskDoneMask`, `VlTriggerVec`, sched structs) MUST be built with
`CCACHE_DISABLE=1` (or a cleared cache) — ccache's include-hash can
otherwise serve objects compiled against the old layout and produce an
ODR-corrupt binary that crashes far from the change. `devcv` v2 rebuild
launched with `CCACHE_DISABLE=1` (~2543 real compiles). This also bit
`devnodebug` mid-build (127 post-push objects had the new mask mixed
with 2416 old) — fixed by restoring the pre-cv header and surgically
rebuilding only the contaminated `.o` (kept objects were genuinely
old-header, so the set is now uniformly old-header = valid devcase
comparator).

**Probe queue** (all fw_payload +150K, `perf stat` + guest-retired
sidecar, tohost=0 → full cap): devnodebug (no `-DVL_DEBUG`, isolates
the §14 ~30% scaffolding estimate), devthr1 (`--threads 1` serial,
parallel-efficiency baseline vs devcase threads=4). Results pending.

### 19.1 Fallback design if per-mask cv proves buggy

If `devcv` v2 still faults, the robust alternative keeps
`VlMTaskDoneMask` **POD** (`m_word[16]` only — zero layout delta, so no
ODR/ccache hazard ever) and moves sleep state to a function-local-static
global `std::mutex`+`std::condition_variable`+sleepers count. `signal()`
notifies the global cv; `spinUntil` sleeps on it after the yield budget
and re-checks `ready()`. Cross-mask wakeups are harmless (predicate
re-check → re-sleep); hyp8 has ~1 mask/tag so herd cost ≈ nil. Trade:
loses per-mask cv precision, gains layout stability + trivially-
copyable mask (safe under incremental/ccache builds and any future
model memcpy). Decide on v2 evidence.

## 20. __Vsampled__ shadow copies: measured NEGLIGIBLE (2026-11-20)

Static census of `devcase-ab/model`: **49,035 `__Vsampled__` line-refs**
across .cpp, **3,659 shadow-member declarations** in the core header,
concentrated in `___eval`'s "Init" block — per-signal
`vlSymsp->…__Vsampled__TOP__…X = vlSymsp->…X` snapshots taken every
settle so always blocks read pre-edge values (NBA semantics). Top
signals: `ndmreset_n` (8,354 refs), per-core `spec_older_q`/`spec_valid_q`/
`speculative_queue_q`/`cand_tid_q` replicated ×4 harts.

**But the dynamic cost is ~0.1% — do NOT pursue batching.** Per-sim-cycle
host work is ~5.25e12 insns / 150K cycles ≈ **35M insns/sim-cycle**; even
~3,600 sampled copies × ~6 insns (CSE'd base + load + store) ≈ 22K insns
≈ 0.06%. The copies are scalar/CData/SData/VlWide through deep member
chains GCC already collapses — cheap relative to the settle+NBA cone
evaluation and the 56% scheduler spin. The earlier "786 signals × 2
evals" framing overstated it by ~3 orders of magnitude. Logged as a
closed negative result; effort is better spent on the MTask dependency
graph (V3Partition/V3Sched edge reduction) and the debug-scaffolding
tax, which are the measured first-order costs.

### 19.2 Both cv variants smoke-validated; per-mask kept pending v2

Two functionally-equivalent cv-sleep designs were built and passed the
same threaded smoke (`VT_SMOKE_OK`): (a) **per-mask cv** — committed
`410921e33`, mask owns `m_mutex`/`m_cv`/`m_waiters` (~+100 B layout);
(b) **POD/global-cv** — `verif/regress/remote/vt_pod_mask.inc`, mask
keeps upstream `m_word[16]`-only layout, sleep state in a
function-local-static `SleepSync` shared by all masks (cross-mask
wakeups are harmless via `ready()` predicate re-check; ~1 mask/tag in
practice). Per-mask is kept as the committed design because it is
already building for measurement and scales cleanly to many masks; the
layout delta is a non-issue for version-locked fresh builds — the ODR
crash was purely an incremental-ccache artifact (§19). POD remains the
documented fallback (`vt_pod_mask.inc`) if a real logic fault appears
or if layout-stability for incremental user builds is later preferred.
The wait/signal *logic* is identical in both, so v2's scale verdict
transfers to either placement.

## 21. Debug/assert tax — refined mechanism (2026-11-20)

Static census of `devcase-ab/model` generated code:
- **`-DVL_DEBUG` scope is tiny**: it only gates `VL_DEBUG_IF`/`VL_DEBUG_IFDEF`
  (→ `if (Verilated::debug()) stmt`, ~3-4 insns/site) and
  `VerilatedAssertOneThread::check()` — the latter is used ONLY in
  `verilated_save.h` (save/restore), **zero references in generated hyp8
  code**. ~16K VL_DEBUG sites exist but mostly sit in cold dump/debug
  functions; the ones in hot `__Vthread__nba__N`/sequent paths are a
  handful of cheap guard checks. **Predicted dynamic delta <0.1%** — the
  earlier "~30% scaffolding" was *static .text size*, not dynamic cost.
  devnodebug-vs-devcase should confirm ≈ no difference.

- **The REAL candidate is `--assert`, not `-DVL_DEBUG`.** Each `--assert`
  emits a match-detection computation OUTSIDE the `assertOn()` guard:
  `if ((parallel_case/full_case multi-match vector) == expect) { if
  (assertOn()) {VL_WRITEF; VL_STOP_MT} }`. The outer condition —
  evaluating every arm-match and counting hits — runs **every execution
  regardless of `assertOn()`**. Census: **39,558 `VL_STOP_MT` sites**
  (~39K assertions). For wide `parallel_case`/`full_case` this is
  proportional extra decode work per asserted case per eval — plausibly
  the largest *removable* per-cycle tax, but it is present in BOTH
  devcase and devnodebug (phase2 kept `--assert` so `hyp8_tb.cpp` can
  probe `__PVT__` internals), so the current A/B does NOT isolate it.

**Follow-up needed to measure `--assert` tax**: a build with `--assert`
removed. Blocker: `hyp8_tb.cpp` accesses generated `__PVT__` internals;
whether those survive without `--assert` is unverified (earlier failure
was a missing *renamed* member, may be unrelated). Alternative: keep
signals alive via `/*verilator public*/`/`--public-flat-rw` annotations
or a TB that only touches public signals, then rebuild sans `--assert`.
Queued as next experiment once devnodebug confirms the `-DVL_DEBUG`≈0
baseline.

## 22. Debug/assert scaffolding — mechanism resolved; -DVL_DEBUG negligible, --assert required + costly (2026-11-20)

**`-DVL_DEBUG` is a NEGLIGIBLE runtime tax (~0.2%)** — single-TU compiles of
hot DepSet functions and the runtime objects (`verilated.cpp`,
`verilated_threads.cpp`) show ≤241 B `.text` delta each. `VL_DEBUG_IF` /
`VL_DEBUG_IFDEF` total only ~6.5K sites model-wide and are mostly
once-per-region-entry trace messages; without the define
`Verilated::debug()` is `constexpr 0` so the compiler deletes the bodies
even in debug builds' callers. The earlier devnodebug full-model delta
(4.11e12 vs devcase.nopgo 5.25e12 insns, −22%) is therefore a **build
confound, not a debug tax** — see devclean experiment below.

**`--assert` is load-bearing for this TB and cannot be flag-removed.**
A no-`--assert` verilate (`devnoassert-ab`, 2193 .cpp) fails
`hyp8_tb.cpp` compile: `Vg6lc_testharness_g6lc_core__pi37 has no member
'__PVT__...i_rob__DOT__head_q'` — the microarchitectural observability
signals the `[rob]` trace/probes read are kept alive *by* `--assert`.
`--public-flat-rw` is the fallback that preserves all members without
assert checks (queued experiment).

**The real `--assert` dynamic cost is the case-assertion match vector**
(`V3Assert.cpp:292-341`, `parallel_case`/`unique`/`full_case`): for each
such case, Verilator concats a fresh `AstEq(expr,cond)` per item into a
match vector and wraps it in `AstOneHot[0]` — evaluated **unconditionally
every cycle** the case evaluates, independent of `assertOn()`. The inner
`if(vlSymsp->_vm_contextp__->assertOn())` (default `m_assertOn=true`,
`verilated.h:348`) only gates the `VL_WRITEF`+`VL_STOP_MT` report, NOT the
match computation. ~54K `assertOn` + ~40K `VL_STOP_MT` sites exist
model-wide; every `parallel_case`/`unique case` in the RTL pays N compares
+ onehot-reduce per eval. `assert property` statements go through
`newIfAssertOn` (`if(assertOn()){...}`) and ARE properly gated — the case
assertions are the ungated hot path.

**Candidate optimization (tools/verilator, in scope)**: the match vector
duplicates comparisons the case decoder already performs. Either (a)
reuse/share the decoder's match bits, or (b) wrap the whole
`!onehot → fireAssert` in `if(assertOn())` so `+assertoff`/non-assert runs
skip the vector entirely. Quantify first via a `--public-flat-rw` +
no-`--assert` build (keeps TB probes, drops checks) before implementing.

### 22.1 CRITICAL: verilator output is NONDETERMINISTIC — same input, ~22% instruction swing

`devnodebug` and `devcase` were verilated by the **same**
`verilator-v5.008-g6lc-dev` binary with **byte-identical arguments**
(full `Arguments:` token diff = only `-DVL_DEBUG` + Mdir path), same RTL,
same `+define`/`+incdir` set, same split-loops `.vlt`. Yet they produced
different generated C++: devnodebug 2619 `.cpp` / +1.32M lines vs devcase
2535 — the delta is entirely `__Slow`/higher-index `DepSet` partitioning
(the 84 extra `.cpp` are uncompiled orphans; both built the same 2544
`.o`). The devnodebug binary then ran **4.11e12 vs devcase.nopgo 5.25e12
instructions (−22%)** on identical guest work.

**Implication**: `-DVL_DEBUG` cannot be the cause (≈0.2%/TU), so the swing
comes from nondeterministic partitioning/codegen — most plausibly
hash-order-dependent `V3SplitVar`/`V3Partition`/`--output-split`
decisions. Consequences:

- **Every A/B must reuse identical generated sources** (recompile `.cpp`,
  never re-verilate) — otherwise you measure codegen lottery, not the flag.
- The `devclean` rebuild (devcase `.cpp` recompiled cleanly) anchors the
  true devcase number; `devnodebug`'s faster binary is a *different*
  (luckier) partition, not a debug win.
- A ±20% run-to-run dynamic-instruction variance is itself a performance
  bug worth chasing — stable partitioning should be a correctness-adjacent
  goal for reproducible perf.

### 22.2 Clean fw150 numbers (all retired [4835,0], +debug_disable, 150K cap)

| build | insns:u | cycles:u | IPC | note |
|---|---|---|---|---|
| devcase .nopgo (MT4) | 5.252e12 | 2.958e13 | ~0.18 | baseline |
| devnodebug (no VL_DEBUG) | 4.115e12 | 2.221e13 | 0.185 | **nondeterministic partition, not debug** (§22.1) |
| devthr1 (--threads 1) | 2.305e12 | 1.113e13 | 0.207 | serial — no MT spin at all |

**MT spin overhead ≈ 5.25e12 − 2.31e12 ≈ 2.95e12 insns (~56%)** — matches
the §17 profile. cv-sleep targets exactly this.

**IPC ≈ 0.18–0.21 across ALL builds** → the model is memory/port-bound,
not issue-bound. Reducing spin insns (cv-sleep) frees issue slots AND the
mask atomic-load bandwidth, but cycles:u may not fall proportionally if
the residual bottleneck is data-memory traffic. Verdict hinges on
devcv's cycles:u, not just insns.

### 22.3 Nondeterminism source + A/B validity implications

`emitCFuncImp` (`V3EmitCImp.cpp:490-534`) groups `AstCFunc`s into
`DepSet_<hash>` files keyed by a `std::map<std::set<string>,…>` of required
headers — that grouping is order-stable. The variance enters upstream in
`V3Sched`/`V3Order`/`V3SchedPartition`, which use `unordered_map`/`unordered_set`
containers (`V3SchedPartition.cpp:130` `m_senVertices`, `V3Order.cpp`,
`V3Sched*.cpp`). Function boundaries and the `slow()` split
(`V3Order.cpp:1246`, `V3Sched.cpp:65/246`) therefore vary run-to-run →
different `__Slow`/DepSet populations → different inlining → the observed
±20% dynamic-insn swing.

**Transform A/B caveat**: case-table (+38%) and oracc (+14.8%) were each
verilated with different flags, so their deltas mix the transform's real
effect with partition noise. Verdicts: **case-table regression is real**
(+38% >> noise, mechanism understood — early-exit compare-trees beat
unconditional table loads on biased forwarding data). **oracc +14.8% is
borderline** — within ~1σ of partition noise; its unroll-gate already
prevents the bad case, so opt-in-only stands either way. For any future
transform <~25% delta, reuse identical `.cpp` or repeat verilations.

### 22.4 parallel_case match-vector is UNCONDITIONAL + dense in hot decode

Generated structure (verified in `..._g6lc_core__pi37__DepSet_h53a8106c__10.cpp`):

```
<concat of N AstEq(expr,cond) shifted into a mask → AstOneHot0/OneHot → !>   // IF cond — ALWAYS evaluated
    if (VL_UNLIKELY(assertOn())) { VL_WRITEF(...); VL_STOP_MT(...); }        // report only — gated
```

The compare-chain + onehot-reduce is the `if` **condition**, evaluated every
call; `assertOn()` (default `true`) only skips the report. So `+assertoff`
saves the report but NOT the match-vector — the tax is paid whenever
`--assert` emitted the check, regardless of runtime flag.

**Density**: 371 generated files contain `parallel_case` sites; hot FAST
DepSet files of `g6lc_core__pi37` carry 9–127 each (e.g. `__10`=122,
`__102`=127). Many are small decode helpers (`is_rd_fpr`, `is_rs1_fpr` in
`g6lc_core_pkg`) emitted as separate `__Vfunc_*` calls — function boundary
blocks GCC CSE, so each call re-pays the compare-chain.

**Why it's not a quick win**: runtime `assertOn`-gating is useless (defaults
true → zero default savings). Real levers, in order of risk:
1. `--public-flat-rw` + no `--assert` build (`devpubflat-ab`, staged) →
   quantifies total assert tax as an upper bound before any codegen change.
2. Structural: teach the case decoder to expose its match bits so the
   parallel_case check reuses them instead of re-comparing (deep, risky).
3. Inline small decode helpers so GCC CSEs repeated compares (broad).

### 22.5 Nondeterminism mechanism refined — function-split boundaries

`V3Order.cpp:processMoveOneLogic` (1202-1254) packs logic into `AstCFunc`s,
splitting when the running statement count exceeds
`opt.outputSplitCFuncs()`. The per-vertex processing order feeding this
comes from the ordering/partition passes that iterate `unordered_*`
containers → the *boundaries* where `newStmtsr` crosses the threshold vary
run-to-run → different `__Slow`/DepSet populations → different GCC
inlining → the ±20% insn swing. `slow()` (V3Order.cpp:1246, V3Sched.cpp:65)
inherits `m_slow`/procedure suspendability, compounding the layout delta.

**Fix direction** (not yet implemented — needs a repro pair + care not to
perturb the topological order the algorithm depends on): make the vertex/
logic iteration that feeds `processMoveOneLogic` deterministic by sorting
on a stable key (fileline/name) at the iteration site, preserving the
dependency-driven order semantics. Highest-value follow-up: it makes every
perf A/B reproducible AND stabilizes codegen size.

### 22.6 CRITICAL near-miss: toolchain header was silently reverted → cv experiment void

Discovered while auditing the devcv build: the **installed**
`runtime/include/verilated_threads.h` (and its hardlink twin
`share/verilator/include/verilated_threads.h`, same inode) was the
**pre-cv 10260-byte version** — the earlier "restore pre-cv header" step
(done to decontaminate devnodebug) had reverted the toolchain header
*globally*. devcv v2 was therefore compiling ~2543 objects against the OLD
mask → a cv-less binary that would have falsely read as "cv-sleep no
help." Caught before the probe ran.

**Facts that matter for any runtime-header experiment:**
- Model `.mk` sets `VERILATOR_ROOT = .../toolchains/verilator-v5.008-g6lc-dev/runtime`
  (NOT `share/verilator`); `include $(VERILATOR_ROOT)/include/verilated.mk`.
- `runtime/include/*` and `share/verilator/include/*` are **hardlinks**
  (same inode) — editing one edits both; there is no separate copy.
- Effective `-I` is `$(VERILATOR_ROOT)/include` = `runtime/include`.
- `verilated.mk` honors a **command-line `VERILATOR_ROOT=` override**
  (make CLI vars beat file assignments, and the `include` directive +
  `-I`/`VPATH` all re-resolve through it).

**Isolation pattern used (keeps sibling A/Bs clean):** built
`/opt/testharness/cvroot` = symlink farm of `share/verilator` with
`include/verilated_threads.h` replaced by the real 11862-byte cv file.
`make VERILATOR_ROOT=/opt/testharness/cvroot` → every TU (model +
`verilated*.cpp` runtime, reached via `VPATH`+quoted-include) sees the cv
header → consistent new mask layout, while gcc16/pubflat/devclean keep the
toolchain's old header → uncontaminated A/Bs. Verified `-I.../cvroot/include`
in the compile lines + `cvroot/include/verilated*.cpp` as VPATH sources.

### 22.7 devclean baseline anchor CONFIRMS nondeterminism finding

devclean (devcase `.cpp` recompiled via ccache hits = bit-identical objects,
old header, `--assert`+`-DVL_DEBUG`, threads=4, fw150, retired [4835,0]):

| build | insns:u | cycles:u | note |
|---|---|---|---|
| devcase .nopgo | 5.252e12 | 2.958e13 | recorded baseline |
| **devclean** | **5.294e12** | 3.110e13 | +0.8% insns (noise), +5% cycles (load) |
| devnodebug | 4.115e12 | 2.221e13 | re-verilated, different partition |

`instructions:u` is the reliable counter (deterministic); devclean
5.294e12 ≈ devcase 5.252e12 confirms the baseline is **valid**, and proves
devnodebug's 4.11e12 came from a genuinely *different* (luckier)
nondeterministic partition — the §22.1 ±20% swing is real, not a
baseline artifact. `cycles:u` varies ±5% with box load/frequency.

## 23. RESULT: VlMTaskDoneMask cv-sleep is a REGRESSION on hyp8 → revert

Clean A/B (identical 2535 generated `.cpp` — devcv reused devcase sources,
only `verilated_threads.h` differed via cvroot; `--assert`+`-DVL_DEBUG`,
threads=4, fw150, retired `[4835,0]` identical → same guest work):

| build | insns:u | cycles:u | IPC |
|---|---|---|---|
| devcase .nopgo (spin) | 5.252e12 | 2.958e13 | ~0.18 |
| devclean (spin, replica) | 5.294e12 | 3.110e13 | 0.17 |
| **devcv (cv-sleep)** | **7.357e12 (+39%)** | **3.721e13 (+20-26%)** | 0.20 |

`instructions:u` is deterministic → **+39% is a real regression**, not
noise. cycles +20-26% (some load variance but consistent sign).

**Why spin→cv-sleep lost here** (mechanism, for the record): hyp8's
per-dependency waits are *short* — fine-grained MT partitioning means
upstream tasks finish in ~µs, so workers poll the 16-word mask briefly and
proceed. `SLEEP_AFTER_YIELDS=4` (~200K pause-iters ≈ tens of µs) is *longer*
than most waits → workers rarely sleep, so the spin path dominates anyway —
but now pays extra: `signal()` does an acquire `m_waiters` load on every one
of ~63 call sites/eval, and when waits DO cross the threshold,
`blockUntilReady`+`notify_all` wakes **all** waiters → each re-checks
`ready()` (≤16 acquire-loads) then mostly re-sleeps (mutex+futex churn).
Sleep/wake syscall+herd overhead exceeds the spin it replaced.

**Verdict**: revert `410921e33`. Pure spin-then-`yieldThread` is already the
right policy for this dependency-wait profile; the condition-variable adds
cost without benefit when waits are short and numerous. The 56%-of-insns
spin cost is *inherent to fine-grained MT dependency tracking*, not fixable
by sleeping — the lever is reducing dep-edge count / critical path
(V3Sched/V3Partition), not the wait primitive.

## 24. RESULT: GCC 16.2 is a runtime REGRESSION vs GCC 13.3 on hyp8 model

Clean compiler-only A/B: `devgcc16-ab/model` = `cp -a` of `devcase-ab/model`
(verified **identical** generated `.cpp`, 0 `.gcda` → no PGO either side,
same `-march=x86-64-v3 -O2/-O1/-O2` `OPT_FAST/OPT_SLOW/OPT_GLOBAL`, threads=4,
fw150, retired `[4835,0]`). Only variable = compiler:

| compiler | insns:u | cycles:u | IPC |
|---|---|---|---|
| gcc 13.3 (devcase .nopgo) | 5.252e12 | 2.958e13 | ~0.18 |
| **gcc 16.2.0-znver4** | **6.002e12 (+14.3%)** | **3.516e13 (+18.8%)** | 0.17 |

`instructions:u` deterministic → **+14% is real gcc16 codegen regression**,
not noise. gcc16's changed inlining/heuristics produce more instructions AND
worse cycles on this 2500-TU generated model. Single-TU compile was −12.5%
faster (build-time win per the toolchain commit) but **runtime is worse**.

**Verdict**: do NOT adopt gcc-16.2.0-znver4 for hyp8 model builds. Keep
gcc 13.3 (`/usr/bin/g++`). The profiledbootstrap/toolchain work remains
valid for *build-time* throughput, but the runtime A/B is decisively
negative — another data point that this memory-bound model (IPC~0.2)
punishes any codegen that adds instructions or hurts layout.

## 25. Strategic conclusion — wait-primitive space is exhausted; real lever is upstream

After four controlled A/B experiments on identical generated sources, **every
transform/runtime/compiler lever regressed** on this memory-bound model
(IPC≈0.2, MT spin ≈56% of insns):

| lever | delta insns | delta cycles | verdict |
|---|---|---|---|
| case→table (`-fcase-table`) | +38% | +55% | gated OFF |
| prio-oracc (`-fprio-oracc`) | +15% | +15% | gated to non-unrollable |
| mask cv-sleep | +39% | +20-26% | reverted |
| gcc 16.2 vs 13.3 | +14% | +19% | keep gcc13.3 |

**Why the wait primitive can't be tuned further**: the cv-sleep result
proved dependency waits are *short* (µs-scale). Any mechanism that trades
spin-polling for sleep/wake syscalls or reduced poll frequency pays
latency/syscall overhead that exceeds the saved coherence traffic — the
spin is already near-optimal *for this wait profile*. Backoff variants
share the same flaw (detection latency on short waits).

**The actual lever** is reducing the *number* of dependency edges /
lengthening task granularity in `V3Sched`/`V3Order`/`V3SchedPartition` —
fewer MTask waits → less spin by construction, no wait-primitive tax.
That is a scheduler-graph change (bigger blast radius, needs its own
controlled A/B), not a runtime-header tweak. `threads=1` already proved
the ceiling: removing sync entirely drops insns 5.25e12→2.31e12.

**Build-config lever still open**: `pubflat` (no `--assert`,
`--public-flat-rw`) quantifies the parallel_case assert tax — if large,
the safe win is a *release* model build without `--assert`, not assert
codegen surgery (the match-vector is the `if` condition; it cannot be
cheapened without changing semantics).

## 26. SIMD/AVX coverage audit + half-width tier (implemented, verified)

Audit of `include/verilated_types.h` word-vector kernels against the
`-march=x86-64-v3` (AVX2) hyp8 build. `VL_SIMD_WORDS` resolves to **8**
(256-bit ymm) under AVX2 — confirmed `ymm`/`xmm` VEX ops in model objects.

**The gap found**: every word-kernel chunked at `VL_SIMD_WORDS`=8, so any
operand of **4–7 words (128–224 bits) got ZERO SIMD** and ran the full
scalar tail. Static call-site histogram of the hot (non-`__Slow`) FAST
DepSets shows the dominant wide-op bucket is exactly 128–224 bits
(~6.8K sites: `SHIFTL_WWI`, `ZERO_W`, `ASSIGNSEL_W*`, `ASSIGN_W`).

**Fix — half-width SIMD tier** (`verilated_types.h`, +67/-4):
- `VL_SIMD_HALF_WORDS = VL_SIMD_WORDS/2` (=4 → 128-bit xmm under AVX2),
  with `VlSimdHalf` vector type + `_vl_simd_load_h/_store_h/_or_lanes_h`.
- Elementwise (`_vl_words_and/or/xor/not/andnot`), reductions
  (`_vl_words_orxor/orall/xorall` → powers `VL_EQ_W`, wide compares), and
  `_vl_words_funnel` (→ unaligned `SHIFTL/SHIFTR/SHIFTRS`, `_vl_insert_WW`
  → `ASSIGNSEL`) now emit a full-width pass, then a half-width pass, then
  the scalar tail — so every operand ≥ half-width uses a vector op.

**Correctness**: `verif/regress/remote/simd_half_test.cpp` brute-forces all
kernels vs scalar reference, word counts 1–40, 200 trials →
`SIMD_HALF_TEST_OK` (compiled `-march=x86-64-v3`, `VL_SIMD_WORDS=8`,
`VL_SIMD_HALF_WORDS=4`; objdump shows `vmovdqu/vpxor/vpor/vpand/vpsrldq`).

**Safety**: header-only `static inline` + macros — **no class/object layout
change → no ODR/ccache hazard** (unlike the reverted `VlMTaskDoneMask`
cv-sleep). Lane-wise ops + already-disjoint funnel preserve aliasing rules.

**Deliberately NOT SIMD'd** (verified carry/branch-bound or already optimal):
- `VL_ADD_W/SUB_W/NEGATE_W/MUL_W` — sequential carry/borrow, ~100 hot uses.
- `_vl_cmp_w` (LT/GT/LE/GE) — lexicographic early-exit.
- `VL_ONEHOT_W/ONEHOT0_W`, `VL_COUNTONES_W` — branchy / already `POPCNT`.
- `_vl_words_zero/copy` → `memset`/`memmove`; `VL_EQ_W`>64w → `memcmp`;
  all already AVX2 via libc.
- `_vl_insert_WW` aliased (non-disjoint) path — must stay scalar.

**Status**: implemented + unit-verified; full-model cycles/s A/B pending
(a header change forces full recompile of every TU — schedule with the
next controlled build, reuse identical generated `.cpp`).

### 26.1 Micro-benchmark confirms the half-tier win (6-word / 192-bit ops)

`simd_bench.cpp` isolates a hot loop of `_vl_words_{and,or,xor}` +
`_vl_words_funnel` over a 6-word buffer — the exact size the half-tier
closes. Same TU, only `verilated_types.h` differs, `-O2 -march=x86-64-v3`:

| header | instructions:u | cycles:u |
|---|---|---|
| original (scalar 6-word) | 3.860e9 | 1.099e9 |
| half-tier SIMD | 1.980e9 (**−48.7%**) | 0.816e9 (**−25.8%**) |

**Monotonicity argument (no regression by construction)**: the half-width
pass only replaces *scalar tail* iterations with vector ops. Operands
≥ VL_SIMD_WORDS are fully handled by the full pass (half-check skips);
operands < half-width were already scalar. The sole behavioral change is
the [half, full) word range plus the sub-full remainder of larger ops —
strictly fewer instructions or identical. Only cost is one extra bounds
compare per kernel call.

Full-model fw150 A/B (`devsimd-ab` vs `devclean-ab` control):

| arm | instructions:u | cycles:u | retired |
|---|---|---|---|
| devclean (orig header) | 5.294e12 | 31.10e12 | [4835,0] |
| **simd (half-tier)** | **2.605e12 (−50.8%)** | **6.395e12 (−79.4%)** | [4835,0] |

IPC 0.17→0.41. **A/B validity verified**: `diff -rq` shows 0 `.cpp`
files differ between the two arms (identical generated code; only
`verilated_types.h` differs), and `retired` sidecar is identical — a
clean single-variable measurement, not partitioning noise. The 4–7-word
ops (`SHIFTL_WWI`/`ASSIGNSEL` scoreboard-forwarding range) were
stall-dominated scalar loops; the half-tier vectorized them. **KEEP** —
largest single measured win of the effort, far exceeding every gated
transform. Note the magnitude is workload-dependent (fw150 is
wide-op-heavy); benefit scales with how hot the 128–224-bit bucket is.

## 27. Dependency-graph granularity audit — edges are already logic-level (2026-11-21)

§25 named "fewer dependency edges / longer task granularity" as the real
lever. Audited whether the edges are *over-conservative* (false sharing on
coarse signal granularity) before committing to a scheduler-graph change.

**Pass ordering** (`src/Verilator.cpp`): `V3SplitVar`(268) → `V3Slice`(374)
→ `V3Split::splitAlwaysAll`(397) → `V3Sched::schedule`(447) →
`V3Premit`(523) → `V3Expand`(528) → `V3Partition::finalize`(578).

Two consequences:

1. **Variable/always granularity is already refined before scheduling.**
   Packed signals are split by `V3SplitVar`/`V3Slice` and always blocks by
   `V3Split` *before* `V3Sched` builds the graph — so `OrderVarVertex`
   deps are on post-split varscopes, not whole packed vectors. The
   "518-word scoreboard = one dependency" false-sharing hypothesis does
   not hold; word-level refinement is largely already done.

2. **Wide-op expansion happens AFTER scheduling.** `V3Expand`(528) creates
   the `VL_ZERO_W`/`VL_SHIFTL_WWI`/`VL_ASSIGNSEL_W*` multi-word helpers
   *after* the dep graph exists. So the graph reasons about pre-expansion
   logic; the 149 MTask edges are genuine inter-task data hazards between
   split always-block regions (pipeline stages), not an artifact of wide
   ops.

**Conclusion**: the dep edges are logic-level and mostly *necessary* —
there is no cheap "refine signal granularity" win. The only practical
levers that reduce the ~2.9e12-insn sync tax without breaking correctness
are the **count** knobs:

- `--threads N` — fewer workers → fewer idle spinners (parallelism
  factor ≈2 on hyp8 ⇒ threads=4 likely oversubscribed). `devthr2` A/B
  staged (verilate→build→probe) to test threads=2 vs the threads=4
  `devclean` control.
- `--threads-max-mtasks N` — force `PartContraction` to merge MTasks
  below the auto cap (`50×threads`=200; hyp8 uses only 59, so the cap is
  not binding — an explicit lower value coarsens the graph → fewer edges
  → less spin, at the cost of parallelism).

Both change the *partitioning* (re-verilate required → subject to the
§22.1 nondeterminism confound, so results are directional, and the
threads=2 graph is expected ~identical to threads=4 since the maxMTasks
cap doesn't bind — the only real variable is worker count).

## 28. Next SIMD frontier — aliased/in-place wide ops (identified, not yet implemented)

After the half-tier (§26) the only remaining scalar wide-op loops are the
**overlap/alias** paths that `_vl_words_disjoint` rejects:

- `_vl_insert_WW` aliased branch (`verilated_funcs.h:1457-58`) — scalar
  `iteration(i)` loop over all words when src/dst overlap. Feeds the
  `VL_ASSIGNSEL_W*` inserts (~8.2K call sites total).
- `VL_SHIFTR_WWI`/`VL_SHIFTRS_WWI` non-disjoint branch
  (`verilated_funcs.h:1835-39`, `~1929`) — scalar per-word loop for
  in-place right shifts (`x <= x >> s` reusing the buffer).

**Why they stay scalar today**: `_vl_words_funnel`/`_vl_insert_WW` SIMD
requires disjoint src/dst; overlap would let stores corrupt later loads.

**Safety analysis (right-shift direction)**: `owp[i]` reads
`lwp[i+word_shift]` and `lwp[i+word_shift+1]` — destination trails source.
The funnel writes `dst[t..t+W-1]` while reading `src[t..t+W]` (one word of
lookahead). For a fully in-place right shift the lookahead `src[t+W]` is
strictly above every already-written `dst` index, so forward chunked SIMD
is safe — each chunk reads only words not yet overwritten. The blocker is
purely the conservative `_vl_words_disjoint` guard, not a real hazard.

**Candidate implementations** (pick by profiling which alias case is hot):
1. Ordered chunked funnel for shift-compatible overlap (right-shift only —
   dest-trails-source). Cheapest, no temp buffer.
2. Temp-buffer: `memmove` src region to a stack/heap scratch, then run the
   disjoint funnel/insert on the scratch. General (handles left-shift and
   arbitrary insert overlap) but adds a copy; bounded scratch size is the
   constraint (wide signals reach hundreds of words).

**Caution**: correctness-critical (in-place SIMD). Needs a brute-force
aliasing regression test (random overlap offsets, both shift directions,
boundary words) + identical-`.cpp` fw150 A/B before keeping. Do NOT rush —
a subtle overlap bug corrupts state silently. Static site counts show the
parents are hot but the *alias* sub-path frequency is unprofiled; confirm
with `perf record` on the §26 binary first if the win looks marginal.

## 29. §28 RESOLVED — aliased/in-place wide ops are DEAD CODE; word-vector SIMD domain exhausted (2026-11-21)

§28 hypothesised the `_vl_words_disjoint`-rejected overlap paths might be a
hot SIMD frontier. Generated-code inspection **disproves** this — they are
unreachable in emitted models, so no SIMD work is needed there.

**Evidence — Verilator temps every wide expression result.** Sampled
`VL_SHIFTR_WWI`/`VL_SHIFTL_WWI`/`VL_ASSIGNSEL_WW` call sites in the devsimd
model (`*.cpp`, 2535 TUs) show src and dst are always *distinct objects*:

- shifts: `VL_SHIFTR_WWI(256,256,7, __Vtemp_h8aaf…, __Vtemp_h2eec…, …)` —
  two different `__Vtemp_*` buffers.
- `VL_SHIFTL_WWI(128,128,32, __Vtemp_h0008…, __Vtemp_h6435…, 0x41)` — ditto.
- `VL_ASSIGNSEL_WW(2048,512, lsb, __PVT__…fill_buf_q, __Vdlyvval__…fill_buf_q__v0)`
  — dest is the `__PVT__` signal, src a `__Vdlyv*` delayed-value temp.

Every wide op writes a fresh `__Vtemp`/`__Vdlyv` result and reads a *different*
temp or signal, so `_vl_words_disjoint(iowp+lword, …, lwp, words)` is always
true and the funnel/memmove SIMD path already runs. `VL_SHIFTL_WWI` even does
`_vl_words_zero(owp)` *before* `_vl_insert_WW(owp,lwp)` — that is only correct
because `lwp` is a separate temp; a true in-place `x <= x << n` would zero the
source first. Verilator's temping makes the alias fallbacks defensive dead
code, exactly like the `middle < 1` scalar spill.

**Action taken**: drafted the §28 temp-buffer path in `_vl_insert_WW`
(`VL_INSERT_TMP_WORDS` scratch + snapshot-then-funnel for `!disjoint`),
verified it compiled, then **reverted** (`git checkout verilated_funcs.h`).
Rationale: the branch can never execute in generated code → zero benefit, and
it added a correctness surface (snapshot reads original source, which for a
hypothetical corrupting overlap would differ from live-read scalar) for no
upside. Dead speculative code does not belong in a hot header.

**Remaining scalar paths — all correctly scalar or cold:**

| path | why not SIMD |
|---|---|
| `_vl_insert_WW/WI/WQ` disjoint interior | already funnel/SIMD (§26) |
| `VL_SHIFTR*/SHIFTL/SEL_WWII` disjoint | already funnel/SIMD |
| `_vl_words_copy`/`_zero`/`_fill` | memmove/memset (libc-optimal) |
| reductions `orxor/orall/xorall` | already SIMD (§26) |
| `VL_ADD/SUB/MUL/NEGATE_W` | carry-bound across words — not lane-wise |
| `_vl_cmp_w` lexicographic | early-exit word order; not a reduction |
| `ONEHOT/COUNTONES` | branchy bit-scan, not word-parallel |
| narrow `_I/_Q/_S/_CData` | single instructions, nothing to vectorize |
| overshift checks `rwp[i]` | loop over tiny shift-amount width (≤1-2 words) |
| `VL_STREAML_WWI` | bit-serial permutation, not word-parallel |
| `verilated.cpp`/`_dpi.cpp` word loops | init/reset/randomize/DPI — cold |
| `VlUnpacked` element access | random-index (`arr[computed]`) — scalar by nature; whole-array ops → memset/memcpy |

**Conclusion**: the runtime-header word-vector SIMD frontier is **exhausted**.
The §26 half-tier captured the only reachable scalar bulk (the 4–7-word
128–224-bit range); everything wider was already full-width SIMD and everything
narrower is correctly scalar, dead, or cold. Further SIMD gains would require
*codegen*-level changes (e.g. batching unpacked-array element loops or
re-widening over-split signals) — a different, larger scope than runtime
headers, and §27 already showed split/scheduler granularity is logic-driven.
No further opportunistic runtime SIMD work is warranted without new profiling
evidence of a reachable scalar word-loop.

## 30. Thread-count oversubscription — threads=2 is the hyp8 optimum (BREAKTHROUGH)

After the SIMD half-tier, flat `perf record` on the simd150 binary
(`/opt/testharness/runs/devsimd-ab/model`, `+max-cycles=40000`) shows the
remaining hot execution paths are **not** word-vector work:

| self-% | function | role |
|---|---|---|
| ~45.6% | `__Vthread__nba__0..3` | worker-thread orchestration: dep-poll + dispatch + call glue (~2400 calls each) |
| 11.0% | `VlWorkerThread::workerLoop` | worker spin loop (`dequeWork<SpinWait:true>`) |
| ~3% | `htif_*` | testbench I/O (libfesvr, not model) |
| 2.6% | `__eval_nba__0` | the SIMD wide-compute home (71% vector insns) |
| tail | `___nba_comb__…i_g6lc__NNNN` ×hundreds @~0.1% | narrow scalar comb logic — not vectorizable |

`nba__0/1/2` contain **zero** xmm/ymm in their own bodies — they are thin
orchestrators; the SIMD compute is concentrated in `eval_nba__0` + callees.
~56% of runtime is scheduler/worker orchestration — the same sync bottleneck
as §17, which SIMD cannot touch.

**Threads sweep (original headers, identical `retired=[4835,0]` guest work):**

| threads | insns:u | cycles:u | IPC |
|---|---|---|---|
| 1 | 2.305e12 | 11.13e12 | 0.21 |
| **2** | **2.425e12** | **4.945e12** | **0.49** |
| 4 (devclean) | 5.294e12 | 31.10e12 | 0.17 |
| 4+SIMD (simd150) | 2.605e12 | 6.395e12 | 0.41 |

threads=2 is the clear optimum: lowest cycles, highest IPC, instructions near
the serial floor. The hyp8 MTask graph has ~59 tasks / ~149 dep-edges with
parallelism factor ~2 — threads=4 leaves ~2 workers spin-waiting on
`VlMTaskDoneMask` the whole eval, burning ~2.9e12 insns of sync tax.
threads=1 is slowest (no parallelism); threads=2 captures the ~2x width.

**threads=2 ORIG (2.425e12/4.945e12) beats threads=4+SIMD (2.605e12/6.395e12)**
on both metrics — the sync tax exceeds the SIMD compute saving. The two are
orthogonal; a threads=2+SIMD build is the predicted best config.

**Generic lever found:** `V3Partition.cpp` `PartParallelismEst::parallelismFactor()`
(= totalGraphCost / longestCpCost) already computes the theoretical parallelism
at compile time and reports it via `statsReport("final")` — but it is only a
stat, never used to size the pool. `m_threads` defaults to 1 and `--threads N`
is a user guess. **`--threads auto`** deriving `ceil(parallelismFactor)` would
remove the oversubscription generically. cpLimit at line ~2780 already coarsens
the graph toward `threads`-way parallelism, so an auto value feeds the same path.

**Correction — the mechanism is partition granularity, not worker count.** The
testbench (`hyp8_tb.cpp`) never calls `VerilatedContext::threads()`, so the
context `m_threads` still defaults to `hardware_concurrency` (~4) and the pool
spawns ~3 workers + the eval thread in BOTH builds. What `--threads 2` actually
changed is the *partition*: `cpLimit = totalGraphCost*3/(threads*5)` coarsens
the MTask graph toward `threads`-way parallelism. Measured final graphs:

| --threads | MTasks | dep-edges | parallelism factor |
|---|---|---|---|
| 4 (devclean/devcase) | 59 | 149 | 2 |
| 2 (devthr2) | **29** | **53** | 1 |
| 1 (devthr1) | n/a — `mtasks()` false, serial, no partition | | |

threads=4 over-fragmented a ~2x-parallel graph into 59 tasks / 149 edges — each
task boundary adds a `VlMTaskDoneMask` dep-mask + spin/dispatch cost per eval.
threads=2's coarser 29-task / 53-edge graph halves the sync surface while still
parallelizing enough to beat serial on cycles (4.9e12 vs 11.1e12). **The lever is
`cpLimit` granularity / MTask coarsening when requested threads exceed real
parallelism** — not the worker count. A generic fix could (a) auto-pick
`--threads` from `parallelismFactor`, or (b) make `cpLimit` target
`min(threads, parallelism)`-way coarsening so an over-large `--threads` does not
over-fragment. Both feed the same `PartContraction` path; (b) is the lower-risk
single-pass change since `parallelismFactor` is only known *after* the initial
(un-coarsened) graph exists.

## 31. Codegen-level SIMD audit — generated `__Vi` loops are cold/dead (SIMD exhausted)

Following §29 (runtime helpers exhausted), audited the *generated* C++ for
scalar packed-data loops — the only remaining conceivable SIMD domain. Grepped
all `*DepSet*.cpp` in the simd150 model for `for (int __Vi0/__Vi1 = ...)`:

| bound | sites | what it is |
|---|---|---|
| `<256`, `<1024`, `<4096`, `<512` | ~85 | **reset-time SRAM clears** — `sram[i]=0`, `VL_ZERO_RESET_W(512,…)` over L2/presence banks. Run once at reset, cold. |
| `<33554432` | 2 | memory-size init, cold |
| `<2`,`<4`,`<6`,`<8`,`<9`,`<16`,`<32`,`<68` | ~340 | **empty scaffolding** (`for(i<4){for(j<68){}}` — dead bodies GCC removes) or tiny unpacked-array clears (`vmt[i]=0`, 4 elems) — reset/cold |

No hot per-cycle packed-data scalar loop exists in generated code. Every
wide op already routes through the `VL_*` helpers (SIMD'd by §26); narrow
comb functions are single ≤64-bit signal updates (inherently scalar, not
batchable); `VlUnpacked` is random-index. **SIMD is now provably exhausted
at both the runtime-helper and generated-code levels.** The only remaining
lever is non-vector: scheduler/partition granularity (§30) or narrow-op
scheduling — see §30 for the threads=2/partition breakthrough.

## 32. cpLimit-parallelism cap — TESTED AND REVERTED (no-op for hyp8)

§30 hypothesized capping `targetParFactor` at pre-coarsening
`parallelismFactor()` would reproduce the threads=2 coarse partition under
`--threads 4`. Implemented in `V3Partition.cpp` `go()` (commit `fd3f6b1be`,
reverted `f590db147`), compile-validated, then verilate-tested.

**Result: NO-OP.** Patched `--threads 4` verilate produced **58 MTasks / 158
edges** — statistically identical to unpatched threads=4 (**59/149**), nowhere
near threads=2's **29/53**. The cap did not trigger.

**Why it failed — the model was wrong.** `parallelismFactor() =
totalGraphCost/longestCpCost` on the *pre-coarsening* fine graph is HIGH
(>4): thousands of tiny MTaskMoveVertex tasks look parallel. But
`PartContraction` merges them into dependency chains, collapsing *achievable*
parallelism to ~2 (final factor). So `ceil(preCoarseningPar) >= threads`
always → `targetParFactor` never reduced → `cpLimit` unchanged → same
partition. **Pre-coarsening cost/CP parallelism does not predict achievable
runtime parallelism** — coarsening itself destroys it.

**The real lever is cpLimit coarseness**, which threads=2 doubled
(`totalCost*3/(threads*5)`: 0.15→0.30). Achievable parallelism is only known
*after* coarsening → capturing it generically needs a **two-pass/iterative
partition** (coarsen → measure final parallelism → re-coarsen with adjusted
cpLimit if oversubscribed). `PartContraction` is destructive, so pass 2 needs
a rebuilt graph — a larger, separate change. Not attempted (context).

**Net for hyp8:** the threads=2 result stands as a *build-config*
recommendation (`--threads 2` for ~2x-parallelism designs), not yet a generic
compiler fix. SIMD remains exhausted (§29/§31); the only proven remaining
lever is partition granularity, which needs the iterative approach above.

## 33. Iterative coarsening — concrete design for the threads=2 fix (NOT yet implemented)

Goal: reproduce threads=2's coarse partition (29 tasks/53 edges) under an
oversubscribed `--threads 4`, generically, by driving `cpLimit` from
*achievable* parallelism instead of requested threads.

Feasibility confirmed: `PartContraction{mtasksp, scoreLimit, slowAsserts}`
(V3Partition.cpp ~1263) is re-runnable — a fresh instance re-scores all
`MTaskEdge`s and merges endpoint `LogicMTask`s whose combined critical-path
score is under `scoreLimit`. The coarsened graph persists with incrementally
maintained critical paths (`PartPropagateCp`), so a second contraction on the
same `mtasksp` merges further. `PartParallelismEst{mtasksp}.traverse()` then
measures the *achievable* (post-coarsening) parallelism.

Sketch (in `V3Partition::go()`, after first `PartContraction` ~line 2790):
```
// after first contraction + before removeTransitiveEdges/reassign-IDs:
for (int iter = 0; iter < K; ++iter) {
    PartParallelismEst est{mtasksp}; est.traverse();
    double par = est.parallelismFactor();
    if (par >= targetParFactor*0.8 || !mergedMore) break;   // parallelism now suffices
    // oversubscribed: re-contract with a higher scoreLimit to cut task count
    PartContraction{mtasksp, cpLimit*SCALE, slowAsserts}.go();
}
```
Open questions to resolve before implementing:
- `scoreLimit` semantics: it is a *critical-path-cost* budget, not a task
  count — doubling it does not linearly halve tasks. Need the right SCALE and
  a merge-progress check (`mtasksp` vertex count before/after) to avoid an
  infinite/coarsening-too-far loop.
- Stop condition: target `parallelism ≈ min(threads, achievable)` is NOT the
  objective — threads=2 won on *less sync overhead* (29 tasks), not more
  parallelism (factor dropped 2→1). The real objective is min total cost
  (compute + per-task-edge sync). May need a task-count-vs-parallelism
  heuristic (e.g. tasks ≈ achievablePar × ~15) rather than parallelism==threads.
- Re-contraction correctness: verify no redundant/transitive-edge or
  critical-path invariant breaks on the second pass (the `m_slowAsserts`
  self-checks in `go()` cover some of this).
- Blast radius: runs on every `--threads>1` compile; must not regress
  genuinely-high-parallelism designs (where fine tasks ARE wanted).
Validate via: verilate hyp8 `--threads 4` → expect ~29-40 tasks (vs 59) →
model build + fw150 `perf stat` → compare vs devclean/devthr2.

## 34. Iterative coarsening — TESTED, infeasible at V3Partition::go (stale costs)

Implemented the §33 design (re-run `PartContraction` with escalating `cpLimit`
driven by measured parallelism) in `V3Partition::go()` after the first
contraction + `removeTransitiveEdges`. Compiled clean, verilated hyp8
`--threads 4`. Result: **no-op** — final partition identical to baseline
(58 mtasks / 158 edges).

Root cause, measured via a `std::cout` diagnostic (`V3PART iter=`):

    iter=0 achievedPar=6.83686  effThreads=4  cpLimit 3412264 -> 3412264  (break)

`PartParallelismEst::parallelismFactor()` on the **`mtasksp` LogicMTask graph**
= **6.84**, but the same estimator on the packed **`execMtaskGraphp`** reports
**2** in `finalizeCosts` (`V3Partition.cpp:3069`). ~3.4x discrepancy.

Why: `V3Partition::go()` runs during **V3Order** and `vertexCost` uses
`AbstractMTask::cost()` = **provisional** per-task estimates. `V3LifePost` and
later optimizations change logic costs before `V3Partition::finalize()` →
`finalizeCosts()` recomputes costs (`fillinCosts`) and measures the real
parallelism on the packed graph. The LogicMTask-stage estimate is therefore
**stale and over-optimistic** — it cannot predict achievable parallelism, so
the oversubscription trigger never fires (effThreads rounds up to threads).

Conclusion: **auto-coarsening cannot be driven from `V3Partition::go`.** The
achievable-parallelism signal only exists after cost finalization + packing,
which is after the LogicMTask partition is already fixed. Viable future paths
(all larger than a local patch):
  - two-pass partition: partition → finalize costs → measure packed parallelism
    → re-run `V3Order` partition with corrected `cpLimit` (rebuilds LogicMTask
    graph; expensive, invasive);
  - defer LogicMTask contraction until after `fillinCosts`, i.e. move coarsening
    later in the pipeline where costs are final;
  - runtime/emit side: expose measured `parallelismFactor` on the model and let
    `VerilatedContext` size its pool (but this does NOT reduce MTask/edge count
    — the actual source of the threads=2 win — so it likely cannot reproduce it).

Reverted `src/V3Partition.cpp` (local + remote `verilator-g6lc-dev`); the
mechanism (`PartContraction` re-runnable, `PartParallelismEst` self-contained)
is proven sound — only the *trigger measurement* is unavailable at that stage.

Actionable result stands: for low-parallelism designs, **`--threads` ≈ measured
`final parallelism factor`** (from `--stats`) avoids over-fragmentation.
hyp8 optimum = `--threads 2` (29 mtasks/53 edges, −84% cycles vs threads=4).

## 35. Partition auto-tuning exhausted (3rd failure) + comb-call overhead audit

**Partition auto-coarsening — three independent triggers all fail.** Tried
driving `PartContraction` re-runs from measured parallelism at `V3Partition::go`:
  1. `PartParallelismEst::parallelismFactor` on mtasksp = **6.84** (cost-based,
     provisional V3Order costs) -> effThreads=4 -> no-op.
  2. Structural `vertexCount/longestChain` = **4.46** (58 verts / 13-deep chain,
     cost-independent) -> effThreads=4 -> no-op.
  3. (earlier) pre-coarsening cap -> no-op.
Achievable parallelism is **~2** (packed `execMtaskGraphp`, final costs) but is
unmeasurable at `go()`: both cost-based AND vertex-count metrics overestimate
because they ignore greedy-packing/contention dynamics AND cost staleness. The
real signal needs the packed graph + final costs -> only exists in
`finalizeCosts`, after LogicMTask partition is fixed. Auto-coarsening requires
two-pass/deferred partitioning (architectural). All three reverted.

**Comb-call overhead audit (`__Vthread__nba__0`, 157KB, devclean objdump):**
  - 2424 `call`s total: **1293 -> `___nba_comb__*`** tiny always_comb logic,
    **662 -> nba/sequent/eval** scheduling, **452 -> thread/misc** (incl.
    `_ZTHN9Verilated3t_sE@plt` TLS accessor x34, `sched_yield` x14,
    `endOfThreadMTaskGuts` x17), 17 -> memory.
  - The 1293 comb calls are REAL calls (not inlined): functions are defined
    across ~500 DepSet TUs so gcc cannot inline cross-TU without LTO.
  - Potential win: co-locate hot caller+callee in one TU or emit `inline`, but
    2521 functions -> code-explosion/i-cache risk; needs profiling-guided
    selection Verilator lacks at compile time. Large/risky, unvalidated.
  - TLS accessor (`_ZTHN9Verilated3t_sE`) x34/eval-region is a minor (~1-2%)
    candidate: cache thread-context pointer instead of repeated PLT calls.

## 36. Campaign summary — SIMD lane CLOSED; remaining work is architectural

End state of the SystemVerilog->executable hot-path optimization campaign:

BANKED (committed, measured):
  - SIMD half-tier wide-word helpers: -50.8% insns / -79.4% cycles / IPC 0.17->0.41
    (verilated_types.h, 71fe4877d + 013bef05d). The single biggest model win.
  - threads=2 measurement: 2.425e12 insns / 4.945e12 cycles / IPC 0.49 vs
    threads=4's 5.294e12 / 31.10e12 / 0.17 (-84% cycles). Actionable TODAY via
    `--threads 2`; generic auto-detection blocked (see below).

PROVEN EXHAUSTED / BLOCKED (do not re-investigate without new evidence):
  - SIMD: all reachable wide-word scalar paths already route through SIMD
    helpers; generated __Vi loops are cold SRAM-reset/dead scaffolding (§29,§31).
  - Partition auto-coarsening: achievable parallelism (~2 for hyp8) is only
    knowable AFTER cost finalization + packing, but LogicMTask partition runs at
    V3Order with provisional costs. Three triggers (cost-par=6.84, struct-par=
    4.46, pre-coarsen cap) all overestimate -> no-op. Needs two-pass/deferred
    partition (§32,§34,§35).
  - Comb-function inlining: 1293/2424 nba__0 calls target tiny functions defined
    as external-linkage members across ~775 DepSet .cpp TUs (deliberate
    compile-parallel split). No cross-TU inline without LTO/emission rework (§35).
  - Reverted-and-documented regressions: case-table, oracc, scheduler cv-sleep,
    gcc16.2, debug/assert tax — all measured, none retained.

REMAINING (architectural, multi-session): deferred-cost MTask partitioning;
emission-model change for comb-function co-location/LTO; runtime pool sizing
backed by emitted parallelismFactor (does NOT reduce mtask/edge count, so it
cannot reproduce the threads=2 win by itself).

## 37. Idiom-level SIMD audit — CLOSED (remaining scalars are narrow/serial)

Per-helper audit of every wide-word runtime idiom in generated hyp8 code:

  already SIMD (vector tier or libc memset/memcmp):
    VL_ZERO_W x4327, VL_ASSIGN_W x704, VL_EQ_W x24 / VL_NEQ_W x4
    (_vl_words_orxor+memcmp), elementwise and/or/xor/not/andnot
    (_vl_words_*), aligned VL_SHIFTL/SHIFTR_WWI (memcpy/memset).

  scalar-but-unfixable (inherently serial OR width too small for SIMD):
    VL_ADD_W x85 (3-6 words, carry chain) / VL_SUB_W x13 / VL_NEGATE_W x40 /
    VL_MUL_W x8  -- serial carry; _vl_cmp_w (LT/GT) is early-exit (optimal).
    VL_COUNTONES_W x11 (4-7 words) -- the one genuinely vectorizable op, but
    only 96-224 bits: 4-7 scalar popcnt ~= 8 cycles, SIMD gives ~nothing.

CONCLUSION: SIMD is closed at runtime-helper, codegen __Vi-loop, AND idiom
levels. All large-width ops vectorized; all remaining scalar ops run on narrow
data or small widths (<=7 words) where SIMD cannot help. No further runtime
SIMD work is justified absent a NEW design with genuinely wide hot vectors.

## 38. High-coverage DYNAMIC profile — SIMD exhausted (final proof)

perf record (60k cycles, all threads) on the SIMD-baseline model, coverage-
weighted by samples (not static site counts):

  WORKER_SYNC    33.34%  VlWorkerThread::workerLoop  -> --threads 2: 10.35%
  DATAPATH_eval  52.59%  ~12% __Vthread__nba__N orchestration bodies
                        + ~40% spread across 2518 nba_comb/sequent fns,
                          each <=0.35% (long tail)
  HOST_FESVR      8.67%  htif_hexwriter read/write_chunk (ELF load, warmup)
  LIBC_MEM        1.67%  malloc/memcpy
  ORCHESTRATION   0.75% / OTHER 0.40%

FINDINGS
1. workerLoop (33%) is thread idle-spin on m_ready_size + condvar wait. It is
   SYNCHRONIZATION, not datapath -> SIMD cannot help. Confirmed by threads=2
   profile dropping it to 10.4% (the oversubscription signature; the fix is
   --threads 2 or coarser MTasks, not vectors).
2. The datapath IS high-coverage but is ~40% spread across 2518 tiny comb
   functions (<=0.35% each) doing narrow scalar logic. No wide-vector loops,
   no dominant function -> nothing for SIMD to grab.
3. The ONLY SIMD in the profile is __memcmp_evex_movbe (0.21%) = the existing
   VL_EQ_W->_vl_words_orxor/memcmp path. SIMD already runs where vectors exist.

VERDICT: along high coverage there is NO remaining SIMD opportunity. Hot code
is (a) thread sync, (b) call dispatch, or (c) narrow scalar control logic too
small/fragmented to vectorize. Wide-vector work is already SIMD'd and is a
small share precisely because wide ops aren't the bottleneck. SIMD lane is
CLOSED at helper, codegen, idiom, AND dynamic-coverage levels.

## 39. AVX-512 (-march=native + VL_SIMD_PREFER_512): -18.3% insns + quarter-tier

The host has full AVX-512 (avx512f/dq/bw/vl/vbmi + avx512_vpopcntdq) but the
model was built -march=x86-64-v3 (AVX2 -> VL_SIMD_WORDS=8). Rebuilding the SAME
generated sources with OPT_FAST="-O2 -march=native -DVL_SIMD_PREFER_512"
activates the opt-in 16-word tier and native codegen.

perf stat, 100k cycles, devclean(avx2) vs devavx512(native+512), rep1
(instruction count is deterministic for identical work -> load-robust):
  A x86-64-v3      : 1.8786e12 insns
  B native+512     : 1.5358e12 insns   -> -18.3% insns
  Binary check: 39763 zmm insns + 21 vpopcntdq emitted.
(Cycles were contention-inflated on the shared box and are not reported.)

ATTRIBUTION: the bulk of the -18% is -march=native codegen over the whole
model (auto-vec, BMI2, more regs, EVEX), NOT the SIMD tier alone -- wide-word
helpers are only ~1% of the profile. Recommendation: build the model with
-march=native (or >=v4) on AVX-512 hosts; add -DVL_SIMD_PREFER_512 to widen the
helper tier too. It is opt-in because old AVX-512 parts downclock; this host
does not.

QUARTER TIER (commit 1556002c9, verilated_types.h): under AVX-512 the half tier
is 8 words so 4-7 word operands regressed to scalar. Added a 128-bit quarter
pass (VL_SIMD_WORDS>=16 only) to the elementwise + orxor/orall/xorall/funnel
kernels -> AVX-512 no longer loses narrow-op coverage vs AVX2. Compile-verified
on v4/v3/core2; incremental benefit unmeasured (small share of the ~1% domain)
but strict-superset, cannot regress.

§40 BMI2/VBMI2 EXECUTION-PATH SWEEP (commit 716fa6d4e)

Census of BMI-family instrs in devclean binary: shrx 897k, shlx 269k,
andn 130k, pext 13.7k, rorx 8.6k, blsr 4.6k -- scalar variable-shift/mask
lowering was already BMI2-clean. pdep=0 is NOT a gap: SV part-selects emit
contiguous masked field ops (andn+or), not packed-scatter, so PDEP does not
apply semantically. PEXT sites already covered; mulx/bzhi/tzcnt have no
emitted-idiom denominators.

REAL GAP FOUND + FIXED -- hardware funnel shift: _vl_words_funnel serves
every unaligned wide shift (VL_SHIFTL_WWI 4692 + SHIFTRS_WWI 96 + SHIFTR_WWI
62 sites) via _vl_insert_WW middle words and VL_SHIFTR_WWI tails. Host has
avx512_vbmi2 (vpshrdvd/vpshldvd) but gcc does NOT fuse (cur>>s)|(nxt<<shl)
into it -- 0 vpshrdv in the -march=native binary. Added _VL_HW_FUNNEL
(AVX512F+VL+VBMI2): _vl_simd_funnel_{f,h,q} pick _mm512/_mm256/_mm
shrdv_epi32 per tier width -> 1 instr per chunk instead of 3. Callers all
pass shl==32-shr so the single count operand is exact. Validated standalone
n=1..79 x shr=1..31 vs scalar ref, 0 fails on native/v4/v3/core2; vpshrdv
emitted only under native (v4 lacks vbmi2 -> generic path, still vectorized).
Incremental model gain small (funnel subset of ~1% wide-helper domain) but
strict improvement, zero-risk: falls back to the committed tiered path.

Also verified NOT profitable: _vl_shiftl_inplace_w has 0 generated sites;
VL_COUNTONES_W (11 sites, 4-7 words) stays scalar -- a vpopcntdq path would
cost more in setup than the 4-7 scalar popcnts it replaces.

§41 REAL-TU VALIDATION OF THE VBMI2 FUNNEL (transport + overlay notes)

The real generated TU Vg6lc_..._DepSet_h53a8106c__12.cpp compiled against
the new header via an overlay include dir (cp -a runtime/include, drop in
the new verilated_types.h): -march=native -DVL_SIMD_PREFER_512 emits
vpshrdv (2 sites/TU -- funnels are thin-spread by design), -march=x86-64-v4
compiles to the generic path (0 vpshrdv, vbmi2 not in v4 baseline). Both
compile clean; md5-verified header transfer.

GOTCHA recorded for future header A/Bs: verilated.h quote-includes
verilated_types.h, so an -I overlay holding ONLY verilated_types.h silently
loses to the toolchain copy in verilated.h's own directory. The overlay
must contain the whole include dir (or at least verilated.h too), else the
compile "succeeds" against the STOCK header and reports a false negative.

§42 DEAD-INIT ON FUNCTION-LOCAL WIDE TEMPS (scoped, not yet implemented)

FINDING: V3EmitCFunc.cpp:705-710 forces zeroit for EVERY isFuncLocal() var
("Randomization too slow"), so each function-local VlWide gets a full-width
VL_ZERO_W in the "// Init" prologue -- even when the var's first touch is an
unconditional covering write, making the memset fully dead.

CONFIRMED SAMPLE (Vg6lc...DepSet_h53a8106c__101.cpp): scoreboard
i_sb_lifecycle gen_mn[*] unnamedblk10 z -- VlWide<17>/518b memset at fn
entry; ALL 17 words then unconditionally written z[k]=a_sbe[k] (no guard in
the whole preceding region), masked RMWs inside if(is_rd_fpr) only touch
already-written words, then a_mem[k]=z[k] reads. Zero is 100% dead work:
17 wasted word-stores per call.

DENOMINATOR: 782/4327 VL_ZERO_W sites (18%) target unnamedblk func locals:
756 x 518b (17w) scoreboard temps across 29 fast TUs + 8 __Slow. Dynamic
cost ~= dead memsets x eval frequency of the enclosing comb fns.

WHY NOT YET A PATCH (honesty): sound elimination needs def-use coverage on
the AST -- prove all words written unconditionally BEFORE first read, where
conditional blocks contribute nothing. Writes arrive as per-word AstAssign
(Sel'd lhs), so the pass must accumulate a covered-word mask across
consecutive top-level assigns, stopping at any control flow/read. That is a
new analysis pass + emitVarDecl skip hook + rebuild + regression -- sized
beyond a safe single-session change; a wrong verdict silently corrupts
semantics (unlike perf-only regressions elsewhere).

IMPLEMENTATION SKETCH (next session): in V3EmitC or a small pre-emit pass,
per AstCFunc collect func-local wide vars w/o valuep; walk stmtsp in order,
top-level only; track covered word mask from AstAssignW / consecutive
word-Sel AstAssign; stop at If/TaskCall/VarRef-read; mask==words -> mark
varp->user1, emitVarDecl skips the zero. Fallback stays zeroit.

§43 DEAD-INIT ELIMINATION IMPLEMENTED (d9d57fd83, compile-verified)

scanCoveredInit in V3EmitCFunc.h marks func-local wide vars whose top-level
unconditional assigns cover all words before any read (Sel/WordSel/Concat
lhs coverage; NodeVarRef-based read scan catches all ref forms). Marked
vars skip emitVarReset at AstCReset. Conservative by construction: any
unprovable touch keeps the init -- worst case is a missed optimization,
never a semantic change. TU compiles clean in remote g6lc-dev obj_opt
(-O3+PGO, real build flags). E2E verilate + memset-count delta pending
(remote tree rebuild in progress; header transfer via chunked b64 -- ~8KB
argv-safe chunks with retry, proven method this session).
§44 DEAD-INIT MEASURED (same-generator controlled A/B, 2026-11-21)

Experiment: two verilator_bin builds differing ONLY in scanCoveredInit
(pass on vs pass off via CTRL-OFF toggle on the same tree/rev), each
verilating hyp8_mc into devdeadz-ab vs devctrlz-ab, then model builds.

Static isolation proof: full VL_* helper census diff between the two
models shows the ONLY change is VL_ZERO_W 4,325 -> 179 sites (-96%);
unnamedblk temps 781 -> 0. Every other helper count identical --
single-variable experiment achieved. .text -174,780 B (-0.085%).

Functional equivalence: 150k-cycle fw_payload runs produce IDENTICAL
results on both models -- sidecar {"cycles":150000,"retired":[4835,0]}
byte-equal, same mc_gap retirement signatures (309/0/0/0), same
verdict trace. No execution discrepancy.

Dynamic (interleaved 3-rep A/B, 50k cycles, instructions:u):
  rep1  A(off)=1.4317e12  B(on)=1.4049e12   -1.87%
  rep2  A=1.1400e12       B=1.1348e12       -0.46%
  rep3  A=1.3044e12       B=1.3079e12       +0.27%
  mean -0.74%; median -0.46%.
Same-binary rep-to-rep swing is +/-12-25% on this loaded box
(spin-wait noise from the ~95-worker pool + co-tenant jobs), so the
true delta is real but small -- on the order of <=1% retired insns on
this workload. The 4,146 dead memsets (mostly 8-17-word scoreboard
temps) are a small share of 1.1-1.4e12 insns/50k-cycle.

Verdict: KEEP. It is a provably-dead-store elimination, free of
downside, shrinks code and store traffic even where the retired-insn
win is marginal. Methodology note: same-generator A/B (pass toggled,
not different verilator builds) is REQUIRED -- toolchain-vs-devtree
comparisons showed +922 COUNTONES/+148 SHIFTL/-ATTR_COLD drift that
fully confounds attribution.
§45 WHY DEAD-INIT WAS MARGINAL + THE REAL DENOMINATOR MAP (2026-11-21)

Introspection: static site census measured OCCURRENCES, not dynamic
weight. 4,146 removed memsets ~= 5-20 insns each, once per eval pass,
vs ~2e7 insns/pass total -> <=1% measured. Lesson: rank candidates by
DYNAMIC instruction weight first (perf sampling), site count second.

Steady-state perf record (79k samples, devdeadz 200k-cycle run):
  ~42%   VlMTaskDoneMask::wait + VlWorkerThread::dequeWork  (spin)
   6.3%  __eval_nba__0 (dispatch + moves)
  ~45%   flat tail: thousands of comb/sequent fns, each <0.6%

taskset isolation (same 30k sim, same binary):
  4 CPUs (3 workers): 1.603e12 insns
 12 CPUs (11 wkrs):  0.973e12 insns   -> ~39% of retires are spin/idle.

Tail archetypes (objdump census of top hot fns):
  a) mask-select: and/or + neg/sbb/sar branchless ?: mux -- ALREADY
     optimal scalar codegen; no per-instruction ISA swap exists.
  b) branch+call: je ~155, call ~150 / window -- priority dispatch;
     fix is emission co-location/LTO, not ISA.
  c) bit-test sequential: bt+jb, inc, movzbl -- already minimal.

Conclusion: per-instruction AVX-512/BMI2 lane is EXHAUSTED on scalar
datapath. The two remaining real denominators are architectural:
  1) Spin ~40-60% of retires -- mtask barrier tails; needs scheduler/
     balance work (stealing, finer barrier, or reduced mtask count),
     plus a spin-friendly wait (pause+backoff already present?).
  2) gen_core[0..3] instance replication: 4 identical cores run the
     SAME comb expressions on different state. Cross-instance SIMD
     (SoA member layout + packed lanes over the genvar index) is the
     only large SIMD lane left -- a generic optimization for SV
     generate-loop replication, not a helper swap. Requires emitter-
     level layout flexibility: detect isomorphic instance arrays,
     emit lane-packed eval. Big effort, big ceiling.
§46 FUTEX BLOCK-WAIT ON MTASK BARRIER — TESTED, REJECTED (regression)

Implementation (reverted, 8dfb42597->350e57f24): adaptive
spin->yield->futex-block in VlMTaskDoneMask -- 32-bit epoch bumped per
signal(), waiters park on FUTEX_WAIT_PRIVATE after 16 yields, signal()
only wakes when m_waiters>0. Functionally correct standalone test
(blocked on partial pred, woke on completion, no lost wake).

Controlled A/B (same model, only runtime header differs), 50k cycles:
  rep1  OLD(spin+yield)=1.325e12   NEW(futex)=2.151e12   +62%
  rep2  OLD=1.128e12               NEW=1.698e12          +50%

Mechanism: intra-round DoneMask waits are MICROSECOND-scale dependency
edges (158 edges/round). Futex wake latency (~2-5us) lands directly on
the dependency critical path, stretching every round; the stretched
round makes all other waits accumulate MORE spin. The 42% wait share is
synchronization load-bearing, not waste heat -- pause-spinning is the
correct wait strategy at mtask-edge timescales. Sleeping pays a fixed
latency tax per edge that no amount of saved spin insns repays.

Lesson: retired-instruction reduction that adds latency to a sync
critical path is anti-productive. The spin overhead can only shrink via
fewer/coarser barrier edges (partition-level work), not wait mechanics.

## 47. Packed left shift: follow callers before choosing the SIMD path

Evidence identity: `analyze_objdump_hotpaths.py` DB `/tmp/variane.db` on
`ovh_calltorch`, from `devdeadz-ab/model/Variane_testharness`, SHA-256
`fc3b5a89cb0795dc8f8c4a086daa37c69e8c104d8b5a29072ea78552f3073705`.
These are **host call sites**, not guest PCs or execution counts. Reproduce the
caller split (change the target substring for other helpers):

```sql
SELECT count(*) AS sites, count(DISTINCT caller_addr) AS callers,
       sum(instr(f.name,'___stl_') > 0) AS settle_sites,
       sum(instr(f.name,'___nba_') > 0) AS nba_sites
FROM calls AS c JOIN functions AS f ON f.addr = c.caller_addr
WHERE f.tier = 'HOT' AND instr(c.target_name,'SHIFTL_WWI') > 0;
```

The query returns **4,793 / 95 / 1,612 / 1,809**. By contrast, of 1,768,392
mutable pointer-conversion sites matching `cvPjEv`, 1,724,917 are in settle
and none has an NBA-named immediate caller. Symbol matches are not a dynamic
denominator. A specific direct path is `__Vthread__nba__3` -> core 0
`___nba_sequent...__331` -> left-shift helper (128 sites in this caller).
The emitted C++ includes both constant multiplier-row shifts and variable
200/224-bit shifts in fast TUs; a variable-only benchmark can miss regressions.

The language contract is `AstShiftL::emitC` -> `VL_SHIFTL_WWI`. In a
non-word-aligned packed shift the old destination is not an input, unlike a
part-select assignment. For disjoint buffers, a sufficiently wide source,
and more than two surviving source words, write the first word, funnel the
adjacent source pairs, then mask the last word. The existing kernel dispatches
to VBMI2 when available, otherwise vector shifts/OR or scalar code. Keep the
constant-width clear: clearing just the variable-size prefix *reduced*
instruction counts but *increased* cycles in the 200-bit leaf. Keep the old
path for overlapping buffers and small tails: the 128-bit constant `<< 65`
control regressed by ~13% in instructions without the small-tail exception.
No design names, scheduler changes, ABI/layout changes or new ISA requirements.

Pinned `perf stat -e instructions:u,cycles:u` leaf A/B/B/A, `g++ -O3
-std=c++17 -march=native -DVL_SIMD_PREFER_512`, both sides using the local
`350e57f24` word-kernel header (the builder checkout's copy differs). Four
million calls to a noinline fixed-width wrapper, shift count `i % bits`,
consume output word `i % words` into a rolling checksum and XOR the checksum
into the corresponding input word. Counts include this identical caller.

| Bits / count | Instructions, old -> new (millions) | Cycles, old -> new (millions, two runs each) |
|---|---:|---:|
| 128 / variable | 395.8 -> 290.3 | 110.8-110.9 -> 103.8-104.0 |
| 200 / variable | 462.2 -> 330.5 | 139.0-145.0 -> 120.3-120.8 |
| 518 / variable | 576.8 -> 405.5 | 201.6-203.0 -> 151.0-151.6 |
| 2048 / variable | 662.4 -> 432.0 | 226.9-228.0 -> 153.7-154.4 |
| 128 / constant 65 | 93.8 -> 93.8 | 36.4 -> 36.8-37.9 |

Checksums matched in every pair. These figures describe the leaf, not boot
time. A 10x harness improvement needs a net saving of 90% of **whole-run
wall time**. Neither this DB nor this experiment establishes the fraction of
time spent in shifts. The overlap guard refused a fresh model profile on the
busy builder. Qualification still needs a same-generated-model/runtime-only
A/B with a fixed firmware, affinity, cycle budget, matching RVFI/sidecars
and a steady-state instruction profile. No change to verification defaults.

## 48. From sampled spin loops to producer and consumer tasks

Two historical `perf record -F 1999` captures on `calltorch` record
**user cycles**, not retired instructions. Both commands specify the same
MC `fw_payload.elf`, `+debug_disable +quiet_axi` and 60,000-cycle cap.
`perf buildid-list` matches `readelf -n` on the respective executables:
`hc.data` / `devclean-ab` = `f6c6a808a02e07c5477dc6e051f31663b8c873ad`;
`hc2.data` / `devthr2-ab` = `872a9b61650503105ba234494a312000531a0c8c`.
Do not join these IPs to the different `devdeadz-ab` ELF in the SQLite DB.

`perf report --stdio --no-children --time 50%-100% -i <capture>` gives
the following period-weighted self shares for the second half by elapsed
time (575K / 329K samples, zero reported lost). This avoids treating ELF
loading as model evaluation; it is not a matched guest-cycle window.

| Build | Worker loop | Generated NBA lane wrappers, combined |
|---|---:|---:|
| devclean, 4 lanes | 37.71% | 13.53% |
| devthr2, 2 lanes | 11.15% | 13.08% |

The difference is not an isolated thread-count A/B. The two categories also
mean different things. In `hc2`, full-capture `perf annotate --stdio
--percent-type local-period` puts 97.24% of workerLoop's own cycles at the
backedge of the queue poll. By contrast, three hot backedges **inside** the
generated lane wrappers are waiting for specific publications. Decode the
load/shift/low-bit/parity test on the retry path, then read the TLS `mtaskId`
store on the success path. This distinguishes even repeated waits on the
same bit. Cross-check against the generated `wait(mask); mtaskId(id);`:

| Lane | Retry branch -> poll target | Producer -> consumer | Full-capture share *within that wrapper*, at retry branch |
|---|---|---|---:|
| 1 (main) | `14a545 -> 12ad59` | 25 -> 23 | 42.71% |
| 1 (main) | `14a605 -> 130385` | 9 -> 22 | 42.14% |
| 0 (worker) | `127c85 -> e0476` | 2 -> 1 | 42.47% |

These ranges contain `pause`, a countdown and the acquire poll. Attribution
to the branch does not imply branch misprediction. The first two shares are
not percentages of total runtime. Nor does a late publication prove that
the producer's *body* is slow: the whole prefix on its lane and OS scheduling
contribute. Task numbers are evidence keys for one build, not compiler rules.

**Two independent experiments, ranked by objective:**

1. For wall time, inspect producer arrival on the critical path first.
   `fillinCosts` already accepts body-hash keyed MTask costs, and
   `PartPackMTasks` chooses earliest estimated start, breaking ties by
   critical-path priority. Use the existing per-task profiling boundaries
   (start is *after* dependency wait). Compare estimated body cost, actual
   begin/end and consumer arrival by workload phase. Try measured costs
   with the same input DAG before changing the packing heuristic. If gaps
   follow descheduling rather than measured work, repacking is the wrong fix.
2. For fewer atomic operations, reduce the graph **after lane assignment**.
   In addition to explicit remote predecessors, every task follows its lane
   predecessor. Drop remote bit `p` when the previous lane task, or another
   required predecessor, already equals or transitively follows `p`.
   Emit task signals only for bits still consumed; retain all thread-finish
   signals and the final join. Census below uses emitted NBA lane functions,
   validates each task ID against its signal, decodes the single-word masks,
   and compares every task's ancestor set before and after reduction.

| NBA schedule | Predecessor bits before -> after | Nonempty task waits | Task publications (excluding joins) |
|---|---:|---:|---:|
| devdeadz, 4 lanes | 113 -> 69 | 52 -> 43 | 58 -> 41 |
| devclean, 4 lanes | 103 -> 64 | 53 -> 44 | 59 -> 32 |
| devthr2, 2 lanes | 24 -> 12 | 20 -> 12 | 29 -> 12 |

Example: in devthr2, lane 1 waits for bit 25 before tasks 23, 11 and 20.
Only the first acquire is needed; it is precisely the one that actually
spins. All three profiled hot edges survive. The reduction therefore
predicts fewer release RMWs and fast-path loads, **not** the disappearance
of the sampled waits. A production pass must also handle multiword masks,
even/odd rounds and acquire/release ordering. Test pruning with a frozen
schedule separately from repacking. Gate both on equal workload/RVFI and
interleaved wall time, host cycles and retired instructions per simulated
cycle; do not add their projected gains. No full-model speedup measured here.

## 49. Lane-order pruning: short throughput A/B

Implemented a limited form of §48 in `V3Partition::createThreadFunctions`,
after packing. Number each task by its position on its producer lane. For
each consumer lane, wait only for the latest still-needed position from
each producer lane; emit a task publication only when some retained mask
uses that bit. A release of a later task covers earlier tasks on its lane;
an acquire on the consumer lane need not be repeated in that invocation.
This does not reorder tasks, move message flushing, change the even/odd
protocol or weaken the end-of-round join. It does not require computing a
whole-graph transitive closure. ISA, model ABI, RTL timing and RVFI probes
are unchanged.

**Method.** Change only `V3Partition.o` in a scratch compiler link. First
prune the old generated C++ offline and compare all task ancestor sets
(explicit waits plus lane order). Then compare the real emitter's generated
C++ files to this independently pruned output: byte-identical on both
workloads. Use identical runtime headers, compiler flags and testbench.
Pin the main and worker threads separately (Linux/WSL logical CPUs 0 and 2
here). Time 250,000 full model clock cycles after 4,096 warmup cycles with
a steady clock, excluding startup, teardown and the independent software
oracle. Every cycle's digest contributes to the checked checksum. Six
pairs per workload, alternating A/B and B/A. No concurrent builds in the
timing window. The leaf is deliberately scheduler-sensitive.

| Work per lane update | Task publications / waits, off -> on | Median simulated cycles/s, off -> on | Median paired speedup (range) | Checksum |
|---|---|---:|---:|---|
| 0 extra mixing rounds | 51 / 2 -> 2 / 2 | 282,240 -> 980,134 | 3.69x (2.42-5.59x) | `7308eb7e` |
| 24 extra mixing rounds | 22 / 11 -> 2 / 2 | 567,103 -> 1,230,795 | 2.20x (2.00-2.54x) | `71e94024` |

Compare A/B **within a row**: changing the payload also changes the
partition. In the first row the wait count is unchanged: the gain does
not require eliminating a spin loop. It is consistent with avoiding atomic
RMWs on a shared done word and simplifying the retained masks. These
tests measure throughput, not cache coherence events. The existing
`t_mtask_mask` test also finished with a three-word mask including a
multiword task wait and final join.

Reproduce with the baseline and candidate `verilator_bin`, identical
`VERILATOR_ROOT`, and fresh model directories; use separate output dirs
for each compiler and each `rounds` value (`0`, `24`):

```sh
leaf=$repo/verif/regress/remote
"$compiler" --cc --exe --threads 2 --top-module g6lc_mtask_bench \
  -GRounds="$rounds" -CFLAGS "-O3 -DBENCH_ROUNDS=$rounds" --Mdir "$out" \
  "$leaf/g6lc_mtask_bench.sv" "$leaf/g6lc_mtask_bench.cpp"
make -s -C "$out" -f Vg6lc_mtask_bench.mk -j2 OPT_FAST=-O3
taskset -c 0,2 timeout 12 "$out/Vg6lc_mtask_bench"
```

Applied offline to the *actual* Hyp8 schedules, this limited rule reaches
the §48 counts on both `devthr2-ab` and `devdeadz-ab`. That is structural
evidence only. Keep the emitter change for the measured leaf benefit;
next gate for a harness throughput claim is a frozen two-lane Hyp8 A/B
with matching simulated budget and RVFI. Do not infer a 2-4x boot speedup
from a model with 24 small lanes.

## 50. MC Hyp8: neutral pruning result, concentrated masked-row work

**Control identity matters.** `devthr2-ab` uses the
`hyp8-rfix131a-phantomprobe-aggregate-t2` source snapshot,
`Flist.hyp8_mc_sim`, `G6LC_HYP8_MC`, two *host* lanes, `-march=x86-64-v3`,
`-DVL_DEBUG`, `OPT_FAST=-O2`. Its NBA graph has 29 tasks and 53 edges.
Recompile only the two generated worker TUs (root `he3e5f5a1__2` and
`__3`) and relink private copies of the model archive. The first replay's
`g++` was GCC 16.2, not the archived GCC 13.3. Do **not** pool those timings.
With `/usr/bin/g++-13`, both control objects and the control executable
matched the originals byte for byte. Control SHA-256
`5eaf04f7a70e4fe9e1dd51912112386835bf51858cc0aab0261f003e84718c0b`;
pruned `494101386a36669503e07f4329f2ce0ff75c90e93df4a4717c502414434b4673`.
No change to payload logic, firmware, generated schedule or runtime headers
between these two builds. Scratch artifacts: `ovh_calltorch:/tmp/hyp8-lane-ab.U2p5fd/`.

**Measure a complete shared-line workload.** Build the existing
`mc_multi_writer_line.S` with `ITERS=8` rather than stopping a long run
before its oracle. Four guest cores write separate slots on one line,
then AMO-add to the same counter. ELF SHA-256
`3e6fc73f5a09696cd8a38d10ed76555fff55333a9ea00bc5f847a21c8b495882`.
Pin to CPUs 2,4 (different physical cores), use the same debug-disable,
quiet-AXI and cycle-stamped RVFI options. Time the whole process in BAAB
order. All four runs passed tohost at cycle **4,649**, with byte-identical
sidecars and eight identical per-hart trace files. RVFI retire counts
for harts 0/2/4/6 were 356/236/220/208; the sidecar `[356,0]` alone does
not describe all four cores.

| Original-compiler run | Seconds | User instructions (billions) |
|---|---:|---:|
| B, pruned | 23.466 | 101.986 |
| A, control | 23.566 | 101.932 |
| A, control | 23.617 | 101.926 |
| B, pruned | 23.565 | 102.014 |

Control/pruned: **197.07 / 197.70 simulated cycles/s** (+0.32%); user
instructions +0.07%. No material throughput win established. The removed
17 publications and eight waits (§49) are not a proxy for saved work on
the critical path. The short complete workload does not qualify Linux boot.

**Follow the expensive task, not its symbol suffix.** Separately sample
the matching GCC 13 control on the same passing ELF (`perf record -D 2000
-e instructions:u -c 4000003`). 21,881 samples; the profiled run's traces
matched the timed control. Join period-weighted *self* samples to generated
leaf callees named in each `mtaskId` body. Exclude symbols called by multiple
tasks from the unique attribution; this is static caller membership, not
a dynamic call stack. Unique callee sets cover 82.62% of the sampled period.
Task 19's account for **44.80%** vs 7.54% for task 9. Task 19 is last on
the main lane. A core-0-named function can receive four different `vlSelf`
pointers: classifying its samples as guest core 0 is wrong.

Cross-check on the longer `ITERS=1500` ELF's first 8,000 cycles (a bounded
prefix, not a verdict), using the GCC 16 worker replay: 39,599 native
instruction samples, 43.74% in task 19's unique callees. **267 distinct
bodies called on all four core instances** account for 42.63% of the whole
sampled period. An instrumented diagnostic of that same replay timestamped
both sides of each wait and the payload end every 251st NBA invocation.
All 94 sampled invocations contained all 29 tasks; its RVFI traces matched.
Task 19 is bimodal: 32 bodies exceeded 1 ms (median 2.10 ms among those);
the median of the last 47 invocations was only 0.41 us. Task 19's body
occupied 44.8% of summed sampled NBA spans, but only 22.2% was after the
other lane finished. Even an ideal equal-speed helper that starts *only*
when that lane is free could save half that tail (~1.125x on these NBA
spans), not halve whole-model wall time. Work reduction inside the body
can affect the overlapping interval too.

On the **original-compiler, complete** run, group those 267 function bodies
by their emitted assignment destinations. As shares of *all* sampled host
instructions: `t1_faval_s` 18.02%, `t1_aval_s` 15.88%, `t1_mk_s` 5.49%,
`t1_fmk_s` 4.09%, both mark arrays 0.18%. These are self samples for the
entire functions, not just their AND/OR instructions. Together they put
43.66% of samples in a much more specific category than "comb logic".
Perfectly eliminating just that category with all other instruction counts
unchanged would give an instruction-count ratio of about 1.77x. This is
not a wall-time forecast.

**A candidate with a language-level explanation.** Representative issue
stage bodies (`...nba_comb...__637`, `__569`) implement rename-recovery
publish rows: for each output bit, OR together that bit from each port
ANDed with its row enable. The emitted C++ repeatedly extracts individual
bits from packed words and rebuilds each destination word. Across adjacent
output bits the enables are the same; the equivalent operation is a
**packed mask-and-OR across ports**, not a priority encoder or an assumed
one-hot select. It preserves zero and simultaneous hits. This is upstream
of AVX-512/BMI2 instruction selection: first restore the contiguous data
operation so a host compiler can optimize it.

Isolated falsification leaf: `verif/regress/remote/g6lc_masked_row_bench.{sv,cpp}`.
Verilate twice with `--cc --exe --threads 1`, identical `-march=x86-64-v3`
and `OPT_FAST=-O2`, changing only `-GPackedRows=1'b0` / `1'b1` (quote each
shell argument). Four 200-bit output rows, eight ports; independent bit
oracle checks all 256 enable masks per row, then 500,000 evals with the
same stimulus. On WSL, pinned CPU 0, three runs each: median **386,735 vs
11,829,054 evals/s**; all checksums `6fceeffa`. Separate Callgrind runs
counted 15.85B vs 0.772B Ir for the whole leaf, including the oracle.
These are combinational evaluations, **not Hyp8 simulated cycles**.

Next compiler experiment: in DFG optimization before wide expansion,
recognize pure adjacent output bits with the same set of enable expressions
and contiguous source slices per operand. Factor only proven groups; retain
multi-hit OR semantics, bit ordering, tail masks, and scalar fallback.
Do not rewrite the timing-oriented RTL or key on rename hierarchy.
Before promotion, count matched groups in the sampled Hyp8 bodies, verify
identical committed traces, and repeat the 4,649-cycle control. Neither
the 30.6x leaf ratio nor a function's sample share is a harness speedup.

## 51. Frozen MC model: packed masked-row lowering

This experiment changes the *model executable*, not the RTL or the
Verilator defaults. To isolate the transformation from scheduling, apply
`g6lc_pack_generated_rows.py` after C++ emission. The matcher accepts only
a single wide-word assignment of supported unsigned reads, casts,
constant shifts, ANDs and ORs. It follows each demanded output bit to
its input-bit products, accounting for truncation and shifts. Products
sharing an enable bit, a source word and a source-to-destination offset
can be computed together with `(-enable) & shifted_data & output_mask`.
OR the groups. This preserves zero/multiple hits, without reordering
assignments or assuming a port is active. Unsupported expressions retain
their original C++; in particular the complemented-enable mark trees are
not optimized in this experiment. No host extension beyond the control's
`x86-64-v3` target is required.

**Two checks before timing.** Applied the actual transformer (not a
hand-written packed RTL variant) to the emitted §50 WSL diagnostic leaf:
25 word assignments changed, the independent exhaustive enable-mask
oracle passed, checksum `6fceeffa`. On the frozen MC model the profiled
selection contained 267 function bodies. **211 TUs / 1,688 assignments**
changed. Compile each TU separately with its recorded flags and GCC 13.3;
replace only its object in a private copy of the original archive and
relink. The model still has the original schedule, including its original
signals. Do not attribute these results to §49 pruning.

**Reproduction.** On `ovh_calltorch` use the remote proxy and a new scratch
directory. With `scripts` pointing at the three `g6lc_*pack*.py` files from
`verif/regress/remote` and `fw` the §50 `ITERS=8` ELF:

```sh
model=/opt/testharness/runs/devthr2-ab/model
python3 "$scripts/g6lc_mc_pack_replay.py" "$model" /tmp/devthr2-build.log "$scratch/model" -j2
python3 "$scripts/g6lc_mc_pack_ab.py" "$model/Variane_testharness" \
    "$scratch/model/Variane_testharness" "$fw" "$scratch/pairs"
```

The runner rejects unexpected control/firmware identities and checks actual
tohost success at cycle 4,649, all-core retirement, eight nonempty trace
files and exact trace/sidecar equality. The normal mode refuses an active
model; `--shared-host` explicitly measures the co-running case and records
neighbor model PIDs at both ends of each run. Preserve the per-run
`perf.csv`, `result.json` and logs. Artifacts for this experiment:
`ovh_calltorch:/tmp/hyp8-lane-ab.U2p5fd/packed/ab`. Candidate SHA-256:
`72ae9370aedb8c08f5fb1cdad6220f8435baaa1c067f153144410a7f82dc44f6`.
An independent rebuild using the delivered replay script produced a
byte-identical executable and a manifest of the same 1,688 assignments.

**Measured result (shared host).** Process affinity `2,4`; same overlapping
four-lane `hyp8-xbarprobe` model PID at the beginning and end of all six
runs. No comparison against the quiet-host §50 timings. Whole-process
wall time includes startup, tracing and exit; hardware counters are
process-wide user-mode counts across threads.

| Pair/order | A sim cycles/s | B sim cycles/s | B/A | User instructions, A / B (billions) | Host user cycles, A / B (billions) |
|---|---:|---:|---:|---:|---:|
| 1 AB | 97.26 | 130.48 | 1.342x | 106.859 / 72.877 | 358.290 / 298.157 |
| 2 BA | 105.68 | 122.40 | 1.158x | 107.677 / 73.151 | 361.552 / 339.441 |
| 3 AB | 110.31 | 120.62 | 1.093x | 106.589 / 72.491 | 330.277 / 346.784 |

**Keep the opt-in lowering for this model.** Median throughput rose from
105.68 to 122.40 simulated cycles/s (+15.8%); the slowest packed run was
faster than the fastest control. Median retired host instructions fell
31.8%. Host cycles did *not* fall in every pair, and aggregate IPC was
lower in B; neither hardware counter is a substitute for the wall-time
measurement. All six tests reached the actual pass verdict and had
identical traces, including byte comparison with the archived §50 oracle.
Same neighbor PID is not a guarantee of constant CPU or SMT-sibling
contention: the evidence is a throughput increase in this co-running
workload, not a quiet-host speedup. No RTL, timing, ISA, DTS, firmware
or scheduling changes; neither a Linux boot nor an enabled-by-default
Verilator DFG optimization is qualified here.

## 52. After packing: follow task 22's wait through task 9 to the checkpoint rows

**Identity and attribution.** Same §51 packed ELF (`72ae9370...`), §50
eight-iteration MC ELF, two host lanes, CPUs 2 and 4. A fresh, delayed
`perf record` produced 7,300 user-instruction and 39,928 user-cycle samples,
zero reported lost samples. Use each event's actual period and its own
denominator. The profile, the independent timestamp build, and the mask
histogram build all passed at cycle 4,649 and matched the archived sidecar
and eight traces. Shared host; these diagnostic runs are not timed A/Bs.

1. Resolve sampled ELF symbol + offset; use the TID observed in each
   `__Vthread__nba__N` function to identify the lane. Intersect the
   generated direct callers of the symbol with tasks on that lane.
   Attribute self samples only when one NBA task remains. This is
   caller-set inference, not an inclusive stack trace. A `gen_core[0]`
   callee name still does not identify its receiver. No static-site-count
   weighting and no join against the older four-lane disassembly DB.
2. The 29 task buckets account for **63.40% of instructions and 65.78%
   of cycles**; ambiguous/unresolved NBA caller sets for 4.73% / 2.34%.
   Lane dispatch/poll accounts for 16.71% / 20.43%, NBA orchestration
   3.01% / 4.07%, worker loop 1.42% / 2.88%, trigger eval 1.64% / 0.67%,
   libraries 0.71% / 0.35%, other symbols 5.99% / 5.86%.
   Sampled IPs at the `pause; sub/dec; jne` retry loops account for ~83%
   of the lane functions' own cycles. Do not also count those cycles as
   producer work or assume deleting the poll advances the producer.
3. In a separate packed-model run, timestamp both sides of each wait
   and each payload end every 113th NBA invocation. All 120 sampled
   invocations have all 29 tasks (353.13 ms of summed round spans). To
   model a shorter payload, replay **both** lane order and the actual
   emitted predecessor masks: begin at the later of lane arrival and
   last required publication. Retain measured launch offsets, inter-task
   gaps and post-ready delay. With no change the replay reproduces every
   measured span exactly. This freezes the schedule, system delays and
   other task durations; it does not predict a new partition or CPU load.

| Task | Role in this schedule | Instructions / cycles (% of profile) | Predicted reduction in sampled NBA span if *whole task body* halves |
|---|---|---:|---:|
| 9 | Worker producer for main task 22 | 9.44 / 9.94 | 11.29% |
| 27 | Late worker, predominantly LSQ in leading group | 2.52 / 1.84 | 2.95% |
| 25 | Worker producer for main task 23 | 2.18 / 2.27 | 2.86% |
| 26 | Worker producer for main task 15 | 2.47 / 2.98 | 2.59% |
| 15 | Main producer for worker task 29 | 3.63 / 4.47 | 2.53% |
| 19 | Terminal main task, many replicated mark computations | 17.56 / 8.84 | 0.25% |

The most useful discriminator: **55.85 ms of task 22's 55.87 ms waiting
overlapped task 9's own body** (41 late arrivals). In contrast, of 28.00
ms late on 25 -> 23, 20.21 ms overlapped task 25's body and 7.79 ms
preceded it. Rebalancing earlier work might help the latter, but simply
dispatching task 9 sooner is not the first hypothesis for the former.
Host descheduling inside a measured body is still possible. A task's
CPU sample share and its marginal wall-time value are different.

**Source mechanism.** Task 9 calls `...nba_sequent...__291` and siblings.
`__291` builds 128-bit columns from a 32,768-bit packed checkpoint map;
successive extracted bits in one emitted word use source word indices
`0x1ff`, `0x1f7`, `0x1ef`, ... at the same bit offset: a 32-byte stride,
not a contiguous slice. The RTL is `col[s] = ckpt_fmap_q[s][a][b]`,
then `g_fmap[a][b] = |(rec_oh_q & col)`; integer maps and allocation rows
use the same construction (`g6lc_rename_recover.sv`, `gen_gmap`,
`gen_galloc`, `gen_gfalloc`). For the actual receiver column `[28][7]`
the emitted sources include multiple scheduled readers/writers as well
as settle/reset references. A wait-edge ID alone does not identify those
data uses. A local rewrite of the reduction that leaves the column
producers executing cannot claim their savings.

Among the profiled tasks examined, sampled recovery functions principally
writing `col` account for 7.81% instructions / 7.74% cycles in task 9,
2.73% / 3.35% in 15, and 1.52% / 1.85% in 26. These are whole-symbol
weights, not an attribution of every instruction to a single expression.
The task-9 IPs themselves corroborate the shape: ~50% of instruction
samples at bitwise logic, ~25% at shifts. In task 19, bodies writing
`t1_mk_s` or `t1_fmk_s` account for 13.58% instructions but only 5.95%
cycles; the previously packed allocation bodies now account for just
2.10% / 0.62%.

**Which lowering to test.** Measure the actual four-word `rec_oh_q`
immediately before the `g_fmap` assignments in four active consumer
functions. Across 15,300 consumer evaluations, **1,400 masks empty,
13,900 single-bit, none multi-bit**. This is a workload observation,
not a compiler invariant. Fuse the pure transpose-plus-reduction while
the DFG still has both sides: in word-sized chunks of the mask, iterate
set bits and OR each selected **contiguous payload row** into the result.
Empty naturally yields zero, one selected row is a copy, and multi-hit
preserves OR semantics, including partial final words. Prove the original
data epoch, enable/trigger behavior, alias safety and lack of remaining
observable uses before removing an intermediate. If a column is traced,
shared at another epoch, or otherwise not dead, retain it or decline.
Do not alter the timing-oriented RTL or assume `rec_oh_q` by name.

A separate single-CPU, 4 KiB hot-table kernel used 128 rows of eight
32-bit words, GCC 13.3 `-O2`, two million calls, three reps per variant,
all outputs independently checked. Sparse fixture: one empty mask in
eleven, otherwise one selected bit; dense control: 64 selected bits.
At `x86-64-v3`, set-bit iteration retired **80 / 528 instructions per
call** (sparse / dense, process totals normalized by calls); a full masked
row scan took 1,473 / 1,474. Pre-counting bits to specialize on exactly
one took 88 / 586. Disassembly of the simple loop already has BMI1
`tzcnt`/`blsr` and AVX2 `vpor` on YMM rows. `x86-64-v4` still used YMM,
not ZMM, and saved about one instruction per call. This is not a
measurement of the current Verilated producer or of MC throughput.
`pext` alone cannot extract bits spread over distinct strided words.
Eliminate the transpose before considering a wider instruction for it.

**Priority and gate.** First test producer/consumer fusion on the frozen
two-lane model, ahead of complemented-enable packing in terminal task 19
or changing the wait primitive. As a sensitivity exercise only, if the
identified transpose-family fraction of each of tasks 9, 15, 26 is
uniform across rounds and proportional to its cycle-sample mix, speeding
that fraction up 2x / 4x reduces the replayed NBA spans by 13.0% / 18.4%.
These are **not whole-run speedups**, cannot be added to spin shares, and
do not account for new consumer work. Require matches in the sampled
producers, actual removal of column construction, identical RVFI and a
paired simulated-cycles/s improvement. Also exercise real recovery plus
zero-, multi-hit and observable-intermediate controls before promotion.

Reanalysis artifacts on `ovh_calltorch` under
`/tmp/hyp8-lane-ab.U2p5fd/postpack.yOnwfD/`: `samples.data`, `paths.py`
and `attrib.json` (both events), `source.json`/`family.txt` (source grouping),
`uses.txt` (example consumer chain), `ops.txt` (sampled instruction decode),
`probe/stamp-*.txt`, `critical.py`, `late.txt`, `lanes.txt` (all 29 tasks,
including predecessors and single-task sensitivity), `sweep.txt`,
`mask/*.hist`, and `kernels/{fold.cpp,run.sh,results,summary.txt}`.

## 53. Shorten the checkpoint producer without changing data epochs

The §52 row-selection proposal would move a read from a producer into a
consumer. An NBA task edge establishes an order, **not** that a read made
after that edge sees the same version of the source table. The column
also has multiple readers and settle/reset references. Rather than assume
away either issue, optimize the producer itself. This is a different
transformation from sparse gather fusion: it retains every output column,
even when the current repair mask is empty. No dependency is removed.

`g6lc_pack_columns.py` follows each of the 32 output bits of a generated
word assignment back through the unsigned casts, constant shifts and
logic. It requires exactly one source bit per output bit, one in-bounds
wide input field and a constant positive byte stride. Within uninterrupted
assignments from that field, group columns which read different bit planes
of the **same 32 bytes**. Do not cross unknown statements, control flow or
a write to the source. Keep partial groups with fewer than four distinct
planes unchanged. Store the original destination words in their original
order; do not require adjacent output addresses or a particular RTL name.

The tile helper loads the 32 proven source words in four AVX2 groups.
It shifts and packs their selected bytes, undoes the within-lane ordering
of x86 packs, then extracts each required column with a movemask. In the
originally sampled `__453` object this gives 16 static `vpgatherdd` and
124 `vpmovmskb` sites. These are code-generation checks, not dynamic event
counts. Without AVX2 it uses four 8x8 shift/mask transposes; no BMI2,
AVX-512, aligned input, or read past the final source word is required.
The standalone test exercises all 256 basis bits with an unaligned
29-byte stride, a source update between batches, and an alias rejection.
Both scalar and AVX2 builds passed. This changes host code only, not
silicon timing, RTL, DTS, firmware, trigger order or observability.

**Replay.** Use the original generated model directory, the §51 packed
directory (archive, changed TUs and ELF), and a fresh output directory.
`g6lc_mc_column_replay.py` relinks the input archive first and requires
an exact match to the packed control hash. Compile changed TUs with
their original GCC 13.3 flags; replace only their objects in a private
archive copy. The profile-specific input list selects the §52 recovery
column callees from tasks 9, 15 and 26. It is *not* a rule used by the
expression matcher. To reconstruct `inputs.txt` for this frozen ELF:

```sh
for i in 72 74 75 355 376; do
  echo "Vg6lc_testharness_g6lc_core__pi37__DepSet_h53a8106c__${i}.cpp"
done >inputs.txt
for i in {447..474} {988..999} {1056..1069} 1227 {1250..1264} {1468..1481} {1538..1551}; do
  echo "Vg6lc_testharness_g6lc_core__pi37__DepSet_h7486aa93__${i}.cpp"
done >>inputs.txt
python3 "$scripts/g6lc_mc_column_replay.py" "$original" "$packed" /tmp/devthr2-build.log \
  inputs.txt "$scratch/model" -j3
python3 "$scripts/g6lc_mc_pack_ab.py" "$packed/Variane_testharness" \
  "$scratch/model/Variane_testharness" "$fw" "$scratch/pairs"
```

On `ovh_calltorch` the test artifacts are under `/tmp/hyp8-lane-ab.U2p5fd/tile1`;
selector: 103 TUs, 101 with matches, **11,678 word projections** changed.
The measured baseline is the packed model (`72ae9370...`), **not** the
original model or the pruned-scheduler build. The timing runs used
`--shared-host`; per-run `result.json`, `perf.csv`, traces and sidecars
are under `ab/`.

| Order | Packed control cycles/s | Tiled cycles/s | Paired ratio | User instructions, control / tile (billions) | User host cycles, control / tile (billions) |
|---|---:|---:|---:|---:|---:|
| AB | 99.96 | 110.15 | 1.102x | 75.800 / 62.485 | 406.269 / 366.674 |
| BA | 102.55 | 112.78 | 1.100x | 75.211 / 63.805 | 396.807 / 335.420 |
| AB | 103.07 | 130.37 | 1.265x | 74.934 / 61.253 | 400.711 / 304.155 |

**Keep for this MC build:** median **+10.0% simulated cycles/s, -16.9%
retired host instructions**. Timed ELF `b8c6cdea3e6478e3815bf512f342c722633110e87add4431c35f81d2b29527be`.
All six timed runs reached the real tohost pass at cycle 4,649, with four
cores retiring, eight identical trace files and the same sidecar as the
archived oracle. Process affinity 2,4. No other model was identified by
the runner at the run boundaries, but the box was loaded; the paired
ratios are more informative than the best individual timing. Do not
compound this percentage with a different session's §51 median.

**Why the throughput changed.** Separately link the *same* two sampled
worker objects from §52 against each payload archive and run ABBA. Each
diagnostic matched the traces and sidecar. All have the same 120 sampled
NBA invocation IDs and all 29 tasks. Numbers below are sums in ms over
those 120 invocations, not totals for the whole run:

| Diagnostic | Task 9 body | Task 22 waiting | Task 15 body | Task 26 body | NBA span |
|---|---:|---:|---:|---:|---:|
| Control | 84.41 | 57.31 | 32.46 | 25.69 | 349.43 |
| Tile | 26.87 | 2.93 | 11.24 | 11.88 | 272.68 |
| Tile | 28.53 | 5.91 | 10.92 | 11.50 | 294.09 |
| Control | 83.11 | 55.02 | 34.41 | 26.99 | 374.16 |

The 9 -> 22 delay largely disappeared **without weakening the acquire
or changing lane order**. Task 19 still consumed 61-63 ms of sampled
tiled payload time. The largest remaining measured late edge was
**25 -> 23** (28.87 and 33.83 ms); that is not a new regression, but a
previously smaller delay now exposed. Replaying hypothetical halved task
bodies no longer identifies one dominant target: task 25 would shorten
sampled tiled spans by 3.11-4.97%, with tasks 27-29 also contenders.
Next discriminate task 25's body from work preceding it in its lane;
do not replace the wait or extrapolate to an OpenSBI/Linux boot.

**Delivered replay check.** The final matcher also refuses unbraced
conditional sites and scopes its C++ temporaries. The resulting executable
had a different SHA-256 (`0a717957fba55e06a85cc8b6c51bec32f213023ffeb6817e05f61af311b7a727`),
so we repeated acceptance rather than attributing prototype timings to it.
In `tile1/final-ab` the AB / BA / AB pairs gave control vs delivered
**104.40 / 133.16**, **83.65 / 118.37**, **88.02 / 117.97** simulated
cycles/s. Median 88.02 -> 118.37 (+34.5%); median retired instructions
77.085B -> 62.155B (-19.4%). All six passed the same cycle, four-core
and exact-trace gates. Do not pool the wall-time ratios from the two
sessions or attribute their difference to temporary scoping: host load
and control timings changed. The producer timestamps above are from the
first build; the final build's timing is uninstrumented.

## 54. Sentinel: separate expression, storage and execution evidence

`--dumpi-sentinel 1` makes two **independent**, read-only observations in
the C++ compiler. Neither enables a rewrite. The unit of analysis depends
on the question; a task is not the root of this index.

| Question | Owning pass / record | What the record does not establish |
|---|---|---|
| Which SV bits compose this value? | `V3DfgOptimizer::optimize`, after `astToDfg`: opcode, operand slots, result width, constant select LSB, file and line. Vertex IDs are local to one module and phase. | Execution count, physical host addresses, or a mapping to a later task. |
| Is the intermediate shared or observable? | The same DFG snapshot includes variable name, reference/keep flags, fanout through operand edges, packed driver offsets and unpacked driver indices. | A false keep flag is not proof that reads at different simulation epochs are interchangeable. This is not a sequential/NBA state-transition graph. |
| Which work must precede which other work? | `V3Partition::createThreadFunctions`, after lane allocation but before moving bodies: full graph predecessors (including same-lane), actual retained waits, lane order, cost and body profile key. | A graph edge is not a source-level def/use; estimated cost isn't elapsed time. |
| Which improvement could shorten an observed invocation? | Offline replay of per-lane arrivals, post-acquire starts and body ends. Split the latest dependency's lateness into body overlap and prefix delay. | CPU occupancy vs descheduling within a body; consequences of a changed cache footprint or new worker assignment. |

Use `g6lc_sentinel_index.py SNAPSHOT` on a `*_sentinel_dfg.json` even for
`--threads 1`. It walks concatenations in SV result-bit order, stops at
variables rather than traversing feedback or partial drivers, and reports
actual source-bit mappings and storage boundaries. Static classifications
include contiguous slices, monotonic extracts inside one 64-bit word,
contiguous byte planes, strided columns and reduction of an AND. These
are **probe candidates**, not instructions selected for emission.
Combinational logic not admitted to the DFG is outside this snapshot.
Do not add counts from pre- and post-inline snapshots or join DFG vertex
IDs to task IDs. Both snapshots can be large; dump on a bounded leaf first.

Use `g6lc_sentinel_index.py SCHEDULE.json CAPTURE_A CAPTURE_B` for timing.
Each capture contains `stamp-LANE.txt` with rows `round task arrival_ns
body_start_ns body_end_ns` from a common monotonic clock. Use captures from
the **same instrumented executable, same region, same workload**; archive
the compiler snapshot and corresponding ELF digest together. Historical
stamps do not authenticate their source ELF. Incomplete rounds, inverted
timestamps and compiler edges not covered by emitted synchronization
plus lane order are refused. Only a supplied full compiler DAG enables
reorder exploration. The search tries one adjacent swap on one lane at a
time, preserves semantic edges and existing wait edges, rejects cycles,
selects on the first capture, and reports the prediction on the others.
It holds launch/inter-task gaps at the same lane positions. This is a
bounded experiment, not a global optimum, scheduler policy or code patch.

**Test the mechanism before promoting it.** On the pinned EPYC host, three
two-million-call probes of a 4 KiB hot table, extracting the high bit of
each of 64 contiguous bytes, gave median **19.6 / 142.3 / 426.9 / 461.0
M rows/s** for portable / BMI2 PEXT / two AVX2 movemasks / AVX-512BW byte
mask (`g++-13 -O2`, CPU 2). All passed a per-input-bit oracle and had
checksum `94d15c65decf6bc6`. BMI2 processes one machine word at a time;
the AVX-512 result is only ~8% over AVX2 here. This is not the strided MC
checkpoint layout and not an MC benchmark. Do not select AVX-512 from
the label "bit gather" without a layout proof.

**MC reanalysis.** Applying the indexer to the two tiled §53 diagnostic
captures (240 matched rounds) attributes 62.70 ms late on 25 -> 23:
**45.37 ms inside the producer body and 17.33 ms before its start**.
The equivalent totals on the two pre-tile captures were 49.06 and
18.55 ms. Thus this delay already existed; it was exposed, not created,
when 9 -> 22 shrank. Hypothetically halving task 25 saves 4.00% of
sampled tiled NBA span versus 3.80% for task 27. The old `attrib.json`
has emitted waits, not full predecessors: **no MC reorder proposed**.

**C++ implementation sequence and gates:**

1. Capture the structural leaf using the least complex model exhibiting
   the SV idiom. Require dataflow evidence without threading. Compare
   model `.cpp` and `.h` bytes with the sentinel off/on. This is the
   observer regression, not a throughput test.
2. For a recognized expression, start at `V3DfgPeephole` *before*
   `V3Expand`, not at a scheduler barrier. Specify the demanded bit map,
   signedness, partial-word behavior and all other users. Preserve or
   decline on traced/public/multi-driver/epoch-sensitive intermediates.
   If a transform can be expressed using existing packed DFG operations,
   prefer that over introducing a target-specific IR vertex.
3. Isolate physical layout and ISA in the emitter/runtime. Require a
   portable bit oracle plus disabled-feature fallback. Benchmark the
   actual width, stride, tail and mask density against the best existing
   lowering, not merely a bit-serial reference. Promote only if it
   reduces dynamic work on the relevant path.
4. For scheduling, change `PartPackMTasks` only after a full-graph
   holdout replay motivates it. Recompute publications and joins from the
   **new** schedule; do not apply a predicted order to the old masks.
   Repacking and payload lowering need separate model identities and A/Bs.
5. For a connection across phases, preserve source provenance through
   lowering and verify it against generated call sites and exact-ELF
   sampled IPs. Cross-phase expression identity, trigger/state epochs
   and dynamic memory alias tracking are **not implemented** in v1.
   Acceptance remains an actual MC pass, matching RVFI and higher
   simulated cycles/s. No new end-to-end speedup claimed for the observer.

The remote scratch compiler replaced only `V3Partition.o` and
`V3DfgOptimizer.o`. `test_g6lc_sentinel_compiler.py` verifies packed
bit order and masked reduction, both without and with worker tasks;
all emitted C++ and headers were byte-identical with observation off/on.
Fixtures, isolated kernels and replay tests are in `verif/regress/remote/`;
remote evidence in `/tmp/hyp8-lane-ab.U2p5fd/sentinel-v1/`.

## 55. From sentinel observation to a controlled DFG rewrite

An emitted DFG snapshot can now suggest one **build-level** experiment:

```sh
python3 g6lc_sentinel_index.py "$snapshot" --write-controls candidate.f
# Pass -f candidate.f on the next invocation of the same Verilator build.
```

The new file contains only `-fdfg-peephole-pack-byte-plane` or its
explicit negative. No snapshot text becomes executable code; an existing
response file is not overwritten. The JSON report lists the candidate
vertex IDs in that snapshot. IDs do **not** authorize an edit, denote
execution frequency, or carry over to the next build. The compiler
rematches every site. With no control file or explicit flag the rewrite
is **off**, even if `--dumpi-sentinel 1` is enabled. With the flag it
works without a dump; `--stats` reports the actual applications.

**Implementation and proof.** In an acyclic component after X handling
and before the existing DFG component optimizer, walk an eight-bit concat
LSB first. Require unshared intermediate concats/selects, single-bit
slices, one identical 64-bit packed variable, and offsets exactly
`p, p+8, ..., p+56` (`0 <= p < 8`). Do not traverse a variable's drivers.
Replace only the concat's result with the high byte of the following
unsigned 64-bit product:

```
(((row >> p) & 0x0101010101010101) * 0x0102040810204080) modulo 2^64
```

The multiplier sets positions `56-7*j` for `j=0..7`. The partial product
from input byte `i` and multiplier term `j` lands at `56+8*i-7*j`.
No two such positions coincide (a nonzero difference in `j` cannot be
a multiple of eight). Exactly `i=j` contributes in positions 56..63.
Thus there are no carries between useful bits. Mixed variables,
descending order, shared intermediate cuts, wrong widths and other
strides stay on the existing path. No change to ISA requirements, task
edges, trigger order, RTL, firmware, or the meaning of X initialization.

**Separate runtime correction.** At `-O3` even the *baseline* failed a
combinational model's input/output oracle, sometimes returning the prior
projection. `VlTriggerVec` wrote flags via `uint64_t` but read and
modified the same storage via `EData*` (32-bit), violating C++ aliasing
rules. `-fno-strict-aliasing` isolated the failure; it is not the fix.
`any`, `set`, `andNot` now operate on the declared word type, with no
layout change. Recompiling the original failing control with just the
corrected private runtime passed at `-O3`. Also checked empty vectors,
31/32, 63/64 and 129 boundaries, and overlapping operands. This is a
host control-flow correctness change; it does not change the wait
protocol. Recompile model/runtime objects consistently to pick it up.

**Measured generated-model experiment.** Same corrected runtime on both
sides, same compiler and native `OPT_FAST=-O3`, CPU 2, four million evals
of the scalar input / eight-plane fixture, two extra nonmatching outputs,
alternating AB/BA/AB. Each run first passed an independent oracle covering
all 256 selected-bit combinations for each of the eight offsets with other
bits set, including reversed and mixed-source outputs. All timed checksums
were `5c54f13def63aaed`; rewrites off/on: **0 / 8**.

| Pair | Off / on (million evals/s) | Off / on user instructions (billions) |
|---|---:|---:|
| AB | 34.81 / 58.41 | 2.251 / 1.271 |
| BA | 32.36 / 58.29 | 2.252 / 1.271 |
| AB | 28.77 / 42.25 | 2.251 / 1.271 |

Native instruction totals fell **43.6%**; median *paired* throughput
ratio was **1.68x**. These are short, host-sensitive leaf timings, not
Monte Carlo confidence bounds, Hyp8 cycles/s or a BMI2/AVX-512 speedup.
The earlier hierarchical fixture in `plane-flow/` did not qualify:
zero matches, and the unrepaired baseline failed its oracle. No timings
from it enter this table. Standalone regression:

```sh
VERILATOR_ROOT="$patched_runtime" python3 test_g6lc_plane_control.py \
    "$scratch_compiler" "$new_output_dir"
```

Scratch artifacts on `ovh_calltorch` are under
`/tmp/hyp8-lane-ab.U2p5fd/sentinel-v1/plane-flow/scalar/`: `plane.f`,
`on/*stats.txt`, `strict.log`, `f0.perf`..`f5.perf`, `qualified/`.
Before considering default enablement, measure actual matches in a
profiled MC payload and test that model at fixed cycles with identical
RVFI. This small one-word projection is not the strided checkpoint
column tile from §53.

## 56. Native sentinel ingest and empty deferred-deletion check

Build the static native index once from the actual, unstripped model ELF
(Linux/binutils; link with `-Wl,--build-id`). For each capture, create a
small separate database instead of reparsing the disassembly:

```sh
python3 analyze_objdump_hotpaths.py --elf "$model" --db native.db
perf record -e instructions:u --buildid-all -o capture.perf -- "$model" ...
python3 analyze_objdump_hotpaths.py --elf "$model" --native-db native.db \
  --db capture.db --perf capture.perf --sentinel "$dfg" --sentinel "$schedule" \
  --bindings provenance.json --report report.json
```

Both `--sentinel` and `--bindings` are optional. Bindings are **reviewed
inputs**, not inferred from matching line numbers, task IDs or symbol
substrings. Manifest shape: `{"elf_sha256":"...", "bindings":[
{"snapshot_sha256":"...", "vertex":37, "symbol":"<exact mangled name>",
"evidence":"<source to generated caller evidence>"}]}`. Use `task_id`
instead of `vertex` for a schedule. A snapshot without a mapping is
searchable static evidence, not credited with any IP samples. For a
wrapper shared by four instances, a function-level binding does not
distinguish the four instances or their threads.

The sidecar joins ELF SHA-256 to the native DB, perf's recorded DSO
build ID to the ELF, and symbol plus offset to an exact instruction owned
by that symbol. This does not depend on ASLR load addresses. Nonmodel
and unresolved samples remain in the event denominator. Reported paths
are shortest **possible** paths over direct calls and inter-function
direct tail jumps, not sampled stacks. The half-self estimate is half
of the symbol's own weighted event share: useful for sizing a hypothesis,
not a wall-time model. Neither the callee's descendants nor all DSO mutex
samples belong to the caller. `region_context` / `task_context` report
**containing-function** weight, which must not be summed across bindings.
Legacy disassembly DBs without authenticated ELF identity remain suitable
for static queries only. Inputs and outputs should have distinct paths.

**Experiment.** Indexed the repaired hierarchical control from §55 and
a candidate linked with the same generated C++, compiler flags and affinity
(CPU 2). In the baseline capture, 660 instruction samples mapped into the
model ELF and 1,465 were outside it. A reviewed binding links DFG vertex 37
(leaf output `bits`, SV line 7) to the generated `plane[0U]` assignment
and its ICO function. But the separate path `eval_step -> VlDeleter::deleteAll
-> VerilatedMutex::lock` suggested a simpler lever: the model checks for
deferred deletion even when no object has been enqueued. The native
`devdeadz` database `/tmp/variane.db` also has a direct call to `deleteAll`
from `eval_step`; that is **reachability only**. Current compiler emission
is conditional on `hasClasses()`; an executable without this call should
not benefit. The short periodic profiles varied sharply between builds;
do not extrapolate the fraction of time spent in libc from them.

**Runtime change.** `VlDeleter::put` sets an atomic pending bit after a
successful enqueue, while holding the queue mutex. The drainer can return
on an acquire load of false. It clears the bit only while swapping the
queue under that same mutex. The locked slow path, ordering of queued
destruction and loop for destructor-generated work are unchanged. A
separate test runs two posting threads, drains concurrently, cascades a
second enqueue from each destructor, and checks the final destructor drain
(16,002 destructions). Rebuild model and runtime objects together because
`VlDeleter` layout changes. No RTL, SoC timing/config/ISA or DTS change.

| Shared host, matched pair | Baseline / candidate M eval/s | User instructions, billions |
|---|---:|---:|
| AB | 24.632 / 28.224 | 1.664 / 1.480 |
| BA | 24.573 / 28.541 | 1.664 / 1.480 |
| AB | 21.039 / 28.462 | 1.664 / 1.480 |

All six timed runs passed the oracle with checksum `3ffcc5a3eee3e186`.
Median paired speedup **1.16x**; retired instructions **-11.1%**. This
isolates empty-disposal overhead, not the eight-plane rewrite. It does not
measure a class-allocation-heavy design, Linux boot, or MC cycles/s. The
next model gate is to verify a steady-state call on the exact MC executable
and qualify cycles/s plus RVFI, not multiply this result by §55.
Remote artifacts under `sentinel-v1/plane-flow/native-ingest/` include both
ELFs/build IDs, captures, SQLite indexes, binding manifests, raw counters
and the read-only reuse test (`reuse/`). The mismatched ELF and mismatched
perf capture were both rejected.

## 57. MC shortlist after tiling: age-matrix transpose versus issue wake predicates

**Question:** which *part of a caller*, on which lane, can shorten an MC
invocation? Rechecked the delivered tiled executable SHA-256 `0a717957...`
and `eight.elf` `3e6fc73f...`; all six archived §53 final A/B sidecars
report cycle 4,649. No new full-model timing or trace qualification in
this pass. The worker timestamps are the §53 first tiled build (`1B`,
`2B`), **not** the uninstrumented final ELF. The native weights are §52
packed-model samples; use them only as hypotheses about unchanged code.
No `deleteAll` self samples appeared in `attrib.json`. This does not rule
out inlining or callees, but does not justify transferring the §56 speedup.

**Check the extrapolator against a known change.** `--retain-body T=X`
on the sentinel CLI replays a fraction of a task's body with all observed
gaps, waits and other work fixed. Repeat for several tasks; replay jointly,
never add the resulting savings. Get a separate result per capture.
On one §53 control/tile pair, learn the ratios of total body times for
tasks 9, 15 and 26, then predict the *other* pair's sampled NBA span:

| Train -> check (control, tile) | Projected span reduction | Observed |
|---|---:|---:|
| (0A, 1B) -> (3A, 2B) | 21.35% | 21.40% |
| (3A, 2B) -> (0A, 1B) | 22.60% | 21.96% |

This is a backtest of the scheduling arithmetic when body changes are
**measured**. It does not validate predicting body cost from native symbol
weights, nor show sub-percent precision on a new workload.

**Where to look.** Divide the whole-symbol cycle weight attributed to each
component by that task's own attributed cycle weight, excluding objects
listed as changed by the final tile manifest. Component names come from
dominant generated source references/writes (not exclusive time in the
named expression). For the archive's partially classified task set,
hypothetically halving all classified LSQ callers gives **4.07% / 2.86%**
less sampled span in 1B / 2B; issue queue **4.03% / 2.74%**; commit bundle
**1.09% / 1.48%**; task-19 mark logic **0.24% / 0.22%**. The first two
are effectively tied at family scope. Do not sum the cases, or call these
projected model speedups. Many tasks/symbols lack classifications. Even in
unchanged objects the input distribution, cache and overlap may differ.

**Two measured operations, not just source labels:**

- **Task 27, LSQ age matrix.** `___nba_...__559` and `__531` build
  `i_vio_red.age_col` from `vio_age_q`. The age matrix packs 40 bits per
  row: destination word 0 reads input bits `0,40,...,1240`; word 1
  reads `1280,...,1560` then `1,41,...,921`. The §53 regular 32-bit
  matcher found **zero** word tiles in these callers. Matching four
  eight-bit fragments per destination word handles the column wrap without
  padding or changing the layout. `g6lc_pack_wrapped_columns.py` uses
  only proven in-range pure reads, batches within the same source epoch,
  and keeps all destination stores in order. Scalar 8x8 transposition
  requires no ISA extensions. **120 rewritten words in each caller.**
- **Task 25, issue wake qualification.** `__244` in TU `h53a8106c__65`
  emits the SV idiom `wk_v[k] && !(wk_lo[k] && !e_alu_cons[e])` bit by
  bit. In word 0 the low eight bits of this particular store are zero;
  the next 24 validity bits align with output bits 8..31. Replicate
  the single predicate bit and compute packed `valid & ~(enable & veto)`
  with exact shifts and masks. `g6lc_pack_predicates.py` demands that
  structure at each live bit and leaves unrecognized expressions alone.
  **42 words** matched in `__244`, zero in the next seven profiled callers.
  Their surrounding wake/tag comparisons, bypass and FPU logic are not
  accelerated by this transformation.

Both are opt-in, generated-C++ experiments; neither pattern matcher selects
by RTL name. Names are used only to choose measured test inputs. Extract
*original emitted expressions*, compile the original and replacement with
GCC 13 `-O2 -march=x86-64-v3`, pin to CPU 2, run AB/BA/AB:

| MC slice | Independent oracle | Control / candidate median throughput | Process instructions |
|---|---|---:|---:|
| LSQ, ten adjacent output words | all 1,600 input basis bits, both functions | 12.23 / 26.63 M batches/s | 3.092B / 1.782B |
| IQ, one output word | 8,192 randomized input sets, per-bit reference, both functions | 96.93 / 742.96 M words/s (first series) | 1.813B / 0.157B |

All six runs per slice had matching checksums. The LSQ transformation is
linear, so a basis checks the complete bit map. The IQ test includes
arbitrary multi-bit validity/veto masks and high bits in the gate operand.
One existing column oracle also passed on remote scalar and AVX2 builds.
These tests don't measure full function cost. The host had multiple other
models active; do not take short wall timings as idle-machine results.

**Effort decision.** The more transferable first trial is the *slower*
LSQ leaf: **688 words across eight unchanged, sampled callers** in a
screen restricted to principal `age_col` writers. Those callers cover
18.37% of task 27 and 4.22% of task 19's previously attributed cycles.
If **whole matched functions** halve, replay gives **0.88% / 0.60%**
less tiled NBA span. For `__244` alone (4.42% of task 25) the equivalent
numbers are **0.22% / 0.14%**. Neither is a bound for unexamined sites.
Thus the large IQ leaf ratio is not evidence for making it a compiler
default or changing the task-23 wait. For a bigger end-to-end target,
sample the exact tiled ELF inside the remaining LSQ `t1_ref_unres_d`
and issue-queue `lf1/lf2` callers before widening either matcher.

```sh
python3 g6lc_mc_age_probe.py "$original" "$fresh/age"
python3 g6lc_mc_predicate_probe.py "$original" "$fresh/wake"
python3 g6lc_mc_age_screen.py "$postpack" "$tile1/final/manifest.json" \
  "$original/Vg6lc_testharness_g6lc_core__pi37.h" \
  "$tile1/latency/1B" "$tile1/latency/2B"
```

Artifacts on `ovh_calltorch`: `/tmp/hyp8-lane-ab.U2p5fd/predicate-v1/`
and `measured/` there (`qualified.json`, `age-leaf/`, `confirm-leaf/`,
`families.py`, `calibrate.py`). No model binaries, RTL, clocks, SoC
timing, firmware or DTS were changed. Before promoting either lowering:
relink against the **tiled** control, compare sidecar and all eight RVFI
traces, and require an interleaved MC cycles/s result distinguishable
from host noise.

## 58. From the IQ wake word to an opt-in compiler pass

`-fdfg-peephole-pack-predicates` lowers a concat of 8..64 independent
`valid & ~(veto & gate)` bits before DFG inlining/expansion. It requires
an in-bounds ascending veto slice of one packed variable and a common
one-bit gate. Valid bits are concatenated in original order, not assumed
contiguous. The usual optimizer can then simplify this concat. The pass
never traverses storage drivers, never runs on SCCs, and does not move
work across tasks. Host software change only; no production RTL, silicon
timing, `.dts`, ISA, or config changes. Default off, independent of
sentinel dumps; `--stats` counts groups, not lanes.

**Coverage before timing:** The first compiler iteration matched the SV
fixture but **zero** groups on the archived IQ bank. `wk_v` has named
one-bit wires, and the gate is a distinct inversion of a distinct select
of the same bit in each lane. Accepting identical scalar reads and keeping
valid wires in order produced **two pre-inline groups** on the bank.
`--debug-check` passed on the fixture and `t_dfg_pack_predicates` reached
its self-checking `$finish`. One pre-inline group on the fixture, none
post-inline: the descending veto control stayed scalar. The final
bounds-guard build emitted byte-identical C++ and headers to the timed
candidate for both tests when invoked with the same input paths.

| Isolated model, off/on | Paired throughput (AB, BA, AB; off/on) | Process retired instructions |
|---|---|---|
| 56-bit SV fixture, M eval/s | 21.246/56.683; 21.463/53.474; 21.395/56.180 | 3.807B/1.422B |
| Archived IQ bank, simulated bank cycles/s | 146270/146760; 148602/150342; 151834/154001 | 6.156B/6.066B |

Pinned CPU 2, `OPT_FAST=-O3`, same corrected runtime and generated
driver on both sides. The first model checked both outputs against an
independent per-bit reference over 8,192 trials, then timed 4M evals;
all checksums `f423f571e990a11e`. The second clocked a bank for 60,000
cycles, hashed every output at both edges, and drove deterministic
pseudorandom inputs; checksums `dc30f6209823bf12`. First bank series
discarded: user C++ omitted `Verilated::commandArgs` and the final block
reported an error. Only the corrected, clean series is in the table.
The bank used the archived MC file list, `NTAKE=8 NXW=64` (72 wake bits,
four entries, as in the generated MC header), but otherwise standalone
defaults including the empty top-level config. This is a differential
bank stress test, not legal firmware traffic or the exact MC configuration.
The **1.46% bank instruction reduction** is more relevant than the
**2.63x fixture throughput**, but neither authorizes a whole-MC claim.

**Next candidate: remove the transpose, rather than just tile it.**
On the archived `g6lc_lsq_reduce` with `NLEAF=40 DIR=1`, the compiler
sees 25 consecutive 64-bit concat drivers of `age_col`. All 40 consumers
are `SEL[40] -> AND(same cand) -> REDOR`, both pre- and post-inline;
the sentinel reports `keep=false`. For a proven transpose this means
all 40 reduction results equal the OR of the original rows selected by
`cand`. The winner mask is `cand & ~selected_rows_or`. This is valid
for zero, one, or many candidates, not just a one-hot case.

An isolated exact-layout test packs each 40-bit row across two 32-bit
words, checks both algorithms against the scalar column oracle and tests
candidate densities separately. GCC 13 `-O3 -march=x86-64-v3`, CPU 2,
four million reductions, AB/BA. Fixed row scan vs set-bit iteration:
single-bit **19.2-19.6 / 391.9-433.5** M eval/s; random mask
**18.4-19.9 / 38.2-40.7**; full mask **17.8-19.1 / 21.3-22.5**.
These compare two candidate row algorithms, **not compiled MC or a
transpose baseline**. Check the actual mask density at the LSQ consumers
(rename-recovery density is irrelevant), prove that the input row version
is still available at each reduction, and check for observers/aliases
before eliminating storage. In particular do not use `keep=false` alone
to justify erasing a partial driver or crossing a scheduler publication.

Artifacts under `/tmp/hyp8-lane-ab.U2p5fd/sentinel-v1/plane-flow/wake-flow/bank-pass/`:
`qual.sh`, `check.sh`, `ok.log`, `leaf-?.perf`, `ok-?.perf`, `lsq40/`,
and `guard/` (scratch compiler SHA-256 `3ffe2ab1399514f2b53bf250ea92e5e85996e8f5884d066378afbea008490cc5`).
Replay via proxy shell only: invoke `--cc --exe --stats` on
`g6lc_wake_pack.sv` and `g6lc_wake_pack.cpp`, toggle the peephole flag;
for the bank, generate the driver with `g6lc_wake_bank_probe.py`. The
LSQ density experiment is `g6lc_age_reduce_probe.cpp` with arguments
`dense|sparse` and `single|random|full`. No new MC/RVFI run this pass.

## 59. Tiled MC LSQ occupancy and a consumer-only empty-mask guard

**Dynamic evidence.** Reproduced the tiled executable by relinking its archive
with the archived companion objects. Recompiled the original consumer TU
(`h7486aa93__852.cpp`) with the logged GCC 13 command; its object matched the
original and the tiled archive member. Sampled immediately before the eight
`i_vio_red.win_mask` assignments in the task-27 `__1238` function. Each RHS
reads that site's own 40-bit `cand` and `age_col`; no sampling at a producer,
no reads of another lane's live input row. Counts are function evaluations
across receiver instances, not guest cycles, per-hart rates, or unique masks.

| LSQ site | Empty | One bit | Two or more |
|---|---:|---:|---:|
| 0 | 4,865 | 7 | 0 |
| 1 through 7 (each) | 4,872 | 0 | 0 |
| Total | 38,969 | 7 | 0 |

**Compiler intervention.** New opt-in `-fdfg-peephole-guard-empty-mask`
puts a conditional around a group of expensive scalar reductions. The compiler
requires 8..64 one-bit results packed in order, each gated by the corresponding
bit of the same full-width variable, each inner OR reduction ANDed with that
same mask. Shared internal ops, mixed masks and cyclic components are excluded.
A nonempty mask takes the original path, including for dense/multihit data.
No transpose, state update, scheduling dependency or trace point is removed.
Default off. The archived 40-entry LSQ reducer and the isolated SV fixture
each applied one guard pre-inline, none post-inline. The generated C++ uses
a lazy conditional. The dedicated compiler regression checked mixed masks and
ran to `$finish` with `--debug-check`.

**Density control.** 4,096 independent per-bit oracle trials precede four
million single-threaded model evals, `-O3`, CPU 2, AB/BA/AB. Counts include
the driver and oracle. The empty-heavy fixture has 127 empty masks per 128
evals; this is not presented as a replay of MC inputs.

| Inputs | Off / on M eval/s in three pairs | Off / on retired instructions |
|---|---|---:|
| Empty-heavy | 23.04/82.78; 23.76/82.02; 23.90/86.91 | 3.474B / 0.921B |
| Random dense | 24.91/23.98; 22.40/23.94; 25.04/23.89 | 3.469B / 3.489B |

**Model qualification, not a throughput claim.** A separate frozen-TU replay
wrapped the same eight reviewed original RHSs in an empty-mask guard. The
occupancy and guarded builds both passed `tohost` at cycle 4,649 with metrics
and all eight retirement traces byte-identical to the tiled reference. Control
SHA `0a717957...`, instrumented `7b41c90b...`, guarded `7933a3a0...`, guest
`3e6fc73f...`. This does not qualify a fresh full-model Verilation or establish
an MC cycles/s improvement. In the older packed native capture, this entire
caller accounted for 0.063% of all sampled cycles, 3.40% of task 27's attributed
cycles. Even *removing the whole caller* with that weight gives only 0.31% /
0.21% sampled NBA-span reduction in the two tiled replays. The skipped
reductions are a subset. Do not spend a noisy shared-host A/B on this caller
alone or claim the instrumentation's wall time as performance evidence.

**Producer gate.** Sentinel now reports `masked_transpose_reductions` only
after checking a complete bit map and the consumers. On `lsq40`, pre- and
post-inline, all 1,600 bits match one square transpose across 25 disjoint
drivers; all 40 full-column slices feed masked reductions of the same mask.
The intermediate has no reported keep/module/external references. This is a
static witness in an isolated elaboration, **not** proof that a generated
consumer may read the current `vio_age_q` instead of the published columns.
For a larger gain, match the witness inside an acyclic compiler component
before scheduling, prove single-version reads/driver ownership there, and
verify that the actual sampled column builders disappear.

Raw artifacts: `/tmp/hyp8-lane-ab.U2p5fd/lsq-occupancy/{run,guard-run,compiler}`.
Reproduce through the remote proxy in fresh output directories:

```sh
python3 g6lc_mc_lsq_occupancy.py "$model" "$tile1/final" "$build_log" \
  "$guest" "$tile1/final-ab/1B" "$new_counts"
python3 g6lc_mc_lsq_occupancy.py "$model" "$tile1/final" "$build_log" \
  "$guest" "$tile1/final-ab/1B" "$new_guard" --guard
```

For the compiler A/B, Verilate `g6lc_empty_mask.sv` with `--cc --exe
--stats --debug-check` and `g6lc_empty_mask.cpp`, toggle only the guard
option and run each model with `z` and `d`. This is a host optimization;
no production RTL, ISA, synthesis timing, or device-tree impact.

## 60. Longer Hyp8 MC writer: nine full-model runs, separate cumulative and incremental gains

Increased `mc_multi_writer_line.S` from 8 to **64 iterations per phase and
writer**, without changing the firmware source, oracle, or trace options.
This is a bounded, complete four-core test, not the default 1,500-iteration
soak or a boot benchmark. The 8-iteration rebuild and archived `eight.elf`
have identical `objcopy -O binary` images (different ELF hashes); use the
64-iteration pinned ELF on *all* sides here. `tohost` remains `0x80001000`.

Compared three exact two-host-thread executables: **O** = archived
`devthr2-ab` original, **T** = packed masked rows + tiled columns, **G** =
T plus the eight frozen consumer guards from §59. These are whole
executable comparisons, not a fresh MC Verilation with a compiler flag.
Only G/T evaluates the incremental LSQ guard. One model at a time,
`taskset -c 2,4` (distinct physical cores), nine independent processes,
three rotated blocks so each build occupies each run position once.
No other `Variane_testharness` was observed at any run's start or end;
this is not a reservation of the host. Time the whole process, including
startup, tracing, finalization and the perf wrapper.

| Run order | O sim cycles/s | T sim cycles/s | G sim cycles/s | T/O | G/T |
|---|---:|---:|---:|---:|---:|
| T G O | 168.45 | 280.84 | 280.56 | 1.6672 | 0.9990 |
| G O T | 167.49 | 283.23 | 280.83 | 1.6911 | 0.9915 |
| O T G | 168.25 | 282.38 | 280.02 | 1.6783 | 0.9917 |

| Median per build | Sim cycles/s | Retired host instructions | Host cycles (both lanes) |
|---|---:|---:|---:|
| O | 168.25 | 321.101B | 700.519B |
| T | 282.38 | 180.979B | 436.384B |
| G | 280.56 | 181.275B | 439.027B |

All nine passed `tohost` at **13,431 cycles**; the metrics sidecar and
eight per-hart trace files matched byte for byte across all nine. At the
two loop-body PCs from the guest disassembly (`0x80000140`/`0064b023`
and `0x800001e4`/`0069b02f`), RVFI records independently confirmed
**64 slot stores and 64 shared-counter AMOs per hart** on harts 0,2,4,6.
These are 256 stores and 256 AMOs, not just a matching final cycle count.

**Decision:** keep T as the MC baseline. T/O delivered **+67.83%**
median within-block throughput with 43.64% fewer median instructions.
G/T delivered **-0.83%** median within-block throughput; median instructions
increased 0.16% and host cycles increased 0.61%. Three blocks on one host
do not prove a general regression of that size. They do show no MC gain
from promoting the eight-site guard here, despite the isolated fast path.
Do not transfer §59's mask histogram from the shorter guest as if it had
been measured on this workload. The better next candidate is removal of
the transpose producer before task scheduling, not further guard tuning.

Replay via the remote proxy, with a new output directory:

```sh
cc=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc
custom=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source/verif/tests/custom
$cc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d -mcmodel=medany -O2 \
  -nostdlib -nostartfiles -DITERS=64 -T "$custom/common/link_verilator.ld" \
  -o i64.elf "$custom/multicore/mc_multi_writer_line.S"
python3 g6lc_mc_long_writer.py "$original" "$tiled" "$guarded" i64.elf "$new_dir"
```

ELF/build pins are in `g6lc_mc_long_writer.py`. Raw evidence on
`ovh_calltorch:/tmp/hyp8-lane-ab.U2p5fd/long64.XCRy9X/`: `i64.elf`,
`guest-coverage.json`, `report`, `results/summary.json`, and per-run
`perf.csv`, metrics, log, traces, and verification hashes. The RVFI loop
count check was run separately against the matching traces and is also
included in the delivered runner. No production RTL or compiler defaults changed.

## 61. Fuse complete masked transpose reductions before scheduling

`-fdfg-peephole-fuse-transpose-reductions` (off by default) checks the actual
DFG component after X handling and SCC extraction, not an offline snapshot.
Only accept an undriven packed input port as the matrix source: no input
driver traversal, mutable alias, SystemC input or non-DFG write. Require
the private intermediate to have no keep/module/external references; prove
all `N*N` destination bits have disjoint complete drivers selecting exactly
`(position % N)*N + position/N` from that port. Require all `N` consumers
to select distinct whole columns and AND with the identical mask before
OR reduction. Replace the reduction results with bits of one shared vector:
a balanced OR of contiguous rows ANDed with broadcast mask bits, zero when
the mask is empty. This is *not* a set-bit iteration loop. The new operations
read the same combinational input and mask vertices before scheduling; no
generated worker reads across an old publication. No new ISA requirement,
production RTL, device interface, or silicon timing change.

**Full MC code generation:** regenerated the archived two-thread Hyp8 MC RTL
with the same scratch compiler and flags, differing only in fusion. One
pre-inline match (elaborated module, not runtime invocation count), zero
post-inline. In the generated core class the eight `i_vio_red.age_col`
members disappeared; direct word-store lines in the `pi37` TUs went from
**1,494 to zero**. The 30-task final graph changed from 61 to 55 edges.
These are *fresh* schedules, not the frozen tiled executable in §60: do not
substitute the new objects into that old archive or claim lower elapsed
time from compiler cost estimates.

**Execution test:** built and clocked the archived `g6lc_lsq_reduce` as
top, `NLEAF=40 DIR=1 TRACK_WAIT=0`, other parameters at their standalone
defaults. Both variants passed an independent bitwise winner oracle over
8,192 updates including flush, empty, singleton and multihit masks, checking
the registered winner and valid at the two-stage interface. One million
timed clocks per run, mutate matrix data, CPU 2, AB/BA/AB, `OPT_FAST=-O3`.
Final-source runs during full codegen:

| Input distribution | Off / on M reducer cycles/s (three pairs) | Process retired instructions |
|---|---|---:|
| 127/128 empty, otherwise singleton | .573/3.971; .576/3.964; .574/3.939 | 19.050B / 3.260B |
| Dense random | .571/3.922; .755/4.749; .717/4.595 | 19.059B / 3.269B |

All timed checksums agreed (`a8ecdcb33d7d`, `224e9018faf729` respectively).
Host work varied during timing; use the instruction counts and the scope
of the measurement. Regression `t_dfg_fuse_transpose` required exactly one
match among four 9x9 cones, rejected a wrong bit permutation, a mixed mask
and another reader, and ran its output oracle across all 512 masks. Disabled
early field/plan splitting on that small regression only. The exact-layout
MC reducer matched with the normal earlier optimizations enabled.

Artifacts: `/tmp/hyp8-lane-ab.U2p5fd/fuse61/` (`exact/verilator_bin`,
SHA `4c16c792630aa008dfca28f199712c2fce12298cadfb11dea0bf436409f536b2`;
`final-{ctl,opt}`, `final.log`, `final-*.perf`, `full-{ctl,final}` and
their stats). `final-bench.sh` builds both reducers with the MC file list,
`--cc --exe --stats --debug-check`, `-ffunction-sections -fdata-sections`
and `-Wl,--gc-sections` to drop unused file-list DPI wrappers. Replay
`g6lc_lsq_fusion_probe.cpp` with `z` and `d`. Both full MC elaborations
completed; **full native builds, 64-iteration firmware traces and paired
MC cycles/s are not yet qualified for fusion**. Build both fresh schedules
consistently and hold the existing packed/tiled optimizations equal before
comparing to the retained baseline.

### Fresh native A/B for the 64-iteration writer

`verif/regress/remote/g6lc_mc_fusion_ab.py` takes the §61 elaboration
directory, the archived RTL snapshot, the same runtime for both builds,
the pinned §60 guest ELF, the archived `0-tiled` reference run, and a new
output directory. Run it on the remote testharness host. It compiles fresh
archives with GCC 13 (`-O2/-O1/-O2`) and never borrows objects from a
different schedule. The generated source directories are left untouched.

Apply both expression matchers to core translation units referencing rename
recovery on each side. This uses the same rule on both sides instead of
assuming old task IDs or TU numbers survived re-elaboration. It can cover
more assignments than the old profiled-TU lists; **A**, not §60's executable,
is the throughput baseline for this experiment. The old executable still
provides an independent guest oracle. Per-file rewrite counts are saved in
`A/lowerings.json` and `B/lowerings.json`.

The detached job is under `ovh_calltorch:/tmp/hyp8-lane-ab.U2p5fd/fuse61/`.
`native62-series.log` tracks build and trial completions;
`native62/{A,B}/build.log` records compiler/link commands. After both links,
the runner automatically executes AB/BA/AB on CPUs 2,4. Each run must match
13,431 cycles, the archived sidecar and eight traces before its timing is
accepted. `native62/qualified.json` is written only after all six pass;
absence of that file is **not** a throughput result.

### Qualified result: do not enable fusion for the two-lane Hyp8 MC build

Both fresh native builds completed. A (off) `2cfd9c67937b8f3e56872a0550c9418283929dd224b1ce8115c203bcaf250f36`;
B (on) `0bca7d503ab7504a760ec91663e24ba2a2716a27b6682318560911c17c226daa`.
Each packed 3,420 row assignments; column lowering matched 13,388 and 13,674
projections respectively after code generation. This measures the end-to-end
effect of enabling fusion, including repartitioning, not fusion at fixed schedule.

| Run order | Off cycles/s | On cycles/s | On/off |
|---|---:|---:|---:|
| A B | 322.80 | 290.28 | 0.8993 |
| B A | 323.20 | 290.30 | 0.8982 |
| A B | 319.76 | 289.96 | 0.9068 |

Median paired throughput **fell 10.07%**. Median retired host instructions
fell 0.34% (172.028B to 171.446B), but median host cycles increased 11.85%
(397.483B to 444.580B, both lanes). All six runs matched the archive's
13,431-cycle success, sidecar and eight traces. No other model process was
observed at trial start/end. Do not use the older frozen tiled model's timing
as the denominator for fusion.

Two separate, trace-qualified `perf record -e cycles:u -c 25000000` runs on
the exact ELFs locate part of the additional cost. Lane 0's NBA worker
accounts for 9.49% of 399.075B sampled-period cycles off and 11.99% of
444.075B on (~37.9B to ~53.2B). `perf annotate` places the hottest branch
in each worker in a `pause; sub; jne` retry loop. The branch targets reload
the dependency word and check bit 30 off, bit 4 on. Generated waits confirm
`0x40000000` before task 29 off, `0x10` before task 23 on. Task IDs are
schedule-local. These are self samples, not exclusive producer attribution
or elapsed wait times. They do **not** explain the entire regression.

Keep fusion opt-in. If revisiting it, timestamp the fused schedule's task 4
start/publication and task 23 wait boundaries to distinguish late producer
start from expensive producer work. Do not prune the true dependency.
Raw data under `fuse61/native62/qualified.json` and
`fuse61/native62-profiles/{A,B}/{perf.data,report,nba0.asm}`.

### 63. The fused task 23 waits mostly before task 4 starts

Recompiled only the two NBA workers against each matching §61 native62
archive. The diagnostic records monotonic raw time at wait arrival, after
the wait, and after each body including `endOfThreadMTask` (immediately
before any publication). It does not move a signal or change a task.
Four diagnostic processes in ABBA order ran the same 64-iteration writer;
all matched the 13,431-cycle success, archived sidecar, and eight traces.
Sampled every 113th NBA invocation, first pair starting at invocation 13
(353 rounds), reverse pair at 71 (352). Every sample covers all 30 tasks
and passes lane-order and producer/consumer precedence checks.

| Model and schedule-local edge | Phase | Total wait ms | Before producer body ms | During body ms | After body ms |
|---|---:|---:|---:|---:|---:|
| A off, 30 -> 29 | 13 | 43.02 | 19.06 | 23.94 | 0.023 |
| B on, 4 -> 23 | 13 | 55.44 | 38.51 | 16.89 | 0.030 |
| B on, 4 -> 23 | 71 | 53.71 | 37.76 | 15.92 | 0.028 |
| A off, 30 -> 29 | 71 | 42.91 | 19.28 | 23.61 | 0.025 |

Intervals are clipped to the consumer wait and summed across sampled
rounds, not across all guest cycles. The tail includes timestamp overhead,
publication and wakeup; it is not a direct measurement of atomic latency.
On B, earlier lane-1 **task 16's body** overlapped 21.19 / 20.90 ms of
the phase-13 / phase-71 waits; **task 17's body** overlapped 15.74 / 15.07
ms. Together these account for **95-96% of the before-start interval**.
Task 4's own wait accounted for only 0.008 / 0.010 ms of it. On A, task
24's body accounts for 18.82 / 19.01 ms before task 30. These are different
graphs; comparisons of the highlighted waits do not decompose the entire
end-to-end fusion regression.

**Decision.** Do not tune the acquire loop or move task 4 ahead of other
work based on emitted waits: some legal-order constraints need no emitted
wait. On B, native direct-callee samples for task 16 include issue-bank
update/wakeup logic; task 17 includes issue arbitration and `vio_age_d`
generation. Bindings are context, not exclusive sample attribution.
For the faster unfused model, prioritize investigating task 25: a fixed-order
replay halving its whole body reduces sampled NBA span 4.69 / 4.70% (largest
single-body counterfactual in both captures). Two of its most sampled direct
callees (`__830` and `__817` in the profiled core instances) each have 2,196
generated `rob_d` assignment sites. That is a lead for a packed next-state
microbenchmark, not evidence that all assignments execute, that either
function can halve, or that MC throughput would increase by 4.7%.

Replay `g6lc_mc_fusion_wait.py "$fuse61/native62" "$guest64" "$new_dir"`
through the remote proxy. Evidence: `fuse61/clock63/{0A,1B,2B,3A}/`
(`qualified.json`, `stamp-{0,1}.txt`, log, metrics and traces). The §61
uninstrumented timings remain the throughput comparison.

### 64. Remote Hyp8 build policy

For a fresh, two-lane `g6lc64_hyp8_mc` throughput build, use packed rows +
tiled columns. The evidence is the four-core 64-iteration writer: 282.38 vs
168.25 simulated cycles/s in the original/tiled series; in a *different*,
fresh-build series, 322.80 without transpose fusion vs 290.28 with fusion.
Do not combine the two speedups. The empty-mask guard did not help this guest
either. Do not add fusion, guard, predicate packing, a task reorder, or a
fixed runtime affinity to general test jobs based on these results.

The common `hyp8-build-harness.sh` resolves `HYP8_BUILD_TUNING` for direct
proxy builds, the isolated integration build, and detached/staged native
PGO builds. `auto` (default) selects packed/tiled on fresh two-lane MC g6lc
split builds without explicit extra Verilator arguments or hierarchical
trace diagnostics. It keeps existing unmarked native seeds on the old path.
Use `off` for a control or `packed-tiled` to explicitly request the lowering
on a compatible MC build. Use distinct clean Mdirs, not a profile switch
inside an existing native build. For example, after proxy sync:

```sh
python verif/regress/remote/testharness_proxy.py build hyp8 --target g6lc64_hyp8_mc --vthreads 2 --jobs 2 --verlib work-ver-hyp8-mc-tuned
```

The g6lc builder prefers `-march=native` when the host compiler enables
AVX-512F/BW/CD/DQ/VL and BMI2; it also sets `VL_SIMD_PREFER_512`. A forced
include verifies those macros on each native compile, including PGO use.
`HYP8_BUILD_MARCH=native` requires them; automatic selection on other hosts
falls back to glibc-supported `x86-64-v3` or the compiler default.
`HYP8_BUILD_MARCH=x86-64-v3` reproduces the ISA of the timed control.
Native ELFs are host-specific: do not distribute them as portable v3 builds.
Native feature enablement is not a measured speedup over the v3 control.
For performance qualification, use matched ELF/traces/counters and CPUs 2,4
on the measured host, not that literal CPU list on arbitrary workers.

The native make overlay uses the active core TUs and their own class headers,
without editing the originals. Both PGO phases use the same overlay. Its
`hyp8-packed-tiled/manifest.json` carries source, tool, helper, and output
digests and per-file counts. A mismatched resume is rejected. On a fresh
unrecognized layout, automatic mode keeps the original C++; explicit mode
fails rather than reporting a tuned build. Isolated closures include the
tools. The build report/manifest records the effective policy; prebuilt
directed, smoke, probe and witness runs retain their selected model. Old
artifacts without a tuning record are unknown, not retrospectively qualified.

Scalar, SMT2, L3, single-thread leaves, compiler-only training, and archived
A/B/replay scripts keep their own contracts. No evidence here establishes
an optimum for those workloads or for Linux boot. On the archived fusion-off
elaboration the overlay matched all 553 qualified TUs, 3,420 row assignments
and 13,388 column projections. After removing only the added tile-temporary
scope and its indentation, all 553 sources matched the qualified overlay.
Representative row and column objects compiled through the generated make
rules. On `ovh_calltorch`, GCC 13 also compiled a tuned core TU with
`-march=native` and the ISA header; disabling either BMI2 or AVX-512F failed
the header check. The native preprocessor defined `__AVX512VBMI2__` as well
(not mandatory). This integration check is not a new simulation timing or
an end-to-end PGO qualification.

### Model-specific Lua tuning policies

`HYP8_BUILD_TUNING_PLUGIN=recovery.lua` opts into a Lua policy for the native
overlay. Use a fresh Mdir and sync/build a new closure first. For example:

```sh
python verif/regress/remote/testharness_proxy.py build hyp8 --target g6lc64_hyp8_mc --vthreads 2 --jobs 2 --verlib work-ver-hyp8-lua --env HYP8_BUILD_TUNING_PLUGIN=recovery.lua
```

Put trusted site policies in `verif/regress/remote/hyp8/policies/`. The proxy
and isolated closure include these files in their source identities. Lua 5.4
or 5.3 must be on the **builder's** PATH for an explicit policy. No Lua is
needed for the existing automatic/off/packed-tiled profiles. Sentinel JSON
observation (`HYP8_BUILD_SENTINEL=1`) remains independent: no dump is
required or automatically enabled, and the policy does not edit the SV or
control scheduling.

The script runs once per overlay preparation. `model.prefix`, `model.command`
and `model.has_source("crossbar.sv")` are taken from the emitted build
(source membership is a basename lookup in Verilator's recorded `.sv`,
`.svh`, `.v`, `.vh` inputs, not a claim of exclusive ownership). Example:

```lua
if model.has_source("crossbar.sv") then
    select_rule(model.prefix .. "_crossbar*", "route_mask", "packed-rows")
end
```

`select_rule(class_glob, literal_cpp_marker, transform)` selects active
generated class translation units. The marker selects the **whole TU**, not
a particular assignment; an empty marker selects every matching TU.
The supported transforms are `packed-rows` and `tiled-columns`, always
applied in that order and at most once per TU. The checked matchers, not
Lua, determine which assignments are legal. The API cannot supply generated
C++, shell commands, paths to outputs, or new lowering algorithms. Use
reviewed scripts: this is a build extension, not a security sandbox.

For other generated tops invoke `g6lc_hyp8_tuning.py MDIR --prefix Vfabric
--plugin PATH.lua` on the builder. It prepares `hyp8-packed-tiled/rules.mk`
for use **after** the model makefile, as in the common harness. It expects
the fork's parallel, separate `__DepSet_` C++ TU format and matching class
headers, not arbitrary C++ or arbitrary SV syntax. Invalid scripts, empty
plans, or zero matches for any requested transform fail an explicit build.
The receipt includes the plugin digest, runtime version, effective rules,
input hashes and rewrite counts. Changed policies do not reuse an existing
overlay. Requalify new policies against a control and a trace oracle before
claiming any model-level gain.

## 65. Sink-domain clock-skip (`-fclock-skip-sink`), DFG bitwise-mux packing, Lua clock-skip wiring, and `packed-mux-rows` (2026-11-23)

### 65.1 Why clock-gated sleeping cores still burned combinational work

Inspecting the generated `g6lc64_hyp8_mc_sleep` (`CoreSleepGate=1`, `--threads 2`)
schedule revealed why core-level ICGs (`tc_clk_gating`) previously yielded only
a marginal simulation speedup (§6.1):

- Sequential blocks (`_nba_sequent__*`, ~500 calls/core) are already cleanly
  isolated onto each core's gated clock triggers (`core_clk[0..3]`) and do not
  run while a core sleeps.
- However, **879 `_nba_comb__*` functions per core** (~818 MB of emitted C++
  per core — including `rob_d`, `u_recover`, `i_iq.e_d`, `i_prf`, `u_resolve`,
  `t1_mk_s`, `t1_fmk_s`) inherited the always-on global cluster clock trigger
  (`posedge clk_i`) via `V3Order::processDomains` domain union from a few
  ungated inputs (`noc_resp_i`, `irq_i`, `rtc_time_i`, etc.).
- **850 of those 879 functions (810.7 MB, 99.1%) are completely pure** with
  zero external `vlSymsp` writes and feed only the core's own gated sequential
  flops. Existing `-fclock-skip` could not touch them: it refuses `--threads > 1`
  models and its per-writer invalidation index emitted 6.18M edges on single-core
  dense activity (§9.5–§9.7).

### 65.2 Implemented generic compiler passes in `tools/verilator`

1. **`-fclock-skip-sink` (`V3ClkSkip::clkSkipSinkAll`, opt-in, ST and MT-safe)**:
   Runs post-`V3Clock` / post-`V3LifePost` and pre-`V3Descope` / pre-`V3Combine`
   / pre-`V3Partition::finalize`. Walks `_eval_nba` (including `AstExecGraph`
   MTasks in deterministic Kahn topological order), pins any variable observed
   outside `_eval_nba` (triggers, `_eval_act`, `_eval_ico`, `_eval` `__Vsampled__`,
   `_eval_final`, DPI, opaque C text, latches, primary IO, public, forceable,
   traced when `--trace`), and runs a monotone backward fixed-point over sink
   trigger sets. Any pure multi-domain `_nba_comb__` call whose transitive sinks
   depend only on a strict subset $K \subsetneq T$ has its NBA trigger guard
   narrowed to $K$ in place. Per sink group $K$ (e.g. one per gated core), emits
   one 1-bit dirty flag (`__Vclkskip_sink_d<N>`) and one `VL_ATTR_COLD`
   (`slow(true)`) pre-NBA refresh function `_clkskip_sink_refresh__<N>` hooked
   around `_eval_nba` in `_eval()` on the main thread (race-free at any
   `--threads N`, zero hot I-cache overhead when awake, exact pre-edge refresh
   on wake). Regressions: `test_regress/t/t_clock_skip_sink.{v,pl}` passes on
   both `--threads 1` and `--threads 2` with `--debug-check` (2 groups, 2
   deferred calls, 2 triggers dropped).
2. **`-fdfg-peephole-pack-bitwise-mux` (`V3DfgOptimizer::packBitwiseMux`, opt-in)**:
   Combines 8..64 adjacent 1-bit 2-way mux lanes `(sel & a[i]) | (~sel & b[i])`
   or `sel ? a[i] : b[i]` with shared 1-bit `sel` and contiguous ascending
   packed slices into one word-level `DfgCond`. Regression:
   `test_regress/t/t_dfg_pack_bitwise_mux.{v,pl}` passes with `--debug-check`
   (`packed bitwise muxes = 2`).

### 65.3 Lua policy clock-skip wiring, `packed-mux-rows`, and objdump/SQLite compare

- `g6lc_tuning_driver.lua` + `g6lc_tuning_policy.py` + `g6lc_hyp8_tuning.py`:
  added `model.has_define`, `model.has_flag`, `model.threads`, `model.phase`,
  `select_verilator_flag`, `select_clock_skip(mode, policy)` (`sink`/`causal`/`auto`,
  `required`/`opportunistic`), pre-verilate `--plan-vlt-flags`, `clockSkipStats`
  manifest verification, and checked `"packed-mux-rows"` (`lower_mux_rows` in
  `g6lc_pack_generated_rows.py`, handling complemented-enable 2-way bitwise muxes
  with shifted enables). Added flexible policies `hyp8/policies/{hyp8_mc_sleep,
  hyp8_mc_perf,generic_sleep}.lua` while keeping `recovery.lua` parity intact.
- `analyze_objdump_hotpaths.py`: added `--stats` (`vlt_stats` table), generic
  `hot_by_region` view, and `--compare <baseline.db>` JSON delta report.
- Harness & installer updates: `hyp8-build-harness.sh` (includes
  `g6lc64_hyp8_mc_sleep` in `packed-tiled` eligibility, wires pre-verilate Lua
  flag planning + capability-checked `HYP8_BUILD_CLOCK_SKIP=auto|sink|causal|off`,
  discovers `/opt/testharness/toolchains/lua*/bin`), `soft-ladder-build-harness.sh`
  (opportunistic `SOFT_LADDER_BUILD_CLOCK_SKIP` + plugin flags),
  `install-verilator-g6lc.sh` (`VLT_ALLOW_DIRTY`, `VLT_PGO_TRAIN_ARGS`, capability
  report, non-git closure `pipefail` fix). Lua 5.4.7 installed at
  `/opt/testharness/toolchains/lua-5.4.7` on `ovh_calltorch` (7/7 `test_g6lc_hyp8_tuning`
  tests pass live).

### 65.4 Measured results

1. **4-core sleeping-core benchmark** (local WSL, 4 `gated_core` instances with
   always-on global bus mutating every cycle, 3 cores asleep / 1 active, 500k
   cycles, `-O2`, checksum `83cedd1783dc8ea3` identical across all 4 builds):
   - `--threads 1`: `2.336M → 6.569M cycles/s` (**2.81× speedup**, 4 sink groups,
     4 deferred calls; cold `clkskip_refresh` total = 112 B / 24 insns in SQLite).
   - `--threads 2`: `1.276M → 1.471M cycles/s` (**+15.3%**).
2. **Real `g6lc64_hyp8_mc` frozen-model A/B of `packed-mux-rows`** on top of
   `hyp8-mc-csrfix-aggregate-t1` (`packed-tiled` + PGO + AVX-512, `--threads 2`,
   `i64.elf` 13,257 cycles, `taskset -c 2,4`, 6 interleaved AB/BA/AB runs,
   `/tmp/clkskip-work/mux-ab/summary.json`):
   - **118 core TUs / 3,498 mux rows** rewritten (`t1_mk_s`/`t1_fmk_s`),
     **−324.65 MB** generated C++.
   - **Objdump/SQLite `--compare` HOT cone**: `.text` `85.43 MB → 80.37 MB`
     (**−5.06 MB / −5.92%**), static HOT insns `18.33M → 17.28M` (**−1.05M / −5.75%**).
   - **Dynamic `instructions:u`**: A = `178.93B / 188.31B / 211.51B` (median
     `188.31B`) vs B = `163.04B / 161.03B / 167.62B` (median **`163.04B`**,
     **−13.42% median**, pairs −8.88% / −14.49% / −20.75%). All 6 runs passed
     `tohost=0` at cycle 13,257 with **all 4 core RVFI traces byte-identical**.
3. **Full `g6lc64_hyp8_mc_sleep` build with `verilator-v5.008-g6lc-clkskip` +
   `hyp8_mc_sleep.lua`** (`hyp8-sleep-clkskip-t1` in flight on `ovh_calltorch`):
   exercises `-fclock-skip-sink -fdfg-peephole-pack-bitwise-mux` + Lua overlay
   (`packed-rows`, `packed-mux-rows`, `tiled-columns`) + PGO; full sleep-model
   A/B vs `hyp8-sleepgatefix-aggregate-t1` follows on build completion.
