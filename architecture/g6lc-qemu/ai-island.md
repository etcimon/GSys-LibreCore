# `g6lc_qemu` — `Xg6lcai` in the emulator, and ai-tensor inside the guest

Parent: [`README.md`](README.md).
**Normative contract (consumed by pin, never reinterpreted):**
[`../ai-matrix/isa-encoding.md`](../ai-matrix/isa-encoding.md) — opcodes, CSRs, descriptor ABI ·
[`../ai-matrix/README.md`](../ai-matrix/README.md) §1 (T0/T1/T2), §5 (ISA/CSR) ·
[`../../corev_apu/ai_island/README.md`](../../corev_apu/ai_island/README.md) (live MMIO/CTL/DMA) ·
[`../ai-matrix/board-uio-eventfd.md`](../ai-matrix/board-uio-eventfd.md) (PLIC-8 / DONE / UIO) ·
[`../../ai-tensor/AGENTS.md`](../../ai-tensor/AGENTS.md) (host ML backend).

The goal of this document: make `ai-tensor` able to run **inside a guest Linux on the emulator**,
against a generated model of the real island, so that the AI software stack can be exercised at
boot-to-shell speed instead of at Verilator speed — without inventing a fifth descriptor layout.

---

## 1. What has to be modelled, and where it lives

`Xg6lcai` is deliberately two planes on opposite sides of the core boundary
([`../ai-matrix/README.md`](../ai-matrix/README.md) §1.1). The emulator mirrors that split exactly.

| Plane | RTL | Emulator locus | Sized by |
|---|---|---|---|
| **T0/T1 core-attached** — `ai.setcfg`, `ai.dot4`, `ai.mv*`, requant/act, `ai.enq`/`ai.poll` | `core/cvxif_g6lc_ai/` at the CVXIF seam | CPU model: custom-2 decode + `aicfg`/`aistatus` CSRs (B1 `trans_xg6lcai.c.inc`, B3 native) | `config_pkg::ai_cfg_t` |
| **T2 island** — descriptor rings, GEMM, DMA, completion, IRQ | `corev_apu/ai_island/` | device model `g6lc_ai_island` on the SoC bus | `g6lc_ai_island_cfg_pkg::ai_island_cfg_t` + the MMIO **capability window** |

Keeping them separate in the emulator is not tidiness — it is what lets `--plane core` model the T0
instructions without an island, and what keeps island geometry (clusters, MACs/cycle, NoC, QoS) out
of the core config, exactly as
[`../ai-matrix/README.md`](../ai-matrix/README.md) §4.1 decided for the RTL.

---

## 2. CPU-side model (T0)

**Opcode space:** custom-2 `0b1011011` (`0x5B`). custom-3 (`0x7B`) is squatted by the shipped CVXIF
example and must not be used. All `Xg6lcai` instructions are 32-bit; **no compressed encodings** —
the compressed CVXIF response is always `accept = 0`.

**`funct3` groups and their config gates** (generated from the model's `ai` block, so a target with
`RequantEn=0` traps on `funct3=100` rather than silently executing):

| `funct3` | Group | Gate |
|---|---|---|
| `000` | configuration (`ai.setcfg`, `ai.getcfg`, `ai.relacc`) | `MatrixEn` |
| `001` | MMA | `MatrixEn` |
| `010` | tile load/store | `MatrixEn` **and** `TileLdEn` (see §4) |
| `011` | GPR dot product | `MatrixEn` |
| `100` | requantise / activate | `RequantEn` |
| `101` | queue management (T2) | `Queues > 0` |
| `110` | sparse / gather assist | `SparseEn` |
| `111` | reserved | **must trap** |

**Operand classes matter.** The contract distinguishes GPR operands (`rs1`/`rs2`/`rd`, read through
the register file) from **tile indices** occupying the same bit positions but naming private SRAM.
The emulator must honour that split, because getting it wrong produces results that look right on a
single instruction and wrong under register pressure. Tile/accumulator index widths are `$clog2` of
`TileCount` / `AccBanks × AccDepth`; out-of-range ⇒ illegal instruction.

