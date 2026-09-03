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
| **QEMU firmware** | U1–U3 (virt + generated `g6lc-soc` OpenSBI/U-Boot/EDK2/OpenWrt/`CPUINFO-DONE`); E2–E3 EDK2 virt; linux-dist **gitlinks** (openwrt `37fc534`, edk2 `4460122`, four feeds) | E4 RTL pflash tandem; soc U3-Shell StartImage hang; `g6lc-soc` has no PCI |
| **AI island** | I1-lite AccTile 256, HARD gemm_s8 + 256³ ~83.7k cy (~0.512 TOPS @ 1 GHz, §2 def); CPL FIFO; PLIC-8; **I3-lite** NoC 8 GB/s + PMU/CAP; `MaxAROut=2`; Cas=0 bypass; opt-in `G6LC_AI_DRAM_TIMING` → `AiIslandDdr4TimingSim` (class 0, Cas=14, AR=8); DRAM backend is the **SoC** `master[DRAM]` slave (cores + island share it); `DramChannels` N=1 live. **CLI:** `diag run ai` / `test --ai` / `test --ai-remote` / `test --ai --channels 4 --ai-dram 1` / `g6q --ai` (QEMU not Variane) | **I3 DRAM-class** (LiteDRAM generated, class-1 N=1/2/4 **opt-in only**; S7 N=4 two IDs/PHY + GEMM stripe directed PASS — `uncore/dram-channel-scaling.md`; 400 GB/s SKU not live); I2 clusters; I4 UPF/thermal |
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

                    ┌─ I3-lite live (DramClass=0, N=1, 8 GB/s NoC, PMU→CAP)
 100 TOPS island ───┤─ I3 DRAM: LiteDRAM at shared xbar DRAM slave, DramClass=1
                    │    (cores + L2 + NrCores use the same channels; before I2)
                    ├─ F12 host tiling vs MaxDim=256; F13 writeback in sizing
                    └─ I2 cluster replica only after DRAM I3 (F6+F8 published)

                    ┌─ Keep RC (g6lc-virt GPEX + EDK2) and EP (virt_ai_card) separate
 PCIe / host push ──┤─ Pin contracts.ai_host_transport before any BAR/device-id
                    └─ F1 placement published (AI_CAP_BASE=0x4000_0000)
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
| 1 | **I3 DRAM class** (LiteDRAM at the **shared** xbar DRAM slave, `DramClass=1`) | Vendored + `--sim` generated. **DramChannels** 1/2/4/8 (power of two); nameplate **N×19 GB/s**. Live **1 ch**. Opt-in `G6LC_AI_DRAM_CLASS1` (1 ch) or `G6LC_AI_DRAM_CHANS_2` (2 ch / 38 GB/s). Core I$/D$/PTW/L2/`NrCores` already hit this slave — do not make channels island-private. Stability: `uncore/dram-channel-scaling.md`. |
| 2 | **I3 measured ≥80% of `min(nameplate, fabric)`** | Directed class-1 `--sim` 256-beat stream **7858 milli-GB/s (98% of 8 GB/s)**. 80% gate **closed**. Live fabric 8 GB/s. Do not treat 8 as 400, nor 19 as measured. |
| 3 | **F12 host tiling** against MaxDim=256 | Directed `ai_gemm_tile_2x2_smoke` (32³ → 2×2 packed 16×16). §12 `4096³` is 16³ descriptors. |
| 4 | **I2 clusters** only after DRAM I3 | F8 bitmap is published; growing MACs on 8 GB/s is the §11 failure. |
| 5 | **Pin `ai_host_transport`** after F1 (published) | Keep GPEX RC ≠ virt_ai_card EP. |

