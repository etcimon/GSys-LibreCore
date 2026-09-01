# RTL_FEEDBACK — next steps toward 100 TOPS vs the broader SoC

Parent: [`README.md`](README.md). Snapshot: [`../current-stage.md`](../current-stage.md).
Sizing: [`../ai-matrix/scaling-100tops.md`](../ai-matrix/scaling-100tops.md).
The **full ledger** is [`../../g6lc_qemu/architecture/RTL_FEEDBACK.md`](../../g6lc_qemu/architecture/RTL_FEEDBACK.md).
This file is the architecture-side **status + progression** evaluation (F1–F15 are not closed
just because the emulator ingested them).

Rule of record: a constant the design does not publish is an **ask on the design**. Removing a
row because QEMU packed a descriptor is the failure the ledger exists to prevent.

---

## 1. Emulator vs design (F1–F15, 2026-09)

None of F1–F15 is **closed on the design**. Several are **handled on the emulator**: ingest,
validate, or refuse, without guessing.

| Ask | Emulator | Design | Why it still matters |
|---|---|---|---|
| **F1** placement | Ingests `cap_base`/`desc_base` when published | Not localparams beside `CAP_OFF_*` | Guest cannot address the island on B1; virt-card UIO is not that pin |
| **F2** desc version | Named `FALLBACK_DESC_VERSION` once | No accepted-version localparam | Honest bad-version reporting |
| **F3** packed cap words | Parses cap-window expressions | Still comments / `always_comb` | One guest binary across SKUs |
| **F4** word order | Cross-check `bits_to_desc` / comments | Byte vs word map unconfirmed | Host image == device == emitted model |
| **F5** flags dtype/irq | `flags_layout` ingested | Helpers/comments, not localparams | No hard-coded `DTYPE_SHIFT` |
| **F6** cluster | `queue_cluster_map` or field; else 0 | No required map/CSR/field | Per-cluster events; I2 dispatch |
| **F7** §8 vs RTL | Ingests RTL `CAP_OFF_*` | `scaling-100tops.md` §8 still `0x14`=DRAM BW | Silent wrong discovery from the doc |
| **F8** clusters enabled | Cannot split one `Clusters` word | RTL emits a single count | Present ≠ enabled; TOPS/W per SKU |
| **F9** PMU offsets | Reader + modelled PMU ready | Live package offsets unpublished | D2 vs RTL `0x180–0x18C` is hand-only |
| **F10** `ew`/`sp24` | Accessors when published | Live pkg: prio/irq only | No INT4 *effective*-TOPS number |
| **F11** measured DRAM | Roofline refuses BW bound if unpublished | `DramGBps=0` | Cannot say compute- vs bandwidth-bound |
| **F12** MaxDim | `shape_fits_blocking` | Not stated in `isa-encoding.md` §7 | 256³ fits; 4096³ is 16³ tiles |
| **F13** writeback | Roofline uses `max(compulsory,tiled)+4mn` | §4 still input-only `2/T` | Intensity 42 vs 128 MAC/byte at T=256 |
| **F14** 16-bit meas | Saturate like RTL `0xFFFF` | Units/range unclear | 400 GB/s cannot be reported precisely |
| **F15** poll pending | Emulator `POLL_PENDING` / ring-full `0` | Unpublished | Not a hardware contract |

---

## 2. How this should progress toward 100 TOPS

The island track in `scaling-100tops.md` §11 is still the order: **measure I3 bandwidth before
I2 clusters**. virt_ai_card + EDK2 ESP is **layout agreement**, not I3. Do not grow a second
MAC/byte model in host Python.

Headline stays the §2 definition: **100e12 dense INT8 ops/s, 1 MAC = 2 ops, no sparsity/INT4
in the number.** F10 would allow a *second* effective-TOPS figure, not a rewrite of the first.

### 2.1 On the 100-TOPS path (island + host push)

