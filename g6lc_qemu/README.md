# g6lc_qemu

**A generator that turns a LibreCore-shaped RISC-V design into emulation.**

Point it at a design's own files — the SystemVerilog configuration packages, the flists that say what
is actually compiled, the SoC package that fixes the memory map, the device trees, the PMU event
matrix — and it produces the machinery to run that design: QEMU invocations, QEMU machine/CPU/device
C, QEMU TCG plugins, and a native Rust virtual machine, plus a diagnosis layer that relates what the
emulator did back to the SystemVerilog.

Licensed **MIT**. It writes GPL-2.0 C for QEMU without linking QEMU — see
[`AGENTS-licensing.md`](AGENTS-licensing.md).

---

## Why

Simulating RTL is exact and slow. A generic ISA simulator is fast and knows nothing about *your* SoC.
This sits in between: fast enough to boot a Linux distribution, specific enough to answer questions
about the configuration you actually elaborated.

The thing that makes it specific is that **nothing is hand-written**. Extension gating, the CSR map,
the memory map, interrupt-controller geometry, PMU event indices, accelerator MMIO offsets and device
ABIs are all derived from the design. A constant typed into the emulator would become a second source
of truth, and its inevitable drift would be blamed on the hardware.

## The idea in one line

> The flist decides what is *real*. The config decides what is *enabled*. The device tree decides what
> *software is told*. An emulator generated from all three — and which reports where they disagree —
> is the only kind worth building.

That disagreement report is a first-class output, not a diagnostic afterthought. A configuration that
enables vectors while the vector unit is not on the flist gets a `stub` verdict, and `--conform
strict` refuses to pretend otherwise.

---

## Install / build

Requires Python 3.9+ and network access on first `setup` (which installs a **contained** Rust
toolchain under `.tools/` — nothing global is touched).

```bash
cd g6lc_qemu
python tools/g6q.py setup     # contained rustup + cargo
python tools/g6q.py check     # green command: independence + fmt + clippy + tests
python tools/g6q.py build
```

Thin wrappers exist for convenience: `./g6q.sh check`, `.\g6q.ps1 check`.

There are **no external Rust dependencies**, so tests run offline on a fresh host once the toolchain
is present.

## First commands

```bash
# What does this design look like, as data?
g6lc-qemu gen --target g6lc64_ai --repo-root /path/to/design --emit-model model.json

# Where do config, flist and device tree disagree?
g6lc-qemu conform --target g6lc64_server_math_v --repo-root /path/to/design

# Boot it
g6lc-qemu run --target g6lc64_smt2 --repo-root /path/to/design \
              --os opensbi-smoke --build-fw
```

Nothing above *requires* a `--repo-root`; every input can be given explicitly, which is how the tool
is used against a fork, a fixture, or a tree laid out differently:

```bash
g6lc-qemu gen \
  --config-pkg ./g6lc64_ai_config_pkg.sv \
  --flist      ./Flist.g6lc --set CVA6_REPO_DIR=/abs/design \
  --soc-map    ./ariane_soc_pkg.sv \
  --dts        ./ariane-ai.dts \
  --emit-model model.json
```

---

## Backends

| | What | Output licence |
|---|---|---|
| **B0** | Drives a **stock** `qemu-system-riscv64`: generated DTB, `-cpu` property string, argv, plus a report of everything stock QEMU cannot express | none — no code emitted |
| **B1** | Generated QEMU **machine + CPU + devices** with a faithful memory map | GPL-2.0, separate work |
| **B2** | Generated QEMU **TCG plugins** for tracing and microarchitectural modelling | GPL-2.0, separate work |
| **B3** | A **native Rust** virtual machine — the tandem oracle, deterministic replay, checkpoints | MIT, in this tree |

## Two machine profiles

- **`g6lc-soc`** — byte-faithful to the design's SoC package. No PCI, no virtio, the real DRAM window.
  Everything that claims to say something about the *hardware* runs here.
- **`g6lc-virt`** — the same plus virtio block/net and more RAM, because a real distribution needs a
  disk and a NIC and the silicon has neither.

They are never merged. The profile is stamped into every artifact, and the diagnosis commands refuse
`g6lc-virt` unless you say `--allow-virt-diag`. This is the property that keeps results meaningful.

## Diagnosis

Two tiers, deliberately never the same run:

- **D1 — tandem.** Emits RVFI-shaped commit records, runs lockstep against a reference ISS or an RTL
  trace, reports the *first* instruction where they diverge, and exports a checkpoint so a cycle-exact
  simulator can resume the last hundred thousand instructions instead of re-running the boot.
- **D2 — microarchitectural.** Models the structures the configuration actually parameterises —
  branch predictors, TLBs, caches, scoreboard, SMT thread select — and emits the design's own PMU
  events, so counters read inside the guest are comparable with counters from RTL.

D2 is *informative*, not cycle-accurate. It reports structure hit/miss and occupancy; it does not
report cycles, and `mcycle` is labelled synthetic wherever it appears.

---

## What this is not

- Not a cycle-accurate model. An RTL simulator owns cycles.
- Not a verification signoff tool. Output is a **hypothesis and a checkpoint** — where this package
  sits inside a verification project, that project's own harness remains the only source of green.
- Not a QEMU fork, and not something that links QEMU.
- Not a place where an ISA is defined. Encodings, CSR maps and device ABIs are consumed by pin from
  the design's normative documents.

## Layout

```
architecture/   design docs (start at architecture/README.md)
tools/          g6q.py — the primary CLI for building, testing and checking this package
crates/         the Rust workspace: readers, IR, emitters, VM, diagnosis, CLI
fixtures/       synthetic inputs + golden outputs; what makes the tests standalone
schemas/        JSON schemas for the target model and the conformance report
pins.toml       pinned revisions: QEMU, OpenSBI, external contracts
out/ qemu/      gitignored: emitted artifacts and the QEMU checkout they target
```

Agents working in this tree should start at [`AGENTS.md`](AGENTS.md).

## Licence

MIT — see [`LICENSE`](LICENSE). Emitted QEMU C is GPL-2.0-or-later and belongs to a separate work;
[`AGENTS-licensing.md`](AGENTS-licensing.md) explains the boundary and how it is enforced.
