# DRAM channel scaling — SoC-wide bandwidth and stability

**Status:** plan of record (I3) · **Live:** class 0, **N = 1**, 64-bit fabric · **Not live:**
class-1 LiteDRAM, N>1, 400 GB/s  
**Parents:** [`ddr4-controller.md`](ddr4-controller.md) ·
[`../ai-matrix/scaling-100tops.md`](../ai-matrix/scaling-100tops.md) §4 ·
[`../multi-core/README.md`](../multi-core/README.md) ·
[`../l2-l3-cache/README.md`](../l2-l3-cache/README.md)  
**Scaffold only** — see `architecture/README.md`. No flist.

This note is the stability plan for the **`DramChannels`** knob. It exists so a later
implementation cannot treat multi-channel DRAM as an island-private GEMM trick, or as I2
cluster replication. The cores, the L2/L3 miss path, and the island DMA must all use the
**same** striped DRAM slave.

---

## 1. What must stay true

LibreCore is a **CPU+AI card with one address space**. DRAM bandwidth is a property of the
**SoC memory-side slave**, not of the island sequencer and not of any `core/` pipeline stage.

| Claim | Consequence |
|---|---|
| One `memory@` map | Linux, OpenSBI, GEMM descriptors, I$/D$/PTW, L2/L3, Ara, and stream copies all see the same DRAMBase. Channels are **not** a second address space. |
| `DramChannels` is a slave knob | It lives in `g6lc_ai_island_cfg_pkg` (uncore package, `scaling-100tops.md` §8). It does **not** enter `cva6_cfg_t`. Core modules stay channel-oblivious. |
| One generated `litedram_core` = one channel | Bandwidth scales by **N independent controllers**, not a wider PHY, not `NrCores`, not I2 `Clusters`. N ∈ {1,2,4,8}. |
| Stripe, not software interleave | `addr[DramChanShift +: log2(N)]`, default shift **6** = 64 B = `Zic64b` / L2 line. Software tiles GEMM at `T` (F12); it does not bind tiles to channels. |
| Class-1 nameplate is `N × 19` GB/s | DDR4-2400×64 peak (`ddr4_nameplate_gbps`). **400 GB/s is class 2 LPDDR5 only.** |
| I3 before I2 | Growing MACs on the 8 GB/s fixture is the §11 failure mode. I2 must not change the memory system. |

Live testharness already instantiates `g6lc_ai_dram_backend` on `master[ariane_soc::DRAM]`
**after** `axi_riscv_atomics_wrap` and the AXI delayer (`corev_apu/tb/ariane_testharness.sv`).
That is the cluster's DRAM port. The island is a **second xbar master** into the same slave.
`NrChannels=1` is a wire (`g6lc_ai_dram_channels` `gen_sel1`). N>1 is the same module with
`axi_demux_intf`.

Build-platform (same flags as OoO, on existing `test`/`diag`/`remote`/`g6q`):

```text
cva6-build diag run ai
cva6-build test --ai --channels 4 --ai-dram 1          # x4 DDR4 LiteDRAM stripe
cva6-build test --ai-remote                            # S4 Variane (ai-dt)
cva6-build test --ai --ai-ghz 1.25 --from-timing <pkg> # Cas=14 + FO4 (not STA)
cva6-build test --ai-qemu                              # g6lc_qemu; not Variane
```

`--channels` is `DramChannels` ∈ {1,2,4,8}. `--ai-dram 2` (400 GB/s LPDDR5) is refused — not live.
`--ai-clusters N` with N>1 exports CAP/F8 env only; I2 is not started.

---

## 2. Why cores must use the channels (not only the island)

The 100-TOPS product story is locality: irregular fallback, page tables, OS, and matrix work
share DRAM. If the island owned a private multi-channel PHY and the cores kept the class-0
SRAM/xbar path, then:

- GEMM would see N×19 GB/s while `ld`/`st`/I$ miss/PTW would not.
- Descriptor payloads, page tables, and C writeback would fight a different memory.
- LR/SC and RVWMO would have two physical images of `0x8000_0000`.
- Multi-core `NrCores` scale would add AXI masters that **miss** the bandwidth the SKU paid for.

