# AGENTS Bootstrap — forming an in-tree agentic structure that facilitates development

> **Scope:** the **agentic-forming ladder** used inside `riscv-compilers/`. A compiler checked out here
> arrives as a foreign tree with no agent guide, no articulated entry points, and no stated invariants.
> This file says how that tree acquires, **in itself**, an agentic structure that *facilitates its own
> development*: architectural notes produced by analysis, a guider that routes a change to the right
> locus, a recorded green command, and a queue — all in-tree, all self-contained, so that after
> bootstrapping this folder is contextually insignificant to it.
>
> The ladder is **generic**: it presumes no language, no build system, no intermediate representation and
> no bootstrap strategy, and treats each of those as an output of analysis rather than an input.
> Governance: [`AGENTS.md`](AGENTS.md) §0. Method: [`AGENTS-logisplain.md`](AGENTS-logisplain.md).
> Posture: [`AGENTS-philosophy.md`](AGENTS-philosophy.md). The sibling ladder for library and runtime
> trees is [`../riscv-dev/AGENTS-bootstrap.md`](../riscv-dev/AGENTS-bootstrap.md); the two are
> deliberate duplicates so either folder remains usable if the other is absent.

---

## 1. The idea in one paragraph

Agency over a codebase is not a property of the codebase and not a property of the agent; it is a
property of the *written relation* between them, and the useful form of that relation is not a
description but a set of **architectural notes that are addressed to the next change**. A large
unfamiliar compiler tree is unactionable because nothing states how meaning, control and data move
through it, which files matter for which intent, what may not be broken, where a change of a given kind
belongs, and how one would know it worked. The ladder manufactures those statements out of the tree
itself, deposits them **inside the tree** as an `architecture/` note set plus a short guider that indexes
it, and thereby converts the checkout from an object of study into a development surface that carries its
own priors. Emancipation is the final rung: once the surface resolves entirely within the submodule, the
scaffold that produced it is no longer part of the working context.

---

## 2. The ladder

### B0 — Admission (record only what is certain)

Record the **id** the submodule will occupy (lowercase, stable), its **upstream** URL, the **pin** it
tracks, the **mechanism** by which it is present (`submodule`, `snapshot`, `absent` while planned), and
the **one-line purpose** the developer declared. Nothing else. A B0-only artifact is a legitimate
`planned` stub and must say so; it may not contain a pipeline description, a file map, or a build
command, because none has been observed. Its value is that the first real analysis has something to
correct instead of something to invent.

### B1 — Inventory (empirical, never presumed)

With the tree present, derive what the codebase is *made of* by looking. Establish the **language
census** — which languages are present, in what proportion, and which carries the compiler's own logic
as opposed to its tests, bindings, or tooling — because the answer governs everything downstream and is
often not the language the project is known for. Establish the **build spine**: configuration entry
point, generator or driver, produced artifacts, and the order in which they must exist. Establish
**entry points**: the executable's `main` or equivalent, the driver that turns a command line into a
compilation, and the boundary where the front end hands over to lowering. Establish the **dependency
surface**: what the tree expects to already exist, whether that expectation is vendored, submoduled, or
assumed on the host, and what versions are actually tolerated rather than declared. Establish the
**bootstrap relation**: whether the tree needs a prior version of itself, a foreign compiler, a checked-in
generated artifact, or a runtime library it will later be responsible for compiling — the property most
likely to dominate a first build and most often absent from the project's own documentation. Establish
the **test harness**: how the project itself decides it works, at what granularity, and how one test is
run alone.

Then record the distinguished item, the **green command**: the tree's own invocation — configure, build,
test, in whatever form the project uses — quoted verbatim and annotated with what it actually did when
run, how long it took, and which part could not be made to work here. A green command that has never
been executed is recorded as *unverified* and is a queue item, not a fact.

### B2 — Reading (Logisplain analysis)

Articulate the tree's internal logic in cohesive prose, following
[`AGENTS-logisplain.md`](AGENTS-logisplain.md). Do not summarise the inventory; explain what it means.
Trace one representative journey end to end — for a compiler, most usefully a single source file from
the driver's argument handling through parsing, semantic analysis, lowering, and emission — because
tracing forces every hand-off to be observed rather than assumed. Attend to where representations
change, since representation boundaries are where a project's real commitments live; to which invariants
are enforced by construction and which only by convention, since the latter are what a change breaks
silently; to how configuration reaches deep code, since that path decides whether a new option is a small
change or a structural one; and to how portable behaviour is separated from target- or platform-specific
behaviour, since that seam is what any later target question will need. Read the project's methodology
out of its artifacts rather than its documentation, and record what the analysis could not see in the same
voice rather than falling silent.

### B3 — Architectural notes (the development substrate, written **for the tree**)

Commit the analysis as an `architecture/` note set **inside the submodule** — `<id>/architecture/` — with
`<id>/architecture/README.md` as its index. Where the checkout cannot yet be written to, the same set is
staged at the scaffold's `architecture/<id>/` and moved in at the first opportunity (§6).

