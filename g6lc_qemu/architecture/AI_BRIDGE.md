# AI_BRIDGE — accelerator scale-out and the host bridge

Index: [`README.md`](README.md). Invariants: [`../AGENTS.md`](../AGENTS.md).
Backends: [`DESIGN.md`](DESIGN.md) §3 · Profiles: §4 · Staging: §7 · Non-goals: §8.

---

## 1. The question this document answers

The accelerator model added at Q6 is reached two ways: by instructions from the guest, and by
**work pushed across a host boundary** from outside the guest entirely. The second path is what a
customer-visible accelerator card looks like, and it changes nothing about the four backends — but it
does add an artifact contract, a host-side tool, and a list of things this package must refuse to
model.

This document fixes that boundary. It adds no new backend and no new stage axis.

**Separation of concerns, stated once:**

| Concern | Owner | This package's role |
|---|---|---|
| Accelerator ISA, CSRs, descriptor layout | host design, pin `contracts.ai_isa` | ingest, never define |
| Island MMIO / completion / IRQ surface | host design, pin `contracts.ai_island_mmio` | ingest, never define |
| Island capability geometry (clusters, tiles, NoC, DRAM, queues) | host design, pin `contracts.ai_island_cap` | ingest into `soc.ai_island.config` |
| Host↔card transport (BAR/virtio/doorbell roles) | host design, pin `contracts.ai_host_transport` | **not modelled** — §6 |
| Peak throughput, sustained TOPS, bandwidth closure | host design + RTL simulation | **never claimed** — §7 |
| Emulating the modelled surface; emitting tensor artifacts | **this package** | B0–B3 + D2 |
| Scheduling many runs, CI policy, framework wheels | host project | consumer of §5 |

Nothing below names a path outside `g6lc_qemu/`, and no geometry constant appears as a literal.
Both are deliberate: the values live in the design's own packages and reach the emulator through
[`INGEST.md`](INGEST.md), so a number typed here would become a second source of truth whose
divergence gets misattributed to the RTL.

## 2. Two reach paths over one model

```text
              TargetModel  (soc.ai_island: config + desc_layout + instr_set)
                    │                  one IR, read by every backend
        ┌───────────┴────────────┐
        │                        │
  in-guest reach            pushed reach
  custom-2 queue            host writes descriptors,
  instructions + MMIO       guest driver submits them
        │                        │
        ├── B3 native VM ────────┤     tensor events, D2 counters
        ├── B1 machine C ────────┤     full-system Linux driver path
        └── B2 plugin C ─────────┘     tensor artifact from inside QEMU
                    │
                    ▼
            tensor artifact  ──►  D2 `ai.tensor.*` counters
            (DIAG.md §4.1, EMIT.md tensor row)
```

The two reach paths differ only in **who writes the descriptor**. They share the descriptor layout,
the completion word, the queue semantics and the artifact — by directive 3 of
[`../AGENTS.md`](../AGENTS.md), a second layout for the pushed path would be a defect.

| Reach | Written by | Backends | What it establishes |
|---|---|---|---|
| in-guest | guest code executing `ai.enq`/`ai.poll`/`ai.qfence` | B3, B1+B2 | queue semantics, ticket order, trap behaviour |
| pushed | a host process, submitted by a guest driver | B1+B2 (B3 for the descriptor half) | that a driver and a host runtime agree on the layout |

## 3. What scale means in the model, and what it does not

The island capability configuration is ingested, not chosen here. Scaling is therefore a **question
asked of the model**, not a knob in the emulator:

| Model field | Emulator consequence |
|---|---|
| `config.cap_base`, `config.desc_base` | **placement** of the capability and descriptor windows; `None` means unresolved, and the island is then unaddressable — see §3.1 |
| `config.queues`, `config.queue_depth` | number of rings and per-ring depth; queue-full is observable |
| `config.clusters` | replication unit; the device model routes by queue, it does **not** replicate compute |
| `config.acc_tile_m` / `_n` / `_k` | the blocking a descriptor may legally request; oversize is an error, not a silent clamp |
| `config.macs_per_cycle`, `config.noc_width`, `config.dram_channels`, `config.dram_gbps`, `config.measured_dram_gbps_x1000` | **reported, never simulated** — they size a machine the emulator does not time; `measured_dram_gbps_x1000` overrides `dram_gbps` in the roofline when supplied |
| `config.qos_classes`, `config.work_quantum_k` | admitted and stamped; arbitration fairness is not modelled |
| `config.cap_offsets` | where a guest reads geometry, so one guest binary works across parts |

