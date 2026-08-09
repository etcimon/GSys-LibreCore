# `Xg6lcai` — frozen ISA, CSR and descriptor contract

**Status:** proposed, unratified · **Scope:** normative for **both** seam options B and D
**Parent:** `README.md` (read §2 first) · **Licensing:** tier T doc; the contract it describes is
implemented by tier **R** RTL and consumed by tier **R/T** interface files

> **Why this document exists.** `README.md` §2.2 makes the encoding, the CSR map and the T2 descriptor
> ABI **invariant across the CVXIF (B) and accelerator (D) seams**, so that the toolchain, the kernel
> driver and the PyTorch backend survive the seam migration untouched. That only holds if the contract
> is written down *before* either implementation exists. This is that contract.
>
> **This is a specification, not an implementation.** Nothing here is licensing-blocked: **AI-0 closed
> with the AI plane on the normal open path** (tier R), so the RTL may be written whenever the
> contract is settled. See `README.md` §7.

## Table of contents
1. Opcode allocation
2. Operand model (the decisive design choice)
3. Instruction encodings
4. CSR map
5. Extension state and context switching
6. Trap and illegal-instruction behaviour
7. T2 descriptor ABI
8. Discovery
9. Versioning and change control
10. Seam-specific notes (B vs D)

---

## 1. Opcode allocation

| Space | Encoding | Status |
|---|---|---|
| custom-0 | `0b0001011` | free, not used here |
| custom-1 | `0b0101011` | free, not used here |
| **custom-2** | **`0b1011011` (`0x5B`)** | **allocated to `Xg6lcai`** |
| custom-3 | `0b1111011` (`0x7B`) | **taken** — the shipped CVXIF example squats it (`core/cvxif_example/include/cvxif_instr_pkg.sv:56-64`) |

custom-2 is chosen so that the AI extension and the existing CVXIF example can coexist in one tree
without a mask/match conflict, even though they are never enabled together.

All `Xg6lcai` instructions are 32-bit. **No compressed (16-bit) encodings are allocated**; the CVXIF
compressed interface stays unused by this extension, so `compressed_resp.accept` is always `0`.

## 2. Operand model (the decisive design choice)

`Xg6lcai` has **two distinct operand classes**, and confusing them is the most likely implementation
bug:

| Class | Fields | Meaning | CVXIF `register_read` |
|---|---|---|---|
| **GPR operands** | `rs1`, `rs2`, `rd` | ordinary integer registers, read/written through the core register file | **set** |
| **Tile indices** | same bit positions | index a tile or accumulator in the AI block's private SRAM — **not** a register-file access | **clear** |

This matters concretely: `issue_resp_t.register_read` in the CVXIF issue response tells the core which
GPRs to fetch (`core/cvxif_example/include/cvxif_instr_pkg.sv:29-33`). Declaring a tile index as a GPR
read wastes register-file ports and serialises issue against unrelated scoreboard entries. **Every
encoding below states its operand class explicitly.**

Tile and accumulator index widths are `$clog2` of the configured counts and must be checked against
`AiTileCount` / `AiAccBanks × AiAccDepth`; out-of-range indices raise illegal-instruction (§6).

## 3. Instruction encodings

R-type field layout throughout: `funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] |
opcode[6:0]`, `opcode = 0b1011011`.

`funct3` selects the group:

| `funct3` | Group | Config gate |
|---|---|---|
| `000` | configuration | `AiMatrixEn` |
| `001` | matrix multiply-accumulate | `AiMatrixEn` |
| `010` | tile load / store | `AiMatrixEn` |
| `011` | GPR dot product | `AiMatrixEn` |
| `100` | requantise / activate | `AiRequantEn` |
| `101` | queue management (T2) | `AiQueues > 0` |
| `110` | sparse / gather assist | `AiSparseEn` |
| `111` | *reserved* — must trap | — |

### 3.1 Configuration — `funct3 = 000`

| `funct7` | Mnemonic | Operands | Semantics |
|---|---|---|---|
| `0000000` | `ai.setcfg rd, rs1` | GPR `rs1` in, GPR `rd` out | request tile geometry/dtype in `rs1`; write **granted** config to `aicfg` and return it in `rd` |
| `0000001` | `ai.getcfg rd` | GPR `rd` out | read `aicfg` without modifying it |
| `0000010` | `ai.relacc` | tile index in `rd` | release/zero accumulator `rd`; ends its liveness for context-switch purposes |

