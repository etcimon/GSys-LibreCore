# CPU Pause/Drain Provider: Bounded C4 Slice

Native Storamic admission remains disabled. This slice qualifies a real-CPU
pause/drain-acknowledge handshake between the configured `cva6` commit path and
the Storamic AXI gate. It does not implement a memory, cache, fabric, transport
or persistence provider, and it does not by itself admit native execution.

## Contract

An external checkpoint/quiesce owner requests a pause through
`storamic_pause_i`. The core sideband then runs a fixed handshake:

- **Halt** — `storamic_halt` is gated by `storamic_pause_gated`
  (`core/cva6.sv:3432`, `origin_supported(CVA6Cfg)` only) and by the
  **AMO-head rule** (`core/cva6.sv:3434-3443`): `storamic_halt_q` sets only in a
  cycle where the commit head is not an AMO/LR/SC
  (`!storamic_amo_head`). Once halt is in effect a later AMO at the head is
  simply never started. This closes a real orphan: `commit_stage` only asserts
  `amo_valid_commit_o` under `!halt_i`, so pausing with an AMO already in
  `AMO_WAIT` withdrew `amo_req` from a miss unit whose atomic was still on the
  bus, deadlocking result propagation.
- **Drain acknowledgement** — `storamic_drained_o`
  (`core/cva6.sv:3452-3455`) certifies, in one cycle:
  `storamic_pause_q && halt_ctrl && no_st_pending_commit &&
   !(lsu_commit_commit_ex && !lsu_commit_ready_ex_commit) &&
   !(CVA6Cfg.DebugEn && set_debug_pc)`.
  `no_st_pending_commit` (`core/cva6.sv:3079`) is
  `no_st_pending_ex & dcache_commit_wbuffer_empty` — the store-buffer commit
  queue plus the D$ commit write buffer must both be empty, and no LSU
  operation may be stuck at the commit handshake (the same term
  `smt_drain_safe` uses). The middle term is the pause-specific guard the
  mutant campaign exercises.
- **Gate close** — the sequencer `g6lc_storamic_cpu_pause`
  (`corev_apu/storamic/g6lc_storamic_cpu_pause.sv`) walks
  Run→Halt→Close→Paused→Open1→Open2→Run. It asserts `gate_close_o` only after
  `core_drained_i`, and `paused_o` only when `paused_ok = core_drained_i &&
  gate_closed_i && !gate_inflight_i`. `error_o` is sticky fail-closed: once
  Paused, a dropped `core_drained_i` or a risen `gate_inflight_i` latches the
  error and freezes the FSM.
- **AXI boundary** — `g6lc_storamic_axi_gate` reports `closed_o` only when
  `close_i` is held, no AW/AR commit is registered, all saturating outstanding
  counters (`wr_cnt/rd_cnt/w_cnt`) are zero and `overflow_q` is clear. While
  closed, no downstream AW/AR/W valid may appear; owed B/R always pass.

## Two latent core defects this slice exposed and fixed

Both are real core bugs, independent of the pause logic itself; both were
found by the cpu-pause stage and fixed in `core/` (not the bench):

1. **AMO-head commit orphan** (`core/cva6.sv`): described above. Reproduced as
   a post-release deadlock (`CPU_PAUSE_FAIL timeout`, mutant k4 reverts the
   guard and must reproduce it).
2. **`load_unit` WAIT_PAGE_OFFSET fall-through** (`core/load_unit.sv`): for a
   non-cacheable narrow store still speculative, a wider load of the same lane
   saw `page_offset_matches_i` but, with `st_pipeline_busy==0` in the
   in-order single-hart config, fell through to `WAIT_GNT` after one cycle and
   re-issued to the D$ — reading stale memory. Any slow older instruction at
   the commit head exposes it; the pause only made the window reliable. Fixed
   for `!OoOEn && NrHarts==1` by holding `WAIT_PAGE_OFFSET` while
   `page_offset_matches_i` (the classic Ariane interlock). **OoO/SMT configs
   keep the old fall-through and rely on `st_pipeline_busy`/replay — that path
   is unaudited and is logged in `AGENTS-todo.md`.** The hyp8 tree was not
   ported.

## Changes Outside The Storamic Folders

Everything below lives in `core/`, `corev_apu/` (not `corev_apu/storamic/`) or a
non-Storamic bench, and is listed here so it can be reviewed apart from the
Storamic-owned files. The Storamic-owned pieces (`g6lc_storamic_axi_gate`,
`g6lc_storamic_cpu_pause`, their benches, formal and runners) sit under
`corev_apu/storamic/` and `verif/tb/storamic/`.

