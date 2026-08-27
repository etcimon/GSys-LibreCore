# g6lc_qemu — live todo / stage state

In-tree queue for this package. **Retrieval contract:** every open item cites where its priors live —
by default this package's own `architecture/` docs; where a host project supplies the normative
contract, the pin in `pins.toml` plus the document it names.

| Layer | Open first | Role |
|---|---|---|
| Why / invariants | [`AGENTS.md`](AGENTS.md) | Independence, `E-GPLLINK`, generated-not-typed, profile rule |
| Licensing boundary | [`AGENTS-licensing.md`](AGENTS-licensing.md) | MIT in, GPL out, enforcement |
| Design | [`architecture/DESIGN.md`](architecture/DESIGN.md) | Backends, staging, structure |
| Ingest / IR | [`architecture/INGEST.md`](architecture/INGEST.md) · [`architecture/IR.md`](architecture/IR.md) | Readers, `TargetModel`, conformance |
| Emission | [`architecture/EMIT.md`](architecture/EMIT.md) | Emitter contract |
| Diagnosis | [`architecture/DIAG.md`](architecture/DIAG.md) | D1 / D2 tiers, error bars |
| CLI | [`architecture/CLI.md`](architecture/CLI.md) | Option surface |

**Green command:** `python tools/g6q.py check`

---

## Current stage

**Q0 — scaffold + skeleton. Complete.**

The package exists, is independent, and compiles. No ingest, no emission, no execution yet: every
crate is a documented stub with a real module boundary and at least one unit test. The next pass is
Q1 (ingest + IR + conformance), which is the stage everything else depends on.

| Stage | State |
|---|---|
| **Q0** scaffold, package surface, Rust skeleton | **done** |
| **Q1** ingest + `TargetModel` + conformance | next |
| **Q2** B0 stock-QEMU driver + firmware chain | open |
| **Q3** B3 native VM + tandem records | open |
| **Q4** B1 generated QEMU machine | open |
| **Q5** D1 tandem / replay / checkpoint | open |
| **Q6** accelerator ISA + device + in-guest runtime | open |
| **Q7** D2 microarchitectural + PMU | open |
| **Q8** MTTCG scale + virt profile + distro | open |
| **Q9** capability matrix | open |

---

## Open items

**G1 — Q1 ingest.** Implement `g6q-svcfg` (config-package reader + legality validator), `g6q-flist`
(expander + membership facts), `g6q-dts` (read / overlay / mutate / emit / validate) and `g6q-core`
(IR + conformance + canonical JSON). Exit gate: every target package in the host design round-trips
to golden JSON; an illegal configuration is rejected; the conformance report produces `stub`,
`undeclared` and `overdeclared` verdicts without any rule being hand-coded per capability.
*Priors: `architecture/INGEST.md`, `architecture/IR.md`.*

**G2 — Reader strategy escalation.** The Q0/Q1 config reader is deliberately narrow: it understands
`localparam` scalars, enum identifiers, named struct-literal members and simple arithmetic, and it
**fails loudly** rather than defaulting. If it proves brittle across real packages, escalate to a
vendored full SystemVerilog parser as an integral in-tree copy with a pin file — do not accumulate
special cases. Record the decision here before doing it.
*Priors: `architecture/INGEST.md` §2.*

**G3 — Schema stability.** `schemas/target-model.schema.json` and `conformance.schema.json` are
version-stamped from the first release. Any field rename is a `schema_version` bump plus a fixture
update; consumers read the version before the payload.
*Priors: `architecture/IR.md`.*

**G4 — Zero-dependency stance.** The workspace has no external crates and offline
`cargo test --workspace` must keep working. Adding a dependency requires a decision recorded here, a
`pins.toml` entry with an exact version, permissive licence only, and a note on offline behaviour.
*Priors: `AGENTS.md` §3, `AGENTS-licensing.md` §5.*

**G5 — `E-GPLLINK` regression.** `tools/check_independence.py` is the enforcement point. Extend it
whenever a new way to reach QEMU appears (a build script, a linker attribute, a vendored header). A
violation must be a build failure, never a review comment.
*Priors: `AGENTS-licensing.md` §2.3.*

**G6 — Profile discipline plumbing.** `profile` must be a required field of every artifact the moment
artifacts start existing (Q2). Retrofitting stamps after the fact is how a `g6lc-virt` result ends up
quoted as a hardware result.
*Priors: `architecture/DESIGN.md` §"Machine profiles".*

**G7 — Pin hygiene.** `pins.toml` currently records QEMU, OpenSBI, and the external contracts this
package consumes. Whenever a consumed contract changes upstream, bump the pin **and** the affected
schema/ABI version in the same pass. Never reinterpret bits silently.
*Priors: `AGENTS.md` §1.9.*

**G8 — Host adapter stays optional.** If a host project grows an adapter that spawns this CLI, it
lives in the host, not here, and the package must keep working without it.
*Priors: `AGENTS.md` §1.1.*

---

## Deferred (with reopen conditions)

| Item | Reopen when |
|---|---|
| B3 T1/T2 JIT tiers | the interpreter is measurably the bottleneck for a stage gate |
| Host-hypervisor acceleration | MTTCG plateaus below need *and* a single-host-OS backend is acceptable |
| Full vector-extension semantics | after Q7; reported as `stub` until then |
| Pipeline / cycle modelling | never — an RTL simulator owns cycles |
| Multi-target single binary | a convenience, not a gate |

---

## Pass log

| Date | Pass | Outcome |
|---|---|---|
| 2026-08-27 | Q0: package surface (`AGENTS*`, `README`, `LICENSE`, `pins.toml`), in-tree `architecture/`, Python spine (`g6q.py`, `env_common.py`, `flist_expand.py`, `check_independence.py`), Cargo workspace + nine std-only crate skeletons, synthetic fixtures, JSON schemas. | Package independent and compiling; `check` green on fixtures. Q1 unblocked. |