**`ai.setcfg` is `vsetvli`-shaped and its return value is authoritative.** Software must use the
returned geometry, never the requested one. A request the hardware cannot satisfy is granted at the
nearest supported geometry — it does **not** trap. This is what allows one binary to run on
differently configured parts.

`rs1` layout (request) and `rd` / `aicfg` layout (grant) are identical:

| Bits | Field | Meaning |
|---|---|---|
| `3:0` | `M` | log2 tile rows |
| `7:4` | `N` | log2 tile cols |
| `11:8` | `K` | log2 reduction depth |
| `13:12` | `dtype` | `00` s8×s8, `01` u8×u8, `10` s8×u8, `11` u8×s8 |
| `15:14` | `accmode` | `00` overwrite, `01` accumulate, `10` accumulate-saturating, `11` reserved |
| `19:16` | `version` | contract version, read-only on grant (§9) |
| `21:20` | `ew` | element width: `00` 8-bit, `01` 4-bit, `10`/`11` reserved |
| `22` | `sp24` | request structured 2:4 sparsity on operand A |
| `XLEN-1:23` | *reserved* | write zero, read zero |

**`ew` and `sp24` exist so that sub-byte and sparse modes are requestable at all.** `dtype[13:12]` is
fully allocated to the four signedness combinations, so without a separate width field INT4 — the main
"effective TOPS" lever at island scale (`scaling-100tops.md` §1) — has no encoding. Both fields are
carved from previously reserved space and both are **`0` on a part that does not implement them**,
which is exactly the value version-1 software writes; the `ai.setcfg` grant rule then downgrades a
4-bit or sparse request to `00`/`0` rather than trapping. Supported combinations are enumerated in the
island capability window, not guessed (§8).

### 3.2 Matrix multiply-accumulate — `funct3 = 001`

| `funct7` | Mnemonic | `rd` | `rs1` | `rs2` |
|---|---|---|---|---|
| `0000000` | `ai.mma.s8` | acc index | tile index A | tile index B |
| `0000001` | `ai.mma.u8` | acc index | tile index A | tile index B |
| `0000010` | `ai.mma.su8` | acc index | tile index A | tile index B |
| `0000011` | `ai.mma.us8` | acc index | tile index A | tile index B |

All operands are **tile indices**, no GPR reads, no GPR writeback. Accumulation is `s32` regardless of
input signedness. Effective shape comes from `aicfg`, not from the instruction.

These are the **T1** long-latency operations: they complete out of order with respect to surrounding
scalar work but retire precisely through the scoreboard.

### 3.3 Tile load / store — `funct3 = 010`

| `funct7` | Mnemonic | `rd` | `rs1` | `rs2` |
|---|---|---|---|---|
| `0000000` | `ai.ldt` | tile index (dest) | **GPR** base address | **GPR** row stride in bytes |
| `0000001` | `ai.stt` | tile index (src) | **GPR** base address | **GPR** row stride in bytes |
| `0000010` | `ai.mvacc` | **GPR** dest | acc index | element index |
| `0000011` | `ai.mvta` | tile index (dest) | **GPR** src | element index |

Mixed operand classes — note carefully which fields are GPRs.

`ai.ldt` / `ai.stt` are **ordinary memory accesses** and are fully subject to translation, PMP/PMA and
the memory model. Under seam **B** they cannot be issued by the coprocessor (no memory port) and must
be synthesised by the compiler from scalar loads plus `ai.mvta`; under seam **D** they use the
accelerator MMU port. **This is the one place where B and D differ in what the hardware can execute**,
and it is why `AiTileLdEn` is discoverable separately (§8).

### 3.4 GPR dot product — `funct3 = 011`

| `funct7` | Mnemonic | Operands |
|---|---|---|
| `0000000` | `ai.dot4.s8 rd, rs1, rs2` | all **GPR**: four `s8` lanes each, `s32` dot product, sign-extended to XLEN in `rd` |
| `0000001` | `ai.dot4.u8 rd, rs1, rs2` | all **GPR**, unsigned |
| `0000010` | `ai.dot4a.s8 rd, rs1, rs2` | all **GPR**, accumulate into prior `rd` (read-modify-write, three GPR reads) |

Pure **T0**: single-cycle-class, precise, no tile state touched. This is the irregular/sparse fallback
path and the one group that remains useful even when every other group is configured out.

