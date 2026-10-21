# Re-pipelining contracts declared in the RTL (`svt-pipe`)

> Design of record for ALGORITHMS-EXPERTS **A123**. Code:
> `crates/sv-timing-core/src/pipe_contract.rs` (vocabulary, resolution,
> permission, alignment, stage bundle), `lower.rs::collect_pipe_pragmas`
> (collection), `sv-timing-transform/src/pipeline.rs::insert_register`
> (plan checks, two-pass application), `sv-timing-emit/src/dense.rs`
> (stage serialization), `sv-timing-emit/src/rhs.rs::rewrite_pipe_consumers`
> (consumer rewires). Fixture: `fixtures/auto_correct/pipe_contract.sv`,
> witness `fixtures/auto_correct/tb_pipe_contract.sv`.

## 1. The mechanisms, inferred from what the package already does

A register cut (`InsertReg`) is exact for a pure datapath and wrong for an
operation in flight: the staged value loses its *valid*, its *id*, the
*cancellation* the core raises in later cycles, the *flush*, and the
side-band (operator, destination) that must arrive with it. The two-stage
multiplier (A115) had to carry all of these by hand, and the P10 heuristic
(“same-edge pulse + index: refuse InsertReg”) exists precisely because the
IR cannot tell which signals play those roles. Three mechanisms already in
the package point at the generic form:

1. **Facts live in the file and are collected textually.** `translate_off`
   fences are comments the parser never sees, masked byte-for-byte before
   parsing; `$onehot0(...)` assertions are collected over the module span
   (`collect_onehot_facts`) and consumed by `OneHotSelect` as the design's
   own proof obligation. A re-pipelining contract is the same kind of fact:
   designer-written, next to the logic, invisible to synthesis, bound to
   names the parser knows.
2. **The transform serializes what it did back into the RTL.** Every cut is
   written as a comment at its origin, a declaration, a feed and a sink,
   and the edit is serialized to JSON (`EditRecord`); the emitted file is
   re-parsed and re-measured. A carried stage must serialize its *contract*
   the same way — the comment says what the stage samples and why that is
   legal; the JSON (`edits[*].pipe_stage`) carries it to the host; fenced
   assertions make it checkable in simulation.
3. **Permission is a path-class decision today (P10, prefix trees, FSM
   lanes).** Those are heuristics about where a flop would change meaning.
   A declaration by the designer is the authoritative form of the same
   decision, and must override the heuristic exactly where it is given —
   and nowhere else.

## 2. Vocabulary

```systemverilog
// svt-pipe: protocol <dom> valid=<sig> id=<sig> kill=<expr using $id> [flush=<sig>]
// svt-pipe: carry <dom> <sig>[,<sig>…]      side-band that must travel with the data
// svt-pipe: result <dom> valid=<sig> id=<sig> consumer-side assigns to rewire onto the last stage
// svt-pipe: cut-ok [<dom>] [on=<lhs>]        this assignment may be a stage boundary
// svt-pipe: no-cut [on=<lhs>]                this assignment is not a stage boundary
// svt-pipe: cycle <dom> q=<flop> d=<next> hold=<sig> steps=<n|param>
// svt-pipe: require-contract                 a bare name is not a stage; a cycle cone is
// svt-pipe: latency <dom> <param> base=<n|param>
```

`$id` in `kill` stands for the id of the operation at the stage being
killed (`kill=cancel_i[$id]`). Anchors (`cut-ok`, `no-cut`) bind to the
first assignment within three lines below the pragma, or to `on=<lhs>`.

Resolution (`pipe_contract::resolve`) binds every name against the module's
declarations and ports. An unbound name, a `kill` that uses `$id` on a
domain with no `id=`, a `carry` or `result` naming an undeclared domain,
or an unknown kind is a *rejected* pragma (`pipe_contract.rejected`). A
`kill` with no `$id` is the global kill of an id-less domain (A127), not
a rejection. A rejected contract forbids every cut. It does not fall
through to an unconstrained module. A `protocol` implies
`require-contract`. `cycle` `q`, `d`, and `hold` must be declared names;
`steps` may be an integer, a declared parameter, or a dotted parameter
such as `CVA6Cfg.MultStages`.

## 3. Semantics

**Permission** (`cut_permission`, then `cone_cut_permission`). For a cut
at node *n*, in order: a rejected pragma forbids the module; the cycle
capture `d` is allowed even if `no-cut` names it; `cut-ok` on its LHS, or
on the line of the statement the planner split *n* out of, wins over
`no-cut` on that same name and allows the named domain; any other
`no-cut` is forbidden; `require-contract` with no anchor is forbidden;
otherwise a domain whose valid or id the node reads allows the cut, and
a module with no contract is unconstrained.

The planner does not stop at that named anchor. `cone_cut_permission`
allows every node on an over-budget path that names both cycle `q` and
`d` (`path_names`: startpoint, endpoint, LHS, or an RHS read). A nameless
expression-spine node on that path is an anchor. The launch `q` and any
other `no-cut` stay forbidden. `schedule_pipeline_cuts` snaps each wanted
cut to the nearest such node. `insert_register` uses the same permission,
so a cone of several cuts is emitted instead of one capture. A handshake
or indexed-restore note on that cycle step stays balance-only (A148).

**Stage bundle** (`stage_for`). Stage *k* of domain *d* samples, on the
module's clock with the module's reset:

```
pipe_v   <= flush ? 0 : (valid_src & ~kill(id_src))   // valid_src = d.valid at stage 1, else previous stage's _v
pipe_id  <= id_src                                    // likewise d.id / previous _id
pipe_c_X <= carry_src(X)                              // each carried signal, likewise
```

Stage indices follow **data order** (the first cut on the path is stage 1)
even though the planner applies cuts from the end of the path; the bundle
of stage *k* chains to stage *k − 1* by name.

**Age consistency.** The logic computing stage *k*'s data (the feed of its
pipe) may read only: its chain predecessor, the domain's carried signals
(substituted by the previous stage's copy — `feed_rewires`), the protocol
signals, constants and loop variables. The *tail* — every node of the path
after the last cut — may read only the last stage's value, the tail's own
earlier nodes, and the carried / protocol signals, which are substituted by
the last stage's copies (`consumer_rewires`). The `result` pragma's assigns
read the last stage's `_v` **killed again at use** (a cancellation in the
consuming cycle must count), `_id`, and carried copies. Anything else is a
*foreign read*: a value of a different age, and the plan is refused with
the signal named and the `carry` line that would admit it.

**Plan discipline** (`insert_register`). The area gate (Dial 11) prices a
carried stage at data width + 1 + 8 + 8·|carry| and decides **per stage
before alignment**, so a refused stage leaves the plan the bundle depth is
derived from. Then, if any remaining cut is in a domain: every cut must be
(a stage without valid / id would desynchronise the operation); no stage
may read an earlier stage's LHS except its chain predecessor
(`alignment_violation`: “side path needs *n* balance register(s)”); no
foreign reads past stage 1 or in the tail. Any violation refuses the whole
plan before anything is rewired (`pipe_contract.misaligned`). Balance
registers for side paths are the next mechanism, deliberately not this one.

**Serialization.** Declarations are hoisted to the module header as plain
vectors of the resolved widths (`type(<signal>)` of a later-declared
variable is illegal in slang/yosys; Verilator tolerates it — the fixture's
first twin elaborated in one tool and not the other). The stage comment
`// svt-pipe: stage k of <dom> (InsertReg #n): valid<=…, id<=…, flush …, carry …`
and the JSON `pipe_stage` carry the contract; two fenced assertions per
stage state its obligations (`*_killed_stays_dead`, `*_flush_clears`).

## 4. Evidence (fixture scale)

`pipe_contract`: a 3-add + select chain under one domain (`valid_q`,
`tid_q`, `cancel_i[$id]`, `flush_i`; `carry op_q,a_q,c_q`; result
`res_valid_d`/`res_tid_d`), four `cut-ok` anchors, `no-cut` on the output
register. At -O3, 4000 MHz, `--allow-latency --real-cut-feeds --assume-clk`:
two stages carried (the gate refused two low-gain stages: 34 cells for
0.5 FO4), structural worst 34 → 14 FO4; stage 2's feed reads
`pipe_svt_p1_c_c_q`, the tail reads `pipe_svt_p2_c_op_q` /
`pipe_svt_p2_c_a_q`, the result side `pipe_svt_p2_v & ~cancel_i[pipe_svt_p2_id]`.

Witness (`tb_pipe_contract`, latency-agnostic: every emerging result must
belong to an issued, never-cancelled, never-flushed operation, with its id
and value, exactly once): gold and emitted twin, 3 seeds × 200 000 cycles
each, **0 errors** — twin: ≈ 103.9 k issued, 86.9 k emerged, 11.1 k killed
in flight, 3.9 k flushed. Mapped on Nangate45: gold 1.123 ns / 16 cells /
1593 µm², twin 1.103 ns / 14 cells / 2652 µm². The mapped gain is small:
ABC builds the three-operand sum as one carry-save adder, so the structural
model's 34 FO4 over-reads the mapped cone (≈ 52 adjusted FO4), and the one
stage the gate kept out (s3) is the tail's remaining depth. The area is the
contract's honest price: 64-wide pipes for 32-bit nets (`SVT_DATA_W`, a
pre-existing emitter choice worth narrowing) plus 64 carried bits.

