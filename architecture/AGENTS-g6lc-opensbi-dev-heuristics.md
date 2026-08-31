# `g6lc` firmware-driven RTL development heuristics

**Status: methodology.** Generalization of
[`multi-threading/AGENTS-smt2-opensbi-dev-logics.md`](multi-threading/AGENTS-smt2-opensbi-dev-logics.md) (the
SMT2-specific inference procedure) into a **workload-agnostic** loop. Normative law stays in
[`firmware-boot-principles.md`](firmware-boot-principles.md),
[`core-fetch/SPEC.md`](core-fetch/SPEC.md), [`core-fetch/VALUES.md`](core-fetch/VALUES.md),
[`core-fetch/NEGATIVE.md`](core-fetch/NEGATIVE.md) and
[`multi-threading/soft-ladder/README.md`](multi-threading/soft-ladder/README.md). Evidence stays in
[`multi-threading/testharness-proxy.md`](multi-threading/testharness-proxy.md).

**Grounded in**
[`multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`](multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md)
— the philosophy layer these heuristics are derived from (propositions P1–P7, thought patterns
T1–T10, the feedback-latency ladder L0–L7). Each heuristic below names the proposition it rests on;
that file is where the derivation lives.

**Firmware witnesses** cite OpenSBI **v1.5**, commit `455de672`, fetched to
`build-platform/workspace/smt2-linux/opensbi` (gitignored) by
`software/smt2-linux/scripts/fetch-opensbi.sh`.

---

## 0. Thesis — peel, soak and hold are symptoms of late detection

The soft-ladder loop works. It also costs ~380 increments, ~314 recorded negatives, a binary patch
oracle, and a 6-minute firmware soak per decision. None of that cost is intrinsic to the problem;
it is the cost of **detecting a contract violation two abstraction layers and ten million cycles
after it happens**.

```text
   contract violated  ──►  (10M cycles)  ──►  symptom in firmware  ──►  guess  ──►  soak
   ^^^^^^^^^^^^^^^^^                                                              ^^^^
   where the information is                                          where we pay for it
```

Every debugging-shaped tool in the repo exists to bridge that gap:

| Tool | Exists because | Disappears when |
|---|---|---|
| **peel** (`mk_plat_skip.py`) | we cannot get past firmware code we cannot debug | the layer under it is proven |
| **soak** | the verdict lives only in the firmware | the verdict lives in a property |
| **hold** ELF | we cannot prove non-regression | identity + proof + battery do it |
| **TRACE** hunt | the failure does not say where it is | each layer asserts its own contract |
| **cookie** | there is no cheaper completion signal | the battery is the signal, cookie is the gate |

The seven heuristics below are ordered by how much of that gap each one closes. They are stated with
**weighted applicability rubrics** because none of them is free: applying H2 to a five-line change is
waste, and skipping H3 makes every other heuristic unmeasured.

### 0.1 The width ledger (what "reducing wideness" means, quantified)

Let the search width be `W ≈ A × R × C × V`:

- **A — activity count.** Firmware activities treated as *distinct problems*. Historically 12
  (`R1`–`R12`); collapses to 7 archetypes and then to **2** real capability gaps. Closed by **H1**.
- **R — rules per problem.** Candidate rules attempted before one lands. Historically dozens
  (≈1600 `g1*` predicates across 380 increments); collapses to **1** derived function per contract.
  Closed by **H2**.
- **C — configurations re-soaked.** How many named envelopes must be re-run per change.
  Historically 4+; collapses to **1** under identity (`I26`–`I28`). Closed by **H2** and **H5**.
- **V — verdict ambiguity.** Whether a recorded "pass" can mean something else. Historically **>1**
  — a timeout was read as PASS; must be **1**. Closed by **H3**.

These are order-of-magnitude estimates for *ordering work*, not measurements. The honest claim is
narrower and sufficient: **A and R are the two large factors, H1 and H2 are the two operators that
attack them, and V is a precondition that silently multiplies error into everything else.**

---

## 1. How OpenSBI is allowed to be referenced

This is the "retrospective abstract accuracy" contract. It is small, and it is the reason the
pseudo-code below can cite firmware without inheriting firmware's arbitrariness.

