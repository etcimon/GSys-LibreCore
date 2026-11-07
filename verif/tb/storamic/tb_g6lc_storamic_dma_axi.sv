// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-037C bench for the single-beat DMA -> AXI4 adapter that time-shares the
// AI-DMA crossbar port. An AXI4 slave memory model (random ready/latency)
// serves both masters; an upstream burst master runs concurrently with
// Storamic beats. Checks: Storamic writes/reads land byte-exactly with
// strobes, upstream bursts complete with correct data, and a Storamic
// transaction is never on the bus while an upstream transaction is in flight.
// InvalEn=1: every Storamic write requests exactly one invalidation of its
// 64-byte block (random ready/done latency) and completes only after done;
// reads and upstream traffic request none. InvalEn=0 requests none at all.
module tb_g6lc_storamic_dma_axi #(parameter bit InvalEn = 1'b0);
  localparam int unsigned IdW = 4;
  typedef struct packed {
    logic [IdW-1:0] id; logic [63:0] addr; logic [7:0] len; logic [2:0] size;
    logic [1:0] burst; logic lock; logic [3:0] cache; logic [2:0] prot;
    logic [3:0] qos; logic [3:0] region; logic [5:0] atop; logic user;
  } aw_t;
  typedef struct packed {
    logic [IdW-1:0] id; logic [63:0] addr; logic [7:0] len; logic [2:0] size;
    logic [1:0] burst; logic lock; logic [3:0] cache; logic [2:0] prot;
    logic [3:0] qos; logic [3:0] region; logic user;
  } ar_t;
  typedef struct packed {logic [63:0] data; logic [7:0] strb; logic last; logic user;} w_t;
  typedef struct packed {logic [IdW-1:0] id; logic [1:0] resp; logic user;} b_t;
  typedef struct packed {
    logic [IdW-1:0] id; logic [63:0] data; logic [1:0] resp; logic last; logic user;
  } r_t;
  typedef struct packed {
    aw_t aw; logic aw_valid; w_t w; logic w_valid; logic b_ready;
    ar_t ar; logic ar_valid; logic r_ready;
  } req_t;
  typedef struct packed {
    logic aw_ready; logic ar_ready; logic w_ready; logic b_valid; b_t b;
    logic r_valid; r_t r;
  } resp_t;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask

  logic sreq = 0, sgnt, swe = 0, srv, serr;
  logic [63:0] saddr = '0, swdata = '0, srdata;
  logic [7:0] sbe = '0;
  req_t up_req, mreq;
  resp_t up_resp, mresp;

  logic inv_valid, inv_ready = 1'b0, inv_done = 1'b0;
  logic [63:0] inv_addr;
  g6lc_storamic_dma_axi #(.IdWidth(IdW), .DmaId(4'h5), .InvalEn(InvalEn),
                          .axi_req_t(req_t), .axi_resp_t(resp_t)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .inflight_o(),
    .dma_req_i(sreq), .dma_gnt_o(sgnt), .dma_we_i(swe), .dma_addr_i(saddr),
    .dma_wdata_i(swdata), .dma_be_i(sbe), .dma_rvalid_o(srv),
    .dma_rdata_o(srdata), .dma_err_o(serr),
    .up_req_i(up_req), .up_resp_o(up_resp),
    .mst_req_o(mreq), .mst_resp_i(mresp),
    .inval_valid_o(inv_valid), .inval_addr_o(inv_addr),
    .inval_ready_i(inv_ready), .inval_done_i(inv_done)
  );

  // ---- CMO-engine model: random accept, done 1..6 cycles later ----
  int inv_accepts = 0, inv_dones = 0, inv_bad_addr = 0, inv_wait = -1;
  logic [63:0] sto_aw_addr = '0;
  always @(negedge clk) inv_ready <= ($urandom % 100) < 50;
  always @(posedge clk) begin
    inv_done <= 1'b0;
    if (rst_n) begin
      if (mreq.aw_valid && mresp.aw_ready && mreq.aw.id == 4'h5) sto_aw_addr <= mreq.aw.addr;
      if (inv_valid && inv_ready) begin
        inv_accepts++;
        if (inv_addr != (sto_aw_addr & ~64'h3F)) inv_bad_addr++;
        inv_wait <= 1 + ($urandom % 6);
      end
      if (inv_wait > 0) inv_wait <= inv_wait - 1;
      if (inv_wait == 1) begin inv_done <= 1'b1; inv_dones++; end
    end
  end

  // ---- AXI4 slave memory: one write and one read burst at a time ----
  logic [7:0] mem [logic [63:0]];
  function automatic logic [63:0] rd64(input logic [63:0] a);
    logic [63:0] v;
    for (int i = 0; i < 8; i++) v[8*i +: 8] = mem.exists(a + i) ? mem[a + i] : 8'h0;
    return v;
  endfunction
  aw_t cur_aw; ar_t cur_ar;
  logic aw_busy = 0, ar_busy = 0;
  int wbeat = 0, rbeat = 0;
  int st_on_bus = 0, overlap = 0, up_inflight = 0;
  always @(negedge clk) begin
    mresp.aw_ready <= !aw_busy && ($urandom % 100 < 70);
    mresp.ar_ready <= !ar_busy && ($urandom % 100 < 70);
    mresp.w_ready <= aw_busy && !mresp.b_valid && ($urandom % 100 < 70);
    if (ar_busy && !mresp.r_valid && ($urandom % 100 < 70)) begin
      mresp.r_valid <= 1'b1;
      mresp.r.id <= cur_ar.id; mresp.r.resp <= 2'b00;
      mresp.r.data <= rd64(cur_ar.addr + 64'(8 * rbeat));
      mresp.r.last <= (rbeat == int'(cur_ar.len));
    end
  end
  always @(posedge clk) begin
    if (!rst_n) begin
      aw_busy <= 0; ar_busy <= 0; mresp <= '0; wbeat <= 0; rbeat <= 0;
    end else begin
      if (mreq.aw_valid && mresp.aw_ready) begin aw_busy <= 1; cur_aw <= mreq.aw; wbeat <= 0; end
      if (mreq.w_valid && mresp.w_ready) begin
        for (int i = 0; i < 8; i++)
          if (mreq.w.strb[i]) mem[cur_aw.addr + 64'(8 * wbeat) + i] = mreq.w.data[8*i +: 8];
        wbeat <= wbeat + 1;
        if (mreq.w.last) begin
          mresp.b_valid <= 1; mresp.b.id <= cur_aw.id; mresp.b.resp <= 2'b00;
        end
      end
      if (mresp.b_valid && mreq.b_ready) begin mresp.b_valid <= 0; aw_busy <= 0; end
      if (mreq.ar_valid && mresp.ar_ready) begin ar_busy <= 1; cur_ar <= mreq.ar; rbeat <= 0; end
      if (mresp.r_valid && mreq.r_ready) begin
        mresp.r_valid <= 0; rbeat <= rbeat + 1;
        if (mresp.r.last) ar_busy <= 0;
      end
      // Exclusivity: a Storamic-ID request only while no upstream is in flight.
      if ((mreq.aw_valid && mreq.aw.id == 4'h5) || (mreq.ar_valid && mreq.ar.id == 4'h5))
        if (up_inflight != 0) overlap++;
    end
  end

  // ---- upstream burst master: writes then reads back 4-beat bursts ----
  int up_done = 0, up_err = 0;
  always @(posedge clk) begin
    if (up_req.aw_valid && up_resp.aw_ready) up_inflight++;
    if (up_req.ar_valid && up_resp.ar_ready) up_inflight++;
    if (up_resp.b_valid && up_req.b_ready) up_inflight--;
    if (up_resp.r_valid && up_resp.r.last && up_req.r_ready) up_inflight--;
  end
  initial begin
    up_req = '0;
    @(posedge rst_n);
    for (int n = 0; n < 12; n++) begin
      logic [63:0] base;
      base = 64'h1000 + 64'(n) * 64'h40;
      up_req.aw = '0; up_req.aw.id = 4'h1; up_req.aw.addr = base;
      up_req.aw.len = 8'd3; up_req.aw.size = 3'd3; up_req.aw.burst = 2'b01;
      up_req.aw_valid = 1;
      do @(posedge clk); while (!up_resp.aw_ready);
      @(negedge clk); up_req.aw_valid = 0;
      for (int b = 0; b < 4; b++) begin
        up_req.w = '0; up_req.w.data = {32'(n), 32'(b)}; up_req.w.strb = '1;
        up_req.w.last = (b == 3); up_req.w_valid = 1;
        do @(posedge clk); while (!up_resp.w_ready);
        @(negedge clk);
      end
      up_req.w_valid = 0; up_req.b_ready = 1;
      do @(posedge clk); while (!up_resp.b_valid);
      @(negedge clk); up_req.b_ready = 0;
      up_req.ar = '0; up_req.ar.id = 4'h2; up_req.ar.addr = base;
      up_req.ar.len = 8'd3; up_req.ar.size = 3'd3; up_req.ar.burst = 2'b01;
      up_req.ar_valid = 1;
      do @(posedge clk); while (!up_resp.ar_ready);
      @(negedge clk); up_req.ar_valid = 0; up_req.r_ready = 1;
      for (int b = 0; b < 4; b++) begin
        do @(posedge clk); while (!up_resp.r_valid);
        if (up_resp.r.data != {32'(n), 32'(b)}) up_err++;
        @(negedge clk);
      end
      up_req.r_ready = 0;
      up_done++;
    end
  end

  int checks = 0, sto_writes = 0;
  bit corrupt = 0;
  task automatic ok(input bit c, input string n);
    checks++;
    if (!c) $fatal(1, "VDMA_FAIL %s", n);
  endtask
  // One Storamic beat through the seam (hold until grant, one rvalid).
  task automatic beat(input bit we, input logic [63:0] a, input logic [63:0] d,
                      input logic [7:0] be, output logic [63:0] q);
    int g;
    sreq = 1; swe = we; saddr = a; swdata = d; sbe = be;
    g = 0;
    while (!sgnt) begin tick(); if (++g > 2000) $fatal(1, "VDMA_TIMEOUT gnt"); end
    tick(); sreq = 0;
    g = 0;
    while (!srv) begin tick(); if (++g > 2000) $fatal(1, "VDMA_TIMEOUT rvalid"); end
    q = srdata;
    ok(!serr, "beat-no-error");
    // A write completes only after its invalidation finished; reads add none.
    if (we) begin
      sto_writes++;
      ok(InvalEn ? (inv_accepts == sto_writes && inv_dones == sto_writes)
                 : inv_accepts == 0, "inval-before-completion");
    end else ok(inv_accepts == (InvalEn ? sto_writes : 0), "no-inval-on-read");
    tick();
  endtask

  logic [63:0] q;
  initial begin
    if ($test$plusargs("oracle_negative")) corrupt = 1;
    repeat (3) tick(); rst_n = 1; repeat (2) tick();
    for (int k = 0; k < 24; k++) begin
      beat(1, 64'h8000 + 64'(8 * k), {32'hA5A5_0000 | 32'(k), 32'(k)}, 8'hFF, q);
      repeat ($urandom % 5) tick();
    end
    beat(1, 64'h9000, 64'h1122_3344_5566_7788, 8'h0F, q);   // partial strobes
    for (int k = 0; k < 24; k++) begin
      beat(0, 64'h8000 + 64'(8 * k), '0, '0, q);
      ok(q == {32'hA5A5_0000 | 32'(k), 32'(corrupt ? k + 1 : k)}, "read-back");
    end
    beat(0, 64'h9000, '0, '0, q);
    ok(q == 64'h0000_0000_5566_7788, "partial-strobe");
    begin
      int g; g = 0;
      while (up_done < 12) begin tick(); if (++g > 50000) $fatal(1, "VDMA_TIMEOUT up"); end
    end
    ok(up_err == 0, "upstream-data");
    ok(overlap == 0, "no-overlap-with-upstream");
    ok(inv_bad_addr == 0, "inval-block-address");
    ok(inv_accepts == (InvalEn ? 25 : 0), "inval-count");
    $display("VDMA_PASS checks=%0d", checks);
    $finish;
  end
  initial begin #3000000; $fatal(1, "VDMA_TIMEOUT global"); end
endmodule
