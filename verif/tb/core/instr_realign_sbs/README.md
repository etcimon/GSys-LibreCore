# instr_realign side-by-side harness (sv-timing A110)

Compares the live `core/fetch_B/instr_realign.sv` (parallel-prefix visits)
against a reference copy of the serial-walk revision, cycle by cycle, on random
halfword streams with mostly sequential fetch blocks (split RVIs carry).

```
git show aead1aa25:core/fetch_B/instr_realign.sv | sed 's/^module instr_realign\s*$/module instr_realign_old/' > instr_realign_old.sv
# flist: the defines/incdirs/packages of the sta-rtl portable flist + both DUTs + this tb
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-UNOPTFLAT   --top-module tb_rl_sbs -f rl.f -j 8 && obj_dir/Vtb_rl_sbs +seed=1
```

Evidence of record: 3 seeds x 500k cycles, ~162k carries per seed, 0 mismatches
on all nine outputs.
