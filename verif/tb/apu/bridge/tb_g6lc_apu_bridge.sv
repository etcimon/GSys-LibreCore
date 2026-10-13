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
    wire [31:0] vgp_used = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                              .i_vgp.gen_on.used_q;
    wire [255:0] pay_free = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                              .i_pay.gen_on.free_q;

    // §12.3 3d-d: relocation cost — one [reloc] line per completed
    // DEVBACKED MAP_BLOB hold (drain + evictions + move + publish)
    // plus the cumulative cycle counter on dbg sel 8
    wire        vc_hold  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .vc_hold;
    wire [31:0] vc_reloc = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_ctl.gen_on.reloc_cyc_q;
    logic [31:0] reloc_dur_q = '0;
    always_ff @(posedge clk_i) begin
      if (vc_hold) reloc_dur_q <= reloc_dur_q + 1;
      else if (reloc_dur_q != 0) begin
        $display("[reloc] DEVBACKED MAP_BLOB relocation: %0d cycles (cumulative %0d)",
                 reloc_dur_q, vc_reloc);
        reloc_dur_q <= '0;
      end
    end

    // F5 bring-up observability: vnfront's descriptor-path state,
    // readable over the bridge debug overlay (sel 32..47)
    wire [7:0]  fr_state = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.state_q;
    wire [31:0] fr_result = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.result_q;
    wire [31:0] fr_cmd   = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.op_q.cmd_type;
    wire [31:0] fr_imm0  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.op_q.imm[0];
    wire [31:0] fr_imm1  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.op_q.imm[1];
    wire [7:0]  fr_flags = {i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.ds_err_q,
                            i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.upd_elok_q,
                            i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.upd_pois_q,
                            i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.upd_bad_q,
                            i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.rw_ok_q,
                            i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.rsv_dead_q,
                            i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.rsv_ok_q,
                            i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.busy_o};
    wire [15:0] fr_upd_i = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.upd_i_q;
    wire [15:0] fr_ent_j = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ent_j_q;
    wire [7:0]  fr_rw_b  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.rw_bind_q;
    wire [7:0]  fr_rw_t  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.rw_typ_q;
    wire [15:0] fr_rw_c  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.rw_cnt_q;
    wire [19:0] fr_rw_o  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.rw_off_q;
    wire [31:0] fr_rec   = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.upd_rec_q;
    wire [15:0] fr_dcnt  = 16'(i_dut.gen_venus.i_vgsys.gen_on.i_top
                               .gen_on.i_pump.gen_on.i_fr.gen_on.upd_dcnt_q);
    wire [15:0] fr_arr   = 16'(i_dut.gen_venus.i_vgsys.gen_on.i_top
                               .gen_on.i_pump.gen_on.i_fr.gen_on.upd_arr_q);
    wire [7:0]  fr_dstb  = 8'(i_dut.gen_venus.i_vgsys.gen_on.i_top
                              .gen_on.i_pump.gen_on.i_fr.gen_on.upd_dstb_q);
    wire [7:0]  fr_utyp  = 8'(i_dut.gen_venus.i_vgsys.gen_on.i_top
                              .gen_on.i_pump.gen_on.i_fr.gen_on.upd_type_q);
    wire [15:0] fr_sbyt  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ds_sbyt_q;
    wire [15:0] fr_ndyn  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ds_ndyn_q;
    wire [24:0] fr_sbase = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ds_sbase_q;
    wire [63:0] fr_udst  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.upd_dst_q;
    wire [63:0] fr_ubuf  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.upd_buf_q;
    wire [24:0] fr_rsvb  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.rsv_base_q;
    wire [15:0] fr_rsvp  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.rsv_phnd_q[15:0];
    wire [15:0] fr_rsve  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.rsv_ep_q;
    wire [15:0] fr_rsvl  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.rsv_layh_q[15:0];
    wire [31:0] fr_eb    = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.upd_eb_q;
    wire [31:0] fr_esz   = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.upd_esz_q;
    // ObjTab request/completion taps (fr boundary)
    wire        fr_ot_rv = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ot_req_valid_o;
    wire        fr_ot_rr = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ot_req_ready_i;
    wire        fr_ot_cv = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ot_cpl_valid_i;
    wire [3:0]  fr_ot_cst = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.ot_cpl_i.status;
    wire [31:0] fr_ot_ch = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ot_cpl_i.handle;
    wire [3:0]  fr_ot_op = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.otr_q.op;

    // ---- wedge diagnosis: graphics-path FSM states (sel 48..55) ----
    wire [7:0]  ra_st   = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_rast.gen_on.st_q;
    wire [7:0]  ra_ret  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_rast.gen_on.mp_ret_q;
    wire [7:0]  ra_fret = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_rast.gen_on.fp_ret_q;
    wire [63:0] ra_ctx  = {20'h0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.code_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.nf_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.nv_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.p_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.f_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.t_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.lc_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.lane_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.clip_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.vsw_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.help_q};
    wire [63:0] ra_cur  = {32'h0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.sx_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.sy_q};
    wire [7:0]  ra_hs   = {
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.mp_rsp_i.err,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.gen_on.mp_acked_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.mp_req_valid_o,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.mp_req_ready_i,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.mp_rsp_valid_i,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.sh_work_valid_o,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.sh_work_ready_i,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_rast.sh_done_i};
    wire [15:0] ex_st   = {1'h0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_exec.gen_on.state_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_exec.gen_on.outst_q};
    wire [7:0]  sh_hs   = {4'h0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_sh.gen_on.cast_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_sh.gen_on.wbusy,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_sh.gen_on.wdone,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_sh.gen_on.disp_q_valid};
    wire [7:0]  wv_st   = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_sh.gen_on.i_wave.gen_on.st_q;
    wire [7:0]  wv_ret  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_sh.gen_on.i_wave.gen_on.ret_q;
    // drain/hold interlock + pump/apmem snapshot (sel 55..57): whether
    // vgctl parks on the relocation drain while an engine parks on its
    // own wait — the kernel D-state signature needs all four busy bits
    wire [7:0]  vg_st   = {2'b0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_ctl.gen_on.state_q};
    wire [7:0]  vg_int  = {5'b0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.vc_hold,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.drain_idle,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_ctl.gen_on.map_hold_q};
    wire [7:0]  eng_b   = {4'b0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.rs_busy,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.xfer_busy_o,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.sh_busy,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.ex_idle};
    wire [7:0]  pu_st   = {1'b0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_pump.gen_on.depth_q,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_pump.gen_on.state_q};
    wire [7:0]  pu_pol  = {6'b0,
        i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_pump.gen_on.poll_q};
    wire [7:0]  mp_os   = {7'b0,
        i_dut.gen_venus.i_vgsys.gen_on.i_mem.gen_on.out_q};
    wire [63:0] fr_ot_id = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.otr_q.id;
    wire [63:0] fr_ot_par = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.otr_q.parent_id;
    wire [5:0]  fr_ot_knd = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                            .i_pump.gen_on.i_fr.gen_on.otr_q.kind;
    wire [7:0]  fr_ctx   = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                           .i_pump.gen_on.i_fr.gen_on.ctx_i;

`ifdef G6LC_APU_DEBUG
    // F5 bring-up trace (-D G6LC_APU_DEBUG): command decode +
    // descriptor-path state transitions + ObjTab req/cpl -> stdout.
    logic [7:0]  fr_prev_q;
    logic [31:0] fr_pcmd_q;
    wire fr_isdesc = (fr_cmd >= 32'h48 && fr_cmd <= 32'h4f);
    always_ff @(posedge clk_i) begin
      if (fr_cmd != fr_pcmd_q)
        $display("[f5tr] cmd=%08x imm0=%0d imm1=%0d",
                 fr_cmd, fr_imm0, fr_imm1);
      if (fr_state != fr_prev_q &&
          (fr_isdesc || fr_state == 8'd155 || fr_result != 32'h0))
        $display("[f5tr] st=%0d res=%08x fl=%02x ui=%0d ej=%0d rwb=%0d rwt=%0d rwc=%0d rwo=%0d rec=%08x dcnt=%0d arr=%0d dstb=%0d utyp=%0d sbyt=%0d sb=%07x udst=%x ubuf=%x rsvb=%07x rsvp=%x rsve=%x rsvl=%x eb=%08x esz=%08x",
                 fr_state, fr_result, fr_flags, fr_upd_i, fr_ent_j,
                 fr_rw_b, fr_rw_t, fr_rw_c, fr_rw_o, fr_rec,
                 fr_dcnt, fr_arr, fr_dstb, fr_utyp, fr_sbyt,
                 fr_sbase, fr_udst, fr_ubuf, fr_rsvb, fr_rsvp,
                 fr_rsve, fr_rsvl, fr_eb, fr_esz);
      if (fr_ot_rv && fr_ot_rr)
        $display("[f5ot] req op=%0d id=%016x par=%016x knd=%0d ctx=%0d",
                 fr_ot_op, fr_ot_id, fr_ot_par, fr_ot_knd, fr_ctx);
      if (fr_ot_cv)
        $display("[f5ot] cpl st=%0d hnd=%08x", fr_ot_cst, fr_ot_ch);
      fr_prev_q <= fr_state;
      fr_pcmd_q <= fr_cmd;
    end

    // 5b guest-bring-up trace: pump FATAL entry + status writes.
    // StFatal=25 is the only source of a FATAL-bit ring-status write.
    logic [5:0] pu_prev_q;
    wire [5:0]  pu_state = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.state_q;
    wire [31:0] pu_ct0  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.cmd_type_q[0];
    wire [31:0] pu_ct1  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.cmd_type_q[1];
    wire        pu_rs0  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.st_q[0].ring_stream;
    wire        pu_rs1  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.st_q[1].ring_stream;
    wire [1:0]  pu_ring = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.st_q[0].ring;
    wire [31:0] pu_pos  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.st_q[0].pos;
    wire [31:0] pu_byt  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.st_q[0].bytes;
    wire        pu_dep  = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.depth_q;
    wire [31:0] pu_df   = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.dec_op.fault;
    wire [31:0] pu_ff   = i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
                          .i_pump.gen_on.fr_fault;
    always_ff @(posedge clk_i) begin
      // NB numeric state compares: hierarchical enum-member refs crash
      // the tool.  StFatal=27 (ordinals shift if the enum grows).
      if (pu_state != pu_prev_q && pu_state == 6'd27)
        $display("[f5pu] FATAL prev=%0d ct0=%08x ct1=%08x rs0=%0d rs1=%0d ring=%0d pos=%08x byt=%08x dep=%0d df=%08x ff=%08x",
                 pu_prev_q, pu_ct0, pu_ct1, pu_rs0, pu_rs1, pu_ring,
                 pu_pos, pu_byt, pu_dep, pu_df, pu_ff);
      pu_prev_q <= pu_state;
    end

    // [f5pu2]: stream create/die + ring head/live/fatal changes so a
    // bad base_head/bytes or a phantom head advance is directly
    // visible in the DMA trace.
`define _PU i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_pump.gen_on
    logic [31:0] pu_h_q[4];
    logic [7:0]  pu_rfl_q;
    logic        pu_s0lv_q, pu_s1lv_q;
    logic [6+32+64+64+32+32-1:0] pu_ex_q;
    always_ff @(posedge clk_i) begin
      if (!pu_s0lv_q && `_PU.st_q[0].live)
        $display("[f5pu2] S0NEW rs=%0d knd=%0d rng=%0d bh=%08x bw=%08x pos=%08x byt=%08x hd0=%08x",
                 `_PU.st_q[0].ring_stream, `_PU.st_q[0].kind,
                 `_PU.st_q[0].ring, `_PU.st_q[0].base_head,
                 `_PU.st_q[0].base_w, `_PU.st_q[0].pos,
                 `_PU.st_q[0].bytes, `_PU.ring_q[0].head);
      if (pu_s0lv_q && !`_PU.st_q[0].live)
        $display("[f5pu2] S0DIE pos=%08x byt=%08x hd0=%08x st=%0d",
                 `_PU.st_q[0].pos, `_PU.st_q[0].bytes,
                 `_PU.ring_q[0].head, `_PU.state_q);
      if (!pu_s1lv_q && `_PU.st_q[1].live)
        $display("[f5pu2] S1NEW bw=%08x byt=%08x pos=%08x",
                 `_PU.st_q[1].base_w, `_PU.st_q[1].bytes,
                 `_PU.st_q[1].pos);
      if (pu_s1lv_q && !`_PU.st_q[1].live)
        $display("[f5pu2] S1DIE pos=%08x byt=%08x st=%0d",
                 `_PU.st_q[1].pos, `_PU.st_q[1].bytes, `_PU.state_q);
      for (int r = 0; r < 4; r++) begin
        if (`_PU.ring_q[r].head != pu_h_q[r])
          $display("[f5pu2] HEAD r%0d %08x -> %08x st=%0d",
                   r, pu_h_q[r], `_PU.ring_q[r].head, `_PU.state_q);
        if ({`_PU.ring_q[r].fatal, `_PU.ring_q[r].live} !=
            pu_rfl_q[2*r +: 2])
          $display("[f5pu2] RING r%0d live=%0d fatal=%0d st=%0d hnd=%016x rctx=%x ckill=%0d ckid=%x thnd=%016x ctype=%08x sctx=%x",
                   r, `_PU.ring_q[r].live, `_PU.ring_q[r].fatal,
                   `_PU.state_q, `_PU.ring_q[r].handle,
                   `_PU.ring_q[r].ctx, `_PU.ctx_kill_valid_i,
                   `_PU.ctx_kill_id_i, `_PU.t_hnd_q,
                   `_PU.cmd_type_q[`_PU.depth_q],
                   `_PU.st_q[`_PU.depth_q].ctx);
        pu_h_q[r]            <= `_PU.ring_q[r].head;
        pu_rfl_q[2*r +: 2]   <= {`_PU.ring_q[r].fatal,
                                `_PU.ring_q[r].live};
      end
      pu_s0lv_q <= `_PU.st_q[0].live;
      pu_s1lv_q <= `_PU.st_q[1].live;
      // ring-record decode + wait resolution: which ctx's stream
      // executed which handle-addressed record (cross-ctx handle
      // collisions show sctx != the matched ring's ctx).
      // NB numeric state compares: hierarchical enum-member refs
      // (``_PU.StTrDo) crash Verilator. StTrDo=12, StWaitR=19.
      // Print only on change: a parked wait would otherwise emit one
      // line per cycle and drown the log.
      if ((`_PU.state_q == 6'd12 || `_PU.state_q == 6'd19) &&
          {`_PU.state_q, `_PU.cmd_type_q[`_PU.depth_q],
           `_PU.t_hnd_q, `_PU.t_val_q,
           `_PU.ring_q[0].head, `_PU.ring_q[1].head} != pu_ex_q)
        $display("[f5pu2] EXEC st=%0d ctype=%08x thnd=%016x tval=%016x sctx=%x r0={h=%016x c=%x lv=%0d hd=%x} r1={h=%016x c=%x lv=%0d hd=%x}",
                 `_PU.state_q, `_PU.cmd_type_q[`_PU.depth_q],
                 `_PU.t_hnd_q, `_PU.t_val_q, `_PU.st_q[`_PU.depth_q].ctx,
                 `_PU.ring_q[0].handle, `_PU.ring_q[0].ctx,
                 `_PU.ring_q[0].live, `_PU.ring_q[0].head,
                 `_PU.ring_q[1].handle, `_PU.ring_q[1].ctx,
                 `_PU.ring_q[1].live, `_PU.ring_q[1].head);
      pu_ex_q <= {`_PU.state_q, `_PU.cmd_type_q[`_PU.depth_q],
                  `_PU.t_hnd_q, `_PU.t_val_q,
                  `_PU.ring_q[0].head, `_PU.ring_q[1].head};
    end

    // [f5wx]: 5b image-path trace — work issue (dispatch/xfer with the
    // resolved operand bases), per-work completion codes, and the
    // xfer fault edge; localizes a wrong-data submit to copy vs shader.
`define _TOP i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
    logic        xf_ffq_q;
    always_ff @(posedge clk_i) begin
      if (`_TOP.ex_work_v && `_TOP.ex_work_rdy &&
          (`_TOP.work_is_disp || `_TOP.work_is_xfer))
        $display("[f5wx] ISSUE ct=%02x xop=%0d sb=%08x ss=%08x db=%08x ds=%08x i0={b%08x s%08x w%0d h%0d f%02x m%0d l%0d lb%08x} i1={b%08x w%0d h%0d f%02x}",
                 `_TOP.work_o.ctype, `_TOP.ex_xfer.op,
                 `_TOP.ex_xfer.src_base, `_TOP.ex_xfer.src_size,
                 `_TOP.ex_xfer.dst_base, `_TOP.ex_xfer.dst_size,
                 `_TOP.ex_xfer.img0.base, `_TOP.ex_xfer.img0.size,
                 `_TOP.ex_xfer.img0.w, `_TOP.ex_xfer.img0.h,
                 `_TOP.ex_xfer.img0.fmt, `_TOP.ex_xfer.img0.mips,
                 `_TOP.ex_xfer.img0.layers,
                 `_TOP.ex_xfer.img0.layer_bytes,
                 `_TOP.ex_xfer.img1.base, `_TOP.ex_xfer.img1.w,
                 `_TOP.ex_xfer.img1.h, `_TOP.ex_xfer.img1.fmt);
      if (`_TOP.sh_done)
        $display("[f5wx] SHDONE code=%02x", `_TOP.sh_done_pl.code);
      if (`_TOP.xf_done)
        $display("[f5wx] XFDONE code=%02x", `_TOP.xf_done_pl.code);
      if (`_TOP.i_xf.gen_on.xf_fault_q && !xf_ffq_q)
        $display("[f5wx] XFFAULT st=%0d xop=%0d",
                 `_TOP.i_xf.gen_on.state_q, `_TOP.i_xf.gen_on.xf_q.op);
      xf_ffq_q <= `_TOP.i_xf.gen_on.xf_fault_q;
    end

    // [f5cx]: cmdexec FSM transitions with the live record ctype —
    // shows exactly where a work record diverges from the issue path.
    logic [7:0] cx_prev_q;
    always_ff @(posedge clk_i) begin
      if (`_TOP.i_exec.gen_on.state_q != cx_prev_q)
        $display("[f5cx] st %0d->%0d ct=%02x buf=%0d rec=%0d opnd=%0d lost=%0d",
                 cx_prev_q, `_TOP.i_exec.gen_on.state_q,
                 `_TOP.i_exec.gen_on.rec_q.ctype,
                 `_TOP.i_exec.gen_on.buf_i_q,
                 `_TOP.i_exec.gen_on.rec_i_q,
                 `_TOP.i_exec.gen_on.xf_opnd_q,
                 `_TOP.i_exec.gen_on.lost_q);
      cx_prev_q <= `_TOP.i_exec.gen_on.state_q;
    end

    // [f5cr]: cmdrec appends + walk reads — which records each cbuf
    // stored and which the submit actually walked.
    always_ff @(posedge clk_i) begin
      if (`_TOP.cr_req_valid && `_TOP.cr_req_ready &&
          `_TOP.cr_req.op != 4'd6)
        $display("[f5cr] REQ op=%0d cbuf=%0d idx=%0d ct=%02x pn=%0d",
                 `_TOP.cr_req.op, `_TOP.cr_req.cbuf, `_TOP.cr_req.idx,
                 `_TOP.cr_req.rec.ctype, `_TOP.cr_req.pay_n);
      if (`_TOP.cr_cpl_valid && `_TOP.cr_cpl_ready)
        $display("[f5cr] CPL st=%0d cnt=%0d ct=%02x",
                 `_TOP.cr_cpl.status, `_TOP.cr_cpl.count,
                 `_TOP.cr_cpl.rec.ctype);
    end

    // [f5ap]: every aperture write at the vgsys mp mux (records,
    // texel fills, image stores) — the data-path ground truth.
`define _VS i_dut.gen_venus.i_vgsys.gen_on
    always_ff @(posedge clk_i) begin
      for (int p = 0; p < 5; p++)
        if (`_VS.mp_req_valid[p] && `_VS.mp_req_ready[p] &&
            `_VS.mp_req[p].we)
          $display("[f5ap] WR p%0d dom=%0d a=%08x d=%x s=%02x", p,
                   `_VS.mp_req[p].dom, `_VS.mp_req[p].addr,
                   `_VS.mp_req[p].wdata, `_VS.mp_req[p].wstrb);
    end

    // 3d-d debug: [f5ot2] taps the arbitrated ObjTab port — every
    // requester (pump/exec/ctl/dbg/sh) — incl. the record-handle
    // READSLOTs and relocation SCAN_OVL/SETAUX ops; [reloc+] reports
    // the vgctl relocation bases and each squatter eviction.
`define _VC i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_ctl.gen_on
    logic [5:0] vc_st_q = '0;
    always_ff @(posedge clk_i) begin
      if (`_TOP.ot_req_valid && `_TOP.ot_req_ready)
        $display("[f5ot2] req who=%0d op=%0d id=%016x knd=%0d off=%x sz=%x msk=%x val=%x mid=%x",
                 `_TOP.ot_grant_pump ? 1 : `_TOP.ot_grant_exec ? 2 :
                 `_TOP.ot_grant_ctl ? 3 : `_TOP.ot_grant_dbg ? 4 : 5,
                 `_TOP.ot_req.op, `_TOP.ot_req.id, `_TOP.ot_req.kind,
                 `_TOP.ot_req.offset, `_TOP.ot_req.size,
                 `_TOP.ot_req.mask, `_TOP.ot_req.value,
                 `_TOP.ot_req.mem_id);
      if (`_TOP.ot_cpl_valid && `_TOP.ot_cpl_ready)
        $display("[f5ot2] cpl og=%0d st=%0d hnd=%08x live=%0d knd=%0d gen=%x sz=%x aux=%x bm=%x",
                 `_TOP.og_q,
                 `_TOP.ot_cpl.status, `_TOP.ot_cpl.handle,
                 `_TOP.ot_cpl.entry.live, `_TOP.ot_cpl.entry.kind,
                 `_TOP.ot_cpl.entry.gen, `_TOP.ot_cpl.entry.size,
                 `_TOP.ot_cpl.entry.aux, `_TOP.ot_cpl.entry.bind_mem);
      if (`_VC.state_q != vc_st_q) begin
        if (`_VC.state_q == 6'd28)   // StMapDrain
          $display("[reloc+] begin K=%x S=%x B=%08x hold=%0d",
                   `_VC.req_ram[8], `_VC.map_size_q,
                   `_VC.map_oldb_q, `_VC.drain_idle_i);
        if (`_VC.state_q == 6'd31)   // StMapEvMv
          $display("[reloc+] evict h=%08x %08x->%08x sz=%x",
                   `_VC.ovl_h_q, `_VC.ovl_base_q,
                   `_VC.ovl_newb_q, `_VC.ovl_size_q);
        // the mover regs load inside StMapEvMv/StMapMv — print on the
        // transition into StMvRd when they hold this move's values
        if (`_VC.state_q == 6'd40 &&
            (vc_st_q == 6'd31 || vc_st_q == 6'd35))
          $display("[reloc+] move %08x->%08x len=%x",
                   `_VC.mv_src_q, `_VC.mv_dst_q, `_VC.mv_len_q);
        if (`_VC.state_q == 6'd39)   // StMapMvFail
          $display("[reloc+] MVFAIL");
      end
      vc_st_q <= `_VC.state_q;
    end
`endif

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
        8'd6:    dbg_rdata_o = 64'(vgp_used);
        8'd7:    dbg_rdata_o = 64'(|pay_free);   // 0 = chunks drained
        // §12.3 3d-d: cumulative DEVBACKED relocation hold cycles
        8'd8:    dbg_rdata_o = 64'(vc_reloc);
        // F5 bring-up: vnfront descriptor-path state taps
        8'd32:   dbg_rdata_o = {24'h0, fr_state, fr_result};
        8'd33:   dbg_rdata_o = {32'h0, fr_cmd};
        8'd34:   dbg_rdata_o = {32'h0, fr_imm0};
        8'd35:   dbg_rdata_o = {32'h0, fr_imm1};
        8'd36:   dbg_rdata_o = {16'h0, fr_flags, fr_upd_i, fr_ent_j};
        8'd37:   dbg_rdata_o = {12'h0, fr_rw_b, fr_rw_t, fr_rw_c,
                              fr_rw_o};
        8'd38:   dbg_rdata_o = {32'h0, fr_rec};
        8'd39:   dbg_rdata_o = {fr_arr, fr_dcnt, fr_dstb, fr_utyp};
        8'd40:   dbg_rdata_o = {7'h0, fr_sbyt, fr_ndyn, fr_sbase};
        8'd42:   dbg_rdata_o = fr_udst;
        8'd43:   dbg_rdata_o = fr_ubuf;
        8'd44:   dbg_rdata_o = {39'h0, fr_rsvb};
        8'd45:   dbg_rdata_o = {16'h0, fr_rsvp, fr_rsvl, fr_rsve};
        8'd46:   dbg_rdata_o = {32'h0, fr_eb};
        8'd47:   dbg_rdata_o = {32'h0, fr_esz};
        // graphics-path wedge taps
        8'd48:   dbg_rdata_o = {32'h0, ra_ret, ra_fret, ra_st, sh_hs};
        8'd49:   dbg_rdata_o = ra_ctx;
        8'd50:   dbg_rdata_o = ra_cur;
        8'd51:   dbg_rdata_o = {56'h0, ra_hs};
        8'd52:   dbg_rdata_o = {48'h0, ex_st};
        8'd53:   dbg_rdata_o = {56'h0, wv_st};
        8'd54:   dbg_rdata_o = {56'h0, wv_ret};
        8'd55:   dbg_rdata_o = {48'h0, vg_int, vg_st};
        8'd56:   dbg_rdata_o = {40'h0, pu_pol, pu_st, eng_b};
        8'd57:   dbg_rdata_o = {56'h0, mp_os};
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
