# Runtime learning philosophy — evidence, reasoning patterns and bounded capability improvement

**Status: preliminary methodology, not an implemented learner or an AGI claim.**
This document generalizes the LibreCore reasoning guides into a philosophy of
learning during technical work. The `AGI` suffix names a research aspiration
about transfer across problem classes; neither this document nor the traces
establish general intelligence, consciousness, autonomous model training or
unrestricted self-modification.

**North star:** learn a better way to ask, distinguish, check and remember — not
merely a more persuasive explanation of the last outcome.

## 0. Sources, scope and authority

The source of record is [`AGENTS-coding-philosophy.md`](AGENTS-coding-philosophy.md),
particularly correctness before performance, verification parity and §2.9. The
repository uses that filename, not `AGENTS-code-philosophy.md`.

| Lens | Actual source | Structure retained here |
|---|---|---|
| Engineering obligations | [Coding philosophy](AGENTS-coding-philosophy.md) | Correctness, explicit contracts, timing/cost, verification and documented trade-offs |
| Foundation | [Reasoning-pattern workflow](architecture/multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md) | `PROPOSITION`, `THOUGHT`, `JUDGEMENT`; rejection conditions; visibility audit; feedback-latency ladder |
| Heuristic selection | [Firmware-development heuristics](architecture/AGENTS-g6lc-opensbi-dev-heuristics.md) | Archetype lift, oracle validity, determinism, locality, executable constraints and amortized learning |
| Situated procedure | [SMT2 development logics](architecture/multi-threading/AGENTS-smt2-opensbi-dev-logics.md) | Obligation → observable → owner → candidate → discriminator → retained artifact |
| Current evidence | [Fetch review](architecture/core-fetch/README.md), [cache review](architecture/l2-l3-cache/README.md) | Scope-qualified findings and recorded counterexamples, not inferred maturity from a feature list |

These are methodological lenses, subordinate to [`AGENTS.md`](AGENTS.md), the
applicable specification, licensing, security and user authorization. Learning
does not authorize changing those constraints. Historical examples in the
source guides are not a substitute for checking current code and evidence.

This document governs proposed reasoning practice, not DUT behavior. It does
not add an RTL learning unit, a PMU event, a production policy, a training
pipeline or an automatic memory-writing service.

## 1. What runtime learning means

Here, **runtime** means the period in which an agent or engineering process is
working with observations and feedback. It does not necessarily mean learning
inside the processor being studied.

| Level | What may change | Evidence required | What it does not establish |
|---|---|---|---|
| L0 — situated adaptation | The current hypothesis, next probe or explanation | A traceable reason to revise the decision | Persistent learning after the session |
| L1 — external memory | A reviewed note, negative case or pattern card | Source, applicability, limitations and invalidation conditions | A change to model weights |
| L2 — procedural improvement | A reusable checker, tool recipe or experiment-selection procedure | Independent tests, non-regression and bounded transfer evidence | General competence outside tested tasks |
| L3 — parameter learning | Parameters of an explicitly implemented learning system | Authorized data, specified objective, versioned training, held-out evaluation and rollback | An automatic consequence of reading traces or writing this file |

L0–L2 can improve the capabilities of an **agent-plus-tools-plus-memory system**
without changing the underlying model. L3 is a separate engineering program;
no such training is implemented or claimed here.

**Reflection** means inspecting an explicit decision record: assumptions,
predictions, evidence, alternatives and outcomes. It is not privileged access
to a model's hidden computations. An explanatory narrative is itself a
hypothesis about the decision, not a reliable recording of internal causation.
Retain concise, inspectable justifications rather than private reasoning dumps.

## 2. Philosophical basis: coherence must answer to evidence

### 2.1 Observation is relational

A trace is not the system itself. It is a projection produced by an instrument,
at a boundary, under a sampling and completion contract. The same numerical
value can mean a request, an acceptance, a response or a committed effect.
Meaning depends on that relationship, not only on the value's plausibility.
The same applies to learned state: an absolute outcome count, a prediction-error
count and a confidence estimate are different objects. A producer that trains
one quantity and a consumer that interprets another can become more consistently
wrong with additional feedback. Audit the training target and consumption rule
together before describing increased stability as learning progress.

### 2.2 Coherence is a constraint, not a feeling

