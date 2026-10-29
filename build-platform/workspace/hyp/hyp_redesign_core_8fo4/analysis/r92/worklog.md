# r92: latency-neutral DOT4 arithmetic and capture reduction

Baseline: commit `a6428f92e` (r91). Scope: Hyp8 `g6lc_ai_exec.sv`,
the existing execution leaf, and measurement/verification records.
Production `core/` and `corev_apu/` are unchanged.

## Matched structural results

All boards use delay-v49 / ir-v6 / correction-v5, the same analyzer binary,
`timing/hyp8-core.f`, r88 parameters with explicit `Dot4Stages` and
`NrRgprPorts`, target 5000 MHz, fo4_ps=20, margin=0.2, budget=8 FO4.
No skipped files or analyzer errors. The twelve manifests were checked:
binary, flist and parameter hashes match within each comparison; final RTL
hashes match the reviewed source. Each manifest records the exact argv.

The table uses the maximum over **all** reported paths, including input-to-
register paths. The analyzer's `frequency_closure` summary can instead select
the register-to-register maximum; it must not substitute for this table.

| Dot4Stages | Register ports | Before | Wired rows + narrow sum | Final | Reduction |
|---|---:|---:|---:|---:|---:|
| 1 | 2 (module default) | 77.35 | 59.04 | 60.44 | 21.9% |
| 1 | 3 (DOT4A accumulator present) | 89.35 | 71.04 | 63.60 | 28.8% |
| 2 | 2 | 40.85 | 36.40 | 34.10 | 16.5% |
| 2 | 3 | 40.85 | 36.40 | 34.10 | 16.5% |

Board stems: `timing/boards/r92-{before,after-rows,final}-d{1,2}-r{2,3}`.
Each has `.json`, `.log`, and `.manifest.json`; large `.ir.json` files remain
local under the existing ignore rule. Maps live in this directory. Reproduce
on the appropriate source revision from the repository root:

```text
python build-platform/workspace/hyp/hyp_redesign_core_8fo4/analysis/r92/measure.py <phase-label>
```

The recipe runs independent bindings two at a time. A new measurement must use
a fresh phase label to preserve these results.

## Kept transformations and arithmetic contracts

1. **Wired signed partial products.** Replace conditional shifted 16-bit rows
   and the negative sign row with shared 8-bit AND partial products and static
   concatenations. Baugh-Wooley complements the two sets of negative-weight
   cross terms; the correction is `16'h8100`, wired into unused row-0 bits.
   The products remain exact modulo 2^16. Signed products are sign-extended
   to 17 bits; unsigned products are zero-extended, preserving 255*255=65025.
2. **Bounded sum width.** Four signed products range from -65024 to 65536;
   four unsigned products range from 0 to 260100. Both sums fit 18 bits.
   Explicit signed/unsigned extension occurs before accumulation and at the
   XLEN result boundary.
3. **DOT4A associative sum.** For three or more register ports, add the
   accumulator as a fifth 32-bit operand rather than after a completed dot
   sum. The result still wraps modulo 2^32 and then sign-extends to XLEN.
   This follows ALGORITHMS-EXPERTS A85: one multi-operand reduction followed
   by carry propagation. The final model charges an extra 1.4 FO4 at the
   shared signed-product node, so the default row is 60.44 rather than the
   intermediate 59.04; the accumulator binding benefits by 7.44 FO4.
4. **Separate accumulator capture.** `dot_acc_ff` captures the third operand
   for accepted DOT4A, otherwise zero, outside the product/sign opcode
   branches. This removes nested decode from that field's capture. The
   register is consumed only in ST_DOT4; clearing it on other accepted IDLE
   operations changes dead state only. There are no new registers.
5. **Absent-port elaboration.** A generate branch supplies zero when
   `NrRgprPorts<3`; no RTL read of nonexistent `registers_i[2]` remains.

The old assertion that the one-cycle row was an immutable arithmetic floor
is superseded: removing row negation reduced it without another stage.

## Caller, lifetime and relocation review

`g6lc_ai_coprocessor` accepts on
`issue_valid && issue_ready && issue_resp.accept`, gates normal issue readiness
with `!exec_busy`, and directly publishes the registered execution result.
Its result-ready input is unused; this is not a generic backpressured result
channel. The current core consumer `cvxif_fu` ties result-ready high. Exec has
no kill input; this change adds no cancellation or commit handling.

