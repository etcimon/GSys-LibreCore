# store_buffer side-by-side harness (sv-timing A109)

Compares the live `core/store_buffer.sv` against a reference copy of a prior
revision, cycle by cycle, under the module's legal environment.

```
git show <rev>:core/store_buffer.sv | sed 's/^module store_buffer\s*$/module store_buffer_old/' > store_buffer_old.sv
# reduced flist: the defines/incdirs/packages of the sta-rtl portable flist + the DUTs + this dir
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-UNOPTFLAT   --top-module tb_sb_sbs -f sb.f -j 8 && obj_dir/Vtb_sb_sbs +seed=1 [+dbg_from=N +dbg_to=M]
```

`wrap.sv` also carries the `assume`s and the `sb_miter_super` top for the yosys
bounded miter (`miter -equiv`, `sat -set-assumes -seq N`); the 8-step miter is
inconclusive within 50 min at the full XLEN=64 / PLEN=56 widths. Evidence of
record: 4 seeds x 400k cycles, 0 mismatches (215k pushes, 146k commits, 78k
cancel cycles, 9k flushes per seed).

A138 trial (reverted): a config-gated input stage was judged by a three-
instance shift witness (`tb_sb_stage.sv`, kept with the trial patch under
`sv-timing/architecture/trials/`): staged RTL, previous RTL with the staged
inputs delayed one cycle (state must match), previous RTL live (its forwarding
/ stall / readiness bound the staged outputs). Four 300k-cycle runs passed and
the gate-off RTL was cycle-exact here (2 × 400k); placement rejected the stage.

A120 refresh: use `--assert` on the stock Verilator semantic witness.
The harness now obeys the reference's clocked capacity/commit assertions,
drives the committing TID from the head, keeps scoreboard owners live and
drives legal CBO metadata. Wrapper assumptions are sampled before the edge;
`ready_o` is next-state capacity and is not a current-cycle acceptance test.
Queue depth and TID widths are configuration-derived. The A120 trial passed
400k cycles with zero mismatches and full occupancy at depth eight; the
gather rewrite was nevertheless rejected after it worsened placed timing.
Earlier four-entry stimulus is narrower historical evidence.
