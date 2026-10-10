// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Venus ring pump (§6b of architecture/uncore/apu-vulkan-engine.md).
// Owns <= Rings ring descriptors (geometry from vkCreateRingMESA), the
// reply-stream state {blob aperture base, size, pos}, a virtqueue
// seqno counter, one aperture word port and one guest-memory read
// port.  It executes Venus command streams from three sources:
//   * a created ring's buffer      (aperture, vn_ring wrap semantics)
//   * a SUBMIT_3D execbuffer       (guest memory, xs_* hand-off)
//   * an ExecuteCommandStreams     (aperture blob window, depth 1)
//
// Per command the pump first decodes through a private g6lc_apu_vndec
// (type, consumed `words`, fault).  TRANSPORT-class commands
// (APU_VN_ACT_TRANSPORT) are executed by the pump itself: the whole
// command is staged into tbuf (<= TBUF words) and arguments are
// parsed at the wire offsets used by
// tools/vn_golden.py::TransportModel.t_cmd.  Every other command runs
// through g6lc_apu_vnfront on the same translated stream window and
// the current reply window.
//
// Ring semantics (vn_ring.c): tail/head are u32 byte seqnos; the
// buffer is power-of-two and commands wrap at `buf_size-1`; the pump
// polls tail while a ring is active, consumes [head,tail), stores
// head only after the command's reply/side effects, parks with IDLE
// after idleTimeout polls of no work, clears IDLE on NotifyRing, and
// sets FATAL on any decode/stream fault with no further head advance.
// WaitRingSeqno/WaitVirtqueueSeqno park the current stream until the
// condition holds.
//
// Timing impact: one aperture or guest-mem word per micro-step; the
// transport staging is a <=40-word sequential fetch.  No SRAM; ring
// descriptors and stream state are flops.
//
// Review checklist: async active-low reset; no latches; single
// always_ff for state; Enable=0 elaborates no datapath.  Deviation
// noted for review: a replying command issued with no reply window
// (never produced by the driver) faults FATAL through the vnrep
// overrun path, where Mesa would discard the reply.

