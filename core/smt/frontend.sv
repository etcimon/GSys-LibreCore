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
// Date: 08.02.2018
// Description: Instruction Fetch Frontend
//
// This module interfaces with the instruction cache, handles control flow change
// requests from the back-end and does branch prediction. With FtqDepth != 0 the
// address generation is decoupled from the I$ by a fetch target queue, which can
// then be run ahead of demand fetch (FDIP) or bypassed by a loop buffer.
//
// A/B draft note: every non-sequential fetch address is arbitrated once
// (arch_redirect_select) and consumed by the NPC register, the FTQ reseed and the
// I$ kill logic, instead of being re-derived as a chain of overriding ifs in each
// of those three places.

module frontend
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type fetch_entry_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Next PC when reset - SUBSYSTEM
    input logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Flush branch prediction - zero
    input logic flush_bp_i,
    // Flush requested by FENCE, mis-predict and exception - CONTROLLER
    input logic flush_i,
    // Halt requested by WFI and Accelerate port - CONTROLLER
    input logic halt_i,
    // Halt frontend - CONTROLLER (in the case of fence_i to avoid fetching an old instruction)
    input logic halt_frontend_i,
    // Set COMMIT PC as next PC requested by FENCE, CSR side-effect and Accelerate port - CONTROLLER
    input logic set_pc_commit_i,
    // Hart of the committing instruction — PC_COMMIT only if it matches smt_hart_i
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] commit_hart_i,
    // COMMIT PC - COMMIT
    input logic [CVA6Cfg.VLEN-1:0] pc_commit_i,
    // Exception event - COMMIT
    input logic ex_valid_i,
    // Mispredict event and next PC - EXECUTE
    input bp_resolve_t resolved_branch_i,
    // Return from exception event - CSR
    input logic eret_i,
    // Next PC when returning from exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] epc_i,
    // Next PC when jumping into exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] trap_vector_base_i,
    // Debug event - CSR
    input logic set_debug_pc_i,
    // Debug mode state - CSR
    input logic debug_mode_i,
    // Active hart + PC restore on coarse-grain switch - SMT
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] smt_hart_i,
    input logic smt_restore_i,
    input logic [CVA6Cfg.VLEN-1:0] smt_npc_restore_i,
    // Live NPC for PC bank snapshot - SMT
    output logic [CVA6Cfg.VLEN-1:0] npc_q_o,
    // A trap redirect is fetched but not yet registered: suppress hart switch - SMT
    output logic smt_trap_hold_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    output icache_dreq_t icache_dreq_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    input icache_drsp_t icache_dreq_i,
    // Handshake's data between fetch and decode - ID_STAGE
    output fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid between fetch and decode - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready between fetch and decode - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i
);

  localparam int unsigned NrInstr = CVA6Cfg.INSTR_PER_FETCH;
  localparam int unsigned IdxW = CVA6Cfg.LOG2_INSTR_PER_FETCH;
  localparam bit FtqEn = CVA6Cfg.FtqDepth != 0;
  localparam bit SmtEn = CVA6Cfg.NrHarts > 1;

  localparam type bht_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;     // update at PC
    logic                    taken;
  };

  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type btb_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;              // update at PC
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type ras_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] ra;
  };

  // next fetch block — pkg geometry (same as win_base + W_BYTES)
  function automatic logic [CVA6Cfg.VLEN-1:0] next_block(logic [CVA6Cfg.VLEN-1:0] addr);
    logic [63:0] nb;
    nb = g6lc_fetch_pkg::next_block(CVA6Cfg, 64'(addr));
    return nb[CVA6Cfg.VLEN-1:0];
  endfunction

  // the three exceptions the frontend can see, as a two bit enum
  function automatic ariane_pkg::frontend_exception_t fe_exception(logic [CVA6Cfg.XLEN-1:0] cause);
    unique case (cause)
      riscv::INSTR_GUEST_PAGE_FAULT:
      return CVA6Cfg.MmuPresent ? ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT : ariane_pkg::FE_NONE;
      riscv::INSTR_PAGE_FAULT:
      return CVA6Cfg.MmuPresent ? ariane_pkg::FE_INSTR_PAGE_FAULT : ariane_pkg::FE_NONE;
      riscv::INSTR_ACCESS_FAULT: return ariane_pkg::FE_INSTR_ACCESS_FAULT;
      default: return ariane_pkg::FE_NONE;
    endcase
  endfunction

  // Instruction Cache Registers, from I$
  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data_q;
  logic icache_valid_q;
  ariane_pkg::frontend_exception_t icache_ex_valid_q;
  logic [CVA6Cfg.VLEN-1:0] icache_vaddr_q;
  logic [CVA6Cfg.GPLEN-1:0] icache_gpaddr_q;
  logic [31:0] icache_tinst_q;
  logic icache_gva_q;
  logic instr_queue_ready;
  logic [NrInstr-1:0] instr_queue_consumed;
  // upper-most branch-prediction from last cycle
  btb_prediction_t btb_q;
  bht_prediction_t bht_q;
  // instruction fetch is ready
  logic if_ready;
  logic [CVA6Cfg.VLEN-1:0] npc_d, npc_q;  // next PC
  logic [CVA6Cfg.VLEN-1:0] seq_base;  // address the sequential step starts from
  logic [CVA6Cfg.VLEN-1:0] fetch_address;  // address presented to I$ / FTQ this cycle
  // indicates whether we come out of reset (then we need to load boot_addr_i)
  logic npc_rst_load_q;

  logic replay;
  logic [CVA6Cfg.VLEN-1:0] replay_addr;

  // halfword offset of the fetch address inside the block
  logic [IdxW-1:0] shamt;

  // -----------------------
  // Ctrl Flow Speculation
  // -----------------------
  // RVI ctrl flow prediction
  logic [NrInstr-1:0] rvi_return, rvi_call, rvi_branch, rvi_jalr, rvi_jump;
  logic [NrInstr-1:0][CVA6Cfg.VLEN-1:0] rvi_imm;
  // RVC branching
  logic [NrInstr-1:0] rvc_branch, rvc_jump, rvc_jr, rvc_return, rvc_jalr, rvc_call;
  logic [NrInstr-1:0][CVA6Cfg.VLEN-1:0] rvc_imm;
  // re-aligned instruction and address (coming from cache - combinationally)
  logic [NrInstr-1:0][31:0] instr;
  logic [NrInstr-1:0][CVA6Cfg.VLEN-1:0] addr;
  logic [NrInstr-1:0] instruction_valid;
  // BHT, BTB and RAS prediction
  bht_prediction_t [NrInstr-1:0] bht_prediction;
  btb_prediction_t [NrInstr-1:0] btb_prediction;
  bht_prediction_t [NrInstr-1:0] bht_prediction_shifted;
  btb_prediction_t [NrInstr-1:0] btb_prediction_shifted;
  ras_t ras_predict;
  logic [CVA6Cfg.VLEN-1:0] vpc_btb;
  logic [CVA6Cfg.VLEN-1:0] vpc_bht;

  // branch-predict update
  logic is_mispredict;
  logic ras_push, ras_pop;
  logic [CVA6Cfg.VLEN-1:0] ras_update;

  // Instruction FIFO
  logic [CVA6Cfg.VLEN-1:0] predict_address;
  cf_t [NrInstr-1:0] cf_type;
  logic [NrInstr-1:0] taken_rvi_cf;
  logic [NrInstr-1:0] taken_rvc_cf;

  logic bp_valid;
  logic [NrInstr-1:0] is_branch, is_call, is_jump, is_return, is_jalr;
  logic serving_unaligned, leftover_pending;
  // I$ request fields are kept as local wires: the request struct is then only
  // driven, never read back inside this module
  logic kill_s1, kill_s2, spec_req;
  logic inflight_q;
  logic [CVA6Cfg.VLEN-1:0] inflight_addr_q;
  logic [63:0] snap_nb;
  // address will always be 16 bit aligned, make this explicit here
  assign shamt = CVA6Cfg.RVC ? icache_dreq_i.vaddr[IdxW:1] : '0;

  // Re-align instructions. Kill and flush are inert on leftover.
  instr_realign #(
      .CVA6Cfg(CVA6Cfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .kill_i             (kill_s2),
      .hart_i             (smt_hart_i),
      .valid_i            (icache_valid_q),
      .serving_unaligned_o(serving_unaligned),
      .leftover_pending_o (leftover_pending),
      .address_i          (icache_vaddr_q),
      .data_i             (icache_data_q),
      .valid_o            (instruction_valid),
      .addr_o             (addr),
      .instr_o            (instr)
  );

  // --------------------
  // Branch Prediction
  // --------------------
  // Index the prediction structures with the generated address. In case we serve
  // an unaligned instruction in instr[0] its prediction was saved last fetch.
  for (genvar i = 0; i < NrInstr; i++) begin : gen_prediction_shifted
    logic [IdxW-1:0] sel;
    assign sel = addr[i][IdxW:1] & IdxW'(NrInstr - 1);
    if (i == 0) begin : gen_head
      assign bht_prediction_shifted[0] = serving_unaligned ? bht_q : bht_prediction[sel];
      assign btb_prediction_shifted[0] = serving_unaligned ? btb_q : btb_prediction[sel];
    end else begin : gen_tail
      assign bht_prediction_shifted[i] = bht_prediction[sel];
      assign btb_prediction_shifted[i] = btb_prediction[sel];
    end
  end

  for (genvar i = 0; i < NrInstr; i++) begin : gen_cf_class
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i]);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i]);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr[i] = instruction_valid[i] & ~is_return[i]
                        & (rvi_jalr[i] | rvc_jalr[i] | rvc_jr[i]);
  end

  // taken/not taken
  always_comb begin : cf_select
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;
    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;

    for (int i = 0; i < NrInstr; i++) cf_type[i] = ariane_pkg::NoCF;

    // lower most prediction gets precedence
    for (int i = NrInstr - 1; i >= 0; i--) begin
      unique case ({
        is_branch[i], is_return[i], is_jump[i], is_jalr[i]
      })
        4'b0000: ;  // regular instruction e.g.: no branch
        // unconditional jump to register, we need the BTB to resolve this
        4'b0001: begin
          if (CVA6Cfg.BTBEntries != 0 && btb_prediction_shifted[i].valid) begin
            predict_address = btb_prediction_shifted[i].target_address;
            cf_type[i] = ariane_pkg::JumpR;
          end
        end
        // its an unconditional jump to an immediate
        4'b0010: begin
          taken_rvi_cf[i] = rvi_jump[i];
          taken_rvc_cf[i] = rvc_jump[i];
          cf_type[i] = ariane_pkg::Jump;
        end
        // return: only alter the RAS if we actually consumed the instruction
        4'b0100: begin
          ras_pop = ras_predict.valid & instr_queue_consumed[i];
          predict_address = ras_predict.ra;
          cf_type[i] = ariane_pkg::Return;
        end
        // branch prediction: dynamic if we have it, else static on the sign of
        // the immediate
        4'b1000: begin
          if (bht_prediction_shifted[i].valid) begin
            taken_rvi_cf[i] = rvi_branch[i] & bht_prediction_shifted[i].taken;
            taken_rvc_cf[i] = rvc_branch[i] & bht_prediction_shifted[i].taken;
          end else begin
            taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
            taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
          end
          if (taken_rvi_cf[i] || taken_rvc_cf[i]) cf_type[i] = ariane_pkg::Branch;
        end
        default: ;  // more than one control flow decoded
      endcase

      // if this instruction is also a call, save the return address, but only if
      // we actually consumed it
      if (is_call[i]) begin
        ras_push   = instr_queue_consumed[i];
        ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
      end
      // calculate the jump target address
      if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
        predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
      end
    end
  end

  // A prediction is only valid if we saw a control flow, and for a return only if
  // the RAS holds a valid address.
  always_comb begin : bp_valid_reduce
    bp_valid = 1'b0;
    for (int i = 0; i < NrInstr; i++) begin
      bp_valid |= ((cf_type[i] != NoCF) & (cf_type[i] != Return))
                  | ((cf_type[i] == Return) & ras_predict.valid);
    end
  end

  // I19: act on a prediction only if the target is fetchable. Resolve is unfiltered.
  logic bp_fire;
  assign bp_fire = bp_valid
      && g6lc_fetch_pkg::predict_fetchable(CVA6Cfg, 64'(predict_address));

  // Classic EX mispredict only. A matching taken Jump must not reseed the NPC:
  // re-fetching a call pushes the RAS twice.
  assign is_mispredict = resolved_branch_i.valid & resolved_branch_i.is_mispredict;

  // ------------------------------------------------------------------
  // Redirect arbitration
  // ------------------------------------------------------------------
  // Every architectural (non branch-predicted) redirect is selected once here.
  //  - arch_pc     : the address the machine must fetch next
  //  - arch_step   : with an FTQ the queue is reseeded with arch_pc, so the NPC
  //                  register steps to the *following* block, otherwise the same
  //                  address would be pushed twice when the CF hold lifts
  //  - arch_reseed : force an FTQ push/flush even if if_ready is low
  logic arch_valid, arch_step, arch_reseed;
  logic [CVA6Cfg.VLEN-1:0] arch_pc;
  logic [CVA6Cfg.VLEN-1:0] commit_next_pc, debug_halt_pc;

  // CSR or AMO instructions do not exist in a compressed form, so commit + 4;
  // if commit is halted just take the PC of the instruction sitting there
  assign commit_next_pc = pc_commit_i + (halt_i ? '0 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100});
  assign debug_halt_pc = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0]
                         + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0];

  // a trap redirect additionally may not be interrupted by a hart switch
  logic arch_trap;
  logic [3:0] arch_src;

  // I8 encoder (post-pre-ladder): trap/eret/commit/debug outrank SMT restore.
  assign arch_src = g6lc_fetch_pkg::arch_src_sel(
      SmtEn, smt_restore_i, CVA6Cfg.DebugEn && set_debug_pc_i,
      g6lc_fetch_pkg::commit_for_hart(SmtEn, set_pc_commit_i,
          8'(commit_hart_i), 8'(smt_hart_i)),
      ex_valid_i, eret_i, is_mispredict);

  always_comb begin : arch_redirect_select
    arch_valid  = 1'b1;
    arch_step   = FtqEn;
    arch_reseed = 1'b1;
    arch_trap   = 1'b0;
    arch_pc     = '0;

    unique case (arch_src)
      g6lc_fetch_pkg::SRC_EX: begin
        arch_pc   = trap_vector_base_i;
        arch_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_ERET: begin
        arch_pc   = epc_i;
        arch_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_COMMIT: begin
        arch_pc     = commit_next_pc;
        arch_step   = FtqEn & ~halt_i;
        arch_reseed = flush_i;
      end
      g6lc_fetch_pkg::SRC_DEBUG: begin
        arch_pc   = debug_halt_pc;
        arch_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_RESTORE: begin
        arch_pc   = smt_npc_restore_i;
        arch_step = 1'b0;
      end
      g6lc_fetch_pkg::SRC_MISP: begin
        arch_pc = resolved_branch_i.target_address;
      end
      default: begin
        arch_valid  = 1'b0;
        arch_step   = 1'b0;
        arch_reseed = 1'b0;
      end
    endcase
  end

  // ------------------------------------------------------------------
  // Redirect completion
  // ------------------------------------------------------------------
  // A redirect is not done when its address is issued, only when its fetch block
  // has been *registered*. If the fetch in flight for it is killed (a flush, or a
  // taken prediction still coming out of the pre-redirect block) the target must be
  // presented again, otherwise the NPC has already moved on and the first
  // instructions at the target are never supplied.
  //
  // This is recovery only, never a stall: the NPC steps as soon as the I$ accepts
  // a request, because an address presented while its request is already accepted
  // is fetched twice, and the second copy is pushed into the queue a second time.
  // With an FTQ the queue holds the target instead (arch_step / cf_hold_q), so this
  // only drives the direct path.
  logic redirect_pend_q, redirect_inflight_q, redirect_lost_q;
  logic redirect_trap_q, redirect_tail_q;
  logic [CVA6Cfg.VLEN-1:0] redirect_pc_q;
  logic redirect_hit, redirect_hold, redirect_accept;

  // L2 keep: registered / in-flight window vs redirect target. No opcode.
  assign redirect_hit = g6lc_fetch_pkg::window_accept(
      icache_valid_q, 1'b0,
      g6lc_fetch_pkg::same_win(CVA6Cfg, 64'(icache_vaddr_q), 64'(redirect_pc_q)));
  assign redirect_hold = g6lc_fetch_pkg::redirect_rehold(
      FtqEn, redirect_pend_q, redirect_lost_q, redirect_hit);
  assign redirect_accept = g6lc_fetch_pkg::window_accept(
      if_ready, kill_s2,
      g6lc_fetch_pkg::same_win(CVA6Cfg, 64'(fetch_address), 64'(redirect_pc_q)));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      redirect_pend_q     <= 1'b0;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      redirect_trap_q     <= 1'b0;
      redirect_tail_q     <= 1'b0;
      redirect_pc_q       <= '0;
    end else if (arch_valid) begin
      redirect_pend_q     <= 1'b1;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      redirect_trap_q     <= arch_trap;
      redirect_tail_q     <= 1'b0;
      redirect_pc_q       <= arch_pc;
    end else if (redirect_pend_q && redirect_hit) begin
      redirect_pend_q     <= 1'b0;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      // the target block may end with an instruction split into the next block;
      // whether it does is only known once the realigner has taken it
      redirect_tail_q     <= 1'b1;
    end else if (redirect_tail_q) begin
      // hold only while that split instruction is still waiting for its second
      // half, so a stalled pipeline cannot block a switch indefinitely
      redirect_tail_q <= serving_unaligned & ~icache_valid_q;
      redirect_trap_q <= redirect_trap_q & serving_unaligned & ~icache_valid_q;
    end else if (redirect_pend_q) begin
      // a kill leaves nothing in flight for the target, so present it again
      if (kill_s2) begin
        redirect_inflight_q <= 1'b0;
        redirect_lost_q     <= 1'b1;
      end else if (redirect_accept) begin
        redirect_inflight_q <= 1'b1;
        redirect_lost_q     <= 1'b0;
      end
    end
  end

  // Narrower than a flush: only a trap redirect blocks the switch, so
  // switch-on-miss still works over ordinary redirects.
  assign smt_trap_hold_o = SmtEn & redirect_trap_q & (redirect_pend_q | redirect_tail_q);

  // -------------------
  // Next PC
  // -------------------
  // The sequential step is taken from the predicted target when a prediction
  // fires this cycle, else from the current NPC (boot address out of reset).
  assign seq_base = npc_rst_load_q ? boot_addr_i : (bp_fire ? predict_address : npc_q);
  // I8: I$ address follows the same encoder as npc_d. Restore-first here
  // outranked trap/commit (I4y) and could present a banked data VA.
  assign fetch_address = arch_valid ? arch_pc :
      redirect_hold ? redirect_pc_q : seq_base;

  always_comb begin : npc_select
    if (arch_valid) npc_d = arch_step ? next_block(arch_pc) : arch_pc;
    // re-present the redirect target until its block has been registered
    else if (redirect_hold) npc_d = redirect_pc_q;
    else if (replay) npc_d = replay_addr;
    else if (if_ready) npc_d = next_block(seq_base);
    else if (bp_fire) npc_d = predict_address;
    else npc_d = seq_base;
  end

  // ------------------------------------------------------------------
  // Cache interface
  // ------------------------------------------------------------------
  // Without an FTQ the NPC is presented to the I$ directly and advances against
  // I$ ready. With an FTQ the NPC advances against queue space, demand fetch
  // drains the queue head, and FDIP may steal idle I$ cycles.
  logic ftq_full, ftq_head_valid, ftq_pop, ftq_push;
  logic [CVA6Cfg.VLEN-1:0] ftq_head_vaddr, ftq_peek_vaddr, ftq_push_vaddr;
  logic ftq_peek_valid;
  logic lbuf_hit, lbuf_consume, lbuf_inject;
  logic [CVA6Cfg.FETCH_WIDTH-1:0] lbuf_data;
  logic pf_req;
  logic [CVA6Cfg.VLEN-1:0] pf_vaddr;
  logic demand_req, demand_fire;

  if (!FtqEn) begin : gen_no_ftq
    assign icache_dreq_o.req = instr_queue_ready & ~halt_frontend_i;
    assign if_ready = icache_dreq_i.ready & instr_queue_ready & ~halt_frontend_i;
    assign ftq_full = 1'b0;
    assign ftq_head_valid = 1'b0;
    assign ftq_head_vaddr = '0;
    assign ftq_peek_valid = 1'b0;
    assign ftq_peek_vaddr = '0;
    assign ftq_push_vaddr = '0;
    assign ftq_pop = 1'b0;
    assign ftq_push = 1'b0;
    assign lbuf_hit = 1'b0;
    assign lbuf_data = '0;
    assign lbuf_consume = 1'b0;
    assign pf_req = 1'b0;
    assign pf_vaddr = '0;
    assign demand_req = 1'b0;
    assign demand_fire = 1'b0;
  end else begin : gen_ftq
    // After a redirect the queue must not be refilled sequentially until the
    // redirected fetch has been registered: otherwise if_ready keeps pushing the
    // pre-redirect NPC and the stream is duplicated. A depth-1 in-flight request
    // (FtqDepth == 0) relies on kill_s2 racing that instead.
    logic cf_hold_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) cf_hold_q <= 1'b0;
      else if (bp_fire || arch_reseed) cf_hold_q <= 1'b1;
      else if (icache_valid_q) cf_hold_q <= 1'b0;  // redirect fetch presented
      else if (flush_i && !arch_reseed) cf_hold_q <= 1'b0;
    end

    // A reseed flushes and refills the queue, so treat that cycle as having free
    // space even if the pre-flush queue was full or held.
    assign if_ready = (~ftq_full | bp_fire | arch_reseed) & instr_queue_ready
                      & ~halt_frontend_i & (~cf_hold_q | bp_fire | arch_reseed);
    // Demand the I$ only when the loop buffer cannot supply the queue head. The
    // reseed is registered, so the same-cycle head is still the pre-flush one.
    assign demand_req = ftq_head_valid & instr_queue_ready & ~halt_frontend_i & ~lbuf_hit
                        & ~bp_fire & ~arch_reseed & ~flush_i;
    assign demand_fire = demand_req & icache_dreq_i.ready;
    // Pop only when the I$ accepts a demand request that is not being killed: a
    // pop under kill_s2 drops the redirect target and discards the miss return.
    // A loop-buffer inject also consumes a fetch block.
    assign ftq_pop = (demand_fire & ~kill_s2) | lbuf_consume;

    assign ftq_push_vaddr = arch_reseed ? arch_pc : (bp_fire ? predict_address : fetch_address);
    assign ftq_push = if_ready | arch_reseed;

    g6lc_ftq #(
        .CVA6Cfg(CVA6Cfg),
        .DEPTH  (CVA6Cfg.FtqDepth)
    ) i_ftq (
        .clk_i,
        .rst_ni,
        // sequential addresses queued behind a taken CF must not be drained
        .flush_i      (flush_i | is_mispredict | bp_fire),
        .push_i       (ftq_push),
        .push_vaddr_i (ftq_push_vaddr),
        .push_taken_i (bp_fire),
        .push_target_i(predict_address),
        .pop_i        (ftq_pop),
        .head_vaddr_o (ftq_head_vaddr),
        .head_taken_o (),
        .head_target_o(),
        .head_valid_o (ftq_head_valid),
        .peek_offset_i(
        (CVA6Cfg.FdipDistance > 0) ? $clog2(CVA6Cfg.FtqDepth + 1)'(CVA6Cfg.FdipDistance) : '0),
        .peek_vaddr_o (ftq_peek_vaddr),
        .peek_valid_o (ftq_peek_valid),
        .full_o       (ftq_full),
        .empty_o      (),
        .count_o      ()
    );

    if (CVA6Cfg.FdipEn) begin : gen_fdip
      g6lc_fdip #(
          .CVA6Cfg (CVA6Cfg),
          .DISTANCE(CVA6Cfg.FdipDistance)
      ) i_fdip (
          .clk_i,
          .rst_ni,
          .flush_i        (flush_i | is_mispredict | bp_fire),
          .enable_i       (1'b1),
          .peek_valid_i   (ftq_peek_valid),
          .peek_vaddr_i   (ftq_peek_vaddr),
          .demand_active_i(demand_req),
          .icache_ready_i (icache_dreq_i.ready),
          .pf_req_o       (pf_req),
          .pf_vaddr_o     (pf_vaddr),
          .pf_drop_pma_o  ()
      );
    end else begin : gen_no_fdip
      assign pf_req   = 1'b0;
      assign pf_vaddr = '0;
    end

    if (CVA6Cfg.LoopBufEn) begin : gen_lbuf
      g6lc_loop_buffer #(
          .CVA6Cfg   (CVA6Cfg),
          .NR_ENTRIES(CVA6Cfg.LoopBufEntries),
          .DATA_W    (CVA6Cfg.FETCH_WIDTH)
      ) i_lbuf (
          .clk_i,
          .rst_ni,
          .flush_i       (flush_i | is_mispredict | flush_bp_i),
          .enable_i      (1'b1),
          .cf_valid_i    (bp_fire),
          .cf_taken_i    (bp_fire),
          // arm on the in-flight fetch PC that produced the taken prediction
          .cf_pc_i       (icache_vaddr_q),
          .cf_target_i   (predict_address),
          // demand fills only (never speculative FDIP)
          .fill_valid_i  (icache_dreq_i.valid & ~spec_req),
          .fill_vaddr_i  (icache_dreq_i.vaddr),
          .fill_data_i   (icache_dreq_i.data[CVA6Cfg.FETCH_WIDTH-1:0]),
          .lookup_vaddr_i(ftq_head_vaddr),
          .lookup_ready_i(instr_queue_ready & ~halt_frontend_i),
          .hit_o         (lbuf_hit),
          .data_o        (lbuf_data),
          .active_o      (),
          .consume_o     (lbuf_consume)
      );
    end else begin : gen_no_lbuf
      assign lbuf_hit     = 1'b0;
      assign lbuf_data    = '0;
      assign lbuf_consume = 1'b0;
    end

    // demand wins; FDIP only when demand is idle; loop-buffer hits skip the I$
    assign icache_dreq_o.req = demand_req | pf_req;
  end

  assign icache_dreq_o.vaddr = (FtqEn && demand_req) ? ftq_head_vaddr :
      (FtqEn && pf_req) ? pf_vaddr : fetch_address;

  // Redirect drops in-flight I$ (A keep/kill capability, no opcode spares).
  assign kill_s1 = g6lc_fetch_pkg::kill_s1(is_mispredict, flush_i, replay);
  assign kill_s2 = g6lc_fetch_pkg::kill_s2(kill_s1, bp_fire);
  assign icache_dreq_o.kill_s1 = kill_s1;
  assign icache_dreq_o.kill_s2 = kill_s2;

  // I10: bank the accepted I$ address when switch kills it, not next_block.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      inflight_q      <= 1'b0;
      inflight_addr_q <= '0;
    end else if (kill_s2) begin
      inflight_q <= 1'b0;
    end else if (FtqEn ? demand_fire : if_ready) begin
      inflight_q      <= 1'b1;
      inflight_addr_q <= FtqEn ? ftq_head_vaddr : fetch_address;
    end else if (icache_dreq_i.valid) begin
      inflight_q <= 1'b0;
    end
  end
  assign snap_nb = g6lc_fetch_pkg::snap_pc(SmtEn && smt_restore_i, inflight_q,
      64'(inflight_addr_q), 64'(npc_q));
  assign npc_q_o = snap_nb[CVA6Cfg.VLEN-1:0];

  // assert on branch, deassert when resolved; prefetches are always speculative
  logic speculative_q, speculative_d;
  assign speculative_d = (speculative_q && !resolved_branch_i.valid
                          || |is_branch || |is_return || |is_jalr) && !flush_i;
  assign spec_req = (FtqEn && pf_req && !demand_req) ? 1'b1 : speculative_d;
  assign icache_dreq_o.spec = spec_req;

  // Update Control Flow Predictions
  bht_update_t bht_update;
  btb_update_t btb_update;

  assign bht_update.valid = resolved_branch_i.valid
                                & (resolved_branch_i.cf_type == ariane_pkg::Branch);
  assign bht_update.pc = resolved_branch_i.pc;
  assign bht_update.taken = resolved_branch_i.is_taken;
  // only update mispredicted branches e.g. no returns from the RAS
  assign btb_update.valid = resolved_branch_i.valid
                                & resolved_branch_i.is_mispredict
                                & (resolved_branch_i.cf_type == ariane_pkg::JumpR);
  assign btb_update.pc = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // ------------------------------------------------------------------
  // I$ response pipeline register
  // ------------------------------------------------------------------
  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data;
  // re-align the cache line
  assign icache_data = icache_dreq_i.data >> {shamt, 4'b0};
  // loop-buffer inject: present as a 1-cycle I$ response without a request
  assign lbuf_inject = FtqEn && CVA6Cfg.LoopBufEn && lbuf_consume;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      npc_rst_load_q    <= 1'b1;
      npc_q             <= '0;
      speculative_q     <= '0;
      icache_data_q     <= '0;
      icache_valid_q    <= 1'b0;
      icache_vaddr_q    <= 'b0;
      icache_gpaddr_q   <= 'b0;
      icache_tinst_q    <= 'b0;
      icache_gva_q      <= 1'b0;
      icache_ex_valid_q <= ariane_pkg::FE_NONE;
      btb_q             <= '0;
      bht_q             <= '0;
    end else begin
      npc_rst_load_q <= 1'b0;
      npc_q          <= npc_d;
      speculative_q  <= speculative_d;
      // A line already registered here would still be presented next cycle and
      // re-enter the instruction queue, so drop it on any redirect. kill_s2 only
      // cancels the in-flight request.
      if (flush_i || is_mispredict || bp_fire) begin
        icache_valid_q    <= 1'b0;
        icache_ex_valid_q <= ariane_pkg::FE_NONE;
      end else begin
        // prefer the real I$ return, else inject the loop buffer into the same pipe
        icache_valid_q <= icache_dreq_i.valid | lbuf_inject;
        if (icache_dreq_i.valid || lbuf_inject) begin
          icache_data_q     <= icache_dreq_i.valid ? icache_data : lbuf_data;
          icache_vaddr_q    <= icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr;
          icache_ex_valid_q <= icache_dreq_i.valid ? fe_exception(icache_dreq_i.ex.cause)
              : ariane_pkg::FE_NONE;
          icache_gpaddr_q <= (CVA6Cfg.RVH && icache_dreq_i.valid) ?
              icache_dreq_i.ex.tval2[CVA6Cfg.GPLEN-1:0] : '0;
          icache_tinst_q <= (CVA6Cfg.RVH && icache_dreq_i.valid) ? icache_dreq_i.ex.tinst : '0;
          icache_gva_q <= (CVA6Cfg.RVH && icache_dreq_i.valid) ? icache_dreq_i.ex.gva : 1'b0;
          // save the uppermost prediction
          btb_q <= btb_prediction[NrInstr-1];
          bht_q <= bht_prediction[NrInstr-1];
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Prediction structures
  // ------------------------------------------------------------------
  // RAS snapshot / restore for the BP checkpoint; train_hart is the hart of the
  // resolving branch so snap/restore stay per-hart
  logic ras_restore;
  ras_t [CVA6Cfg.RASDepth == 0 ? 0 : CVA6Cfg.RASDepth-1:0] ras_stack_snap;
  ras_t [CVA6Cfg.RASDepth == 0 ? 0 : CVA6Cfg.RASDepth-1:0] ras_restore_stack;
  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] resolve_hart;
  assign resolve_hart = resolved_branch_i.hart_id;

  if (CVA6Cfg.RASDepth == 0) begin : gen_no_ras
    assign ras_predict = '0;
    assign ras_stack_snap = '0;
  end else begin : gen_ras
    ras #(
        .CVA6Cfg(CVA6Cfg),
        .ras_t  (ras_t),
        .DEPTH  (CVA6Cfg.RASDepth)
    ) i_ras (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .hart_i          (smt_hart_i),
        .train_hart_i    (resolve_hart),
        .push_i          (ras_push),
        .pop_i           (ras_pop),
        .data_i          (ras_update),
        .data_o          (ras_predict),
        .stack_snapshot_o(ras_stack_snap),
        .restore_i       (ras_restore),
        .restore_stack_i (ras_restore_stack)
    );
  end

  // For FPGA the BTB/BHT are read-synchronous BRAM, for ASIC D flip-flops which
  // can be read in the same cycle.
  assign vpc_btb = CVA6Cfg.FpgaEn ? icache_dreq_i.vaddr : icache_vaddr_q;
  assign vpc_bht = (CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid)
                   ? icache_dreq_i.vaddr : icache_vaddr_q;

  // classic BTB, unless the ITTAGE fabric owns the indirect prediction
  if (CVA6Cfg.BTBEntries == 0
      || (CVA6Cfg.BPType == config_pkg::TAGE_LITE && CVA6Cfg.BPIndirectEn)) begin : gen_no_btb
    if (!(CVA6Cfg.BPType == config_pkg::TAGE_LITE && CVA6Cfg.BPIndirectEn)) begin : gen_btb_tie
      assign btb_prediction = '0;
    end
  end else begin : gen_btb
    btb #(
        .CVA6Cfg         (CVA6Cfg),
        .btb_update_t    (btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES      (CVA6Cfg.BTBEntries)
    ) i_btb (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_btb),
        .btb_update_i    (btb_update),
        .btb_prediction_o(btb_prediction)
    );
  end

  if (CVA6Cfg.BHTEntries == 0) begin : gen_no_bht
    assign bht_prediction = '0;
  end else if (CVA6Cfg.BPType == config_pkg::BHT) begin : gen_bht
    bht #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (CVA6Cfg.BHTEntries)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::PH_BHT) begin : gen_bht2lvl
    bht2lvl #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_i         (flush_bp_i),
        .vpc_i           (icache_vaddr_q),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::GSHARE) begin : gen_gshare
    // standalone gshare (PC xor GHR), same port contract as bht
    g6lc_bp_gshare #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (CVA6Cfg.BHTEntries)
    ) i_gshare (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .hart_i          (smt_hart_i),
        .train_hart_i    (resolve_hart),
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::TAGE_LITE) begin : gen_tage_lite
    // TAGE + optional loop / SC / ITTAGE / checkpoint (GHR+RAS). btb_prediction
    // is driven here only with BPIndirectEn, else the classic BTB owns it.
    btb_prediction_t [NrInstr-1:0] btb_fabric;
    g6lc_bp_top #(
        .CVA6Cfg         (CVA6Cfg),
        .bht_update_t    (bht_update_t),
        .btb_update_t    (btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .ras_t           (ras_t)
    ) i_bp_top (
        .clk_i,
        .rst_ni,
        .flush_bp_i,
        .debug_mode_i,
        .hart_i             (smt_hart_i),
        .resolve_hart_i     (resolve_hart),
        .vpc_bht_i          (vpc_bht),
        .vpc_btb_i          (vpc_btb),
        .bht_update_i       (bht_update),
        .btb_update_i       (btb_update),
        .mispredict_i       (is_mispredict),
        .ras_stack_i        (ras_stack_snap),
        .ras_restore_o      (ras_restore),
        .ras_restore_stack_o(ras_restore_stack),
        .bht_prediction_o   (bht_prediction),
        .btb_prediction_o   (btb_fabric)
    );
    if (CVA6Cfg.BPIndirectEn) begin : gen_ittage_btb
      assign btb_prediction = btb_fabric;
    end
  end

  // only the TAGE fabric checkpoints the RAS; flush_bp still clears it
  if (CVA6Cfg.BPType != config_pkg::TAGE_LITE) begin : gen_no_ras_restore
    assign ras_restore = 1'b0;
    assign ras_restore_stack = '0;
  end

  // we need to inspect up to INSTR_PER_FETCH instructions for branches and jumps
  for (genvar i = 0; i < NrInstr; i++) begin : gen_instr_scan
    instr_scan #(
        .CVA6Cfg(CVA6Cfg)
    ) i_instr_scan (
        .instr_i     (instr[i]),
        .rvi_return_o(rvi_return[i]),
        .rvi_call_o  (rvi_call[i]),
        .rvi_branch_o(rvi_branch[i]),
        .rvi_jalr_o  (rvi_jalr[i]),
        .rvi_jump_o  (rvi_jump[i]),
        .rvi_imm_o   (rvi_imm[i]),
        .rvc_branch_o(rvc_branch[i]),
        .rvc_jump_o  (rvc_jump[i]),
        .rvc_jr_o    (rvc_jr[i]),
        .rvc_return_o(rvc_return[i]),
        .rvc_jalr_o  (rvc_jalr[i]),
        .rvc_call_o  (rvc_call[i]),
        .rvc_imm_o   (rvc_imm[i])
    );
  end

  instr_queue #(
      .CVA6Cfg(CVA6Cfg),
      .fetch_entry_t(fetch_entry_t)
  ) i_instr_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .hart_i             (smt_hart_i),
      .instr_i            (instr),                 // from re-aligner
      .addr_i             (addr),                  // from re-aligner
      .exception_i        (icache_ex_valid_q),     // from I$
      .exception_addr_i   (icache_vaddr_q),
      .exception_gpaddr_i (icache_gpaddr_q),
      .exception_tinst_i  (icache_tinst_q),
      .exception_gva_i    (icache_gva_q),
      .predict_address_i  (predict_address),
      .cf_type_i          (cf_type),
      .valid_i            (instruction_valid),     // from re-aligner
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i)    // to back-end
  );

endmodule
