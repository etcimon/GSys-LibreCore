// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// APU memory-port adapter (§6c Settled bullet 2 of
// architecture/uncore/apu-vulkan-engine.md): N fixed-priority `apu_mp`
// word requesters over ONE AXI4 master.  One outstanding transaction;
// every accepted request produces exactly one rsp_valid pulse (writes
// included, after the B beat).  dom=0 addresses are absolute guest
// byte addresses bounds-checked against the guest window; dom=1 are
// aperture-relative offsets checked against the aperture window and
// rebased.  Requests may be 4-byte aligned (wstrb/wdata pre-positioned
// by the requester); the AXI beat is issued at `phys & ~7` and the
// response carries the full 64-bit beat.  `addr[1:0] != 0`, an
// out-of-window address, or an AXI resp != OKAY answer with err=1 and
// zero data, count the fault, and issue no usable beat (classification
// faults issue none at all).
//
// `flush_i` (engine reset, §6c bullet 5): a selected-but-unissued
// request is dropped without a response; an AXI transaction whose AW,
// W or AR beat was already accepted always runs to completion (B/R)
// and its response is still delivered.  `outstanding_o` marks an
// accepted request not yet answered; `idle_o` is high only with no
// request and no transaction in flight.
//
// Priority: port index 0 is highest (pub > vq > ctl > pump > sh with
// the g6lc_apu_mp_pkg localparams).
//
// Timing impact: classification and grant are combinational on
// req_valid_i (one priority-encoded mux, two window compares); the AXI
// channels are registered-state driven, no new long path.  Single
// outstanding keeps the FSM small; the 5:1 request mux is the widest
// cone.
// Review checklist: always_ff/always_comb split, async active-low
// reset only, no latches, no initial outside translate_off, Enable=0
// produces a constant-zero netlist.
module g6lc_apu_apmem
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_mp_pkg::*;
#(
  parameter bit          Enable = 0,
  parameter int unsigned N      = APU_MP_N,
  // TP5 vertex reuse: post-transform cache record slots served from a
  // second on-chip window (isvtx_w) parallel to the R3 record carve.
  // 0 = no vertex-cache SRAM (bit-identical to pre-TP5).
  parameter int unsigned VtxCacheEntries = 0
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    testmode_i,
  input  logic                    flush_i,
  input  logic [N-1:0]            req_valid_i,
  output logic [N-1:0]            req_ready_o,
  input  apu_mp_req_t [N-1:0]     req_i,
  output logic [N-1:0]            rsp_valid_o,
  output apu_mp_rsp_t [N-1:0]     rsp_o,
  input  logic [63:0]             guest_base_i,
  input  logic [63:0]             guest_bytes_i,
  input  logic [63:0]             ap_base_i,
  input  logic [63:0]             ap_bytes_i,
  // R3 record store: aperture (dom=1) byte offset of the rasteriser's
  // record/clip carve + its valid strobe.  While rec_en_i is high,
  // dom=1 requests inside [rec_base_i, rec_base_i + APU_REC_CARVE_BYTES)
  // are served from the on-chip tc_sram banks instead of the AXI master.
  // Driven from the rasteriser scratch base once S_ALLOC_W latches it;
  // tied off (rec_en_i=0) until that plumbing lands.
  input  logic [63:0]             rec_base_i,
  input  logic                    rec_en_i,
  // TP5 vertex reuse: aperture (dom=1) byte offset of the vertex-cache
  // window + valid strobe, parallel to rec_base_i/rec_en_i.  While
  // vtx_en_i is high, dom=1 requests inside
  // [vtx_base_i, vtx_base_i + VtxCacheEntries*19*8) are served from the
  // vertex-cache tc_sram banks.  Tied off (vtx_en_i=0) until the
  // rasteriser allocates the region; 0 entries = window never matches.
  input  logic [63:0]             vtx_base_i,
  input  logic                    vtx_en_i,
  output apu_dma_axi_req_t        axi_req_o,
  input  apu_dma_axi_resp_t       axi_rsp_i,
  output logic                    outstanding_o,
  output logic [31:0]             fault_cnt_o,
  output logic                    idle_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o    = '0;
    assign rsp_valid_o    = '0;
    assign rsp_o          = '0;
    assign axi_req_o      = '0;
    assign outstanding_o  = 1'b0;
    assign fault_cnt_o    = '0;
    assign idle_o         = 1'b1;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | flush_i |
                    (|req_valid_i) | (|req_i) | (|axi_rsp_i) |
                    (|guest_base_i) | (|guest_bytes_i) |
                    (|ap_base_i) | (|ap_bytes_i) |
                    (|rec_base_i) | rec_en_i |
                    (|vtx_base_i) | vtx_en_i;
  end else begin : gen_on
    typedef enum logic [3:0] {
      StIdle,    // grant + classify
      StResp,    // classification fault: err response, no AXI
      StWrIssue, // AW + W together, independent acceptance
      StWrB,     // wait B
      StRdIssue, // AR
      StRdR,     // wait R
      StDone,    // response pulse
      // R3 record store fast-path (no AXI): write commits in one cycle,
      // read issues then captures the tc_sram data beat the next cycle.
      StSramWr,  // tc_sram write (we=1), commits this edge -> StDone
      StSramRd,  // tc_sram read issue (we=0) -> StSramCap
      StSramCap  // capture sram rdata -> StDone
    } state_e;
    state_e state_q;

    // fixed priority: lowest index wins
    logic [$clog2(N)-1:0] sel;
    logic                 sel_v;
    always_comb begin
      sel   = '0;
      sel_v = 1'b0;
      for (int unsigned i = N; i > 0; i--) begin
        if (req_valid_i[i-1]) begin
          sel   = $clog2(N)'(i-1);
          sel_v = 1'b1;
        end
      end
    end

    apu_mp_req_t sel_req;
    assign sel_req = req_i[sel];

    // classification (combinational on the granted request)
    logic [63:0] sel_phys;
    logic        sel_in, sel_align;
    assign sel_align = sel_req.addr[1:0] == 2'b00;
    always_comb begin
      if (sel_req.dom) begin
        sel_in   = sel_req.addr < ap_bytes_i;
        sel_phys = ap_base_i + sel_req.addr;
      end else begin
        sel_in   = (sel_req.addr >= guest_base_i) &&
                   (sel_req.addr - guest_base_i < guest_bytes_i);
        sel_phys = sel_req.addr;
      end
    end

    // R3 record store: dom=1 aperture requests inside the record/clip
    // carve window are served from the on-chip tc_sram banks below
    // instead of the AXI master.  The window base arrives on rec_base_i
    // (the rasteriser's dynamic scratch-carve base); rec_en_i gates it
    // until the carve is allocated.  The window is a strict subset of
    // the aperture window, so sel_in already covers it; the requester
    // still sees one rsp_valid pulse per accepted request.
    logic        isrec_w;
    logic [12:0] rec_idx_d;
    assign isrec_w = rec_en_i && sel_req.dom &&
                     (sel_req.addr >= rec_base_i) &&
                     ((sel_req.addr - rec_base_i) <
                      g6lc_apu_pkg::APU_REC_CARVE_BYTES);
    assign rec_idx_d = 13'((sel_req.addr - rec_base_i) >> 3);

    // TP5 vertex reuse: parallel on-chip window for the post-transform
    // vertex cache.  Each cache entry is VTX_ENTRY_W 64-bit words —
    // word0 = {valid, tag_index} written by the rasteriser, words 1..18
    // = the 144 B post-transform record.  The window is addressed like
    // the record carve (8 B beats) but lives in its own tc_sram banks so
    // the 64 KiB batch carve is untouched.  vtx_en_i gates it until the
    // rasteriser allocates the region; VtxCacheEntries==0 never matches.
    localparam int unsigned VTX_ENTRY_W  = g6lc_apu_pkg::APU_VTX_ENTRY_WORDS;
    localparam int unsigned VTX_WORDS    = VtxCacheEntries * VTX_ENTRY_W;
    localparam logic [63:0] VTX_BYTES    = g6lc_apu_pkg::APU_VTX_ENTRY_BYTES *
                                           64'(VtxCacheEntries);
    // two 4096-word banks = 8192 words max -> VtxCacheEntries <= 431
    localparam int unsigned VTX_BANKS    = (VTX_WORDS + 4095) / 4096;
    logic        isvtx_w;
    logic [12:0] vtx_idx_d;
    assign isvtx_w = vtx_en_i && (VtxCacheEntries != 0) && sel_req.dom &&
                     (sel_req.addr >= vtx_base_i) &&
                     ((sel_req.addr - vtx_base_i) < VTX_BYTES);
    assign vtx_idx_d = 13'((sel_req.addr - vtx_base_i) >> 3);

    logic        accept;
    assign accept = state_q == StIdle && sel_v && !flush_i;

    // latched request + issue progress
    logic [$clog2(N)-1:0] port_q;
    logic [63:0]          phys_q;
    logic [63:0]          wdata_q;
    logic [7:0]           wstrb_q;
    logic [12:0]          rec_idx_q;   // R3: sram word index (8192 x 64b)
    // TP5: vertex-cache sram word index + which store the in-flight
    // SRAM op targets (0 = record carve, 1 = vertex cache)
    logic [12:0]          vtx_idx_q;
    logic                 vtx_q;
    logic                 aw_done_q, w_done_q, ar_done_q;
    logic [63:0]          rdata_q;
    logic                 err_q;
    logic                 out_q;
    logic [31:0]          fault_q;

    assign outstanding_o = out_q;
    assign idle_o        = state_q == StIdle && !out_q;
    assign fault_cnt_o   = fault_q;

    // req_ready_o: only the granted port, only while Idle and not flushing
    always_comb begin
      req_ready_o = '0;
      if (accept) req_ready_o[sel] = 1'b1;
    end

    // response pulse: one cycle, only to the granted port
    always_comb begin
      rsp_valid_o = '0;
      rsp_o       = '{default: '0};
      if (state_q == StResp || state_q == StDone) begin
        rsp_valid_o[port_q]   = 1'b1;
        rsp_o[port_q].rdata   = err_q ? 64'h0 : rdata_q;
        rsp_o[port_q].err     = err_q;
      end
    end

    // AXI channel drivers
    always_comb begin
      axi_req_o = '0;
      if (state_q == StWrIssue) begin
        if (!aw_done_q) begin
          axi_req_o.aw_valid = 1'b1;
          axi_req_o.aw.id    = '0;
          axi_req_o.aw.addr  = phys_q & ~64'h7;
          axi_req_o.aw.len   = 8'd0;
          axi_req_o.aw.size  = 3'd3;
          axi_req_o.aw.burst = axi_pkg::BURST_INCR;
        end
        if (!w_done_q) begin
          axi_req_o.w_valid = 1'b1;
          axi_req_o.w.data  = wdata_q;
          axi_req_o.w.strb  = wstrb_q;
          axi_req_o.w.last  = 1'b1;
        end
      end
      if (state_q == StWrB) axi_req_o.b_ready = 1'b1;
      if (state_q == StRdIssue && !ar_done_q) begin
        axi_req_o.ar_valid = 1'b1;
        axi_req_o.ar.id    = '0;
        axi_req_o.ar.addr  = phys_q & ~64'h7;
        axi_req_o.ar.len   = 8'd0;
        axi_req_o.ar.size  = 3'd3;
        axi_req_o.ar.burst = axi_pkg::BURST_INCR;
      end
      if (state_q == StRdR) axi_req_o.r_ready = 1'b1;
    end

    // a flush may only drop a request before any AXI beat left
    logic issued;
    assign issued = aw_done_q | w_done_q | ar_done_q;

    // R3 record store: tc_sram control (declared before the FSM that
    // reads sram_rdata; instances + assigns follow the always_ff).
    logic        sram_req, sram_we;
    logic [11:0] sram_addr;
    logic [63:0] sram_wdata;
    logic [7:0]  sram_be;
    logic [63:0] sram_rdata;
    logic [63:0] sram_rdata_b [1:0];
    // TP5 vertex-cache store (parallel tc_sram array, same StSram* path)
    logic [11:0] vsram_addr;
    logic [63:0] vsram_rdata;
    logic [63:0] vtx_rdata_b [1:0];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q   <= StIdle;
        port_q    <= '0;
        phys_q    <= '0;
        wdata_q   <= '0;
        wstrb_q   <= '0;
        rec_idx_q <= '0;
        vtx_idx_q <= '0;
        vtx_q     <= 1'b0;
        aw_done_q <= 1'b0;
        w_done_q  <= 1'b0;
        ar_done_q <= 1'b0;
        rdata_q   <= '0;
        err_q     <= 1'b0;
        out_q     <= 1'b0;
        fault_q   <= '0;
      end else begin
        unique case (state_q)
          StIdle: begin
            if (accept) begin
              port_q    <= sel;
              phys_q    <= sel_phys;
              wdata_q   <= sel_req.wdata;
              wstrb_q   <= sel_req.wstrb;
              rec_idx_q <= rec_idx_d;
              vtx_idx_q <= vtx_idx_d;
              vtx_q     <= isvtx_w;
              aw_done_q <= 1'b0;
              w_done_q  <= 1'b0;
              ar_done_q <= 1'b0;
              rdata_q   <= '0;
              err_q     <= 1'b0;
              out_q     <= 1'b1;
              if (!sel_align || !sel_in) begin
                err_q   <= 1'b1;
                fault_q <= fault_q + 32'd1;
                state_q <= StResp;
              end else if (isrec_w || isvtx_w) begin
                // R3/TP5: record + vertex carve -> on-chip tc_sram,
                // no AXI beats; vtx_q picks which store the beat hits
                state_q <= sel_req.we ? StSramWr : StSramRd;
              end else if (sel_req.we) begin
                state_q <= StWrIssue;
              end else begin
                state_q <= StRdIssue;
              end
            end
          end
          StResp: begin
            // err pulse emitted; request consumed
            state_q <= StIdle;
            out_q   <= 1'b0;
          end
          StWrIssue: begin
            if (axi_rsp_i.aw_ready && !aw_done_q) aw_done_q <= 1'b1;
            if (axi_rsp_i.w_ready  && !w_done_q)  w_done_q  <= 1'b1;
            // a flush may drop the request only while nothing is on
            // the wire: `issued` is registered, so the acceptance of
            // an AW/W beat this cycle must veto the drop as well —
            // otherwise a flush arriving together with the ready
            // would strand an accepted beat (AW without W, or a
            // transaction whose B/R is never consumed).
            if (flush_i && !issued &&
                !axi_rsp_i.aw_ready && !axi_rsp_i.w_ready) begin
              // never issued: drop silently, no response
              state_q <= StIdle;
              out_q   <= 1'b0;
            end else if ((aw_done_q || axi_rsp_i.aw_ready) &&
                         (w_done_q  || axi_rsp_i.w_ready)) begin
              state_q <= StWrB;
            end
          end
          StWrB: begin
            if (axi_rsp_i.b_valid) begin
              if (axi_rsp_i.b.resp != axi_pkg::RESP_OKAY) begin
                err_q   <= 1'b1;
                fault_q <= fault_q + 32'd1;
              end
              state_q <= StDone;
            end
          end
          StRdIssue: begin
            if (axi_rsp_i.ar_ready) ar_done_q <= 1'b1;
            // same flush/accept race as StWrIssue: an AR accepted this
            // cycle vetoes the drop and the read completes normally
            if (flush_i && !issued && !axi_rsp_i.ar_ready) begin
              state_q <= StIdle;
              out_q   <= 1'b0;
            end else if (axi_rsp_i.ar_ready) begin
              state_q <= StRdR;
            end
          end
          StRdR: begin
            if (axi_rsp_i.r_valid) begin
              rdata_q <= axi_rsp_i.r.data;
              if (axi_rsp_i.r.resp != axi_pkg::RESP_OKAY ||
                  !axi_rsp_i.r.last) begin
                err_q   <= 1'b1;
                fault_q <= fault_q + 32'd1;
              end
              state_q <= StDone;
            end
          end
          StDone: begin
            state_q <= StIdle;
            out_q   <= 1'b0;
          end
          // ---- R3 record store: tc_sram fast-path, no AXI ----------
          StSramWr: begin
            // write committed at the edge ending this state; the beat
            // is resident before the StDone response pulse, preserving
            // the producer->consumer ordering the AXI path implied.
            state_q <= StDone;
          end
          StSramRd: begin
            // read issued last cycle; rdata_o is valid now (Latency=1)
            state_q <= StSramCap;
          end
          StSramCap: begin
            // TP5: vtx_q selects the vertex-cache store's read data;
            // record carve and vertex cache share the StSram* timing
            rdata_q <= vtx_q ? vsram_rdata : sram_rdata;
            state_q <= StDone;
          end
          default: state_q <= StIdle;
        endcase
      end
    end

    // ---- R3 record store: 64 KiB carve as two 4096x64b tc_sram banks.
    // rec_idx_q[12] selects the bank (keeps each array inside the
    // depth<=4096 envelope); rec_idx_q[11:0] is the word address.  A
    // record access is one 8-byte beat; a 4-byte record word rides the
    // request's wstrb/wdata exactly as it did on the AXI beat.
    // TP5: the vertex-cache store is a parallel tc_sram array reached
    // through the same StSram* timing; vtx_q picks which array a beat
    // targets and which index/addr it uses.  sram_req/we/wdata/be are
    // shared; each bank's req_i is qualified by the store select.
    assign sram_req   = (state_q == StSramWr) || (state_q == StSramRd);
    assign sram_we    = (state_q == StSramWr);
    assign sram_addr  = rec_idx_q[11:0];
    assign sram_wdata = wdata_q;
    assign sram_be    = wstrb_q;
    assign sram_rdata = rec_idx_q[12] ? sram_rdata_b[1] : sram_rdata_b[0];
    for (genvar b = 0; b < 2; b++) begin : g_recstore
      tc_sram #(.NumWords(4096), .DataWidth(64), .NumPorts(1),
                .SimInit("none")) i_recstore (
        .clk_i, .rst_ni,
        .req_i(sram_req && !vtx_q && (rec_idx_q[12] == 1'(b))),
        .we_i(sram_we), .addr_i(sram_addr),
        .wdata_i(sram_wdata), .be_i(sram_be),
        .rdata_o(sram_rdata_b[b]));
    end

    // ---- TP5 vertex cache: VTX_BANKS x 4096x64b tc_sram banks covering
    // the VTX_WORDS-word window ([vtx_base_i, +VTX_BYTES)).  Bank = the
    // 4096-word block of vtx_idx_q (bit 12); word = vtx_idx_q[11:0].
    // VtxCacheEntries==0 -> VTX_BANKS==0 -> no cells, isvtx_w never
    // matches, bit-identical to pre-TP5.
    assign vsram_addr = vtx_idx_q[11:0];
    assign vsram_rdata = (VTX_BANKS <= 1) ? vtx_rdata_b[0]
                         : (vtx_idx_q[12] ? vtx_rdata_b[1]
                                          : vtx_rdata_b[0]);
    for (genvar b = 0; b < 2; b++) begin : g_vtxstore
      if (b < VTX_BANKS) begin : g_vtxbank
        tc_sram #(.NumWords(4096), .DataWidth(64), .NumPorts(1),
                  .SimInit("none")) i_vtxstore (
          .clk_i, .rst_ni,
          .req_i(sram_req && vtx_q && (vtx_idx_q[12] == 1'(b))),
          .we_i(sram_we), .addr_i(vsram_addr),
          .wdata_i(sram_wdata), .be_i(sram_be),
          .rdata_o(vtx_rdata_b[b]));
      end else begin : g_vtxbank_off
        assign vtx_rdata_b[b] = 64'h0;
      end
    end

    logic unused;
    assign unused = testmode_i;

    `ifndef SYNTHESIS
    // TP5: the vertex store is two 4096-word banks = 8192 words, so
    // VtxCacheEntries*APU_VTX_ENTRY_WORDS must fit — fail loudly at
    // time-0 rather than let an oversized window alias onto low words.
    initial begin
      if (VtxCacheEntries * g6lc_apu_pkg::APU_VTX_ENTRY_WORDS > 8192)
        $fatal(1, "APU APMEM: VtxCacheEntries=%0d exceeds the 8192-word vertex store (max %0d)",
               VtxCacheEntries, 8192 / g6lc_apu_pkg::APU_VTX_ENTRY_WORDS);
    end
    // Protocol assertions: one outstanding, rsp only for the port in
    // flight, single-cycle pulse.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == StResp |=> !rsp_valid_o[port_q])
      else $fatal(1, "APU APMEM: rsp pulse wider than one cycle");
    `endif
  end
endmodule
