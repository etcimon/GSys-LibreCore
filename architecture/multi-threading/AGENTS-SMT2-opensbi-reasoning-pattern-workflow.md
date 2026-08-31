# SMT2 × OpenSBI reasoning-pattern workflow — the foundation the logics and heuristics stand on

**Status: philosophy and thought-pattern foundation.** This is the third and lowest layer of a trio.
It does not add rules; it explains *why* the other two have the rules they have, and it gives an
agent an executable way to think so that the rules can be **re-derived rather than memorised**.

```text
   AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md  ← YOU ARE HERE. Propositions + thought patterns.
        │                                               "how to think about a change"
        ├── ../AGENTS-g6lc-opensbi-dev-heuristics.md   ← Weighted heuristics H1–H7, workload-agnostic.
        │                                               "what to do, and when it is worth doing"
        └── AGENTS-smt2-opensbi-dev-logics.md          ← SMT2 inference procedure, instance-specific.
                                                        "where this pin lives and what owns it"
```

Normative law is elsewhere and unchanged: [`../firmware-boot-principles.md`](../firmware-boot-principles.md)
(R1–R12, I1–I28), [`../core-fetch/SPEC.md`](../core-fetch/SPEC.md),
[`../core-fetch/VALUES.md`](../core-fetch/VALUES.md), [`../core-fetch/NEGATIVE.md`](../core-fetch/NEGATIVE.md),
[`soft-ladder/README.md`](soft-ladder/README.md). Evidence is
[`testharness-proxy.md`](testharness-proxy.md) only. Firmware witnesses are OpenSBI **v1.5**
(`455de672`) at `build-platform/workspace/smt2-linux/opensbi`.

**Why SMT2 is the right ground for a general philosophy.** `g6lc64_smt2` is the smallest
configuration in the tree that is simultaneously multi-threaded (`T=2`), superscalar (`I=2`),
compressed (`RVC`) and wide-fetch (`FW=64`), running real supervisor firmware. It is therefore the
first configuration where *interaction* dominates *component correctness* — and interaction is the
regime every future capability (n-wide, `NrCores` scale, `RVH`, RVV, OoO) also lives in. The
propositions below were paid for once, at SMT2 prices.

---

## 1. The notation — sentence pseudo-code (SPC)

The other two documents use Python-shaped pseudo-code because they describe *procedures*. This one
describes *reasoning*, so its atoms are propositions, not operations. An agent reading SPC should be
able to execute it by thinking, and to check its own work by seeing which clause it skipped.

```text
PROPOSITION  P#  · <name>
  CLAIM      <the sentence itself>
  EVIDENCE   <what in the SMT2 record makes this more than an opinion>
  FORBIDS    <the concrete move this rules out>
  REQUIRES   <the concrete move this obliges>
  FEEDS      <which heuristic / logics section rests on it>

THOUGHT      T#  · <name>
  TRIGGER    <the situation that should invoke this pattern>
  I HOLD     <the belief being worked on>
  I ASK      <the question that advances it>
  I ACCEPT   <the exit condition that means the thought succeeded>
  I REJECT   <the exit condition that means the belief is dead>
  BECAUSE    <the proposition it derives from>
  YIELDS     <the artifact handed to the next stage>

JUDGEMENT
  GIVEN      <premise>
  AND        <premise>
  THEN       <conclusion>
  UNLESS     <defeater>
  BECAUSE    <the proposition that licenses the inference>
```

Two conventions, both load-bearing:

- **A sentence containing a proper noun is a draft.** Addresses, register names, OpenSBI symbols and
  package names are permitted in `EVIDENCE` and forbidden in `CLAIM`, `THEN` and `YIELDS`. This is
  the mechanical form of "retrospective abstract accuracy".
- **`I REJECT` is mandatory.** A thought pattern with no rejection condition is a rationalisation.
  The SMT2 record's most expensive habit was holding a belief that could only be *weakened*, never
  falsified — the exemption list that grows a clause per soak.

---

## 2. The foundation — seven propositions SMT2 paid for

### P1 · The workload is a witness, never a controller

```text
PROPOSITION  P1 · Witness, not controller
  CLAIM      Firmware demonstrates what must be true; it never decides what to change.
  EVIDENCE   OpenSBI is ordinary RV64GC — it contains no knowledge of SMT, of issue width,
             or of fetch geometry (`firmware-boot-principles.md` §0). Therefore every SMT2
             failure under OpenSBI is a failure to implement RV64GC, not a failure to
             accommodate OpenSBI. Using the cookie as a search signal instead of a gate is
             what produced ~380 increments and ~314 recorded negatives.
  FORBIDS    Special-casing a PC, a symbol, an encoding, or a register pair.
             Editing firmware so that it stops exercising a defect.
  REQUIRES   Every contract must be restatable for firmware that has never been compiled.
  FEEDS      H1 (archetype lift) · H6 (red lines) · logics §1 (obligation extraction)
```

