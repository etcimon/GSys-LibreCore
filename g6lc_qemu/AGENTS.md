# g6lc_qemu — Agent Guider (package root)

> **Scope:** This file is the entry point for agents working **inside `g6lc_qemu/`**.
> The package is **project-independent**: it must build, test, and generate its emulation artifacts
> with only this tree + `fixtures/`. Host monorepos (GSys LibreCore / CVA6 `build-platform`) are
> **optional consumers** that pass paths on the command line — they never become crate dependencies.

| Artifact | Path | Role |
|---|---|---|
| **This guider** | `AGENTS.md` | Purpose, invariants, navigation, extension playbook |
| **Live todo / state** | [`AGENTS-todo.md`](AGENTS-todo.md) | Stage checklist; update every pass |
| **Licensing** | [`AGENTS-licensing.md`](AGENTS-licensing.md) | MIT first-party; the **GPL-out boundary** |
| **Architecture index** | [`architecture/README.md`](architecture/README.md) | Map of in-tree design docs |
| **System design** | [`architecture/DESIGN.md`](architecture/DESIGN.md) | End-to-end shape, backends, staging |
| **Ingest** | [`architecture/INGEST.md`](architecture/INGEST.md) | Config / flist / DTS readers |
| **IR** | [`architecture/IR.md`](architecture/IR.md) | `TargetModel` + conformance report |
| **Emission** | [`architecture/EMIT.md`](architecture/EMIT.md) | B0–B3 emitter contract |
| **Diagnosis** | [`architecture/DIAG.md`](architecture/DIAG.md) | D1 tandem / D2 microarchitectural |
| **CLI** | [`architecture/CLI.md`](architecture/CLI.md) | Complete option surface |
| **Human entry** | [`README.md`](README.md) | Quickstart, usable without knowing any monorepo |
| **Terms** | [`LICENSE`](LICENSE) | MIT |

---

## 0. Purpose — a generator, not an emulator you maintain by hand

**`g6lc_qemu` reads a LibreCore-shaped design and generates the machinery to emulate it.**

Inputs are the design's **own** files: the SystemVerilog config packages, the flists that say what is
actually compiled, the SoC package that fixes the memory map, the device trees, and the PMU event
matrix. Outputs are four backends over one IR:

| # | Backend | Output | License of output |
|---|---|---|---|
| **B0** | stock-QEMU driver | argv + `.dtb` + `-cpu` props (**no code emitted**) | — |
| **B1** | QEMU machine + CPU | C into a QEMU checkout | **GPL-2.0**, separate work |
| **B2** | QEMU TCG plugins | C against the plugin ABI | **GPL-2.0**, separate work |
| **B3** | native Rust VM | Rust, in this tree | **MIT** |

