// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// tb_clmul_hyp8 - leaf for the hyp8 mult_clmul wired-row slice rewrite.
// 1000+ steps, independent polynomial-XOR golden, exact six-edge
// latency, id/op pass-through, flush and reset pending. Local config
// function supplies the g6lc_cfg_t (XLEN=64, TRANS_ID_BITS=5).
module tb_clmul_hyp8;
  import g6lc_core_pkg::*;
  import config_pkg::*;
  localparam int unsigned XLEN = 64;
  localparam int unsigned TID  = 5;

  function automatic g6lc_cfg_t mk_cfg();
    g6lc_cfg_t c = g6lc_cfg_empty;
    c.XLEN = 64; c.TRANS_ID_BITS = TID; c.NrLoadBufEntries = 8;
    return c;
  endfunction
  localparam g6lc_cfg_t CFG = mk_cfg();

  logic clk = 0, rst_n = 0, flush = 0;
  always #5 clk = ~clk;
  logic                 valid_i;
  logic [TID-1:0]       tid_i;
  fu_op                 op_i;
  logic [XLEN-1:0]      a_i, b_i;
  logic [XLEN-1:0]      clmul_o, clmulr_o;
  logic                 valid_o;
  logic [TID-1:0]       tid_o;
  fu_op                 op_o;

  mult_clmul #(.G6LCCfg(CFG), .HypCfg(g6lc_hyp_pkg::HypDefault)) i_dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .valid_i(valid_i), .trans_id_i(tid_i), .operation_i(op_i),
    .a_i(a_i), .b_i(b_i),
    .clmul_o(clmul_o), .clmulr_o(clmulr_o),
    .valid_o(valid_o), .trans_id_o(tid_o), .operation_o(op_o)
  );

  int unsigned checks = 0, errors = 0, published = 0, killed = 0;
  task automatic chk(input bit c, input string w);
    checks++; if (!c) begin errors++; $display("FAIL %s at %0t", w, $time); end
  endtask
  task automatic chkv(input logic [63:0] got, input logic [63:0] want,
                      input string w);
    checks++;
    if (got !== want) begin
      errors++; $display("FAIL %s got=%h want=%h at %0t", w, got, want, $time);
    end
  endtask

  function automatic logic [127:0] clmul_gold(input logic [63:0] a,
                                              input logic [63:0] b);
    logic [127:0] acc;
    acc = '0;
    for (int j = 0; j < 64; j++)
      if (b[j]) acc ^= 128'(a) << j;
    return acc;
  endfunction
  function automatic logic [63:0] brev(input logic [63:0] v);
    logic [63:0] r;
    for (int j = 0; j < 64; j++) r[j] = v[63-j];
    return r;
  endfunction

  typedef struct packed {logic v; logic [63:0] lo; logic [TID-1:0] tid;
                         fu_op op;} expected_t;
  expected_t expected[6];

  task automatic step(input bit reset_n, kill, issue,
                      input logic [63:0] a, b,
                      input logic [TID-1:0] tid, input fu_op op);
    logic [127:0] gold;
    @(negedge clk); rst_n = reset_n; flush = kill; valid_i = issue;
                    a_i = a; b_i = b; tid_i = tid; op_i = op;
    @(posedge clk);
    if (!reset_n || kill) begin
      for (int k = 0; k < 6; k++) if (expected[k].v) killed++;
      for (int k = 0; k < 6; k++) expected[k] = '0;
    end else begin
      for (int k = 5; k > 0; k--) expected[k] = expected[k-1];
      gold = clmul_gold(a, b);
      expected[0] = '{v: issue, lo: gold[63:0], tid: tid, op: op};
      if ($test$plusargs("negative_oracle") && issue) expected[0].lo ^= 64'd1;
    end
    #1;
    chk(valid_o === expected[5].v, "six-edge valid");
    if (expected[5].v) begin
      chkv(clmul_o, expected[5].lo, "polynomial");
      chkv(clmulr_o, brev(expected[5].lo), "reverse");
      chk(tid_o === expected[5].tid, "identity");
      chk(op_o === expected[5].op, "operation");
      published++;
    end
  endtask

  initial begin
    int unsigned seed = 32'h94c1e001;
    valid_i = 0; tid_i = '0; op_i = CLMUL; a_i = '0; b_i = '0;
    for (int k = 0; k < 6; k++) expected[k] = '0;
    step(0, 0, 0, '0, '0, '0, CLMUL);   // held low
    step(0, 0, 0, '0, '0, '0, CLMUL);
    for (int t = 0; t < 1000; t++) begin : gen_tok
      logic [63:0] ra, rb;
      bit issue;
      seed = seed ^ (seed << 13); seed = seed ^ (seed >> 17); seed = seed ^ (seed << 5);
      ra = {seed, seed ^ 32'hA5A5A5A5};
      seed = seed ^ (seed << 13); seed = seed ^ (seed >> 17); seed = seed ^ (seed << 5);
      rb = {seed, seed ^ 32'h5A5A5A5A};
      case (t)
        0: begin ra = 64'hFFFFFFFFFFFFFFFF; rb = 64'hFFFFFFFFFFFFFFFF; end
        1: begin ra = 64'h8000000000000000; rb = 64'h8000000000000000; end
        2: begin ra = 64'd1; rb = 64'hFFFFFFFFFFFFFFFF; end
        3: begin ra = 64'h0123456789ABCDEF; rb = 64'hFEDCBA9876543210; end
        4: begin ra = '0; rb = '0; end
        5: begin ra = 64'hAAAAAAAAAAAAAAAA; rb = 64'h5555555555555555; end
        default: ;
      endcase
      issue = (t < 100) ? 1'b1 : ((t % 11 != 5) && (t % 11 != 6));
      if ((t % 37) == 10) begin
        step(1, 1, issue, ra, rb, TID'(t % 32),
             (t % 3 == 0) ? CLMULR : (t % 3 == 1) ? CLMULH : CLMUL);
      end else if ((t % 239) == 87) begin
        step(0, 0, issue, ra, rb, TID'(t % 32), CLMUL);
        step(1, 0, 0, '0, '0, '0, CLMUL);   // resync one cycle
      end else begin
        step(1, 0, issue, ra, rb, TID'(t % 32),
             (t % 3 == 0) ? CLMULR : (t % 3 == 1) ? CLMULH : CLMUL);
      end
    end
    for (int d = 0; d < 8; d++) step(1, 0, 0, '0, '0, '0, CLMUL);
    chk(published > 400, "published volume");
    chk(killed > 0, "kill coverage");
    if (errors == 0) $display("PASS tb_clmul_hyp8 checks=%0d", checks);
    else begin
      $display("FAIL tb_clmul_hyp8 errors=%0d checks=%0d", errors, checks);
      $fatal(1);
    end
    $finish;
  end
  initial begin
    #20000000;
    $display("FAIL tb_clmul_hyp8 TIMEOUT checks=%0d", checks); $fatal(1);
  end
endmodule
