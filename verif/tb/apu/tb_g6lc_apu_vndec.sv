// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Vector-driven test of g6lc_apu_vndec. The CS model is a flat word array
// filled by $readmemh with a two-region layout:
//   [0,65535)   : ue_sm5_core.hex CS words (comment lines skipped)
//   [65536,...) : ue_sm5_core.exp records, REC_W=335 words each
//   (2641 records + sentinel after the transport commands joined the set)
// .exp record (documented in g6lc_apu_vn_tables.md):
//   0: cs_base  1: cs_len  2: type  3: flags
//   4..19:  q[i] lo/hi pairs   20..27: qkind  28..35: qrole  36: qv
//   37..52: imm[0..15]  53: immv  54..57: cnt
//   58..61: blob{off,words} x2  62: pres  63..70: chain
//   71: chain_n  72: obj_kind  73: reply_prog  74: words
//   75: fault  76: fault_word  77: fault_val  78: pay_len
//   79..334: expected pay_valid_o/pay_data_o stream (pay_len words)
// Terminated by a {FFFFFFFF,FFFFFFFF} sentinel in the base/len slots.
module tb_g6lc_apu_vndec;
  import g6lc_apu_vn_pkg::*;

  localparam int REC_W = 335;
  localparam int EXP_BASE = 65536;
  localparam int PAY_OFF = 79;
  localparam int PAY_MAX = 256;

  logic clk = 0, rst_ni = 0;
  logic start = 0, busy, done;
  logic [15:0] cs_base = '0, cs_len = '0;
  logic cs_re; logic [15:0] cs_addr;
  logic [31:0] cs_rdata = '0;
  logic cs_rv = 0;
  apu_vn_op_t op, off_op;
  logic pay_valid; logic [31:0] pay_data;
  logic off_busy, off_done, off_re, off_pv; logic [15:0] off_addr;
  logic [31:0] off_pd;

  logic [31:0] cs [0:1048575];
  // captured payload stream for the in-flight decode
  logic [31:0] pay_buf [0:PAY_MAX+63];
  int pay_i = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vndec #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni(rst_ni),
    .start_i(start), .cs_base_i(cs_base), .cs_len_i(cs_len),
    .cs_re_o(cs_re), .cs_addr_o(cs_addr),
    .cs_ready_i(1'b1), .cs_rvalid_i(cs_rv), .cs_rdata_i(cs_rdata),
    .cs_err_i(1'b0),
    .busy_o(busy), .done_o(done), .op_o(op),
    .pay_valid_o(pay_valid), .pay_data_o(pay_data));
  g6lc_apu_vndec_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni(rst_ni),
    .start_i(start), .cs_base_i(cs_base), .cs_len_i(cs_len),
    .cs_re_o(off_re), .cs_addr_o(off_addr),
    .cs_ready_i(1'b1), .cs_rvalid_i(1'b0), .cs_rdata_i('0),
    .cs_err_i(1'b0),
    .busy_o(off_busy), .done_o(off_done), .op_o(off_op),
    .pay_valid_o(off_pv), .pay_data_o(off_pd));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  // handshake CS model: accept every request, respond one cycle later
  always @(posedge clk or negedge rst_ni)
    if (!rst_ni) begin cs_rv <= 1'b0; cs_rdata <= '0; end
    else begin
      cs_rv <= 1'b0;
      if (cs_re) begin cs_rv <= 1'b1; cs_rdata <= cs[cs_addr]; end
    end
  always @(posedge clk) if (pay_valid) begin
    if (pay_i > PAY_MAX + 63) $fatal(1, "payload overrun in TB");
    pay_buf[pay_i] <= pay_data;
    pay_i <= pay_i + 1;
  end
  always @(negedge clk) if (off_re || off_busy || off_done || off_pv ||
                            off_op.cmd_type !== '0 || off_op.words !== '0 ||
                            off_op.fault != APU_VN_FAULT_NONE)
    $fatal(1, "disabled vndec active");

  function automatic logic [31:0] ev(input int rec, input int w);
    return cs[EXP_BASE + rec * REC_W + w];
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

  // header/scalar compare; returns fault code, -1 on mismatch
  function automatic int cmp(input int r);
    int c;
    c = 0;
    if (op.cmd_type    !== ev(r, 2))  c++;
    if (op.cmd_flags   !== ev(r, 3))  c++;
    if (op.qv          !== 8'(ev(r,36)))  c++;
    if (op.immv        !== 16'(ev(r,53))) c++;
    if (op.pres        !== 8'(ev(r,62)))  c++;
    if (op.chain_n     !== 4'(ev(r,71)))  c++;
    if (op.obj_kind    !== 6'(ev(r,72)))  c++;
    if (op.reply_prog  !== 8'(ev(r,73)))  c++;
    if (op.words       !== 16'(ev(r,74))) c++;
    if (op.fault       !== 4'(ev(r,75)))  c++;
    if (op.fault_word  !== 16'(ev(r,76))) c++;
    if (op.fault_val   !== ev(r,77)) c++;
    if (op.pay_words   !== 16'(ev(r,78))) c++;
    checks += 13;
    if (c != 0) begin
      errors += c;
      $display("FAIL rec %0d hdr: got typ=%08x flg=%08x qv=%02x immv=%04x pres=%02x cn=%0d ok=%02x rp=%02x w=%0d f=%0d fw=%0d fv=%08x",
               r, op.cmd_type, op.cmd_flags, op.qv, op.immv, op.pres,
               op.chain_n, op.obj_kind, op.reply_prog, op.words, op.fault,
               op.fault_word, op.fault_val);
      $display("     exp       typ=%08x flg=%08x qv=%02x immv=%04x pres=%02x cn=%0d ok=%02x rp=%02x w=%0d f=%0d fw=%0d fv=%08x",
               ev(r,2), ev(r,3), 8'(ev(r,36)), 16'(ev(r,53)), 8'(ev(r,62)),
               4'(ev(r,71)), 6'(ev(r,72)), 8'(ev(r,73)), 16'(ev(r,74)),
               4'(ev(r,75)), 16'(ev(r,76)), ev(r,77));
      if (errors > 12) $fatal(1, "too many errors");
      return -1;
    end
    return int'(4'(ev(r,75)));
  endfunction

  task automatic cmp_tail(input int r);
    for (int i = 0; i < 8; i++) begin
      check($sformatf("q%0d", i),
            op.q[i] === {ev(r,5+2*i), ev(r,4+2*i)});
      check($sformatf("qkind%0d", i), op.qkind[i] === 6'(ev(r,20+i)));
      check($sformatf("qrole%0d", i), op.qrole[i] === 3'(ev(r,28+i)));
    end
    for (int i = 0; i < 16; i++)
      check($sformatf("imm%0d", i), op.imm[i] === ev(r,37+i));
    for (int i = 0; i < 4; i++)
      check($sformatf("cnt%0d", i), op.cnt[i] === ev(r,54+i));
    for (int i = 0; i < 2; i++)
      check($sformatf("blob%0d", i),
            op.blob[i] === {16'(ev(r,58+2*i)), 17'(ev(r,59+2*i))});
    for (int i = 0; i < 8; i++) begin
      if (op.chain[i] !== 8'(ev(r,63+i)))
        $display("     rec %0d chain%0d got=%02x exp=%08x", r, i,
                 op.chain[i], ev(r,63+i));
      check($sformatf("chain%0d", i), op.chain[i] === 8'(ev(r,63+i)));
    end
  endtask

  logic [31:0] base_w, len_w;
  int ft;
  initial begin
    for (int i = 0; i < $size(cs); i++) cs[i] = '0;
    $readmemh("vn_vectors/ue_sm5_core.hex", cs, 0);
    $readmemh("vn_vectors/ue_sm5_core.exp", cs, EXP_BASE);
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    check("init quiet", !busy && !done && !cs_re &&
                        op.cmd_type === '0 && op.words === '0);
    rec = 0;
    while (ev(rec,0) !== 32'hFFFFFFFF) begin
      base_w = ev(rec,0);
      len_w  = ev(rec,1);
      @(negedge clk);
      pay_i = 0;
      cs_base = 16'(base_w); cs_len = 16'(len_w); start = 1'b1;
      @(posedge clk);
      @(negedge clk); start = 1'b0;
      while (!done) @(negedge clk);
      cases++;
      ft = cmp(rec);
      if (ft >= 0 && ft == 0) cmp_tail(rec);
      // §7b payload stream: word-for-word against the .exp region
      check("pay_i==pay_words", pay_i == int'(op.pay_words));
      for (int i = 0; i < pay_i; i++)
        check($sformatf("pay[%0d]", i),
              i < PAY_MAX && pay_buf[i] === ev(rec, PAY_OFF + i));
      @(negedge clk);
      check("idle busy", busy == 1'b0);
      rec++;
    end
    $display("PASS tb_g6lc_apu_vndec cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "vndec %0d errors", errors);
    $finish;
  end

  initial begin #120_000_000; $fatal(1, "vndec timeout"); end
endmodule
