# Storamic hyp8 Port Ledger

Purpose: when the non-hyp8 Storamic implementation is finished, this file is
the work list for carrying it into the hyp8 redesign trees
(`build-platform/workspace/hyp/hyp_redesign_core_8fo4`,
`.../hyp_redesign_corev_apu_8fo4`). It lists every Storamic-driven change that
lives **outside** the Storamic-owned folders, because those are the edits that
cannot be copied and must be re-implemented against the hyp8 structure.

Rules that keep the port cheap:

- Storamic-owned folders (`g6lc_storamic/`, `corev_apu/storamic/`,
  `verif/tb/storamic/`, `verif/tests/custom/storamic/`) are shared by both
  trees and need no port. Put new logic there whenever possible.
- A change in `core/` or `corev_apu/` outside those folders goes in its own
  commit, separate from Storamic-folder changes, and gets a row here in the
  same commit series.
- Hooks are narrow and config-gated (`StoramicEn`, `StoramicIoEn`,
  `StoramicCheckpointEn`, `g6lc_storamic_origin_supported`), inert when off.
- Generic core fixes found through Storamic are marked **fix**; they are owed
  to hyp8 regardless of whether Storamic is ever enabled there.

Status as of 2026-11-12: the hyp8 trees contain **no** Storamic hook
(`grep -ci storamic` is 0 in every hyp8 file listed below). Only the generic
fixes marked "ported" are present.

## 1. Configuration surface

| Main-tree file | Content | hyp8 counterpart | Status |
|---|---|---|---|
| `core/include/config_pkg.sv` | `StoramicEn`, `StoramicCheckpointEn`, `StoramicIoEn` in user and derived cfg; `g6lc_storamic_origin_supported()`; `g6lc_storamic_data_prot()`; `check_cfg` asserts `STORAMIC_CORE_AXI_GEOMETRY`, `STORAMIC_ROLE_NORMALIZE`, `STORAMIC_CHECKPOINT_PRIMARY_REQUIRED` | `core/include/config_pkg.sv` (hyp8 copy) | not ported |
| `core/include/build_config_pkg.sv` | Field propagation; `G6LC_STORAMIC` / `G6LC_STORAMIC_IO` defines | hyp8 copy | not ported |
| `core/include/*_config_pkg.sv` (all targets) | `StoramicEn: 0`, `StoramicCheckpointEn: 0` defaults | hyp8 target packages | not ported |
| `corev_apu/include/g6lc_storamic_soc_cfg_pkg.sv` | SoC-level Storamic parameters | absent in hyp8 | not ported (copy) |

Port first: nothing else elaborates without these fields. The origin-supported
predicate must be re-derived for hyp8, not copied: it names the qualified
profile (one hart, in-order, WT cache), and hyp8's pipeline is a different
qualification target.

## 2. CPU access-origin transport (C1)

Carries privilege/debug origin on AXI `prot` for data accesses when
`StoramicCheckpointEn` is set; `prot` stays `000` otherwise.

| Main-tree file | Hook | hyp8 counterpart | Status |
|---|---|---|---|
| `core/load_store_unit.sv` | `gen_data_origin`: computes `data_prot` via `g6lc_storamic_data_prot` (unknown in debug mode, for AMO/LR/SC, and in unsupported profiles) | `core/load_store_unit.sv` | not ported |
| `core/store_unit.sv`, `core/store_buffer.sv` | origin field carried with each store through speculative and commit queues | same names; hyp8 store buffer is restructured (`fwd_hold` pipeline, `sb_lifecycle.sv`) | not ported |
| `core/load_unit.sv` | origin carried with the load request | same name | not ported |
| `core/cache_subsystem/wt_dcache_ctrl.sv`, `wt_dcache_missunit.sv`, `wt_dcache_wbuffer.sv`, `wt_axi_adapter.sv` | origin carried through D$ read, miss and write-buffer paths to the adapter | same names; hyp8 write buffer has the W1 pipelined accept | not ported |
| `core/axi_shim.sv` | drives `aw.prot` / `ar.prot` from the carried origin | same name | not ported |
| `core/cva6.sv` | top-level wiring of the above | `core/g6lc_core.sv` | not ported |