The sharpest consequence is easy to state and hard to obey: **if a change makes OpenSBI pass but
would make a legal program that nobody has written fail, the change is wrong even though the soak
is green.** SMT2 produced at least one live instance of this — see §9.2.

### P2 · The residual lives in the product of the axes, not in any factor

```text
PROPOSITION  P2 · Product, not factor
  CLAIM      For axes {threads T, issue I, compression RVC, fetch width FW}, a residual is a
             property of the tuple. A test that varies one axis samples a face of the cube,
             not the cube.
  EVIDENCE   ~1600 predicates in the g1* frontend were gated `SuperscalarEn && NrHarts>1`
             while the geometry that explains them is `SuperscalarEn && RVC` (RC2). Minis
             that exercise a single factor pass while the firmware fails — `mini_fetch_straddle`
             (straddle alone) passes; `mini_fdt_rdxrs1` (rd==rs1 alone) passes; the pin stands.
  FORBIDS    Gating on the axis that happens to be set in the failing package.
             Concluding "not this class" from a single-factor mini that passes.
  REQUIRES   Every gate is justified by an explanation (I28), and every mini names its
             co-factors explicitly — including the ones it does NOT provide.
  FEEDS      H1 · H2 (envelope proofs) · logics §4 (`minimal_config_gate`)
```

### P3 · Speculation's whole contract is invisibility, and its channels are enumerable

```text
PROPOSITION  P3 · Six visibility channels
  CLAIM      Speculation is correct exactly when it is architecturally invisible. There are
             six channels through which it can become visible, and they are a CLOSED list.
  EVIDENCE   Every SMT2 speculation residual in the record is one of these six; none is a
             seventh. The list is I13–I18 restated as an audit.
  FORBIDS    Treating a speculation bug as novel before the six have been checked.
  REQUIRES   For any change touching squash, flush, forwarding, restore or leftover:
             walk all six and state which are affected.
  FEEDS      H1 · H5 (layer assertions) · logics §5 (vetoes N2, N7, N8, N9, N11)

  CHANNEL 1  a squashed operation performs an architectural write        (I15)
  CHANNEL 2  a non-squashed operation omits a required write             (I15)
  CHANNEL 3  state survives a kill that should have consumed it          (I3, I13)
  CHANNEL 4  state is killed that the architecture still needed          (I3, I9)
  CHANNEL 5  a control decision reads a speculative or forwarded VALUE   (I17, I19)
  CHANNEL 6  an ordering becomes observable to another hart              (I18, I24)
```

This is the most reusable artifact in this document. It converts "speculation bug" from an open
category into a six-row checklist, and it is why the `g6lc_sb_keep` exemption list was doomed: an
exemption list is an attempt to patch channels 1 and 2 one instruction at a time, while the actual
defect is a wrong squash *window* — a channel-3/4 problem that no per-register clause can reach.

### P4 · A promise broken between two modules is discovered at a third

```text
PROPOSITION  P4 · Non-local discovery
  CLAIM      The distance between where a contract breaks and where it is observed is the
             single largest cost multiplier in this project.
  EVIDENCE   A realigner→queue promise broke and was observed as a firmware store fault three
             layers and ~10M cycles later; iter-014 attributed the same pin successively to
             the write-buffer, to load write-back, and finally to a 32-bit fetch straddle.
  FORBIDS    Reasoning about components. ("The realigner looks wrong.")
  REQUIRES   Reasoning about promises. ("Who promised what to whom, and which promise is
             violated in this trace?") Then instrumenting the promise, not the component.
  FEEDS      H4 (determinism) · H5 (blame locality) · logics §3 (`route_blame`)
```

### P5 · Identity is a proof obligation, not a comment

```text
PROPOSITION  P5 · Identity is proof
  CLAIM      "Config-gated, so the baseline is safe" is a claim requiring evidence, and it is
             a claim about the NETLIST, not about intent.
  EVIDENCE   I26–I28. Reducing a knob to baseline must yield a bit-identical baseline netlist;
             behaviour gated on a parameter must be EXPLAINED by that parameter.
  FORBIDS    Treating a config gate as a licence. A red line under `NrHarts>1` is still a red
             line; it merely defers the bill to the day that configuration ships.
  REQUIRES   Identity is checked, and the gate is justified — two separate obligations.
  FEEDS      H2 · H6 · logics §4 (`si_identity`) and §5 (admission test)
```