### 3.5 Requantise and activate — `funct3 = 100`, gated on `AiRequantEn`

| `funct7` | Mnemonic | `rd` | `rs1` | `rs2` |
|---|---|---|---|---|
| `0000000` | `ai.requant` | tile index (dest, s8) | acc index (src, s32) | **GPR** pointer to per-channel scale/zero-point |
| `0000001` | `ai.requant.t` | tile index | acc index | **GPR** immediate-style packed scale (per-tensor) |
| `0000010` | `ai.act.relu` | tile index | tile index | — |
| `0000011` | `ai.act.gelu` | tile index | tile index | approximation selected by `aicfg.version` |

Rounding is **round-half-to-even** on the `s32 → s8` narrowing, then saturating clamp to `[-128, 127]`
(or `[0, 255]` for unsigned output). **This rule is normative**: a mismatch here silently degrades
model accuracy and is the single most likely source of a "works in Python, wrong on hardware" bug.

**Seam B packed scale (GPR `rs2`) for both `ai.requant` and `ai.requant.t`:** the CVXIF seam has no
memory port, so the “pointer” form cannot dereference a table. Software passes one tensor’s parameters
inline:

| Bits | Field | Type |
|---|---|---|
| `15:0` | `scale` | s16 multiplier |
| `23:16` | `zp` | s8 zero-point |
| `27:24` | `shift` | 0–15, applied after multiply |
| `31:28` | reserved | write 0 |

Compute: `y = clamp_s8( round_half_to_even(acc * scale, shift) + zp )`. Per-channel tables remain the
job of the T2 island / seam D (or a software loop of `.t` ops).

### 3.6 Queue management (T2) — `funct3 = 101`, gated on `AiQueues > 0`

| `funct7` | Mnemonic | `rd` | `rs1` | `rs2` |
|---|---|---|---|---|
| `0000000` | `ai.enq rd, rs1` | **GPR** ticket out | **GPR** descriptor pointer | — |
| `0000001` | `ai.poll rd, rs1` | **GPR** status out | **GPR** ticket | — |
| `0000010` | `ai.qfence` | — | — | — |

`ai.enq` returns a monotonically increasing ticket, or all-ones on queue-full — it **does not block and
does not trap** on a full queue. `ai.poll` returns `0` pending, `1` complete, `2` completed with error;
error detail is in the descriptor's completion word (§7).

`ai.qfence` orders all previously enqueued descriptors from this hart against subsequent memory
accesses; it is a **release** on enqueue and an **acquire** on completion observation. It does not wait
for completion — use `ai.poll` for that.

### 3.7 Sparse assist — `funct3 = 110`, gated on `AiSparseEn`

| `funct7` | Mnemonic | `rd` | `rs1` | `rs2` |
|---|---|---|---|---|
| `0000000` | `ai.gathr` | tile index (dest) | **GPR** base | **GPR** index vector pointer |
| `0000001` | `ai.expsel` | **GPR** selected expert id | **GPR** score vector pointer | **GPR** count |

Same memory-access caveat as §3.3 under seam B.

## 4. CSR map

Addresses chosen to avoid collisions in this tree:

- `0x7C0`/`0x7C1`/`0x7C2` = `CSR_ICACHE`/`CSR_DCACHE`/`CSR_ACC_CONS`
- **`0x800` = `CSR_FTRAN`** (FP precision control) — **must not** host `aicfg`. Surfaced at CSR
  implementation time; URW AI CSRs therefore start at **`0x801`** (pre-implementation address fix,
  not a version bump — no software was shipped against `0x800`).

| Address | Name | Priv | Purpose |
|---|---|---|---|
| `0x801` | `aicfg` | URW | active geometry/dtype/accmode; layout per §3.1 |
| `0x802` | `aistatus` | URW | `[0]` busy, `[1]` acc dirty, `[2]` queue error, `[5:4]` owning hart, `[7:6]` **`ais`** extension status (§5), `[15:8]` last error code |
| `0x803` | `aiscale` | URW | pointer to the active per-channel scale table |
| `0x804` | `aizp` | URW | pointer to the active zero-point table |
| `0x5C0` | `aiqbase` | SRW | T2 ring base physical/effective address |
| `0x5C1` | `aiqctl` | SRW | `[0]` enable, `[7:4]` log2 ring entries, `[15:8]` queue id |
| `0x5C2` | `aiqhead` | SRW | ring head, software-owned |
| `0x7C8` | `aiperm` | MRW | `[0]` U-mode issue enable, `[1]` S-mode, `[2]` VS-mode, `[3]` lock |

