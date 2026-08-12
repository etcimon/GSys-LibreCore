# AGENTS Philosophy — engineering posture for compiler work

> **Scope:** how a change to a submodule under `riscv-compilers/` is conceived, judged, and finished.
> It is the compiler-side counterpart of the reading method: [`AGENTS-logisplain.md`](AGENTS-logisplain.md)
> says how the tree is understood, this file says what kind of change that understanding should
> produce. It sits beside (never above) [`AGENTS.md`](AGENTS.md) §0 and presumes nothing about the
> submodule's language, build system, or internal representations.
>
> This posture is **carried by value into each submodule** at rung B4 as its own condensed
> `AGENTS-development.md`, so that an emancipated tree holds its own standard and never refers back to
> this scaffold. Where this file says `architecture/` or the guider, it means the submodule's **own**
> in-tree `architecture/` note set and its own `AGENTS.md`.

---

## 1. What is being built

A compiler is infrastructure whose output other people depend on without reading it. That single fact
sets the standard for changes here. A compiler that is merely *usually* right is not a compiler; it is
a source of defects that appear far from their cause, in code its users wrote correctly, and which they
will attribute to themselves before they suspect the toolchain. Everything below follows from taking
that seriously: correctness is not one property among several but the property the artifact exists to
have, and the qualities that protect it — reproducibility, staged invariants, honest diagnostics,
tests written in the same breath as the change — are not overhead but the mechanism by which
correctness survives contact with a second contributor.

---

## 2. Principles, in the order they bind

**Correctness before performance, and never silently traded.** A faster path that changes observable
behaviour is not an optimisation; it is a semantic change wearing an optimisation's clothes. Where a
trade-off is real it is made explicit, gated so it can be turned off, and written down. This is
especially sharp in a compiler because the observable is not only the program's answer but its
diagnostics, its exit status, its emitted symbols, and its behaviour under separate compilation.

**Staged lowering with invariants stated at each boundary.** A compiler's structure is a sequence of
representations, and its real interfaces are the guarantees each stage may assume about the one before.
A change that adds information to a representation must say who is now required to maintain it; a change
that relaxes a guarantee must say who was relying on it. Where the project maintains a boundary
invariant only by convention, a change in that region is written so the convention is easier to keep,
not harder.

**The emitted artifact is a contract.** Object layout, symbol naming, calling convention, ABI-visible
type sizes, name mangling, and debug information are consumed by other tools and by code compiled by
other versions. They are changed deliberately, with a statement of who breaks, or they are not changed.
An accidental ABI change is the most expensive class of defect available in this folder, because it is
invisible in the tree's own test suite and appears only when something links.

**Reproducibility of the build and of the bootstrap.** The same inputs produce the same outputs, and
the path from a bare checkout to a working compiler is written down and actually walked, including the
prior-compiler or self-hosting relation if there is one. A change that makes the bootstrap harder to
reproduce is a change to the project's most fragile property and is treated as structural even when its
diff is small.

**Diagnostics are part of the product.** A compiler is used most often when it is refusing to do
something, so the quality of its refusal is a large part of its quality. A new error path gets a
message that names the construct and the reason; an existing message is not degraded in passing.

**Tests in the same pass as the change.** The submodule's own harness is the instrument, discovered at
inventory and recorded as the green command. A change lands with a test the harness runs, written in the
style the harness expects, and the pass ends with that command executed and its result recorded — green,
or a failure characterised precisely enough that the next pass starts from a fact.

**Upstreamable form as the default posture.** Prefer the change the maintainers would accept: their
layout, their idiom, their naming, their test style. This is not deference for its own sake; a change
shaped like the project is a change the project's own reviewers and future refactors will preserve,
whereas a foreign-bodied change decays. Divergence is legitimate when the project's direction and the
work's direction genuinely differ, and then it is recorded as a divergence with a reason rather than
left to be discovered.

**Explicit over implicit, in the tree's own vocabulary.** New behaviour is discoverable — a flag, an
option, a declared capability — reachable through the configuration path the project already has, and
named the way the project already names things. Hidden behaviour that depends on build configuration or
host state is how a compiler acquires bugs that only reproduce elsewhere.

**Documented trade-offs, in the tree's own notes.** Anything non-obvious leaves a written trace where the
work is: a corrected paragraph in the `architecture/` note for the area if the change altered how the
system should be understood, an invariant line in the tree's own `AGENTS.md` if it altered what may not be
broken, an extension-point line if it created or moved a place where future changes belong, and a queue
entry if it left something open. The project's memory is these notes; a decision that is not in them did
not happen, and a note that was not corrected by a change that invalidated it is now actively misleading.

---

## 3. Scale discipline

Most useful work here is small and sequenced. A pass that changes one representation boundary, or adds
one option, or makes one previously-failing test pass, can be reviewed, and its effect on the green
command is legible. A pass that rewrites a pipeline stage, introduces a second intermediate
representation, or replaces a build system cannot be reviewed and cannot be attributed when it breaks;
if such work is genuinely required, it is planned in the queue as a sequence of individually green
steps, with the reading updated at each step. The equivalent failure at the other extreme is a pass
that touches many files superficially to satisfy a preference — renaming, reformatting, restyling —
which consumes the reviewer's attention that the substantive change needed and makes the diff
unusable as history.

---

## 4. Checklist for a finished pass

Before calling a pass complete, state each of these or say why it does not apply: the thesis the pass
set out to prove and whether it holds; the invariants the change touched and how they are still
maintained; whether anything ABI- or artifact-visible moved, and if so who is affected; what the
recorded green command reported, verbatim in outcome if not in output; the test that now covers the
change and the harness that runs it; whether the change is in the project's idiom or is a recorded
divergence; which in-tree architectural notes and which lines of the tree's own guider were corrected;
and what the next blocked question is. A pass that cannot answer the ABI question or the green-command
question is not finished, regardless of how convincing the diff looks.

---

## 5. On targets

Nothing in this posture is target-specific, and nothing in it assumes a submodule has a target story at
all. A pass may improve a frontend's diagnostics, its bootstrap reproducibility, or its parsing
correctness for years without a target question arising. When one does arise — because the submodule's
declared purpose reaches toward a particular machine, or because a prompt asks — the material is in
[`AGENTS-riscv-target.md`](AGENTS-riscv-target.md), and it enters as *content for one kind of change*
rather than as a new standard against which unrelated work is measured. When it is engaged, the part that
proves relevant is condensed into an in-tree note of the submodule's own, so that the target question
becomes part of what the project knows about itself rather than a standing obligation to an external
document.
