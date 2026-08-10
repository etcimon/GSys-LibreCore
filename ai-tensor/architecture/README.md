# ai-tensor / architecture

Authoritative **software** design for this package. The monorepo’s
[`architecture/ai-matrix/`](../../architecture/ai-matrix/) tree remains the **silicon / ISA scaffold**;
this directory is the **host backend** plan (frameworks → island). Nothing here is compiled.

## Doc map

| Doc | Purpose |
|---|---|
| [`DESIGN.md`](DESIGN.md) | End-to-end stack, modular M0–M8 path, independence |
| [`ABI-CONTRACT.md`](ABI-CONTRACT.md) | What we implement from the frozen ISA/descriptor contract |
| [`RUNTIME.md`](RUNTIME.md) | Device, memory, queues, poll/IRQ, backends |
| [`FRAMEWORKS.md`](FRAMEWORKS.md) | PyTorch / TensorFlow attachment strategy |
| [`VERSIONING.md`](VERSIONING.md) | Selectable cross-connect to monorepo + island revisions |
| [`HOST.md`](HOST.md) | Optional LibreCore `build-platform` adapter |
| [`../AGENTS.md`](../AGENTS.md) | Package purpose and agent rules |
| [`../AGENTS-todo.md`](../AGENTS-todo.md) | Live checklist |

## Cross-connect (one hop)

| Topic | Upstream (monorepo) | Here |
|---|---|---|
| T0/T1/T2 model | `architecture/ai-matrix/README.md` | DESIGN § Planes |
| Encodings / CSR / desc | `architecture/ai-matrix/isa-encoding.md` | ABI-CONTRACT |
| Scaling / island plane | `architecture/ai-matrix/scaling-100tops.md` | DESIGN § Non-goals |
| Live MMIO / DMA / CTL | `corev_apu/ai_island/README.md` | RUNTIME § Profiles |
| Pin / profile selection | git rev + island capability window | VERSIONING |

## Current state

| Area | State |
|------|--------|
| Architecture scaffold | **M0 done** |
| Rust workspace | **M1–M2 + Phase A** — abi (CAP/PMU), ir (tile limits), rt-sim Caps |
| Python + PyTorch helpers | **M3–M4 partial** — sim path; Caps/tile auto not yet in Python |
| Default profile | `sim-v0`; pin stub `island-p3-v1` (AccTile=256, Noc 64) |
| Live island MMIO | **SoftIsland hostless** (real UIO still open) |
| Island alignment | CAP/PMU/AccTile match I3-lite; bus micro-arch stays in RTL |

## Independence

Default development and CI for this package must not require building LibreCore RTL. Hardware and
Verilator are **opt-in backends** selected by profile, not by hard-coded monorepo paths in crates.