Rationale for the split: `aicfg`/`aistatus`/`aiscale`/`aizp` are **per-context user state** and must be
cheap to save/restore; the ring registers are **kernel resources**; `aiperm` is a machine-mode policy
gate. User-mode T2 submission uses an `mmap`ped doorbell page, **never** `aiqbase`.

All AI CSRs raise illegal-instruction when `AiMatrixEn == 0`, exactly as `CSR_ACC_CONS` does today
under `EnableAccelerator` (`core/csr_regfile.sv:1013-1016`, `:2104-2107`) — copy that pattern.

## 5. Extension state and context switching

> **Corrected before implementation (AI-E3).** Version 1 of this document said to "un-hardwire
> `mstatus.xs`" and make it software-writable. **That is not architecturally legal.** The privileged
> spec states that `mstatus` has "the FS[1:0] and VS[1:0] **WARL** fields and the XS[1:0] **read-only**
> field", that "**every additional extension with state provides a CSR field that encodes the
> equivalent of the XS states**", and that "the XS field effectively reports the **maximum** status
> value across all user-extension status fields". `XS` is a *summary*, never a control. No
> implementation existed yet, so this is a correction rather than a version bump (cf. AI-E2).

**`mstatus.xs` is currently hardwired to `Off`** (`core/csr_regfile.sv:1791`; `vsstatus_d.xs` likewise
at `:1425`), which is **correct and spec-required today**: "in harts without additional user extensions
requiring new state, the XS field is read-only zero." The hardwire is not a bug to be removed — it
becomes wrong only once an extension with state exists. `mstatus.sd` **already** ORs `xs == Dirty`
(`:2242`), so that half needs no change.

The contract is therefore:

1. **`aistatus[7:6]` (`ais`) is the extension's own status field**, using the standard Off / Initial /
   Clean / Dirty encoding (spec Table 101). It is **URW** — this, not `XS`, is what a kernel writes to
   do lazy state switching, and what it clears to `Off` to disable the unit for a context.
2. **`mstatus.xs` becomes a read-only summary** = the maximum status across user extensions with
   state. `Xg6lcai` is currently the only one, so `xs == ais`. It stays hardwired `Off` whenever
   `AiMatrixEn == 0`, so **every existing package remains bit-identical**. Writes to `mstatus.xs` are
   ignored (read-only), never trapped.
3. **Hardware sets `ais = Dirty`** on any instruction that writes tile or accumulator state; `xs`
   follows, and `sd` follows `xs` with no further change.
4. **Trap AI instructions with illegal-instruction when `ais == Off`** (equivalently `xs == Off`, since
   they are equal while AI is the only X extension). Test `ais`, not `xs`, so the rule stays correct if
   a second X extension is ever added and `xs` becomes a max over both.
5. Under `RVH`, `vsstatus.xs` is the same read-only summary for the virtualised context.

**Implementation consequence:** the AI-X work is *not* "delete the `xs = Off` line". It is "make `xs` a
read-only function of `ais`, gated on `AiMatrixEn`", which means `aistatus` must exist first.

**Context-switch contract for supervisor software:** save/restore `aicfg`, `aistatus`, `aiscale`,
`aizp`, plus tile and accumulator contents if `xs == Dirty`. **Accumulators must be zeroed or
ownership-checked on switch** — residual `s32` activations are another tenant's data on a multi-tenant
inference card.

**SMT2:** `aicfg`/`aistatus` are per-hart. Accumulators are banked per hart
(`AiAccBanks >= NrHarts`), so `aistatus[5:4]` reports the owning hart for diagnostics rather than
arbitrating a shared resource.

## 6. Trap and illegal-instruction behaviour

| Condition | Result |
|---|---|
| `AiMatrixEn == 0` | illegal-instruction on the whole custom-2 opcode |
| group's config gate off (e.g. `AiRequantEn == 0`) | illegal-instruction |
| `funct3 = 111`, or an unallocated `funct7` | illegal-instruction — **must not** be a silent NOP |
| tile / accumulator index out of range | illegal-instruction |
| `aistatus.ais == Off` (equivalently `mstatus.xs == Off`) | illegal-instruction — test `ais`, per §5 |
| issued from U-mode with `aiperm[0] == 0` | illegal-instruction |
| `ai.ldt`/`ai.stt` fault | ordinary load/store page/access fault, precise, with correct `tval` |
| T2 descriptor error | **not** an exception — reported through `ai.poll` and the completion word |