Qualification to repeat on hyp8: `cpu-origin`, `cpu-origin-atomic`,
`cpu-origin-unsupported`, `cpu-debug*`, `origin-profile`, `origin-queue`
(`verif/tb/storamic/`). Every extra queue or pipeline register hyp8 adds on a
load/store path needs the origin field and its own queue-class case.

## 3. CPU pause/drain provider (C4)

Contract and evidence: `cpu-pause-provider.md`.

| Main-tree file | Hook | hyp8 counterpart | Status |
|---|---|---|---|
| `core/controller.sv` | input `halt_storamic_i`, OR-ed into `halt_o` | `core/controller.sv` | not ported |
| `core/cva6.sv` | ports `storamic_pause_i` / `storamic_drained_o`; profile gate; `storamic_halt_q` latch that refuses to start a halt with an AMO/LR/SC at the commit head; registered drain acknowledgement from `halt_ctrl`, `no_st_pending_commit`, LSU commit handshake, debug redirect | `core/g6lc_core.sv` | not ported |
| `corev_apu/src/ariane.sv` | port pass-through, profile re-gate | absent in hyp8: `g6lc_core_hb.sv` wraps the core directly | n/a (fold into `g6lc_core_hb`) |
| `corev_apu/src/g6lc_core_hb.sv` | port pass-through | same name | not ported |
| `corev_apu/src/g6lc_cluster.sv` | scalar sideband to core 0; inert for `NR_CORES > 1` or unsupported profile | same name | not ported |
| FPGA/OpenPiton/gate wrappers, lint tops, `cva6_tb_wrapper.sv`, controller benches | tie-offs | hyp8 equivalents of each instantiation | not ported |

hyp8-specific design points, to settle before porting:

- The drain predicate lists the main tree's commit-side state. hyp8 has more
  (LSQ `g6lc_lsq.sv`, `sb_lifecycle`, pipelined write buffer, loop buffer);
  each needs an explicit empty term, proven by a k1-style mutant that leaves
  dirty state behind.
- The AMO-head guard depends on how hyp8's miss unit holds an atomic in
  flight; re-derive it and keep the k4 deadlock mutant.
- `halt_o` is on hyp8's timing-critical control path; the extra OR term needs
  an FO4 check, not an assumption.

Qualification to repeat: `cpu-pause` (12 positive cases, mutants k1–k5),
`axi-gate-formal`.

## 3a. CPU resume synchronization (C5)

Contract: `cpu-pause-provider.md` (resync on release). Runs when a pause that
replaced RAM is released: flush D-cache, invalidate I-cache, squash to the
commit head, clear LR/SC reservations, then acknowledge.

| Main-tree file | Hook | hyp8 counterpart | Status |
|---|---|---|---|
| `core/controller.sv` | Storamic D-cache flush request/ack and squash inputs, folded into the existing flush outputs | `core/controller.sv` | not ported |
| `core/cva6.sv` | resync FSM between pause release and core un-halt; `resync_squash` redirect to the commit head | `core/g6lc_core.sv` | not ported |
| `core/fetch_B/frontend.sv`, `core/fetch_A/frontend/frontend.sv` | `commit_step_i`: lets the commit-source redirect advance the architectural PC while `halt_i` is held, otherwise the head block is fetched twice | hyp8 `fetch_B` frontend | not ported |
| `corev_apu/src/g6lc_axi_lrsc.sv`, `g6lc_axi_atomics_wrap.sv` | `res_clr_i`: drop every reservation (clear wins over a same-cycle LR) | same names | not ported |

