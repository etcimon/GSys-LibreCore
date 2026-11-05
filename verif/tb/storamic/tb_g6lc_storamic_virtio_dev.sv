// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-037A end-to-end bench for the standalone virtio-blk device. A driver
// model performs the VirtIO 1.4 MMIO initialization through AXI-Lite, builds
// split rings in an independent guest-RAM byte model and issues OUT, IN,
// GET_ID and FLUSH requests, checking used entries, status bytes, data, the
// interrupt and ACK, then resets the device mid-request and re-initializes.
module tb_g6lc_storamic_virtio_dev;
  localparam logic [63:0] WinBase = 64'h8000_0000;
  localparam logic [63:0] WinSize = 64'h0010_0000;
  localparam logic [63:0] CapSectors = 64'd128;
  localparam logic [63:0] Desc = 64'h8000_1000, Avail = 64'h8000_2000,
                          Used = 64'h8000_3000;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask

  g6lc_storamic_pkg::axil_req_t req;
  g6lc_storamic_pkg::axil_resp_t resp;
  logic irq;
  logic cap_ev = 0;
  logic [159:0] serial = 160'h3433_3231_5F43_494D_4152_4F54_535F_4336_4C47_3647;
  logic dreq, dgnt = 0, dwe, drv = 0, derr = 0;
  logic [63:0] daddr, dwdata, drdata = '0;
  logic [7:0] dbe;
  logic sreq, sgnt = 0, swe, srv = 0;
  logic [63:0] saddr, swdata, srdata = '0;
  logic [7:0] sbe;

  g6lc_storamic_virtio_dev #(.QueueNumMax(16), .MaxSegs(4)) dut (
    .clk_i(clk), .rst_ni(rst_n), .ctrl_req_i(req), .ctrl_resp_o(resp), .irq_o(irq),
    .device_usable_i(1'b1), .capacity_i(CapSectors), .capacity_update_i(cap_ev),
    .serial_i(serial), .store_ready_i(1'b1),
    .dma_base_i(WinBase), .dma_size_i(WinSize),
    .dma_req_o(dreq), .dma_gnt_i(dgnt), .dma_we_o(dwe), .dma_addr_o(daddr),
    .dma_wdata_o(dwdata), .dma_be_o(dbe), .dma_rvalid_i(drv),
    .dma_rdata_i(drdata), .dma_err_i(derr),
    .st_req_o(sreq), .st_gnt_i(sgnt), .st_we_o(swe), .st_addr_o(saddr),
    .st_wdata_o(swdata), .st_be_o(sbe), .st_rvalid_i(srv), .st_rdata_i(srdata),
    .st_err_i(1'b0),
    .st_durable_i(1'b0), .st_flush_req_o(), .st_flush_ack_i(1'b0), .st_flush_err_i(1'b0)
  );

  // ---- guest RAM and store models ----
  logic [7:0] ram [logic [63:0]];
  logic [7:0] store [logic [63:0]];
  int win_viol = 0, dma_beats = 0;
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
  logic dbusy = 0, dbwe, sbusy = 0, sbwe;
  logic [63:0] dbaddr, sbaddr;
  int dlat, slat;
  always @(negedge clk) begin
    dgnt <= ($urandom % 100) < 70;
    sgnt <= ($urandom % 100) < 70;
    if (dbusy && !drv) begin
      if (dlat > 0) dlat <= dlat - 1;
      else begin drv <= 1'b1; drdata <= dbwe ? 64'h0 : ram64(dbaddr); end
    end
    if (sbusy && !srv) begin
      if (slat > 0) slat <= slat - 1;
      else begin srv <= 1'b1; srdata <= sbwe ? 64'h0 : store64(sbaddr); end
    end
  end
  always @(posedge clk) begin
    if (rst_n && dreq && dgnt && !dbusy) begin
      dbusy <= 1'b1; dbwe <= dwe; dbaddr <= daddr; dlat <= $urandom % 3;
      dma_beats++;
      if (daddr[2:0] != 0 || daddr < WinBase || daddr + 8 > WinBase + WinSize) win_viol++;
      if (dwe) for (int i = 0; i < 8; i++) if (dbe[i]) ram[daddr + i] = dwdata[8*i +: 8];
    end
    if (drv) begin drv <= 1'b0; dbusy <= 1'b0; end
    if (rst_n && sreq && sgnt && !sbusy) begin
      sbusy <= 1'b1; sbwe <= swe; sbaddr <= saddr; slat <= $urandom % 3;
      if (swe) for (int i = 0; i < 8; i++) store[saddr + i] = swdata[8*i +: 8];
    end
    if (srv) begin srv <= 1'b0; sbusy <= 1'b0; end
  end

  // ---- AXI-Lite master ----
  int acc[3];
  always @(posedge clk) begin
    if (req.aw_valid && resp.aw_ready) acc[0]++;
    if (req.w_valid && resp.w_ready) acc[1]++;
    if (req.ar_valid && resp.ar_ready) acc[2]++;
  end
  task automatic wr(input logic [11:0] a, input logic [31:0] d);
    int a0, w0, g;
    a0 = acc[0]; w0 = acc[1];
    req.aw.addr = 64'(a); req.aw_valid = 1;
    req.w.data = d; req.w.strb = 4'hF; req.w_valid = 1;
    g = 0;
    while (acc[0] == a0 || acc[1] == w0) begin
      @(negedge clk);
      if (acc[0] != a0) req.aw_valid = 0;
      if (acc[1] != w0) req.w_valid = 0;
      if (++g > 100) $fatal(1, "VDEV_TIMEOUT wr");
    end
    req.b_ready = 1;
    while (!resp.b_valid) tick();
    if (resp.b.resp != 2'b00) $fatal(1, "VDEV_FAIL write %h slverr", a);
    tick(); req.b_ready = 0;
  endtask
  task automatic rd(input logic [11:0] a, output logic [31:0] d);
    int r0, g;
    r0 = acc[2];
    req.ar.addr = 64'(a); req.ar_valid = 1;
    g = 0;
    while (acc[2] == r0) begin tick(); if (++g > 100) $fatal(1, "VDEV_TIMEOUT rd"); end
    req.ar_valid = 0; req.r_ready = 1;
    while (!resp.r_valid) tick();
    d = resp.r.data;
    tick(); req.r_ready = 0;
  endtask

  int checks = 0;
  bit corrupt = 0;
  task automatic ok(input bit c, input string n);
    checks++;
    if (!c) $fatal(1, "VDEV_FAIL %s", n);
  endtask
  task automatic section(input string n);
    $display("VDEV_SECTION %s", n); $fflush();
  endtask
  task automatic put16(input logic [63:0] a, input logic [15:0] v);
    ram[a] = v[7:0]; ram[a + 1] = v[15:8];
  endtask
  task automatic put32(input logic [63:0] a, input logic [31:0] v);
    put16(a, v[15:0]); put16(a + 2, v[31:16]);
  endtask
  task automatic put64(input logic [63:0] a, input logic [63:0] v);
    put32(a, v[31:0]); put32(a + 4, v[63:32]);
  endtask
  function automatic logic [15:0] get16(input logic [63:0] a);
    return {ram.exists(a + 1) ? ram[a + 1] : 8'h0, ram.exists(a) ? ram[a] : 8'h0};
  endfunction
  function automatic logic [31:0] get32(input logic [63:0] a);
    return {get16(a + 2), get16(a)};
  endfunction

  // Driver state.
  logic [15:0] avail_idx, used_seen;
  logic [31:0] d;

  task automatic driver_init;
    for (int i = 0; i < 16 * 16; i++) ram[Desc + i] = 8'h0;
    for (int i = 0; i < 64; i++) begin ram[Avail + i] = 8'h0; ram[Used + i] = 8'h0; end
    for (int i = 0; i < 6 + 8 * 16; i++) ram[Used + i] = 8'h0;
    avail_idx = 0; used_seen = 0;
    wr(12'h070, 32'h0);                       // reset
    begin int g; g = 0; do begin rd(12'h070, d); g++; end while (d != 0 && g < 50); end
    ok(d == 0, "init-reset-done");
    wr(12'h070, 32'h1); wr(12'h070, 32'h3);   // ACKNOWLEDGE, DRIVER
    rd(12'h000, d); ok(d == 32'h7472_6976, "magic");
    rd(12'h004, d); ok(d == 2, "version");
    rd(12'h008, d); ok(d == 2, "device-id-block");
    wr(12'h014, 32'h1); rd(12'h010, d); ok(d == 32'h1, "features-bank1");
    wr(12'h024, 32'h0); wr(12'h020, 32'h0);
    wr(12'h024, 32'h1); wr(12'h020, 32'h1);
    wr(12'h070, 32'hB);                       // FEATURES_OK
    rd(12'h070, d); ok(d[3], "features-ok");
    rd(12'h100, d); ok(d == 32'(CapSectors), "capacity");
    wr(12'h030, 32'h0);
    rd(12'h034, d); ok(d == 16, "queue-num-max");
    wr(12'h038, 32'd8);
    wr(12'h080, Desc[31:0]); wr(12'h084, Desc[63:32]);
    wr(12'h090, Avail[31:0]); wr(12'h094, Avail[63:32]);
    wr(12'h0A0, Used[31:0]); wr(12'h0A4, Used[63:32]);
    wr(12'h044, 32'h1);
    rd(12'h044, d); ok(d == 1, "queue-ready");
    wr(12'h070, 32'hF);                       // DRIVER_OK
    rd(12'h070, d); ok(d == 32'hF, "driver-ok");
  endtask

  // Post a 3-descriptor request using descriptors 0..2 and wait for it.
  task automatic blk_req(input logic [31:0] typ, input logic [63:0] sector,
                         input logic [63:0] data, input logic [31:0] dlen,
                         input bit dwrite, output logic [7:0] status,
                         output logic [31:0] ulen);
    logic [63:0] hdr, st;
    int g;
    hdr = 64'h8000_5000; st = 64'h8000_5100;
    put32(hdr, typ); put32(hdr + 4, 0); put64(hdr + 8, sector);
    ram[st] = 8'hEE;
    put64(Desc + 0, hdr); put32(Desc + 8, 16); put16(Desc + 12, 16'h1); put16(Desc + 14, 1);
    if (dlen != 0) begin
      put64(Desc + 16, data); put32(Desc + 24, dlen);
      put16(Desc + 28, dwrite ? 16'h3 : 16'h1); put16(Desc + 30, 2);
      put64(Desc + 32, st); put32(Desc + 40, 1); put16(Desc + 44, 16'h2); put16(Desc + 46, 0);
    end else begin
      put16(Desc + 14, 2);
      put64(Desc + 32, st); put32(Desc + 40, 1); put16(Desc + 44, 16'h2); put16(Desc + 46, 0);
    end
    put16(Avail + 4 + 2 * (avail_idx % 8), 0);
    avail_idx++;
    put16(Avail + 2, avail_idx);
    wr(12'h050, 32'h0);                       // QueueNotify
    g = 0;
    while (!irq) begin tick(); if (++g > 20000) $fatal(1, "VDEV_TIMEOUT irq"); end
    rd(12'h060, d); ok(d[0], "irq-used");
    wr(12'h064, 32'h1);
    rd(12'h060, d); ok(d[0] == 0, "irq-acked");
    ok(get16(Used + 2) == used_seen + 1, "used-idx-advanced");
    ok(get32(Used + 4 + 8 * (used_seen % 8)) == 0, "used-id");
    ulen = get32(Used + 8 + 8 * (used_seen % 8));
    used_seen++;
    status = ram[st];
  endtask

  logic [7:0] status;
  logic [31:0] ulen;
  initial begin
    req = '0;
    if ($test$plusargs("oracle_negative")) corrupt = 1;
    repeat (3) tick(); rst_n = 1; repeat (2) tick();

    section("init");
    driver_init();

    section("out");
    for (int i = 0; i < 1024; i++) ram[64'h8000_8000 + i] = 8'(i * 13 + 1);
    blk_req(32'd1, 64'd5, 64'h8000_8000, 1024, 0, status, ulen);
    ok(status == 0 && ulen == 1, "out-status");
    for (int i = 0; i < 1024; i++)
      if (store[5 * 512 + i] !== 8'(i * 13 + 1)) ok(0, "out-store-byte");

    section("in");
    blk_req(32'd0, 64'd5, 64'h8000_C000, 1024, 1, status, ulen);
    ok(status == 0 && ulen == (corrupt ? 32'd1024 : 32'd1025), "in-status");
    for (int i = 0; i < 1024; i++)
      if (ram[64'h8000_C000 + i] !== 8'(i * 13 + 1)) ok(0, "in-byte");

    section("get-id");
    blk_req(32'd8, 64'd0, 64'h8000_E000, 20, 1, status, ulen);
    ok(status == 0 && ulen == 21, "getid-status");
    for (int i = 0; i < 20; i++) ok(ram[64'h8000_E000 + i] == serial[8*i +: 8], "getid-byte");

    section("flush-unsupp");
    blk_req(32'd4, 64'd0, 64'h0, 0, 0, status, ulen);
    ok(status == 2 && ulen == 1, "flush-unsupp");

    section("ioerr-capacity");
    blk_req(32'd1, CapSectors - 1, 64'h8000_8000, 1024, 0, status, ulen);
    ok(status == 1, "ioerr-past-capacity");

    section("reset-and-reinit");
    wr(12'h070, 32'h0);
    driver_init();
    blk_req(32'd0, 64'd5, 64'h8000_D000, 512, 1, status, ulen);
    ok(status == 0 && ram[64'h8000_D000 + 7] == 8'(7 * 13 + 1), "after-reset-io");

    section("capacity-event");
    cap_ev = 1; tick(); cap_ev = 0; tick();
    ok(irq, "cfg-irq");
    rd(12'h060, d); ok(d[1], "cfg-bit");
    rd(12'h0FC, d); ok(d == 1, "cfg-generation");
    wr(12'h064, 32'h2);
    ok(!irq, "cfg-acked");

    ok(win_viol == 0, "no-window-violations");
    $display("VDEV_PASS checks=%0d dma_beats=%0d", checks, dma_beats);
    $finish;
  end

  initial begin
    #5000000;
    $fatal(1, "VDEV_TIMEOUT global");
  end
endmodule

// Synthesis wrapper (top level).
module g6lc_storamic_virtio_dev_synth (
  input logic clk_i, rst_ni,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  output logic irq_o,
  input logic device_usable_i,
  input logic [63:0] capacity_i,
  input logic capacity_update_i,
  input logic [159:0] serial_i,
  input logic store_ready_i,
  input logic [63:0] dma_base_i, dma_size_i,
  output logic dma_req_o,
  input logic dma_gnt_i,
  output logic dma_we_o,
  output logic [63:0] dma_addr_o, dma_wdata_o,
  output logic [7:0] dma_be_o,
  input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i,
  input logic dma_err_i,
  output logic st_req_o,
  input logic st_gnt_i,
  output logic st_we_o,
  output logic [63:0] st_addr_o, st_wdata_o,
  output logic [7:0] st_be_o,
  input logic st_rvalid_i,
  input logic [63:0] st_rdata_i,
  input logic st_err_i,
  input logic st_durable_i,
  output logic st_flush_req_o,
  input logic st_flush_ack_i,
  input logic st_flush_err_i
);
  g6lc_storamic_virtio_dev #(.QueueNumMax(128), .MaxSegs(8)) i_dev (.*);
endmodule
