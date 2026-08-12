# riscv-compilers — scaffold ledger

Live state for the **bootstrap scaffold only**. Its job is to say which submodules exist and which rung
of the ladder each has reached, and then to go quiet: once a submodule is emancipated
([`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §4), its state lives in its **own** in-tree
`AGENTS-todo.md` and its row here shrinks to a pointer. A long, detailed row in this file is a sign that
material which belongs in a submodule is still being held outside it.

**Retrieval contract:** every open item cites where its priors live. Before emancipation those are the
transitional `architecture/<id>/` notes; after it, the submodule's own `architecture/` and guider.

| Layer | Open first | Role |
|---|---|---|
| Why the scaffold exists | [`AGENTS.md`](AGENTS.md) | Independence contract, navigation, what a pass is |
| How a tree is promoted | [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) | B0–B7, staleness, independence test, in-tree templates |
| How it is read | [`AGENTS-logisplain.md`](AGENTS-logisplain.md) | Analysis method; notes addressed to the next change |
| What kind of change | [`AGENTS-philosophy.md`](AGENTS-philosophy.md) | Engineering posture, finished-pass checklist |
| Target material (inert) | [`AGENTS-riscv-target.md`](AGENTS-riscv-target.md) | Engaged only on `declared`/`active` affinity or by prompt |

---

## Current state

**No submodules admitted.** The scaffold is complete and unused: `agents/` and `architecture/` are empty
by design, and the first entry in the table below appears when a checkout is admitted at B0.

| id | upstream | pin | rung | affinity | green state | priors |
|---|---|---|---|---|---|---|
| _(none)_ | — | — | — | — | — | — |

---

## Open items

**S1 — First admission.** Nothing is admitted until a developer names a compiler to work on. Admission is
cheap and reversible: record id, upstream, pin, mechanism, and a one-line purpose per
[`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §2 B0, then stop. Do not pre-populate a pipeline description,
a build command, or a language census for a tree that is not present.
_Priors: `AGENTS-bootstrap.md` §2 (B0), §7 (status vocabulary)._

**S2 — Emancipation hygiene.** Whenever a submodule reaches B7, delete its transitional
`architecture/<id>/`, reduce `agents/<id>.md` to a pointer or remove it, and shrink its row above to a
pointer at the submodule's own queue. Re-run the three independence questions before doing so; a
submodule that still needs the scaffold is mid-transition, and the remedy is to complete the in-tree
surface.
_Priors: `AGENTS-bootstrap.md` §4, §6, §2 (B7)._

**S3 — Scaffold drift.** If two or more submodules require the same clarification of the ladder, the
clarification belongs in `AGENTS-bootstrap.md`, not repeated in each in-tree surface. If a clarification
is only ever needed by one submodule, it belongs in that submodule's own notes. Keeping this distinction
is what stops the scaffold from re-accumulating governance it is supposed to shed.
_Priors: `AGENTS.md` §0.2 (carry by value), §5 (non-goals)._

---

## Pass log

| date | pass | outcome |
|---|---|---|
| 2026-08-12 | Scaffold authored: guider, ladder (B0–B7), analysis method, philosophy, inert target dossier, transitional-directory conventions, human README. | Ready for first admission; no submodules present. |
