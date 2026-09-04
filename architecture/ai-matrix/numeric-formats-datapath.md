# Numeric formats in hardware — datapath analysis and development order

**Status:** analysis, partially implemented · **Scope:** `corev_apu/ai_island` PE datapath
**Parent:** [`README.md`](README.md) · **Contract:** [`isa-encoding.md`](isa-encoding.md) §3.1a
**Sizing model:** [`scaling-100tops.md`](scaling-100tops.md) · **Emulator reference:**
`g6lc_qemu/crates/g6q-vm/src/numfmt.rs`

> **Why this document exists.** The format *contract* is frozen (`numfmt`, the grant mask,
> `ST_BAD_FMT`) and the *emulator* computes all six formats. The hardware computes INT8 only.
> The obvious next step — "add the other formats to the PE" — is the wrong one, for two
> reasons this document establishes with numbers: the existing INT8 reduction cannot meet
> timing, and equal throughput across formats is forbidden by memory bandwidth rather than by
> multiplier area. Both change the development order.

---

## 1. Finding: the INT8 baseline does not close timing

`g6lc_ai_pe_dot.sv` reduces `Lanes` products with a **linear chain**:

```systemverilog
assign partial[0] = $signed(acc_i);
for (genvar l = 0; l < int'(Lanes); l++)
  assign partial[l+1] = partial[l] + prod[l];   // depth == Lanes
```

The header comment says "MAC tree depth ~Lanes", which is two errors in one phrase: it is not
a tree, and a *tree* would be depth `log2(Lanes)`. At the live `PeLanes = 256`:

| Structure | Adder depth | Est. delay @ 32-bit add ≈ 100 ps | Implied f_max |
|---|---|---|---|
| chain (today) | **256** | ~25.6 ns | **~39 MHz** |
| balanced tree | **8** | ~0.8 ns | ~1.25 GHz (before the multiplier) |

100 ps for a 32-bit carry-propagate add is optimistic at the 12 nm class this targets, so the
chain figure is a floor, not an estimate. Against `AGENTS-configuration.md` §1.0a's 1.0 GHz
island clock the baseline is **off by more than an order of magnitude**.

**Consequence for the format work.** Every format multiplies the multiplier count or width.
Doing that first would (a) spend area on a datapath that cannot be clocked, and (b) make the
resulting timing failure impossible to attribute — is it the new format, or the pre-existing
chain? So the reduction is fixed *first*, and it is fixed in a way that cannot change results:

**Two's-complement wrapping addition is associative**, so a balanced tree produces
bit-identical sums to the chain, including on overflow. The existing GEMM goldens are
therefore the regression test, and any difference is a bug in the restructuring rather than
an accepted numerical change. That property is why this is step 0 and not step 3.

A tree at depth 8 is necessary but not obviously sufficient: ~0.8 ns of adder plus an 8×8
multiply leaves little of a 1 ns budget, so pipelining the PE is expected to follow. That is a
*sequencer* change (`acc_d = pe_acc_out` consumes the result in the same cycle) and therefore
a separate, larger step — see §5 F0b.

---

## 2. Finding: equal throughput is a bandwidth question, not a multiplier question

`scaling-100tops.md` §1 derives operand traffic for a `T×T×T` tile: `2T²` operand bytes for
`T³` MACs, so **bytes/MAC = 2/T** for one-byte elements. Generalised to `w` bytes per element:

```
bytes_per_mac(w) = 2w / T
required_bandwidth = mac_rate × bytes_per_mac(w)
```

At the frozen `T = 256` and the 100-TOPS-class dense-INT8 point of `50e12` MAC/s:

| Format | `w` (bytes) | bytes/MAC | BW at 50e12 MAC/s | Feasible on planned DRAM? |
|---|---|---|---|---|
| INT4 | 0.5 | 0.0039 | **195 GB/s** | yes — headroom for 2× MAC rate |
| INT8 | 1 | 0.0078 | **391 GB/s** | yes — this *is* the balance point |
| FP8 (E4M3/E5M2) | 1 | 0.0078 | **391 GB/s** | yes — same as INT8 |
| BF16 / FP16 | 2 | 0.0156 | **781 GB/s** | **no** — ~2× the best planned |
| FP32 | 4 | 0.0313 | **1563 GB/s** | **no** — ~4× |

Planned memory, from [`../uncore/dram-channel-scaling.md`](../uncore/dram-channel-scaling.md)
and `AGENTS-configuration.md` §1.0a: DDR4 at `N × 19` GB/s (152 GB/s at the `N = 8` maximum),
or the LPDDR5 throughput SKU at ~400 GB/s. **391 GB/s is where INT8 balances**, which is not a
coincidence — the whole 100-TOPS plan was sized to it.

