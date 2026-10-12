// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Directed + seeded-random test of g6lc_apu_vgpages (§7b): first-fit
// page allocation over the aperture window, free/reuse, fragmentation,
// window-full and bounds arms, Enable=0 quiet.  A TB-side reference
// model (bitmap) predicts every completion; ALLOC must return the
// exact first-fit base.
module tb_g6lc_apu_vgpages
  import g6lc_apu_vgpages_pkg::*;
#(
  // §12.3 3d-c: run the same body at the shipped 8192-page (32 MiB)
  // geometry and at 65536 pages (256 MiB) — run-apu-vgpages.sh builds
  // both via -GPages
  parameter int unsigned Pages = 8192
);
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

  // §12.3 F5/3d-c: second instance with a device-private arena —
  // guest ops are bounded to [0, GuestBytes), ALLOC_PRIV scans
  // [GuestPages, Pages); the two pools are independent.  The split
  // must land on a 64-page word boundary and the arena must cover at
  // least 1 MiB (elaboration assertions): 768/1024 pages = 3 MiB guest
  // + 1 MiB private at 4 KiB.
  localparam int unsigned PPages = 1024;
  localparam int unsigned GPages = 768;
  logic pv_v = 0, pv_r, pv_cpl_v;
  apu_vgpages_req_t pv_req = '0;
  apu_vgpages_cpl_t pv_cpl;
  g6lc_apu_vgpages #(.Enable(1'b1), .Pages(PPages),
                     .PageBytes(PageBytes), .GuestPages(GPages)) i_priv (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(pv_v), .req_ready_o(pv_r), .req_i(pv_req),
    .cpl_valid_o(pv_cpl_v), .cpl_ready_i(1'b1), .cpl_o(pv_cpl));

  task automatic do_pv(input apu_vgpages_op_e op, input logic [31:0] b,
                       input logic [31:0] n, output apu_vgpages_cpl_t c);
    @(negedge clk);  // let StCpl retire before the next request
    pv_v = 1'b1; pv_req = '{op: op, base: b, excl_hi: '0, bytes: n};
    @(posedge clk);
    @(negedge clk); pv_v = 1'b0;
    while (!pv_cpl_v) @(negedge clk);
    c = pv_cpl;
  endtask

  // §12.3 3d-d: exclusion-carrying variant (base doubles as excl_lo)
  task automatic do_pvx(input apu_vgpages_op_e op,
                        input logic [31:0] b, input logic [31:0] xh,
                        input logic [31:0] n, output apu_vgpages_cpl_t c);
    @(negedge clk);
    pv_v = 1'b1; pv_req = '{op: op, base: b, excl_hi: xh, bytes: n};
    @(posedge clk);
    @(negedge clk); pv_v = 1'b0;
    while (!pv_cpl_v) @(negedge clk);
    c = pv_cpl;
  endtask

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) if (off_req_r || off_cpl_v || |off_cpl)
    $fatal(1, "disabled vgpages active");

  // ---- reference model -------------------------------------------------
  bit m_free [Pages];
  // §12.3 3d-d: model for the private instance's guest window (case 8);
  // module scope because Vlt <5.020 mis-reads `ref` unpacked-array args
  bit p_free [Pages];

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
  // §12.3 3d-d: top-down first-fit inside the guest window, skipping
  // every candidate overlapping the byte exclusion [el, eh)
  // (el == eh = none); -1 when nothing fits.  Operates on p_free:
  // passing it as a `ref` array arg is mis-read by Vlt <5.020.
  function automatic int m_alloc_hi(input int b, input int el,
                                    input int eh, input int gpages);
    int n = m_pages(b);
    if (b == 0) return 0;
    if (n > gpages) return -1;
    for (int s = gpages - n; s >= 0; s--) begin
      bit ok = 1'b1;
      for (int i = 0; i < n; i++) ok &= p_free[s + i];
      // page-granular overlap of [s, s+n) with [el, eh)
      ok &= !(s * PageBytes < eh && el < (s + n) * PageBytes);
      if (ok) begin
        for (int i = 0; i < n; i++) p_free[s + i] = 0;
        return s * PageBytes;
      end
    end
    return -1;
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
    req_v = 1'b1; req = '{op: op, base: b, excl_hi: '0, bytes: n};
    @(posedge clk);
    @(negedge clk); req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
    c = cpl;
  endtask

  apu_vgpages_cpl_t c;
  int base_a, base_b, base_c, base_d, m_base;
  int maxalloc = 0;   // worst observed ALLOC latency in cycles

  task automatic t_alloc(input int b, output int base);
    int c0;
    c0 = cycles;
    do_req(APU_VGPAGES_OP_ALLOC, 0, b, c);
    if (cycles - c0 > maxalloc) maxalloc = cycles - c0;
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
    // unaligned base is legal for FREE (kernel-chosen extents are
    // 4 KiB-class; the run unmarks every covered page, matching
    // ALLOC_AT) — [7, 7+PageBytes) covers pages 0-1, all free anyway
    do_req(APU_VGPAGES_OP_FREE, 7, PageBytes, c);
    check("free unaligned", c.status == APU_VGPAGES_OK);
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

    // ---- worst-case scan latency (§12.3 3d-c) -----------------------
    // fill every word but the last, then a 1-page ALLOC walks all
    // Words summaries (full words skip at 1 cycle each) and finds the
    // only free run at the top of the window
    cases++;
    t_alloc(WinBytes - PageBytes, base_a);
    check("fill base0", base_a == 0);
    t_alloc(PageBytes, base_b);
    check("worst-fit top page", base_b == WinBytes - PageBytes);
    t_free(base_b, PageBytes);
    t_free(base_a, WinBytes - PageBytes);

    // ---- private arena (§12.3 F5) ------------------------------------
    cases++;
    begin
      apu_vgpages_cpl_t pc;
      do_pv(APU_VGPAGES_OP_ALLOC, 0, 32'(GPages) * PageBytes, pc);
      check("guest whole window", pc.status == APU_VGPAGES_OK &&
            pc.base == 32'h0);
      do_pv(APU_VGPAGES_OP_ALLOC, 0, PageBytes, pc);
      check("guest window full", pc.status == APU_VGPAGES_FULL);
      do_pv(APU_VGPAGES_OP_ALLOC_PRIV, 0, 32'(PPages - GPages) *
            PageBytes, pc);
      check("priv whole arena", pc.status == APU_VGPAGES_OK &&
            pc.base == 32'(GPages) * PageBytes);
      do_pv(APU_VGPAGES_OP_ALLOC_PRIV, 0, PageBytes, pc);
      check("priv arena full", pc.status == APU_VGPAGES_FULL);
      // guest-chosen extents cannot reach into the private arena
      do_pv(APU_VGPAGES_OP_ALLOC_AT, 32'(GPages) * PageBytes, PageBytes,
            pc);
      check("alloc_at into priv bounds",
            pc.status == APU_VGPAGES_BOUNDS);
      // freeing the private extent releases it for reuse
      do_pv(APU_VGPAGES_OP_FREE, 32'(GPages) * PageBytes,
            32'(PPages - GPages) * PageBytes, pc);
      check("priv free", pc.status == APU_VGPAGES_OK);
      do_pv(APU_VGPAGES_OP_ALLOC_PRIV, 0, PageBytes, pc);
      check("priv reuse", pc.status == APU_VGPAGES_OK &&
            pc.base == 32'(GPages) * PageBytes);
      do_pv(APU_VGPAGES_OP_FREE, 32'(GPages) * PageBytes, PageBytes, pc);
      do_pv(APU_VGPAGES_OP_FREE, 0, 32'(GPages) * PageBytes, pc);
    end

    // ---- §12.3 3d-d: ALLOC_HI top-down + exclusion -------------------
    cases++;
    begin
      apu_vgpages_cpl_t pc;
      int               mb;
      // model mirror for the private instance's guest window: the
      // guest range [0,GPages) starts all-free here
      for (int i = 0; i < Pages; i++) p_free[i] = (i < GPages);
      // highest-address placement in the guest window
      do_pvx(APU_VGPAGES_OP_ALLOC_HI, 0, 0, 4 * PageBytes, pc);
      mb = m_alloc_hi(4 * PageBytes, 0, 0, GPages);
      check("hi top-down status", pc.status == APU_VGPAGES_OK);
      check("hi top-down base", pc.base == 32'((GPages - 4) * PageBytes)
            && mb == int'(pc.base));
      do_pvx(APU_VGPAGES_OP_ALLOC_HI, 0, 0, 2 * PageBytes, pc);
      mb = m_alloc_hi(2 * PageBytes, 0, 0, GPages);
      check("hi second base", pc.status == APU_VGPAGES_OK &&
            pc.base == 32'((GPages - 6) * PageBytes) &&
            mb == int'(pc.base));
      // exclusion [GPages-8, GPages-4): the evicted squatter must land
      // below the excluded kernel range, not inside or above it
      do_pvx(APU_VGPAGES_OP_ALLOC_HI,
             32'((GPages - 8) * PageBytes),
             32'((GPages - 4) * PageBytes),
             2 * PageBytes, pc);
      mb = m_alloc_hi(2 * PageBytes, (GPages - 8) * PageBytes,
                      (GPages - 4) * PageBytes, GPages);
      check("hi excl status", pc.status == APU_VGPAGES_OK);
      check("hi excl base", pc.base == 32'((GPages - 10) * PageBytes)
            && mb == int'(pc.base));
      // seeded ALLOC_HI/FREE loop against the model
      begin
        int hb [16]; int hbz [16]; int hlv;
        logic [31:0] rnd, xb, xe;
        hlv = 0;
        for (int it = 0; it < 300; it++) begin
          rnd = $urandom;
          if (hlv < 12 && (rnd[1:0] != 2'd3 || hlv == 0)) begin
            int b = 1 + ($urandom % (8 * PageBytes));
            xb = rnd[7] ? 32'($urandom % WinBytes) : 32'h0;
            xe = rnd[7] ? xb + 32'($urandom % (16 * PageBytes)) : 32'h0;
            do_pvx(APU_VGPAGES_OP_ALLOC_HI, xb, xe, b, pc);
            mb = m_alloc_hi(b, int'(xb), int'(xe), GPages);
            check("hi rand status",
                  pc.status == (mb < 0 ? APU_VGPAGES_FULL
                                       : APU_VGPAGES_OK));
            if (mb >= 0 && pc.base != 32'(mb))
              $display("HI-DIV it=%0d b=%0d xb=%08x xe=%08x dut=%08x mdl=%08x st=%0d",
                       it, b, xb, xe, pc.base, 32'(mb), pc.status);
            check("hi rand base",
                  mb < 0 || pc.base == 32'(mb));
            if (pc.status == APU_VGPAGES_OK) begin
              hb[hlv] = int'(pc.base); hbz[hlv] = b; hlv++;
            end
          end else begin
            int k = $urandom % hlv;
            do_pv(APU_VGPAGES_OP_FREE, hb[k], hbz[k], pc);
            check("hi rand free", pc.status == APU_VGPAGES_OK);
            for (int i = 0; i < hbz[k]; i += PageBytes)
              p_free[(hb[k] + i) / PageBytes] = 1;
            hb[k] = hb[hlv-1]; hbz[k] = hbz[hlv-1]; hlv--;
          end
        end
        while (hlv > 0) begin
          hlv--;
          do_pv(APU_VGPAGES_OP_FREE, hb[hlv], hbz[hlv], pc);
        end
      end
      // FULL: exclude almost the whole window, ask for two pages
      do_pvx(APU_VGPAGES_OP_ALLOC_HI, PageBytes,
             32'((GPages - 1) * PageBytes), 2 * PageBytes, pc);
      check("hi full", pc.status == APU_VGPAGES_FULL);
    end

    $display("PASS tb_g6lc_apu_vgpages pages=%0d cases=%0d checks=%0d \
cycles=%0d maxalloc=%0d", Pages, cases, checks, cycles, maxalloc);
    if (errors != 0) $fatal(1, "vgpages %0d errors", errors);
    $finish;
  end

  initial begin #20_000_000; $fatal(1, "vgpages timeout"); end
endmodule