A useful explanation must make identity, order, values and effects agree across
independently checked boundaries. A smooth narrative can be coherent and false.
The stronger kind of coherence survives an observation that was not used to
construct it and explains why a competing account would predict differently.

An earlier observed violation narrows a causal search; it does not guarantee
that its visible location is the ultimate cause. Missing upstream observations,
shared faults and multiple concurrent failures remain possible.

### 2.3 Abstraction should remove accidents, not mechanisms

Replace an incidental address or register name with its causal role: owner,
allocation generation, oldest unissued work, accepted target or observation
window. Do not erase a relevant alignment, privilege, lifetime or ownership
condition merely to make the sentence sound universal.

A good abstraction compresses examples while preserving the conditions that
predict their differences. The smallest statement is not necessarily the most
useful one; a short rule that hides its boundary is overcompression.

### 2.4 Knowledge is revisable; evidence is not rewritten

New evidence can invalidate an old interpretation. Preserve the original
observation and mark the dependent claim superseded. Do not silently replace
an old number, scope or verdict with a more convenient baseline.

An instrument defect invalidates conclusions that depend on that instrument,
not every result in the project. Track the dependency graph: a simulator
runtime defect need not invalidate an independent synthesis or formal result.

### 2.5 Learning is improved discrimination

The unit of progress is a warranted distinction: one hypothesis eliminated,
one interface contract clarified, one applicability boundary discovered, or
one cheaper test made possible. A longer explanation, a moving failure symptom
or a passing output cookie is not by itself capability improvement.

## 3. Propositions

The notation follows the source workflow. `RT-P*` identifiers are labels, not a
schedule or priority score.

```text
PROPOSITION RT-P1 · The instrument is part of the observation
  CLAIM     An outcome is evidence only within an identified observation contract.
  EVIDENCE  The source record contains cookie misclassification, vacuous bounds
            and a host-runtime overwrite despite plausible simulator results.
  REQUIRES  Name the instrument, input identity, boundary, scope and completion test.
  FORBIDS   Treating missing failure text as success, or a timeout as a proof.
  FEEDS     RT-H1, RT-T1

PROPOSITION RT-P2 · Identity precedes correlation
  CLAIM     Events may be related only through an adequate identity and lifetime model.
  EVIDENCE  Hart, transaction ID and allocation generation distinguished instruction
            ownership from the currently active fetch context.
  REQUIRES  Preserve identity through allocation, reuse, cancellation and completion.
  FORBIDS   Joining by temporal proximity, repeated address or reused ID alone.
  FEEDS     RT-H2, RT-T2

PROPOSITION RT-P3 · A hypothesis owes a discriminating prediction
  CLAIM     An explanation becomes more useful when it predicts an observation that
            competing explanations do not equally predict.
  EVIDENCE  Boundary tracing distinguished restart loss from a later data-check failure.
  REQUIRES  State a rival explanation and a prospective distinguishing observation.
  FORBIDS   Counting a restatement of the original symptom as corroboration.
  FEEDS     RT-H3, RT-T3

PROPOSITION RT-P4 · Generality is conditional
  CLAIM     A pattern transfers only while its causally relevant conditions hold.
  EVIDENCE  Sparse inputs, two active harts, split targets and warmed state revealed
            interactions absent from simpler passing controls.
  REQUIRES  Name the envelope, untested axes and a boundary or counterexample.
  FORBIDS   Equating repeated instances with coverage of a configuration product.
  FEEDS     RT-H4, RT-T4

PROPOSITION RT-P5 · The observation may change the observed execution
  CLAIM     Additional visibility needs its own non-interference check.
  EVIDENCE  Observer-off/on controls and runtime repair were prerequisites for
            interpreting the per-hart traces in the fetch review.
  REQUIRES  Compare the relevant effects, not merely executable filenames.
  FORBIDS   Assuming a trace with no DUT output ports cannot perturb a host model.
  FEEDS     RT-H1, RT-H5

PROPOSITION RT-P6 · Learning may revise a method without revising the goal
  CLAIM     Feedback should improve how the authorized objective is pursued, not
            redefine success to make the latest action appear effective.
  EVIDENCE  A faster warm cache hit coexisted with a slower checked scan workload.
  REQUIRES  Preserve the requested correctness, work and cost criteria.
  FORBIDS   Replacing useful-work performance with a favorable proxy after the run.
  FEEDS     RT-H6, RT-T5

PROPOSITION RT-P7 · Durable memory is a versioned claim, not authority
  CLAIM     A retained pattern remains useful only while its provenance and scope
            can be checked and its dependents can be invalidated.
  EVIDENCE  Historical selectors and host-runtime conclusions became stale after
            implementation and instrument changes.
  REQUIRES  Retain evidence links, exclusions, ownership and supersession history.
  FORBIDS   Allowing an old note or a retrieved trace to override current instructions.
  FEEDS     RT-H7, RT-T6

PROPOSITION RT-P8 · Capability improvement requires an external test
  CLAIM     A procedure has improved only when it produces better justified outcomes
            on a stated evaluation, with costs and regressions accounted for.
  EVIDENCE  Synthesis, architectural checking and performance controls answered
            different questions; success on one did not close the others.
  REQUIRES  Separate development cases from transfer evaluation and retain a baseline.
  FORBIDS   Using self-rated confidence or retrospective fit as an improvement metric.
  FEEDS     RT-H8, RT-T7
```