So the stripe belongs **below** L2/L3 and **below** the exclusive-monitor wrap, where every
DRAM-bound AXI transaction already goes. `core/` does not grow a `DramChannels` port. It
**uses** the channels because its miss fills already target DRAMBase.

### 2.1 Core-pipeline consumers (channel-oblivious)

These paths issue AXI toward DRAM today. They must keep working, bit-identical at N=1, and
stripe-correct at N>1, without decoding `DramChanShift` inside the stage.

| Pipeline / unit | Locus | What hits DRAM |
|---|---|---|
| Instruction fetch / I$ | `core/frontend/`, `core/cache_subsystem` | Line fill on miss. Sequential PC naturally round-robins 64 B stripes. |
| Load/store / D$ / WT buffer | `core/load_store_unit.sv`, `store_buffer.sv`, `*axi_adapter.sv` | Demand miss, write-through, writeback. Live L1 line is **16 B** (`DcacheLineWidth=128`); a 64 B stripe holds four L1 lines. |
| Page-table walk | `core/cva6_mmu/` | Sequential PTE fills. Same stripe as demand data. |
| AMO / LR/SC | `axi_riscv_atomics_wrap` **above** the demux | Reservation is on the **unified** address. Never a per-channel monitor. |
| SMT2 second hart | `NrHarts=2` on one `ariane` | Both harts share the core's AXI master; they do not double the DRAM port. |
| Stream / Zicboz / memcpy | `cbo.zero`, HWPF, stream8 | Full-line ops at 64 B (`riscv,cboz-block-size = <64>`). Must not span a stripe. |
| Ara / RVV | `corev_apu/src/g6lc_ara_attach.sv` | Vector unit is another AXI master on the same map when attached. |
| T0/T1 AI tile | `core/cvxif_fu.sv`, `acc_dispatcher.sv` | Small and latency-bound; must not grow with TOPS (`scaling-100tops.md` §3). Still uses DRAMBase for anything that misses L1. |

Do **not** add channel-select muxes inside `ex_stage`, the LSU, or the frontend. That would
couple a SoC PHY count into every core package and break N=1 identity.

### 2.2 Multi-core and the cache hierarchy

```
N × ariane  ──► coherence hub ──► L2 ──► L3 (opt) ──► server PF (opt)
                                                      │
island GEMM DMA ──────────────────────────────────────┤
                                                      ▼
                              atomics wrap ──► stripe demux ──► N × litedram_core
```

| Level | Live geometry | Channel interaction |
|---|---|---|
| L1 | 16 B lines | Four L1 lines per 64 B stripe. No change. |
| L2 | **64 B** lines, 4 data banks, 8 MSHR (`g6lc_l2_pkg`) | Line size **equals** default stripe. Bank = `line_index % 4` ≈ `addr[7:6]`. |
| L3 | 64 B, 16 MSHR, 8 banks | Same line size. |
| Cluster | `g6lc_cluster` `mem_req_o` | N=1 `IDENTITY_FAST` skips the hub; the DRAM slave is unchanged. Raising `NrCores` adds miss-fill **concurrency**, not channels. |
| Prefetch | `g6lc_server_prefetcher` next-line | Walks consecutive 64 B lines → round-robins channels. Demand always wins AR. |

**Bank/channel alignment (keep):** with 64 B lines, L2's four banks sit on `addr[7:6]`.

- N=2 (`addr[6]`): consecutive lines alternate channel **and** bank.
- N=4 (`addr[7:6]`): **each L2 bank maps to one DRAM channel** — miss-parallelism is
  channel-parallelism.
- N=8 (`addr[8:6]`): two channels per L2 bank; still legal.

If a later SKU moves `DramChanShift` or L2 line size, re-check this table before elaborating.
A cache line or AXI burst **must not straddle** a stripe: `axi_demux_intf` routes the whole
transaction by AR/AW address of the **first** beat.

**`NrCores` vs `DramChannels`:** orthogonal knobs. Stream8-class starts at 2 cores / 1 channel.
Do not infer channel count from core count.

---

## 3. Bandwidth math (100 TOPS vs the DDR4 ladder)

