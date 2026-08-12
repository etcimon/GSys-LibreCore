# AGENTS RISC-V Target — an inert dossier, engaged only on affinity

> **Status: inert.** This file governs nothing. It is not a standard against which a submodule is
> measured, not a precondition for admission, not a reason a pass exists, and not a document any
> submodule is obliged to read. A compiler under `riscv-compilers/` may be advanced indefinitely — its
> diagnostics, its bootstrap reproducibility, its parsing correctness, its internal representations —
> with none of the material below in play, and that is a complete and legitimate use of this folder.
>
> **Engagement is by affinity or by prompt.** Each submodule's own guider records a `riscv_affinity`
> value as an *observation* about its declared purpose: `none` (no target dimension), `latent` (the tree
> has a target abstraction that could carry RISC-V, but nobody has asked), `declared` (the developer's
> stated purpose reaches toward RISC-V), `active` (target work is in progress). Only `declared` and
> `active`, or an explicit prompt, make this file relevant — and then only to the specific change at
> hand. When it does become relevant, the part that proves useful is **condensed into an in-tree note of
> the submodule's own**, because the terminal state of every submodule here is self-containment
> ([`AGENTS-bootstrap.md`](AGENTS-bootstrap.md) §4).

---

## 1. Why the dossier is shaped as questions

The failure mode this file is written against is a compiler change that treats an architecture as a list
of facts to be hard-coded. A target is not a list; it is a set of *decisions the tree must be able to
represent*, and the useful preparation is knowing which decisions exist and where a project would
normally express them. The material below is therefore organised as the questions a codegen or porting
pass must answer from its own tree and from the architecture's own normative text, not as answers to be
copied. Any concrete value stated here is illustrative of the shape of the answer and must be verified
against the specification and against the target machine actually being compiled for.

The normative source is the RISC-V ISA specification, with the ABI and psABI documents as the separate
contract layer above it. Where this repository happens to carry a copy of the ISA manual and an annotated
index of it, that is a convenience for a reader who is already here, not a dependency of any submodule; a
submodule that has engaged this material writes down which document and which version it relied on, in
its own tree.

---

## 2. What a compiler must be able to represent

**The base and the extension set are a property of the target, not a constant.** RISC-V is defined as a
small base integer architecture plus extensions that are individually present or absent, so a compiler's
target model must carry an extension set rather than a fixed instruction repertoire, must be able to
answer "may I emit this instruction" from that set, and must be able to report the set it compiled for in
a form other tools can read. Hard-coding a popular combination is the single most common way a RISC-V back
end becomes wrong on a real machine: the machine that actually exists may lack a floating-point unit, may
lack compressed instructions, may add atomics or bit-manipulation or vector facilities, and may add
vendor-defined extensions the compiler has never heard of. The questions are therefore: where does this
tree hold its notion of an enabled feature set, how does a command-line specification of that set reach
code generation, what does the tree do with a feature it does not recognise, and how does the set reach the
emitted artifact so that a linker or a loader can check compatibility.

**The data model and the calling convention are contracts, not choices.** Register width, integer and
pointer sizes, the argument and return registers, stack alignment, how aggregates and variadic arguments
are passed, whether floating-point arguments travel in floating-point registers, and how the frame is laid
out are all fixed by the ABI for a given target rather than by the compiler's convenience — and a
mismatch does not fail to compile, it fails to link or, worse, links and misbehaves. The questions are:
where does this tree describe a calling convention, is that description declarative or scattered through
emission code, how would a second ABI variant coexist with the first, and does the tree's own test harness
have any way of *detecting* an ABI deviation, since an ordinary functional test suite generally cannot.

**Addressing has a code-model dimension.** Because the architecture builds large constants and long
branches out of instruction pairs, a compiler must decide how far away it is allowed to assume things are,
and that decision propagates into relocation choices, into the layout the linker is asked to produce, and
into whether small or large data lands in a short-addressable region. The questions are: does this tree
have a code-model concept at all, where does an address materialise as instructions, and what does it
assume about the distance between code and data.

**Relocations and linker cooperation are part of the output.** The architecture's toolchains rely on the
assembler and linker to complete work the compiler deliberately leaves open, including relaxation of
conservative sequences into shorter ones. A compiler that emits sequences the linker is expected to rewrite
must emit them in the form the linker recognises, and a compiler that assumes final layout may defeat
relaxation or, worse, be silently invalidated by it. The questions are: does this tree emit assembly or
objects directly, which relocation vocabulary does it use, and does anything in its correctness argument
depend on layout that relaxation may change.

**Atomics and memory ordering must be derived, not assumed.** The base architecture has no atomics; they
arrive as an extension, with a separate memory model governing what orderings mean and how fences and
acquire/release annotations map onto instructions. A language runtime's atomic and memory-ordering
primitives must therefore lower differently depending on the target's extension set, and must have a
correct fallback when the facility is absent. The questions are: where does this tree lower atomic and
fence operations, does the lowering consult the feature set, and is the fallback path exercised by anything.

**Vector and other wide facilities are configuration, not a fixed width.** Where the target provides a
vector facility, its width and shape are runtime-configured rather than fixed by the instruction encoding,
which is a different model from fixed-width SIMD and cannot be represented by pretending a width. The
question for a compiler is whether its vectorisation abstraction can express a length that is unknown at
compile time at all; if it cannot, that is a structural finding to record rather than a gap to paper over.

**Bare-metal and hosted are different targets.** The same architecture is used with a full operating
system, with a minimal runtime, and with no runtime at all, and the difference shows up in the compiler as
the presence or absence of a system interface, in start-up and linkage expectations, and in what the test
harness is even able to execute. The questions are: what does this tree assume exists at link time, and can
its harness run a produced artifact on this target at all — under an emulator, under a simulator, on
hardware, or not yet.

---

## 3. Discovering a target rather than assuming one

When a submodule's work becomes `active`, the target it is compiling for should be treated as something to
be *described* and then represented, in this order: which base and which extensions are actually present,
which ABI variant is intended, what the code model and memory layout are, what runtime exists, and how a
produced artifact will be executed for testing. Any of these that cannot be established is recorded as an
unknown in the submodule's own notes rather than defaulted, because a default here is an untested
assumption that will surface as a link or run failure much later.

If the target in question happens to be a configuration of the core that surrounds this scaffold, its
enabled extension set and its ABI-visible parameters are discoverable from that project's own
configuration surface and device description, and its simulators and boot flow are discoverable from its
build tooling. That is genuinely useful when it applies, and it is the one place where these folders touch
the surrounding repository — but it is an *option a prompt may take*, not a direction the folder points in.
A submodule targeting an entirely different RISC-V implementation, or a generic profile, or an emulator, is
in no way a lesser use of this scaffold, and a submodule with no target ambition at all is not using this
file.

---

## 4. What engagement produces

A pass that engages this material leaves three things behind, all inside the submodule. The first is a
target note in the submodule's own `architecture/`: which architecture, which extension set, which ABI,
which code model, which runtime, which execution method for tests, and which specification version was
relied upon. The second is a set of extension points in the notes for the areas that had to change — the
feature-set representation, the calling-convention description, the atomic lowering, the relocation
emission — so that the next target question costs less than this one did. The third is the honest
statement of what remains untested, since the characteristic RISC-V defect is not a compile failure but a
correct-looking artifact that misbehaves on a machine whose extension set or ABI differs from the one
assumed.