hyp8-specific design points: the squash must also empty hyp8's LSQ and loop
buffer; the frontend redirect-under-halt case must be re-derived for hyp8's
fetch pipeline rather than copied. Qualification to repeat: `cpu-pause` C5
cases with mutants r1–r4, and `native-ckpt` mutants n2–n4.

## 3b. Native checkpoint composition (C3/C6)

Contract: `native-composition.md`. All logic is in `corev_apu/storamic/`
(`g6lc_storamic_native_ckpt`, `g6lc_storamic_native_providers`, `attach`); the
outside-folder surface is wiring only.

| Main-tree file | Content | hyp8 counterpart | Status |
|---|---|---|---|
| `corev_apu/include/g6lc_storamic_soc_cfg_pkg.sv` | `ckpt_plat_in_t`, `ckpt_plat_out_t`, `ckpt_events_t` platform boundary structs | absent in hyp8 | not ported (copy) |
| `corev_apu/src/g6lc_ai_dram_backend.sv` | attach checkpoint ports tied off (native profile instantiates the attach from the harness) | same name | not ported |
| `corev_apu/tb/ariane_testharness.sv` | native attach binding, provider/pause/quiesce wiring for CPU, debug and VirtIO, reservation clear, `STORAMIC_CKPT_STATE` report, sim triggers | `corev_apu/tb/g6lc_testharness.sv` | not ported |
| `corev_apu/tb/g6lc_tb.cpp` | deferred preload into the native endpoint RAM on `boot_ready`, `+storamic_ckpt_report`, `+storamic_sba_ctrl` | hyp8 C++/SV driver | not ported |
| `Makefile` | source list and defines | hyp8 build lists | not ported |

The boot recovery agent (`g6lc_storamic_boot_recovery`, C6b) is inside
`g6lc_storamic_native_ckpt` and needs no port; outside the folder it adds only
the bench power-cycle trigger (`StoramicBase + 0x3078`, a reset term on the
harness `rstgen`) and the `CkptBootRecovery` attach parameter.

Qualification to repeat: `native-ckpt` (cases and mutants n1-n8).

## 4. Generic core fixes found through Storamic

| Fix | Main-tree file | hyp8 status |
|---|---|---|
| Write-buffer merge keeps tag-check result | `core/cache_subsystem/wt_dcache_wbuffer.sv` | ported (`d465cc28c`) |
| LR→SC window holds plain stores only | `core/issue_read_operands.sv` | ported (`d465cc28c`) |
| No store→load forward for non-cacheable loads | `core/store_buffer.sv` | **not ported**: `fwd_hold` pipeline and plain branch both need the gate |
| No merge of a non-cacheable store into a live write-buffer entry | `core/cache_subsystem/wt_dcache_wbuffer.sv` | **not ported**: W1 pipelined accept and plain path |
| CSR temporaries without defaults (real combinational loops) | `core/csr_regfile.sv` | ported (`4f65b65b9`) |
| False-loop cuts: scoreboard issue pointer, PTW leaf update, miss-unit `mem_req`, instruction-queue admission, I-cache split | `core/scoreboard.sv`, `core/cva6_mmu/cva6_ptw.sv`, `wt_dcache_missunit.sv`, `instr_queue.sv`, `g6lc_icache.sv` | ported (`4f65b65b9`) |
| I-cache `ready` on its own wire | `core/cva6.sv`, cache subsystems, frontends | not ported (no warning reduction; optional) |
| Store-buffer commit+flush assertions | `core/store_buffer.sv` | ported, lint only; not simulated |
| `load_unit` `WAIT_PAGE_OFFSET` holds while the page-offset match is live (`!OoOEn && NrHarts == 1`) | `core/load_unit.sv` | **not ported** |
| `load_unit` in-order multi-hart hold (`LuSmtHold`): held while the match can still be an older store (load not yet the commit head, or a commit-queue/write-buffer/sticky match); released once the load is the commit head and only speculative entries match. Elaborated only with a Storamic role (`StoramicEn || StoramicIoEn`); every other build is unchanged and keeps the hazard | `core/load_unit.sv` | **not ported**. hyp8 must re-derive it against its LSQ/`sb_lifecycle`; decide there whether to drop the Storamic gate |
| OoO `load_unit` path audited, no change: `st_pipeline_busy` (`SpeculativeSb && SuperscalarEn`) holds an uncovered match until the store buffer and write buffer are empty or the load is replayed; `g6lc64_ooo` passes `storamic_lu_hazard.c` | `core/load_unit.sv` | n/a (repeat the test on hyp8) |
| Trigger module: address trigger enters debug with cause 3; store/load trigger lost on a squashed instruction | `core/trigger_module.sv` | open in both trees (`AGENTS-todo.md`) |

