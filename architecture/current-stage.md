# Current stage — SMT2, QEMU, 100 TOPS, and the broader change sets

**Scaffold only** (`architecture/README.md`). Queue: [`AGENTS-todo.md`](../AGENTS-todo.md)
**Current phase**. Emulator asks: [`g6lc_qemu/architecture/RTL_FEEDBACK.md`](../g6lc_qemu/architecture/RTL_FEEDBACK.md).
QEMU never substitutes for Variane evidence (`multi-threading/testharness-proxy.md`).

This file is the **WIP snapshot** the programs of record point at. It does not replace
`router-core-upgrade-program.md` or `remaining-upgrade-sequence.md`; it records where those
tracks actually are so 100 TOPS work is not sequenced as if the rest of the SoC were still
at U0.

---

## 1. What is live (2026-09)

| Plane | Live state | Not yet |
|---|---|---|
| **B1 SMT2 RTL** | Fine-grain banks (PC/CSR/RF/RAS/GHR); `g6lc64_smt2` N=1 T=2; cookie SUCCESS `51b1babe` is Variane trapdump; SL-W queue landed (default `WtDcacheFixupDepth=0`); I4dp `_v` and `ooo_server` 200M `tohost=0` on proxy | SL-C topology truth; R3b Linux Image; dual-commit same cycle; `SMT2` default SKU; retire boot crutches |
| **QEMU firmware** | U1–U3 (virt + generated `g6lc-soc` OpenSBI/U-Boot/OpenWrt/`CPUINFO-DONE`); E2–E3 EDK2 virt (Shell, OpenWrt, GPEX virtio); U3-Shell virt green | E4 RTL pflash tandem (no 32 MiB pflash on Variane); soc U3-Shell StartImage hang; `g6lc-soc` has no PCI |
| **AI island** | I1-lite AccTile 256, HARD gemm_s8 + 256³ ~83.7k cy (~0.512 TOPS @ 1 GHz, §2 def); CPL FIFO; PLIC-8; I3-lite bus; **F1/F7–F10/F12–F14 published** (`CAP_BASE`/`PMU_OFF_*`/`DESC_VERSION`/cluster enable) | **I3 measured BW** (`DramGBps=0`); I2 clusters; I4 UPF/thermal |
| **ai-tensor / PCIe stand-in** | virt-ai-pcie TCP UIO; packed DESC/CPL/CAP join EDK2 ESP; doorbell/IRQ/QoS/qid bounds; `contracts.ai_host_transport` **unpinned** | Fused GPEX endpoint; pinned BAR/MSI/device ID; Linux UIO on live board |
| **OoO / multi-issue / multi-core** | `OoOEn` production-gated; `NrIssuePorts` 1–4 by package; `NrCores` 1–8 hub; stream8 CRT 9/9 | Slice-OoO default off; `CVA6_MAX_SMT_HARTS=2`; merge stream×SMT packages |
| **Hypervisor** | U9.0–U9.2 + H-edge Spike+RTL 3/3 | KVM stress; G-stage soak |
| **RVV** | Ara vendored + attach + lint + DTS + directed tests | OpenSBI VRF; live Ara cosim |
| **Stream plane** | `g6lc64_stream8` promoted; orthogonal to SMT2 until FDT trusted | Do not merge with `g6lc64_smt2` DI |

100 TOPS remains the **§2 definition** (100e12 dense INT8 ops/s, 1 MAC = 2 ops, no sparsity/INT4
in the headline). The live island is a **latency SKU fixture**, not a 100-TOPS measurement.

---

## 2. Parallel change sets (do not serialise)

These are **independent envelopes**. A 100-TOPS island pass must not wait for full OoO, and an
OoO pass must not invent AI BAR sizes.

```
                    ┌─ B1 SMT2 / soft-ladder (cookie, SL-W, SL-C, R3b Image)
                    ├─ QEMU firmware ladder (virt/soc U-Boot/EDK2; E4 pflash later)
 SoC control plane ─┤─ Hypervisor KVM stress (U9 landed; soak open)
                    ├─ Stream8 vs SMT2 (orthogonal until FDT trusted)
                    └─ RVV/Ara cosim (attach landed; VRF open)

                    ┌─ I3 measure DRAM vs scaling-100tops.md §4  (before I2)
 100 TOPS island ───┤─ F9/F11/F14 PMU + measured BW (emulator ready, RTL unpublished)
                    ├─ F12 host tiling vs MaxDim; F13 writeback in sizing
                    ├─ F10 ew/sp24 named  (else no INT4 effective-TOPS number)
                    └─ I2 cluster replica behind same ABI (needs F6+F8)

                    ┌─ Keep RC (g6lc-virt GPEX + EDK2) and EP (virt_ai_card) separate
 PCIe / host push ──┤─ Pin contracts.ai_host_transport before any BAR/device-id
                    └─ Then B1 guest-visible island (needs F1 placement)
```

