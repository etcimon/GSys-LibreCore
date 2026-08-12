# AGENTS Bootstrap — forming an in-tree agentic structure that facilitates development

> **Scope:** the **agentic-forming ladder** used inside `riscv-dev/`. A library or runtime checked out here
> arrives as a foreign tree with no agent guide, no articulated interface boundary, and no stated
> invariants. This file says how that tree acquires, **in itself**, an agentic structure that *facilitates
> its own development*: architectural notes produced by analysis, a guider that routes a change to the
> right locus, a recorded green command, and a queue — all in-tree, all self-contained, so that after
> bootstrapping this folder is contextually insignificant to it.
>
> The ladder is **generic**: it presumes no language, build system, package manager, or platform
> abstraction, and treats each as an output of analysis rather than an input. Governance:
> [`AGENTS.md`](AGENTS.md) §0. Method: [`AGENTS-logisplain.md`](AGENTS-logisplain.md). Posture:
> [`AGENTS-philosophy.md`](AGENTS-philosophy.md). The sibling ladder for compilers is
> [`../riscv-compilers/AGENTS-bootstrap.md`](../riscv-compilers/AGENTS-bootstrap.md); the two are
> deliberate duplicates so either folder remains usable if the other is absent.

---

## 1. The idea in one paragraph

Agency over a codebase is not a property of the codebase and not a property of the agent; it is a property
of the *written relation* between them, and the useful form of that relation is not a description but a set
of **architectural notes addressed to the next change**. A library is unactionable to an agent not because
it is large but because nothing states what it promises to its callers, which of its internals are free to
move, where its assumptions about the environment are concentrated, what its configuration surface reaches,
and how one would know a change was safe. The ladder manufactures those statements out of the tree itself,
deposits them **inside the tree** as an `architecture/` note set indexed by the tree's own guider, and
thereby converts the checkout from an object of study into a development surface that carries its own
priors. Emancipation is the final rung: once the surface resolves entirely within the submodule, the
scaffold that produced it leaves the working context.

---

## 2. The ladder

### B0 — Admission (record only what is certain)

Record the **id** the submodule will occupy (lowercase, stable), its **upstream** URL, the **pin** it
tracks, the **mechanism** by which it is present (`submodule`, `snapshot`, `absent` while planned), and the
**one-line purpose** the developer declared. Nothing else. A B0-only artifact is a legitimate `planned`
stub and must say so; it may not contain an interface description, a dependency list, or a build command,
because none has been observed.

### B1 — Inventory (empirical, never presumed)

With the tree present, derive what the codebase is *made of* by looking. Establish the **language census**
— which languages are present, in what proportion, and which carries the library's own logic as opposed to
its tests, bindings, examples, or tooling. Establish the **public interface**: which headers, modules,
exported symbols, or declared entry points constitute the promise to callers, and — the more important half
— where the boundary between promised and internal actually falls, since a library's real difficulty is
usually that the boundary is less clear than its documentation claims. Establish the **build spine**:
configuration entry point, generator or driver, produced artifacts, installation or packaging surface, and
the order in which things must exist. Establish the **dependency graph**: what the tree needs, whether that
need is vendored, submoduled, fetched at configure time, or assumed on the host, which versions are actually
tolerated rather than declared, and which dependencies are optional in name but load-bearing in practice.
Establish the **environmental assumption surface**: where the tree concentrates its knowledge of platform,
architecture, word size, endianness, threading, filesystem, and system interface — because that
concentration, or its absence, determines what porting would cost. Establish the **configuration and
feature-detection surface**: how a build-time or run-time capability decision reaches deep code. Establish
the **test matrix**: what dimensions the project itself tests across, at what granularity, and how one test
is run alone.

Then record the distinguished item, the **green command**: the tree's own invocation — configure, build,
test — quoted verbatim, annotated with which matrix cell it exercised, what it actually did when run, how
long it took, and which part could not be made to work here. A green command that has never been executed is
recorded as *unverified* and is a queue item, not a fact.

### B2 — Reading (Logisplain analysis)