### P6 · Information is purchased, not found

```text
PROPOSITION  P6 · Buy the cheapest discriminator
  CLAIM      An experiment has a price and an expected yield. The discipline is portfolio
             selection, not persistence.
  EVIDENCE   The A/B flavour pair (same ELF, `--flavour legacy` vs `--flavour B`) is nearly
             free and partitions the hypothesis space into "fetch" vs "not fetch" — the
             largest single partition available. It was frequently run after RTL was written
             rather than before.
  FORBIDS    Running the most familiar experiment. Running the most complete experiment first.
  REQUIRES   Before any run: state the partition it will induce and its price. If a cheaper
             experiment induces the same partition, run that one.
  FEEDS      H4 · H7 (hatch budget) · logics §10 (`information_per_hour`)
```

### P7 · An unrecorded negative is re-derived at full price

```text
PROPOSITION  P7 · The record is the compiler
  CLAIM      A negative result that is not mechanically re-consumable will be rediscovered.
  EVIDENCE   "Do not stall or fault on a small-non-zero address use" was learned as I4bv, then
             I4ca, then G0, then G1i, then W1 — five reverts, five soaks, one lesson. This is
             why `NEGATIVE.md` is indexed by MECHANISM and not by increment id.
  FORBIDS    Recording a negative as prose in a table nobody greps before proposing.
  REQUIRES   Every negative becomes one of: a property, an assertion, a lint, or a rubric row.
  FEEDS      H6 (red-line executability) · H7 (repayment) · logics §5 (the pruner exists at all)
```

---

## 3. Ten thought patterns

These are the agent's cognitive moves. Each is small, each has a rejection condition, and each hands
a named artifact to the next.

### T1 · Lift — from instance to class

```text
THOUGHT  T1 · Lift
  TRIGGER  a symptom is stated with an address, a register, or a firmware symbol
  I HOLD   a sentence describing what went wrong
  I ASK    "what would have to be true for the observed behaviour to be LEGAL?"
  I REWRITE the sentence, once per step, deleting one proper noun each time
             "s3 became 0x12b2a"
           → "a callee-saved register held a value from the previous frame"
           → "a restore did not observe the youngest store to its own slot"
           → "structure walk: callee-saved liveness across nested calls"
  I ACCEPT when no proper noun remains AND at least two independent witnesses
           exhibit the resulting class
  I REJECT when only the failing program exhibits it — that is a patch, not a class
  BECAUSE  P1 (witness, not controller)
  YIELDS   an archetype  →  H1  →  a contract family
```

### T2 · Promise Location — who owed what to whom

```text
THOUGHT  T2 · Promise Location
  TRIGGER  a fault is observed away from any module that was recently changed
  I HOLD   the trace
  I ASK    "name the two modules between which a stated promise is now false"
  I ENUMERATE the promises on the path, in order, and mark the FIRST that fails:
             I$ → realign   : "the bytes I hand you are the bytes at this address"
             realign → IQ   : "each slot is a whole instruction, in address order"
             IQ → issue     : "I deliver program order; I never reorder or invent"
             issue → EX     : "operands are architectural or transparently forwarded"
             EX → commit    : "squashed means no write; unsquashed means every write"
             commit → arch  : "what I retire is what the ISA says"
  I ACCEPT when exactly one promise is first-false; that pair owns the bug
  I REJECT when two are simultaneously false — then instrument and re-run; a trace
           that cannot order the failures is not yet evidence
  BECAUSE  P4 (non-local discovery)
  YIELDS   an owning interface  →  H5  →  an assertion at that boundary
```

### T3 · Narrow by Contradiction — a belief needs a second consequence

```text
THOUGHT  T3 · Narrow by Contradiction
  TRIGGER  a hypothesis about which mechanism is at fault
  I HOLD   "the fault is <mechanism M>"
  I ASK    "if M were true, what ELSE would be observable that is cheaper to check?"
  I DERIVE a second consequence C, independent of the symptom that suggested M
  I CHECK  C by the cheapest available means
  I ACCEPT M when C is observed
  I REJECT M outright when C is absent — I do NOT weaken M, I replace it
  BECAUSE  P6 (buy the cheapest discriminator) and P7 (a weakened belief is how an
           exemption list is born: I4bw → I4cf added a register per soak because each
           refutation was absorbed instead of accepted)
  YIELDS   a surviving hypothesis, or an eliminated one — both are progress
```

### T4 · Product, not Factor — name the missing co-factor

