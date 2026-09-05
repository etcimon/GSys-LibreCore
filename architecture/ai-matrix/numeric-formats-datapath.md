# Numeric formats in hardware — datapath analysis and development order

**Status:** analysis, partially implemented · **Scope:** `corev_apu/ai_island` PE datapath
**Parent:** [`README.md`](README.md) · **Contract:** [`isa-encoding.md`](isa-encoding.md) §3.1a
**Sizing model:** [`scaling-100tops.md`](scaling-100tops.md) · **Emulator reference:**
`g6lc_qemu/crates/g6q-vm/src/numfmt.rs`

> **Why this document exists.** The format *contract* is frozen (`numfmt`, the grant mask,
> `ST_BAD_FMT`) and the *emulator* computes the defined formats. The live hardware computes INT4/INT8.
> The obvious next step — "add the other formats to the PE" — is the wrong one, for two
> reasons explored here: the original INT8 reduction chain needed restructuring, and
> format-wide throughput depends on memory bandwidth as well as multiplier area. The tree
> and INT4 path have since landed; floating arithmetic remains an isolated scalar primitive.
> Structural delay estimates below are historical planning assumptions, not STA results.

---

The independent format-aware policy compartment is described in `README.md` §11.
`AiCfg.PolicyBenefitEn` enables scheduling metadata and benefit-driven row/column/
reduction grouping for the seven scalar formats, with native zero classification
and no floating-point residual skipping. Its matched-format cycle percentages
come from a validated service model, **not the numeric PE**; they neither complete
F2–F5 nor authorize a capability-mask change, reassociation or precision loss.

### Ordered floating arithmetic and emulator-evaluation continuation

The implemented arithmetic increment is an optional **scalar** operation
`RNE(RNE(widen(A) * widen(B)) + acc_fp32)`, using the existing FPnew FP32 unit in
separate MUL and ADD operations. Exact source widening covers FP8 E4M3/E5M2,
FP16, BF16 and FP32; integer execution remains on its existing reducer. This does
not assume BF16 or E4M3 support from a differently named vendor format. The
`AiCfg.IslandFpEn` gate is off by default and does not itself grant a format in
the island capability window. Native NaN outputs are canonical quiet FP32 NaN;
subnormals and signed zero remain significant. Per-operation flags are local
outputs, not implicit writes to a core's floating-point CSRs.

A generic floating block-floating dot-product PE is provided in two flavors:
* the combinational `g6lc_ai_pe_dot_float` is verified at `Lanes=4`; it decodes
  FP8 E4M3/E5M2, FP16, BF16 and FP32, multiplies, picks the most negative
  exponent as a block exponent, aligns products into a 640-bit signed
  accumulator, reduces with a balanced adder tree, and normalises/rounds to RNE
  FP32 once;
* the pipelined `g6lc_ai_pe_dot_float_pipe` adds registered stages so the same
  datapath supports `Lanes=256` without a single-cycle critical path, exposes
  `start_i`/`valid_o` with `Latency = $clog2(Lanes) + 4`, and registers stage-2
  product and block-exp/flag metadata plus a stage-3 block-exp/flag register so
  back-to-back starts with different `numfmt` and data stay aligned.

`verif/tb/ai_island/run-pe-dot-float.sh` passes 5,018 checks vs an exact
`double` oracle for the combinational module. `run-pe-dot-float-pipe.sh` passes
5,028 checks for `Lanes=4` and `Lanes=8`, including back-to-back issue with
different `numfmt`/data and half/alternating valid masks (finite results checked
within 1 ULP of the `double`-to-float oracle because the BFP reduction rounds
once at the end). A Verilator Lanes=256 elaboration/lint build of the pipelined
module completes with only pre-existing width warnings. Yosys `read_slang`,
`check -assert` and `synth -noabc -top g6lc_ai_pe_dot_float -flatten` report
zero problems, and `synth -noabc -top g6lc_ai_pe_dot_float_pipe -flatten` also
reports zero errors/warnings and zero CHECK problems for Lanes=4.

`g6lc_ai_gemm_seq` now dispatches FP8 (E4M3/E5M2), FP16, BF16 and FP32 to the
floating PE, accumulates multi-step tiles with a per-step FP32 `fp32_add`, and
stores the FP32 result in the C tile. When `DotPipeFloat` is set it uses the
pipelined `g6lc_ai_pe_dot_float_pipe` with a `dot_valid` handshake, a metadata
shift-register that returns `(first,last,i,j)` with the delayed `sum_o`, and an
outstanding-transaction counter (`dot_pending_q`) that prevents the C-flush path
from overtaking in-flight dot results. INT8 stays on the existing integer PE and
INT4 stays on the packed-nibble path. The MAC-side byte gather scales
`mac_step` and `fmt_row_bytes` by the format byte width (1/2/4), so the loaders
remain byte-oriented and the same bank/address mapping covers all formats.

The backend unit test `verif/tb/ai_island/run-gemm-backend.sh` now includes
directed 2x2x16 goldens for all live formats: INT8, INT4 (0x11 packed +1
nibbles), FP8 E4M3, FP8 E5M2, FP16, BF16 and FP32. Each uses all-1.0 (or
all-1 for integers) operands and expects 16/16.0 in the C tile. It passes for
nch={1,2,4,8} with both the combinational (`dpf=0`) and pipelined
(`dpf=1`) dot-product implementations. The standalone `g6lc_ai_pe_dot_float`
and `g6lc_ai_pe_dot_float_pipe` regressions both still pass.

