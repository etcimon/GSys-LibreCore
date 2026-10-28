// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Directed + seeded-random test of g6lc_apu_objpay (§5a ObjPay-V):
// next-fit chunk allocation over the DRAM-backed payload arena
// (through g6lc_apu_objmem's payload cache), WRITE/READ word access,
// free/reuse, fragmentation, arena-full and bounds arms, write-back
// eviction correctness, Enable=0 quiet.  A TB-side reference model
// (bitmap + next-fit cursor + memory array) predicts every
// completion; ALLOC must return the exact next-fit base.
//
// The ObjPay mp traffic is served by g6lc_apu_objmem in front of
// tb_apu_mp_mem (the carve window is the aperture range
// [APU_OBJMEM_OFF, pay_end)).
module tb_g6lc_apu_objpay;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_mp_pkg::*;

  localparam int unsigned PayMemBytes  = 64 * 1024;   // 256 chunks
  localparam int unsigned ObjEntries   = 256;
  localparam int unsigned ChunkWords   = APU_OBJPAY_CHUNK_WORDS;
  localparam int unsigned PayWords     = PayMemBytes / 4;
  localparam int unsigned NumChunks    = PayWords / ChunkWords;
  localparam int unsigned BmpWords     = NumChunks / 64;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_r, cpl_v, cpl_r = 1;
  apu_objpay_req_t req = '0;
  apu_objpay_cpl_t cpl;
  logic off_req_r, off_cpl_v;
  apu_objpay_cpl_t off_cpl;

  int errors = 0, checks = 0, cycles = 0, cases = 0;

  // ---- objmem plumbing ---------------------------------------------------
  logic         omp_v, omp_r, omp_rv;
  apu_omp_req_t omp_req;
  apu_omp_rsp_t omp_rsp;
  logic         omtr_r, omtr_rv;
  apu_omt_rsp_t omtr_rsp;
  logic         mp_v, mp_r, mp_rv;
  apu_mp_req_t  mp_req;
  apu_mp_rsp_t  mp_rsp;

  g6lc_apu_objpay #(.Enable(1'b1), .PayMemBytes(PayMemBytes)) i_on (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(req_r), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .omp_req_valid_o(omp_v), .omp_req_ready_i(omp_r),
    .omp_req_o(omp_req),
    .omp_rsp_valid_i(omp_rv), .omp_rsp_i(omp_rsp));

  // the omt port is idle in this TB — objmem still needs a legal
  // requester tie-off
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

  // one-port aperture responder: carve window only, 1-8 cycle latency
  // (+mp_lat_* plusargs)
  tb_apu_mp_mem #(.N(1), .GMW(1), .APW(0),
                  .PWB(32'(APU_OBJMEM_OFF >> 2)),
                  .PPW(32'((apu_objmem_pay_off(ObjEntries) +
                            64'(PayMemBytes) - APU_OBJMEM_OFF) >> 2) +
                        64))
      i_mem (
    .clk_i(clk), .rst_ni(rst_ni),
    .req_valid_i(mp_v), .req_ready_o(mp_r), .req_i('{mp_req}),
    .rsp_valid_o(mp_rv), .rsp_o('{mp_rsp}));

  g6lc_apu_objpay_fixture #(.Enable(1'b0),
                            .PayMemBytes(PayMemBytes)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(off_req_r), .req_i(req),
    .cpl_valid_o(off_cpl_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .omp_req_valid_o(), .omp_req_ready_i(1'b0), .omp_req_o(),
    .omp_rsp_valid_i(1'b0), .omp_rsp_i('{default: '0}));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  // trace
  always @(posedge clk) if (omp_v && omp_r)
    $display("[%0t] OMP  we=%0d line=%0d w0=%08x w1=%08x", $time,
             omp_req.we, omp_req.line_addr, omp_req.wdata[31:0],
             omp_req.wdata[63:32]);
  always @(posedge clk) if (omp_rv)
    $display("[%0t] OMPR w0=%08x w1=%08x w32=%08x", $time,
             omp_rsp.rdata[31:0], omp_rsp.rdata[63:32],
             omp_rsp.rdata[511:480]);
  always @(posedge clk) if (mp_v && mp_r)
    $display("[%0t] MP   we=%0d addr=%08x d=%016x", $time,
             mp_req.we, mp_req.addr, mp_req.wdata);
  always @(posedge clk) if (mp_rv)
    $display("[%0t] MPR  d=%016x", $time, mp_rsp.rdata);
  always @(negedge clk) if (off_req_r || off_cpl_v || |off_cpl)
    $fatal(1, "disabled objpay active");

  // ---- reference model ---------------------------------------------------
  // bitmap: 1 = allocated chunk; cursor = bitmap-word index (next-fit)
  bit          m_bmp [NumChunks];
  int unsigned m_cursor;
  logic [31:0] m_mem [PayWords];

  function automatic int m_chunks(input int w);
    return (w + ChunkWords - 1) / ChunkWords;
  endfunction

  // mirror of the DUT scan: bitmap words from the cursor, wrap once,
  // carried free-runs across words, no run across the wrap
  function automatic int m_alloc(input int w);
    int unsigned nch, scan, wrap, run, run_s;
    nch = m_chunks(w);
    if (w == 0) return 0;
    if (nch > NumChunks) return -1;
    scan = m_cursor; wrap = 0; run = 0; run_s = 0;
    forever begin
      // bits of this bitmap word
      automatic logic [63:0] bw;
      automatic int lfree, tset, fnd, a, s;
      bw = '0;
      for (int i = 0; i < 64; i++)
        if (scan * 64 + i < NumChunks) bw[i] = m_bmp[scan*64 + i];
      // LSB-side free prefix (64 when the whole word is free)
      lfree = 64;
      for (int i = 0; i < 64; i++)
        if (bw[i] && lfree == 64) lfree = i;
      if (run + lfree >= nch) begin
        s = (run != 0) ? run_s : scan * 64;
        a = s;
      end else begin
        fnd = -1;
        if (nch <= 64) begin
          for (int i = 0; i + nch <= 64 && fnd < 0; i++) begin
            automatic bit ok = 1'b1;
            for (int j = 0; j < nch; j++) ok &= !bw[i + j];
            if (ok) fnd = i;
          end
        end
        if (fnd >= 0) a = scan * 64 + fnd;
        else if (wrap == BmpWords - 1) return -1;
        else begin
          if (bw == 64'h0) begin
            run += 64;
            if (run == 64) run_s = scan * 64;
          end else begin
            // highest set bit
            tset = 0;
            for (int i = 0; i < 64; i++) if (bw[i]) tset = i;
            run   = 63 - tset;
            run_s = scan * 64 + tset + 1;
          end
          wrap += 1;
          if (scan == BmpWords - 1) begin
            scan = 0; run = 0; run_s = 0;
          end else
            scan += 1;
          continue;
        end
      end
      // found run [a, a+nch): mark + advance cursor like the DUT
      for (int i = 0; i < nch; i++) m_bmp[a + i] = 1;
      m_cursor = ((a + nch) / 64) % BmpWords;
      return a * ChunkWords;
    end
  endfunction

  task automatic m_free(input int base, input int w);
    int n;
    n = m_chunks(w);
    for (int i = 0; i < n; i++) m_bmp[base / ChunkWords + i] = 0;
  endtask

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
    while (!req_r) @(negedge clk);
    req_v = 1'b1; req = '{op: op, addr: a, words: w, wdata: d};
    @(posedge clk);
    @(negedge clk); req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
    c = cpl;
    @(posedge clk);
    @(negedge clk);
  endtask

  // expected status for a word access: in-arena AND in an allocated
  // chunk (the DUT checks the allocation bitmap, not just the arena)
  function automatic apu_objpay_status_e m_acc(input int a);
    if (a >= PayWords) return APU_OBJPAY_BOUNDS;
    if (!m_bmp[a / ChunkWords]) return APU_OBJPAY_BOUNDS;
    return APU_OBJPAY_OK;
  endfunction

  apu_objpay_cpl_t c;
  int base_a, base_b, base_c, base_d, m_base;

  task automatic t_alloc(input int w, output int base);
    apu_objpay_status_e est;
    do_req(APU_OBJPAY_OP_ALLOC, 0, w, 0, c);
    m_base = -1;
    if (w > APU_OBJPAY_MAX_WORDS) est = APU_OBJPAY_BOUNDS;
    else begin
      m_base = m_alloc(w);
      est = m_base < 0 ? APU_OBJPAY_FULL : APU_OBJPAY_OK;
    end
    check($sformatf("alloc(%0d) status", w), c.status == est);
    check($sformatf("alloc(%0d) base", w),
          m_base < 0 || c.base == 32'(m_base));
    base = c.status == APU_OBJPAY_OK ? int'(c.base) : -1;
  endtask

  task automatic t_free(input int base, input int w);
    do_req(APU_OBJPAY_OP_FREE, base, w, 0, c);
    check($sformatf("free(%0d,%0d)", base, w),
          c.status == APU_OBJPAY_OK);
    m_free(base, w);
  endtask

  task automatic t_write(input int a, input logic [31:0] d);
    do_req(APU_OBJPAY_OP_WRITE, a, 0, d, c);
    check($sformatf("write(%0d)", a), c.status == m_acc(a));
    if (m_acc(a) == APU_OBJPAY_OK) m_mem[a] = d;
  endtask

  task automatic t_read(input int a);
    do_req(APU_OBJPAY_OP_READ, a, 0, 0, c);
    check($sformatf("read(%0d) status", a), c.status == m_acc(a));
    if (m_acc(a) == APU_OBJPAY_OK) begin
      if (c.rdata !== m_mem[a])
        $display("  rd(%0d) got=%08x exp=%08x", a, c.rdata, m_mem[a]);
      check($sformatf("read(%0d) data", a), c.rdata === m_mem[a]);
    end
  endtask

  // READN: n (1..16) words inside one 16-word line -> n completions.
  // A burst violating the line/word rules answers one BOUNDS cpl.
  task automatic t_readn(input int a, input int n);
    @(negedge clk);
    while (!req_r) @(negedge clk);
    req_v = 1'b1;
    req   = '{op: APU_OBJPAY_OP_READN, addr: 32'(a),
              words: 32'(n), wdata: '0};
    @(posedge clk);
    @(negedge clk); req_v = 1'b0;
    begin
      automatic bit legal = (a < PayWords) && (n >= 1) && (n <= 16) &&
                            ((a % 16) + n <= 16) &&
                            (m_acc(a) == APU_OBJPAY_OK);
      if (!legal) begin
        while (!cpl_v) @(negedge clk);
        check($sformatf("readn(%0d,%0d) bounds", a, n),
              cpl.status == APU_OBJPAY_BOUNDS);
        @(posedge clk); @(negedge clk);
        check($sformatf("readn(%0d,%0d) idle after bounds", a, n),
              cpl_v == 1'b0);
      end else begin
        for (int i = 0; i < n; i++) begin
          while (!cpl_v) @(negedge clk);
          check($sformatf("readn(%0d,%0d) beat%0d status", a, n, i),
                cpl.status == APU_OBJPAY_OK);
          if (cpl.rdata !== m_mem[a + i])
            $display("  rn(%0d+%0d) got=%08x exp=%08x",
                     a, i, cpl.rdata, m_mem[a + i]);
          check($sformatf("readn(%0d,%0d) beat%0d data", a, n, i),
                cpl.rdata === m_mem[a + i]);
          @(posedge clk); @(negedge clk);
        end
      end
    end
  endtask

  initial begin
    for (int i = 0; i < NumChunks; i++) m_bmp[i] = 0;
    for (int i = 0; i < PayWords; i++) m_mem[i] = '0;
    m_cursor = 0;
    // mirror StInit: chunk 0 stays marked — 0 is the "none" sentinel for
    // extent parkings, so no real allocation may begin at word 0
    m_bmp[0] = 1;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    check("init quiet", cpl_v === 1'b0);
    // objmem cold boot reads the magic pair first
    repeat (40) @(negedge clk);
    while (!req_r) @(negedge clk);
    check("ready", req_r == 1'b1);

    // ---- directed: alloc/write/read/free round trip -----------------
    cases++;
    t_alloc(100, base_a);            // chunks 1-2 -> base 64 (chunk 0
                                     // is the reserved sentinel)
    check("alloc100 base64", base_a == 64);
    for (int i = 0; i < 100; i++) t_write(base_a + i, 32'hA5000000 + i);
    for (int i = 0; i < 100; i++) t_read(base_a + i);
    t_alloc(40, base_b);             // 1 chunk -> base 192
    check("alloc40 base192", base_b == 192);
    t_free(base_a, 100);
    t_alloc(60, base_c);             // next-fit resumes at chunk 3:
                                     // chunk 0-1 free -> base 0 anyway
                                     // only if cursor returned... model
                                     // decides — just check it matches
    check("alloc60 ok", base_c >= 0);
    t_alloc(70, base_d);
    check("alloc70 ok", base_d >= 0);

    // ---- fragmentation ----------------------------------------------
    cases++;
    t_free(base_d, 70);
    t_alloc(200, base_d);            // 4 contiguous chunks somewhere
    check("frag alloc200", base_d >= 0);

    // ---- arena full ---------------------------------------------------
    cases++;
    t_alloc(APU_OBJPAY_MAX_WORDS + 1, base_a);
    check("words>65535 bounds", base_a == -1);
    // fill the rest of the arena chunk-by-chunk
    t_free(base_c, 60); t_free(base_b, 40); t_free(base_d, 200);
    t_alloc(PayWords - 64, base_a);  // all allocatable space (chunk 0
                                     // is permanently reserved)
    check("full-arena alloc", base_a == 64);
    t_alloc(1, base_b);              // nothing left -> FULL
    check("exhausted full", base_b == -1);
    t_free(base_a, PayWords - 64);

    // ---- bounds --------------------------------------------------------
    cases++;
    t_write(PayWords, 32'hDEAD);     // off end -> BOUNDS
    t_read(PayWords);
    // unallocated chunk -> BOUNDS (extent check through the bitmap);
    // chunk 0 itself is permanently marked (reserved sentinel), so use
    // chunk 3 — every chunk but 0 is free at this point
    t_write(192, 32'h1234ABCD);      // chunk 3 free -> BOUNDS
    t_read(192);
    t_alloc(64, base_a);             // one chunk -> word access ok
    t_write(base_a, 32'h1234ABCD);
    t_read(base_a);
    // past the extent but inside the next (unallocated) chunk -> BOUNDS
    t_read(base_a + 64);
    do_req(APU_OBJPAY_OP_FREE, 7, 64, 0, c); // unaligned -> BOUNDS
    check("free unaligned", c.status == APU_OBJPAY_BOUNDS);
    do_req(APU_OBJPAY_OP_FREE, PayWords - 32, 64, 0, c); // past end
    check("free pastend", c.status == APU_OBJPAY_BOUNDS);
    do_req(APU_OBJPAY_OP_FREE, 0, 0, 0, c);  // words==0 -> OK no-op
    check("free0 ok", c.status == APU_OBJPAY_OK);
    do_req(APU_OBJPAY_OP_ALLOC, 0, 0, 0, c); // alloc0 -> OK base 0
    check("alloc0 ok", c.status == APU_OBJPAY_OK && c.base == 32'h0);
    t_free(base_a, 64);

    // ---- write-back: dirty lines evict + read back -------------------
    cases++;
    begin
      // chunk for the data + a second extent to cycle > PayCacheLines
      // other lines through the objmem payload cache
      t_alloc(64, base_a);
      t_alloc(64 * 64, base_b);      // 64 chunks = 256 lines
      for (int i = 0; i < 16; i++)
        t_write(base_a + i, 32'hBEEF0000 + i);
      // touch 40 other (distinct) lines: writes mark them dirty and
      // reads evict; 4-line pay cache rolls many times
      for (int l = 0; l < 40; l++) begin
        t_write(base_b + l * 16, 32'hFACE0000 + l);
        t_read (base_b + l * 16);
      end
      // original words must survive the evictions + write-backs
      for (int i = 0; i < 16; i++) t_read(base_a + i);
      t_free(base_a, 64);
      t_free(base_b, 64 * 64);
    end

    // ---- READN burst reads ----------------------------------------------
    cases++;
    begin
      t_alloc(128, base_a);          // two chunks -> base somewhere
      for (int i = 0; i < 128; i++)
        t_write(base_a + i, 32'hCAFE0000 + i);
      t_readn(base_a, 16);           // full aligned line
      t_readn(base_a + 33, 7);       // mid-line partial burst
      t_readn(base_a + 48, 16);      // line 3, whole line
      t_readn(base_a + 1, 15);       // offset 1..15
      // illegal bursts: cross-line, n=0, n>16, out of arena,
      // unallocated chunk (past the 128-word extent)
      t_readn(base_a + 12, 8);       // off=12 + 8 > 16 -> BOUNDS
      t_readn(base_a, 0);            // n=0 -> BOUNDS
      t_readn(base_a, 17);           // n>16 -> BOUNDS
      t_readn(PayWords - 16, 4);     // out of arena -> BOUNDS
      t_readn(base_a + 128, 4);      // unallocated chunk -> BOUNDS
      // READN immediately after a same-line WRITE exercises the
      // write-merge overlay path
      t_write(base_a + 5, 32'h5555_0005);
      t_readn(base_a, 16);
      t_free(base_a, 128);
    end

    // ---- seeded random vs model -----------------------------------------
    cases++;
    begin
      int bases [32]; int ws [32]; int live;
      logic [31:0] rnd;
      live = 0;
      for (int it = 0; it < 800; it++) begin
        rnd = $urandom;
        if (live < 28 && (rnd[1:0] != 2'd3 || live == 0)) begin
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

  initial begin #60_000_000; $fatal(1, "objpay timeout"); end
endmodule