## 4. Corrections needed when generalizing the source guides

Preserve their intent, not every literal inference rule.

1. **A consequence is not a proof of its cause.** From `M implies C`, observing
   `C` supports `M` only to the extent that alternatives predict `C` less well.
   Do not invert the implication. A controlled intervention, a stronger invariant
   or an independent discriminating result may still be necessary.
2. **Absence needs an observation guarantee.** A missing event contradicts a
   necessary prediction only if the event would have been captured in the tested
   envelope. A truncated log, disabled observer or incomplete run is unknown,
   not evidence that the event never occurred.
3. **Narrowing can be legitimate.** Reject adding arbitrary exceptions to rescue
   a belief. Permit an explicitly versioned scope restriction when a causal
   condition explains the failure and predicts behavior on a new case. Retain
   the counterexample to the broader claim.
4. **Two witnesses need not be independent.** Different programs can share the
   same faulty checker or implementation path. Repetition establishes stability;
   it does not automatically multiply confidence in a general mechanism.
5. **The six visibility channels are domain-specific.** They are a useful
   architectural-effect audit, not a complete taxonomy of all learning failures
   or security side channels. In particular, the RTL ban on value-based
   suppression of required effects is not a ban on analyzing values in a learner.
6. **A declared assertion is not automatically informative.** Check reachable
   antecedents, reset behavior, assumptions and fault sensitivity. A bounded
   result applies to its horizon; complete covers and unbounded proof are
   separate claims.
7. **A plausible owner is not a confirmed cause.** A/B routing ranks boundaries
   to inspect. Shared dependencies, interactions and invalid hybrid interfaces
   can prevent a unique attribution from that comparison alone.

These refinements prevent a useful engineering heuristic from becoming an
unjustified universal law.

## 5. The analysis segment as a learning unit

An **analysis segment** is a bounded question-to-decision interval, not an
arbitrary chunk of conversation or a fixed number of tokens. Segment around a
contract, a causal alternative or a measurement boundary.

```text
SEGMENT CARD
  QUESTION        The uncertainty this segment is meant to resolve.
  OBJECTIVE       The authorized outcome and constraints; distinguish hard gates
                  from performance preferences.
  ENVELOPE        System/configuration, workload class, runtime and observation scope.
  INPUTS          Immutable source, executable, workload and trace identities.
  CONTRACT        Expected relation at the boundary, stated independently of the symptom.
  OBSERVATIONS    What was directly captured, including missing or incomplete channels.
  HYPOTHESES      Candidate explanations and their competing predictions.
  DISCRIMINATOR   Next check, expected outcomes and what each would eliminate.
  RESULT          Actual outcome, effect on hypotheses and unresolved uncertainty.
  LIMITS          Unsupported extrapolations and conditions requiring revalidation.
  NEXT ARTIFACT   Test, property, recipe or reviewed pattern that prevents rediscovery.
```

Keep raw observations and derived summaries separate. Reformat a frozen result
from its retained record; do not rerun the source measurement merely to improve
presentation. Maintain separate execution, observation and revision timelines:
a later summary is not an additional experimental trial.

Cross-segment coherence requires explicit dependency edges. A downstream
segment cannot silently treat an upstream hypothesis as a fact. A change to an
instrument, input or contract invalidates the dependent segment conclusions
until their applicability has been reassessed.

## 6. Thought patterns for bounded runtime learning