**`ai.setcfg` is `vsetvli`-shaped and its return value is authoritative.** The emulator grants at the
configured geometry and returns the *granted* value in `rd`; software that uses the requested value is
buggy, and the emulator must expose that bug rather than paper over it by granting whatever was asked.

**CSRs:** `aicfg` `0x801` (geometry/dtype), `aistatus` `0x802` (busy, dirty, error, ownership, and
`ais[7:6]`), `aiscale`/`aizp` (requant), `aiqbase`/`aiqctl` (**S-mode only**; U-mode gets a mapped
doorbell page), `aiperm` (per-privilege issue enable). `0x800` is `CSR_FTRAN` — never host `aicfg`
there.

**Extension state (AI-X).** `aistatus.ais` is the Off/Initial/Clean/Dirty field; `mstatus.xs` /
`vsstatus.xs` are a **read-only summary** of `ais` when `MatrixEn=1`. Illegal-instruction on issue
tests `ais`, not a writable XS. The emulator implements this exactly, and models
**accumulator flush / ownership check on context switch** — stale INT8 activations leaking between
tenants is a real property of the design that a lax emulator would hide.

**SMT.** With `NrHarts=2`, `aicfg`/`aistatus` are **per hart** and accumulators are **banked**
(`AccBanks ≥ NrHarts`), not ownership-locked. The emulator banks them; it does not model arbitration
fairness (that is D2 / Verilator territory).

---

## 3. Island device model (T2)

Generated from `corev_apu/include/g6lc_ai_island_cfg_pkg.sv`,
`corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv` and the module inventory under
`corev_apu/ai_island/`.

**Placement (from the live SoC map):** the 4 KiB **GPIO window** at `0x4000_0000`
(`ariane_soc::GPIOBase` = `AiIslandBase`) when `AiCfg.MatrixEn`; otherwise the window stays an error
slave and the device is not instantiated. IRQ is **PLIC source 8** (`irq_sources[7]`), sticky on
`desc.flags[2]`.

**Register surface modelled** (offsets carried in the model, not typed here as constants — the
authority is the RTL + island README):

| Region | Behaviour |
|---|---|
| **CAP window** | read-only capability words: `MacsPerCycle`, `AccTileM/N/K`, queues, queue depth, NoC width, DRAM info. Software (including ai-tensor) discovers geometry here — **this is the mechanism that lets one binary run on the 5-TOPS and 100-TOPS parts**, so the emulator must never hard-code geometry into the guest-visible answer. |
| **CTL `0x100`** | bit0 enable, bit1 `wr_cpl_en` (completion-word DMA). Reset default `wr_cpl_en = EnableDmaFetch`. Directed tests use `CTL=3`; PLIC-IRQ soak uses `CTL=1`. |
| **DONE `0x10C`** | completion claim = pop CPL FIFO head; multi-ticket ordering preserved |
| **`desc_ptr` `0x118`/`0x11C`** | descriptor pointer; doorbell bit[31] = fetch |
| **AI-3 regions** | per-queue `[base, limit)` + R/W permission check; out-of-range / permission failure returns the RTL's error code, not a host fault |
| **PMU `0x180`** | island counters |

**Descriptor ABI:** the **64-byte** `Desc64` from `g6lc_ai_desc_pkg.sv`, with the same version/op
validation and the same `make_completion` word. One layout for MMIO doorbell, `ai.enq`, PyTorch and
TensorFlow — a framework-specific layout is a defect
([`../../ai-tensor/AGENTS.md`](../../ai-tensor/AGENTS.md) §1.3).

**Compute:** the emulator implements the **functional** INT8 GEMM (`s8×s8→s32` accumulate, plus
`u8`/`su8`/`us8` variants and the requant/activation post-ops) matching the golden used by
`ai_gemm_s8_smoke`. It does **not** model the PE array, banking, oct-drain, multi-outstanding AR, or
the 83,705-cycle 256³ figure. Island throughput is a Verilator/`hard-tests.md` question; the emulator
answers *"does the software stack drive this device correctly"*.