## 5. SoC and harness integration

| Main-tree file | Content | hyp8 counterpart | Status |
|---|---|---|---|
| `corev_apu/src/g6lc_cluster.sv` | Storamic DMA write-invalidation writer on the CMO engine (`storamic_dma_inval_*`, `StoInval`) | same name | not ported |
| `corev_apu/src/g6lc_ai_dram_backend.sv` | Storamic attach parameters and control/IRQ ports | same name | not ported (only the DRAM-delay knob is) |
| `corev_apu/tb/ariane_soc_pkg.sv` | `StoramicBase` 0x5000_0000, lengths, IRQ sources 10/11 | `corev_apu/tb/g6lc_soc_pkg.sv` | not ported |
| `corev_apu/tb/ariane_peripherals.sv` | PLIC sources 10/11 | `corev_apu/tb/g6lc_peripherals.sv` | not ported |
| `corev_apu/tb/ariane_testharness.sv` | Crossbar window and checkpoint route, VirtIO device, model stick, DMA on port 2, C2 monitor bind and origin probe, `G6LC_XBAR_LATENCY`, `STORAMIC_C2_PROFILE`, sim power-cut/save/restore triggers | `corev_apu/tb/g6lc_testharness.sv` | not ported |
| `corev_apu/tb/g6lc_tb.cpp` | Preload window, DMI SBA probe (`preload_aware_dtm_t`) | hyp8 uses `g6lc_tb.sv`; C++ driver differs | not ported |
| `Makefile`, `corev_apu/storamic/Flist.storamic_soc` | Source lists | hyp8 build lists (`verif/regress/remote/hyp8/`) | not ported |

Qualification to repeat: `native-c2`, `native-c2-wide`, `native-virtio`, the
checkpoint-route stages, then the C3–C6 native composition stages once they
exist in the main tree.

### 5a. Non-checkpoint fixes (2026-11-13)

All three are elaborated only with a Storamic role; a build without one is
textually or structurally identical to before (`native-fixes` checks this).

| Main-tree file | Content | hyp8 counterpart | Status |
|---|---|---|---|
| `corev_apu/tb/ariane_testharness.sv` | **AI island port + Storamic storage.** Under `G6LC_AI_DRAM_ISLAND_PORT`, crossbar port 2 is driven from `ai_dma_sh_req` (as in the non-island build) with upstream sharer `p2_up` = the `G6LC_APU` compositor DMA or idle. With the Storamic IO role, `g6lc_storamic_dma_axi` time-shares the port with `p2_up`; without it `ai_dma_sh_req = p2_up` (same values as the old explicit tie-off / APU assignment). `vd_usable` is no longer forced to 0. Also removes a second driver of `ai_dma_resp` in island builds without Storamic | `corev_apu/tb/g6lc_testharness.sv` (port-2 sharing) | not ported |
| `corev_apu/tb/ariane_testharness.sv` | **Debug `sbcs.sberror`.** `dm_top`'s DMI port goes through `dm_dmi_*`; `gen_dmi_sberror` (only `if (CVA6Cfg.StoramicIoEn)`) inserts `g6lc_storamic_dmi_sberror` fed by the SBA AXI master's error responses, otherwise the wires are assigned straight through. The vendored `corev_apu/riscv-dbg` submodule is not modified | hyp8 instantiates its own `dm_top` in `g6lc_testharness.sv` / `g6lc_soc.sv`; the shim itself is in `corev_apu/storamic/` and needs no port | not ported |
| `corev_apu/tb/g6lc_tb.cpp` | SBA probe also checks that a set `sberror` blocks the next trigger and clears on W1C (`blocked_sberror`, `cleared_sberror`) | hyp8 driver | not ported |
| `Makefile` | `g6lc_storamic_dmi_sberror.sv` in the testharness source list (after `dm_pkg`) | hyp8 build lists | not ported |

