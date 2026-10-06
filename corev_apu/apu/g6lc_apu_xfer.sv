// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// §12.3 phase C / increment 5a of architecture/uncore/apu-vulkan-engine.md:
// the Xfer engine — hardware execution of vkCmdCopyBuffer, vkCmdFillBuffer
// and vkCmdUpdateBuffer as bulk DMA over the shared AXI master.
//
// cmdexec resolves the operand buffers into an apu_xfer_desc_t sideband
// (aperture-relative {base, size} per operand) and hands the work record
// here; the U64 operands (copy regions, dstOffset/size, update data) ride
// the cmdrec payload arena and are replayed through PAYREAD (a third
// cmdrec requester — vgtop arbitration is pump > cmdexec > xfer).
//
// Datapath: every operand goes through the existing checked pair
// g6lc_apu_dma_read / g6lc_apu_dma_write.  The pair speaks the same
// right-justified fragment format ({data, contiguous-low keep,
// chunk-relative offset, last}), so COPY is a fragment FIFO from reader
// to writer — the write engine's own stepping performs the src/dst
// realignment (Vulkan imposes no alignment on copy offsets).  FILL and
// UPDATE bypass the reader and feed the FIFO directly (UPDATE reads its
// data words back through PAYREAD).  All region/offset bounds and the
// Vulkan no-overlap rule are validated in pass A before any write
// request is issued in pass B, so a refused record writes zero bytes.
// Requests are chunked to Dma{Read,Write}MaxBytes.
//
// The read engine emits checked bursts (page-split at 4 KiB, up to
// DmaReadBurstBeats beats); the write engine performs one narrow AXI
// write round trip per fragment step.  One read and one write are
// outstanding at a time — the next performance step is deeper
// outstanding (multi-request pipelining) in both engines.
//
// A DMA completion with status != APU_DMA_OK, or an engine bus_fault,
// completes the record APU_SH_DONE_FAULT (cmdexec marks the submit
// DEVICE_LOST) and poisons the engine until reset: later records fail
// fast instead of hanging on a halted DMA leg.  The engines themselves
// latch protocol faults in their Halted state until rst_ni.
//
// Config seam: apu_cfg_legal forbids Dma{Read,Write}En under VenusEn, so
// the pair sees a derived view — the Venus window/burst geometry with the
// internal DMA legs on and the guest-facing VIRGL surface cleared.  This
// is an internal engine only; the outer ApuCfg keeps the F1 split.
//
// flush_i (engine reset, from vgsys): cancels both legs, drains in-flight
// bursts to completion or halt, drops the work item without a done pulse,
// and returns to idle — an issued AXI transaction always retires before
// eng_rst_n falls.
//
// Timing impact: the widest state element is the fragment FIFO
// (FifoDepth x 105 bits, flops — a deeper geometry should move to
// tc_sram); control is a micro-FSM with one PAYREAD / AXI beat per
// micro-step.
//
// Review checklist: async active-low reset; always_ff/always_comb split;
// no latches; Enable=0 constant-inactive netlist; no new clocks.