`pipe_contract_side`: the same cone whose result reads `s1` and `s2`
directly — refused: “stage 4 reads `s1` (cut 1) past stage 2: side path
needs 2 balance register(s)”; the module is left unchanged.

Two emitter defects the fixture exposed and fixed: the “twin” rewrite of an
identical continuous assign now stays within the cut's own module
(`module_span_of_line`), and every injection (hoisted declarations, early
block, BalanceMux snippets, late stage block) targets the module that owns
the edits (`owning_module_slice`) rather than the first header / last
`endmodule` of the file.

## 5. Where this leads, and what it does not do

- It makes the latency-changing transform *declarable* where the designer
  knows the protocol, with the proof obligations serialized. It does not
  infer protocols.
- It does not insert balance registers on side paths (refused instead),
  does not handle ready/back-pressure (a `ready=` word is reserved, not
  implemented), and does not re-time across module ports. On a `cycle`
  cone it does change the planner's anchors: each budget-fit cut snaps to
  a cone-permitted node (A148, §18), then the plan is carried or refused
  as a whole. A module with no `cycle` line still only admits, carries,
  or refuses the anchors `cut_permission` already named.
- The whole-core question (A121: 176 adjusted FO4 at the worst module)
  needs the contract written at the eleven modules' real boundaries
  (acceptance, reservation, byte validity, cancellation, transaction
  identity — CONTROL-CONE-CLOSURE.md) and the balance-register mechanism
  for their side paths. The fixture shows the shape; the core is the work.

## 6. The core's list (A124): every file over 10 adjusted FO4, in order

Measured on the retained tree (Nangate45 module board, `adjusted-fo4.json`,
platform FO4 21.40 ps). `st@10` is the arithmetic of the rung — the number
of stages of ≤ 10 adjusted FO4 the worst cone would need, flop overhead
excluded — not a plan: at 10 adjusted FO4 (214 ps) the cycle is below one
64-bit adder on this library (≈ 26 adjusted FO4), so the lower rungs need
operators split across stages, not only stages between operators.

| # | module | adj FO4 | ns | st@10 | file |
|---|---|---:|---:|---:|---|
| 1 | `g6lc_lsq` | 176.0 | 3.766 | 18 | `core/ooo/g6lc_lsq.sv` |
| 2 | `g6lc_iq` | 142.8 | 3.055 | 15 | `core/ooo/g6lc_iq.sv` |
| 3 | `frontend` | 142.4 | 3.047 | 15 | `core/fetch_B/frontend.sv` |
| 4 | `store_buffer` | 141.3 | 3.024 | 15 | `core/store_buffer.sv` |
| 5 | `multiplier` | 131.8 | 2.820 | 14 | `core/multiplier.sv` |
| 6 | `scoreboard` | 127.9 | 2.737 | 13 | `core/scoreboard.sv` |
| 7 | `g6lc_rename` | 125.9 | 2.693 | 13 | `core/ooo/g6lc_rename.sv` |
| 8 | `instr_realign` | 119.0 | 2.547 | 12 | `core/fetch_B/instr_realign.sv` |
| 9 | `wt_dcache_wbuffer` | 105.6 | 2.259 | 11 | `core/cache_subsystem/wt_dcache_wbuffer.sv` |
| 10 | `g6lc_ooo_dispatch` | 97.9 | 2.095 | 10 | `core/ooo/g6lc_ooo_dispatch.sv` |
| 11 | `alu` | 96.4 | 2.063 | 10 | `core/alu.sv` |
| 12 | `csr_regfile` | 87.0 | 1.862 | 9 | `core/csr_regfile.sv` |
| 13 | `aes` | 83.7 | 1.790 | 9 | `core/aes.sv` |
| 14 | `g6lc_rob` | 77.9 | 1.667 | 8 | `core/ooo/g6lc_rob.sv` |
| 15 | `branch_unit` | 77.4 | 1.657 | 8 | `core/branch_unit.sv` |
| 16 | `g6lc_loop_buffer` | 71.6 | 1.533 | 8 | `core/frontend/g6lc_loop_buffer.sv` |
| 17 | `perf_counters` | 70.8 | 1.515 | 8 | `core/perf_counters.sv` |
| 18 | `g6lc_bp_ckpt` | 68.0 | 1.456 | 7 | `core/frontend/g6lc_bp_ckpt.sv` |
| 19 | `issue_read_operands` | 65.9 | 1.411 | 7 | `core/issue_read_operands.sv` |
| 20 | `g6lc_prf` | 65.2 | 1.395 | 7 | `core/ooo/g6lc_prf.sv` |
| 21 | `serdiv` | 63.3 | 1.354 | 7 | `core/serdiv.sv` |
| 22 | `instr_queue` | 62.7 | 1.342 | 7 | `core/fetch_B/instr_queue.sv` |
| 23 | `g6lc_bp_statcor` | 60.9 | 1.304 | 7 | `core/frontend/g6lc_bp_statcor.sv` |
| 24 | `wt_dcache_missunit` | 60.0 | 1.283 | 6 | `core/cache_subsystem/wt_dcache_missunit.sv` |
| 25 | `load_unit` | 59.3 | 1.268 | 6 | `core/load_unit.sv` |
| 26 | `store_unit` | 58.0 | 1.242 | 6 | `core/store_unit.sv` |
| 27 | `g6lc_bp_loop` | 54.5 | 1.167 | 6 | `core/frontend/g6lc_bp_loop.sv` |
| 28 | `ariane_regfile` | 54.3 | 1.161 | 6 | `core/ariane_regfile_ff.sv` |
| 29 | `cva6_fifo_v3` | 54.3 | 1.161 | 6 | `core/cva6_fifo_v3.sv` |
| 30 | `g6lc_icache` | 52.5 | 1.124 | 6 | `core/cache_subsystem/g6lc_icache.sv` |
| 31 | `cva6` | 48.2 | 1.032 | 5 | `core/cva6.sv` |
| 32 | `g6lc_memdep` | 47.9 | 1.026 | 5 | `core/ooo/g6lc_memdep.sv` |
| 33 | `fpu_wrap` | 47.3 | 1.012 | 5 | `core/fpu_wrap.sv` |
| 34 | `wt_dcache_mem` | 47.2 | 1.009 | 5 | `core/cache_subsystem/wt_dcache_mem.sv` |
| 35 | `cva6_mmu` | 45.7 | 0.978 | 5 | `core/cva6_mmu/cva6_mmu.sv` |
| 36 | `ex_stage` | 42.8 | 0.916 | 5 | `core/ex_stage.sv` |
| 37 | `cva6_tlb` | 41.8 | 0.895 | 5 | `core/cva6_mmu/cva6_tlb.sv` |
| 38 | `cva6_ptw` | 41.6 | 0.891 | 5 | `core/cva6_mmu/cva6_ptw.sv` |
| 39 | `ras` | 39.1 | 0.837 | 4 | `core/frontend/ras.sv` |
| 40 | `g6lc_bp_ittage` | 32.9 | 0.705 | 4 | `core/frontend/g6lc_bp_ittage.sv` |
| 41 | `lsu_bypass` | 32.3 | 0.691 | 4 | `core/lsu_bypass.sv` |
| 42 | `csr_buffer` | 30.6 | 0.655 | 4 | `core/csr_buffer.sv` |
| 43 | `wt_axi_adapter` | 29.8 | 0.638 | 3 | `core/cache_subsystem/wt_axi_adapter.sv` |
| 44 | `g6lc_bp_tage` | 29.2 | 0.625 | 3 | `core/frontend/g6lc_bp_tage.sv` |
| 45 | `commit_stage` | 26.7 | 0.572 | 3 | `core/commit_stage.sv` |
| 46 | `mult` | 25.6 | 0.547 | 3 | `core/mult.sv` |
| 47 | `exp_backoff` | 23.6 | 0.505 | 3 | `vendor/pulp-platform/common_cells/src/exp_backoff.sv` |
| 48 | `g6lc_way_predictor` | 23.2 | 0.497 | 3 | `core/cache_subsystem/g6lc_way_predictor.sv` |
| 49 | `g6lc_ftq` | 19.8 | 0.423 | 2 | `core/frontend/g6lc_ftq.sv` |
| 50 | `rr_arb_tree` | 19.0 | 0.407 | 2 | `vendor/pulp-platform/common_cells/src/rr_arb_tree.sv` |
| 51 | `cva6_shared_tlb` | 14.7 | 0.315 | 2 | `core/cva6_mmu/cva6_shared_tlb.sv` |
| 52 | `g6lc_bp_ghist` | 14.5 | 0.311 | 2 | `core/frontend/g6lc_bp_ghist.sv` |
| 53 | `axi_shim` | 13.7 | 0.293 | 2 | `core/axi_shim.sv` |
| 54 | `id_stage` | 10.9 | 0.234 | 2 | `core/id_stage.sv` |
| 55 | `fpnew_top` | 10.8 | 0.231 | 2 | `core/cvfpu/src/fpnew_top.sv` |
| 56 | `g6lc_fdip` | 10.1 | 0.217 | 2 | `core/frontend/g6lc_fdip.sv` |