Articulate the tree's internal logic in cohesive prose, following
[`AGENTS-logisplain.md`](AGENTS-logisplain.md). Trace at least one representative journey end to end — for a
library, most usefully a single public entry point followed inward until it reaches whatever the library
treats as primitive — because tracing forces every layer to be observed rather than assumed. Attend to where
the promised interface stops and the internals begin, since that is the seam every future change is measured
against; to which invariants are enforced by construction and which only by convention, since the latter are
what a change breaks silently; to how resources, errors, and failure are handled, since a library's error
behaviour is part of its contract; to how configuration reaches deep code; and to where environmental and
architectural assumptions live, since that is what a port must touch. Read the project's methodology out of
its artifacts rather than its documentation, and record what the analysis could not see rather than falling
silent.

### B3 — Architectural notes (the development substrate, written **for the tree**)

Commit the analysis as an `architecture/` note set **inside the submodule** — `<id>/architecture/` — indexed
by its own `architecture/README.md`. Where the checkout cannot yet be written to, stage the same set at the
scaffold's `architecture/<id>/` and move it in at the first opportunity (§6).

Notes are written to *facilitate development*. Each names an **area**, explains in prose how it works and
what it is responsible for, **locates** that responsibility as concrete files and regions, states the
**invariants** an incoming change must preserve and whether each is held by construction or by convention,
names the **extension points** — where a change of a given kind belongs and what must move with it — and
closes with the **questions left open**. For a library, three notes carry unusual weight: the one describing
the public interface and where its boundary truly falls, the one describing the dependency graph and what it
assumes about its environment, and the one describing the build, packaging, and test matrix, since those
three determine whether any change can be validated at all. A note that does not tell the next agent where a
change goes has described the system without equipping anyone to develop it.

### B4 — In-tree agentic surface (self-contained, carried by value)

Write the submodule's own guider at `<id>/AGENTS.md`, derived from B1–B3 and nothing else: a provenance
block for self-versioning, what the tree is and is not, an index of the notes, a navigate-by-intent map into
its own source, its green command, the invariants a change must not break with each item traceable to a
note, its recorded `riscv_affinity`, and its open questions. Alongside it write the condensed `AGENTS-*`
companions — at minimum a development guide defining a pass and what finished means, and a method note
carrying the reading discipline so later analysis stays consistent.

Two rules make the surface independent rather than tethered. Everything it needs is **carried by value**:
posture, method, and any porting material are written in, never linked upward. And every reference resolves
**inside its own tree**: no `../`, no superproject path, no assumed parent guider.

**Where it is kept is a separate question from where it lives.** By default the surface is written into the
checkout but **left untracked** — present for development, invisible to both the library's history and the
superproject's — so a developer can work this way without committing anything into a project that did not ask
for it. Committing it on a branch is an opt-in. See §6.

### B5 — Queue (in-tree state)

Create `<id>/AGENTS-todo.md`: the **advancement thesis** in one sentence, the **current state** including
what the green command last reported and on which matrix cell, and the **first blocked question**. This is
the submodule's own state from here on; the scaffold's ledger merely points at it.

### B6 — Development passes

The library is developed under its own guider: a pass names its thesis, opens what the in-tree map says to
open, changes the tree in the tree's own idiom, adds or corrects the note for the area it touched, runs the
in-tree green command, and records the outcome — green, or a failure characterised precisely enough that the
next pass starts from a fact. Interface- or ABI-visible movement is stated explicitly, because a library's
callers cannot be re-tested from inside the library.

### B7 — Emancipation

Verify independence against §4, then reduce the scaffold's footprint: remove any transitional
`architecture/<id>/` once its content lives in the checkout, reduce `agents/<id>.md` to a pointer or delete
it, and shrink the ledger row in [`AGENTS-todo.md`](AGENTS-todo.md) to a pointer at the submodule's own queue.
Emancipation does **not** require the surface to be committed: an untracked in-tree surface (§6, mode A)
satisfies the independence test as long as it is complete and self-contained. From
this point the scaffold is **contextually insignificant** to that submodule. If a later pass finds it needs
the scaffold, the defect is a gap in the in-tree surface: complete the missing material in-tree rather than
restoring the dependency.

---

## 3. Staleness (the self-aware part)

An in-tree surface is **stale**, and must be refreshed before it is trusted, when the pin it was authored
against is no longer in effect, when its recorded fingerprint no longer matches the tree, when its green
command no longer exists or no longer behaves as recorded, when the dependency graph has moved, or when its
declared status contradicts what is on disk. Staleness is a **warning, not a failure**: note it, refresh it,
proceed.

---

## 4. The independence test (three questions)