From `scaling-100tops.md` §4, streaming-reduction demand is `(2/T) × MAC-rate`. F13 adds C
writeback (`4mn`) on the live resident GEMM.

DDR4-2400×64 nameplate:

| `DramChannels` | Nameplate | Role |
|---|---|---|
| 1 | **19 GB/s** | `AiIslandDdr4Bringup` (opt-in `G6LC_AI_DRAM_CLASS1`) |
| 2 | **38 GB/s** | `AiIslandDdr4x2Bringup` (`G6LC_AI_DRAM_CHANS_2`) |
| 4 | **76 GB/s** | legal; no named SKU yet |
| 8 | **152 GB/s** | max of this PHY class |

That ladder **closes the latency SKU's GEMM demand** at `T = 512` (24–48 GB/s for 12–25 TOPS)
once the **fabric** is wide enough to observe it. It does **not** close 100 TOPS:

| Target | GEMM demand (streaming, `T=512`) | Max DDR4 (8ch) | Fits? |
|---|---|---|---|
| Live fixture 0.512 TOPS | ≪ 8 GB/s | n/a (class 0 NoC) | I3-lite fabric-bound |
| Latency SKU 12–25 TOPS | 24–48 GB/s | 38–152 GB/s | 2–4ch once fabric ≥ nameplate |
| Throughput SKU **98 TOPS** | **195 GB/s** | **152 GB/s** | **No** — class 2 LPDDR5 (~400 GB/s) or a faster/wider DRAM |

8 × 19 GB/s = 152 GB/s is short of the 195 GB/s row and far short of the 391 GB/s `T=256`
row. **Do not advertise 400 GB/s on a DDR4 channel count.** Class 2 is a different PHY.

### 3.1 Fabric ceiling (the measurement trap)

Live SoC AXI and island NoC are **64-bit @ 1 GHz = 8 GB/s**. Observed bandwidth cannot exceed:

```
BW_ceiling = min( N × 19 GB/s ,  (AxiDataWidth/8) × f_GHz  ,  noc_peak_gbps )
```

On the live fixture that is `min(19, 8, 8) = 8` even after class-1 elaborates. Raising
`DramChannels` **without** widening `AxiDataWidth` / `NocWidth` / clock does not move the
PMU. The I3 ≥80% gate in §12 is therefore:

> **`BW_measured` ≥ 80% of `min(nameplate, fabric peak)`** — never 80% of a nameplate the
> interconnect cannot carry, and never 80% of 400 on class 1.

`AiIslandLatencySkuTarget` already publishes `NocWidth=512` (64 GB/s @ 1 GHz) with class 2
and 2 channels. That width is an **island** number; the core cluster port may stay narrower
(see §4).

---

## 4. Two-port DRAM front-end (plan, not live)

Today one xbar master port (`DRAM`) feeds the stripe. That is correct for I3-lite and for
DDR4 bringup at 19–38 GB/s. It is **not** how 400 GB/s and Linux coexist:

- A 400 GB/s island path through a 64-bit (or even 512-bit) **shared** xbar either starves
  fetch/LSU or is physically too wide for the core cluster.
- Splitting into island-private DRAM **breaks** §1.

**Planned shape** when class 2 or a wide class-1 SKU needs it:

```
cluster mem_req (narrow, L2/L3/PF) ──► ┐
                                       ├─► stripe demux ──► N × PHY
island DMA      (wide, GEMM)       ──► ┘
```

Rules for that step:

1. Both ports see the **same** stripe function and the same N controllers.
2. Atomics / exclusive monitor stay on the **core/cluster** port only. Island DMA is
   memcpy-class and must not issue `AxLOCK`.
3. QoS: demand I$/D$/L2 miss wins over island GEMM and over the server prefetcher
   (prefetch already yields). Bound island `MaxAROut` so a GEMM cannot stall OpenSBI fetch.
4. `init_done` is still the AND of all channel PHYs; **no** master issues until it is 1
   (`CAP_OFF_DRAM_STATUS[0]`).
5. Do not rename this to I2. I2 replicates **compute clusters** behind the NoC cut line
   (`scaling-100tops.md` §7). The memory system is frozen.

Until that dual-port exists, cores already use the channels through the shared xbar slave.
That is the I3 bringup path.

