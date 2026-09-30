// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Modified by: Etienne Cimon
// Date: 08.05.2017
// Description: Flush controller


module controller
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Virtualization mode - CSR_REGFILE
    input logic v_i,
    // Set PC om PC Gen - FRONTEND
    output logic set_pc_commit_o,
    // Flush the IF stage - FRONTEND
    output logic flush_if_o,
    // Flush un-issued instructions of the scoreboard - FRONTEND
    output logic flush_unissued_instr_o,
    // Flush ID stage - ID_STAGE
    output logic flush_id_o,
    // Flush EX stage - EX_STAGE
    output logic flush_ex_o,
    // Flush branch predictors - FRONTEND
    output logic flush_bp_o,
    // Flush ICache - CACHE
    output logic flush_icache_o,
    // Flush DCache - CACHE
    output logic flush_dcache_o,
    // Acknowledge the whole DCache Flush - CACHE
    input logic flush_dcache_ack_i,
    // Flush TLBs - EX_STAGE
    output logic flush_tlb_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic flush_tlb_vvma_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic flush_tlb_gvma_o,
    // Halt request from CSR (WFI instruction) - CSR_REGFILE
    input logic halt_csr_i,
    // Halt request from accelerator dispatcher - ACC_DISPATCHER
    input logic halt_acc_i,
    // Halt frontend during fence.i to prevent fetching stale instructions
    output logic halt_frontend_o,
    // Halt signal to commit stage - COMMIT_STAGE
    output logic halt_o,
    // Return from exception - CSR_REGFILE
    input logic eret_i,
    // We got an exception, flush the pipeline - FRONTEND
    input logic ex_valid_i,
    // set the debug pc from CSR - FRONTEND
    input logic set_debug_pc_i,
    // We got a resolved branch, check if we need to flush the front-end - EX_STAGE
    input bp_resolve_t resolved_branch_i,
    // We got an instruction which altered the CSR, flush the pipeline - CSR_REGFILE
    input logic flush_csr_i,
    // fence.i in - ACC_DISPATCH
    input logic fence_i_i,
    // fence in - ACC_DISPATCH
    input logic fence_i,
    // We got an instruction to flush the TLBs and pipeline - COMMIT_STAGE
    input logic sfence_vma_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic hfence_vvma_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic hfence_gvma_i,
    // Flush request from commit stage - COMMIT_STAGE
    input logic flush_commit_i,
    // Committing entry requests refetch from its own PC - COMMIT_STAGE
    input logic replay_i,
    // flush_commit_i is a memory-order replay: frontend refetches the same PC
    output logic mem_replay_pc_o,
    // Flush request from accelerator - ACC_DISPATCHER
    input logic flush_acc_i,
    // U6.1 coarse-grain SMT switch: full pipeline flush, PC comes from PC bank
    input logic smt_switch_i,
    // N1c bounded drain force - SMT selector (drained handoff): the resident
    // hart's uncommitted state is killed so the pending handoff can complete;
    // the outgoing hart's restart PC is banked via npc_alt, not set_pc.
    input logic drain_force_i
);

  // active fence - high if we are currently flushing the dcache
  logic fence_active_d, fence_active_q;
  logic flush_dcache;
  // Added fence_i_active state to track fence.i progress
  logic fence_i_active_d, fence_i_active_q;

  // T6b-3 exit: a fine-grain switch must never degrade a commit-level flush.
  // commit_flush enumerates every flush_id_o source in flush_ctrl below the
  // defaults (mispredict / cf-unissued legs raise only flush_unissued_instr_o,
  // so they are deliberately absent). Under mixed residency an eret/exception
  // coincident with a switch still needs the scoreboard+EX kill: already-issued
  // copies of the flushing instruction survive an unissued-only flush and
  // re-commit against a bank context the first commit already mutated (the
  // parked-xret duplicate-mret failure). Under drained handoff or a single
  // hart MixedSmt folds to 0 and the override below is bit-identical.
  localparam bit MixedSmt = CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff;
`ifdef G6LC_MUT_CTRL_SWITCH_DEGRADES
  // Review-only mutation: the switch override degrades commit-level flushes
  // again — a resident peer's already-issued copies survive and re-commit.
  localparam bit SwitchGuardMut = 1'b1;
`else
  localparam bit SwitchGuardMut = 1'b0;
