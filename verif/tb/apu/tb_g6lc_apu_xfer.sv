// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Standalone gate for g6lc_apu_xfer (§12.3 phase C, increment 5a of
// architecture/uncore/apu-vulkan-engine.md): vkCmdCopyBuffer /
// vkCmdFillBuffer / vkCmdUpdateBuffer executed by the engine's checked
// DMA pair against a burst-capable AXI aperture model.
//
// Composition: g6lc_apu_cmdrec (the real module — the TB stages
// payload words through BEGIN/APPEND/pay-stream/END exactly like
// vnpump's writer, and the DUT replays them through PAYREAD) +
// g6lc_apu_xfer + a byte-accurate AXI slave over the aperture array
// apm[].
//
// AXI invariants, always on:
//   * every AW/AR address (and every read-burst beat) inside the
//     aperture window [AB, AB+APB);
//   * <= 3 transactions outstanding (the DUT itself caps at 2: one
//     read burst + one write);
//   * write bursts are single-beat (aw.len == 0, w.last) — the DMA
//     write engine is narrow;
//   * every accepted AW+W answers a B, every AR a complete R burst
//     (balance check after every test).
//
// Coverage:
//   * COPY: >= 200 randomized cases — region count 1..4, sizes
//     0..1024, src/dst offsets sweeping every (mod 8) pair plus
//     fully-random heads/tails, regions crossing 4 KiB, same-buffer
//     and split-buffer operands.  Checked byte-for-byte against a
//     shadow memory over both operand extents.
//   * FILL: explicit size, VK_WHOLE_SIZE tail fill, misaligned
//     dstOffset / size refused before any write beat.
//   * UPDATE: staged pData words from the arena; dataSize % 4 != 0
//     refused.
//   * negatives: region beyond the destination mapping -> FAULT with
//     zero bytes written; overlapping src/dst -> refused before any
//     beat (the W-beat counter must not move).
//   * Enable=0: constant-inactive outputs.

