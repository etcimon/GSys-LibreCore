# riscv-compilers — Agent Guider (bootstrap scaffold)

> **Scope:** This file is the entry point for agents working **inside `riscv-compilers/`**. The folder
> hosts **git submodules**, each one a compiler, a compiler frontend, or a toolchain component, and each
> one arriving **non-agentic** — a foreign tree with its own languages, build spine, internal
> representations, and conventions, and no agent guide of its own.
>
> **This folder is scaffolding, not substrate.** Its product is not code and not a permanent governance
> layer; it is a *transition*. A submodule is bootstrapped until it carries **its own** agentic surface
> in-tree — its own `AGENTS.md`, its own `AGENTS-*` family, its own `architecture/` reading, its own
> queue — at which point this folder's structure becomes **contextually insignificant** to it: an agent
> working on that submodule opens the submodule's own `AGENTS.md` and never needs to read, resolve, or
> inherit anything from here. The surrounding monorepo is likewise not a dependency and not the
> subject; nothing here requires LibreCore RTL, its SoC disciplines, or its traceability files.

| Artifact | Path | Role |
|---|---|---|
| **This guider** | `AGENTS.md` | Why the scaffold exists, the independence contract, navigation |
| **Agentic-forming ladder** | [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) | B0–B7: reading → in-tree surface → **emancipation** + templates |
| **Analysis method** | [`AGENTS-logisplain.md`](AGENTS-logisplain.md) | How a foreign codebase is read; what prose that reading becomes |
| **Philosophy** | [`AGENTS-philosophy.md`](AGENTS-philosophy.md) | Compiler-side posture, **carried into** the submodule at B4, not linked from it |
| **Target dossier (inert)** | [`AGENTS-riscv-target.md`](AGENTS-riscv-target.md) | RISC-V material, available on engagement, governing nothing by default |
| **Scaffold ledger** | [`AGENTS-todo.md`](AGENTS-todo.md) | Which submodules are at which rung; goes quiet as each is emancipated |
| **Transitional shadows** | [`agents/README.md`](agents/README.md) | `agents/<id>.md` — pre-emancipation only; becomes a pointer or is deleted |
| **Transitional readings** | [`architecture/README.md`](architecture/README.md) | `architecture/<id>/` — workspace before the reading moves in-tree |
| **Human entry** | [`README.md`](README.md) | Developer quickstart; usable without knowing this repository |

---

## 0. Prime directive — bootstrap toward independence, then get out of the way

A submodule placed here is not yet a subject an agent can act on: it is a mass of files whose internal
logic has not been articulated. The discipline of this folder is that the articulation happens **first,
in writing, out of the tree itself**, that the agentic surface is *derived* from that articulation, and
that both are then **relocated into the submodule** so the submodule stops depending on this folder to
be understood.

