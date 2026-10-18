// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Side-by-side harness: the two-stage multiplier (`MultStages = 2`,
// sv-timing A115) against the one-register multiplier of the same source on
// random operands and every MUL/CLMUL operation; the two-stage result,
// valid and trans_id are compared one cycle after the one-stage ones.
module tb_mul_sbs;
  import ariane_pkg::*;
  localparam config_pkg::cva6_user_cfg_t UCfg1 = cva6_config_pkg::cva6_cfg;
  function automatic config_pkg::cva6_user_cfg_t with_stages(config_pkg::cva6_user_cfg_t c, int unsigned n);
    with_stages = c;
    with_stages.MultStages = n;
`ifdef SVT_MUL_XLEN
    with_stages.XLEN = `SVT_MUL_XLEN;
`endif
`ifdef SVT_MUL_RVB
    with_stages.RVB = `SVT_MUL_RVB;
`endif
  endfunction
`ifndef SVT_MUL_STAGES
`define SVT_MUL_STAGES 2
`endif
  // the staged instance's depth: 2 (A115) or 3 (A128); run with +lag=MultStages-1
  localparam int unsigned STAGES = `SVT_MUL_STAGES;
  localparam config_pkg::cva6_cfg_t Cfg1 = build_config_pkg::build_config(with_stages(UCfg1, 1));
  localparam config_pkg::cva6_cfg_t Cfg2 = build_config_pkg::build_config(with_stages(UCfg1, STAGES));
  logic clk = 1'b0, rst_ni = 1'b0;
  always #1 clk = ~clk;
  logic [Cfg1.TRANS_ID_BITS-1:0] trans_id_i;
  logic mult_valid_i;
  fu_op operation_i;
  logic [Cfg1.XLEN-1:0] operand_a_i, operand_b_i;
  logic [Cfg1.XLEN-1:0] result_1, result_2;
  logic valid_1, valid_2;
  logic [Cfg1.TRANS_ID_BITS-1:0] tid_1, tid_2;
  multiplier #(.CVA6Cfg(Cfg1)) u1 (.clk_i(clk), .rst_ni(rst_ni), .trans_id_i(trans_id_i), .mult_valid_i(mult_valid_i), .operation_i(operation_i), .operand_a_i(operand_a_i), .operand_b_i(operand_b_i), .result_o(result_1), .mult_valid_o(valid_1), .mult_trans_id_o(tid_1));
  multiplier #(.CVA6Cfg(Cfg2)) u2 (.clk_i(clk), .rst_ni(rst_ni), .trans_id_i(trans_id_i), .mult_valid_i(mult_valid_i), .operation_i(operation_i), .operand_a_i(operand_a_i), .operand_b_i(operand_b_i), .result_o(result_2), .mult_valid_o(valid_2), .mult_trans_id_o(tid_2));

  // the one-stage outputs delayed by `lag` cycles = what the staged version
  // must show: 1 for the two-stage multiplier, 2 for a three-stage one
  // (`+lag=N`, sv-timing A125 generate-scope stage on prod_sum)
  localparam int unsigned MAX_LAG = 4;
  int unsigned lag = 1;
  logic [MAX_LAG:1][Cfg1.XLEN-1:0] result_1_sh;
  logic [MAX_LAG:1] valid_1_sh;
  logic [MAX_LAG:1][Cfg1.TRANS_ID_BITS-1:0] tid_1_sh;
  always_ff @(posedge clk) begin
    result_1_sh[1] <= result_1;
    valid_1_sh[1]  <= valid_1;
    tid_1_sh[1]    <= tid_1;
    for (int unsigned k = 2; k <= MAX_LAG; k++) begin
      result_1_sh[k] <= result_1_sh[k-1];
      valid_1_sh[k]  <= valid_1_sh[k-1];
      tid_1_sh[k]    <= tid_1_sh[k-1];
    end
  end
  logic [Cfg1.XLEN-1:0] result_1_d;
  logic valid_1_d;
  logic [Cfg1.TRANS_ID_BITS-1:0] tid_1_d;
  assign result_1_d = result_1_sh[lag];
  assign valid_1_d  = valid_1_sh[lag];
  assign tid_1_d    = tid_1_sh[lag];

  fu_op ops[8] = '{MUL, MULH, MULHU, MULHSU, MULW, CLMUL, CLMULH, CLMULR};
  int unsigned cyc = 0, errors = 0, valids = 0, seed = 1;
  function automatic logic [63:0] rnd64();
    rnd64 = {$urandom, $urandom};
  endfunction
  function automatic logic [63:0] shaped(logic [63:0] r, logic [7:0] sel);
    // corners: 0, all-ones, min/max signed, small, one-hot, plus plain random
    case (sel % 8)
      0: shaped = '0;
      1: shaped = '1;
      2: shaped = 64'h8000_0000_0000_0000;
      3: shaped = 64'h7FFF_FFFF_FFFF_FFFF;
      4: shaped = 64'(r[7:0]);
      5: shaped = 64'd1 << r[5:0];
      6: shaped = {{32{r[31]}}, r[31:0]};
      default: shaped = r;
    endcase
  endfunction
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("lag=%d", lag)) lag = 1;
    if (lag < 1 || lag > MAX_LAG) lag = 1;
    void'($urandom(seed));
    #7 rst_ni = 1'b1;
  end
  always @(negedge clk) begin
    logic [63:0] r0, r1, r2;
    r0 = rnd64(); r1 = rnd64(); r2 = rnd64();
    mult_valid_i = (r0[7:0] < 8'd200);
    trans_id_i   = $bits(trans_id_i)'(r0[23:16]);
    operation_i  = ops[Cfg1.RVB ? int'(r0[10:8]) : int'(r0[10:8]) % 5];
    operand_a_i  = Cfg1.XLEN'(shaped(r1, r0[39:32]));
    operand_b_i  = Cfg1.XLEN'(shaped(r2, r0[47:40]));
  end
  always @(posedge clk) begin
    if (rst_ni) begin
      cyc++;
      if (cyc > 3 + lag) begin
        if (valid_1_d !== valid_2) begin errors++; if (errors < 10) $display("[%0d] valid mismatch 1-stage(d)=%b 2-stage=%b", cyc, valid_1_d, valid_2); end
        if (valid_2) begin
          valids++;
          if (result_1_d !== result_2) begin errors++; if (errors < 10) $display("[%0d] result mismatch 1-stage(d)=%h 2-stage=%h tid=%0d", cyc, result_1_d, result_2, tid_2); end
          if (tid_1_d !== tid_2) begin errors++; if (errors < 10) $display("[%0d] tid mismatch %0d vs %0d", cyc, tid_1_d, tid_2); end
        end
      end
      if (cyc == 300000) begin
        $display("%s tb_mul_sbs lag=%0d cycles=%0d valid_results=%0d errors=%0d", errors == 0 ? "PASS" : "FAIL", lag, cyc, valids, errors);
        if (errors != 0 || valids == 0) $fatal(1, "Multiplier comparison failed or was vacuous");
        $finish;
      end
    end
  end
endmodule

// Directed boundary check of the real mult wrapper, in addition to the
// arithmetic comparison above. A killed generation must never reappear
// when the cancellation mask clears or its TID is reused.
module tb_mul_lifetime;
  timeunit 1ns;
  timeprecision 1ps;
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t cfg();
    cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
    cfg.MultStages = `SVT_MUL_STAGES;
    cfg.OoOEn = 1;
  endfunction
  localparam config_pkg::cva6_cfg_t C = cfg();
  typedef struct packed {
    logic [C.TRANS_ID_BITS-1:0] trans_id;
    fu_op operation;
    logic [C.XLEN-1:0] operand_a, operand_b;
  } fu_t;
  logic clk = 0, rst_n = 0, flush = 0, valid_i = 0;
  logic [C.NR_SB_ENTRIES-1:0] cancelled = '0;
  logic [C.TRANS_ID_BITS-1:0] tid_drive = '0;
  logic [C.XLEN-1:0] a_drive = '0;
  fu_t fu;
  // Drive leaf nets and assemble the input continuously. This also keeps
  // task scheduling independent of packed-struct partial-write handling.
  assign fu = {tid_drive, MUL, a_drive, C.XLEN'(7)};
  logic valid_o, ready_o;
  logic [C.TRANS_ID_BITS-1:0] tid_o;
  logic [C.XLEN-1:0] result_o;
  always #1 clk = ~clk;
  mult #(.CVA6Cfg(C), .fu_data_t(fu_t)) dut (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i(cancelled),
      .fu_data_i(fu), .mult_valid_i(valid_i), .result_o,
      .mult_valid_o(valid_o), .mult_ready_o(ready_o), .mult_trans_id_o(tid_o));
  int checked = 0;
  // Reference model of the wrapper's lifetime contract, for any MultStages:
  // an operation issued at step k emerges at step k + MultStages - 1 with
  // data a*7 unless its slot was cancelled at any step from issue through
  // emergence (inclusive) or a flush happened in between.
  localparam int unsigned STAGES = `SVT_MUL_STAGES;
  bit          live  [16];
  int          issue [16];
  int          adata [16];
  int          step = 0;
  task automatic cycle(input bit send, input int tid, input int a,
                       input int kill_tid, input bit squash);
    bit expect_valid = 0;
    int expect_tid = 0, expect_data = 0;
    // what emerges this step (sampled after this step's posedge)
    for (int t = 0; t < 16; t++)
      if (live[t] && issue[t] + int'(STAGES) - 1 == step && t != kill_tid && !squash) begin
        expect_valid = 1; expect_tid = t; expect_data = adata[t] * 7;
      end
    @(negedge clk);
    valid_i = send;
    tid_drive = C.TRANS_ID_BITS'(tid);
    a_drive = C.XLEN'(a);
    #0.01;
    if (fu.trans_id !== C.TRANS_ID_BITS'(tid))
      $fatal(1, "MUL_STIMULUS TID was not driven");
    cancelled = '0;
    if (kill_tid >= 0) cancelled[kill_tid] = 1'b1;
    flush = squash;
    // the model's state after this step's edge
    if (squash) for (int t = 0; t < 16; t++) live[t] = 0;
    if (kill_tid >= 0) live[kill_tid] = 0;
    for (int t = 0; t < 16; t++)
      if (live[t] && issue[t] + int'(STAGES) - 1 == step) live[t] = 0;  // emerged
    if (send && !squash && kill_tid != tid) begin
      live[tid] = 1; issue[tid] = step; adata[tid] = a;
    end
    @(posedge clk);
    #0.1;
    if (valid_o !== expect_valid ||
        (expect_valid && (tid_o !== C.TRANS_ID_BITS'(expect_tid) ||
                          result_o !== C.XLEN'(expect_data))))
      $fatal(1, "MUL_LIFETIME step=%0d valid=%b tid=%0d data=%h expected=%b/%0d/%0d",
             checked, valid_o, tid_o, result_o, expect_valid, expect_tid, expect_data);
    checked++;
    step++;
  endtask
  initial begin
    for (int t = 0; t < 16; t++) live[t] = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    cycle(1, 1, 3, -1, 0);
    cycle(1, 2, 5, -1, 0);
    cycle(0, 0, 0, -1, 0);
    cycle(0, 0, 0, -1, 0);
    // Flush an outstanding multiply, then immediately reuse the slot.
    cycle(1, 3, 9, -1, 0);
    cycle(0, 0, 0, -1, 1);
    cycle(1, 3, 11, -1, 0);
    cycle(0, 0, 0, -1, 0);
    cycle(0, 0, 0, -1, 0);
    // Dispatch on a cancelled slot, then remove the mask before completion.
    cycle(1, 4, 13, 4, 0);
    cycle(0, 0, 0, -1, 0);
    cycle(0, 0, 0, -1, 0);
    // Cancel one stage while a different generation enters the pipeline.
    cycle(1, 5, 17, -1, 0);
    cycle(1, 6, 19, 5, 0);
    cycle(1, 5, 23, -1, 0);
    cycle(0, 0, 0, -1, 0);
    cycle(0, 0, 0, -1, 0);
    cycle(0, 0, 0, -1, 0);
    // Cancel at each pipeline age, including the output-use edge, then
    // remove the mask and reuse that TID. Drain before the next experiment.
    for (int age = 0; age < int'(STAGES); age++) begin
      cycle(1, 7, 29, age == 0 ? 7 : -1, 0);
      for (int k = 1; k < int'(STAGES); k++)
        cycle(0, 0, 0, k == age ? 7 : -1, 0);
      cycle(1, 7, 31, -1, 0);
      for (int k = 0; k < int'(STAGES); k++)
        cycle(0, 0, 0, -1, 0);
    end
    $display("PASS tb_mul_lifetime stages=%0d checks=%0d", STAGES, checked);
    $finish;
  end
endmodule
