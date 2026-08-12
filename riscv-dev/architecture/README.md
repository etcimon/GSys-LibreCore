# `architecture/` — transitional readings only

The architectural notes produced by analysis belong **inside the submodule**, at `<id>/architecture/`, indexed
by that tree's own `architecture/README.md` and routed to by that tree's own `AGENTS.md`. They are written for
the code they describe, versioned with it, and corrected in the same commit that invalidates them; that is what
turns analysis into a development substrate the project owns
([`../AGENTS-logisplain.md`](../AGENTS-logisplain.md) §5).

This directory exists for the interval in which that is not yet possible — a read-only pin, an undecided
branch, an unfinished promotion — and for nothing else. While in use, `architecture/<id>/` holds exactly what
the in-tree set will hold, in the form given by [`../AGENTS-bootstrap.md`](../AGENTS-bootstrap.md) §5.4, so
relocation is a move rather than a rewrite. At emancipation (B7) the directory for that submodule is removed.

## What a note is

A note is **addressed to the next change**, not to a reader. It names an area of the system, explains in
cohesive prose how that area works and what it is responsible for, *locates* that responsibility as concrete
files and regions, states the invariants an incoming change must preserve and whether each is held by
construction or by convention, names the extension points where a change of a given kind belongs and what must
move with it, and closes with what the analysis did not resolve. A note that describes without locating, or
locates without stating invariants, leaves the next agent to redo the analysis and should be rewritten rather
than supplemented.

## The set

Once inventory and reading exist, the minimum set is an index; an overview note carrying the representative
journey inward from a public entry point; an **interface note** saying what the promise is and where its
boundary truly falls; a **dependency and environment note** saying what the tree needs and what it believes
about the machine beneath it; a **build, packaging and test-matrix note** carrying the green command with its
*observed* behaviour and the cell it exercised; notes per subsystem the journey passed through; and an
open-questions note. The set grows one note per area as passes reach new ground. It is never expected to be
complete, and no work is ever blocked on completing it.

## Voice

Notes are cohesive paragraphs, grounded in the code, neutral and precise, with anything unobserved marked as
unobserved in place rather than inferred into the prose. Tables and file-location lists are welcome where they
are genuinely navigational; they do not substitute for the paragraph that explains what moves through the area
and why it is arranged as it is.
