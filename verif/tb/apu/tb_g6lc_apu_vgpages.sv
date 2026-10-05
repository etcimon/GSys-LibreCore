// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Directed + seeded-random test of g6lc_apu_vgpages (§7b): first-fit
// page allocation over the aperture window, free/reuse, fragmentation,
// window-full and bounds arms, Enable=0 quiet.  A TB-side reference
// model (bitmap) predicts every completion; ALLOC must return the
// exact first-fit base.
module tb_g6lc_apu_vgpages;
  import g6lc_apu_vgpages_pkg::*;

  localparam int unsigned Pages     = 64;
  localparam int unsigned PageBytes = 4096;
  localparam int unsigned WinBytes  = Pages * PageBytes;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_r, cpl_v, cpl_r = 1;
  apu_vgpages_req_t req = '0;
  apu_vgpages_cpl_t cpl;
  logic off_req_r, off_cpl_v;
  apu_vgpages_cpl_t off_cpl;

  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpages #(.Enable(1'b1), .Pages(Pages),
                     .PageBytes(PageBytes)) i_on (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(req_r), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl));
  g6lc_apu_vgpages_fixture #(.Enable(1'b0), .Pages(Pages),
                             .PageBytes(PageBytes)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(req_v), .req_ready_o(off_req_r), .req_i(req),
    .cpl_valid_o(off_cpl_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) if (off_req_r || off_cpl_v || |off_cpl)
    $fatal(1, "disabled vgpages active");

  // ---- reference model -------------------------------------------------
  bit m_free [Pages];

  function automatic int m_pages(input int b);
    return (b + PageBytes - 1) / PageBytes;
  endfunction
  // first-fit: exact base the DUT must find, -1 if full
  function automatic int m_alloc(input int b);
    int n = m_pages(b);
    if (b == 0) return 0;
    if (n > Pages) return -1; // avoids Pages-n unsigned underflow
    for (int s = 0; s <= Pages - n; s++) begin
      bit ok = 1'b1;
      for (int i = 0; i < n; i++) ok &= m_free[s + i];
      if (ok) begin
        for (int i = 0; i < n; i++) m_free[s + i] = 0;
        return s * PageBytes;
      end
    end
    return -1;
  endfunction
  function automatic void m_release(input int base, input int b);
    int n = m_pages(b);
    for (int i = 0; i < n; i++) m_free[base / PageBytes + i] = 1;
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
  task automatic do_req(input apu_vgpages_op_e op, input logic [31:0] b,
                        input logic [31:0] n, output apu_vgpages_cpl_t c);
    @(negedge clk);
    req_v = 1'b1; req = '{op: op, base: b, bytes: n};
    @(posedge clk);
    @(negedge clk); req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
    c = cpl;
  endtask

  apu_vgpages_cpl_t c;
  int base_a, base_b, base_c, base_d, m_base;

  task automatic t_alloc(input int b, output int base);
    do_req(APU_VGPAGES_OP_ALLOC, 0, b, c);
    m_base = m_alloc(b);
    check($sformatf("alloc(%0d) status", b),
          c.status == (m_base < 0 ? APU_VGPAGES_FULL : APU_VGPAGES_OK));
    check($sformatf("alloc(%0d) base", b),
          m_base < 0 || c.base == 32'(m_base));
    base = c.status == APU_VGPAGES_OK ? int'(c.base) : -1;
  endtask

  task automatic t_free(input int base, input int b);
    do_req(APU_VGPAGES_OP_FREE, base, b, c);
    check($sformatf("free(%0d,%0d)", base, b),
          c.status == APU_VGPAGES_OK);
    m_release(base, b);
  endtask

  initial begin
    for (int i = 0; i < Pages; i++) m_free[i] = 1;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    check("init quiet", cpl_v === 1'b0);
    repeat (2) @(negedge clk);
    check("ready", req_r == 1'b1);

    // ---- directed: alloc/free round trip ---------------------------
    cases++;
    t_alloc(8192, base_a);           // pages 0-1 -> base 0
    check("alloc8192 base0", base_a == 0);
    t_alloc(4096, base_b);           // 1 page -> base 8192
    check("alloc4096 base8192", base_b == 8192);
    t_free(base_a, 8192);
    t_alloc(4096, base_c);           // 1 page -> base 0 (first-fit)
    check("alloc4096 reuse0", base_c == 0);
    t_alloc(8192, base_d);           // pages 1-2? p1 free, p2 busy ->
                                     // pages 3-4 -> base 12288
    check("alloc8192 firstfit", base_d == 12288);

    // ---- fragmentation ---------------------------------------------
    cases++;
    // layout now: p0:C p1:free p2:B p3-4:D p5..:free
    t_free(base_d, 8192);            // free pages 3-4
    t_alloc(16384, base_d);          // 4 contiguous -> pages 3-6 -> 12288
    check("frag alloc16384", base_d == 12288);

    // ---- window full ------------------------------------------------
    cases++;
    t_alloc(WinBytes + 1, base_a);   // over-size -> FULL, no state change
    check("oversize full", base_a == -1);
    for (int i = 0; i < Pages; i++) m_free[i] = 1;
    t_free(base_c, 4096); t_free(base_b, 4096); t_free(base_d, 16384);
    t_alloc(WinBytes, base_a);       // whole window -> base 0
    check("full-window alloc", base_a == 0);
    t_alloc(1, base_b);              // nothing left -> FULL
    check("exhausted full", base_b == -1);
    t_free(base_a, WinBytes);

    // ---- bounds -------------------------------------------------------
    cases++;
    do_req(APU_VGPAGES_OP_FREE, 7, PageBytes, c); // unaligned -> BOUNDS
    check("free unaligned", c.status == APU_VGPAGES_BOUNDS);
    do_req(APU_VGPAGES_OP_FREE, WinBytes - PageBytes/2, PageBytes, c);
    check("free pastend", c.status == APU_VGPAGES_BOUNDS);
    do_req(APU_VGPAGES_OP_FREE, 0, 0, c);  // bytes==0 -> OK no-op
    check("free0 ok", c.status == APU_VGPAGES_OK);
    do_req(APU_VGPAGES_OP_ALLOC, 0, 0, c); // alloc0 -> OK base 0
    check("alloc0 ok", c.status == APU_VGPAGES_OK && c.base == 32'h0);
    // sub-page requests round up to one page
    t_alloc(1, base_a);
    check("alloc1 base0", base_a == 0);
    t_alloc(PageBytes, base_b);
    check("allocpage next", base_b == PageBytes);
    t_free(base_a, 1); t_free(base_b, PageBytes);

    // ---- seeded random vs model --------------------------------------
    cases++;
    begin
      int bases [32]; int bs [32]; int live;
      logic [31:0] rnd;
      live = 0;
      for (int it = 0; it < 800; it++) begin
        rnd = $urandom;
        if (live < 28 && (rnd[1:0] != 2'd3 || live == 0)) begin
          int b = 1 + ($urandom % (8 * PageBytes));
          t_alloc(b, base_a);
          if (base_a >= 0) begin
            bases[live] = base_a; bs[live] = b; live++;
          end
        end else begin
          int k = $urandom % live;
          t_free(bases[k], bs[k]);
          bases[k] = bases[live-1]; bs[k] = bs[live-1]; live--;
        end
      end
      while (live > 0) begin
        live--;
        t_free(bases[live], bs[live]);
      end
    end

    $display("PASS tb_g6lc_apu_vgpages cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "vgpages %0d errors", errors);
    $finish;
  end

  initial begin #20_000_000; $fatal(1, "vgpages timeout"); end
endmodule