| Order | Work | Why it is next |
|---|---|---|
| 1 | **I3 bandwidth measure** (host `--measured-dram-gbps` is a *hypothesis* only) | §11: do not grow MAC arrays ahead of memory. F11 leaves `DramGBps=0`. Live 256³ is 78% MAC util; widening without I3 predicts ~10% util. |
| 2 | **F12 software tiling** against ingested `acc_tile_*` | §12 `4096³` is not one descriptor on MaxDim=256. |
| 3 | **F13 writeback in any BW claim** | Resident GEMM writeback is `4·m·n`; at `m=n=k=T` that is 2× the inputs. |
| 4 | **F9 PMU offsets as localparams** | Modelled D2 cannot auto-diff RTL `0x180–0x18C`. |
| 5 | **F10 accessors** for `ew`/`sp24` | Else INT4 2:4 is inexpressible. |
| 6 | **F8 enabled-cluster bitmap** then **I2** | F6 map is ambiguous if present≠enabled. |
| 7 | **F1 placement localparams** | B1 guest-visible island. |
| 8 | **F7** make §8 match RTL `CAP_OFF_*` (or the reverse) | Silent wrong discovery. |
| 9 | **Pin `ai_host_transport`** only after BAR/virtio/MSI exist in a package or DTB | Until then EDK2 GPEX ≠ card endpoint. |

Live geometry: **256 MAC/cycle × 1 GHz = 0.512 TOPS**. Throughput SKU plan: 8 clusters ×
4096 MAC/cycle @ 1.5 GHz ≈ **98.3 TOPS**. The 192× gap is MAC width × clock, not an emulator
measurement.

### 2.2 Off the island critical path (separate change sets)

These are **independent envelopes**. A 100-TOPS island pass must not wait for them, and they
must not invent AI BAR sizes or island knobs in `cva6_cfg_t`.

| Change set | Live (2026-09) | Next | Relation to 100 TOPS |
|---|---|---|---|
| **SMT2 / soft-ladder** | Fine-grain banks; cookie `51b1babe`; SL-W landed | SL-C FDT/`cpu-map`; R3b Image; retire `SMT_COLD_EXCL` | Host Linux workers need two honest harts. Not MAC width. QEMU `--smp 2` is not the cookie. |
| **QEMU U-Boot/EDK2** | virt/soc boot green (hypothesis); E2–E3 virt | Soc Shell hang; 32 MiB pflash for E4 | Firmware hypothesis for the card's own Linux. Never Variane evidence. |
| **PCIe bridge** | GPEX RC on virt; virt_ai_card EP stand-in; transport **unpinned** | Pin transport after F1; keep RC ≠ EP | Better PCIe is BAR/MSI/virtio **after** the pin, not a fused QEMU PCI AI device. |
| **Full OoO + multi-issue** | `OoOEn` production-gated; `NrIssuePorts` 1–4 by package | Keep identity when `OoOEn=0`; dual-issue SMT is U6.1 not U5 | Control-plane IPC. Island knobs stay out of `cva6_cfg_t`. |
| **Multi-core** | `NrCores` 1–8 hub; PLIC `S≤8` | Scale per envelope; `CVA6_MAX_SMT_HARTS=2` | Independent of island cluster count. |
| **Hypervisor** | U9.0–U9.2; H-edge 3/3 | KVM stress; G-stage soak | Server SKU, not island TOPS. |
| **Stream plane** | `g6lc64_stream8` CRT 9/9 | Keep separate until FDT trusted | Do not merge with `g6lc64_smt2` DI. |
| **RVV / Ara** | Vendored + attach + lint + DTS + directed | OpenSBI VRF; live cosim | Core-attached memcpy/math. Do **not** widen `AiTileM/N/K=8` with island TOPS. |

---

## 3. Dependency sketch

```text
F1 placement ────► guest-addressable island ────► pushed path end-to-end
F7 cap doc vs RTL ─► a host may discover geometry from the document at all
F11 measured DRAM ─► I3 ─► I2 clusters (F8 enabled bitmap, F6 dispatch)
F13 writeback + F12 MaxDim ─► honest BW sizing and host tiling
F9/F14 PMU ─► BW_measured / TOPS_sustained@AI vs D2, not guessed
F10 ew/sp24 ─► second (INT4 2:4) number only
ai_host_transport pin ─► after F1, never by fusing GPEX with virt_ai_card
```

Growing `MacsPerCycle` from 256 toward the 8192 latency-SKU target without I3 shrinks only the
78% that is already arithmetic and leaves delivered throughput almost unchanged. That is the
failure `scaling-100tops.md` §11 orders the track to make structurally impossible.