```python
# ---------------------------------------------------------------------------
# An OpenSBI location has exactly one role in this methodology: it WITNESSES
# that a workload archetype occurs in real supervisor firmware. It is evidence
# that the archetype matters. It is never the specification of a fix, never a
# target to special-case, and never a value the RTL may know about.
#
# The structural guarantee below is deliberate: `contract_for` reads the
# witness's *archetype* field and then the witness goes out of scope. No
# contract body can reach a file, a line, a symbol, a PC, or a register.
# ---------------------------------------------------------------------------

class Witness:
    """A citation, not a requirement."""
    def __init__(self, locus, archetype, what_it_shows):
        self.locus         = locus          # "lib/utils/libfdt/fdt.c:165"
        self.archetype     = archetype      # W_STRUCTURE_WALK
        self.what_it_shows = what_it_shows  # one clause, no addresses
        self.role          = "WITNESS"      # never "SPEC", never "TARGET"


WITNESSES = [
    # --- W1 structure walk -------------------------------------------------
    Witness("lib/utils/libfdt/fdt.c:165",      W_STRUCTURE_WALK,
            "tag-dispatched offset advance; the tag decides how far to step"),
    Witness("lib/utils/libfdt/fdt.c:18",       W_STRUCTURE_WALK,
            "big-endian header words assembled byte-at-a-time from lbu"),
    Witness("lib/utils/libfdt/fdt_ro.c:394",   W_STRUCTURE_WALK,
            "loop calls a helper that stores through a caller-supplied pointer"),
    Witness("lib/sbi/sbi_heap.c",              W_STRUCTURE_WALK,
            "freelist link chasing: the load's result is the next address"),

    # --- W2 self-armed trap probe -----------------------------------------
    Witness("include/sbi/sbi_csr_detect.h:17", W_TRAP_PROBE,
            "arm mtvec, execute a maybe-illegal op, restore mtvec, inline"),
    Witness("lib/sbi/sbi_expected_trap.S:23",  W_TRAP_PROBE,
            "handler advances mepc by a fixed ilen and mrets"),
    Witness("lib/sbi/sbi_hart.c:771",          W_TRAP_PROBE,
            "the probe is repeated dozens of times back-to-back"),

    # --- W3 indirect dispatch ---------------------------------------------
    Witness("include/sbi/sbi_platform.h:73",   W_INDIRECT_DISPATCH,
            "operations struct of function pointers"),
    Witness("include/sbi/sbi_platform.h:265",  W_INDIRECT_DISPATCH,
            "every accessor is `if (ops->f) return ops->f(...)`"),

    # --- W4 byte-string walk ----------------------------------------------
    Witness("lib/sbi/sbi_string.c:43",         W_STRING_WALK,
            "unbounded byte loop terminated by a data value"),

    # --- W5 cross-hart release/acquire ------------------------------------
    Witness("lib/sbi/sbi_init.c:196",          W_RELEASE_ACQUIRE,
            "peer spins on an acquire load until a release store lands"),
    Witness("lib/sbi/sbi_hsm.c:165",           W_RELEASE_ACQUIRE,
            "per-hart wait state entered before the releaser has run"),

    # --- W6 atomic ticket / reservation -----------------------------------
    Witness("lib/sbi/riscv_locks.c:48",        W_ATOMIC_TICKET,
            "amoadd then spin-load; forward progress required of the AMO"),
    Witness("lib/sbi/riscv_locks.c:22",        W_ATOMIC_TICKET,
            "lr/sc retry loop; the reservation must survive the loop body"),

    # --- W7 reset-time election / self-relocation -------------------------
    Witness("firmware/fw_base.S:48",           W_ELECTION,
            "amoswap lottery decides which hart relocates; losers spin"),
    Witness("firmware/fw_base.S:38",           W_ELECTION,
            "a hart's stack does not exist until its own path writes it"),

    # --- observable of the whole chain ------------------------------------
    Witness("platform/generic/platform.c:187", W_STRUCTURE_WALK,
            "the walk's only durable output is a counted hart total"),
]


def contract_for(witness, geometry):
    """Motivated by firmware; defined without it.

    The assertion is the whole point. If a contract cannot be written after the
    witness goes out of scope, then what is being written is a special case,
    not a contract -- and it will need a peel to survive the next firmware.
    """
    assert witness.role == "WITNESS", \
        "an OpenSBI line may motivate a contract; it may never define one"
    archetype = witness.archetype
    del witness                                  # structurally out of reach
    return ARCHETYPE_CONTRACTS[archetype](geometry)
```

**The test that makes this real:** a contract passes the retrospective-accuracy check if it can be
restated, verbatim, for a firmware that has never been compiled. `"leftover completes only from the
immediately next window"` survives that test. `"keep c.mv s2,a0 through a mispredict"` does not —
and the record shows that family (`I4bw`–`I4cf`, then `G1b`–`G1g`) consumed a dozen increments and
closed nothing.

---

## 2. Archetypes and their contract families

Seven **kinds of workload**, not seven steps. A change is classified into one of them; the number is
an identifier.

- **W1 — Structure walk.** *Shape:* nested calls, pointer-through-argument stores, byte-assembled
  words, values that are offsets before they are addresses. *Contract family:* mixed-length fetch at
  every legal boundary; callee-saved / `ra` / `sp` survive speculation; a restore observes the
  youngest store; **no control decision from a data value**. *Witnesses:* `fdt.c`, `fdt_ro.c`,
  `sbi_heap.c`.
- **W2 — Self-armed trap probe.** *Shape:* arm vector → execute possibly-illegal → restore vector,
  inline, repeated. *Contract family:* precise trap; the vector entry is fetched and consumed before
  anything else can redirect; the probe is delivered whole; no same-cycle pairing of the arming CSR
  with the armed one. *Witnesses:* `sbi_csr_detect.h`, `sbi_hart.c`.
- **W3 — Indirect dispatch.** *Shape:* function-pointer table, one indirect call per service.
  *Contract family:* resolution is never filtered — not by value, not by PMA, not by predictor
  confidence. *Witness:* `sbi_platform.h`.
- **W4 — Byte-string walk.** *Shape:* data-terminated loops over unaligned bytes.
  *Contract family:* identical to W1 — this is why `R4 ≡ R8`. *Witness:* `sbi_string.c`.
- **W5 — Release/acquire handshake.** *Shape:* one hart releases, others spin-acquire.
  *Contract family:* cross-hart ordering plus a **bounded** fetch grant to every ready hart.
  *Witnesses:* `sbi_init.c`, `sbi_hsm.c`.
- **W6 — Atomic ticket / reservation.** *Shape:* `amoadd` ticket, `lr`/`sc` retry.
  *Contract family:* AMO forward progress; the reservation is not clobbered by a squash or an
  unrelated store. *Witness:* `riscv_locks.c`.
- **W7 — Election / self-relocation.** *Shape:* lottery, GOT rewrite, per-hart stack creation.
  *Contract family:* per-hart reset state; a hart with no stack yet is *correct*, not stuck.
  *Witness:* `fw_base.S`.

