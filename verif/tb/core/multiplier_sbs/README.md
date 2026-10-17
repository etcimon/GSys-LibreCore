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