Config identity: `OoOEn=0`, `NrHarts=1`, `AiMatrixEn=0`, `VExtEn=0` remain **netlist-identity**
paths. Named packages (`g6lc64_smt2`, `g6lc64_stream8`, `g6lc64_ai`, `cv64a6_ooo_server`,
`cv64a6_server_math_v`) are union-soaked, not merged (`soft-ladder/CONTRACT.md` §8).

---

## 3. 100 TOPS next (from RTL_FEEDBACK, in order)

Emulator ingest for F1–F8 is largely **landed**; the **design asks stay open**. Do not delete a
row because QEMU packed a descriptor. Detail: `RTL_FEEDBACK.md` §2.1.

| Order | Work | Why it is next |
|---|---|---|
| 1 | **I3 bandwidth measure** (or host `--measured-dram-gbps` only as a *hypothesis*) | §11: do not grow MAC arrays ahead of memory. F11 leaves `DramGBps=0`. |
| 2 | **F12 software tiling** against ingested `acc_tile_*` | `4096³` is not one descriptor on live MaxDim=256. |
| 3 | **F13 writeback in any BW claim** | §4 `2/T` is input-only; resident GEMM is `max(compulsory, tiled)+4mn`. |
| 4 | **F9 PMU offsets as localparams** | Modelled D2 vs RTL `0x180–0x18C` cannot be auto-diffed until published. |
| 5 | **F10 accessors** for `ew`/`sp24` | Headline stays dense INT8; effective INT4 2:4 is a *second* number, inexpressible until named. |
| 6 | **F8 enabled-cluster bitmap** then **I2** | F6 map is not enough if present≠enabled. |
| 7 | **F1 placement localparams** | Guest-addressable island on B1; virt-card UIO is not that pin. |
| 8 | **F7** make `scaling-100tops.md` §8 match RTL `CAP_OFF_*` (or the reverse) | Silent wrong discovery. |
| 9 | **Pin `ai_host_transport`** only after BAR/virtio/MSI exist in a package or DTB | Until then EDK2 GPEX ≠ card endpoint. |

Live geometry (`RTL_FEEDBACK.md` §3.1): 256 MAC/cycle × 1 GHz = **0.512 TOPS**; throughput SKU
plan is 8 clusters × 4096 MAC/cycle @ 1.5 GHz ≈ **98.3 TOPS**. The 192× gap is MAC width × clock,
not a QEMU measurement.

---

## 4. Broader SoC next (not on the island critical path)

| Track | Next concrete | Must not |
|---|---|---|
| SMT2 | SL-C FDT/`cpu-map` honesty; R3b Image; keep cookie green | Treat QEMU `smp: 2 CPUs` as Variane SUCCESS |
| QEMU | Soc Shell file-path; 32 MiB pflash for E4; `results --tops` from `g6q-diag` | Cite virt as tape-out evidence; invent AI PCI IDs |
| OoO | Keep `OoOEn` gated; dual-issue SMT product closeout is U6.1 not U5 | Turn on full OoO in the router low-power SKU |
| Multi-core | `NrCores` scale per envelope; PLIC `S≤8` | `NrHarts>2` until `CVA6_MAX_SMT_HARTS` + contexts |
| Hypervisor | KVM stress on server_math | Block 100 TOPS on KVM |
| Stream | Keep `g6lc64_stream8` separate | Merge with smt2 DI |
| RVV | `ara-vector-cosim` when `_v` TB + Image | Grow core tile 8×8×8 with island TOPS |

---

## 5. Open first

| Need | Path |
|---|---|
| This snapshot | this file |
| U1–U10 plan | `router-core-upgrade-program.md` · `remaining-upgrade-sequence.md` |
| SMT2 / ladder | `multi-threading/README.md` · `smt2-bringup.md` · `soft-ladder/` |
| QEMU stages | `g6lc-qemu/README.md` · `g6lc-qemu/staging.md` · `g6lc_qemu/AGENTS-todo.md` |
| 100 TOPS sizing | `ai-matrix/scaling-100tops.md` · `ai-matrix/hard-tests.md` |
| Design asks | `g6lc_qemu/architecture/RTL_FEEDBACK.md` |
| PCIe roles | `uncore/pcie-endpoint.md` · `uncore/pcie-root-complex.md` |
| Queue | `AGENTS-todo.md` Current phase |