---

## 5. Stability invariants (implementation checklist)

Hold these when turning `G6LC_AI_DRAM_CHANS_2` (or N=4/8) from a define into a SKU.

### 5.1 Identity and image

1. **N=1 is a wire.** `gen_sel1` must remain combinational. Cookie `51b1babe`, HARD
   `gemm_s8` / 256³ ~83.7k cy, and OpenSBI at `0x8000_0080` stay bit-identical to class 0
   when class is still 0, and to single-channel class 1 when class is 1.
2. **N>1 is the same bytes at the same addresses.** Stripe is an interleave of one map, not
   N windows. A directed test writes 64 B at `DRAMBase + i×64` and reads it back on N=1 and
   N=2; the image matches.
3. **LiteDRAM AXI is 31-bit** in the generated `--sim` core (`awaddr[30:0]`). The wrap must
   keep `DRAMBase` aliasing explicit so `0x8000_0000` and the island's descriptor pointers
   land in the same physical image.

### 5.2 AXI, ordering, RVWMO

4. **Whole-transaction route.** Bursts and cache-line fills are ≤ `2^DramChanShift` bytes.
   L2/L3/CMO 64 B + default shift 6 is the frozen pair. If `DcacheLineWidth` or L2 line
   grows past the stripe, **raise `ChanShift`**, do not split a line across PHYs.
5. **Same-address order** is per-channel (one address → one slave). Different addresses may
   complete out of order across channels; that is AXI-legal and RVWMO-legal. `FENCE` /
   `FENCE.I` / `Zifencei` do not change.
6. **IDs.** `axi_demux_intf` `MAX_TRANS=8`; xbar `MaxMstTrans/MaxSlvTrans=8`; L2 MSHR 8;
   L3 MSHR 16; island `MaxAROut` live 2 / DRAM 8; LiteDRAM `cmd_buffer_depth=16`. Over-
   subscription must **backpressure**, never drop. Multi-core × MSHR × island AR is the
   budget to re-prove when `NrCores` or N grows.
7. **`testmode_i`** stays on the demux (scan/ATPG). No new clock, no second async reset into
   `core/` (`AGENTS.md` §0.1). PHY CDC lives inside each wrap.
7a. **One reservation per hart, not one per SoC.** `g6lc_axi_lrsc` replaces pulp
   `axi_riscv_lrsc` on every build that selects `G6LC_AI_EXCL_MULTI` — which is *any*
   `G6LC_AI_DRAM_*` / `SIM_CHANS_*` / `TIMING` define, i.e. every multi-channel and class-1
   configuration. Its first version held **one global reservation**, which livelocks two harts
   contending on **different** addresses:

   ```text
   hart 0: lr.d A   -> res = A
   hart 1: lr.d B   -> res = B      (A destroyed; nothing wrote A)
   hart 0: sc.d A   -> fails; retry destroys B in turn
   ```

   Neither hart is guaranteed progress and no guest-side backoff helps, so it blocks
   OpenSBI/Linux spinlocks and `__atomic` CAS on exactly the configurations this document
   introduces. **The existing `ai-dual-core-excl` gate cannot see it**: that test has one line in
   play, so a single reservation passes it. The disjoint case needed its own gate —
   `ai-dual-core-lrsc-disjoint` (`verif/tests/custom/ai/ai_dual_core_lrsc_disjoint_smoke.S`).

   The monitor now keys an `NRes`-entry table on address, sized from `NR_HARTS` by
   `ariane_testharness.sv`. Address keying is required rather than preferred: HPDCACHE LDEX uses
   the read ID space and STEX uses uncached-write `id='1`, so **the same hart's LR and SC do not
   share an AXI ID** and there is no hart id at this seam to key on. Address keying gives the
   needed semantics directly — disjoint addresses are independent, same-address gets exactly one
   winner because a successful SC consumes its entry. Table-full evicts the rotating victim, which
   is a permitted spurious SC failure and cannot starve a requester.

   `NRes = 1` reproduces the old behaviour for bisection, and
   `+define+G6LC_AI_LRSC_SINGLE_RES` on the testharness forces it. **Keep that seam**: it is what
   makes the gate an oracle rather than a test that has never failed, and rediscovering the negative
   costs a 22-minute harness rebuild.

   Proxy evidence (Variane, flavour `ai-dt`):

   | Netlist | `ai_dual_core_lrsc_disjoint_smoke` |
   |---|---|
   | `NRes = NR_HARTS = 2` (fixed) | **SUCCESS `tohost=1`, 16602 cy** |
   | `NRes = 1` (pre-fix, `work-ver-ai-1res`) | **FAILED `tohost=9`, 16580 cy** |

   `tohost=9` is `fail_lrsc` — hart 0's `sc.d` refused although nothing wrote its address. The
   same-address snoop gate `ai-dual-core-excl` still passes at **16667 cy**, bit-identical to its
   recorded baseline, so the fix is additive rather than a behaviour swap.

   Note `corev_apu/coherence/g6lc_lr_sc_tracker.sv` is a **different** monitor on the coherence-hub
   path; the two must not disagree about who owns the reservation on a given build.

