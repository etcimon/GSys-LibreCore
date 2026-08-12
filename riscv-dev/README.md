# riscv-dev

A place to put a library or runtime as a git submodule and give it an **agentic development surface of its own**.

You add a checkout here; an agent reads it and writes architectural notes and a guider **into that checkout**;
from then on the submodule is developed through its own in-tree documents and this folder is irrelevant to it.
That last part is the point: this folder is scaffolding whose success is measured by how little of it remains in
the picture once bootstrapping is done.

Nothing here requires you to know anything about the repository that surrounds it. RISC-V is *available* as
porting material for the day a submodule needs it, and governs nothing before then — a library advanced here for
its interface clarity, its dependency footprint, or its build portability is using this folder exactly as
intended.

## What you get

After bootstrapping, the submodule itself contains an `AGENTS.md` that says what the tree is, what it promises
its callers, where its logic and its environmental assumptions live, which files to open for a given intent,
what may not be broken, and the exact command — with the configuration cell it covers — that decides whether a
change worked; an `architecture/` set of notes produced by analysis, each written to tell the next change where
it goes, with the interface boundary, the dependency graph, and the build-and-test matrix given their own notes
because those three decide whether anything can be validated at all; a short development guide and method note
so the standard travels with the code; and an `AGENTS-todo.md` carrying the current thesis and the next blocked
question. All of it resolves inside the submodule, with no reference back here, so it survives re-checkout and
can go upstream if the project wants it.

## How to use it

Place a checkout under this folder using a short lowercase id. **If this folder already lives inside
another git repository**, clone into `<id>/` as a nested repository and do **not** register it as a
submodule of that host unless you explicitly want the host to pin it — see
[`AGENTS-selectivity.md`](AGENTS-selectivity.md). Session notes go in untracked `TODO-scratch.md`;
the tracked ledger [`AGENTS-todo.md`](AGENTS-todo.md) is updated only when you ask to admit ids.

Ask an agent
to run the bootstrap in [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) for that id: it will admit the tree,
inventory it empirically — interface, dependencies, configuration surface, test matrix, green command — read it,
write the notes, derive the in-tree guider, and open the queue. Read what it wrote; the open questions are
usually the most useful part. Then work in passes: each pass names one thesis, changes the tree in the tree's own
idiom, corrects the note for the area it touched, runs the recorded green command on a named cell, and records
the outcome.

If the checkout cannot be written to yet, the same material is staged in this folder's `agents/` and
`architecture/` directories and moved in-tree later. Both are temporary by design and should be empty in steady
state.

## When a compiler is involved

If the library needs a compiler that is itself under development — because it exercises a language feature, a
code generator, or a runtime that compiler owns — read
[`AGENTS-toolchain-link.md`](AGENTS-toolchain-link.md). The relation is a recorded pin and a recorded
invocation, never a path import, and its purpose is to let a pass say which of its failures belong to the
library and which belong to the toolchain beneath it. Compilers are promoted in the sibling folder
[`../riscv-compilers/`](../riscv-compilers/) by the same ladder.

## What to read, and what to ignore

