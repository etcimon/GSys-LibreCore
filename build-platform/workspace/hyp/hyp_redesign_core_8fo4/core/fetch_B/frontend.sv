// hyp8 provenance: REWRITTEN for the 8-FO4 frontend (staged next-line design)
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
// This module interfaces with the instruction cache, handles control flow
// change requests from the back-end and does branch prediction. With
// FtqDepth != 0 the address generation is decoupled from the I$ by a fetch
// target queue, which can then be run ahead of demand fetch (FDIP) or
// bypassed by a loop buffer.
//
// hyp8 staged architecture (ranks per analysis/cut_minimization.md):
//   * g6lc_fe_redirect  — all redirect sources (arch > mispredict > replay >
//     override #1 > override #2) are arbitrated once into one REGISTERED
//     record that applies for exactly one cycle and advances the fetch epoch.
//   * g6lc_fe_nextline  — the only single-cycle next-PC kernel: redirect
//     apply, redirect-completion hold, then advance by the untagged line
//     table (read one cycle ahead) else next_block. FeNextlineUntagged=0
//     degenerates to sequential advance only.
//   * g6lc_fe_btb_check — override #1: one cycle after an FTQ push, a
//     dedicated block-keyed BTB look + RAS top check the line guess.
//   * g6lc_fe_override  — override #2: the response-side verdict (the
//     reference cf_select) as a registered lookup stage plus a registered
//     verdict, driving the queue presentation in its second cycle.
//   * Response path: token accept -> instr_realign stage A (boundary/carry)
//     -> stage B (lane alignment) -> instr_scan registered predecode +
//     g6lc_fe_override stage L -> stage S (queue present + verdict).
//   * Every queued/staged object carries a fetch epoch; entries stamped with
//     a dead epoch drain without issuing (FTQ, instr_queue, realign,
//     override, RAS speculation).
//   * Unchanged: the 2-bit I$ token ownership (want_valid_q/want_token_q,
//     hart and window conjuncts, kill_s1/kill_s2), replay reseed semantics,
//     halt_frontend_i, debug/set-PC, SMT restore flush, boot address,
//     fetch exceptions, the queue's prefix-fire and slot-FIFO alignment.

module frontend
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
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
    input logic [G6LCCfg.VLEN-1:0] boot_addr_i,
    // Flush branch prediction - zero
    input logic flush_bp_i,
    // Flush requested by FENCE, mis-predict and exception - CONTROLLER
    input logic flush_i,
    // Halt requested by WFI and Accelerate port - CONTROLLER
    input logic halt_i,
    // Halt frontend - CONTROLLER (in the case of fence_i to avoid fetching an old instruction)
    input logic halt_frontend_i,
    // T29: instruction translation active (satp mode != bare below M, or
    // G-stage) -- predicted targets are virtual, the PMA filter does not apply
    input logic fetch_translation_en_i,
    // Set COMMIT PC as next PC requested by FENCE, CSR side-effect and Accelerate port - CONTROLLER
    input logic set_pc_commit_i,
    // Hart of the committing instruction — PC_COMMIT only if it matches smt_hart_i
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] commit_hart_i,
    // COMMIT PC - COMMIT
    input logic [G6LCCfg.VLEN-1:0] pc_commit_i,
    // Memory-order replay: refetch the committing PC instead of pc+4 - CONTROLLER
    input logic mem_replay_pc_i,
    // Exception event - COMMIT
    input logic ex_valid_i,
    // Mispredict event and next PC - EXECUTE
    input bp_resolve_t resolved_branch_i,
    // Return from exception event - CSR
    input logic eret_i,
    // Next PC when returning from exception - CSR
    input logic [G6LCCfg.VLEN-1:0] epc_i,
    // Next PC when jumping into exception - CSR
    input logic [G6LCCfg.VLEN-1:0] trap_vector_base_i,
    // Debug event - CSR
    input logic set_debug_pc_i,
    // Debug mode state - CSR
    input logic debug_mode_i,
    // Active hart + PC restore on coarse-grain switch - SMT
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] smt_hart_i,
    input logic smt_restore_i,
    input logic [G6LCCfg.VLEN-1:0] smt_npc_restore_i,
    // T6b-2a: a global flush owned by the OTHER hart restarts this (active)
    // hart's stream at its scoreboard head or surviving frontier. Mixed
    // residency only — tied low on every drained configuration.
    input logic peer_restart_valid_i,
    input logic [G6LCCfg.VLEN-1:0] peer_restart_pc_i,
    // Live NPC for PC bank snapshot - SMT
    output logic [G6LCCfg.VLEN-1:0] npc_q_o,
    // T6b-3b: oldest undelivered fetch position for the SMT restart frontier -
    // the armed redirect target, else the accepted in-flight request, else the
    // NPC cursor. A kill that drops an in-flight parcel must still restart
    // from it, never from the fetch-ahead cursor.
    output logic [G6LCCfg.VLEN-1:0] fetch_frontier_pc_o,
    // T6b-3b: oldest undelivered instruction per hart inside the instruction
    // queue — the port view only reaches NrIssuePorts positions; deeper queued
    // peer entries would be dropped by a kill with no restart frontier.
    output logic [G6LCCfg.NrHarts-1:0] queue_oldest_valid_o,
    output logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:0] queue_oldest_pc_o,
    // A trap redirect is fetched but not yet registered: suppress hart switch - SMT
    output logic smt_trap_hold_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    output icache_dreq_t icache_dreq_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    input icache_drsp_t icache_dreq_i,
    // Handshake's data between fetch and decode - ID_STAGE
    output fetch_entry_t [G6LCCfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid between fetch and decode - ID_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready between fetch and decode - ID_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] fetch_entry_ready_i,
    // hyp8 H27: perf pulses — the distance-1 / distance-2 override verdict
    // won the redirect arbitration and applied this cycle.
    output logic hyp_fe_override1_o,
    output logic hyp_fe_override2_o
);

  localparam g6lc_fetch_pkg::fetch_geo_t Geo = g6lc_fetch_pkg::geo(G6LCCfg);
  localparam int unsigned NrInstr = Geo.slots;
  localparam int unsigned IdxW = Geo.log2_slots;
  localparam bit FtqEn = Geo.ftq;
  localparam bit SmtEn = Geo.smt;
  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;

  localparam type bht_update_t = struct packed {
    logic                    valid;
    logic [G6LCCfg.VLEN-1:0] pc;     // update at PC
    logic                    taken;
  };

  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [G6LCCfg.VLEN-1:0] target_address;
  };

  localparam type btb_update_t = struct packed {
    logic                    valid;
    logic [G6LCCfg.VLEN-1:0] pc;              // update at PC
    logic [G6LCCfg.VLEN-1:0] target_address;
  };

  localparam type ras_t = struct packed {
    logic                    valid;
    logic [G6LCCfg.VLEN-1:0] ra;
  };

  // the three exceptions the frontend can see, as a two bit enum
  function automatic g6lc_core_pkg::frontend_exception_t fe_exception(logic [G6LCCfg.XLEN-1:0] cause);
    unique case (cause)
      riscv::INSTR_GUEST_PAGE_FAULT:
      return G6LCCfg.MmuPresent ? g6lc_core_pkg::FE_INSTR_GUEST_PAGE_FAULT : g6lc_core_pkg::FE_NONE;
      riscv::INSTR_PAGE_FAULT:
      return G6LCCfg.MmuPresent ? g6lc_core_pkg::FE_INSTR_PAGE_FAULT : g6lc_core_pkg::FE_NONE;
      riscv::INSTR_ACCESS_FAULT: return g6lc_core_pkg::FE_INSTR_ACCESS_FAULT;
      default: return g6lc_core_pkg::FE_NONE;
    endcase
  endfunction

  // ==================================================================
  // Signal declarations
  // ==================================================================
  // Response accept (the I$ return or a loop-buffer inject), unregistered feed
  logic [G6LCCfg.FETCH_WIDTH-1:0] icache_data;
  logic icache_take;
  logic [G6LCCfg.VLEN-1:0] ftq_head_vaddr;
  logic ftq_head_taken;
  logic [G6LCCfg.VLEN-1:0] ftq_head_target;
  logic [EW-1:0] ftq_head_epoch;
  logic [G6LCCfg.FETCH_WIDTH-1:0] lbuf_data;
  logic instr_queue_ready;
  logic [NrInstr-1:0] instr_queue_consumed;
  // instruction fetch is ready (FTQ space + queue space + not halted)
  logic if_ready;
  logic [G6LCCfg.VLEN-1:0] npc_d, npc_q;  // next PC
  logic [G6LCCfg.VLEN-1:0] fetch_address;  // block presented to I$ / FTQ
  logic line_taken;                      // next-line guess steering npc_d
  logic [G6LCCfg.VLEN-1:0] line_target;

  // stage-S window products (g6lc_fe_override) and realigner outputs —
  // declared once, driven below
  logic s_win, s_bp_valid, s_carry_done, s_serving_unaligned, s_protect;
  logic s_spec_mark;
  logic [G6LCCfg.VLEN-1:0] s_vaddr, s_predict, s_cf_pc;
  logic [NrInstr-1:0][31:0] s_instr;
  logic [NrInstr-1:0][G6LCCfg.VLEN-1:0] s_addr;
  logic [NrInstr-1:0] iq_valid, iq_is_call, iq_is_return, ov_bp_push_cf;
  cf_t [NrInstr-1:0] iq_cf_type;
  logic [G6LCCfg.VLEN-1:0] iq_predict_address;
  logic ov_ras_push, ov_ras_pop;
  logic [G6LCCfg.VLEN-1:0] ov_ras_update;
  logic [EW-1:0] ov_spec_epoch;
  // instr_realign stage-B outputs and carry-verdict handshake
  logic [NrInstr-1:0] rl_valid;
  logic [NrInstr-1:0][G6LCCfg.VLEN-1:0] rl_addr, rl_base, rl_off;
  logic [NrInstr-1:0][31:0] rl_instr;
  logic rl_serving_unaligned, rl_carry_done, rl_pend_valid, rl_bank_valid;
  logic [G6LCCfg.VLEN-1:0] rl_bank_pc;
  logic pend_resolve, pend_keep;
  // override #1 train taps
  logic ov1_train_valid, ov1_train_taken;
  logic [G6LCCfg.VLEN-1:0] ov1_train_pc, ov1_train_target;

  logic replay, replay_q;
  logic [G6LCCfg.VLEN-1:0] replay_addr, replay_addr_q;
  // redirect record (g6lc_fe_redirect outputs) and same-cycle arbiter events
  logic red_valid, red_step, red_reseed, red_trap;
  logic [3:0] red_src;
  logic [G6LCCfg.VLEN-1:0] red_pc;
  logic is_mispredict, arch_now, resolution_for_active;
  logic [EW-1:0] fe_epoch;

  // request-side kill strobes and the speculative marker
  logic kill_s1, kill_s2, spec_req;
  logic inflight_q;
  logic [G6LCCfg.VLEN-1:0] inflight_addr_q;
  // A hart switch drops every hart-blind queue/prefetcher: entries pushed for
  // the old stream must never serve the restored hart (the loop buffer keys
  // on vaddr and the harts run different address spaces). The same term also
  // kills the in-flight I$ request and drains every piece of mid-stream state
  // (taken-not-presented block, leftover carry, pending-prediction filter,
  // speculative marker): a response accepted after the switch is stamped with
  // the incoming hart, so the outgoing hart's fetch block must never reach the
  // queue. Folds to 0 at NrHarts==1 (SmtEn is a localparam).
  logic smt_restore_flush;