Two collapses fall out immediately and were, historically, discovered only in retrospect:
**W1 ≡ W4** (so `R4 ≡ R8`) and **W2 ≈ W3** at the redirect layer (so `R3 ≡ R5`). Seven archetypes,
two capability gaps. That is the H1 dividend.

---

## 3. Weighted applicability — how to choose which heuristic to run

```python
# Each heuristic exposes CRITERIA: {name: (weight, predicate)}, weights sum to 1.0.
# score(situation) = sum(w for name,(w,p) in CRITERIA.items() if p(situation))
#
#   score >= 0.70  ->  APPLY        (skipping it is the expensive choice)
#   0.40..0.69     ->  PARTIAL      (apply the cheap half; record why not fully)
#   < 0.40         ->  SKIP         (cost exceeds expected information)
#
# Thresholds are conventions for ordering work, not measurements. Two rules
# override every score:
#   * H3 is a PRECONDITION. If H3 scores >= 0.40 and is not satisfied, every
#     other score is meaningless, because the verdicts they consume are.
#   * H6 is a VETO. A red line is never traded off against convenience.

def rank_heuristics(situation):
    scored = [(h, h.score(situation)) for h in [H1, H2, H3, H4, H5, H6, H7]]
    if H3.score(situation) >= 0.40 and not situation.oracle_validated:
        return [(H3, "PRECONDITION — stop and validate the oracle first")]
    return sorted(scored, key=lambda hs: -hs[1])
```

---

## H1 — Archetype Lift

> **Reason about the workload class, never about the firmware instance.** Lift the OpenSBI locus to
> an archetype (§2), derive the contract from the archetype, and let the firmware serve only as the
> witness that the archetype is real and the final gate that the contract is sufficient.

### Applicability rubric

| Criterion | Weight | Fires when |
|---|---:|---|
| The symptom is expressed with a PC, a register name, or a symbol | **0.30** | the description of the bug contains `0x…`, `sN`, or an OpenSBI function name |
| A previous fix in this area was per-register or per-encoding | **0.25** | the area already has a keep-list, an exemption, or a named-pair clause |
| The same class has surfaced at ≥2 distinct firmware sites | **0.20** | e.g. the walk fails in `next_tag` *and* in `strlen` |
| A capability (not a bug) is being added | **0.15** | new envelope, wider issue, more harts, new extension |
| The change is a mechanical extract with no behaviour delta | **−0.20** | bit-identical refactor |

### Pseudo-code

```python
def archetype_lift(symptom):
    """Turn an instance into a class.

    The loop below is the same 'ask why once more' ladder as the SMT2 logics
    doc, but its exit condition is stronger: not merely 'expressible in CVA6Cfg
    terms', but 'names an archetype that at least two independent witnesses
    already exhibit'. The second witness is what proves the lift is a class and
    not a rationalisation of one bug.
    """
    claim = literal(symptom)                     # instance-level, unusable
    while names_an_instance(claim):
        claim = generalise_once(claim)
        #   "s3 became 0x12b2a"
        #     -> "a callee-saved register held the previous frame's link"
        #        -> "a restore did not observe the youngest store to its slot"
        #           -> "structure walk: callee-saved liveness across nested calls"

    candidates = [a for a in ARCHETYPES if claim_matches(claim, a)]
    if len(candidates) != 1:
        return Undecided("grow the claim until exactly one archetype matches; "
                         "two matches means the claim still mixes layers")

    a = candidates[0]
    corroborating = [w for w in WITNESSES
                     if w.archetype is a and w.locus != symptom.locus]
    if len(corroborating) == 0:
        return Weak(a, "single-witness archetype: treat the contract as "
                       "provisional and do not spend a capability increment "
                       "on it until a second witness appears")

    # The dividend: one contract now covers every witness of this archetype,
    # including firmware not yet written. Every mini generated for `a` is a
    # permanent regression for all of them.
    return Lifted(archetype=a,
                  contract=ARCHETYPE_CONTRACTS[a],
                  battery=generate_battery(a),        # see H5
                  witnesses=corroborating)
```

### Retrospective — what H1 would have changed in SMT2

- `R4 ≡ R8` and `R3 ≡ R5` are stated in `firmware-boot-principles.md` §A *as a conclusion of ~380
  increments*. H1 derives both before the first increment: `fdt` and `strlen` are the same
  archetype (W1/W4); expected-trap and platform ops are the same redirect archetype (W2/W3).
- The `c.mv` pair chase — `I4bw`, `I4bx`, `I4by`, `I4cf`, then `G1b`, `G1c`, `G1e`, `G1f`, `G1g` —
  is nine increments spent enumerating *register pairs* inside one archetype. Under H1 the
  archetype yields **one** contract about callee-saved liveness, and the enumeration never starts.
- `COMPLETION.md` §1 already says "the increment is a *class*, not a GPR". H1 is that rule promoted
  from advice to an entry gate with a corroboration requirement.

### Forward

Adding a capability starts at the archetype table, not at a package. "Enable stream `I=2`" becomes
"which archetypes does dual-issue change the geometry of?" → W1 (leftover present) only → one
VALUES row, one battery re-run. No smt2 pin is involved, which is exactly what
`CONTRACT.md` §6.2 asks for and what a symptom-first approach keeps violating.

---

## H2 — Contract Before Change

> **Write the property, prove it bounded, then implement.** In `core/fetch_B` the behaviour is
> already expressed as pure functions; a pure function with a stated property is a *proof
> obligation*, not a soak candidate.

