# AGENTS Toolchain Link — an optional backing compiler, by pin and invocation only

> **Scope:** how a submodule under `riscv-dev/` may be *backed* by a compiler that is itself being advanced —
> typically one promoted under [`../riscv-compilers/`](../riscv-compilers/) — without either tree becoming
> dependent on the other's documents or paths. The relation is **optional**: most libraries are built with
> whatever toolchain the developer already has, and this file is irrelevant to them. It exists because a
> library that exercises a language feature, a code generator, or a runtime the compiler owns will otherwise
> accumulate failures it cannot attribute.

---

## 1. The problem it solves

When a library is built with a compiler that is itself under development, every failure has two possible
owners, and the cost of not knowing which is high: a pass spends its effort in the wrong tree, a defect is
reported upstream against the wrong project, or a real compiler bug is worked around in library code where it
will remain long after the compiler is fixed. Attribution is therefore not a nicety but the practical
requirement of the relation, and the whole mechanism below exists to make attribution possible.

---

## 2. What the relation is, and what it is not

The relation is a **recorded pin and a recorded invocation**. The library's own in-tree surface records which
toolchain build it was last known green against — identified by the compiler's version output and, where the
compiler is a tracked checkout, by its pin — and the exact invocation used to build with it, in the same form
and with the same discipline as the green command itself. That is the entirety of the coupling.

The relation is **not** a path import: the library's build must not reach into a sibling folder, and its
documents must not reference one, because either would break the independence the ladder exists to produce
([`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §4). It is **not** a requirement: the library must remain
buildable with a released toolchain, and if it is not, that is itself the most important fact in its queue. And
it is **not** shared ownership of documents: the compiler's notes live in the compiler's tree and the library's
in the library's, and a fact relevant to both is written down twice rather than linked once.

---

## 3. Recording it in-tree

The library's own guider carries the toolchain facts in its provenance block or immediately beside it: which
toolchain identity it was green against, which invocation was used, whether a released toolchain also works,
and — if a development toolchain is currently required — the single reason why, stated concretely enough to be
retested later. A library that requires an unreleased compiler for a reason nobody wrote down has acquired an
invisible dependency, which is the failure this recording prevents.

Where the requirement is a specific compiler behaviour rather than a version, the behaviour is the thing to
record: the language feature, the code-generation property, or the runtime facility the library depends on, and
the smallest test that demonstrates its presence. That test is worth more than the version number, because it
keeps working when versions move.

---

## 4. Attribution during a pass

A pass on a library backed by a development toolchain establishes, before diagnosing anything, whether the
failure survives a change of toolchain. If the same source fails on a released compiler and passes on the
development one, or the reverse, the failure belongs to the toolchain and the library's queue records it as an
external blocker with the minimal reproduction attached — and, if the compiler is being advanced in the sibling
scaffold, that reproduction is what its queue receives. If the failure is present on both, it belongs to the
library. Where the distinction genuinely cannot be drawn, that inability is itself the finding and is recorded
rather than resolved by guesswork.

The corollary is a discipline about workarounds. A workaround for a toolchain defect is written as a
workaround — marked, scoped, and paired with the reproduction that will tell a future pass it can be removed —
because an unmarked workaround becomes indistinguishable from design and outlives the defect by years.

---

## 5. Both trees stay independent

Two emancipated trees related in this way remain independently checkoutable, independently buildable with a
released toolchain where possible, and independently understandable from their own notes. The relation lives as
a recorded fact in each, not as a structure spanning them, which is what allows either to be moved, forked, or
sent upstream without carrying the other along.
