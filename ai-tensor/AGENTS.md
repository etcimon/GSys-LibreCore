# ai-tensor — Agent Guider (package root)

> **Scope:** This file is the entry point for agents working **inside `ai-tensor/`**.  
> The package is **project-independent**: it must build, test, and simulate its device/ABI model
> with only this tree + fixtures. Host monorepos (LibreCore / CVA6 `build-platform`) are **optional
> consumers** that spawn the CLI, discover DTS/MMIO, or rehydrate JSON — they never become crate
> dependencies.

| Artifact | Path | Role |
|---|---|---|
| **This guider** | `AGENTS.md` | Purpose, invariants, navigation |
| **Live todo / state** | [`AGENTS-todo.md`](AGENTS-todo.md) | Phase checklist; update every pass |
| **Architecture index** | [`architecture/README.md`](architecture/README.md) | Map of design docs |
| **System design** | [`architecture/DESIGN.md`](architecture/DESIGN.md) | End-to-end stack, modular path |
| **ABI contract** | [`architecture/ABI-CONTRACT.md`](architecture/ABI-CONTRACT.md) | Descriptors, CSR, custom-2, completion |
| **Runtime** | [`architecture/RUNTIME.md`](architecture/RUNTIME.md) | Device, memory, queues, IRQ/poll |
| **Frameworks** | [`architecture/FRAMEWORKS.md`](architecture/FRAMEWORKS.md) | PyTorch / TensorFlow backends |
| **Versioning / cross-connect** | [`architecture/VERSIONING.md`](architecture/VERSIONING.md) | Pin to island + monorepo architecture |
| **Host integration** | [`architecture/HOST.md`](architecture/HOST.md) | Optional monorepo adapter boundary |

When this package lives inside LibreCore, also respect monorepo `AGENTS.md` §0 (SoC readiness) and
`AGENTS-licensing.md` for **host-side** glue only. Never import monorepo modules into Rust crates here.

---

## 0. Purpose — PyTorch / TensorFlow backend for `Xg6lcai` / `ai_island`

**`ai-tensor` exists to provide the host software backend** that lets machine-learning frameworks
(primarily **PyTorch**, secondarily **TensorFlow**, optionally JAX) **submit tensor work to the
LibreCore AI island** using the **same** frozen instruction, CSR, descriptor, and MMIO contract as
directed tests and the island RTL.

| What this package **is** | What this package **is not** |
|---|---|
| ABI pack/unpack + IR + device runtime | A replacement for island GEMM silicon |
| Framework plugins (custom ops / device) | A private “CUDA-like” memory model by default |
| Hostless **sim** backend for CI | A crate that links `core/` or Verilator by default |
| Version-selectable link to monorepo architecture | A second competing ISA encoding |

**Product sentence:** frameworks call stable C/Python APIs; those APIs lower to **T2 descriptors +
doorbell / `ai.enq`** (and optional T0 control) on `ai_island`, with zero-copy buffers in a **shared
address space** when the platform allows.

Normative silicon/ISA text remains in the monorepo scaffold:

- [`architecture/ai-matrix/isa-encoding.md`](../architecture/ai-matrix/isa-encoding.md) — opcodes, CSR, T2 descriptor
- [`architecture/ai-matrix/README.md`](../architecture/ai-matrix/README.md) — tiers T0/T1/T2, seam B/D
- [`architecture/ai-matrix/scaling-100tops.md`](../architecture/ai-matrix/scaling-100tops.md) — island plane
- [`corev_apu/ai_island/README.md`](../corev_apu/ai_island/README.md) — live MMIO map, CTL, DMA notes

This package **consumes** that contract via a **pinned cross-connect** (`architecture/VERSIONING.md`);
it does not redefine opcodes.

---

## 1. Prime directives

1. **Independence (KD0).** Default `cargo test --workspace` and the **sim** backend succeed with only
   `ai-tensor/`. No compile- or link-time dependency on `build-platform`, Verilator, or monorepo
   workspace paths. Enforce with `tools/check_independence.py` once the tree has a `tools/` spine.
2. **Design is law.** Behavior and module boundaries are defined under `architecture/`. Update design
   (or open a delta in `AGENTS-todo.md`) before large structural code changes.