This is the highest-leverage unexploited asset in the tree. `core/fetch_B/g6lc_fetch_pkg.sv` is
**44 declarations — two structs, seven localparams, and pure `function automatic` bodies**
(`leftover_complete`, `leftover_next`, `leftover_drop`, `rvi_prefix`, `window_accept`, `same_win`,
`next_block`, `arch_src_sel`, `slot_ge_expected`, `packet_upto_cf`, …). There is **no
`core/fetch_B/formal/`**. Meanwhile `core/ooo/formal/` already proves the pattern works in this
repo: four self-contained `*_props.sv` + `.sby` pairs (`mode prove`, `depth 12`, `smtbmc z3`),
wired into `verify.formalTasks` and a `diag-ooo-formal-paths` path-check, explicitly documented as
*"self-contained prop modules — do not require full-core elaboration."*

### Applicability rubric

| Criterion | Weight | Fires when |
|---|---:|---|
| The behaviour is (or can be) a pure function of a named tuple | **0.30** | it lives in, or can move to, a `g6lc_*_pkg` function |
| The property is bounded — a violation is visible within a few cycles | **0.25** | leftover, window accept, redirect priority, packet order |
| The current verdict path is a firmware soak | **0.20** | today the only check is cookie/pin |
| The invariant is already written in English somewhere | **0.15** | `SPEC.md` / `firmware-boot-principles.md` §B rows |
| The behaviour is inherently whole-core / long-horizon | **−0.25** | Linux boot, multi-million-cycle liveness |

### Pseudo-code

```python
def contract_before_change(archetype, geometry):
    """Derive, prove, then wire. Note what is absent: there is no 'propose a
    candidate and see if the pin moves' step. Search is replaced by
    construction, which is the R-factor collapse in the width ledger.
    """
    contract = ARCHETYPE_CONTRACTS[archetype](geometry)

    # 1. STATE. One sentence, no address/register/opcode, plus the exact tuple
    #    the behaviour is allowed to depend on. The tuple IS the port list; if
    #    the implementation later needs a field outside it, that is a design
    #    review, not a patch.
    prop = Property(
        sentence = contract.sentence,
        depends_on = contract.tuple,        # e.g. {addr, carry_pc, carry_lo, valid}
        holds_for = "all inputs in the geometry envelope",
    )

    # 2. PROVE BEFORE IMPLEMENTING. A property provable against an empty
    #    implementation is vacuous; a property that cannot be violated by any
    #    implementation is not a property. Establish the counterexample shape
    #    first -- it doubles as the mini's fail-code.
    cex_shape = smallest_input_that_would_violate(prop)
    assert cex_shape is not None, "vacuous property -- strengthen it"

    # 3. IMPLEMENT AS THE FUNCTION. The pure function IS the design; the
    #    always_comb that calls it is glue. This is what keeps L2/L3 'may drop,
    #    never modify' structurally true rather than reviewer-enforced.
    fn = pure_function(name=contract.name, tuple=contract.tuple, body=derive(prop))

    # 4. BOUND-PROVE, mirroring core/ooo/formal exactly:
    #       core/fetch_B/formal/g6lc_fetch_<layer>_props.sv   (self-contained)
    #       core/fetch_B/formal/g6lc_fetch_<layer>.sby        (mode prove, depth D)
    #       defaults.ts verify.formalTasks += that .sby
    #       defaults.ts diagnostics += diag-fetch-formal-paths
    #    Depth: the property's own horizon (leftover = 2 windows; redirect
    #    priority = 1 cycle; packet order = geo.slots), not a guess.
    result = sby(prop, fn, depth=contract.horizon, engine="smtbmc z3")
    if result.is_counterexample:
        # A CEX at depth<=12 in seconds, with the exact input tuple, replaces a
        # 6-minute firmware soak whose output is a PC and a hypothesis.
        return Reject(fn, cex=result.trace, cost="seconds")

    # 5. Only now does firmware appear -- once, as a gate.
    return Admit(fn, proof=result, integration=RunFirmwareOnce())
```

### Retrospective — what H2 would have changed in SMT2

Every one of these was found by firmware soak and is a bounded property over two windows:

| Increment | Firmware cost | As a property |
|---|---|---|
| `I4ad` — do not complete `{hi, 0}`; require `[1:0]==2'b11` | soak + trapdump | `leftover_complete ⇒ rvi_prefix(carry_lo)` |
| `I4ae` — a same-block replay is not a completion | soak | `leftover_complete ⇒ win_tag(addr) ≠ win_tag(carry_pc)` |
| `I4az` / VALUES `563299f6` — do not keep leftover across a valid non-next window | **HOLD-FAIL**, `plat_hc=80` | `valid ∧ ¬leftover_next ⇒ leftover_drop` |
| `I4y`/`I8` — trap outranks SMT restore | multi-increment | `arch_src_sel` is a total order; one `assert` per pair |
| `I12` — sequential step is one window | `G1fu`…`G1gd`, HOLD-FAIL | `npc = next_block(base)` |

Five families, each a three-line property, each instead paid for with soaks and at least one
HOLD-FAIL regression of a known-good path.

### Forward

`geo.issue 2→4`, `geo.harts 2→4`, stream `I=2`, `RVH` pass-through: each changes the *envelope* of
an already-proven property, so the work is re-proving at a new geometry (seconds) rather than
re-soaking a new package (hours). This is the `C` collapse in the width ledger.

---

## H3 — Oracle Validity First *(precondition)*

> **A pass must be positive evidence of completion, never the absence of a failure string.** Before
> any verdict is consumed, prove the oracle can say both words.

This is not hypothetical. On **2026-08-31** the DI classifier was corrected: it had treated the
harness timeout line `*** SUCCESS *** (tohost = 0)` as a pass. Both the proxy
(`verif/regress/remote/testharness_proxy.py`, now parsing `(tohost = N)` and requiring `1`) and
`verif/regress/soft-ladder-di-regress.sh` (now `grep -qE 'tohost = (0x)?1[^0-9a-fA-F]'`) were
fixed. The corrected suite reports **0/16**, where the previous classifier reported 15/16 and
16/16. The tests had not regressed; **"the test never ran" had been rendered as "the test passed"**
for an unknown span of the record.

