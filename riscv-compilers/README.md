# riscv-compilers

A place to put a compiler as a git submodule and give it an **agentic development surface of its own**.

You add a checkout here; an agent reads it and writes architectural notes and a guider **into that
checkout**; from then on the submodule is developed through its own in-tree documents and this folder is
irrelevant to it. That last part is the point: this folder is scaffolding whose success is measured by how
little of it remains in the picture once bootstrapping is done.

Nothing here requires you to know anything about the repository that surrounds it. There is no RTL, no
silicon workflow, and no project-wide policy in play. RISC-V is *available* as material for the day a
submodule needs a target story, and governs nothing before then.

## What you get

After bootstrapping, the submodule itself contains an `AGENTS.md` that says what the tree is, where its
logic lives, which files to open for a given intent, what may not be broken, and the exact command that
decides whether a change worked; an `architecture/` set of notes, produced by analysis, each one written
to tell the next change where it goes; a short development guide and method note so the standard travels
with the code; and an `AGENTS-todo.md` carrying the current thesis and the next blocked question. All of
it resolves inside the submodule, with no reference back here, so it survives re-checkout and can go
upstream if the project wants it.

## How to use it

Add the compiler as a submodule under this folder, choosing a short lowercase id for its directory. Ask an
agent to run the bootstrap in [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) for that id: it will admit the
tree, inventory it empirically, read it, write the architectural notes, derive the in-tree guider, and open
the queue. Read what it wrote — the notes are the honest record of what is understood and what is not, and
the open questions are usually the most useful part. Then work in passes: each pass names one thesis,
changes the tree in the tree's own idiom, corrects the note for the area it touched, runs the recorded
green command, and records the outcome.

If the checkout cannot be written to yet — a read-only pin, or an undecided branch — the same material is
staged in this folder's `agents/` and `architecture/` directories and moved in-tree later. Those two
directories are temporary by design and should be empty in steady state.

## What to read, and what to ignore