`endif
  logic commit_flush;
  assign commit_flush = ex_valid_i | eret_i
      | (CVA6Cfg.DebugEn & set_debug_pc_i)
      | flush_csr_i | flush_acc_i | drain_force_i
      | ((CVA6Cfg.RVA | CVA6Cfg.OoOEn) & flush_commit_i)
      | fence_i | fence_i_i
      | (CVA6Cfg.RVS & sfence_vma_i)
      | (CVA6Cfg.RVH & (hfence_vvma_i | hfence_gvma_i));

  // ------------
  // Flush CTRL
  // ------------
  always_comb begin : flush_ctrl
    fence_active_d         = fence_active_q;
    fence_i_active_d       = fence_i_active_q;
    set_pc_commit_o        = 1'b0;
    flush_if_o             = 1'b0;
    flush_unissued_instr_o = 1'b0;
    flush_id_o             = 1'b0;
    flush_ex_o             = 1'b0;
    flush_dcache           = 1'b0;
    flush_icache_o         = 1'b0;
    flush_tlb_o            = 1'b0;
    flush_tlb_vvma_o       = 1'b0;
    flush_tlb_gvma_o       = 1'b0;
    flush_bp_o             = 1'b0;
    mem_replay_pc_o        = 1'b0;
    // ------------
    // Mis-predict
    // ------------
    // Only real EX is_mispredict. Matching taken Jump must not flush_if:
    // without NPC reseed it discards the correct target stream (early
    // load-misalign/illegal); with reseed via is_mispredict, TAGE RAS restore
    // → IAF mepc=0x1400000000; reseed without TAGE double-pushes RAS → PC=0x4.
    // Hang-6 residual fallthrough needs a selective IQ kill (not global flush).
    // Note (R3a): do NOT flush_ex here — that would drop older still-speculative
    // correct-path stores from the STQ. Younger-cancel must not mark STORE
    // cancelled (scoreboard); STQ flush remains full-flush only (fence/exception).
    if (resolved_branch_i.is_mispredict) begin
      // flush only un-issued instructions
      flush_unissued_instr_o = 1'b1;
      // and if stage
      flush_if_o             = 1'b1;
    end
    // EXTRACT E3: I4x/bz/ce predicted-correct Jump/Return/JumpR IQ kill.
    // B already ends the packet at the first predicted CF (`packet_upto_cf`)
    // and kills in-flight on `bp_fire`. A keeps the extra unissued flush.
`ifndef G6LC_FETCH_B
    if (g6lc_cf_unissued::flush(
            CVA6Cfg,
            resolved_branch_i.valid,
            resolved_branch_i.is_mispredict,
            resolved_branch_i.is_taken,
            resolved_branch_i.cf_type)) begin
      flush_unissued_instr_o = 1'b1;
    end
