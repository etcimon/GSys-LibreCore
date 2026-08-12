# riscv-dev — Agent Guider (bootstrap scaffold)

> **Scope:** This file is the entry point for agents working **inside `riscv-dev/`**. The folder hosts
> **git submodules**, each one a library, a runtime, a language support package, or another
> developer-facing software component, and each one arriving **non-agentic** — a foreign tree with its own
> languages, build spine, public interface, dependency graph, and conventions, and no agent guide of its
> own.
>
> **This folder is scaffolding, not substrate.** Its product is not code and not a permanent governance
> layer; it is a *transition*. A submodule is bootstrapped until it carries **its own** agentic surface
> in-tree — its own `AGENTS.md`, its own `AGENTS-*` family, its own `architecture/` notes, its own queue —
> at which point this folder's structure becomes **contextually insignificant** to it: an agent working on
> that submodule opens the submodule's own `AGENTS.md` and never needs to read or inherit anything from
> here. The surrounding monorepo is likewise not a dependency and not the subject.

| Artifact | Path | Role |
|---|---|---|
| **This guider** | `AGENTS.md` | Why the scaffold exists, the independence contract, navigation |
| **Agentic-forming ladder** | [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) | B0–B7: reading → in-tree surface → **emancipation** + templates |
| **Analysis method** | [`AGENTS-logisplain.md`](AGENTS-logisplain.md) | How a foreign codebase is read; what notes that reading becomes |
| **Philosophy** | [`AGENTS-philosophy.md`](AGENTS-philosophy.md) | Library/runtime posture, **carried into** the submodule at B4 |
| **Backing toolchain (optional)** | [`AGENTS-toolchain-link.md`](AGENTS-toolchain-link.md) | How a library may be backed by a compiler without depending on it |
| **Target dossier (inert)** | [`AGENTS-riscv-target.md`](AGENTS-riscv-target.md) | RISC-V porting material, available on engagement, governing nothing |
| **Scaffold ledger** | [`AGENTS-todo.md`](AGENTS-todo.md) | Which submodules are at which rung; goes quiet as each is emancipated |
| **Transitional shadows** | [`agents/README.md`](agents/README.md) | `agents/<id>.md` — pre-emancipation only |
| **Transitional readings** | [`architecture/README.md`](architecture/README.md) | `architecture/<id>/` — workspace before the notes move in-tree |
| **Human entry** | [`README.md`](README.md) | Developer quickstart; usable without knowing this repository |

---

## 0. Prime directive — bootstrap toward independence, then get out of the way

A submodule placed here is not yet a subject an agent can act on: it is a mass of files whose internal
logic, public promises, and environmental assumptions have not been articulated. The discipline of this
folder is that the articulation happens **first, in writing, out of the tree itself**, that the agentic
surface is *derived* from it, and that both are **relocated into the submodule** so it stops depending on
this folder to be understood.