Qualification to repeat: `native-fixes`, and the SBA cases of `native-c2` and
`native-ckpt`.

### 5b. Checkpoint widening W0 + W1: single-core L2/L3 (2026-11-22)

Refusal gaps closed in `g6lc_storamic_origin_supported` (`NrCores <= 1`,
`!AiCfg.MatrixEn`, `!ServerPrefetchEn`), and L2/L3 below one in-order WT hart
implemented and qualified (`storamic-c53a18704013`, `origin-profile` +
`native-ckpt-l2l3`). All pause/quiesce/inval-all inputs tie to `0` when
Storamic is off; `AxPROT` bypass preservation is an AXI4 fix that carries
`3'b000` in every non-Storamic build.

| Main-tree file | Content | hyp8 counterpart | Status |
|---|---|---|---|
| `core/include/config_pkg.sv` | `g6lc_storamic_origin_supported`: adds `NrCores <= 1`, `!AiCfg.MatrixEn`, `!ServerPrefetchEn` | hyp8 `core/include/config_pkg.sv` | not ported |
| `core/include/build_config_pkg.sv` | `G6LC_STORAMIC_L2` / `G6LC_STORAMIC_L3` qualification overlays (auto-infers L2/L3 geometry + `WtAxiAllocEn`, `L2PostedWriteEn`, `L2WriteUpdateEn`, `L2CmoEn`, `L2PrefetchEn`, and under L3 `L2TagSramEn`/`L3InclusiveEn`/`L3PrefetchEn`) | hyp8 `build_config_pkg.sv` | not ported |
| `core/include/*_config_pkg.sv` (30 pkgs) | Backfill the 11 `RVZimop..RVZabha: bit'(0)` fields missed by commit `89d3dadd0` (generic build fix, not Storamic-specific) | check hyp8 target packages | not ported |
| `corev_apu/l2_cache/g6lc_l2_tag.sv` | `inval_set_i` / `inval_set_index_i`: clears all ways' valid (and `pf_q`) bits in one set per cycle in both `gen_tag_flop` and `gen_tag_sram` (no 32K-flop synchronous clear fanout) | hyp8 `corev_apu/l2_cache/g6lc_l2_tag.sv` | not ported |
| `corev_apu/l2_cache/g6lc_l2_top.sv` | Bypass `AxPROT` capture/forwarding (`prot_q` on `S_BYPASS_AR`/`S_BYPASS_AW`; cacheable fills keep `3'b000`); `l2_quiesce_i` (suppresses `g6lc_l2_pf`), `l2_block_slv_i` (blocks new slave AR/AW once core drained), `l2_idle_o` (full idle: write-idle + `S_IDLE` + MSHRs/rdtrk/bfid/wr_inval/pf_probe/inval_all empty), `l2_inval_all_i` / `l2_inval_all_done_o` (1-set/cycle walk once idle) | hyp8 `corev_apu/l2_cache/g6lc_l2_top.sv` | not ported |
| `corev_apu/l3_cache/g6lc_l3_top.sv` | Pass-through of `l3_quiesce_i`, `l3_block_slv_i`, `l3_idle_o`, `l3_inval_all_i`, `l3_inval_all_done_o` | hyp8 `corev_apu/l3_cache/g6lc_l3_top.sv` | not ported |
| `corev_apu/src/g6lc_cluster.sv` | `gen_sto_llc_resync` (when `STO_PAUSE_EN && HAS_LLC`): quiesces L2/L3 prefetchers during pause, blocks new L2 slave AR/AW once core 0 drains, includes `l2_all_idle && l3_all_idle && !incl_inv_busy` in `storamic_drained_o`, and on release holds core 0 paused while L2 and L3 walk all sets in parallel before core 0's C5 L1 resync runs | hyp8 `corev_apu/src/g6lc_cluster.sv` | not ported |
| `corev_apu/tb/ariane_testharness.sv` | `llc_invals` / `l2_hits` / `l3_hits` in `STORAMIC_CKPT_STATE`, copy-phase `llc_not_idle` independent oracle | hyp8 `corev_apu/tb/g6lc_testharness.sv` | not ported |
| `verif/tb/g6lc_uncore_lint_tops.sv`, `verif/tb/l2/*.sv`, `verif/tb/l2/formal/g6lc_l2_top_fpv.sv` | Tie-offs for the new L2/L3/tag ports (Verilator 5.008 rejects default values on module inputs) | hyp8 equivalents if any | not ported |

