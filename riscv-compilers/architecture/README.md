# `architecture/` — transitional readings only

The architectural notes produced by analysis belong **inside the submodule**, at `<id>/architecture/`,
indexed by that tree's own `architecture/README.md` and routed to by that tree's own `AGENTS.md`. They are
written for the code they describe and corrected whenever the tree invalidates them; that is what turns
analysis into a development substrate the project owns
([`../AGENTS-logisplain.md`](../AGENTS-logisplain.md) §5). By default they are written there and left
**untracked** ([`../AGENTS-bootstrap.md`](../AGENTS-bootstrap.md) §6 mode A), so the analysis sits beside the
code without entering the project's history or this repository's; committing it on a branch inside the
submodule is the opt-in.

This directory exists only for the interval in which even an untracked write is impossible — a read-only pin,
an undecided branch, an unfinished promotion — and for nothing else. While it is in use, `architecture/<id>/` holds
exactly what the in-tree set will hold, in exactly the form given by
[`../AGENTS-bootstrap.md`](../AGENTS-bootstrap.md) §5.4, so relocation is a move rather than a rewrite.
At emancipation (B7) the directory for that submodule is removed.

## What a note is

A note is **addressed to the next change**, not to a reader. It names an area of the system, explains in
cohesive prose how that area works and what it is responsible for, *locates* that responsibility as
concrete files and regions, states the invariants an incoming change must preserve and whether each is
held by construction or by convention, names the extension points where a change of a given kind belongs
and what must move with it, and closes with what the analysis did not resolve. A note that describes
without locating, or locates without stating invariants, leaves the next agent to redo the analysis and
should be rewritten rather than supplemented.

## The set

Once inventory and reading exist, the minimum set is an index; an overview note carrying the
representative journey through the system; one note per stage or subsystem that journey passed through; a
build-and-bootstrap note carrying the spine, the bootstrap relation, and the green command with its
*observed* behaviour; a dependency note recording what the tree needs and where it expects it; and an
open-questions note. The set then grows one note per area as passes reach new ground. It is never
expected to be complete, and no work is ever blocked on completing it.

## Voice

Notes are cohesive paragraphs, grounded in the code, neutral and precise, with anything unobserved marked
as unobserved in place rather than inferred into the prose. Tables and file-location lists are welcome
where they are genuinely navigational; they do not substitute for the paragraph that explains what moves
through the area and why it is arranged as it is.