3. **One ABI for all entry points.** MMIO doorbell, T0 `ai.enq`, PyTorch, and TensorFlow must pack the
   **same** 64-byte descriptor and interpret the **same** completion word. A framework-specific
   layout is a defect.
4. **Shared-memory first.** Prefer pointers into process-visible buffers (AI-3 regions programmed).
   Copy-in/copy-out is an opt-in profile, not the default card story.
5. **Bulk work is T2; T0 is control.** Framework matmul/conv go to island descriptors. T0 custom-2 is
   for enqueue/poll/fusion control, not peak TOPS (see monorepo scaling doc).
6. **Flexible coupling.** Hardware/profile selection is **versioned and selectable**
   (`VERSIONING.md`) so the package can track island bring-up without forking the ISA.
7. **Licensing.** First-party software/docs: **MIT** (tier T when under LibreCore). Do not rewrite
   tier-R RTL headers from this tree. Kernel modules (if any) are a separate work.
8. **State.** Every implementation pass updates `AGENTS-todo.md`.

---

## 2. Directory map (target; scaffold may lag code)

```
ai-tensor/
  AGENTS.md                 ← this file
  AGENTS-todo.md
  architecture/             ← conceptual design (this PR)
  tools/                    ← ait.py spine (later)
  crates/                   ← Rust workspace (later)
  python/  frameworks/      ← wheels / torch / tf (later)
  fixtures/  schemas/
  .tools/                   ← gitignored bootstrap
```

Live RTL and monorepo architecture are **outside** this package; they are linked by pin, not by path
import into crates.

---

## 3. Modular development path (summary)

Full detail: [`architecture/DESIGN.md`](architecture/DESIGN.md) § Development path.

| Module / phase | Outcome | Framework impact |
|---|---|---|
| **M0** Docs + pins | This tree; VERSIONING profile `sim-v0` | — |
| **M1** `ai-tensor-abi` | Pack/unpack desc + completion; golden fixtures | Offline validate |
| **M2** IR + sim RT | Hostless submit/wait | Python ctypes smoke |
| **M3** C ABI | Stable `ai_tensor_*` symbols | Shared by torch/tf |
| **M4** PyTorch custom ops | `torch.ops.ai_tensor.*` | Eager backend |
| **Phase A** | CAP/PMU/tile contract lock (hostless) | M5 ready |
| **M5** | Caps-driven MMIO + AI-3 + PMU (UIO/VFIO/map) | Real HW/FPGA |
| **M6** TensorFlow ops | Same C ABI | Second frontend |
| **M7** IRQ / multi-queue | PLIC/MSI wait, QoS hooks | Production soak |
| **M8** PrivateUse1 / compile | Optional torch device / Inductor | Stretch |

Each module is **independently testable** (sim + fixtures) before the next framework surface lands.

---

## 4. Cross-connect (do not drift)

| Concern | Monorepo / island locus | Package locus |
|---|---|---|
| Opcode / CSR / descriptor | `architecture/ai-matrix/isa-encoding.md` | `architecture/ABI-CONTRACT.md` + generated `abi/` |
| Live MMIO / CTL / DMA | `corev_apu/ai_island/README.md` | `RUNTIME.md` profiles |
| T0 vs T2 split | `architecture/ai-matrix/README.md` §1 | `DESIGN.md` planes |
| Completion word | `g6lc_ai_desc_pkg::make_completion` | abi completion type |
| Pin selection | island git tag / monorepo rev | `VERSIONING.md` + `profiles/*.toml` (later) |

**Rule:** if silicon docs change the contract, bump the pin and the package ABI version; do not silently
reinterpret bits in framework code.

---

## 5. Daily commands (target)

```bash
# From ai-tensor/ (once tools/ exists)
python tools/ait.py setup
python tools/ait.py test
python tools/ait.py doctor
```

Until the tooling spine exists, treat `architecture/` + `AGENTS-todo.md` as the only required
artifacts and keep changes documentation-first.

---

## 6. Invariants (short)

- No monorepo path inside `Cargo.toml` dependencies.
- No second descriptor layout for “ML convenience.”
- Framework packages may depend on libtorch/TF; the **core workspace must not** by default.
- Sim backend is mandatory CI; hardware backends are features.
- Prefer documenting trade-offs in `architecture/` over ad-hoc comments only in bindings.
