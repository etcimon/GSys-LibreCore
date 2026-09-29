// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_ai_cmd_fifo #(parameter int unsigned Depth = 4);
  localparam int CountWidth = Depth > 1 ? $clog2(Depth + 1) : 1;
  logic clk = 0, rst_n = 0;
  logic push_valid = 0, push_ready, pop_valid, pop_ready = 0;
  logic [127:0] push_data = '0, pop_data;
  logic [CountWidth-1:0] count;
  logic [127:0] expected[$];
  logic [127:0] blocked_data;
  bit producer_blocked = 0, consumer_blocked = 0;
  int unsigned sequence_id = 1, pushes = 0, pops = 0, stalls = 0, simultaneous = 0;
  logic [31:0] random_state = 32'ha164_2026;
  always #5 clk = !clk;

  g6lc_ai_cmd_fifo #(.Depth(Depth)) dut (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .push_valid_i(push_valid), .push_ready_o(push_ready), .push_data_i(push_data),
      .pop_valid_o(pop_valid), .pop_ready_i(pop_ready), .pop_data_o(pop_data), .count_o(count)
  );

  task automatic step(input bit want_push, want_pop);
    logic [127:0] popped;
    bit push_fire, pop_fire;
    int old_size;
    @(negedge clk);
    if (!producer_blocked) begin
      push_valid = want_push;
      push_data = {sequence_id, ~sequence_id, sequence_id ^ 32'h1234_abcd, sequence_id + 32'h9012_3456};
    end
    pop_ready = want_pop;
    @(posedge clk);
    if (consumer_blocked && (!pop_valid || pop_data !== blocked_data))
      $fatal(1, "CMD_FIFO_STABILITY");
    if (pop_valid && (expected.size() == 0 || pop_data !== expected[0]))
      $fatal(1, "CMD_FIFO_HEAD depth=%0d got=%h", Depth, pop_data);
    push_fire = push_valid && push_ready;
    pop_fire = pop_valid && pop_ready;
    old_size = expected.size();
    if (pop_fire) begin
      popped = expected.pop_front();
      if (popped !== pop_data) $fatal(1, "CMD_FIFO_POP_IDENTITY");
      pops++;
    end
    if (push_fire) begin
      expected.push_back(push_data);
      pushes++;
      sequence_id++;
    end
    producer_blocked = push_valid && !push_ready;
    consumer_blocked = pop_valid && !pop_ready;
    blocked_data = pop_data;
    if (producer_blocked) stalls++;
    if (push_fire && pop_fire) simultaneous++;
    if (expected.size() != old_size + int'(push_fire) - int'(pop_fire))
      $fatal(1, "CMD_FIFO_REFERENCE_COUNT");
    #1;
    if (32'(count) != expected.size() || expected.size() > Depth)
      $fatal(1, "CMD_FIFO_COUNT depth=%0d count=%0d expected=%0d", Depth, count, expected.size());
  endtask

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    for (int round = 0; round < 5; round++) begin
      repeat (Depth + 4) step(1, 0);
      repeat (2 * Depth + 4) step(1, 1);
      while (expected.size() != 0 || producer_blocked) step(0, 1);
    end
    for (int i = 0; i < 1024; i++) begin
      random_state = random_state * 32'd1664525 + 32'd1013904223;
      step(random_state[21], random_state[30]);
    end
    while (expected.size() != 0 || producer_blocked) step(0, 1);
    step(0, 1);
    if (pushes != pops || pushes <= 2 * Depth || stalls == 0 || simultaneous == 0)
      $fatal(1, "CMD_FIFO_COVER pushes=%0d pops=%0d stalls=%0d simultaneous=%0d", pushes, pops, stalls, simultaneous);
    if ($test$plusargs("oracle_negative")) $fatal(1, "FAIL oracle negative control");
    $display("PASS CMD_FIFO depth=%0d pushes=%0d pops=%0d stalls=%0d simultaneous=%0d", Depth, pushes, pops, stalls, simultaneous);
    $finish;
  end
  initial begin
    #500000;
    $fatal(1, "CMD_FIFO_TIMEOUT");
  end
endmodule
