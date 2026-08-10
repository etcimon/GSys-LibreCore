# ai-tensor — system design

**Status:** conceptual (M0) · **Package role:** PyTorch / TensorFlow backend for `Xg6lcai` island  
**Companion:** monorepo [`architecture/ai-matrix/`](../../architecture/ai-matrix/) (ISA + silicon scaffold)

---

## 1. Intent

Provide a **stable, framework-facing software stack** that:

1. Speaks the **frozen** `Xg6lcai` ABI (custom-2, CSRs, 64 B T2 descriptors, completion word).
2. Drives the **island** control plane (MMIO, doorbell, optional DMA fetch/store, poll/IRQ).
3. Plugs into **PyTorch** (primary) and **TensorFlow** (secondary) without inventing a second tensor
   calling convention.
4. Stays **independently buildable** (sim backend) while **version-linking** to monorepo architecture
   and live `ai_island` docs when running on real platforms.

Peak arithmetic remains in silicon (`ai_island` / future GEMM). This package is the **control plane
and glue**, not a software GEMM replacement.

---

## 2. Planes (aligned with monorepo, not re-derived)

| Plane | Silicon home | Software owner in ai-tensor |
|---|---|---|
| **Core-attached T0/T1** | CVXIF / optional accel seam | Optional later: encode `ai.enq`/`ai.poll`; not bulk matmul |
| **Island T2** | `corev_apu/ai_island` | **Primary:** desc build, region program, submit, wait, complete |

Framework bulk ops (**matmul, conv, attention blocks**) → **T2 only**.  
T0 is reserved for low-latency control and future fusion, consistent with
`architecture/ai-matrix/scaling-100tops.md`.

---

## 3. Layered stack

```
┌─────────────────────────────────────────────────────────┐
│  PyTorch / TensorFlow / (JAX)                            │
│  custom ops · optional PrivateUse1 / pluggable device    │
└───────────────────────────┬─────────────────────────────┘
                            │ stable C ABI + Python
┌───────────────────────────▼─────────────────────────────┐
│  ai-tensor-rt     Device · Queue · Buffer · Job           │
│  ai-tensor-ir     Ops · layouts · dtype · lower rules     │
│  ai-tensor-abi    Desc64 · CSR/MMIO · completion · caps   │
└───────────────────────────┬─────────────────────────────┘
                            │ Backend trait
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
   ai-tensor-sim      ai-tensor-linux      (cosim / replay)
   hostless CI         UIO / VFIO          optional
```

**Dependency rule:** upper layers may depend on lower; **abi** has no I/O; **frameworks** must not
bypass **abi** packing.

---

## 4. Modular development path (independently shippable)

Each module has its own acceptance tests. Later modules consume earlier crates only.

| ID | Module | Deliverable | Acceptance (independent) | Unlocks |
|---|---|---|---|---|
| **M0** | Architecture | This `architecture/` + AGENTS | Docs review; pins defined | All |
| **M1** | ABI | Desc64 + CAP/PMU maps + goldens | Golden bytes vs island/ISA tables | IR, sim |
| **M2** | IR + sim RT | lower + Caps + max-tile + sim GEMM | Hostless GEMM; reject oversize tile | Python |
| **Phase A** | Contract lock | CAP/PMU/tile profiles hostless | `cargo test`; pin AccTile=256 | M5 |
| **M3** | C + Python | `ai_tensor` wheel (sim) | NumPy/DLPack on sim | Torch/TF |
| **M4** | PyTorch | High-level ops first; C++ ext later | `gemm_s8` vs torch int32 on sim | Eager ML |
| **M5** | Real island | Caps-driven MMIO + AI-3 + PMU read | Same API on map; dual oracle ELFs | Real HW |
| **M6** | TensorFlow | Custom ops | Same Desc64 path | Second FW |
| **M7** | Production RT | IRQ, multi-queue, multi-tile stream | Concurrent jobs; timeout policy | Card SKU |
| **M8** | Stretch | PrivateUse1 / `torch.compile` | Selected models | UX |

**Flexibility:** a profile may enable M5 without M6, or M4 against sim only. Version pins
(`VERSIONING.md`) select which island/MMIO revision M5 talks to.

---

## 5. Data path principles

1. **One descriptor image** for MMIO latch, DMA-fetch, and `ai.enq` sideband.
2. **AI-3 regions** programmed before submit; fail closed if missing.
3. **Completion:** if `wr_cpl_en` / caps say so, wait on `ptr_done` word and/or status MMIO; document
   ordering with PLIC claim (island has a known interaction; runtime must fence/drain).
4. **Zero-copy default:** framework tensor storage → device pointers after pin/map; no mandatory
   bounce buffer.
5. **Discovery:** capability window + DTS/`xg6lcai` string when on Linux; sim fakes caps
   (AccTile*, MacsPerCycle, NocWidth, PMU zeros until first job).
6. **Tile geometry is CAP-owned:** host IR enforces `m,n,k ≤ AccTile*`; larger work is a
   **stream of tiled descs**, not a second ABI. Bus micro-arch (trail store, multi-out AR) is
   invisible to software.

---

## 6. Non-goals (keep the design optimal)

- Growing core-attached tile geometry for framework “speed” (belongs on the island).
- Framework-specific descriptor forks (“torch layout” vs “tf layout”).
- Linking Verilator or monorepo flists into the default Rust workspace.
- Replacing OpenSBI/Linux driver policy with ad-hoc `/dev/mem` as the only production path
  (bring-up only).

---

## 7. Relationship to monorepo scaffold

| Tree | Role |
|---|---|
| `architecture/ai-matrix/**` | ISA + silicon *scaffold* (not compiled) |
| `corev_apu/ai_island/**` | Live / evolving RTL implementation |
| `ai-tensor/**` | Host software package (this design) |
| `verif/tests/custom/ai/**` | Directed ELFs — **conformance oracles** for pins |

Promotion of RTL is governed by monorepo §0; promotion of **framework support** is governed by M0–M8
here. Neither tree should silently absorb the other’s responsibilities.

---

## 8. Evolution

- ABI-breaking change → bump **package ABI major** *and* require monorepo isa-encoding revision
  (or an explicit compatibility profile).
- MMIO-only bring-up quirks → new **runtime profile**, not a new op encoding.
- New island ops (conv, layout) → extend IR + abi tables; frameworks gain ops only after sim goldens
  exist.
