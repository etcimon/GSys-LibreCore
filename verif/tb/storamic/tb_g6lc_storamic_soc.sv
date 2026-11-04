// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`include "axi/assign.svh"
`include "axi/typedef.svh"

module tb_g6lc_storamic_soc #(
  parameter int unsigned DramClass = 0,
  parameter int unsigned NrChannels = 1,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned IdWidth = 5,
  parameter int unsigned BackendAddrWidth = 64,
  parameter bit Joined = 1'b0,
  parameter bit Source = 1'b0,
  parameter bit LegacyGate = 1'b0,
  // ST-011B: with G6LC_STORAMIC_MODEL the attach serves the DRAM slave from
  // the sim model memory instead of refusing.
  parameter bit Model = 1'b0,
  parameter int unsigned ModelWords = 1024
);
  localparam logic [63:0] ModelBase = 64'h8000_0000;
  localparam logic [63:0] ModelBytes = 64'(ModelWords) * (DataWidth / 8);
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;
  logic ready, service_ready;
  logic [g6lc_ai_island_cfg_pkg::AI_DRAM_MAX_CHANNELS-1:0][31:0] reads, writes;
  AXI_BUS #(
    .AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(DataWidth),
    .AXI_ID_WIDTH(IdWidth), .AXI_USER_WIDTH(2)
  ) bus();
  AXI_BUS #(
    .AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(DataWidth),
    .AXI_ID_WIDTH(IdWidth + (Joined ? 1 : 0)), .AXI_USER_WIDTH(2)
  ) backend_bus();

  typedef logic [63:0] check_addr_t;
  typedef logic [IdWidth + (Joined ? 1 : 0)-1:0] check_id_t;
  typedef logic [DataWidth-1:0] check_data_t;
  typedef logic [DataWidth/8-1:0] check_strb_t;
  typedef logic [1:0] check_user_t;
  `AXI_TYPEDEF_ALL(check_axi, check_addr_t, check_id_t, check_data_t, check_strb_t, check_user_t)
  check_axi_req_t expected_request;
  `AXI_ASSIGN_TO_REQ(expected_request, backend_bus)
  always @(posedge clk) begin
    if (rst_n)
      assert (dut.gen_storamic.i_storamic.req === expected_request)
        else $fatal(1, "STORAMIC_SOC_PAYLOAD_LOSS");
  end

  if (Joined) begin : gen_joined
    typedef logic [63:0] addr_t;
    typedef logic [IdWidth-1:0] id_t;
    typedef logic [DataWidth-1:0] data_t;
    typedef logic [DataWidth/8-1:0] strb_t;
    typedef logic [1:0] user_t;
    `AXI_TYPEDEF_ALL(idle_axi, addr_t, id_t, data_t, strb_t, user_t)
    idle_axi_req_t idle_req;
    assign idle_req = '0;
    AXI_BUS #(
      .AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(DataWidth),
      .AXI_ID_WIDTH(IdWidth), .AXI_USER_WIDTH(2)
    ) cluster_bus(), island_bus();
    if (Source) begin : gen_island
      `AXI_ASSIGN(island_bus, bus)
      `AXI_ASSIGN_FROM_REQ(cluster_bus, idle_req)
    end else begin : gen_cluster
      `AXI_ASSIGN(cluster_bus, bus)
      `AXI_ASSIGN_FROM_REQ(island_bus, idle_req)
    end
    g6lc_ai_dram_join #(
      .AXI_DATA_WIDTH(DataWidth), .ISLAND_DATA_WIDTH(DataWidth),
      .AXI_ID_WIDTH(IdWidth), .AXI_USER_WIDTH(2)
    ) i_join (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .init_done_i(LegacyGate ? ready : service_ready),
      .cluster(cluster_bus), .island(island_bus), .master(backend_bus)
    );
  end else begin : gen_direct
    `AXI_ASSIGN(backend_bus, bus)
  end

  g6lc_storamic_pkg::axil_req_t creq;
  g6lc_storamic_pkg::axil_resp_t cresp;
  logic cirq;

  g6lc_ai_dram_backend #(
    .StoramicEn(1'b1), .DramClass(DramClass), .NrChannels(NrChannels),
    .AXI_ADDR_WIDTH(BackendAddrWidth),
    .AXI_ID_WIDTH(IdWidth + (Joined ? 1 : 0)),
    .AXI_DATA_WIDTH(DataWidth), .AXI_USER_WIDTH(2),
    .NUM_WORDS(Model ? ModelWords : 2**25),
    .StoramicModelBase(ModelBase)
  ) dut (
    .storamic_ctrl_req_i(creq), .storamic_ctrl_resp_o(cresp),
    .storamic_irq_o(cirq),
    .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n),
    .testmode_i(1'b0), .slave(backend_bus), .init_done_o(ready),
    .service_ready_o(service_ready),
    .ch_r_beats_o(reads), .ch_w_beats_o(writes)
  );

  // ST-011B model-profile helpers: an independent byte-addressed model and
  // AXI burst drivers. Data/strobe patterns are generated inside, mirrored
  // to bmodel on the write path and compared on the read path.
  byte unsigned bmodel [longint unsigned];
  bit corrupt = 1'b0;
  int model_checks = 0;


  function automatic logic [63:0] beat_addr(input logic [63:0] base,
      input int i, input int len, input logic [1:0] burst);
    logic [63:0] span;
    if (burst == 2'b10) begin
      span = 64'(len + 1) * (DataWidth / 8);
      return (base & ~(span - 1)) +
             ((base & (span - 1)) + 64'(i) * (DataWidth / 8)) % span;
    end
    return base + 64'(i) * (DataWidth / 8);
  endfunction

  task automatic model_wr(input logic [63:0] addr, input int len,
                          input logic [1:0] burst, input logic [7:0] seed);
    bus.aw_addr = addr; bus.aw_len = 8'(len); bus.aw_size = 3;
    bus.aw_burst = burst; bus.aw_valid = 1;
    // Handshakes are sampled at posedge: a ready read in the same timestep
    // as the valid assignment may not have settled.
    do @(posedge clk); while (!bus.aw_ready);
    @(negedge clk); bus.aw_valid = 0;
    $display("STORAMIC_SOC_MODEL aw-accepted");
    for (int i = 0; i <= len; i++) begin
      for (int lane = 0; lane < DataWidth/8; lane++) begin
        bus.w_data[lane*8 +: 8] = seed ^ 8'(i * 8 + lane);
        bus.w_strb[lane] = ((i + lane) % 4) != 3;
      end
      // The model frontend refuses W beats with nonzero user bits.
      bus.w_user = '0;
      bus.w_last = (i == len); bus.w_valid = 1;
      do @(posedge clk); while (!bus.w_ready);
      for (int lane = 0; lane < DataWidth/8; lane++)
        if (bus.w_strb[lane])
          bmodel[beat_addr(addr, i, len, burst) + lane] =
              bus.w_data[lane*8 +: 8];
      @(negedge clk);
      $display("STORAMIC_SOC_MODEL w-beat %0d", i);
    end
    bus.w_valid = 0; bus.w_last = 0;
    bus.b_ready = 1;
    do @(posedge clk); while (!bus.b_valid);
    assert (bus.b_resp == 2'b00) else $fatal(1, "STORAMIC_MODEL_B_RESP");
    @(negedge clk); bus.b_ready = 0;
    model_checks++;
  endtask

  task automatic model_rd(input logic [63:0] addr, input int len,
                          input logic [1:0] burst);
    bus.ar_addr = addr; bus.ar_len = 8'(len); bus.ar_size = 3;
    bus.ar_burst = burst; bus.ar_valid = 1;
    do @(posedge clk); while (!bus.ar_ready);
    @(negedge clk); bus.ar_valid = 0;
    bus.r_ready = 1;
    for (int i = 0; i <= len; i++) begin
      do @(posedge clk); while (!bus.r_valid);
      assert (bus.r_resp == 2'b00) else $fatal(1, "STORAMIC_MODEL_R_RESP");
      for (int lane = 0; lane < DataWidth/8; lane++) begin
        logic [63:0] ba; byte exp;
        ba = beat_addr(addr, i, len, burst) + lane;
        exp = bmodel.exists(ba) ? bmodel[ba] : 8'h0;
        if (corrupt && ba == addr) exp ^= 8'hFF;
        model_checks++;
        assert (bus.r_data[lane*8 +: 8] === exp)
          else $fatal(1, "STORAMIC_MODEL_RDATA a=%h lane=%0d got=%h exp=%h",
                      ba, lane, bus.r_data[lane*8 +: 8], exp);
      end
      assert (bus.r_last == (i == len))
        else $fatal(1, "STORAMIC_MODEL_LAST");
      @(negedge clk);
    end
    bus.r_ready = 0;
  endtask

  task automatic model_refused(input logic [63:0] addr);
    bus.ar_addr = addr; bus.ar_len = 0; bus.ar_size = 3; bus.ar_burst = 1;
    bus.ar_valid = 1;
    do @(posedge clk); while (!bus.ar_ready);
    @(negedge clk); bus.ar_valid = 0;
    bus.r_ready = 1;
    do @(posedge clk); while (!bus.r_valid);
    assert (bus.r_resp == 2'b10) else $fatal(1, "STORAMIC_MODEL_REFUSE");
    model_checks++;
    @(negedge clk); bus.r_ready = 0;
  endtask

  initial begin
    creq = '0;
    bus.aw_id = '1;
    bus.aw_addr = 64'h8000_01a8;
    bus.aw_len = 0;
    bus.aw_size = 3;
    bus.aw_burst = 1;
    bus.aw_lock = 0;
    bus.aw_cache = 4'hb;
    bus.aw_prot = 3'h5;
    bus.aw_qos = 4'h9;
    bus.aw_region = 4'h6;
    bus.aw_atop = 0;
    bus.aw_user = 2'b10;
    bus.aw_valid = 0;
    for (int lane = 0; lane < DataWidth/8; lane++) begin
      bus.w_data[lane*8 +: 8] = 8'(8'h5a ^ lane);
      bus.w_strb[lane] = (lane % 3) != 0;
    end
    bus.w_last = 1;
    bus.w_user = 2'b01;
    bus.w_valid = 0;
    bus.b_ready = 0;
    bus.ar_id = '1;
    bus.ar_addr = 64'h8000_02b0;
    bus.ar_len = 3;
    bus.ar_size = 3;
    bus.ar_burst = 1;
    bus.ar_lock = 0;
    bus.ar_cache = 4'he;
    bus.ar_prot = 3'h3;
    bus.ar_qos = 4'h7;
    bus.ar_region = 4'hc;
    bus.ar_user = 2'b11;
    bus.ar_valid = 0;
    bus.r_ready = 0;
    repeat (3) @(negedge clk);
    assert (!service_ready && !ready) else $fatal(1, "STORAMIC_SOC_RESET_READY");
    rst_n = 1;
    if ($test$plusargs("oracle_negative")) corrupt = 1'b1;
    if (Model) begin : model_seq
      // ST-011B: writes/reads land in the sim model memory; the byte model
      // is independent of the DUT.
      $display("STORAMIC_SOC_MODEL wr-incr");
      model_wr(ModelBase + 64'h100, 3, 2'b01, 8'hA5);   // INCR, partial strb
      $display("STORAMIC_SOC_MODEL rd-incr");
      model_rd(ModelBase + 64'h100, 3, 2'b01);
      $display("STORAMIC_SOC_MODEL wr-wrap");
      model_wr(ModelBase + 64'h228, 3, 2'b10, 8'h3C);   // WRAP @ span 0x220
      model_rd(ModelBase + 64'h228, 3, 2'b10);
      $display("STORAMIC_SOC_MODEL top");
      // Read-after-write at the top word of the window.
      model_wr(ModelBase + ModelBytes - 8, 0, 2'b01, 8'h77);
      model_rd(ModelBase + ModelBytes - 8, 0, 2'b01);
      $display("STORAMIC_SOC_MODEL refuse");
      // Out-of-range: SLVERR, memory unchanged.
      bus.aw_addr = ModelBase + ModelBytes; bus.aw_len = 0; bus.aw_size = 3;
      bus.aw_burst = 1; bus.aw_valid = 1;
      while (!bus.aw_ready) @(negedge clk);
      @(negedge clk); bus.aw_valid = 0;
      bus.w_valid = 1; bus.w_last = 1;
      while (!bus.w_ready) @(negedge clk);
      @(negedge clk); bus.w_valid = 0; bus.w_last = 0;
      bus.b_ready = 1;
      while (!bus.b_valid) @(negedge clk);
      assert (bus.b_resp == 2'b10) else $fatal(1, "STORAMIC_MODEL_W_REFUSE");
      @(negedge clk); bus.b_ready = 0;
      model_refused(ModelBase + ModelBytes);
      model_rd(ModelBase + ModelBytes - 8, 0, 2'b01);
      $display("STORAMIC_SOC_MODEL checks=%0d", model_checks);
    end else begin
    bus.aw_valid = 1;
    bus.ar_valid = 1;
    fork
      begin
        do @(posedge clk); while (!bus.aw_ready);
        @(negedge clk);
        bus.aw_valid = 0;
      end
      begin
        do @(posedge clk); while (!bus.ar_ready);
        @(negedge clk);
        bus.ar_valid = 0;
      end
    join
    bus.w_valid = 1;
    do @(posedge clk); while (!bus.w_ready);
    @(negedge clk);
    bus.w_valid = 0;
    assert (service_ready && !ready && reads == 0 && writes == 0)
      else $fatal(1, "STORAMIC_SOC_FALSE_CAPABILITY");
    assert (bus.b_valid && bus.b_id == {IdWidth{1'b1}} &&
            bus.b_resp == 2'b10 && bus.b_user == 0)
      else $fatal(1, "STORAMIC_SOC_B");
    for (int i = 0; i < 4; i++) begin
      assert (bus.r_valid && bus.r_id == {IdWidth{1'b1}} &&
              bus.r_resp == 2'b10 && bus.r_data == 0 &&
              bus.r_user == 0 && bus.r_last == (i == 3))
        else $fatal(1, "STORAMIC_SOC_R");
      bus.r_ready = 1;
      @(negedge clk);
    end
    bus.r_ready = 0;
    bus.b_ready = 1;
    @(negedge clk);
    assert (!bus.r_valid && !bus.b_valid) else $fatal(1, "STORAMIC_SOC_EXTRA");
    bus.b_ready = 0;
    bus.ar_len = 7;
    bus.ar_valid = 1;
    do @(posedge clk); while (!bus.ar_ready);
    @(negedge clk);
    bus.ar_valid = 0;
    repeat (3) @(negedge clk);
    assert (bus.r_valid && bus.r_resp == 2'b10 && !bus.r_last)
      else $fatal(1, "STORAMIC_SOC_STALLED_READ");
    rst_n = 0;
    repeat (2) @(negedge clk);
    assert (!service_ready && !bus.r_valid && !bus.b_valid && !ready)
      else $fatal(1, "STORAMIC_SOC_RESET_ABORT");
    rst_n = 1;
    @(negedge clk);
    assert (service_ready && !bus.r_valid && !bus.b_valid && !ready)
      else $fatal(1, "STORAMIC_SOC_STALE_RESPONSE");
    end
    // ST-010C: ID read through the native ctrl seam returns OKAY + magic.
    $display("STORAMIC_SOC_CTRL_BEGIN t=%0t", $time);
    creq.ar.addr = 64'h0; creq.ar_valid = 1'b1;
    while (!cresp.ar_ready) @(negedge clk);
    @(negedge clk); creq.ar_valid = 1'b0;
    creq.r_ready = 1'b1;
    while (!cresp.r_valid) @(negedge clk);
    assert (cresp.r.resp == 2'b00 && cresp.r.data == 32'h5354_524D)
      else $fatal(1, "STORAMIC_SOC_CTRL_ID");
    assert (!cirq) else $fatal(1, "STORAMIC_SOC_CTRL_IRQ");
    @(negedge clk); creq.r_ready = 1'b0;
    $display("STORAMIC_SOC_PASS");
    $finish;
  end
  initial begin
    #20000;
    $fatal(1, "STORAMIC_SOC_TIMEOUT ar_ready=%0d r_valid=%0d",
           cresp.ar_ready, cresp.r_valid);
  end
endmodule

// Structural wrapper for synthesis of the native adapter and refusal profile.
module g6lc_storamic_soc_synth (
  input logic clk_i, rst_ni, testmode_i,
  input g6lc_storamic_pkg::axi_req_t req_i,
  output g6lc_storamic_pkg::axi_resp_t resp_o,
  output logic init_done_o, service_ready_o
);
  typedef logic [63:0] addr_t;
  typedef logic [7:0] id_t;
  typedef logic [63:0] data_t;
  typedef logic [7:0] strb_t;
  typedef logic user_t;
  `AXI_TYPEDEF_ALL(native_axi, addr_t, id_t, data_t, strb_t, user_t)
  native_axi_req_t native_req;
  AXI_BUS #(.AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(64),
            .AXI_ID_WIDTH(8), .AXI_USER_WIDTH(1)) bus();
  always_comb begin
    native_req = '0;
    native_req.aw = '{id: req_i.aw.id, addr: req_i.aw.addr, len: req_i.aw.len,
      size: req_i.aw.size, burst: req_i.aw.burst, lock: req_i.aw.lock,
      cache: req_i.aw.cache, prot: req_i.aw.prot, qos: req_i.aw.qos,
      region: req_i.aw.region, atop: '0, user: req_i.aw.user};
    native_req.aw_valid = req_i.aw_valid;
    native_req.w = req_i.w;
    native_req.w_valid = req_i.w_valid;
    native_req.b_ready = req_i.b_ready;
    native_req.ar = req_i.ar;
    native_req.ar_valid = req_i.ar_valid;
    native_req.r_ready = req_i.r_ready;
  end
  `AXI_ASSIGN_FROM_REQ(bus, native_req)
  `AXI_ASSIGN_TO_RESP(resp_o, bus)
  g6lc_storamic_attach #(.Enable(1'b1), .AddrWidth(64), .IdWidth(8),
                        .DataWidth(64), .UserWidth(1)) dut (
    .clk_i, .rst_ni, .testmode_i, .slave(bus), .ctrl_req_i('0),
    .ctrl_resp_o(), .irq_o(), .init_done_o, .service_ready_o
  );
endmodule
