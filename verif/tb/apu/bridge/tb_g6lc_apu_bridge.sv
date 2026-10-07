// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// 3d-b RTL bridge fixture (apu-vulkan-engine.md §12.3 phase B, second
// half): g6lc_apu_sys with ApuCfg = ApuVenus behind flat scalar ports so
// bridge_main.cpp (Verilator --cc) can drive the guest AXI-Lite window
// and serve the device AXI4 master over the unix-socket bridge protocol.
// VenusOff=1 builds the ApuP1Transport control instead (kernel probes
// -virgl, no capsets, no DMA).  The debug tap page is a server-side
// overlay: offsets above the MMIO window answer internal observability
// signals without touching the DUT (QEMU never generates them).

module tb_g6lc_apu_bridge
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit VenusOff = 1'b0) (
  input  logic        clk_i,
  input  logic        rst_ni,
  // guest AXI4-Lite slave port — C++ is the master
  input  logic        g_awvalid_i,
  input  logic [63:0] g_awaddr_i,
  output logic        g_awready_o,
  input  logic        g_wvalid_i,
  input  logic [31:0] g_wdata_i,
  input  logic [3:0]  g_wstrb_i,
  output logic        g_wready_o,
  output logic        g_bvalid_o,
  output logic [1:0]  g_bresp_o,
  input  logic        g_bready_i,
  input  logic        g_arvalid_i,
  input  logic [63:0] g_araddr_i,
  output logic        g_arready_o,
  output logic        g_rvalid_o,
  output logic [31:0] g_rdata_o,
  output logic [1:0]  g_rresp_o,
  input  logic        g_rready_i,
  // device AXI4 master — C++ is the slave
  output logic        d_awvalid_o,
  output logic [3:0]  d_awid_o,
  output logic [63:0] d_awaddr_o,
  output logic [7:0]  d_awlen_o,
  output logic [2:0]  d_awsize_o,
  output logic [1:0]  d_awburst_o,
  input  logic        d_awready_i,
  output logic        d_wvalid_o,
  output logic [63:0] d_wdata_o,
  output logic [7:0]  d_wstrb_o,
  output logic        d_wlast_o,
  input  logic        d_wready_i,
  input  logic        d_bvalid_i,
  input  logic [3:0]  d_bid_i,
  input  logic [1:0]  d_bresp_i,
  output logic        d_bready_o,
  output logic        d_arvalid_o,
  output logic [3:0]  d_arid_o,
  output logic [63:0] d_araddr_o,
  output logic [7:0]  d_arlen_o,
  output logic [2:0]  d_arsize_o,
  output logic [1:0]  d_arburst_o,
  input  logic        d_arready_i,
  input  logic        d_rvalid_i,
  input  logic [3:0]  d_rid_i,
  input  logic [63:0] d_rdata_i,
  input  logic [1:0]  d_rresp_i,
  input  logic        d_rlast_i,
  output logic        d_rready_o,
  output logic        guest_irq_o,
  // debug tap page: sel -> 64-bit readback (server overlay; see
  // bridge_main.cpp for the map).  All zeros under VenusOff.
  input  logic [7:0]  dbg_sel_i,
  output logic [63:0] dbg_rdata_o
);

  function automatic config_pkg::cva6_cfg_t venus_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction

  // transport-only control config: hart+RAM pairing per apu_cfg_legal
  function automatic apu_cfg_t venus_off_cfg();
    apu_cfg_t cfg = ApuP1Transport;
    cfg.FirmwareHart     = 1;
    cfg.FirmwareRamBase  = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction

  localparam apu_cfg_t Cfg = VenusOff ? venus_off_cfg() : ApuVenus;

  apu_axi_req_t  g_req;
  apu_axi_resp_t g_rsp;
  apu_axi_req_t  c_req;
  apu_axi_resp_t c_rsp;
  apu_dma_axi_req_t  d_req;
  apu_dma_axi_resp_t d_rsp;

  // flat guest port <-> AXI4-Lite struct
  always_comb begin
    g_req            = '0;
    g_req.aw.addr    = g_awaddr_i;
    g_req.aw.prot    = 3'b111;
    g_req.aw_valid   = g_awvalid_i;
    g_req.w.data     = g_wdata_i;
    g_req.w.strb     = g_wstrb_i;
    g_req.w_valid    = g_wvalid_i;
    g_req.b_ready    = g_bready_i;
    g_req.ar.addr    = g_araddr_i;
    g_req.ar.prot    = 3'b111;
    g_req.ar_valid   = g_arvalid_i;
    g_req.r_ready    = g_rready_i;
  end
  assign g_awready_o = g_rsp.aw_ready;
  assign g_wready_o  = g_rsp.w_ready;
  assign g_bvalid_o  = g_rsp.b_valid;
  assign g_bresp_o   = g_rsp.b.resp;
  assign g_arready_o = g_rsp.ar_ready;
  assign g_rvalid_o  = g_rsp.r_valid;
  assign g_rdata_o   = g_rsp.r.data;
  assign g_rresp_o   = g_rsp.r.resp;

  // VenusOff: the transport leg holds the guest port after STATUS<-0
  // until a control-window ACTRL_RESET_ACK lands — the "service hart"
  // ack the sys-venus TB performs with ocwrite.  Emulate it with a
  // one-shot AXI-Lite master on the control port (the guest/QEMU never
  // sees the control window; the protocol carries only the guest one).
  logic be_rreq;
  if (VenusOff) begin : gen_cack
    typedef enum logic [1:0] {C_IDLE, C_ISSUE, C_RESP} cst_e;
    cst_e cst_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cst_q <= C_IDLE;
        c_req <= '0;
      end else begin
        unique case (cst_q)
          C_IDLE: if (be_rreq) begin
            c_req.aw.addr   <= Cfg.ControlBase + 64'(ACTRL_RESET_ACK);
            c_req.aw.prot   <= 3'b111;
            c_req.aw_valid  <= 1'b1;
            c_req.w.data    <= 32'h1;
            c_req.w.strb    <= 4'hf;
            c_req.w_valid   <= 1'b1;
            c_req.b_ready   <= 1'b0;
            c_req.ar        <= '{default: '0};
            c_req.ar_valid  <= 1'b0;
            c_req.r_ready   <= 1'b0;
            cst_q <= C_ISSUE;
          end
          C_ISSUE: begin
            if (c_req.aw_valid && c_rsp.aw_ready) c_req.aw_valid <= 1'b0;
            if (c_req.w_valid && c_rsp.w_ready)   c_req.w_valid  <= 1'b0;
            if ((!c_req.aw_valid || c_rsp.aw_ready) &&
                (!c_req.w_valid || c_rsp.w_ready)) begin
              c_req.b_ready <= 1'b1;
              cst_q <= C_RESP;
            end
          end
          C_RESP: if (c_rsp.b_valid) begin
            c_req <= '0;
            cst_q <= C_IDLE;
          end
          default: cst_q <= C_IDLE;
        endcase
      end
    end
  end else begin : gen_no_cack
    assign c_req = '0;
  end

  // flat AXI4 master <-> slave response struct
  assign d_awvalid_o = d_req.aw_valid;
  assign d_awid_o    = d_req.aw.id;
  assign d_awaddr_o  = d_req.aw.addr;
  assign d_awlen_o   = d_req.aw.len;
  assign d_awsize_o  = d_req.aw.size;
  assign d_awburst_o = d_req.aw.burst;
  assign d_wvalid_o  = d_req.w_valid;
  assign d_wdata_o   = d_req.w.data;
  assign d_wstrb_o   = d_req.w.strb;
  assign d_wlast_o   = d_req.w.last;
  assign d_bready_o  = d_req.b_ready;
  assign d_arvalid_o = d_req.ar_valid;
  assign d_arid_o    = d_req.ar.id;
  assign d_araddr_o  = d_req.ar.addr;
  assign d_arlen_o   = d_req.ar.len;
  assign d_arsize_o  = d_req.ar.size;
  assign d_arburst_o = d_req.ar.burst;
  assign d_rready_o  = d_req.r_ready;

  always_comb begin
    d_rsp             = '0;
    d_rsp.aw_ready    = d_awready_i;
    d_rsp.w_ready     = d_wready_i;
    d_rsp.b_valid     = d_bvalid_i;
    d_rsp.b.id        = d_bid_i;
    d_rsp.b.resp      = axi_pkg::resp_t'(d_bresp_i);
    d_rsp.ar_ready    = d_arready_i;
    d_rsp.r_valid     = d_rvalid_i;
    d_rsp.r.id        = d_rid_i;
    d_rsp.r.data      = d_rdata_i;
    d_rsp.r.resp      = axi_pkg::resp_t'(d_rresp_i);
    d_rsp.r.last      = d_rlast_i;
  end

  g6lc_apu_sys #(
    .ApuCfg(Cfg), .CoreCfg(venus_core())
  ) i_dut (
    .clk_i, .rst_ni, .testmode_i(1'b1),
    .guest_req_i(g_req), .guest_rsp_o(g_rsp),
    .control_req_i(c_req), .control_rsp_o(c_rsp),
    .control_aw_authorized_i(1'b1), .control_ar_authorized_i(1'b1),
    .guest_irq_o, .control_irq_o(),
    .vq_state_o(), .queue_enable_o(),
    .backend_reset_req_o(be_rreq), .backend_queue_stop_req_o(),
    .backend_reset_done_i(1'b1), .backend_idle_i('1),
    .used_valid_i(1'b0), .used_qid_i('0), .used_context_i('0),
    .used_fence_i('0), .used_len_i('0), .used_ready_o(),
    .cfg_display_event_i(1'b0), .bus_fault_o(),
    .dma_req_o(d_req), .dma_rsp_i(d_rsp),
    .guest_hold_i(1'b0), .guest_epoch_i('0), .ctrl_hold_i(1'b0),
    .ctrl_epoch_i('0), .epoch_o()
  );

  // ---- debug taps ------------------------------------------------------
  logic        f_seen_q;
  logic [63:0] f_id_q;
  logic [7:0]  f_ring_q;

  if (!VenusOff) begin : gen_dbg
    wire        f_pulse = i_dut.gen_venus.i_vgsys.fence_pulse_o;
    wire [63:0] f_id    = i_dut.gen_venus.i_vgsys.fence_id_o;
    wire [7:0]  f_ring  = i_dut.gen_venus.i_vgsys.fence_ring_o;
    wire [15:0] ot_live = i_dut.gen_venus.i_vgsys.objtab_live_o;
    wire [31:0] fcnt    = i_dut.gen_venus.i_vgsys.fault_cnt_o;
    wire        vg_idle = i_dut.gen_venus.vg_idle;
    wire        rdone   = i_dut.gen_venus.i_vgsys.reset_done_o;
    wire [3:0][31:0] r_status = i_dut.gen_venus.i_vgsys.ring_status_o;
    wire [3:0][31:0] r_head   = i_dut.gen_venus.i_vgsys.ring_head_o;
    wire [3:0][g6lc_apu_vg_pkg::APU_VG_AP_WORD_W-1:0] r_extra  = i_dut.gen_venus.i_vgsys.ring_extra_w_o;
    wire [g6lc_apu_vg_pkg::APU_VG_PAGES-1:0] vgp_free = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                              .i_vgp.gen_on.free_q;
    wire [255:0] pay_free = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                              .i_pay.gen_on.free_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        f_seen_q <= 1'b0; f_id_q <= '0; f_ring_q <= '0;
      end else if (f_pulse) begin
        f_seen_q <= 1'b1; f_id_q <= f_id; f_ring_q <= f_ring;
      end
    end

    always_comb begin
      unique case (dbg_sel_i)
        8'd0:    dbg_rdata_o = 64'h600D_B21D_0000_0001;   // magic
        8'd1:    dbg_rdata_o = 64'(ot_live);
        8'd2:    dbg_rdata_o = 64'(fcnt);
        8'd3:    dbg_rdata_o = 64'({6'h0, f_seen_q, rdone, vg_idle});
        8'd4:    dbg_rdata_o = f_id_q;
        8'd5:    dbg_rdata_o = 64'(f_ring_q);
        8'd6:    dbg_rdata_o = 64'($countones(vgp_free));
        8'd7:    dbg_rdata_o = 64'(|pay_free);   // 0 = chunks drained
        default: begin
          if (dbg_sel_i >= 8'd16 && dbg_sel_i < 8'd20)
            dbg_rdata_o = 64'(r_head[dbg_sel_i[1:0]]);
          else if (dbg_sel_i >= 8'd20 && dbg_sel_i < 8'd24)
            dbg_rdata_o = 64'(r_status[dbg_sel_i[1:0]]);
          else if (dbg_sel_i >= 8'd24 && dbg_sel_i < 8'd28)
            dbg_rdata_o = 64'(r_extra[dbg_sel_i[1:0]]);
          else dbg_rdata_o = '0;
        end
      endcase
    end
  end else begin : gen_dbg_off
    assign f_seen_q = 1'b0;
    assign f_id_q   = '0;
    assign f_ring_q = '0;
    always_comb dbg_rdata_o = dbg_sel_i == 8'd0
                                ? 64'h600D_B21D_0000_0001 : '0;
  end

endmodule