### 6.1 The pattern: contract first, then the rung the contract admits

Each round takes the worst file, declares its contract (where a stage may
go, what it must carry, where it may not go and why), runs `correct
--allow-latency`, keeps what the witness and the board confirm, re-measures,
and moves to the new worst. The contract's verdicts name the next mechanism
when a rung is not yet mechanizable.

### 6.2 Round one (A124): contracts on the first nine files

| file | contract | verdict of `correct --allow-latency` |
|---|---|---|
| `core/multiplier.sv` | `protocol mul valid=mult_valid_s1 id=trans_id_s1` (no kill: mult.sv carries cancellation), `carry operator_s1,corr_q`, `result valid=mult_valid_q id=trans_id_q operator_d`, `cut-ok` on `prod_sum`, `no-cut` on the output register | contract resolved; bare cuts on `operand_a`, `sign_a`, `sign_b` **refused** (they would have desynchronised valid/id); the planner snapped the stage-2 cut to `prod_sum` — and the emitter refused it: `prod_sum` is declared inside `gen_two_stage` (**generate-scope emission** is the next emitter mechanism) |
| `core/ooo/g6lc_lsq.sv` | `protocol agu valid=addr_valid_i id=addr_id_i kill=cancelled_mask_i[$id] flush=flush_i`, `carry addr_i,addr_is_st_i,addr_size_i`, `no-cut` on `ld_d`, `st_d` | no stage admissible in the many-writer next-state function; **input staging** of the AGU request (with the occupancy outputs counting it) is the mechanism |
| `core/fetch_B/frontend.sv` | `require-contract`, `no-cut` on `npc_d`, `seq_base`, `fetch_address` | the fetch loop is architectural (next-line prediction with late correction) |
| `core/store_buffer.sv` | `protocol st valid=valid_i id=trans_id_i kill=cancelled_mask_i[$id] flush=flush_i`, `no-cut` on `speculative_queue_n`, `speculative_write_pointer_n` | input staging of the store request before the permutation |
| `core/scoreboard.sv` | `require-contract`, `no-cut` on `mem_n` | the id owner: staging belongs at its ports (writeback results, issue ack) |
| `core/ooo/g6lc_iq.sv` | `require-contract`, `no-cut` on `q_after_issue`, `older_d` | wakeup/select loop: speculative wakeup is an issue-queue architecture |
| `core/ooo/g6lc_rename.sv` | `require-contract`, `no-cut` on `map_d`, `fmap_d` | rename-read / rename-write split with intra-group bypass; id-less domain needed for a protocol pragma |
| `core/alu.sv` | `require-contract` | pure datapath: the stage is the FLU's, to be declared in `ex_stage` on `flu` valid / trans_id |
| `core/ooo/g6lc_ooo_dispatch.sv` | `require-contract`, `no-cut` on `tid_is_fpr_d` | input staging of the dispatch record (struct-member id) |

Changes to the mechanism this round required: a declared `protocol`
implies `require-contract`; `kill=` is optional (flush-only / carried-only
domains) and a kill without `$id` is a global kill; `result` takes bare
words for further consumer assignments (`operator_d`); carried signals of
user type are read back through `type(<sig>)'(<net>)`; names declared with
a package-imported type (`fu_op operator_s1;`, absent from the parser's
declaration sites) bind through their assignments; and the cut
**scheduler** snaps each wanted cut back to the nearest permitted anchor of
its segment, so the contract drives the planner rather than only judging
it.

### 6.3 What the verdicts ask for next

1. **Generate-scope emission**: declare the pipe, the bundle and the stage
   block inside the generate block that owns the cut (`gen_two_stage`),
   not at module scope. Unblocks the multiplier's third stage.
2. **Input staging** (`stage-input`, reserved): register a request
   (valid, id, kill, flush, carried fields) at a module's input and rewire
   every read of it, with the designer declaring how the module's
   acceptance / occupancy outputs account for the staged request. Unblocks
   lsq, store_buffer, dispatch, and the scoreboard's ports.
3. **Id-less domains** (rename, realign: `valid` + global `kill`/`flush`,
   no transaction id) and **struct-member ids** (dispatch).
4. **Balance registers** for side paths (A123).
5. The architectural rungs — fetch loop, issue loop, FLU latency — are
   design decisions with IPC cost; the contract records them as `no-cut`
   with the architecture that would move them, so no tool pass spends
   effort there.

## 7. Generate-scope emission and merge balance (A125)

**Generate scope.** A cut whose net is declared inside a *named* generate
block (if/case generate, not a loop body) is admitted when the contract
permits the anchor and the statement's RHS names only block-locals of that
scope (`generate_scope_of`, `block_locals_within`); an expression-spine cut
of the same statement inherits the scope, but a carried plan drops spine
cuts (a stage is a whole statement). The stage is then emitted *inside the
block*: its declarations after `begin : <label>`, its feed, capture, sinks
and assertions before the block's `end` (`inject_into_gen_block`, tokens in
order so `end else begin : sibling` closes the block at its `end`). The
staged data net takes the measured width (`PipeStage::data_width`: a
128-bit product sum is not staged through the module-wide 64-bit pipe).

**Exports.** A consumer outside the block cannot read `label.net`: the
block does not exist when its condition is false (the one-stage
configuration of the same module), and the consumer must then read what it
read before. Each such read becomes a module-level export driven by a
generate-if on the block's own condition — the staged expression,
hierarchically, in the active branch; the original signal in the other:

```systemverilog
logic [1-1:0] svt_gen_two_stage_mult_valid_s1;   // header
…
if (CVA6Cfg.MultStages > 1) begin : gen_svt_export_gen_two_stage
  assign svt_gen_two_stage_mult_valid_s1 = (gen_two_stage.pipe_svt_p1_v & ~(1'b0));
end else begin : gen_svt_export_default
  assign svt_gen_two_stage_mult_valid_s1 = mult_valid_s1;
end
…
mult_valid_q <= svt_gen_two_stage_mult_valid_s1;  // the consumer
```

Only signals a consumer actually reads are rewired or exported (an export
of an unread block-local would need a default its scope cannot see).

**Merge balance.** The side-by-side witness (`tb_mul_sbs +lag=2`) found
what the alignment rules had not: the emitted three-stage multiplier
elaborated in both configurations and failed on one result in three — the
carry-less products (`clmul_q`, `clmulr_q`) keep their own two-stage
pipeline and merge with the product at `result_o`, one operation late.
`merge_violation` now closes everything downstream of the stage's
consumers (every writer of a reached LHS is the same merge point — the
other arms of the result select) and refuses any register read there that
is not staged with the domain:

> merge at `result_o` reads register `clmul_q`, which is not staged with
> domain `mul`: a parallel datapath must take the same stage (carry it, or
> stage it with the same parameter)