The capability window is the mechanism that lets a single guest binary run against a small and a
large part. The emulator must therefore **answer from the model and never from a literal**, or it
destroys the only property that made the window worth having.

**Growing the target does not grow the core-attached plane.** The core-attached instructions are a
latency device sized by the core configuration; the island is a throughput device sized by the
capability window. The emulator keeps them separate so a run can exercise the instructions with no
island present, exactly as the two planes are separate in the design.

### 3.1 Two halves of an address, from two different places

A guest-visible register address has two independent halves, and the design keeps them in two
different kinds of file:

| Half | Answer lives in | Ingested? |
|---|---|---|
| offset of a field *within* the descriptor | the accelerator's descriptor **package** | yes — `desc_layout.fields[*].offset` |
| **base** of the descriptor window, and of the capability window, within the island region | the island's **address decode**, i.e. RTL | **not currently published** |

The reader takes the placement from `CAP_BASE` / `DESC_BASE` (or `REG_OFF_CAP` / `REG_OFF_DESC`)
localparams when a configuration package declares them, and reports it **unresolved** when none is
present. It does not parse an address decoder, and it does not guess.

Guessing here is unusually dangerous, which is why absence is loud rather than defaulted: a wrong
base relocates the *entire* descriptor while every individual field still looks correctly placed
relative to its neighbours. The resulting failure looks like a driver or descriptor bug anywhere
except where it actually is.

Current behaviour when the placement is unresolved:

- `AiIslandConfig::placement_resolved()` reports `false`;
- the descriptor window collapses to offset zero — a visible degradation, not a claim;
- the capability window is **not decoded at all**, so a guest read returns nothing rather than a
  plausible-looking wrong geometry;
- `g6q run --backend native` prints a warning naming the cause;
- `ai_tensor_bridge.py` warns while still packing, because a packed descriptor *image* is
  placement-independent — it just cannot be delivered.

**Ask on the design:** publish the island register-map placement as localparams in the accelerator
configuration package, alongside the capability offsets that are already there. Until then the
pushed path can be exercised end-to-end only against a model that states the bases.

## 4. Concurrency: what the design actually permits

The emulator must honour the design's own topology arithmetic, not a wished-for one. Two hard caps
in the host design bound everything in this section, and both are ingested rather than assumed:

- total software harts `S = cores × threads-per-core`, and
- `S` is bounded by the interrupt controller's context count, which the model already carries as
  `soc.intc_targets` / `soc.contexts_per_hart` and enforces in `Soc::harts_total`.

On the reference design that arithmetic yields **`S ≤ 8`**: two threads per core therefore caps cores
at four, and eight cores forces one thread per core. A configuration claiming eight cores *and* two
threads each is not a scaling target, it is an illegal configuration, and the conformance report
should say so rather than the emulator quietly running it. Threads per core are likewise capped at
two by the design of record.

Consequences for the island device model:

| Area | Modelled | Not modelled |
|---|---|---|
| Threads / cores | one ring per hart from `config.queues`, wrapping when rings < harts; island-wide tickets so `ai.poll` stays unambiguous | ring arbitration fairness, banked-accumulator contention |
| Per-hart accelerator state | the design banks accelerator CSRs per hart and requires accumulator banks ≥ threads | bank pressure or spill behaviour |
| Vector data movement | descriptor pointers and byte counts are faithful | vector instruction execution in B3 |
| Issue width | irrelevant to descriptor correctness | any issue-width-derived timing; D2 counts retired descriptors, never cycles |
| Bulk data plane | descriptors in guest-coherent memory, read through the translated map | device-side DMA fetch, and any bandwidth or latency figure |
| Firmware | the queue is discovered as a non-ISA feature via the tree and the capability window | a firmware extension for cross-accelerator scheduling — none is required for the queue |

