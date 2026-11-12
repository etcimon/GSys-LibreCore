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
| `load_unit` `WAIT_PAGE_OFFSET` holds while the page-offset match is live (`!OoOEn && NrHarts == 1`) | `core/load_unit.sv` | **not ported**; hyp8 and OoO/SMT rely on `st_pipeline_busy`/replay, which is unaudited |
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

## 6. Suggested port order

1. Section 1 (config), with every hook still absent: hyp8 must elaborate and
   pass its smoke tests unchanged.
2. Outstanding generic fixes from section 4.
3. Section 5 with the IO role only (`StoramicIoEn`), then the primary role.
4. Section 2, then section 3, each with its mutants.
5. C3–C6 composition, after it is qualified in the main tree.

Update a row's status in the same commit that ports it, with the remote run
tag as evidence.