The live island `AiIslandDtypeMask` and `AiIslandPeImplMask` remain INT8+INT4
only until the descriptor/grant path is updated to issue and validate the wider
floating formats.

## Lanes=256 floating dot-product architecture

The pipelined module `g6lc_ai_pe_dot_float_pipe` implements the same decode ->
product -> block-exponent -> align -> reduce -> round datapath as the
combinational `g6lc_ai_pe_dot_float`, but breaks the path into registered
stages so it can support `Lanes = 256` without a single-cycle critical path:

1. **Decode & multiply** (1 stage): per lane, decode `a_i/b_i` and form
   `(sign, mantissa, exponent)` for each product.
2. **Block exponent** (1 stage): reduce the 256 product exponents to the most
   negative (i.e. largest negative) value; this is the only serial dependency
   before alignment.
3. **Align** (1 stage): shift each product mantissa by
   `product_exp - block_exp` into the shared 640-bit accumulator grid.
4. **Reduce** (`$clog2(Lanes)` levels): a balanced signed adder tree, with a
   pipeline register every level. The total latency is `$clog2(Lanes) + 4`
   cycles from `start_i` to `valid_o`, including the final output register.
5. **Normalise & round** (1 stage): `bfp_mant_exp_to_fp32` produces the final
   FP32 `sum_o` and `flags_o`.

`g6lc_ai_gemm_seq` adds a `dot_valid` handshake and a metadata shift-register
that returns `(first,last,i,j)` with the delayed `sum_o`. An outstanding-transaction
counter (`dot_pending_q`) gates the C-flush path so a pipelined result can never
be overwritten by a store that was issued before the dot returned. The
`DotPipeFloat` parameter selects the pipelined PE and is verified in the backend
unit test for `nch={1,2,4,8}` across all live formats.

Descriptor version 2 remains the contract: A is `[m][k]`, B is `[n][k]`, both
leading dimensions count elements along K. `DESC_B_K_MAJOR` publishes that fact
for consumers that must not infer layout from square test cases. Conventional
framework `A @ B` APIs must repack B at the boundary rather than changing their
mathematical meaning. The g6lc_qemu native evaluation route must derive version,
field locations, flags and grants from the ingested model; unsupported layouts
and ungranted formats are refusals, never INT8 reinterpretations.

Software-native evaluation can complete before the remaining T2 floating loader,
byte-gather, accumulator, DMA and grant integration. Likewise, a scalar primitive
is not the format-wide array assumed by the policy scheduling model. Its measured
latency/initiation interval must be reported independently, and F2–F5 stay open
at island level until integrated GEMM numerical and memory regressions pass.

## 1. Historical finding: the original INT8 reduction chain

Before F0a/F0b, `g6lc_ai_pe_dot.sv` reduced `Lanes` products with a **linear chain**.
The following analysis motivated the now-landed balanced tree and pipeline; it is
not a description or timing sign-off of the current reducer:


```systemverilog
assign partial[0] = $signed(acc_i);
for (genvar l = 0; l < int'(Lanes); l++)
  assign partial[l+1] = partial[l] + prod[l];   // depth == Lanes
```

The former header described "MAC tree depth ~Lanes", but the structure was a chain;
a tree has depth `log2(Lanes)`. The historical comparison at `PeLanes = 256` was:

| Structure | Adder depth | Est. delay @ 32-bit add ≈ 100 ps | Implied f_max |
|---|---|---|---|
| original chain | **256** | ~25.6 ns | **~39 MHz** |
| balanced tree | **8** | ~0.8 ns | ~1.25 GHz (before the multiplier) |

The assumed 100 ps per 32-bit carry-propagate add makes the original chain miss the
1.0 GHz target in `AGENTS-configuration.md` §1.0a by more than an order of magnitude
in this structural model. These numbers are neither a physical delay bound nor a
measured clock limit; the current tree still needs library/placement-aware STA.

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
| **F2** | **FP8 E4M3 + E5M2** | First float, and the only float that keeps INT8-equivalent speed (§2). Mantissa is *smaller* than the existing cell (§3), so the cost is purely the float accumulator. The `g6lc_ai_pe_dot_float` unit is verified at Lanes=4 with 5,018 checks and `g6lc_ai_pe_dot_float_pipe` at Lanes=4/8 with 5,028 checks; both are synthesizable (`synth -top g6lc_ai_pe_dot_float -flatten` reports zero problems) | INT8/INT4 goldens; FP8 golden incl. the 448.0 and subnormal cases; standalone dot-product Verilator + Yosys check/synth pass; pipelined GEMM integration nch={1,2,4,8} dpf=0,1 PASS |
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

## 7. F1 design: INT4 in the island datapath

INT4 is the cheapest format and the only one that *raises* throughput. The work splits into
carrying `numfmt` to the sequencer, changing the operand fetch, and reusing the 8×8 signed
multiplier to compute two 4×4 products.

### 7.1 The multiplier trick

A signed 4-bit value sign-extended to 8 bits is still that value. So for INT4:

```
let a4 = sext4(nibble_a);  // a4 is the 4-bit value in an 8-bit signed container
let b4 = sext4(nibble_b);
let p  = a4 * b4;          // fits in 8 bits (max 49, min -56)
```

