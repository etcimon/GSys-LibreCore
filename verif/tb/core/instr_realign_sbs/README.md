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

A134 compares against `62c00081a`, before continuation caching. The test checks
both the packet consumed at the clock edge and the settled post-edge outputs.
It drives legal hart indices, keeps a continuation stream per hart, and includes
directed even/odd address-wrap cases.

Optional leaf overrides are `SVT_RL_WIDTH`, `SVT_RL_HARTS`, `SVT_RL_VLEN`,
`SVT_RL_RVC` and `SVT_RL_SLOTS`. The boundary-review profile runs five
configurations for 500k cycles each, including 32-bit VLEN overflow, full-64-bit
wrap, reduced slot capacity and RVC off. Accepted splits and completions must
both occur in RVC-enabled tests.

Use `run_fo4_control_review.py --profile boundary` with remote
`CONTROL_MODE=boundary-surface`. `CONTROL_SURFACE_MODULE=instr_realign` restricts
the surface run to this leaf. Its negative control truncates the stored successor
to VLEN and disables RTL assertions; the interface comparison must still fail.