**Interrupt path detail worth modelling exactly:** clear the level source (`AI_DONE`) **before** PLIC
complete, or a level-set re-arms IP. Getting this wrong in the emulator would mask a real driver bug.

**Sideband ordering quirk:** after any desc/region MMIO write, guest software must load a *different*
island register before `ai.enq` (same-address load-back can store-to-load-forward; the kick is a core
wire). The emulator reproduces the hazard rather than being permissive, so guest code that works here
also works on RTL.

---

## 4. `AiTileLdEn` — the one behavioural difference between seams

`funct3=010` (`ai.ldt`/`ai.stt`) is **not executable under seam B**: CVXIF has no memory port, so tile
loads must be synthesised from scalar loads plus `ai.mvta`. Under seam D (accelerator port) they use
the accelerator MMU port. This is exposed as the separately discoverable `AiTileLdEn`, *not* as an
encoding change ([`../ai-matrix/isa-encoding.md`](../ai-matrix/isa-encoding.md) §3.3, §8).

The emulator therefore:

- reads `AiCfg.TileLdEn` and `AiCfg.AccelEn` from the model,
- traps `funct3=010` as illegal when `TileLdEn=0`,
- reports the seam (`B` / `D`) in the model and in every trace header.

`isa-encoding.md` §2.2 makes the encoding, CSR map and descriptor ABI **invariant across B and D** so
that the toolchain, kernel driver and PyTorch backend survive the seam migration untouched. The
emulator inherits that property for free — and would destroy it if it special-cased seams anywhere
other than this one gate.

---

## 5. `ai-tensor` inside the guest — the `qemu-uio` backend

`ai-tensor` today has backends `sim` (hostless), `virt-card` (soft UIO / eventfd, local or TCP
`CardAgent`), and the SV **HARD** path via `tensor virt-impl --impl hard`
([`../ai-matrix/frameworks-virt-pcie.md`](../ai-matrix/frameworks-virt-pcie.md)). The emulator adds a
fourth, and it is qualitatively different from the others:

| Backend | Where ai-tensor runs | What it exercises |
|---|---|---|
| `sim` | host, hostless | ABI pack/unpack, IR |
| `virt-card` | host, soft device | contract conformance, eventfd/UIO shape |
| SV HARD | host driving Verilator | the real RTL, at RTL speed |
| **`qemu-uio`** (**landed**, `ai-tensor/python/ai_tensor/qemu_uio.py`) | **inside guest Linux on the emulator** | the *whole* path: Linux UIO bind → mmap of the `g6lc,ai-matrix` node → doorbell → PLIC-8 IRQ → DONE claim → descriptor ABI |

This is the only backend where the **guest kernel driver, the DTS node, the interrupt path and the
userspace runtime are all in the loop at once**, and it runs at boot-to-shell speed rather than at
200 M-cycle-soak speed.

**How it is wired:**

1. `g6q run --target g6lc64_ai --machine g6lc-soc --ai-island on --dts corev_apu/bootrom/ariane-ai.dts`
   boots Linux with the `g6lc,ai-matrix` node present (`compatible = "g6lc,ai-matrix"`, `reg` at
   `0x4000_0000`/`0x1000`, `interrupts = <8>`, plus the `g6lc,acc-tile-*` / `g6lc,macs-per-cycle` /
   `g6lc,queues` discovery helpers).
2. In-guest UIO binds the node. `uio_pdrv_genirq` matches it two ways: the DTS now carries
   `compatible = "g6lc,ai-matrix", "generic-uio"`, and the OpenWrt command line also sets
   `uio_pdrv_genirq.of_id=g6lc,ai-matrix` so an out-of-date DTB still binds. ai-tensor sets
   `AI_TENSOR_UIO` to the guest UIO path (a `virt://` path still selects `virt-card`).