Read [`AGENTS.md`](AGENTS.md) for the contract this folder holds itself to, and
[`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) when you are promoting a tree. Read
[`AGENTS-logisplain.md`](AGENTS-logisplain.md) if you want to know why the notes look the way they do, and
[`AGENTS-philosophy.md`](AGENTS-philosophy.md) for the standard a library change is held to. Ignore
[`AGENTS-riscv-target.md`](AGENTS-riscv-target.md) until a submodule actually has a porting question; it is
written to be inert. [`AGENTS-todo.md`](AGENTS-todo.md) tells you which submodules exist and how far each has
come.

## Worked example — a non-compiler library

Suppose the library is a serialisation and wire-format package — call it `acme-serde`, upstream
`https://github.com/<org>/acme-serde.git` — with callers outside this repository, a configure-time feature
surface, and a test suite whose dimensions you have not looked at yet. Add it and run one prompt:

```text
# default when riscv-dev is already inside a host repo (does not touch host .gitmodules):
git clone https://github.com/<org>/acme-serde.git riscv-dev/acme-serde

# only if you explicitly want the *host* to record the pin:
# git submodule add https://github.com/<org>/acme-serde.git riscv-dev/acme-serde
```

```text
Promote the submodule at riscv-dev/acme-serde (upstream https://github.com/<org>/acme-serde.git) to an
agentic, self-developing tree by running the ladder in riscv-dev/AGENTS-bootstrap.md end to end. Read that
file, riscv-dev/AGENTS-logisplain.md and riscv-dev/AGENTS-philosophy.md first; they are the only context
you need from outside the checkout.

Purpose to record at admission: "serialisation library; advance its interface clarity, dependency
footprint and build portability." Set riscv_affinity from the tree's own evidence — `none` if it has no
architecture dimension at all, `latent` if it has a platform layer that could carry one — and do NOT do
porting work in this pass. riscv-dev/AGENTS-riscv-target.md stays closed unless I ask.

Treat everything you already believe about this project as a HYPOTHESIS TO VERIFY. Derive from the files:
which languages carry the library's own logic versus tests, bindings and examples; what constitutes the
public interface and — the part that matters — where the boundary between promised and internal actually
falls, as opposed to where the documentation says it falls; how the build is configured, installed and
packaged; the dependency graph, including which needs are vendored, fetched at configure time or assumed
on the host, which versions are tolerated rather than declared, and which optional dependency is
load-bearing in practice; where the tree concentrates its assumptions about platform, word size,
threading, filesystem and system interface; how a build-time or run-time capability decision reaches deep
code; and what dimensions the test matrix actually covers. Anything you cannot establish is recorded as
unknown, not as a plausible default.

Then find and RUN the tree's own configure/build/test invocation, record it verbatim as the green command,
and say WHICH matrix cell it exercised — configuration, feature set, platform — along with what it did
here, how long it took, and anything that would not work. A green state without a named cell is not a
green state. If it cannot be run, record it unverified and make that the first blocked question.

Deposit the output INSIDE the submodule but leave it UNTRACKED — persistence mode A in
riscv-dev/AGENTS-bootstrap.md §6, the default. Do not commit anything into the acme-serde checkout and do not
touch its .gitignore. Instead append the surface paths to the submodule's own local exclude file
(gitdir=$(git -C riscv-dev/acme-serde rev-parse --git-dir); append /AGENTS.md, /AGENTS-*.md, /AGENTS-todo.md
and /architecture/ to "$gitdir/info/exclude"), and set submodule.riscv-dev/acme-serde.ignore=untracked in LOCAL
git config so the superproject does not report the submodule as dirty. Libraries often already have an
architecture/ or docs/architecture/ tree, so check first and fall back to a non-colliding prefix, used
consistently and recorded in the guider. Record persistence: untracked-local in the provenance block, and warn
me that `git clean -xdf` inside the submodule would delete the surface.

The files to write are:
  acme-serde/architecture/         notes: index; an overview carrying one representative journey traced
                                   inward from a public entry point to whatever the library treats as
                                   primitive; an interface note stating the promise and where its boundary
                                   truly falls; a dependency-and-environment note; a build, packaging and
                                   test-matrix note holding the green command with its observed behaviour;
                                   notes per subsystem the journey passed through; an open-questions note
  acme-serde/AGENTS.md             the guider: provenance block, what the tree is and is not, index of the
                                   notes, navigate-by-intent map, green command with its cell, invariants
                                   with interface and ABI items first, recorded affinity, open questions
  acme-serde/AGENTS-development.md what a pass is and what finished means, carried by value
  acme-serde/AGENTS-method.md      the reading discipline, carried by value
  acme-serde/AGENTS-todo.md        advancement thesis, current state, first blocked question

Every note must be addressed to the next change: prose on how the area works, concrete file:line loci, the
invariants an incoming change must preserve marked as held by construction or by convention, the extension
points where a change of a given kind belongs and what must move with it, and what the analysis did not
close.

Hard constraint: the in-tree surface must be self-contained. No `../`, no reference to this scaffold or the
repository around it, no assumed parent guider — carry by value anything it needs. Then run the three
independence questions in riscv-dev/AGENTS-bootstrap.md §4 and report the answers; an untracked surface passes
them as long as it is complete and self-contained. If the checkout cannot be written to at all, fall back to
persistence mode C — stage the identical material under riscv-dev/architecture/acme-serde/ and
riscv-dev/agents/acme-serde.md — and tell me rather than tethering the tree to this folder.

If the library turns out to need a compiler that is itself under development, record that relation as a pin
plus an invocation per riscv-dev/AGENTS-toolchain-link.md — never as a path into a sibling folder.

Finally, update riscv-dev/AGENTS-todo.md with the rung reached, and stop. Do not change library behaviour
in this pass; promotion is the deliverable.
```

The expected result is a tree whose root reads like a package that always had an agent guide: a scope note,
an artifact table pointing at its own notes and queue, a numbered prime directive stating what must hold for
a change to be acceptable, a directory map, a development path, invariants and non-goals, and a live todo
that every later pass updates. The library-specific weight sits in three of the notes — the interface
boundary, the dependency and environment surface, and the build-and-test matrix — because those three decide
whether any subsequent change can be validated at all, and a promotion that leaves them vague has produced a
description rather than a development surface.

By default none of this enters version control. The surface sits in the library's working tree, excluded
through the submodule's own local exclude file rather than its tracked `.gitignore`, with the superproject told
to ignore untracked content there — so you can develop the library with a full agentic surface while neither
its history nor this repository records that you did. The costs are that `git clean -xdf` removes it, which
matters more for a library with a generated build tree than for most projects, and that it does not travel with
a fresh clone; when either starts to matter, add `persistence: branch agentic-surface` to the prompt and the
same files are committed inside the submodule instead. A read-only checkout falls back to staging in this
folder. All three modes are in [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §6, and none of them changes
whether the tree counts as independent.

Substitute any real library for `acme-serde` and the prompt is unchanged except for the id, the upstream and
the recorded purpose; that invariance is the point of writing the ladder generically. Once the tree is
emancipated, later prompts stop mentioning this folder entirely: they name a thesis against the submodule's
own guider, and the scaffold plays no further part.

## Terms

Everything this folder provides — this README, the guiders, the ladder, the method and posture files, the
toolchain-link relation, the transitional directory conventions — is dedicated to the **public domain** under
CC0 1.0 ([`LICENSE`](LICENSE)). Take it, adapt it, embed it in your own project or product, with no conditions
and no attribution required.

The dedication stops at the folder boundary, deliberately. A library you check out here remains a separate work
under **its own licence**, and nothing about placing it here, reading it, or generating notes about it
relicenses it, creates a derivative work of it, or waives anyone's patents or trademarks. Documents an agent
writes into a submodule tree belong to whoever ran the process and to that project's terms, not to this file.
No third-party IP is conveyed or cleared by anything here.

## Current state

Empty. No submodules are admitted, which is the correct initial state — the folder acquires content the first
time a checkout is read.
