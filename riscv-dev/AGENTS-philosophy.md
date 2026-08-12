# AGENTS Philosophy — engineering posture for library and runtime work

> **Scope:** how a change to a submodule under `riscv-dev/` is conceived, judged, and finished. It is the
> library-side counterpart of the reading method: [`AGENTS-logisplain.md`](AGENTS-logisplain.md) says how the
> tree is understood, this file says what kind of change that understanding should produce. It sits beside
> (never above) [`AGENTS.md`](AGENTS.md) §0 and presumes nothing about the submodule's language, build
> system, or platform abstraction.
>
> This posture is **carried by value into each submodule** at rung B4 as its own condensed
> `AGENTS-development.md`, so that an emancipated tree holds its own standard and never refers back to this
> scaffold. Where this file says `architecture/` or the guider, it means the submodule's **own** in-tree note
> set and its own `AGENTS.md`.

---

## 1. What is being built

A library exists for code that is not in the repository. Its callers cannot be re-tested from the inside,
cannot see its internals, and did not consent to its assumptions; they consented to its interface. That one
asymmetry sets the standard here. Everything below follows from taking it seriously: the promise is the
product, the internals are free only to the extent that the promise is precisely stated, and the qualities
that protect the promise — a boundary that is actually where it is documented to be, honest failure
behaviour, a test matrix that covers the variability the library claims to support, and a build that works in
settings the maintainers never saw — are not overhead but the mechanism by which the promise survives contact
with a second contributor.

---

## 2. Principles, in the order they bind

**The public interface is a promise, and it is changed deliberately or not at all.** Signatures, semantics,
error behaviour, resource ownership, thread-safety claims, symbol visibility, and — where the language has one
— binary compatibility are contracts. A change to any of them is stated in the terms callers use, with who
breaks and how they migrate; an *accidental* interface change is the most expensive defect available here,
because the library's own tests generally cannot see it.

**Portability is achieved by removing assumptions, not by adding conditionals.** The first response to a new
platform or architecture is to find the assumption that made the code non-portable and delete it. A
conditional is the second-best answer, legitimate when the difference is genuine, and it is placed where the
tree already concentrates such knowledge rather than at the point of use. Every conditional added where an
assumption could have been removed makes the next port more expensive, permanently.

**Correctness before performance, and never silently traded.** A faster path that changes observable
behaviour — including error behaviour, allocation behaviour, and ordering visible to callers — is a semantic
change wearing an optimisation's clothes. Where a trade-off is real it is explicit, gated so it can be turned
off, and written down.

**The dependency graph is part of the design.** Adding a dependency adds everything that dependency assumes,
including its own portability limits and its build requirements; removing one is often the highest-value
change available. Optional dependencies must actually be optional, verified by building without them, and a
dependency that is load-bearing in practice is documented as required regardless of how it is declared.

**Validation is a matrix, and the cell matters.** A library's green state is meaningless without saying which
configuration, feature set, and platform it was green on. A pass records the cell it ran, and a change that
plausibly affects other cells says so instead of implying coverage it does not have.

**Failure behaviour is part of the product.** How the library reports what it cannot do — return values,
exceptions, error codes, diagnostics, partial state after failure — is consumed by callers as much as its
success paths. New failure paths get the treatment the project already gives them, and existing ones are not
degraded in passing.

**Tests in the same pass as the change.** The tree's own harness is the instrument, discovered at inventory
and recorded as the green command. A change lands with a test the harness runs, written in the style the
harness expects, and the pass ends with that command executed on a named cell and its result recorded — green,
or a failure characterised precisely enough that the next pass starts from a fact.

**Upstreamable form as the default posture.** Prefer the change the maintainers would accept: their layout,
their idiom, their naming, their test style. A change shaped like the project is one the project's reviewers
and future refactors will preserve; a foreign-bodied change decays. Divergence is legitimate when directions
genuinely differ, and is then recorded as a divergence with a reason rather than left to be discovered.

**Explicit over implicit, in the tree's own vocabulary.** New behaviour is discoverable through the
configuration path the project already has and named the way the project already names things. Behaviour that
depends silently on build configuration or host state is how a library acquires defects that reproduce only
elsewhere.

**Documented trade-offs, in the tree's own notes.** Anything non-obvious leaves a written trace where the work
is: a corrected paragraph in the note for the area, an invariant line in the tree's own `AGENTS.md` if the
change altered what may not be broken, an extension-point line if it created or moved where future changes
belong, and a queue entry if it left something open. The project's memory is these notes; a decision that is
not in them did not happen, and a note left uncorrected by a change that invalidated it is now actively
misleading.

---

## 3. Scale discipline

Most useful work here is small and sequenced: one interface clarification, one assumption removed, one
previously-failing matrix cell made green. Such a pass can be reviewed and its effect attributed. A pass that
restructures the public interface, replaces the build system, or rewrites the platform layer cannot be
reviewed and cannot be attributed when it breaks; if such work is required, it is planned in the queue as a
sequence of individually green steps with the notes updated at each. The opposite failure is a pass that
touches many files superficially — renaming, reformatting, restyling — consuming the review attention the
substantive change needed and making the history unusable.

---

## 4. Checklist for a finished pass

Before calling a pass complete, state each of these or say why it does not apply: the thesis and whether it
holds; whether anything interface- or ABI-visible moved, and if so who is affected and how they migrate; which
invariants the change touched and how they are still maintained; what the recorded green command reported and
on which matrix cell; which other cells are plausibly affected and untested; the test that now covers the
change and the harness that runs it; whether the change is in the project's idiom or is a recorded divergence;
which in-tree notes and which lines of the tree's own guider were corrected; and what the next blocked question
is. A pass that cannot answer the interface question or the green-command question is not finished, regardless
of how convincing the diff looks.

---

## 5. On targets

Nothing in this posture is target-specific, and nothing in it assumes a submodule has a target story at all. A
pass may improve a library's interface clarity, its dependency footprint, its failure behaviour, or its build
portability indefinitely without an architecture question arising. When one does arise — because the
submodule's declared purpose reaches toward a particular machine, or because a prompt asks — the material is in
[`AGENTS-riscv-target.md`](AGENTS-riscv-target.md), and it enters as *content for one kind of change* rather
than as a new standard against which unrelated work is measured. When it is engaged, the part that proves
relevant is condensed into an in-tree note of the submodule's own, so the porting question becomes part of what
the project knows about itself rather than a standing obligation to an external document.