```text
THOUGHT  T4 · Product, not Factor
  TRIGGER  a directed mini PASSES while the integration still FAILS
  I HOLD   "the mini covers the class"
  I ASK    "which axes does the failing context supply that my mini does not?"
  I LIST   T (a second live thread) · I (a second issue port in the same window) ·
           RVC (a straddle at the exact boundary) · FW (the window that splits it) ·
           context (a live frame, a prior call, a warmed cache set, a peer's traffic)
  I ACCEPT when the grown mini fails — the class is now reproduced OUTSIDE the firmware
  I REJECT the conclusion "not this class"; a passing mini eliminates a SHAPE, never a class
  BECAUSE  P2 (product, not factor)
  YIELDS   a co-factor mini  →  H1 battery  →  a permanent regression
```

### T5 · Visibility Audit — walk the six channels

```text
THOUGHT  T5 · Visibility Audit
  TRIGGER  any change to squash, flush, forwarding, restore, leftover, or commit
  I HOLD   the proposed change
  I WALK   channel 1..6 of P3 and answer each with yes/no/unchanged
  I ACCEPT when every channel is answered AND no answer is "this change makes a control
           decision from a data value" (channel 5 is not a trade-off; it is a red line)
  I REJECT any change that closes one channel by opening another — that is the signature
           of a wrong squash WINDOW being patched at its edges
  BECAUSE  P3 (six channels) and P5 (a config gate does not launder channel 5)
  YIELDS   a channel table attached to the change  →  H6 veto input
```

### T6 · Push Left — minimise the latency of the check

```text
THOUGHT  T6 · Push Left
  TRIGGER  a new invariant, rule, or constraint has been identified
  I HOLD   "this must always be true"
  I ASK    "what is the LEFTMOST stage of §4's ladder at which this can be checked?"
  I MOVE   the check left until it no longer fits, then stop one stage right of that
  I ACCEPT when the check fires before the artifact that would violate it can exist,
           or as early as the state it constrains is available
  I REJECT "we will catch it in the soak" — a soak is the rightmost stage and the most
           expensive place to learn anything
  BECAUSE  P4 (distance is the cost multiplier) and P6 (price the experiment)
  YIELDS   a parameter constraint, an elaboration assert, a bounded property, or an SVA
           — in that order of preference  →  H2 / H5
```

### T7 · Refuse to Special-Case — the unwritten-program test

```text
THOUGHT  T7 · Refuse to Special-Case
  TRIGGER  a candidate change that would make the current failure disappear
  I HOLD   the candidate, stated as a rule
  I ASK    "what does this rule say about a program that nobody has written?"
  I TEST   by substituting an arbitrary legal instruction sequence into the rule
  I ACCEPT when the rule's answer for the unwritten program is the ISA's answer
  I REJECT when the rule's correctness depends on the program being the one in hand —
           even if the soak is green, even if it is config-gated
  BECAUSE  P1 (witness, not controller) and P5 (identity is not a licence)
  YIELDS   either a contract, or an explicit decision to keep searching
```

### T8 · Prove Down — move the verdict toward the definition

