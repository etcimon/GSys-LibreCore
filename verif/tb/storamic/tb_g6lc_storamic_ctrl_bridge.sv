// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-010C: AXI4 -> AXI-Lite control bridge bench. An AXI4 master model drives
// g6lc_storamic_ctrl_bridge into the real g6lc_storamic_regs block. Expected
// register values come from the documented register map, not from the DUT.
// StallW=1 inserts a shim that holds the AXI-Lite W channel off for several
// cycles after every AW acceptance, so AW and W complete on different cycles.
`define STORAMIC_WAIT_FOR(cond, name) begin int g; g = 0; while (!(cond)) begin @(negedge clk); g++; if (g > 200) $fatal(1, "STORAMIC_CTRL_TIMEOUT %s", name); end end

module tb_g6lc_storamic_ctrl_bridge #(
  parameter bit StallW = 1'b0,
  parameter bit CtrlPageEn = 1'b1
);
  localparam int unsigned IdW = 4;
  localparam logic [63:0] Base = 64'h5000_0000;
  localparam logic [31:0] Magic = 32'h5354_524D;

  // Channel shapes follow ariane_axi_soc (AR carries no atop).
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
  typedef struct packed {
    logic [63:0] data; logic [7:0] strb; logic last; logic user;
  } w_t;
  typedef struct packed {logic [IdW-1:0] id; logic [1:0] resp; logic user;} b_t;
  typedef struct packed {
    logic [IdW-1:0] id; logic [63:0] data; logic [1:0] resp; logic last;
    logic user;
  } r_t;
  typedef struct packed {
    aw_t aw; logic aw_valid; w_t w; logic w_valid; logic b_ready;
    ar_t ar; logic ar_valid; logic r_ready;
  } req_t;
  typedef struct packed {
    logic aw_ready; logic w_ready; b_t b; logic b_valid;
    logic ar_ready; r_t r; logic r_valid;
  } resp_t;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask

  req_t mreq;
  resp_t mresp;
  g6lc_storamic_pkg::axil_req_t lreq, sreq;
  g6lc_storamic_pkg::axil_resp_t lresp, sresp;
  logic irq;
  logic [2:0] faults;

  g6lc_storamic_pkg::axil_req_t vreq;
  g6lc_storamic_pkg::axil_resp_t vresp;
  g6lc_storamic_ctrl_bridge #(
    .AddrWidth(64), .DataWidth(64), .IdWidth(IdW), .UserWidth(1),
    .Base(Base), .CtrlPageEn(CtrlPageEn),
    .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .axi_req_i(mreq), .axi_resp_o(mresp),
    .ctrl_req_o(lreq), .ctrl_resp_i(lresp),
    .vctrl_req_o(vreq), .vctrl_resp_i(vresp)
  );

  // Page 1: a real virtio-blk transport (DeviceID 0, as natively bound).
  g6lc_storamic_virtio_mmio #(.QueueNumMax(128)) vmmio (
    .clk_i(clk), .rst_ni(rst_n), .ctrl_req_i(vreq), .ctrl_resp_o(vresp),
    .device_usable_i(1'b0), .capacity_i('0), .capacity_update_i(1'b0), .flush_cap_i(1'b0),
    .dma_idle_i(1'b1), .used_event_i(1'b0), .ring_fault_i(1'b0),
    .notify_o(), .irq_o(), .driver_ok_o(), .features_ok_o(),
    .driver_features_o(), .reset_epoch_o(), .queue_ready_o(), .queue_num_o(),
    .queue_desc_o(), .queue_driver_o(), .queue_device_o(), .reset_pending_o()
  );

  // Optional W stall shim between the bridge and the register block.
  // W is admitted only from registered state: an AW must already have been
  // accepted, and four cycles must have passed since. This forces AW and W
  // to complete on different cycles without a combinational path back into
  // the bridge.
  int stall;
  logic aw_pending;
  logic w_block;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stall <= 0;
      aw_pending <= 1'b0;
    end else begin
      if (sreq.aw_valid && sresp.aw_ready) begin
        stall <= 4;
        aw_pending <= 1'b1;
      end else if (stall > 0) stall <= stall - 1;
      if (sreq.w_valid && sresp.w_ready) aw_pending <= 1'b0;
    end
  end
  assign w_block = StallW && (stall > 0 || !aw_pending);
  always_comb begin
    sreq = lreq;
    sreq.w_valid = lreq.w_valid && !w_block;
  end
  always_comb begin
    lresp = sresp;
    lresp.w_ready = sresp.w_ready && !w_block;
  end

  // Independent AXI-Lite handshake counters (bridge side).
  int lite_aw, lite_w, lite_ar, lite_b, lite_r;
  always @(posedge clk) begin
    if (lreq.aw_valid && lresp.aw_ready) lite_aw++;
    if (lreq.w_valid && lresp.w_ready) lite_w++;
    if (lreq.ar_valid && lresp.ar_ready) lite_ar++;
    if (lreq.b_ready && lresp.b_valid) lite_b++;
    if (lreq.r_ready && lresp.r_valid) lite_r++;
  end
  function automatic int lite_total();
    return lite_aw + lite_w + lite_ar + lite_b + lite_r;
  endfunction

  // ST-037C IO-only role: page-0 AXI-Lite traffic must never appear.
  if (!CtrlPageEn) begin : gen_ioonly_guard
    always @(posedge clk) if (rst_n) begin
      if (lreq.aw_valid || lreq.w_valid || lreq.ar_valid ||
          lreq.b_ready || lreq.r_ready)
        $fatal(1, "STORAMIC_CTRL_FAIL ioonly-ctrl-active");
    end
  end

  g6lc_storamic_region_pkg::slot_map_t s_map;
  g6lc_storamic_regs #(
    .Cfg(g6lc_storamic_cfg_pkg::StoramicModel), .Slots(3), .Regions(4),
    .DataWidth(64)
  ) regs (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .ctrl_req_i(sreq), .ctrl_resp_o(sresp),
    .service_ready_i(1'b1), .model_ready_i(1'b1),
    .sequence_exhausted_i(1'b0), .faults_i(faults), .stray_i(1'b0),
    .txn_accept_i('0), .txn_refuse_i('0), .txn_retire_i('0),
    .txn_error_i('0), .inflight_i(1'b0),
    .slot_state_i('0), .slot_fault_i('0), .slot_dup_i('0),
    .slot_map_i(s_map), .slot_fault_event_i('0), .slot_ready_event_i('0),
    .slot_quiesce_o(), .slot_fault_clear_o(), .irq_o(irq),
    .map_valid_o(), .slot_map_o(), .region_map_o()
  );

  int checks = 0;
  bit corrupt = 1'b0;
  task automatic ok(input bit c, input string n);
    checks++;
    if (!c) $fatal(1, "STORAMIC_CTRL_FAIL %s", n);
  endtask

  // One AXI4 write. W is offered `wgap` cycles after AW acceptance; all W
  // beats (len+1) are sent. B is accepted `bgap` cycles after it appears and
  // must stay stable meanwhile.
  task automatic awr(input logic [63:0] a, input logic [63:0] d,
                     input logic [7:0] stb, input logic [IdW-1:0] id,
                     input logic [7:0] len, input logic [2:0] sz,
                     input logic [5:0] atop, input int bgap,
                     output logic [1:0] rsp);
    logic [1:0] first;
    mreq.aw = '0;
    mreq.aw.addr = a; mreq.aw.id = id; mreq.aw.len = len; mreq.aw.size = sz;
    mreq.aw.burst = 2'b01; mreq.aw.atop = atop; mreq.aw_valid = 1'b1;
    `STORAMIC_WAIT_FOR(mresp.aw_ready, "aw")
    tick(); mreq.aw_valid = 1'b0;
    for (int beat = 0; beat <= len; beat++) begin
      mreq.w = '0;
      mreq.w.data = d; mreq.w.strb = stb; mreq.w.last = (beat == len);
      mreq.w_valid = 1'b1;
      `STORAMIC_WAIT_FOR(mresp.w_ready, "w")
      tick();
    end
    mreq.w_valid = 1'b0;
    `STORAMIC_WAIT_FOR(mresp.b_valid, "b")
    first = mresp.b.resp;
    repeat (bgap) begin
      ok(mresp.b_valid && mresp.b.resp == first && mresp.b.id == id, "b-stable");
      tick();
    end
    rsp = mresp.b.resp;
    ok(mresp.b.id == id, "b-id");
    mreq.b_ready = 1'b1; tick(); mreq.b_ready = 1'b0;
    ok(!mresp.b_valid, "b-retired");
  endtask

  // One AXI4 read returning the first beat, total beats and last placement.
  task automatic ard(input logic [63:0] a, input logic [IdW-1:0] id,
                     input logic [7:0] len, input logic [2:0] sz,
                     input int rgap, output logic [63:0] d,
                     output logic [1:0] rsp, output int beats);
    logic [63:0] first_d;
    mreq.ar = '0;
    mreq.ar.addr = a; mreq.ar.id = id; mreq.ar.len = len; mreq.ar.size = sz;
    mreq.ar.burst = 2'b01; mreq.ar_valid = 1'b1;
    `STORAMIC_WAIT_FOR(mresp.ar_ready, "ar")
    tick(); mreq.ar_valid = 1'b0;
    `STORAMIC_WAIT_FOR(mresp.r_valid, "r")
    first_d = mresp.r.data;
    repeat (rgap) begin
      ok(mresp.r_valid && mresp.r.data == first_d, "r-stable");
      tick();
    end
    d = mresp.r.data; rsp = mresp.r.resp;
    beats = 0;
    mreq.r_ready = 1'b1;
    forever begin
      ok(mresp.r_valid && mresp.r.id == id, "r-id");
      beats++;
      if (mresp.r.resp != rsp) ok(0, "r-resp-consistent");
      if (mresp.r.last) break;
      ok(beats <= int'(len), "r-last-late");
      tick();
    end
    ok(beats == int'(len) + 1, "r-beats");
    tick(); mreq.r_ready = 1'b0;
  endtask

  logic [63:0] d;
  logic [1:0] rsp;
  int beats, snap;
  initial begin
    mreq = '0;
    faults = '0;
    s_map = '0;
    if ($test$plusargs("oracle_negative")) corrupt = 1'b1;
    repeat (3) tick(); rst_n = 1'b1; repeat (2) tick();

    if (!CtrlPageEn) begin
      // ST-037C IO-only role: page 0 answers DECERR exactly like a reserved
      // page (write beats drained, len+1 R beats, IDs echoed) and drives no
      // AXI-Lite traffic — the concurrent guard above fires on any activity.
      // Page 1 (virtio) is unaffected.
      ard(Base, 4'h3, 0, 2, 0, d, rsp, beats);
      ok(rsp == 2'b11 && d == '0 && beats == 1, "ioonly-id-decerr");
      awr(Base + 64'h18, 64'h5, 8'h0F, 4'h7, 1, 2, '0, 0, rsp);
      ok(rsp == 2'b11, "ioonly-write-decerr");
      ard(Base + 64'h1C, 4'h5, 2, 2, 0, d, rsp, beats);
      ok(rsp == 2'b11 && beats == 3, "ioonly-burst-decerr");
      ok(lite_total() == 0, "ioonly-no-lite");
      ard(Base + 64'h1000, 4'hC, 0, 2, 0, d, rsp, beats);
      ok(rsp == 2'b00 && d[31:0] == 32'h7472_6976, "ioonly-virtio-magic");
      awr(Base + 64'h2000, 64'h1, 8'hFF, 4'hA, 0, 2, '0, 0, rsp);
      ok(rsp == 2'b11, "ioonly-2000-decerr");
      ard(Base, 4'h1, 0, 2, 0, d, rsp, beats);
      ok(rsp == (corrupt ? 2'b00 : 2'b11), "ioonly-page0-decerr");
    end else begin
    // ID (lane 0) and VERSION (lane 1, contract version 4), data replicated.
    ard(Base + 64'h0, 4'h3, 0, 2, 0, d, rsp, beats);
    ok(rsp == 2'b00 && d == {Magic, Magic}, "id-lane0");
    ard(Base + 64'h4, 4'h5, 0, 2, 2, d, rsp, beats);
    ok(rsp == 2'b00 && d == {32'd4, 32'd4}, "version-lane1");
    ard(Base + 64'h4, 4'h5, 0, 0, 0, d, rsp, beats);
    ok(rsp == 2'b00 && d[31:0] == 32'd4, "byte-read-legal");

    // IRQ_ENABLE (0x18, lane 0): full write, read back; partial strobes.
    awr(Base + 64'h18, 64'h5, 8'h0F, 4'h7, 0, 2, '0, 0, rsp);
    ok(rsp == 2'b00, "irqen-wr");
    ard(Base + 64'h18, 4'h1, 0, 2, 0, d, rsp, beats);
    ok(rsp == 2'b00 && d[31:0] == 32'h5, "irqen-rd");
    awr(Base + 64'h18, 64'hF, 8'h00, 4'h7, 0, 2, '0, 3, rsp); // no strobes
    ard(Base + 64'h18, 4'h1, 0, 2, 0, d, rsp, beats);
    ok(d[31:0] == 32'h5, "irqen-no-strobe-no-change");
    // Strobes on the wrong lane for 0x18 (upper) must not change it either.
    awr(Base + 64'h18, 64'hF_0000_0000, 8'hF0, 4'h7, 0, 2, '0, 0, rsp);
    ard(Base + 64'h18, 4'h1, 0, 2, 0, d, rsp, beats);
    ok(d[31:0] == 32'h5, "irqen-other-lane-ignored");

    // Fault event -> FAULTS[0] and IRQ_PENDING[0]; irq_o is a level.
    awr(Base + 64'h18, 64'h1, 8'h0F, 4'h2, 0, 2, '0, 0, rsp);
    faults = 3'b001; tick(); faults = '0;
    repeat (2) tick();
    ok(irq, "irq-level-high");
    ard(Base + 64'h1C, 4'h2, 0, 2, 0, d, rsp, beats);
    ok(d[0] == 1'b1, "pending-set");
    // IRQ_PENDING (0x1C) W1C through the upper lane.
    awr(Base + 64'h1C, 64'h1_0000_0000, 8'hF0, 4'h2, 0, 2, '0, 0, rsp);
    ok(rsp == 2'b00, "w1c-upper-lane");
    ard(Base + 64'h1C, 4'h2, 0, 2, 0, d, rsp, beats);
    ok(d[32] == 1'b0 && d[0] == 1'b0, "pending-cleared");
    repeat (2) tick();
    ok(!irq, "irq-level-low");

    // RO register write: AXI-Lite SLVERR passes through.
    awr(Base + 64'h0, 64'h1, 8'hFF, 4'h4, 0, 2, '0, 0, rsp);
    ok(rsp == 2'b10, "ro-write-slverr");

    // Illegal shapes: SLVERR, every beat honoured, zero AXI-Lite handshakes.
    snap = lite_total();
    awr(Base + 64'h18, 64'h1, 8'hFF, 4'h6, 1, 2, '0, 0, rsp);
    ok(rsp == 2'b10, "len1-write-slverr");
    awr(Base + 64'h18, 64'h1, 8'hFF, 4'h6, 3, 2, '0, 0, rsp);
    ok(rsp == 2'b10, "len3-write-slverr");
    ard(Base + 64'h0, 4'h8, 1, 2, 0, d, rsp, beats);
    ok(rsp == 2'b10 && beats == 2, "len1-read-slverr");
    ard(Base + 64'h0, 4'h8, 7, 2, 1, d, rsp, beats);
    ok(rsp == 2'b10 && beats == 8, "len7-read-slverr");
    awr(Base + 64'h18, 64'h1, 8'hFF, 4'h9, 0, 3, '0, 0, rsp);
    ok(rsp == 2'b10, "size3-write-slverr");
    ard(Base + 64'h0, 4'h9, 0, 3, 0, d, rsp, beats);
    ok(rsp == 2'b10, "size3-read-slverr");
    awr(Base + 64'h18, 64'h1, 8'hFF, 4'h9, 0, 2, 6'b100000, 0, rsp);
    ok(rsp == 2'b10, "atop-slverr");
    ok(lite_total() == snap, "illegal-no-lite");

    // Reserved virtio apertures: DECERR, zero AXI-Lite handshakes.
    snap = lite_total();
    awr(Base + 64'h2000, 64'h1, 8'hFF, 4'hA, 0, 2, '0, 0, rsp);
    ok(rsp == 2'b11, "w-2000-decerr");
    ard(Base + 64'hF_FFFC, 4'hB, 0, 2, 0, d, rsp, beats);
    ok(rsp == 2'b11 && d == '0, "r-ffffc-decerr");
    ard(Base + 64'h8_0000, 4'hB, 2, 2, 0, d, rsp, beats);
    ok(rsp == 2'b11 && beats == 3, "r-burst-decerr");
    ok(lite_total() == snap, "reserved-no-lite");

    // Page 1 reaches the virtio transport: magic, version 2, DeviceID 0.
    snap = lite_total();
    ard(Base + 64'h1000, 4'hC, 0, 2, 0, d, rsp, beats);
    ok(rsp == 2'b00 && d[31:0] == 32'h7472_6976, "virtio-magic");
    ard(Base + 64'h1004, 4'hC, 0, 2, 0, d, rsp, beats);
    ok(rsp == 2'b00 && d[63:32] == 32'd2, "virtio-version-lane1");
    ard(Base + 64'h1008, 4'hC, 0, 2, 0, d, rsp, beats);
    ok(rsp == 2'b00 && d[31:0] == 32'd0, "virtio-deviceid-0");
    awr(Base + 64'h1070, 64'h1, 8'h0F, 4'hC, 0, 2, '0, 0, rsp);
    ok(rsp == 2'b00, "virtio-status-write");
    ard(Base + 64'h1070, 4'hC, 0, 2, 0, d, rsp, beats);
    ok(d[31:0] == 32'h1, "virtio-status-readback");
    ard(Base + 64'h0000, 4'hC, 0, 2, 0, d, rsp, beats);
    ok(d[31:0] == Magic, "page0-still-regs");
    ok(lite_total() > snap, "virtio-page-uses-lite");

    // IRQ_ENABLE still holds its value: no side effect from refused writes.
    ard(Base + 64'h18, 4'h1, 0, 2, 0, d, rsp, beats);
    ok(d[31:0] == 32'h1, "no-side-effect");

    // Concurrent read and write with distinct IDs.
    mreq.aw = '0; mreq.ar = '0;
    mreq.aw.addr = Base + 64'h18; mreq.aw.id = 4'hD; mreq.aw.size = 2;
    mreq.ar.addr = Base + 64'h0; mreq.ar.id = 4'hE; mreq.ar.size = 2;
    mreq.aw_valid = 1'b1; mreq.ar_valid = 1'b1;
    mreq.w = '0; mreq.w.data = 64'h3; mreq.w.strb = 8'h0F; mreq.w.last = 1'b1;
    mreq.w_valid = 1'b1;
    mreq.b_ready = 1'b1; mreq.r_ready = 1'b1;
    begin
      bit aw_done, ar_done, w_done, b_done, r_done;
      int g;
      {aw_done, ar_done, w_done, b_done, r_done} = '0;
      g = 0;
      while (!(b_done && r_done)) begin
        @(posedge clk);
        if (mreq.aw_valid && mresp.aw_ready) aw_done = 1;
        if (mreq.ar_valid && mresp.ar_ready) ar_done = 1;
        if (mreq.w_valid && mresp.w_ready) w_done = 1;
        if (mresp.b_valid && mreq.b_ready) begin
          ok(mresp.b.id == 4'hD && mresp.b.resp == 2'b00, "conc-b");
          b_done = 1;
        end
        if (mresp.r_valid && mreq.r_ready) begin
          ok(mresp.r.id == 4'hE && mresp.r.data == {Magic, Magic} &&
             mresp.r.last, "conc-r");
          r_done = 1;
        end
        @(negedge clk);
        if (aw_done) mreq.aw_valid = 1'b0;
        if (ar_done) mreq.ar_valid = 1'b0;
        if (w_done) mreq.w_valid = 1'b0;
        if (++g > 200) $fatal(1, "STORAMIC_CTRL_TIMEOUT concurrent");
      end
      mreq.b_ready = 1'b0; mreq.r_ready = 1'b0;
      mreq.aw_valid = 1'b0; mreq.ar_valid = 1'b0; mreq.w_valid = 1'b0;
    end
    ard(Base + 64'h18, 4'h1, 0, 2, 0, d, rsp, beats);
    ok(d[31:0] == 32'h3, "conc-write-landed");

    // Reset in the middle of a read: no response survives, service resumes.
    mreq.ar = '0; mreq.ar.addr = Base; mreq.ar.size = 2; mreq.ar_valid = 1'b1;
    `STORAMIC_WAIT_FOR(mresp.ar_ready, "ar-rst")
    tick(); mreq.ar_valid = 1'b0;
    rst_n = 1'b0; repeat (2) tick();
    ok(!mresp.r_valid && !mresp.b_valid, "reset-clears");
    rst_n = 1'b1; repeat (2) tick();
    ok(!mresp.r_valid, "reset-no-stale-r");
    ard(Base + 64'h18, 4'h1, 0, 2, 0, d, rsp, beats);
    ok(rsp == 2'b00 && d[31:0] == 32'h0, "post-reset-irqen");
    ard(Base, 4'h1, 0, 2, 0, d, rsp, beats);
    ok(d == (corrupt ? 64'h0 : {Magic, Magic}), "post-reset-id");
    end

    $display("STORAMIC_CTRL_PASS stall=%0d checks=%0d lite_aw=%0d lite_w=%0d",
             StallW, checks, lite_aw, lite_w);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "STORAMIC_CTRL_TIMEOUT global");
  end
endmodule

// Synthesis wrapper: the bridge alone with ariane-shaped channel structs.
module g6lc_storamic_ctrl_bridge_synth #(
  parameter bit CtrlPageEn = 1'b1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic [3:0] aw_id_i,
  input logic [63:0] aw_addr_i,
  input logic [7:0] aw_len_i,
  input logic [2:0] aw_size_i,
  input logic [5:0] aw_atop_i,
  input logic aw_valid_i,
  input logic [63:0] w_data_i,
  input logic [7:0] w_strb_i,
  input logic w_last_i,
  input logic w_valid_i,
  input logic b_ready_i,
  input logic [3:0] ar_id_i,
  input logic [63:0] ar_addr_i,
  input logic [7:0] ar_len_i,
  input logic [2:0] ar_size_i,
  input logic ar_valid_i,
  input logic r_ready_i,
  output logic aw_ready_o,
  output logic w_ready_o,
  output logic b_valid_o,
  output logic [1:0] b_resp_o,
  output logic ar_ready_o,
  output logic r_valid_o,
  output logic [63:0] r_data_o,
  output logic r_last_o,
  output g6lc_storamic_pkg::axil_req_t ctrl_req_o,
  input g6lc_storamic_pkg::axil_resp_t ctrl_resp_i,
  output g6lc_storamic_pkg::axil_req_t vctrl_req_o,
  input g6lc_storamic_pkg::axil_resp_t vctrl_resp_i
);
  typedef struct packed {
    logic [3:0] id; logic [63:0] addr; logic [7:0] len; logic [2:0] size;
    logic [5:0] atop;
  } aw_t;
  typedef struct packed {
    logic [3:0] id; logic [63:0] addr; logic [7:0] len; logic [2:0] size;
  } ar_t;
  typedef struct packed {logic [63:0] data; logic [7:0] strb; logic last;} w_t;
  typedef struct packed {logic [3:0] id; logic [1:0] resp; logic user;} b_t;
  typedef struct packed {
    logic [3:0] id; logic [63:0] data; logic [1:0] resp; logic last; logic user;
  } r_t;
  typedef struct packed {
    aw_t aw; logic aw_valid; w_t w; logic w_valid; logic b_ready;
    ar_t ar; logic ar_valid; logic r_ready;
  } req_t;
  typedef struct packed {
    logic aw_ready; logic w_ready; b_t b; logic b_valid;
    logic ar_ready; r_t r; logic r_valid;
  } resp_t;
  req_t req;
  resp_t resp;
  assign req = '{
    aw: '{id: aw_id_i, addr: aw_addr_i, len: aw_len_i, size: aw_size_i,
          atop: aw_atop_i},
    aw_valid: aw_valid_i,
    w: '{data: w_data_i, strb: w_strb_i, last: w_last_i},
    w_valid: w_valid_i, b_ready: b_ready_i,
    ar: '{id: ar_id_i, addr: ar_addr_i, len: ar_len_i, size: ar_size_i},
    ar_valid: ar_valid_i, r_ready: r_ready_i};
  assign aw_ready_o = resp.aw_ready;
  assign w_ready_o = resp.w_ready;
  assign b_valid_o = resp.b_valid;
  assign b_resp_o = resp.b.resp;
  assign ar_ready_o = resp.ar_ready;
  assign r_valid_o = resp.r_valid;
  assign r_data_o = resp.r.data;
  assign r_last_o = resp.r.last;
  g6lc_storamic_ctrl_bridge #(
    .AddrWidth(64), .DataWidth(64), .IdWidth(4), .UserWidth(1),
    .Base(64'h5000_0000), .CtrlPageEn(CtrlPageEn),
    .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) i_bridge (
    .clk_i, .rst_ni, .axi_req_i(req), .axi_resp_o(resp),
    .ctrl_req_o, .ctrl_resp_i, .vctrl_req_o, .vctrl_resp_i
  );
endmodule

// ST-037C: CtrlPageEn=0 synthesis variant (IO-only role).
module g6lc_storamic_ctrl_bridge_io_synth (
  input logic clk_i,
  input logic rst_ni,
  input logic [3:0] aw_id_i,
  input logic [63:0] aw_addr_i,
  input logic [7:0] aw_len_i,
  input logic [2:0] aw_size_i,
  input logic [5:0] aw_atop_i,
  input logic aw_valid_i,
  input logic [63:0] w_data_i,
  input logic [7:0] w_strb_i,
  input logic w_last_i,
  input logic w_valid_i,
  input logic b_ready_i,
  input logic [3:0] ar_id_i,
  input logic [63:0] ar_addr_i,
  input logic [7:0] ar_len_i,
  input logic [2:0] ar_size_i,
  input logic ar_valid_i,
  input logic r_ready_i,
  output logic aw_ready_o,
  output logic w_ready_o,
  output logic b_valid_o,
  output logic [1:0] b_resp_o,
  output logic ar_ready_o,
  output logic r_valid_o,
  output logic [63:0] r_data_o,
  output logic r_last_o,
  output g6lc_storamic_pkg::axil_req_t ctrl_req_o,
  input g6lc_storamic_pkg::axil_resp_t ctrl_resp_i,
  output g6lc_storamic_pkg::axil_req_t vctrl_req_o,
  input g6lc_storamic_pkg::axil_resp_t vctrl_resp_i
);
  g6lc_storamic_ctrl_bridge_synth #(.CtrlPageEn(1'b0)) i_wrap (.*);
endmodule