The ring-per-hart rule is the load-bearing one: a threaded or multi-core guest that submits
concurrently must not serialise onto one ring by accident, because that would hide precisely the
contention the guest software is being tested for.

`config.macs_per_cycle`, `config.dram_gbps` and `config.measured_dram_gbps_x1000` being present in the IR and absent from the timing
model is not an oversight; it is directive 6 of [`../AGENTS.md`](../AGENTS.md) applied to the
accelerator. A cycle-informative model that reported a bandwidth number would be quoted as one.

### 4.1 Premises checked against the design of record

Requests for this document have repeatedly assumed capabilities the host design does not currently
describe. They are recorded here because writing them into the model would manufacture a second
source of truth, which is the failure this package exists to prevent.

| Assumed | What the design of record says | Consequence here |
|---|---|---|
| a 1000-TOPS target | **No document states one.** The stated target is the 100-TOPS class, reached on a *single monolithic die* by replicating clusters behind a NoC boundary frozen as a future die-cut line. Chiplets are deferred behind a die-area gate. **Multi-card scale-out is not described anywhere.** | the package claims no throughput number at all (§9); a 10× tier would need a design decision first, not an emulator change |
| issue width `n > 6` | the configuration field admits up to 8 as *headroom*, but **no named package exceeds 4**. Four-issue is the widest landed configuration. | issue width is ingested and reported; it changes no descriptor behaviour, so nothing here depends on it |
| eight-plus cores with two threads each | prohibited by the `S ≤ 8` interrupt-context arithmetic above | reported as an illegal configuration, not emulated |
| the "stream plane" is the accelerator data plane | **it is not.** In this design "stream plane" means a *multi-core, one-thread-per-core* SoC topology — the counterpart to the SMT plane — and the package named for it caps the *cluster count*, not the issue width. It has nothing to do with the accelerator's descriptor plane. | this document no longer uses the term for the accelerator; the accelerator's asynchronous path is the descriptor ring, and its bulk path is §6 |

An earlier revision of this document misused "stream plane" for the descriptor ring. That was wrong
and is corrected above.

Firmware note: the reference firmware profile is pinned in `../pins.toml`, and the design's own
bring-up is **not** currently green for the two-thread configuration — the firmware's platform
initialisation does not complete its device-tree walk, so its reported hart count stays at a
sentinel rather than reaching `S`. Two invariants follow for anything this package emits: the number
of processor nodes in the tree must equal `S`, and the firmware's hart count must equal `S` before
any topology claim is trusted. An emulator that booted a tree those two rules reject would hide a
live firmware defect.

## 5. The host bridge — an artifact contract, not a control surface

`tools/ai_tensor_bridge.py` is package automation ([`../AGENTS.md`](../AGENTS.md) §5, same tier as
`tools/g6q.py`). It is deliberately thin, and the direction of dependency is fixed:

> The host project **calls** the bridge. The bridge never calls the host project, imports from it, or
> assumes its layout. Becoming a build platform is a non-goal ([`DESIGN.md`](DESIGN.md) §8).

What the bridge owns:

| Step | Behaviour |
|---|---|
| `pack` | pack a descriptor image using **the model's own** field offsets, sizes and op table; `--decode-out` writes a Shell-friendly field dump (`unpack` is the inverse); `--cap-out` writes ingested island CAP geometry plus modelled peak (`cap` dumps the same); `--cpl-out` writes the ingested completion-word layout and a packed example word (`cpl` dumps the same) |
| `push` | run one execution on a chosen route, retrieve the tensor artifact; `--route virt-card` drives the existing `ai-tensor` `virt_ai_card` TCP stand-in (BAR4 put + gemm_s8 golden) and stamps `evidence: false`. With `--model` it packs an OP_GEMM image from `desc_layout`, BAR4-puts it as name `DESC` into UIO DESC@0x140, and stamps `desc_hex` / `bar4_desc`. With `--uarch-out` (native route only) it also runs `g6lc-qemu diag` |
| `results` | summarise the artifact: event count, completion count, op/hart/status/cluster histograms; with `--model` it resolves op/status codes to the design's names, reports the SKU `clusters` count, and with `--per-event` it emits a PyTorch-friendly `outputs` list of completed operations with shapes, `cluster`, `dtype`, and A/B/C pointers; when the artifact carries `flags_layout`, `dtype` is recovered from `flags` when the event does not carry the field |
| `results --tops` | add a 100-TOPS-style roofline section from `g6lc-qemu diag`: `peak_tops`, `peak_gops`, `total_macs`, `total_ops`, the theoretical time the observed MACs would take at peak utilisation, and the `Compute`/`Bandwidth`/`Unresolved` `bound` derived from the D2 `balance_mac_per_byte` and `tiled_input_intensity_mac_per_byte` counters; this is a modelled bound, not a measurement, and is marked `tops_not_evidence` |
| `diag` | run `g6lc-qemu diag` and feed it an optional `--measured-dram-gbps` host measurement; the bridge converts GB/s to milli-GB/s and passes it through `--measured-dram-gbps-x1000`, closing the F11 roofline loop from the host side |
|| `compare` | first-divergence diff between two artifacts, for regression triage |