module g6lc_apu_vnpump
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable  = 1'b0,
  parameter int unsigned Rings   = 4,
  parameter int unsigned Streams = 4,   // max ExecuteCommandStreams n
  parameter int unsigned TBUF    = 40   // transport arg stage words
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  // execbuffer hand-off from vgctl (guest-memory stream)
  input  logic            xs_valid_i,
  output logic            xs_ready_o,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_desc_i,
  input  logic [3:0]      xs_ndesc_i,
  input  logic [31:0]     xs_off_i,      // payload byte off in read space
  input  logic [31:0]     xs_bytes_i,
  input  logic [7:0]      xs_ctx_i,
  output logic            xs_done_o,
  output logic            xs_fault_o,
  output logic            xs_active_o,   // pump owns the guest-mem port
  // shared memory port (§6c apu_mp handshake): one request at a time
  // for aperture words (dom=1, aperture-relative byte offset),
  // execbuffer guest reads (dom=0, absolute guest byte address), pump
  // head/status writes and vnrep reply writes.  Requests are held
  // until mp_ready_i; exactly one mp_rvalid_i returns per request —
  // writes included.  mp_err_i returns zero data, no usable beat.
  output logic            mp_req_o,
  output logic            mp_we_o,
  output logic            mp_dom_o,
  output logic [63:0]     mp_addr_o,
  output logic [63:0]     mp_wdata_o,
  output logic [7:0]      mp_wstrb_o,
  input  logic            mp_ready_i,
  input  logic            mp_rvalid_i,
  input  logic [63:0]     mp_rdata_i,
  input  logic            mp_err_i,
  // ObjTab port (shared pump/front, muxed inside)
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i,
  // CmdRec pass-through (vnfront inside)
  output logic            cr_req_valid_o,
  input  logic            cr_req_ready_i,
  output apu_cmdrec_req_t cr_req_o,
  input  logic            cr_cpl_valid_i,
  output logic            cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t cr_cpl_i,
  // CmdRec payload stream pass-through (vnfront inside)
  output logic            cr_pay_valid_o,
  output logic [31:0]     cr_pay_data_o,
  input  logic            cr_pay_ready_i,
  // ObjPay port (vnfront inside)
  output logic            op_req_valid_o,
  input  logic            op_req_ready_i,
  output apu_objpay_req_t op_req_o,
  input  logic            op_cpl_valid_i,
  output logic            op_cpl_ready_o,
  input  apu_objpay_cpl_t op_cpl_i,
  // ShaderCore slot/stage/commit pass-through (vnfront inside, §7b)
  output logic               sm_req_o,
  output apu_sh_sm_req_t     sm_req_pl_o,
  input  logic               sm_cpl_i,
  input  apu_sh_sm_cpl_t     sm_cpl_pl_i,
  output logic               sh_wr_en_o,
  output logic [2:0]         sh_wr_slot_o,
  output logic [15:0]        sh_wr_addr_o,
  output logic [31:0]        sh_wr_data_o,
  output logic               sh_commit_o,
  output apu_sh_commit_t     sh_commit_pl_o,
  input  logic               sh_c_done_i,
  input  apu_sh_cpl_t        sh_c_done_pl_i,
  // aperture page allocator pass-through (vnfront inside, §7b)
  output logic               pg_req_valid_o,
  input  logic               pg_req_ready_i,
  output apu_vgpages_req_t   pg_req_o,
  input  logic               pg_cpl_valid_i,
  output logic               pg_cpl_ready_o,
  input  apu_vgpages_cpl_t   pg_cpl_i,
  // cmdexec pass-through (vnfront inside)
  output logic               ex_submit_valid_o,
  input  logic               ex_submit_ready_i,
  output apu_cmdexec_submit_t ex_submit_o,
  input  logic [15:0]        ex_done_seq_i,
  input  logic [15:0]        ex_fence_signaled_i,
  input  logic [15:0]        ex_fence_lost_i,
  output logic [15:0]        ex_fence_clr_o,
  // context kill (§12.3 5b-r2): registered pulse from vgctl's
  // CTX_DESTROY — retire the context's rings deterministically so a
  // later memory blob remapped at the same window never sees a dead
  // ring's FATAL/idle status or head publish
  input  logic               ctx_kill_valid_i,
  input  logic [7:0]         ctx_kill_id_i,
  // observability
  output logic            busy_o,
  output logic [Rings-1:0]       ring_active_o,
  output logic [Rings-1:0][31:0] ring_status_o,
  output logic [Rings-1:0][31:0] ring_head_o,
  output logic [Rings-1:0][APU_VG_AP_WORD_W-1:0] ring_extra_w_o
);
  localparam logic [1:0] SK_RING = 2'd0, SK_LIN_AP = 2'd1,
                        SK_LIN_GM = 2'd2;
  localparam int unsigned TW = APU_VN_DEC_TYPE_MAX + 1;
  // Venus vkCreateRingMESA carries idleTimeout as a u64 in *nanoseconds*.
  // The pump has no wall clock — it counts ring-poll rounds — so the
  // requested timeout is saturated to IdleToMax rounds.  That keeps the
  // IDLE/ALIVE status refresh cadence bounded (the Mesa ring watchdog
  // clears ALIVE on every warn iteration and needs the renderer to
  // re-assert it while the ring is parked); a shorter renderer-side idle
  // timeout only costs the guest extra vkNotifyRingMESA submits.
  localparam logic [31:0] IdleToMax = 32'd32;

  if (!Enable) begin : gen_off
    assign xs_ready_o = 1'b0;   assign xs_done_o = 1'b0;
    assign xs_fault_o = 1'b0;   assign xs_active_o = 1'b0;
    assign mp_req_o = 1'b0;     assign mp_we_o = 1'b0;
    assign mp_dom_o = 1'b0;     assign mp_addr_o = '0;
    assign mp_wdata_o = '0;     assign mp_wstrb_o = '0;
    assign ot_req_valid_o = 1'b0; assign ot_req_o = '0;
    assign ot_cpl_ready_o = 1'b0;
    assign cr_req_valid_o = 1'b0; assign cr_req_o = '0;
    assign cr_cpl_ready_o = 1'b0;
    assign cr_pay_valid_o = 1'b0; assign cr_pay_data_o = '0;
    assign op_req_valid_o = 1'b0; assign op_req_o = '0;
    assign op_cpl_ready_o = 1'b0;
    assign sm_req_o = 1'b0;        assign sm_req_pl_o = '0;
    assign sh_wr_en_o = 1'b0;      assign sh_wr_slot_o = '0;
    assign sh_wr_addr_o = '0;      assign sh_wr_data_o = '0;
    assign sh_commit_o = 1'b0;     assign sh_commit_pl_o = '0;
    assign pg_req_valid_o = 1'b0;  assign pg_req_o = '0;
    assign pg_cpl_ready_o = 1'b0;
    assign ex_submit_valid_o = 1'b0; assign ex_submit_o = '0;
    assign ex_fence_clr_o = '0;
    assign busy_o = 1'b0;
    for (genvar g = 0; g < Rings; g++) begin : g_off_ring
      assign ring_active_o[g] = 1'b0;
      assign ring_status_o[g] = '0;
      assign ring_head_o[g] = '0;
      assign ring_extra_w_o[g] = '0;
    end
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | xs_valid_i |
                    (|xs_ndesc_i) | (|xs_off_i) | (|xs_bytes_i) |
                    (|xs_ctx_i) | (|mp_rdata_i) | mp_ready_i |
                    mp_rvalid_i | mp_err_i |
                    ot_req_ready_i | ot_cpl_valid_i | (|ot_cpl_i) |
                    cr_req_ready_i | cr_cpl_valid_i | (|cr_cpl_i) |
                    cr_pay_ready_i |
                    op_req_ready_i | op_cpl_valid_i | (|op_cpl_i) |
                    sm_cpl_i | (|sm_cpl_pl_i) |
                    sh_c_done_i | (|sh_c_done_pl_i) |
                    pg_req_ready_i | pg_cpl_valid_i | (|pg_cpl_i) |
                    ex_submit_ready_i | (|ex_done_seq_i) |
                    (|ex_fence_signaled_i) | (|ex_fence_lost_i) |
                    ctx_kill_valid_i | (|ctx_kill_id_i) |
                    (|xs_desc_i[0]) | (|xs_desc_i[1]) |
                    (|xs_desc_i[2]) | (|xs_desc_i[3]);
  end else begin : gen_on

    // ---- ring descriptor table ------------------------------------------
    typedef struct packed {
      logic        live;
      logic        fatal;
      logic        idle;          // aperture status IDLE bit we wrote
      logic [63:0] handle;
      logic [7:0]  ctx;
      logic [31:0] head;          // byte seqno consumed by device
      logic [APU_VG_AP_WORD_W-1:0] head_w;        // aperture word addrs
      logic [APU_VG_AP_WORD_W-1:0] tail_w;
      logic [APU_VG_AP_WORD_W-1:0] status_w;
      logic [APU_VG_AP_WORD_W-1:0] buf_w;
      logic [31:0] buf_size;      // bytes, power of two
      logic [APU_VG_AP_WORD_W-1:0] extra_w;
      logic [31:0] extra_size;
      logic [31:0] idle_to;
      logic [31:0] idle_cnt;
    } ring_t;
    ring_t ring_q [Rings];
    logic [63:0] vq_seqno_q;

    // ---- stream state (2-deep: outer + one exec window) ------------------
    typedef struct packed {
      logic        live;
      logic [1:0]  kind;          // SK_*
      logic [1:0]  ring;          // ring slot when SK_RING
      logic [31:0] base_head;     // ring head at stream start (bytes)
      logic [APU_VG_AP_WORD_W-1:0] base_w;        // ap word base (SK_LIN_AP)
      logic [31:0] bytes;         // stream size in bytes
      logic [31:0] pos;           // bytes consumed so far
      logic [7:0]  ctx;
      logic        ring_stream;
    } stream_t;
    stream_t st_q [2];
    logic        depth_q;
    logic        fatal_stream_q;

    // execbuffer desc table (guest read-space walk)
    apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_d_q;
    logic [3:0]   xs_n_q;
    logic [31:0]  xs_boff_q;

    // reply window
    logic        rep_live_q;
    logic [APU_VG_AP_WORD_W-1:0] rep_base_w_q;
    logic [31:0] rep_size_q;
    logic [31:0] rep_pos_q;       // bytes into the window

    // transport staging + working registers; indexed by depth_q so an
    // ExecuteCommandStreams window cannot clobber the outer command's
    // staged words / wire fields
    logic [31:0] tbuf [2][TBUF];
    logic [5:0]  tb_i;
    logic [15:0] cmd_words_q [2];
    logic [31:0] cmd_type_q [2];
    logic [3:0]  cmd_cn_q [2];
    logic [63:0] t_hnd_q, t_val_q, t_off64_q, t_size64_q;
    logic [31:0] t_rid_q;
    logic [3:0]  t_i_q;           // exec-window stream index
    logic [APU_VG_AP_WORD_W-1:0] blob_base_w_q;
    logic [63:0] blob_size_q;
    logic [APU_VG_AP_WORD_W-1:0] wr_addr_q;
    logic [31:0] wr_data_q;

    // poll bookkeeping
    logic [1:0]  poll_q;
    // §12.3 E: exponential poll backoff — an idle poll round (a full
    // sweep over the rings that found no new tail) waits `gap_q`
    // cycles before the next round; the gap doubles from 1 up to
    // PollGapMax and collapses to 0 on any new work, NotifyRing or
    // ring creation so a live ring's tail is not re-read every cycle
    // while it sits idle
    localparam int unsigned PollGapMax = 256;
    logic [8:0]  gap_q;
    logic [8:0]  gap_cnt_q;

    // ---- vndec + vnfront wiring -------------------------------------------
    logic        dec_start_q, dec_busy, dec_done, dec_re;
    logic [15:0] dec_addr;
    logic [31:0] dec_rdata;
    logic        dec_rdy, dec_rv;
    apu_vn_op_t  dec_op;
    g6lc_apu_vndec #(.Enable(1'b1)) i_dec (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .start_i(dec_start_q), .cs_base_i(16'h0),
      .cs_len_i(16'(st_q[depth_q].bytes - st_q[depth_q].pos > 32'hFFFF
                   ? 32'hFFFF : st_q[depth_q].bytes - st_q[depth_q].pos)),
      .cs_re_o(dec_re), .cs_addr_o(dec_addr), .cs_ready_i(dec_rdy),
      .cs_rvalid_i(dec_rv), .cs_rdata_i(dec_rdata), .cs_err_i(mp_err_i),
      .busy_o(dec_busy), .done_o(dec_done), .op_o(dec_op),
      // the pump-level decoder only frames transport headers; its
      // KEEP stream belongs to the vnfront's own decoder instance
      .pay_valid_o(), .pay_data_o());

    logic        fr_start_q, fr_busy, fr_done, fr_cre, fr_rwe;
    logic [15:0] fr_caddr, fr_raddr;
    logic [31:0] fr_rdata, fr_wdata;
    logic        fr_cs_rdy, fr_cs_rv, fr_rep_rdy, fr_rep_done;
    logic        fr_ot_v, fr_cpl_rdy;
    apu_objtab_req_t fr_ot_req;
    logic        fr_cr_v, fr_cr_cpl_rdy;
    apu_cmdrec_req_t fr_cr_req;
    logic        fr_op_v, fr_op_cpl_rdy;
    apu_objpay_req_t fr_op_req;
    // §12.3 F5: front descriptor-record aperture port, arbitrated
    // onto mp as owner OW_FAP (dom=1, aperture byte address)
    logic        fap_req, fap_we, fap_rdy, fap_done;
    logic [31:0] fap_addr;
    logic [63:0] fap_wdata;
    logic [7:0]  fap_wstrb;
    logic [31:0] fr_result;
    logic [15:0] fr_repn;
    logic [3:0]  fr_fault;

    g6lc_apu_vnfront #(.Enable(1'b1)) i_fr (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .start_i(fr_start_q),
      .cs_base_i(16'h0), .cs_len_i(cmd_words_q[depth_q]),
      .rep_base_i(16'(rep_pos_q >> 2)),
      .rep_len_i(rep_live_q ? 16'((rep_size_q - rep_pos_q) >> 2)
                            : 16'h0),
      .ctx_i(st_q[depth_q].ctx),
      .cs_re_o(fr_cre), .cs_addr_o(fr_caddr), .cs_ready_i(fr_cs_rdy),
      .cs_rvalid_i(fr_cs_rv), .cs_rdata_i(fr_rdata), .cs_err_i(mp_err_i),
      .rep_we_o(fr_rwe), .rep_addr_o(fr_raddr), .rep_wdata_o(fr_wdata),
      .rep_ready_i(fr_rep_rdy), .rep_done_i(fr_rep_done),
      .rep_err_i(mp_err_i),
      .ot_req_valid_o(fr_ot_v), .ot_req_ready_i(ot_req_ready_i),
      .ot_req_o(fr_ot_req),
      .ot_cpl_valid_i(ot_cpl_valid_i), .ot_cpl_ready_o(fr_cpl_rdy),
      .ot_cpl_i(ot_cpl_i),
      .cr_req_valid_o(fr_cr_v), .cr_req_ready_i(cr_req_ready_i),
      .cr_req_o(fr_cr_req),
      .cr_cpl_valid_i(cr_cpl_valid_i), .cr_cpl_ready_o(fr_cr_cpl_rdy),
      .cr_cpl_i(cr_cpl_i),
      .cr_pay_valid_o(cr_pay_valid_o), .cr_pay_data_o(cr_pay_data_o),
      .cr_pay_ready_i(cr_pay_ready_i),
      .op_req_valid_o(fr_op_v), .op_req_ready_i(op_req_ready_i),
      .op_req_o(fr_op_req),
      .op_cpl_valid_i(op_cpl_valid_i), .op_cpl_ready_o(fr_op_cpl_rdy),
      .op_cpl_i(op_cpl_i),
      .sm_req_o(sm_req_o), .sm_req_pl_o(sm_req_pl_o),
      .sm_cpl_i(sm_cpl_i), .sm_cpl_pl_i(sm_cpl_pl_i),
      .sh_wr_en_o(sh_wr_en_o), .sh_wr_slot_o(sh_wr_slot_o),
      .sh_wr_addr_o(sh_wr_addr_o), .sh_wr_data_o(sh_wr_data_o),
      .sh_commit_o(sh_commit_o), .sh_commit_pl_o(sh_commit_pl_o),
      .sh_c_done_i(sh_c_done_i), .sh_c_done_pl_i(sh_c_done_pl_i),
      .pg_req_valid_o(pg_req_valid_o), .pg_req_ready_i(pg_req_ready_i),
      .pg_req_o(pg_req_o),
      .pg_cpl_valid_i(pg_cpl_valid_i), .pg_cpl_ready_o(pg_cpl_ready_o),
      .pg_cpl_i(pg_cpl_i),
      .ap_req_o(fap_req), .ap_we_o(fap_we), .ap_addr_o(fap_addr),
      .ap_wdata_o(fap_wdata), .ap_wstrb_o(fap_wstrb),
      .ap_ready_i(fap_rdy), .ap_done_i(fap_done),
      .ap_rdata_i(mp_rdata_i), .ap_err_i(mp_err_i),
      .ex_submit_valid_o(ex_submit_valid_o),
      .ex_submit_ready_i(ex_submit_ready_i),
      .ex_submit_o(ex_submit_o),
      .ex_done_seq_i(ex_done_seq_i),
      .ex_fence_signaled_i(ex_fence_signaled_i),
      .ex_fence_lost_i(ex_fence_lost_i),
      .ex_fence_clr_o(ex_fence_clr_o),
      .busy_o(fr_busy), .done_o(fr_done), .result_o(fr_result),
      .rep_words_o(fr_repn), .fault_o(fr_fault));

    // ---- FSM ---------------------------------------------------------------
    typedef enum logic [5:0] {
      StIdle, StPollFire, StPollCap, StPollNext, StPollGap, StIdleWr,
      StDecFire, StDecWait, StFrontWait,
      StTrFire, StTrCap, StTrExec, StTrDo,
      StOtReq, StOtCpl, StOtDo, StCreate,
      StWinNext, StWaitVq, StWaitR,
      StApWr, StHeadWr, StNext, StDecNext, StXsDone,
      StFatal, StFatalWr, StFatalNext, StFatalWr2
    } state_e;
    state_e state_q;

    // ---- stream byte addressing --------------------------------------------
    // byte offset of a word index within the current stream
    function automatic logic [APU_VG_AP_WORD_W-1:0] apw(input logic [31:0] boff);
      if (st_q[depth_q].kind == SK_RING)
        return ring_q[st_q[depth_q].ring].buf_w +
               APU_VG_AP_WORD_W'(((st_q[depth_q].base_head + boff) &
                    (ring_q[st_q[depth_q].ring].buf_size - 32'd1))
                   >> 2);
      return st_q[depth_q].base_w + APU_VG_AP_WORD_W'(boff >> 2);
    endfunction

    // guest-memory byte address for execbuffer stream byte `boff`
    function automatic logic [63:0] gma(input logic [31:0] boff);
      logic [31:0] acc;
      acc = 32'h0;
      for (int i = 0; i < APU_VG_MAX_DESC; i++) begin
        if (i < xs_n_q && !xs_d_q[i].write) begin
          if (boff >= acc && boff < acc + xs_d_q[i].len)
            return xs_d_q[i].addr + 64'(boff - acc);
          acc = acc + xs_d_q[i].len;
        end
      end
      return xs_d_q[0].addr + 64'(boff);
    endfunction

    // combined decoder read strobe (vndec or vnfront cs)
    logic        cs_re;
    logic [15:0] cs_addr;
    assign cs_re   = dec_re | fr_cre;
    assign cs_addr = dec_re ? dec_addr : fr_caddr;
    logic cs_via_gm;
    assign cs_via_gm = st_q[depth_q].kind == SK_LIN_GM;

    // ---- pump's own aperture/guest access ------------------------------------
    logic pump_re, pump_we, pump_gm;
    logic [APU_VG_AP_WORD_W-1:0] pump_addr;
    // the transport fetch reads word tb_i of the current command
    logic [31:0] rd_boff;
    assign rd_boff = st_q[depth_q].pos +
                     ((state_q == StTrFire) ? (32'(tb_i) << 2)
                                            : (32'(cs_addr) << 2));

    assign pump_re = (state_q == StPollFire &&
                      ring_q[poll_q].live && !ring_q[poll_q].fatal) ||
                     ((state_q == StTrFire) && !cs_via_gm);
    assign pump_gm = (state_q == StTrFire) && cs_via_gm;
    assign pump_we = (state_q == StApWr)   || (state_q == StIdleWr) ||
                     (state_q == StHeadWr) || (state_q == StFatalWr) ||
                     (state_q == StFatalWr2);
    always_comb begin
      pump_addr = '0;
      unique case (state_q)
        StPollFire: pump_addr = ring_q[poll_q].tail_w;
        StTrFire:   pump_addr = apw(rd_boff);
        default:    pump_addr = wr_addr_q;
      endcase
    end

    // ---- shared mp port arbitration ------------------------------------------
    // One request outstanding.  Fixed pick order: pump writes, front
    // reply writes, front descriptor-aperture traffic, front/decoder
    // CS reads, pump ring/transport reads.
    // The pick is academic — the engines serialize themselves (front
    // runs alone, pump write/read states run while it is idle) — but
    // a stall is always safe since every requester holds its request.
    typedef enum logic [2:0] {
      OW_NONE, OW_PWR, OW_FRW, OW_FAP, OW_DEC, OW_FRD, OW_PRD
    } owner_e;
    owner_e src;
    owner_e rsp_owner_q;
    logic   rsp_hi_q;          // addr[2] of the accepted request
    logic [APU_VG_AP_WORD_W-1:0] fr_waddr;
    assign fr_waddr = rep_base_w_q + APU_VG_AP_WORD_W'(fr_raddr);
    always_comb begin
      src         = OW_NONE;
      mp_req_o    = 1'b0;
      mp_we_o     = 1'b0;
      mp_dom_o    = 1'b0;
      mp_addr_o   = '0;
      mp_wdata_o  = '0;
      mp_wstrb_o  = '0;
      // one request outstanding: while a response is pending no new
      // request is issued (requesters simply hold)
      if (rsp_owner_q != OW_NONE) begin end
      else if (pump_we) begin
        src        = OW_PWR;
        mp_req_o   = 1'b1;
        mp_we_o    = 1'b1;
        mp_dom_o   = 1'b1;
        mp_addr_o  = {(62-APU_VG_AP_WORD_W)'(1'b0), wr_addr_q, 2'b00};
        mp_wdata_o = {2{wr_data_q}};
        mp_wstrb_o = wr_addr_q[0] ? 8'hF0 : 8'h0F;
      end else if (fr_rwe) begin
        src        = OW_FRW;
        mp_req_o   = 1'b1;
        mp_we_o    = 1'b1;
        mp_dom_o   = 1'b1;
        mp_addr_o  = {(62-APU_VG_AP_WORD_W)'(1'b0), fr_waddr, 2'b00};
        mp_wdata_o = {2{fr_wdata}};
        mp_wstrb_o = fr_waddr[0] ? 8'hF0 : 8'h0F;
      end else if (fap_req) begin
        // front descriptor records: full 64-bit aperture access
        src        = OW_FAP;
        mp_req_o   = 1'b1;
        mp_we_o    = fap_we;
        mp_dom_o   = 1'b1;
        mp_addr_o  = {32'h0, fap_addr};
        mp_wdata_o = fap_wdata;
        mp_wstrb_o = fap_wstrb;
      end else if (cs_re) begin
        src       = dec_re ? OW_DEC : OW_FRD;
        mp_req_o  = 1'b1;
        mp_we_o   = 1'b0;
        if (cs_via_gm) begin
          mp_dom_o   = 1'b0;
          mp_addr_o  = gma(xs_boff_q + rd_boff);
        end else begin
          mp_dom_o   = 1'b1;
          mp_addr_o  = {(62-APU_VG_AP_WORD_W)'(1'b0), apw(rd_boff), 2'b00};
        end
      end else if (pump_re) begin
        src       = OW_PRD;
        mp_req_o  = 1'b1;
        mp_we_o   = 1'b0;
        mp_dom_o  = 1'b1;
        mp_addr_o = {(62-APU_VG_AP_WORD_W)'(1'b0), pump_addr, 2'b00};
      end else if (pump_gm) begin
        src       = OW_PRD;
        mp_req_o  = 1'b1;
        mp_we_o   = 1'b0;
        mp_dom_o  = 1'b0;
        mp_addr_o = gma(xs_boff_q + rd_boff);
      end
    end

    // response routing: the pending request's owner sees rvalid; the
    // 32-bit payload is the half selected by the issued address bit 2
    logic [31:0] mp_rd32;
    assign mp_rd32    = rsp_hi_q ? mp_rdata_i[63:32] : mp_rdata_i[31:0];
    assign dec_rdy    = mp_ready_i && src == OW_DEC;
    assign fr_cs_rdy  = mp_ready_i && src == OW_FRD;
    assign fr_rep_rdy = mp_ready_i && src == OW_FRW;
    assign fap_rdy    = mp_ready_i && src == OW_FAP;
    assign fap_done   = mp_rvalid_i && rsp_owner_q == OW_FAP;
    assign dec_rv       = mp_rvalid_i && rsp_owner_q == OW_DEC;
    assign fr_cs_rv     = mp_rvalid_i && rsp_owner_q == OW_FRD;
    assign fr_rep_done  = mp_rvalid_i && rsp_owner_q == OW_FRW;
    logic pump_rd_done, pump_wr_done;
    assign pump_rd_done = mp_rvalid_i && rsp_owner_q == OW_PRD;
    assign pump_wr_done = mp_rvalid_i && rsp_owner_q == OW_PWR;
    // ctx-kill same-cycle guard: a kill pulse landing in the cycle a
    // ring stream was about to publish head or write FATAL status must
    // still suppress the write (the registered retire applies from
    // the next cycle)
    wire kill_strm = ctx_kill_valid_i &&
                     st_q[depth_q].ctx == ctx_kill_id_i;
    wire kill_strm0 = ctx_kill_valid_i &&
                      st_q[0].ctx == ctx_kill_id_i;
    assign dec_rdata = mp_rd32;
    assign fr_rdata  = mp_rd32;

    // ---- ObjTab mux (front while busy, pump otherwise) ------------------------
    logic pump_ot_v, pump_ot_cpl_rdy;
    apu_objtab_req_t pump_ot_req;
    assign ot_req_valid_o = fr_busy ? fr_ot_v : pump_ot_v;
    assign ot_req_o       = fr_busy ? fr_ot_req : pump_ot_req;
    assign ot_cpl_ready_o = fr_busy ? fr_cpl_rdy : pump_ot_cpl_rdy;
    assign cr_req_valid_o = fr_cr_v;
    assign cr_req_o = fr_cr_req;
    assign cr_cpl_ready_o = fr_cr_cpl_rdy;
    assign op_req_valid_o = fr_op_v;
    assign op_req_o = fr_op_req;
    assign op_cpl_ready_o = fr_op_cpl_rdy;

    // pump's own ObjTab request: LOOKUP a transport resource id
    // (kind is enforced for non-ALLOC resolves -> BLOB_SHMEM)
    assign pump_ot_req = '{op: APU_OBJTAB_OP_LOOKUP,
                           id: APU_VG_ID_TAG | {32'h0, t_rid_q},
                           kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM),
                           default: '0};
    assign pump_ot_v = state_q == StOtReq;
    assign pump_ot_cpl_rdy = state_q == StOtCpl;

    // the idle-poll sweep reports busy so observers see a sweep in
    // progress, but the inter-round backoff wait is quiescent: a
    // completed sweep that found no work deasserts busy_o exactly
    // where the un-paced loop used to pass through StIdle
    assign busy_o = state_q != StIdle && state_q != StPollGap;
    assign xs_ready_o = state_q == StIdle && rst_ni;
    assign xs_done_o = state_q == StXsDone;
    assign xs_fault_o = fatal_stream_q;
    assign xs_active_o = st_q[0].live && st_q[0].kind == SK_LIN_GM;
    for (genvar g = 0; g < Rings; g++) begin : g_ring_obs
      assign ring_active_o[g] = ring_q[g].live && !ring_q[g].fatal;
      // aperture status image: {ALIVE,FATAL,IDLE} (bit2/bit1/bit0)
      assign ring_status_o[g] =
        {29'h0, ring_q[g].live, ring_q[g].fatal, ring_q[g].idle};
      assign ring_head_o[g] = ring_q[g].head;
      assign ring_extra_w_o[g] = ring_q[g].extra_w;
    end

    // ring lookup by handle / first free slot (fixture sized)
    function automatic int ring_of(input logic [63:0] h);
      for (int i = 0; i < Rings; i++)
        if (ring_q[i].live && ring_q[i].handle == h) return i;
      return -1;
    endfunction
    function automatic int ring_free();
      for (int i = 0; i < Rings; i++)
        if (!ring_q[i].live) return i;
      return -1;
    endfunction

    // live ring g's poll tail or command buffer collides with a
    // candidate ring window [lo,hi) (or its buffer covers the
    // candidate): the guest reused the shmem window without
    // vkDestroyRingMESA (process teardown frees the blob while
    // the device slot stays live); the stale slot's cached head
    // would mis-frame the new owner's stream and its FATAL/idle
    // status writes would corrupt it, so the slot is retired
    function automatic logic ring_overlap(input int g,
        input logic [APU_VG_AP_WORD_W-1:0] lo,
        input logic [APU_VG_AP_WORD_W-1:0] hi);
      return ring_q[g].live &&
             ((lo <= ring_q[g].tail_w && ring_q[g].tail_w < hi) ||
              (lo <= ring_q[g].buf_w  && ring_q[g].buf_w  < hi) ||
              (ring_q[g].buf_w <= lo &&
               lo < ring_q[g].buf_w +
                    APU_VG_AP_WORD_W'(ring_q[g].buf_size >> 2)));
    endfunction

    // power of two and non-zero
    function automatic logic pow2nz(input logic [31:0] v);
      return v != 32'h0 && (v & (v - 32'd1)) == 32'h0;
    endfunction

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle;
        for (int i = 0; i < Rings; i++) ring_q[i] <= '{default: '0};
        st_q[0] <= '{default: '0}; st_q[1] <= '{default: '0};
        depth_q <= 1'b0; fatal_stream_q <= 1'b0;
        for (int i = 0; i < APU_VG_MAX_DESC; i++)
          xs_d_q[i] <= '{default: '0};
        xs_n_q <= '0; xs_boff_q <= '0;
        rep_live_q <= 1'b0; rep_base_w_q <= '0;
        rep_size_q <= '0; rep_pos_q <= '0; vq_seqno_q <= '0;
        for (int i = 0; i < TBUF; i++) begin
          tbuf[0][i] <= '0; tbuf[1][i] <= '0;
        end
        tb_i <= '0;
        cmd_words_q <= '{default: '0}; cmd_type_q <= '{default: '0};
        cmd_cn_q <= '{default: '0};
        t_hnd_q <= '0; t_val_q <= '0; t_off64_q <= '0; t_size64_q <= '0;
        t_rid_q <= '0; t_i_q <= '0;
        blob_base_w_q <= '0; blob_size_q <= '0;
        wr_addr_q <= '0; wr_data_q <= '0;
        poll_q <= '0; gap_q <= '0; gap_cnt_q <= '0;
        rsp_owner_q <= OW_NONE; rsp_hi_q <= 1'b0;
        dec_start_q <= 1'b0; fr_start_q <= 1'b0;
      end else begin
        dec_start_q <= 1'b0;
        fr_start_q <= 1'b0;
        // mp bookkeeping: one outstanding; accept tags the owner and
        // the addressed 32-bit half, the response frees the port
        if (mp_rvalid_i)
          rsp_owner_q <= OW_NONE;
        if (mp_req_o && mp_ready_i) begin
          rsp_owner_q <= src;
          rsp_hi_q    <= mp_addr_o[2];
        end

        // §12.3 5b-r2 CTX_DESTROY: retire every live ring of the dead
        // context with NO status write — the aperture window can be
        // re-assigned to another context's memory blob at once, and a
        // dead ring must never write FATAL/IDLE there.  In-flight ring
        // streams of that ctx are demoted (ring_stream <= 0) so they
        // neither publish head (StNext gate) nor write status on fault
        // (StFatal gate); they still drain their bytes harmlessly —
        // ObjTab lookups under the tombstoned ctx fail truthfully.
        // ring_overlap stays as defence in depth for window reuse.
        if (ctx_kill_valid_i) begin
          for (int i = 0; i < Rings; i++)
            if (ring_q[i].live && ring_q[i].ctx == ctx_kill_id_i)
              ring_q[i].live <= 1'b0;
          for (int i = 0; i < 2; i++)
            if (st_q[i].live && st_q[i].ring_stream &&
                st_q[i].ctx == ctx_kill_id_i)
              st_q[i].ring_stream <= 1'b0;
        end

        unique case (state_q)
          // ------------------------------------------------------------
          StIdle: begin
            if (xs_valid_i) begin
              gap_q <= '0; gap_cnt_q <= '0;   // new work: no backoff
              xs_d_q <= xs_desc_i;
              xs_n_q <= xs_ndesc_i;
              xs_boff_q <= xs_off_i;
              st_q[0] <= '{live: 1'b1, kind: SK_LIN_GM, ring: 2'h0,
                           base_head: '0, base_w: '0,
                           bytes: xs_bytes_i, pos: '0,
                           ctx: xs_ctx_i, ring_stream: 1'b0};
              depth_q <= 1'b0;
              fatal_stream_q <= 1'b0;
              state_q <= StDecFire;
            end else begin
              poll_q <= '0;
              state_q <= StPollFire;
            end
          end

          // ---- idle poll loop ----------------------------------------------
          StPollFire: begin
            // mp request on ring_q[poll_q].tail_w while in this state
            if (ring_q[poll_q].live && !ring_q[poll_q].fatal) begin
              if (mp_ready_i && src == OW_PRD)
                state_q <= StPollCap;
            end else if (poll_q == 2'(Rings - 1))
              state_q <= StPollGap;   // idle round complete
            else
              poll_q <= poll_q + 2'd1;
          end
          StPollCap: begin
            if (pump_rd_done) begin
              if (mp_err_i) begin
                // aperture miss on the ring tail: FATAL like a decode
                // fault, keep polling the rest
                ring_q[poll_q].fatal <= 1'b1;
                state_q <= StPollNext;
              end else if (mp_rd32 > ring_q[poll_q].head) begin
                st_q[0] <= '{live: 1'b1, kind: SK_RING, ring: poll_q,
                             base_head: ring_q[poll_q].head,
                             base_w: '0,
                             bytes: mp_rd32 - ring_q[poll_q].head,
                             pos: '0, ctx: ring_q[poll_q].ctx,
                             ring_stream: 1'b1};
                depth_q <= 1'b0;
                fatal_stream_q <= 1'b0;
                ring_q[poll_q].idle_cnt <= '0;
                gap_q <= '0; gap_cnt_q <= '0;   // new tail: no backoff
                state_q <= StDecFire;
              end else begin
                if (ring_q[poll_q].idle_cnt + 32'd1 >=
                    ring_q[poll_q].idle_to) begin
                  // periodic ALIVE|IDLE refresh (the guest ring watchdog
                  // clears ALIVE while it waits and needs re-assertion);
                  // re-arm the counter so writes happen every idle_to
                  // rounds, not every round
                  ring_q[poll_q].idle <= 1'b1;
                  ring_q[poll_q].idle_cnt <= '0;
                  wr_addr_q <= ring_q[poll_q].status_w;
                  wr_data_q <= APU_VNRING_ALIVE | APU_VNRING_IDLE;
                  state_q <= StIdleWr;
                end else begin
                  ring_q[poll_q].idle_cnt <=
                    ring_q[poll_q].idle_cnt + 32'd1;
                  state_q <= StPollNext;
                end
              end
            end
          end
          StIdleWr: begin
            if (pump_wr_done) begin
              if (mp_err_i) fatal_stream_q <= 1'b1;
              state_q <= StPollNext;
            end
          end
          StPollNext: begin
            if (poll_q == 2'(Rings - 1)) state_q <= StPollGap;
            else begin
              poll_q <= poll_q + 2'd1;
              state_q <= StPollFire;
            end
          end
          // §12.3 E: inter-round backoff — sit here for `gap_q` cycles
          // (a zero gap still costs one state visit, i.e. the first
          // idle round waits ~1 cycle), then double the gap up to
          // PollGapMax and start the next sweep.  An execbuf push
          // aborts the wait immediately
          StPollGap: begin
            if (xs_valid_i) begin
              gap_q <= '0; gap_cnt_q <= '0;
              state_q <= StIdle;
            end else if (gap_cnt_q + 9'd1 <
                         (gap_q == 9'd0 ? 9'd1 : gap_q)) begin
              gap_cnt_q <= gap_cnt_q + 9'd1;
            end else begin
              gap_cnt_q <= '0;
              gap_q     <= (gap_q == 9'd0)               ? 9'd2 :
                           (gap_q >= 9'(PollGapMax / 2)) ? 9'(PollGapMax)
                                                        : {gap_q[7:0], 1'b0};
              poll_q    <= '0;
              state_q   <= StPollFire;
            end
          end

          // ---- decode the command at the stream cursor ----------------------
          StDecFire: begin
            dec_start_q <= 1'b1;
            state_q <= StDecWait;
          end
          StDecWait: begin
            if (dec_done) begin
              cmd_type_q[depth_q] <= dec_op.cmd_type;
              cmd_words_q[depth_q] <= dec_op.words;
              cmd_cn_q[depth_q] <= dec_op.chain_n;
              if (dec_op.fault != APU_VN_FAULT_NONE)
                state_q <= StFatal;
              else if ((dec_op.cmd_type <= 32'(TW - 1)) &&
                  APU_VN_ACT[dec_op.cmd_type[8:0]].act_class
                  == APU_VN_ACT_TRANSPORT) begin
                tb_i <= '0;
                if (dec_op.words > 16'(TBUF)) state_q <= StFatal;
                else                          state_q <= StTrFire;
              end else begin
                fr_start_q <= 1'b1;
                state_q <= StFrontWait;
              end
            end
          end

          // ---- vnfront executes a regular command ----------------------------
          StFrontWait: begin
            if (fr_done) begin
              if (fr_fault != APU_VN_FAULT_NONE) begin
                state_q <= StFatal;
              end else begin
                rep_pos_q <= rep_pos_q + 32'(fr_repn) * 32'd4;
                state_q <= StNext;
              end
            end
          end

          // ---- transport: stage the whole command into tbuf ------------------
          StTrFire: begin
            if (mp_ready_i && src == OW_PRD)
              state_q <= StTrCap;
          end
          StTrCap: begin
            if (pump_rd_done) begin
              if (mp_err_i) begin
                state_q <= StFatal;      // memory fault = decode fault
              end else begin
                tbuf[depth_q][tb_i] <= mp_rd32;
                tb_i <= tb_i + 6'd1;
                if (tb_i + 6'd1 >= 6'(cmd_words_q[depth_q]))
                  state_q <= StTrExec;
                else
                  state_q <= StTrFire;
              end
            end
          end

          // ---- transport dispatch (args at fixed wire offsets) ---------------
          // layouts mirror vn_golden.py::TransportModel.t_cmd
          StTrExec: begin
            unique case (cmd_type_q[depth_q])
              32'hB2: begin // SetReply {rid w4, off w5-6, size w7-8}
                t_rid_q <= tbuf[depth_q][4];
                t_off64_q <= {tbuf[depth_q][6], tbuf[depth_q][5]};
                t_size64_q <= {tbuf[depth_q][8], tbuf[depth_q][7]};
                state_q <= StOtReq;
              end
              32'hB3: begin // SeekReply {pos w2-3}
                if (!rep_live_q || {tbuf[depth_q][3], tbuf[depth_q][2]} > 64'(rep_size_q))
                  state_q <= StFatal;
                else begin
                  rep_pos_q <= 32'({tbuf[depth_q][3], tbuf[depth_q][2]});
                  state_q <= StNext;
                end
              end
              32'hB4: begin // ExecuteCommandStreams
                if (depth_q || tbuf[depth_q][2] > 32'(Streams) ||
                    tbuf[depth_q][2] == 32'h0)
                  state_q <= StFatal;
                else begin
                  t_i_q <= '0;
                  t_rid_q <= tbuf[depth_q][5];
                  t_off64_q <= {tbuf[depth_q][7], tbuf[depth_q][6]};
                  t_size64_q <= {tbuf[depth_q][9], tbuf[depth_q][8]};
                  state_q <= StOtReq;
                end
              end
              32'hBC: begin // CreateRing
                // self fields start at f = 9 + 4*chain_n:
                //   f+0 flags, f+1 resourceId, f+2 off, f+4 size,
                //   f+6 idleTo, f+8 head, f+10 tail, f+12 status,
                //   f+14 buf, f+16 bufSize, f+18 extra, f+20 extraSize
                t_hnd_q <= {tbuf[depth_q][3], tbuf[depth_q][2]};
                t_rid_q <= tbuf[depth_q][10 + 4 * cmd_cn_q[depth_q]];
                state_q <= StOtReq;
              end
              32'hBD: begin // DestroyRing {hnd w2-3}
                t_hnd_q <= {tbuf[depth_q][3], tbuf[depth_q][2]};
                state_q <= StTrDo;
              end
              32'hBE: begin // NotifyRing {hnd w2-3}
                t_hnd_q <= {tbuf[depth_q][3], tbuf[depth_q][2]};
                state_q <= StTrDo;
              end
              32'hBF: begin // WriteRingExtra {hnd w2-3, off w4-5, val w6}
                t_hnd_q <= {tbuf[depth_q][3], tbuf[depth_q][2]};
                t_off64_q <= {tbuf[depth_q][5], tbuf[depth_q][4]};
                t_val_q <= 64'(tbuf[depth_q][6]);
                state_q <= StTrDo;
              end
              32'hFB: begin // SubmitVirtqueueSeqno {ring w2-3, seq w4-5}
                if ({tbuf[depth_q][5], tbuf[depth_q][4]} > vq_seqno_q)
                  vq_seqno_q <= {tbuf[depth_q][5], tbuf[depth_q][4]};
                state_q <= StNext;
              end
              32'hFC: begin // WaitVirtqueueSeqno {seq w2-3}
                if ({tbuf[depth_q][3], tbuf[depth_q][2]} <= vq_seqno_q)
                  state_q <= StNext;
                else
                  state_q <= StWaitVq;
              end
              32'hFD: begin // WaitRingSeqno {ring w2-3, seq w4-5}
                t_hnd_q <= {tbuf[depth_q][3], tbuf[depth_q][2]};
                t_val_q <= {tbuf[depth_q][5], tbuf[depth_q][4]};
                state_q <= StWaitR;
              end
              default: state_q <= StFatal;
            endcase
          end

          // per-command direct actions
          StTrDo: begin
            unique case (cmd_type_q[depth_q])
              32'hBD: begin // DestroyRing
                if (ring_of(t_hnd_q) < 0) state_q <= StFatal;
                else begin
                  ring_q[ring_of(t_hnd_q)].live <= 1'b0;
                  state_q <= StNext;
                end
              end
              32'hBE: begin // NotifyRing: clear IDLE (|= ~IDLE)
                if (ring_of(t_hnd_q) < 0) state_q <= StFatal;
                else begin
                  ring_q[ring_of(t_hnd_q)].idle_cnt <= '0;
                  ring_q[ring_of(t_hnd_q)].idle <= 1'b0;
                  gap_q <= '0; gap_cnt_q <= '0;
                  wr_addr_q <= ring_q[ring_of(t_hnd_q)].status_w;
                  wr_data_q <= APU_VNRING_ALIVE |
                               (ring_q[ring_of(t_hnd_q)].fatal
                                ? APU_VNRING_FATAL : 32'h0);
                  state_q <= StApWr;
                end
              end
              32'hBF: begin // WriteRingExtra
                if (ring_of(t_hnd_q) < 0) state_q <= StFatal;
                else if (t_off64_q + 64'd4 >
                         64'(ring_q[ring_of(t_hnd_q)].extra_size))
                  state_q <= StFatal;
                else begin
                  wr_addr_q <= ring_q[ring_of(t_hnd_q)].extra_w +
                               APU_VG_AP_WORD_W'(t_off64_q >> 2);
                  wr_data_q <= 32'(t_val_q);
                  state_q <= StApWr;
                end
              end
              default: state_q <= StFatal;
            endcase
          end

          // ---- ObjTab blob resolve (SetReply/ExecStreams/CreateRing) --------
          // hold valid until ready: the ObjTab port is arbitrated and
          // may not accept on the first cycle
          StOtReq: if (ot_req_ready_i) state_q <= StOtCpl;
          StOtCpl: begin
            if (ot_cpl_valid_i) begin
              if (ot_cpl_i.status != APU_OBJTAB_OK)
                state_q <= StFatal;
              else begin
                blob_base_w_q <=
                  APU_VG_AP_WORD_W'((ot_cpl_i.entry.bind_offset - APU_VG_SHM_BASE) >> 2);
                blob_size_q <= ot_cpl_i.entry.size;
                state_q <= StOtDo;
              end
            end
          end
          StOtDo: begin
            unique case (cmd_type_q[depth_q])
              32'hB2: begin // SetReply: window must fit the blob
                if (t_off64_q + t_size64_q > blob_size_q)
                  state_q <= StFatal;
                else begin
                  rep_live_q <= 1'b1;
                  rep_base_w_q <= blob_base_w_q + APU_VG_AP_WORD_W'(t_off64_q >> 2);
                  rep_size_q <= 32'(t_size64_q);
                  rep_pos_q <= '0;
                  state_q <= StNext;
                end
              end
              32'hB4: begin // window for stream t_i_q
                if (t_off64_q + t_size64_q > blob_size_q)
                  state_q <= StFatal;
                else begin
                  if (rep_live_q) begin
                    // positions array: n u64s at w (5+5n+2+2i)
                    rep_pos_q <= 32'(
                      {tbuf[depth_q][8 + 5 * tbuf[depth_q][2] + 2 * t_i_q],
                       tbuf[depth_q][7 + 5 * tbuf[depth_q][2] + 2 * t_i_q]});
                  end
                  st_q[1] <= '{live: 1'b1, kind: SK_LIN_AP,
                               ring: '0, base_head: '0,
                               base_w: blob_base_w_q +
                                       APU_VG_AP_WORD_W'(t_off64_q >> 2),
                               bytes: 32'(t_size64_q), pos: '0,
                               ctx: st_q[0].ctx, ring_stream: 1'b0};
                  depth_q <= 1'b1;
                  state_q <= StDecFire;
                end
              end
              32'hBC: begin
                // CreateRing validation per TransportModel.t_cmd:
                // window {off,size} inside the blob; head/tail/status
                // and buffer and extra all inside the window `size`;
                // bufferSize nonzero power-of-two; handle unique and
                // a free slot.
                // f = 9+4cn: off@11, size@13, idle@15, head@17,
                // tail@19, stat@21, buf@23, bufSz@25, extra@27, exSz@29
                if (t_hnd_q == 64'h0 || ring_free() < 0 ||
                    ring_of(t_hnd_q) >= 0 ||
                    {tbuf[depth_q][12 + 4 * cmd_cn_q[depth_q]],
                     tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]]} +
                    {tbuf[depth_q][14 + 4 * cmd_cn_q[depth_q]],
                     tbuf[depth_q][13 + 4 * cmd_cn_q[depth_q]]} > blob_size_q ||
                    !pow2nz(tbuf[depth_q][25 + 4 * cmd_cn_q[depth_q]]) ||
                    64'(tbuf[depth_q][23 + 4 * cmd_cn_q[depth_q]]) +
                    64'(tbuf[depth_q][25 + 4 * cmd_cn_q[depth_q]]) >
                    64'(tbuf[depth_q][13 + 4 * cmd_cn_q[depth_q]]) ||
                    64'(tbuf[depth_q][17 + 4 * cmd_cn_q[depth_q]]) + 64'd4 >
                    64'(tbuf[depth_q][13 + 4 * cmd_cn_q[depth_q]]) ||
                    64'(tbuf[depth_q][19 + 4 * cmd_cn_q[depth_q]]) + 64'd4 >
                    64'(tbuf[depth_q][13 + 4 * cmd_cn_q[depth_q]]) ||
                    64'(tbuf[depth_q][21 + 4 * cmd_cn_q[depth_q]]) + 64'd4 >
                    64'(tbuf[depth_q][13 + 4 * cmd_cn_q[depth_q]]) ||
                    64'(tbuf[depth_q][27 + 4 * cmd_cn_q[depth_q]]) +
                    64'(tbuf[depth_q][29 + 4 * cmd_cn_q[depth_q]]) >
                    64'(tbuf[depth_q][13 + 4 * cmd_cn_q[depth_q]]))
                  state_q <= StFatal;
                else begin
                  // ring aperture base = blob base + (off >> 2)
                  gap_q <= '0; gap_cnt_q <= '0;   // new live ring
                  // the new ring claims its window; retire any stale
                  // slot whose tail/buffer the window covers (shmem
                  // reuse without vkDestroyRingMESA) with no status
                  // write -- the words now belong to the new owner
                  for (int g = 0; g < Rings; g++)
                    if (ring_overlap(g,
                            blob_base_w_q +
                            APU_VG_AP_WORD_W'(tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]] >> 2),
                            blob_base_w_q +
                            APU_VG_AP_WORD_W'((tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]] +
                                               tbuf[depth_q][13 + 4 * cmd_cn_q[depth_q]]) >> 2)))
                      ring_q[g].live <= 1'b0;
                  ring_q[ring_free()] <=
                    '{live: 1'b1, fatal: 1'b0, idle: 1'b0,
                      handle: t_hnd_q,
                      ctx: st_q[depth_q].ctx, head: '0,
                      head_w: blob_base_w_q +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]] >> 2) +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][17 + 4 * cmd_cn_q[depth_q]] >> 2),
                      tail_w: blob_base_w_q +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]] >> 2) +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][19 + 4 * cmd_cn_q[depth_q]] >> 2),
                      status_w: blob_base_w_q +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]] >> 2) +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][21 + 4 * cmd_cn_q[depth_q]] >> 2),
                      buf_w: blob_base_w_q +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]] >> 2) +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][23 + 4 * cmd_cn_q[depth_q]] >> 2),
                      buf_size: tbuf[depth_q][25 + 4 * cmd_cn_q[depth_q]],
                      extra_w: blob_base_w_q +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]] >> 2) +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][27 + 4 * cmd_cn_q[depth_q]] >> 2),
                      extra_size: tbuf[depth_q][29 + 4 * cmd_cn_q[depth_q]],
                      // idleTimeout is a u64 ns count; the pump counts
                      // poll rounds — saturate at IdleToMax so the
                      // IDLE/ALIVE refresh stays bounded
                      idle_to: (|tbuf[depth_q][16 + 4 * cmd_cn_q[depth_q]] ||
                                tbuf[depth_q][15 + 4 * cmd_cn_q[depth_q]] >
                                IdleToMax)
                               ? IdleToMax
                               : tbuf[depth_q][15 + 4 * cmd_cn_q[depth_q]],
                      idle_cnt: '0};
                  wr_addr_q <= blob_base_w_q +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][11 + 4 * cmd_cn_q[depth_q]] >> 2) +
                        APU_VG_AP_WORD_W'(tbuf[depth_q][21 + 4 * cmd_cn_q[depth_q]] >> 2);
                  wr_data_q <= APU_VNRING_ALIVE;
                  state_q <= StApWr;
                end
              end
              default: state_q <= StFatal;
            endcase
          end

          // ---- ExecuteCommandStreams iteration -------------------------------
          StWinNext: begin
            if (t_i_q + 4'd1 >= 4'(tbuf[depth_q][2])) begin
              state_q <= StNext;        // outer command done
            end else begin
              t_i_q <= t_i_q + 4'd1;
              t_rid_q <= tbuf[depth_q][5 + 5 * (t_i_q + 4'd1)];
              t_off64_q <= {tbuf[depth_q][7 + 5 * (t_i_q + 4'd1)],
                            tbuf[depth_q][6 + 5 * (t_i_q + 4'd1)]};
              t_size64_q <= {tbuf[depth_q][9 + 5 * (t_i_q + 4'd1)],
                             tbuf[depth_q][8 + 5 * (t_i_q + 4'd1)]};
              state_q <= StOtReq;
            end
          end

          // ---- seqno waits (re-checked every cycle) ---------------------------
          StWaitVq: begin
            if ({tbuf[depth_q][3], tbuf[depth_q][2]} <= vq_seqno_q) state_q <= StNext;
          end
          StWaitR: begin
            if (ring_of(t_hnd_q) < 0) state_q <= StFatal;
            else if (64'({32'h0, ring_q[ring_of(t_hnd_q)].head})
                     >= t_val_q)
              state_q <= StNext;
          end

          // ---- aperture write commit / ring head store --------------------------
          StApWr: begin
            if (pump_wr_done) begin
              if (mp_err_i) fatal_stream_q <= 1'b1;
              state_q <= StNext;
            end
          end
          StHeadWr: begin
            if (pump_wr_done) begin
              if (mp_err_i) begin
                // a head publish that misses the aperture kills the ring
                ring_q[st_q[depth_q].ring].fatal <= 1'b1;
                fatal_stream_q <= 1'b1;
              end
              state_q <= StDecNext;
            end
          end

          StNext: begin
            // side effects complete: publish consumed head for rings
            st_q[depth_q].pos <= st_q[depth_q].pos +
                                 32'(cmd_words_q[depth_q]) * 32'd4;
            // a slot retired by a same-window CreateRing mid-stream
            // (or guest DestroyRing) must not publish head -- the
            // words now belong to the ring's new owner
            if (st_q[depth_q].ring_stream &&
                ring_q[st_q[depth_q].ring].live && !kill_strm) begin
              ring_q[st_q[depth_q].ring].head <=
                ring_q[st_q[depth_q].ring].head +
                32'(cmd_words_q[depth_q]) * 32'd4;
              wr_addr_q <= ring_q[st_q[depth_q].ring].head_w;
              wr_data_q <= ring_q[st_q[depth_q].ring].head +
                           32'(cmd_words_q[depth_q]) * 32'd4;
              state_q <= StHeadWr;
            end else begin
              state_q <= StDecNext;
            end
          end

          StDecNext: begin
            // StNext already advanced pos by this command's size; a
            // second add would end the stream a command early whenever
            // the remaining bytes fit inside the last command's size
            // (ring drains self-heal via re-poll; exec windows lose the
            // tail commands outright)
            if (st_q[depth_q].pos >= st_q[depth_q].bytes) begin
              st_q[depth_q].live <= 1'b0;
              if (depth_q) begin
                depth_q <= 1'b0;
                state_q <= StWinNext;
              end else if (st_q[0].kind != SK_LIN_GM) begin
                // ring streams — including ones demoted by ctx-kill —
                // drain silently to idle; xs_done_o/xs_fault_o belong
                // to execbuffer streams only, so a killed ring must
                // not pulse a phantom completion to vgctl
                st_q[0].live <= 1'b0;
                state_q <= StIdle;
              end else begin
                state_q <= StXsDone;
              end
            end else begin
              state_q <= StDecFire;
            end
          end
          StXsDone: state_q <= StIdle;

          // ---- fatal ------------------------------------------------------------
          StFatal: begin
            if (st_q[depth_q].ring_stream && !kill_strm) begin
              ring_q[st_q[depth_q].ring].fatal <= 1'b1;
              wr_addr_q <= ring_q[st_q[depth_q].ring].status_w;
              wr_data_q <= APU_VNRING_ALIVE | APU_VNRING_FATAL |
                           (ring_q[st_q[depth_q].ring].idle
                            ? APU_VNRING_IDLE : 32'h0);
              state_q <= StFatalWr;
            end else begin
              // only execbuffer streams may set xs_fault_o; a ring
              // stream demoted by ctx-kill (or faulting in a nested
              // window under a ring outer) drains silently instead
              if (st_q[0].kind == SK_LIN_GM)
                fatal_stream_q <= 1'b1;
              st_q[depth_q].live <= 1'b0;
              state_q <= StFatalNext;
            end
          end
          StFatalWr: begin
            if (pump_wr_done) begin
              fatal_stream_q <= 1'b1;
              st_q[depth_q].live <= 1'b0;
              state_q <= StFatalNext;
            end
          end
          StFatalNext: begin
            if (depth_q) begin
              // a nested-window fault kills the outer stream too
              depth_q <= 1'b0;
              st_q[1].live <= 1'b0;
              if (st_q[0].ring_stream && !kill_strm0) begin
                ring_q[st_q[0].ring].fatal <= 1'b1;
                wr_addr_q <= ring_q[st_q[0].ring].status_w;
                wr_data_q <= APU_VNRING_ALIVE | APU_VNRING_FATAL |
                             (ring_q[st_q[0].ring].idle
                              ? APU_VNRING_IDLE : 32'h0);
                state_q <= StFatalWr2;
              end else begin
                // execbuffer outers report; ring outers (live or
                // ctx-kill demoted) drain silently
                state_q <= st_q[0].kind == SK_LIN_GM ? StXsDone
                                                     : StIdle;
              end
            end else if (st_q[0].kind != SK_LIN_GM) begin
              state_q <= StIdle;   // ring dead until DestroyRing
            end else begin
              state_q <= StXsDone;
            end
          end
          StFatalWr2: begin
            if (pump_wr_done)
              state_q <= StIdle;
          end

          default: state_q <= StIdle;
        endcase
      end
    end
  end
endmodule

// Fixture wrapper for the *_SYNTH=1 screens.
module g6lc_apu_vnpump_fixture
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable  = 1'b0,
  parameter int unsigned Rings   = 4,
  parameter int unsigned Streams = 4,
  parameter int unsigned TBUF    = 40
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            xs_valid_i,
  output logic            xs_ready_o,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_desc_i,
  input  logic [3:0]      xs_ndesc_i,
  input  logic [31:0]     xs_off_i,
  input  logic [31:0]     xs_bytes_i,
  input  logic [7:0]      xs_ctx_i,
  output logic            xs_done_o,
  output logic            xs_fault_o,
  output logic            xs_active_o,
  output logic            mp_req_o,
  output logic            mp_we_o,
  output logic            mp_dom_o,
  output logic [63:0]     mp_addr_o,
  output logic [63:0]     mp_wdata_o,
  output logic [7:0]      mp_wstrb_o,
  input  logic            mp_ready_i,
  input  logic            mp_rvalid_i,
  input  logic [63:0]     mp_rdata_i,
  input  logic            mp_err_i,
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i,
  output logic            cr_req_valid_o,
  input  logic            cr_req_ready_i,
  output apu_cmdrec_req_t cr_req_o,
  input  logic            cr_cpl_valid_i,
  output logic            cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t cr_cpl_i,
  output logic            cr_pay_valid_o,
  output logic [31:0]     cr_pay_data_o,
  input  logic            cr_pay_ready_i,
  output logic            op_req_valid_o,
  input  logic            op_req_ready_i,
  output apu_objpay_req_t op_req_o,
  input  logic            op_cpl_valid_i,
  output logic            op_cpl_ready_o,
  input  apu_objpay_cpl_t op_cpl_i,
  output logic               sm_req_o,
  output apu_sh_sm_req_t     sm_req_pl_o,
  input  logic               sm_cpl_i,
  input  apu_sh_sm_cpl_t     sm_cpl_pl_i,
  output logic               sh_wr_en_o,
  output logic [2:0]         sh_wr_slot_o,
  output logic [15:0]        sh_wr_addr_o,
  output logic [31:0]        sh_wr_data_o,
  output logic               sh_commit_o,
  output apu_sh_commit_t     sh_commit_pl_o,
  input  logic               sh_c_done_i,
  input  apu_sh_cpl_t        sh_c_done_pl_i,
  output logic               pg_req_valid_o,
  input  logic               pg_req_ready_i,
  output apu_vgpages_req_t   pg_req_o,
  input  logic               pg_cpl_valid_i,
  output logic               pg_cpl_ready_o,
  input  apu_vgpages_cpl_t   pg_cpl_i,
  output logic               ex_submit_valid_o,
  input  logic               ex_submit_ready_i,
  output apu_cmdexec_submit_t ex_submit_o,
  input  logic [15:0]        ex_done_seq_i,
  input  logic [15:0]        ex_fence_signaled_i,
  input  logic [15:0]        ex_fence_lost_i,
  output logic [15:0]        ex_fence_clr_o,
  input  logic            ctx_kill_valid_i,
  input  logic [7:0]      ctx_kill_id_i,
  output logic            busy_o,
  output logic [Rings-1:0]       ring_active_o,
  output logic [Rings-1:0][31:0] ring_status_o,
  output logic [Rings-1:0][31:0] ring_head_o,
  output logic [Rings-1:0][APU_VG_AP_WORD_W-1:0] ring_extra_w_o
);
  g6lc_apu_vnpump #(.Enable(Enable), .Rings(Rings), .Streams(Streams),
                    .TBUF(TBUF)) i_dut (.*);
endmodule
