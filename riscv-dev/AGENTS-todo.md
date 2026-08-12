# riscv-dev — scaffold ledger

Live state for the **bootstrap scaffold only**. Its job is to say which submodules exist and which rung of the
ladder each has reached, and then to go quiet: once a submodule is emancipated
([`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §4), its state lives in its **own** in-tree `AGENTS-todo.md` and
its row here shrinks to a pointer. A long, detailed row in this file is a sign that material which belongs in a
submodule is still being held outside it.

**Retrieval contract:** every open item cites where its priors live. By default that is the submodule's own
`<id>/architecture/` notes and its in-tree guider — untracked there unless the developer opted into a branch
([`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §6) — and only for a checkout that cannot be written to is it the
staged copy under this folder's `architecture/<id>/`.

| Layer | Open first | Role |
|---|---|---|
| Why the scaffold exists | [`AGENTS.md`](AGENTS.md) | Independence contract, navigation, what a pass is |
| How a tree is promoted | [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) | B0–B7, staleness, independence test, in-tree templates |
| How it is read | [`AGENTS-logisplain.md`](AGENTS-logisplain.md) | Analysis method; notes addressed to the next change |
| What kind of change | [`AGENTS-philosophy.md`](AGENTS-philosophy.md) | Library/runtime posture, finished-pass checklist |
| Backing toolchain | [`AGENTS-toolchain-link.md`](AGENTS-toolchain-link.md) | Optional compiler relation; failure attribution |
| Porting material (inert) | [`AGENTS-riscv-target.md`](AGENTS-riscv-target.md) | Engaged only on `declared`/`active` affinity or by prompt |

---

## Current state

**No submodules admitted.** The scaffold is complete and unused: `agents/` and `architecture/` are empty by
design, and the first entry in the table below appears when a checkout is admitted at B0.

| id | upstream | pin | rung | affinity | green state / cell | backing toolchain | priors |
|---|---|---|---|---|---|---|---|
| _(none)_ | — | — | — | — | — | — | — |

---

## Open items

**S1 — First admission.** Nothing is admitted until a developer names a library or runtime to work on.
Admission is cheap and reversible: record id, upstream, pin, mechanism, and a one-line purpose per
[`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §2 B0, then stop. Do not pre-populate an interface description, a
dependency list, or a build command for a tree that is not present.
_Priors: `AGENTS-bootstrap.md` §2 (B0), §7 (status vocabulary)._

**S2 — Emancipation hygiene.** Whenever a submodule reaches B7, delete its transitional `architecture/<id>/`,
reduce `agents/<id>.md` to a pointer or remove it, and shrink its row above to a pointer at the submodule's own
queue. Re-run the three independence questions first; a submodule that still needs the scaffold is
mid-transition, and the remedy is to complete the in-tree surface.
_Priors: `AGENTS-bootstrap.md` §4, §6, §2 (B7)._

**S3 — Scaffold drift.** If two or more submodules need the same clarification of the ladder, the clarification
belongs in `AGENTS-bootstrap.md`, not repeated in each in-tree surface. If only one ever needs it, it belongs in
that submodule's own notes. Keeping this distinction is what stops the scaffold from re-accumulating governance
it is supposed to shed.
_Priors: `AGENTS.md` §0.2 (carry by value), §5 (non-goals)._

**S4 — Toolchain attribution.** Any submodule recorded as backed by a development toolchain must carry, in its
own tree, the invocation, the identity it was green against, and the concrete reason a released toolchain is
insufficient. An unexplained toolchain requirement is an invisible dependency and is treated as an open blocker.
_Priors: `AGENTS-toolchain-link.md` §3–§4._

---

## Pass log

| date | pass | outcome |
|---|---|---|
| 2026-08-12 | Scaffold authored: guider, ladder (B0–B7), analysis method, philosophy, optional toolchain-link relation, inert porting dossier, transitional-directory conventions, human README. | Ready for first admission; no submodules present. |
