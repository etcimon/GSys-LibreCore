# AGENTS Logisplain — the reading method

> **Scope:** the epistemic core of `riscv-compilers/`. This file says how a foreign codebase is
> *understood* and what that understanding must become: **architectural notes, committed inside the
> submodule, addressed to the next change**. It is the file that makes the rest of the folder generic —
> it describes how to seize an unfamiliar language, an unfamiliar build spine, and an unfamiliar
> dependency graph without naming any of them in advance. Consumed by
> [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) at rungs B1–B3, and by every later pass that finds the
> existing notes insufficient. A condensed, self-contained copy of this discipline is carried into each
> submodule at B4 as its own `AGENTS-method.md`, so that later analysis stays consistent without the
> submodule referring back here.

---

## 1. The stance

Logisplain treats the codebase itself as the primary object of understanding. Code is never examined
or written in isolation; any construct, change, or explanation is grasped as an expression of the
existing system's internal logic, its established patterns of organisation, its resolution of names and
responsibilities, and the architectural commitments already embodied in its structure. The aim is not
to impose an external method on the tree but to inhabit the tree's own way of being — its conventions,
its boundaries, its invariants, and the quiet methodology that has already shaped it — so that analysis
and generation remain continuous with that understanding. Applied to a compiler this is unusually
consequential, because a compiler is a codebase whose *subject* is also structure, and it is easy to
mistake the compiler's account of its own domain for an account of itself.

The practical form of the stance is that understanding is written as cohesive paragraphs grounded in
concrete realities of the code, tracing how meaning, control and data actually move through the existing
organisation, in language that is neutral and precise and free of figurative flourish, lists, or
procedural scaffolding. This is not a stylistic preference. A fragment can hide a gap in understanding
behind a plausible label; a paragraph that has to connect one clause to the next cannot. When a reading
becomes hard to write, that difficulty is information: it locates the part of the system that is not yet
understood, and it is recorded as such rather than compressed into a bullet that reads as if it were.

---

## 2. What a reading pass actually does

A reading pass begins from the tree's own surface rather than from expectation. It looks at what is
present and in what proportion, and it lets the census correct the assumption the project's reputation
creates — a compiler celebrated for one language is frequently implemented in another, its tests in a
third, and its build orchestration in a fourth, and each of those layers has a different relationship
to the logic that matters. It then finds where responsibility begins: the invocation that turns a
command line into work, because that is the only place in a compiler where the whole system is visible
at once, and because the shape of that entry reveals whether the project is a monolith with internal
phases, a driver over separable programs, or a library with a thin executable wrapped around it.

From that entry the pass follows a single representative journey all the way through, and it prefers
depth over coverage: one source file taken from argument handling to emitted artifact teaches more than
a directory-by-directory census, because it forces every hand-off to be observed rather than assumed.
Along that journey the pass attends to where representations change, since a representation boundary is
where a project's real commitments live; to which invariants are enforced by construction and which
merely by convention, since the latter are what a change breaks silently; to how configuration reaches
deep code, since that path determines whether a new option is a small change or a structural one; and
to how the project separates portable behaviour from target-specific or platform-specific behaviour,
since that seam is the one an agent will need if a target question ever arises.

The pass also reads the project's methodology out of its artifacts rather than its documentation. The
shape of its tests says what the maintainers believe is worth guaranteeing. The shape of its error
reporting says how much it expects to be used interactively. The way it vendors or assumes
dependencies says how much of its environment it considers its own responsibility. The history of a
few load-bearing files says which parts are settled and which are in motion. And the difference between
what its documentation claims and what its build actually requires is almost always the most useful
single observation available, because it is where a first build fails.

---

## 3. Bootstrap and dependency as first-class subjects

For compilers specifically, two properties deserve their own sustained attention because they dominate
every later pass and are routinely under-described by the projects themselves. The first is the
bootstrap relation: whether the tree needs a prior version of itself, a foreign compiler, a generated
artifact that is checked in, or a runtime library that it will subsequently be responsible for
compiling. This relation determines what "building it" even means, it creates the ordering constraints
that make a first build succeed or fail, and it is the mechanism by which a change to the compiler can
invalidate the tool used to build the compiler. The second is the dependency surface: which components
the tree expects to already exist, whether that expectation is satisfied inside the tree, by a
submodule, or by the host, and what version range is actually tolerated as opposed to declared. A
reading that has not resolved these two has not yet made the tree buildable, and a guide written on top
of it will send the next agent into the same wall.

---

## 4. What the reading must produce

The reading is committed as an `architecture/` note set **inside the submodule** (staged at the
scaffold's `architecture/<id>/` only while the checkout cannot be written to), indexed by its own
`architecture/README.md`. The decisive property of a note is that it is **addressed to the next
change** rather than to a reader: it states in prose how an area works and what it is responsible for,
it *locates* that responsibility as concrete files and regions within them, it states the invariants an
incoming change must preserve and whether each is held by construction or by convention, it names the
extension points where a change of a given kind belongs and what must move with it, and it closes with
what the analysis did not resolve. A note that explains a subsystem beautifully without saying where a
change goes has documented the system without equipping anyone to develop it.

The set therefore grows along the shape of the work rather than along the shape of the directory tree.
An overview note carries the representative journey; one note per stage or subsystem the journey passed
through carries the local detail; a build-and-bootstrap note carries the spine, the bootstrap relation,
and the green command with its *observed* rather than intended behaviour; a dependency note records what
is needed and where it is expected; and an open-questions note collects everything raised and not
closed, each with enough context that a later pass can pick it up cold. New areas acquire notes as
passes reach them, which is why the set is never expected to be complete and is never blocked on being
so.

Two rules keep the notes trustworthy over time. Anything not observed is marked as unobserved, in place,
rather than inferred into the prose — a reading is judged by how clearly it distinguishes what it saw
from what it supposes. And a note is never edited to agree with a later assumption: when the tree turns
out to differ, the note is corrected against the tree and the correction is recorded, because the value
of the note lies precisely in its having been produced by looking.

---

## 5. Reading as preparation for change

The reading is not scholarship for its own sake; it exists so that a change can be proposed in the
tree's own idiom. A change conceived without a reading tends to arrive as a foreign body: it introduces
a second way of doing something the project already does, it places state where the project's
configuration path cannot reach, it adds a test in a style the harness does not run, or it breaks an
invariant that was maintained by convention and therefore invisible. A change conceived after a reading
tends instead to look like the project — which is the practical definition of upstreamable, and the
reason [`AGENTS-philosophy.md`](AGENTS-philosophy.md) can treat upstreamable form as a default rather
than an aspiration. When a change genuinely cannot be made in the project's idiom, the reading is what
allows that to be stated as a considered divergence with a reason attached, rather than discovered later
as an inconsistency.

The final consequence is where the notes live. Because their purpose is to make the *next* change
cheaper, they belong with the code they describe, versioned alongside it, correctable in the same commit
that invalidates them — which is why the ladder deposits them inside the submodule and why the surface
they support must be self-contained. A reading held in a parent scaffold describes a codebase from
outside and decays as soon as the pin moves; the same reading held in-tree, indexed by the tree's own
guider, is a development substrate that the project can carry forward on its own, and the analysis that
produced it becomes something the submodule owns rather than something done to it.