…plus a two-tier diagnosis layer: **D1** tandem (RVFI-shaped lockstep, divergence bisection,
checkpoints) and **D2** microarchitectural (structures sized from the config; PMU counters from the
design's own event table).

| What this package **is** | What this package **is not** |
|---|---|
| A generator over config + flist + DTS | A hand-maintained emulator |
| A conformance reporter for design/flist/DTS disagreement | A second source of truth for the ISA |
| An MIT tool that *writes* GPL C | A QEMU fork, or anything that links QEMU |
| A triage and bisection instrument | A source of citable verification evidence |
| A cycle-informative model | A cycle-accurate model |

---

## 1. Prime directives

1. **Independence (KD0).** `cargo test --workspace` and every default command succeed with only this
   tree + `fixtures/`. No compile- or link-time dependency on a monorepo, `build-platform`, Verilator,
   or QEMU. Enforced by `tools/check_independence.py`.
2. **Generated, never typed.** Every ISA / CSR / memory-map / PMU / descriptor constant a backend
   needs is derived from the design's files. **A hard-coded constant in an emitter is a defect**, not
   a shortcut — it creates a second source of truth whose divergence gets misattributed to the RTL.
3. **`E-GPLLINK` — the hard boundary.** No crate under `crates/**` may depend on, `#include`,
   `bindgen`, or link any QEMU header or library. Emission is **text-out only**. See
   [`AGENTS-licensing.md`](AGENTS-licensing.md).
4. **Read-only toward the design.** The generator only *reads* the source tree. It never edits a
   config package, flist, DTS or RTL file, and never touches a copyright / SPDX / attribution line.
5. **Design is law.** Behaviour, backend boundaries and the IR are defined under `architecture/`.
   Update the design (or open a delta in `AGENTS-todo.md`) before a large structural change.
6. **Determinism before diagnosis.** Anything feeding D1/D2 runs with fixed instructions-per-`mtime`
   tick, seeded device timing and recorded MMIO/IRQ. A non-deterministic oracle is not an oracle.
7. **Two machine profiles, never one.** `g6lc-soc` is faithful to the SoC package and is the only
   profile any diagnosis may cite. `g6lc-virt` adds virtio so a distro can boot, and is stamped and
   quarantined. Never merge them.
8. **Not evidence.** Output is a **hypothesis and a checkpoint**. Where this package sits inside a
   verification project, that project's own harness remains the sole source of green.
9. **Pins, not reinterpretation.** External contracts (QEMU rev, OpenSBI ref, ISA/descriptor
   contracts, trace-record layout) live in `pins.toml`. A contract change bumps a pin deliberately;
   bits are never silently reinterpreted.
10. **State.** Every implementation pass updates [`AGENTS-todo.md`](AGENTS-todo.md).

---

## 2. Directory map

```
g6lc_qemu/
  AGENTS.md  AGENTS-todo.md  AGENTS-licensing.md  README.md  LICENSE
  pins.toml                  ← pinned revs: QEMU, OpenSBI, contracts
  Cargo.toml                 ← workspace (first-party path deps only)
  rust-toolchain.toml        ← pinned channel; contained rustup installs it into .tools/
  g6q.sh / g6q.ps1           ← thin wrappers → tools/g6q.py (no business logic)
  architecture/
    README.md DESIGN.md INGEST.md IR.md EMIT.md DIAG.md CLI.md
  tools/
    g6q.py                   ← PRIMARY CLI: setup doctor build test check gen run flist clean env
    env_common.py            ← contained-toolchain paths
    flist_expand.py          ← generic ${VAR} / nested -f expander (no project names baked in)
    check_independence.py    ← KD0 + E-GPLLINK enforcement
  crates/
    g6q-svcfg/               ← SystemVerilog config-package reader + legality rules
    g6q-flist/               ← flist expansion + membership facts (Present/Absent/Unknown)
    g6q-dts/                 ← device tree parse + semantic extraction
    g6q-core/                ← TargetModel IR, conformance report, JSON (dependency-free)
    g6q-ingest/              ← assembles the model from the three readers + capability table
    g6q-emit-args/           ← B0: stock-QEMU argv + DTB
    g6q-emit-qemu/           ← B1/B2: QEMU C emitters (text out only)
    g6q-vm/                  ← B3: native Rust virtual machine
    g6q-diag/                ← D1 tandem records + D2 models + PMU
    g6q-cli/                 ← binary `g6lc-qemu` (alias `g6q`)
  fixtures/                  ← miniature config pkg + flist + dts + golden model JSON
  schemas/                   ← target-model.schema.json, conformance.schema.json
  out/                       ← gitignored: emitted artifacts, DTBs, firmware
  qemu/                      ← gitignored: the QEMU checkout emission targets (separate GPL work)
  .tools/                    ← gitignored: contained rustup / cargo / venv
```

---

## 3. Zero-dependency stance (current)

The workspace declares **no external Rust dependencies**. Argv parsing and JSON writing are
hand-rolled `std`-only. This is deliberate:

- `cargo test --workspace` runs offline on a fresh host with no registry fetch — which is what makes
  the independence claim real rather than aspirational.
- It keeps the supply-chain surface at zero for a tool that will be pointed at other people's trees.

Adopting a dependency is a **recorded decision** in `AGENTS-todo.md` plus a `pins.toml` entry, subject
to the usual supply-chain hygiene: pin an exact version, prefer one published at least a week ago, no
floating ranges.

---

## 4. Daily commands

From `g6lc_qemu/`:

```bash
python tools/g6q.py setup       # contained rustup/cargo (+venv) under .tools/
python tools/g6q.py doctor      # host probe: rust, python, qemu, dtc, spike
python tools/g6q.py build
python tools/g6q.py test
python tools/g6q.py check       # GREEN COMMAND: independence + fmt + clippy + test + golden
python tools/g6q.py run -- --help
python tools/g6q.py flist --in entry.f --set ROOT=/abs/project --out portable.f
python tools/g6q.py clean       # cargo target + out/
python tools/g6q.py clean --all # + .tools/ (re-run setup after)
```

Thin wrappers: `./g6q.sh check` · `.\g6q.ps1 check`. **Do not grow logic in the wrappers** — port it
to `tools/g6q.py`.

### Green command

```
python tools/g6q.py check
```

This is the local completion gate. Nothing outside this package substitutes for it.

---

## 5. Extension playbook

| Task | Where |
|---|---|
| Change architecture | `architecture/*.md` + a note in `AGENTS-todo.md` |
| Add a config field to the model | `crates/g6q-svcfg` (reader) + `crates/g6q-core` (IR) + `schemas/target-model.schema.json` + a fixture |
| **Add / retarget a capability** | `crates/g6q-ingest/data/capabilities.ini` — **data, not code**; override at run time with `--capabilities FILE` |
| Add a conformance rule | `crates/g6q-core` + `schemas/conformance.schema.json` + a fixture case |
| Change how the model is assembled | `crates/g6q-ingest` (keeps `g6q-core` dependency-free) |
| Add a DTS property understood semantically | `crates/g6q-dts` + a fixture |
| Add / change a QEMU emitter | `crates/g6q-emit-qemu` — **text out only**, banner + SPDX on every emitted file |
| Add a stock-QEMU capability mapping | `crates/g6q-emit-args` |
| Add an instruction / CSR to the native VM | `crates/g6q-vm`, gated on a model field, never on a literal |
| Add a diagnosis model or PMU event | `crates/g6q-diag` — sized from the model, never hard-coded |
| Add a CLI verb or option | `crates/g6q-cli` + `architecture/CLI.md` |
| Add package automation | `tools/g6q.py` (**not** the shell wrappers) |
| Independence regression | `tools/check_independence.py` |

---

## 6. Standing checklist (every code pass)

- [ ] `AGENTS-todo.md` updated
- [ ] `python tools/g6q.py check` green
- [ ] No new external crate dependency (or: recorded decision + `pins.toml` entry)
- [ ] No QEMU header / library reachable from any crate (`E-GPLLINK`)
- [ ] No hard-coded design constant in an emitter or model
- [ ] Emitted files carry the `DO NOT EDIT` banner and correct SPDX
- [ ] SPDX header on net-new first-party code files (`MIT`)
- [ ] Fixtures-only success criteria preserved (no monorepo path required)
- [ ] `architecture/` still accurate for user-visible behaviour changes
- [ ] Machine profile stamped into any new artifact type

---

## 7. Non-goals

- Cycle accuracy, pipeline timing, IPC, or any latency-derived number.
- Replacing an RTL simulator or an ISS as a verification reference.
- Vendoring, forking, or linking QEMU.
- Becoming a build platform, a test runner, or a second control surface for a host project.
- Defining an ISA. Instruction encodings, CSR maps and device ABIs are *consumed by pin* from the
  design's own normative documents.