```text
THOUGHT RT-T1 · Ground the observation
  TRIGGER   A result appears to resolve the question.
  I HOLD    An outcome and a proposed interpretation.
  I ASK     What produced it, what was observable, and did the run complete?
  I ACCEPT  A scoped observation with validated verdict semantics.
  I REJECT  A result that cannot distinguish success from missing evidence.
  YIELDS    An observation record, or an instrument-repair task.

THOUGHT RT-T2 · Reconstruct the relation
  TRIGGER   Several trace channels seem to describe the same work.
  I HOLD    Candidate joins between events.
  I ASK     Which identity, lifetime and ordering rules make those joins valid?
  I ACCEPT  A causal/partial-order account with explicit unmatched events.
  I REJECT  A total timeline inferred solely from timestamps or reused identifiers.
  YIELDS    A boundary map and the earliest established divergence, if one exists.

THOUGHT RT-T3 · Seek an alternative that could win
  TRIGGER   One explanation feels sufficient.
  I HOLD    A favored hypothesis and a rival with different consequences.
  I ASK     What inexpensive observation would make the rival more credible?
  I ACCEPT  A prospective prediction and a result that distinguishes the alternatives.
  I REJECT  A check whose every outcome is interpreted as support for the favorite.
  YIELDS    A revised ranking or a documented inability to distinguish yet.

THOUGHT RT-T4 · Lift, then probe the boundary
  TRIGGER   A local mechanism appears reusable.
  I HOLD    An instance-level rule and its causal conditions.
  I ASK     Which identifiers are incidental, and where should the rule stop applying?
  I ACCEPT  A conditional pattern with an independent transfer test and countercase.
  I REJECT  A slogan that becomes universal by dropping inconvenient conditions.
  YIELDS    A provisional pattern card, not automatic production policy.

THOUGHT RT-T5 · Compare local and aggregate benefit
  TRIGGER   A component metric improves.
  I HOLD    The local result and the original useful-work objective.
  I ASK     What work, traffic, waiting or error moved elsewhere?
  I ACCEPT  An end-to-end comparison with costs and regressions visible.
  I REJECT  A changed denominator, hidden work reduction or favorable proxy substitution.
  YIELDS    A scoped benefit, a regression, or a new cost-attribution experiment.

THOUGHT RT-T6 · Reflect on the method
  TRIGGER   A diagnosis changed or an experiment taught little.
  I HOLD    The recorded prediction and outcome, not a reconstructed success story.
  I ASK     Was the failed step framing, observation, identity, inference or transfer?
  I ACCEPT  One testable correction to the procedure and a case that can refute it.
  I REJECT  A self-evaluation based only on fluency, confidence or eventual success.
  YIELDS    A revised procedure plus a retention/non-regression check.

THOUGHT RT-T7 · Retain only what can be revisited
  TRIGGER   A segment is complete or work is interrupted.
  I HOLD    Its finding, scope and execution state.
  I ASK     What minimum record lets another session reproduce the decision?
  I ACCEPT  A versioned artifact with provenance, remaining uncertainty and resume state.
  I REJECT  An unsupported memory entry, discarded negative, or claim about an unfinished run.
  YIELDS    A resumable task and, where justified, a reusable capability artifact.
```

## 7. Preliminary heuristics and applicability

These are **provisional ordinal priorities**, not learned weights, probabilities
or calibrated scores. The original guide's numerical weights are workflow
conventions; they are not copied into a new domain as empirical calibration.

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---|---|---|
| RT-H1 — Validate before interpreting | New tool, classifier, observer or missing completion evidence | Precondition | Check input identity, completion and positive/negative controls | The observation cannot distinguish the claimed outcomes |
| RT-H2 — Join by ownership and lifetime | Reuse, concurrency, retries or cancellation | Precondition for correlation | Establish the identity tuple and partial order | Matching is only by proximity or repeated value |
| RT-H3 — Buy a distinction | Several explanations fit | High | Choose a check with different predicted outcomes | It merely repeats a settled result or changes several causal dimensions |
| RT-H4 — Preserve the envelope | Reuse of a finding in another context | High | List changed axes and test a plausible boundary case | The transfer relies only on surface resemblance |
| RT-H5 — Move detection closer | Failure observed long after its cause | High when reusable | Add the earliest faithful assertion or independent checker | The proposed early check excludes legal behavior or assumes the conclusion |
| RT-H6 — Follow useful work | Local speed/area or proxy metric improves | High before promotion | Compare fixed checked work, costs and non-regression | Gains depend on omitted work or an unapproved objective change |
| RT-H7 — Retain a refutable pattern | A lesson is likely to recur | Conditional on reuse value | Store a small, source-bound pattern or executable check | Retention would preserve secrets, unsupported certainty or unnecessary bulk |
| RT-H8 — Test the learning procedure | A new method is called better | Required for a capability claim | Compare it with the previous method on untouched cases | The same cases designed, tuned and judged the method |