### Applicability rubric

| Criterion | Weight | Fires when |
|---|---:|---|
| The pass criterion is a *string match* on harness output | **0.30** | `grep SUCCESS`, `in out_text`, exit-code-only |
| Absence of a failure can produce the pass criterion | **0.30** | timeout, no-write, crash-before-start all look identical |
| The suite has no negative control (a test that must fail) | **0.20** | nothing in the suite proves the oracle can say FAIL |
| Results are being compared across a tooling change | **0.20** | any counted metric spanning a classifier edit |
| The verdict is a hardware assertion firing in-sim | **−0.30** | an SVA cannot be satisfied by absence |

### Pseudo-code

```python
def validate_oracle(suite):
    """Four rules. The first is the one that was violated.

    O1  A pass is POSITIVE EVIDENCE. The test must have written something only
        a completed test could write. 'No failure observed' is not a pass; it
        is indistinguishable from 'never started', 'timed out', 'harness died'.
    O2  Two controls, always. A POSITIVE control that must pass and a NEGATIVE
        control that must fail. An oracle broken in one direction is invisible
        without the control for that direction -- which is exactly how a
        pass-biased classifier survives.
    O3  Changing the verdict INVALIDATES the history recorded under the old
        verdict. Re-measure or annotate; never silently re-baseline.
    O4  Exit code is transport, not verdict. rc==255 is an SSH drop; rc==1 can
        be an rvfi mismatch with tohost still 0. Parse the artifact.
    """
    if not suite.pass_is_positive_evidence():
        return Invalid("O1: pass criterion is satisfiable by absence")

    if suite.run(POSITIVE_CONTROL) != PASS:
        return Invalid("O2: oracle cannot say PASS -- everything reads FAIL")
    if suite.run(NEGATIVE_CONTROL) != FAIL:
        return Invalid("O2: oracle cannot say FAIL -- everything reads PASS "
                       "(the 2026-08-31 class)")

    for prior in suite.recorded_results_before(suite.verdict_changed_at):
        prior.mark("MEASURED UNDER A SUPERSEDED VERDICT -- re-run before citing")

    return Valid(rule="rc is transport; classify from the artifact")
```

### Retrospective and forward

Two consequences follow that are worth stating plainly rather than absorbing quietly:

1. **Scope of invalidation.** Any DI count recorded before 2026-08-31 came from the old classifier.
   `b1-rtl-residuals.md` currently carries "16/16 PASS after `En.order`; previously 12/16 flaky"
   and `linux-boot-scale.md` §5 carries a long table of per-mini PASS/FAIL. Those need re-measuring
   or an annotation before they are used to rule a hypothesis in or out — several of them are
   currently doing exactly that (e.g. "`mini_fdt_rdxrs1` PASS rules out …").
2. **The controls are cheap and absent.** A `mini_must_fail.S` that writes `tohost=3`
   unconditionally, and a `mini_must_pass.S` that writes `tohost=1` in three instructions, cost
   minutes and would have caught this on the day the classifier was written.

Forward, H3 is why the admission gate in H7 runs oracle validation before it runs anything else.

---

## H4 — Determinism Before Attribution

> **Make the symptom repeatable before you explain it.** An explanation fitted to a
> non-deterministic symptom is unfalsifiable, and the record shows it will be replaced by another
> one rather than disproven.

### Applicability rubric

| Criterion | Weight | Fires when |
|---|---:|---|
| The same input yields different pins across runs | **0.35** | pin wanders between soaks |
| A sim-only observer changes the outcome | **0.25** | `+fetch_snap` (a `translate_off` bind with no outputs) makes the hang disappear |
| Runs may share host resources | **0.20** | parallel harnesses, shared SP, thread pools |
| An attribution has already been revised ≥1 time | **0.20** | the blame has moved between layers |
| The failure is a hard architectural trap at a fixed PC | **−0.30** | already deterministic |

### Pseudo-code

```python
def determinism_first(symptom):
    """Sequence matters: every knob here REMOVES a source of nondeterminism
    without changing the DUT. Only after the symptom is stable is any RTL
    hypothesis admissible -- because only then can a hypothesis be refuted.
    """
    for knob in [SingleSimThread(),        # verilator --threads=1
                 OneHarnessAtATime(),      # the proxy's _no_overlap_guard
                 FixedSeedAndCycleCap(),
                 ObserverOff()]:           # snap/TRACE binds removed
        symptom = rerun(symptom, knob)
        if symptom.is_stable_across(N=3):
            break
    else:
        # Not a failure -- a FINDING. A design whose symptom depends on
        # simulator scheduling has a race or an unconstrained X, and that is
        # the bug, ahead of whatever the pin says.
        return Finding("outcome depends on simulation scheduling; "
                       "hunt the race/X before the functional hypothesis")

    if symptom.changed_under(ObserverOff()):
        return Finding("observer effect: an output-less translate_off bind "
                       "altered behaviour -- evaluation-order sensitivity")

    return Stable(symptom, note="attribution is now falsifiable")
```

### Retrospective — SMT2

iter-014 attributed the same pin, in order, to the **write-buffer**, then to **load write-back**,
then — after `verilator --threads=1` fixed `npc0` at `0x800138d8` (the upper half of a 32-bit
`beqz` starting at `0x800138d6`) — to a **`core/fetch_B` 32-bit straddle**. The `+fetch_snap`
observation (an outputs-free `translate_off` bind changing whether `fdt_ro_probe_` completes) and
the overlapping-harness flakiness that motivated `_no_overlap_guard` are the same finding twice.
Under H4 the first two attributions are never written down, and the observer effect is logged as a
race hunt rather than absorbed as noise.

