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
  parameter int unsigned N      = APU_MP_N
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
                    (|ap_base_i) | (|ap_bytes_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      StIdle,    // grant + classify
      StResp,    // classification fault: err response, no AXI
      StWrIssue, // AW + W together, independent acceptance
      StWrB,     // wait B
      StRdIssue, // AR
      StRdR,     // wait R
      StDone     // response pulse
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

    logic        accept;
    assign accept = state_q == StIdle && sel_v && !flush_i;

    // latched request + issue progress
    logic [$clog2(N)-1:0] port_q;
    logic [63:0]          phys_q;
    logic [63:0]          wdata_q;
    logic [7:0]           wstrb_q;
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

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q   <= StIdle;
        port_q    <= '0;
        phys_q    <= '0;
        wdata_q   <= '0;
        wstrb_q   <= '0;
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
          default: state_q <= StIdle;
        endcase
      end
    end

    logic unused;
    assign unused = testmode_i;

    `ifndef SYNTHESIS
    // Protocol assertions: one outstanding, rsp only for the port in
    // flight, single-cycle pulse.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == StResp |=> !rsp_valid_o[port_q])
      else $fatal(1, "APU APMEM: rsp pulse wider than one cycle");
    `endif
  end
endmodule