Two things the bridge deliberately does **not** do, because both would duplicate a contract:

- **It types no descriptor geometry.** Offsets, sizes, op codes and status codes are read from
  `soc.ai_island.desc_layout` in an ingested model. An unknown field name is an error that names the
  available fields; a model with no ingested layout is refused rather than packed with guesses.
- **It does not re-derive the modelled counters.** `ai.tensor.bytes` and `ai.tensor.macs` depend on a
  data-type width table and a dense-execution assumption owned by `g6q-diag` ([`DIAG.md`](DIAG.md)
  §4.1). The bridge reports only what the artifact already contains, so the synthetic counters have
  exactly one implementation.

Also not owned: scheduling policy, framework installation, workload selection, result archival.
Those belong to whichever project consumes the artifact.

Because the artifact is the contract, all three execution routes are interchangeable to a caller.
A Python/PyTorch consumer uses `results --model <model.json>` to map raw op/status codes onto
names, and `results --model <model.json> --per-event` to recover the completed operations with
A/B/C tensor pointers and shapes. The consumer still owns the host-side tensor data: the bridge
gives it the guest-side metadata it needs to line up a reference kernel against the accelerator's
claimed work.

The B3 native run, a local QEMU run, and a remote QEMU run produce the same shape, stamped with the
machine profile and `"evidence": false` per [`DIAG.md`](DIAG.md). For the remote route,
`tools/g6q_remote.py test --ai-island --model <model.json>` derives the RISC-V payload compile
flags from the model (descriptor window base, field offsets, `OP_GEMM`, `UART_BASE`, and the test
shape), pulls the tensor artifact back, and optionally runs `ai_tensor_bridge.py results --tops`
so the remote run reports the same modelled TOPS as a local run.

## 6. Transport: why it is absent

A host↔card transport (config space, BARs, doorbell mapping, message-signalled interrupts, resizable
bulk windows) is named by pin `contracts.ai_host_transport` and is **`unpinned`**. Until that pin is
set, the pushed path is emulated as *"a host process placed descriptors in memory the guest can
reach"* — which is sufficient to validate layout agreement and driver logic, and insufficient to say
anything about link behaviour.

When the contract is pinned, it enters through the normal route: ingest reads it,
[`IR.md`](IR.md) gains the fields, and the B1 emitter generates the glue. Transcribing a proposed
BAR table into this document ahead of that would create exactly the divergence
[`../AGENTS.md`](../AGENTS.md) §1.9 exists to prevent.

Permanently out of scope regardless of pin state: link training, physical-layer behaviour, DMA
engine timing, and any power or thermal figure.

### 6.1 What the host PCIe/virtio outline implies (not yet a contract)

The host monorepo has a scaffold for a compute-card form factor that would carry the pushed path
over a PCIe link
(`architecture/uncore/pcie-endpoint.md`, `architecture/ai-matrix/scaling-100tops.md`).
The salient points for this package are:

- **Direction:** LibreCore as a PCIe *endpoint* enumerated by a host, not as a root complex. This is
  the inverse of `architecture/uncore/pcie-root-complex.md` and must not be confused with it.
- **Control plane:** virtio-pci (net, console, vsock, blk) plus a thin custom management function for
  reset, telemetry, power cap and resizable-BAR setup. Stock in-kernel `virtio_*` drivers would
  satisfy the data path; no bespoke host network driver is required.