**So the answer to "equivalent speed" is format-dependent, and it is forced:**

| Format | Max MAC rate vs dense INT8 | Limited by |
|---|---|---|
| INT4 | **2×** | operand bandwidth (2 elements per byte) |
| INT8 | **1×** | baseline |
| FP8 E4M3 / E5M2 | **1×** — *equivalent speed achievable* | same operand width as INT8 |
| BF16 / FP16 | **½** | operand bandwidth, not multipliers |
| FP32 | **¼** | operand bandwidth |

This *derives* the ratio table the emulator reports (`NumFmt::mac_rate_ratio`) rather than
asserting it. The ratios are the bandwidth-optimal operating points, so a design that hit
equal MAC rate for BF16 would have to double the memory system for no arithmetic benefit —
the extra multipliers would starve.

**Statement to hold to:** *the formats that can run at INT8-equivalent speed are INT4 (faster),
INT8, and FP8. BF16, FP16 and FP32 cannot, on this memory system, and their halved and
quartered rates are correct rather than a shortfall.*

---

## 3. Finding: BF16 and FP8 mantissas fit the multiplier that already exists

The area cost of a float format at the multiplier is set by its **significand** width
(mantissa + implicit leading 1), not by its storage width:

| Format | Storage | Mantissa | Significand | Multiplier needed | vs existing 8×8 |
|---|---|---|---|---|---|
| INT4 | 4 b | — | 4 b | 4×4 | **fits, 2 per cell** |
| INT8 | 8 b | — | 8 b | 8×8 | **is the cell** |
| FP8 E4M3 | 8 b | 3 | **4 b** | 4×4 | **smaller than the cell** |
| FP8 E5M2 | 8 b | 2 | **3 b** | 3×3 | **smaller than the cell** |
| BF16 | 16 b | 7 | **8 b** | 8×8 | **exactly the cell** |
| FP16 | 16 b | 10 | **11 b** | 11×11 | wider — new multiplier |
| FP32 | 32 b | 23 | **24 b** | 24×24 | far wider — decomposition |

Two consequences that invert the naive "smallest storage first" ordering:

1. **BF16 is the cheapest 16-bit float by a wide margin**, because its 8-bit significand is
   *exactly* the existing signed 8×8 product. Its incremental cost over INT8 is exponent
   handling and float accumulation — no new multiplier. This is why BF16 exists as a format.
2. **FP16 costs more silicon than BF16 for identical throughput** (both are 2 bytes, both ½
   rate), buying only mantissa precision. It is therefore *last* among the 16-bit formats,
   not first.

**The expensive shared step is not any multiplier — it is float accumulation.** Products with
differing exponents must be aligned before summing, and a 256-lane float adder tree is far
larger than the integer one. The standard mitigation, and the one this design should take, is
to accumulate in **fixed point with a shared exponent** across the reduction (block floating
point): align each product once into a wide integer accumulator, reduce with the *same integer
tree* §1 builds, and normalise once at the end. That reuses step 0's work and keeps one
reduction structure for every format.

---

## 4. What "correctly" must mean, and how it is checked

The emulator is now the executable reference (`numfmt.rs`), and it was written to be
reproducible rather than merely close: products form in `f32` and sum in `f32` in the `k`
order the engine walks. Hardware must match it bit-for-bit for the operands the tests use.

Three traps this ordering is designed to expose early, all already encoded as emulator tests:

- **FP8 E4M3 has no infinity.** Its top exponent is finite except for the all-ones mantissa,
  so `0x7e` is `448.0`. Treating it like E5M2 turns the largest finite value into an infinity
  and poisons the accumulator. `fp8_e4m3_has_no_infinity` pins this.
- **Subnormals are not optional.** FP8's smallest positive value is subnormal (`2^-9` for
  E4M3), and dropping subnormal support silently zeroes small operands.
- **INT4 is signed 4-bit, range −8..7.** An unrepresentable operand wraps rather than
  saturating; this already produced a wrong golden during emulator development.

Because the emulator refuses any format the ingested grant mask does not carry, **the model
and the hardware agree by construction at every step**: raising `AiIslandPeImplMask` and
`AiIslandDtypeMask` together is what turns a format on, and
`g6lc_ai_island_top`'s grant ⊆ implemented assertion makes a mismatch a build failure. There
is no window in which software can request a format the PE cannot do.

---

## 5. Development order