### 5.3 Timing, init, observability

8. **Do not put DRAM command delay on the core testharness SRAM.** `g6lc_ai_dram_timing` is
   island-DMA only. Class 0 + Cas=0 is the identity fixture. Opt-in `G6LC_AI_DRAM_TIMING`
   must not become the default — it would move OpenSBI off the cookie path.
9. **`init_done_o = AND(ch[*])`.** CAP `0x48` bit 0. Firmware/Linux `memory@` is usable only
   after this bit. Partial-channel bring-up is not a SKU.
10. **PMU.** Island PMU (`0x180–0x18C`, CAP `0x18`/`0x2C`) is **aggregate**. Add per-channel
    beat counters before claiming N>1 is balanced. Core `perf_counters` keep miss/fill
    events; a later DRAM-occupancy PMU is SoC-side, not a new `ex_stage` probe.
11. **DTS.** One `memory@` node. Channel count and shift are on `g6lc,ai-matrix`
    (`g6lc,dram-channels`, `g6lc,dram-chan-shift`) plus CAP `0x38`. Cross-check
    `AGENTS-dts-validation.md`. Do not invent per-channel `memory@` nodes.

### 5.4 What this knob is not

12. **Not I2.** `Clusters` / `ClustersEnabled` / CAP `0x30` are compute replication.
13. **Not a core config field.** ~24 packages must not grow `DramChannels`.
14. **Not 400 GB/s.** `island_cfg_legal()` already refuses class-1 nameplates other than
    `N×19` and refuses class 2 that reuses the NoC 8 GB/s number. Directed
    `tb_g6lc_ai_dram_stripe` **PASS**: class 0/DDR4 refuse 400, DDR4 refuses NoC 8,
    LPDDR5 refuses NoC 8, N=3 and ChanShift=2 illegal.
15. **Not a reason to pin `contracts.ai_host_transport`.**

---

## 6. Implementation sequence (docs → RTL later)

Do not start this list in the same pass as I2 or a transport pin.