---

## H5 — Blame Locality

> **Each layer asserts its own contract, so the first violated assertion names the layer.** A
> failure that has to be *routed* is a failure that was not instrumented.

`AGENTS-smt2-opensbi-dev-logics.md` §3 contains `route_blame`, a careful decision tree for guessing which
layer broke. H5's claim is that `route_blame` is a workaround: it exists because L1–L4 do not
declare their own contracts in simulation. Once they do, routing is a lookup.

### Applicability rubric

| Criterion | Weight | Fires when |
|---|---:|---|
| The layer has a stated contract with no runtime check | **0.30** | any `SPEC.md` §2–§5 rule / `firmware-boot-principles.md` §B row |
| Symptoms from this layer surface far from it | **0.25** | fetch bug seen as a firmware store fault |
| The layer is on the path of ≥2 archetypes | **0.20** | leftover serves W1, W2, W4 |
| A battery already exists but does not localize | **0.15** | minis pass/fail without naming a layer |
| The check would need whole-core state to evaluate | **−0.25** | not a local contract |

### Pseudo-code

```python
def install_locality(layer):
    """Two artifacts per layer, both cheap, both permanent.

    (a) A translate_off contract assertion at the layer boundary. It fires on
        the cycle of the violation, in EVERY simulation -- minis, directed
        suites, and firmware soaks alike. The firmware soak stops being a
        search signal and becomes what it should be: a very long random test
        that happens to be realistic.
    (b) An archetype battery: for each archetype crossing this layer, the
        smallest program exercising it, with a DISTINCT fail-code per phase so
        the artifact says which clause broke, not merely that something did.
    """
    for rule in layer.contract_rules:            # SPEC 2..5 / principles B
        emit_sva(layer, rule,
                 guard="translate_off",          # never synthesised
                 message=f"{layer.name}: {rule.id} violated",
                 severity="error")               # stop the run at the source

    for a in archetypes_crossing(layer):
        emit_mini(a, layer,
                  phases=contract_phases(a, layer),
                  failcode_per_phase=True,       # tohost value == phase id
                  controls=(POSITIVE, NEGATIVE)) # H3

    return Localized(layer,
                     promise="a violation names this layer on the cycle it "
                             "happens; no TRACE window, no blame router")
```

### Retrospective — SMT2

- `I1` ("decode is a function of bytes and address alone") is checkable at the realigner boundary
  against the I$ line. It is already computed for *display* — `g6lc_fetch_dbg.sv` prints
  `[fetch_slot] … ok=` where `ok` is exactly I1. It is a printed diagnostic where it could be a
  firing assertion; the difference is a debugging session versus a stopped simulation with a name.
- `I3`/`I5`/`I7`/`I8`/`I12` are all local and all currently unasserted.
- Cost of not having them: `NEGATIVE.md` §11 (leftover window) and §1 (unbounded holds) together
  account for ~35 reverts, every one of which violates a rule that is one `assert property` long.

### Forward

Localized layers are what make capability work safe without a hold ELF: adding `geo.issue=4` cannot
silently break I6, because I6 fires in every mini the moment it is violated.

---

## H6 — Red-Line Executability *(veto)*

> **A prohibition that lives only in prose is not a prohibition.** Every ISA red line must have a
> mechanical check, and **if firmware source is edited to accommodate an RTL behaviour, the RTL
> behaviour is the bug and the firmware edit is a peel in disguise.**

### Applicability rubric

| Criterion | Weight | Fires when |
|---|---:|---|
| The change inspects a data value to make a control decision | **0.35** | commit filters, forward-by-value, resolve-by-PMA |
| A document already forbids this class in prose | **0.25** | `firmware-boot-principles.md` §E, `NEGATIVE.md` §7/§8 |
| Firmware or bootrom source was adjusted to suit the RTL | **0.25** | any `.S`/`.c` edit whose comment names an RTL mechanism |
| The behaviour is config-gated so baselines stay identity | **0.00** | *identity is necessary, not sufficient — it does not license a red line* |
| The change is a pure geometry/width parameter | **−0.30** | no ISA-visible behaviour |

### Pseudo-code

```python
def red_line_gate(change):
    """A veto, not a score. Runs in `verify`, before lint.

    The reason this must be mechanical rather than reviewed: the class is
    seductive. Each individual filter is small, config-gated, and demonstrably
    moves a pin. The cost is not local -- it is that the core stops being the
    ISA, and the price is paid later, somewhere else, by someone reading
    firmware that mysteriously must avoid an encoding.
    """
    for line in ISA_RED_LINES:      # firmware-boot-principles.md section E
        if line.matches(change):
            return Veto(line.id, line.rationale,
                        remedy="fix the mechanism that made the filter look "
                               "necessary -- squash membership, forwarding "
                               "transparency, or redirect priority")

    # The corollary, and the cheapest red-line detector in the repo:
    for edit in change.firmware_and_bootrom_edits():
        if edit.rationale_mentions_an_rtl_mechanism():
            return Veto("FW-ACCOMMODATION",
                        f"{edit.path} was changed to avoid {edit.mechanism}. "
                        "The encoding that had to be avoided is legal RISC-V; "
                        "every other program that uses it is still broken, and "
                        "no test will show it.",
                        remedy="revert the firmware edit; the RTL mechanism is "
                               "the defect")

    return Clear()
```

### Retrospective — SMT2, and one live instance

