# AGENTS RISC-V Target — an inert porting dossier, engaged only on affinity

> **Status: inert.** This file governs nothing. It is not a standard against which a submodule is measured,
> not a precondition for admission, not a reason a pass exists, and not a document any submodule is obliged
> to read. A library under `riscv-dev/` may be advanced indefinitely — its interface clarity, its dependency
> footprint, its failure behaviour, its build portability, its test matrix — with none of the material below
> in play, and that is a complete and legitimate use of this folder.
>
> **Engagement is by affinity or by prompt.** Each submodule's own guider records a `riscv_affinity` value as
> an *observation* about its declared purpose: `none` (no architecture dimension), `latent` (the tree has a
> platform abstraction that could carry a new architecture, but nobody has asked), `declared` (the stated
> purpose reaches toward RISC-V), `active` (porting work is in progress). Only `declared` and `active`, or an
> explicit prompt, make this file relevant — and then only to the change at hand. When it does become
> relevant, the part that proves useful is **condensed into an in-tree note of the submodule's own**, because
> the terminal state of every submodule here is self-containment
> ([`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §4).

---

## 1. Why the dossier is shaped as questions

The failure mode this file is written against is a port that proceeds by adding architecture conditionals
until the test suite passes. That produces a library which builds on the new machine and has become
permanently more expensive to move to the next one. The useful preparation is knowing which *assumptions* a
new architecture puts under pressure and where a well-organised project would already concentrate them, so
that the first response can be to remove an assumption rather than to branch on it. The material below is
therefore organised as questions to answer from the tree and from the architecture's own normative text, not
as answers to copy. Any concrete value stated here is illustrative and must be verified against the
specification and against the machine actually being targeted.

---

## 2. What a port actually touches

**Capability is a property of the target, discovered rather than assumed.** RISC-V is a small base
architecture plus extensions that are individually present or absent, so a library that wants to use a
facility — hardware floating point, atomics, bit manipulation, vectors, a vendor extension — cannot assume it
exists. The questions are: does this tree have a notion of a capability at all, is it decided at build time
or at run time, where does that decision enter, and what is the fallback path when the facility is missing —
and is that fallback ever exercised, since an untested fallback is the defect that appears on the one machine
that lacks the extension.

**Word size, alignment and the data model.** Register width, pointer size, integer type widths, structure
alignment and packing are ABI properties of the target, not conveniences. The questions are: does the tree
assume a particular pointer or long width anywhere, does it assume that unaligned access is free or even
permitted, does it rely on structure layout being what one compiler produced, and does its test matrix
contain any cell that would notice.

**Atomics, memory ordering and threading.** Atomic operations are an extension rather than part of the base,
and the memory model governs what an ordering means and how acquire, release and fences map onto
instructions. A library's concurrency primitives therefore depend on target capability, and its
lock-free paths need a correct fallback. The questions are: where does the tree express atomicity and
ordering, does it use the language's model or its own inline sequences, and would a weaker-ordering machine
expose an assumption that a stronger one hid — which is the classic way a library that was correct for years
becomes wrong on a new architecture.

**Any architecture-specific code path.** Hand-written assembly, intrinsics, SIMD kernels, register-level
tricks, and code that reasons about instruction encodings are the parts a port must either reimplement or
route around. The questions are: how much such code exists, is it isolated behind a portable interface with a
generic implementation beside it, and does the generic path still work — because the answer decides whether a
port is a week or a quarter.

**Vector facilities are configuration, not a fixed width.** Where the target provides vectors, their length is
runtime-configured rather than fixed by the encoding, which is a different model from fixed-width SIMD and
cannot be represented by choosing a width. If the tree's abstraction cannot express a length unknown at compile
time, that is a structural finding to record rather than a gap to paper over.

**The system beneath the library.** The same architecture is used under a full operating system, under a
minimal runtime, and with none at all. What the library assumes exists at link and run time — a C runtime, a
threading implementation, a filesystem, a clock, a system call surface — is part of its portability, and often
the part that actually blocks a build. The questions are: what does the tree require of its environment, and is
that requirement stated anywhere or merely implied by what it happens to call.

**The build and the toolchain.** Cross-compilation, sysroots, target triples, and the availability of the
dependencies on the new target are usually the first wall, before any source-level portability question. The
questions are: does the tree support cross-compilation at all, how does it detect the target as opposed to the
host, and are its dependencies available for the target — and if a specific compiler is required to answer
this, the relation is recorded per [`AGENTS-toolchain-link.md`](AGENTS-toolchain-link.md).

**Execution for testing.** A port is unfinished while it cannot be *run*. Whether the produced artifact
executes under an emulator, a simulator, on hardware, or not yet, and whether the tree's harness can be pointed
at that execution method, determines whether the port has been validated or merely compiled. This is worth
establishing early, because it is frequently the real constraint.

---

## 3. Discovering a target rather than assuming one

When a submodule's work becomes `active`, the target should be *described* before it is represented: which base
and which extensions are actually present, which ABI variant is intended, what runtime and system interface
exist, how dependencies are obtained for it, and how a produced artifact will be executed for testing. Anything
that cannot be established is recorded as an unknown in the submodule's own notes rather than defaulted, because
a default here is an untested assumption that will surface much later as a link failure or a wrong answer.

If the target happens to be a configuration of the core that surrounds this scaffold, its enabled extension set
and ABI-visible parameters are discoverable from that project's own configuration surface and device
description, and its simulators and boot flow from its build tooling. That is genuinely useful when it applies,
and it is the one place where these folders touch the surrounding repository — but it is an *option a prompt may
take*, not a direction the folder points in. A submodule targeting a different RISC-V implementation, a generic
profile, an emulator, or no RISC-V at all is in no way a lesser use of this scaffold.

---

## 4. What engagement produces

A pass that engages this material leaves three things behind, all inside the submodule. The first is a porting
note in the submodule's own `architecture/`: which architecture, which capabilities relied upon and how
detected, which ABI, which runtime, which execution method for tests, and which specification version was
relied upon. The second is a set of extension points in the notes for the areas that had to change — the
capability-detection path, the platform layer, the atomic and ordering code, the build's target handling — so
that the next architecture costs less than this one did. The third is the honest statement of what remains
untested, since the characteristic porting defect is not a build failure but a library that builds and passes
on the machine it was ported on and misbehaves on the next one whose capability set differs.