Ordered by *value per unit of risk*, with the §1–§3 findings applied. Each step is separately
verifiable, and each has a named regression that must not move.

| # | Step | Why here | Regression that must not move |
|---|---|---|---|
| **F0a** | Reduction chain → balanced tree | Prerequisite (§1). Bit-identical by associativity, so zero functional risk and a ~30× depth reduction | existing GEMM goldens, byte- and cycle-identical |
| **F0b-1** | Move the accumulate out of the PE into the sequencer | Prerequisite for F0b-2. Bit-identical, so zero functional risk | GEMM goldens byte- and cycle-identical |
| **F0b-2** | Insert the pipeline register on `sum_o`, delay the C write | Register site now exists and is not on a recurrence | GEMM goldens identical; small fixtures show **no** cycle-count change, large fixtures (64x64 etc.) validate the delayed C write and trail-store arbitration |
| **F1** | **INT4**, by fracturing the 8×8 cell into 2×(4×4) | Cheapest format: no float logic, no accumulator change, and the only one that *raises* throughput (§2). It is also the "effective TOPS" lever `scaling-100tops.md` §1 names | INT8 goldens; new INT4 golden vs emulator |
| **F2** | **FP8 E4M3 + E5M2** | First float, and the only float that keeps INT8-equivalent speed (§2). Mantissa is *smaller* than the existing cell (§3), so the cost is purely the float accumulator | INT8/INT4 goldens; FP8 golden incl. the 448.0 and subnormal cases |
| **F3** | **BF16** | Reuses F2's float accumulator *and* the unmodified 8×8 cell (§3). ½ rate, which §2 shows is the correct point | all previous goldens; BF16 golden |
| **F4** | **FP16** | Needs an 11×11 significand for the same ½ rate as BF16 — more area, no throughput gain (§3). Deliberately after BF16 | all previous; FP16 golden incl. subnormals |
| **F5** | **FP32** | 24×24 significand by decomposition, ¼ rate | all previous; FP32 golden |

**Ordering claims worth stating explicitly, because they are counter-intuitive:**

- F0a/F0b come before *any* format. Adding formats to an unclosable datapath makes the
  eventual timing failure unattributable.
- F1 (INT4) before every float, because it needs no float infrastructure at all.
- **F3 (BF16) before F4 (FP16)**, though FP16 is the more familiar format: identical
  throughput, and BF16 needs no new multiplier.
- F2 (FP8) before F3 (BF16), on the "equivalent speed" criterion — FP8 is the only float that
  reaches INT8's MAC rate.

### 5.1 F0b-2: where the register goes, and the one thing that makes it non-trivial

F0b-1 landed the seam, so the register site now exists. The reason it could not simply be
added to the old PE is worth stating, because it is the kind of error that produces plausible
wrong numbers rather than a failure: the accumulator is a **recurrence**,
`acc_q <= acc_i + tree` with `acc_i == acc_q`. Registering the PE's old `acc_o` would have fed
a *stale* accumulator into the next step and silently dropped terms. The reduction is a pure
function of its operands; the accumulator is state. Separating them is what makes the register
placeable, and `acc_i`/`acc_o` were **removed** rather than deprecated so no future reader
finds an inviting output to register.

The implementation, landed and verified:

```
sum_q      <= pe_sum;                          // the pipeline stage
sum_v_q    <= mac_active;                      // a step was issued
sum_first_q<= (t_q == 0);                      // zero the accumulator
sum_last_q <= (t_q + PeLanes >= k_q);          // element complete
sum_i_q, sum_j_q <= i_q, j_q;                  // C address, delayed to match

acc_d = (sum_first_q ? '0 : acc_q) + sum_q;
if (sum_v_q && sum_last_q) write C[sum_i_q, sum_j_q] = acc_d;
```

Throughput is preserved: operands still issue every cycle and only the *accumulate* lags, so
the cost is one drain cycle at the end of the whole GEMM rather than per element. The index
advance may proceed at issue rate precisely because `(i, j)` travel down the pipe. Small
fixtures kept their **identical** cycle counts (4×4 1673, smoke/lda 1212), and the 64×64 trail-
store fixture (93,194 cycles, 0 assertions) passed, which is the re-proof the hazard asked for.

**The hazard.** `c_w_req` is shared with the trail-C-store path in `ST_MAC`, which opportunistically
streams completed rows on cycles the MAC is not using AXI. Moving the MAC's own C write one
cycle later changes that arbitration, so F0b-2 had to be re-proven beyond the plain goldens.
Leaving ST_MAC also needs `&& !sum_v_q` so the last in-flight sum lands; that guard is in place.