`firmware-boot-principles.md` §E lists, as ISA red lines that CF-0 reverted and that must not be
re-landed: *"Commit value filter — drop `x8` unless 8-byte aligned; drop `x1` if result < 4 KiB."*
`core-fetch/VALUES.md` §2 repeats it ("commit value filters … keep them off B").

`core/commit_stage.sv:464-485` currently implements, under `SuperscalarEn && NrHarts > 1`:

```systemverilog
if (we_gpr_o[p] && commit_instr_i[p].rd == 5'd8   && rs1 != 5'd0
                && commit_instr_i[p].result[2:0] != 3'b0)            we_gpr_o[p] = 1'b0;
if (we_gpr_o[p] && commit_instr_i[p].rd == 5'd1   && fu != CTRL_FLOW
                && commit_instr_i[p].result[XLEN-1:12] == '0)        we_gpr_o[p] = 1'b0;
```

Those two clauses are the §E red lines verbatim. The consequence arrived immediately and is the
corollary in action: `corev_apu/bootrom/bootrom.S` was changed from `li s0, 1` to `addi s0, x0, 1`
with the comment *"Force rs1=x0 so the SMT FDT-compensation commit filter (G1lc) does not suppress
the immediate."* The bootrom is our own code, which makes the edit feel free — but the filter
suppresses a legal RISC-V write for **every** program on that configuration, and only the one
program that was edited will ever show it. Under H6 this is a veto with a named remedy, caught in
`verify`, on the commit that introduced the filter — not discovered later in a bootrom that no
longer boots.

*(Reported, not changed: reverting a live filter is a behavioural RTL decision, not a doc task.)*

### Forward

Mechanizing §E is a short, bounded task: five patterns, an AST or `rg` check over `core/**`, one
`verify` stage, one `diag` entry. It converts the most-repeated failure class in the record from
"remember the rule" into "cannot land".

---

## H7 — Escape-Hatch Amortization

> **Every peel, soak, hold and TRACE must leave behind a permanent artifact that makes the next one
> unnecessary.** An escape hatch used twice for the same archetype without repayment is debt, and
> debt is what a 380-increment record looks like from the inside.

### Applicability rubric

| Criterion | Weight | Fires when |
|---|---:|---|
| A peel / soft stub is about to be added or retained | **0.30** | any `mk_plat_skip.py` site |
| The hatch has already been used for this archetype | **0.25** | second or later use |
| No permanent artifact came out of the previous use | **0.25** | no property, mini, control or lint landed |
| The hatch is the *only* verdict for the change | **0.20** | no battery, no proof |
| First use on a genuinely novel archetype | **−0.25** | exploration is legitimate |

### Pseudo-code

```python
HATCH_REPAYMENT = {
    "peel":  "a mini reproducing the peeled behaviour + the property it violates",
    "soak":  "a bounded property that would have caught it in seconds (H2)",
    "hold":  "an identity check + battery that makes the hold ELF redundant",
    "trace": "a layer assertion at the point the trace was inspected (H5)",
    "cookie":"a positive-control battery signal that does not need firmware (H3)",
}

def use_escape_hatch(kind, archetype, reason):
    """Legitimate, budgeted, and self-liquidating -- in that order."""
    budget[archetype][kind] += 1

    if budget[archetype][kind] == 1:
        return Allowed(kind, owes=HATCH_REPAYMENT[kind],
                       note="exploration; repay before the next increment")

    if not repaid(archetype, kind):
        return Blocked(kind,
            f"{kind} was already used for {archetype} and produced no durable "
            f"artifact. Land {HATCH_REPAYMENT[kind]} first. Repeating the hatch "
            f"buys the same information at the same price a second time.")

    return Allowed(kind, owes=None, note="prior use repaid")


def health(archetype):
    """The metric that says whether the methodology is working. It should fall
    monotonically. If it does not, the loop has reverted to search."""
    return sum(budget[archetype].values()) / max(1, landed_changes[archetype])
```

### Retrospective — SMT2

`soft-ladder/README.md` already encodes the intent ("soft nops/shims are temporary evidence only",
"prefer B1 status `rtl-fixed`", inventory statuses). What is missing is the **budget**: nothing
counts hatch uses per archetype, so a peel can persist across dozens of increments while every
individual decision to keep it looks locally reasonable. `inventory.yaml` is one column away from
being that ledger.

### Forward

The end state stated in `AGENTS-smt2-opensbi-dev-logics.md` §8 — stock OpenSBI, no peels, `plat_hc==2`,
crutches deleted — is exactly `health(archetype) → 0` for every archetype. H7 makes that a tracked
number instead of an aspiration.

---

## 4. The composed loop

```python
def develop(work_item):
    """H1..H7 assembled. Compare with the SMT2 loop it generalizes:
    propose -> prune -> mini -> soak -> peel. Here, firmware appears exactly
    once, at the end, as a gate."""

    # -- precondition ------------------------------------------------------
    if not validate_oracle(work_item.suite).is_valid:        # H3
        return "stop: verdicts are not measurements yet"

    # -- stabilise ---------------------------------------------------------
    symptom = determinism_first(work_item.symptom)           # H4
    if isinstance(symptom, Finding):
        return symptom                                       # race/X first

    # -- lift --------------------------------------------------------------
    lifted = archetype_lift(symptom)                         # H1
    if not lifted.is_single_archetype:
        return "grow the claim; do not build yet"

    # -- construct ---------------------------------------------------------
    change = contract_before_change(lifted.archetype,        # H2
                                    work_item.geometry)

    # -- veto --------------------------------------------------------------
    gate = red_line_gate(change)                             # H6
    if gate.is_veto:
        return gate                                          # non-negotiable

    # -- instrument --------------------------------------------------------
    for layer in change.layers_touched:                      # H5
        install_locality(layer)

    # -- admit -------------------------------------------------------------
    return admit(change,
                 proof      = change.bounded_proof,          # H2
                 identity   = baseline_netlist_identical(),  # I27
                 battery    = lifted.battery,                # H1/H5
                 integration= run_firmware_once(),           # gate, not search
                 hatches    = budget_report(lifted.archetype))  # H7
```