A submodule is **agentic-structurally independent** when all three answers are yes. Does its own `AGENTS.md`,
with the files it references, resolve **every** reference inside its own tree, with no upward path and no
assumed parent document? Does its recorded green command run to its recorded outcome with this scaffold
absent — checked out alone, or with the parent renamed? Do its state and its architectural notes live
**in-tree**, such that the scaffold holds nothing that would be lost? If any answer is no, the submodule is
mid-transition and the missing material is a queue item; the remedy is always to complete the in-tree
surface, never to document the dependency.

Independence is about *location and resolution*, not about version control: a surface sitting in the checkout
untracked (§6, mode A) passes all three questions, because it is in the tree, it resolves within it, and the
scaffold holds nothing. What fails the test is a surface that is *outside* the tree, or one that reaches
upward to be understood.

---

## 5. Templates for the in-tree surface

### 5.1 `<id>/AGENTS.md`

```markdown
# <project> — Agent Guider (repository root)

> **Scope:** entry point for agents working in this repository. Everything referenced here resolves
> inside this tree. Architectural notes live in `architecture/`; live state in `AGENTS-todo.md`.

```yaml
# --- provenance (self-versioning) ---
pin:              <commit sha or tag this surface was authored against>
status:           inventoried | read | agentic | advancing
purpose:          <one line>
languages:        <census: language -> role>
public_interface: <what constitutes the promise to callers>
build_spine:      <configure/build/package driver>
dependencies:     <load-bearing needs and how they are satisfied>
green_command:    <verbatim invocation>
green_matrix:     <which configuration/platform cell it exercised>
green_state:      verified <date, result> | unverified
persistence:      untracked-local | branch <name> | scaffold-staged       # §6; default untracked-local
fingerprint:      { files: <n>, entry_points: [<path>], harness: <path> }
riscv_affinity:   none | latent | declared | active
authored_at:      <ISO date>
last_refresh:     <ISO date>
```

## 0. Prime directive
What must hold for a change here to be acceptable: the public interface as a promise, portability by
removing assumptions rather than adding conditionals, tests in the same pass, the project's own idiom.
(Condensed from analysis; self-contained — no external references.)

## 1. What carries the logic
Which directories and languages hold the real logic versus tests, bindings, examples, tooling.

## 2. Architectural notes
Index of `architecture/` with one line per note. Detail lives there; this file only routes.

## 3. Navigate by intent
| To find / to change... | Open |
|---|---|
| public interface / exported surface | <path> |
| core implementation | <path> |
| platform / architecture assumptions | <path> |
| configuration / feature detection | <path> |
| build, install, packaging | <path> |
| test harness / one test | <path> |

## 4. Green command
Verbatim invocation, which matrix cell it covers, what it produces, observed duration, and any part that
does not work here.

## 5. Invariants (what a change must not break)
Each item traceable to a note in `architecture/`. Interface and ABI items first.

## 6. Target affinity
Recorded affinity and, if engaged, the in-tree note carrying the porting material. If `none` or `latent`,
say so and stop.

## 7. Open questions
Pointer into `architecture/OPEN-QUESTIONS.md` (or the note that carries them), newest first.

## 8. Refresh log
| date | pin | trigger | what changed |
|---|---|---|---|
```

### 5.2 `<id>/AGENTS-development.md`

What a pass is: thesis, reading scope, change in the project's idiom, note added or corrected, green command
run on a named matrix cell, outcome recorded. What "finished" means, including the interface/ABI question and
the green-command question. Scale discipline: one boundary, one option, or one failing test per pass; large
work sequenced into individually green steps.

### 5.3 `<id>/AGENTS-method.md`

The reading discipline in condensed, self-contained form: analysis is cohesive prose grounded in the code;
anything unobserved is marked unobserved in place; a note is addressed to the next change and therefore names
loci, invariants, extension points and open questions; notes are corrected against the tree rather than the
tree against the notes.

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
Cohesive prose: responsibility, what enters and leaves, what callers may rely on.

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

Thesis, current state including the last green-command outcome and matrix cell, blocked question, and a short
log of completed passes with what each established.

---

## 6. Persistence — where the surface is kept (default: untracked in the checkout)

The surface always **lives in the checkout**; how durably it is kept there is a separate, explicit choice
recorded as `persistence` in the provenance block. There are three modes, and the default is the first.