| Step | Work | Gate |
|---|---|---|
| S0 | This document + §4.2 in `scaling-100tops.md` | docs only — **done** |
| S1 | Keep N=1 class 0 default; class-0 N>1 SRAM stripe + GEMM burst cap | cookie / HARD identity at N=1 (`MaxBurstBeats=255`). N>1: `G6LC_AI_DRAM_SIM_CHANS_2`, GEMM INCR ≤ stripe, L2/I$/D$ line ≤ stripe (testharness `$error`). Variane **`ai-sc{2,4,8}` PASS 582 cy** dual-core stripe+occupancy (class-0 SRAM `gen_sim_stripe` preload; `MaxAROut=2`, not S4). Exclusive **`ai-sc2`/`ai-sc4` PASS 620 cy** / snoop **16686 cy** after SIM_CHANS joined `G6LC_AI_EXCL_MULTI` (`g6lc_axi_atomics_wrap`, wrap AW=8 via `DRAM_EXCL_AW`; pulp 1-OT was tohost=9 then hang at AW=1). Cookie `dram_aw_out` stays 1. `ai-sc8` still older Mdir. All-N occupancy **`ai-sc8` PASS 889 cy** (CAP `0x70+4*i` i<8). `tb_g6lc_ai_dram_stripe`. Island DMA **PASS** `tb_g6lc_ai_gemm_stripe` n1+n2 (N=1 identity **53 cy** id=2 only; N=2 **53 cy** split ids) and `tb_g6lc_ai_gemm_backend` n1+n2+n4+n8 (N=1 **175 cy** ch0-only; N=2 **356 cy** / N=4 **405 cy** / N=8 **503 cy** wide `lda=64` all-NCH occupancy). **golden C=16** |
| S2 | Class-1 N=1 opt-in (`G6LC_AI_DRAM_CLASS1`) | Native wrap **PASS** id6 **1445 cy** (two 64 B AR + mixed AW+AR + eight AR live / 9th **backpressure** + eight AW live / 9th **backpressure** + L1 16 B INCR + ST.W +4 + NC AR + AR-while-B + WRAP SLVERR). Wrap **NrArSlots/NrAwSlots** follow island `MaxAROut` (CLASS1 = 8). AXI `aw/ar/w_ready` gated on `init_done` (`ForceInitDone=1` in `--sim`). Extra AR/AW wait on ready. Directed 256-beat `--sim` stream **2048 beats / 2085 cy = 7858 milli-GB/s (98% of 8 GB/s fabric)** — 80% gate **closed**. GEMM vs class-1 N=1 **336 cy** golden C=16, occupancy **ch0-only** (identity, MaxAROut=8). Testharness CLASS1 slave (`dram_backend`) N=1/2 **336/681 cy**. LiteDRAM rdata is a delayed pulse (no backpressure); wrap always accepts and issues only while FIFO+inflight fit. Timing: SLVERR is a resp mux, not a native-path cone. Atomics wrap sits **above** (`mst_*_lock=0`); LOCK/ATOP never reach the PHY. Testharness live cookie keeps pulp `axi_riscv_atomics_wrap` (1 AR + 1 AW). S4/CLASS1 instantiates `g6lc_axi_atomics_wrap` (vendor AMO + `g6lc_axi_lrsc`): regular AR/AW up to `MaxAROut`, LR/SC still snoops stores. Directed `tb_g6lc_ai_atomics_aw` (pulp 1-write) + `tb_g6lc_axi_lrsc` (8 AR + 8 AW). Not 19 GB/s nameplate; not 400. YAML `native_0` live. |
| S3 | N=2 stripe (`G6LC_AI_DRAM_CHANS_2`) | Class-0 SRAM **PASS**. Class-1 dual LiteDRAM **PASS** id6. GEMM vs class-0 slave wide **356 cy**. GEMM vs **class-1 N=1/N=2 LiteDRAM** `tb_g6lc_ai_gemm_channels` **336/681 cy** (MaxAROut=8) and N=1/2/4/8 **336/681/821/1162 cy**. Testharness `dram_backend` N=1/2 **336/681 cy** (same slave cores+island share). Variane **`ai-d2` PASS 5758 cy** (S4 smoke; eight 64 B loads alternate channels). Variane **dual-core stripe PASS 830/900 cy** on `ai-d2`/`ai-d8` (CAP 0x38 N>=2 shift=6; S5 `0x70`/`0x74` both nonzero). S4 parks hart 1: `ai-dt` **2620**, `ai-d1` **4246**, `ai-d2` **4520**, `ai-d4` **4553**, `ai-d8` **4582**. All-N occupancy **`ai-d8` PASS 1328 cy**. Exclusive **PASS `ai-dt` 552** / CLASS1 **`ai-d1` 781** / **`ai-d2` 945** / **`ai-d4` 941** / **`ai-d8` 941 cy** (`amoadd.d` + `lr.d`/`sc.d`; N>=2 second stripe). CLASS1 exclusive {1,2,4,8} closed. Dual-core snoop **PASS `ai-dt` 16667 cy** / CLASS1 **`ai-d1` 17137** / **`ai-d2` 17137** / **`ai-d4` 17163** / **`ai-d8` 17187 cy**. CLASS1 snoop {1,2,4,8} closed. Isolated lrsc **130 cy**; wrap-stack **104 cy**. Dual-core OpenSBI soak still open (cookie path, not CLASS1) |
| S4 | Outstanding-budget proof | **S4-lite + S4-line + S4-mshr directed PASS.** Wrap eight AR + eight AW live / 9th backpressure **1445 cy**. Full testharness wiring: proxy flavours `ai`/`ai-dt`/`ai-d{1,2,4,8}`/`ai-sc{2,4,8}`, `ai-matrix-build-harness.sh`, `s4-mshr-xbar.sh` + `ai_s4_mshr_xbar_smoke.S`. **CLI:** `cva6-build test --ai-remote` (ai-dt); `test --ai --channels 4 --ai-dram 1` (x4 LiteDRAM + wrap TB); `diag run ai`; `--from-timing` on test/diag. Remote v5.008 elaborate needed: drop island port defaults, hoist L1 line-size localparams, `G6LC_TB_NO_HIER` on `ariane_tb.cpp`. First `build ai-dt` C++ **OOM at -j12**; `--jobs 4` and **`-j2` still Killed cc1plus** on `DepSet_*__10.cpp` (Makefile `-O3`/`-Os` overrode `-CFLAGS -O1`). Harness **C++ jobs=1** (OOM at `-j2` on 30 Gi), **g++ wrapper `-O0`**. Live **`ai-dt` vthreads=12** rebuild **1395 s**, **40.7 Mi**, no OOM. Exclusive **PASS 552 cy**. Dual-core snoop wall **4890 s** vs **4875 s** on 1-thread (delay-loop ELF). Live **`ai-d1` vthreads=12** rebuild **1334 s**, **41.7 Mi**; exclusive still **PASS 781 cy**. Live **`ai-d2` vthreads=12** **42.9 Mi**; exclusive **PASS 945 cy**. Live **`ai-d4` vthreads=12** **47.4 Mi**; exclusive **PASS 941 cy**. Live **`ai-d8` 49.1 Mi** vthreads=12. `ai-sc*` still older Mdirs. Proxy `pkill` matches `/Variane_testharness` + space/EOL only. `test --ai-remote` **PASS:** `tohost=1` after **2620 cycles** parked hart 1 (`g6lc_axi_atomics_wrap`; was 2899 two-hart race, 2681 on pulp 1-OT). Parked CLASS1: **`ai-d1` 4246**, **`ai-d2` 4520**, **`ai-d4` 4553**, **`ai-d8` 4582**. Post-loop `getenv("CVA6_TRAP_DUMP")` SIGSEGV was TB, not RTL. CLASS1 wrap **NrArSlots/NrAwSlots=8** (directed **1445 cy**). S4/CLASS1 `g6lc_axi_atomics_wrap` (AMO + 1-cycle cut + `g6lc_axi_lrsc`) eight regular AR/AW **50 cy**; isolated lrsc **101 cy** + LR/SC snoop. Cookie keeps pulp 1-OT. CLASS1 ELF preload is LiteDRAM **native** (`G6LC_LITEDRAM_PRELOAD` + wrap `pl_*`); `gen_sim_axi.i_sram` is not elaborated. Cluster held until the queue drains. Variane **`ai-d1` PASS:** `tohost=1` after **5363 cycles** (preload 20 native words, drain t=177). Variane **`ai-d2` PASS:** `tohost=1` after **5758 cycles** (N=2 stripe, drain t=150). Variane **`ai-d4` PASS:** `tohost=1` after **5762 cycles**. Variane **`ai-d8` PASS:** `tohost=1` after **5821 cycles** (eight 64 B loads, one per channel). CLASS1 {1,2,4,8} closed. Exclusive Variane **PASS `ai-dt` 552** / CLASS1 **`ai-d1` 781** / **`ai-d2` 945** / **`ai-d4` 941** / **`ai-d8` 941 cy**. Dual-core snoop **PASS `ai-dt` 16667** / **`ai-d1` 17137** / **`ai-d2` 17137** / **`ai-d4` 17163** / **`ai-d8` 17187 cy**. CLASS1 exclusive+snoop {1,2,4,8} closed. Not 19 GB/s nameplate. |
| S5 | Per-channel PMU + DTS | **SoC-side counters live** on the DRAM slave; testharness wires them into CAP `0x50`/`0x70`. Decode **PASS** 47 cy. After GEMM, CAP matches slave counters. Variane dual-core stripe **PASS 830 cy**: CAP `0x70`/`0x74` both nonzero (core WT stores on ch0 and ch1). All-N occupancy **PASS 1328/889 cy** on `ai-d8`/`ai-sc8` (`ai_nch_occupancy_smoke.S`: CAP `0x38` N, `sd` cookie+i at LINE+i*64, `0x70+4*i` all nonzero). Wide `lda=64` (one A row per 64 B stripe, same as an L2 line) makes **all NCH** read occupancy live: class-0 N=2/4/8 **356/405/503 cy**; class-1 N=2/4/8 **681/821/1162 cy**. Island CAP `0x180`/`0x18`/`0x2C` stay **aggregate GEMM**. Occupancy is not a DT property. DTS↔CAP: live `g6lc,dram-channels=<1>` / `chan-shift=<6>` match CAP `0x38` (**PASS** 59 cy); CLASS1 N=2 packs `2/6`; `--sim` `ForceInitDone` pins wrap `init_done` so CAP `0x48` bit0 is 1. |
| S6 | Dual-port front-end (§4) **only if** fabric ceiling blocks the SKU | cores still on the same map; island `AxLOCK=0` |
| S7 | N=4/8 or class 2 | **Class-0 {2,4,8} SRAM PASS. Class-1 N=1/2/4/8 LiteDRAM PASS** (PHY **375/416/448/453 cy**; N=1 ch0-only; N=1/2/4 two IDs/PHY; N=8 one ID). GEMM vs class-1 N=1/2/4/8 **336/681/821/1162 cy** golden C=16 CAP (MaxAROut=8; N=1 ch0-only; N>1 wide all-NCH). `AiIslandDdr4x{2,4,8}Bringup` 38/76/152 GB/s; testharness `CHANS_{2,4,8}`. Variane **`ai-d4` PASS 5762 cy** first-pass / **4553 cy** parked; **`ai-d8` PASS 5821 cy** first-pass / **4582 cy** parked. All-N occupancy **1328 cy** on `ai-d8`. CLASS1 {1,2,4,8} closed. Exclusive+snoop {1,2,4,8} closed. Class 2 / 400 still open; I2 still forbidden until BW is measured |