- **Bulk plane:** a resizable BAR (BAR4, 256 MB–4 GB) is the proposed bulk tensor/weight window; the
  split control/bulk path is the reason virtio-net alone is rejected for large tensors.
- **Two-plane split:** the 100-TOPS-class target keeps the core-attached `ai.*` instructions as a
  small, fixed latency device (`AiTileM/N/K = 8`) while the throughput island sits on the SoC fabric
  and scales by cluster count. The emulator must preserve that split: the queue instructions are not
  widened with the cluster count, and the island's `macs_per_cycle`/`dram_gbps` are reported, not
  simulated.
- **Staged SKU:** the host plan builds the latency/decode SKU first (one or two clusters, ~12–25 TOPS)
  and reaches the 100-TOPS SKU by replicating clusters behind the same NoC and memory system. The
  emulator's scaling story is therefore "the same queue ABI on more rings", not a second descriptor
  layout or a second transport.
- **SMT/ topology cap:** the design of record keeps `S ≤ 8` and `CVA6_MAX_SMT_HARTS = 2`; a 100-TOPS
  card with many clusters is still limited to the same software-hart count. Core count and cluster
  count are independent.

None of these points change the package until `contracts.ai_host_transport` is pinned. When it is,
the normal ingest route applies: an SoC package or DTB entry publishes the BAR/virtio roles, the
`TargetModel` grows the fields, and the B1/B2 emitters generate the glue. Hard-coding a BAR table,
virtio device id, or a 1000-TOPS claim before that pin is set would be exactly the divergence
[`../AGENTS.md`](../AGENTS.md) §1.9 forbids.

`tools/ai_tensor_bridge.py pcie` exposes the concept without committing to it: it prints the proposed
BAR/virtio/MSI outline and exits with an error when the contract is `unpinned`. This gives host
adapters a stable place to hook the push path once the design publishes the transport contract.

### 6.2 EDK2 PCI witness vs the existing card stand-in

Two implementations already exist. They are **opposite ends of the link** and must not be merged
into one invented BAR table:

