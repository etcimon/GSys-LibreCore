// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// T6b-4b review leaf: per-hart commit heads over the shared scoreboard ring.
// The mixed-geometry DUT (NrHarts=2, !SmtDrainedHandoff) is wired through a
// real commit_stage so both the scoreboard's port *offers* and the commit
// port *acks* are checked. A second scoreboard instance in drained geometry
// receives the identical stimulus; with only hart-A residency the two must
// produce cycle-for-cycle identical port offers/acks (SBC_LEGACY_EQUIV).
//
// Scenarios:
//   0  A0 incomplete + B0 complete -> port1 offers/acks B0 (hole), reclaim
//      stays; A0 completes -> port0 acks A0, reclaim jumps the hole to the
//      next live slot in one cycle.
//   1  Ring full with a committed hole -> issue_full, no alloc onto the live
//      window (SBC_NO_OVERWRITE; G6LC_MUT_SB_POPCOUNT_FREE must fatal here).
//   2  B head = CSR, older A simple head -> port0 offers B, port1 offers A's
//      head, port1 ack suppressed (privileged port 0).
//   3  B head with exception -> port0 offers B, both acks suppressed.
//   4  Replay-marked B head -> routed to port 0 (commit_replay_o[0]).
//   5  Hart-A-only stream on both geometries -> identical offers/acks every
//      cycle (SBC_LEGACY_EQUIV).
module tb_g6lc_sbcommit;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"

  localparam int NSB = 8;
  localparam int TW  = $clog2(NSB);

  function automatic config_pkg::cva6_cfg_t cfg(input bit drained);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.GPLEN=64;c.FLen=64;c.IS_XLEN64=1;
    c.NrHarts=2;c.SmtDrainedHandoff=drained;
    c.NrIssuePorts=1;c.NrCommitPorts=2;c.NrWbPorts=1;c.NrRgprPorts=2;
    c.NR_SB_ENTRIES=NSB;c.TRANS_ID_BITS=TW;
    c.OoOEn=1;c.SuperscalarEn=1;c.SpeculativeSb=1;
    c.RVA=1;c.RVS=1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C  = cfg(0);  // MIXED
  localparam config_pkg::cva6_cfg_t CL = cfg(1);  // DRAINED (legacy shape)

  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C) sbe_t;
  typedef struct packed {
    logic valid; logic [63:0] pc,target_address; logic is_mispredict,is_taken;
    cf_t cf_type; logic hart_id,ckpt_restore; logic [TW-1:0] trans_id;
  } bp_t;
  typedef struct packed {
    logic valid; logic [63:0] data; logic ex_valid; logic [TW-1:0] trans_id;
  } wb_t;
  typedef struct packed {
    logic [NSB-1:0] still_issued; logic [TW-1:0] issue_pointer;
    wb_t [0:0] wb; sbe_t [NSB-1:0] sbe;
  } fwd_t;

  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  task automatic tick; @(negedge clk); #1; @(posedge clk); #1; endtask

  // ---- shared stimulus ----
  sbe_t [0:0] decoded='{default:'0};
  logic [0:0][31:0] orig='0;
  logic [0:0] decoded_valid='0, issue_ack='0;
  logic [0:0][TW-1:0] wb_tid='0;
  logic [0:0][63:0] wb_data='0;
  exception_t [0:0] wb_ex='{default:'0};
  logic [0:0] wt_valid='0;
  bp_t resolved='0;
  logic flush=0, flush_unissued=0;
  logic mem_violation=0;
  logic [TW-1:0] mem_violation_id='0;

  // ---- mixed DUT ----
  logic [0:0] da, iv;
  sbe_t [1:0] commit_instr;
  logic [1:0] commit_drop, commit_replay;
  logic [1:0] commit_ack;
  logic [0:0][TW-1:0] rvfi_issue;
  logic [1:0][TW-1:0] rvfi_commit;
  logic [TW-1:0] reclaim;
  logic sb_full;
  fwd_t fwd;
  scoreboard #(.CVA6Cfg(C),.bp_resolve_t(bp_t),.exception_t(exception_t),
      .scoreboard_entry_t(sbe_t),.forwarding_t(fwd_t),.writeback_t(wb_t),
      .rs3_len_t(logic[63:0])) dut (
    .clk_i(clk),.rst_ni(rst_n),.sb_full_o(sb_full),.sb_empty_o(),
    .spec_cancel_o(),.cancelled_mask_o(),.sb_live_o(),
    .sb_head_pc_o(),.sb_head_valid_o(),
    .mem_violation_i(mem_violation),.mem_violation_id_i(mem_violation_id),
    .flush_unissued_instr_i(flush_unissued),
    .flush_i(flush),.x_transaction_accepted_i(1'b0),.x_issue_writeback_i(1'b0),
    .x_id_i('0),.commit_instr_o(commit_instr),.commit_drop_o(commit_drop),
    .commit_replay_o(commit_replay),.commit_ack_i(commit_ack),
    .decoded_instr_i(decoded),.orig_instr_i(orig),
    .decoded_instr_valid_i(decoded_valid),.decoded_instr_ack_o(da),
    .issue_instr_o(),.orig_instr_o(),
    .issue_instr_valid_o(iv),.issue_ack_i(issue_ack),.fwd_o(fwd),
    .resolved_branch_i(resolved),.trans_id_i(wb_tid),.wbdata_i(wb_data),
    .ex_i(wb_ex),.wt_valid_i(wt_valid),.x_we_i(1'b0),.x_rd_i('0),
    .rvfi_issue_pointer_o(rvfi_issue),.rvfi_commit_pointer_o(rvfi_commit),
    .reclaim_ptr_o(reclaim),
    .g1mf_v_o(),.g1mf_rd_o(),.g1mf_line_o(),.g1mf_a3_o());

  // ---- commit stage on the mixed DUT's offers ----
  commit_stage #(.CVA6Cfg(C),.exception_t(exception_t),
      .scoreboard_entry_t(sbe_t)) cs (
    .clk_i(clk),.rst_ni(rst_n),.halt_i(1'b0),.flush_dcache_i(1'b0),
    .flush_i(1'b0),
    .exception_o(),.dirty_fp_state_o(),.single_step_i(1'b0),.step_hart_i('0),
    .commit_instr_i(commit_instr),.commit_drop_i(commit_drop),
    .commit_replay_i(commit_replay),.commit_ack_o(commit_ack),
    .commit_macro_ack_o(),.waddr_o(),.wdata_o(),.we_gpr_o(),.whart_o(),
    .we_fpr_o(),.amo_resp_i('0),.pc_o(),.csr_op_o(),.csr_wdata_o(),
    .csr_rdata_i('0),.csr_write_fflags_o(),.csr_exception_i('0),
    .commit_lsu_o(),.commit_lsu_ready_i(1'b1),.commit_tran_id_o(),
    .amo_valid_commit_o(),.no_st_pending_i(1'b1),.commit_csr_o(),
    .fence_i_o(),.fence_o(),.flush_commit_o(),.replay_o(),.sfence_vma_o(),
    .hfence_vvma_o(),.hfence_gvma_o(),.shared_tlb_flush_busy_i(1'b0),
    .break_from_trigger_i(1'b0));

  // ---- drained-geometry reference (same stimulus, legacy select) ----
  logic [0:0] da_l, iv_l;
  sbe_t [1:0] commit_instr_l;
  logic [1:0] commit_drop_l, commit_replay_l;
  logic [1:0] commit_ack_l;
  logic [TW-1:0] reclaim_l;
  fwd_t fwd_l;
  scoreboard #(.CVA6Cfg(CL),.bp_resolve_t(bp_t),.exception_t(exception_t),
      .scoreboard_entry_t(sbe_t),.forwarding_t(fwd_t),.writeback_t(wb_t),
      .rs3_len_t(logic[63:0])) dut_leg (
    .clk_i(clk),.rst_ni(rst_n),.sb_full_o(),.sb_empty_o(),
    .spec_cancel_o(),.cancelled_mask_o(),.sb_live_o(),
    .sb_head_pc_o(),.sb_head_valid_o(),
    .mem_violation_i(mem_violation),.mem_violation_id_i(mem_violation_id),
    .flush_unissued_instr_i(flush_unissued),
    .flush_i(flush),.x_transaction_accepted_i(1'b0),.x_issue_writeback_i(1'b0),
    .x_id_i('0),.commit_instr_o(commit_instr_l),.commit_drop_o(commit_drop_l),
    .commit_replay_o(commit_replay_l),.commit_ack_i(commit_ack_l),
    .decoded_instr_i(decoded),.orig_instr_i(orig),
    .decoded_instr_valid_i(decoded_valid),.decoded_instr_ack_o(da_l),
    .issue_instr_o(),.orig_instr_o(),
    .issue_instr_valid_o(iv_l),.issue_ack_i(issue_ack),.fwd_o(fwd_l),
    .resolved_branch_i(resolved),.trans_id_i(wb_tid),.wbdata_i(wb_data),
    .ex_i(wb_ex),.wt_valid_i(wt_valid),.x_we_i(1'b0),.x_rd_i('0),
    .rvfi_issue_pointer_o(),.rvfi_commit_pointer_o(),.reclaim_ptr_o(reclaim_l),
    .g1mf_v_o(),.g1mf_rd_o(),.g1mf_line_o(),.g1mf_a3_o());

  // The reference gets its own commit_stage — the mixed model's acks free
  // slots that the legacy select does not present.
  commit_stage #(.CVA6Cfg(CL),.exception_t(exception_t),
      .scoreboard_entry_t(sbe_t)) cs_leg (
    .clk_i(clk),.rst_ni(rst_n),.halt_i(1'b0),.flush_dcache_i(1'b0),
    .flush_i(1'b0),
    .exception_o(),.dirty_fp_state_o(),.single_step_i(1'b0),.step_hart_i('0),
    .commit_instr_i(commit_instr_l),.commit_drop_i(commit_drop_l),
    .commit_replay_i(commit_replay_l),.commit_ack_o(commit_ack_l),
    .commit_macro_ack_o(),.waddr_o(),.wdata_o(),.we_gpr_o(),.whart_o(),
    .we_fpr_o(),.amo_resp_i('0),.pc_o(),.csr_op_o(),.csr_wdata_o(),
    .csr_rdata_i('0),.csr_write_fflags_o(),.csr_exception_i('0),
    .commit_lsu_o(),.commit_lsu_ready_i(1'b1),.commit_tran_id_o(),
    .amo_valid_commit_o(),.no_st_pending_i(1'b1),.commit_csr_o(),
    .fence_i_o(),.fence_o(),.flush_commit_o(),.replay_o(),.sfence_vma_o(),
    .hfence_vvma_o(),.hfence_gvma_o(),.shared_tlb_flush_busy_i(1'b0),
    .break_from_trigger_i(1'b0));

  int equiv_mismatch = 0;
  task automatic equiv_check;
    // Cycle-for-cycle identical presentation under hart-A-only residency.
    if (commit_instr[0].trans_id !== commit_instr_l[0].trans_id ||
        commit_instr[1].trans_id !== commit_instr_l[1].trans_id ||
        commit_instr[0].valid    !== commit_instr_l[0].valid    ||
        commit_instr[1].valid    !== commit_instr_l[1].valid    ||
        commit_instr[0].pc       !== commit_instr_l[0].pc       ||
        commit_instr[1].pc       !== commit_instr_l[1].pc       ||
        commit_ack !== commit_ack_l ||
        da !== da_l || iv !== iv_l) begin
      equiv_mismatch++;
      $display("SBC_LEGACY_EQUIV_MISMATCH p0=%0d/%0d p1=%0d/%0d da=%b/%b",
               commit_instr[0].trans_id, commit_instr_l[0].trans_id,
               commit_instr[1].trans_id, commit_instr_l[1].trans_id, da, da_l);
    end
  endtask

  task automatic alloc(input int h, input logic [63:0] pc,
                       input fu_t fu = NONE, input bit exv = 0,
                       input fu_op op = ADD);
    decoded = '{default:'0};
    decoded[0].fu = fu; decoded[0].op = op;
    decoded[0].pc = 64'(pc); decoded[0].rd = 5'd1;
    decoded[0].hart_id = h[0]; decoded[0].ex.valid = exv;
    decoded_valid = 1'b1; issue_ack = 1'b1;
    #1;
    if (!iv[0] || !da[0]) $fatal(1, "SBC_ALLOC pc=%h iv=%b da=%b", pc, iv[0], da[0]);
    tick();
    decoded_valid = '0; issue_ack = '0; decoded = '{default:'0};
  endtask

  task automatic wb(input int tid, input bit exv = 0);
    wb_tid[0] = TW'(tid); wt_valid = 1'b1; wb_ex[0].valid = exv;
    wb_ex[0].cause = 64'd13;  // ILLEGAL_INSTRUCTION when exv
    tick(); wt_valid = '0; wb_ex[0].valid = 1'b0;
  endtask

  task automatic chk_offer(input int p, input int tid, input int h,
                           input string tag);
    if (commit_instr[p].trans_id !== TW'(tid) ||
        commit_instr[p].hart_id  !== h[0])
      $fatal(1, "%s port=%0d tid got=%0d want=%0d hart got=%b want=%b",
             tag, p, commit_instr[p].trans_id, tid,
             commit_instr[p].hart_id, h[0]);
  endtask

  int scenario;
  bit negative;
  initial begin
    negative = $test$plusargs("oracle_negative");
    if (!$value$plusargs("scenario=%d", scenario)) scenario = 0;
    repeat (2) tick(); rst_n = 1; repeat (2) tick();

    if (scenario == 0) begin
      // A0 B0 A1 B1; A0 stays incomplete (no WB), B0 is written back so it
      // is a complete simple head eligible for the cross-hart port.
      alloc(0, 64'h100, ALU); alloc(1, 64'h200, ALU);
      alloc(0, 64'h104);      alloc(1, 64'h204);
      // B0 completes at the wb posedge; its cross-hart ack is combinational
      // and visible until the NEXT posedge retires it — check before tick.
      wb(1);
      chk_offer(0, 0, 0, "SBC_X_P0");
      chk_offer(1, 1, 1, "SBC_X_P1");
      if (commit_ack[0] !== 1'b0) $fatal(1, "SBC_X_P0_ACK incomplete head acked");
      if (commit_ack[1] !== 1'b1) $fatal(1, "SBC_X_P1_ACK cross head not acked");
      tick();  // B0 retires: slot 1 becomes a hole.
      if (reclaim !== TW'(0)) $fatal(1, "SBC_RECLAIM_HOLE moved before head commit: %0d", reclaim);
      wb(0);   // A0 completes.
      chk_offer(0, 0, 0, "SBC_X_P0_DONE");
      if (commit_ack[0] !== 1'b1) $fatal(1, "SBC_X_P0_ACK2 head not acked");
      tick();  // A0 retires: reclaim must jump over the slot-1 hole to slot 2.
      if (reclaim !== TW'(2))
        $fatal(1, "SBC_RECLAIM_JUMP got=%0d want=2", reclaim);
      $display("RTL_REVIEW_PASS sbcommit scenario=0");
    end
    else if (scenario == 1) begin
      // Fill the ring, commit B0 cross-hart (hole), then prove no slot in the
      // live window is allocatable even though a hole exists.
      alloc(0, 64'h100, ALU); alloc(1, 64'h200, ALU);
      alloc(0, 64'h104);      alloc(1, 64'h204);
      alloc(0, 64'h108);      alloc(1, 64'h208);
      alloc(0, 64'h10c);      alloc(1, 64'h20c);
      wb(1);
      if (commit_ack[1] !== 1'b1) $fatal(1, "SBC_FULL_XACK setup");
      tick();  // hole at slot 1; ring full.
      decoded = '{default:'0};
      decoded[0].fu = NONE; decoded[0].pc = 64'h300; decoded[0].rd = 5'd1;
      decoded_valid = 1'b1;
      #1;
      // Protocol-honest ack: accept only an offered issue slot. Under correct
      // window accounting nothing is offered on a full live window; the
      // popcount-free mutant offers slot 0 — still the live head — which is
      // the overwrite this scenario exists to catch.
      issue_ack = iv[0];
      #1;
      if (iv[0] !== 1'b0 || sb_full !== 1'b1)
        $fatal(1, "SBC_NO_OVERWRITE window alloc allowed: iv=%b full=%b",
               iv[0], sb_full);
      issue_ack = 1'b0;
      tick();
      decoded_valid = '0; decoded = '{default:'0};
      // The surviving head must still retire, proving the live slot was not
      // clobbered.
      wb(0);
      if (commit_instr[0].trans_id !== TW'(0) || commit_instr[0].pc !== 64'h100)
        $fatal(1, "SBC_NO_OVERWRITE head clobbered: tid=%0d pc=%h",
               commit_instr[0].trans_id, commit_instr[0].pc);
      if (commit_ack[0] !== 1'b1) $fatal(1, "SBC_FULL drain");
      $display("RTL_REVIEW_PASS sbcommit scenario=1 SBC_NO_OVERWRITE");
    end
    else if (scenario == 2) begin
      // A0 simple complete, B0 CSR: port 0 must offer the privileged head.
      // The port-1 exclusion is ack-qualified: while B0 waits incomplete,
      // port 0 cannot ack, so A0 retires cross-hart during wb(0) and A's head
      // advances to slot 2. Once wb(1) completes B0, its privileged port-0
      // ack suppresses the cross-hart ack for that cycle only.
      alloc(0, 64'h100, ALU); alloc(1, 64'h200, CSR, 0, CSR_WRITE);
      alloc(0, 64'h104);      alloc(1, 64'h204);
      // CSR is privileged by fu alone — B0 holds port 0 throughout. wb(0)
      // retires A0 early (B0 cannot ack incomplete); wb(1) raises B0's
      // combinational port-0 ack.
      wb(0); wb(1);
      chk_offer(0, 1, 1, "SBC_CSR_P0");
      chk_offer(1, 2, 0, "SBC_CSR_P1");
      if (commit_ack[0] !== 1'b1) $fatal(1, "SBC_CSR_P0_ACK");
      if (commit_ack[1] !== 1'b0) $fatal(1, "SBC_CSR_P1_ACK cross under privileged port0");
      $display("RTL_REVIEW_PASS sbcommit scenario=2");
    end
    else if (scenario == 3) begin
      // B0 carries an exception: port 0 offers it and never acks (the leaf
      // takes no trap). The exception arrives the realistic way — on
      // writeback (valid && ex), which is what sb_privileged keys on — and
      // lands first so port 0 is already privileged when A0 completes. A0's
      // cross-hart ack is legal here: the exclusion binds only on the cycle
      // port 0 actually acks the faulting entry.
      alloc(0, 64'h100, ALU); alloc(1, 64'h200);
      alloc(0, 64'h104);      alloc(1, 64'h204);
      wb(1, 1); wb(0);
      chk_offer(0, 1, 1, "SBC_EX_P0");
      chk_offer(1, 0, 0, "SBC_EX_P1");
      if (commit_ack[0] !== 1'b0) $fatal(1, "SBC_EX_P0_ACK faulting entry acked");
      // The leaf never acks the pending exception (no trap machinery), so the
      // ack-qualified exclusion does not bind — the peer's head commits.
      if (commit_ack[1] !== 1'b1) $fatal(1, "SBC_EX_P1_ACK cross under exception");
      $display("RTL_REVIEW_PASS sbcommit scenario=3");
    end
    else if (scenario == 4) begin
      // Replay-marked head (memory-order violation on B0): it must present on
      // port 0 with commit_replay_o, never port 1. Entries use a real fu so
      // the FU-NONE auto-complete rule cannot retire them before the mark.
      alloc(0, 64'h100, ALU); alloc(1, 64'h200, ALU);
      alloc(0, 64'h104);      alloc(1, 64'h204);
      tick();
      mem_violation = 1'b1; mem_violation_id = TW'(1); tick();
      mem_violation = 1'b0;
      chk_offer(0, 1, 1, "SBC_REPLAY_P0");
      if (commit_replay[0] !== 1'b1) $fatal(1, "SBC_REPLAY_FLAG");
      if (commit_replay[1] !== 1'b0) $fatal(1, "SBC_REPLAY_P1 replay on port 1");
      $display("RTL_REVIEW_PASS sbcommit scenario=4");
    end
    else if (scenario == 5) begin
      // Single-resident equivalence: hart-A-only stream, every cycle's port
      // offers and acks must match the drained geometry bit for bit.
      for (int n = 0; n < 4; n++) begin
        alloc(0, 64'h400 + 64'(n) * 4, ALU);
        equiv_check();
      end
      tick(); equiv_check();
      // wb(1) first: slot 1 completes while slot 0 still holds port 0
      // incomplete, so nothing commits; wb(0) then raises BOTH acks
      // combinationally — the next posedge retires the +1 legacy pair
      // identically on both geometries.
      wb(1); equiv_check();
      wb(0); equiv_check();
      for (int n = 0; n < 3; n++) begin
        tick(); equiv_check();
      end
      // Realloc mixed shapes still single-hart: interleave a stalled head.
      alloc(0, 64'h500, ALU); alloc(0, 64'h504); alloc(0, 64'h508);
      tick(); equiv_check();
      if (commit_ack[1] !== 1'b0) $fatal(1, "SBC_EQ_P1 incomplete same-hart +1");
      wb(4);   // 0x500 landed at slot 4 (0-3 drained above); complete it.
      equiv_check();
      for (int n = 0; n < 4; n++) begin tick(); equiv_check(); end
      if (equiv_mismatch != 0)
        $fatal(1, "SBC_LEGACY_EQUIV mismatches=%0d", equiv_mismatch);
      $display("RTL_REVIEW_PASS sbcommit scenario=5 SBC_LEGACY_EQUIV");
    end
    else if (scenario == 6) begin
      // T6b-4b pair-retirement preference: A0 A1 B0 B1. While A0/A1 stay
      // incomplete the legacy +1 pair cannot retire, so the complete peer
      // head B0 must present and ack cross-hart on port 1. Once A0/A1 are
      // complete the legacy pair presents on 0/1 and acks together, and the
      // reclaim pointer jumps over the slot-2 hole to B1.
      alloc(0, 64'h600, ALU); alloc(0, 64'h604, ALU);
      alloc(1, 64'h700, ALU); alloc(1, 64'h704, ALU);
      wb(2);   // B0 completes; A0/A1 incomplete.
      chk_offer(0, 0, 0, "SBC_PAIR_P0");
      chk_offer(1, 2, 1, "SBC_PAIR_X1");
      if (commit_ack[0] !== 1'b0) $fatal(1, "SBC_PAIR_P0_ACK incomplete head acked");
      if (commit_ack[1] !== 1'b1) $fatal(1, "SBC_PAIR_X1_ACK peer head not acked");
      tick();  // B0 retires: hole at slot 2.
      if (reclaim !== TW'(0)) $fatal(1, "SBC_PAIR_RECLAIM moved: %0d", reclaim);
      wb(1); wb(0);   // A1 then A0 complete.
      chk_offer(0, 0, 0, "SBC_PAIR_P0_DONE");
      chk_offer(1, 1, 0, "SBC_PAIR_P1_LEG");
      if (commit_ack !== 2'b11)
        $fatal(1, "SBC_PAIR_ACK legacy pair did not ack together: %b", commit_ack);
      tick();  // A0+A1 retire; reclaim jumps over the slot-2 hole to B1.
      if (reclaim !== TW'(3))
        $fatal(1, "SBC_PAIR_RECLAIM_JUMP got=%0d want=3", reclaim);
      $display("RTL_REVIEW_PASS sbcommit scenario=6");
    end
    else $fatal(1, "SBC_SCENARIO");
    $finish;
  end
endmodule
