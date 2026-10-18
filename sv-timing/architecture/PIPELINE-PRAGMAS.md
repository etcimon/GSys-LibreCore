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