The existing 8×8 multiplier cell computes `a8 * b8` where `a8` and `b8` are already sign-
extended from 8-bit inputs. If those inputs happen to be sign-extended 4-bit values, the
product is the correct 4×4 product, still in 32-bit sign-extended form. So the multiplier
array does not need a separate 4×4 unit; it needs the **right nibble** fed to each lane.

This means the *tree* is the bottleneck. For INT4, each read byte contains two operands, so
the PE can produce `2 * PeLanes` products per cycle. The tree already parameterized by `Lanes`;
F1 sizes it for `2 * PeLanes` and uses the upper half as zeros when `numfmt != INT4`. The
depth increases by one adder level (log2(2*256)=9), which is fine because the F0b-2 register
sits between the tree and the accumulator.

### 7.2 Operand fetch

The A/B tile SRAM has `PeLanes` banks, each returning one byte. In INT8, bank `q` in a MAC
step reads the byte at element `t_q + q`. In INT4, the same `PeLanes` bytes contain
`2 * PeLanes` elements:

```
byte b = t_q / 2 + q                 // t_q is a multiple of PeLanes and therefore even
nibble 0 -> element t_q + 2q
nibble 1 -> element t_q + 2q + 1
```

The `t_q` advance for INT4 should be `2 * PeLanes` elements per issue. The bank address is
`i * KPerBank + (t_q/2 + q) / PeLanes` (A) and `j * KPerBank + (t_q/2 + q) / PeLanes` (B).
`KPerBank = ceil(MaxDim/PeLanes)` is still sufficient because `t_q/2 + q < MaxDim/2 + PeLanes <=
MaxDim <= PeLanes * KPerBank` for the live parameters. The byte fits; only the mapping changes.

`pe_a[p]` for the PE therefore becomes `2 * PeLanes` 8-bit lanes:
- for INT8: `pe_a[2q] = a_r_data[q]`, `pe_a[2q+1] = 0`, `pe_v[2q+1] = 0`.
- for INT4: `pe_a[2q] = sext4(a_r_data[q][3:0])`, `pe_a[2q+1] = sext4(a_r_data[q][7:4])`,
  both valid.

The tree width doubles, but the upper half of the product array is zero for INT8, so the sum
is unchanged.

### 7.3 Descriptor / capability plumbing

The `numfmt` field (`flags[22:20]`) already reaches the descriptor engine
(`g6lc_ai_desc_engine.sv`) and is refused with `ST_BAD_FMT` if not granted. For F1:

- `g6lc_ai_gemm_seq` receives `numfmt` from the descriptor (it already has `m/n/k/lda/ldb`).
- INT4 uses `numfmt == AI_FMT_INT4` (value from `config_pkg`).
- `AiIslandPeImplMask` and `AiIslandDtypeMask` gain `AI_FMT_INT4`.
- `g6lc_ai_island_top` already asserts `grant ⊆ impl`; the assertion will fire unless both
  masks move together.

### 7.4 Why not a separate small INT4 PE

A dedicated 4×4 multiplier array would need `2 * PeLanes` 4×4 multipliers to get the 2×
throughput, which is the same cell count as fracturing the existing 8×8 array (`~2× area` for
2× the products is expected). Keeping one array and switching the inputs avoids a second
reduction tree and a second accumulator path — the same F0b-2 pipeline serves all formats.

### 7.5 Verification plan

1. PE-level: once the unit TB layer works, verify `pe_sum` for INT4 against a reference
   function with packed nibbles.
2. Harness: `ai_gemm_s8_*` tests must remain byte/cycle-identical (INT8 path unchanged).
   Done for this slice: `ai_gemm_s8_smoke` 1212 cy, `ai_gemm_s8_4x4_smoke` 1673 cy,
   `ai_gemm_s8_64x64_smoke` 93,194 cy, all 0 assertions.
3. New test `ai_gemm_int4_4x4_smoke.S`: operand fixture values in `[-8,7]`, golden computed
   from the emulator `numfmt.rs`.
4. Edge cases: odd `k` (last byte carries one valid nibble), negative zero, `lda` that is odd
   (packed row stride is not an integer number of bytes), and `ldb` mismatched with `n`.

### 7.6 Sequencer changes: historical F1 split (now closed)

The MAC-execution slice is in place in `g6lc_ai_gemm_seq`:

1. `t_q` advances by `2 * PeLanes` for INT4, `PeLanes` for INT8 (`mac_step` signal).
2. For INT4, read byte index `(t_q / 2) + p` from bank `p` (this works because `t_q` is
   always a multiple of `2 * PeLanes`, so `t_q / 2` is a multiple of `PeLanes`).
3. Per-lane nibble validity and masking: zero the invalid nibble in `pe_a`/`pe_b` when
   `t_q + 2p + 1 >= k_q`, but keep the valid nibble.
4. `a_addr` / `b_addr` scale the byte offset of element `t` by `t / 2` and the leading-
   dimension byte stride by `ceil(lda / 2)` for INT4. The live INT8 path is unchanged.

Subsequent F1 closure (see §9):

5. The A/B loaders now count `ceil(k / 2)` native bytes and use the corresponding
   per-row byte strides. The earlier INT4 over-fetch gap is closed.
