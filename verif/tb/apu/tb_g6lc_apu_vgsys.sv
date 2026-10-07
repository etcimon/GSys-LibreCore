// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps
// §6c-i g6lc_apu_vgsys bench: the vn_golden guest-script tapes replayed
// through real split virtqueues instead of the chain_* port.  Queue 0
// (num=64) is the control queue; queue 1 (num=16) is the cursor queue.
// Both live in the guest window (guest_base_i=0x8000_0000, 1 MiB); the
// aperture window is APU_VG_SHM_BASE..+1 MiB.  A single-beat AXI4 slave
// model backs both windows and $fatal-asserts that every AW/AR address
// lands inside one of them.
//
// TP_CHAIN tape ops are materialized as descriptor-table entries plus an
// avail-ring push + notify_i[0]; publications are observed as
// used_valid_o pulses plus the used-ring memory image.  Negative arms
// (+vec=neg_*) cover the §6c exit list.  Tape ops identical to
// tb_g6lc_apu_vgtop (see its header).

module tb_g6lc_apu_vgsys;
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;

  localparam int unsigned Rings  = 4;
  localparam logic [63:0] GB     = 64'h8000_0000;   // guest window
  localparam int unsigned GBW    = 32'h40000;       // 1 MiB / 4 B
  localparam logic [63:0] AB     = APU_VG_SHM_BASE; // aperture window
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

  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  // ---- DUT signals -----------------------------------------------------
  // i_ws0 mirrors the same outputs under w_*; the observation wires
  // mux on ws_arm_q so every task/check is transparent to which
  // instance is live.
  g6lc_apu_pkg::apu_vq_state_t vq0, vq1;
  logic [1:0]      qen = '0, notify = '0;
  logic [1:0]      d_nclr, nclr;
  logic            d_uv, u_v;
  logic [31:0]     d_uqid, u_qid, d_ulen, u_len;
  logic            u_rdy = 1'b1;
  logic [1:0][15:0] d_lav, last_av;
  logic            rreq = 0, d_rdone, rdone, d_idle, idle, d_bf, bfault;
  logic [31:0]     d_fcnt, fcnt;
  logic            w_v;
  logic            w_r;
  apu_cmdexec_work_t w_o;
  logic            w_done = 0;
  logic            d_done, d_fpu, f_pulse;
  logic [63:0]     d_fid, f_id;
  logic [7:0]      d_fring, f_ring;
  logic [Rings-1:0]       d_ra, r_active;
  logic [Rings-1:0][31:0] d_rs, r_status, d_rh, r_head;
  logic [Rings-1:0][APU_VG_AP_WORD_W-1:0] d_re, r_extra;
  logic [15:0]     d_liv, ot_live;
  assign nclr     = d_nclr | w_nclr;
  assign u_v      = ws_arm_q ? w_uv   : d_uv;
  assign u_qid    = ws_arm_q ? w_uqid : d_uqid;
  assign u_len    = ws_arm_q ? w_ulen : d_ulen;
  assign last_av  = ws_arm_q ? w_lav  : d_lav;
  assign rdone    = ws_arm_q ? w_rdone : d_rdone;
  assign idle     = ws_arm_q ? w_idle : d_idle;
  assign bfault   = d_bf | w_bf;
  assign fcnt     = ws_arm_q ? w_fcnt : d_fcnt;
  assign f_pulse  = d_fpu | w_fp;
  assign f_id     = ws_arm_q ? w_fid  : d_fid;
  assign f_ring   = ws_arm_q ? w_fring : d_fring;
  assign r_active = ws_arm_q ? w_ra : d_ra;
  assign r_status = ws_arm_q ? w_rs : d_rs;
  assign r_head   = ws_arm_q ? w_rh : d_rh;
  assign r_extra  = ws_arm_q ? w_re : d_re;
  assign ot_live  = ws_arm_q ? w_liv : d_liv;
  apu_dma_axi_req_t  areq;
  apu_dma_axi_resp_t arsp;
  logic [63:0]     ap_bytes = APU_VG_SHM_BYTES;
  // debug ObjTab (unused; tied off)
  logic            dot_r;
  apu_objtab_req_t dot_req = '0;
  logic            dot_cv;
  apu_objtab_cpl_t dot_cpl;

  // WorkSink=0 arm flag: gates i_dut inert and muxes the AXI slave onto
  // i_ws0 for the +vec=neg_worksink0 run only.
  logic            ws_arm_q = 1'b0;
  wire vw_cv = ws_arm_q ? i_ws0.gen_on.vw_chain_v
                        : i_dut.gen_on.vw_chain_v;
  wire vw_cr = ws_arm_q ? i_ws0.gen_on.vw_chain_rdy
                        : i_dut.gen_on.vw_chain_rdy;
  wire [APU_VG_PAGES-1:0] vgp_free =
      ws_arm_q ? i_ws0.gen_on.i_top.gen_on.i_vgp.gen_on.free_q
               : i_dut.gen_on.i_top.gen_on.i_vgp.gen_on.free_q;
  wire [255:0] pay_free =
      ws_arm_q ? i_ws0.gen_on.i_top.gen_on.i_pay.gen_on.free_q
               : i_dut.gen_on.i_top.gen_on.i_pay.gen_on.free_q;

  g6lc_apu_vgsys #(.Enable(1'b1), .Rings(Rings)) i_dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .vq0_i(vq0), .vq1_i(vq1),
    .queue_enable_i(ws_arm_q ? 2'b00 : qen),
    .notify_i(ws_arm_q ? 2'b00 : notify), .notify_clear_o(d_nclr),
    .used_valid_o(d_uv), .used_qid_o(d_uqid), .used_len_o(d_ulen),
    .used_ready_i(u_rdy), .last_avail_o(d_lav),
    .reset_req_i(ws_arm_q ? 1'b0 : rreq), .reset_done_o(d_rdone),
    .idle_o(d_idle), .bus_fault_o(d_bf),
    .dma_req_o(areq), .dma_rsp_i(arsp),
    .guest_base_i(GB), .guest_bytes_i(64'h100000),
    .ap_base_i(AB), .ap_bytes_i(ap_bytes),
    .fault_cnt_o(d_fcnt),
    .work_valid_o(w_v), .work_ready_i(w_r), .work_o(w_o),
    .work_done_i(w_done), .work_done_pl_i('0),
    .done_o(d_done),
    .fence_pulse_o(d_fpu), .fence_id_o(d_fid), .fence_ring_o(d_fring),
    .ring_active_o(d_ra), .ring_status_o(d_rs),
    .ring_head_o(d_rh), .ring_extra_w_o(d_re),
    .objtab_live_o(d_liv),
    .dbg_ot_valid_i(1'b0), .dbg_ot_ready_o(dot_r),
    .dbg_ot_req_i(dot_req),
    .dbg_ot_cpl_valid_o(dot_cv), .dbg_ot_cpl_ready_i(1'b0),
    .dbg_ot_cpl_o(dot_cpl));

  // WorkSink=0 twin (§6c F1): same queues, refuses non-dispatch work
  // UNSUPPORTED -> DEVICE_LOST.  Inert outside the ws0 arm (i_dut owns
  // the queue inputs; this one still sees them but ws_arm_q muxes the
  // AXI slave away from i_dut, not onto a second live path).
  logic [1:0]      w_nclr;
  logic [1:0][15:0] w_lav;
  logic            w_uv, w_rdone, w_idle, w_bf, w_wv, w_dn, w_fp;
  logic [31:0]     w_uqid, w_ulen, w_fcnt;
  logic [63:0]     w_fid;
  logic [7:0]      w_fring;
  logic [Rings-1:0]       w_ra;
  logic [Rings-1:0][31:0] w_rs, w_rh;
  logic [Rings-1:0][APU_VG_AP_WORD_W-1:0] w_re;
  logic [15:0]     w_liv;
  logic            w_dotr, w_dotcv;
  apu_dma_axi_req_t w_areq;
  apu_cmdexec_work_t w_wo;
  apu_objtab_cpl_t w_dotcpl;

  g6lc_apu_vgsys #(.Enable(1'b1), .Rings(Rings), .WorkSink(1'b0)) i_ws0 (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .vq0_i(vq0), .vq1_i(vq1),
    .queue_enable_i(ws_arm_q ? qen : 2'b00),
    .notify_i(ws_arm_q ? notify : 2'b00), .notify_clear_o(w_nclr),
    .used_valid_o(w_uv), .used_qid_o(w_uqid), .used_len_o(w_ulen),
    .used_ready_i(u_rdy), .last_avail_o(w_lav),
    .reset_req_i(ws_arm_q ? rreq : 1'b0), .reset_done_o(w_rdone),
    .idle_o(w_idle), .bus_fault_o(w_bf),
    .dma_req_o(w_areq), .dma_rsp_i(arsp),
    .guest_base_i(GB), .guest_bytes_i(64'h100000),
    .ap_base_i(AB), .ap_bytes_i(ap_bytes),
    .fault_cnt_o(w_fcnt),
    .work_valid_o(w_wv), .work_ready_i(1'b0), .work_o(w_wo),
    .work_done_i(1'b0), .work_done_pl_i('0),
    .done_o(w_dn),
    .fence_pulse_o(w_fp), .fence_id_o(w_fid), .fence_ring_o(w_fring),
    .ring_active_o(w_ra), .ring_status_o(w_rs),
    .ring_head_o(w_rh), .ring_extra_w_o(w_re),
    .objtab_live_o(w_liv),
    .dbg_ot_valid_i(1'b0), .dbg_ot_ready_o(w_dotr),
    .dbg_ot_req_i(dot_req),
    .dbg_ot_cpl_valid_o(w_dotcv), .dbg_ot_cpl_ready_i(1'b0),
    .dbg_ot_cpl_o(w_dotcpl));

  // Enable=0 fixture: all outputs quiet, idle_o high
  logic [1:0]      o_nclr;
  logic [1:0][15:0] o_lav;
  logic            o_uv, o_rdone, o_idle, o_bf, o_wv, o_dn, o_fp;
  logic [31:0]     o_uqid, o_ulen, o_fcnt;
  logic [63:0]     o_fid;
  logic [7:0]      o_fring;
  logic [Rings-1:0]       o_ra;
  logic [Rings-1:0][31:0] o_rs, o_rh;
  logic [Rings-1:0][APU_VG_AP_WORD_W-1:0] o_re;
  logic [15:0]     o_liv;
  logic            o_dotr, o_dotcv;
  apu_dma_axi_req_t o_areq;
  apu_cmdexec_work_t o_wo;
  apu_objtab_cpl_t o_dotcpl;
  apu_dma_axi_resp_t arsp0 = '0;

  g6lc_apu_vgsys #(.Enable(1'b0), .Rings(Rings)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .vq0_i(vq0), .vq1_i(vq1),
    .queue_enable_i(qen), .notify_i(notify), .notify_clear_o(o_nclr),
    .used_valid_o(o_uv), .used_qid_o(o_uqid), .used_len_o(o_ulen),
    .used_ready_i(1'b1), .last_avail_o(o_lav),
    .reset_req_i(rreq), .reset_done_o(o_rdone),
    .idle_o(o_idle), .bus_fault_o(o_bf),
    .dma_req_o(o_areq), .dma_rsp_i(arsp0),
    .guest_base_i(GB), .guest_bytes_i(64'h100000),
    .ap_base_i(AB), .ap_bytes_i(ap_bytes),
    .fault_cnt_o(o_fcnt),
    .work_valid_o(o_wv), .work_ready_i(1'b0), .work_o(o_wo),
    .work_done_i(1'b0), .work_done_pl_i('0),
    .done_o(o_dn),
    .fence_pulse_o(o_fp), .fence_id_o(o_fid), .fence_ring_o(o_fring),
    .ring_active_o(o_ra), .ring_status_o(o_rs),
    .ring_head_o(o_rh), .ring_extra_w_o(o_re),
    .objtab_live_o(o_liv),
    .dbg_ot_valid_i(1'b0), .dbg_ot_ready_o(o_dotr),
    .dbg_ot_req_i(dot_req),
    .dbg_ot_cpl_valid_o(o_dotcv), .dbg_ot_cpl_ready_i(1'b0),
    .dbg_ot_cpl_o(o_dotcpl));

  // standalone Enable=0 fixtures for the two other composed engines
  // (continuous-zero monitors below): the composition fixture covers
  // vgsys; these cover apmem and vqwalk on their own ports.
  logic [APU_MP_N-1:0]     z_rdy, z_rv;
  apu_mp_rsp_t [APU_MP_N-1:0] z_mprsp;
  apu_dma_axi_req_t          z_areq;
  logic                      z_aout, z_aidle;
  logic [31:0]               z_afcnt;
  g6lc_apu_apmem #(.Enable(1'b0)) i_apm_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .flush_i(rreq),
    .req_valid_i('1), .req_ready_o(z_rdy), .req_i('{default: '0}),
    .rsp_valid_o(z_rv), .rsp_o(z_mprsp),
    .guest_base_i(GB), .guest_bytes_i(64'h100000),
    .ap_base_i(AB), .ap_bytes_i(ap_bytes),
    .axi_req_o(z_areq), .axi_rsp_i(arsp0),
    .outstanding_o(z_aout), .fault_cnt_o(z_afcnt),
    .idle_o(z_aidle));

  logic            z_wreq_v, z_chv, z_uv2, z_bf2, z_widle, z_cr;
  apu_mp_req_t     z_wreq;
  logic [15:0]     z_chid;
  logic [3:0]      z_chn;
  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] z_chd;
  logic [31:0]     z_uqid2, z_ulen2;
  logic [1:0]      z_nc;
  logic [1:0][15:0] z_la;
  g6lc_apu_vqwalk #(.Enable(1'b0)) i_vqw_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .reset_req_i(rreq),
    .vq0_i(vq0), .vq1_i(vq1),
    .queue_enable_i(qen), .notify_i(notify), .notify_clear_o(z_nc),
    .mp_req_valid_o(z_wreq_v), .mp_req_ready_i(1'b1),
    .mp_req_o(z_wreq), .mp_rsp_valid_i(1'b0), .mp_rsp_i('0),
    .chain_valid_o(z_chv), .chain_ready_i(1'b1),
    .chain_id_o(z_chid), .chain_n_o(z_chn), .chain_desc_o(z_chd),
    .cpl_valid_i(1'b0), .cpl_ready_o(z_cr), .cpl_len_i(32'h0),
    .used_valid_o(z_uv2), .used_qid_o(z_uqid2), .used_len_o(z_ulen2),
    .used_ready_i(1'b1),
    .bus_fault_o(z_bf2), .idle_o(z_widle), .last_avail_o(z_la));

  // ---- tape / expected stores -------------------------------------------
  logic [31:0] tape [TAPEW];
  logic [31:0] expm [EXPW];
  int unsigned tp, ep;

  // ---- guest RAM + aperture backing stores ------------------------------
  logic [31:0] gmem [GBW];   // gmem[off>>2] <-> GB+off
  logic [31:0] apm  [ABW];   // apm[apix(off>>2)]  <-> AB+off

  // ---- AXI4 slave model (burst reads, <=3 outstanding) ------------------
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
  // B-order log: every write beat's address, in B-acceptance order.
  logic [63:0] b_log [4096];
  int unsigned b_n = 0;
  // beats inside the real aperture window but past ap_bytes_i (must be 0)
  int unsigned oob_ap = 0;
  // number of accepted AW+AR after reset_done_o (must stay 0)
  int unsigned post_rst_axi = 0;
  // always-on transaction invariants: at most three outstanding
  // transactions on the master (apmem 1 + xfer read 1 + xfer write 1;
  // tdma's owner lock makes the achievable peak 2), and every
  // AW+W/AR is answered by a B/R (checked by check_axi_bal at the end
  // of every arm/session)
  int unsigned aw_n = 0, w_n = 0, ar_n = 0, r_n = 0, ar_beats = 0;
  int unsigned outst = 0;
  // programmable ready stalls for the flush races (neg_flush):
  // while set the channel's ready stays low no matter the state
  logic        stall_aw = 0, stall_w = 0, stall_ar = 0;
  // programmable R latency (neg_qdrop): cycles between AR acceptance
  // and r_valid — lets a queue drop land while an R is in flight
  int unsigned axi_rd_dly = 0;
  int unsigned rd_wait    = 0;
  // slave request port mux: i_ws0 owns the bus only during the ws0 arm
  wire apu_dma_axi_req_t sm_areq = ws_arm_q ? w_areq : areq;

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
    if (a >= AB + ap_bytes && a < AB + APU_VG_SHM_BYTES) oob_ap++;
  endtask

  always_comb begin
    arsp = '0;
    arsp.ar_ready = !r_act && !r_vld && !stall_ar;
    arsp.r_valid  = r_vld;
    arsp.r        = rch;
    arsp.aw_ready = !aw_s && !stall_aw;
    arsp.w_ready  = !w_s && !stall_w;
    arsp.b_valid  = b_vld;
    arsp.b        = '{id: 4'd1, resp: axi_pkg::RESP_OKAY, user: '0};
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_act <= 0; r_vld <= 0; r_addr <= '0; r_size <= '0; r_rem <= 0;
      rch <= '0;
      aw_s <= 0; w_s <= 0; b_vld <= 0; waw <= '0; ww <= '0;
      rd_wait <= 0;
    end else begin
      if (sm_areq.ar_valid && arsp.ar_ready) begin
        win_check(sm_areq.ar.addr, "AR");
        if (sm_areq.ar.burst != axi_pkg::BURST_INCR)
          $fatal(1, "AXI: non-INCR read burst");
        ar_n++;
        ar_beats += int'(sm_areq.ar.len) + 1;
        r_act   <= 1;
        rd_wait <= axi_rd_dly;
        r_addr  <= sm_areq.ar.addr;
        r_size  <= sm_areq.ar.size;
        r_rem   <= int'(sm_areq.ar.len) + 1;
        outst++;
        if (outst > 3)
          $fatal(1, "AXI: outstanding bound %0d > 3", outst);
        if (rdone || w_rdone) post_rst_axi++;
      end
      if (r_act && !r_vld && rd_wait != 0) begin
        rd_wait <= rd_wait - 1;
      end else if (r_act && !r_vld) begin
        r_vld <= 1;
        rch   <= '0;
        rch.resp <= axi_pkg::RESP_OKAY;
        rch.last <= r_rem == 1;
        for (int b = 0; b < 8; b++)
          rch.data[8*b +: 8] <= rd8((r_addr & ~64'h7) + 64'(b));
      end
      if (r_vld && sm_areq.r_ready) begin
        r_n++;
        r_vld <= 0;
        r_addr <= r_addr + (64'd1 << r_size);
        if (r_rem <= 1) begin r_act <= 0; outst--; end
        else r_rem <= r_rem - 1;
      end
      if (sm_areq.aw_valid && arsp.aw_ready) begin
        win_check(sm_areq.aw.addr, "AW");
        if (sm_areq.aw.len != 0)
          $fatal(1, "AXI: write burst len %0d (engines are narrow)",
                 sm_areq.aw.len);
        aw_n++;
        aw_s <= 1; waw <= sm_areq.aw;
        outst++;
        if (outst > 3)
          $fatal(1, "AXI: outstanding bound %0d > 3", outst);
        if (rdone || w_rdone) post_rst_axi++;
      end
      if (sm_areq.w_valid && arsp.w_ready) begin
        if (!sm_areq.w.last)
          $fatal(1, "AXI: multi-beat write");
        w_n++;
        w_s <= 1; ww <= sm_areq.w;
      end
      if (aw_s && w_s && !b_vld) begin
        // strb lanes are absolute within aw.addr & ~7 (narrow writes)
        for (int b = 0; b < 8; b++)
          if (ww.strb[b])
            wr8((waw.addr & ~64'h7) + 64'(b), ww.data[8*b +: 8]);
        b_vld <= 1;
      end
      if (b_vld && sm_areq.b_ready) begin
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

  // balance check: every accepted address/data pair was answered —
  // called at the end of every arm and session.  A legitimately
  // in-flight transaction (e.g. the walker's drain re-read right
  // after the last publication) gets a bounded settle first; a beat
  // orphaned by the DUT makes the wait time out and the check fails.
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
          $sformatf("AXI read balance ar=%0d beats=%0d r=%0d",
                    ar_n, ar_beats, r_n));
  endtask

  // ---- work port sink (accept after 1 cycle, done 3 later) ---------------
  int unsigned w_delay = 0;
  logic      w_vq = 0;
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      w_delay <= 0; w_vq <= 0; w_done <= 0;
    end else begin
      w_done <= 0;
      if (w_v && w_r) begin
        w_vq <= 1'b1; w_delay <= 3;
      end else if (w_vq && w_delay != 0) begin
        w_delay <= w_delay - 1;
        if (w_delay == 1) begin w_done <= 1'b1; w_vq <= 0; end
      end
    end
  end
  assign w_r = !w_vq;

  // ---- fence / notify / used observability -------------------------------
  int unsigned f_count = 0;
  logic [63:0] f_seen_id;
  logic [7:0]  f_seen_ring;
  int unsigned nc_seen[2];              // notify_clear pulses per queue
  int unsigned u_count = 0;             // used_valid handshakes
  int unsigned uidx_b_wrong = 0;        // used_valid with no idx B seen
  always @(posedge clk or negedge rst_ni)
    if (!rst_ni) begin
      f_count <= 0; f_seen_id <= '0; f_seen_ring <= '0;
      nc_seen[0] <= 0; nc_seen[1] <= 0; u_count <= 0;
    end else begin
      if (f_pulse) begin
        f_count <= f_count + 1; f_seen_id <= f_id; f_seen_ring <= f_ring;
      end
      if (nclr[0]) nc_seen[0] <= nc_seen[0] + 1;
      if (nclr[1]) nc_seen[1] <= nc_seen[1] + 1;
      if (u_v && u_rdy) u_count <= u_count + 1;
    end

  // chain hand-off observation (neg_cursor asserts this stays 0 for q1)
  logic chain_seen = 0;
  always @(posedge clk)
    if (vw_cv && vw_cr)
      chain_seen <= 1'b1;

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) begin
    if (o_uv || (|o_uqid) || (|o_ulen) || (|o_nclr) || o_wv || o_dn ||
        o_fp || o_dotcv || o_dotr || (|o_lav) || o_bf || o_rdone ||
        (|o_fcnt) || (|o_fid) || (|o_fring) || (|o_ra) || (|o_rs) ||
        (|o_rh) || (|o_re) || o_liv !== '0 || (|o_areq) ||
        o_idle !== 1'b1)
      $fatal(1, "disabled vgsys active");
    // Enable=0 apmem / vqwalk fixtures: outputs continuously zero
    // (idle_o high is the sanctioned non-zero output)
    if ((|z_rdy) || (|z_rv) || (|z_mprsp) || (|z_areq) || z_aout ||
        (|z_afcnt) || z_aidle !== 1'b1)
      $fatal(1, "disabled apmem active");
    if (z_wreq_v || (|z_wreq) || z_chv || (|z_chid) || (|z_chn) ||
        (|z_chd) || z_uv2 || (|z_uqid2) || (|z_ulen2) || z_bf2 ||
        (|z_nc) || (|z_la) || z_cr || z_widle !== 1'b1)
      $fatal(1, "disabled vqwalk active");
    if (cycles > MAXCYC) $fatal(1, "watchdog");
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

  // TB-side queue cursors
  int unsigned av_push[2];    // next avail.idx value to publish
  int unsigned dcur[2];       // next free descriptor index
  int unsigned uexp[2];       // expected used.idx (count of used elems)

  // write a 16-byte descriptor table entry
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

  // push an avail entry (ring[last] = head) and bump avail.idx
  task automatic push_avail(input int q, input int unsigned head);
    int unsigned aidx;
    aidx = av_push[q];
    gh(qavail(q) + 4 + 32'(aidx % qnum(q)) * 2, 16'(head));
    gh(qavail(q) + 2, 16'(aidx + 1));
    av_push[q] = aidx + 1;
  endtask

  // doorbell: level until the walker pulses notify_clear_o[q]
  task automatic do_notify(input int q);
    int unsigned nc0, t;
    nc0 = nc_seen[q]; t = 0;
    notify[q] = 1'b1;
    @(posedge clk);
    while (nc_seen[q] == nc0 && t < 2_000_000) begin
      @(posedge clk); t++;
    end
    check(nc_seen[q] != nc0, $sformatf("notify_clear q%0d", q));
    notify[q] = 1'b0;
  endtask

  // did a B beat for address `a` complete (first / last B-order index)?
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

  // wait for one used_valid_o pulse on queue q; returns {qid,len}.
  // A call can begin while the previous publication's level is still
  // visible across its exit edge — drain any in-flight pulse first so
  // back-to-back publications are not mistaken for each other.
  logic [31:0] u_qid_s, u_len_s;
  task automatic wait_used(input int q);
    int unsigned t;
    t = 0;
    while (u_v) @(posedge clk);
    while (!(u_v && u_qid == 32'(q)) && t < 20_000_000) begin
      @(negedge clk); t++;
    end
    check(t < 20_000_000 && u_v && u_qid == 32'(q),
          $sformatf("used_valid timeout q%0d", q));
    u_qid_s = u_qid; u_len_s = u_len;
    @(posedge clk);
  endtask

  // check the used-ring image for the latest publication on queue q:
  // element {id,len} at ring[uexp % num], used.idx == uexp+1, the idx
  // beat's B precedes used_valid, and the element beats precede it
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
    // the used.idx beat's B precedes used_valid (b_log holds only
    // B-accepted writes, so a hit proves ordering); the element's len
    // beat must precede the idx beat.  For pos=0 the id write and the
    // idx write share the used+0 beat — first vs last match separates
    // them — so compare the always-distinct len beat instead.
    bi_elem = b_find_last(GB + ub + 8 + 64'(pos % qnum(q)) * 8);
    bi_idx  = b_find_last((GB + ub + 2) & ~64'h7);
    check(bi_idx >= 0, "used.idx B beat observed before used_valid");
    check(bi_elem >= 0, "used elem B beat observed");
    if (bi_elem >= 0 && bi_idx >= 0)
      check(bi_elem < bi_idx, "used elem B before used.idx B");
    uexp[q]++;
  endtask

  // ---- chain submit / expect (split so batching can interleave) -----------
  int unsigned  pend_head[512];   // pushed heads awaiting publication
  logic [63:0]  pend_raddr[512];  // write-desc guest offsets per chain
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

  // wait for the publication of the oldest pushed chain and run the
  // EK_RESP/EK_BODY/EK_FENCE record checks against it
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
      while (!idle && t < 100000) begin @(posedge clk); t++; end
      check(idle, "vgsys idle after completion");
      if ((flags & 1) != 0) begin
        check(rec_kind() == 8, "EK_FENCE kind");
        ep++;
        check(f_seen_id == fence &&
              f_count != 0,
              "fence id match");
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
  task automatic play_tape();
    while (1) begin
      int unsigned op = ntap();
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
                if (apm[((a1 >> 2) + expm[ep + 1])] != expm[ep + 2])
                  bad++;
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
              check($countones(vgp_free)
                    == int'(expm[ep + 1]),
                    $sformatf("CK_PAGES got=%0d exp=%0d",
                              $countones(vgp_free),
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
    check(pay_free === '0,
          "objpay chunks drained");
  endtask

  // §7a Gate-2 float compare (same rule as tb_g6lc_apu_vgtop)
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

  // ---- queue init / reset --------------------------------------------------
  task automatic vq_init(input logic [31:0] u0);
    // u0 = aperture bytes presented to the DUT (64 KiB shrink arm)
    for (int i = 0; i < GBW; i++) gmem[i] = '0;
    for (int i = 0; i < ABW; i++) apm[apix(i)] = '0;
    vq0 = '{desc: GB + Q0D, avail: GB + Q0A, used: GB + Q0U,
            num: 16'(Q0N), ready: 1'b1};
    vq1 = '{desc: GB + Q1D, avail: GB + Q1A, used: GB + Q1U,
            num: 16'(Q1N), ready: 1'b1};
    av_push[0] = 0; av_push[1] = 0;
    dcur[0] = 0;    dcur[1] = 0;
    uexp[0] = 0;    uexp[1] = 0;
    pend_n = 0; pend_c = 0;
    ap_bytes = u0;
    qen = 2'b11;
  endtask

  task automatic do_reset();
    qen = '0; notify = '0; rreq = 0;
    rst_ni = 0;
    repeat (8) @(posedge clk);
    rst_ni = 1;
    repeat (4) @(posedge clk);
  endtask

  // ---- negative arms ---------------------------------------------------------
  // next-loop chain: desc0 -> desc1 -> desc0 publishes {id,0}, queue
  // continues (a following oob-head element publishes too)
  task automatic neg_next_loop();
    put_desc(0, 0, GB + 64'h4000, 32'd4, VF_NEXT, 16'd1);
    put_desc(0, 1, GB + 64'h4000, 32'd4, VF_NEXT, 16'd0);
    push_avail(0, 0);
    do_notify(0);
    wait_used(0);
    check(u_len_s == 0, "next-loop used len 0");
    check_used_img(0, 0, 0);
    push_avail(0, 200);            // head >= num: chain fault, len 0
    do_notify(0);
    wait_used(0);
    check(u_len_s == 0, "oob-head used len 0");
    check_used_img(0, 200, 0);
    check_axi_bal();
  endtask

  task automatic neg_desc_oob();
    push_avail(0, Q0N + 5);        // head >= num
    do_notify(0);
    wait_used(0);
    check(u_len_s == 0, "desc-oob used len 0");
    check_used_img(0, Q0N + 5, 0);
    check_axi_bal();
  endtask

  // descriptor buffer below the guest window: apmem errs the vgctl
  // read; the element publishes len=0 and no AXI beat hits 0x40
  task automatic neg_buf_oob();
    put_desc(0, 0, 64'h40, 32'd4, 16'h0, 16'h0);
    push_avail(0, 0);
    do_notify(0);
    wait_used(0);
    check(u_len_s == 0,
          $sformatf("buf-oob used len got=%0d", u_len_s));
    check_used_img(0, 0, u_len_s);
    check_axi_bal();
  endtask

  // aperture accesses past ap_bytes_i: robust err responses, fault_cnt
  // grows, and no AXI beat ever addresses those bytes (oob_ap == 0;
  // the window assert covers absolute OOB)
  task automatic neg_aperture();
    int unsigned f0, t;
    f0 = fcnt;
    // a chain whose descriptor points into the "shrunk" aperture via
    // the execbuffer path is complex; simplest deterministic arm:
    // present only the first 64 KiB of aperture and replay the
    // transport tape, which creates ring/blob windows at blob offsets
    // the session itself allocates inside the shrunken window — any
    // aperture access past 64 KiB faults robustly.  Play until the
    // fault counter moves (bounded).  The caller presents only 256 B
    // of aperture (vq_init); the tape's aperture traffic sits at
    // offsets 0x0..0x5xxx, so nearly all of it faults on the first
    // chain.
    $readmemh("vn_vectors/ue_sm5_transport.hex", tape, 0);
    $readmemh("vn_vectors/ue_sm5_transport.exp", expm, 0);
    tp = 0; ep = 0; t = 0;
    while (fcnt == f0 && t < 3_000_000 && tp < TAPEW &&
           tape[tp] != 0) begin
      // replay ops without exp checks: consume TP_MEMW/TP_APW/DELAY
      // and push chains ignoring results (they fault anyway)
      int unsigned op = tape[tp]; tp++;
      case (op)
        1: begin
          int unsigned n = ntap();
          int unsigned al = ntap(), ah = ntap();
          for (int i = 0; i < n; i++) gmem[((al >> 2) + i) % GBW] = ntap();
        end
        2: begin
          chain_submit(); do_notify(0);
          // swallow the publication if it comes
          t += 2000;
          for (int i = 0; i < 2000; i++) @(posedge clk);
        end
        3: begin
          int unsigned n = ntap();
          int unsigned al = ntap(), ah = ntap();
          for (int i = 0; i < n; i++) apm[apix(((al >> 2) + i))] = ntap();
        end
        // WAIT_HEAD/WAIT_IDLE/CHECK: consume operands, give the pump a
        // bounded window to issue its (faulting) aperture traffic
        4: begin
          tp += 4;
          for (int i = 0; i < 4000; i++) @(posedge clk);
        end
        5: begin
          tp += 5;
          for (int i = 0; i < 4000; i++) @(posedge clk);
        end
        6: tp += 3;
        7: begin
          int unsigned n = ntap();
          repeat (n) @(posedge clk);
        end
        default: break;
      endcase
      t++;
    end
    check(fcnt > f0, "aperture OOB fault count grows");
    check(oob_ap == 0, "no AXI beat past ap_bytes_i");
    check_axi_bal();
  endtask

  // used ring outside the guest window: mp err on the publish write
  // raises bus_fault_o, halts the queue, publishes nothing
  task automatic neg_used_oob();
    int unsigned u0c, t;
    vq0.used = 64'h40;             // outside every window
    u0c = u_count;
    push_avail(0, Q0N + 3);        // faulting chain, still publishes len 0
    do_notify(0);
    t = 0;
    while (!bfault && t < 200_000) begin @(posedge clk); t++; end
    check(bfault, "bus_fault_o on used-ring OOB");
    t = 0;
    while (t < 2_000) begin @(posedge clk); t++; end
    check(u_count == u0c, "nothing published after bus fault");
    // queue halted: a further notify produces no publication
    push_avail(0, Q0N + 4);
    notify[0] = 1'b1;
    t = 0;
    while (t < 5_000 && u_count == u0c) begin @(posedge clk); t++; end
    notify[0] = 1'b0;
    check(u_count == u0c, "queue halted after bus fault");
    check_axi_bal();
  endtask

  // reset mid-session: compute work in flight -> reset_done bounded,
  // no AXI after done, objtab drained, then a fresh session passes
  task automatic neg_reset();
    // stage a real chain so engines are busy when reset lands
    put_desc(0, 0, GB + 64'h4000, 32'd4, 16'h0, 16'h0);
    push_avail(0, 0);
    do_notify(0);
    repeat (200) @(posedge clk);   // engines mid-flight
    rreq = 1'b1;
    begin
      int unsigned t = 0;
      while (!rdone && t < 100_000) begin @(posedge clk); t++; end
      check(rdone, "reset_done_o within bound");
      check(t < 50_000, "reset_done bound tight");
    end
    repeat (50) @(posedge clk);
    check(post_rst_axi == 0, "no AXI beat after reset_done");
    check(ot_live == 0, "objtab drained by reset");
    rreq = 1'b0;
    repeat (8) @(posedge clk);
    // rebuild queue state and replay the transport session cleanly
    vq_init(APU_VG_SHM_BYTES);
    $readmemh("vn_vectors/ue_sm5_transport.hex", tape, 0);
    $readmemh("vn_vectors/ue_sm5_transport.exp", expm, 0);
    tp = 0; ep = 0;
    play_tape();
    check_axi_bal();
  endtask

  // cursor queue: publishes {id, 0} itself, vgtop never sees a chain
  task automatic neg_cursor();
    put_desc(1, 0, GB + 64'h4000, 32'd4, 16'h0, 16'h0);
    push_avail(1, 0);
    do_notify(1);
    wait_used(1);
    check(u_qid_s == 1 && u_len_s == 0, "cursor publishes len 0");
    check_used_img(1, 0, 0);
    check(!chain_seen, "cursor element never reaches vgctl");
    check_axi_bal();
  endtask

  // batching: three avail entries then one notify -> three ordered
  // publications.  The tape chains all share one request buffer (a
  // sequential-execution tape), so staged copies would race; the arm
  // instead builds three identical GET_CAPSET_INFO chains at three
  // distinct buffer pairs, heads {0,2,4}.
  task automatic neg_batch();
    int unsigned c0;
    for (int c = 0; c < 3; c++) begin
      int unsigned rq = 32'h20000 + 32'(c) * 32'h100;   // req buffer
      int unsigned rp = 32'h20800 + 32'(c) * 32'h100;   // resp buffer
      for (int i = 0; i < 8; i++)
        gw(rq + 32'(4 * i), (i == 0) ? 32'h0108 : 32'h0);
      put_desc(0, 2 * c,     GB + rq, 32'd32, VF_NEXT, 16'(2 * c + 1));
      put_desc(0, 2 * c + 1, GB + rp, 32'd40, VF_WRITE, 16'h0);
      push_avail(0, 2 * c);
    end
    c0 = u_count;
    do_notify(0);
    for (int c = 0; c < 3; c++) begin
      wait_used(0);
      check(u_qid_s == 0, "batch used qid");
      // GET_CAPSET_INFO: 32 req bytes + 40 resp bytes
      check(u_len_s == 32'd72,
            $sformatf("batch used_len got=%08x exp=%08x", u_len_s, 72));
      check_used_img(0, 2 * c, u_len_s);
    end
    // u_count increments on the handshake edge; settle past it
    repeat (4) @(posedge clk);
    check(u_count == c0 + 3, "three publications from one notify");
    check_axi_bal();
  endtask

  // flush mid-issue (review R1): an mp request accepted but not yet
  // issued to AXI may be dropped by flush, but once an AW/W/AR beat is
  // being accepted the transaction must run to completion — the drop
  // must not strand an accepted beat.  Two sub-cases: reset_req_i in
  // the cycle ar_ready rises for a stalled AR, and in the cycle
  // aw_ready+w_ready rise for a stalled response write.
  task automatic neg_flush();
    int unsigned t;
    // ---- read: stall AR, flush on the accepting edge --------------
    stall_ar = 1'b1;
    put_desc(0, 0, GB + 64'h4000, 32'd4, 16'h0, 16'h0);
    push_avail(0, 0);
    do_notify(0);
    t = 0;
    while (!areq.ar_valid && t < 100_000) begin @(posedge clk); t++; end
    check(areq.ar_valid, "neg_flush: walker AR offered");
    rreq     = 1'b1;
    stall_ar = 1'b0;              // AR accepted this edge, under flush
    t = 0;
    while (!rdone && t < 100_000) begin @(posedge clk); t++; end
    check(rdone, "neg_flush: reset_done after accepted AR completes");
    check_axi_bal();
    notify[0] = 1'b0;
    rreq      = 1'b0;
    repeat (10) @(posedge clk);
    // ---- write: stall AW+W, flush on the accepting edge -----------
    vq_init(APU_VG_SHM_BYTES);
    stall_aw = 1'b1; stall_w = 1'b1;
    for (int i = 0; i < 8; i++)
      gw(32'h21000 + 32'(4 * i), (i == 0) ? 32'h0108 : 32'h0);
    put_desc(0, 0, GB + 32'h21000, 32'd32, VF_NEXT, 16'd1);
    put_desc(0, 1, GB + 32'h21100, 32'd40, VF_WRITE, 16'h0);
    push_avail(0, 0);
    do_notify(0);
    t = 0;
    while (!areq.aw_valid && t < 500_000) begin @(posedge clk); t++; end
    check(areq.aw_valid, "neg_flush: write AW offered");
    rreq     = 1'b1;
    stall_aw = 1'b0; stall_w = 1'b0;   // AW+W accepted under flush
    t = 0;
    while (!rdone && t < 100_000) begin @(posedge clk); t++; end
    check(rdone, "neg_flush: reset_done after accepted AW+W+B");
    rreq = 1'b0;
    repeat (10) @(posedge clk);
    check(post_rst_axi == 0, "neg_flush: no beats after reset_done");
    check_axi_bal();
  endtask

  // queue drop mid-request (review R2): queue_enable_i falling while
  // the walker waits on an mp response must drain the pending rsp in
  // StAbort — never issue a new beat with one outstanding, and never
  // let a stale response feed a later request.  Re-enabling restarts
  // the queue's counters at 0.
  task automatic neg_qdrop();
    int unsigned t;
    // the slave accepts the avail.idx AR then holds R back for 40
    // cycles, so the queue can be dropped with a response genuinely
    // in flight (walker parked in StIdxW with mp_pend set)
    axi_rd_dly = 40;
    put_desc(0, 0, GB + 64'h4000, 32'd4, 16'h0, 16'h0);
    put_desc(0, 1, GB + 32'h21400, 32'd32, VF_NEXT, 16'd2);
    put_desc(0, 2, GB + 32'h21500, 32'd40, VF_WRITE, 16'h0);
    for (int i = 0; i < 8; i++)
      gw(32'h21400 + 32'(4 * i), (i == 0) ? 32'h0108 : 32'h0);
    push_avail(0, 0);
    notify[0] = 1'b1;
    t = 0;
    while (ar_n == 0 && t < 100_000) begin @(posedge clk); t++; end
    check(ar_n == 1 && r_n == 0, "neg_qdrop: AR accepted, R held");
    qen[0]    = 1'b0;                 // drop the queue mid-wait
    notify[0] = 1'b0;
    repeat (10) @(posedge clk);
    // re-enable + re-notify while the stale response is still
    // pending: StAbort must hold acquisition until the pending R
    // returns — no new master beat may be issued meanwhile (the
    // slave-side <=1-outstanding invariant is always on)
    qen[0] = 1'b1;
    gh(qavail(0) + 4, 16'd1);          // ring[0] = head 1
    gh(qavail(0) + 2, 16'd1);          // avail.idx = 1
    av_push[0] = 1;
    uexp[0]    = 0;                    // queue counters restart at 0
    notify[0] = 1'b1;
    repeat (10) @(posedge clk);        // R still in flight
    check(ar_beats > r_n && aw_n == w_n && w_n == b_n,
          "neg_qdrop: pending R beats not yet delivered");
    // the delayed R lands, StAbort drains it, and the re-notified
    // element is walked and published as position 0 of the new epoch
    wait_used(0);
    notify[0] = 1'b0;
    check(u_len_s == 32'd72,
          $sformatf("neg_qdrop used len got=%0d exp=72", u_len_s));
    check_used_img(0, 1, u_len_s);     // pos 0, used.idx -> 1
    check_axi_bal();
  endtask

  // response write outside the guest window (review R4): the vgctl
  // write errs -> sticky mem_fault -> bus_fault_o, no AXI beat to that
  // address (the window assert fires first otherwise), and the used
  // element publishes the truthful header-only length: the consumed
  // 32-byte request, zero response words written.
  task automatic neg_resp_oob();
    int unsigned f0;
    f0 = fcnt;
    for (int i = 0; i < 8; i++)
      gw(32'h21800 + 32'(4 * i), (i == 0) ? 32'h0108 : 32'h0);
    put_desc(0, 0, GB + 32'h21800, 32'd32, VF_NEXT, 16'd1);
    put_desc(0, 1, 64'h40, 32'd40, VF_WRITE, 16'h0);   // outside window
    push_avail(0, 0);
    do_notify(0);
    wait_used(0);
    check(u_len_s == 32'd32,
          $sformatf("resp-oob used len got=%0d exp=32", u_len_s));
    check_used_img(0, 0, u_len_s);
    check(bfault, "bus_fault_o on response write OOB");
    check(fcnt > f0, "resp-oob counted as mp fault");
    check_axi_bal();
  endtask

  // WorkSink=0 (the §6c-ii SoC seam): i_ws0 owns the queues and the
  // AXI slave.  A session whose submit carries a non-dispatch record
  // gets refused UNSUPPORTED one cycle after accept -> cmdexec marks
  // the submission DEVICE_LOST (flost_q plus the 0xFFFF_FFFC vk
  // result visible in the guest response), the chain still publishes,
  // nothing hangs, and the following session passes.
  task automatic neg_worksink0();
    int unsigned pubs0;
    pubs0 = u_count;
    // worksink variant: the submit's CB records a vkCmdDispatchIndirect
    // — a non-dispatch CLS_WORK record the WorkSink=0 backend refuses.
    // The tape's own expectations are truthful: the wait-class replies
    // expect the 0xFFFF_FFC DEVICE_LOST result (CK_REPLY).
    $readmemh("vn_vectors/ue_ws0_bufcopy_1.hex", tape, 0);
    $readmemh("vn_vectors/ue_ws0_bufcopy_1.exp", expm, 0);
    tp = 0; ep = 0;
    play_tape();
    repeat (200) @(posedge clk);
    check(u_count > pubs0, "worksink0: chains still publish");
    check(|i_ws0.gen_on.i_top.gen_on.i_exec.gen_on.flost_q,
          "worksink0: cmdexec fence lost (DEVICE_LOST)");
    check_axi_bal();
    // next session passes: after DEVICE_LOST the driver reinitialises
    // — a backend reset clears the fence-lost state (it is in the
    // engine reset domain), then a fresh transport session replays.
    rreq = 1'b1;
    begin
      int unsigned tr = 0;
      while (!w_rdone && tr < 100_000) begin @(posedge clk); tr++; end
      check(w_rdone, "worksink0: reset_done after lost session");
    end
    rreq = 1'b0;
    repeat (8) @(posedge clk);
    vq_init(APU_VG_SHM_BYTES);
    $readmemh("vn_vectors/ue_sm5_transport.hex", tape, 0);
    $readmemh("vn_vectors/ue_sm5_transport.exp", expm, 0);
    tp = 0; ep = 0;
    play_tape();
    check_axi_bal();
    cases++;
  endtask

  // --------------------------------------------------------------------------
  initial begin
    string vname;
    if (!$value$plusargs("vec=%s", vname)) vname = "ue_sm5_transport";
    if (vname != "") $display("session tape: %s", vname);
    do_reset();
    if (vname == "neg_next_loop") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_next_loop();
    end else if (vname == "neg_desc_oob") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_desc_oob();
    end else if (vname == "neg_buf_oob") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_buf_oob();
    end else if (vname == "neg_aperture") begin
      vq_init(64'h100);            // present only 256 B of aperture
      neg_aperture();
    end else if (vname == "neg_used_oob") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_used_oob();
    end else if (vname == "neg_reset") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_reset();
    end else if (vname == "neg_cursor") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_cursor();
    end else if (vname == "neg_batch") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_batch();
    end else if (vname == "neg_flush") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_flush();
    end else if (vname == "neg_qdrop") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_qdrop();
    end else if (vname == "neg_resp_oob") begin
      vq_init(APU_VG_SHM_BYTES);
      neg_resp_oob();
    end else if (vname == "neg_worksink0") begin
      ws_arm_q = 1'b1;             // i_ws0 owns queues + AXI slave
      vq_init(APU_VG_SHM_BYTES);
      neg_worksink0();
    end else begin
      vq_init(APU_VG_SHM_BYTES);
      $readmemh({"vn_vectors/", vname, ".hex"}, tape, 0);
      $readmemh({"vn_vectors/", vname, ".exp"}, expm, 0);
      tp = 0; ep = 0;
      play_tape();
      check_axi_bal();
    end

    if (errors == 0) begin
      if (g1_n != 0)
        $display("PASS-COMPUTE g1=%0d g2=%0d ulp1=%0d ulp2=%0d maxulp=%0d cycles=%0d",
                 g1_n, g2_n, ulp1, ulp2, maxulp, cycles);
      $display("PASS tb_g6lc_apu_vgsys cases=%0d checks=%0d cycles=%0d",
               cases, checks, cycles);
    end else
      $display("FAIL tb_g6lc_apu_vgsys cases=%0d checks=%0d errors=%0d",
               cases, checks, errors);
    $finish;
  end
endmodule