`tval` carries the faulting instruction when `TvalEn`, matching `cvxif_fu`'s handling
(`core/cvxif_fu.sv:68-77`).

Reserved encodings trapping (rather than NOP-ing) is what makes future contract versions detectable by
probing.

## 7. T2 descriptor ABI

64-byte, naturally aligned, little-endian. Identical across seams B and D, and identical between the
in-core `ai.enq` path and the host-side PCIe doorbell path.

| Offset | Size | Field | Notes |
|---|---|---|---|
| `0x00` | 2 | `version` | must equal `aicfg.version`; mismatch → error, not trap |
| `0x02` | 2 | `op` | `1` GEMM, `2` conv2d, `3` layout transform, `4` prefetch |
| `0x04` | 4 | `flags` | `[0]` fence-before, `[1]` fence-after, `[2]` raise IRQ, `[3]` fused requant |
| `0x08` | 4 | `m` | rows |
| `0x0C` | 4 | `n` | cols |
| `0x10` | 4 | `k` | reduction depth |
| `0x14` | 4 | `lda`, packed `ldb` high half | leading dimensions, elements |
| `0x18` | 8 | `ptr_a` | effective address, translated in the issuing context |
| `0x20` | 8 | `ptr_b` | |
| `0x28` | 8 | `ptr_c` | destination |
| `0x30` | 8 | `ptr_scale` | per-channel scale/zero-point table, or `0` |
| `0x38` | 8 | `ptr_done` | completion word address |

`flags` bit assignment:

| Bits | Field |
|---|---|
| `0` | fence-before |
| `1` | fence-after |
| `2` | raise IRQ on completion |
| `3` | fused requant |
| `9:8` | `dtype`, encoded as §3.1 |
| `11:10` | `accmode`, encoded as §3.1 |
| `13:12` | `ew`, encoded as §3.1 |
| `14` | `sp24` |
| `19:16` | priority class (§7.1); `0` is the default class |
| `31:20`, `15` | reserved, write zero |

**The descriptor is self-describing and the engine must not read `aicfg`.** Arithmetic type used to be
implicit in `aicfg`, which is wrong for an engine whose work outlives the instruction that enqueued it:
the submitting thread may rewrite the CSR mid-descriptor, a context switch may replace it, and a
host-side PCIe doorbell submission has no `aicfg` at all. Type therefore travels with the work. (This
corrects an unratified contract before any implementation exists; it is not a version bump — §9.)

**Completion word** (8 bytes at `ptr_done`): `[31:0]` ticket, `[47:32]` status (`0` ok, non-zero error
code), `[63:48]` reserved. Written **once**, with release semantics, after all data writes of the
descriptor are globally visible. Software polls it or waits on the IRQ; `ai.poll` reads the same state.

**Addresses in a descriptor are effective addresses in the submitting context.** The engine therefore
needs translation and permission checking equivalent to the submitter's — see `README.md` §9 and
todo **AI-3**. A descriptor engine that dereferences these pointers without a check is a privilege
escalation from any process holding a doorbell page.

Ring: `aiqbase` + power-of-two entries (`aiqctl[7:4]`), producer index in the doorbell page, consumer
index owned by hardware. Full is signalled by `ai.enq` returning all-ones, never by blocking.

### 7.1 Scheduling, QoS and preemption (normative)

A single descriptor at island scale can occupy the engine for **milliseconds**
(`scaling-100tops.md` §5). With several tenants holding mapped doorbell pages that is an unbounded
latency channel and a denial-of-service vector, so the scheduling contract is part of the ABI:

1. **Bounded work quantum.** The engine must reach a preemption point at least every `Q` µs, where `Q`
   is reported in the capability window. A reduction-block (`k`-step) boundary is the natural point.
2. **Restartability.** State at a preemption point is exactly (descriptor, `k`-offset, accumulator
   bank); no other hidden state may be live across it. This is also what makes a watchdog able to
   abort a descriptor without resetting the island.
3. **Arbitration.** Ready queues are served round-robin within a priority class and strictly by class
   between them, with a starvation floor so class 0 always makes progress. Priority is per descriptor
   (`flags[19:16]`), clamped by a per-queue maximum that only S-mode can raise.