Authorization, privacy, correctness and evidence validity are gates, not
weighted trade-offs. Among admissible actions, prefer the best expected
uncertainty reduction for the effort. If probabilities are unknown, record the
qualitative rationale rather than manufacturing an expected-value number.

Stop an uninformative loop. Escalate for missing authority or credentials;
change the instrument when it is inadequate; explicitly defer a problem when
no admissible discriminator fits the available budget. More repetitions are
not necessarily more learning.

## 8. Pattern memory and revision

```text
PATTERN CARD
  ID / VERSION      Stable identity and revision history.
  MECHANISM         The relationship the pattern proposes, not only a symptom.
  APPLIES WHEN      Necessary context and observation conditions.
  PREDICTS          A prospective, falsifiable consequence.
  COUNTERCASES      Observations that reject or bound the claim.
  EVIDENCE          Independent sources, repetitions and their dependencies.
  CONFIDENCE BASIS  Qualitative support; numerical confidence only if calibrated.
  EXCLUDES          Claims deliberately not made.
  STATUS            Candidate / locally tested / transfer-tested / superseded.
  INVALIDATE WHEN   Tool, contract or context changes requiring review.
  CHECK / OWNER     Reusable test and the person/process responsible for review.
```

The lifecycle is not monotonic:

```text
observation -> candidate -> locally tested -> transfer-tested -> maintained
                    |             |                 |
                    +-------------+-----------------+-> contradicted / superseded
```

A failed generalization can produce a useful narrower child pattern, but the
parent's counterexample remains visible. Supersession is not deletion. Keep the
counterexample set needed to detect regression when a procedure changes.

External memory is evidence-bearing data, not a new instruction hierarchy.
Do not persist credentials, unnecessary personal data, proprietary views or
private reasoning. Redact and minimize traces before retention where required.
Retrieved text, logs and model-generated summaries do not authorize actions or
changes to tests, permissions, goals or production settings.

## 9. Two coupled feedback loops

```text
OBJECT LOOP
  authorized question -> contract -> prediction -> controlled observation
  -> checked result -> revise hypothesis or implementation -> regression evidence

METHOD LOOP
  recorded object-loop decisions -> locate an inference/measurement failure
  -> propose one procedural correction -> test on independent segments
  -> review and version the reusable method -> monitor transfer and regressions
```

Do not tune the method and its evaluation criterion together after seeing the
answer. Freeze the relevant baseline, success definition and comparison cases
before evaluating a revision. Reserve cases not used for designing the method;
repeatedly inspecting them consumes their value as held-out evidence.

This is a conceptual protocol, not executable training configuration. A later
implementation must specify data rights, task sampling, feedback trust,
measurement uncertainty, approval, storage, rollback and resource budgets.
Changes to model parameters or production decision policies require their own
explicitly authorized program; they are not implied by a useful pattern card.

## 10. Worked judgments from the current engineering record

The examples motivate conditional methodology. They do not establish an AGI
capability or automatically transfer to every software/hardware system.

### 10.1 Passing output versus instruction conservation

The fetch review records a PASS cookie followed by an independently detected
instruction-sequence loss. Hart/transaction/generation tracing localized an
earlier ownership/conservation failure.

```text
JUDGEMENT · completion is not semantic completeness
  GIVEN    A coarse completion marker agrees with its expected value.
  AND      An independent sequence contract detects omitted required work.
  THEN     The completion marker is insufficient for that contract.
  UNLESS   The independent check's identity or observation model is invalid.
  BECAUSE  RT-P1 and RT-P2 separate output plausibility from preserved work.
```

Retain an independent boundary checker, not the universal claim that all
completion markers are useless.

### 10.2 Instrument repair and selective invalidation

The Verilator runtime overwrite required revalidation of native simulation
results, including apparently non-crashing models. Independent formal and
synthesis evidence had different dependencies.