`ifdef G6LC_MUT_FETCH_RESTORE_NOFLUSH
  // MUTANT: pre-M3 behaviour — a hart switch leaves hart-blind FTQ/FDIP/loop
  // buffer state and the in-flight request live for the restored hart.
  assign smt_restore_flush = 1'b0;
`else
  assign smt_restore_flush = SmtEn & smt_restore_i;
`endif
  logic [63:0] snap_nb;
  // halfword offset of the fetch address inside the block (HALFWORDS)
  logic [IdxW-1:0] shamt;
  assign shamt = G6LCCfg.RVC ? icache_dreq_i.vaddr[IdxW:1] : '0;

  // ==================================================================
  // Replay register — an IQ refusal is a redirect record next cycle
  // ==================================================================
  // (the reference stored replay_addr_q for seq_base; here the record
  //  carries it through g6lc_fe_redirect instead)
  // Half muxes. The capture if guarded a VLEN write (the 26.5 cone).
  logic        replay_take;
  logic [63:0] replay_addr_d;
  assign replay_take = replay && !arch_now;
  assign replay_addr_d[31:0]  = replay_take ? replay_addr[31:0]  : replay_addr_q[31:0];
  assign replay_addr_d[63:32] = replay_take ? replay_addr[63:32] : replay_addr_q[63:32];
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      replay_q      <= 1'b0;
      replay_addr_q <= '0;
    end else begin
      replay_q      <= replay_take;
      replay_addr_q <= replay_addr_d;
    end
  end

  // ==================================================================
  // g6lc_fe_redirect — one registered redirect record, epoch source
  // ==================================================================
  logic ov1_valid;
  logic [G6LCCfg.VLEN-1:0] ov1_pc;
  logic ov2_valid;
  logic [G6LCCfg.VLEN-1:0] ov2_pc;

  g6lc_fe_redirect #(
      .G6LCCfg     (G6LCCfg),
      .HypCfg      (HypCfg),
      .bp_resolve_t(bp_resolve_t)
  ) i_fe_redirect (
      .clk_i,
      .rst_ni,
      .flush_i,
      .ex_valid_i,
      .eret_i,
      .epc_i,
      .trap_vector_base_i,
      .set_pc_commit_i,
      .commit_hart_i,
      .pc_commit_i,
      .halt_i,
      .mem_replay_pc_i,
      .set_debug_pc_i,
      .smt_restore_i,
      .smt_npc_restore_i,
      .peer_restart_valid_i,
      .peer_restart_pc_i,
      .smt_hart_i,
      .resolved_branch_i,
      .replay_i      (replay_q),
      .replay_addr_i (replay_addr_q),
      .ov1_valid_i   (ov1_valid),
      .ov1_pc_i      (ov1_pc),
      .ov2_valid_i   (ov2_valid),
      .ov2_pc_i      (ov2_pc),
      .red_valid_o   (red_valid),
      .red_pc_o      (red_pc),
      .red_step_o    (red_step),
      .red_reseed_o  (red_reseed),
      .red_trap_o    (red_trap),
      .red_src_o     (red_src),
      .ov1_taken_o   (hyp_fe_override1_o),
      .ov2_taken_o   (hyp_fe_override2_o),
      .misp_now_o    (is_mispredict),
      .arch_now_o    (arch_now),
      .resolve_active_o(resolution_for_active),
      .epoch_o       (fe_epoch)
  );

  // an applying record of an architectural class (arch/mispredict: src<=PEER)
  logic red_is_arch;
  assign red_is_arch = red_valid && (red_src <= g6lc_fetch_pkg::SRC_PEER);
  // a reseeding record applies this cycle: FTQ flush+push, demand suppressed
  logic reseed_now;
  assign reseed_now = red_valid && red_reseed;

  // ==================================================================
  // Redirect completion (unchanged semantics; armed at the apply cycle)
  // ==================================================================
  logic redirect_pend_q, redirect_inflight_q, redirect_lost_q;
  logic redirect_trap_q, redirect_tail_q;
  logic [G6LCCfg.VLEN-1:0] redirect_pc_q;
  logic redirect_hit, redirect_hold, redirect_accept;
  logic [7:0][63:0] redirect_slot_pc;

  always_comb begin
    redirect_slot_pc = '0;
    for (int p = 0; p < NrInstr; p++)
      redirect_slot_pc[p] = 64'(s_addr[p]);
  end

  // L2 keep: presented-and-consumed stage-S window vs redirect target.
  assign redirect_hit = g6lc_fetch_pkg::accepted_target(
      NrInstr, s_win, flush_i, 8'(instr_queue_consumed),
      redirect_slot_pc, 64'(redirect_pc_q));
  assign redirect_hold = g6lc_fetch_pkg::redirect_rehold(
      FtqEn, redirect_pend_q, redirect_lost_q, redirect_hit);
  assign redirect_accept = g6lc_fetch_pkg::window_accept(
      if_ready, kill_s2,
      g6lc_fetch_pkg::same_win(G6LCCfg, 64'(fetch_address), 64'(redirect_pc_q)));

  // L2: predicted redirect does not set redirect_pend (arch only). kill_s2
  // can lose the sequential inflight (OpenSBI 12ad0 leftover_drop of jal).
  // Mispredict retargets pend to the resolve target. TTL lifts if the target
  // I$ never returns. Same as the reference except the prediction arm moves
  // to the registered override verdict (ov2) — +2 cycles, the epoch kill
  // covers the interval.
  logic bp_pend_q;
  logic [G6LCCfg.VLEN-1:0] bp_tgt_q;
  logic [2:0] bp_misp_ttl_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bp_pend_q     <= 1'b0;
      bp_tgt_q      <= '0;
      bp_misp_ttl_q <= '0;
    end else if (is_mispredict) begin
      bp_pend_q     <= 1'b1;
      bp_tgt_q      <= resolved_branch_i.target_address;
      bp_misp_ttl_q <= 3'd7;
    end else if (flush_i | smt_restore_flush) begin
      bp_pend_q     <= 1'b0;
      bp_misp_ttl_q <= '0;
    end else if (ov2_valid) begin
      bp_pend_q     <= 1'b1;
      bp_tgt_q      <= ov2_pc;
      bp_misp_ttl_q <= '0;
    end else if (bp_pend_q && icache_dreq_i.valid &&
        g6lc_fetch_pkg::same_win(G6LCCfg, 64'(icache_dreq_i.vaddr), 64'(bp_tgt_q))) begin
      bp_pend_q     <= 1'b0;
      bp_misp_ttl_q <= '0;
    end else if (bp_misp_ttl_q != 3'd0) begin
      // I23 bound on the mispredict hold: if the resolve target's window never
      // comes back, the TTL releases pend instead of filtering every return.
      if (bp_misp_ttl_q == 3'd1) bp_pend_q <= 1'b0;
      bp_misp_ttl_q <= bp_misp_ttl_q - 3'd1;
    end
  end

  // hyp8: a split completion waiting on its verdict — pend armed (completing
  // window downstream) or a carry still banked (half instruction buffered).
  logic split_wait;
  assign split_wait = rl_pend_valid | rl_bank_valid;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      redirect_pend_q     <= 1'b0;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      redirect_trap_q     <= 1'b0;
      redirect_tail_q     <= 1'b0;
      redirect_pc_q       <= '0;
    end else if (red_is_arch) begin
      redirect_pend_q     <= 1'b1;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      redirect_trap_q     <= red_trap;
      redirect_tail_q     <= 1'b0;
      redirect_pc_q       <= red_pc;
    end else if (redirect_pend_q && redirect_hit) begin
      redirect_pend_q     <= 1'b0;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      // the target block may end with an instruction split into the next block;
      // whether it does is only known once the realigner has taken it
      redirect_tail_q     <= 1'b1;
    end else if (redirect_tail_q) begin
      // hold only while that split instruction is still waiting for its second
      // half — the carry bank / pending verdict are that condition now
      redirect_tail_q <= split_wait;
      redirect_trap_q <= redirect_trap_q & split_wait;
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

  // ==================================================================
  // Cache interface (FTQ / FDIP / loop buffer / demand)
  // ==================================================================
  logic ftq_full, ftq_head_valid, ftq_pop, ftq_push;
  logic [G6LCCfg.VLEN-1:0] ftq_peek_vaddr, ftq_push_vaddr;
  logic [EW-1:0] ftq_peek_epoch;
  logic ftq_peek_valid;
  logic lbuf_hit, lbuf_hold, lbuf_active, lbuf_consume, lbuf_inject;
  logic pf_req;
  logic [G6LCCfg.VLEN-1:0] pf_vaddr;
  logic demand_req, demand_fire;
  logic cf_hold_q;

  if (!FtqEn) begin : gen_no_ftq
    assign icache_dreq_o.req = instr_queue_ready & ~halt_frontend_i;
    assign if_ready = icache_dreq_i.ready & instr_queue_ready & ~halt_frontend_i;
    assign ftq_full = 1'b0;
    assign ftq_head_valid = 1'b0;
    assign ftq_head_vaddr = '0;
    assign ftq_head_taken = 1'b0;
    assign ftq_head_target = '0;
    assign ftq_head_epoch = '0;
    assign ftq_peek_valid = 1'b0;
    assign ftq_peek_vaddr = '0;
    assign ftq_peek_epoch = '0;
    assign ftq_push_vaddr = '0;
    assign ftq_pop = 1'b0;
    assign ftq_push = 1'b0;
    assign lbuf_hit = 1'b0;
    assign lbuf_hold = 1'b0;
    assign lbuf_active = 1'b0;
    assign lbuf_data = '0;
    assign lbuf_consume = 1'b0;
    assign pf_req = 1'b0;
    assign pf_vaddr = '0;
    assign demand_req = 1'b0;
    assign demand_fire = 1'b0;
    assign cf_hold_q = 1'b0;
  end else begin : gen_ftq
    // After a redirect the queue must not be refilled sequentially until the
    // redirected fetch has been registered: otherwise if_ready keeps pushing
    // the pre-redirect NPC and the stream is duplicated. A depth-1 in-flight
    // request (FtqDepth == 0) relies on kill_s2 racing that instead.
    // hyp8: the hold arms at the applying reseed (registered record) instead
    // of the same-cycle bp_fire/arch_reseed — the epoch bump covers the gap.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) cf_hold_q <= 1'b0;
      else if (reseed_now && ftq_push) cf_hold_q <= 1'b1;
      else if (icache_take) cf_hold_q <= 1'b0;  // redirect fetch presented
      else if (flush_i && !reseed_now) cf_hold_q <= 1'b0;
    end

    // A reseed flushes and refills the queue, so treat that cycle as having
    // free space even if the pre-flush queue was full or held. The replay
    // reseed of the reference now arrives as a redirect record too.
    assign if_ready = (~ftq_full | reseed_now) & instr_queue_ready
                      & ~halt_frontend_i & (~cf_hold_q | reseed_now);
    // Demand the I$ only when the loop buffer cannot supply the queue head.
    // hold_o covers the registered-hit in-flight cycle (hit lands next
    // cycle); hit_o/active_o cover the held registered hit.
    assign demand_req = ftq_head_valid & instr_queue_ready & ~halt_frontend_i
                        & ~lbuf_active & ~lbuf_hold
                        & ~reseed_now & ~flush_i & ~replay_q & ~is_mispredict;
    assign demand_fire = demand_req & icache_dreq_i.ready;
    // Pop only when the I$ accepts a demand request that is not being killed:
    // a pop under kill_s2 drops the redirect target and discards the miss
    // return. A loop-buffer inject also consumes a fetch block.
    assign ftq_pop = (demand_fire & ~kill_s2) | lbuf_consume;

    // The pushed guess records what the stream believes follows the pushed
    // block: the line guess on an ordinary push, nothing on a reseed (the
    // redirect itself decides where the stream goes next).
    assign ftq_push_vaddr = reseed_now ? red_pc : fetch_address;
    assign ftq_push = if_ready | reseed_now;

    g6lc_ftq #(
        .G6LCCfg(G6LCCfg),
        .HypCfg (HypCfg),
        .DEPTH  (G6LCCfg.FtqDepth)
    ) i_ftq (
        .clk_i,
        .rst_ni,
        // sequential addresses queued behind a taken CF must not be drained
        .flush_i      (flush_i | is_mispredict | reseed_now | smt_restore_flush),
        .epoch_i      (fe_epoch),
        .push_i       (ftq_push),
        .push_vaddr_i (ftq_push_vaddr),
        .push_taken_i (reseed_now ? 1'b0 : line_taken),
        .push_target_i(line_target),
        .pop_i        (ftq_pop),
        .head_vaddr_o (ftq_head_vaddr),
        .head_taken_o (ftq_head_taken),
        .head_target_o(ftq_head_target),
        .head_valid_o (ftq_head_valid),
        .head_epoch_o (ftq_head_epoch),
        .peek_offset_i(
        (G6LCCfg.FdipDistance > 0) ? $clog2(G6LCCfg.FtqDepth + 1)'(G6LCCfg.FdipDistance) : '0),
        .peek_vaddr_o (ftq_peek_vaddr),
        .peek_valid_o (ftq_peek_valid),
        .peek_epoch_o (ftq_peek_epoch),
        .full_o       (ftq_full),
        .empty_o      (),
        .count_o      ()
    );

    if (G6LCCfg.FdipEn) begin : gen_fdip
      g6lc_fdip #(
          .G6LCCfg (G6LCCfg),
          .HypCfg  (HypCfg),
          .DISTANCE(G6LCCfg.FdipDistance)
      ) i_fdip (
          .clk_i,
          .rst_ni,
          .flush_i        (flush_i | is_mispredict | reseed_now | smt_restore_flush),
          .enable_i       (1'b1),
          .epoch_i        (fe_epoch),
          .peek_epoch_i   (ftq_peek_epoch),
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

    if (G6LCCfg.LoopBufEn) begin : gen_lbuf
      g6lc_loop_buffer #(
          .G6LCCfg   (G6LCCfg),
          .HypCfg    (HypCfg),
          .NR_ENTRIES(G6LCCfg.LoopBufEntries),
          .DATA_W    (G6LCCfg.FETCH_WIDTH)
      ) i_lbuf (
          .clk_i,
          .rst_ni,
          .flush_i       (flush_i | is_mispredict | flush_bp_i | smt_restore_flush),
          .enable_i      (1'b1),
          .epoch_i       (fe_epoch),
          // arm on the verdict of the window that produced the taken CF
          .cf_valid_i    (s_bp_valid),
          .cf_taken_i    (s_bp_valid),
          .cf_pc_i       (s_cf_pc),
          .cf_target_i   (s_predict),
          // demand fills only (never speculative FDIP)
          .fill_valid_i  (icache_dreq_i.valid & ~spec_req),
          .fill_vaddr_i  (icache_dreq_i.vaddr),
          .fill_data_i   (icache_dreq_i.data[G6LCCfg.FETCH_WIDTH-1:0]),
          .lookup_vaddr_i(ftq_head_vaddr),
          .lookup_ready_i(instr_queue_ready & ~halt_frontend_i),
          .hit_o         (lbuf_hit),
          .data_o        (lbuf_data),
          .active_o      (lbuf_active),
          .consume_o     (lbuf_consume),
          .hold_o        (lbuf_hold)
      );
    end else begin : gen_no_lbuf
      assign lbuf_hit     = 1'b0;
      assign lbuf_hold    = 1'b0;
      assign lbuf_active  = 1'b0;
      assign lbuf_data    = '0;
      assign lbuf_consume = 1'b0;
    end

    // demand wins; FDIP only when demand is idle; loop-buffer hits skip the I$
    assign icache_dreq_o.req = demand_req | pf_req;
  end

  // Three mutually exclusive suppliers, priority-encoded rather than OR'd:
  // demand (FTQ head) > FDIP prefetch > the direct redirect/NPC path.
  assign icache_dreq_o.vaddr = (FtqEn && demand_req) ? ftq_head_vaddr :
      (FtqEn && pf_req) ? pf_vaddr : fetch_address;

  // Redirect drops in-flight I$ (A keep/kill capability, no opcode spares).
  // A hart switch kills the in-flight request too (I10). A registered reseed
  // applying this cycle is a redirect: it kills the old stream's in-flight
  // request the same way mispredict/bp_fire did before (they travel the
  // record now). The IQ's combinational refusal (replay) additionally kills
  // the concurrent accept — unchanged.
  assign kill_s1 = g6lc_fetch_pkg::kill_s1(is_mispredict, flush_i,
                       replay_q | replay)
      | smt_restore_flush | reseed_now;
  assign kill_s2 = g6lc_fetch_pkg::kill_s2(kill_s1, 1'b0);
  assign icache_dreq_o.kill_s1 = kill_s1;
  assign icache_dreq_o.kill_s2 = kill_s2;

  // ==================================================================
  // Request ownership by token (verbatim from the reference)
  // ==================================================================
  logic [1:0] req_token_q, want_token_q;
  logic       want_valid_q, want_pf_q, icache_accept, kill_drop;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] want_hart_q;
  logic [G6LCCfg.VLEN-1:0] want_addr_q;
  // hyp8: the request also stamps the fetch epoch and the line guess that was
  // steering the stream past the requested block — the response's window
  // epoch and the override's "what we expected to fetch next" baseline.
  logic [EW-1:0] want_epoch_q;
  logic want_line_taken_q;
  logic [G6LCCfg.VLEN-1:0] want_line_target_q;

  assign icache_accept = icache_dreq_o.req & icache_dreq_i.ready;
  assign icache_dreq_o.token = req_token_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_token_q         <= '0;
      want_token_q        <= '0;
      want_valid_q        <= 1'b0;
      want_pf_q           <= 1'b0;
      want_hart_q         <= '0;
      want_addr_q         <= '0;
      want_epoch_q        <= '0;
      want_line_taken_q   <= 1'b0;
      want_line_target_q  <= '0;
    end else begin
      if (icache_accept) req_token_q <= req_token_q + 1'b1;
      if (kill_s2) begin
        want_valid_q <= 1'b0;
        if (icache_accept) begin
          want_token_q        <= req_token_q;
          want_pf_q           <= FtqEn && pf_req && !demand_req;
          want_hart_q         <= smt_hart_i;
          want_addr_q         <= icache_dreq_o.vaddr;
          want_epoch_q        <= fe_epoch;
          want_line_taken_q   <= FtqEn ? ftq_head_taken : line_taken;
          want_line_target_q  <= FtqEn ? ftq_head_target : line_target;
        end
      end else if (icache_accept) begin
        want_valid_q        <= 1'b1;
        want_token_q        <= req_token_q;
        want_pf_q           <= FtqEn && pf_req && !demand_req;
        want_hart_q         <= smt_hart_i;
        want_addr_q         <= icache_dreq_o.vaddr;
        want_epoch_q        <= fe_epoch;
        want_line_taken_q   <= FtqEn ? ftq_head_taken : line_taken;
        want_line_target_q  <= FtqEn ? ftq_head_target : line_target;
      end else if (icache_dreq_i.valid && icache_dreq_i.token == want_token_q
          && want_hart_q == smt_hart_i
          && g6lc_fetch_pkg::same_win(G6LCCfg,
              64'(icache_dreq_i.vaddr), 64'(want_addr_q))) begin
        // Only the truly-owned response discharges the want: an aliased stale
        // response must not retire the token the wanted response still needs.
        want_valid_q <= 1'b0;
      end
    end
  end
  assign kill_drop = icache_dreq_i.valid
      && !(want_valid_q && icache_dreq_i.token == want_token_q && !want_pf_q
           && want_hart_q == smt_hart_i
           && g6lc_fetch_pkg::same_win(G6LCCfg,
               64'(icache_dreq_i.vaddr), 64'(want_addr_q)));

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
  assign npc_q_o = snap_nb[G6LCCfg.VLEN-1:0];
  // Stream order is: an armed redirect target (requests re-issue from it),
  // then the accepted in-flight request, then the NPC cursor.
  assign fetch_frontier_pc_o = redirect_pend_q ? redirect_pc_q
      : inflight_q ? inflight_addr_q : npc_q;

  // ==================================================================
  // g6lc_fe_nextline — the next-PC kernel (+ the untagged line table)
  // ==================================================================
  // Line-table training, highest priority first: resolve (the architecturally
  // true outcome), then override #2 (response verdict), then override #1
  // (tagged BTB check). resolve trains on any active-hart CF outcome.
  logic nl_train_valid, nl_train_taken;
  logic [G6LCCfg.VLEN-1:0] nl_train_pc, nl_train_target;
  logic ov2_train_valid, ov2_train_taken;
  logic [G6LCCfg.VLEN-1:0] ov2_train_pc, ov2_train_target;

  logic resolve_train;
  assign resolve_train = resolution_for_active && resolved_branch_i.valid
                         && (resolved_branch_i.cf_type != g6lc_core_pkg::NoCF);
  always_comb begin
    if (resolve_train) begin
      nl_train_valid  = 1'b1;
      nl_train_pc     = resolved_branch_i.pc;
      nl_train_taken  = resolved_branch_i.is_taken;
      nl_train_target = resolved_branch_i.target_address;
    end else if (ov2_train_valid) begin
      nl_train_valid  = 1'b1;
      nl_train_pc     = ov2_train_pc;
      nl_train_taken  = ov2_train_taken;
      nl_train_target = ov2_train_target;
    end else begin
      nl_train_valid  = ov1_train_valid;
      nl_train_pc     = ov1_train_pc;
      nl_train_taken  = ov1_train_taken;
      nl_train_target = ov1_train_target;
    end
  end

  g6lc_fe_nextline #(
      .G6LCCfg(G6LCCfg),
      .HypCfg (HypCfg)
  ) i_fe_nextline (
      .clk_i,
      .rst_ni,
      .flush_i,
      .boot_addr_i,
      .red_valid_i  (red_valid),
      .red_pc_i     (red_pc),
      .red_step_i   (red_step),
      .hold_i       (redirect_hold),
      .hold_pc_i    (redirect_pc_q),
      // FTQ: advance on a queue push (covers reseed); no FTQ: on I$ accept
      .advance_i    (FtqEn ? ftq_push : if_ready),
      .train_valid_i (nl_train_valid),
      .train_pc_i    (nl_train_pc),
      .train_taken_i (nl_train_taken),
      .train_target_i(nl_train_target),
      .npc_o          (npc_q),
      .npc_d_o        (npc_d),
      .fetch_address_o(fetch_address),
      .line_taken_o   (line_taken),
      .line_target_o  (line_target)
  );

  // ==================================================================
  // g6lc_fe_btb_check — override #1 (tagged check of the pushed block)
  // ==================================================================
  btb_update_t btb_update;
  ras_t ras_predict;

  g6lc_fe_btb_check #(
      .G6LCCfg         (G6LCCfg),
      .HypCfg          (HypCfg),
      .btb_update_t    (btb_update_t),
      .btb_prediction_t(btb_prediction_t),
      .ras_t           (ras_t)
  ) i_fe_btb_check (
      .clk_i,
      .rst_ni,
      .flush_bp_i         (flush_bp_i),
      .debug_mode_i       (debug_mode_i),
      .epoch_i            (fe_epoch),
      // skip reseed pushes: the redirect record, not the line, decides the
      // next block — a check against a fabricated guess would be noise
      .push_valid_i       (ftq_push & ~reseed_now & FtqEn),
      .push_vaddr_i       (ftq_push_vaddr),
      .push_epoch_i       (fe_epoch),
      .push_line_taken_i  (reseed_now ? 1'b0 : line_taken),
      .push_line_target_i (line_target),
      .btb_update_i       (btb_update),
      .ras_predict_i      (ras_predict),
      .ov1_valid_o        (ov1_valid),
      .ov1_pc_o           (ov1_pc),
      .train_valid_o      (ov1_train_valid),
      .train_pc_o         (ov1_train_pc),
      .train_taken_o      (ov1_train_taken),
      .train_target_o     (ov1_train_target)
  );

  // ==================================================================
  // Response accept — meta pipeline (replaces the reference icache_*_q regs)
  // ==================================================================
  // Window metadata marching beside the datapath stages:
  //   meta_a (accept, beside realign stage A regs)
  //   meta_b (beside realign stage B regs / predictor P1 hash)
  //   meta_c (beside the predictor P2/verdict registers)
  //   meta_d (beside the override stage-L regs and instr_scan outputs)
  // A stage's valid dies on any of the same events that cleared the
  // registered response of the reference: flush, a qualified mispredict, an
  // applying reseed and the SMT restore flush. A wrong-epoch window is
  // additionally deadened downstream (realign stage B / the queue).
  typedef struct packed {
    logic                            valid;
    logic [G6LCCfg.VLEN-1:0]         vaddr;
    g6lc_core_pkg::frontend_exception_t ex;
    logic [G6LCCfg.GPLEN-1:0]        gpaddr;
    logic [31:0]                     tinst;
    logic                            gva;
    logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart;
    logic [EW-1:0]                   epoch;      // epoch the request was made under
    logic                            line_taken; // guess for the block after
    logic [G6LCCfg.VLEN-1:0]         line_target;
    logic [63:0]                     present_exp; // accept-time prefix-filter base
  } winmeta_t;

  winmeta_t meta_a_q, meta_b_q, meta_c_q, meta_d_q;

  // Re-align: the response is presented to stage A the same cycle it arrives
  // (I22 carry-over: never through a raw registered copy first). kill terms
  // that are window-late in the staged design (leftover-complete slot0 push,
  // leftover_branch_bp_fire) now resolve through the carry pend instead.
  logic [G6LCCfg.VLEN-1:0] realigner_vaddr;
  logic [G6LCCfg.FETCH_WIDTH-1:0] realigner_data;
  logic leftover_kill;

  assign realigner_vaddr = icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr;
  assign realigner_data  = icache_dreq_i.valid ? icache_data     : lbuf_data;

  assign leftover_kill = is_mispredict | flush_i | replay
      | smt_restore_flush | reseed_now;

  // Re-align: leftover_kill is misp/flush/replay. In the staged design the
  // carry never drops at accept; the verdict retires it via pend_resolve.
  instr_realign #(
      .G6LCCfg(G6LCCfg),
      .HypCfg (HypCfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .kill_i             (leftover_kill),
      .hart_i             (smt_hart_i),
      .epoch_i            (fe_epoch),
      // the response's stream epoch: the request-stamped epoch for an I$
      // return, the FTQ entry's epoch for a loop-buffer inject
      .rsp_epoch_i        (icache_dreq_i.valid ? want_epoch_q : ftq_head_epoch),
      // I23: hold the realigner at 0 during reset so an X-state I$.valid or
      // stale carry is not pushed into the instruction queue as a bogus pc=0.
      .valid_i            (icache_take & rst_ni),
      .serving_unaligned_o(rl_serving_unaligned),
      .leftover_pending_o (),
      .leftover_valid_o   (),
      .leftover_pc_o      (),
      .bank_valid_o       (rl_bank_valid),
      .bank_pc_o          (rl_bank_pc),
      .pend_valid_o       (rl_pend_valid),
      .carry_done_o       (rl_carry_done),
      .pend_resolve_i     (pend_resolve),
      .pend_keep_i        (pend_keep),
      .address_i          (realigner_vaddr),
      .data_i             (realigner_data),
      .valid_o            (rl_valid),
      .addr_o             (rl_addr),
      .base_o             (rl_base),
      .off_o              (rl_off),
      .instr_o            (rl_instr)
  );

  // I$ response accept (token- and window- and hart-qualified, pending-target
  // and leftover-retake filters — all carried over from the reference)
  assign icache_take = (icache_dreq_i.valid | lbuf_inject)
      && !kill_drop
      && g6lc_fetch_pkg::bp_ret_ok(bp_pend_q,
          g6lc_fetch_pkg::same_win(G6LCCfg,
              64'(icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr),
              64'(bp_tgt_q)))
      && g6lc_fetch_pkg::leftover_retake(
          replay_q, rl_bank_valid,
          g6lc_fetch_pkg::leftover_next(
              64'(icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr),
              64'(rl_bank_pc)));

  // re-align the cache line (reference shifter position, at accept)
  assign icache_data = icache_dreq_i.data >> {shamt, 4'b0};
  // loop-buffer inject: present as a 1-cycle I$ response without a request.
  // consume_o is the registered-hit handshake (hit_q && consumer ready).
  assign lbuf_inject = FtqEn && G6LCCfg.LoopBufEn && lbuf_consume;

  logic meta_clear;
  assign meta_clear = flush_i | is_mispredict | smt_restore_flush | reseed_now;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      meta_a_q <= '0;
      meta_b_q <= '0;
      meta_c_q <= '0;
      meta_d_q <= '0;
    end else begin
      // meta_a: stamp the response at accept
      meta_a_q.valid       <= icache_take & ~meta_clear;
      meta_a_q.vaddr       <= realigner_vaddr;
      meta_a_q.ex          <= (icache_dreq_i.valid && icache_dreq_i.ex.valid)
                              ? fe_exception(icache_dreq_i.ex.cause)
                              : g6lc_core_pkg::FE_NONE;
      meta_a_q.gpaddr      <= (G6LCCfg.RVH && icache_dreq_i.valid)
                              ? icache_dreq_i.ex.tval2[G6LCCfg.GPLEN-1:0] : '0;
      meta_a_q.tinst       <= (G6LCCfg.RVH && icache_dreq_i.valid)
                              ? icache_dreq_i.ex.tinst : '0;
      meta_a_q.gva         <= (G6LCCfg.RVH && icache_dreq_i.valid)
                              && icache_dreq_i.ex.gva;
      meta_a_q.hart        <= icache_dreq_i.valid ? want_hart_q : smt_hart_i;
      meta_a_q.epoch       <= icache_dreq_i.valid ? want_epoch_q : ftq_head_epoch;
      meta_a_q.line_taken  <= icache_dreq_i.valid ? want_line_taken_q
                                                  : ftq_head_taken;
      meta_a_q.line_target <= icache_dreq_i.valid ? want_line_target_q
                                                  : ftq_head_target;
      // I3/I7 prefix-filter base for this window, computed at accept exactly
      // like the reference's same-cycle present_exp — including the clear-on-
      // redirect arm (a reseed cycle stamps the post-redirect base anyway,
      // and the killed window never reads it).
      meta_a_q.present_exp <= g6lc_fetch_pkg::present_expected(
          bp_pend_q, 64'(bp_tgt_q), 64'(realigner_vaddr));
      // stages b/c/d march the window beside predictor P1/P2 and the
      // override stage-L regs (hyp8: the two-stage predictor lookup pushes
      // the verdict consumer one stage later)
      meta_b_q <= meta_a_q;
      meta_c_q <= meta_b_q;
      meta_d_q <= meta_c_q;
      if (meta_clear) begin
        meta_b_q.valid <= 1'b0;
        meta_c_q.valid <= 1'b0;
        meta_d_q.valid <= 1'b0;
      end
    end
  end

  // hyp8: stage-C shadow of the realigned slot bundle — the predictor's
  // registered verdict reaches the override's stage S one cycle later than
  // the reference, so the whole window path takes one more register stage.
  logic [NrInstr-1:0] rl2_valid;
  logic [NrInstr-1:0][G6LCCfg.VLEN-1:0] rl2_addr, rl2_base, rl2_off;
  logic [NrInstr-1:0][31:0] rl2_instr;
  logic rl2_serving_unaligned, rl2_carry_done;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rl2_valid             <= '0;
      rl2_addr              <= '0;
      rl2_base              <= '0;
      rl2_off               <= '0;
      rl2_instr             <= '0;
      rl2_serving_unaligned <= 1'b0;
      rl2_carry_done        <= 1'b0;
    end else begin
      rl2_valid             <= rl_valid;
      rl2_addr              <= rl_addr;
      rl2_base              <= rl_base;
      rl2_off               <= rl_off;
      rl2_instr             <= rl_instr;
      rl2_serving_unaligned <= rl_serving_unaligned;
      rl2_carry_done        <= rl_carry_done;
    end
  end

  // ==================================================================
  // Predictor lookup stage (stage-B window -> registered products)
  // ==================================================================
  // Combinational lookups run on the window sitting in the stage-B registers;
  // the lookup products are captured alongside the override's stage-L
  // registers. The FPGA paths keep their request-time lookup phase, so they
  // index the stage-A window instead.
  logic [G6LCCfg.VLEN-1:0] vpc_btb, vpc_bht;
  bht_prediction_t [NrInstr-1:0] bht_prediction;
  btb_prediction_t [NrInstr-1:0] btb_prediction;

  assign vpc_btb = G6LCCfg.FpgaEn ? realigner_vaddr : meta_b_q.vaddr;
  assign vpc_bht = G6LCCfg.FpgaEn ? realigner_vaddr : meta_b_q.vaddr;

  // hyp8: stage-S prediction alignment. The TAGE fabric's P2 verdict
  // registers make bht_prediction/btb_prediction live during the override's
  // stage-S cycle directly. The non-TAGE predictors answer combinationally
  // on their lookup cycle — the meta_b window for BHT/GSHARE/classic BTB,
  // the stage-A window for PH_BHT — so their verdict nets take delay taps to
  // land on the same stage-S cycle the registered TAGE verdict does.
  // (Indicative for the non-FPGA configs; FpgaEn paths keep their
  // request-time lookup phase and tap like the PH_BHT case.)
  bht_prediction_t [NrInstr-1:0] bht_pred_d1_q, bht_pred_d2_q, bht_pred_d3_q;
  btb_prediction_t [NrInstr-1:0] btb_pred_d1_q, btb_pred_d2_q, btb_pred_d3_q;
  bht_prediction_t [NrInstr-1:0] bht_pred_s;
  btb_prediction_t [NrInstr-1:0] btb_pred_s;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bht_pred_d1_q <= '0;
      bht_pred_d2_q <= '0;
      bht_pred_d3_q <= '0;
      btb_pred_d1_q <= '0;
      btb_pred_d2_q <= '0;
      btb_pred_d3_q <= '0;
    end else begin
      bht_pred_d1_q <= bht_prediction;
      bht_pred_d2_q <= bht_pred_d1_q;
      bht_pred_d3_q <= bht_pred_d2_q;
      btb_pred_d1_q <= btb_prediction;
      btb_pred_d2_q <= btb_pred_d1_q;
      btb_pred_d3_q <= btb_pred_d2_q;
    end
  end

  assign bht_pred_s = (G6LCCfg.BPType == config_pkg::TAGE_LITE) ? bht_prediction
                    : (G6LCCfg.FpgaEn
                       || G6LCCfg.BPType == config_pkg::PH_BHT) ? bht_pred_d3_q
                    :                                            bht_pred_d2_q;
  assign btb_pred_s = (G6LCCfg.BPType == config_pkg::TAGE_LITE
                       && G6LCCfg.BPIndirectEn) ? btb_prediction
                      : (G6LCCfg.FpgaEn)        ? btb_pred_d3_q
                      :                          btb_pred_d2_q;

  // ==================================================================
  // instr_scan — one registered predecode stage per slot
  // ==================================================================
  logic [NrInstr-1:0] rvi_return, rvi_call, rvi_branch, rvi_jalr, rvi_jump;
  logic [NrInstr-1:0][G6LCCfg.VLEN-1:0] rvi_imm;
  logic [NrInstr-1:0] rvc_branch, rvc_jump, rvc_jr, rvc_return, rvc_jalr, rvc_call;
  logic [NrInstr-1:0][G6LCCfg.VLEN-1:0] rvc_imm;

  for (genvar i = 0; i < NrInstr; i++) begin : gen_instr_scan
    instr_scan #(
        .G6LCCfg(G6LCCfg)
    ) i_instr_scan (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .instr_i     (rl2_instr[i]),
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

  // ==================================================================
  // g6lc_fe_override — stage-L capture, stage-S select/verdict (ov #2)
  // ==================================================================
  g6lc_fe_override #(
      .G6LCCfg         (G6LCCfg),
      .HypCfg          (HypCfg),
      .bht_prediction_t(bht_prediction_t),
      .btb_prediction_t(btb_prediction_t),
      .ras_t           (ras_t)
  ) i_fe_override (
      .clk_i,
      .rst_ni,
      .flush_i,
      .epoch_i             (fe_epoch),
      .fetch_translation_en_i(fetch_translation_en_i),
      // window meta (hyp8: the stage-C window — the predictor verdict lands
      // one stage later than the reference, so the window pipeline carries an
      // extra stage before stage L)
      .win_valid_i         (meta_c_q.valid),
      .win_vaddr_i         (meta_c_q.vaddr),
      .win_epoch_i         (meta_c_q.epoch),
      .win_line_taken_i    (meta_c_q.line_taken),
      .win_line_target_i   (meta_c_q.line_target),
      .serving_unaligned_i (rl2_serving_unaligned),
      .carry_done_i        (rl2_carry_done),
      .present_exp_i       (meta_c_q.present_exp),
      // realigned slot bundle (stage-C shadow registers)
      .vld_raw_i           (rl2_valid),
      .instr_i             (rl2_instr),
      .addr_i              (rl2_addr),
      .base_i              (rl2_base),
      .off_i               (rl2_off),
      // predecode (instr_scan registered outputs, same stage as L)
      .rvi_return_i(rvi_return), .rvi_call_i(rvi_call), .rvi_branch_i(rvi_branch),
      .rvi_jalr_i(rvi_jalr), .rvi_jump_i(rvi_jump),
      .rvi_imm_i           (rvi_imm),
      .rvc_branch_i(rvc_branch), .rvc_jump_i(rvc_jump), .rvc_jr_i(rvc_jr),
      .rvc_return_i(rvc_return), .rvc_jalr_i(rvc_jalr),
      .rvc_call_i          (rvc_call),
      .rvc_imm_i           (rvc_imm),
      // predictor verdicts of this window, live at stage S
      .bht_pred_i          (bht_pred_s),
      .btb_pred_i          (btb_pred_s),
      .ras_predict_i       (ras_predict),
      // same-cycle queue handshake
      .consumed_i          (instr_queue_consumed),
      // stage-S products
      .s_valid_o           (),
      .s_win_o             (s_win),
      .s_vaddr_o           (s_vaddr),
      .s_instr_o           (s_instr),
      .s_addr_o            (s_addr),
      .iq_valid_o          (iq_valid),
      .iq_cf_type_o        (iq_cf_type),
      .iq_predict_address_o(iq_predict_address),
      .iq_is_call_o        (iq_is_call),
      .iq_is_return_o      (iq_is_return),
      .bp_push_cf_o        (ov_bp_push_cf),
      .ras_push_o          (ov_ras_push),
      .ras_pop_o           (ov_ras_pop),
      .ras_update_o        (ov_ras_update),
      .spec_epoch_o        (ov_spec_epoch),
      .s_carry_done_o      (s_carry_done),
      .s_serving_unaligned_o(s_serving_unaligned),
      .s_protect_o         (s_protect),
      .s_bp_valid_o        (s_bp_valid),
      .s_predict_o         (s_predict),
      .spec_mark_o         (s_spec_mark),
      .s_cf_pc_o           (s_cf_pc),
      // registered verdict
      .ov2_valid_o         (ov2_valid),
      .ov2_pc_o            (ov2_pc),
      // line training
      .train_valid_o       (ov2_train_valid),
      .train_pc_o          (ov2_train_pc),
      .train_taken_o       (ov2_train_taken),
      .train_target_o      (ov2_train_target)
  );

  // carry pend verdict: resolve when the completing window reaches stage S;
  // keep the carry for a protected split branch or a refused (replayed)
  // completing window — the reference's leftover_branch_bp_fire /
  // leftover_slot0_push exceptions, moved to the verdict stage.
  assign pend_resolve = rl_pend_valid & s_carry_done;
  assign pend_keep    = s_protect | (replay & s_carry_done);

  // ==================================================================
  // Prediction structures
  // ==================================================================
  // RAS top-of-stack checkpoint / restore for the BP checkpoint (T21: pointer
  // RAS, {tos, cnt, top} snapshot of the fetch hart; restore targets the
  // resolving branch's hart and re-applies that branch's own stack effect)
  localparam int unsigned RasPtrW = (G6LCCfg.RASDepth <= 1) ? 1 : $clog2(G6LCCfg.RASDepth);
  localparam int unsigned RasCntW = (G6LCCfg.RASDepth < 1) ? 1 : $clog2(G6LCCfg.RASDepth + 1);
  localparam int unsigned CkptIdxW = 8;  // branch_predict.ckpt_idx width
  logic ras_restore, ras_restore_own;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ras_restore_hart;
  logic [RasPtrW-1:0] ras_snap_tos, ras_restore_tos;
  logic [RasCntW-1:0] ras_snap_cnt, ras_restore_cnt;
  logic [G6LCCfg.VLEN-1:0] ras_snap_top, ras_restore_top;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] resolve_hart;
  assign resolve_hart = resolved_branch_i.hart_id;

  // Prediction-time checkpoint bookkeeping (TAGE fabric): allocate one entry
  // per consumed real-CF slot — decode type, not predicted cf_type, so the
  // allocation set equals the resolve set; each resolve frees its own entry
  // (index carried by the instruction, T21).
  logic             bp_cf_resolve;
  logic             ckpt_alloc_v;
  logic [NrInstr-1:0] ckpt_slot_v;
  logic [NrInstr-1:0][CkptIdxW-1:0] ckpt_slot_idx;
  for (genvar i = 0; i < NrInstr; i++) begin : gen_ckpt_slot
    assign ckpt_slot_v[i] = ckpt_alloc_v & ov_bp_push_cf[i];
  end
  assign bp_cf_resolve = resolved_branch_i.valid
                         && (resolved_branch_i.cf_type != g6lc_core_pkg::NoCF);
  // T21: an IF flush that is not this frontend's mispredict redirect (SMT
  // switch, commit-side replay, exception, a mispredict outranked by an
  // architectural redirect) kills the fetch hart's consumed-unresolved CFs:
  // drop its checkpoints so they cannot pin the bank. Overrides are fetch-
  // path corrections, not resolves — they do not clear the checkpoint bank.
  logic ckpt_clear;
  assign ckpt_clear = (flush_i | smt_restore_flush) && !is_mispredict;

  if (G6LCCfg.RASDepth == 0) begin : gen_no_ras
    assign ras_predict  = '0;
    assign ras_snap_tos = '0;
    assign ras_snap_cnt = '0;
    assign ras_snap_top = '0;
  end else begin : gen_ras
    ras #(
        .G6LCCfg(G6LCCfg),
        .HypCfg (HypCfg),
        .ras_t  (ras_t),
        .DEPTH  (G6LCCfg.RASDepth),
        .PTR_W  (RasPtrW),
        .CNT_W  (RasCntW)
    ) i_ras (
        .clk_i,
        .rst_ni,
        .flush_bp_i       (flush_bp_i),
        .hart_i           (smt_hart_i),
        .restore_hart_i   (ras_restore_hart),
        .epoch_i          (fe_epoch),
        .spec_epoch_i     (ov_spec_epoch),
        .push_i           (ov_ras_push),
        .pop_i            (ov_ras_pop),
        .data_i           (ov_ras_update),
        .data_o           (ras_predict),
        .snap_tos_o       (ras_snap_tos),
        .snap_cnt_o       (ras_snap_cnt),
        .snap_top_o       (ras_snap_top),
        .restore_i        (ras_restore),
        .restore_tos_i    (ras_restore_tos),
        .restore_cnt_i    (ras_restore_cnt),
        .restore_top_i    (ras_restore_top),
        // the checkpoint is the state before the resolving CF's window: a
        // mispredicted return re-pops, a mispredicted call re-pushes its link
        // (a switch/replay clear restores the frontier context as is)
        .restore_pop_i    (ras_restore_own && resolved_branch_i.cf_type == g6lc_core_pkg::Return),
        .restore_push_i   (ras_restore_own && resolved_branch_i.is_call),
        .restore_push_ra_i(resolved_branch_i.next_pc),
        // resolve-side restores are architectural: stamp them with the epoch
        // at issue so only a NEWER redirect can drop them
        .restore_epoch_i  (fe_epoch)
    );
  end

  // assert on branch, deassert when resolved; prefetches are always speculative
  // hyp8: the mark arrives with the verdict-stage window (s-stage), delayed by
  // the response staging — it only widens the speculative window, never a
  // request's kill/ownership rules.
  logic speculative_q, speculative_d;
  assign speculative_d = (speculative_q && !resolution_for_active
                          || s_spec_mark) && !flush_i
                          && !smt_restore_flush;
  // FDIP is speculative by construction; a demand fetch is speculative only
  // while an unresolved CF is outstanding. Do not reuse this as a leftover
  // gate: spec_req is high on ordinary sequential fetch (NEGATIVE I3 keep).
  assign spec_req = (FtqEn && pf_req && !demand_req) ? 1'b1 : speculative_d;
  assign icache_dreq_o.spec = spec_req;

  // Update Control Flow Predictions
  bht_update_t bht_update;

  assign bht_update.valid = resolved_branch_i.valid
                                & (resolved_branch_i.cf_type == g6lc_core_pkg::Branch);
  assign bht_update.pc = resolved_branch_i.pc;
  assign bht_update.taken = resolved_branch_i.is_taken;
  // only update mispredicted branches e.g. no returns from the RAS
  assign btb_update.valid = resolved_branch_i.valid
                                & resolved_branch_i.is_mispredict
                                & (resolved_branch_i.cf_type == g6lc_core_pkg::JumpR);
  assign btb_update.pc = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // classic BTB, unless the ITTAGE fabric owns the indirect prediction
  if (G6LCCfg.BTBEntries == 0
      || (G6LCCfg.BPType == config_pkg::TAGE_LITE && G6LCCfg.BPIndirectEn)) begin : gen_no_btb
    if (!(G6LCCfg.BPType == config_pkg::TAGE_LITE && G6LCCfg.BPIndirectEn)) begin : gen_btb_tie
      assign btb_prediction = '0;
    end
  end else begin : gen_btb
    btb #(
        .G6LCCfg         (G6LCCfg),
        .btb_update_t    (btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES      (G6LCCfg.BTBEntries)
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

  if (G6LCCfg.BHTEntries == 0) begin : gen_no_bht
    assign bht_prediction = '0;
  end else if (G6LCCfg.BPType == config_pkg::BHT) begin : gen_bht
    bht #(
        .G6LCCfg     (G6LCCfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (G6LCCfg.BHTEntries)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (G6LCCfg.BPType == config_pkg::PH_BHT) begin : gen_bht2lvl
    bht2lvl #(
        .G6LCCfg     (G6LCCfg),
        .bht_update_t(bht_update_t)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_i         (flush_bp_i),
        // PH_BHT keeps its registered-response lookup phase (stage A)
        .vpc_i           (meta_a_q.vaddr),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (G6LCCfg.BPType == config_pkg::GSHARE) begin : gen_gshare
    // standalone gshare (PC xor GHR), same port contract as bht
    g6lc_bp_gshare #(
        .G6LCCfg     (G6LCCfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (G6LCCfg.BHTEntries)
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
  end else if (G6LCCfg.BPType == config_pkg::TAGE_LITE) begin : gen_tage_lite
    // TAGE + optional loop / SC / ITTAGE / checkpoint (GHR+RAS). btb_prediction
    // is driven here only with BPIndirectEn, else the classic BTB owns it.
    btb_prediction_t [NrInstr-1:0] btb_fabric;
    g6lc_bp_top #(
        .G6LCCfg         (G6LCCfg),
        .bht_update_t    (bht_update_t),
        .btb_update_t    (btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .CKPT_IDX_W      (CkptIdxW),
        .RAS_PTR_W       (RasPtrW),
        .RAS_CNT_W       (RasCntW)
    ) i_bp_top (
        .clk_i,
        .rst_ni,
        .flush_bp_i,
        .debug_mode_i,
        .hart_i             (smt_hart_i),
        .resolve_hart_i     (resolve_hart),
        .clear_i            (ckpt_clear),
        .push_cf_i          (ov_bp_push_cf),
        .ckpt_alloc_v_o     (ckpt_alloc_v),
        .ckpt_alloc_idx_o   (ckpt_slot_idx),
        .cf_resolve_i       (bp_cf_resolve),
        .ckpt_v_i           (resolved_branch_i.ckpt_v),
        .ckpt_idx_i         (resolved_branch_i.ckpt_idx),
        .vpc_bht_i          (vpc_bht),
        .vpc_btb_i          (vpc_btb),
        .bht_update_i       (bht_update),
        .btb_update_i       (btb_update),
        .mispredict_i       (resolved_branch_i.valid && resolved_branch_i.is_mispredict),
        .ras_tos_i          (ras_snap_tos),
        .ras_cnt_i          (ras_snap_cnt),
        .ras_top_i          (ras_snap_top),
        .ras_restore_o      (ras_restore),
        .ras_restore_own_o  (ras_restore_own),
        .ras_restore_hart_o (ras_restore_hart),
        .ras_restore_tos_o  (ras_restore_tos),
        .ras_restore_cnt_o  (ras_restore_cnt),
        .ras_restore_top_o  (ras_restore_top),
        .bht_prediction_o   (bht_prediction),
        .btb_prediction_o   (btb_fabric)
    );
    if (G6LCCfg.BPIndirectEn) begin : gen_ittage_btb
      assign btb_prediction = btb_fabric;
    end
  end

  // only the TAGE fabric checkpoints the RAS; flush_bp still clears it
  if (G6LCCfg.BPType != config_pkg::TAGE_LITE) begin : gen_no_ras_restore
    assign ras_restore     = 1'b0;
    assign ras_restore_own = 1'b0;
    assign ras_restore_hart = resolve_hart;
    assign ras_restore_tos = '0;
    assign ras_restore_cnt = '0;
    assign ras_restore_top = '0;
    assign ckpt_alloc_v    = 1'b0;
    assign ckpt_slot_idx   = '0;
  end

  // ==================================================================
  // instr_queue — elastic epoch-aware per-lane FIFOs + prefix fire
  // ==================================================================
  // O7m note: an experiment to flush the instruction queue on predicted taken
  // control flow (bp_fire) was tried and reverted. It removed the return target
  // along with the fall-through and the core refetched the caller path.
  instr_queue #(
      .G6LCCfg(G6LCCfg),
      .HypCfg (HypCfg),
      .fetch_entry_t(fetch_entry_t)
  ) i_instr_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      // Parcels die on a hart switch: gen_smt_restart_frontier banks the
      // outgoing hart's oldest undelivered PC and the restored stream
      // refetches from it, so leaving queued parcels would deliver them twice.
      .flush_i            (flush_i | smt_restore_flush),
      .hart_i             (meta_d_q.hart),
      .epoch_i            (fe_epoch),
      .push_epoch_i       (ov_spec_epoch),
      .instr_i            (s_instr),               // from the override stage L
      .addr_i             (s_addr),                // from the override stage L
      .exception_i        (meta_d_q.ex),           // from I$ (staged)
      .exception_addr_i   (meta_d_q.vaddr),
      .exception_gpaddr_i (meta_d_q.gpaddr),
      .exception_tinst_i  (meta_d_q.tinst),
      .exception_gva_i    (meta_d_q.gva),
      .predict_address_i  (iq_predict_address),
      .cf_type_i          (iq_cf_type),
      // T21: BP checkpoint identity + call flag ride with the instruction
      .ckpt_v_i           (ckpt_slot_v),
      .ckpt_idx_i         (ckpt_slot_idx),
      .is_call_i          (iq_is_call),
      .is_return_i        (iq_is_return),
      .valid_i            (iq_valid),              // from the verdict stage
      .leftover_complete_i(s_serving_unaligned),
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i),   // to back-end
      .queue_oldest_valid_o(queue_oldest_valid_o),
      .queue_oldest_pc_o  (queue_oldest_pc_o)
  );

//pragma translate_off
  // -------------------------------------------------------------------------
  // WINDOW LIFECYCLE PROBE (`+fetch_win_trace`) and KILL-PERSISTENCE CHECK
  // (`+fetch_kill_check`) — carried over from the reference, retargeted at the
  // staged signals (bpf -> the registered override verdict; vmask -> the
  // stage-S presentation).
  // -------------------------------------------------------------------------
  logic fwt_en, kcheck_en;
  initial begin
    fwt_en = $test$plusargs("fetch_win_trace");
    kcheck_en = $test$plusargs("fetch_kill_check");
  end

  // verilog_lint: waive always-ff-non-reset
  always_ff @(posedge clk_i) begin
    if (rst_ni && kcheck_en && icache_dreq_i.valid && icache_take
        && !(want_valid_q && icache_dreq_i.token == want_token_q && !want_pf_q)) begin
      $display("[killchk] t=%0t UNWANTED TAKE rsp_vaddr=%h rsp_tok=%0d want=%b want_tok=%0d npc=%h",
               $time, icache_dreq_i.vaddr, icache_dreq_i.token,
               want_valid_q, want_token_q, npc_d);
    end
  end

  // verilog_lint: waive always-ff-non-reset
  always_ff @(posedge clk_i) begin
    if (rst_ni && fwt_en && $time() < 200000) begin
      if (icache_dreq_i.valid || icache_take || kill_s1 || kill_s2 || ov2_valid
          || flush_i || is_mispredict || replay || red_valid) begin
        $display("[win] t=%0t rsp=%b vaddr=%h take=%b k1=%b k2=%b ov2=%b red=%b fl=%b mp=%b rp=%b ep=%0d vmask=%b iqr=%b npc=%h",
                 $time, icache_dreq_i.valid, icache_dreq_i.vaddr, icache_take,
                 kill_s1, kill_s2, ov2_valid, red_valid, flush_i, is_mispredict,
                 replay, fe_epoch, iq_valid, instr_queue_ready, npc_d);
      end
    end
  end
//pragma translate_on

  // speculative marker register (kept with the request-side plumbing)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) speculative_q <= '0;
    else         speculative_q <= speculative_d;
  end

endmodule