### Mode A — `untracked-local` (default)

The surface is written into the submodule and deliberately **left untracked**, so a developer can use it to
develop the library without adding anything to the library's history or to the superproject's. The submodule
is told to ignore the paths through its **own** local exclude file — not through its tracked `.gitignore`,
which belongs to the upstream maintainers:

```bash
# resolve the submodule's real git dir (a submodule's .git is a file pointing into .git/modules/…)
gitdir=$(git -C <id> rev-parse --git-dir)
printf '/AGENTS.md\n/AGENTS-*.md\n/AGENTS-todo.md\n/architecture/\n' >> "$gitdir/info/exclude"

# keep the superproject quiet about the submodule being "dirty" with untracked content,
# in LOCAL config so .gitmodules (a tracked file) is not touched
git config submodule.<path-to-id>.ignore untracked
```

Three consequences must be handled rather than discovered. **Name collisions**: libraries frequently already
have an `architecture/`, `docs/architecture/`, or a similarly named document root, so check before writing and
fall back to a non-colliding prefix (for example `AGENTS-<id>.md` and `agentic-notes/`), used consistently and
recorded in the guider. **Cleanability**: excluded files *are* removed by `git clean -xdf`, which for a library
with a generated build tree is a routine command; either clean with the paths preserved
(`git clean -xdf -e AGENTS.md -e 'AGENTS-*.md' -e architecture`) or keep a mirror somewhere the developer
chooses. **Portability of effort**: the surface does not travel with a fresh clone, so if it becomes valuable
to more than one person, that is the moment to consider mode B.

### Mode B — `branch <name>` (opt-in)

The surface is committed inside the submodule on a working branch — conventionally `agentic-surface` — which
makes it survive cleans, travel with the checkout, and become reviewable, and which is the precondition for
ever offering it upstream. It is opt-in because it writes into a repository whose maintainers did not ask for
it: choose it when the fork is yours, when several people share the surface, or when the notes have become too
valuable to lose. Never commit it onto a branch that tracks upstream directly.

### Mode C — `scaffold-staged` (fallback)

When the checkout cannot be written to at all — a read-only pin, an unfinished promotion, an undecided branch —
the identical material is staged at the scaffold's `architecture/<id>/` and `agents/<id>.md`. This is the only
case in which those directories should be populated. They hold the same material in the same form, so
relocating them into the checkout is a move rather than a rewrite, and they are removed or reduced to a pointer
at B7. Any material that would be *lost* by deleting the scaffold is material that has not yet been moved.

### Switching modes

Modes are a property of the developer's situation, not of the submodule, and they change freely: A becomes B by
committing the same files on a branch and removing the exclude lines; B becomes A by keeping the files and
dropping the commits; C becomes A or B as soon as the checkout is writable. Whichever mode is in effect is
recorded in the provenance block, because an agent that does not know whether the surface is tracked cannot
reason about whether it will still be there.

---

## 7. Status vocabulary

`planned` — admitted at B0, no checkout. `checked-out` — present, not yet inventoried. `inventoried` — B1
complete, green command recorded (verified or not). `read` — B2–B3 complete, notes committed. `agentic` —
B4–B5 complete, the in-tree guider is the valid entry point. `advancing` — B6 in motion with a live thesis.
`emancipated` — B7 passed the independence test. These words appear in both the in-tree provenance block and
the scaffold ledger; disagreement between the two is itself a staleness signal.

---

## 8. Anti-patterns

Committing the surface into a submodule as a reflex, when the developer only wanted it locally, writes into a
project that did not ask for it; conversely, relying on the untracked default without noting the clean risk
loses the whole reading to a routine `git clean -xdf`. Writing a guider before the notes exist produces a
surface that encodes assumptions and will be trusted.
Importing a plausible architecture from general ecosystem knowledge rather than from the tree hides the local
peculiarities that make a change fail. Recording a green command that was never run turns an open question
into a false fact. Writing an in-tree guider that references the parent scaffold defeats the ladder. Leaving
notes in the scaffold after the checkout became writable keeps the submodule dependent for no reason.
Imposing this folder's layout, language, or test style on a project that does not use them destroys
upstreamability. Adding a platform conditional where an assumption could have been removed makes every future
port more expensive. And treating RISC-V as the reason a submodule exists, when its recorded affinity says
otherwise, redirects effort away from the work that would actually make the tree developable.