---

## 5. Migration — named capability gaps between here and the loop

**These are definitions of what is missing, not a sprint plan.** Nothing here is scheduled, assigned
or committed; `AGENTS-todo.md` is where work is queued. The dependency order is stated because it is
a property of the items, not because it is an instruction to start at the top.

- **M1 — Oracle controls.** The DI suite and the soak classifier have no positive or negative
  control (`mini_must_pass` / `mini_must_fail`), and counts recorded before 2026-08-31 are not
  annotated as superseded. *Depends on nothing; everything else depends on it.* Scale: hours.
- **M2 — Fetch bounded formal.** `core/fetch_B/formal/` does not exist, though
  `core/ooo/formal/` is the working in-tree precedent and `g6lc_fetch_pkg` is already pure
  functions. Would carry I1, I3, I5, I7, I8, I12, plus `verify.formalTasks` and a
  `diag-fetch-formal-paths` entry. Scale: days.
- **M3 — Red lines as code.** `firmware-boot-principles.md` §E is prose only; the
  firmware-accommodation detector (H6) does not exist. Scale: ~1 day.
- **M4 — Assertions from existing computations.** `g6lc_fetch_dbg` computes I1 as `ok=` and prints
  it rather than asserting it; I3/I5/I7 have no boundary assertion. Scale: hours.
- **M5 — Battery classification.** Minis are not tagged by archetype (§2), so the archetype × layer
  matrix has unknown coverage. Scale: days.
- **M6 — Hatch ledger.** `inventory.yaml` has no escape-hatch column and no `health(archetype)`
  reporting, so H7's trend is invisible. Scale: hours.
- **M7 — Capability work on proven ground.** The state in which increments resume with M1–M6
  discharged; not itself a task.

---

## 6. Anti-heuristics

Things that look like shortcuts and are not. Each has a body count in the record.

| Anti-heuristic | Why it fails | Where it fails in the record |
|---|---|---|
| *"Tighten the trigger condition."* | Both directions fail and there is no stable middle; the premise (that the mechanism is right and only the scope is wrong) is the error | `NEGATIVE.md` §2 — eight settings, all failed |
| *"It's gated on `NrHarts>1`, so the baseline is safe."* | Identity is necessary, not sufficient. A red line under a config gate is still a red line, and it becomes ISA-visible the day that config ships | `commit_stage.sv:464-485` |
| *"The firmware can just avoid it."* | Firmware is a witness, not a variable. Editing it hides the defect from every program that was not edited | bootrom `li s0,1` → `addi s0,x0,1` |
| *"The mini passes, so the RTL is right."* | A mini proves the *shape*; the bug may need the *context*. Grow the mini — do not conclude. And per H3, check what "passes" meant | `mini_fetch_straddle` PASS while the pin stands — a pre-2026-08-31 record, so doubly unsafe to reason from |
| *"More TRACE will find it."* | TRACE shows what happened, not which contract broke. Without a contract, a longer trace is a longer guess | iter-014's three successive attributions |
| *"The pin moved, so we are closer."* | A moved pin is one bit of information. Without a proof it is equally consistent with having displaced the symptom | `I4z` → `I4aa` → `I4ab` → `I4ac` (HOLD-FAIL) |
| *"Cookie green, therefore correct."* | The cookie is one path through one firmware under one set of peels. It gates; it does not certify | `soft-ladder/README.md` "soft default is not success" |

---

## 7. Using this file

| Situation | Entry point |
|---|---|
| A firmware soak just failed | H3 (is the verdict real?) → H4 (is it stable?) → H1 |
| Planning an RTL change | H1 → H2 → H6 → §4 `develop()` |
| Adding a capability / envelope | H1 (which archetypes change geometry?) → H2 (re-prove, don't re-soak) |
| Tempted to add a peel or a soft stub | H7 |
| A prohibition keeps getting re-landed | H6 (make it mechanical) |
| Deciding where to spend the next week | §5 migration table |

**Subordinate to `AGENTS.md` §0.** Nothing here relaxes the carry-over checklist: config gate with a
`check_cfg` assert, `always_ff`/`always_comb` separation, async-active-low reset, timing-impact
note, RVFI/PMU observability, `test_en_i`/`testmode_i` preserved, `.dts` ↔ config ↔ spec alignment.
A heuristic that yields un-synthesizable or un-verifiable RTL has yielded nothing.

**Related:**
[`multi-threading/AGENTS-smt2-opensbi-dev-logics.md`](multi-threading/AGENTS-smt2-opensbi-dev-logics.md) (the
SMT2 instance of this loop) · [`firmware-boot-principles.md`](firmware-boot-principles.md) ·
[`core-fetch/SPEC.md`](core-fetch/SPEC.md) · [`core-fetch/VALUES.md`](core-fetch/VALUES.md) ·
[`core-fetch/NEGATIVE.md`](core-fetch/NEGATIVE.md) ·
[`multi-threading/soft-ladder/README.md`](multi-threading/soft-ladder/README.md) ·
[`multi-threading/soft-ladder/CONTRACT.md`](multi-threading/soft-ladder/CONTRACT.md) ·
[`multi-threading/testharness-proxy.md`](multi-threading/testharness-proxy.md) ·
`core/ooo/formal/` (the in-tree bounded-formal precedent) ·
`core/fetch_B/g6lc_fetch_pkg.sv` (the pure-function surface H2 targets).
