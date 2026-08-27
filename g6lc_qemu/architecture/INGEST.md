# INGEST — readers

Index: [`README.md`](README.md) · Output: [`IR.md`](IR.md).
Crates: `g6q-svcfg`, `g6q-flist`, `g6q-dts`, and the PMU table reader in `g6q-core`.

Ingest is the only part of the package that touches the design's files, and it is strictly
**read-only** — never an edit, never a copyright or SPDX line
([`../AGENTS-licensing.md`](../AGENTS-licensing.md) §3).

---

## 1. Planes

| `--plane` | Reads | Produces |
|---|---|---|
| `core` | core configuration package(s), the shared configuration struct + legality rules, the PMU event matrix, core flists | ISA, CSR, microarchitecture facts, PMU table, instruction-supply selection |
| `apu` | SoC/peripheral package, SoC flist, accelerator island configuration and descriptor package | memory map, peripherals, interrupt-controller geometry, accelerator MMIO + descriptor ABI |
| `soc` (default) | both | the complete machine |

Device trees are read alongside either plane and cross-checked against both.

`--plane core` is useful alone: it is what an ISA-only run needs, and what the accelerator's
core-attached instruction model needs without pulling in the island device.

---

## 2. `g6q-svcfg` — configuration-package reader

### 2.1 Deliberately narrow

The inputs are a small number of stylistically uniform package files: a `typedef struct packed`
describing the configuration type, `localparam` scalars, and one named struct literal per target
package. A complete SystemVerilog parser is a large dependency for that job.

The reader therefore resolves:

- `localparam` scalars and simple integer arithmetic (`+ - * / <<`, `2**n`, `$clog2`);
- `` `define `` substitution;
- enum identifiers (predictor type, replacement policy, thread-select policy, coherence policy,
  coprocessor selection) as symbolic strings, not integers;
- named struct-literal members `Field: value,` including nested structs;
- `'0`, `1'b1`, sized literals, and identifier references to previously resolved parameters.

**It fails loudly.** Anything it cannot resolve becomes `unresolved` in the model rather than
silently defaulting, and `--conform strict` treats `unresolved` as fatal. A reader that guesses is
worse than a reader that stops, because a guessed configuration produces a *plausible* wrong emulator.

### 2.2 Field discovery is data-driven

The reader walks the configuration struct definition and carries **every** member into the model,
whether or not the package assigns semantic meaning to it. Fields the model understands are typed;
the rest land in `uarch.raw`. Consequence: a new knob added to the design appears in the model without
an edit here, and a backend can start using it without a re-ingest pass.

### 2.3 Legality mirroring

The configuration struct is normally accompanied by elaboration-time legality assertions
(power-of-two table sizes, predictor prerequisites, thread and core count ceilings, mutually exclusive
seams). The reader re-expresses them as a **validator**, so a configuration the RTL would refuse to
elaborate cannot produce a running emulator. Without this, "it works in QEMU" can be reported for a
design that does not build.

### 2.4 Escalation, recorded in advance

If the narrow reader proves brittle across real packages, escalate to a **vendored full SystemVerilog
parser** as an integral in-tree copy with a pin file and patches applied in sort order — do not
accumulate special cases. The Q1 gate (every target package round-tripping to golden JSON) is what
makes brittleness detectable instead of latent. Decision is recorded in
[`../AGENTS-todo.md`](../AGENTS-todo.md) G2 before it is taken.

---

## 3. `g6q-flist` — expansion and membership

A generic `.f` reader: file paths, `#` and `//` comments, `+incdir+`, `+define+`, nested `-f` / `-F`
with cycle guarding, and `${VAR}` / `$VAR` expansion from an **explicit** `--set` map. No project
variable name is baked in; the caller supplies the map, which is what lets the package run against any
tree.

Two outputs:

1. the **file set** actually compiled for this target;
2. the **define set** in effect.

From those, membership facts the model needs:

| Fact | Derived from |
|---|---|
| Is an optional accelerator/vector unit real, or a stub? | presence of its flist and source tree vs. a stub decoder file |
| Which instruction-supply variant is compiled? | which supply flist is included, plus the selecting `+define+` |
| Are optional cache levels present? | presence of their source trees in the set |
| Gate-level vs RTL manifest | which manifest was used |
| Board-conditional sizing | conditional defines that change package constants |

Membership is why the conformance report can say `stub` instead of trusting a configuration bit.

---

## 4. `g6q-dts` — device tree

Reads a source or binary device tree into a small node/property tree; supports overlay merge, path
mutation (`--dts-set`), deletion (`--dts-del`), synthesis from the model (`--dts-generate`), and
emission back to source or binary.

Properties understood **semantically** — as opposed to carried opaquely — are the ones that make a
claim about the hardware:

ISA base and extension list · MMU mode and split-TLB flag · cache block sizes and geometry ·
cache-maintenance block sizes · CPU topology map (cluster / core / thread) · timebase and clock
frequency · PMU event mapping · hart-local interrupt controller · timer/software-interrupt controller ·
external interrupt controller and its device count · memory regions · `chosen` boot arguments and
console · accelerator device node and its discovery properties.

`--dts-validate` re-checks these against the ingested configuration and flist facts and reports in a
FAIL / WARN / GAP vocabulary, so it can agree with whatever validation the design project already runs.

---

## 5. PMU event table

The design's performance-counter module holds an event matrix indexed by `{group, index}`. The reader
extracts group → index → symbolic event name.

This single table then feeds three consumers that must agree:

1. the D2 counter implementation ([`DIAG.md`](DIAG.md) §4);
2. the generated device-tree PMU mapping, so the guest kernel's `perf` sees consistent events;
3. the model's `pmu` block, so a report can name events rather than print indices.

Because it is derived, a new event added to the design's counter module appears in the emulator
without an edit here.

---

## 6. Determinism and provenance

- Every source file is hashed; the model records a SHA-256 per file plus the design revision when
  discoverable.
- Re-running ingest on an unchanged tree produces a **byte-identical** model (canonical ordering
  everywhere, no timestamps).
- `--cfg-override` values are recorded as `synthetic` with their origin, never folded silently into
  the configuration, and the taint propagates into every downstream artifact.
- Golden fixtures under `../fixtures/` are **synthetic** ([`../AGENTS-licensing.md`](../AGENTS-licensing.md)
  §4) and are what let `cargo test --workspace` pass with only this tree.