Published this pass / prior: F1–F15; **S1–S7 directed closed**. Native wrap **PASS** id6 **1445 cy** (eight AR + eight AW live / 9th backpressure, mixed AW+AR, L1 16 B, WRAP SLVERR). Wrap **NrArSlots/NrAwSlots** = island `MaxAROut` (CLASS1 = 8); AXI held until `init_done` (`ForceInitDone=1` in `--sim`). Testharness live cookie keeps pulp atomics (1 AR/AW). S4/CLASS1 uses `g6lc_axi_atomics_wrap` (AMO+cut+`g6lc_axi_lrsc`, eight AR/AW **50 cy**; LR/SC proven on isolated lrsc). Rebuild `ai-dt` to pick it up. Class-1 `--sim` 256-beat stream **7858 milli-GB/s (98% of fabric)** — 80% gate **closed**. Class-1 PHY N=1/2/4/8 **375/416/448/453 cy**. Class-1 GEMM N=1/2/4/8 **336/681/821/1162 cy** (MaxAROut=8). Testharness CLASS1 slave (`dram_backend`) N=1/2 **336/681 cy**. DTS↔CAP `0x38` **PASS** (live 1 ch / shift 6; one `memory@`). Nameplate guard **PASS** (refuse 400 on class 0/1). Variane S4 **`ai-dt` PASS:** `cva6-build test --ai-remote` after rebuild with `g6lc_axi_atomics_wrap` → `tohost=1` after **2899 cycles** (was 2681 on pulp 1-OT). Live `ai-dt` **vthreads=12** jobs=1 **1395 s** **40.7 Mi** (was 37.8 Mi / 1 thread); exclusive **PASS 552 cy**. Dual-core snoop wall **4890 s** ≈ 1-thread **4875 s**. Live `ai-d1` **vthreads=12** jobs=1 **1334 s** **41.7 Mi**; exclusive still **PASS 781 cy**. Live `ai-d2` **vthreads=12** **42.9 Mi**; exclusive **PASS 945 cy**. Live `ai-d4` **vthreads=12** **47.4 Mi**; exclusive **PASS 941 cy**. Live `ai-d8` **49.1 Mi** vthreads=12. CLASS1 ELF preload is LiteDRAM native (cluster held; no `gen_sim_axi.i_sram`). Variane **`ai-d1` PASS:** `S4_FLAVOUR=ai-d1` → `tohost=1` after **5363 cycles** (preload 20 native words, drain t=177). Variane **`ai-d2` PASS:** N=2 LiteDRAM stripe → `tohost=1` after **5758 cycles** (preload drain t=150). Variane **`ai-d4` PASS:** N=4 → `tohost=1` after **5762 cycles**. Variane **`ai-d8` PASS:** N=8 → `tohost=1` after **5821 cycles**. CLASS1 channel ladder {1,2,4,8} closed. S4 parks hart 1: **`ai-dt` 2620 cy** (was 2899), **`ai-d1` 4246**, **`ai-d2` 4520**, **`ai-d4` 4553**, **`ai-d8` 4582**. Dual-core stripe+occupancy **830/900/582 cy** on `ai-d2`/`ai-d8`/`ai-sc{2,4,8}`. All-N occupancy **1328/889 cy** on `ai-d8`/`ai-sc8` (CAP `0x38` N, `0x70+4*i` all nonzero). Exclusive **PASS** `ai-dt` **552** / CLASS1 `ai-d1` **781** / `ai-d2` **945** / `ai-d4` **941** / `ai-d8` **941 cy** / class-0 stripe **`ai-sc2` 620** / **`ai-sc4` 620 cy**. CLASS1 exclusive {1,2,4,8} closed. SIM_CHANS uses `g6lc_axi_atomics_wrap` + wrap AW=8 (`DRAM_EXCL_AW`); cookie pulp `dram_aw_out` stays 1. Dual-core snoop **PASS `ai-dt` 16667 cy** / CLASS1 **`ai-d1` 17137** / **`ai-d2` 17137** / **`ai-d4` 17163** / **`ai-d8` 17187 cy** / class-0 stripe **`ai-sc2` 16686** / **`ai-sc4` 16686 cy** (`H1_DELAY=4000`). CLASS1 snoop {1,2,4,8} closed. Isolated lrsc **130 cy**; wrap-stack **104 cy**. Same-hart store-between-LR/SC is wrap-TB only. Class-0 SRAM **`ai-sc{2,4,8}` PASS 582 cy** dual-core (striped `gen_sim_stripe` preload; `MaxAROut=2` so not S4). OpenSBI soak stays on the class-0 cookie path. Not 400.

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
| Multi-core | `NrCores` scale per envelope; PLIC `S≤8`. DRAM channels stay a **slave** knob — raising N cores does not raise `DramChannels` (`uncore/dram-channel-scaling.md`) | `NrHarts>2` until `CVA6_MAX_SMT_HARTS` + contexts; do not infer channel count from core count |
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
| 100 TOPS sizing | `ai-matrix/scaling-100tops.md` · `ai-matrix/hard-tests.md` · `uncore/dram-channel-scaling.md` |
| Design asks | `g6lc_qemu/architecture/RTL_FEEDBACK.md` |
| PCIe roles | `uncore/pcie-endpoint.md` · `uncore/pcie-root-complex.md` |
| Queue | `AGENTS-todo.md` Current phase |