The note set is written to *facilitate development*, not to document for its own sake, and that intent
changes what each note contains. A note names its **area** of the system, states in prose how that area
works and what it is responsible for, locates the small number of files and the specific regions within
them that carry that responsibility, states the **invariants** an incoming change must preserve and
whether each is enforced by construction or by convention, names the **extension points** — where a
change of a given kind belongs, and what else must move with it — and closes with the **questions the
analysis left open**. A note that does not tell the next agent where a change goes has described the
system without equipping anyone to develop it, and should be rewritten.

The minimum viable set, once inventory and reading exist, is an index, an overview note carrying the
representative journey, a note per stage or subsystem the journey passed through, a build-and-bootstrap
note carrying the spine and the green command with its observed behaviour, a dependency note, and an
open-questions note. The set is expected to grow one note per area as passes touch new ground, and it is
expected to be *corrected* whenever a pass discovers it was wrong — a pass that only corrects a note has
produced a real result.

### B4 — In-tree agentic surface (self-contained, carried by value)

Write the submodule's own guider at `<id>/AGENTS.md`, derived from B1–B3 and nothing else. It carries a
provenance block so it can detect its own staleness, states what the tree is and is not, indexes the
architectural notes, gives a navigate-by-intent map into its own source, quotes its green command, states
the invariants a change must not break with each item traceable to a note, records its `riscv_affinity`,
and points at its own open questions. Alongside it, write the condensed `AGENTS-*` companions the tree
needs — at minimum a development guide describing what a pass is and how completion is judged, and a
method note carrying the reading discipline in condensed form so future analysis stays consistent.

Two rules make this surface independent rather than tethered. Everything it needs is **carried by
value**: posture, method and, if affinity engages, target material are written into the submodule in
condensed self-contained form, never linked upward to this folder or this repository. And every
reference it makes resolves **inside its own tree**: no `../`, no superproject path, no assumption that a
parent guider exists. A surface that fails either rule is not yet emancipated.

### B5 — Queue (in-tree state)

Create `<id>/AGENTS-todo.md`: the **advancement thesis** in one sentence, the **current state** including
what the green command last reported, and the **first blocked question** — the smallest thing whose
answer would unblock real work. This is the submodule's own state from here on; the scaffold's ledger
merely points at it. A submodule with no blocked question is either finished or unread.

### B6 — Development passes

The submodule is now developed under its own guider: a pass names its thesis, opens what the in-tree
navigation map says to open, changes the tree in the tree's own idiom, adds or corrects the architectural
note for the area it touched, runs the in-tree green command, and records the outcome — green, or a
failure characterised precisely enough that the next pass starts from a fact. The notes are not a
by-product of this loop; they are the substrate that makes each pass cheaper than the last.

### B7 — Emancipation

Verify independence against §4, then reduce the scaffold's footprint: the transitional
`architecture/<id>/` is removed once its content lives in-tree, the shadow `agents/<id>.md` becomes a
one-line pointer or is deleted, and the ledger row in [`AGENTS-todo.md`](AGENTS-todo.md) shrinks to a
pointer at the submodule's own queue. From this point the scaffold is **contextually insignificant** to
that submodule and must not be re-imposed. If a later pass finds it needs the scaffold, the defect is a
gap in the in-tree surface: complete the missing material in-tree rather than restoring the dependency.

---

## 3. Staleness (the self-aware part)

An in-tree surface is **stale**, and must be refreshed before it is trusted, when the pin it was authored
against is no longer in effect, when its recorded fingerprint no longer matches the tree, when its green
command no longer exists or no longer behaves as recorded, or when its declared status contradicts what is
on disk. Staleness is a **warning, not a failure**: note it, refresh it, proceed. The fingerprint exists
to stop an agent from acting confidently on a description of a codebase that has moved underneath it.

---

## 4. The independence test (three questions)

A submodule is **agentic-structurally independent** when all three answers are yes. Does its own
`AGENTS.md`, together with the files it references, resolve **every** reference inside its own tree, with
no upward path and no assumed parent document? Does its recorded green command run to its recorded
outcome with this scaffold absent — checked out on its own, or with the parent renamed? Do its state and
its architectural notes live **in-tree**, such that the scaffold holds nothing that would be lost? If any
answer is no, the submodule is still mid-transition and the missing material is a queue item; the remedy
is always to complete the in-tree surface, never to document the dependency.

---

## 5. Templates for the in-tree surface

### 5.1 `<id>/AGENTS.md`