| Role | Existing implementation | Gate |
|---|---|---|
| Host **root complex** firmware | QEMU virt GPEX + EDK2 PciBus; `virtio-blk-pci` + hubport `virtio-net-pci` + `virtio-serial-pci` | `--expect 1AF4` / `E2-PCI-BAR` / `E2-PCI-NET` / **`Virtio Network Device`**: GPEX `1B36:0008`, blk `1AF4:1001`, net `1AF4:1000` (VirtioNetDxe bound), console `1AF4:1003`. Hubport: no packets, no `ifconfig` addresses. Stock virtio roles, not an AI BAR |
| Packed descriptor on the ESP | `DESC.BIN` / `DESC.HEX` / `DESC.TXT` from `ai_tensor_bridge.py pack --decode-out` against ingested `desc_layout` (64-byte OP_GEMM, `m=n=k=2`). Shell `type fs0:\DESC.TXT` prints `op=OP_GEMM`. This is a **file**, not a BAR write | `--expect OP_GEMM` (layout agreement only) |
| Model-reported CAP on the ESP | `CAP.TXT` from ingested `soc.ai_island.config` plus modelled peak (`macs_per_cycle × clock × 2 ops/MAC`) and 100-TOPS class vs SKU (`class_need_macs_per_cycle=50000` at 1 GHz; fixture `sku_frac_of_class=0.00512`). Not a measurement | `--expect class_need_macs_per_cycle` |
| UIO MMIO stand-in | `virt_ai_card` `mmio_rd`/`mmio_wr` on the existing 4 KiB window. CAP and DESC bases come from the ingested model (`cap_base`, `desc_base`, `cap_offsets`) | `push --route virt-card --model` logs MMIO CAP + DESC round-trip |
| Doorbell + completion | Host BAR4-stages A/B, writes UIO DOORBELL, polls DONE/TICKET/DSTATUS, claims DONE, reads stand-in PMU (not TOPS). ESP `CPL.TXT`/`CPL.BIN`/`CPL.HEX` is an ingested completion word (`ticket=1`, `ST_OK`). virt-card BAR4 name `CPL` carries the same bytes; `esp_cpl_join` when it matches the ESP file | `--expect example_hex` |
| Two-plane split | ESP `PLANE.TXT`: island throughput from ingested `acc_tile_*`/`clusters`; core plane is latency and **not in this model** (do not type 8×8×8 here). TOPS ride the island | `--expect tops_on=island` |
| IRQ wait + ESP/card join | Host `irq_wait` (eventfd MSI stand-in) then claims DONE. ESP `JOIN.TXT` records DESC/CPL images and SHA-256 shared with BAR4 `DESC`/`CPL`. `esp_desc_join` / `esp_cpl_hash_join` when they match | `--expect join=firmware_and_card` |
| Class DRAM roofline | ESP `ROOF.TXT`: `bytes_per_mac=2/T` from ingested `acc_tile_m`; class BW at 50e12 MAC/s vs this SKU; `acc_sram_bytes=T²·4`. Not a measurement | `--expect class_dram_gbps` / `acc_sram_kib` |
| Ingested queues | ESP `QUEUE.TXT`: `queues`/`queue_depth`/`qos_classes`/`work_quantum_k`; doorbell qid 0 and last=`queues-1`. virt-card rings qid 0 then qid 1 when `queues>=2` | `--expect doorbell_qid_last` |
| Null pointer fields | ESP `PTR.TXT`: ingested `ptr_*` offsets packed as `0` (ABI null). Bulk tensors are BAR4 names `A`/`B`/`C`; completion is MMIO CPL (`wr_cpl_en=0`). No invented DRAM/BAR addresses | `--expect ptr_null` |
| Ingested IRQ flag | ESP `FLAGS.TXT`: `irq_bit` from `desc_layout.flags_layout` (`isa-encoding.md` §7 bit 2). Packed DESC `flags=1<<irq_bit`. virt_ai_card `FLAG_IRQ` matches. Dense INT8 `dtype_s8s8` / `ew_byte`; `int4_not_in_headline` (100 TOPS definition) | `--expect irq_bit_ok` / `dtype_s8s8` |
| Packed `ld_ab` | ESP `DESC.TXT`: `lda=k`, `ldb=n` packed into ingested `ld_ab` (`ai-tensor` `pack_desc64`). Not an address | `--expect ld_ab_ok` |
| Queue→cluster map | ESP `QUEUE.TXT` `qidN_cluster` from ingested `queue_cluster_map`. virt-card stamps `cluster` on each doorbell qid | `--expect cluster_from_map` |
| Scheduling / QoS | ESP `SCHED.TXT`: stand-in `k` vs ingested `work_quantum_k` (`within_quantum`); qid→qos class. FLAGS `fence_clear` / `priority_default`. Card rejects `ld_ab` that does not match `n,k`. Not a measurement | `--expect within_quantum` |
| qid bounds / version | ESP `STAT.TXT`: `qid < queues` (`qid_bound`); oob doorbell rejected; packed `version=1`. Card `ST_ERR` on oob qid or bad version (stand-in error, not an ingested extra status) | `--expect qid_bound` |
| Ingested op table | ESP `OP.TXT`: ingested `OP_GEMM`; packed `op_ok`. Card `ST_BAD_OP` on unknown op (stand-in) | `--expect op_ok` |
| CTL enable | ESP `CTL.TXT`: `ctl_enable=1` `wr_cpl_en=0` (null `ptr_done`). Disabled doorbells complete stand-in `ST_DISABLED`; `CTL.enable=1` restores `ST_OK` (`reenable_ok`) | `--expect reenable_ok` |
| Card **endpoint** stand-in | `ai-tensor/tools/virt_ai_card/` (`VirtualPcieLink` TCP JSON, BAR0-like MMIO, BAR4 blob, golden GEMM). `push --route virt-card --model` BAR4-puts the packed image as name `DESC` into the existing UIO DESC window at 0x140 and stamps `desc_hex` / `bar4_desc` on the artifact | `python3 ai-tensor/tools/virt_ai_card/smoke.py` |
| Joined PCIe function the host enumerates *and* the card exposes | blocked on `contracts.ai_host_transport` | `ai_tensor_bridge.py pcie` exits 1 while unpinned |