Read [`AGENTS.md`](AGENTS.md) for the contract this folder holds itself to, and
[`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) when you are promoting a tree. Read
[`AGENTS-logisplain.md`](AGENTS-logisplain.md) if you want to know why the notes look the way they do, and
[`AGENTS-philosophy.md`](AGENTS-philosophy.md) for the standard a compiler change is held to. Ignore
[`AGENTS-riscv-target.md`](AGENTS-riscv-target.md) until a submodule actually has a target question;
it is written to be inert. [`AGENTS-todo.md`](AGENTS-todo.md) tells you which submodules exist and how far
each has come.

The sibling folder [`../riscv-dev/`](../riscv-dev/) does the same thing for libraries and runtimes, and can
be backed by a compiler promoted here.

## Worked example — LDC (the `ldc2` D compiler)

Take `https://github.com/ldc-developers/ldc.git` as the tree to promote, occupying the id `ldc2`. Add it and
run one prompt:

```text
git submodule add https://github.com/ldc-developers/ldc.git riscv-compilers/ldc2
```

```text
Promote the submodule at riscv-compilers/ldc2 (upstream https://github.com/ldc-developers/ldc.git,
default branch master, binary name ldc2) to an agentic, self-developing tree by running the ladder in
riscv-compilers/AGENTS-bootstrap.md end to end. Read that file, riscv-compilers/AGENTS-logisplain.md and
riscv-compilers/AGENTS-philosophy.md first; they are the only context you need from outside the checkout.

Purpose to record at admission: "LLVM-based D compiler; advance its correctness, bootstrap
reproducibility and portability." Set riscv_affinity to whatever the tree's own evidence supports — most
likely `latent` — and do NOT do target work in this pass. riscv-compilers/AGENTS-riscv-target.md stays
closed unless I ask.

Treat everything you already believe about this project as a HYPOTHESIS TO VERIFY, not a fact. In
particular: which languages carry the compiler's own logic versus its tests, bindings and tooling; whether
the front end is vendored or generated and how it is kept in step; how the backend dependency is obtained
and which versions the tree actually tolerates; whether a prior D compiler is required to build this one
and what that does to the build order; what the runtime and standard library are and who compiles them;
and what the test harness is and how one test runs alone. Derive each of those from files in the checkout,
and where you cannot, record it as unknown rather than plausible.

Then find and RUN the tree's own configure/build/test invocation and record it verbatim as the green
command, with what it actually did here, how long it took, and any part that could not be made to work. If
it cannot be run in this environment, record it as unverified and make that the first blocked question —
do not write it down as if it worked.

Deposit the output INSIDE the submodule but leave it UNTRACKED — persistence mode A in
riscv-compilers/AGENTS-bootstrap.md §6, the default. Do not commit anything into the ldc2 checkout and do
not touch its .gitignore. Instead, append the surface paths to the submodule's own local exclude file
(gitdir=$(git -C riscv-compilers/ldc2 rev-parse --git-dir); append /AGENTS.md, /AGENTS-*.md, /AGENTS-todo.md
and /architecture/ to "$gitdir/info/exclude"), and set submodule.riscv-compilers/ldc2.ignore=untracked in
LOCAL git config so the superproject does not report the submodule as dirty. Before writing, check whether
the tree already uses AGENTS.md or architecture/; if it does, switch to a non-colliding prefix, use it
consistently, and say so in the guider. Record persistence: untracked-local in the provenance block, and warn
me in your summary that `git clean -xdf` inside the submodule would delete the surface.

The files to write are:
  ldc2/architecture/          notes: index, overview carrying one representative journey traced from the
                              driver's argument handling to an emitted artifact, one note per stage or
                              subsystem that journey passed through, a build-and-bootstrap note holding
                              the spine plus the green command with its observed behaviour, a dependency
                              note, and an open-questions note
  ldc2/AGENTS.md              the guider: provenance block, what the tree is and is not, index of the
                              notes, navigate-by-intent map into its own source, the green command, the
                              invariants a change must not break, the recorded affinity, open questions
  ldc2/AGENTS-development.md  what a pass is and what finished means, carried by value
  ldc2/AGENTS-method.md       the reading discipline, carried by value
  ldc2/AGENTS-todo.md         advancement thesis, current state, first blocked question

Every note must be addressed to the next change, not to a reader: prose explaining how the area works,
then concrete file:line loci, then the invariants an incoming change must preserve marked as held by
construction or by convention, then the extension points where a change of a given kind belongs and what
must move with it, then what the analysis did not close.

Hard constraint: the in-tree surface must be self-contained. No `../`, no reference to this scaffold or to
the repository around it, no assumption that a parent guider exists — carry anything it needs by value.
Then run the three independence questions in riscv-compilers/AGENTS-bootstrap.md §4 and report the answers;
an untracked surface passes them as long as it is complete and self-contained. If the checkout cannot be
written to at all, fall back to persistence mode C — stage the identical material under
riscv-compilers/architecture/ldc2/ and riscv-compilers/agents/ldc2.md — and tell me, instead of tethering the
tree to this folder.

Finally, update riscv-compilers/AGENTS-todo.md with the rung reached, and stop. Do not change compiler
behaviour in this pass; promotion is the deliverable.
```

What that prompt is expected to produce is a tree whose root looks like a package that always had an agent
guide: a scope note declaring what the tree is and what it is not, an artifact table pointing at its own
notes and queue, a numbered prime directive stating what must hold for a change to be acceptable, a
directory map, a development path, a short list of invariants and non-goals, and a live todo that every
later pass updates. If your repository contains other packages built to that shape, comparing against one
of them is the quickest way to judge whether the result is finished; nothing in the submodule should refer
to them.

By default none of this enters version control. The surface sits in the `ldc2/` working tree, excluded through
the submodule's own local exclude file rather than its tracked `.gitignore`, with the superproject told to
ignore untracked content in that submodule — so you can develop the compiler with a full agentic surface while
neither LDC's history nor this repository records that you did. The two costs are that a `git clean -xdf` inside
the submodule removes it and that it does not travel with a fresh clone; when either starts to matter, add
`persistence: branch agentic-surface` to the prompt and the same files are committed inside the submodule
instead. A read-only checkout falls back to staging in this folder. All three modes are described in
[`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §6, and none of them changes whether the tree counts as
independent.

LDC is a deliberately hard test of the prompt rather than an easy demonstration. It mixes languages, it
carries a front end whose provenance is a real question, it depends on a large external backend whose
version tolerance is not obvious, it very plausibly needs a working D compiler in order to build a D
compiler at all, and it owns a runtime and standard library that the compiler itself must be able to
compile. Those are exactly the properties that defeat a promotion done by assumption, so if the resulting
notes locate them honestly — including recording as unknown whatever could not be established — the
promotion worked. A second pass then begins normally: name a thesis, open only what the in-tree map says
to open, change the tree in its own idiom, correct the note for the area touched, run the green command,
record the outcome.

## Terms

Everything this folder provides — this README, the guiders, the ladder, the method and posture files, the
transitional directory conventions — is dedicated to the **public domain** under CC0 1.0
([`LICENSE`](LICENSE)). Take it, adapt it, embed it in your own project or product, with no conditions and no
attribution required.

The dedication stops at the folder boundary, deliberately. A submodule you check out here remains a separate
work under **its own licence**, and nothing about placing it here, reading it, or generating notes about it
relicenses it, creates a derivative work of it, or waives anyone's patents or trademarks. Documents an agent
writes into a submodule tree belong to whoever ran the process and to that project's terms, not to this file.
No third-party IP — upstream projects, specifications, toolchains, silicon — is conveyed or cleared by
anything here.

## Current state

Empty. No submodules are admitted, which is the correct initial state — the folder acquires content the
first time a checkout is read.
