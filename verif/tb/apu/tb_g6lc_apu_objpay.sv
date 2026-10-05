// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Directed + seeded-random test of g6lc_apu_objpay (§7b): first-fit
// chunk allocation over the payload arena, WRITE/READ word access,
// free/reuse, fragmentation, arena-full and bounds arms, Enable=0
// quiet.  A TB-side reference model (bitmap + memory array) predicts
// every completion; ALLOC must return the exact first-fit base.
module tb_g6lc_apu_objpay;
  import g6lc_apu_objpay_pkg::*;

  localparam int unsigned PayWords   = 1024;
  localparam int unsigned ChunkWords = 64;
  localparam int unsigned NumChunks  = PayWords / ChunkWords;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_r, cpl_v, cpl_r = 1;
  apu_objpay_req_t req = '0;
  apu_objpay_cpl_t cpl;
  logic off_req_r, off_cpl_v;
  apu_objpay_cpl_t off_cpl;

  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_objpay #(.Enable(1'b1), .PayWords(PayWords),
                    .ChunkWords(ChunkWords)) i_on (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(req_r), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl));
  g6lc_apu_objpay_fixture #(.Enable(1'b0), .PayWords(PayWords),
                            .ChunkWords(ChunkWords)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(off_req_r), .req_i(req),
    .cpl_valid_o(off_cpl_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) if (off_req_r || off_cpl_v || |off_cpl)
    $fatal(1, "disabled objpay active");

  // ---- reference model -------------------------------------------------
  bit m_free [NumChunks];
  logic [31:0] m_mem [PayWords];

  function automatic int m_chunks(input int w);
    return (w + ChunkWords - 1) / ChunkWords;
  endfunction
  // first-fit: exact base the DUT must find, -1 if full
  function automatic int m_alloc(input int w);
    int n = m_chunks(w);
    if (w == 0) return 0;
    if (n > NumChunks) return -1; // avoids NumChunks-n unsigned underflow
    for (int s = 0; s <= NumChunks - n; s++) begin
      bit ok = 1'b1;
      for (int i = 0; i < n; i++) ok &= m_free[s + i];
      if (ok) begin
        for (int i = 0; i < n; i++) m_free[s + i] = 0;
        return s * ChunkWords;
      end
    end
    return -1;
  endfunction
  function automatic void m_release(input int base, input int w);
    int n = m_chunks(w);
    for (int i = 0; i < n; i++) m_free[base / ChunkWords + i] = 1;
  endfunction

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL case %0d: %s", cases, name);
      if (errors > 12) $fatal(1, "too many errors");
    end
  endtask

  // one request/complete exchange
  task automatic do_req(input apu_objpay_op_e op, input logic [31:0] a,
                        input logic [31:0] w, input logic [31:0] d,
                        output apu_objpay_cpl_t c);
    @(negedge clk);
    req_v = 1'b1; req = '{op: op, addr: a, words: w, wdata: d};
    @(posedge clk);
    @(negedge clk); req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
    c = cpl;
  endtask

  apu_objpay_cpl_t c;
  int base_a, base_b, base_c, base_d, m_base;

  task automatic t_alloc(input int w, output int base);
    do_req(APU_OBJPAY_OP_ALLOC, 0, w, 0, c);
    m_base = m_alloc(w);
    check($sformatf("alloc(%0d) status", w),
          c.status == (m_base < 0 ? APU_OBJPAY_FULL : APU_OBJPAY_OK));
    check($sformatf("alloc(%0d) base", w),
          m_base < 0 || c.base == 32'(m_base));
    base = c.status == APU_OBJPAY_OK ? int'(c.base) : -1;
  endtask

  task automatic t_free(input int base, input int w);
    do_req(APU_OBJPAY_OP_FREE, base, w, 0, c);
    check($sformatf("free(%0d,%0d)", base, w),
          c.status == APU_OBJPAY_OK);
    m_release(base, w);
  endtask

  task automatic t_write(input int a, input logic [31:0] d);
    do_req(APU_OBJPAY_OP_WRITE, a, 0, d, c);
    check($sformatf("write(%0d)", a),
          c.status == (a < PayWords ? APU_OBJPAY_OK : APU_OBJPAY_BOUNDS));
    if (a < PayWords) m_mem[a] = d;
  endtask

  task automatic t_read(input int a);
    do_req(APU_OBJPAY_OP_READ, a, 0, 0, c);
    check($sformatf("read(%0d) status", a),
          c.status == (a < PayWords ? APU_OBJPAY_OK : APU_OBJPAY_BOUNDS));
    if (a < PayWords)
      check($sformatf("read(%0d) data", a), c.rdata === m_mem[a]);
  endtask

  initial begin
    for (int i = 0; i < NumChunks; i++) m_free[i] = 1;
    for (int i = 0; i < PayWords; i++) m_mem[i] = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    check("init quiet", cpl_v === 1'b0);
    repeat (2) @(negedge clk);
    check("ready", req_r == 1'b1);

    // ---- directed: alloc/write/read/free round trip -----------------
    cases++;
    t_alloc(100, base_a);            // chunks 0-1 -> base 0
    check("alloc100 base0", base_a == 0);
    for (int i = 0; i < 100; i++) t_write(base_a + i, 32'hA5000000 + i);
    for (int i = 0; i < 100; i++) t_read(base_a + i);
    t_alloc(40, base_b);             // 1 chunk -> base 128
    check("alloc40 base128", base_b == 128);
    t_free(base_a, 100);
    t_alloc(60, base_c);             // 1 chunk -> base 0 (first-fit)
    check("alloc60 reuse0", base_c == 0);
    t_alloc(70, base_d);             // 2 chunks -> base 192? chunk1 free,
                                     // chunk2 busy -> chunks 3-4 -> 192
    check("alloc70 firstfit", base_d == 192);

    // ---- fragmentation ----------------------------------------------
    cases++;
    // layout now: c0:C(60) c1:free c2:B(40) c3-4:D(70) c5..:free
    t_free(base_d, 70);              // free chunks 3-4
    t_alloc(200, base_d);            // 4 contiguous -> chunks 3-6 -> 192
    check("frag alloc200", base_d == 192);

    // ---- arena full ---------------------------------------------------
    cases++;
    t_alloc(PayWords + 1, base_a);   // over-size -> FULL, no state change
    check("oversize full", base_a == -1);
    // fill the whole arena
    for (int i = 0; i < NumChunks; i++) m_free[i] = 1;
    t_free(base_c, 60); t_free(base_b, 40); t_free(base_d, 200);
    t_alloc(PayWords, base_a);       // whole arena -> base 0
    check("full-arena alloc", base_a == 0);
    t_alloc(1, base_b);              // nothing left -> FULL
    check("exhausted full", base_b == -1);
    t_free(base_a, PayWords);

    // ---- bounds --------------------------------------------------------
    cases++;
    t_write(PayWords, 32'hDEAD);     // off end -> BOUNDS
    t_read(PayWords);
    t_write(PayWords - 1, 32'h1234ABCD); // last word in range
    t_read(PayWords - 1);
    do_req(APU_OBJPAY_OP_FREE, 7, 64, 0, c); // unaligned -> BOUNDS
    check("free unaligned", c.status == APU_OBJPAY_BOUNDS);
    do_req(APU_OBJPAY_OP_FREE, PayWords - 32, 64, 0, c); // past end
    check("free pastend", c.status == APU_OBJPAY_BOUNDS);
    do_req(APU_OBJPAY_OP_FREE, 0, 0, 0, c);  // words==0 -> OK no-op
    check("free0 ok", c.status == APU_OBJPAY_OK);
    do_req(APU_OBJPAY_OP_ALLOC, 0, 0, 0, c); // alloc0 -> OK base 0
    check("alloc0 ok", c.status == APU_OBJPAY_OK && c.base == 32'h0);

    // ---- seeded random vs model -----------------------------------------
    cases++;
    begin
      int bases [32]; int ws [32]; int live;
      logic [31:0] rnd;
      live = 0;
      for (int it = 0; it < 800; it++) begin
        rnd = $urandom;
        if (live < 28 && (rnd[1:0] != 2'd3 || live == 0)) begin
          // alloc a random size, then write+read one word inside it
          int w = 1 + ($urandom % 130);
          t_alloc(w, base_a);
          if (base_a >= 0) begin
            int off = $urandom % w;
            t_write(base_a + off, 32'hC0DE0000 + it);
            t_read(base_a + off);
            bases[live] = base_a; ws[live] = w; live++;
          end
        end else begin
          int k = $urandom % live;
          t_free(bases[k], ws[k]);
          bases[k] = bases[live-1]; ws[k] = ws[live-1]; live--;
        end
      end
      while (live > 0) begin
        live--;
        t_free(bases[live], ws[live]);
      end
    end

    $display("PASS tb_g6lc_apu_objpay cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "objpay %0d errors", errors);
    $finish;
  end

  initial begin #20_000_000; $fatal(1, "objpay timeout"); end
endmodule