6. `g6lc_ai_island_cfg_pkg::AiIslandDtypeMask` and `AiIslandPeImplMask` were raised
   together to `AiFmtMaskInt8Int4` (`16'h0003`), retaining `grant ⊆ implemented`.
   Floating formats are not included in this grant.

---

## 6. Status

| Step | State |
|---|---|
| F0a tree | **landed and verified.** Variane `ai-dt` rebuilt; island GEMM goldens `ai_gemm_s8_smoke` **SUCCESS 1212 cy** and `ai_gemm_s8_4x4_smoke` **SUCCESS 1673 cy**, zero assertions fired (`--assert` is live since AI-X5). Those exercise the PE through `g6lc_ai_gemm_seq`, which is the integration that matters. The unit TB `tb_g6lc_ai_pe_dot` is written but **cannot run** on this tool version — see below |
| F0b-1 accumulator moved out of the PE | **landed and verified.** `g6lc_ai_pe_dot` no longer has `acc_i`/`acc_o`; it is a pure sum-of-products reducer, and `g6lc_ai_gemm_seq` owns `acc_q + pe_sum`. Bit-identical: goldens **1212 cy** and **1673 cy**, unchanged from F0a, 0 assertions |
| F0b-2 pipeline register | **landed and verified.** `sum_q <= pe_sum`, drain computes `acc_d = (first_q ? '0 : acc_q) + sum_q` and writes `C` at `(sum_i_q, sum_j_q)` if `last_q`. Indices advance at issue rate; the C write and accumulator update lag by one cycle but issue one cycle per MAC. Verified: `ai_gemm_s8_smoke` **1212 cy**, `ai_gemm_s8_4x4_smoke` **1673 cy** (same as F0b-1, so the pipeline is fully hidden for small fixtures), `ai_gemm_s8_lda_smoke` **1212 cy**, `ai_gemm_s8_64x64_smoke` **SUCCESS 93,194 cy** with zero assertions. The trail-store hazard predicted in §5.1 does not appear in these fixtures because the delayed C write still completes before the trail store streams the same row; full trail-store stress is left for the wider flavour sweep |
| F1 INT4 | **COMPLETE and verified.** PE widening (F1-PE), MAC addressing/stride scaling (F1-sequencer), the §8 k-major operand change, and byte-counting loaders (F1-load) are all landed. Grants raised to `AiFmtMaskInt8Int4` (`16'h0003`) in both `AiIslandDtypeMask` and `AiIslandPeImplMask`. `ai_gemm_s4_smoke` (m=2 n=2 k=4, operands spanning −8..7, negative C) **PASSES 1230 cy**, and all seven INT8 fixtures keep their exact cycle counts. See §9 |
| F2–F5 FP8/FP16/BF16/FP32 | E4M3/E5M2 widening, ordered scalar arithmetic and both combinational (`g6lc_ai_pe_dot_float`) and pipelined (`g6lc_ai_pe_dot_float_pipe`) dot-product PEs **landed and verified**: 5,018 Verilator Lanes=4 checks vs a `double` oracle for the combinational
`g6lc_ai_pe_dot_float` and 5,028 Lanes=4/8 checks (with 1-ULP finite tolerance
for BFP-vs-float rounding) for `g6lc_ai_pe_dot_float_pipe`, including
back-to-back issue with different `numfmt`/data and half/alternating valid masks;
Lanes=256 Verilator elaboration/lint passes with only pre-existing width warnings;
`g6lc_ai_gemm_seq` integrated with `DotPipeFloat` and `dot_pending_q`
outstanding-transaction tracking; `run-gemm-backend.sh` PASS for nch={1,2,4,8}
with `dpf=0,1` across all live formats. Yosys `read_slang`, `check -assert` and
`synth -noabc -top g6lc_ai_pe_dot_float -flatten` all report zero problems, and
`synth -noabc -top g6lc_ai_pe_dot_float_pipe -flatten` also reports zero
errors/warnings and zero CHECK problems for Lanes=4 (full `abc` mapping skipped
on the 640-bit proof-of-concept accumulator). `fp_dot_product` now narrows the
mantissa product to `a.mant[23:0] * b.mant[23:0]` (24×24) before the 64-bit
extension, so the widest significand path is an explicit 24×24 unsigned
multiplier. Yosys generic cell count for `g6lc_ai_pe_dot_float_pipe` (Lanes=4)
falls from ~128k to ~115k cells. Full `abc` mapping on the 640-bit accumulator
remains too heavy for this tool pass, and physical hard-macro/timing closure for
100-TOPS-class arrays is still a PDK- and floorplan-dependent step; the current
product path is functionally correct for dot-product sums that fit within the
640-bit FP_DOT_MAXW accumulator.
| F3 BF16 | Included in the generic dot-product PE and the pipelined GEMM backend |
| F4 FP16 | Included in the generic dot-product PE and the pipelined GEMM backend |
| F5 FP32 | Included in the generic dot-product PE and the pipelined GEMM backend; 24×24 decomposition open for non-decomposable product widths |

Live `AiIslandPeImplMask` / `AiIslandDtypeMask` are `16'h0003`: INT8 and packed INT4.
Software references implement seven scalar formats, but execute only those allowed by
the selected mask. The explicitly named software fixture uses `0x00fb`; it never
replaces live discovery. SP24 remains unsupported even in that fixture.

