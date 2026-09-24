// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// T6b-4b review leaf: transaction-id keyed ROB frees. Under per-hart commit
// heads the committing scoreboard tid is not the ROB head slot, so
// retire_ack_i[r] must free the slot carrying retire_tid_i[r] — occupancy
// (count) stays exact and the report-only head re-anchors on the oldest
// remaining entry. G6LC_MUT_ROB_POSITIONAL_FREE restores head+r frees and
// must fail with ROB_TID_FREE / ROB_COUNT.
module tb_g6lc_rob;
  localparam int ROB_ENTRIES = 8;
  localparam int ROB_W       = 3;
  localparam int NR_ALLOC    = 2;
  localparam int NR_RETIRE   = 2;
  localparam int NR_COMPLETE = 2;
  localparam int TID_W       = 3;
  localparam int NR_SB       = 8;

  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  task automatic tick; @(negedge clk); #1; @(posedge clk); #1; endtask

  logic flush=0;
  logic [NR_SB-1:0] cancelled='0;
  logic [NR_ALLOC-1:0] alloc_v='0;
  logic [NR_ALLOC-1:0][15:0] alloc_e='0;
  logic [NR_ALLOC-1:0][TID_W-1:0] alloc_tid='0;
  logic [NR_ALLOC-1:0][ROB_W-1:0] alloc_id;
  logic full;
  logic [NR_COMPLETE-1:0] complete_v='0;
  logic [NR_COMPLETE-1:0][TID_W-1:0] complete_tid='0;
  logic [NR_COMPLETE-1:0] complete_exc='0;
  logic [NR_RETIRE-1:0] retire_v;
  logic [15:0][NR_RETIRE-1:0] retire_e;
  logic [NR_RETIRE-1:0][ROB_W-1:0] retire_id;
  logic [NR_RETIRE-1:0] retire_ack='0;
  logic [NR_RETIRE-1:0][TID_W-1:0] retire_tid='0;

  g6lc_rob #(.ROB_ENTRIES(ROB_ENTRIES),.ROB_W(ROB_W),.NR_ALLOC(NR_ALLOC),
      .NR_RETIRE(NR_RETIRE),.NR_COMPLETE(NR_COMPLETE),.TID_W(TID_W),
      .NR_SB(NR_SB),.entry_t(logic[15:0])) dut (
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.cancelled_mask_i(cancelled),
    .alloc_valid_i(alloc_v),.alloc_entry_i(alloc_e),.alloc_tid_i(alloc_tid),
    .alloc_id_o(alloc_id),.full_o(full),
    .complete_valid_i(complete_v),.complete_tid_i(complete_tid),
    .complete_exc_i(complete_exc),
    .retire_valid_o(retire_v),.retire_entry_o(retire_e),.retire_id_o(retire_id),
    .retire_ack_i(retire_ack),.retire_tid_i(retire_tid));

  task automatic alloc2(input int t0, input int t1);
    alloc_v = 2'b11;
    alloc_tid[0] = TID_W'(t0); alloc_tid[1] = TID_W'(t1);
    alloc_e[0] = 16'(16'hA000 + t0); alloc_e[1] = 16'(16'hA000 + t1);
    tick(); alloc_v = '0;
  endtask

  task automatic complete(input int t0, input int t1 = -1);
    complete_v[0] = 1'b1; complete_tid[0] = TID_W'(t0);
    if (t1 >= 0) begin complete_v[1] = 1'b1; complete_tid[1] = TID_W'(t1); end
    tick(); complete_v = '0;
  endtask

  task automatic retire(input int p, input int tid);
    retire_ack[p] = 1'b1; retire_tid[p] = TID_W'(tid);
    tick(); retire_ack[p] = 1'b0;
  endtask

  int scenario;
  bit negative;
  initial begin
    negative = $test$plusargs("oracle_negative");
    if (!$value$plusargs("scenario=%d", scenario)) scenario = 0;
    repeat (2) tick(); rst_n = 1; repeat (2) tick();

    if (scenario == 0) begin
      // Alloc 4 (tids 0..3), complete all, then free strictly out of ring
      // order: tid2 first (a cross-hart commit), then tid0, tid3, tid1.
      alloc2(0, 1); alloc2(2, 3);
      complete(0, 1); complete(2, 3);
      if (dut.count_q !== 4) $fatal(1, "ROB_COUNT alloc got=%0d", dut.count_q);
      retire(0, 2);
      if (dut.count_q !== 3) $fatal(1, "ROB_COUNT free tid2 got=%0d", dut.count_q);
      if (dut.rob_q[2].valid !== 1'b0 || dut.rob_q[0].valid !== 1'b1)
        $fatal(1, "ROB_TID_FREE wrong slot freed: q2=%b q0=%b",
               dut.rob_q[2].valid, dut.rob_q[0].valid);
      if (dut.head_q !== 0)
        $fatal(1, "ROB_TID_FREE head drifted to %0d with slot0 live", dut.head_q);
      retire(0, 0); retire(1, 3);
      if (dut.count_q !== 1) $fatal(1, "ROB_COUNT mid got=%0d", dut.count_q);
      if (dut.head_q !== 1)
        $fatal(1, "ROB_TID_FREE head not re-anchored on oldest live: %0d", dut.head_q);
      retire(0, 1);
      if (dut.count_q !== 0) $fatal(1, "ROB_COUNT drain got=%0d", dut.count_q);
      $display("RTL_REVIEW_PASS rob scenario=0 ROB_TID_FREE");
    end
    else if (scenario == 1) begin
      // Dual-port same-cycle frees of two different harts' tids.
      alloc2(0, 1); alloc2(2, 3);
      complete(0, 1); complete(2, 3);
      retire_ack = 2'b11; retire_tid[0] = TID_W'(1); retire_tid[1] = TID_W'(3);
      tick(); retire_ack = '0;
      if (dut.count_q !== 2) $fatal(1, "ROB_COUNT dual got=%0d", dut.count_q);
      if (dut.rob_q[1].valid || dut.rob_q[3].valid ||
          !dut.rob_q[0].valid || !dut.rob_q[2].valid)
        $fatal(1, "ROB_TID_FREE dual wrong slots");
      $display("RTL_REVIEW_PASS rob scenario=1");
    end
    else $fatal(1, "ROB_SCENARIO");
    $finish;
  end
endmodule
