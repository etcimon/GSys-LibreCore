// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps
// §6c-ii / F1 g6lc_apu_sys Venus bench: the SoC-facing wrapper with
// ApuCfg = ApuVenus — the stock virtio-mmio/virtio-gpu probe register
// for register, then the vn_golden guest-script tapes replayed through
// real split virtqueues.  The doorbell is QUEUE_NOTIFY over AXI-Lite;
// completion is observed as guest_irq_o -> INTERRUPT_STATUS ->
// INTERRUPT_ACK, with the used-ring image checked in guest memory.
// Queue 0 (num=64) is the control queue; queue 1 (num=16) the cursor
// queue, both in the guest window (0x8000_0000, 1 MiB); the aperture
// window is APU_SHM_BASE..+1 MiB — advertised as SHM id 1.  A
// single-beat AXI4 slave model backs both windows with the same
// always-on invariants as tb_g6lc_apu_vgsys (in-window, <=1
// outstanding, channel balance).
//
// Arms (+vec=): the transport/compute session tapes, dev_reset
// (STATUS<-0 mid-session then a full re-probe), q_reset (the RING_RESET
// protocol mid-walk), venusoff (ApuP1Transport fixture), worksink0
// (non-dispatch refuse -> DEVICE_LOST), legality (cfg split checks).
// Tape ops identical to tb_g6lc_apu_vgsys (see its header).