hyp8-specific design notes for W1:
- `g6lc_l2_top` / `g6lc_l2_tag` / `g6lc_l3_top` are structurally close to hyp8's copies; check whether hyp8's L2 has any extra pipeline stage on `S_IDLE`/`S_TAG` before porting `l2_idle_o` and `prot_q`.
- `ServerPrefetchEn` remains refused in `g6lc_storamic_origin_supported` until `g6lc_server_prefetcher.sv` receives a `quiesce_i`/`pf_idle_o` port (deferred to avoid colliding with another session's uncommitted fix there).

Qualification to repeat: `origin-profile`, `native-ckpt-l2l3` (7 cases + mutants `w1-no-l2-inval`, `w2-no-l3-inval`, `w3-no-l2-prot`).

### 5c. hyp8 native checkpoint composition port (2026-11-23, in qualification)

The W0–W2c native checkpoint path is wired into the hyp8 MC build behind
`HYP8_STORAMIC_CKPT=1` (`-DG6LC_STORAMIC_CKPT -DG6LC_STORAMIC_MODEL`,
`-DG6LC_STORAMIC_CKPT_TB` on the C++ side). Evidence run:
`hyp8-storamic-aggregate-t1` (closure `closure-mc-storamic`, PGO g6lc
fork); directed grading via `verif/regress/remote/run_hyp8_storamic_ckpt.py`
mirroring `run_native_ckpt.py` (10 cases: boot/flow/oracles, provider
negatives, cold recovery, dual-active mh).

| hyp8 file | Content | Status |
|---|---|---|
| `corev_apu/tb/g6lc_testharness.sv` | `ifdef G6LC_STORAMIC_CKPT` native composition: bench triggers (`StoramicBase+0x3040..0x3078`), `g6lc_storamic_native_providers`, packed `ckpt_plat_in_t/out_t`, `g6lc_storamic_attach` with `CheckpointRequested/NativeBound/CkptBootRecovery`, pause/quiesce/restore-safe wiring, `STORAMIC_CKPT_STATE` final report, L2/L3/LLC hit counters. The ordinary `g6lc_ai_dram_backend` is instantiated only in the `else` arm | ported, lint-clean (scalar/smt2/mc `%Error: 0`), build qualification in progress |
| `verif/regress/remote/hyp8/Flist.hyp8_mc_sim` | Full Storamic package+RTL set (cfg/checkpoint/pad pkgs, controller/IO/media/service/policy, AXI frontend+slot mux, discovery, VirtIO host, `g6lc_storamic_top`, soc cfg pkg, all `corev_apu/storamic/` attach/native/boot-recovery modules) ahead of `g6lc_ai_dram_backend` | ported |
| `verif/regress/remote/hyp8/Flist.hyp8_sim` | `g6lc_storamic_pkg.sv` added before `g6lc_ai_dram_backend`/`g6lc_testharness` (they reference `axil_req_t`/`axil_resp_t` unconditionally) | ported |
| `verif/regress/remote/hyp8/hyp8_tb.cpp` | `MEM` macro `G6LC_STORAMIC_CKPT_TB` arm pointing at `i_ckpt_attach__DOT__gen_native_ckpt__DOT__i_native_ckpt__DOT__endpoint__DOT__gen_model__DOT__media__DOT__i_ram__DOT__i_sram__DOT__…m_storage` (the `sram`/`tc_sram` `public_flat` array, same suffix as `gen_sim_axi`); deferred `ckpt_image` preload on `storamic_ckpt_boot_ready` (`+ckpt_preload_max`); plusargs `storamic_ckpt_report/trace` allowlisted; `MEM_USER` block fenced off (no user-bit memory in ckpt/model compositions) | ported |
| `verif/regress/remote/hyp8/hyp8-build-harness.sh` | `HYP8_STORAMIC_CKPT=1` adds the three defines + `-DG6LC_STORAMIC_MODEL` (without it `make_cfg` yields `ProfileOff`→`gen_refuse`, no `gen_model`); `HYP8_STORAMIC_MODEL=0` is the A/B escape; `HYP8_STORAMIC_CKPT_WORDS` optional | ported |
| `verif/regress/remote/run_hyp8_storamic_ckpt.py` | New directed runner (firmware matrix, state-line grading, provider negatives) | added |
| `verif/regress/remote/run_hyp8_integration.py` | Non-resume builds now `rmtree(out/'model')` before verilating — a same-tag rerun otherwise hits `g6lc_hyp8_tuning.py` "generated source … changed; use a fresh Mdir" because the packed-tiled manifest identity covers the verilator command | fixed |

Also already present in hyp8 (verified while porting): `g6lc_soc_pkg`
`Storamic=11`/`StoramicBase=0x5000_0000`/`StoramicLength=0x4000`, the
`gen_storamic_ctrl` block and `STORAMIC_IDX` xbar rule under
`G6LCCfg.StoramicIoEn`, and the bench trigger decode on
`gen_storamic_ctrl.storamic_axi_req.aw.addr`.

Not yet ported (still open): `ariane_soc_pkg` PLIC IRQ sources 10/11 wiring
to `g6lc_peripherals`, `G6LC_XBAR_LATENCY`, `STORAMIC_C2_PROFILE`
monitor bind, DMI `sbcs.sberror` shim in the hyp8 `dm_top` path, C2 origin
probe, `+storamic_sba_ctrl`/`+storamic_sba_probe` C++ probes (ariane-only;
the debug-command-refused case is skipped on hyp8), W1 `G6LC_STORAMIC_L2/L3`
qualification overlays in hyp8 `build_config_pkg.sv`, and the section-4
`load_unit`/`store_buffer` items marked not-ported above.

### 5d. Checkpoint widening W2: in-order multi-hart / multi-core (2026-11-23, in qualification)

Committed as `283db4303` (core/corev_apu) + `d7881eadf` (Storamic
verification). Widens `g6lc_storamic_origin_supported` to in-order WT
multi-core and drained-handoff SMT (`NrHarts == 1 || SmtDrainedHandoff`);
mixed-residency SMT, OoO, RVH, WB, AI island and `ServerPrefetchEn` remain
refused. Remote evidence in progress: `storamic-837c36f99341` (SMT2/SMT2+L3
cases pass; `ckpt-mc2` cases failed on a config assertion — fixed by the
`build_config_pkg.sv` row below, rerun pending).

| Main-tree file | Content | hyp8 counterpart | Status |
|---|---|---|---|
| `core/include/config_pkg.sv` | `g6lc_storamic_origin_supported`: admits `NrCores>1` in-order WT and `SmtDrainedHandoff` SMT | hyp8 `core/include/config_pkg.sv` | not ported |
| `core/include/build_config_pkg.sv` | `G6LC_STORAMIC_MC2` overlay (NrCores=2 + coherence hub + L2 feature plane); snoop-filter default now reads effective `cfg.SnoopFilterEn` so the overlay's `En=1` gets the 64-per-core entries default instead of being reset to the package's 0 | hyp8 `build_config_pkg.sv` | not ported |
| `core/controller.sv` | `resync_storamic_nopc_i`: a core parked in WFI or SMT drain-quiesce with an empty scoreboard flushes IF/ID/EX + I-cache without `set_pc_commit_o` instead of wedging in `RESYNC_WAIT_HEAD` | hyp8 controller equivalent | not ported |
| `core/cva6.sv` | Resync FSM: WFI/SMT-drain nopc path; `i_smt_thread_select`/`smt_drain_safe` frozen during pause/resync; `storamic_drained_o` gated on `!smt_switch`; `storamic_resync_i` threaded to the store path; decode-validity gate during `RESYNC_WAIT_HEAD` | hyp8 `g6lc_core.sv` (name mapping unverified) | not ported |
| `core/ex_stage.sv`, `core/load_store_unit.sv`, `core/store_unit.sv`, `core/store_buffer.sv` | `storamic_resync_i` evicts all speculative stores including `LEGACY_SMT_KEEP` `fwd_keep` entries (with assertion) | hyp8 store-buffer/LSU equivalents | not ported |
| `corev_apu/coherence/g6lc_coherence_hub.sv` | `hub_block_slv_i` + `hub_idle_o` (AR/AW/W/hold/inval-bus empty) | hyp8 coherence hub | not ported |
| `corev_apu/src/g6lc_cluster.sv` | Pause/resync fanned to all NC cores; `storamic_drained_o` requires every core drained plus `hub_all_idle` | hyp8 `corev_apu/src/g6lc_cluster.sv` | not ported |
| `corev_apu/tb/ariane_testharness.sv`, `verif/tb/core/*.sv`, `verif/tb/{l2,uncore}/` | W2 tie-offs for new ports | hyp8 `g6lc_testharness.sv` + bench equivalents | not ported |

hyp8-specific design notes for W2:
- hyp8 has SMT2 (`g6lc64_hyp8_smt2`) and MC (`hyp8_mc`) profiles, so the
  per-hart/per-core fan-out has real targets; the `g6lc_core.sv` mapping
  for `cva6.sv` resync logic is unverified — read before porting.
- `SmtDrainedHandoff` semantics in hyp8's SMT switch may differ; the
  `!smt_switch` drain gate and frozen `smt_drain_safe` need re-derivation,
  not copy-paste.
- The `fwd_keep`/`LEGACY_SMT_KEEP` store-buffer entries are the highest-risk
  port: hyp8's store buffer was restructured; verify retained-entry
  eviction semantics before qualifying.

Qualification to repeat: `origin-profile`, `origin-queue`,
`stq-commit-flush`, `native-ckpt-w2` (SMT2, SMT2+L3, `G6LC_STORAMIC_MC2`
flow/dual-active/cold/oracle + mutants `w4-no-core1-pause`,
`w5-no-smt-l2-inval`).

## 6. Suggested port order

1. Section 1 (config), with every hook still absent: hyp8 must elaborate and
   pass its smoke tests unchanged.
2. Outstanding generic fixes from section 4.
3. Section 5 with the IO role only (`StoramicIoEn`), then the primary role.
4. Section 2, then section 3, each with its mutants.
5. C3–C6 composition, after it is qualified in the main tree.

Update a row's status in the same commit that ports it, with the remote run
tag as evidence.
