// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// g6lc_ai_pe_dot_pipe vs g6lc_ai_pe_dot: bit-identical sums, latency equal to
// $clog2(Lanes)+5 (the float pipe's observed valid_o), back-to-back issue with alternating
// INT8/INT4 operands and valid masks. Random operands against the
// combinational cell as the oracle (two's-complement wrap is associative, so
// the oracle is exact).
module tb_g6lc_ai_pe_dot_pipe #(
    parameter int unsigned LANES = 4
);
  localparam int unsigned LAT = $clog2(LANES < 1 ? 1 : LANES) + 5;
  logic clk = 0, rst_n = 0;
  logic signed [7:0] a [LANES];
  logic signed [7:0] b [LANES];
  logic              v [LANES];
  logic [2:0]        fmt;
  logic              start;
  logic [31:0]       ref_sum, pipe_sum;
  logic              pipe_valid;

  g6lc_ai_pe_dot #(.Lanes(LANES)) i_ref (
      .a_i(a), .b_i(b), .valid_i(v), .numfmt_i(fmt), .sum_o(ref_sum));
  g6lc_ai_pe_dot_pipe #(.Lanes(LANES)) i_dut (
      .clk_i(clk), .rst_ni(rst_n), .start_i(start), .a_i(a), .b_i(b),
      .valid_i(v), .numfmt_i(fmt), .valid_o(pipe_valid), .sum_o(pipe_sum));

  // expected results queue (issue order)
  logic [31:0] exp_q[$];
  int unsigned checked = 0, failed = 0, issued = 0, returned = 0;
  int unsigned t = 0;

  always @(posedge clk) begin
    if (rst_n) begin
      t++;
      if (pipe_valid) begin
        returned++;
        if (exp_q.size() == 0) begin
          failed++; $display("FAIL unexpected valid_o at t=%0d", t);
        end else begin
          automatic logic [31:0] e = exp_q.pop_front();
          checked++;
          if (pipe_sum !== e) begin
            failed++;
            $display("FAIL t=%0d sum=%h expected=%h", t, pipe_sum, e);
          end
        end
      end
    end
  end

  task automatic drive(input bit do_start, input bit int4, input int seed_mask);
    for (int unsigned l = 0; l < LANES; l++) begin
      a[l] = $urandom();
      b[l] = $urandom();
      v[l] = (seed_mask == 0) ? 1'b1 : (seed_mask == 1 ? l[0] : $urandom_range(0, 1));
    end
    fmt   = int4 ? 3'd1 : 3'd0;
    start = do_start;
  endtask

  initial begin
    for (int unsigned l = 0; l < LANES; l++) begin a[l] = 0; b[l] = 0; v[l] = 0; end
    fmt = 0; start = 0;
    repeat (3) begin #5 clk = 1; #5 clk = 0; end
    rst_n = 1;
    // single transaction, measure latency
    drive(1, 0, 0);
    #1 exp_q.push_back(ref_sum);   // let the combinational oracle settle
    #4 clk = 1; #5 clk = 0; start = 0;
    begin
      automatic int unsigned waited = 0;
      while (!pipe_valid && waited < 64) begin #5 clk = 1; #5 clk = 0; waited++; end
      // valid_o is sampled after the edge that set it: LAT edges from the
      // issue edge means the (LAT)th tick after issue
      if (waited + 1 != LAT) begin
        failed++; $display("FAIL latency: valid after %0d cycles, expected %0d", waited + 1, LAT);
      end
    end
    // back-to-back, alternating formats and masks, with bubbles
    for (int unsigned n = 0; n < 400; n++) begin
      automatic bit go = ($urandom_range(0, 3) != 0);
      drive(go, $urandom_range(0, 1), $urandom_range(0, 2));
      #1 if (go) begin exp_q.push_back(ref_sum); issued++; end
      #4 clk = 1; #5 clk = 0;
    end
    start = 0;
    repeat (LAT + 4) begin #5 clk = 1; #5 clk = 0; end
    if (exp_q.size() != 0) begin failed++; $display("FAIL %0d results never returned", exp_q.size()); end
    if (failed == 0) $display("PE_DOT_PIPE_PASS lanes=%0d checked=%0d", LANES, checked);
    else $display("PE_DOT_PIPE_FAIL lanes=%0d failed=%0d checked=%0d", LANES, failed, checked);
    $finish;
  end
endmodule
