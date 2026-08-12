# AGENTS Logisplain — the reading method

> **Scope:** the epistemic core of `riscv-dev/`. This file says how a foreign codebase is *understood* and
> what that understanding must become: **architectural notes, committed inside the submodule, addressed to
> the next change**. It is the file that makes the rest of the folder generic — it describes how to seize an
> unfamiliar language, an unfamiliar build spine, and an unfamiliar dependency graph without naming any of
> them in advance. Consumed by [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) at rungs B1–B3, and by every
> later pass that finds the existing notes insufficient. A condensed, self-contained copy of this discipline
> is carried into each submodule at B4 as its own `AGENTS-method.md`, so later analysis stays consistent
> without the submodule referring back here.

---

## 1. The stance

Logisplain treats the codebase itself as the primary object of understanding. Code is never examined or
written in isolation; any construct, change, or explanation is grasped as an expression of the existing
system's internal logic, its established patterns of organisation, its resolution of names and
responsibilities, and the architectural commitments already embodied in its structure. The aim is not to
impose an external method on the tree but to inhabit the tree's own way of being — its conventions, its
boundaries, its invariants, and the quiet methodology that has already shaped it — so that analysis and
generation remain continuous with that understanding. Applied to a library this has a particular edge,
because a library's structure is partly a claim about how it will be *used*, and the claim its
documentation makes and the claim its code makes are frequently not the same.

The practical form of the stance is that understanding is written as cohesive paragraphs grounded in
concrete realities of the code, tracing how meaning, control and data actually move through the existing
organisation, in language that is neutral and precise and free of figurative flourish, lists, or procedural
scaffolding. This is not a stylistic preference. A fragment can hide a gap in understanding behind a
plausible label; a paragraph that must connect one clause to the next cannot. When a reading becomes hard
to write, that difficulty locates the part of the system that is not yet understood, and it is recorded as
such rather than compressed into a bullet that reads as though it were.

---

## 2. What a reading pass actually does

A reading pass begins from the tree's own surface rather than from expectation. It looks at what is present
and in what proportion, and lets the census correct the assumption the project's reputation creates — a
library celebrated for one thing is frequently mostly something else, and its tests, bindings and examples
often outweigh the logic that matters. It then finds the promise: the headers, modules, or exported symbols
that constitute the interface callers depend on, and, more importantly, where the boundary between promised
and internal actually falls, because that boundary is the thing every future change is measured against and
it is almost always less crisp in the code than in the documentation.

From an entry point on that boundary the pass follows a single journey inward, all the way to whatever the
library treats as primitive, preferring depth over coverage: one public call followed to the bottom teaches
more than a directory census, because it forces every layer, allocation, error path and configuration
lookup to be observed rather than assumed. Along the way the pass attends to which invariants are enforced
by construction and which merely by convention, since the latter are what a change breaks silently; to how
resources and failures are handled, since a library's behaviour when things go wrong is part of its
contract; to how configuration and capability decisions reach deep code, since that path determines whether
a new option is a small change or a structural one; and to where knowledge of the environment — platform,
architecture, word size, threading, filesystem, system interface — is concentrated or scattered, since that
distribution is exactly what a port must pay for.

The pass also reads the project's methodology out of its artifacts rather than its documentation. The shape
of its tests says what the maintainers believe is worth guaranteeing, and the dimensions of its test matrix
say which variability they consider real. The way it vendors, fetches, or assumes dependencies says how much
of its environment it considers its own responsibility. Its versioning and deprecation practice says how
seriously it treats its own promise. And the difference between what its documentation claims and what its
build actually requires is usually the single most useful observation available, because it is where a first
build fails.

---

## 3. Dependency and environment as first-class subjects

