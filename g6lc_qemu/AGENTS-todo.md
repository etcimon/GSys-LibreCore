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

**Q1 — ingest, `TargetModel`, conformance. Complete.**

The three readers work against real input, the model assembles from them, and `gen` / `conform` are
live. Nothing is emitted or executed yet.

Verified against a real design tree (opt-in soaks, `G6Q_DESIGN_ROOT`): **21 configuration packages**
parse at 165 fields with **0 unresolved** and all legal; **7 device trees** parse with topologies
matching their documented `cores × threads` shapes; model generation is **byte-identical** on re-run.

Findings the conformance report produces unaided, each an inputs disagreement rather than a rule
written for it:

| Target | Finding |
|---|---|
| vector-enabled target | `stub` **+** `overdeclared` — enabled in configuration, vector manifest not in the build, tree still advertises the tokens |
| all targets | second-level cache `stub` — enabled in configuration, its RTL on no manifest |
| two targets | hypervisor `undeclared` — live in RTL, token deliberately omitted from the tree |
| all targets | NAPOT pages `undeclared` |
| accelerator target | **topology**: 2 logical harts in configuration, 1 `cpu@` node in the tree — software would see one |

| Stage | State |
|---|---|
| **Q0** scaffold, package surface, Rust skeleton | **done** |
| **Q1** ingest + `TargetModel` + conformance | **done** |
| **Q2** B0 stock-QEMU driver + firmware chain | **done** — emission complete; boot gate pending host tooling (§Q2) |
| **Q3** B3 native VM + tandem records | **in progress** — RV64I decoder, register file, flat memory and interpreter green; M/A/F/D/C/Zicsr + Sv39 next |
| **Q4** B1 generated QEMU machine | open |
| **Q5** D1 tandem / replay / checkpoint | open |
| **Q6** accelerator ISA + device + in-guest runtime | open |
| **Q7** D2 microarchitectural + PMU | open |
| **Q8** MTTCG scale + virt profile + distro | open |
| **Q9** capability matrix | open |

---

### Q2 status — emission complete, boot gate pending host tooling

Landed and tested offline:

- **`--emit args`** — full invocation from the model: machine, processor properties from
  live capabilities only, processor count, memory, firmware mode, disks, networking with port
  forwards, serial, deterministic time. Plus the **capability delta**: what a stock model cannot
  express (vendor extensions, the coprocessor seam, the memory map, and a hart-topology mismatch
  when there is one).
- **`--emit dts` / `--emit dtb`** — a flattened-tree writer *and* reader, so no external
  device-tree compiler is needed. All 7 real trees round-trip with their facts intact.
- Disks and networking are **refused on the faithful machine**, which genuinely has neither.

**Not verified, and cannot be on this host:** no emulator, no device-tree compiler and no
cross-toolchain are installed, so the Q2 exit gate — firmware banner and a shell on a stock
binary — has not been demonstrated. Two consequences worth stating plainly:

- **`qemu` property names in the capability table are unvalidated.** Most default to the
  device-tree token, which is usually right. Check `-cpu help` on the pinned release before
  trusting a boot. A wrong name fails at start-up rather than silently, which is the better
  failure.
- **The firmware chain (`g6q fw`) is not implemented.** It needs a cross-toolchain to be
  meaningful, and building it blind against the in-tree profile would be guesswork.

Closing Q2 needs an emulator and a toolchain on the host, then: validate the property names,
implement `fw`, and run the two boots.

## Open items

**G1 — Q1 ingest. Closed.** Readers, model assembly, capability table, `gen` and `conform` are live
and soaked against a real tree. Remaining Q1-adjacent work is device-tree *mutation* (`--dts-set`,
`--dts-del`, overlay merge, blob emission) and `--dts-validate`, which land with the command-line
surface that needs them at Q2.
*Priors: `architecture/INGEST.md`, `architecture/IR.md`.*

**G9 — Interrupt-controller capacity is not read.** `intc_targets` currently counts the contexts a
**board wires**, taken from the controller's `interrupts-extended` list. The controller's hardware
capacity lives in the design's SoC package, which the `apu` plane does not read yet. Until it does,
`max_harts` describes what the board connects, not what the silicon could serve. The model reports
`null` rather than `0` when the number is unknown, so nothing downstream mistakes ignorance for a
limit. Close this when the SoC-package reader lands.
*Priors: `architecture/INGEST.md` §1 (planes).*

**G10 — Capability table coverage.** `crates/g6q-ingest/data/capabilities.ini` covers the extension
and unit surface reached so far. It is data and is expected to grow; two rules keep it honest. A
capability with no separate compilation unit must have **no** `impl` entry, or manifest membership
will report it as a stub. A capability the device tree cannot express must have **no** `dts` entry —
giving privilege modes extension tokens produced a false `undeclared` on every target until it was
removed.
*Priors: `crates/g6q-ingest/data/capabilities.ini` header.*

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
| 2026-08-27 | Q1: configuration reader + legality rules; manifest membership with a three-valued presence; device-tree parser + semantic extraction; `g6q-ingest` (10th crate) with the data-driven capability table; `gen` and `conform` implemented. Contained toolchain provisioned by `setup`. | 174 tests green on the package's **own** toolchain; 21 packages and 7 trees soaked; model byte-identical on re-run. Q2 unblocked. |

### Defects found and fixed while soaking Q1

| Defect | Why it mattered |
|---|---|
| POSIX absolute paths were treated as relative on one host | every membership query silently missed — a tooling gap that reads as a design fact |
| Unterminated preprocessor directives swallowed the declaration after them | one real package parsed to an **empty** configuration, silently |
| String lists split on raw commas | every vendor-prefixed `compatible` and `mmu-type` was cut in half |
| An unreadable nested manifest aborted the whole manifest | dropped the core file set, so core units reported `stub` rather than "unknown" |
| Manifest gaps rendered as `stub` | "could not tell" presented as a claim about the design; now `unresolved` |
| Post-inference legality rules applied to source values | flagged valid packages (`0` means *infer* for cache size and issue width) |
| `setup` used the run-time environment | would have installed the toolchain into the user's home instead of the package |
| Unknown interrupt budget reported as `0` | stated a limit the inputs do not support; now `null` |
| Privilege modes given device-tree tokens | false `undeclared` on every target |