`g6lc-soc` has no PCI (`architecture/g6lc-qemu/README.md`). The faithful map is MMIO island
`0x4000_0000` + PLIC-8, not ECAM. EDK2 on virt proving `pci` lists a host bridge is the firmware
half of `pcie-root-complex.md`; `virt_ai_card` is the software half of `pcie-endpoint.md`. Pinning
the transport is what would put an endpoint function on the GPEX bus so both halves share a
device. Until then, run both gates; do not emit a QEMU `pci-testdev` with guessed BAR sizes.

### 6.3 "QEMU is the card's SoC" — where the boundary actually falls

A recurring request is to have QEMU *behave like the SoC on the AI card*, with outside processes
submitting contained PyTorch jobs. That is already the shape of §2's pushed path, but the phrase
hides a fork that decides where every future file goes, so it is written out here.

**QEMU emulates the die, not the link.** The thing on the card is a LibreCore SoC: harts, MMIO
island at `0x4000_0000`, PLIC source 8, DRAM. That is exactly what `g6lc-soc` already models, and it
is why `g6lc-soc` deliberately has **no PCI**. Making the guest enumerate itself over ECAM to reach
its own island would model the *host's* view from inside the card — the one place it does not exist.
So:

```text
  outside QEMU                      │  inside QEMU (= the card's SoC)
                                    │
  contained PyTorch job             │
   torch.nn / torch op              │
        │ ai-tensor-ir              │
        │ ai-tensor-abi (Desc64)    │
        ▼                           │
   bridge / virt-card ──────────────┼──► guest DRAM (descriptors + operands)
   (transport stand-in;             │           │
    the LINK, unpinned)             │           ▼
                                    │    guest driver / UIO ── ai.enq / doorbell
                                    │           │
                                    │           ▼
                                    │    island model ── completion + PLIC-8
   results / tensor artifact ◄──────┼───────────┘
```

The dashed column is the **only** place a transport contract belongs, and it is the only column that
is unpinned. Everything to its right is already faithful; everything to its left is host software.

**Four compartments, four owners.** The reason to draw it this way is that each column then has one
owner and one failure mode, so a bug lands in a known package:

| Compartment | Owner | Fails as |
|---|---|---|
| Framework op → `Desc64` | `ai-tensor` (`-ir`, `-abi`) | wrong descriptor, caught by golden GEMM |
| Host↔card transport | **unpinned** `contracts.ai_host_transport`; stood in by `virt_ai_card` | cannot fail yet — there is nothing to be wrong |
| Guest driver → island | `corev_apu` DTS + UIO; `ai_tensor/qemu_uio.py` in-guest | wrong MMIO/IRQ sequence, caught by the qemu-uio suite |
| Island semantics | design packages, ingested | wrong status/geometry, caught by conformance |

**What "contained" has to mean, concretely.** A PyTorch job arriving from outside is untrusted with
respect to the card, so containment is not a wrapper script — it is three properties the model
already has, and they are worth naming so they are not weakened for convenience:

1. **Descriptor-only authority.** The outside process supplies a `Desc64` and operand bytes. It does
   not choose an island register, an IRQ, or a queue's internal state. Every effect it can have is
   reachable through a descriptor the engine parses and may refuse.
2. **Bounds are the engine's, not the submitter's.** `g6lc_ai_addr_check` and `ST_BAD_PTR` are what
   make an out-of-window pointer an error rather than a read of someone else's memory. A host-side
   check would be advice; the engine's check is the boundary.
3. **Refusal is visible.** `ST_BAD_VER` / `ST_BAD_OP` / `ST_BAD_QID` / `ST_BAD_FMT` are distinct so a
   rejected job reports *why*. A submitter that asked for BF16 on an INT8 part must learn that,
   rather than receive INT8 results computed from BF16 bits.

**What this does not license.** Two claims remain out of reach no matter how complete the guest path
becomes, and both are easy to make by accident once PyTorch runs end to end inside a guest:

- A tensor artifact produced this way is functional agreement on the ABI. It is **not** throughput,
  not TOPS, and not evidence — `../AGENTS.md` §1.8 and [`DIAG.md`](DIAG.md) apply unchanged.
