// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-034 bench: AXI-Lite master driving g6lc_storamic_virtio_mmio with an
// independent expected model. Covers identity, feature negotiation, the
// Linux init order, QueueReady legality, notify gating, interrupts, config
// window, reset-with-dma_idle, every SLVERR case, channel order/backpressure
// and a mid-transaction reset. +oracle_negative must fail.
module tb_g6lc_storamic_virtio_mmio;
  import g6lc_storamic_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask

  axil_req_t req;
  axil_resp_t resp;
  logic usable, dma_idle, used_ev, fault_ev, cap_ev;
  logic [63:0] cap_in;
  logic notify, irq, dok, fok, qready, rpend;
  logic [63:0] dfeat, qdesc, qdrv, qdev;
  logic [7:0] epoch;
  logic [15:0] qnum_o;

  g6lc_storamic_virtio_mmio #(
    .VendorId(32'hDEAD_BEEF), .QueueNumMax(128)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .ctrl_req_i(req), .ctrl_resp_o(resp),
    .device_usable_i(usable), .capacity_i(cap_in),
    .capacity_update_i(cap_ev), .flush_cap_i(1'b0), .dma_idle_i(dma_idle),
    .used_event_i(used_ev), .ring_fault_i(fault_ev),
    .notify_o(notify), .irq_o(irq), .driver_ok_o(dok),
    .features_ok_o(fok), .driver_features_o(dfeat),
    .reset_epoch_o(epoch), .queue_ready_o(qready),
    .queue_num_o(qnum_o), .queue_desc_o(qdesc),
    .queue_driver_o(qdrv), .queue_device_o(qdev),
    .reset_pending_o(rpend)
  );

  int acc[4];
  always @(posedge clk) begin
    if (req.aw_valid && resp.aw_ready) acc[0]++;
    if (req.w_valid && resp.w_ready) acc[1]++;
    if (req.ar_valid && resp.ar_ready) acc[2]++;
  end

  int checks = 0, fails = 0;
  task automatic ok(input bit c, input string n);
    checks++;
    if (!c) begin fails++; $display("VIRTIO_FAIL %s", n); end
  endtask
  task automatic section(input string n);
    $display("VIRTIO_SECTION %s", n);
    $fflush();
  endtask

  task automatic wr(input logic [11:0] a, input logic [31:0] d,
                    input logic [3:0] stb, output logic [1:0] rsp);
    int s0;
    s0 = acc[0];
    req.aw.addr = 64'(a); req.aw_valid = 1;
    do @(negedge clk); while (acc[0] == s0);
    req.aw_valid = 0;
    s0 = acc[1];
    req.w.data = d; req.w.strb = stb; req.w_valid = 1;
    do @(negedge clk); while (acc[1] == s0);
    req.w_valid = 0;
    req.b_ready = 1;
    while (!resp.b_valid) @(negedge clk);
    rsp = resp.b.resp;
    tick(); req.b_ready = 0;
  endtask

  task automatic wr_wfirst(input logic [11:0] a, input logic [31:0] d,
                           output logic [1:0] rsp);
    int s0;
    s0 = acc[1];
    req.w.data = d; req.w.strb = 4'hF; req.w_valid = 1;
    do @(negedge clk); while (acc[1] == s0);
    req.w_valid = 0;
    s0 = acc[0];
    req.aw.addr = 64'(a); req.aw_valid = 1;
    do @(negedge clk); while (acc[0] == s0);
    req.aw_valid = 0;
    req.b_ready = 1;
    while (!resp.b_valid) @(negedge clk);
    rsp = resp.b.resp;
    tick(); req.b_ready = 0;
  endtask

  task automatic rd(input logic [11:0] a, output logic [31:0] d,
                    output logic [1:0] rsp);
    int s0;
    s0 = acc[2];
    req.ar.addr = 64'(a); req.ar_valid = 1;
    do @(negedge clk); while (acc[2] == s0);
    req.ar_valid = 0;
    req.r_ready = 1;
    while (!resp.r_valid) @(negedge clk);
    d = resp.r.data; rsp = resp.r.resp;
    tick(); req.r_ready = 0;
  endtask

  logic [31:0] d;
  logic [1:0] rsp;
  int notify_pulses;

  // Drive a queue setup to just before QueueReady (helper).
  task automatic negotiate(input bit version1);
    logic [1:0] r0;
    wr(12'h070, 32'h0, 4'hF, r0);          // reset (dma_idle=1 -> immediate)
    wr(12'h064, 32'h3, 4'hF, r0);          // ACK irqs
    wr(12'h070, 32'h3, 4'hF, r0);          // ACKNOWLEDGE|DRIVER
    wr(12'h014, 32'h0, 4'hF, r0);          // features bank 0
    wr(12'h020, 32'h0, 4'hF, r0);
    wr(12'h014, 32'h1, 4'hF, r0);          // features bank 1
    wr(12'h024, 32'h1, 4'hF, r0);
    wr(12'h020, version1 ? 32'h1 : 32'h0, 4'hF, r0);
    wr(12'h024, 32'h0, 4'hF, r0);
  endtask

  task automatic queue_setup();
    logic [1:0] r0;
    wr(12'h030, 32'h0, 4'hF, r0);
    wr(12'h038, 32'd128, 4'hF, r0);
    wr(12'h080, 32'h0001_0000, 4'hF, r0);
    wr(12'h084, 32'h0, 4'hF, r0);
    wr(12'h090, 32'h0002_0000, 4'hF, r0);
    wr(12'h094, 32'h0, 4'hF, r0);
    wr(12'h0A0, 32'h0003_0000, 4'hF, r0);
    wr(12'h0A4, 32'h0, 4'hF, r0);
  endtask

  always @(posedge clk) if (notify) notify_pulses++;

  initial begin
    req = '0; usable = 0; dma_idle = 1; used_ev = 0; fault_ev = 0;
    cap_ev = 0; cap_in = 64'h1234_5678_9ABC_DEF0; notify_pulses = 0;
    repeat (3) tick(); rst_n = 1; repeat (2) tick();

    section("identity");
    rd(12'h000, d, rsp); ok(rsp == 0 && d == 32'h7472_6976, "magic");
    rd(12'h004, d, rsp); ok(rsp == 0 && d == 32'd2, "version");
    rd(12'h008, d, rsp); ok(rsp == 0 && d == 0, "devid-off");
    usable = 1; tick();
    rd(12'h008, d, rsp); ok(rsp == 0 && d == 2, "devid-on");
    rd(12'h00C, d, rsp); ok(rsp == 0 && d == 32'hDEAD_BEEF, "vendor");

    section("features");
    wr(12'h014, 32'h0, 4'hF, rsp); rd(12'h010, d, rsp);
    ok(rsp == 0 && d == 0, "feat-bank0");
    wr(12'h014, 32'h1, 4'hF, rsp); rd(12'h010, d, rsp);
    ok(rsp == 0 && d == 32'h1, "feat-bank1");
    wr(12'h014, 32'h2, 4'hF, rsp); rd(12'h010, d, rsp);
    ok(rsp == 0 && d == 0, "feat-bank2");
    wr(12'h014, 32'h33, 4'hF, rsp); rd(12'h010, d, rsp);
    ok(d == 0, "feat-bank33");

    section("linux-init");
    negotiate(1);
    wr(12'h070, 32'h8, 4'hF, rsp); // FEATURES_OK
    rd(12'h070, d, rsp); ok(d == 8'h0B, "fok-status");
    ok(fok, "fok-out");
    ok(dfeat == 64'h1_0000_0000, "dfeat-out");
    queue_setup();
    rd(12'h034, d, rsp); ok(d == 128, "qnmax");
    wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 1 && qready, "qready");
    wr(12'h070, 32'h4, 4'hF, rsp); // DRIVER_OK
    rd(12'h070, d, rsp); ok(d == 8'h0F && dok, "dok");

    section("fok-refused-no-v1");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    usable = 1;
    negotiate(0); // no VERSION_1
    wr(12'h070, 32'h8, 4'hF, rsp);
    rd(12'h070, d, rsp); ok(d == 8'h03 && !fok, "fok-refused-nov1");

    section("fok-refused-extra");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    negotiate(1);
    wr(12'h014, 32'h0, 4'hF, rsp);
    wr(12'h024, 32'h0, 4'hF, rsp);
    wr(12'h020, 32'h2, 4'hF, rsp); // bank0 unoffered bit
    wr(12'h070, 32'h8, 4'hF, rsp);
    rd(12'h070, d, rsp); ok(d == 8'h03 && !fok, "fok-refused-extra");

    section("dok-before-fok");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    negotiate(1);
    wr(12'h070, 32'h4, 4'hF, rsp);
    rd(12'h070, d, rsp); ok(d == 8'h03 && !dok, "dok-before-fok");

    section("qready-refusals");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    negotiate(1);
    wr(12'h070, 32'h8, 4'hF, rsp);
    queue_setup();
    // QueueNum = 0
    wr(12'h038, 32'd0, 4'hF, rsp); wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 0 && !qready, "qr-num0");
    // QueueNum = 3 (not pow2)
    wr(12'h038, 32'd3, 4'hF, rsp); wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 0, "qr-num3");
    // QueueNum = 256 (> max)
    wr(12'h038, 32'd256, 4'hF, rsp); wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 0, "qr-num256");
    // valid num but misaligned desc
    wr(12'h038, 32'd128, 4'hF, rsp);
    wr(12'h080, 32'h0001_0004, 4'hF, rsp); wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 0, "qr-desc-align");
    wr(12'h080, 32'h0001_0000, 4'hF, rsp);
    // driver misaligned (needs 2-byte)
    wr(12'h090, 32'h0002_0001, 4'hF, rsp); wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 0, "qr-drv-align");
    wr(12'h090, 32'h0002_0000, 4'hF, rsp);
    // device misaligned (needs 4-byte)
    wr(12'h0A0, 32'h0003_0002, 4'hF, rsp); wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 0, "qr-dev-align");
    wr(12'h0A0, 32'h0003_0000, 4'hF, rsp);
    // device area wrapping 2^64: device=2^64-8, num=128 -> +6+8*128 over
    wr(12'h0A0, 32'hFFFF_FFF0, 4'hF, rsp);
    wr(12'h0A4, 32'hFFFF_FFFF, 4'hF, rsp); wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 0, "qr-dev-wrap");
    wr(12'h0A0, 32'h0003_0000, 4'hF, rsp);
    wr(12'h0A4, 32'h0, 4'hF, rsp);
    // now a legal setup commits
    wr(12'h044, 32'h1, 4'hF, rsp);
    rd(12'h044, d, rsp); ok(d == 1 && qready, "qr-ok");
    // writes while ready ignored
    wr(12'h038, 32'd64, 4'hF, rsp);
    ok(qnum_o == 128, "qnum-frozen");
    // queue 1 writes ignored
    wr(12'h030, 32'h1, 4'hF, rsp);
    wr(12'h038, 32'd16, 4'hF, rsp);
    ok(qnum_o == 128, "qnum-q1-ign");
    rd(12'h044, d, rsp); ok(d == 0, "qready-q1-read");
    wr(12'h030, 32'h0, 4'hF, rsp);
    // DRIVER_OK already set -> queue ready write of 0 ignored, and a second
    // ready is blocked because DRIVER_OK is set
    wr(12'h070, 32'h4, 4'hF, rsp);

    section("notify");
    begin
      int snap;
      snap = notify_pulses;
      wr(12'h050, 32'h0, 4'hF, rsp);
      ok(notify_pulses == snap + 1, "notify-ok");
      wr(12'h050, 32'h1, 4'hF, rsp);
      ok(notify_pulses == snap + 1, "notify-val1");
      wr(12'h050, 32'h0, 4'hF, rsp);
      ok(notify_pulses == snap + 2, "notify-again");
      // ring fault blocks notify
      fault_ev = 1; tick(); fault_ev = 0;
      rd(12'h070, d, rsp); ok(d == 8'h4F, "needs-reset");
      rd(12'h060, d, rsp); ok(d[1] == 1 && irq, "fault-irq");
      snap = notify_pulses;
      wr(12'h050, 32'h0, 4'hF, rsp);
      ok(notify_pulses == snap, "notify-fault");
    end

    section("irq-events");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    used_ev = 1; tick(); used_ev = 0;
    rd(12'h060, d, rsp); ok(d == 1 && irq, "irq-used");
    wr(12'h064, 32'h1, 4'hF, rsp);
    rd(12'h060, d, rsp); ok(d == 0 && !irq, "irq-ack");
    // same-cycle event + ack: event wins
    used_ev = 1;
    // AW and W offered together; used_ev is held high until the write
    // handshake completes, so the ACK lands in a cycle with the event.
    begin
      int a0, w0;
      a0 = acc[0]; w0 = acc[1];
      req.aw.addr = 64'h064; req.aw_valid = 1;
      req.w.data = 32'h1; req.w.strb = 4'hF; req.w_valid = 1;
      while (acc[0] == a0 || acc[1] == w0) begin
        @(negedge clk);
        if (acc[0] != a0) req.aw_valid = 0;
        if (acc[1] != w0) req.w_valid = 0;
      end
      tick();
    end
    used_ev = 0; req.aw_valid = 0; req.w_valid = 0;
    req.b_ready = 1;
    while (!resp.b_valid) @(negedge clk);
    tick(); req.b_ready = 0;
    rd(12'h060, d, rsp); ok(d == 1, "irq-event-wins");

    section("capacity");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    rd(12'h0FC, d, rsp); ok(d == 0, "cfggen0");
    cap_in = 64'h0000_0000_0010_0000;
    cap_ev = 1; tick(); cap_ev = 0;
    rd(12'h0FC, d, rsp); ok(d == 1, "cfggen1");
    rd(12'h060, d, rsp); ok(d == 2, "cap-irq");
    rd(12'h100, d, rsp); ok(d == 32'h0010_0000, "cap-lo");
    rd(12'h101, d, rsp); ok(d == 32'h0010_0000, "cap-byte1");
    rd(12'h104, d, rsp); ok(d == 0, "cap-hi");
    rd(12'h107, d, rsp); ok(d == 0, "cap-byte7");
    rd(12'h140, d, rsp); ok(d == 0, "cfg-other");
    wr(12'h100, 32'hFFFF_FFFF, 4'hF, rsp); ok(rsp == 0, "cfg-wr-ign");
    rd(12'h100, d, rsp); ok(d == 32'h0010_0000, "cap-stable");

    section("ring-fault");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    fault_ev = 1; tick(); fault_ev = 0;
    rd(12'h070, d, rsp); ok(d == 8'h40, "fault-needsreset");
    rd(12'h060, d, rsp); ok(d == 2, "fault-bit1");

    section("reset-dma");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    negotiate(1); queue_setup();
    wr(12'h070, 32'h8, 4'hF, rsp);
    wr(12'h044, 32'h1, 4'hF, rsp);
    wr(12'h070, 32'h4, 4'hF, rsp);
    cap_in = 64'h5555; cap_ev = 1; tick(); cap_ev = 0;
    begin
      int epoch0;
      epoch0 = epoch;
      dma_idle = 0;
      wr(12'h070, 32'h0, 4'hF, rsp);
      ok(rpend, "rpend-high");
      rd(12'h070, d, rsp); ok(d == 8'h0F, "status-held");
      wr(12'h018, 32'h1, 4'hF, rsp); ok(rsp == 2'b10, "write-while-pend-ro");
      repeat (3) tick();
      rd(12'h070, d, rsp); ok(d == 8'h0F, "status-still-held");
      dma_idle = 1; tick();
      ok(!rpend, "rpend-low");
      rd(12'h070, d, rsp); ok(d == 0, "status-cleared");
      ok(epoch == epoch0 + 1, "epoch-inc");
      rd(12'h0FC, d, rsp); ok(d == 1, "cfggen-persists");
      rd(12'h100, d, rsp); ok(d == 32'h5555, "cap-persists");
      ok(!qready && !dok && !fok, "all-cleared");
    end

    section("slverr");
    rd(12'h001, d, rsp); ok(rsp == 2'b10, "rd-misaligned");
    wr(12'h014, 32'h0, 4'h7, rsp); ok(rsp == 2'b10, "wr-strb");
    wr(12'h013, 32'h0, 4'hF, rsp); ok(rsp == 2'b10, "wr-misaligned");
    rd(12'h014, d, rsp); ok(rsp == 2'b10, "rd-wo");
    rd(12'h020, d, rsp); ok(rsp == 2'b10, "rd-drvfeat");
    rd(12'h030, d, rsp); ok(rsp == 2'b10, "rd-qsel");
    rd(12'h038, d, rsp); ok(rsp == 2'b10, "rd-qnum");
    rd(12'h050, d, rsp); ok(rsp == 2'b10, "rd-notify");
    rd(12'h064, d, rsp); ok(rsp == 2'b10, "rd-ack");
    rd(12'h0AC, d, rsp); ok(rsp == 2'b10, "rd-shmsel");
    rd(12'h0B0, d, rsp); ok(rsp == 0 && d == 32'hFFFF_FFFF, "shmlen");
    rd(12'h0B8, d, rsp); ok(rsp == 0 && d == 0, "shmbase");
    wr(12'h0B0, 32'h0, 4'hF, rsp); ok(rsp == 2'b10, "wr-shmlen");
    wr(12'h034, 32'h1, 4'hF, rsp); ok(rsp == 2'b10, "wr-ro");
    rd(12'h018, d, rsp); ok(rsp == 2'b10, "rd-018");
    rd(12'h0C4, d, rsp); ok(rsp == 2'b10, "rd-0c4");
    rd(12'h160, d, rsp); ok(rsp == 2'b10, "rd-160");
    rd(12'hFFC, d, rsp); ok(rsp == 2'b10, "rd-ffc");
    wr(12'h160, 32'h0, 4'hF, rsp); ok(rsp == 2'b10, "wr-160");
    wr(12'h0C0, 32'h1, 4'hF, rsp); ok(rsp == 0, "qreset-ign");
    rd(12'h0C0, d, rsp); ok(rsp == 0 && d == 0, "qreset-rd");

    section("order-backpressure");
    wr_wfirst(12'h014, 32'h1, rsp); ok(rsp == 0, "w-before-aw");
    rd(12'h010, d, rsp); ok(d == 1, "w-before-aw-data");
    // hold R
    begin
      int r0;
      r0 = acc[2];
      req.ar.addr = 64'h000; req.ar_valid = 1;
      while (acc[2] == r0) @(negedge clk);
    end
    req.ar_valid = 0;
    repeat (2) begin
      ok(resp.r_valid && resp.r.data == 32'h7472_6976, "r-held");
      tick();
    end
    req.r_ready = 1; tick(); req.r_ready = 0;
    // hold B
    begin
      int a0, w0;
      a0 = acc[0];
      req.aw.addr = 64'h014; req.aw_valid = 1;
      while (acc[0] == a0) @(negedge clk);
      req.aw_valid = 0;
      w0 = acc[1];
      req.w.data = 32'h0; req.w.strb = 4'hF; req.w_valid = 1;
      while (acc[1] == w0) @(negedge clk);
      req.w_valid = 0;
    end
    repeat (2) begin ok(resp.b_valid, "b-held"); tick(); end
    req.b_ready = 1; tick(); req.b_ready = 0;

    section("reset-mid");
    begin
      int r0;
      r0 = acc[2];
      req.ar.addr = 64'h000; req.ar_valid = 1;
      while (acc[2] == r0) @(negedge clk);
    end
    req.ar_valid = 0;
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (2) tick();
    ok(!resp.r_valid, "reset-mid-r");
    rd(12'h000, d, rsp); ok(rsp == 0 && d == 32'h7472_6976, "post-reset");

    if ($test$plusargs("oracle_negative")) ok(0, "oracle-negative");
    if (fails != 0) $fatal(1, "VIRTIO_FAILED fails=%0d", fails);
    $display("VIRTIO_PASS checks=%0d", checks);
    $finish;
  end

  initial begin
    #500000;
    $fatal(1, "VIRTIO_TIMEOUT");
  end
endmodule

// Synthesis wrapper (top-level module).
module g6lc_storamic_virtio_mmio_synth (
  input logic clk_i,
  input logic rst_ni,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  input logic device_usable_i,
  input logic [63:0] capacity_i,
  input logic capacity_update_i,
  input logic dma_idle_i,
  input logic used_event_i,
  input logic ring_fault_i,
  output logic notify_o,
  output logic irq_o,
  output logic driver_ok_o,
  output logic features_ok_o,
  output logic queue_ready_o,
  output logic reset_pending_o
);
  g6lc_storamic_virtio_mmio #(
    .VendorId(32'h5354_524D), .QueueNumMax(128)
  ) dut (
    .clk_i, .rst_ni, .ctrl_req_i, .ctrl_resp_o,
    .device_usable_i, .capacity_i, .capacity_update_i, .flush_cap_i(1'b0), .dma_idle_i,
    .used_event_i, .ring_fault_i, .notify_o, .irq_o, .driver_ok_o,
    .features_ok_o, .driver_features_o(), .reset_epoch_o(),
    .queue_ready_o, .queue_num_o(), .queue_desc_o(), .queue_driver_o(),
    .queue_device_o(), .reset_pending_o
  );
endmodule