module tb_g6lc_apu_xfer;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_sh_pkg::*;

  localparam logic [63:0] AB   = APU_SHM_BASE;
  localparam int unsigned APW  = 32'h40000;            // 1 MiB / 4 B
  localparam logic [63:0] APB  = 64'(APW) * 4;
  localparam int unsigned MAXCYC = 200_000_000;

  // operand geometry inside the aperture
  localparam int unsigned SRCB = 32'h2000;   // src buffer base offset
  localparam int unsigned DSTB = 32'h8000;   // dst buffer base offset
  localparam int unsigned BUFZ = 32'h2000;   // 8 KiB each

  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cases = 0, cycles = 0;
  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (cycles > MAXCYC) $fatal(1, "timeout");
  end

  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL %s (cycle %0d)", what, cycles);
    end
  endtask

  // ---- DUT ---------------------------------------------------------------
  logic               w_v = 0, w_rdy;
  apu_cmdexec_work_t  work;
  apu_xfer_desc_t     xf;
  logic               done;
  apu_sh_done_t       done_pl;
  logic               xf_busy;
  logic               flush = 0;
  apu_dma_axi_req_t   areq;
  apu_dma_axi_resp_t  arsp;

  // cmdrec ports: TB staging requests vs DUT PAYREAD
  logic               xf_cr_v, xf_cr_rdy, xf_cr_cpl_rdy;
  apu_cmdrec_req_t    xf_cr_req;
  logic               st_req_v = 0;
  apu_cmdrec_req_t    st_req = '0;
  logic               cr_req_v, cr_req_rdy, cr_cpl_v, cr_cpl_rdy;
  apu_cmdrec_req_t    cr_req;
  apu_cmdrec_cpl_t    cr_cpl;
  logic               pay_v = 0, pay_rdy;
  logic [31:0]        pay_d = '0;
  logic               cpl_own_q;   // 0 = TB staging, 1 = DUT

  // staging only ever runs while the engine is idle, so a completion
  // while cpl_own_q == 0 is always the staging request's
  assign cr_req_v  = st_req_v | xf_cr_v;
  assign cr_req    = st_req_v ? st_req : xf_cr_req;
  assign xf_cr_rdy = xf_cr_v & !st_req_v & cr_req_rdy;
  assign cr_cpl_rdy = cpl_own_q ? xf_cr_cpl_rdy : 1'b1;



  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) cpl_own_q <= 1'b0;
    else if (cr_req_v && cr_req_rdy) cpl_own_q <= !st_req_v;
  end

  g6lc_apu_cmdrec #(.Enable(1'b1), .NumBufs(2), .RecsPerBuf(64),
                    .PayWordsPerBuf(1024)) i_rec (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(cr_req_v), .req_ready_o(cr_req_rdy),
    .req_i(cr_req),
    .cpl_valid_o(cr_cpl_v), .cpl_ready_i(cr_cpl_rdy),
    .cpl_o(cr_cpl),
    .pay_valid_i(pay_v), .pay_data_i(pay_d), .pay_ready_o(pay_rdy));

  g6lc_apu_xfer #(.Enable(1'b1), .ApuCfg(ApuVenus),
                  .FifoDepth(32)) i_dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .work_valid_i(w_v), .work_ready_o(w_rdy),
    .work_i(work), .xf_i(xf),
    .done_o(done), .done_pl_o(done_pl),
    .cr_req_valid_o(xf_cr_v), .cr_req_ready_i(xf_cr_rdy),
    .cr_req_o(xf_cr_req),
    .cr_cpl_valid_i(cr_cpl_v), .cr_cpl_ready_o(xf_cr_cpl_rdy),
    .cr_cpl_i(cr_cpl),
    .ap_base_i(AB), .flush_i(flush),
    .busy_o(xf_busy),
    .axi_req_o(areq), .axi_rsp_i(arsp));

  // Enable=0 fixture: outputs stay constant-inactive
  logic o_wr, o_dn, o_crv, o_crr, o_bsy;
  apu_sh_done_t o_pl;
  apu_dma_axi_req_t o_areq;
  g6lc_apu_xfer_fixture #(.Enable(1'b0), .ApuCfg(ApuVenus)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .work_valid_i(w_v), .work_ready_o(o_wr),
    .work_i(work), .xf_i(xf),
    .done_o(o_dn), .done_pl_o(o_pl),
    .cr_req_valid_o(o_crv), .cr_req_ready_i(1'b0),
    .cr_req_o(),
    .cr_cpl_valid_i(1'b0), .cr_cpl_ready_o(o_crr),
    .cr_cpl_i('0),
    .ap_base_i(AB), .flush_i(flush),
    .busy_o(o_bsy),
    .axi_req_o(o_areq), .axi_rsp_i('0));

  // ---- aperture memory ---------------------------------------------------
  logic [31:0] apm [APW];
  logic [31:0] epm [APW];              // shadow for byte-for-byte compare

  function automatic logic [7:0] rd8(input logic [63:0] a);
    logic [63:0] o;
    o = a - AB;
    return apm[32'(o >> 2)][8*(o[1:0]) +: 8];
  endfunction
  function automatic logic [7:0] erd8(input int unsigned o);
    return epm[o >> 2][8*(o[1:0]) +: 8];
  endfunction
  function automatic void wr8(input logic [63:0] a, input logic [7:0] d);
    logic [63:0] o;
    o = a - AB;
    apm[32'(o >> 2)][8*(o[1:0]) +: 8] = d;
  endfunction
  function automatic void ewr8(input int unsigned o, input logic [7:0] d);
    epm[o >> 2][8*(o[1:0]) +: 8] = d;
  endfunction

  // ---- AXI4 slave model ----------------------------------------------------
  // window assertion + burst-capable reads + single-beat writes +
  // <=3 outstanding + AW/W/B and AR/R balance
  logic               r_act, r_vld;
  apu_dma_axi_r_chan_t  rch;
  logic [63:0]        r_addr;
  logic [2:0]         r_size;
  int unsigned        r_rem;
  logic               aw_s, w_s, b_vld;
  apu_dma_axi_aw_chan_t waw;
  apu_dma_axi_w_chan_t  ww;
  int unsigned        aw_n = 0, w_n = 0, b_n = 0, ar_n = 0, r_n = 0;
  int unsigned        ar_beats = 0;
  int unsigned        outst = 0;
  int unsigned        rd_wait = 0, axi_rd_dly = 0;
  int unsigned        bytes_wr = 0;

  always_comb begin
    arsp = '0;
    arsp.ar_ready = !r_act && !r_vld;
    arsp.r_valid  = r_vld;
    arsp.r        = rch;
    arsp.aw_ready = !aw_s;
    arsp.w_ready  = !w_s;
    arsp.b_valid  = b_vld;
    arsp.b        = '{id: 4'd1, resp: axi_pkg::RESP_OKAY, user: '0};
  end

  task automatic win_check(input logic [63:0] a, input string tag);
    if (!(a >= AB && a < AB + APB))
      $fatal(1, "AXI %s address %016x outside aperture window", tag, a);
  endtask

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_act <= 0; r_vld <= 0; r_rem <= 0; r_addr <= '0; r_size <= '0;
      aw_s <= 0; w_s <= 0; b_vld <= 0; waw <= '0; ww <= '0;
      rch <= '0; rd_wait <= 0;
    end else begin
      // ---- read channel: one burst in flight ----------------------
      if (areq.ar_valid && arsp.ar_ready) begin
        win_check(areq.ar.addr, "AR");
        if (areq.ar.burst != axi_pkg::BURST_INCR)
          $fatal(1, "AXI: non-INCR read burst");
        r_act   <= 1;
        r_addr  <= areq.ar.addr;
        r_size  <= areq.ar.size;
        r_rem   <= int'(areq.ar.len) + 1;
        rd_wait <= axi_rd_dly;
        ar_n++;
        ar_beats += int'(areq.ar.len) + 1;
        outst++;
        if (outst > 3)
          $fatal(1, "AXI: outstanding bound %0d > 3", outst);
      end
      if (r_act && !r_vld) begin
        if (rd_wait != 0) rd_wait <= rd_wait - 1;
        else begin
          win_check(r_addr & ~64'h7, "R");
          rch <= '0;
          rch.id   <= '0;
          rch.resp <= axi_pkg::RESP_OKAY;
          rch.last <= r_rem == 1;
          for (int b = 0; b < 8; b++)
            rch.data[8*b +: 8] <= rd8((r_addr & ~64'h7) + 64'(b));
          r_vld <= 1;
        end
      end
      if (r_vld && areq.r_ready) begin
        r_vld <= 0;
        r_n++;
        r_addr <= r_addr + (64'd1 << r_size);
        if (r_rem <= 1) begin
          r_act <= 0;
          outst--;
        end else r_rem <= r_rem - 1;
      end

      // ---- write channel: single-beat writes; W may precede AW ----
      if (areq.aw_valid && arsp.aw_ready) begin
        win_check(areq.aw.addr, "AW");
        if (areq.aw.len != 0)
          $fatal(1, "AXI: write burst len %0d (engine is narrow)",
                 areq.aw.len);
        aw_s <= 1; waw <= areq.aw;
        aw_n++;
        outst++;
        if (outst > 3)
          $fatal(1, "AXI: outstanding bound %0d > 3", outst);
      end
      if (areq.w_valid && arsp.w_ready) begin
        if (!areq.w.last) $fatal(1, "AXI: multi-beat write");
        w_s <= 1; ww <= areq.w;
        w_n++;
      end
      if (aw_s && w_s && !b_vld) begin
        for (int b = 0; b < 8; b++)
          if (ww.strb[b]) begin
            wr8((waw.addr & ~64'h7) + 64'(b), ww.data[8*b +: 8]);
            bytes_wr++;
          end
        b_vld <= 1;
      end
      if (b_vld && areq.b_ready) begin
        b_vld <= 0; aw_s <= 0; w_s <= 0;
        b_n++;
        outst--;
      end
    end
  end

  task automatic axi_balance(input string where);
    check(aw_n == w_n && w_n == b_n,
          $sformatf("%s: write balance aw=%0d w=%0d b=%0d",
                    where, aw_n, w_n, b_n));
    check(ar_beats == r_n,
          $sformatf("%s: read balance beats=%0d r=%0d",
                    where, ar_beats, r_n));
  endtask

  // ---- cmdrec staging --------------------------------------------------------
  // The TB mirrors the bump pointer of arena buffer 0.
  int unsigned  pay_top = 0;
  logic [31:0]  stage_w [1024];

  // drive one request (negedge-style stimulus like the sibling TBs);
  // for a payload APPEND stream stage_w[] afterwards, then wait for
  // the completion and require OK
  task automatic do_op(input apu_cmdrec_op_e op, input int cbuf,
                       input apu_cmdrec_rec_t rec, input int pay_n);
    int mark = cycles;
    @(negedge clk);
    st_req   = '{op: op, cbuf: 8'(cbuf), idx: '0, pay_n: 16'(pay_n),
                 rec: rec};
    st_req_v = 1'b1;
    @(posedge clk);
    while (!cr_req_rdy) begin
      @(posedge clk);
      if (cycles - mark > 100000)
        $fatal(1, "do_op req stuck op=%0d cbuf=%0d", op, cbuf);
    end
    @(negedge clk);
    st_req_v = 1'b0;
    if (op == APU_CMDREC_OP_APPEND && pay_n != 0) begin
      for (int i = 0; i < pay_n; i++) begin
        pay_v = 1'b1;
        pay_d = stage_w[i];
        @(posedge clk);
        while (!pay_rdy) @(posedge clk);
        @(negedge clk);
      end
      pay_v = 1'b0;
    end
    while (!(cr_cpl_v && !cpl_own_q)) begin
      @(negedge clk);
      if (cycles - mark > 100000)
        $fatal(1, "do_op cpl stuck op=%0d cpl_v=%b own=%b st=%0d",
               op, cr_cpl_v, cpl_own_q, i_rec.gen_on.state_q);
    end
    check(cr_cpl.status == APU_CMDREC_OK,
          $sformatf("cmdrec op %0d status %0d", op, cr_cpl.status));
  endtask

  task automatic begin_buf(input int cbuf);
    do_op(APU_CMDREC_OP_BEGIN, cbuf, '0, 0);
    if (cbuf == 0) pay_top = 0;
  endtask
  task automatic append_payload(input int cbuf, input int unsigned n);
    do_op(APU_CMDREC_OP_APPEND, cbuf, '0, int'(n));
    if (cbuf == 0) pay_top += n;
  endtask
  task automatic seal_buf(input int cbuf);
    do_op(APU_CMDREC_OP_END, cbuf, '0, 0);
  endtask

  // ---- work issue -------------------------------------------------------------
  task automatic issue(input apu_xfer_desc_t x, input logic [31:0] pat,
                       output apu_sh_done_t pl);
    int mark = cycles;
    work = '0;
    work.ctype = x.op == APU_XFER_OP_COPY
                 ? 32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT) :
                 x.op == APU_XFER_OP_FILL
                 ? 32'(APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT)
                 : 32'(APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT);
    work.rec.ctype  = work.ctype;
    work.rec.imm[0] = pat;
    @(negedge clk);
    xf  = x;
    w_v = 1'b1;
    @(posedge clk);
    while (!w_rdy) begin
      @(posedge clk);
      if (cycles - mark > 100000)
        $fatal(1, "issue: work not accepted");
    end
    @(negedge clk);
    w_v = 1'b0;
    while (!done) begin
      @(negedge clk);
      if (cycles - mark > 2000000)
        $fatal(1, "issue: done never arrived (busy=%b)", xf_busy);
    end
    pl = done_pl;
  endtask

  // ---- memory helpers -----------------------------------------------------------
  task automatic fill_src(input int unsigned base, input int unsigned n,
                          input int unsigned sd);
    for (int i = 0; i < int'(n); i++) begin
      automatic logic [7:0] v = 8'((sd * 31 + i * 7 + (i >> 4)) & 8'hff);
      wr8(AB + 64'(base + i), v);
      ewr8(base + i, v);
    end
  endtask
  task automatic poison(input int unsigned base, input int unsigned n);
    for (int i = 0; i < int'(n); i++) begin
      wr8(AB + 64'(base + i), 8'hA5);
      ewr8(base + i, 8'hA5);
    end
  endtask
  // compare aperture vs shadow over [lo, hi); one check per range with
  // the first mismatch reported
  task automatic cmp_range(input int unsigned lo, input int unsigned hi,
                           input string what);
    int bad = -1;
    for (int i = int'(lo); i < int'(hi); i++)
      if (bad < 0 && rd8(AB + 64'(i)) != erd8(i)) bad = i;
    check(bad < 0,
          $sformatf("%s: byte %05x exp %02x got %02x", what, bad,
                    bad < 0 ? 8'h0 : erd8(bad),
                    bad < 0 ? 8'h0 : rd8(AB + 64'(bad))));
  endtask

  // ---- COPY driver ------------------------------------------------------------
  task automatic run_copy(input int unsigned nreg,
                          input logic [63:0] soff [], doff [], sz [],
                          input bit same_map,
                          output apu_sh_done_t pl);
    int unsigned pb;
    begin_buf(0);
    for (int r = 0; r < int'(nreg); r++) begin
      stage_w[6*r+0] = soff[r][31:0];
      stage_w[6*r+1] = soff[r][63:32];
      stage_w[6*r+2] = doff[r][31:0];
      stage_w[6*r+3] = doff[r][63:32];
      stage_w[6*r+4] = sz[r][31:0];
      stage_w[6*r+5] = sz[r][63:32];
    end
    pb = pay_top;
    append_payload(0, 6*int'(nreg));
    seal_buf(0);
    issue('{op: APU_XFER_OP_COPY, cbuf: 8'd0, pay_base: 16'(pb),
           regions: 16'(nreg),
           src_base: SRCB, src_size: BUFZ,
           dst_base: same_map ? SRCB : DSTB, dst_size: BUFZ},
          '0, pl);
  endtask

  // ---- main sequence -----------------------------------------------------------
  apu_sh_done_t pl;
  int unsigned  seed = 32'h5eed_0001;
  int unsigned  ncases = 0;
  logic [63:0]  so [], do_ [], sz [];
  int unsigned  copy_ok = 0;
  int unsigned  wmark, cycles_mark;

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cases=%d", ncases));
    if (ncases == 0) ncases = 240;
    for (int i = 0; i < int'(APW); i++) begin apm[i] = '0; epm[i] = '0; end
    repeat (8) @(posedge clk);
    rst_ni = 1'b1;
    repeat (4) @(posedge clk);

    // ============ directed: 1 KiB aligned copy (perf datum) =============
    cases++;
    poison(SRCB, BUFZ); poison(DSTB, BUFZ);
    fill_src(SRCB, 1024, 3);
    so = new[1]; do_ = new[1]; sz = new[1];
    so[0] = 0; do_[0] = 0; sz[0] = 1024;
    for (int i = 0; i < 1024; i++) ewr8(DSTB + i, erd8(SRCB + i));
    cycles_mark = cycles;
    run_copy(1, so, do_, sz, 0, pl);
    $display("COPY1K cycles=%0d", cycles - cycles_mark);
    check(pl.code == APU_SH_DONE_OK, "copy1k done code");
    cmp_range(DSTB, DSTB + 1024, "copy1k dst");
    cmp_range(DSTB + 1024, DSTB + 1088, "copy1k guard");
    cmp_range(SRCB, SRCB + 1024, "copy1k src");
    axi_balance("copy1k");

    // ============ randomized COPY =====================================
    for (int c = 0; c < int'(ncases); c++) begin
      automatic int unsigned nreg;
      automatic bit same_map;
      cases++;
      same_map = (c % 7 == 3);            // every 7th: one mapping
      nreg = 1 + ($urandom(seed + c) % 4);
      so = new[nreg]; do_ = new[nreg]; sz = new[nreg];
      for (int r = 0; r < int'(nreg); r++) begin
        automatic int unsigned soff, doff, mx, n;
        // sweep every (mod 8) src/dst pair across the first 64 cases
        if (c < 64) begin
          soff = (c & 7) + (($urandom(seed + c*31 + r) % 128) & ~32'h7);
          doff = ((c >> 3) & 7) +
                 (($urandom(seed + c*17 + r) % 128) & ~32'h7);
        end else if (c % 11 == 4) begin
          // page-crossing sources and destinations
          soff = 4096 - 40 + ($urandom(seed + c*13 + r) % 32);
          doff = 4096 - 24 + ($urandom(seed + c*19 + r) % 32);
        end else begin
          soff = $urandom(seed + c*29 + r) % BUFZ;
          doff = $urandom(seed + c*23 + r) % BUFZ;
        end
        mx = BUFZ - soff < BUFZ - doff ? BUFZ - soff : BUFZ - doff;
        n  = mx == 0 ? 0 :
             $urandom(seed + c*37 + r*3) % (mx > 1024 ? 1025 : mx + 1);
        if (c % 13 == 5) n = 0;           // a sprinkling of size-0
        if (same_map) begin
          // Vulkan union rule: union(src) must not intersect
          // union(dst) — the engine checks every src/dst pair, so the
          // TB must keep the committed extents disjoint too
          automatic bit bad = 1'b0;
          automatic int unsigned tries = 0;
          do begin
            bad = 1'b0;
            if (n != 0) begin
              if (doff < soff + n && soff < doff + n) bad = 1'b1;
              for (int k = 0; k < int'(r); k++) begin
                if (soff < int'(do_[k]) + int'(sz[k]) &&
                    int'(do_[k]) < soff + n) bad = 1'b1;
                if (doff < int'(so[k]) + int'(sz[k]) &&
                    int'(so[k]) < doff + n) bad = 1'b1;
              end
            end
            if (bad) begin
              tries++;
              doff = $urandom(seed + c*101 + r*7 + tries) % BUFZ;
              if (doff + n > BUFZ) n = BUFZ - doff;
            end
          end while (bad && tries < 8);
          if (bad) n = 0;
        end
        so[r] = 64'(soff); do_[r] = 64'(doff); sz[r] = 64'(n);
      end
      fill_src(SRCB, BUFZ, 100 + c);
      if (!same_map) poison(DSTB, BUFZ);
      // expected shadow: apply the regions in order (Vulkan's
      // no-overlap rule makes the in-order apply exact)
      for (int r = 0; r < int'(nreg); r++)
        for (int i = 0; i < int'(sz[r]); i++)
          ewr8((same_map ? SRCB : DSTB) + int'(do_[r]) + i,
               erd8(SRCB + int'(so[r]) + i));
      run_copy(nreg, so, do_, sz, same_map, pl);
      check(pl.code == APU_SH_DONE_OK,
            $sformatf("copy case %0d done code %0d", c, pl.code));
      if (pl.code == APU_SH_DONE_OK) copy_ok++;
      if (same_map)
        cmp_range(SRCB, SRCB + BUFZ, $sformatf("copy %0d same-buf", c));
      else begin
        cmp_range(DSTB, DSTB + BUFZ, $sformatf("copy %0d dst", c));
        cmp_range(SRCB, SRCB + BUFZ, $sformatf("copy %0d src", c));
      end
      axi_balance($sformatf("copy %0d", c));
    end
    check(copy_ok == int'(ncases), "all randomized copies DONE_OK");

    // ============ FILL =================================================
    cases++;
    begin_buf(0);
    stage_w[0] = 32'h40; stage_w[1] = 0;          // dstOffset = 64
    stage_w[2] = 32'h200; stage_w[3] = 0;         // size = 512
    append_payload(0, 4); seal_buf(0);
    poison(DSTB, BUFZ);
    for (int i = 64; i < 64 + 512; i++) ewr8(DSTB + i, 8'h5A);
    issue('{op: APU_XFER_OP_FILL, cbuf: 8'd0, pay_base: 16'(0),
           regions: '0, src_base: '0, src_size: '0,
           dst_base: DSTB, dst_size: BUFZ}, 32'h5A5A_5A5A, pl);
    check(pl.code == APU_SH_DONE_OK, "fill done code");
    cmp_range(DSTB, DSTB + BUFZ, "fill");
    axi_balance("fill");

    // VK_WHOLE_SIZE tail
    cases++;
    begin_buf(0);
    stage_w[0] = 32'h1FF0; stage_w[1] = 0;
    stage_w[2] = 32'hFFFF_FFFF; stage_w[3] = 32'hFFFF_FFFF;
    append_payload(0, 4); seal_buf(0);
    poison(DSTB, BUFZ);
    for (int i = 32'h1FF0; i < int'(BUFZ); i++) ewr8(DSTB + i, 8'hC3);
    issue('{op: APU_XFER_OP_FILL, cbuf: 8'd0, pay_base: 16'(0),
           regions: '0, src_base: '0, src_size: '0,
           dst_base: DSTB, dst_size: BUFZ}, 32'hC3C3_C3C3, pl);
    check(pl.code == APU_SH_DONE_OK, "fill WHOLE done code");
    cmp_range(DSTB, DSTB + BUFZ, "fill WHOLE");
    axi_balance("fill-whole");

    // misaligned dstOffset -> FAULT, zero bytes written
    cases++;
    begin_buf(0);
    stage_w[0] = 32'h42; stage_w[1] = 0;
    stage_w[2] = 32'h100; stage_w[3] = 0;
    append_payload(0, 4); seal_buf(0);
    poison(DSTB, BUFZ);
    wmark = w_n;
    issue('{op: APU_XFER_OP_FILL, cbuf: 8'd0, pay_base: 16'(0),
           regions: '0, src_base: '0, src_size: '0,
           dst_base: DSTB, dst_size: BUFZ}, 32'hAAAA_AAAA, pl);
    check(pl.code == APU_SH_DONE_FAULT, "fill misaligned dstOff FAULT");
    check(w_n == wmark, "fill misaligned: zero W beats");
    cmp_range(DSTB, DSTB + BUFZ, "fill misaligned guard");

    // misaligned size -> FAULT
    cases++;
    begin_buf(0);
    stage_w[0] = 32'h0; stage_w[1] = 0;
    stage_w[2] = 32'h102; stage_w[3] = 0;
    append_payload(0, 4); seal_buf(0);
    poison(DSTB, BUFZ);
    wmark = w_n;
    issue('{op: APU_XFER_OP_FILL, cbuf: 8'd0, pay_base: 16'(0),
           regions: '0, src_base: '0, src_size: '0,
           dst_base: DSTB, dst_size: BUFZ}, 32'hBBBB_BBBB, pl);
    check(pl.code == APU_SH_DONE_FAULT, "fill misaligned size FAULT");
    check(w_n == wmark, "fill misaligned size: zero W beats");

    // ============ UPDATE ===============================================
    cases++;
    begin_buf(0);
    stage_w[0] = 32'h80; stage_w[1] = 0;          // dstOffset = 128
    stage_w[2] = 32'd64; stage_w[3] = 0;          // dataSize = 64
    for (int i = 0; i < 16; i++)
      stage_w[4 + i] = 32'hD00D_0000 + 32'(i);
    append_payload(0, 4 + 16); seal_buf(0);
    poison(DSTB, BUFZ);
    for (int i = 0; i < 64; i++)
      ewr8(DSTB + 128 + i,
           8'((32'hD00D_0000 + 32'(i >> 2)) >> (8 * (i & 3))));
    issue('{op: APU_XFER_OP_UPDATE, cbuf: 8'd0, pay_base: 16'(0),
           regions: '0, src_base: '0, src_size: '0,
           dst_base: DSTB, dst_size: BUFZ}, '0, pl);
    check(pl.code == APU_SH_DONE_OK, "update done code");
    cmp_range(DSTB, DSTB + BUFZ, "update");
    axi_balance("update");

    // dataSize % 4 != 0 -> FAULT
    cases++;
    begin_buf(0);
    stage_w[0] = 32'h0; stage_w[1] = 0;
    stage_w[2] = 32'd62; stage_w[3] = 0;
    append_payload(0, 4); seal_buf(0);
    poison(DSTB, BUFZ);
    wmark = w_n;
    issue('{op: APU_XFER_OP_UPDATE, cbuf: 8'd0, pay_base: 16'(0),
           regions: '0, src_base: '0, src_size: '0,
           dst_base: DSTB, dst_size: BUFZ}, '0, pl);
    check(pl.code == APU_SH_DONE_FAULT, "update misaligned FAULT");
    check(w_n == wmark, "update misaligned: zero W beats");

    // ============ negative: region past dst mapping ======================
    cases++;
    begin_buf(0);
    stage_w[0] = 0; stage_w[1] = 0;               // srcOff = 0
    stage_w[2] = 32'h1000; stage_w[3] = 0;        // dstOff = 4096
    stage_w[4] = 32'h1400; stage_w[5] = 0;        // size = 5120 > rem
    append_payload(0, 6); seal_buf(0);
    fill_src(SRCB, BUFZ, 900);
    poison(DSTB, BUFZ);
    wmark = w_n;
    issue('{op: APU_XFER_OP_COPY, cbuf: 8'd0, pay_base: 16'(0),
           regions: 16'd1, src_base: SRCB, src_size: BUFZ,
           dst_base: DSTB, dst_size: BUFZ}, '0, pl);
    check(pl.code == APU_SH_DONE_FAULT, "oob copy FAULT");
    check(w_n == wmark, "oob copy: zero W beats");
    cmp_range(DSTB, DSTB + BUFZ, "oob dst untouched");

    // ============ negative: overlapping src/dst ==========================
    cases++;
    begin_buf(0);
    stage_w[0] = 32'h0;    stage_w[1] = 0;        // src = [0,256)
    stage_w[2] = 32'h80;   stage_w[3] = 0;        // dst = [128,384)
    stage_w[4] = 32'h100;  stage_w[5] = 0;
    append_payload(0, 6); seal_buf(0);
    fill_src(SRCB, BUFZ, 901);
    wmark = w_n;
    issue('{op: APU_XFER_OP_COPY, cbuf: 8'd0, pay_base: 16'(0),
           regions: 16'd1, src_base: SRCB, src_size: BUFZ,
           dst_base: SRCB, dst_size: BUFZ}, '0, pl);
    check(pl.code == APU_SH_DONE_FAULT, "overlap copy FAULT");
    check(w_n == wmark, "overlap copy: zero W beats");
    cmp_range(SRCB, SRCB + BUFZ, "overlap buffer untouched");

    // ============ Enable=0 fixture ========================================
    check(!o_wr && !o_dn && !o_crv && !o_bsy && o_areq == '0,
          "Enable=0 outputs quiet");

    $display("TB_XFER done: cases=%0d checks=%0d errors=%0d cycles=%0d",
             cases, checks, errors, cycles);
    if (errors == 0)
      $display("PASS tb_g6lc_apu_xfer cases=%0d checks=%0d cycles=%0d",
               cases, checks, cycles);
    else             $display("FAIL");
    $finish;
  end
endmodule
