# AGENTS Selectivity — what is tracked, what stays local, what the scaffold may absorb

> **Scope:** generic rules for *where writing goes* when this folder lives inside a **host git
> repository** (a monorepo, worktree, or any superproject that already tracks `riscv-dev/` as
> documents). The ladder in [`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) is unchanged. This file
> only answers: which paths the host may record, which paths must stay out of the host, and which
> edits to the scaffold itself are allowed during a bootstrap pass.
>
> Nothing here names a language, package manager, compiler, or particular library. Those are
> outputs of admission and inventory, recorded in **untracked** process files or in a checkout’s
> own surface.

---

## 1. Why selectivity exists

The scaffold’s success is measured by how little of it remains relevant once a checkout is
emancipated ([`AGENTS.md`](AGENTS.md) §0). That fails in two common ways when the folder sits
inside another project:

1. **Host pollution.** Registering every library checkout as a *host* git submodule, or committing
   session notes into the host, couples the host history to foreign trees and to unfinished
   analysis.
2. **Scaffold churn.** Writing package-specific facts, toolchain versions, or pass logs into the
   tracked guiders (`AGENTS.md`, the ledger, this file) turns a generic instrument into a diary
   of one workspace.

Selectivity is the rule that prevents both.

---

## 2. Three layers of writing

| Layer | Typical paths | Host git | Purpose |
|---|---|---|---|
| **Scaffold (tracked)** | `AGENTS.md`, `AGENTS-*.md`, `README.md`, `LICENSE`, `agents/README.md`, `architecture/README.md` | **yes** | Generic contract, ladder, method. No package inventory. |
| **Process scratches (untracked)** | `TODO-scratch.md`, optional local env/install helpers, optional catalogs | **no** | Session board: which checkouts exist *here*, which commands were run, next step. |
| **Checkouts (untracked in the host)** | `<id>/` working trees | **no** (default) | The foreign trees. Each may be its own git repo. |
| **Local tools (untracked)** | `toolchains/`, caches, build debris | **no** | Compilers and extracts used to run green cells. |
| **Mode C shadows (untracked in the host)** | `agents/<id>.md`, `architecture/<id>/` | **no** (default) | Transitional B0–B3 material until it can live inside `<id>/`. |

The ledger [`AGENTS-todo.md`](AGENTS-todo.md) is **scaffold**: it may list admitted ids only when
an explicit pass is asked to write B0 rows. Until then, live workspace state belongs in
`TODO-scratch.md` (create it untracked if absent).

---

## 3. How a checkout is present (mechanism)

At B0 the **mechanism** field is required ([`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §2 B0).
When this folder is itself tracked by a host repository, the default mechanism is:

**`nested-clone`** — `git clone <upstream> <id>` (or an equivalent fetch) so `<id>/.git` is a
real repository. The host **does not** `git submodule add` that path. The host ignore file lists
a *generic* pattern for first-level checkout directories (see §5), not a catalog of names.

**`host-submodule`** is allowed only when the developer *explicitly* asks to register the
checkout in the host’s `.gitmodules`. It is never the default of a bootstrap pass.

**`snapshot`**, **`absent`/`planned`** remain as in the ladder.

The scaffold never vendors checkout source into tracked files.

---

## 4. Scaffold-preserving edits

A pass may **change tracked scaffold files** only when the change is *generic*: it clarifies the
ladder, the independence contract, selectivity, or a template that any future `<id>` will use.

A pass must **not** write into tracked scaffold files:

- a particular library’s name, pin, interface, or dependency graph
- a particular compiler version or install URL
- a session’s pass log or “what we did today”
- a list of checkouts present on this disk

Those belong in `TODO-scratch.md` or in `<id>/` (mode A/B) or in mode C shadows (untracked).

Updating [`AGENTS-todo.md`](AGENTS-todo.md)’s admission table is an **explicit** request (“admit
these ids to the ledger”), not a side effect of cloning or of writing scratches.

---

## 5. Host ignore (generic pattern)

When the host tracks this folder, it should ignore checkouts and tools by **pattern**, not by
enumerating package names. A sufficient first-level rule is: ignore every directory under
`riscv-dev/` except the scaffold directories `agents/` and `architecture/`.

Tracked files that live in the folder root (`AGENTS.md`, `README.md`, …) are unaffected. New
root-level helpers (`setenv`, install scripts, catalogs) stay **untracked** unless a later
generic pass promotes a *nameless* helper into the scaffold on purpose.

Mode C paths `agents/<id>.md` and `architecture/<id>/` stay untracked in the host so shadows can
exist without a host commit. The tracked files `agents/README.md` and `architecture/README.md`
remain the only permanent entries in those directories.

---

## 6. Relation to persistence modes A/B/C

[`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §6 still governs the **checkout**:

| Mode | Where the agentic surface lives | Host sees |
|---|---|---|
| **A** untracked-local | Inside `<id>/`, excluded in that repo’s `info/exclude` | Nothing (checkout itself untracked) |
| **B** branch | Inside `<id>/` on a working branch | Nothing unless `host-submodule` |
| **C** scaffold-staged | `agents/<id>.md`, `architecture/<id>/` | Untracked shadows only |

Selectivity adds the host axis; it does not replace A/B/C.

---

## 7. What an agent does by default

1. Leave tracked scaffold files unchanged unless the edit is generic (§4).
2. Do not `git submodule add` checkouts into the host.
3. Put session state in untracked `TODO-scratch.md`.
4. Put B0 stubs in untracked `agents/<id>.md` until asked to update the ledger.
5. Prefer writing B3+ notes inside `<id>/` (mode A) once the checkout is writable.
6. Never invent ignore lines that name a specific library; use the generic directory pattern.

If a later prompt says “admit to the ledger” or “register as host submodules”, that overrides the
defaults for the named ids only.