For libraries specifically, two properties deserve sustained attention because they dominate every later
pass and are routinely under-described. The first is the dependency graph: what the tree needs, whether the
need is vendored, submoduled, fetched at configure time or assumed on the host, what versions are actually
tolerated as opposed to declared, and which optional dependency is load-bearing in practice. This determines
whether the library can be built at all in a new setting, and it is the mechanism by which a library's
portability problem turns out to be someone else's portability problem. The second is the environmental
assumption surface: where the tree encodes what it believes about the machine and the system beneath it. A
library that concentrates those beliefs behind a small number of definitions can be moved; a library that
scatters them through its implementation must be understood before it can be moved, and the reading is that
understanding. A reading that has resolved neither has not yet made the tree portable *or* buildable, and a
guider written on top of it will send the next agent into the same wall.

Where a library additionally has a generation or bootstrap relation — checked-in generated sources, a code
generator run at configure time, bindings derived from a schema or a foreign header, or a component that must
be built by an earlier version of itself — that relation deserves the same sustained attention a compiler's
bootstrap does, and for the same reason: it determines what "building it" means, it creates ordering
constraints that make a first build succeed or fail, and it is the mechanism by which an edit to a source file
fails to reach the artifact because the generated copy is what actually compiled.

---

## 4. What the reading must produce

The reading is committed as an `architecture/` note set **inside the submodule** (staged at the scaffold's
`architecture/<id>/` only while the checkout cannot be written to), indexed by its own
`architecture/README.md`. The decisive property of a note is that it is **addressed to the next change**
rather than to a reader: it states in prose how an area works and what it is responsible for, *locates* that
responsibility as concrete files and regions, states the invariants an incoming change must preserve and
whether each is held by construction or by convention, names the extension points where a change of a given
kind belongs and what must move with it, and closes with what the analysis did not resolve. A note that
explains a subsystem beautifully without saying where a change goes has documented the system without
equipping anyone to develop it.

Three notes carry unusual weight for a library. The interface note says what the promise is and where its
boundary truly falls, and it is the note against which every later change is judged. The dependency and
environment note says what the tree needs and what it believes about the machine, and it is the note that
makes portability tractable. The build, packaging and test-matrix note says how a change can be validated at
all, and it carries the green command with its *observed* rather than intended behaviour, including which
matrix cell was actually exercised. Around those, an overview note carries the journey, notes per subsystem
carry local detail, and an open-questions note collects everything raised and not closed with enough context
to be picked up cold. The set grows as passes reach new areas; it is never expected to be complete and no
work is blocked on completing it.

Two rules keep the notes trustworthy. Anything not observed is marked as unobserved, in place, rather than
inferred into the prose — a reading is judged by how clearly it distinguishes what it saw from what it
supposes. And a note is never edited to agree with a later assumption: when the tree turns out to differ,
the note is corrected against the tree and the correction recorded, because the value of the note lies
precisely in its having been produced by looking.

---

## 5. Reading as preparation for change

The reading is not scholarship for its own sake; it exists so that a change can be proposed in the tree's own
idiom. A change conceived without a reading arrives as a foreign body: it introduces a second way of doing
something the project already does, it widens the promised interface by accident, it places state where the
configuration path cannot reach, it adds a test in a style the harness does not run, or it breaks an invariant
that was held by convention and therefore invisible. A change conceived after a reading looks like the
project — the practical definition of upstreamable, and the reason
[`AGENTS-philosophy.md`](AGENTS-philosophy.md) can treat upstreamable form as a default rather than an
aspiration. When a change genuinely cannot be made in the project's idiom, the reading is what allows that to
be stated as a considered divergence with a reason attached rather than discovered later as an inconsistency.

The final consequence is where the notes live. Because their purpose is to make the *next* change cheaper,
they belong with the code they describe, versioned alongside it, correctable in the same commit that
invalidates them — which is why the ladder deposits them inside the submodule and why the surface they support
must be self-contained. A reading held in a parent scaffold describes a codebase from outside and decays as
soon as the pin moves; the same reading held in-tree, indexed by the tree's own guider, is a development
substrate the project can carry forward on its own, and the analysis that produced it becomes something the
submodule owns rather than something done to it.
