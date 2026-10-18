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
// svt-pipe: cut-ok [<dom>]                   next assignment: a stage may be cut here
// svt-pipe: no-cut                           next assignment: never cut (handshake, side effect)
// svt-pipe: require-contract                 module: only cut-ok anchors may be cut
```

`$id` in `kill` stands for the id of the operation at the stage being
killed (`kill=cancel_i[$id]`). Anchors (`cut-ok`, `no-cut`) bind to the
first assignment within three lines below the pragma, or to `on=<lhs>`.

Resolution (`pipe_contract::resolve`) binds every name against the module's
declarations and ports; an unbound name, a `kill` without `$id`, a `carry`
or `result` naming an undeclared domain, an unknown kind — each is a
*rejected* pragma, reported (`pipe_contract.rejected` in the algo trace)
and never guessed around. A module whose pragmas all reject has no contract.

## 3. Semantics

**Permission** (`cut_permission`). For a cut at node *n*: `no-cut` on its
LHS → forbidden; `cut-ok` on its LHS, or on the line of the statement the
planner split *n* out of (expression-spine nodes inherit) → allowed, in the
named domain or the domain whose valid / id the node reads; otherwise, if
the module `require-contract`s → forbidden, else unconstrained (today's
behaviour). The P10 handshake lock yields on a path that contains an
allowed anchor of a declared domain (`path_has_contract_cut`), and only
there.

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
  implemented), does not re-time across module ports, and does not change
  the planner's choice of cut points — only admits, carries or refuses them.
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