So the multiplier's third stage is admitted, emitted correctly inside
`gen_two_stage`, exported to its module-level consumers — and refused on
merge balance until the carry-less pipeline takes the same depth. That is
a designer change, named: the clmul staging must follow the product's
stage count (and `mult.sv`'s liveness depth, `MultStages`, with it).

**Evidence.** Stock multiplier under the widened witness: 3 seeds × 300 k,
`lag=1`, 0 errors (unchanged). Emitted three-stage multiplier before the
merge rule: elaborates for `MultStages` 1 and 2, valid and trans_id align at
`lag=2` on every cycle, **77 313 result mismatches of 234 155** — all
CLMUL-class, as the rule now predicts. The merge rule is the round's
result; the stage itself waits on the RTL.

## 8. The merge resolved from both ends (A126)

The merge rule named the hazard: `result_o` reads `clmul_q`, one stage
short of the product. Two ends corrected it, neither alone sufficient.

**RTL end.** The carry-less stage-1 results `clmul_s1` / `clmulr_s1` were
locals of the unnamed `if (CVA6Cfg.RVB)` block — a stage in
`gen_two_stage` could not carry them, and an export's default could not
read them. They are now module-level nets (zero in the new `gen_no_clmul`
branch; the RVB block became `gen_clmul`), the same logic made visible.
The contract then says what must travel and where it lands:

```systemverilog
// svt-pipe: carry  mul operator_s1,corr_q,clmul_s1,clmulr_s1
// svt-pipe: result mul valid=mult_valid_q id=trans_id_q operator_d corr_sh clmul_q clmulr_q
```

`clmul_q <= clmul_s1` becomes `clmul_q <= svt_gen_two_stage_clmul_s1` —
the carried copy when the two-stage branch exists, `clmul_s1` otherwise —
so the carry-less path gains the same stage the product gained and the
select at `result_o` sees one operation's operands. The merge closure now
finds every register it reads among the staged (`clmul_q`, `clmulr_q`,
`operator_q`, `mult_result_q`) and admits the plan.

**Mechanism end.** The area gate then refused the stage: a bundle priced
at `1 + 8 + 8·|carry|` understated two 64-bit carries. The estimate now
uses the resolved widths — valid 1, id 5, operator 8, `corr_q` 66,
`clmul_s1` 64, `clmulr_s1` 64 — plus the 128-bit data: **336 cells for
10 FO4, 33.6 cells/FO4**, over the -O3 limit of 16. Balancing a parallel
datapath is what the stage costs here; the ledger says so, and the run
admitted it explicitly with `--opt-max-cells-per-fo4 48` (the row is in
`tradeoffs[]`).

**Witness.** Emitted three-stage multiplier against the one-stage
reference two cycles later (`tb_mul_sbs +lag=2`, stock Verilator):
**3 seeds × 300 000 cycles, 234 155 / 234 213 / 233 708 valid results, 0
errors** — every MUL / MULH* / MULW / CLMUL / CLMULH / CLMULR result, valid
and trans_id. The refactored stock RTL under `lag=1`: 0 errors, unchanged.

**What adoption needs.** The emitted module is one cycle longer than
`MultStages` says; `mult.sv` tracks cancellation for `MultStages` cycles.
Adoption is the emitted RTL *with* `MultStages = 3` in the configuration
(the wrapper's liveness follows the parameter); `tb_mul_lifetime` is a
fixed two-cycle script and needs a three-cycle variant before that
change. The mapped reading of the three-stage product comes from the full
route, not from this step.

## 9. The sweep (A127): every file of the list under `correct --allow-latency`

One run over the 56 modules at -O3, dial 11 at 48, contracts as declared
in rounds one and two. "Stage" is what the planner emitted: *carried* =
under a contract with valid / id / kill / flush travelling; **bare** = a
plain register in a module that declares no contract (exactly what a
contract exists to forbid — these are review items, not pipelines).
"Neutral" are the latency-neutral credits (BalanceMux / rebalance / loop
rewrite) the run also recorded.

| module | adj FO4 | contract | stage | neutral | verdicts |
|---|---:|---|---|---|---|
| `g6lc_lsq` | 176.0 | yes | none | balancemux 21 | insertreg_refused:cut_schedule=1, refuse=1 |
| `g6lc_iq` | 142.8 | - | none | balancemux 38 | — |
| `frontend` | 142.4 | yes | none | balancemux 3, rebalanceassoc 3 | refuse=4 |
| `store_buffer` | 141.3 | - | none | balancemux 26 | — |
| `multiplier` | 131.8 | yes | 1 carried | — | plan=1, refuse=5, rejected=5 |
| `scoreboard` | 127.9 | yes | none | looprewrite 1 | refuse=1 |
| `g6lc_rename` | 125.9 | - | none | — | — |
| `instr_realign` | 119.0 | - | none | balancemux 1 | — |
| `wt_dcache_wbuffer` | 105.6 | - | none | balancemux 1, rebalanceassoc 1 | — |
| `g6lc_ooo_dispatch` | 97.9 | - | none | balancemux 2 | — |
| `alu` | 96.4 | yes | none | balancemux 18 | refuse=1 |
| `csr_regfile` | 87.0 | - | none | balancemux 1 | — |
| `aes` | 83.7 | - | none | — | — |
| `g6lc_rob` | 77.9 | - | none | balancemux 16 | — |
| `branch_unit` | 77.4 | - | none | balancemux 3 | — |
| `g6lc_loop_buffer` | 71.6 | - | 4 **bare** | balancemux 8 | — |
| `perf_counters` | 70.8 | - | none | — | — |
| `g6lc_bp_ckpt` | 68.0 | - | none | balancemux 14, rebalanceassoc 1 | — |
| `issue_read_operands` | 65.9 | - | none | balancemux 1 | — |
| `g6lc_prf` | 65.2 | - | none | — | — |
| `serdiv` | 63.3 | - | none | — | — |
| `instr_queue` | 62.7 | - | none | balancemux 1 | insertreg_refused:compound_source_rewrite_unsupported=1 |
| `g6lc_bp_statcor` | 60.9 | - | 2 **bare** | balancemux 5 | — |
| `wt_dcache_missunit` | 60.0 | - | none | balancemux 1 | insertreg_refused:compound_source_rewrite_unsupported=1 |
| `load_unit` | 59.3 | - | none | — | — |
| `store_unit` | 58.0 | - | 1 **bare** | balancemux 1 | — |
| `g6lc_bp_loop` | 54.5 | - | 1 **bare** | balancemux 11 | — |
| `ariane_regfile` | 54.3 | - | none | — | — |
| `cva6_fifo_v3` | 54.3 | - | none | — | — |
| `g6lc_icache` | 52.5 | - | none | balancemux 14 | — |
| `cva6` | 48.2 | - | 1 **bare** | balancemux 1 | — |
| `g6lc_memdep` | 47.9 | - | none | balancemux 5 | — |
| `fpu_wrap` | 47.3 | - | none | — | — |
| `wt_dcache_mem` | 47.2 | - | none | balancemux 2 | insertreg_refused:cut_schedule=1 |
| `cva6_mmu` | 45.7 | - | none | balancemux 5 | — |
| `ex_stage` | 42.8 | - | none | balancemux 2 | — |
| `cva6_tlb` | 41.8 | - | none | balancemux 14 | — |
| `cva6_ptw` | 41.6 | - | none | — | — |
| `ras` | 39.1 | - | none | — | — |
| `g6lc_bp_ittage` | 32.9 | - | none | — | — |
| `lsu_bypass` | 32.3 | - | none | — | — |
| `csr_buffer` | 30.6 | - | none | — | — |
| `wt_axi_adapter` | 29.8 | - | none | — | — |
| `g6lc_bp_tage` | 29.2 | - | none | — | — |
| `commit_stage` | 26.7 | - | none | balancemux 13 | — |
| `mult` | 25.6 | - | none | balancemux 3 | — |
| `exp_backoff` | 23.6 | - | 1 **bare** | — | — |
| `g6lc_way_predictor` | 23.2 | - | none | — | — |
| `g6lc_ftq` | 19.8 | - | none | — | — |
| `rr_arb_tree` | 19.0 | - | none | — | — |
| `cva6_shared_tlb` | 14.7 | - | 1 **bare** | — | — |
| `g6lc_bp_ghist` | 14.5 | - | none | — | — |
| `axi_shim` | 13.7 | - | none | — | — |
| `id_stage` | 10.9 | - | none | balancemux 5 | — |
| `fpnew_top` | 10.8 | - | none | — | — |
| `g6lc_fdip` | 10.1 | - | none | rebalanceassoc 1 | — |

### 9.1 Reading

- **One carried stage in the whole list**: the multiplier (A126). Every
  other module either declares `no-cut` where its cone is (the state
  machines and loops of round one), or declares nothing and gets at most
  a bare register the planner cannot justify — seven of them, all in
  modules whose protocol nobody has declared (`g6lc_loop_buffer` 4,
  `g6lc_bp_statcor` 2, `store_unit`, `g6lc_bp_loop`, `cva6`,
  `exp_backoff`, `cva6_shared_tlb`). They stay review-only.
- **The refusals name the next contracts**: block-locals of `always`
  bodies and generate branches (`sdist` in the LSQ's STL scan, `rid` in
  the ROB, `less`/`sgn` in the ALU, `instret_d` in the CSR file,
  `fixup_active_dead` in the write buffer) — each a `cut-ok` decision or
  a `no-cut` with its reason, by the designer.
- **The structural report moved nowhere** (78.2 FO4 before and after):
  the one carried stage sits in a module whose structural worst is the
  atomic product, and the design's worst is elsewhere. The adjusted
  reading of the three-stage multiplier itself is owed to the full route.

### 9.2 What "pipelines throughout the list" is, after this sweep

Not a tool pass. Each file's rung is one of three decisions, and the
contract is how the decision is written down where the tool can enforce
it:

1. **An operation pipeline with a local protocol** (multiplier): declare,
   emit, witness, adopt with the latency parameter. Done once; repeatable
   where such a protocol exists — the FPU wrappers and `serdiv` are the
   candidates with their own valid / id.
2. **A fixed-latency unit whose latency is architectural** (ALU, branch,
   CSR, AES through `ex_stage`'s single FLU writeback port): a stage adds
   a structural hazard on that port and a cycle to branch resolution; the
   decision is an FLU redesign (own writeback port, speculative
   bypass), with IPC on the table. The contract records `no-cut` until
   it is taken.
3. **A state machine** (LSQ, IQ, store buffer, scoreboard, rename, ROB,
   dispatch, caches, TLBs — most of the list): the cone is a many-writer
   next-state function. Its rungs are *input staging* with the
   acceptance outputs counting the staged request, or *read retiming*
   (a scan computed from `_q` instead of `_d`, one cycle stale, declared
   acceptable) — mechanisms the vocabulary reserves (`stage-input`) and
   this round did not build, each with a module-specific correctness
   argument the designer must make.

Id-less domains (`protocol … valid= kill=<global>`, no `id=`) are in the
vocabulary as of this round for the fetch-side streams (realign, queues),
whose stages are rung 1 with a global kill; their contracts are the next
declarations to write.

## 10. Contracts on every file of the list; the multiplier's stage adopted (A128)

**Declarations.** All 44 editable files of the list that had none now carry
a contract, in the same fail-closed form: `require-contract` (no bare
register can land), the protocol roles the module's ports expose where
the role is unambiguous (`instr_realign` `valid_i`/`kill_i`/`flush_i` as an
id-less domain; `g6lc_loop_buffer`, `instr_queue`, `g6lc_ftq`, `g6lc_fdip`,
`g6lc_bp_ckpt`, `g6lc_bp_ghist`, `ras`, `cva6_fifo_v3` on their push /
update valids), and `no-cut` on the measured worst cone's next-state or
register with the one-line reason — a state machine, a same-cycle
handshake, the FLU port, an architectural loop. The three vendored tier-U
files (`exp_backoff`, `rr_arb_tree`, `fpnew_top`) are not edited. The
sweep resolves every contract; the only bare register left is
`exp_backoff`'s (vendored).

**The multiplier's stage, adopted.** The emitted third stage is written
into the RTL as `gen_three_stage` under `MultStages == 3`: `prod_sum`
registered, `corr_q` / `operator_s1` / `trans_id_s1` / `mult_valid_s1` /
`clmul_s1` / `clmulr_s1` one register further, and the output register and
the carry-less registers reading "last stage" nets (`*_sl`) that the
two-stage and three-stage branches both drive — the export pattern of §7
as plain RTL. `check_cfg` admits `MultStages inside {1, 2, 3}`;
`g6lc64_ooo` sets 3. `mult.sv` tracks cancellation for `MultStages` cycles
unchanged.

**Witnesses.** `tb_mul_sbs` takes the staged depth from `SVT_MUL_STAGES`
(default 2): `MultStages = 3` against the one-stage reference at `+lag=2`,
seeds 1 / 5 / 17 / 23 × 300 000 cycles, ≈ 234 k results each, **0 errors**.
`tb_mul_lifetime` is now a reference-model script (an operation issued at
step k emerges at k + MultStages − 1 unless cancelled through emergence or
flushed): **PASS at 2 and at 3 stages, 18 checks each**; the old wrapper
still fails it at step 5 (negative control unchanged). Whole-core slang
elaboration of the source tree with `MultStages = 3`: PASS
(`CONTROL_MODE=source-elab`).

**Reading.** The adjusted reading of the three-stage multiplier belongs
to the live-RTL route on `g6lc64_ooo` (`timings sta-rtl --remote --fo4 0`),
running as this is written; the module's mapped worst was the product
cone at 2.820 ns = 131.8 adjusted FO4. The 56 declarations move no path by
themselves: they are the enforcement layer under which every further
stage on the list is a designer's decision the tool can carry out.

## 18. Cone budget and the emitted stages (A148)

The structural budget \(B\) is the correct target (`budget_fo4`, 10 at
4000 MHz, `fo4_ps` 20, margin 0.2). Each over-budget path asks for

\[
\mathrm{cuts} = \min\left(16,\ \lceil \mathrm{FO4}/B \rceil - 1\right)
\]

and the walker may use more slots when `--opt-max-stages-per-region` is
larger. The dial does not reduce a cone below its own count. The uniform
remainder is \(\mathrm{FO4}/(\mathrm{cuts}+1)\). A single node wider than
\(B\) stays that wide.

A `cycle` line is the contract for that cone. `steps` is the wait the
rest of the machine already has. When the measured `q`→`d` step is inside
\(B\), longer cones in the module leave the single-cycle board. When the
step is over budget or unmeasured, they stay. The step itself is never
hidden by dividing its FO4 by `steps`.

With `--allow-latency` and `--real-cut-feeds`, an admitted cone becomes
corrected SV:

```systemverilog
logic [31:0] pipe_svt_p1_c, pipe_svt_p1;
logic        pipe_svt_p1_v;
assign pipe_svt_p1_c = (s1 + 32'd1);          // origin RHS, same cycle
// origin assign rewritten:
s2 = pipe_svt_p1;
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    pipe_svt_p1   <= '0;
    pipe_svt_p1_v <= 1'b0;
  end else begin
    pipe_svt_p1   <= pipe_svt_p1_c;
    pipe_svt_p1_v <= valid_i & ~(1'b0);       // stage 1; later stages chain _v
  end
end
```

The reparse of that file is the FO4 reading. On `cone_budget` (sixteen
32-bit adds, 60 structural FO4, `no-cut` on the launch `a_q`, `cut-ok` on
`y_d`) the emit placed seven stages. Reparse segments are 8.0 and 4.0
FO4, the `a_q`→`y_d` step is 4.0, and closure closes. Verilator 5.020
`--lint-only -Wall -Wno-fatal` exited 0. `valid_o` stayed on `valid_q`
because the fixture names no `result`. `max_path_fo4_after` in the JSON
stayed 60: that field is the in-pass IR max, not the reparse.

The same formula does not move a measured board. Delay-v43 was not
rerun. Delay-v44 changed the structural reading by linking reads to
reaching definitions (rename 234.9 → 130.4, lsq 181.2 → 216.9) and that
reading was not refit through this cut count. A 64-bit add remains about
12 structural FO4 and about 26 adjusted. On the delay-v43 file the
16-cut structural aim stays over 10 for `g6lc_rename` (13.8) and
`g6lc_lsq` (10.7).

### 18.1 What a `cycle` cone may absorb (A148b)

The `cone_budget` fixture's seven stages are a reparse result, not a
machine the fixture's consumer would accept: on a cone `q → f → d → q`
the launch keeps updating every cycle while `d` arrives `k` cycles late,
so `q` captures `f(q_{t-k})`. A `cycle` line therefore authorizes a
register only within the wait it publishes:

- `steps=S` resolves to an integer (a literal, a parameter-map entry such
  as `CVA6Cfg.MultStages`, or a module parameter with an integer default);
- `hold` gates the launch register: every non-reset non-blocking write of
  `q` is under `hold`, or `q <= q_d` and every non-copy writer of `q_d` is;
- the stages already emitted on the domain plus the plan are at most
  `S − 1`.

`steps=1` is a single-cycle recurrence and absorbs no register; the plan
is refused (`pipe_contract.refuse … absorbs 0 register(s)`), and the cone
keeps its latency-neutral rewrites only. A declared step that fits the
budget is a fact about that step; it does not take the module's other
single-cycle paths off the board. A feed-forward datapath whose consumers
wait on a valid is declared with `protocol`/`result`, not with `cycle`.

### 18.2 Experimental cuts, carry-over, cut surface (A149)

`correct --cycle-cuts experimental` lets a refused cycle plan land. The
stage's rationale carries `[UNVERIFIED: <reason>]`, the trace records
`pipe_contract.unverified`, and `correct.json` reports
`boot_validity.unverified_stages`. Such a tree changes the recurrence; it is
a research emit and is never a boot claim. The A123 alignment rule (a later
stage reads only its chain predecessor, carried signals and protocol
state) still applies and is where the OoO cones stop.

`correct.json` also carries two reference searches that change no IR:

- `carry_over[]` — for each emitted stage on an output port: every parent
  instance connecting that port, its parent-side readers (`flop`, `comb`,
  `output`), `feeds_back` (a combinational parent net derived from the port
  drives an input of the same instance), `propagates_up` (a parent output is
  written from it), and a verdict naming the adaptation the consumers need.
- `cut_surface[]` — for each procedural loop holding an over-budget cone:
  block-locals a per-iteration stage would hoist, roots written under the
  loop index, loop-carried names, indexed roots also written outside the
  loop, and a verdict (`expandable`, `expandable with hoisting`,
  `loop-carried`, `default outside the loop`, `no per-iteration write`).
  A loop-to-generate rewrite is sound only for `expandable*`; it gives the
  flop a legal scope and leaves the recurrence question where it was.

### 18.3 Balance instead of refusal; the propagation plan (A149b)

The A123 alignment rule exists so that every input a stage reads has the
same age as its chain. Its purpose is served by a balance register as well
as by a refusal, so `insert_register` now carries a side read instead of
refusing when the read is a **stable source**: an input port, a register of
the module, or a combinational net whose every source (through at most six
combinational writers, none on the plan's path) is one of those
(`balanceable_side_read`). The carried copy travels through every stage like
an authored `carry`, the stage statements read the previous stage's copy, and
the consumer reads the last. A side read derived from the staged chain is
still refused: its lag would have to follow the cut it branches from, which a
stage-1 copy does not give. Trace: `pipe_contract.balance` with the carried
names and widths (the area gate priced the plan before this bundle grew;
the widths are logged so that can be read).

Two checks that the loosening made necessary, both correctness, both
previously missing: a statement **off the staged path** that reads an
intermediate cut net is refused (the net now carries its stage's age and a
carry starts at stage 1, so no balanced copy exists: "side path needs k
balance register(s) from stage j"); a statement off the path that reads the
**last** cut net is refused unless the result rewiring reaches it or
everything else it reads is constant (reset and clock pins excepted). The
`pipe_contract_side` fixture's `res_d` read `s1` and `s2` past their stages
and had been refused only by accident (an uncarried `c_q`); it is now
refused for that reason. Expression-spine nodes keep only the text of their
RHS, so every alignment check parses it when the expression is absent.

### 18.4 Balance lines from any stage; observers (A149c, M1 and M13)

A carried signal now has a **start stage** (`PipeDomain::carry_from`,
default 1). The reader after cut *i* feeds stage *i+2* and reads cut *i*'s
net at age *i+1*; a read of cut *j*'s net (*j < i*) is *i − j* cycles too
old. `alignment_balance` carries that net from stage *j+2* on: the start
stage samples the net itself, every later stage samples the previous copy,
and the reader is rewired to the copy at stage *i+1*. The tail does the
same for the earlier nets it reads (`pipe_svt_p3_c_s1`,
`pipe_svt_p3_c_s2` in the `pipe_contract_side` fixture, whose `res_d` is
now a landed, balanced plan rather than a refusal). `stage_for` lists only
the carries active at a stage; a balance line adds *n − start + 1*
registers of the net's width. The age argument is the retiming one: every
input of every merge has the age of its chain.

An **observer** (`observer_only`) is a statement whose LHS is not an output
port, not a flop, not wired into a child instance, and has no functional
reader (through four combinational hops) — a debug alias, an RVFI or
performance tap whose only consumers are `$display`s and assertions the IR
has no nodes for. An observer may read a cut net a stage late; the plan is
not refused for it, and the trace names it (`pipe_contract.observer`).
`store_buffer`'s `speculative_write_pointer_q` is this shape.

### 18.5 Hint domains, retimable frontiers, unemitted stages (A149d)

```text
// svt-pipe: hint <dom> verified-by=<sig>
```

The domain's outputs are predictions a named verifier checks later (a
memory-dependence guess the LSQ orders anyway, a branch predictor the branch
unit resolves). A stage on its `cycle` cone changes *when* the hint is made,
not what the machine computes, so `cycle_capacity_refusal` does not apply;
the stage's rationale carries `[HINT: advisory domain … verified by …]` and
the trace `pipe_contract.hint`. The verifier must be a declared name. The
obligation is the designer's: every consumer treats the output as a hint,
and waits the hint can prolong stay bounded. `g6lc_memdep` declares
`hint md verified-by=train_valid_i` (its `svt-plan` lines already said the
LSQ ordering is authoritative).

`propagation[]` now records each capture's guards (reset, flush, enable) and
a `retimable` verdict: when every step is a `delay-capture` that reads only
the staged net and all those captures share one guard class, the parent
registers can move into the child instead of a stage being added — a
backward retiming across the port, no latency change. `moved_registers`
names them. Applying the move is not implemented; the plan states it.

A stage whose origin the emitter cannot rewrite (block-local or loop-index
feed, a non-assign origin) is **not emitted**: no declaration, no capture,
no assertion — a marker comment instead (`// sv-timing: stage … not
emitted: origin feed unresolved … IR credit void`). The CLI collects the
markers into `boot_validity.unemitted_stages`. Before this the stage was a
register fed `svt_zero` that nothing read, carrying IR credit.

### 18.6 Elastic stages (`ready=`), latency co-emission as a plan (A149e)

```text
// svt-pipe: protocol <dom> valid=<v> ready=<r> [id= kill= flush=]
```

`ready=` names the downstream ready the module's producer logic waits on
(A132 refused the field; M12 gives it a meaning). A stage on such a domain
is an **elastic register**:

```systemverilog
assign pipe_svt_p1_en = ~pipe_svt_p1_v | pipe_svt_p2_en;   // stage k: next stage's enable
assign pipe_svt_p2_en = ~pipe_svt_p2_v | ready_i;          // last stage: the consumer's ready
if (flush_i) pipe_svt_p1_v <= 1'b0;
else if (pipe_svt_p1_en) begin pipe_svt_p1 <= pipe_svt_p1_c; pipe_svt_p1_v <= …; … end
else if (<kill against the held id>) pipe_svt_p1_v <= 1'b0;
```

A stage accepts when it is empty or draining; a flush clears its valid
regardless; an operation held in it is still killed. The producer's reads of
`ready` — in assigns **and in the guards of its own captures** (`end else if
(ready_i || !valid_q)`), which the consumer rewiring now reaches through the
nearest enclosing header — move to the first stage's enable; the consumer
side (tail and `result` statements) keeps the real ready. The handshake
absorbs the added cycle: latency-insensitive by construction. Fixture
`pipe_elastic.sv`: two stages, `ready_o = pipe_svt_p1_en || !valid_q`, the
input register's enable likewise, `valid_o` from the last stage, Verilator
lint clean. The ready path itself stays combinational (`~v | ready`), so the
gain is on data and valid; a registered-ready (two-entry skid) variant is
the next step if the ready path sets the clock.

`check_latency` still refuses a plan whose stage count the published
parameter does not cover; M6 is recorded as a plan: `latency_update` gives
`(param, published, required)` and the CLI lists them in
`boot_validity.latency_updates` (trace `pipe_contract.latency_update`). The
co-emission itself — the parameter and its `check_cfg` range set to
`required` in the same emit — is not performed.

`correct.json` → `propagation[]` is the cross-module plan of each emitted
stage on an output port (`carry_over::propagation_plan`): a bounded walk
over the instance graph that records `delay-capture` (a flop reader samples
one cycle later; its other reads are its balance), `stage-comb` (a
combinational reader is re-staged and its readers follow),
`propagate-port` (a parent output moves and the walk enters the
grandparent) and `blocked-feedback` (the net re-enters an instance whose
output the walk moved: a cross-module recurrence). `valid` is true only when
every frontier settled at a capture inside the bound. The plan is what a
cross-module adaptation would have to do; the tool does not apply it.

### 18.7 Bottleneck trace: callers that wait more than one cycle

`correct.json` → `bottlenecks[]` (`carry_over::bottleneck_trace`) is the
verbose bubble list for stages that actually landed (`InsertReg`, a
`cut-ok` anchor, or a `cycle` cone). Stages on the same net are one group.
`added_cycles` is how many registers that group placed. `via` is `cut-ok`,
`cycle-cone`, or `insert-reg`.

A caller is listed only when the wait for the result is **more than one
cycle**:

- A combinational or output reader of *N* cuts waits *N* cycles. One cut is
  a one-cycle displacement and is not listed. Two or more cuts are a stall
  on a dependent use.
- A flop reader can absorb one cut by moving that capture into the child.
  Further cuts leave an *N*-cycle wait and are listed.
- A recurrence (the net is a `cycle` `q` or `d`, or `carry_over` says the
  port feeds back into the same instance) waits *N + 1* cycles: the loop
  edge plus the cuts. One cut already makes the loop take two cycles, so
  the caller is listed. That is the displacement of a clock limit into a
  synchronous wait.

Each caller records `module`, `instance` (empty when the reader is inside
the staged module), `caller` (the LHS), `line`, `kind` (`flop`, `comb`,
`output`, `recurrence`), `wait_cycles`, and `bubble` (one sentence). The
`verdict` is the same fact in one line. `correct` also prints it:

```text
bottleneck: cycle-cone placed 2 stage(s) on `y_o`; 2 caller(s) wait up to 2 cycle(s), a bubble on a dependent use
  wait 2 cycles  top u0 s comb line 12  combinational caller sampled this result in the same cycle; 2 cut(s) make it wait 2 cycle(s)
```

The list is feedback for a person reading an emit. It does not refuse the
cut, does not change FO4, and does not rewrite the caller. A second copy of
the callee is not assumed: the trace says who stalls, and a replica only
helps a second caller that does not need this result. A true dependence on
the listed caller is still a bubble of `wait_cycles`.

## 11. The `latency` word (A129)

```systemverilog
// svt-pipe: latency mul CVA6Cfg.MultStages base=CVA6Cfg.MultStages
```

A domain's stage count is a contract with the module's *consumers*: the
wrapper's cancellation liveness (`mult.sv` tracks `MultStages` cycles), a
scoreboard's latency table, a bypass network's distance. The word names
the parameter that publishes it and the stages the source already has
(`base=`, a number or a parameter when the source follows it, as the
multiplier does since A128). A plan of k stages is admitted only when `base + k` equals the
parameter's elaborated value. When `base` and the published parameter are
the same name, both sides move together, so the check refuses:

> latency: source already follows `CVA6Cfg.MultStages` (4 cycles); adding
> 1 stage(s) requires an RTL boundary change and matching consumer depth,
> not merely increasing the same parameter

That is the current `check_latency` text. An older diagnostic told the
user to set the same parameter to `base + 1`; that suggestion is not what
the tool prints now. `g6lc64_ooo` publishes `MultStages` 4 and
`multiplier.sv` already has `gen_four_stage`. Another tool stage on that
product stays refused until the register and the consumer depth change
together. The word is still the general form of A126: the designer writes
the published depth once, and the tool enforces it.

## 12. The live-RTL board after adoption (A130)

`timings sta-rtl --remote --fo4 0 --target g6lc64_ooo --map-recipe streamed`
on the tree with `MultStages = 3` and every contract declared — the **live
RTL**, no sv-timing emit. The previous board (§6) was of the *corrected
emit*; the two columns below are therefore not the same netlist, and the
tree also carries the concurrent write-buffer fixes (T46/T47). Platform
FO4 21.40 ps/INV_X1; 56 of 65 measured modules over budget;
budget-equivalent 216 MHz on Nangate45.

| # | module | adj FO4 | ns | §6 board | delta |
|---|---|---:|---:|---:|---:|
| 1 | `store_buffer` | 173.0 | 3.702 | 141.3 | +31.7 |
| 2 | `wt_dcache_wbuffer` | 132.3 | 2.831 | 105.6 | +26.7 |
| 3 | `frontend` | 128.2 | 2.744 | 142.4 | -14.2 |
| 4 | `g6lc_rename` | 125.9 | 2.693 | 125.9 | +0.0 |
| 5 | `multiplier` | 120.6 | 2.581 | 131.8 | -11.2 |
| 6 | `instr_realign` | 119.0 | 2.547 | 119.0 | +0.0 |
| 7 | `g6lc_iq` | 112.3 | 2.403 | 142.8 | -30.5 |
| 8 | `g6lc_ooo_dispatch` | 100.8 | 2.157 | 97.9 | +2.9 |
| 9 | `wt_dcache_mem` | 96.6 | 2.068 | 47.2 | +49.5 |
| 10 | `scoreboard` | 93.7 | 2.006 | 127.9 | -34.2 |
| 11 | `g6lc_lsq` | 91.6 | 1.961 | 176.0 | -84.4 |
| 12 | `issue_read_operands` | 90.8 | 1.943 | 65.9 | +24.9 |
| 13 | `alu` | 90.5 | 1.936 | 96.4 | -5.9 |
| 14 | `csr_regfile` | 84.9 | 1.816 | 87.0 | -2.1 |
| 15 | `g6lc_bp_statcor` | 83.7 | 1.791 | 60.9 | +22.8 |
| 16 | `aes` | 83.7 | 1.790 | 83.7 | +0.0 |
| 17 | `g6lc_rob` | 82.4 | 1.764 | 77.9 | +4.5 |
| 18 | `g6lc_bp_ckpt` | 73.3 | 1.568 | 68.0 | +5.2 |
| 19 | `g6lc_loop_buffer` | 72.3 | 1.548 | 71.6 | +0.7 |
| 20 | `cva6_tlb` | 69.1 | 1.478 | 41.8 | +27.2 |

**The multiplier.** 2.820 → **2.581 ns** (131.8 → 120.6 adjusted FO4),
reg→reg 2.013 → **1.817 ns**. The worst path is now the stage-1 product
from the module's inputs into `pp_q` (operand conditioning + the 65×17
Booth product, 38 cells reg→reg); the shifted-product sum that the third
stage isolated no longer appears. The remaining 120 adjusted FO4 is the
atomic product itself: the next rung in this module is *narrower slices*
(XLEN/8 partial products of 65×9 under `MultStages = 3`, whose sum tree the
third stage already owns), an arithmetic restructure the contract can
admit (`cut-ok` stays on the sum) but cannot perform.

**What moved and why, honestly.** `g6lc_lsq` 176 → 92, `g6lc_iq` 143 →
112, `scoreboard` 128 → 94 read lower on the live RTL than on the old
emit: the emit's own cuts had created in→reg boundary cones the board
attributed to those modules. `store_buffer` 141 → 173 and
`wt_dcache_wbuffer` 106 → 132 read higher: the write-buffer fixup-queue
work (T46/T47) added bytes-superseded masking to the forward merge and
the queue permutation. Neither movement is a pipeline result; the
multiplier's is.

**Flow.** The whole-core recipes now make slang's async-load flops
synchronous before mapping, as the per-module phase did; the first
live-RTL attempt mapped for 86 minutes and failed at OpenSTA on
`$_ALDFFE_` black boxes.

## 13. Hand re-pipelining, surface-tested: the multiplier's slices (A131)

With the emit path set aside and the contracts kept as the validation
layer, the first hand rung on the live board's multiplier cone: under
`MultStages = 3` the second operand is sliced into **8-bit** pieces
(`SB = MultStages > 2 ? 8 : 16`, `NS = XLEN / SB`, `PW = AW + SB + 1`),
eight (XLEN+1) × 9 partial products instead of four (XLEN+1) × 17, and an
8-term balanced sum (`gen_sum8`) in the stage the third register already
owns. Two-stage configurations keep the A115 16-bit slices. `check_cfg`
requires `XLEN % 8 == 0` at three stages.

| multiplier, Nangate45 live board | §12 (3 stages, 16-bit slices) | now (3 stages, 8-bit slices) |
|---|---:|---:|
| worst reg→reg | 1.817 ns (38 cells) | **1.623 ns** (33 cells) — the 8-term sum |
| worst any (in→reg into `pp_q`) | 2.581 ns = 120.6 adj FO4 | **2.531 ns = 118.3 adj FO4** |

The reg→reg cone the module owns fell 10.7 %; the boundary cone from
the operand inputs barely moved, because it is dominated by the operand
conditioning ahead of the product (the MULW / MULH* sign and width
selection on `operation_i`), not by the product's width — a cone whose
real start is the issue stage's operand mux, which the module board reads
with ideal inputs. The module's own stages now sit at 76 adjusted FO4;
the next rung for the boundary is a stage on the conditioned operands
(`MultStages = 4`, `mult.sv` follows), which the contract would admit
through the same `latency` word. (A132 measured that operand-only capture
and rejected it; A147 spends `MultStages = 4` on the final add instead —
PIPELINE-PRAGMA-REVIEW.md A147.)

**Surface tests.** `tb_mul_sbs`: `MultStages = 2` (16-bit slices,
`lag=1`) and `MultStages = 3` (8-bit, `lag=2`), seeds 1/17/23 × 300 k,
**0 errors** each; `tb_mul_lifetime` at 3 stages PASS (18 checks); the
streamed live route re-mapped the core (474 s) and OpenSTA linked
(`s2-openroad-sta` pass). The contract on the module is unchanged
(`cut-ok` on the sum, `latency … base=CVA6Cfg.MultStages`), so `correct
--allow-latency` still proposes nothing further under 3 stages.

## 14. A132: applicability audit and measured source/emit comparison

The current review is [PIPELINE-PRAGMA-REVIEW.md](PIPELINE-PRAGMA-REVIEW.md).
It distinguishes the 53 existing guards from executable cut plans, records
the vector-valid and target-binding gaps, and describes the request reservation,
backpressure and replay obligations for the highest measured modules.

Invalid domains now refuse emission; required contracts cannot fall back to
uncarried registers. Stage admission requires resolved scalar valids and bundle
widths. Unsupported `ready=` is an error. `latency` uses exact keys and explains
that `base=<same parameter>` leaves no room for an automatically added stage.
The old advice in §11 to increase that parameter does not solve this equation.

The retained RTL partitions the multiplier into smaller product tiles,
carry-save reduction and a final addition, at its existing three-cycle depth.
Paired placement with no disabled arcs improves worst arrival 2.634 → 2.215 ns
at +1.4% area. The actual corrected SV passes the same surface witnesses and
places at 2.298 ns. Neither source nor emit is near 10 adjusted FO4 yet.
The old board's trace describes reg→reg, not necessarily worst-any:
the causal claims about the input cone in §§12–13 require the independent
boundary reports now produced by the isolated review runner.

## 17. Input staging as a uniform shift (A138, trial)

For a module whose next-state permutation consumes every input, the admitted
stage is input staging of the whole input set, judged by a shift witness
(state equality with a delayed reference; outputs bounded by the previous
semantics). Built by hand on the store buffer behind `CVA6Cfg.StqInputStage`,
functionally proven, rejected on placement (the worst path was inside the
permutation). Any automatic `stage-input` mechanism inherits both the witness
obligations and the applicability condition (placed in→reg must dominate).

## 16. Row-local source preparation (A135)

`row-local <name> index=<net> rows=<param> banks=<q:d,...> max-rows=<n>`
must directly precede one `always_comb` conditional statement. Preparation
replaces that statement with an explicit per-row loop and `index == row`
selection; the directive is consumed into `row-local-applied`. It changes no
cycle latency and awards no timing credit. Prepared files are separate review
artifacts that are reparsed before correction; originals are never edited.
Refusals cover unstable or signed indices, mismatched bank types, non-field
writes, calls/macros/locals, unbounded replication and stale sources.
Measured loop-predictor result: 1.911 → 1.410 ns placed at −6.9% area.
See [PIPELINING-RT-LEARNING.md](PIPELINING-RT-LEARNING.md) §5a.

## 15. Representation preprocessing (A133)

`representation <domain> carry-save sum=<net> carry=<net> result=<net>` is a
standalone comment directive compiled before initial timing attribution.
The equal-width consumer must be exactly sum plus already-shifted carry.
An authored cut on either row authorizes one paired boundary: the critical
row is data and the other becomes its companion. A prohibition on either
blocks both. No boundary is authorized by the representation alone.

The compiler preserves source facts and adds marked derived carry/result and
equivalent-anchor facts to IR. It refuses unsupported scope, widths, hidden
reads, feedback and protocol-role aliases. Successful emission replaces the
directive with `no-cut on=sum,carry`; comma-separated no-cut targets are
supported for that consumed boundary.

See [PIPELINING-RT-LEARNING.md](PIPELINING-RT-LEARNING.md) for the implemented
pipeline, evidence, mathematical obligations and broader strategy families.

## 19. `svt-stage`: stage-aware FO4 view

A `svt-stage` region is an annotation, not a cut contract: it groups the IR
nodes whose origin-mapped source line falls between its `begin`/`end`
comments and gives that group its own budget multiplier. **The base
closure numbers are measurement truth and do not change** — this is an
additional view over the same paths, not a waiver and not STA.

Grammar (one pragma per comment line, anywhere in a module body):

```text
// svt-stage: begin <name> [cycles=<n>] [window=<n>] [after=<name2>]
// svt-stage: end <name>
// svt-stage: order <module> <s1>,<s2>,...
// svt-stage: use <name> on=<signal>[,<signal>...]
```

- `cycles=n` (default 1): a path whose first and last comb nodes are both
  inside the stage is judged against `n × budget_fo4` — a declared
  multi-cycle window, reported as such.
- `window=n` (default 0): a path *entering* the stage (last comb node in
  the stage, first comb node in another stage or unstaged) is judged
  against `(1+n) × budget_fo4`.
- `after=<name2>`: documentation plus a boundary check. A finding is
  emitted when the boundary is crossed combinationally — a path whose
  comb nodes run `name2 → <name>`, or (the node-graph fallback, when no
  single path spans both regions) a comb node inside `<name>` that reads
  a net whose *driver* is a comb node inside `name2`.
- `use <name> on=<signal>`: overrides region membership for the nodes
  that drive the named nets (LHS root match), wherever the assign sits.
- `order` is documentation of the intended stage order for the module.
- Nodes in no region belong to the implicit stage `-` (unstaged).
  Unbalanced `begin`/`end`, nesting past one level, duplicate names and
  bad arguments are reported as pragma issues on the module's first
  stage row, never silently.

Region membership uses the origin-mapped line (`get_origin`), never the
preprocessed offset, so pragmas keep meaning through `include` and macro
expansion.

Report surface: `analyze` and `correct` JSON gain

```json
"stages": [
  { "module", "stage",
    "decl": { "file", "line_begin", "line_end", "cycles", "window", "after" },
    "node_count",
    "worst_in_stage":   { "path_id", "total_fo4", "startpoint", "endpoint", "primary_loc" },
    "worst_into_stage": { "from_stage", "path_id", "total_fo4", "startpoint", "endpoint" },
    "stage_budget_fo4", "closes_in_stage", "closes_into_stage",
    "findings": [] }
],
"stage_users": [
  { "module", "stages": [names],
    "used_by": [ { "parent_module", "instance", "file" } ] }
]
```

and every path carries `stage_start` / `stage_end` (first/last comb node
stage; `null` = unstaged) so a consumer can regroup. CLI:
`analyze --stages` / `correct --stages` prints the per-module table
(stage | cycles | window | nodes | worst in-stage vs budget | worst
into-stage (from) | file:lines | findings) plus a users table; modules
with no `svt-stage` declarations print nothing. `--stages-json <path>`
dumps `{stages, stage_users}` separately. Fixture:
`fixtures/auto_correct/stage_pragmas.sv` (S2 `cycles=2` closes a 14-FO4
cone against its 16-FO4 stage budget; the deliberate S1→S2 comb crossing
produces the `after` finding; S3 `window=1` admits the `-` → S3 entry).

### 19.1 Bubble-up: what a declared stage's cycles do to its readers

`svt-stage: class <stage> decision|value` — one pragma line per stage,
optional — tells the bubble-up analysis the author's intent for every
reader of that stage's outputs. The distinction is the machine's, not the
annotator's:

- a register in a cone that produces a READINESS / NEXT-ADDRESS DECISION
  (issue wakeup → select → grant, a dispatch `issue_valid`, scoreboard
  operand-ready, an `npc` recurrence, a rename map → prd back-to-back) is
  a **drag**: it inserts a bubble between dependent decisions and no other
  issue port can wake the dependent one sooner;
- a register on a VALUE path (multiplier, ALU result, a verdict, a
  write-buffer forward) is a **stall** that out-of-order issue covers
  when another instruction is ready — the dependent use still waits the
  full depth.

For every stage that *adds cycles* (`cycles>1`, `window>0`, or a region
containing the registers that publish its results — flop captures in the
region whose Q is read outside it, including through an output port), the
analysis computes the stage's **output nets** (nets driven inside the
stage and read outside it) and walks every reader: in-module readers in
other stages plus parent-side readers through the instance graph (the
same `carry_over` walk the bottleneck trace uses, one combinational hop
included). Each reader records `{module, instance, lhs, line, kind,
wait_cycles, class, class_source, absorbed, absorbed_by}` where
`wait_cycles` is `(cycles−1) + window + (publishing register ? 1 : 0)`
plus one on a recurrence.

Classification order: the stage's `class` pragma wins for all its
readers; a reader on a `svt-pipe: cycle` recurrence (its LHS is a
declared `q=`/`d=`/`hold=` name) or a `recurrence`-kind reader is
`decision`; a reader LHS matching the readiness vocabulary
(`*valid_o`, `*ready*`, `*rdy*`, `*grant*`, `*select*`, `*issue*`,
`npc*`, `*map*`, `*prd*`, `*wake*`) is `decision`, labelled `heuristic`;
everything else is `value`.

A reader is `absorbed` when a declaration covers the wait: the net's
domain `throughput … accept=<n>` (n ≥ wait), an elastic
`protocol … ready=` domain, `replicate <dom>`, or the reader module's own
`async … cycles=<n>` on the read. Verdict per stage:

- `drag` — any non-absorbed `decision` reader; the `svt-pipe: cycle`
  lines the stage collides with (file:line, in the producer or the
  reader's module) are listed so the author sees the recurrence it drags;
- `covered` — every non-absorbed reader is `value`;
- `absorbed` — every reader is absorbed by a declaration, **or** the
  stage carries an explicit `svt-stage: absorb` architectural cover
  (below).

#### Architectural covers: `svt-stage: absorb`

```text
// svt-stage: absorb <stage> by=<mechanism> [cond=<text>]
```

`mechanism ∈ {spec-wakeup, read-ahead, elastic, replicate, async,
throughput}`; `cond=` is free-form rest-of-line text (quotes optional)
recording the precondition the author asserts. A declared cover is the
*only* legitimate cover for a decision-class stage: the stage reports
`verdict: "absorbed"`, its `cover` object carries `{by, cond, verified}`,
the readers are still listed verbatim, and the verdict no longer hides
the drag readers — they print as `decision readers: …`.

The cover's precondition is checked where the IR can see it:

- `spec-wakeup` — verified when latency-class/wakeup state is visible in
  the module (`hyp_lat_class`/`LAT_*` uses, `alloc_lat`, `wake_cnt`, …):
  producer latency classes fixed, `LAT_NONSPEC` producers waking on real
  writeback, replay re-arming. When the IR cannot see that machinery —
  e.g. it lives in a sibling module — the stage still reports `absorbed`
  but carries an `unverified-cover` finding with the cond text;
- `read-ahead` — verified when the stage contains a register whose D is
  an indexed read of another register inside the stage (the table read
  produced one cycle ahead of its use); otherwise `unverified-cover`;
- `elastic`, `replicate`, `async`, `throughput` — verified when the
  corresponding `svt-pipe` contract (`protocol … ready=`, `replicate`,
  `async … cycles=`, `throughput … accept=`) exists on the module;
  otherwise `unverified-cover`.

Report: `stage_bubbles` rows gain `cover: {by, cond, verified}` and a
`findings` array; `--stages` prints `cover by <mech> (cond: …)` and each
finding on the bubble-up line. Measurement truth unchanged: a cover is an
author-declared architectural fact, not a waiver.

Report: `stage_bubbles` in the analyze/correct JSON and `--stages` prints
a `bubble-up: <verdict> — N reader(s), worst wait K cycle(s); drag
readers: …` line under each stage. Measurement truth unchanged: this is a
view, not a waiver. Fixture `fixtures/auto_correct/stage_bubbles.sv`
covers all three verdicts, both `decision` sources, and both `absorb`
outcomes (a verified `read-ahead` cover and an unverified `spec-wakeup`
one).