`core/` RTL changes in this sequence are **none**, except possibly a later SoC-side PMU
event and the existing L2/L3/prefetch outstanding depths if full S4 (Variane) proves they
deadlock. The pipelines already issue to DRAMBase. S1 landed the **slave-side** pieces
cores need: class-0 N>1 striped SRAM on `master[DRAM]`, GEMM bursts that no longer
straddle a stripe (so L2 fills and GEMM agree on the image), and a testharness
line-vs-stripe `$error` so an oversized I$/D$/L2 line cannot elaborate with N>1.
S4-lite is the same slave seeing two in-flight IDs (the L2-MSHR case) without a
`core/` edit. S1's GEMM cap is now exercised against that slave
(`tb_g6lc_ai_gemm_stripe`): island DMA and L2 fills agree on the striped image.

---

## 7. Open first

| Layer | Path |
|---|---|
| 100 TOPS sizing | [`../ai-matrix/scaling-100tops.md`](../ai-matrix/scaling-100tops.md) §4 / §11 |
| Controller outline | [`ddr4-controller.md`](ddr4-controller.md) |
| Generate contract | [`litedram-testharness.yml`](litedram-testharness.yml) |
| Multi-core hub | [`../multi-core/README.md`](../multi-core/README.md) |
| L2/L3 / PF | [`../l2-l3-cache/README.md`](../l2-l3-cache/README.md) |
| Snapshot | [`../current-stage.md`](../current-stage.md) |
| Island knobs | `corev_apu/include/g6lc_ai_island_cfg_pkg.sv` |
| Stripe RTL | `corev_apu/src/g6lc_ai_dram_channels.sv` |
| DRAM slave | `corev_apu/src/g6lc_ai_dram_backend.sv` · testharness `master[DRAM]` |
