// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Directed + seeded-random test of g6lc_apu_cmdrec (§5a G3b-iii):
// command buffers live entirely in PayMem — a 64-word descriptor
// block per buffer plus 1024-word record/payload chunk chains behind
// a CbOpen write-back descriptor cache and a 2-deep read prefetch.
// Cases: BEGIN/APPEND/END/READ/COUNT round trip, 200-record chunk
// growth, payload straddle into a fresh chunk, cursor rewind vs
// chain-walk, implicit reset on re-BEGIN, secondary-flag retention,
// RESET_POOL SWEEP stream, DESTROY_POOL descriptor frees,
// NOT_RECORDING payload drain, Enable=0 quiet.
//
// The DUT's ObjPay client port shares the objpay instance with a
// TB-direct requester (descriptor setup + backdoor reads); the TB
// only drives when the DUT's port is idle, and a one-bit owner flop
// routes the completion.
module tb_g6lc_apu_cmdrec;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_mp_pkg::*;

  localparam int unsigned PayMemBytes = 1024 * 1024;  // 256Ki words
  localparam int unsigned ObjEntries  = 256;
  localparam int unsigned CW          = APU_CB_CHUNK_WORDS;   // 1024

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_r, cpl_v, cpl_r = 1;
  apu_cmdrec_req_t req = '0;
  apu_cmdrec_cpl_t cpl;
  logic pay_v = 0, pay_r;
  logic [31:0] pay_d = '0;
  logic off_req_r, off_cpl_v;
  apu_cmdrec_cpl_t off_cpl;
  logic off_op_v;
  apu_objpay_req_t off_op_req;
  logic off_pay_r;

  int errors = 0, checks = 0, cycles = 0, cases = 0;

  // ---- shared ObjPay port: DUT wins; TB drives only when idle ----------
  logic            dut_op_v, dut_op_rdy;
  apu_objpay_req_t dut_op_req;
  logic            tb_op_v = 0, tb_op_rdy;
  apu_objpay_req_t tb_op_req = '0;
  logic            tb_own_q = 1'b0;   // the in-flight op is the TB's
  logic            op_v, op_r;
  apu_objpay_req_t op_req;
  logic            op_cv;
  apu_objpay_cpl_t op_c;

  assign op_v       = dut_op_v | tb_op_v;
  assign op_req     = dut_op_v ? dut_op_req : tb_op_req;
  assign dut_op_rdy = dut_op_v & op_r;
  assign tb_op_rdy  = ~dut_op_v & tb_op_v & op_r;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) tb_own_q <= 1'b0;
    else begin
      if (tb_op_v && tb_op_rdy) tb_own_q <= 1'b1;
      if (op_cv && tb_own_q)    tb_own_q <= 1'b0;
    end
  end

  // ---- objmem plumbing (same as tb_g6lc_apu_objpay) --------------------
  logic         omp_v, omp_r, omp_rv;
  apu_omp_req_t omp_req;
  apu_omp_rsp_t omp_rsp;
  logic         omtr_r, omtr_rv;
  apu_omt_rsp_t omtr_rsp;
  logic         mp_v, mp_r, mp_rv;
  apu_mp_req_t  mp_req;
  apu_mp_rsp_t  mp_rsp;

  g6lc_apu_cmdrec #(.Enable(1'b1), .CbOpen(4)) i_on (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(req_r), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .pay_valid_i(pay_v), .pay_data_i(pay_d), .pay_ready_o(pay_r),
    .op_req_valid_o(dut_op_v), .op_req_ready_i(dut_op_rdy),
    .op_req_o(dut_op_req),
    .op_cpl_valid_i(op_cv && !tb_own_q), .op_cpl_ready_o(),
    .op_cpl_i(op_c));

  g6lc_apu_objpay #(.Enable(1'b1), .PayMemBytes(PayMemBytes)) i_pay (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(op_v), .req_ready_o(op_r), .req_i(op_req),
    .cpl_valid_o(op_cv), .cpl_ready_i(1'b1), .cpl_o(op_c),
    .omp_req_valid_o(omp_v), .omp_req_ready_i(omp_r),
    .omp_req_o(omp_req),
    .omp_rsp_valid_i(omp_rv), .omp_rsp_i(omp_rsp));

  g6lc_apu_objmem #(.Enable(1'b1), .ObjEntries(ObjEntries),
                    .PayMemBytes(PayMemBytes),
                    .DirCacheSets(8), .EntCacheLines(8),
                    .PayCacheLines(4)) i_om (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .omt_req_valid_i(1'b0), .omt_req_ready_o(omtr_r),
    .omt_req_i(apu_omt_req_t'(0)),
    .omt_rsp_valid_o(omtr_rv), .omt_rsp_o(omtr_rsp),
    .omp_req_valid_i(omp_v), .omp_req_ready_o(omp_r),
    .omp_req_i(omp_req),
    .omp_rsp_valid_o(omp_rv), .omp_rsp_o(omp_rsp),
    .mp_req_valid_o(mp_v), .mp_req_ready_i(mp_r),
    .mp_req_o(mp_req),
    .mp_rsp_valid_i(mp_rv), .mp_rsp_i(mp_rsp));

  tb_apu_mp_mem #(.N(1), .GMW(1), .APW(0),
                  .PWB(32'(APU_OBJMEM_OFF >> 2)),
                  .PPW(32'((apu_objmem_pay_off(ObjEntries) +
                            64'(PayMemBytes) - APU_OBJMEM_OFF) >> 2) +
                        64))
      i_mem (
    .clk_i(clk), .rst_ni(rst_ni),
    .req_valid_i(mp_v), .req_ready_o(mp_r), .req_i('{mp_req}),
    .rsp_valid_o(mp_rv), .rsp_o('{mp_rsp}));

  g6lc_apu_cmdrec_fixture #(.Enable(1'b0), .CbOpen(4)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(off_req_r), .req_i(req),
    .cpl_valid_o(off_cpl_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .pay_valid_i(pay_v), .pay_data_i(pay_d), .pay_ready_o(off_pay_r),
    .op_req_valid_o(off_op_v), .op_req_ready_i(1'b0),
    .op_req_o(off_op_req),
    .op_cpl_valid_i(1'b0), .op_cpl_ready_o(),
    .op_cpl_i(apu_objpay_cpl_t'('0)));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk)
    if (off_req_r || off_cpl_v || (|off_cpl) || off_op_v || off_pay_r)
      $fatal(1, "disabled cmdrec active");

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL case %0d: %s", cases, name);
      if (errors > 12) $fatal(1, "too many errors");
    end
  endtask

  // ---- TB-direct ObjPay op (descriptor setup / backdoor reads) ---------
  apu_objpay_cpl_t tc;
  task automatic tb_op(input apu_objpay_op_e o, input logic [31:0] a,
                       input logic [31:0] w, input logic [31:0] d);
    @(negedge clk);
    while (dut_op_v || !op_r) @(negedge clk);
    tb_op_v   = 1'b1;
    tb_op_req = '{op: o, addr: a, words: w, wdata: d};
    @(posedge clk);
    @(negedge clk); tb_op_v = 1'b0;
    while (!(op_cv && tb_own_q)) @(negedge clk);
    tc = op_c;
    @(posedge clk); @(negedge clk);
  endtask

  // ---- descriptor helpers (vnfront's w8..w11 ownership mirrored) -------
  // allocate a 64-word descriptor; w0 secondary bit on request, the rest
  // of the cmdrec-owned header zeroed (recycled chunks carry stale
  // chains — BEGIN would take them for real)
  task automatic mk_desc(output logic [31:0] cbd, input logic sec);
    tb_op(APU_OBJPAY_OP_ALLOC, '0, 32'(APU_CBD_WORDS), '0);
    check("mk_desc alloc", tc.status == APU_OBJPAY_OK &&
          tc.base != 32'h0);
    cbd = tc.base;
    for (int i = 0; i < 12; i++) begin
      automatic logic [31:0] v = '0;
      if (i == APU_CBD_W0)  v = {29'h0, sec, 2'b0};
      if (i == APU_CBD_OWN) v = 32'hCAF0_0000 | cbd;  // own-handle tag
      tb_op(APU_OBJPAY_OP_WRITE, cbd + 32'(i), '0, v);
      check("mk_desc write", tc.status == APU_OBJPAY_OK);
    end
  endtask

  task automatic wr_desc(input logic [31:0] cbd, input int w,
                         input logic [31:0] v);
    tb_op(APU_OBJPAY_OP_WRITE, cbd + 32'(w), '0, v);
    check("wr_desc", tc.status == APU_OBJPAY_OK);
  endtask

  task automatic rd_desc(input logic [31:0] cbd, input int w,
                         output logic [31:0] v);
    tb_op(APU_OBJPAY_OP_READ, cbd + 32'(w), '0, '0);
    v = tc.rdata;
  endtask

  // ---- cmdrec request --------------------------------------------------
  apu_cmdrec_cpl_t cc;

  function automatic apu_cmdrec_rec_t mkrec(input logic [31:0] tag);
    apu_cmdrec_rec_t r;
    r = '0;
    r.ctype   = 32'hC000_0000 | tag;
    r.imm[0]  = tag;
    return r;
  endfunction

  // one op; when pay_n != 0 the caller streams pay words after accept
  task automatic cop(input apu_cmdrec_op_e o, input logic [31:0] cbd,
                     input logic [15:0] ix, input logic [31:0] fl,
                     input apu_cmdrec_rec_t r, input int pn);
    @(negedge clk);
    while (!req_r) @(negedge clk);
    req_v = 1'b1;
    req   = '{op: o, cbd: cbd, idx: ix, pay_n: 16'(pn), flags: fl,
              rec: r};
    @(posedge clk);
    @(negedge clk); req_v = 1'b0;
  endtask

  task automatic cget();
    while (!cpl_v) @(negedge clk);
    cc = cpl;
    @(posedge clk); @(negedge clk);
  endtask

  task automatic cbegin(input logic [31:0] cbd, input logic [31:0] fl);
    cop(APU_CMDREC_OP_BEGIN, cbd, '0, fl, '0, 0);
    cget();
    check($sformatf("begin cbd=%0d", cbd), cc.status == APU_CMDREC_OK);
  endtask

  task automatic cend(input logic [31:0] cbd);
    cop(APU_CMDREC_OP_END, cbd, '0, '0, '0, 0);
    cget();
    check($sformatf("end cbd=%0d", cbd), cc.status == APU_CMDREC_OK);
  endtask

  // APPEND a record with an optional payload stream {pay0, pay0+1, ...}
  task automatic capp(input logic [31:0] cbd, input logic [31:0] tag,
                      input int pn, input logic [31:0] pay0,
                      input apu_cmdrec_status_e est);
    cop(APU_CMDREC_OP_APPEND, cbd, '0, '0, mkrec(tag), pn);
    for (int i = 0; i < pn; i++) begin
      @(negedge clk);
      while (!pay_r) @(negedge clk);
      pay_v = 1'b1; pay_d = pay0 + 32'(i);
      @(posedge clk);
      @(negedge clk); pay_v = 1'b0;
    end
    cget();
    check($sformatf("append cbd=%0d tag=%08x st", cbd, tag),
          cc.status == est);
  endtask

  task automatic ccnt(input logic [31:0] cbd, input int exp);
    cop(APU_CMDREC_OP_COUNT, cbd, '0, '0, '0, 0);
    cget();
    check($sformatf("count cbd=%0d", cbd),
          cc.status == APU_CMDREC_OK && cc.count == 32'(exp));
  endtask

  task automatic crd(input logic [31:0] cbd, input int idx,
                     input logic [31:0] etag);
    cop(APU_CMDREC_OP_READ, cbd, 16'(idx), '0, '0, 0);
    cget();
    check($sformatf("read cbd=%0d idx=%0d st", cbd, idx),
          cc.status == APU_CMDREC_OK);
    if (cc.rec.imm[0] !== etag || cc.rec.ctype !== (32'hC000_0000 | etag))
      $display("  rd cbd=%0d idx=%0d ctype=%08x imm0=%08x imm7=%08x",
               cbd, idx, cc.rec.ctype, cc.rec.imm[0], cc.rec.imm[7]);
    check($sformatf("read cbd=%0d idx=%0d tag", cbd, idx),
          cc.rec.imm[0] === etag &&
          cc.rec.ctype === (32'hC000_0000 | etag));
  endtask

  logic [31:0] dA, dB, dC, dD, dE, dF;
  logic [31:0] pbd [6];   // case 12's pool chain — later cases reuse
                         // it to push cache entries out
  logic [31:0] p1, p2, p3, q1, q2;
  logic [31:0] rv;
  int          pay_base;

  initial begin
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    check("init quiet", cpl_v === 1'b0);
    repeat (40) @(negedge clk);          // objmem cold boot
    while (!req_r) @(negedge clk);
    check("ready", req_r == 1'b1);

    // chunk 0 is reserved by the allocator itself: cbd==0 is the
    // nil/bad-buffer sentinel (and the pool chain's nil link) —
    // mk_desc asserts every ALLOC lands past it


    // ---- case 1: begin/append/end/read round trip --------------------
    cases++;
    mk_desc(dA, 1'b0);
    cbegin(dA, '0);
    capp(dA, 32'h1111_0001, 0, '0, APU_CMDREC_OK);
    capp(dA, 32'h1111_0002, 0, '0, APU_CMDREC_OK);
    capp(dA, 32'h1111_0003, 4, 32'h0A00_0000, APU_CMDREC_OK);
    cend(dA);
    ccnt(dA, 3);
    crd(dA, 0, 32'h1111_0001);
    crd(dA, 1, 32'h1111_0002);
    crd(dA, 2, 32'h1111_0003);
    // the payload's absolute word address rides rec.imm[7]
    check("rec2 imm7 set", cc.rec.imm[7] != 32'h0);
    begin
      automatic logic [31:0] pb = cc.rec.imm[7];
      for (int i = 0; i < 4; i++) begin
        tb_op(APU_OBJPAY_OP_READ, pb + 32'(i), '0, '0);
        check($sformatf("pay[%0d]", i),
              tc.status == APU_OBJPAY_OK &&
              tc.rdata === 32'h0A00_0000 + 32'(i));
      end
    end

    // ---- case 2: protocol arms ----------------------------------------
    cases++;
    mk_desc(dB, 1'b0);
    // APPEND with payload on a non-recording buffer: the declared
    // stream is still drained before NOT_RECORDING returns
    capp(dB, 32'h2222_0001, 3, 32'h0B00_0000, APU_CMDREC_NOT_RECORDING);
    // READ on a sealed buffer past the fill
    cop(APU_CMDREC_OP_READ, dA, 16'd5, '0, '0, 0); cget();
    check("read bad idx", cc.status == APU_CMDREC_BAD_IDX);
    // READ on a recording (unsealed) buffer
    cop(APU_CMDREC_OP_READ, dB, 16'd0, '0, '0, 0); cget();
    check("read not sealed", cc.status == APU_CMDREC_NOT_SEALED);
    // END on a non-recording buffer
    cop(APU_CMDREC_OP_END, dB, '0, '0, '0, 0); cget();
    check("end not recording", cc.status == APU_CMDREC_NOT_RECORDING);

    // ---- case 3: 200 records -> 4 record chunks -----------------------
    cases++;
    mk_desc(dC, 1'b0);
    cbegin(dC, '0);
    for (int i = 0; i < 200; i++)
      capp(dC, 32'h3300_0000 | 32'(i), 0, '0, APU_CMDREC_OK);
    cend(dC);
    ccnt(dC, 200);
    begin
      automatic logic [31:0] rh, rt, x0, x1, x2, x3;
      // the descriptor's w0..w7 only reach PayMem when the write-back
      // cache evicts — push dC out with four other fills first
      mk_desc(x0, 1'b0); mk_desc(x1, 1'b0);
      mk_desc(x2, 1'b0); mk_desc(x3, 1'b0);
      ccnt(dA, 3); ccnt(x0, 0); ccnt(x1, 0); ccnt(x2, 0);
      ccnt(x3, 0);
      rd_desc(dC, APU_CBD_RECH, rh);
      rd_desc(dC, APU_CBD_RECT, rt);
      check("200-rec chunk growth", rh != rt);
      rd_desc(dC, APU_CBD_COUNT, rt);
      check("desc count=200", rt == 32'd200);
    end
    // sequential reads (cursor + prefetch + chunk hops) — F3: a
    // boundary hop costs one link READN + one line READN, never a
    // head walk; the whole 200-read run stays O(records)
    begin
      automatic int tseq0, thop1, thop2, thop3;
      tseq0 = cycles; thop1 = 0; thop2 = 0; thop3 = 0;
      for (int i = 0; i < 200; i++) begin
        automatic int t0r = cycles;
        crd(dC, i, 32'h3300_0000 | 32'(i));
        if (i == 63)  thop1 = cycles - t0r;
        if (i == 126) thop2 = cycles - t0r;
        if (i == 189) thop3 = cycles - t0r;
      end
      $display("  seq read total=%0d hops=%0d,%0d,%0d",
               cycles - tseq0, thop1, thop2, thop3);
      check("seq read bounded", cycles - tseq0 < 200 * 120);
      check("chunk hop 63 bounded",  thop1 < 120);
      check("chunk hop 126 bounded", thop2 < 120);
      check("chunk hop 189 bounded", thop3 < 120);
    end
    // rewind — cursor behind, walk from the head again
    crd(dC, 0, 32'h3300_0000);
    // mid-buffer walk after a rewind reads through chunk hops
    crd(dC, 150, 32'h3300_0096);

    // ---- case 4: payload straddle --------------------------------------
    cases++;
    mk_desc(dD, 1'b0);
    cbegin(dD, '0);
    // first payload: words 1..1020 of the fresh pay chunk
    capp(dD, 32'h4444_0001, 1020, 32'h0C00_0000, APU_CMDREC_OK);
    // second payload (10 words) cannot fit the tail -> new chunk,
    // imm[7] = chunk base + 1 (w0 is the next-chunk link)
    capp(dD, 32'h4444_0002, 10, 32'h0D00_0000, APU_CMDREC_OK);
    cend(dD);
    cop(APU_CMDREC_OP_READ, dD, 16'd0, '0, '0, 0); cget();
    begin
      automatic logic [31:0] pa = cc.rec.imm[7];
      cop(APU_CMDREC_OP_READ, dD, 16'd1, '0, '0, 0); cget();
      // a fresh pay chunk's first payload word is base+1 (w0 = next
      // link); chunk bases are 64-word aligned, so the straddle lands
      // at residue 1 mod 64 — a same-chunk continuation would be
      // pa + 1020
      check("straddle new chunk",
            cc.rec.imm[7] != pa + 32'd1020 &&
            cc.rec.imm[7][5:0] == 6'd1);
      pay_base = int'(cc.rec.imm[7]);
    end
    begin
      automatic logic [31:0] pb = cc.rec.imm[7];
      for (int i = 0; i < 10; i++) begin
        tb_op(APU_OBJPAY_OP_READ, pb + 32'(i), '0, '0);
        check($sformatf("straddle pay[%0d]", i),
              tc.rdata === 32'h0D00_0000 + 32'(i));
      end
    end
    // a payload of exactly the remaining 1023 words still fits the tail
    cbegin(dD, '0);
    capp(dD, 32'h4444_0003, 1023, 32'h0E00_0000, APU_CMDREC_OK);
    cend(dD);
    cop(APU_CMDREC_OP_READ, dD, 16'd0, '0, '0, 0); cget();
    check("exact-fit same chunk",
          cc.rec.imm[7][5:0] == 6'd1);

    // ---- case 5: RESET then re-BEGIN -----------------------------------
    cases++;
    mk_desc(dE, 1'b0);
    cbegin(dE, '0);
    for (int i = 0; i < 5; i++)
      capp(dE, 32'h5500_0000 | 32'(i), 0, '0, APU_CMDREC_OK);
    cend(dE);
    cop(APU_CMDREC_OP_RESET, dE, '0, '0, '0, 0); cget();
    check("reset ok", cc.status == APU_CMDREC_OK);
    ccnt(dE, 0);
    cop(APU_CMDREC_OP_READ, dE, 16'd0, '0, '0, 0); cget();
    check("read after reset not sealed",
          cc.status == APU_CMDREC_NOT_SEALED);
    cbegin(dE, '0);
    capp(dE, 32'h5500_0100, 0, '0, APU_CMDREC_OK);
    cend(dE);
    ccnt(dE, 1);

    // ---- case 6: implicit reset on re-BEGIN + secondary retention -------
    cases++;
    mk_desc(dF, 1'b1);                 // secondary descriptor
    cbegin(dF, '0);
    capp(dF, 32'h6600_0001, 0, '0, APU_CMDREC_OK);
    cend(dF);
    cbegin(dF, 32'h8);                 // re-BEGIN: implicit reset + ONE_TIME
    ccnt(dF, 0);
    capp(dF, 32'h6600_0002, 0, '0, APU_CMDREC_OK);
    cend(dF);
    cop(APU_CMDREC_OP_RESET, dF, '0, '0, '0, 0); cget();
    check("reset2 ok", cc.status == APU_CMDREC_OK);
    // secondary survives BEGIN/END/RESET
    rd_desc(dF, APU_CBD_W0, rv);
    check("secondary kept", rv[APU_CBF_SECONDARY] === 1'b1);

    // ---- case 7: RESET_POOL sweep stream --------------------------------
    cases++;
    mk_desc(p1, 1'b0); mk_desc(p2, 1'b0); mk_desc(p3, 1'b0);
    wr_desc(p1, APU_CBD_PNEXT, p2);
    wr_desc(p2, APU_CBD_PPREV, p1); wr_desc(p2, APU_CBD_PNEXT, p3);
    wr_desc(p3, APU_CBD_PPREV, p2);
    for (int b = 0; b < 3; b++) begin
      automatic logic [31:0] cbd = b == 0 ? p1 : b == 1 ? p2 : p3;
      cbegin(cbd, '0);
      for (int i = 0; i <= b; i++)
        capp(cbd, 32'h7700_0000 | (32'(b) << 8) | 32'(i), 0, '0,
             APU_CMDREC_OK);
      cend(cbd);
    end
    cop(APU_CMDREC_OP_RESET_POOL, p1, '0, '0, '0, 0);
    for (int b = 0; b < 3; b++) begin
      automatic logic [31:0] cbd = b == 0 ? p1 : b == 1 ? p2 : p3;
      cget();
      check($sformatf("sweep %0d status", b),
            cc.status == APU_CMDREC_SWEEP);
      check($sformatf("sweep %0d own", b),
            cc.pdata === (32'hCAF0_0000 | cbd));
    end
    cget();
    check("reset_pool done", cc.status == APU_CMDREC_OK);
    // buffers survive a pool reset, records and chains are gone
    ccnt(p2, 0);
    cbegin(p2, '0);
    capp(p2, 32'h7700_1000, 0, '0, APU_CMDREC_OK);
    cend(p2);
    ccnt(p2, 1);
    cop(APU_CMDREC_OP_RESET_POOL, p1, '0, '0, '0, 0);
    repeat (3) cget();                  // 3 sweeps (order-independent)
    cget();
    check("reset_pool again ok", cc.status == APU_CMDREC_OK);

    // ---- case 8: DESTROY_POOL frees descriptors --------------------------
    cases++;
    mk_desc(q1, 1'b0); mk_desc(q2, 1'b0);
    wr_desc(q1, APU_CBD_PNEXT, q2);
    wr_desc(q2, APU_CBD_PPREV, q1);
    cbegin(q1, '0); capp(q1, 32'h8800_0001, 0, '0, APU_CMDREC_OK);
    cend(q1);
    cop(APU_CMDREC_OP_DESTROY_POOL, q1, '0, '0, '0, 0);
    cget(); check("destroy sweep0", cc.status == APU_CMDREC_SWEEP);
    cget(); check("destroy sweep1", cc.status == APU_CMDREC_SWEEP);
    cget(); check("destroy done",  cc.status == APU_CMDREC_OK);
    // the descriptor extents are back in the allocator
    tb_op(APU_OBJPAY_OP_READN, q1, 32'd8, '0);
    check("desc freed", tc.status == APU_OBJPAY_BOUNDS);

    // ---- case 9: idle prefetch cannot starve a requester -------------------
    cases++;
    // sequential reads already exercised the 2-deep prefetch against
    // dC; one more rewind confirms the FIFO does not pin the port
    crd(dC, 40, 32'h3300_0028);
    crd(dC, 41, 32'h3300_0029);

    // ---- case 10: CbOpen eviction — >4 interleaved recording buffers ------
    // five buffers record in round-robin so every descriptor leaves
    // the 4-entry write-back cache at least once; a mid-run
    // rd_desc probes the evicted write-back, then each buffer is
    // READ-walked end to end
    cases++;
    begin
      automatic logic [31:0] ebd [5];
      automatic logic [31:0] cnt5, tbd;
      for (int b = 0; b < 5; b++) begin
        mk_desc(tbd, 1'b0); ebd[b] = tbd;
        cbegin(ebd[b], '0);
      end
      for (int i = 0; i < 6; i++)
        for (int b = 0; b < 5; b++)
          capp(ebd[b], 32'hAA00_0000 | (32'(b) << 12) | 32'(i),
               0, '0, APU_CMDREC_OK);
      // ebd[0] must have been written back by now — its count is
      // visible in PayMem before any further access to it
      rd_desc(ebd[0], APU_CBD_COUNT, cnt5);
      check("evict write-back count", cnt5 == 32'd6);
      for (int b = 0; b < 5; b++) cend(ebd[b]);
      for (int b = 0; b < 5; b++) begin
        ccnt(ebd[b], 6);
        for (int i = 0; i < 6; i++)
          crd(ebd[b], i,
              32'hAA00_0000 | (32'(b) << 12) | 32'(i));
      end
    end

    // ---- case 11: executing-read while four buffers record ---------------
    // one sealed buffer is walked by index while four others take
    // turns recording — five live cache entries for four slots
    cases++;
    begin
      automatic logic [31:0] xbd, rbd [4];
      automatic logic [31:0] tbd;
      mk_desc(xbd, 1'b0);
      cbegin(xbd, '0);
      for (int i = 0; i < 24; i++)
        capp(xbd, 32'hB000_0000 | 32'(i), 0, '0, APU_CMDREC_OK);
      cend(xbd);
      for (int b = 0; b < 4; b++) begin
        mk_desc(tbd, 1'b0); rbd[b] = tbd;
        cbegin(rbd[b], '0);
      end
      for (int i = 0; i < 24; i++) begin
        crd(xbd, i, 32'hB000_0000 | 32'(i));
        capp(rbd[i % 4], 32'hB100_0000 | (32'(i % 4) << 8) | 32'(i),
             0, '0, APU_CMDREC_OK);
      end
      for (int b = 0; b < 4; b++) cend(rbd[b]);
      for (int b = 0; b < 4; b++) begin
        ccnt(rbd[b], 6);
        for (int j = 0; j < 6; j++)
          crd(rbd[b], j,
              32'hB100_0000 | (32'(b) << 8) | 32'(b + 4 * j));
      end
    end

    // ---- case 12: RESET_POOL over 6 mixed buffers, bitmap restored -------
    // two sealed, two still recording, two never begun; every chain
    // chunk is enumerated beforehand and must come back to the
    // allocator (READN -> BOUNDS)
    cases++;
    begin
      automatic logic [31:0] chunks [16];
      automatic logic [31:0] tbd;
      automatic int          nch;
      automatic logic [31:0] w0r, w1r;
      automatic int          nsw;
      nch = 0;
      for (int b = 0; b < 6; b++) begin
        mk_desc(tbd, 1'b0); pbd[b] = tbd;
      end
      // pool chain pbd[0] -> pbd[1] -> ... -> pbd[5]
      for (int b = 0; b < 6; b++) begin
        wr_desc(pbd[b], APU_CBD_PPREV, b == 0 ? '0 : pbd[b - 1]);
        wr_desc(pbd[b], APU_CBD_PNEXT, b == 5 ? '0 : pbd[b + 1]);
      end
      // b0,b1: sealed (one record each); b2,b3: recording with
      // records; b4,b5: never begun
      for (int b = 0; b < 4; b++) begin
        cbegin(pbd[b], '0);
        for (int i = 0; i <= b; i++)
          capp(pbd[b], 32'hCC00_0000 | (32'(b) << 8) | 32'(i),
               1, 32'h0F00_0000 | (32'(b) << 8) | 32'(i),
               APU_CMDREC_OK);
        if (b < 2) cend(pbd[b]);
      end
      // evict all four recording/sealed entries so the write-backs
      // reach PayMem, then enumerate every chain chunk (record +
      // payload heads and the links inside them) via backdoor reads
      ccnt(dA, 3); ccnt(dB, 0); ccnt(dC, 200); ccnt(dE, 1);
      for (int b = 0; b < 4; b++) begin
        automatic logic [31:0] rh, ph, nx;
        rd_desc(pbd[b], APU_CBD_RECH, rh);
        rd_desc(pbd[b], APU_CBD_PAYH, ph);
        if (rh != 32'h0) begin
          chunks[nch++] = rh;
          tb_op(APU_OBJPAY_OP_READ, rh, '0, '0); nx = tc.rdata;
          while (nx != 32'h0) begin
            chunks[nch++] = nx;
            tb_op(APU_OBJPAY_OP_READ, nx, '0, '0); nx = tc.rdata;
          end
        end
        if (ph != 32'h0) begin
          chunks[nch++] = ph;
          tb_op(APU_OBJPAY_OP_READ, ph, '0, '0); nx = tc.rdata;
          while (nx != 32'h0) begin
            chunks[nch++] = nx;
            tb_op(APU_OBJPAY_OP_READ, nx, '0, '0); nx = tc.rdata;
          end
        end
      end
      check("pool enum chunks", nch >= 4 && nch <= 16);
      cop(APU_CMDREC_OP_RESET_POOL, pbd[0], '0, '0, '0, 0);
      nsw = 0;
      cget();
      while (cc.status == APU_CMDREC_SWEEP) begin
        nsw++;
        check($sformatf("sweep own %0d", nsw),
              (cc.pdata & 32'hFFFF_0000) === 32'hCAF0_0000);
        cget();
      end
      check("pool reset done", cc.status == APU_CMDREC_OK);
      check("sweep count 6", nsw == 6);
      // every enumerated chain chunk is back in the allocator
      for (int i = 0; i < nch; i++) begin
        tb_op(APU_OBJPAY_OP_READN, chunks[i], 32'd8, '0);
        check($sformatf("chunk %0d freed", i),
              tc.status == APU_OBJPAY_BOUNDS);
      end
      // descriptors survive, cleared to a virgin state
      for (int b = 0; b < 6; b++) begin
        rd_desc(pbd[b], APU_CBD_W0, w0r);
        rd_desc(pbd[b], APU_CBD_COUNT, w1r);
        check($sformatf("buf %0d cleared", b),
              w0r === 32'h0 && w1r === 32'h0);
        rd_desc(pbd[b], APU_CBD_RECH, w1r);
        check($sformatf("buf %0d rech 0", b), w1r === 32'h0);
      end
      // a buffer still records correctly after the sweep
      cbegin(pbd[4], '0);
      capp(pbd[4], 32'hCC00_1000, 0, '0, APU_CMDREC_OK);
      cend(pbd[4]);
      ccnt(pbd[4], 1);
    end

    // ---- case 13: BEGIN alloc failure leaves a clean descriptor ----
    // the free-walk always frees the head chunk it reads (FREE is an
    // unconditional 1024-word clear), so an ALLOC failure is only
    // reachable when the walk frees nothing: point both chain heads
    // at an unaligned word inside the descriptor itself — the link
    // READN returns the never-written w63 (0), the FREE bounds-faults
    // on the unaligned base, and the record-chunk ALLOC fails against
    // a packed arena.  The descriptor must come back cleared (F1)
    cases++;
    begin
      automatic logic [31:0] fbd, frh, fph, w0f, w1f, nx;
      automatic logic [31:0] fil_b [300];
      automatic logic [31:0] fil_w [300];
      automatic logic [31:0] deadc [16];
      automatic int          nfil, ndead, g;
      nfil = 0; ndead = 0;
      mk_desc(fbd, 1'b1);        // SECONDARY — the FULL path keeps it
      cbegin(fbd, '0);
      capp(fbd, 32'hDD00_0001, 3, 32'h0D00_0000, APU_CMDREC_OK);
      cend(fbd);
      // push the descriptor out of the cache so the fields are in
      // PayMem, then read the chain heads (pbd[4] still holds case
      // 12's post-sweep record)
      for (int b = 0; b < 6; b++) ccnt(pbd[b], b == 4 ? 32'd1 : 32'd0);
      rd_desc(fbd, APU_CBD_RECH, frh);
      rd_desc(fbd, APU_CBD_PAYH, fph);
      check("chain heads read", frh != 32'h0);
      // enumerate the chain continuations — the descriptor is about
      // to be orphaned, so the arm frees every chunk it owns once
      if (frh != 32'h0) begin
        tb_op(APU_OBJPAY_OP_READ, frh, '0, '0); nx = tc.rdata;
        while (nx != 32'h0 && ndead < 16) begin
          deadc[ndead++] = nx;
          tb_op(APU_OBJPAY_OP_READ, nx, '0, '0); nx = tc.rdata;
        end
      end
      if (fph != 32'h0) begin
        tb_op(APU_OBJPAY_OP_READ, fph, '0, '0); nx = tc.rdata;
        while (nx != 32'h0 && ndead < 16) begin
          deadc[ndead++] = nx;
          tb_op(APU_OBJPAY_OP_READ, nx, '0, '0); nx = tc.rdata;
        end
      end
      // pack the arena until a 1024-word extent no longer fits —
      // whatever free space remains is shorter than a record chunk
      g = 0;
      while (nfil < 290 && g < 400) begin
        g++;
        tb_op(APU_OBJPAY_OP_ALLOC, '0, 32'd1024, '0);
        if (tc.status == APU_OBJPAY_OK) begin
          fil_b[nfil] = tc.base; fil_w[nfil] = 32'd1024; nfil++;
        end
      end
      check("paymem packed", nfil > 0);
      // chain heads -> an unaligned word inside the descriptor block
      // itself: the walk's link read returns w63 (=0), the FREE
      // bounds-faults on the unaligned base, and no chunk is freed
      wr_desc(fbd, APU_CBD_RECH, fbd + 32'd63);
      wr_desc(fbd, APU_CBD_PAYH, fbd + 32'd63);
      cop(APU_CMDREC_OP_BEGIN, fbd, '0, '0, '0, 0); cget();
      check("begin full", cc.status == APU_CMDREC_FULL);
      // evict so the write-back reaches PayMem, then inspect
      for (int b = 0; b < 6; b++) ccnt(pbd[b], b == 4 ? 32'd1 : 32'd0);
      rd_desc(fbd, APU_CBD_W0, w0f);
      rd_desc(fbd, APU_CBD_RECH, w1f);
      check("full-begin secondary kept",
            w0f === (32'h1 << APU_CBF_SECONDARY));
      check("full-begin rech clear", w1f === 32'h0);
      // every chunk returns exactly once — a stale-pointer
      // double-free would corrupt this accounting
      for (int i = 0; i < nfil; i++) begin
        tb_op(APU_OBJPAY_OP_FREE, fil_b[i], fil_w[i], '0);
        check($sformatf("filler %0d free", i),
              tc.status == APU_OBJPAY_OK);
      end
      tb_op(APU_OBJPAY_OP_FREE, frh, 32'(CW), '0);
      check("frh free", tc.status == APU_OBJPAY_OK);
      if (fph != 32'h0) begin
        tb_op(APU_OBJPAY_OP_FREE, fph, 32'(CW), '0);
        check("fph free", tc.status == APU_OBJPAY_OK);
      end
      for (int i = 0; i < ndead; i++) begin
        tb_op(APU_OBJPAY_OP_FREE, deadc[i], 32'(CW), '0);
        check($sformatf("dead %0d free", i),
              tc.status == APU_OBJPAY_OK);
      end
      // now the buffer can begin again with a fresh chain
      cbegin(fbd, '0);
      capp(fbd, 32'hDD00_0002, 0, '0, APU_CMDREC_OK);
      cend(fbd);
      ccnt(fbd, 1);
      crd(fbd, 0, 32'hDD00_0002);
    end

    // ---- case 14: record-count ceiling (16-bit executor index) ----------
    // write count=FFFF into an evicted descriptor — the next APPEND
    // must answer FULL (and still drain the declared payload stream)
    cases++;
    begin
      automatic logic [31:0] gbd;
      mk_desc(gbd, 1'b0);
      cbegin(gbd, '0);
      capp(gbd, 32'hEE00_0001, 0, '0, APU_CMDREC_OK);
      // evict gbd's cache entry, then inflate the count in PayMem
      for (int b = 0; b < 6; b++) ccnt(pbd[b], b == 4 ? 32'd1 : 32'd0);
      wr_desc(gbd, APU_CBD_COUNT, 32'h0000_FFFF);
      capp(gbd, 32'hEE00_0002, 2, 32'h0E00_0000, APU_CMDREC_FULL);
      ccnt(gbd, 32'h0000_FFFF);
    end

    $display("PASS tb_g6lc_apu_cmdrec cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "cmdrec %0d errors", errors);
    $finish;
  end

  initial begin #900_000_000; $fatal(1, "cmdrec timeout"); end
endmodule
