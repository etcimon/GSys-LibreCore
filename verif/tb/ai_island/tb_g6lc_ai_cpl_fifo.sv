// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_ai_cpl_fifo #(parameter int unsigned Depth = 16);
  localparam int CntW = Depth <= 1 ? 1 : $clog2(Depth + 1);
  typedef struct packed {
    logic [31:0] ticket;
    logic [15:0] status;
    logic irq;
  } entry_t;
  logic clk = 0;
  logic rst_n = 0;
  logic push = 0, pop = 0, empty, full;
  logic [CntW-1:0] count;
  entry_t incoming, head, expected[$];
  int unsigned sequence_id = 1;
  int unsigned checks = 0;
  logic [31:0] random_state = 32'h16ca_2026;
  always #5 clk = !clk;

  g6lc_ai_cpl_fifo #(.Depth(Depth)) dut (
      .clk_i(clk), .rst_ni(rst_n), .push_i(push), .pop_i(pop),
      .ticket_i(incoming.ticket), .status_i(incoming.status), .irq_i(incoming.irq),
      .empty_o(empty), .full_o(full), .count_o(count),
      .ticket_o(head.ticket), .status_o(head.status), .head_irq_o(head.irq)
  );

  task automatic step(input bit do_push, do_pop);
    bit accept_push, accept_pop;
    entry_t discarded;
    int old_size;
    @(negedge clk);
    old_size = expected.size();
    incoming = '{ticket: sequence_id, status: 16'(sequence_id ^ 32'h59a5), irq: sequence_id[0]};
    sequence_id++;
    push = do_push;
    pop = do_pop;
    accept_pop = do_pop && expected.size() != 0;
    accept_push = do_push && (expected.size() < Depth || accept_pop);
    if (accept_pop) begin
      discarded = expected.pop_front();
      if (discarded !== head) $fatal(1, "CPL_FIFO_POP_IDENTITY");
    end
    if (accept_push) expected.push_back(incoming);
    if (expected.size() != old_size + int'(accept_push) - int'(accept_pop))
      $fatal(1, "CPL_FIFO_REFERENCE_COUNT");
    @(posedge clk);
    #1;
    if (int'(count) != expected.size() || empty != (expected.size() == 0) || full != (expected.size() == Depth))
      $fatal(1, "CPL_FIFO_COUNT depth=%0d got=%0d expected=%0d push=%b pop=%b", Depth, count, expected.size(), do_push, do_pop);
    if (expected.size() != 0 && head !== expected[0])
      $fatal(1, "CPL_FIFO_HEAD depth=%0d got=%h expected=%h", Depth, head, expected[0]);
    if (32'(dut.wr_q) >= Depth || 32'(dut.rd_q) >= Depth)
      $fatal(1, "CPL_FIFO_POINTER depth=%0d wr=%0d rd=%0d", Depth, dut.wr_q, dut.rd_q);
    checks++;
  endtask

  initial begin
    incoming = '0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    step(0, 1);
    for (int round = 0; round < 5; round++) begin
      for (int i = 0; i < Depth; i++) step(1, 0);
      step(1, 0);
      if (!$test$plusargs("wrap_only")) step(1, 1);
      for (int i = 0; i < Depth; i++) step(0, 1);
      step(0, 1);
    end
    if (!$test$plusargs("wrap_only")) begin
      for (int i = 0; i < 512; i++) begin
        random_state = random_state * 32'd1664525 + 32'd1013904223;
        step(random_state[23], random_state[31]);
      end
      while (expected.size() != 0) step(0, 1);
    end
    if ($test$plusargs("oracle_negative")) $fatal(1, "FAIL oracle negative control");
    $display("PASS CPL_FIFO depth=%0d checks=%0d", Depth, checks);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "CPL_FIFO_TIMEOUT");
  end
endmodule