module g6lc_apu_xfer
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  // outer (Venus) view; the DMA pair gets apu_xfer_cfg(ApuCfg)
  parameter apu_cfg_t    ApuCfg = ApuVenus,
  // fragments between the read leg and the write leg; flops
  parameter int unsigned FifoDepth = 32
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  // work port (routed from cmdexec by vgtop; xf_i valid with work_i)
  input  logic              work_valid_i,
  output logic              work_ready_o,
  input  apu_cmdexec_work_t work_i,
  input  apu_xfer_desc_t    xf_i,
  output logic              done_o,
  output apu_sh_done_t      done_pl_o,
  // cmdrec payload-arena reads (PAYREAD requester)
  output logic              cr_req_valid_o,
  input  logic              cr_req_ready_i,
  output apu_cmdrec_req_t   cr_req_o,
  input  logic              cr_cpl_valid_i,
  output logic              cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t   cr_cpl_i,
  // aperture base (mapping base = ap_base_i + operand offset)
  input  logic [63:0]       ap_base_i,
  // engine reset: cancel + drain DMA, drop work, return idle
  input  logic              flush_i,
  // non-idle FSM (vgsys reset sequencer waits for this too)
  output logic              busy_o,
  // AXI master: union of the read leg (AR/R) and write leg (AW/W/B)
  output apu_dma_axi_req_t  axi_req_o,
  input  apu_dma_axi_resp_t axi_rsp_i
);
  // ---- derived internal DMA configuration -----------------------------
  // VenusEn configs may not enable the host-facing DMA legs; the xfer
  // pair is internal, so it runs on the Venus geometry with the legs
  // on and the guest-facing VIRGL surface cleared.  Declared at module
  // scope — constant functions under a generate cannot drive localparams.
  function automatic apu_cfg_t apu_xfer_cfg(input apu_cfg_t c);
    apu_cfg_t d;
    d = c;
    d.VenusEn          = 1'b0;
    d.FeatureVirgl     = 1'b0;
    d.NumCapsets       = unsigned'(0);
    d.DmaReadEn        = 1'b1;
    d.DmaWriteEn       = 1'b1;
    d.DmaReadMaxBytes  = unsigned'(1048576);
    d.DmaWriteMaxBytes = unsigned'(1048576);
    return d;
  endfunction
  localparam apu_cfg_t    XCfg = apu_xfer_cfg(ApuCfg);
  localparam int unsigned ChunkMax =
      XCfg.DmaReadMaxBytes < XCfg.DmaWriteMaxBytes
      ? XCfg.DmaReadMaxBytes : XCfg.DmaWriteMaxBytes;
  localparam logic [63:0] WHOLE = 64'hFFFF_FFFF_FFFF_FFFF;

  if (!Enable) begin : gen_off
    assign work_ready_o   = 1'b0;
    assign done_o         = 1'b0;
    assign done_pl_o      = '0;
    assign cr_req_valid_o = 1'b0;
    assign cr_req_o       = '0;
    assign cr_cpl_ready_o = 1'b0;
    assign busy_o         = 1'b0;
    assign axi_req_o      = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | work_valid_i |
                    (|work_i) | (|xf_i) | cr_req_ready_i |
                    cr_cpl_valid_i | (|cr_cpl_i) | (|ap_base_i) |
                    flush_i | (|axi_rsp_i);
  end else begin : gen_on

    `ifndef SYNTHESIS
    initial begin
      assert (apu_cfg_legal(XCfg))
        else $fatal(1, "APU xfer: derived DMA configuration illegal");
      assert (FifoDepth >= 2)
        else $fatal(1, "APU xfer: FifoDepth < 2");
    end
    `endif

    typedef enum logic [4:0] {
      XIdle,
      XPay,                          // u64 arena fetch (2 x PAYREAD)
      XHdrA, XHdrB, XHdrChk,         // FILL/UPDATE {dstOffset, size}
      XVaS, XVaD, XVaChk,            // pass A: region bounds
      XOvA, XOvChk,                  // pass A: overlap inner loop
      XExS, XExD, XExChk,            // pass B: region re-read
      XReq,                          // issue one chunk's DMA requests
      XRun,                          // stream fragments
      XDone, XAbort
    } xf_state_e;
    xf_state_e state_q;

    apu_xfer_desc_t xf_q;
    logic [31:0]    fill_q;            // FILL pattern (rec.imm[0])
    // PAYREAD u64 service: the caller presets pay_adr_q + pay_ret_q and
    // enters XPay; on return pw_q holds the pair
    logic           pay_fly_q, pay_half_q;
    logic [15:0]    pay_adr_q;
    xf_state_e      pay_ret_q;
    logic [63:0]    pw_q;
    // FILL/UPDATE operands
    logic [63:0]    hoff_q, hsz_q;
    // COPY state
    logic [15:0]    vi_q, vj_q, ei_q;
    logic [63:0]    so_q, do_q, sz_q;  // region under validation/execution
    logic [63:0]    os_q;              // probe region srcOffset
    // chunk/byte bookkeeping
    logic [63:0]    coff_q;            // region byte cursor
    logic [31:0]    csz_q;             // bytes in the in-flight chunk req
    logic [31:0]    csent_q;           // bytes pushed for this chunk
    logic [63:0]    rem_q;             // record bytes left to produce
    logic           rd_iss_q, wr_iss_q;  // request accepted
    logic           rd_done_q, wr_done_q; // completion consumed
    logic           xf_fault_q;
    logic           poison_q;          // a DMA leg faulted: fail fast
    // UPDATE producer
    logic           up_ph_q;           // fetching data word 1
    logic [31:0]    up_lo_q;
    logic           up_v_q;
    apu_dma_read_data_t up_frag_q;
    // fragment FIFO (producer -> write leg)
    apu_dma_read_data_t ff_q [FifoDepth];
    localparam int unsigned FBits = $clog2(FifoDepth);
    logic [FBits-1:0] fwr_q, frd_q;
    logic [FBits:0]   fn_q;
    logic             fifo_space;
    assign fifo_space = fn_q != (FBits+1)'(FifoDepth);

    logic is_copy, is_fill, is_upd;
    assign is_copy = xf_q.op == APU_XFER_OP_COPY;
    assign is_fill = xf_q.op == APU_XFER_OP_FILL;
    assign is_upd  = xf_q.op == APU_XFER_OP_UPDATE;

    // ---- DMA pair ------------------------------------------------------
    apu_dma_mapping_t rd_map, wr_map;
    assign rd_map = '{valid: 1'b1, permissions: 2'b01,
                     resource_id: 32'h1, context_id: 32'h0, epoch: 32'h0,
                     base:  ap_base_i + 64'(xf_q.src_base),
                     bytes: 64'(xf_q.src_size)};
    assign wr_map = '{valid: 1'b1, permissions: 2'b10,
                     resource_id: 32'h1, context_id: 32'h0, epoch: 32'h0,
                     base:  ap_base_i + 64'(xf_q.dst_base),
                     bytes: 64'(xf_q.dst_size)};

    logic               kill;
    assign kill = flush_i || xf_fault_q;

    logic               rd_req_v, rd_req_rdy;
    apu_dma_read_req_t  rd_req;
    logic               rd_dv, rd_dr;
    apu_dma_read_data_t rd_data;
    logic               rd_cpl_v, rd_idle, rd_fault;
    apu_dma_read_cpl_t  rd_cpl;
    logic               wr_req_v, wr_req_rdy;
    apu_dma_write_req_t wr_req;
    logic               wr_dv, wr_dr;
    apu_dma_read_data_t wr_data;
    logic               wr_cpl_v, wr_idle, wr_fault;
    apu_dma_write_cpl_t wr_cpl;
    apu_dma_axi_req_t   rd_axi, wr_axi;

    assign rd_req = '{resource_id: 32'h1, context_id: 32'h0, epoch: 32'h0,
                     offset: so_q + coff_q, bytes: csz_q,
                     tag: {48'h0, ei_q}};
    assign wr_req = '{resource_id: 32'h1, context_id: 32'h0, epoch: 32'h0,
                     offset: is_copy ? (do_q + coff_q)
                                     : (hoff_q + coff_q),
                     bytes: csz_q, tag: {48'h0, ei_q}};

    g6lc_apu_dma_read #(.ApuCfg(XCfg)) i_rd (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .enable_i(1'b1), .cancel_i(kill),
      .req_valid_i(rd_req_v), .req_ready_o(rd_req_rdy), .req_i(rd_req),
      .mapping_i(rd_map),
      .data_valid_o(rd_dv), .data_ready_i(rd_dr), .data_o(rd_data),
      .cpl_valid_o(rd_cpl_v), .cpl_ready_i(1'b1), .cpl_o(rd_cpl),
      .idle_o(rd_idle), .bus_fault_o(rd_fault),
      .axi_req_o(rd_axi), .axi_rsp_i(axi_rsp_i));

    g6lc_apu_dma_write #(.ApuCfg(XCfg)) i_wr (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .enable_i(1'b1), .cancel_i(kill),
      .req_valid_i(wr_req_v), .req_ready_o(wr_req_rdy), .req_i(wr_req),
      .mapping_i(wr_map),
      .data_valid_i(wr_dv), .data_ready_o(wr_dr), .data_i(wr_data),
      .cpl_valid_o(wr_cpl_v), .cpl_ready_i(1'b1), .cpl_o(wr_cpl),
      .idle_o(wr_idle), .bus_fault_o(wr_fault),
      .axi_req_o(wr_axi), .axi_rsp_i(axi_rsp_i));

    // read leg drives AR/R only; write leg drives AW/W/B only — unioned
    // onto the single AXI master the join carries downstream
    always_comb begin
      axi_req_o          = '0;
      axi_req_o.ar_valid = rd_axi.ar_valid;
      axi_req_o.ar       = rd_axi.ar;
      axi_req_o.r_ready  = rd_axi.r_ready;
      axi_req_o.aw_valid = wr_axi.aw_valid;
      axi_req_o.aw       = wr_axi.aw;
      axi_req_o.w_valid  = wr_axi.w_valid;
      axi_req_o.w        = wr_axi.w;
      axi_req_o.b_ready  = wr_axi.b_ready;
    end

    // ---- producers -> fragment FIFO -> write leg -----------------------
    // COPY: reader fragments pass through (offset/last are already
    // chunk-relative and the formats match).  FILL: pattern words.
    // UPDATE: pairs of PAYREAD words assembled into fragments.
    // `crem` = bytes left to feed for the in-flight chunk request.
    logic [31:0]        crem;
    logic               discard, fill_go, upd_go;
    logic               fifo_push, fifo_pop;
    apu_dma_read_data_t push_frag;
    logic [3:0]         upd_n;
    assign crem    = csz_q - csent_q;
    assign upd_n   = crem >= 32'd8 ? 4'd8 : 4'(crem[2:0]);
    assign discard = xf_fault_q || flush_i;

    assign fill_go = state_q == XRun && is_fill && crem != 32'h0 &&
                     fifo_space && !discard;
    assign upd_go  = state_q == XRun && is_upd && crem != 32'h0 &&
                     !up_ph_q && !up_v_q && !pay_fly_q &&
                     fifo_space && !discard;

    assign fifo_push = state_q == XRun && !discard &&
        ((is_copy && rd_dv && fifo_space) ||
         fill_go ||
         (is_upd && up_v_q && fifo_space));

    always_comb begin
      push_frag = '0;
      if (is_copy) begin
        push_frag = rd_data;
      end else if (is_fill) begin
        // dstOffset and size are 4-byte aligned -> fragments are 8 or 4 B
        push_frag.data   = crem >= 32'd8 ? {2{fill_q}} : {32'h0, fill_q};
        push_frag.keep   = crem >= 32'd8 ? 8'hff : 8'h0f;
        push_frag.offset = csent_q;
        push_frag.last   = csent_q + (crem >= 32'd8 ? 32'd8 : 32'd4) ==
                           csz_q;
      end else begin
        push_frag = up_frag_q;
      end
    end

    // read leg drains into the FIFO; under fault/flush it still consumes
    // beats (into /dev/null) so an in-flight burst always retires
    assign rd_dr = (state_q == XRun || state_q == XAbort) &&
                   (fifo_space || discard);
    assign wr_dv    = fn_q != '0;
    assign wr_data  = ff_q[frd_q];
    assign fifo_pop = wr_dv && wr_dr;

    // ---- PAYREAD port --------------------------------------------------
    // XPay (region/operand fetches) and XRun (UPDATE data words) share
    // the requester; at most one is active at a time.
    assign cr_cpl_ready_o = 1'b1;
    assign cr_req_o = '{op: APU_CMDREC_OP_PAYREAD, cbuf: xf_q.cbuf,
                       idx: pay_adr_q, default: '0};

    assign busy_o    = state_q != XIdle;
    assign done_o    = state_q == XDone;
    assign done_pl_o = '{code: xf_fault_q ? 8'(APU_SH_DONE_FAULT)
                                         : 8'(APU_SH_DONE_OK),
                         wave: '0, pc: '0, robust: '0, work_id: '0};

    // an engine is settled when its completion was seen, it never issued,
    // or it halted on a bus/protocol fault
    logic rd_settled, wr_settled;
    assign rd_settled = rd_done_q || !rd_iss_q || rd_fault;
    assign wr_settled = wr_done_q || !wr_iss_q || wr_fault;

    always_comb begin
      cr_req_valid_o = 1'b0;
      rd_req_v       = 1'b0;
      wr_req_v       = 1'b0;
      if (state_q == XPay && !pay_fly_q) cr_req_valid_o = 1'b1;
      if (state_q == XRun && is_upd &&
          (upd_go || (up_ph_q && !pay_fly_q))) cr_req_valid_o = 1'b1;
      if (state_q == XReq && !discard) begin
        rd_req_v = is_copy && !rd_iss_q;
        wr_req_v = !wr_iss_q;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q    <= XIdle;
        xf_q       <= '0;
        fill_q     <= '0;
        pay_fly_q  <= 1'b0;
        pay_half_q <= 1'b0;
        pay_adr_q  <= '0;
        pay_ret_q  <= XIdle;
        pw_q       <= '0;
        hoff_q     <= '0;
        hsz_q      <= '0;
        vi_q       <= '0;
        vj_q       <= '0;
        ei_q       <= '0;
        so_q       <= '0;
        do_q       <= '0;
        sz_q       <= '0;
        os_q       <= '0;
        coff_q     <= '0;
        csz_q      <= '0;
        csent_q    <= '0;
        rem_q      <= '0;
        rd_iss_q   <= 1'b0;
        wr_iss_q   <= 1'b0;
        rd_done_q  <= 1'b0;
        wr_done_q  <= 1'b0;
        xf_fault_q <= 1'b0;
        poison_q   <= 1'b0;
        up_ph_q    <= 1'b0;
        up_lo_q    <= '0;
        up_v_q     <= 1'b0;
        up_frag_q  <= '0;
        fwr_q      <= '0;
        frd_q      <= '0;
        fn_q       <= '0;
      end else begin
        // ---- fragment FIFO -------------------------------------------
        if (fifo_push) begin
          ff_q[fwr_q] <= push_frag;
          fwr_q <= fwr_q == FBits'(FifoDepth - 1) ? '0 : fwr_q + 1'b1;
        end
        if (fifo_pop)
          frd_q <= frd_q == FBits'(FifoDepth - 1) ? '0 : frd_q + 1'b1;
        if (fifo_push && !fifo_pop)      fn_q <= fn_q + 1'b1;
        else if (fifo_pop && !fifo_push) fn_q <= fn_q - 1'b1;

        // ---- DMA completions / fault tracking ------------------------
        if (rd_cpl_v) begin
          rd_done_q <= 1'b1;
          if (rd_cpl.status != APU_DMA_OK) begin
            xf_fault_q <= 1'b1;
            poison_q   <= 1'b1;
          end
        end
        if (wr_cpl_v) begin
          wr_done_q <= 1'b1;
          if (wr_cpl.status != APU_DMA_OK) begin
            xf_fault_q <= 1'b1;
            poison_q   <= 1'b1;
          end
        end
        if (rd_fault || wr_fault) begin
          xf_fault_q <= 1'b1;
          poison_q   <= 1'b1;
        end

        unique case (state_q)
          XIdle: begin
            xf_fault_q <= 1'b0;
            if (work_valid_i && work_ready_o) begin
              xf_q   <= xf_i;
              fill_q <= work_i.rec.imm[0];
              coff_q <= '0;
              pay_half_q <= 1'b0;
              pay_fly_q  <= 1'b0;
              if (poison_q) begin
                // a DMA leg is halted: fail fast rather than hang
                xf_fault_q <= 1'b1;
                state_q    <= XDone;
              end else if (xf_i.op == APU_XFER_OP_COPY) begin
                if (xf_i.regions == 16'h0) begin
                  state_q <= XDone;        // degenerate record: OK
                end else begin
                  vi_q      <= '0;
                  pay_adr_q <= xf_i.pay_base;
                  pay_ret_q <= XVaS;
                  state_q   <= XPay;
                end
              end else begin
                // FILL / UPDATE header {dstOffset, size} at the base
                pay_adr_q <= xf_i.pay_base;
                pay_ret_q <= XHdrA;
                state_q   <= XPay;
              end
            end
          end

          // shared u64 arena fetch: two PAYREADs into pw_q
          XPay: begin
            if (!pay_fly_q) begin
              if (cr_req_ready_i) begin
                pay_fly_q <= 1'b1;
                pay_adr_q <= pay_adr_q + 16'd1;
              end
            end else if (cr_cpl_valid_i) begin
              pay_fly_q <= 1'b0;
              if (cr_cpl_i.status != APU_CMDREC_OK) begin
                xf_fault_q <= 1'b1;
                state_q    <= XDone;
              end else if (!pay_half_q) begin
                pw_q[31:0] <= cr_cpl_i.pdata;
                pay_half_q <= 1'b1;
              end else begin
                pw_q[63:32] <= cr_cpl_i.pdata;
                pay_half_q  <= 1'b0;
                state_q     <= pay_ret_q;
              end
            end
            // a flush waits for an in-flight read to answer, then aborts
            if (flush_i && !(pay_fly_q && !cr_cpl_valid_i)) begin
              pay_fly_q <= 1'b0;
              state_q   <= XAbort;
            end
          end

          // ---- FILL / UPDATE header {dstOffset, size} -----------------
          XHdrA: begin
            hoff_q    <= pw_q;
            pay_ret_q <= XHdrB;
            state_q   <= XPay;
          end
          XHdrB: begin
            hsz_q   <= pw_q;
            state_q <= XHdrChk;
          end
          XHdrChk: begin
            automatic logic [63:0] eff;
            eff = hsz_q;
            if (is_fill && hsz_q == WHOLE)
              eff = hoff_q >= 64'(xf_q.dst_size) ? 64'h0
                    : 64'(xf_q.dst_size) - hoff_q;
            if (hoff_q[1:0] != 2'b00 ||              // dstOffset % 4
                (is_upd && (hsz_q[1:0] != 2'b00 ||   // dataSize % 4
                            hsz_q == 64'h0 || hsz_q > 64'd65536)) ||
                (is_fill && hsz_q != WHOLE && hsz_q[1:0] != 2'b00) ||
                (is_fill && hsz_q == WHOLE && eff[1:0] != 2'b00) ||
                hoff_q > 64'(xf_q.dst_size) ||
                eff > 64'(xf_q.dst_size) - hoff_q) begin
              xf_fault_q <= 1'b1;
              state_q    <= XDone;
            end else if (eff == 64'h0) begin
              state_q <= XDone;                      // legal no-op
            end else begin
              rem_q     <= eff;
              // UPDATE data words follow the 4-word header
              if (is_upd) pay_adr_q <= xf_q.pay_base + 16'd4;
              rd_iss_q  <= 1'b0;
              rd_done_q <= 1'b1;                     // no read leg
              wr_iss_q  <= 1'b0;
              wr_done_q <= 1'b0;
              csent_q   <= '0;
              coff_q    <= '0;
              fn_q      <= '0; fwr_q <= '0; frd_q <= '0;
              up_ph_q   <= 1'b0;
              up_v_q    <= 1'b0;
              csz_q     <= eff > 64'(ChunkMax) ? 32'(ChunkMax)
                                               : 32'(eff);
              state_q   <= XReq;
            end
          end

          // ---- COPY pass A: bounds + overlap ---------------------------
          // region i: {srcOff, dstOff, size} at pay_base + 6*i
          XVaS: begin
            so_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(vi_q) * 16'd6 + 16'd2;
            pay_ret_q <= XVaD;
            state_q   <= XPay;
          end
          XVaD: begin
            do_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(vi_q) * 16'd6 + 16'd4;
            pay_ret_q <= XVaChk;
            state_q   <= XPay;
          end
          XVaChk: begin
            sz_q <= pw_q;
            if (so_q > 64'(xf_q.src_size) ||
                pw_q > 64'(xf_q.src_size) - so_q ||
                do_q > 64'(xf_q.dst_size) ||
                pw_q > 64'(xf_q.dst_size) - do_q) begin
              xf_fault_q <= 1'b1;
              state_q    <= XDone;
            end else if (pw_q == 64'h0) begin
              // zero-size region: nothing to overlap or move
              if (vi_q + 16'd1 >= xf_q.regions) begin
                ei_q      <= '0;
                pay_adr_q <= xf_q.pay_base;
                pay_ret_q <= XExS;
                state_q   <= XPay;
              end else begin
                vi_q      <= vi_q + 16'd1;
                pay_adr_q <= xf_q.pay_base +
                             16'(vi_q + 16'd1) * 16'd6;
                pay_ret_q <= XVaS;
                state_q   <= XPay;
              end
            end else begin
              vj_q      <= '0;
              pay_adr_q <= xf_q.pay_base;       // srcOffset[0]
              pay_ret_q <= XOvA;
              state_q   <= XPay;
            end
          end
          // inner overlap loop: src region j x dst region i
          XOvA: begin
            os_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(vj_q) * 16'd6 + 16'd4;
            pay_ret_q <= XOvChk;
            state_q   <= XPay;
          end
          XOvChk: begin
            // pw_q = size_j; reject src_j x dst_i intersection
            if (pw_q != 64'h0 &&
                64'(xf_q.src_base) + os_q <
                    64'(xf_q.dst_base) + do_q + sz_q &&
                64'(xf_q.dst_base) + do_q <
                    64'(xf_q.src_base) + os_q + pw_q) begin
              xf_fault_q <= 1'b1;
              state_q    <= XDone;
            end else if (vj_q + 16'd1 >= xf_q.regions) begin
              // region i is clean
              if (vi_q + 16'd1 >= xf_q.regions) begin
                ei_q      <= '0;
                pay_adr_q <= xf_q.pay_base;
                pay_ret_q <= XExS;
                state_q   <= XPay;
              end else begin
                vi_q      <= vi_q + 16'd1;
                pay_adr_q <= xf_q.pay_base +
                             16'(vi_q + 16'd1) * 16'd6;
                pay_ret_q <= XVaS;
                state_q   <= XPay;
              end
            end else begin
              vj_q      <= vj_q + 16'd1;
              pay_adr_q <= xf_q.pay_base +
                           16'(vj_q + 16'd1) * 16'd6;
              pay_ret_q <= XOvA;
              state_q   <= XPay;
            end
          end

          // ---- COPY pass B: re-read region ei, then execute ------------
          XExS: begin
            so_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(ei_q) * 16'd6 + 16'd2;
            pay_ret_q <= XExD;
            state_q   <= XPay;
          end
          XExD: begin
            do_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(ei_q) * 16'd6 + 16'd4;
            pay_ret_q <= XExChk;
            state_q   <= XPay;
          end
          XExChk: begin
            sz_q <= pw_q;
            if (pw_q == 64'h0) begin
              if (ei_q + 16'd1 >= xf_q.regions) begin
                state_q <= XDone;
              end else begin
                ei_q      <= ei_q + 16'd1;
                pay_adr_q <= xf_q.pay_base +
                             16'(ei_q + 16'd1) * 16'd6;
                pay_ret_q <= XExS;
                state_q   <= XPay;
              end
            end else begin
              coff_q    <= '0;
              csz_q     <= pw_q > 64'(ChunkMax) ? 32'(ChunkMax)
                                                : 32'(pw_q);
              csent_q   <= '0;
              rd_iss_q  <= 1'b0;
              wr_iss_q  <= 1'b0;
              rd_done_q <= 1'b0;
              wr_done_q <= 1'b0;
              fn_q      <= '0; fwr_q <= '0; frd_q <= '0;
              state_q   <= XReq;
            end
          end

          // ---- issue one chunk's DMA requests --------------------------
          XReq: begin
            if (rd_req_v && rd_req_rdy) rd_iss_q <= 1'b1;
            if (wr_req_v && wr_req_rdy) wr_iss_q <= 1'b1;
            if ((!is_copy || rd_iss_q || (rd_req_v && rd_req_rdy)) &&
                (wr_iss_q || wr_req_rdy))
              state_q <= XRun;
          end

          XRun: begin
            // UPDATE word fetch handshakes
            if (upd_go && cr_req_ready_i) begin
              pay_fly_q <= 1'b1;
              pay_adr_q <= pay_adr_q + 16'd1;
            end
            if (up_ph_q && !pay_fly_q && cr_req_ready_i &&
                is_upd) begin
              pay_fly_q <= 1'b1;
              pay_adr_q <= pay_adr_q + 16'd1;
            end
            if (pay_fly_q && cr_cpl_valid_i) begin
              pay_fly_q <= 1'b0;
              if (cr_cpl_i.status != APU_CMDREC_OK) begin
                xf_fault_q <= 1'b1;
              end else if (!up_ph_q) begin
                up_lo_q <= cr_cpl_i.pdata;
                if (upd_n == 4'd8) begin
                  up_ph_q <= 1'b1;              // fetch the second word
                end else begin
                  up_v_q           <= 1'b1;
                  up_frag_q.data   <= {32'h0, cr_cpl_i.pdata};
                  up_frag_q.keep   <= 8'h0f;
                  up_frag_q.offset <= csent_q;
                  up_frag_q.last   <= csent_q + 32'd4 == csz_q;
                end
              end else begin
                up_v_q           <= 1'b1;
                up_frag_q.data   <= {cr_cpl_i.pdata, up_lo_q};
                up_frag_q.keep   <= 8'hff;
                up_frag_q.offset <= csent_q;
                up_frag_q.last   <= csent_q + 32'd8 == csz_q;
                up_ph_q          <= 1'b0;
              end
            end
            if (up_v_q && fifo_space && !discard) begin
              up_v_q  <= 1'b0;
              rem_q   <= rem_q - 64'(upd_n);
              csent_q <= csent_q + 32'(upd_n);
            end
            if (fill_go) begin
              rem_q   <= rem_q - 64'(crem >= 32'd8 ? 8 : 4);
              csent_q <= csent_q + (crem >= 32'd8 ? 32'd8 : 32'd4);
            end

            // chunk done when both legs completed and the FIFO drained;
            // on fault the halted leg never drains — stranded fragments
            // and a pending update word are discarded instead of blocking
            if (rd_settled && wr_settled && !fifo_push &&
                (fn_q == '0 || xf_fault_q) && (!up_v_q || xf_fault_q)) begin
              if (xf_fault_q) begin
                state_q <= XDone;
              end else if (is_copy && coff_q + 64'(csz_q) < sz_q) begin
                // next chunk of the same region
                coff_q    <= coff_q + 64'(csz_q);
                csz_q     <= sz_q - coff_q - 64'(csz_q) > 64'(ChunkMax)
                             ? 32'(ChunkMax)
                             : 32'(sz_q - coff_q - 64'(csz_q));
                csent_q   <= '0;
                rd_iss_q  <= 1'b0;
                wr_iss_q  <= 1'b0;
                rd_done_q <= 1'b0;
                wr_done_q <= 1'b0;
                state_q   <= XReq;
              end else if (is_copy) begin
                // region done: next region or record done
                if (ei_q + 16'd1 >= xf_q.regions) begin
                  state_q <= XDone;
                end else begin
                  ei_q      <= ei_q + 16'd1;
                  pay_adr_q <= xf_q.pay_base +
                               16'(ei_q + 16'd1) * 16'd6;
                  pay_fly_q <= 1'b0;
                  pay_ret_q <= XExS;
                  state_q   <= XPay;
                end
              end else if (rem_q != 64'h0) begin
                // next chunk of the same fill/update
                coff_q    <= coff_q + 64'(csz_q);
                csz_q     <= rem_q > 64'(ChunkMax) ? 32'(ChunkMax)
                                                   : 32'(rem_q);
                csent_q   <= '0;
                wr_iss_q  <= 1'b0;
                wr_done_q <= 1'b0;
                state_q   <= XReq;
              end else begin
                state_q <= XDone;
              end
            end
            if (flush_i) state_q <= XAbort;
          end

          // done pulse; cmdexec sees work_done_i for one cycle
          XDone: state_q <= XIdle;

          // engine reset: cancel both legs, drain to idle or halt
          XAbort: begin
            fn_q      <= '0; fwr_q <= '0; frd_q <= '0;
            up_ph_q   <= 1'b0; up_v_q <= 1'b0;
            pay_fly_q <= 1'b0;
            if ((rd_idle || rd_fault) && (wr_idle || wr_fault) &&
                !rd_cpl_v && !wr_cpl_v)
              state_q <= XIdle;
          end

          default: state_q <= XIdle;
        endcase

        // a flush outside XRun/XPay/XAbort still aborts cleanly
        if (flush_i && state_q != XRun && state_q != XPay &&
            state_q != XAbort && state_q != XIdle)
          state_q <= XAbort;
      end
    end

    assign work_ready_o = state_q == XIdle && !flush_i;

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cr_req_valid_o && !cr_req_ready_i |=>
        cr_req_valid_o && $stable(cr_req_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      rd_req_v && !rd_req_rdy |=> rd_req_v && $stable(rd_req));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_req_v && !wr_req_rdy |=> wr_req_v && $stable(wr_req));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fifo_push |-> fn_q < (FBits+1)'(FifoDepth));
    `endif
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_xfer_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter apu_cfg_t    ApuCfg = ApuVenus,
  parameter int unsigned FifoDepth = 32
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  input  logic              work_valid_i,
  output logic              work_ready_o,
  input  apu_cmdexec_work_t work_i,
  input  apu_xfer_desc_t    xf_i,
  output logic              done_o,
  output apu_sh_done_t      done_pl_o,
  output logic              cr_req_valid_o,
  input  logic              cr_req_ready_i,
  output apu_cmdrec_req_t   cr_req_o,
  input  logic              cr_cpl_valid_i,
  output logic              cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t   cr_cpl_i,
  input  logic [63:0]       ap_base_i,
  input  logic              flush_i,
  output logic              busy_o,
  output apu_dma_axi_req_t  axi_req_o,
  input  apu_dma_axi_resp_t axi_rsp_i
);
  g6lc_apu_xfer #(.Enable(Enable), .ApuCfg(ApuCfg),
                  .FifoDepth(FifoDepth)) i_dut (.*);
endmodule