1. **Independence is the terminal state.** Bootstrapping is finished when the submodule is
   *agentic-structurally independent*: its in-tree `AGENTS.md` resolves every reference inside its own
   tree, its recorded green command runs with this scaffold absent, and its notes and queue live in-tree.
   After that this folder is contextually insignificant to it and must not be re-imposed. Test it with the
   three questions in [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §4.
2. **Carry by value, never by link.** Whatever a submodule needs from this folder's posture — method,
   standard, porting material — is written **into** the submodule in condensed self-contained form at B4.
   An in-tree guider that says "see `../AGENTS-philosophy.md`" has been tethered, not emancipated.
2a. **Untracked by default.** The surface lives in the checkout but is **not committed** unless asked: it is
   excluded through the submodule's own local exclude file so a developer can use it to develop the library
   without writing anything into the library's history or the superproject's. Committing it on a working
   branch is opt-in, and staging it in this scaffold is a fallback for read-only checkouts
   ([`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §6). Independence does not depend on which mode is in use.
3. **The checkout is authoritative.** Never record a fact that was not read out of the tree or observed by
   running it. What is unknown is written down as unknown.
4. **Analysis precedes surface.** The notes exist before the guider, and the guider only routes. A guider
   with no notes behind it will be trusted, which is why it is the failure mode this folder prevents.
5. **Green is discovered, then binding.** The tree's own configure/build/test invocation is recorded
   verbatim and becomes the local completion gate. For a library that gate usually has a matrix dimension
   — configurations, feature flags, platforms — and the recorded command says which cell was actually run.
6. **The public interface is a promise.** A library's callers are the reason it exists; its API, ABI,
   behaviour under error, and packaging surface are contracts. Changes to them are deliberate and stated,
   or they are not made.
7. **Upstreamable form is the default.** Prefer the change — and the document — the maintainers would
   accept: their layout, their idiom, their test style. This is also why the in-tree surface must be
   self-contained: a file referencing a parent superproject cannot go upstream.
8. **Generic over languages and build systems.** Nothing here presumes a language, package manager, build
   generator, or platform abstraction. Those are outputs of the ladder's inventory and reading rungs.
9. **Affinity, not governance.** RISC-V is *available*, not sovereign. Each submodule records a
   `riscv_affinity` (`none | latent | declared | active`) as an observation about its own purpose; only
   `declared`/`active` engages porting material, and then only as content for one kind of change. Porting
   a library to a new architecture is one legitimate use of this folder among many, and no submodule is
   judged by whether it has a target story.
10. **Prose over fragments; state kept where the work is.** Understanding is written as cohesive
    paragraphs ([`AGENTS-logisplain.md`](AGENTS-logisplain.md)); before emancipation state lives in this
    folder's ledger, after it in the submodule's own queue, and this folder's row shrinks to a pointer.

---

## 1. Directory map

```
riscv-dev/
  AGENTS.md                 ← this scaffold guider
  AGENTS-bootstrap.md       ← B0–B7 ladder, independence contract, in-tree templates
  AGENTS-logisplain.md      ← reading method (condensed copy carried in-tree at B4)
  AGENTS-philosophy.md      ← library/runtime posture (condensed copy carried in-tree at B4)
  AGENTS-toolchain-link.md  ← optional backing-compiler relation, by pin and invocation only
  AGENTS-riscv-target.md    ← inert porting dossier (copied in-tree only when affinity engages)
  AGENTS-todo.md            ← scaffold ledger: rung per submodule; quiet once emancipated
  README.md                 ← human entry point
  agents/                   ← TRANSITIONAL shadows only (see agents/README.md)
  architecture/             ← TRANSITIONAL readings only (see architecture/README.md)
  <id>/                     ← the submodule checkout — and, after B4, the real home of:
                                <id>/AGENTS.md            (its own guider)
                                <id>/AGENTS-*.md          (its own condensed method/posture/porting)
                                <id>/AGENTS-todo.md       (its own queue)
                                <id>/architecture/        (its own notes)
                              written there but UNTRACKED by default (AGENTS-bootstrap.md §6 mode A)
```

The folder ships with **no submodules**; empty `agents/` and `architecture/` is the correct initial state,
and near-empty is the correct steady state.

---

## 2. The ladder, and where it deposits its output

Full detail: [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md). Admission (**B0**) records id, upstream, pin,
mechanism and declared purpose. Inventory (**B1**) derives what the tree is made of, including its public
interface, its dependency graph, its configuration and feature-detection surface, its test matrix, and its
green command. Reading (**B2**) articulates the tree's logic in prose. Structuring (**B3**) commits
architectural notes **for the submodule**. Surfacing (**B4**) writes the in-tree guider and companions,
carrying posture by value. Seeding (**B5**) opens the in-tree queue. Passes (**B6**) advance the library
against its own green command. Emancipation (**B7**) verifies nothing reaches upward and reduces this
folder to a pointer.

The direction matters: **B3 output is written for the submodule, not for this folder.** Where the checkout
can be committed to, the notes are authored directly at `<id>/architecture/` and the parent copy never
exists.

---

## 3. Navigate by intent

| If the prompt is about... | Open |
|---|---|
| A submodule that already carries `<id>/AGENTS.md` | **that file only** — this folder is insignificant to it |
| A submodule not yet checked out, or checked out and unread | `AGENTS-bootstrap.md` (B0–B2) |
| How to read a foreign tree so the notes stay usable | `AGENTS-logisplain.md` |
| What kind of change is the right kind | `AGENTS-philosophy.md` |
| A library that needs a specific compiler to be built or tested | `AGENTS-toolchain-link.md` |
| Writing the submodule's own in-tree surface | `AGENTS-bootstrap.md` §5 (templates) |
| Whether a submodule is really independent yet | `AGENTS-bootstrap.md` §4 (three questions) |
| Building or testing anything | the `green_command` in the submodule's own guider |
| Porting, target capability, architecture-conditional code | `AGENTS-riscv-target.md` — only on `declared`/`active` affinity, or by prompt |
| Which submodules exist and at which rung | `AGENTS-todo.md` |

---

## 4. What a pass looks like

Before emancipation a pass advances a submodule up the ladder and its state is written here. After
emancipation a pass is governed entirely by the submodule's own guider: it names a thesis, opens what the
in-tree map says to open, changes the tree in the tree's own idiom, corrects the note for the area it
touched, runs the in-tree green command, and records the outcome — green, or a failure characterised
precisely enough to be a fact. If such a pass finds it needs this folder, that is a gap in the in-tree
surface: complete the missing material in-tree rather than restore the dependency.

Where a library's advancement depends on a compiler — because it exercises a language feature, a code
generator, or a runtime the compiler owns — the relation is recorded per
[`AGENTS-toolchain-link.md`](AGENTS-toolchain-link.md) as a pin and an invocation, and the pass must be
able to say which of its failures belong to the library and which belong to the toolchain beneath it. The
sibling scaffold [`../riscv-compilers/`](../riscv-compilers/) promotes compilers by the same ladder toward
the same independence; two emancipated trees are related by a recorded pin, never by a path import or a
shared document.

---

## 5. Invariants and non-goals

This folder never becomes a build dependency of a submodule, and no submodule becomes a build dependency of
its documents. Nothing here vendors, mirrors, or rewrites submodule source into the superproject. No
document here asserts a language, framework, or platform abstraction as a precondition, and none treats
RISC-V support as a measure of a submodule's worth. This folder is not a permanent governance layer, not a
package registry, and not a place to fork libraries by habit; it is a means of making a foreign tree
self-describing and developable, after which its own success is measured by how little of it remains
relevant.