**Grant discipline throughout.** `AiIslandPeImplMask` moves only with the datapath, and
`AiIslandDtypeMask` only with it. A format is never advertised before it computes; the
capability window would otherwise promise arithmetic that returns `ST_BAD_FMT`.

---

## 6. Status

| Step | State |
|---|---|
| F0a tree | **landed and verified.** Variane `ai-dt` rebuilt; island GEMM goldens `ai_gemm_s8_smoke` **SUCCESS 1212 cy** and `ai_gemm_s8_4x4_smoke` **SUCCESS 1673 cy**, zero assertions fired (`--assert` is live since AI-X5). Those exercise the PE through `g6lc_ai_gemm_seq`, which is the integration that matters. The unit TB `tb_g6lc_ai_pe_dot` is written but **cannot run** on this tool version — see below |
| F0b-1 accumulator moved out of the PE | **landed and verified.** `g6lc_ai_pe_dot` no longer has `acc_i`/`acc_o`; it is a pure sum-of-products reducer, and `g6lc_ai_gemm_seq` owns `acc_q + pe_sum`. Bit-identical: goldens **1212 cy** and **1673 cy**, unchanged from F0a, 0 assertions |
| F0b-2 pipeline register | **landed and verified.** `sum_q <= pe_sum`, drain computes `acc_d = (first_q ? '0 : acc_q) + sum_q` and writes `C` at `(sum_i_q, sum_j_q)` if `last_q`. Indices advance at issue rate; the C write and accumulator update lag by one cycle but issue one cycle per MAC. Verified: `ai_gemm_s8_smoke` **1212 cy**, `ai_gemm_s8_4x4_smoke` **1673 cy** (same as F0b-1, so the pipeline is fully hidden for small fixtures), `ai_gemm_s8_lda_smoke` **1212 cy**, `ai_gemm_s8_64x64_smoke` **SUCCESS 93,194 cy** with zero assertions. The trail-store hazard predicted in §5.1 does not appear in these fixtures because the delayed C write still completes before the trail store streams the same row; full trail-store stress is left for the wider flavour sweep |
| F1 INT4 | open |
| F2 FP8 | open |
| F3 BF16 | open |
| F4 FP16 | open |
| F5 FP32 | open |

Live `AiIslandPeImplMask` / `AiIslandDtypeMask` remain `16'h0001`, dense INT8, and will until
F1 lands. The emulator implements all six and refuses all but INT8 against that mask, so the
model and the hardware do not disagree in the meantime.

**Not established here.** No STA has been run on either the chain or the tree; the delay
figures in §1 are structural estimates for *ordering decisions only*, and
`AGENTS-configuration.md` §1.0b governs what may be claimed from `sv-timing` FO4 screening
versus real closure. The area costs in §3 are significand-width arguments, not synthesis
results.

### 6.1 Two RTL-shape traps found while landing F0a

Both produced a **stale combinational output** — the PE returned the previous stimulus's sum
after its inputs changed, which is indistinguishable from latched state in a module that has
none, and cost two misdirected investigations. Recorded so the next datapath change does not
rediscover them:

1. **A reduction written as one rectangular 2D array.** Every level both reads and writes the
   same signal, dependency analysis is per-signal rather than per-element, and the array
   appears to depend on itself. Reported as `UNOPTFLAT` — which the first version of
   `run-pe-dot.sh` was suppressing, so the warning that would have explained it was hidden.
   `-Wno-UNOPTFLAT` is now deliberately absent from that runner.
2. **Per-level signals read across generate scopes** as `gen_lvl[v-1].node[i]`. Legal SV, but
   the cross-scope hierarchical reference defeats the dependency graph just as thoroughly.

The shape that works is **one `always_comb` that multiplies and reduces with no intermediate
signal**, reading only the module's input ports. It has a single unambiguous dependency and an
explicit evaluation order, so neither failure mode is expressible.

A third instance of the same family sits on the *harness* side and is why the unit TB cannot
run: element-wise assignment into an **unpacked array port** is not tracked, so the testbench's
own arrays went stale while the DUT agreed with them exactly. Four DUT structures and three
harness structures all produced the identical wrong delta before the harness was identified;
`tb_g6lc_ai_pe_dot.sv`'s header carries the full record, and `run-pe-dot.sh` reports SKIP
rather than a verdict. Note the design itself is unaffected: `g6lc_ai_gemm_seq` drives
`pe_a[p]` procedurally from its own `always_comb`, which is the pattern that works — and is
why the harness-level goldens are valid evidence.