4. **Isolation.** Address checking is per queue and carries the submitting context (**AI-3**);
   accumulator and staging state must be scrubbed or bank-partitioned between queues, exactly as §5
   requires between harts. A stale `s32` activation crossing a tenant boundary is a data leak.
5. **Watchdog.** Each descriptor has a deadline; expiry completes it with an error status through the
   ordinary completion word rather than trapping or wedging the ring.

## 8. Discovery

Software must never hard-code geometry. Four layers, in order of preference:

| Layer | Mechanism |
|---|---|
| Runtime | `ai.setcfg` grant value — authoritative for the **core-attached plane**, works with no OS help |
| Island | **MMIO capability window** — authoritative for the **island plane**: clusters, MACs/cycle, clock, SRAM, measured DRAM bandwidth, dtype/`ew`/sparsity mask, queues, QoS classes, work quantum `Q`. Layout in `scaling-100tops.md` §8 |
| Kernel | `/sys/devices/.../g6lcai/{tile_m,tile_n,tile_k,acc_banks,queues,tile_ld}` and a `hwprobe`-style ioctl |
| Device tree | `riscv,isa-extensions` gains `xg6lcai`; a `g6lc,ai-matrix` node carries geometry, `AiTileLdEn`, queue count, register window and IRQ |
| Build | `core/include/g6lc64_ai_config_pkg.sv` (tier R) — the source all of the above derive from |

`AiTileLdEn` is separately discoverable precisely because §3.3 differs between seams B and D.

**No CSR ever describes island geometry.** Cluster count and throughput are read from the capability
window, never from `aicfg`. That separation is what lets one binary run unmodified on a ~5-TOPS
embedded part and a ~100-TOPS card (`scaling-100tops.md` §8).

**Never advertise `xg6lcai` in a device tree whose package has `AiMatrixEn == 0`** — the same rule the
vector track enforces for `v` (`agents/guides/AGENTS-vector.md:94-95`), cross-validated per
`AGENTS-dts-validation.md`.

## 8.1 PMU event group (implementation contract)

`mhpmeventN` uses `{group[7:5], idx[4:0]}` (`core/include/ariane_pkg.sv`). Group **4**
(`MHPMGrpAI`) is allocated to Xg6lcai. Indices:

| idx | `mhpmevent` low byte | Event |
|---|---|---|
| 0 | `0x80` | any AI instruction result_valid |
| 1 | `0x81` | MMA complete |
| 2 | `0x82` | post-op complete (requant / relu / gelu) |
| 3 | `0x83` | T0 complete (setcfg/getcfg/dot4/mv*/queue mgmt) |
| 4 | `0x84` | busy cycle (multi-cycle unit occupied) |

Island MMIO counters (cluster throughput, queue occupancy) stay **out** of `perf_counters` —
see `README.md` § island telemetry. RVFI exposes `aicfg`/`aistatus` for cosim when
`AiCfg.MatrixEn=1`.

## 9. Versioning and change control

`aicfg.version` (bits 19:16) is the contract version; this document describes **version 1**.

- Adding a `funct7` within an existing group, or a field in reserved descriptor space: **minor**, no
  version bump, discoverable by the reserved-encoding trap rule.
- Changing an existing encoding, a CSR address, the rounding rule of §3.5, or a descriptor offset:
  **breaking** — bump `version`, and support the previous value or refuse to advertise it.
- The encoding must **not** change between seam B and seam D. If option D turns out to require an
  encoding change, that is a defect in this document, not a licence to fork the contract.

## 10. Seam-specific notes

**Seam B (CVXIF).** Build the mask/match table in the shape of
`core/cvxif_example/include/cvxif_instr_pkg.sv:56-137`, one entry per allocated `funct3`/`funct7`, with
`register_read` set **only** for the GPR-operand fields identified in §2/§3. `writeback` is set only
for groups that write `rd` as a GPR. §3.3 tile loads are not implementable here — report
`AiTileLdEn = 0` and let the compiler synthesise them.

**Seam D (accelerator).** The first-pass decoder replacing
`core/cva6_accel_first_pass_decoder_stub.sv` must recognise custom-2 and report `is_accel`, plus the
correct scalar read/write flags, using the same operand-class table. §3.3 becomes natively executable
via the accelerator MMU port; report `AiTileLdEn = 1`.

Both seams share §4–§7 unchanged.