```text
THOUGHT  T8 · Prove Down
  TRIGGER  a behaviour whose only verdict today is a firmware run
  I HOLD   the behaviour
  I ASK    "is this a pure function of a nameable tuple?"
  I EXTRACT the tuple; if the answer is yes, the behaviour belongs in a `g6lc_*_pkg`
           function and its rule belongs in a bounded property beside it
  I ACCEPT when a violation would be found by `sby` in seconds at a stated depth
  I REJECT when the tuple cannot be closed — then the behaviour is genuinely stateful and
           belongs at the next stage right (an SVA), not at the soak
  BECAUSE  P4, P6
  YIELDS   `core/<plane>/formal/*_props.sv` + `.sby`  →  H2
```

### T9 · Invalidate Backwards — when the instrument changes, the record moves

```text
THOUGHT  T9 · Invalidate Backwards
  TRIGGER  any change to a classifier, pass criterion, harness, or measurement
  I HOLD   the corrected instrument
  I ASK    "which recorded conclusions were produced by the old instrument?"
  I WALK   the record backwards to the instrument's introduction and mark every count,
           every PASS/FAIL, and — most importantly — every hypothesis that was ELIMINATED
           on the strength of one
  I ACCEPT when each affected claim is re-measured or annotated as superseded
  I REJECT silent re-baselining; the new number is not comparable to the old one
  BECAUSE  P7 (the record is the compiler; a corrupted record compiles wrong beliefs)
  YIELDS   an annotated record  →  H3
```

### T10 · Close the Loop Once — a finding must terminate in an artifact

```text
THOUGHT  T10 · Close the Loop Once
  TRIGGER  any experiment that produced information
  I HOLD   the finding, positive or negative
  I ASK    "what durable artifact prevents this from being learned again?"
  I CHOOSE exactly one: a property · an assertion · a mini · a control · a lint · a rubric row
  I ACCEPT when the artifact is committed and is on a path that runs by default
  I REJECT a note in a table as sufficient — five reverts of one rule is the measured cost
  BECAUSE  P7
  YIELDS   the artifact  →  H7 repayment ledger
```

---

## 4. The feedback-latency ladder

This section is the direct answer to *minimising testing, debugging and feedback*. The ladder is
ordered by the latency between a mistake and its discovery. **A check's value is roughly inversely
proportional to that latency**, and the whole methodology is one instruction: *push left*.

The stages are **named positions on a latency axis, not a sequence to work through.** A given rule
is checked at exactly one of them; the question is always *which one*, never *how far along* one is.

- **L0 — Definition.** Types and parameter arithmetic. Latency to discovery: *zero* — the illegal
  state cannot be written down. Suits widths, derived counts, and mutual exclusion by construction.
  SMT2: `fetch_geo_t` fields derived from `CVA6Cfg` rather than from literals.
- **L1 — Elaboration.** `check_cfg` assertions. Latency: seconds, at compile. Suits the legality of
  a configuration *tuple*. SMT2: `NrHarts ≤ CVA6_MAX_SMT_HARTS` is here; the `NrCores × NrHarts`
  versus PLIC-context bound is **not** — see §7.
- **L2 — Bounded proof.** `sby` over pure functions. Latency: seconds, and exhaustive within the
  envelope. Suits every rule expressible over a closed tuple. SMT2: I1/I3/I5/I7/I8/I12 over
  `g6lc_fetch_pkg` would live here; **no `core/fetch_B/formal/` exists yet**.
- **L3 — Simulation assertion.** `translate_off` SVA at a module boundary. Latency: the cycle it
  happens, in *every* run. Suits stateful contracts that need live neighbours. SMT2:
  `g6lc_fetch_dbg` already *computes* I1 as `ok=` and only prints it.
- **L4 — Directed mini.** One fail-code per phase. Latency: seconds to minutes, and it names the
  phase. Suits archetype coverage with explicit co-factors. SMT2: the `mini_fdt_*` family.
- **L5 — Suite / battery.** Latency: minutes. Suits regression across archetypes. SMT2:
  `soft-ladder-di`.
- **L6 — Firmware integration.** Latency: minutes to hours, for one bit of output. Suits
  *sufficiency* of the whole contract set — and nothing else. SMT2: cookie `51b1babe`.
- **L7 — Peel / hold / TRACE.** Latency: hours, plus permanent debt. Catches nothing that L0–L5
  could not have caught earlier. SMT2: `mk_plat_skip.py`.

```text
JUDGEMENT · the push-left rule
  GIVEN    a rule that must always hold
  AND      the ladder stage S at which it is currently checked
  AND      the leftmost stage S' at which it COULD be checked
  THEN     the work item is "move the check from S to S'", not "run S again"
  UNLESS   S' cannot express the rule without inventing state it does not have
  BECAUSE  P4 — the distance between violation and discovery is the cost multiplier
```

**Where SMT2 actually sits.** The three most-used stages in the record are L4, L6 and L7. L2 does not
exist for fetch at all, and L3 exists only as printing. That ordering — heavy on the two most
expensive stages, absent at the two cheapest — is a complete explanation of the 380-increment cost,
and it is repairable without any new idea, only by moving existing knowledge left.

---

## 5. How the three documents compose

```text
              ┌──────────────── this file ────────────────┐
              │  P1..P7  propositions   T1..T10  thoughts │
              └───────┬───────────────────────┬───────────┘
                      │ justifies             │ operationalises
                      ▼                       ▼
     …-g6lc-opensbi-dev-heuristics.md   …-smt2-opensbi-dev-logics.md
        H1 lift        ← T1, P1/P2           §1 obligation   ← T1
        H2 contract    ← T6, T8, P5          §2 obligations  ← P1 witness protocol
        H3 oracle      ← T9, P7              §3 route_blame  ← T2 (and is REPLACED by T2+H5)
        H4 determinism ← T3, P6              §4 propose      ← T7
        H5 locality    ← T2, P4              §5 pruner       ← P3, P7
        H6 red lines   ← T5, T7, P1/P5       §6 verdicts     ← T9, P6
        H7 amortize    ← T10, P7             §7 stages       ← P6
                      │                       │
                      └───────────┬───────────┘
                                  ▼
                    SystemVerilog in core/** and corev_apu/**
```

| If an agent is about to… | Read | Then |
|---|---|---|
| write RTL | T5, T6, T7 here | H2, H6 |
| explain a failing soak | T2, T3, T9 here | H3 → H4 → logics §3 |
| add a feature | T1, T4 here | H1 → H2 → logics §9 |
| decide whether to peel | T10 here | H7 |
| audit someone else's change | P3 channel table, P5 | H6 |

---

## 6. Reasoning transcript A — a `core/` change (instruction supply)

An end-to-end trace of an agent thinking in SPC, from a firmware symptom to the *shape* of a
SystemVerilog artifact. The point is the reasoning, not the diff.

```text
INPUT   a peeled OpenSBI soak stops with the next PC fixed at the upper half of a
        32-bit branch whose lower half begins two bytes earlier

T1 Lift
  I HOLD   "npc is stuck at the second half of a 32-bit op"
  I REWRITE → "an instruction was presented at an address that is not its start"
            → "instruction supply violated address→bytes agreement at a straddle"
  I ACCEPT  witnesses: `lib/utils/libfdt/fdt.c:165` (tag-dispatched walk, densely RVC)
            and `lib/sbi/sbi_string.c:43` (byte loop, same alignment freedom).
            Two independent witnesses ⇒ archetype W1/W4, not an instance.
  YIELDS   archetype = structure walk / byte walk

T2 Promise Location
  I ENUMERATE  I$→realign holds (the bytes at that address are correct in memory)
               realign→IQ FAILS  (a slot is not a whole instruction)
  I ACCEPT     owning interface = realign→IQ
  YIELDS       the assertion site, before any fix exists

T4 Product, not Factor
  I ASK    a straddle-only mini already passes — which co-factors does firmware add?
  I LIST   RVC density before the straddle · a live call frame · I=2 in the same window
           · T=2 peer traffic · a prior window that was killed
  YIELDS   the grown mini's specification (co-factors are stated, not assumed)

T8 Prove Down
  I ASK    is "may this carried halfword complete here?" a pure function?
  I EXTRACT tuple = {this window's address, carry address, carry halfword, valid}
  I NOTE   `core/fetch_B/g6lc_fetch_pkg.sv` already exposes exactly this shape
           (`leftover_complete`, `leftover_next`, `rvi_prefix`, `leftover_drop`)
  I ACCEPT depth = 2 windows ⇒ bounded, provable
  YIELDS   core/fetch_B/formal/g6lc_fetch_align_props.sv  +  .sby   (mirroring
           core/ooo/formal/, which already runs under verify.formalTasks)

T5 Visibility Audit
  channel 3 (state survives a kill)   : affected — leftover across flush
  channel 4 (state killed too early)  : affected — leftover across a foreign window
  channel 5 (control from a value)    : MUST BE NO
  channels 1,2,6                      : unchanged
  YIELDS   the two properties that must both hold, and the one that must not be violated

T7 Refuse to Special-Case
  I TEST   "would this rule be correct for a program nobody has written?"
  I ACCEPT only a rule phrased over the tuple; any phrasing that mentions a PC dies here

T6 Push Left
  L2  the two properties above (seconds, exhaustive)
  L3  an SVA at realign→IQ: every emitted slot's bytes equal memory at its own PC
      — note this value is ALREADY COMPUTED for display as `ok=` in `g6lc_fetch_dbg.sv`
  L4  the grown co-factor mini
  L6  firmware once, as a gate
  YIELDS   four artifacts, of which only the last needs the firmware
```

**Shape of the resulting SystemVerilog** — a contract, its proof, and a call site; no new module,
no new port, nothing that reads a value:

```systemverilog
// core/fetch_B/g6lc_fetch_pkg.sv — the contract IS the function (already the local style)
function automatic logic leftover_complete(...);   // tuple only: addr, carry_pc, carry_lo, valid

// core/fetch_B/formal/g6lc_fetch_align_props.sv — self-contained, no core elaboration
//   assert property (complete |-> leftover_next(addr, carry_pc));      // I3
//   assert property (complete |-> rvi_prefix(carry_lo));               // I5
//   assert property (valid && !leftover_next |-> leftover_drop);       // I3 (the I4az class)
// core/fetch_B/formal/g6lc_fetch_align.sby  — mode prove, depth 2..12, smtbmc z3
// build-platform/src/config/defaults.ts     — verify.formalTasks += that .sby
```

Compare the cost. The historical route to the same three properties was `I4ad`, `I4ae` and `I4az`
— three soaks, one HOLD-FAIL regression of a known-good path, and a revert. The route above is one
`sby` invocation, and it is re-run free on every `verify` thereafter.

---

## 7. Reasoning transcript B — a `corev_apu/` change (interrupt topology)

The same patterns applied to the uncore, where the preconditions in `AGENTS-corev-apu.md` §3 apply
instead of the fetch spec. This transcript ends at **L1**, which is the interesting part: the check
belongs at elaboration, and today it does not exist.

```text
INPUT   planning "raise NrCores while keeping SMT threads"

T1 Lift
  WITNESS  `platform/generic/platform.c:187` — the firmware's durable output from the whole
           FDT walk is a COUNT of enabled `cpu@` nodes (`plat_hc`), obtained via
           `fdt_parse_hart_id` over `/cpus`.
  WITNESS  `lib/sbi/sbi_hsm.c:165` — each of those harts independently enters a wait state.
  I REWRITE → "software harts are counted, not inferred; each needs its own interrupt state"
  YIELDS   archetype W5 (release/acquire) + the topology identity  S = NrCores × NrHarts

T2 Promise Location
  I ENUMERATE  core → CLINT : "one MSIP/MTIMECMP slot per mhartid"
               core → PLIC  : "one M context and one S context per mhartid"
               SoC  → DTS   : "the `cpu@` count I advertise is the count I can service"
  I NOTE   `corev_apu/tb/ariane_testharness.sv:52` sets NR_HARTS = NR_CORES × NrHarts and
           feeds CLINT `.NR_CORES(NR_HARTS)`; line 790 slices the PLIC vector as
           `irqs[2*(c*NR_HARTS_PER_CORE + h) +: 2]` — two contexts per software hart.
  I NOTE   `corev_apu/tb/ariane_soc_pkg.sv:17` fixes `NumTargets = 16`.
  THEN     the PLIC promise is keepable only while 2·S ≤ 16, i.e. S ≤ 8.

T6 Push Left
  I ASK    where is S ≤ 8 checked today?
  I FIND   in prose — `linux-boot-scale.md` §0.4 — and nowhere else.
           `core/include/config_pkg.sv:756` asserts NrCores ≤ CVA6_MAX_CORES (8);
           `:746` asserts NrHarts ≤ CVA6_MAX_SMT_HARTS (2). The PRODUCT is unconstrained,
           so `NrCores=8, NrHarts=2` elaborates cleanly and yields S=16 → 32 contexts
           against 16 targets.
  I ACCEPT the leftmost expressible stage is L1 (elaboration), because both operands are
           compile-time constants. Discovery today would be at L6+ (Linux, wrong CPU takes
           an interrupt) — the maximum possible latency for a constant-foldable mistake.
  YIELDS   a `check_cfg` obligation of the form
             assert (Cfg.NrCores * Cfg.NrHarts <= CVA6_MAX_SW_HARTS);
           NOTE the coupling this exposes: `config_pkg` is core-side and cannot see
           `ariane_soc::NumTargets` (an APU/TB package), so the bound must exist as a
           core-side constant kept in lockstep with the PLIC target count — exactly the
           discipline `ariane_soc_pkg.sv:15-17` already documents for `gen_plic_addrmap.py -t 16`
           and `CVA6_MAX_CORES`. Making the coupling explicit is part of the yield, not a
           complication of it: an implicit cross-package constraint is precisely the kind
           that gets discovered at L6.  Plus the DTS-triple note that the `cpu@` count
           advertised must equal S.

T10 Close the Loop Once
  ARTIFACT the assert, not a sentence in a plan — otherwise P7 applies and the constraint
           will be rediscovered by a boot failure on a future package.
```

**Reported, not changed.** `check_cfg` gaining a product assert is a real (if small) RTL change with
an elaboration-visible effect on any config that currently violates it; that is a decision for the
owner of the topology plan, not a documentation edit. The reasoning is recorded here so the decision
is explicit rather than latent. Same discipline as the fetch transcript: **the document proposes the
check; it does not land it.**

---

## 8. The OpenSBI reading protocol

How firmware source is allowed to enter reasoning, stated once, so both other documents can rely on
it.

```text
JUDGEMENT · admissible use of an OpenSBI locus
  GIVEN    a location L in the OpenSBI tree
  THEN     L may be used to ESTABLISH that an archetype occurs in real firmware
  AND      L may be used to BOUND an obligation (how deep, how many, how often)
  AND      L may be cited in EVIDENCE
  UNLESS   the use would let a PC, symbol, encoding, or register reach a contract body,
           an RTL predicate, or a test's pass criterion — those uses are inadmissible
  BECAUSE  P1
```

The four legitimate questions to ask of firmware, and the four illegitimate ones:

| Ask | Do not ask |
|---|---|
| *What class of program is this?* | *What address fails?* |
| *How deeply does it nest / how often does it repeat?* | *Which register holds the pointer?* |
| *What does it assume the ISA guarantees?* | *What encoding can I special-case?* |
| *What single value proves the whole activity succeeded?* | *How can I make this program stop failing?* |

The fourth left-hand question is the most underused and the most valuable. For the FDT walk it has a
precise answer — `platform.hart_count`, written once at `platform/generic/platform.c:187` — which is
why `plat_hc == 2` is worth more as an observable than any number of intermediate PCs.

---

## 9. Failure modes of the reasoning itself

### 9.1 The four meta-patterns

| Meta-failure | Signature | Corrective thought |
|---|---|---|
| **Belief weakening** | a predicate gains a clause after each refutation | T3 — refutation means *replace*, not narrow |
| **Component thinking** | the discussion names modules, not promises | T2 |
| **Instrument trust** | a count is quoted without asking what "pass" meant | T9 |
| **Local relief** | the pin moved, so the change is kept | T7 + P6 — a moved pin is one bit |

### 9.2 The live instance worth studying

The clearest worked example of P1 and P5 failing together is currently in the tree, and it is
instructive precisely because every individual step looked reasonable:

1. A commit-stage filter suppresses architectural register writes whose *value* looks wrong
   (`core/commit_stage.sv:464-485`, gated `SuperscalarEn && NrHarts>1`). It is the class listed as an
   ISA red line in `../firmware-boot-principles.md` §E and repeated in `../core-fetch/VALUES.md` §2.
2. Because it is config-gated, P5's "identity is not a licence" was not applied.
3. Because the pin moved, T7's unwritten-program test was not applied.
4. The bill arrived one layer away: `corev_apu/bootrom/bootrom.S` now writes `addi s0, x0, 1`
   instead of `li s0, 1`, with a comment naming the filter — P1 inverted, firmware edited to
   accommodate RTL.

Run through the patterns, it is caught three times before it lands: T5 channel 5 (a control decision
from a data value) is a red line, not a trade-off; T7 asks what the rule says about a program nobody
wrote (it silently drops a legal write); T6 notes the rule is not expressible over any closed tuple,
which is itself the tell that it is a filter rather than a contract.

---

## 10. Agent quick-reference card

```text
BEFORE READING A TRACE
  T9  did the instrument change?  if yes, the record is unknown until re-measured
  T3  what is the second consequence of my hypothesis, and is it cheaper to check?

BEFORE WRITING RTL
  T1  is my sentence free of proper nouns, and do two witnesses show the class?
  T5  which of the six visibility channels does this touch?  (channel 5 is a veto)
  T7  what does this rule say about a program nobody has written?
  T6  what is the leftmost ladder stage that can check this?

BEFORE RUNNING ANYTHING
  P6  what partition does this run induce, and is there a cheaper run with the same one?
  T2  which promise, between which two modules, will this observe?

AFTER ANY RESULT
  T4  if a mini passed and integration failed, name the missing co-factor
  T10 what durable artifact stops this from being learned twice?

NEVER
  P1  edit firmware to accommodate RTL
  P3  make a control decision from a data value
  P5  treat a config gate as permission
  P7  record a negative only as prose
```

---

**Related:**
[`AGENTS-smt2-opensbi-dev-logics.md`](AGENTS-smt2-opensbi-dev-logics.md) (the SMT2 procedure) ·
[`../AGENTS-g6lc-opensbi-dev-heuristics.md`](../AGENTS-g6lc-opensbi-dev-heuristics.md) (the weighted heuristics) ·
[`../firmware-boot-principles.md`](../firmware-boot-principles.md) (R1–R12, I1–I28, §E red lines) ·
[`../core-fetch/SPEC.md`](../core-fetch/SPEC.md) · [`../core-fetch/NEGATIVE.md`](../core-fetch/NEGATIVE.md) ·
[`soft-ladder/README.md`](soft-ladder/README.md) · [`soft-ladder/CONTRACT.md`](soft-ladder/CONTRACT.md) ·
[`testharness-proxy.md`](testharness-proxy.md) · `AGENTS-corev-apu.md` (uncore preconditions) ·
`AGENTS-coding-philosophy.md` · `AGENTS.md` §0 (SoC prime directive — nothing here relaxes it).