- Running the job under `g6lc-virt` (needed for a distro with Python) does **not** carry over to
  `g6lc-soc`. The virtio profile is stamped and quarantined for exactly this reason; a PyTorch result
  from `g6lc-virt` says the software stack agrees, not that the SoC does.

## 7. Stage placement (no new axis)

This work lands on the existing Q-stages of [`DESIGN.md`](DESIGN.md) §7. The backend letters B0–B3
and diagnosis tiers D1/D2 keep their existing meanings.

| Stage | Item | State |
|---|---|---|
| **Q6** | accelerator ISA decode gated on the ingested instruction set | landed |
| **Q6** | island device model, queue ring, tickets, completion | landed |
| **Q6** | in-guest reach through B3; tensor artifact from B3; B3 `ai.enq` reads the descriptor from guest memory using `desc_layout` and `flags_layout`; B3 `ai.qfence` writes the completion word to `ptr_done` | landed |
|| **Q6** | B3 queue CSRs `aiqbase`/`aiqctl`/`aiqhead` from `AiInstrSet`; CSR read-modify-write instructions routed to the island per hart; head normalised to queue depth | landed |
| **Q7** | D2 `ai.tensor.*` counters, marked synthetic | landed |
| **Q7** | B2 plugin tensor artifact; remote retrieval of it | landed |
| **Q7** | host bridge over the artifact contract (§5) | landed |
| **Q7** | `flags_layout` carried by the tensor artifact and used by the bridge to recover `dtype` from `flags` | landed |
| **Q6** | MMIO window and status codes resolved from the ingested descriptor layout | landed |
| **Q7** | capability-window values answered from `config.cap_offsets` | landed (placement open, below) |
| **Q8** | one ring per hart from `config.queues`; island-wide tickets | landed |
| **Q6** | `config.cap_base` / `config.desc_base` ingested when published; unresolved reported loudly (§3.1) | landed |
| **Q7** | descriptor word-order validation: `bits_to_desc` / `desc_to_bits` / `desc_t` byte-offset comments cross-checked in `g6q-diag` | landed |
| **Q7** | cluster dispatch: `AiIslandConfig.queue_cluster_map` parsed from the config package, B3 `g6q-vm` and B2 generated plugin both use a `cluster` descriptor field or the map, and fall back to unresolved (0) when neither is published | landed — F6 still open until the design publishes one source |
| **Q7** | arithmetic-type subfields of `flags` (`dtype`/`accmode`/`ew`/`sp24`) read from per-field accessors, with a combined comment marked `dtype_combined` so the blob is never reported as a data type | landed — F10 open until the design publishes the accessors; until then sub-byte and sparse work is **not expressible**, so no effective-throughput multiplier may be claimed |
| **Q6** | the design publishing the island register-map placement in the configuration package | open — **ask on the design**, §3.1 |
| **Q8** | conformance rule rejecting `S` above the interrupt-context cap, and accumulator banks below thread count | landed — `g6q-core/src/model.rs` enforces the interrupt-context cap as a blocking finding; `g6q-svcfg/src/derive.rs` raises `AccBanks` to `NrHarts` (the build step normalises rather than asserts, see `AGENTS-todo.md` Q1 C7) |
| **Q8** | host↔card transport once `contracts.ai_host_transport` is pinned | blocked on pin |
| **Q9** | capability matrix row for the accelerator plane | landed — `crates/g6q-ingest/data/capabilities.ini` now has `[matrix-accelerator]` (core-attached `Xg6lcai` token) and `[ai-island]` (uncore `ai-island` node) as two rows, both with the stock-QEMU delta |

Deferred items are tracked in [`../AGENTS-todo.md`](../AGENTS-todo.md); a deferral with no reopen
condition recorded there is a defect.

## 8. Non-goals inherited and added

Inherited from [`DESIGN.md`](DESIGN.md) §8: cycle accuracy · replacing an RTL simulator or an ISS as
a verification reference · forking or linking QEMU · defining an ISA · becoming a build platform.

Added by this document:

- No peak, sustained, or effective throughput claim of any kind.
- No second descriptor layout for the pushed path.
- No transport, power, or thermal modelling.
- No geometry constant typed into this package; the capability window is the only answer.