`endif

    // ---------------------------------
    // FENCE
    // ---------------------------------
    if (fence_i) begin
      // this can be seen as a CSR instruction with side-effect
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;
      // this is not needed in the case since we
      // have a write-through cache in this case
      // or we are expecting explicit flush/inval via RVZiCbom
      if (CVA6Cfg.DcacheFlushOnFence) begin
        flush_dcache   = 1'b1;
        fence_active_d = 1'b1;
      end
    end

    // ---------------------------------
    // FENCE.I
    // ---------------------------------
    if (fence_i_i) begin
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;
      flush_icache_o         = 1'b1;
      // this is not needed in the case since we
      // have a write-through cache in this case
      // When handling fence.i, flush both caches and activate fence_i state
      if (CVA6Cfg.DcacheFlushOnFenceI) begin
        flush_dcache = 1'b1;
        fence_active_d = 1'b1;
        fence_i_active_d = 1'b1;
      end
    end

    // this is not needed in the case since we
    // have a write-through cache in this case
    if (CVA6Cfg.DcacheFlushOnFence || CVA6Cfg.DcacheFlushOnFenceI) begin
      // Wait for the acknowledge here
      // Deassert fence_i state only after DCache flush completes
      if (flush_dcache_ack_i && fence_i_active_q) begin
        fence_i_active_d = 1'b0;
      end
      if (flush_dcache_ack_i && fence_active_q) begin
        fence_active_d = 1'b0;
        // keep the flush dcache signal high as long as we didn't get the acknowledge from the cache
      end else if (fence_active_q) begin
        flush_dcache = 1'b1;
      end
    end
    // ---------------------------------
    // SFENCE.VMA
    // ---------------------------------
    if (CVA6Cfg.RVS && sfence_vma_i) begin
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;

      if (CVA6Cfg.RVH && v_i) flush_tlb_vvma_o = 1'b1;
      else flush_tlb_o = 1'b1;
    end

    // ---------------------------------
    // HFENCE.VVMA
    // ---------------------------------
    if (CVA6Cfg.RVH && hfence_vvma_i) begin
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;

      flush_tlb_vvma_o       = 1'b1;
    end

    // ---------------------------------
    // HFENCE.GVMA
    // ---------------------------------
    if (CVA6Cfg.RVH && hfence_gvma_i) begin
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;

      flush_tlb_gvma_o       = 1'b1;
    end

    // ---------------------------------
    // CSR side effects and accelerate port
    // ---------------------------------
    // Set PC to commit stage and flush pipeline
    if (flush_csr_i || flush_acc_i) begin
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;
    end else if ((CVA6Cfg.RVA || CVA6Cfg.OoOEn) && flush_commit_i) begin
      set_pc_commit_o        = 1'b1;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;
      mem_replay_pc_o        = replay_i;
    end

    // ---------------------------------
    // 1. Exception
    // 2. Return from exception
    // ---------------------------------
    if (ex_valid_i || eret_i || (CVA6Cfg.DebugEn && set_debug_pc_i)) begin
      // don't flush pcgen as we want to take the exception: Flush PCGen is not a flush signal
      // for the PC Gen stage but instead tells it to take the PC we gave it
      set_pc_commit_o        = 1'b0;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;
      // this potentially reduces performance, but is needed
      // to suppress speculative fetches to virtual memory from
      // machine mode. TODO: remove when PMA checkers have been
      // added to the system
      flush_bp_o             = 1'b1;
    end

    // ---------------------------------
    // U6.1 fine-grain SMT switch
    // ---------------------------------
    // Flush frontend IF path and drop unissued decode; do NOT assert flush_id
    // (that clears the scoreboard) or flush_ex so in-flight ops of the outgoing
    // hart can drain. CSR/RF bank by instruction hart_id. Do NOT flush BP —
    // RAS/GHR are per-hart and must survive. PC from cva6_smt_pc_bank.
    // The override is skipped when a commit-level flush coincides with the
    // switch under mixed residency — its full-flush outputs above then stand.
    if (CVA6Cfg.NrHarts > 1 && smt_switch_i
        && !(MixedSmt && commit_flush && !SwitchGuardMut)) begin
      set_pc_commit_o        = 1'b0;
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b0;
      flush_ex_o             = 1'b0;
      flush_bp_o             = 1'b0;
    end

    // ---------------------------------
    // N1c bounded drain force
    // ---------------------------------
    // Kill the resident hart's uncommitted state exactly like a commit-level
    // flush but WITHOUT set_pc_commit_o: the outgoing hart's restart PC is
    // banked by g6lc_smt_pc_bank through npc_alt at the switch. Under the
    // drained handoff every in-flight entry belongs to the resident hart, so
    // the global kill is hart-scoped. The selector asserts this only when no
    // uncancellable side effect is in flight, so it cannot race a commit
    // redirect. Ordered last so the kill can never be degraded by the switch
    // override; drained handoff only, constant-0 otherwise.
    if (drain_force_i) begin
      flush_if_o             = 1'b1;
      flush_unissued_instr_o = 1'b1;
      flush_id_o             = 1'b1;
      flush_ex_o             = 1'b1;
    end
  end

  // ----------------------
  // Halt Logic
  // ----------------------
  always_comb begin
    // halt the core if the fence is active
    halt_o = halt_csr_i || halt_acc_i || ((CVA6Cfg.DcacheFlushOnFence || CVA6Cfg.DcacheFlushOnFenceI) && fence_active_q);
    // Halt frontend during fence.i to synchronize ICache/DCache flushes
    halt_frontend_o = fence_i_active_q;
  end

  // ----------------------
  // Registers
  // ----------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      fence_active_q   <= 1'b0;
      fence_i_active_q <= 1'b0;
      flush_dcache_o   <= 1'b0;
    end else begin
      fence_active_q   <= fence_active_d;
      fence_i_active_q <= fence_i_active_d;
      // register on the flush signal, this signal might be critical
      flush_dcache_o   <= flush_dcache;
    end
  end
endmodule