For Dot4Stages=1, the result/valid/identity and PMU pulse remain at the issue
capture edge, with one accepted DOT4 per cycle. For Dot4Stages=2, products,
accumulator, signedness and hart/id/rd belong to one operation until ST_DOT4
completion at the next edge, with one accepted DOT4 every two cycles.
Asynchronous active-low reset discards pending completion. The default is 1.
The tests now check these exact contracts instead of eventual completion.

Relocation cards and parallel-timing classifications remain in each board.
The P10 same-edge contract bars automatic register insertion. The r27/r28
history and ALGORITHMS-EXPERTS A85/A132 favor changing arithmetic representation
before another temporal cut. No whole-module extraction was used to hide a
combinational chain: products, sums and result selection remain visible together.
The functional split here is the accumulator field's independently decoded
capture process, with the original state owner.

## Final path census and next useful work

One cycle, three ports: `pp -> signed row -> ps -> dot4_s_p -> dot4a_sum_s
-> result_n`, approximately 3.4 + 2.9 + 17.0 + 2.2 + 14.5 + 23.5 = 63.6 FO4.
The default two-port variant is 60.44 on DOT4A's no-accumulator result arm.
These remain opportunities, not proven physical floors.

Two cycles: the maximum has moved out of DOT4:

| Path | FO4 | Next strategy to evaluate |
|---|---:|---|
| ReLU index/read/write (`relu_c_w -> relu_c_idx -> relu_v -> relu_byte -> tiles_d`) | 34.10 | Separate bounded element-index formation from full-width validity checking; preserve non-aliasing of invalid indices. |
| Requant round/negate/select (`rq_bump -> rq_neg_rnd -> rq_adj`) | 32.27 | Examine the existing phase window and carry/select representation with a dedicated requant functional gate. |
| Accumulator-read result arm | 31.51 | Trace bank/read select and result publication together before any module extraction. |

Another DOT4 stage alone cannot reduce the 34.10 module maximum. Any future
split must report the complete connected path and carry operation identity,
validity, side effects and reset across its boundary.

## Verification and limits

`run_hyp8_ai_exec_local.sh` builds the existing leaf against the Hyp8 source
using WSL Verilator, with assertions. Build/simulation failures propagate;
the runner requires an exact PASS marker and rejects FAIL markers.
Logs and configuration identities: `logs/summary.txt`, `logs/sim-*.log`.

| Configuration | Checks | Result |
|---|---:|---|
| D4S=1, ports=2, XLEN=64 | 140145 | PASS |
| D4S=1, ports=3, XLEN=64 | 140189 | PASS |
| D4S=1, ports=4, XLEN=64 | 140189 | PASS |
| D4S=2, ports=2, XLEN=64 | 141715 | PASS |
| D4S=2, ports=3, XLEN=64 | 141767 | PASS |
| D4S=2, ports=4, XLEN=64 | 141767 | PASS |
| D4S=2, ports=3, XLEN=32 | 141767 | PASS |

Coverage includes all 65536 byte pairs against multiplication, mixed-lane
corners, 256 deterministic random pairs across S8/U8/DOT4A, 32-bit accumulator
wrap, changing live operands/identity during pending completion, reset while
pending, and a no-gap stream checking exact acceptance spacing, result cycle,
data, identity and side effects. Existing MMA signed/unsigned/F17 checks pass.
The incompatible enq-ready geometry test was not rerun.

The required `./build.sh verify --lint --sim --synth --target g6lc64_hyp8`
attempt did **not** pass. Lint/synthesis could not resolve the Hyp8 config
package because the generated flist points at production `core/include/`.
The unrelated CV64 smoke returned ISS rc=2 and the CV32 smoke timed out in
Spike; their root causes were not diagnosed. The complete gate log was not
retained, so these are recorded attempt outcomes, not qualification evidence.
The focused AI gate above is the functional evidence for this change.

Review checklist: no new clock, reset, latch, state width, parameter, memory
macro or DFT interface; simulation arithmetic assertions are translate-off;
existing result/PMU observability remains aligned. ISA encodings, configuration
selection and DTS/software contracts are unchanged. Extra flip-flop area is
zero; mapped area, power, fanout repair and physical timing are unmeasured.
Existing tier-R RTL and MIT bench/tooling notices are retained under the
Etienne Cimon contributor policy. The exec source's CRLF is normalized to LF;
`git diff --ignore-cr-at-eol` shows the semantic diff.

These are structural screening results. No OpenROAD, new Linux boot witness,
full-core qualification or 8-FO4 closure is claimed.
