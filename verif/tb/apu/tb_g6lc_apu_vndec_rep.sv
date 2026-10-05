// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Vector-driven integration test of g6lc_apu_vndec + g6lc_apu_vnrep.
// For every reply-vector case the decoder produces apu_vn_op_t from
// the CS words and the reply builder executes the reply ROM program
// into a word-addressed reply-window model; the emitted words are
// compared word-for-word with the golden reply.
//
//   cs[]        : ue_sm5_reply.hex (command words + golden reply words)
//   exp[]       : ue_sm5_reply.exp, REC_W=456 words per record:
//     0: cs_base  1: cs_len  2: result  3: exec_n
//     4..67:   exec_w[0..63]
//     68: rep_base  69: rep_len  70: exp_words
//     71..454: expected reply words (MAX_EXP=384, zero padded)
//     455: expected fault
//   Terminated by a {FFFFFFFF,FFFFFFFF} sentinel in words 0/1.
module tb_g6lc_apu_vndec_rep;
  import g6lc_apu_vn_pkg::*;

  localparam int REC_W = 456;
  localparam int MAX_EXP = 384;

  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  // ---- CS model (shared: vndec scans, vnrep echoes RBLOB) ----
  logic [31:0] cs   [0:65535];
  logic [31:0] expm [0:262143];
  logic [31:0] repm [0:65535];

  // ---- vndec ----
  logic        d_start = 0, d_busy, d_done, d_re;
  logic [15:0] d_base = '0, d_len = '0, d_addr;
  logic [31:0] d_rdata = '0;
  apu_vn_op_t  op;
  logic        off_busy, off_done, off_re;
  logic [15:0] off_addr;
  apu_vn_op_t  off_op;

  // ---- vnrep ----
  logic        r_start = 0, r_busy, r_done, r_fault;
  logic        r_re;
  logic [15:0] r_addr;
  logic [31:0] r_rdata = '0;
  logic        r_we;
  logic [15:0] r_waddr;
  logic [31:0] r_wdata;
  logic [15:0] r_words;
  logic [64*32-1:0] exec_w;
  logic [6:0]  exec_n;
  logic [31:0] result_r;
  logic [15:0] rep_base_r, rep_len_r;
  apu_vn_op_t  op_r;

  logic        roff_busy, roff_done, roff_fault, roff_re, roff_we;
  logic [15:0] roff_addr, roff_waddr, roff_words;
  logic [31:0] roff_wdata;

  // §7b decoder payload stream: reply vectors carry no expected-pay
  // section (the vndec TB covers payload contents); count the words so
  // the stream is at least exercised, and quiet-check the off engine.
  logic        pay_v, off_pv;
  logic [31:0] pay_d, off_pd;
  int          pay_n = 0;
  always @(posedge clk) if (pay_v) pay_n++;

  g6lc_apu_vndec #(.Enable(1'b1)) i_dec (
    .clk_i(clk), .rst_ni(rst_ni),
    .start_i(d_start), .cs_base_i(d_base), .cs_len_i(d_len),
    .cs_re_o(d_re), .cs_addr_o(d_addr), .cs_rdata_i(d_rdata),
    .pay_valid_o(pay_v), .pay_data_o(pay_d),
    .busy_o(d_busy), .done_o(d_done), .op_o(op));
  g6lc_apu_vndec_fixture #(.Enable(1'b0)) i_dec_off (
    .clk_i(clk), .rst_ni(rst_ni),
    .start_i(d_start), .cs_base_i(d_base), .cs_len_i(d_len),
    .cs_re_o(off_re), .cs_addr_o(off_addr), .cs_rdata_i(d_rdata),
    .pay_valid_o(off_pv), .pay_data_o(off_pd),
    .busy_o(off_busy), .done_o(off_done), .op_o(off_op));

  g6lc_apu_vnrep #(.Enable(1'b1)) i_rep (
    .clk_i(clk), .rst_ni(rst_ni),
    .start_i(r_start), .op_i(op_r), .result_i(result_r),
    .exec_w_i(exec_w), .exec_n_i(exec_n),
    .rep_base_i(rep_base_r), .rep_len_i(rep_len_r),
    .cs_base_i(d_base),
    .cs_re_o(r_re), .cs_addr_o(r_addr), .cs_rdata_i(r_rdata),
    .rep_we_o(r_we), .rep_addr_o(r_waddr), .rep_wdata_o(r_wdata),
    .busy_o(r_busy), .done_o(r_done), .rep_words_o(r_words),
    .fault_o(r_fault));
  g6lc_apu_vnrep_fixture #(.Enable(1'b0)) i_rep_off (
    .clk_i(clk), .rst_ni(rst_ni),
    .start_i(r_start), .op_i(op_r), .result_i(result_r),
    .exec_w_i(exec_w), .exec_n_i(exec_n),
    .rep_base_i(rep_base_r), .rep_len_i(rep_len_r),
    .cs_base_i(d_base),
    .cs_re_o(roff_re), .cs_addr_o(roff_addr), .cs_rdata_i(r_rdata),
    .rep_we_o(roff_we), .rep_addr_o(roff_waddr),
    .rep_wdata_o(roff_wdata),
    .busy_o(roff_busy), .done_o(roff_done),
    .rep_words_o(roff_words), .fault_o(roff_fault));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  // CS read: vndec and vnrep never overlap (sequential phases)
  always @(posedge clk) begin
    if (d_re) d_rdata <= cs[d_addr];
    if (r_re) r_rdata <= cs[r_addr];
  end
  // reply-window write model
  always @(posedge clk) if (r_we) repm[r_waddr] <= r_wdata;

  always @(negedge clk) begin
    if (off_re || off_busy || off_done || roff_re || roff_we ||
        roff_busy || roff_done || roff_fault ||
        off_op.cmd_type !== '0 || off_op.words !== '0 ||
        off_op.fault != APU_VN_FAULT_NONE ||
        off_pv || off_pd !== '0 ||
        roff_words !== '0)
      $fatal(1, "disabled engine active");
  end

  function automatic logic [31:0] ev(input int rec, input int w);
    return expm[rec * REC_W + w];
  endfunction

  int rec;
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL rec %0d: %s", rec, name);
      if (errors > 12) $fatal(1, "too many errors");
    end
  endtask

  int nw;
  initial begin
    for (int i = 0; i < $size(cs); i++) cs[i] = '0;
    for (int i = 0; i < $size(expm); i++) expm[i] = '0;
    for (int i = 0; i < $size(repm); i++) repm[i] = '0;
    $readmemh("vn_vectors/ue_sm5_reply.hex", cs, 0);
    $readmemh("vn_vectors/ue_sm5_reply.exp", expm, 0);
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    check("init quiet", !d_busy && !d_done && !d_re &&
                        !r_busy && !r_done && !r_we && !r_re);

    rec = 0;
    while (ev(rec, 0) !== 32'hFFFFFFFF) begin
      // ---- phase 1: decode the command ----
      @(negedge clk);
      d_base = 16'(ev(rec, 0)); d_len = 16'(ev(rec, 1));
      d_start = 1'b1;
      @(posedge clk);
      @(negedge clk); d_start = 1'b0;
      while (!d_done) @(negedge clk);
      check("decode fault-free", op.fault == APU_VN_FAULT_NONE);
      // ---- phase 2: build the reply ----
      result_r   = ev(rec, 2);
      exec_n     = 7'(ev(rec, 3));
      for (int i = 0; i < 64; i++) exec_w[32*i +: 32] = ev(rec, 4 + i);
      rep_base_r = 16'(ev(rec, 68));
      rep_len_r  = 16'(ev(rec, 69));
      op_r       = op;
      @(negedge clk); r_start = 1'b1;
      @(posedge clk);
      @(negedge clk); r_start = 1'b0;
      while (!r_done) @(negedge clk);
      cases++;
      check("fault status", r_fault == 1'(ev(rec, 455)));
      if (ev(rec, 455) == 0) begin
        nw = int'(ev(rec, 70));
        check("rep_words", r_words === 16'(ev(rec, 70)));
        for (int i = 0; i < nw; i++)
          check($sformatf("rep[%0d] got=%08x exp=%08x", i,
                          repm[16'(ev(rec, 68)) + i], ev(rec, 71 + i)),
                repm[16'(ev(rec, 68)) + i] === ev(rec, 71 + i));
      end else begin
        // overrun: window filled exactly, prefix words correct
        nw = int'(ev(rec, 69));
        check("rep_words bounded", r_words === 16'(ev(rec, 69)));
        for (int i = 0; i < nw; i++)
          check($sformatf("ovr rep[%0d] got=%08x exp=%08x", i,
                          repm[16'(ev(rec, 68)) + i], ev(rec, 71 + i)),
                repm[16'(ev(rec, 68)) + i] === ev(rec, 71 + i));
      end
      @(negedge clk);
      check("idle busy", r_busy == 1'b0);
      rec++;
    end

    // ---- directed: GENERATE_REPLY clear -> zero words, no writes ----
    begin
      automatic logic [31:0] sentinel = 32'hDEADBEEF;
      automatic apu_vn_op_t op2;
      // reuse record 0's decode; clear the generate-reply flag
      @(negedge clk);
      d_base = 16'(ev(0, 0)); d_len = 16'(ev(0, 1));
      d_start = 1'b1;
      @(posedge clk);
      @(negedge clk); d_start = 1'b0;
      while (!d_done) @(negedge clk);
      op2 = op;
      op2.cmd_flags = op.cmd_flags & ~32'h1;
      repm[16'(ev(0, 68))] = sentinel;
      result_r   = ev(0, 2);
      exec_n     = 7'(ev(0, 3));
      rep_base_r = 16'(ev(0, 68));
      rep_len_r  = 16'(ev(0, 69));
      op_r       = op2;
      @(negedge clk); r_start = 1'b1;
      @(posedge clk);
      @(negedge clk); r_start = 1'b0;
      while (!r_done) @(negedge clk);
      check("noreply words", r_words === 16'h0);
      check("noreply fault", r_fault === 1'b0);
      check("noreply no writes", repm[16'(ev(0, 68))] === sentinel);
      cases++;
    end

    $display("PASS tb_g6lc_apu_vndec_rep cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "vndec_rep %0d errors", errors);
    $finish;
  end

  initial begin #120_000_000; $fatal(1, "vndec_rep timeout"); end
endmodule