```markdown
# <project> — Agent Guider (repository root)

> **Scope:** entry point for agents working in this repository. Everything referenced here resolves
> inside this tree. Architectural notes live in `architecture/`; live state in `AGENTS-todo.md`.

```yaml
# --- provenance (self-versioning) ---
pin:             <commit sha or tag this surface was authored against>
status:          inventoried | read | agentic | advancing
purpose:         <one line>
languages:       <census: language -> role>
build_spine:     <configure/build driver>
bootstrap:       <prior-compiler / self-hosting / none>
green_command:   <verbatim invocation>
green_state:     verified <date, result> | unverified
fingerprint:     { files: <n>, entry_points: [<path>], harness: <path> }
riscv_affinity:  none | latent | declared | active
authored_at:     <ISO date>
last_refresh:    <ISO date>
```

## 0. Prime directive
What must hold for a change here to be acceptable: correctness first, staged invariants, the emitted
artifact as a contract, reproducible bootstrap, tests in the same pass, the project's own idiom.
(Condensed from analysis; self-contained — no external references.)

## 1. What carries the logic
Which directories and languages hold the real logic versus tests, bindings, tooling.

## 2. Architectural notes
Index of `architecture/` with one line per note. Detail lives there; this file only routes.

## 3. Navigate by intent
| To find / to change... | Open |
|---|---|
| driver / argument handling | <path> |
| front-end boundary | <path> |
| lowering / emission | <path> |
| runtime or support library | <path> |
| target or platform description | <path> |
| test harness / one test | <path> |

## 4. Green command
Verbatim invocation, what it produces, observed duration, and any part that does not work here.

## 5. Invariants (what a change must not break)
Each item traceable to a note in `architecture/`.

## 6. Target affinity
Recorded affinity and, if engaged, the in-tree note that carries the target material. If `none` or
`latent`, say so and stop.

## 7. Open questions
Pointer into `architecture/OPEN-QUESTIONS.md` (or the note that carries them), newest first.

## 8. Refresh log
| date | pin | trigger | what changed |
|---|---|---|---|
```

### 5.2 `<id>/AGENTS-development.md`

What a pass is: thesis, reading scope, change in the project's idiom, note added or corrected, green
command run, outcome recorded. What "finished" means, including the artifact/ABI question and the
green-command question. Scale discipline: one boundary, one option, or one failing test per pass;
large work sequenced into individually green steps.

### 5.3 `<id>/AGENTS-method.md`

The reading discipline in condensed, self-contained form: analysis is written as cohesive prose grounded
in the code; anything unobserved is marked unobserved in place; a note is addressed to the next change
and therefore names loci, invariants, extension points and open questions; notes are corrected against
the tree rather than the tree against the notes.

### 5.4 `<id>/architecture/README.md` and the note template

```markdown
# Architectural notes — <project>

Produced by analysis of this tree. Each note is addressed to the next change.

| Note | Area | Written against pin | State |
|---|---|---|---|
```

```markdown
# <area>

## How it works
Cohesive prose: responsibility, how control and data enter and leave, which representation is canonical.

## Loci
`path:line-range` per responsibility, with what each region does.

## Invariants
What must remain true; for each, enforced by construction or by convention.

## Extension points
Where a change of kind X belongs, and what must move with it.

## Open questions
What the analysis did not close.
```

### 5.5 `<id>/AGENTS-todo.md`

Thesis, current state including the last green-command outcome, blocked question, and a short log of
completed passes with what each established.

---

## 6. Transitional artifacts in the scaffold

The scaffold's `architecture/<id>/` and `agents/<id>.md` exist **only** while the in-tree surface cannot
yet be written — a read-only pin, an unfinished promotion, or a checkout whose branch is not yet decided.
They are staging, not the destination: they hold the same material in the same form, so relocating them
in-tree is a move rather than a rewrite, and they are removed or reduced to a pointer at B7. Any material
that would be *lost* by deleting the scaffold is, by definition, material that has not yet been moved.

---

## 7. Status vocabulary

`planned` — admitted at B0, no checkout. `checked-out` — present, not yet inventoried. `inventoried` —
B1 complete, green command recorded (verified or not). `read` — B2–B3 complete, notes committed.
`agentic` — B4–B5 complete, the in-tree guider is the valid entry point. `advancing` — B6 in motion with
a live thesis. `emancipated` — B7 passed the independence test; the scaffold holds only a pointer. These
words appear in both the in-tree provenance block and the scaffold ledger, and disagreement between the
two is itself a staleness signal.

---

## 8. Anti-patterns

Writing a guider before the notes exist produces a surface that encodes assumptions and is worse than
none, because it will be trusted. Importing a plausible pipeline description from general ecosystem
knowledge rather than from the tree hides exactly the local peculiarities that make a change fail.
Recording a green command that was never run turns an open question into a false fact. Writing an in-tree
guider that references the parent scaffold defeats the purpose of the ladder. Leaving the notes in the
scaffold after the checkout became writable keeps the submodule dependent for no reason. Imposing this
folder's layout, language, or test style on a project that does not use them destroys upstreamability for
no gain. Writing notes that describe without locating leaves the next agent to redo the analysis. And
treating RISC-V as the reason a submodule exists, when its recorded affinity says otherwise, redirects
effort away from the work that would actually make the tree developable.
