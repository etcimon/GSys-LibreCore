# multiplier side-by-side harness (sv-timing A115)

Compares `core/multiplier.sv` built with `MultStages = 2` (the product as
XLEN/16 registered partial products and one final sum) against the same source
with `MultStages = 1` (the one-register multiplier), on random and corner
operands over MUL / MULH / MULHU / MULHSU / MULW / CLMUL / CLMULH / CLMULR;
the two-stage result, valid and trans_id must equal the one-stage ones one
cycle later, every cycle.

```
# flist: the defines/incdirs/packages of the sta-rtl portable flist + multiplier.sv + this tb
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-UNOPTFLAT --top-module tb_mul_sbs -f mul.f -j 8 && obj_dir/Vtb_mul_sbs +seed=1
```

Evidence of record: 3 seeds x 300k cycles, ~234k valid results per seed,
0 mismatches.

`tb_mul_lifetime` additionally instantiates the real `mult` wrapper and
checks fixed two-cycle valid/TID/data alignment, flush and cancellation,
mask removal, and TID reuse. Run this top with stock Verilator 5.008
(`--binary --timing --assert -O0`) including `mult.sv`, `serdiv.sv` and
`lzc.sv`. The preceding wrapper must fail the flush case as a negative
control; the changed wrapper must print `PASS tb_mul_lifetime checks=15`.

The isolated runner `verif/regress/remote/run_fo4_control_review.py` builds
both versions with `CONTROL_MODE=lifetime` and reruns the arithmetic
comparison on the same stock tool. The experimental A-fork failed the
directed harness's stimulus check; its outputs do not qualify this test.

## A128 — three stages

`+define+SVT_MUL_STAGES=3` builds the staged instance (and the lifetime
wrapper) at three stages; run `tb_mul_sbs` with `+lag=2`. `tb_mul_lifetime`
is a reference-model script since A128 (an operation issued at step k
emerges at step k + MultStages - 1 unless cancelled through emergence or
flushed) and prints `PASS tb_mul_lifetime stages=N checks=18` for N = 2
and 3; the pre-A115 wrapper still fails it at step 5.

A131: at three stages the second operand is sliced 8 bits wide (eight
(XLEN+1) x 9 products, `gen_sum8`); the same `+define+SVT_MUL_STAGES=3
+lag=2` run covers it (3 seeds x 300k, 0 errors).

A132 also tiles the first operand and carries two compressed rows through
the middle boundary at the same three-cycle latency. The lifetime witness
now cancels at every pipeline age and reuses the ID after clearing the mask
(39 checks at three stages). Optional `SVT_MUL_XLEN=32` and `SVT_MUL_RVB=0`
exercise source parameter variants; emitted RTL is qualified for the exact
specialization used to generate it. Arithmetic mismatches and vacuous output
counts now return a failing simulator exit code.

`run_fo4_control_review.py --profile multiplier` with remote
`CONTROL_MODE=mult-pipeline` compares immutable baseline/source snapshots,
and an optionally uploaded `multiplier__svt.sv`, using identical mapping and
separate boundary reports. `CONTROL_PLACE=1` adds placement/repair.