| File | Change | Effect when Storamic is not used |
|---|---|---|
| `core/controller.sv` | New input `halt_storamic_i`, OR-ed into `halt_o` next to `halt_csr_i`/`halt_acc_i`. | Tied 0 by the parent: `halt_o` unchanged. |
| `core/cva6.sv` | New ports `storamic_pause_i` / `storamic_drained_o`. The pause is gated on `g6lc_storamic_origin_supported(CVA6Cfg)`, latched into `storamic_halt_q` only when the commit head is not an AMO/LR/SC, and drives `halt_storamic_i`. `storamic_drained_o` is a registered AND of `halt_ctrl`, `no_st_pending_commit`, no stuck LSU commit handshake and no debug redirect. | Unsupported profile: pause ignored, the three flops stay 0. |
| `core/load_unit.sv` | `WAIT_PAGE_OFFSET` holds while `page_offset_matches_i` for `!OoOEn && NrHarts == 1` (defect 2 above). **This is a functional core fix, not a Storamic feature**: it applies to every in-order single-hart config. | Active regardless of Storamic; OoO/SMT configs unchanged. |
| `corev_apu/src/ariane.sv` | Passes the two ports through to `cva6` (both generate branches), re-gated on the supported profile. | Output tied 0. |
| `corev_apu/src/g6lc_core_hb.sv` | Pass-through of the two ports. | None. |
| `corev_apu/src/g6lc_cluster.sv` | Scalar sideband to core 0 only; ignored and `drained_o = 0` for `NR_CORES > 1` or an unsupported profile. | Inert. |
| `corev_apu/tb/ariane_testharness.sv` | Cluster ports tied off (`pause = 0`, `drained` open: the native binding is C6 work). Bench-only `G6LC_XBAR_LATENCY` define for the C2 latency sweep and the `STORAMIC_C2_PROFILE` report line under `+storamic_c2_report`. | Without the define and plusarg: identical elaboration. |
| `corev_apu/altera/src/cva6_altera.sv`, `corev_apu/fpga/src/ariane_xilinx.sv`, `corev_apu/openpiton/ariane_verilog_wrap.sv`, `corev_apu/tb/ariane_gate_tb.sv` | Tie-offs of the two new `ariane` ports. | None. |
| `verif/tb/core/tb_g6lc_ctrl.sv`, `tb_g6lc_rtl_review.sv`, `tb_g6lc_hyp8_control.sv`, `verif/tb/g6lc_ara_lint_top.sv`, `g6lc_cluster_lint_top.sv`, `verif/tb/uvmt/cva6_tb_wrapper.sv` | Tie-offs of `halt_storamic_i` or of the two new ports. | None. |

Timing: one extra OR term into `halt_o`; `storamic_drained_o` and the halt
latch are registered from existing status signals, so no new combinational
cone reaches the commit path. The `load_unit` change adds one term to an
existing next-state priority chain. No new clock, reset, latch or memory.

## Verification And Identity

Remote-only, content-addressed snapshot `storamic-a5e1324652e8` (real `cva6`,
`StoramicCheckpointEn=1`, delay 0/16, seeds {1,7}, bus back-pressure tiers
`+wstall/+rstall` ∈ {0, 24/8, 48/8}). Oracles: o1 no downstream AW/AR/W valid
while `paused_o`; o2 bench memory equals an RVFI-retire reference (committed
stores only, AMO/SC included) sampled while paused; o3 `error_o` never; o4
final memory signature identical to a never-paused reference.

- **12 positive cases all pass**, signature `d17673a511d1877b`, 1463–2616
  pauses each (≥40 required), including the deepest `+wstall=48 +delay=16`
  tier where committed stores saturate the `DEPTH_COMMIT=4` queue.
- **All five mutants killed**, none survived:
  k1 (drop `no_st_pending_commit`) → o2 dirty; k2 (gate `closed_o` ignores
  counters) → o3 `error_o`; k3 (Halt→Paused skip Close) → o3 `error_o`;
  k4 (revert AMO-head guard) → timeout deadlock; k5 (revert load_unit
  interlock) → trap.
- **Directed `+nopause` regression** reproduces the load_unit hazard with a
  `divu` commit-head blocker and no pause: fixed RTL passes at delay 0 and 16;
  the k5 copy is rejected at both — proving the defect is pre-existing and
  pause-independent.
- A 12-store-per-iteration burst phase was added to the program specifically
  to hold several committed stores without AW-valid across a B return; that is
  what makes k1 observable (o2 dirty at a burst lane).

Core-RTL regression on the same tree `storamic-72a94e83a5b7` passes all five
stages (`core-scc` 0 SCC/0 latch; `cpu-strict-pins` observed==pinned, no new
UNOPTFLAT; `cpu-origin`, `cpu-debug`, `native-c2` incl. m1–m6). Remote unit
suite totals are recorded in the run receipt.

## What This Does Not Provide

- No memory, cache, fabric, transport, DMA or persistence provider; the gate
  only bounds the CPU's AXI boundary during a pause window.
- No checkpoint record, no state save/restore, no durability — those remain
  C3/C5/C6 scope.
- Native admission stays refused; `origin_supported` gating keeps the
  sideband inert in unqualified configurations, and default-off behavior is
  preserved.
