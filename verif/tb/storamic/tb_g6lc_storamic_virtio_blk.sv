// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-036 virtio-blk backend bench. Independent byte memories model the guest
// RAM (DMA port) and the volatile block store; both answer with random grant
// and response latency. Requests are built the way the ring engine hands them
// over. Expected bytes come from what the bench placed, never from the DUT.
module tb_g6lc_storamic_virtio_blk;
  localparam int unsigned MaxSegs = 4;
  localparam logic [63:0] WinBase = 64'h8000_0000;
  localparam logic [63:0] WinSize = 64'h0010_0000;
  localparam logic [63:0] CapSectors = 64'd64;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask

  logic rpend = 0, idle;
  logic rq_valid = 0, rq_ready;
  logic [$clog2(MaxSegs + 1)-1:0] rq_nsegs = '0;
  logic [MaxSegs-1:0][63:0] rq_addr = '0;
  logic [MaxSegs-1:0][31:0] rq_len = '0;
  logic [MaxSegs-1:0] rq_wr = '0;
  logic rs_valid, rs_fault;
  logic [31:0] rs_len;
  logic dreq, dgnt = 0, dwe, drv = 0, derr = 0;
  logic [63:0] daddr, dwdata, drdata = '0;
  logic [7:0] dbe;
  logic sready = 1, sreq, sgnt = 0, swe, srv = 0, serr = 0;
  logic [63:0] saddr, swdata, srdata = '0;
  logic [7:0] sbe;
  // ST-037D flush seam model: acknowledges a held request after 3 cycles,
  // as an error when fl_fail is set; counts requests and writes seen first.
  logic fl_en = 0, fl_req, fl_ack = 0, fl_err = 0;
  bit fl_fail = 0;
  int fl_count = 0, fl_wait = 0, fl_writes_before = -1;
  logic [159:0] serial = 160'h3433_3231_5F43_494D_4152_4F54_535F_4336_4C47_3647;

  g6lc_storamic_virtio_blk #(.MaxSegs(MaxSegs)) dut (
    .clk_i(clk), .rst_ni(rst_n), .reset_pending_i(rpend), .idle_o(idle),
    .req_valid_i(rq_valid), .req_ready_o(rq_ready), .req_nsegs_i(rq_nsegs),
    .req_seg_addr_i(rq_addr), .req_seg_len_i(rq_len), .req_seg_write_i(rq_wr),
    .rsp_valid_o(rs_valid), .rsp_written_len_o(rs_len), .rsp_fault_o(rs_fault),
    .dma_base_i(WinBase), .dma_size_i(WinSize),
    .dma_req_o(dreq), .dma_gnt_i(dgnt), .dma_we_o(dwe), .dma_addr_o(daddr),
    .dma_wdata_o(dwdata), .dma_be_o(dbe), .dma_rvalid_i(drv),
    .dma_rdata_i(drdata), .dma_err_i(derr),
    .store_ready_i(sready), .capacity_i(CapSectors), .serial_i(serial),
    .st_req_o(sreq), .st_gnt_i(sgnt), .st_we_o(swe), .st_addr_o(saddr),
    .st_wdata_o(swdata), .st_be_o(sbe), .st_rvalid_i(srv), .st_rdata_i(srdata),
    .st_err_i(serr),
    .flush_en_i(fl_en), .st_flush_req_o(fl_req), .st_flush_ack_i(fl_ack),
    .st_flush_err_i(fl_err)
  );

  logic [7:0] ram [logic [63:0]];
  logic [7:0] store [logic [63:0]];
  bit ram_wr [logic [63:0]];
  int store_writes = 0, win_viol = 0, store_viol = 0;
  int store_err_at = -1;      // fail the Nth store beat (counted from 0)
  int store_beats = 0;

  function automatic logic [63:0] ram64(input logic [63:0] a);
    logic [63:0] v;
    for (int i = 0; i < 8; i++) v[8*i +: 8] = ram.exists(a + i) ? ram[a + i] : 8'h00;
    return v;
  endfunction
  function automatic logic [63:0] store64(input logic [63:0] a);
    logic [63:0] v;
    for (int i = 0; i < 8; i++) v[8*i +: 8] = store.exists(a + i) ? store[a + i] : 8'h00;
    return v;
  endfunction

  // Guest RAM port.
  logic dbusy = 0, dbwe;
  logic [63:0] dbaddr;
  int dlat;
  always @(negedge clk) begin
    dgnt <= ($urandom % 100) < 60;
    sgnt <= ($urandom % 100) < 60;
    if (dbusy && !drv) begin
      if (dlat > 0) dlat <= dlat - 1;
      else begin drv <= 1'b1; drdata <= dbwe ? 64'h0 : ram64(dbaddr); end
    end
  end
  always @(posedge clk) begin
    if (rst_n && dreq && dgnt && !dbusy) begin
      dbusy <= 1'b1; dbwe <= dwe; dbaddr <= daddr; dlat <= $urandom % 3;
      if (daddr[2:0] != 0 || daddr < WinBase || daddr + 8 > WinBase + WinSize)
        win_viol++;
      if (dwe)
        for (int i = 0; i < 8; i++)
          if (dbe[i]) begin ram[daddr + i] = dwdata[8*i +: 8]; ram_wr[daddr + i] = 1; end
    end
    if (drv) begin drv <= 1'b0; dbusy <= 1'b0; end
  end

  // Block store port.
  logic sbusy = 0, sbwe;
  logic [63:0] sbaddr;
  int slat;
  logic sfail;
  always @(negedge clk) begin
    if (sbusy && !srv) begin
      if (slat > 0) slat <= slat - 1;
      else begin
        srv <= 1'b1; serr <= sfail;
        srdata <= sbwe ? 64'h0 : store64(sbaddr);
      end
    end
  end
  always @(posedge clk) begin
    if (rst_n && sreq && sgnt && !sbusy) begin
      sbusy <= 1'b1; sbwe <= swe; sbaddr <= saddr; slat <= $urandom % 3;
      sfail <= (store_beats == store_err_at);
      if (saddr[2:0] != 0 || saddr + 8 > CapSectors * 512) store_viol++;
      if (swe && store_beats != store_err_at) begin
        store_writes++;
        for (int i = 0; i < 8; i++) store[saddr + i] = swdata[8*i +: 8];
      end
      store_beats++;
    end
    if (srv) begin srv <= 1'b0; serr <= 1'b0; sbusy <= 1'b0; end
  end

  always @(posedge clk) begin
    fl_ack <= 1'b0; fl_err <= 1'b0;
    if (rst_n && fl_req && !fl_ack && !fl_err) begin
      if (fl_wait == 0) begin fl_count++; fl_writes_before = store_writes; end
      if (fl_wait == 3) begin
        fl_ack <= !fl_fail; fl_err <= fl_fail; fl_wait <= 0;
      end else fl_wait <= fl_wait + 1;
    end
  end

  int checks = 0;
  bit corrupt = 0;
  task automatic ok(input bit c, input string n);
    checks++;
    if (!c) $fatal(1, "VBLK_FAIL %s", n);
  endtask
  task automatic section(input string n);
    $display("VBLK_SECTION %s", n); $fflush();
  endtask

  task automatic put32(input logic [63:0] a, input logic [31:0] v);
    for (int i = 0; i < 4; i++) ram[a + i] = v[8*i +: 8];
  endtask
  task automatic put64(input logic [63:0] a, input logic [63:0] v);
    for (int i = 0; i < 8; i++) ram[a + i] = v[8*i +: 8];
  endtask
  task automatic header(input logic [63:0] a, input logic [31:0] typ,
                        input logic [63:0] sector);
    put32(a, typ); put32(a + 4, 0); put64(a + 8, sector);
  endtask

  // Hand one request over and wait for the response.
  logic [31:0] got_len;
  bit got_fault;
  task automatic run(input int n);
    int g;
    rq_nsegs = n[$clog2(MaxSegs + 1)-1:0];
    rq_valid = 1;
    g = 0;
    while (!rq_ready) begin tick(); if (++g > 100) $fatal(1, "VBLK_TIMEOUT ready"); end
    tick();
    rq_valid = 0;
    g = 0;
    while (!rs_valid) begin tick(); if (++g > 20000) $fatal(1, "VBLK_TIMEOUT rsp"); end
    got_len = rs_len; got_fault = rs_fault;
    tick();
  endtask
  task automatic seg(input int i, input logic [63:0] a, input logic [31:0] l,
                     input bit w);
    rq_addr[i] = a; rq_len[i] = l; rq_wr[i] = w;
  endtask

  localparam logic [63:0] Hdr = 64'h8000_1000, D0 = 64'h8000_2000,
                          D1 = 64'h8000_3000, St = 64'h8000_4000;

  initial begin
    if ($test$plusargs("oracle_negative")) corrupt = 1;
    repeat (3) tick(); rst_n = 1; repeat (2) tick();

    section("out");
    for (int i = 0; i < 1024; i++) ram[(i < 512 ? D0 : D1 - 512) + i] = 8'(i * 7 + 3);
    header(Hdr, 32'd1, 64'd3);
    seg(0, Hdr, 16, 0); seg(1, D0, 512, 0); seg(2, D1, 512, 0); seg(3, St, 1, 1);
    ram[St] = 8'hEE;
    run(4);
    ok(!got_fault && got_len == 1 && ram[St] == 8'd0, "out-status");
    for (int i = 0; i < 1024; i++)
      if (store[3 * 512 + i] !== 8'(i * 7 + 3)) ok(0, $sformatf("out-byte-%0d", i));
    ok(1, "out-bytes");

    section("in");
    for (int i = 0; i < 1024; i++) begin ram[D0 + 64'h8000 + i] = 8'h00; end
    header(Hdr, 32'd0, 64'd3);
    seg(0, Hdr, 16, 0); seg(1, D0 + 64'h8000, 1024, 1); seg(2, St + 3, 1, 1);
    run(3);
    ok(!got_fault && got_len == (corrupt ? 32'd1024 : 32'd1025) && ram[St + 3] == 8'd0,
       "in-status");
    for (int i = 0; i < 1024; i++)
      if (ram[D0 + 64'h8000 + i] !== 8'(i * 7 + 3)) ok(0, $sformatf("in-byte-%0d", i));
    ok(1, "in-bytes");

    section("get-id");
    header(Hdr + 3, 32'd8, 64'd0);   // unaligned header
    seg(0, Hdr + 3, 16, 0); seg(1, D0, 20, 1); seg(2, St + 5, 1, 1);
    run(3);
    ok(!got_fault && got_len == 21 && ram[St + 5] == 8'd0, "getid-status");
    for (int i = 0; i < 20; i++) ok(ram[D0 + i] == serial[8*i +: 8], "getid-byte");

    section("unsupp-flush");
    begin
      int w0;
      w0 = store_writes;
      header(Hdr, 32'd4, 64'd0);
      seg(0, Hdr, 16, 0); seg(1, St, 1, 1);
      run(2);
      ok(!got_fault && got_len == 1 && ram[St] == 8'd2 && store_writes == w0, "unsupp");
    end

    section("flush");
    begin
      int w0;
      fl_en = 1; w0 = store_writes;
      header(Hdr, 32'd4, 64'd0);
      seg(0, Hdr, 16, 0); seg(1, St, 1, 1);
      ram[St] = 8'hEE;
      run(2);
      ok(!got_fault && got_len == 1 && ram[St] == 8'd0, "flush-ok");
      ok(fl_count == 1 && fl_writes_before == w0, "flush-once-after-writes");
      fl_fail = 1; ram[St] = 8'hEE;
      run(2);
      ok(!got_fault && ram[St] == 8'd1 && fl_count == 2, "flush-error-ioerr");
      fl_fail = 0; fl_en = 0;
      run(2);
      ok(ram[St] == 8'd2 && fl_count == 2, "flush-unnegotiated-unsupp");
      ok(store_writes == w0, "flush-no-store-write");
    end

    section("ioerr");
    for (int k = 0; k < 8; k++) begin
      int w0, ns;
      w0 = store_writes; ns = 3;
      store_err_at = -1; sready = 1;
      header(Hdr, 32'd1, 64'd0);
      seg(0, Hdr, 16, 0); seg(1, D0, 512, 0); seg(2, St, 1, 1);
      unique case (k)
        6: rq_addr[1] = WinBase + WinSize - 256;          // data runs past the window
        7: begin                                          // empty data segment
          seg(1, D0, 0, 0); seg(2, D1, 512, 0); seg(3, St, 1, 1); ns = 4;
        end
        0: header(Hdr, 32'd1, CapSectors);               // past capacity
        1: rq_len[1] = 256;                               // not a sector multiple
        2: rq_wr[1] = 1;                                  // OUT into writable buffer
        3: rq_addr[1] = D0 + 4;                           // misaligned data
        4: sready = 0;                                    // store not ready
        5: store_err_at = store_beats + 3;                // store error mid-transfer
      endcase
      ram[St] = 8'hEE;
      run(ns);
      ok(!got_fault && got_len == 1 && ram[St] == 8'd1, $sformatf("ioerr-%0d-status", k));
      if (k != 5)
        ok(store_writes == w0, $sformatf("ioerr-%0d-no-store-write", k));
    end
    store_err_at = -1; sready = 1;

    section("faults");
    begin
      int r0;
      ram_wr.delete();
      header(Hdr, 32'd1, 64'd0);
      seg(0, Hdr, 16, 0); seg(1, D0, 512, 0); seg(2, St, 1, 0);   // status not writable
      run(3);
      ok(got_fault && ram_wr.size() == 0, "fault-status-readonly");
      seg(0, Hdr, 8, 0); seg(1, St, 1, 1);                          // header too short
      run(2);
      ok(got_fault && ram_wr.size() == 0, "fault-short-header");
    end

    section("reset-mid");
    header(Hdr, 32'd1, 64'd0);
    seg(0, Hdr, 16, 0); seg(1, D0, 512, 0); seg(2, St, 1, 1);
    rq_nsegs = 3; rq_valid = 1;
    while (!rq_ready) tick();
    tick(); rq_valid = 0;
    repeat (20) tick();
    rpend = 1;
    begin
      int g; g = 0;
      while (!idle) begin tick(); if (++g > 200) $fatal(1, "VBLK_TIMEOUT idle"); end
    end
    repeat (10) begin ok(!rs_valid && !dreq && !sreq, "reset-quiet"); tick(); end
    rpend = 0; repeat (2) tick();
    header(Hdr, 32'd4, 64'd0);
    seg(0, Hdr, 16, 0); seg(1, St, 1, 1);
    run(2);
    ok(ram[St] == 8'd2, "reset-recovers");

    ok(win_viol == 0 && store_viol == 0, "no-window-or-store-violations");
    $display("VBLK_PASS checks=%0d store_writes=%0d", checks, store_writes);
    $finish;
  end

  initial begin
    #5000000;
    $fatal(1, "VBLK_TIMEOUT global");
  end
endmodule

// Synthesis wrapper (top level).
module g6lc_storamic_virtio_blk_synth (
  input logic clk_i, rst_ni, reset_pending_i,
  output logic idle_o,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic [3:0] req_nsegs_i,
  input logic [7:0][63:0] req_seg_addr_i,
  input logic [7:0][31:0] req_seg_len_i,
  input logic [7:0] req_seg_write_i,
  output logic rsp_valid_o,
  output logic [31:0] rsp_written_len_o,
  output logic rsp_fault_o,
  input logic [63:0] dma_base_i, dma_size_i,
  output logic dma_req_o,
  input logic dma_gnt_i,
  output logic dma_we_o,
  output logic [63:0] dma_addr_o, dma_wdata_o,
  output logic [7:0] dma_be_o,
  input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i,
  input logic dma_err_i,
  input logic store_ready_i,
  input logic [63:0] capacity_i,
  input logic [159:0] serial_i,
  output logic st_req_o,
  input logic st_gnt_i,
  output logic st_we_o,
  output logic [63:0] st_addr_o, st_wdata_o,
  output logic [7:0] st_be_o,
  input logic st_rvalid_i,
  input logic [63:0] st_rdata_i,
  input logic st_err_i,
  input logic flush_en_i,
  output logic st_flush_req_o,
  input logic st_flush_ack_i,
  input logic st_flush_err_i
);
  g6lc_storamic_virtio_blk #(.MaxSegs(8)) i_blk (.*);
endmodule
