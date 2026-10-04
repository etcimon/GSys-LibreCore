// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Directed + seeded-random test of g6lc_apu_cmdrec: BEGIN/APPEND/END/
// RESET/READ/COUNT, FULL at RecsPerBuf, NOT_RECORDING/NOT_SEALED/
// BAD_IDX/BAD_BUF status legs, a reference-model random sweep, and the
// Enable=0 quiet check.
module tb_g6lc_apu_cmdrec;
  import g6lc_apu_cmdrec_pkg::*;

  localparam int NumBufs    = 16;
  localparam int RecsPerBuf = 64;

  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  logic            req_v = 0, req_r;
  apu_cmdrec_req_t req;
  logic            cpl_v, cpl_r = 1;
  apu_cmdrec_cpl_t cpl;
  logic            oreq_r, ocpl_v;
  apu_cmdrec_cpl_t ocpl;

  g6lc_apu_cmdrec #(.Enable(1'b1), .NumBufs(NumBufs),
                    .RecsPerBuf(RecsPerBuf)) i_dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(req_r), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl));
  g6lc_apu_cmdrec_fixture #(.Enable(1'b0), .NumBufs(NumBufs),
                            .RecsPerBuf(RecsPerBuf)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(oreq_r), .req_i(req),
    .cpl_valid_o(ocpl_v), .cpl_ready_i(cpl_r), .cpl_o(ocpl));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) if (oreq_r || ocpl_v || ocpl.status !== '0)
    $fatal(1, "disabled cmdrec active");

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL: %s (op=%0d cbuf=%0d idx=%0d st=%0d cnt=%0d)",
               name, req.op, req.cbuf, req.idx, cpl.status, cpl.count);
      if (errors > 16) $fatal(1, "too many errors");
    end
  endtask

  // issue one request, wait for its completion
  task automatic op(input apu_cmdrec_op_e o, input logic [7:0] b,
                    input logic [7:0] ix, input apu_cmdrec_rec_t r);
    @(negedge clk);
    req_v = 1'b1; req = '{op: o, cbuf: b, idx: ix, rec: r};
    @(posedge clk);
    while (!req_r) @(posedge clk);
    @(negedge clk); req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
    cases++;
  endtask

  function automatic apu_cmdrec_rec_t mkrec(input logic [31:0] tag);
    apu_cmdrec_rec_t r;
    r.ctype  = tag;
    r.flags  = tag ^ 32'h5A5A0000;
    for (int i = 0; i < 4; i++) begin
      r.handle[i] = tag * (i + 3) + i;
      r.kind[i]   = 8'(tag + i);
    end
    for (int i = 0; i < 8; i++) r.imm[i] = tag + i;
    r.spare  = '0;
    return r;
  endfunction

  // ---- reference model ------------------------------------------------
  logic [7:0]        m_cnt  [NumBufs];
  logic              m_recd [NumBufs];
  logic              m_seal [NumBufs];
  apu_cmdrec_rec_t   m_mem  [NumBufs][RecsPerBuf];

  task automatic m_op(input apu_cmdrec_op_e o, input logic [7:0] b,
                      input logic [7:0] ix, input apu_cmdrec_rec_t r,
                      output apu_cmdrec_status_e st,
                      output apu_cmdrec_rec_t orr);
    if (b >= NumBufs) begin
      st = APU_CMDREC_BAD_BUF; orr = '0; return;
    end
    orr = '0;
    case (o)
      APU_CMDREC_OP_BEGIN: begin
        m_cnt[b[3:0]] = 0; m_recd[b[3:0]] = 1; m_seal[b[3:0]] = 0;
        st = APU_CMDREC_OK;
      end
      APU_CMDREC_OP_APPEND: begin
        if (!m_recd[b[3:0]])       st = APU_CMDREC_NOT_RECORDING;
        else if (m_cnt[b[3:0]] >= RecsPerBuf) st = APU_CMDREC_FULL;
        else begin
          m_mem[b[3:0]][m_cnt[b[3:0]][5:0]] = r; m_cnt[b[3:0]]++;
          st = APU_CMDREC_OK;
        end
      end
      APU_CMDREC_OP_END: begin
        if (!m_recd[b[3:0]]) st = APU_CMDREC_NOT_RECORDING;
        else begin m_recd[b[3:0]] = 0; m_seal[b[3:0]] = 1; st = APU_CMDREC_OK; end
      end
      APU_CMDREC_OP_RESET: begin
        m_cnt[b[3:0]] = 0; m_recd[b[3:0]] = 0; m_seal[b[3:0]] = 0; st = APU_CMDREC_OK;
      end
      APU_CMDREC_OP_READ: begin
        if (!m_seal[b[3:0]])         st = APU_CMDREC_NOT_SEALED;
        else if (ix >= m_cnt[b[3:0]]) st = APU_CMDREC_BAD_IDX;
        else begin orr = m_mem[b[3:0]][ix[5:0]]; st = APU_CMDREC_OK; end
      end
      default: st = APU_CMDREC_OK;   // COUNT
    endcase
  endtask

  apu_cmdrec_status_e st_exp;
  apu_cmdrec_rec_t    rec_exp, r0;

  initial begin
    for (int i = 0; i < NumBufs; i++) begin
      m_cnt[i] = 0; m_recd[i] = 0; m_seal[i] = 0;
    end
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    check("init quiet", !req_v && !cpl_v);

    // ---- case 1: record, seal, read back ------------------------------
    op(APU_CMDREC_OP_BEGIN, 0, 0, '0);
    check("begin ok", cpl.status == APU_CMDREC_OK);
    for (int i = 0; i < 10; i++) begin
      op(APU_CMDREC_OP_APPEND, 0, 0, mkrec(32'h100 + i));
      check("append ok", cpl.status == APU_CMDREC_OK &&
                         cpl.count == 8'(i + 1));
    end
    op(APU_CMDREC_OP_READ, 0, 0, '0);
    check("unsealed read", cpl.status == APU_CMDREC_NOT_SEALED);
    op(APU_CMDREC_OP_END, 0, '0, '0);
    check("end ok", cpl.status == APU_CMDREC_OK);
    op(APU_CMDREC_OP_COUNT, 0, 0, '0);
    check("count", cpl.status == APU_CMDREC_OK && cpl.count == 8'd10);
    for (int i = 0; i < 10; i++) begin
      op(APU_CMDREC_OP_READ, 0, 8'(i), '0);
      check("read rec", cpl.status == APU_CMDREC_OK &&
                       cpl.rec === mkrec(32'h100 + i));
    end
    op(APU_CMDREC_OP_READ, 0, 8'd10, '0);
    check("bad idx", cpl.status == APU_CMDREC_BAD_IDX);

    // ---- case 2: FULL --------------------------------------------------
    op(APU_CMDREC_OP_BEGIN, 1, 0, '0);
    check("begin 1", cpl.status == APU_CMDREC_OK);
    for (int i = 0; i < RecsPerBuf; i++) begin
      op(APU_CMDREC_OP_APPEND, 1, 0, mkrec(i));
      check("append full", cpl.status == APU_CMDREC_OK);
    end
    op(APU_CMDREC_OP_APPEND, 1, 0, mkrec(32'hFF));
    check("full", cpl.status == APU_CMDREC_FULL);

    // ---- case 3: NOT_RECORDING -----------------------------------------
    op(APU_CMDREC_OP_APPEND, 2, 0, mkrec(1));
    check("append idle", cpl.status == APU_CMDREC_NOT_RECORDING);
    op(APU_CMDREC_OP_END, 2, 0, '0);
    check("end idle", cpl.status == APU_CMDREC_NOT_RECORDING);

    // ---- case 4: BAD_BUF ------------------------------------------------
    op(APU_CMDREC_OP_BEGIN, 8'(NumBufs), 0, '0);
    check("begin badbuf", cpl.status == APU_CMDREC_BAD_BUF);
    op(APU_CMDREC_OP_APPEND, 8'(NumBufs), 0, mkrec(0));
    check("append badbuf", cpl.status == APU_CMDREC_BAD_BUF);
    op(APU_CMDREC_OP_END, 8'(NumBufs), 0, '0);
    check("end badbuf", cpl.status == APU_CMDREC_BAD_BUF);
    op(APU_CMDREC_OP_RESET, 8'(NumBufs), 0, '0);
    check("reset badbuf", cpl.status == APU_CMDREC_BAD_BUF);
    op(APU_CMDREC_OP_READ, 8'(NumBufs), 0, '0);
    check("read badbuf", cpl.status == APU_CMDREC_BAD_BUF);
    op(APU_CMDREC_OP_COUNT, 8'(NumBufs), 0, '0);
    check("count badbuf", cpl.status == APU_CMDREC_BAD_BUF);

    // ---- case 5: RESET / re-BEGIN clears --------------------------------
    op(APU_CMDREC_OP_BEGIN, 4, 0, '0);
    for (int i = 0; i < 3; i++) op(APU_CMDREC_OP_APPEND, 4, 0, mkrec(i));
    op(APU_CMDREC_OP_RESET, 4, 0, '0);
    check("reset", cpl.status == APU_CMDREC_OK);
    op(APU_CMDREC_OP_COUNT, 4, 0, '0);
    check("reset count", cpl.status == APU_CMDREC_OK && cpl.count == 0);
    op(APU_CMDREC_OP_READ, 4, 0, '0);
    check("reset unseal", cpl.status == APU_CMDREC_NOT_SEALED);
    op(APU_CMDREC_OP_BEGIN, 4, 0, '0);
    op(APU_CMDREC_OP_APPEND, 4, 0, mkrec(7));
    op(APU_CMDREC_OP_BEGIN, 4, 0, '0);
    check("rebegin", cpl.status == APU_CMDREC_OK);
    op(APU_CMDREC_OP_COUNT, 4, 0, '0);
    check("rebegin count", cpl.status == APU_CMDREC_OK &&
                            cpl.count == 0);

    // ---- case 6: seeded random vs model ----------------------------------
    begin
      int seed = 32'hC0FFEE;
      for (int i = 0; i < 2000; i++) begin
        apu_cmdrec_op_e o = apu_cmdrec_op_e'($urandom_range(0, 5));
        logic [7:0] b = 8'($urandom_range(0, NumBufs + 2));
        logic [7:0] ix = 8'($urandom_range(0, RecsPerBuf + 4));
        r0 = mkrec(32'($urandom(seed)) ^ i);
        m_op(o, b, ix, r0, st_exp, rec_exp);
        op(o, b, ix, r0);
        check("rnd status", cpl.status == st_exp);
        if (o == APU_CMDREC_OP_COUNT)
          check("rnd count", cpl.count == m_cnt[b[3:0]] ||
                             b >= NumBufs);
        if (o == APU_CMDREC_OP_READ && st_exp == APU_CMDREC_OK)
          check("rnd rec", cpl.rec === rec_exp);
      end
    end

    $display("PASS tb_g6lc_apu_cmdrec cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "cmdrec %0d errors", errors);
    $finish;
  end

  initial begin #120_000_000; $fatal(1, "cmdrec timeout"); end
endmodule