1. **Independence is the terminal state.** Bootstrapping is finished when the submodule is
   *agentic-structurally independent*: its own in-tree `AGENTS.md` resolves every reference it makes
   inside its own tree, its green command runs without anything from this folder, and its queue and
   reading live in-tree. After that, this folder's structure is contextually insignificant to work on
   that submodule and must not be re-imposed on it. Test it with the three questions in
   [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §4.
2. **Carry by value, never by link.** Anything a submodule needs from this folder's posture — reading
   method, engineering standard, target material — is **written into** the submodule in condensed,
   self-contained form at B4. An in-tree `AGENTS.md` that says "see `../AGENTS-philosophy.md`" has not
   been emancipated; it has been tethered.
3. **The checkout is authoritative.** Never record a fact about a submodule that was not read out of its
   files or observed by running it. A plausible fact about a language, a build system, or a compiler
   pipeline is not a fact about *this* tree. What is unknown is written down as unknown.
4. **Analysis precedes surface.** The reading exists before the guide, and the guide only summarises and
   points. A guide with no reading behind it is the failure mode this folder exists to prevent, because
   it will be trusted.
5. **Green is discovered, then binding.** Each submodule's own configure/build/test invocation is
   recorded verbatim as its **green command** and becomes the local completion gate. No command from
   this folder or this repository ever substitutes for it.
6. **Upstreamable form is the default.** Prefer the change — and the document — the submodule's own
   maintainers would accept: their layout, their idiom, their test style. This is also why the in-tree
   surface must be self-contained: a file that references a parent superproject cannot go upstream.
7. **Generic over languages and build systems.** Nothing here presumes a language, dependency manager,
   intermediate representation, or bootstrap strategy. Those are outputs of the ladder's inventory and
   reading rungs, per submodule.
8. **Affinity, not governance.** RISC-V is *available*, not sovereign. Each submodule records a
   `riscv_affinity` (`none | latent | declared | active`) as an observation about its own purpose; only
   `declared`/`active` engages target material, and then only as content for one kind of change. No
   submodule here is blocked on having a RISC-V story, and none is judged by whether it has one.
9. **Prose over fragments.** Understanding is written as cohesive paragraphs
   ([`AGENTS-logisplain.md`](AGENTS-logisplain.md)), because a fragment can hide a gap in understanding
   and a paragraph cannot. Tables are for navigation; prose is for meaning.
10. **State is kept where the work is.** Before emancipation, in this folder's ledger; after it, in the
    submodule's own queue, and this folder's row shrinks to a pointer.

---

## 1. Directory map

```
riscv-compilers/
  AGENTS.md               ← this scaffold guider
  AGENTS-bootstrap.md     ← B0–B7 ladder, independence contract, in-tree templates
  AGENTS-logisplain.md    ← reading method (condensed copy is carried in-tree at B4)
  AGENTS-philosophy.md    ← engineering posture (condensed copy is carried in-tree at B4)
  AGENTS-riscv-target.md  ← inert target dossier (copied in-tree only when affinity engages)
  AGENTS-todo.md          ← scaffold ledger: rung per submodule; quiet once emancipated
  README.md               ← human entry point
  agents/                 ← TRANSITIONAL shadows only (see agents/README.md)
  architecture/           ← TRANSITIONAL readings only (see architecture/README.md)
  <id>/                   ← the submodule checkout — and, after B4, the real home of:
                              <id>/AGENTS.md            (its own guider)
                              <id>/AGENTS-*.md          (its own condensed method/posture/target)
                              <id>/AGENTS-todo.md       (its own queue)
                              <id>/architecture/        (its own reading)
```

The folder ships with **no submodules**, and an empty `agents/` and `architecture/` is the correct
initial state. In steady state those two directories should be nearly empty again — populated only by
submodules mid-transition, or by shadows for checkouts that cannot be written to.

---

## 2. The ladder, and where it deposits its output

Full detail: [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md).

Admission (**B0**) records only what is certain: id, upstream, pin, declared purpose. Inventory (**B1**)
derives empirically what the tree is made of, including its green command. Reading (**B2**) articulates
the tree's own logic in prose. Structuring (**B3**) commits that articulation as a small ordered document
set. Surfacing (**B4**) writes the submodule's **in-tree** `AGENTS.md` and `AGENTS-*` family from B1–B3
and nothing else, carrying by value whatever posture it needs. Seeding (**B5**) opens the submodule's own
in-tree queue. Passes (**B6**) advance the submodule against its own recorded green command.
Emancipation (**B7**) verifies that nothing in the submodule's surface reaches upward, and reduces this
folder's shadow and ledger row to a pointer.

The important consequence is directional: **B3 output is written for the submodule, not for this
folder**. Where the checkout can be committed to — a fork branch, a working branch, a maintained
downstream — the reading is authored directly at `<id>/architecture/` and the parent copy never exists.
The parent's `architecture/<id>/` and `agents/<id>.md` are only a workspace for the case where the
checkout is pinned read-only or the promotion is unfinished, and they are explicitly temporary.

---

## 3. Navigate by intent

| If the prompt is about... | Open |
|---|---|
| A submodule that already carries `<id>/AGENTS.md` | **that file only** — this folder is contextually insignificant to it |
| A submodule not yet checked out, or checked out and unread | `AGENTS-bootstrap.md` (B0–B2) |
| How to read a foreign tree so the reading stays usable | `AGENTS-logisplain.md` |
| What kind of change is the right kind | `AGENTS-philosophy.md` |
| Writing the submodule's own in-tree surface | `AGENTS-bootstrap.md` §5 (templates) |
| Checking whether a submodule is really independent yet | `AGENTS-bootstrap.md` §4 (three questions) |
| Building or testing anything | the `green_command` recorded in the submodule's own guider |
| RISC-V targets, ABI, relocations, capability discovery | `AGENTS-riscv-target.md` — only if affinity is `declared`/`active`, or the prompt asks |
| Which submodules exist and at which rung | `AGENTS-todo.md` |

---

## 4. What a pass looks like

Before emancipation, a pass advances a submodule up the ladder and its state is written here. After
emancipation, a pass is governed entirely by the submodule's own guider: it names a thesis, reads what
the in-tree navigation map says to read, changes the tree in the tree's own idiom, runs the in-tree green
command, and records the outcome in the in-tree queue. Nothing in this folder is consulted, and nothing
in this folder should need to change. If a pass on an emancipated submodule finds itself needing this
folder, that is a defect in the submodule's surface — the fix is to complete the missing material
in-tree, not to restore the dependency.

Where a submodule's advancement genuinely requires something outside it — a companion library, a backing
runtime, a second toolchain component — that requirement is recorded as a blocked question in the
submodule's own queue. `../riscv-dev/` is the sibling scaffold for library and runtime trees and runs the
same ladder toward the same independence; two emancipated trees may be related by a recorded pin and an
invocation, never by a path import or a shared document.

---

## 5. Invariants and non-goals

This folder never becomes a build dependency of a submodule, and no submodule becomes a build dependency
of its documents. Nothing here vendors, mirrors, or rewrites submodule source into the superproject: the
checkout is the only copy. No document here asserts a language, framework, or pipeline shape as a
precondition, and none treats RISC-V support as a measure of a submodule's worth. This folder is not a
permanent governance layer, not a registry that submodules must stay registered in, and not a place to
reimplement a compiler; it is a means of making a foreign tree self-describing, after which its own
success is measured by how little of it remains relevant.