```text
JUDGEMENT · invalidate through dependencies
  GIVEN    An instrument used to produce observations is defective.
  AND      Some conclusions depend on it while others use independent instruments.
  THEN     Suspend the dependent conclusions and revalidate their inputs and outputs.
  UNLESS   Evidence establishes that a particular result is outside the defect's scope.
  BECAUSE  RT-P1 and RT-P7 preserve both skepticism and valid prior work.
```

### 10.3 Warm-hit improvement versus aggregate regression

The cache review's table load becomes a real warm D-cache hit, yet the larger
matched scan control changes from 275,593 to 374,177 reported warm+scan cycles.
The local result and aggregate regression can both be true.

```text
JUDGEMENT · transfer the mechanism, not the headline
  GIVEN    A local operation becomes cheaper under a particular state.
  AND      Reaching or maintaining that state adds costs elsewhere.
  THEN     Predict a conditional benefit, and compare fixed useful work end-to-end.
  UNLESS   The new context preserves neither the state nor the causal path.
  BECAUSE  RT-P4 and RT-P6 keep locality and objective boundaries explicit.
```

Retain the locality question. Do not learn either "caching is always faster"
or "caching is useless" from this pair. A resident-working-set probe tests the
boundary; its actual outcomes and limitations belong in the cache evidence record.
Checking work inside a measured loop also changes that loop's instruction mix and
can hide latency. Functional verification and performance observation therefore
need separately stated contracts, even when the same experiment supplies both.

### 10.4 A proof horizon is not an implementation milestone

The earlier IQ review had a twelve-frame BMC pass with reachability unfinished.
A later strengthened contract passed binary-state temporal induction and its
expanded cover set. That new evidence does not retroactively make the earlier
BMC unbounded, and its reduced geometry still bounds the claim. Retain both
versions rather than collapse them into either universal closure or failure.

An induction counterexample starts from arbitrary proof state and is not
necessarily reachable from reset. Likewise, a binary-state safety proof does
not establish X-propagation behavior. Check the intended state domain, base
case, active assertions and negative controls before changing the model; use
representation changes to express the contract faithfully, not to evade it.

## 11. Evaluating capability improvement by segment

Evaluate the procedure's externally checkable outputs, not a claimed inner
mental state. Before a comparison, specify the task set, adjudication, cost
budget and whether cases are development or transfer cases.

| Analysis capability | Candidate evidence of improvement | Guard against a misleading result |
|---|---|---|
| Framing | More correctly specified contracts and explicit applicability bounds | Do not score verbosity or repeated terminology |
| Observation design | More decisive, complete captures with validated controls | More trace volume is not necessarily more information |
| Identity and causality | Correct ownership joins and fewer unsupported cause assignments | Earliest visible event is not automatically the root cause |
| Experiment choice | More warranted eliminations per bounded experiment cost | Retain failed predictions and abandoned hypotheses |
| Transfer | Correct prospective predictions on untouched configurations/classes | Shared instruments and near-duplicates are not independent transfer |
| Calibration | Confidence labels agree with later adjudicated outcomes | No invented probabilities or retrospective relabeling |
| Retention | Fewer repeated mistakes without new regressions on old cases | Check supersession, stale notes and forgotten counterexamples |
| Efficiency | Same checked work with lower measured cost or earlier faithful detection | Preserve denominator, correctness and tool/runtime provenance |

A future numeric evaluation must define each denominator and uncertainty model.
No thresholds or scores in this preliminary philosophy are production gates.

## 12. Adoption and continuation

1. Start with one segment card for an unresolved, authorized task.
2. Write its prediction and rejection condition before the next experiment.
3. Check the oracle and join events by the correct identity/lifetime tuple.
4. Produce a short evidence-to-decision explanation, with remaining alternatives.
5. Retain one useful test, recipe or reviewed pattern; leave raw evidence linked.
6. Test transfer separately before calling the method a general capability.
7. On interruption, record the run identity and state; resume instead of blindly
   restarting or silently abandoning it.

**Preliminary development agenda:** pilot these cards on trace diagnosis,
configuration validation and performance interpretation; review where the
method itself fails; then decide whether a tool-backed pattern registry is
worth implementing. Do not build an autonomous learner merely because a
philosophy document now exists.

The practical standard is modest and demanding: a future analysis should make
a better, more testable decision because this one happened. If that improvement
cannot be demonstrated, call the result a proposed method rather than learned
capability.