module g6lc_apu_sys_venus_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter apu_cfg_t ApuCfg = ApuVenus) (
  input logic clk_i, rst_ni, testmode_i,
  input apu_axi_req_t guest_req_i,
  output apu_axi_resp_t guest_rsp_o,
  input apu_axi_req_t control_req_i,
  output apu_axi_resp_t control_rsp_o,
  input logic control_aw_authorized_i, control_ar_authorized_i,
  output logic guest_irq_o, control_irq_o,
  output apu_vq_state_t vq_state_o [APU_NUM_QUEUES],
  output logic [APU_NUM_QUEUES-1:0] queue_enable_o,
  output logic backend_reset_req_o,
  output logic [APU_NUM_QUEUES-1:0] backend_queue_stop_req_o,
  output logic used_ready_o,
  output logic bus_fault_o,
  output apu_dma_axi_req_t dma_req_o,
  input apu_dma_axi_resp_t dma_rsp_i
);
  function automatic config_pkg::cva6_cfg_t venus_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
  g6lc_apu_sys #(
    .ApuCfg(ApuCfg), .CoreCfg(venus_core())
 ) i_dut (
    .clk_i, .rst_ni, .testmode_i,
    .guest_req_i, .guest_rsp_o, .control_req_i, .control_rsp_o,
    .control_aw_authorized_i, .control_ar_authorized_i,
    .guest_irq_o, .control_irq_o, .vq_state_o, .queue_enable_o,
    .backend_reset_req_o, .backend_queue_stop_req_o,
    // transport fixture: the "backend" is always reset-done + idle —
    // g6lc_apu_control's reset_ack_o needs both before it releases the
    // guest side after STATUS<-0 (Venus ignores these inputs).
    .backend_reset_done_i(1'b1), .backend_idle_i('1),
    .used_valid_i(1'b0), .used_qid_i('0), .used_context_i('0),
    .used_fence_i('0), .used_len_i('0), .used_ready_o,
    .cfg_display_event_i(1'b0), .bus_fault_o,
    .dma_req_o, .dma_rsp_i,
    .guest_hold_i(1'b0), .guest_epoch_i('0), .ctrl_hold_i(1'b0),
    .ctrl_epoch_i('0), .epoch_o()
 );
endmodule

module tb_g6lc_apu_sys_venus;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vnfront_pkg::*;

  localparam logic [63:0] GB     = 64'h8000_0000;   // guest window
  localparam int unsigned GBW    = 32'h40000;       // 1 MiB / 4 B
  localparam logic [63:0] AB     = APU_SHM_BASE;    // aperture window
  localparam int unsigned ABW    = 32'h40000;    // dense 1 MiB model
                                                   // of the 32 MiB window
  // first-fit keeps every session low; an index past the dense model
  // is a tape/model bug — never wrap
  function automatic int unsigned apix(input int unsigned w);
    if (w >= ABW) $fatal(1, "aperture word %0d past dense model", w);
    return w;
  endfunction
  localparam int unsigned TAPEW  = 32'h20000;
  localparam int unsigned EXPW   = 32'h40000;
  localparam int unsigned MAXCYC = 20_000_000;

  // virtqueue layout inside the guest window (well clear of the tape
  // regions at 0x4000 / 0x10000+)
  localparam logic [31:0] Q0D = 32'h80000, Q0A = 32'h81000,
                          Q0U = 32'h82000;
  localparam logic [31:0] Q1D = 32'h83000, Q1A = 32'h84000,
                          Q1U = 32'h85000;
  localparam int unsigned Q0N = 64, Q1N = 16;
  localparam logic [15:0] VF_NEXT = 16'h1, VF_WRITE = 16'h2;
  localparam logic [31:0] LOST    = APU_VK_ERROR_DEVICE_LOST;

  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  // ---- DUT signals ----------------------------------------------------
  apu_axi_req_t  g_req, o_greq, c_req;
  apu_axi_resp_t g_rsp, o_grsp, c_rsp;
  logic          girq, cirq, bfault;
  apu_vq_state_t vq [APU_NUM_QUEUES];
  logic [APU_NUM_QUEUES-1:0] qen, stop_req;
  logic          reset_req, used_rdy;
  apu_dma_axi_req_t  areq;
  apu_dma_axi_resp_t arsp;

  g6lc_apu_sys_venus_fixture #(.ApuCfg(ApuVenus)) i_venus (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b1),
    .guest_req_i(g_req), .guest_rsp_o(g_rsp),
    .control_req_i(c_req), .control_rsp_o(c_rsp),
    .control_aw_authorized_i(1'b1), .control_ar_authorized_i(1'b1),
    .guest_irq_o(girq), .control_irq_o(cirq),
    .vq_state_o(vq), .queue_enable_o(qen),
    .backend_reset_req_o(reset_req), .backend_queue_stop_req_o(stop_req),
    .used_ready_o(used_rdy), .bus_fault_o(bfault),
    .dma_req_o(areq), .dma_rsp_i(arsp));

  // VenusOff fixture: ApuP1Transport — the transport-only path, with
  // the firmware hart + RAM pairing every existing APU bench assigns
  // (apu_cfg_legal requires the RAM once a hart is named).  Its DMA
  // port must stay silent; its irq must stay low.
  function automatic apu_cfg_t venus_off_cfg();
    apu_cfg_t cfg = ApuP1Transport;
    cfg.FirmwareHart     = 1;
    cfg.FirmwareRamBase  = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction

  // F1 legality spot-checks — ApuVenus legal, three mutations + the
  // legacy bad-grant package illegal (there is no dedicated cfg-legality
  // TB; these run at time 0 alongside the per-module asserts).
  function automatic apu_cfg_t venus_patch(input logic [31:0] hart,
                                           input int unsigned ncap,
                                           input longint unsigned wbytes);
    apu_cfg_t c = ApuVenus;
    c.FirmwareHart   = hart;
    c.NumCapsets     = ncap;
    c.DmaWindowBytes = wbytes;
    return c;
  endfunction
  initial begin
    assert (apu_cfg_legal(ApuVenus))
      else $fatal(1, "APU Venus: ApuVenus must be legal");
    assert (!apu_cfg_legal(venus_patch(32'd1, 1, 64'h1000_0000)))
      else $fatal(1, "APU Venus: VenusEn+hart must be illegal");
    assert (!apu_cfg_legal(venus_patch(APU_FW_HART_UNASSIGNED, 2, 64'h1000_0000)))
      else $fatal(1, "APU Venus: VenusEn+NumCapsets=2 must be illegal");
    assert (!apu_cfg_legal(venus_patch(APU_FW_HART_UNASSIGNED, 1, 64'h0)))
      else $fatal(1, "APU Venus: VenusEn+DmaWindowBytes=0 must be illegal");
    assert (!apu_cfg_legal(ApuBadVirglGrant))
      else $fatal(1, "APU Venus: ApuBadVirglGrant must stay illegal");
  end

  logic          o_girq, o_cirq, o_bf, o_rreq, o_urdy;
  apu_vq_state_t o_vq [APU_NUM_QUEUES];
  logic [APU_NUM_QUEUES-1:0] o_qen, o_sreq;
  apu_dma_axi_req_t o_areq;
  apu_axi_req_t  oc_req;
  apu_axi_resp_t oc_rsp;

  g6lc_apu_sys_venus_fixture #(.ApuCfg(venus_off_cfg())) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b1),
    .guest_req_i(o_greq), .guest_rsp_o(o_grsp),
    .control_req_i(oc_req), .control_rsp_o(oc_rsp),
    .control_aw_authorized_i(1'b1), .control_ar_authorized_i(1'b1),
    .guest_irq_o(o_girq), .control_irq_o(o_cirq),
    .vq_state_o(o_vq), .queue_enable_o(o_qen),
    .backend_reset_req_o(o_rreq), .backend_queue_stop_req_o(o_sreq),
    .used_ready_o(o_urdy), .bus_fault_o(o_bf),
    .dma_req_o(o_areq), .dma_rsp_i('0));

  // ---- hierarchical observability (Venus instance only) --------------
  wire        vg_idle   = i_venus.i_dut.gen_venus.vg_idle;
  wire [31:0] fcnt      = i_venus.i_dut.gen_venus.i_vgsys.fault_cnt_o;
  wire        vg_rdone  = i_venus.i_dut.gen_venus.i_vgsys.reset_done_o;
  wire        f_pulse   = i_venus.i_dut.gen_venus.i_vgsys.fence_pulse_o;
  wire [63:0] f_id      = i_venus.i_dut.gen_venus.i_vgsys.fence_id_o;
  wire [7:0]  f_ring    = i_venus.i_dut.gen_venus.i_vgsys.fence_ring_o;
  wire [15:0] ot_live   = i_venus.i_dut.gen_venus.i_vgsys.objtab_live_o;
  wire        wch_v     = i_venus.i_dut.gen_venus.i_vgsys.gen_on.vw_chain_v;
  wire        wch_r     = i_venus.i_dut.gen_venus.i_vgsys.gen_on.vw_chain_rdy;
  wire [15:0] flost     =
      i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_exec.gen_on.flost_q;
  wire [3:0][31:0] r_status = i_venus.i_dut.gen_venus.i_vgsys.ring_status_o;
  wire [3:0][31:0] r_head   = i_venus.i_dut.gen_venus.i_vgsys.ring_head_o;
  wire [3:0][APU_VG_AP_WORD_W-1:0] r_extra  = i_venus.i_dut.gen_venus.i_vgsys.ring_extra_w_o;

  // ---- tape / expected stores ------------------------------------------
  logic [31:0] tape [TAPEW];
  logic [31:0] expm [EXPW];
  int unsigned tp, ep;

  // ---- guest RAM + aperture backing stores ------------------------------
  logic [31:0] gmem [GBW];   // gmem[off>>2] <-> GB+off
  logic [31:0] apm  [ABW];   // apm[apix(off>>2)]  <-> AB+off

  // ---- AXI4 slave model (burst reads, <=3 outstanding) ----------------
  // Any AW/AR outside the two windows is an immediate test failure.
  // Since 5a the joined master carries apmem + Xfer through tdma; tdma
  // grants one owner while it has outstanding traffic, so the wire can
  // see at most one read burst plus one write transaction in flight —
  // the global bound assert is 3 (apmem 1 + xfer read 1 + xfer write 1).
  logic        r_act, r_vld, aw_s, w_s, b_vld;
  int unsigned wlog;
  initial wlog = $value$plusargs("wlog=%d", wlog);
  logic [63:0] r_addr;
  logic [2:0]  r_size;
  int unsigned r_rem;
  apu_dma_axi_r_chan_t  rch;
  apu_dma_axi_aw_chan_t waw;
  apu_dma_axi_w_chan_t  ww;
  logic [63:0] b_log [4096];
  int unsigned b_n = 0;
  int unsigned oob_ap = 0;
  int unsigned post_rst_axi = 0;
  // always-on invariants: at most three outstanding transactions on
  // the master (apmem 1 + xfer read 1 + xfer write 1; tdma's owner
  // lock makes the achievable peak 2), channel balance
  int unsigned aw_n = 0, w_n = 0, ar_n = 0, r_n = 0, ar_beats = 0;
  int unsigned outst = 0;
  logic        wr_pend = 0, rd_pend = 0;
  // off-fixture DMA must stay silent
  int unsigned off_beats = 0;

  function automatic logic [7:0] rd8(input logic [63:0] a);
    logic [63:0] o;
    if (a >= GB && a < GB + 64'h100000) begin
      o = a - GB;
      return gmem[32'(o >> 2)][8*(o & 3) +: 8];
    end
    o = a - AB;
    return apm[apix(32'(o >> 2))][8*(o & 3) +: 8];
  endfunction

  task automatic wr8(input logic [63:0] a, input logic [7:0] d);
    logic [63:0] o;
    if (a >= GB && a < GB + 64'h100000) begin
      o = a - GB;
      gmem[32'(o >> 2)][8*(o & 3) +: 8] <= d;
    end else begin
      o = a - AB;
      apm[apix(32'(o >> 2))][8*(o & 3) +: 8] <= d;
    end
  endtask

  task automatic win_check(input logic [63:0] a, input string tag);
    if (!((a >= GB && a < GB + 64'h100000) ||
          (a >= AB && a < AB + APU_VG_SHM_BYTES)))
      $fatal(1, "AXI %s address %016x outside both windows", tag, a);
  endtask

  always_comb begin
    arsp = '0;
    arsp.ar_ready = !r_act && !r_vld;
    arsp.r_valid  = r_vld;
    arsp.r        = rch;
    arsp.aw_ready = !aw_s && !b_vld;
    arsp.w_ready  = !w_s && !b_vld;
    arsp.b_valid  = b_vld;
    // dma_write drives aw.id=1 and checks b.id==1; echo that id
    arsp.b        = '{id: 4'd1, resp: axi_pkg::RESP_OKAY, user: '0};
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_act <= 0; r_vld <= 0; r_addr <= '0; rch <= '0;
      aw_s <= 0; w_s <= 0; b_vld <= 0; waw <= '0; ww <= '0;
      wr_pend <= 0; rd_pend <= 0;
    end else begin
      if (areq.ar_valid && arsp.ar_ready) begin
        win_check(areq.ar.addr, "AR");
        if (areq.ar.burst != axi_pkg::BURST_INCR)
          $fatal(1, "AXI: non-INCR read burst");
        rd_pend <= 1;
        ar_n++;
        ar_beats += int'(areq.ar.len) + 1;
        r_act  <= 1;
        r_addr <= areq.ar.addr;
        r_size <= areq.ar.size;
        r_rem  <= int'(areq.ar.len) + 1;
        outst++;
        if (outst > 3)
          $fatal(1, "AXI: outstanding bound %0d > 3", outst);
        if (vg_rdone) post_rst_axi++;
      end
      if (r_act && !r_vld) begin
        r_vld <= 1;
        rch   <= '0;
        rch.last <= r_rem == 1;
        for (int b = 0; b < 8; b++)
          rch.data[8*b +: 8] <= rd8((r_addr & ~64'h7) + 64'(b));
      end
      if (r_vld && areq.r_ready) begin
        r_n++;
        r_vld <= 0;
        r_addr <= r_addr + (64'd1 << r_size);
        if (r_rem <= 1) begin
          r_act <= 0; rd_pend <= 0; outst--;
        end else r_rem <= r_rem - 1;
      end
      if (areq.aw_valid && arsp.aw_ready) begin
        win_check(areq.aw.addr, "AW");
        if (areq.aw.len != 0)
          $fatal(1, "AXI: write burst len %0d (engines are narrow)",
                 areq.aw.len);
        wr_pend <= 1;
        aw_n++;
        aw_s <= 1; waw <= areq.aw;
        outst++;
        if (outst > 3)
          $fatal(1, "AXI: outstanding bound %0d > 3", outst);
        if (vg_rdone) post_rst_axi++;
      end
      if (areq.w_valid && arsp.w_ready) begin
        if (!areq.w.last)
          $fatal(1, "AXI: multi-beat write");
        w_n++;
        w_s <= 1; ww <= areq.w;
      end
      if (aw_s && w_s && !b_vld) begin
        // strb lanes are absolute within aw.addr & ~7 (narrow writes)
        for (int b = 0; b < 8; b++)
          if (ww.strb[b])
            wr8((waw.addr & ~64'h7) + 64'(b), ww.data[8*b +: 8]);
        b_vld <= 1;
      end
      if (b_vld && areq.b_ready) begin
        wr_pend <= 0;
        b_vld <= 0; aw_s <= 0; w_s <= 0;
        b_log[b_n % 4096] <= waw.addr;
        b_n++;
        outst--;
        if (wlog && b_n < 80)
          $display("WBEAT %016x data=%016x strb=%02x", waw.addr,
                   ww.data, ww.strb);
      end
    end
  end

  // VenusOff DMA activity counter
  always @(posedge clk) begin
    if (o_areq.aw_valid || o_areq.w_valid || o_areq.ar_valid) off_beats++;
    if (|o_areq) off_beats++;
  end

  // balance check (bounded settle for a legitimately in-flight beat)
  task automatic check_axi_bal();
    int unsigned t = 0;
    while ((aw_n != w_n || w_n != b_n || ar_beats != r_n) &&
           t < 2_000_000) begin
      @(posedge clk); t++;
    end
    check(aw_n == w_n && w_n == b_n,
          $sformatf("AXI write balance aw=%0d w=%0d b=%0d",
                    aw_n, w_n, b_n));
    check(ar_beats == r_n,
          $sformatf("AXI read balance beats=%0d r=%0d",
                    ar_beats, r_n));
  endtask

  // ---- fence / used observability --------------------------------------
  int unsigned f_count = 0;
  logic [63:0] f_seen_id;
  logic [7:0]  f_seen_ring;
  int unsigned pubs = 0;               // used IRQs observed
  int unsigned stop_seen[2];
  logic        ws0_lost = 0;
  always @(posedge clk or negedge rst_ni)
    if (!rst_ni) begin
      f_count <= 0; f_seen_id <= '0; f_seen_ring <= '0;
      pubs <= 0; stop_seen[0] <= 0; stop_seen[1] <= 0;
      ws0_lost <= 0;
    end else begin
      if (f_pulse) begin
        f_count <= f_count + 1; f_seen_id <= f_id; f_seen_ring <= f_ring;
      end
      if (stop_req[0]) stop_seen[0] <= stop_seen[0] + 1;
      if (stop_req[1]) stop_seen[1] <= stop_seen[1] + 1;
      if (|flost) ws0_lost <= 1'b1;
    end

  logic chain_seen = 0;
  always @(posedge clk)
    if (wch_v && wch_r) chain_seen <= 1'b1;

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) begin
    // VenusOff fixture: DMA port silent, no bus fault. (o_cirq may
    // legitimately pulse — in the firmware path a guest doorbell
    // interrupts the service hart through fw_irq.)
    if ((|o_areq) || o_bf)
      $fatal(1, "transport-only sys driving backend signals");
    if (cycles > MAXCYC) begin
      $display("STALL tp=%0d ep=%0d cases=%0d pend=%0d/%0d",
               tp, ep, cases, pend_n, pend_c);
      $display("STALL axi outst=%0d r_act=%0d r_rem=%0d aw_s=%0d w_s=%0d b_vld=%0d girq=%0d vg_idle=%0d",
               outst, r_act, r_rem, aw_s, w_s, b_vld, girq, vg_idle);
      $display("STALL cnt aw_n=%0d w_n=%0d b_n=%0d ar_n=%0d r_n=%0d",
               aw_n, w_n, b_n, ar_n, r_n);
      $display("STALL chan awv=%0d wv=%0d arv=%0d rr=%0d br=%0d",
               areq.aw_valid, areq.w_valid, areq.ar_valid,
               areq.r_ready, areq.b_ready);
      $display("STALL xf st=%0d busy=%0d exw_v=%0d xfrdy=%0d crv=%0d crrdy=%0d crcv=%0d",
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.state_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.xfer_busy,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.ex_work_v,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.xf_work_rdy,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.xf_cr_v,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.xf_cr_rdy,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on
          .xf_cr_cpl_rdy);
      $display("STALL ex_st=%0d wsv=%0d",
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_exec
          .gen_on.state_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.ws_v);
      $display("STALL legs fn=%0d rdis=%0d rddone=%0d wris=%0d wrdone=%0d fault=%0d upv=%0d vi=%0d ei=%0d rem=%0d csent=%0d csz=%0d",
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.fn_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.rd_iss_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.rd_done_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.wr_iss_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.wr_done_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.xf_fault_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.up_v_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.vi_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.ei_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.rem_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.csent_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.csz_q);
      $display("STALL legs rd_st=%0d wr_st=%0d rd_dv=%0d rd_dr=%0d wr_dv=%0d wr_dr=%0d rd_cpl=%0d wr_cpl=%0d",
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.i_rd.gen_on.state_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.i_wr.gen_on.state_q,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.rd_dv,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.rd_dr,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.wr_dv,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.wr_dr,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.rd_cpl_v,
        i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_xf
          .gen_on.wr_cpl_v);
      $fatal(1, "watchdog");
    end
  end

  // ---- helpers -----------------------------------------------------------
  function automatic logic [31:0] nexp();
    nexp = expm[ep]; ep++;
  endfunction
  function automatic logic [31:0] ntap();
    ntap = tape[tp]; tp++;
  endfunction
  function automatic int rec_kind();
    if (ep + 1 < EXPW && expm[ep] == 32'hFFFFFFFF &&
        expm[ep + 1] == 32'hFFFFFFFF)
      return 0;
    return expm[ep];
  endfunction
  task automatic check(input bit ok, input string msg);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL %s (t=%0d)", msg, cycles);
      if (errors > 40) $fatal(1, "too many errors");
    end
  endtask

  // guest-window word access by byte offset (off = phys - GB)
  task automatic gw(input logic [31:0] off, input logic [31:0] v);
    gmem[off >> 2] = v;
  endtask
  function automatic logic [31:0] gr(input logic [31:0] off);
    return gmem[off >> 2];
  endfunction
  task automatic gh(input logic [31:0] off, input logic [15:0] v);
    if (off[1]) gmem[off >> 2][31:16] = v;
    else        gmem[off >> 2][15:0]  = v;
  endtask
  function automatic logic [15:0] grh(input logic [31:0] off);
    return off[1] ? gmem[off >> 2][31:16] : gmem[off >> 2][15:0];
  endfunction

  // ---- AXI-Lite master (guest window, port g_req/g_rsp) -------------------
  task automatic send_write(input int p, input logic [63:0] a,
                            input logic [31:0] d);
    bit aw_done, w_done;
    aw_done = 0; w_done = 0;
    @(negedge clk);
    if (p == 0) begin
      g_req.aw.addr = a; g_req.aw.prot = 3'b111;
      g_req.w.data = d; g_req.w.strb = 4'hf;
      g_req.aw_valid = 1; g_req.w_valid = 1;
    end else begin
      o_greq.aw.addr = a; o_greq.aw.prot = 3'b111;
      o_greq.w.data = d; o_greq.w.strb = 4'hf;
      o_greq.aw_valid = 1; o_greq.w_valid = 1;
    end
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (p == 0) begin
        if (g_req.aw_valid && g_rsp.aw_ready) aw_done = 1;
        if (g_req.w_valid && g_rsp.w_ready) w_done = 1;
      end else begin
        if (o_greq.aw_valid && o_grsp.aw_ready) aw_done = 1;
        if (o_greq.w_valid && o_grsp.w_ready) w_done = 1;
      end
      @(negedge clk);
      if (p == 0) begin
        if (aw_done) g_req.aw_valid = 0;
        if (w_done) g_req.w_valid = 0;
      end else begin
        if (aw_done) o_greq.aw_valid = 0;
        if (w_done) o_greq.w_valid = 0;
      end
    end
  endtask
  task automatic receive_write(input int p);
    @(posedge clk);
    if (p == 0) begin
      while (!g_rsp.b_valid) @(posedge clk);
      check(g_rsp.b.resp == 2'b00, "AXI B resp");
      @(negedge clk); g_req.b_ready = 1;
      @(posedge clk); @(negedge clk); g_req.b_ready = 0;
    end else begin
      while (!o_grsp.b_valid) @(posedge clk);
      check(o_grsp.b.resp == 2'b00, "AXI B resp (off)");
      @(negedge clk); o_greq.b_ready = 1;
      @(posedge clk); @(negedge clk); o_greq.b_ready = 0;
    end
  endtask
  task automatic write_reg(input int p, input logic [63:0] a,
                           input logic [31:0] d);
    send_write(p, a, d);
    receive_write(p);
  endtask
  task automatic send_read(input int p, input logic [63:0] a);
    @(negedge clk);
    if (p == 0) begin
      g_req.ar.addr = a; g_req.ar.prot = 3'b111; g_req.ar_valid = 1;
      @(posedge clk);
      while (!g_rsp.ar_ready) @(posedge clk);
      @(negedge clk); g_req.ar_valid = 0;
    end else begin
      o_greq.ar.addr = a; o_greq.ar.prot = 3'b111; o_greq.ar_valid = 1;
      @(posedge clk);
      while (!o_grsp.ar_ready) @(posedge clk);
      @(negedge clk); o_greq.ar_valid = 0;
    end
  endtask
  task automatic receive_read(input int p, output logic [31:0] data);
    @(posedge clk);
    if (p == 0) begin
      while (!g_rsp.r_valid) @(posedge clk);
      data = g_rsp.r.data;
      check(g_rsp.r.resp == 2'b00, "AXI R resp");
      @(negedge clk); g_req.r_ready = 1;
      @(posedge clk); @(negedge clk); g_req.r_ready = 0;
    end else begin
      while (!o_grsp.r_valid) @(posedge clk);
      data = o_grsp.r.data;
      check(o_grsp.r.resp == 2'b00, "AXI R resp (off)");
      @(negedge clk); o_greq.r_ready = 1;
      @(posedge clk); @(negedge clk); o_greq.r_ready = 0;
    end
  endtask
  task automatic read_reg(input int p, input logic [63:0] a,
                          output logic [31:0] data);
    send_read(p, a);
    receive_read(p, data);
  endtask

  // virtio-mmio register access on the Venus guest window
  task automatic vwrite(input logic [15:0] off, input logic [31:0] d);
    write_reg(0, APU_MMIO_BASE + 64'(off), d);
  endtask
  task automatic vread(input logic [15:0] off, output logic [31:0] d);
    read_reg(0, APU_MMIO_BASE + 64'(off), d);
  endtask
  // same on the transport-only fixture (port 1)
  task automatic owrite(input logic [15:0] off, input logic [31:0] d);
    write_reg(1, APU_MMIO_BASE + 64'(off), d);
  endtask
  task automatic oread(input logic [15:0] off, output logic [31:0] d);
    read_reg(1, APU_MMIO_BASE + 64'(off), d);
  endtask
  // off-fixture control window (firmware role): ctrl_hold_i is 0 so the
  // write is tagged with the current epoch automatically.
  task automatic ocwrite(input logic [63:0] a, input logic [31:0] d);
    bit aw_done, w_done;
    aw_done = 0; w_done = 0;
    @(negedge clk);
    oc_req.aw.addr = a; oc_req.aw.prot = 3'b111;
    oc_req.w.data = d; oc_req.w.strb = 4'hf;
    oc_req.aw_valid = 1; oc_req.w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (oc_req.aw_valid && oc_rsp.aw_ready) aw_done = 1;
      if (oc_req.w_valid && oc_rsp.w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) oc_req.aw_valid = 0;
      if (w_done) oc_req.w_valid = 0;
    end
    @(posedge clk);
    while (!oc_rsp.b_valid) @(posedge clk);
    @(negedge clk); oc_req.b_ready = 1;
    @(posedge clk); @(negedge clk); oc_req.b_ready = 0;
  endtask

  // ---- virtqueue geometry -------------------------------------------------
  function automatic logic [31:0] qdesc(input int q);
    return q == 0 ? Q0D : Q1D;
  endfunction
  function automatic logic [31:0] qavail(input int q);
    return q == 0 ? Q0A : Q1A;
  endfunction
  function automatic logic [31:0] qused(input int q);
    return q == 0 ? Q0U : Q1U;
  endfunction
  function automatic int unsigned qnum(input int q);
    return q == 0 ? Q0N : Q1N;
  endfunction

  int unsigned av_push[2];
  int unsigned dcur[2];
  int unsigned uexp[2];

  task automatic put_desc(input int q, input int unsigned idx,
                          input logic [63:0] addr,
                          input logic [31:0] len,
                          input logic [15:0] flags,
                          input logic [15:0] next);
    logic [31:0] b;
    b = qdesc(q) + 32'(idx) * 32'd16;
    gw(b + 0,  addr[31:0]);
    gw(b + 4,  addr[63:32]);
    gw(b + 8,  len);
    gw(b + 12, {next, flags});
  endtask

  task automatic push_avail(input int q, input int unsigned head);
    int unsigned aidx;
    aidx = av_push[q];
    gh(qavail(q) + 4 + 32'(aidx % qnum(q)) * 2, 16'(head));
    gh(qavail(q) + 2, 16'(aidx + 1));
    av_push[q] = aidx + 1;
  endtask

  // doorbell: QUEUE_NOTIFY over AXI-Lite (the virtio_mmio driver write)
  task automatic do_notify(input int q);
    vwrite(VREG_QUEUE_NOTIFY, 32'(q));
  endtask

  // used publication observed as a used-buffer IRQ: read
  // INTERRUPT_STATUS (bit0), write INTERRUPT_ACK<-1, verify the line
  // drops.  The used element itself lives in the guest ring.
  logic [31:0] u_qid_s, u_len_s;
  task automatic wait_used(input int q);
    int unsigned t;
    logic [31:0] isr;
    t = 0;
    while (!girq && t < 20_000_000) begin @(negedge clk); t++; end
    check(t < 20_000_000 && girq,
          $sformatf("used irq timeout q%0d", q));
    vread(VREG_INTERRUPT_STATUS, isr);
    check(isr[0] == 1'b1, "interrupt status used bit");
    vwrite(VREG_INTERRUPT_ACK, 32'h1);
    repeat (4) @(posedge clk);
    check(!girq, "guest irq low after interrupt_ack");
    pubs++;
    u_qid_s = 32'(q);
    u_len_s = gr(qused(q) + 8 + 32'(uexp[q] % qnum(q)) * 8);
    @(posedge clk);
  endtask

  // check the used-ring image for the latest publication on queue q
  task automatic check_used_img(input int q, input int unsigned head,
                                input logic [31:0] len);
    int unsigned pos;
    logic [31:0] ub, eid, elen, uidx;
    int          bi_elem, bi_idx;
    pos  = uexp[q];
    ub   = qused(q);
    eid  = gr(ub + 4 + 32'(pos % qnum(q)) * 8);
    elen = gr(ub + 8 + 32'(pos % qnum(q)) * 8);
    uidx = 32'(grh(ub + 2));
    check(eid == 32'(head),
          $sformatf("used elem q%0d id got=%0d exp=%0d", q, eid, head));
    check(elen == len,
          $sformatf("used elem q%0d len got=%0d exp=%0d", q, elen, len));
    check(uidx == 32'(pos + 1),
          $sformatf("used idx q%0d got=%0d exp=%0d", q, uidx, pos + 1));
    bi_elem = b_find_last(GB + ub + 8 + 64'(pos % qnum(q)) * 8);
    bi_idx  = b_find_last((GB + ub + 2) & ~64'h7);
    check(bi_idx >= 0, "used.idx B beat observed before irq");
    check(bi_elem >= 0, "used elem B beat observed");
    if (bi_elem >= 0 && bi_idx >= 0)
      check(bi_elem < bi_idx, "used elem B before used.idx B");
    uexp[q]++;
  endtask

  function automatic int b_find(input logic [63:0] a);
    for (int i = 0; i < b_n; i++)
      if (b_log[i % 4096] == a) return i;
    return -1;
  endfunction
  function automatic int b_find_last(input logic [63:0] a);
    int r;
    r = -1;
    for (int i = 0; i < b_n; i++)
      if (b_log[i % 4096] == a) r = i;
    return r;
  endfunction

  // ---- chain submit / expect -------------------------------------------
  int unsigned  pend_head[512];
  logic [63:0]  pend_raddr[512];
  int unsigned  pend_ridx[512];
  logic [63:0]  pend_fence[512];
  int unsigned  pend_flags[512];
  int unsigned  pend_n = 0, pend_c = 0;

  task automatic chain_submit();
    int unsigned nd, a0, a1, dl, dw;
    int unsigned flags, flo, fhi, cx, ridx;
    int unsigned head;
    nd = ntap();
    head = dcur[0];
    pend_raddr[pend_n] = 64'h0;
    for (int i = 0; i < nd; i++) begin
      a0 = ntap(); a1 = ntap(); dl = ntap(); dw = ntap();
      put_desc(0, (dcur[0] + i) % Q0N, GB + {32'(a1), 32'(a0)},
               32'(dl),
               (dw != 0 ? VF_WRITE : 16'h0) |
               (i + 1 < nd ? VF_NEXT : 16'h0),
               16'((dcur[0] + i + 1) % Q0N));
      if (dw != 0)
        pend_raddr[pend_n] = {32'(a1), 32'(a0)};
    end
    dcur[0] = (dcur[0] + nd) % Q0N;
    flags = ntap(); flo = ntap(); fhi = ntap(); cx = ntap(); ridx = ntap();
    pend_head[pend_n]  = head;
    pend_flags[pend_n] = flags;
    pend_fence[pend_n] = {32'(fhi), 32'(flo)};
    pend_ridx[pend_n]  = ridx;
    pend_n++;
    push_avail(0, head);
  endtask

  task automatic chain_expect();
    int unsigned head, flags, ridx;
    logic [63:0] raddr, fence;
    int unsigned t;
    head   = pend_head[pend_c];
    flags  = pend_flags[pend_c];
    raddr  = pend_raddr[pend_c];
    fence  = pend_fence[pend_c];
    ridx   = pend_ridx[pend_c];
    pend_c++;
    wait_used(0);
    // EK_RESP {kind, used_len, resp_type, nbody, 0,0,0,0}
    check(rec_kind() == 1, "EK_RESP kind");
    begin
      int unsigned e_used, e_type, e_nbody;
      ep++;
      e_used  = nexp();
      e_type  = nexp();
      e_nbody = nexp();
      ep += 4;
      check(u_len_s == 32'(e_used),
            $sformatf("used_len got=%08x exp=%08x", u_len_s, e_used));
      check(u_qid_s == 0, "used qid");
      check(gr(32'(raddr)) == e_type,
            $sformatf("resp type got=%08x exp=%08x",
                      gr(32'(raddr)), e_type));
      for (int i = 0; i < e_nbody; i++) begin
        check(rec_kind() == 2, "EK_BODY kind");
        check(gr(32'(raddr) + 32'(24 + 4 * i)) == expm[ep + 1],
              $sformatf("resp body[%0d] got=%08x exp=%08x", i,
                        gr(32'(raddr) + 32'(24 + 4 * i)), expm[ep + 1]));
        ep += 8;
      end
      check_used_img(0, head, u_len_s);
      // drain + idle
      t = 0;
      while (!vg_idle && t < 100000) begin @(posedge clk); t++; end
      check(vg_idle, "vgsys idle after completion");
      if ((flags & 1) != 0) begin
        check(rec_kind() == 8, "EK_FENCE kind");
        ep++;
        check(f_seen_id == fence && f_count != 0, "fence id match");
        check(f_seen_ring == 8'(ridx), "fence pulse seen");
        ep += 7;
      end
      cases++;
    end
  endtask

  task automatic do_chain();
    chain_submit();
    do_notify(0);
    chain_expect();
  endtask

  // ---- tape player ---------------------------------------------------------
  int tlog = 0;
  task automatic play_tape();
    tlog = $test$plusargs("tlog");
    while (1) begin
      int unsigned op = ntap();
      if (tlog) $display("[tape] op=%0d tp=%0d t=%0d", op, tp, cycles);
      if (op == 0) break;
      case (op)
        1: begin // TP_MEMW
          int unsigned n = ntap();
          int unsigned al = ntap(), ah = ntap();
          for (int i = 0; i < n; i++)
            gmem[((al >> 2) + i) % GBW] = ntap();
        end
        2: do_chain();
        3: begin // TP_APW
          int unsigned n = ntap();
          int unsigned al = ntap(), ah = ntap();
          for (int i = 0; i < n; i++)
            apm[apix(((al >> 2) + i))] = ntap();
        end
        4: begin // TP_WAIT_HEAD [ring][ap_addr][exp][tmo]
          int unsigned rg = ntap(), ad = ntap(),
                       eh = ntap(), tmo = ntap();
          int unsigned t = 0;
          while (apm[apix((ad >> 2))] != eh && t < tmo) begin
            @(posedge clk); t++;
          end
          check(apm[apix((ad >> 2))] == eh,
                $sformatf("WAIT_HEAD ring%0d ap got=%08x exp=%08x",
                          rg, apm[apix((ad >> 2))], eh));
          check(rec_kind() == 3, "EK_HEAD kind");
          check(expm[ep + 1] == rg && expm[ep + 2] == eh,
                "EK_HEAD words");
          check(r_head[rg] == eh,
                $sformatf("ring_head_o got=%08x exp=%08x",
                          r_head[rg], eh));
          ep += 8;
        end
        5: begin // TP_WAIT_IDLE [ring][ap_addr][mask][want][tmo]
          int unsigned rg = ntap(), ad = ntap(), mask = ntap(),
                       want = ntap(), tmo = ntap();
          int unsigned t = 0;
          while (((apm[apix((ad >> 2))] & mask) != want) && t < tmo)
            begin @(posedge clk); t++; end
          check((apm[apix((ad >> 2))] & mask) == want,
                $sformatf("WAIT_IDLE ring%0d status=%08x mask=%0d want=%0d",
                          rg, apm[apix((ad >> 2))], mask, want));
          check(rec_kind() == 4, "EK_STATUS kind");
          check(r_status[rg] == expm[ep + 2],
                $sformatf("ring_status_o got=%08x exp=%08x",
                          r_status[rg], expm[ep + 2]));
          check(apm[apix((ad >> 2))] == expm[ep + 2],
                "aperture status == exp");
          ep += 8;
        end
        6: begin // TP_CHECK
          int unsigned what = ntap(), a0 = ntap(), a1 = ntap();
          case (what)
            0: begin // CK_HEAD
              check(rec_kind() == 3, "EK_HEAD kind");
              check(r_head[a0] == expm[ep + 2],
                    $sformatf("CK_HEAD ring%0d got=%08x exp=%08x",
                              a0, r_head[a0], expm[ep + 2]));
              ep += 8;
            end
            1: begin // CK_STATUS
              check(rec_kind() == 4, "EK_STATUS kind");
              check(r_status[a0] == expm[ep + 2],
                    $sformatf("CK_STATUS ring%0d got=%08x exp=%08x",
                              a0, r_status[a0], expm[ep + 2]));
              ep += 8;
            end
            2: begin // CK_REPLY [nwords][ap byte off]
              int unsigned bad = 0;
              for (int i = 0; i < a0; i++) begin
                check(rec_kind() == 5, "EK_REPLY kind");
                check(apm[((a1 >> 2) + expm[ep + 1])] == expm[ep + 2],
                      $sformatf("CK_REPLY off=%0x idx=%0d got=%08x exp=%08x",
                                a1, expm[ep + 1],
                                apm[((a1 >> 2) + expm[ep + 1])],
                                expm[ep + 2]));
                ep += 8;
              end
            end
            3: begin // CK_LIVE (+ EK_PAGES)
              check(rec_kind() == 6, "EK_LIVE kind");
              check(ot_live == 16'(expm[ep + 1]),
                    $sformatf("CK_LIVE got=%0d exp=%0d",
                              ot_live, expm[ep + 1]));
              ep += 8;
              check(rec_kind() == 11, "EK_PAGES kind");
              check($countones(i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top
                               .gen_on.i_vgp.gen_on.free_q)
                    == int'(expm[ep + 1]),
                    $sformatf("CK_PAGES got=%0d exp=%0d",
                              $countones(i_venus.i_dut.gen_venus.i_vgsys
                                .gen_on.i_top.gen_on.i_vgp.gen_on.free_q),
                              expm[ep + 1]));
              ep += 8;
            end
            4: begin // CK_EXTRA [ring][byte off]
              check(rec_kind() == 7, "EK_EXTRA kind");
              check(apm[(r_extra[a0] + (a1 >> 2))] == expm[ep + 3],
                    $sformatf("CK_EXTRA ring%0d off=%0x got=%08x exp=%08x",
                              a0, a1,
                              apm[(r_extra[a0] + (a1 >> 2))],
                              expm[ep + 3]));
              ep += 8;
            end
            6: begin // CK_APR [nwords][ap byte off]
              for (int i = 0; i < a0; i++) begin
                automatic logic [31:0] got =
                    apm[apix(((a1 >> 2) + i))];
                automatic int unsigned u;
                check(rec_kind() == 10, "EK_APRCHK kind");
                check(expm[ep + 1] == a1 + 4 * i, "EK_APRCHK offset");
                g1_n++;
                if (got != expm[ep + 2]) g1_bad++;
                check(got == expm[ep + 2],
                      $sformatf("G1 off=%0x got=%08x exp=%08x",
                                a1 + 4 * i, got, expm[ep + 2]));
                g2_n++;
                if (expm[ep + 4] == 0) begin
                  check(got == expm[ep + 3],
                        $sformatf("G2i off=%0x got=%08x exp=%08x",
                                  a1 + 4 * i, got, expm[ep + 3]));
                end else begin
                  u = ulpd(got, expm[ep + 3]);
                  if (u == 1) ulp1++;
                  else if (u == 2) ulp2++;
                  if (u > maxulp && u != 32'h7FFF_FFFF) maxulp = u;
                  if (u == 32'h7FFF_FFFF) maxulp = 32'h7FFF_FFFF;
                  check(u <= 2,
                        $sformatf("G2f off=%0x got=%08x exp=%08x ulp=%0d",
                                  a1 + 4 * i, got, expm[ep + 3], u));
                end
                ep += 8;
              end
            end
            default: $fatal(1, "unknown CHECK %0d", what);
          endcase
        end
        7: begin // TP_DELAY
          int unsigned n = ntap();
          repeat (n) @(posedge clk);
        end
        default: $fatal(1, "unknown tape op %0d", op);
      endcase
    end
    // teardown
    check(i_venus.i_dut.gen_venus.i_vgsys.gen_on.i_top.gen_on.i_pay.gen_on
          .free_q === '0,
          "objpay chunks drained");
  endtask

  function automatic int unsigned ulpd(input logic [31:0] a,
                                       input logic [31:0] b);
    logic [31:0] d;
    begin
      if (a === b) return 0;
      if ((a & 32'h7FFF_FFFF) == 0 && (b & 32'h7FFF_FFFF) == 0) return 0;
      if (a[30:23] == 8'hFF && a[22:0] != 0 &&
          b[30:23] == 8'hFF && b[22:0] != 0) return 0;
      if (a[31] != b[31]) return 32'h7FFF_FFFF;
      d = (a > b) ? a - b : b - a;
      return int'(d);
    end
  endfunction

  int unsigned g1_n = 0, g1_bad = 0, g2_n = 0;
  int unsigned ulp1 = 0, ulp2 = 0, maxulp = 0;

  // ---- queue init ---------------------------------------------------------
  task automatic vq_init();
    for (int i = 0; i < GBW; i++) gmem[i] = '0;
    for (int i = 0; i < ABW; i++) apm[i] = '0;
    av_push[0] = 0; av_push[1] = 0;
    dcur[0] = 0;    dcur[1] = 0;
    uexp[0] = 0;    uexp[1] = 0;
    pend_n = 0; pend_c = 0;
  endtask

  // ---- virtio-mmio probe: the stock virtio_mmio + virtio_gpu sequence -----
  // venus=1 expects the F1 feature split (VIRGL/BLOB/CTX_INIT,
  // capset 1, SHM id 1); venus=0 the transport-only profile.
  task automatic queue_setup(input int p, input int q,
                             input int unsigned num,
                             input logic [63:0] d,
                             input logic [63:0] a,
                             input logic [63:0] u);
    logic [31:0] r;
    if (p == 0) begin
      vwrite(VREG_QUEUE_SEL, 32'(q));
      vread(VREG_QUEUE_NUM_MAX, r);
      check(r >= num,
            $sformatf("queue%0d num_max got=%0d exp>=%0d", q, r, num));
      vwrite(VREG_QUEUE_NUM, 32'(num));
      vwrite(VREG_QUEUE_DESC_LO,  d[31:0]);
      vwrite(VREG_QUEUE_DESC_HI,  d[63:32]);
      vwrite(VREG_QUEUE_AVAIL_LO, a[31:0]);
      vwrite(VREG_QUEUE_AVAIL_HI, a[63:32]);
      vwrite(VREG_QUEUE_USED_LO,  u[31:0]);
      vwrite(VREG_QUEUE_USED_HI,  u[63:32]);
      vwrite(VREG_QUEUE_READY, 32'h1);
    end else begin
      owrite(VREG_QUEUE_SEL, 32'(q));
      oread(VREG_QUEUE_NUM_MAX, r);
      check(r >= num,
            $sformatf("off queue%0d num_max got=%0d exp>=%0d", q, r, num));
      owrite(VREG_QUEUE_NUM, 32'(num));
      owrite(VREG_QUEUE_DESC_LO,  d[31:0]);
      owrite(VREG_QUEUE_DESC_HI,  d[63:32]);
      owrite(VREG_QUEUE_AVAIL_LO, a[31:0]);
      owrite(VREG_QUEUE_AVAIL_HI, a[63:32]);
      owrite(VREG_QUEUE_USED_LO,  u[31:0]);
      owrite(VREG_QUEUE_USED_HI,  u[63:32]);
      owrite(VREG_QUEUE_READY, 32'h1);
    end
  endtask

  task automatic virtio_probe(input int p, input bit venus);
    logic [31:0] r, flo, fhi;
    int unsigned t;
    if (p == 0) begin
      vread(VREG_MAGIC, r);
      check(r == VIRTIO_MMIO_MAGIC, "probe magic");
      vread(VREG_VERSION, r);
      check(r == VIRTIO_MMIO_VERSION2, "virtio version 2");
      vread(VREG_DEVICE_ID, r);
      check(r == VIRTIO_DEVICE_GPU, "device id gpu");
      vread(VREG_VENDOR_ID, r);
      check(r == G6LC_VIRTIO_VENDOR, "vendor id");
      vwrite(VREG_STATUS, 32'h0);
      vwrite(VREG_STATUS, 32'(VSTATUS_ACKNOWLEDGE));
      vwrite(VREG_STATUS, 32'(VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER));
      vwrite(VREG_DEVICE_FEAT_SEL, 32'h0);
      vread(VREG_DEVICE_FEATURES, flo);
      vwrite(VREG_DEVICE_FEAT_SEL, 32'h1);
      vread(VREG_DEVICE_FEATURES, fhi);
      if (venus) begin
        check((flo & (32'h1 | (32'h1 << 3) | (32'h1 << 4))) ==
              (32'h1 | (32'h1 << 3) | (32'h1 << 4)),
              $sformatf("venus feature low got=%08x", flo));
        check((fhi & 32'h1) != 0 && (fhi & (32'h1 << 8)) != 0,
              $sformatf("venus feature high got=%08x", fhi));
      end else begin
        check((flo & (32'h1 | (32'h1 << 3) | (32'h1 << 4))) == 0,
              $sformatf("off feature low got=%08x", flo));
        check((fhi & 32'h1) != 0 && (fhi & (32'h1 << 8)) != 0,
              $sformatf("off feature high got=%08x", fhi));
      end
      // write back exactly the device feature words
      vwrite(VREG_DRIVER_FEAT_SEL, 32'h0);
      vwrite(VREG_DRIVER_FEATURES, flo);
      vwrite(VREG_DRIVER_FEAT_SEL, 32'h1);
      vwrite(VREG_DRIVER_FEATURES, fhi);
      vwrite(VREG_STATUS,
             32'(VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER | VSTATUS_FEATURES_OK));
      vread(VREG_STATUS, r);
      check((r & 32'(VSTATUS_FEATURES_OK)) != 0,
            $sformatf("features_ok reads back got=%02x", r[7:0]));
      // SHM selectors
      vwrite(VREG_SHM_SEL, 32'h1);
      vread(VREG_SHM_LEN_LO, r);
      check(r == (venus ? APU_SHM_BYTES[31:0] : 32'hffff_ffff),
            $sformatf("shm len lo got=%08x", r));
      vread(VREG_SHM_LEN_HI, r);
      check(r == (venus ? APU_SHM_BYTES[63:32] : 32'hffff_ffff),
            $sformatf("shm len hi got=%08x", r));
      vread(VREG_SHM_BASE_LO, r);
      check(r == (venus ? APU_SHM_BASE[31:0] : 32'hffff_ffff),
            $sformatf("shm base lo got=%08x", r));
      vread(VREG_SHM_BASE_HI, r);
      check(r == (venus ? APU_SHM_BASE[63:32] : 32'hffff_ffff),
            $sformatf("shm base hi got=%08x", r));
      vwrite(VREG_SHM_SEL, 32'h0);
      vread(VREG_SHM_LEN_LO, r);
      check(r == 32'hffff_ffff, $sformatf("shm0 len lo got=%08x", r));
      vread(VREG_SHM_BASE_LO, r);
      check(r == 32'hffff_ffff, $sformatf("shm0 base lo got=%08x", r));
      // config space
      vread(VCFG_NUM_CAPSETS, r);
      check(r == (venus ? 32'd1 : 32'd0),
            $sformatf("num_capsets got=%0d", r));
      vread(VCFG_NUM_SCANOUTS, r);
      check(r == 32'd0, $sformatf("num_scanouts got=%0d", r));
      // queues + DRIVER_OK
      queue_setup(0, 0, Q0N, GB + Q0D, GB + Q0A, GB + Q0U);
      queue_setup(0, 1, Q1N, GB + Q1D, GB + Q1A, GB + Q1U);
      vwrite(VREG_STATUS,
             32'(VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER |
                 VSTATUS_FEATURES_OK | VSTATUS_DRIVER_OK));
      cases++;
    end else begin
      oread(VREG_MAGIC, r);
      check(r == VIRTIO_MMIO_MAGIC, "off magic");
      oread(VREG_VERSION, r);
      check(r == VIRTIO_MMIO_VERSION2, "off version");
      owrite(VREG_STATUS, 32'h0);
      // firmware-ack model: STATUS=0 holds every write until the
      // service hart acks at ACTRL_RESET_ACK (backend_reset_done_i
      // and backend_idle_i are tied 1 in the transport fixture).
      t = 0;
      while (!o_rreq && t < 1000) begin @(posedge clk); t++; end
      check(o_rreq, "off: backend_reset_req_o rises on STATUS=0");
      ocwrite(APU_CONTROL_BASE + 64'(ACTRL_RESET_ACK), 32'h1);
      owrite(VREG_STATUS, 32'(VSTATUS_ACKNOWLEDGE));
      owrite(VREG_STATUS, 32'(VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER));
      owrite(VREG_DEVICE_FEAT_SEL, 32'h0);
      oread(VREG_DEVICE_FEATURES, flo);
      owrite(VREG_DEVICE_FEAT_SEL, 32'h1);
      oread(VREG_DEVICE_FEATURES, fhi);
      check((flo & (32'h1 | (32'h1 << 3) | (32'h1 << 4))) == 0,
            $sformatf("off feature low got=%08x", flo));
      check((fhi & 32'h1) != 0 && (fhi & (32'h1 << 8)) != 0,
            $sformatf("off feature high got=%08x", fhi));
      owrite(VREG_DRIVER_FEAT_SEL, 32'h0);
      owrite(VREG_DRIVER_FEATURES, flo);
      owrite(VREG_DRIVER_FEAT_SEL, 32'h1);
      owrite(VREG_DRIVER_FEATURES, fhi);
      owrite(VREG_STATUS,
             32'(VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER | VSTATUS_FEATURES_OK));
      owrite(VREG_SHM_SEL, 32'h1);
      oread(VREG_SHM_LEN_LO, r);
      check(r == 32'hffff_ffff, $sformatf("off shm len lo got=%08x", r));
      oread(VREG_SHM_BASE_LO, r);
      check(r == 32'hffff_ffff, $sformatf("off shm base lo got=%08x", r));
      owrite(VREG_SHM_SEL, 32'h0);
      oread(VREG_SHM_LEN_LO, r);
      check(r == 32'hffff_ffff, $sformatf("off shm0 len lo got=%08x", r));
      oread(VCFG_NUM_CAPSETS, r);
      check(r == 32'd0, $sformatf("off num_capsets got=%0d", r));
      queue_setup(1, 0, Q0N, GB + Q0D, GB + Q0A, GB + Q0U);
      queue_setup(1, 1, Q1N, GB + Q1D, GB + Q1A, GB + Q1U);
      owrite(VREG_STATUS,
             32'(VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER |
                 VSTATUS_FEATURES_OK | VSTATUS_DRIVER_OK));
      cases++;
    end
  endtask

  // ---- arms ---------------------------------------------------------------
  task automatic do_reset();
    g_req = '0; o_greq = '0; c_req = '0; oc_req = '0;
    rst_ni = 0;
    repeat (8) @(posedge clk);
    rst_ni = 1;
    repeat (4) @(posedge clk);
  endtask

  // session tape replay arm (+vec=<session>)
  task automatic arm_session(input string vname);
    vq_init();
    virtio_probe(0, 1'b1);
    $readmemh({"vn_vectors/", vname, ".hex"}, tape, 0);
    $readmemh({"vn_vectors/", vname, ".exp"}, expm, 0);
    tp = 0; ep = 0;
    play_tape();
    check_axi_bal();
  endtask

  // device reset mid-session: STATUS<-0 while a compute chain is in
  // flight; the request completes only after the backend reset, then a
  // full re-probe and a clean transport session pass.
  task automatic arm_dev_reset();
    logic [31:0] r;
    int unsigned t;
    vq_init();
    virtio_probe(0, 1'b1);
    // stage a chain so engines are mid-flight when reset lands
    put_desc(0, 0, GB + 64'h4000, 32'd4, 16'h0, 16'h0);
    push_avail(0, 0);
    do_notify(0);
    repeat (200) @(posedge clk);
    check(reset_req == 1'b0, "no reset request before STATUS<-0");
    vwrite(VREG_STATUS, 32'h0);
    t = 0;
    while (!reset_req && t < 100_000) begin @(posedge clk); t++; end
    check(reset_req, "backend_reset_req_o rises on STATUS<-0");
    t = 0;
    while (reset_req && t < 100_000) begin @(posedge clk); t++; end
    check(!reset_req, "backend_reset_req_o falls after backend reset");
    vread(VREG_STATUS, r);
    check(r[7:0] == 8'h0, $sformatf("status after reset got=%02x", r[7:0]));
    repeat (50) @(posedge clk);
    check(post_rst_axi == 0, "no DMA beat after reset_done");
    check(qen == '0, "queues disabled after device reset");
    // full re-probe, then a clean transport session from position 0
    vq_init();
    virtio_probe(0, 1'b1);
    $readmemh("vn_vectors/ue_sm5_transport.hex", tape, 0);
    $readmemh("vn_vectors/ue_sm5_transport.exp", expm, 0);
    tp = 0; ep = 0;
    play_tape();
    check_axi_bal();
    cases++;
  endtask

  // queue reset mid-walk: QUEUE_RESET<-1 on queue 0 while an element is
  // in flight; the pending read drains (<=3 outstanding invariant),
  // the queue state clears, re-ready restarts the element at
  // used position 0.
  task automatic arm_q_reset();
    logic [31:0] r;
    int unsigned t, s0;
    vq_init();
    virtio_probe(0, 1'b1);
    for (int i = 0; i < 8; i++)
      gw(32'h21400 + 32'(4 * i), (i == 0) ? 32'h0108 : 32'h0);
    put_desc(0, 0, GB + 64'h4000, 32'd4, VF_NEXT, 16'd1);
    put_desc(0, 1, GB + 32'h21400, 32'd32, VF_NEXT, 16'd2);
    put_desc(0, 2, GB + 32'h21500, 32'd40, VF_WRITE, 16'h0);
    push_avail(0, 0);
    do_notify(0);
    // wait until the chain is actually in flight before resetting
    t = 0;
    while (!wch_v && t < 100_000) begin @(posedge clk); t++; end
    s0 = stop_seen[0];
    vwrite(VREG_QUEUE_SEL, 32'h0);
    vwrite(VREG_QUEUE_RESET, 32'h1);
    check(stop_req[0] || stop_seen[0] > s0,
          "backend_queue_stop_req_o[0] rises");
    t = 0;
    do begin
      vread(VREG_QUEUE_RESET, r); t++;
      if (t > 200_000) break;
    end while (r[0] != 0);
    check(r[0] == 0, "queue reset completes (reads back 0)");
    check(stop_seen[0] > s0, "queue stop request seen");
    check(vq[0].ready == 1'b0 && vq[0].num == 16'h0,
          "queue 0 state cleared by ring reset");
    // drain any IRQ left over from the dropped walk
    repeat (4) @(posedge clk);
    if (girq) begin
      vread(VREG_INTERRUPT_STATUS, r);
      vwrite(VREG_INTERRUPT_ACK, r & 32'h1);
      repeat (4) @(posedge clk);
    end
    check(!girq, "no stale irq after queue reset");
    // re-ready queue 0 and replay the element at position 0
    queue_setup(0, 0, Q0N, GB + Q0D, GB + Q0A, GB + Q0U);
    do_notify(0);
    wait_used(0);
    // the replayed head-0 chain (4B + 32B consumed, 40B response
    // buffer) truthfully publishes len 60 — same element re-decoded,
    // deterministic response.
    check(u_len_s == 32'd60,
          $sformatf("post-reset used len got=%0d exp=60", u_len_s));
    check_used_img(0, 0, u_len_s);
    check_axi_bal();
    cases++;
  endtask

  // VenusOff: the transport-only fixture — no Venus features, no SHM,
  // a doorbell produces no DMA and no IRQ within 2,000 cycles.
  task automatic arm_venusoff();
    int unsigned b0;
    vq_init();
    virtio_probe(1, 1'b0);
    b0 = off_beats;
    owrite(VREG_QUEUE_NOTIFY, 32'h0);
    repeat (2000) @(posedge clk);
    check(off_beats == b0, "venusoff: no DMA beat after notify");
    check(!o_girq, "venusoff: no irq after notify");
    cases++;
  endtask

  // WorkSink=0 (the sys path): a session whose submit carries a
  // non-dispatch record is refused UNSUPPORTED -> the fence reports
  // DEVICE_LOST (flost_q and the 0xFFFF_FFFC vk result in the
  // aperture replies, verified by the tape's CK_REPLYs), nothing
  // hangs, and the next session passes after the driver-level
  // reset + re-probe a lost device requires.
  task automatic arm_worksink0();
    int unsigned pubs0;
    vq_init();
    virtio_probe(0, 1'b1);
    ws0_lost = 1'b0;
    pubs0 = pubs;
    // worksink variant: the submit's CB records a vkCmdDispatchIndirect
    // — a non-dispatch CLS_WORK record the WorkSink=0 backend refuses.
    // The tape's own expectations are truthful: the wait-class replies
    // expect the 0xFFFF_FFC DEVICE_LOST result.
    $readmemh("vn_vectors/ue_ws0_bufcopy_1.hex", tape, 0);
    $readmemh("vn_vectors/ue_ws0_bufcopy_1.exp", expm, 0);
    tp = 0; ep = 0;
    play_tape();
    repeat (200) @(posedge clk);
    check(pubs > pubs0, "worksink0: chains still publish");
    check(ws0_lost, "worksink0: cmdexec fence lost (DEVICE_LOST)");
    check_axi_bal();
    // next session passes: after DEVICE_LOST a driver reinitialises
    // the device — STATUS<-0 (backend reset, clearing the fence-lost
    // state) then a full re-probe, then a clean transport session.
    vq_init();
    virtio_probe(0, 1'b1);
    $readmemh("vn_vectors/ue_sm5_transport.hex", tape, 0);
    $readmemh("vn_vectors/ue_sm5_transport.exp", expm, 0);
    tp = 0; ep = 0;
    play_tape();
    check_axi_bal();
    cases++;
  endtask

  // cfg legality split (F1): ApuVenus legal, ApuBadVirglGrant illegal,
  // and the three targeted mutations.
  task automatic arm_legality();
    apu_cfg_t cfg;
    check(apu_cfg_legal(ApuVenus), "ApuVenus legal");
    check(!apu_cfg_legal(ApuBadVirglGrant), "ApuBadVirglGrant illegal");
    check(apu_cfg_legal(ApuP1Transport), "ApuP1Transport still legal");
    check(apu_cfg_legal(ApuHarness), "ApuHarness still legal");
    cfg = ApuVenus; cfg.FirmwareHart = 1;
    check(!apu_cfg_legal(cfg), "VenusEn + FirmwareHart illegal");
    cfg = ApuVenus; cfg.NumCapsets = 2;
    check(!apu_cfg_legal(cfg), "VenusEn + NumCapsets=2 illegal");
    cfg = ApuVenus; cfg.DmaWindowBytes = 0;
    check(!apu_cfg_legal(cfg), "VenusEn + DmaWindowBytes=0 illegal");
    cases++;
  endtask

  // --------------------------------------------------------------------------
  initial begin
    string vname;
    if (!$value$plusargs("vec=%s", vname)) vname = "ue_sm5_transport";
    if (vname != "") $display("session tape: %s", vname);
    do_reset();
    if (vname == "dev_reset")      arm_dev_reset();
    else if (vname == "q_reset")   arm_q_reset();
    else if (vname == "venusoff")  arm_venusoff();
    else if (vname == "worksink0") arm_worksink0();
    else if (vname == "legality")  arm_legality();
    else                           arm_session(vname);

    if (errors == 0) begin
      if (g1_n != 0)
        $display("PASS-COMPUTE g1=%0d g2=%0d ulp1=%0d ulp2=%0d maxulp=%0d cycles=%0d",
                 g1_n, g2_n, ulp1, ulp2, maxulp, cycles);
      $display("PASS tb_g6lc_apu_sys_venus cases=%0d checks=%0d cycles=%0d",
               cases, checks, cycles);
    end else
      $display("FAIL tb_g6lc_apu_sys_venus cases=%0d checks=%0d errors=%0d",
               cases, checks, errors);
    $finish;
  end
endmodule