3. ai-tensor reads geometry from the **CAP window**, not from the DTS helpers — same rule as on real
   hardware. The accumulator tile comes from the packed `block_mnk` word, which is the bound every
   descriptor dimension must respect (F12).
4. `gemm_s8` submits a `Desc64`, rings the doorbell, waits on the eventfd/IRQ, claims DONE, and
   compares against the same INT8 golden as `ai_gemm_s8_smoke`.

**Operands need a guest-physical home.** The island DMAs `A`/`B`/`C`, so they cannot live in
ordinary pageable memory. `ariane-ai.dts` carves a `no-map` `reserved-memory` region out of the
same DRAM the cores use — one `memory@` node still, a carve-out and not a second address space —
and the node points at it with `memory-region`. ai-tensor takes the window as
`AI_TENSOR_DMA_BASE`/`AI_TENSOR_DMA_SIZE` and refuses to start without a base, because an invented
DMA base corrupts whatever actually lives there.

**What the emulator side had to gain to make this real.** The device model used to record
descriptors and completion words without computing anything, so an in-guest test could only ask
"did a completion appear" — which passes on a device that multiplies nothing. B3 now reads the
operands and writes `C` (`g6q-vm/src/gemm.rs`), and the published control surface
(`REG_OFF_{CTL,STATUS,DOORBELL,CPL}`) is ingested and implemented, so the sequence above is the
sequence the emulator actually executes.

**Cross-connect discipline** ([`../../ai-tensor/AGENTS.md`](../../ai-tensor/AGENTS.md) §4): the
emulator consumes the contract by **pin**; if the silicon docs change opcodes, CSRs or the descriptor,
`pins.toml` is bumped and the ABI version with it. Bits are never silently reinterpreted, and
`g6lc_qemu` never becomes a second place where the encoding is defined.

**Rootfs note:** the faithful `g6lc-soc` profile has no disk, so the `qemu-uio` path uses an
initramfs-embedded ai-tensor build. A full PyTorch stack needs `g6lc-virt`
([`os-linux-matrix.md`](os-linux-matrix.md) §4) — and results from it are software-valid,
hardware-invalid, per the profile rule.

---

## 6. PMU group 4

Group `MHPMGrpAI = 4`, indices stable once published: `0` op complete, `1` MMA complete, `2` post-op,
`3` T0 complete, `4` busy cycle. The emulator increments them from the same events, so an in-guest
`perf stat` over a tensor workload produces counters comparable with the directed
`ai_pmu_group4_smoke` numbers. RVFI carries `aicfg`/`aistatus`, so AI CSR state is visible in D1
tandem records too.

---

## 7. Invariants and pitfalls

1. **No second ISA definition.** `isa-encoding.md` is normative; the emulator's tables are generated
   from the model, and any encoding constant typed into `g6q-emit-qemu` or `g6q-vm` is a defect.
2. **CAP window is the discovery mechanism.** Never let the guest learn geometry from a hard-coded
   emulator constant; that would break the "one binary, many SKUs" property the RTL was designed for.
3. **Functional, not throughput.** The emulator says nothing about TOPS. `../ai-matrix/hard-tests.md`
   and `scaling-100tops.md` own that; a TOPS number from `g6lc_qemu` is meaningless.
4. **Island presence is a flist fact.** The island README records it is *not yet on the SoC AXI flist*
   in every configuration; the conformance report must say `stub`/`absent` rather than instantiating a
   device the elaborated design does not have.
5. **Seam is reported, not assumed.** B today, D on the roadmap; only `AiTileLdEn` behaviour differs
   (§4).
6. **Trap fidelity over convenience.** Reserved `funct3=111`, out-of-range tile indices, U-mode issue
   without `aiperm`, `aiqbase`/`aiqctl` from U-mode, and `ais`-gated illegal-instruction must all trap.
   An emulator that is permissive here produces guest software that fails on silicon.
