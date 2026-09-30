// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Core-side ai.enq / ai.poll producer contract against a held-valid island seam.
`timescale 1ns/1ps
module tb_g6lc_ai_enq_ready;
  import g6lc_ai_instr_pkg::*;
  localparam int XLEN = 64;
  typedef logic [1:0][XLEN-1:0] registers_t;
  logic clk = 0, rst_n = 0;
  always #5 clk = !clk;
  logic valid = 0, ready = 1, attached = 1, q_en = 1;
  registers_t regs = '0;
  opcode_t opcode = AI_ENQ;
  logic [31:0] instr = 32'h0005D55B;  // rd=10 rs1=11 rs2=0 (tile/acc indices ride here)
  logic isl_done = 0;
  logic [31:0] isl_ticket = 0;
  logic [15:0] isl_status = 0;
  logic isl_retired_valid = 0;
  logic [31:0] isl_retired_ticket = 0;
  logic sb_valid, res_valid, res_we, busy;
  logic [7:0] sb_qid;
  // Island-side ticket allocation (g6lc_ai_island_top SbTicketAlloc): one stream,
  // advanced on every accepted kick; the coprocessor must return THIS value.
  logic [31:0] isl_alloc = 0;
  logic alloc_set_v = 0; logic [31:0] alloc_set = 0;
  always @(posedge clk) begin
    if (alloc_set_v) isl_alloc <= alloc_set;
    else if (rst_n && sb_valid && ready && attached) isl_alloc <= isl_alloc + 1;
  end
  logic [31:0] sb_ticket;
  logic [XLEN-1:0] sb_ptr, result;
  int unsigned held_cycles, results;

  g6lc_ai_exec #(.NrRgprPorts(2), .XLEN(XLEN), .AiCfg(config_pkg::AiCfgVaTurboTest),
                 .hartid_t(logic), .id_t(logic [3:0]), .registers_t(registers_t)) dut (
      .clk_i(clk), .rst_ni(rst_n), .valid_i(valid), .registers_i(regs), .opcode_i(opcode),
      .instr_i(instr), .hartid_i(1'b0), .id_i(4'd3), .rd_i(5'd10),
      .aicfg_i('0), .ais_i(AiInitial), .ai_q_en_i(q_en), .ai_qid_i(8'd1),
      .isl_has_completion_i(isl_done), .isl_last_ticket_i(isl_ticket), .isl_last_status_i(isl_status),
      .isl_retired_valid_i(isl_retired_valid), .isl_retired_ticket_i(isl_retired_ticket),
      .isl_attached_i(attached), .sb_enq_ready_i(ready), .sb_enq_ticket_i(isl_alloc), .testmode_i(1'b0),
      .setcfg_we_o(), .setcfg_wdata_o(), .dirty_o(), .busy_o(busy),
      .sb_enq_valid_o(sb_valid), .sb_qid_o(sb_qid), .sb_ticket_o(sb_ticket), .sb_desc_ptr_o(sb_ptr),
      .pmu_op_o(), .pmu_mma_o(), .pmu_post_o(), .pmu_t0_o(),
      .result_o(result), .hartid_o(), .id_o(), .rd_o(), .valid_o(res_valid), .we_o(res_we)
  );

  always @(posedge clk) if (rst_n && res_valid) results++;

  task automatic issue(input opcode_t op, input logic [XLEN-1:0] rs1);
    @(negedge clk);
    opcode = op; regs[0] = rs1; valid = 1;
    @(negedge clk);
    valid = 0;
  endtask

  task automatic expect_result(input logic [XLEN-1:0] want, input string tag);
    int guard = 0;
    while (!res_valid && guard < 50) begin @(negedge clk); guard++; end
    if (!res_valid || !res_we || result !== want) $fatal(1, "%s got=%h want=%h", tag, result, want);
    @(negedge clk);
  endtask

  initial begin
    results = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    // Held kick: READY low for 12 cycles, identity stable, no result, issue stalled.
    ready = 0;
    issue(AI_ENQ, 64'h8000_0400);
    held_cycles = 0;
    repeat (12) begin
      @(negedge clk);
      if (!sb_valid || sb_ticket !== 0 || sb_qid !== 1 || sb_ptr !== 64'h8000_0400 || res_valid || !busy)
        $fatal(1, "ENQ_HOLD lost identity or completed early");
      held_cycles++;
    end
    ready = 1;
    expect_result(0, "ENQ_TICKET0");
    @(negedge clk);
    if (sb_valid) $fatal(1, "ENQ_VALID not dropped after acceptance");
    // Legacy pulse: READY high -> exactly one VALID cycle, ticket 1.
    issue(AI_ENQ, 0);
    expect_result(1, "ENQ_TICKET1");
    // Attached island: allocated ticket is NOT complete until the island says so.
    issue(AI_POLL, 0);
    expect_result(POLL_PENDING, "POLL_ATTACHED_PENDING");
    isl_done = 1; isl_ticket = 0; isl_status = 0;
    issue(AI_POLL, 0);
    expect_result(POLL_OK, "POLL_ATTACHED_OK");
    isl_ticket = 1; isl_status = 16'd5;
    issue(AI_POLL, 1);
    expect_result(POLL_ERR, "POLL_ATTACHED_ERR");
    issue(AI_POLL, 7);
    expect_result(POLL_PENDING, "POLL_FUTURE");
    // Behind the head: ticket 0 is no longer the head (1 is) and not yet claimed
    // knowledge -- pending without the watermark, complete once the island's
    // retired watermark covers it; a ticket above the watermark stays pending.
    issue(AI_POLL, 0);
    expect_result(POLL_PENDING, "POLL_BEHIND_HEAD_NO_WATERMARK");
    isl_retired_valid = 1; isl_retired_ticket = 1;
    issue(AI_POLL, 0);
    expect_result(POLL_OK, "POLL_BEHIND_HEAD_RETIRED");
    issue(AI_POLL, 2);
    expect_result(POLL_PENDING, "POLL_ABOVE_WATERMARK");
    isl_retired_valid = 0;
    // Unattached bring-up stub keeps local completion for allocated tickets only.
    attached = 0; isl_done = 0;
    issue(AI_POLL, 1);
    expect_result(POLL_OK, "POLL_STUB_LOCAL");
    issue(AI_POLL, 2);
    expect_result(POLL_PENDING, "POLL_STUB_FUTURE");
    // Queue disabled: refused immediately, no kick, ticket counter untouched.
    q_en = 0;
    issue(AI_ENQ, 0);
    expect_result(ENQ_FULL, "ENQ_DISABLED");
    q_en = 1;
    issue(AI_ENQ, 0);
    expect_result(2, "ENQ_TICKET2");
    // Multi-producer stream: another core's kicks moved the island's counter on;
    // the ticket returned is the island's, and the local counter follows it so the
    // unattached fallback keeps counting from there.
    attached = 1;
    alloc_set = 9; alloc_set_v = 1; @(negedge clk); alloc_set_v = 0;
    issue(AI_ENQ, 0);
    expect_result(9, "ENQ_TICKET_ISLAND_STREAM");
    attached = 0;
    issue(AI_POLL, 9);
    expect_result(POLL_OK, "POLL_STUB_FOLLOWS_ISLAND");
    issue(AI_POLL, 10);
    expect_result(POLL_PENDING, "POLL_STUB_FOLLOWS_ISLAND_FUTURE");
    attached = 1;
    // Accumulator read path (extracted request process): 1x1x1 MMA of tile0[0]=3
    // with itself lands 9 in acc0; MVACC reads it back; RELACC clears it.
    instr = 32'h0000005B;  // rd=0 rs1=0 rs2=0
    issue(AI_MVTA, 64'd3);
    while (busy) @(negedge clk);
    @(negedge clk);
    issue(AI_MMA_S8, 0);
    while (busy) @(negedge clk);
    @(negedge clk);
    instr = 32'h0000055B;  // rd=10 (GPR), rs1=acc0, rs2=elem0
    issue(AI_MVACC, 0);
    expect_result(9, "MVACC_AFTER_MMA");
    instr = 32'h0000005B;
    issue(AI_RELACC, 0);
    while (busy) @(negedge clk);
    @(negedge clk);
    instr = 32'h0000055B;
    issue(AI_MVACC, 0);
    expect_result(0, "MVACC_AFTER_RELACC");
    if (results != 21 || held_cycles != 12) $fatal(1, "ENQ_COUNT results=%0d", results);
    if ($test$plusargs("oracle_negative")) $fatal(1, "FAIL oracle negative control");
    $display("PASS ENQ_READY results=%0d held=%0d", results, held_cycles);
    $finish;
  end
  initial begin #200000; $fatal(1, "ENQ_READY timeout"); end
endmodule