The floating primitive is `g6lc_ai_fp_mac.sv` with `include/g6lc_ai_fp_pkg.sv`.
For 1/2/3/5 pipeline registers, isolated RTL measures 4/6/8/12 cycles to a visible
result and 6/8/10/14-cycle initiation intervals. Default-off `AiCfg.IslandFpEn`
does not connect it to `g6lc_ai_gemm_seq`; that sequencer remains integer-only.
Loaders, byte gathering, ordered accumulation, C stores and integrated grant tests
are still required before claiming F2–F5 at island level. Reproduction and scope:
[`README.md` §12](README.md#12-native-model-evaluation-and-exact-floating-arithmetic).

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

---

## 8. The operand-layout decision: B becomes k-major

F1's MAC slice landed (§7.6) and then hit a wall in the **load** path. Resolving it turned out
to require an ABI change, and the analysis inverted the obvious answer, so it is recorded here
rather than in a commit message.

### 8.1 The constraint, stated precisely

The blocking property is **not** "INT4 needs a transpose". It is:

> A sub-byte format forces the **packing axis to equal the reduction axis**. Two INT4 elements
> sharing a byte must both feed the *same* `C[i,j]` accumulator, so they must be two
> consecutive `t`. Every ≥1-byte format (INT8, FP8, BF16, FP16, FP32) is indifferent to the
> packing axis, because each element occupies whole bytes.

So this is a **sub-byte** problem, not a general numeric-format problem. FP32 with row-major B
works fine on the existing loader; only INT4 (and any future INT2/FP4) breaks. That matters,
because it means "one common path for all six formats" is a benefit the ABI change *buys*, not
a requirement the formats impose.

`A[i,t]` is row-major and therefore already packs along `t`. `B[t,j]` row-major packs along
`j`. Those axes do not match, which is the whole difficulty.

### 8.2 The three candidates

| | ABI | Throughput | RTL effect | Generality |
|---|---|---|---|---|
| **(i)** row-major B, transpose nibbles inside the loader | unchanged | **~2× B load latency** for INT4 — cannot pack until rows `t` and `t+1` are both resident, which cancels much of the point | + `MaxDim`-byte row buffer, + pair-and-pack | INT4 only |
| **(ii)** row-major B, 2×2 INT4 micro-tile (2 `t` × 2 `j`, 4 products, 2 C columns) | unchanged | full 2× | **two accumulators per issue, 2× C write rate** — reopens exactly the `sum_first`/`sum_last`/delayed-C protocol F0b-1/F0b-2 just cleaned up | INT4 only |
| **(iii)** **B supplied k-major** (`B'[j,t]`, `ldb = k`) | **breaks row-major B** | full 2×, byte-for-byte identical traffic | **net deletion** — see §8.3 | all six formats, one path |

### 8.3 Why (iii) removes code rather than adding it

The decisive observation is that **the B *tile* layout does not change at all**. It is already
k-contiguous within a `j` row:

```
b_bank_addr(t, j) = j * KPerBank + t / PeLanes      bank = t % PeLanes
a_bank_addr(i, t) = i * KPerBank + t / PeLanes      bank = t % PeLanes
```

Those are the *same function* with the row index swapped. What fights the tile is the current
memory **traversal**, which streams along `j`. Stream along `t` instead and B's loader becomes
structurally identical to A's:

| | A today | B today | B under (iii) |
|---|---|---|---|
| memory traversal | along `t` | along `j` | along `t` |
| a 64-bit beat lands in | `PeLanes` banks, 1 addr each | **1 bank, 8 addrs** | `PeLanes` banks, 1 addr each |
| tile SRAM write ports | 2 | **8** | 2 |
| sub-byte packing | natural | impossible | natural |

So (iii) does not merely enable INT4. It deletes the oct-port drain: the
`beat_left_q`/`beat_lane_q`/`beat_q` leftover machinery, the `b_w2..b_w8` port fan-out, and the
B tile's `NumPorts(8) → 2`. That is a real area saving on the largest SRAM in the island, and
the 8 ports turn out to buy nothing the bank spread does not already provide — A sustains one
beat per cycle across 8 *different* banks with a single write port each.

One scale function then serves both operands and all six formats:

```
byte_off(t)     = (elems_per_byte == 2) ? t >> 1        : t * bytes_per_elem
row_stride(ld)  = (elems_per_byte == 2) ? (ld + 1) >> 1 : ld * bytes_per_elem
```

which is `config_pkg::ai_fmt_bytes()` generalised — a function that already exists and already
carries the INT4 "packed two per byte" note.

### 8.4 Why the ABI "break" is smaller than it sounds

**For the dominant workload, k-major B is the layout the caller already has.**

`torch.nn.Linear.weight` is stored `[out_features, in_features]` = `[n, k]` row-major, and
`F.linear(x, W) = x @ Wᵀ`. In `C[m,n] = A[m,k] · B[k,n]` that makes `B = Wᵀ`, and `W` as stored
is exactly **k-contiguous per output column `j`** — layout (iii). TF `Dense` kernels under the
usual `[units, input_dim]` storage are the same. So the *current* row-major-B contract is the
one that forces a transpose of every `nn.Linear` weight; (iii) adopts the layout the callers
already satisfy and pushes the transpose onto the rarer general-GEMM case, where `OP_LAYOUT`
(opcode 3, **already reserved and already accepted** by the descriptor engine) is the sanctioned
home for it.

### 8.5 Versioning — where the repo's own instinct does not apply

`AI_FMT_INT == 0` exists so that "no shipped image changes meaning" and `ContractVersion` stays
1. Applying that reflex here would give a `FLAG_BT` bit defaulting to legacy and **two permanent
B loaders** — the opposite of the minimality (iii) is chosen for. The no-break rule does not
bind, because:

- live grants are INT8-only (`AiIslandDtypeMask = 16'h0001`), so no format needing this is
  reachable yet;
- every consumer of `ldb` is in-tree — the RTL, the four `verif/tb/ai_island` benches, the
  emulator, `ai-tensor`. There is no external shipped image;
- the island is pre-tape-out.

Decision: **`ContractVersion` goes to 2, k-major B becomes the only layout, and the legacy
oct-drain path is deleted.** `FLAG_BT` is *not* introduced; a migration bit whose only consumer
is the migration is dead weight the moment the goldens are regenerated.

### 8.6 The verification hazard that must be closed first

This is the real risk in the change, and it is not the ABI.

- `ai_gemm_s8_64x64_smoke`, `128x128`, `256x256` fill `mat_b` with `.rept N / .byte 1` — an
  **all-ones** matrix. It is layout-invariant and **cannot distinguish** row-major B from
  k-major B.
- `ai_gemm_s8_smoke`, `4x4`, `lda` are square or symmetric enough that a transposed B still
  produces plausible C.

So a wrong transpose passes the entire existing suite. Before the switch, the suite needs a
fixture with `m ≠ n ≠ k` and **asymmetric** B data, whose C is wrong under either layout if the
other is used. `ai_gemm_s8_asym_smoke` (m=2, n=3, k=4) is that fixture, and it lands *first*,
on the pre-change RTL, so it is proven to pass row-major before it is asked to prove k-major.

Note that C never changes: `C = A·B` is the same product. Only B's **storage** changes, so the
expected values in every fixture stay exactly as they are.

### 8.7 Throughput

Byte-for-byte identical. The current B load is `k` bursts of `row_bytes(n)`; the proposed one is
`n` bursts of `row_bytes(k)`. Same total, both fully contiguous INCR.

| shape | effect |
|---|---|
| square `k ≈ n` | identical |
| tall-skinny `k ≫ n` | **better** — fewer, longer bursts |
| wide-flat `n ≫ k` | worse burst count, mitigated by `MaxAROut` multi-outstanding AR, which A already depends on |

Beat absorption is unchanged at one beat per cycle. This is why the oct-port was removable
without a throughput cost — but the claim is only settled by re-measuring
`ai_gemm_s8_64x64_smoke` against its **93,194 cy** baseline, not by this argument.

### 8.8 Change surface — **LANDED**

| File | Change |
|---|---|
| `include/g6lc_ai_desc_pkg.sv` | `ContractVersion = 2`, `DESC_VERSION = 16'd2`; normative OPERAND LAYOUT block |
| `g6lc_ai_gemm_seq.sv` | `ST_LB` rewritten to mirror `ST_LA` (burst along t, row cursor j); beat-hold drain, `b_w2..b_w8`, `beat_q`/`beat_lane_q`/`beat_left_q` **deleted**; B tile `NumPorts(8) → 2`; `b_addr` swaps its axes; `ldb < k` legality; `lb_n_d` widened `[3:0] → [7:0]` |
| `core/include/config_pkg.sv` | `ai_fmt_bytes` unchanged — the sequencer's `fmt_t_to_byte_off`/`fmt_ld_to_stride` already generalise it |
| `g6q-vm/src/gemm.rs` | B row base `t * b_row_stride` → `j * b_row_stride`, element index `j` → `t`; `ldb < n` → `ldb < k`; `read_elem` needed **no** change |
| `ai-tensor-abi` | `CONTRACT_VERSION = 2`; `Gemm::new` sets `ld_ab = k \| (k << 16)`; `mmio::CAP_LAYOUT` + bit masks |
| `g6lc_ai_island_cfg_pkg.sv` / `g6lc_ai_cap_window.sv` | new `CAP_OFF_LAYOUT = 0x4C` publishing `a_k_major`/`b_k_major`, so software discovers the layout instead of inferring it from a version it may not read |
| fixtures | 17 fixtures bumped to version 2; `ldb` corrected where `n != k`; `mat_b` transposed in the data-bearing ones. The all-ones large fixtures needed no data edit |

Net effect on `g6lc_ai_gemm_seq.sv`: **1677 → ~1520 lines.** The change removes code, as §8.3 predicted.

### 8.10 Measured result

Same `ai-dt` netlist, all fixtures recompiled at version 2:

| fixture | shape | cycles | note |
|---|---|---|---|
| `ai_gemm_s8_smoke` | 2×2×2 | **1212** | identical to the row-major baseline |
| `ai_gemm_s8_lda_smoke` | 2×2×2, lda=4 | **1212** | identical |
| `ai_gemm_s8_4x4_smoke` | 4×4×8 | **1612** | was 1673 — k-major B is *faster* here |
| `ai_gemm_s8_asym_smoke` | 2×4×6 | **1375** | the layout oracle |
| `ai_gemm_s8_oddn_smoke` | 2×3×4 | **1369** | was FAILING (AI-X8) |
| `ai_gemm_s8_n1_smoke` | 2×1×4 | **1154** | matrix-vector |
| `ai_gemm_s8_m1n3_smoke` | 1×3×4 | **1218** | odd n, no trail store |
| `ai_gemm_s8_64x64_smoke` | 64×64×64 | **93,194** | **bit-identical to the baseline**, 0 assertions |

`g6lc_qemu` workspace **583/583**; `ai-tensor-abi` + `ai-tensor-ir` **15/15**.

**The 64×64 result is the one that settles §8.7.** The 8-port B tile and the oct-drain were
removed and the large-fixture cycle count did not move by one cycle, so the claim that the
extra write ports bought no throughput is now measured rather than argued. The saving is
`PeLanes` × 6 write ports on the island's largest SRAM array.

`ai_gemm_s8_smoke` accepting a version-2 descriptor is itself the proof the netlist
carries the change: a stale build would have answered `ST_BAD_VER`.

The 4×4 improvement is the §8.7 tall-skinny case showing up early — that fixture is
`k=8 > n=4`, so `n` bursts of `row_bytes(k)` beats `k` bursts of `row_bytes(n)`.

### 8.11 What this bought F2–F5

The point of §8 was never INT4 alone. With the loaders counting **bytes**, a format now only
has to declare how many bytes a row of `k` elements occupies — `fmt_row_bytes` — and neither
loader needs a per-format branch. The remaining format work is therefore confined to the
*MAC-side gather and the multiplier*, which is where it belongs:

| step | load work remaining | datapath work remaining |
|---|---|---|
| **F2** FP8 E4M3/E5M2 | **none** — 1 byte/element, already exact | float dot-product PE / accumulator; significand is *smaller* than the existing 8×8 cell. Lanes=4 `g6lc_ai_pe_dot_float` (5,018 checks) and `g6lc_ai_pe_dot_float_pipe` (5,028 Lanes=4/8 checks) verified with Verilator; Lanes=256 lint passes; pipelined GEMM integration PASS nch={1,2,4,8}, dpf=0,1 |
| **F3** BF16 | `fmt_row_bytes` × 2 (one line) | exponent path; reuses F2's accumulator and the unmodified 8×8 cell |
| **F4** FP16 | `fmt_row_bytes` × 2 (one line) | 11×11 significand — new multiplier |
| **F5** FP32 | `fmt_row_bytes` × 4 (one line) | 24×24 by decomposition |

So the ordering argument of §5 survives contact with the implementation, and the "one
configurable common path" the ABI change was chosen for is real rather than aspirational.

### 8.9 Sizing note

`KPerBank = ceil(MaxDim / PeLanes)` and `BankWords = MaxDim * KPerBank` are sized in
**elements**. For a sub-byte format a tile row holds `ceil(MaxDim/2)` bytes, so the existing
sizing is conservative (over-provisioned), not wrong — INT4 uses half the tile. Left as is
deliberately; shrinking it would make the tile format-dependent, which is the coupling this
whole section removes.

---

## 9. F1 complete: INT4 executes in RTL

The last F1 slice was the **load byte-count**, and it turned out to be the cleanest of the
three because it is expressible as a change of *units* rather than a new branch.

### 9.1 Two cursor conventions, stated

`g6lc_ai_gemm_seq` now uses `t` with two different meanings, in two disjoint sets of states:

| states | `t` counts | bound |
|---|---|---|
| `ST_LA`, `ST_LB` | **bytes** along the operand row | `k_bytes = fmt_row_bytes(k_q)` |
| `ST_MAC` | **elements** | `k_q` |

`t_q` is reset at every state transition, so the meanings never overlap — the same reuse
`i_q`/`j_q` already rely on. This is why the load path became format-agnostic: the tile stores
bytes keyed by byte position (`bank = byte % PeLanes`, `addr = row*KPerBank + byte/PeLanes`),
which is exactly what the MAC reads back with `byte_idx = (t_q >> 1) + p`. Only ST_MAC needs to
know about elements, because only elements bound against `k` and only elements decide nibble
validity on an odd-`k` tail.

Consequence: `a_addr`/`b_addr` no longer convert `t`, because the caller already scaled it.
Only `fmt_ld_to_stride` remains, and it is now a thin wrapper over `fmt_row_bytes`.

### 9.2 Grants raised, in lockstep

`AiIslandDtypeMask` and `AiIslandPeImplMask` both moved `16'h0001 → 16'h0003`. The
`grant ⊆ implemented` assertion in `g6lc_ai_island_top` passed at elaboration, which is the
build-time proof that the two did not drift.

Both are **literals**, not `config_pkg::AiFmtMaskInt8Int4`: the `verif/tb/ai_island/run-gemm-*.sh`
unit-TB runners compile `g6lc_ai_island_cfg_pkg` *before* core's `config_pkg`, so a
cross-package reference breaks them. The value is pinned instead by the elaboration assertion
and by the emulator's ingest test, which reads the real package text and asserts `0x0003`.

### 9.3 Measured

| fixture | shape | cycles |
|---|---|---|
| **`ai_gemm_s4_smoke`** | **INT4** 2×2×4 | **1230** |
| `ai_gemm_s8_smoke` | 2×2×2 | 1212 |
| `ai_gemm_s8_lda_smoke` | 2×2×2, lda=4 | 1212 |
| `ai_gemm_s8_4x4_smoke` | 4×4×8 | 1612 |
| `ai_gemm_s8_asym_smoke` | 2×4×6 | 1375 |
| `ai_gemm_s8_oddn_smoke` | 2×3×4 | 1369 |

Every INT8 count is unchanged from before the byte-counting change, which is the regression
argument: for INT8 `k_bytes == k_q`, so the load path is bit-identical by construction.

The INT4 fixture is built to fail loudly rather than pass by luck: operands span the signed
INT4 endpoints (`−8`, `7`), `−8 × −8 = +64` is present so a sign-extension slip shows up as a
negative product, and three of the four golden C values are **negative**, which an
all-positive golden could not check. It also asserts `ST_OK` rather than `ST_BAD_FMT`, so it
fails if the grant and the datapath disagree.

### 9.4 Measured: INT4 buys ~nothing at 64×64, and that is the correct answer

`ai_gemm_s4_64x64_smoke` is the INT4 twin of `ai_gemm_s8_64x64_smoke` — **byte-identical
descriptors except `flags.numfmt`**, same all-ones operands, same golden `C[i,j] = 64` checked
across all 4096 elements. So the cycle delta is attributable to the format alone:

| fixture | format | cycles |
|---|---|---|
| `ai_gemm_s8_64x64_smoke` | INT8 | **93,194** |
| `ai_gemm_s4_64x64_smoke` | INT4 | **93,177** |

**A 17-cycle difference — 0.02%.** Halving the operand bytes bought essentially nothing.

This is not a defect, and it is worth stating plainly because it contradicts a naive reading of
§2's "INT4 = 2×":

1. **The MAC cost is identical by construction.** At `PeLanes ≥ 64` one issue covers all of
   `k=64` for both formats (INT8 steps by `PeLanes`, INT4 by `2*PeLanes`), so both spend
   exactly `m*n` issues in `ST_MAC`. INT4's extra lanes are *idle* at this `k`, not busy.
2. **The load is latency-bound, not byte-bound.** Both formats issue the same **number** of AR
   transactions (one burst per operand row, 64 each); INT4 only makes each burst shorter. With
   `MaxAROut = 2` the per-burst latency dominates, so fewer beats per burst barely helps.
3. **The harness dominates the wall clock anyway.** 93k cycles is mostly CPU boot, descriptor
   setup, the completion poll and a 4096-element check loop. The GEMM is a small slice.

So §2's 2× is an argument about a **DRAM-bandwidth-saturated** regime, and a 64×64 tile
resident in SRAM is emphatically not in that regime. The honest claim after this pass is:
*INT4 halves operand traffic, which is a bandwidth-regime win and is not observable on these
fixtures.* Nothing here licenses an "INT4 throughput" number.

`ai_gemm_fmt_pmu_smoke` exists to sharpen this by reading the island's own per-job counter
(`AI_PMU_CY`, 0x188) for both formats in one ELF and requiring INT4 to be strictly faster. It
needs `S4_TIME_OUT=3000000` (see its header) and has **not** produced a number yet.

### 9.4b Not established

- **INT4 in a bandwidth-bound regime.** Needs a shape that actually saturates DRAM — large `k`
  with a tile that does not fit, or `MaxAROut` raised so the load stops being latency-bound.
  Until then §2's ratios remain projections.
- **Odd `k`** — now covered, see `ai_gemm_s4_oddk_smoke` in §9.3.
### 9.5 The multi-channel defect the layout rewrite introduced (AI-X10)

Worth recording, because the layout change looked complete and was not.

`ai-dt` is single-channel, so `SplitArId` is 0 and the load column cursor comes straight from
`t_q`. On `ai-sc2` (`NrChannels = 2`) the AR slots are split and the cursor lives in
`ar_slot_q[].col`, retired by a **per-state bound**:

```
if ((state_q == ST_LA && ...col + ntake >= k_bytes) ||
    (state_q == ST_LB && ...col + ntake >= n_q   ))   // <-- stale
```

`n_q` was right while B was row-major, because its rows ran along `j`. AI-X9 made `col` a byte
offset along `t`, so the bound had to become `k_bytes` — and did not. The slot rolled its row at
the wrong point and corrupted C.

It is reachable only when **both** conditions hold:

1. `SplitArId` — `NrChannels > 1` and `PeLanes >= BytesPerBeat`;
2. a row stride that does **not** divide `BytesPerBeat`, so a row straddles a beat.

No power-of-two shape can satisfy (2), which is why every earlier flavour sweep was blind to it.
Bisected in three 20 s runs:

| fixture | strides | `ai-dt` | `ai-sc2` |
|---|---|---|---|
| power-of-two fixtures | divide 8 | PASS | PASS |
| `ai_gemm_s8_asym_smoke` | lda=6, **ldb=6** | PASS | **FAIL** |
| `ai_gemm_s8_astraddle_smoke` | lda=6, **ldb=8** (padded) | PASS | **PASS** |

The third row is the one that matters: with only A straddling it passes, which acquits the
untouched `ST_LA` and puts the fault squarely in the new `ST_LB`.

**Standing lesson:** non-power-of-two dimensions belong in the permanent suite, not just in
bring-up. Every dimension in the suite was a power of two before this session, and that single
property hid an odd-`n` C-store defect (AI-X8) *and* a multi-channel load defect (AI-X10).
