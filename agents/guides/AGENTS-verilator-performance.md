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
- **Identity**: the Verilator work lives in the fork `github.com/etcimon/verilator`,
  branch `g6lc` (based on the pinned `v5.008`), pinned as the submodule
  `tools/verilator`; `build-platform/scripts/install-verilator-g6lc.sh` builds the pinned
  commit into `/opt/testharness/toolchains/verilator-v5.008-g6lc` (version string
  `5.008 (mod)`) and assembles a runtime dir (pinned headers + fork `verilator_bin`)
  that the build driver selects with `T16_VLT_ROOT` (the pinned `verilator` wrapper
  runs `$VERILATOR_ROOT/bin/verilator_bin`). A model built that way carries
  `recipe.verilatorRoot` in its manifest; qualification records say which compiler
  built the model.

## 5. Status and next measurements

| item | state |
|---|---|
| callgrind toolchain on the builder | done |
| fork commit `1878fd75` (no wide MultiSel merge) | fork + submodule pinned; compiler built on the builder; first model build in flight (`ooocoh-t21s-ooo-vltp2-build`, `T16_VLT_ROOT`) |
| `.vlt` split_var for the hybrid loops | candidate list above; not yet applied |
| PGO recipe (`-fprofile-generate/-use`) in the driver | not yet |
| harness preload rewrite | not yet |
| Verilator 5.03x A/B | not yet (pinned 5.008 stays the qualification compiler) |
| struct-of-arrays lowering (2.6) | assessment only |
