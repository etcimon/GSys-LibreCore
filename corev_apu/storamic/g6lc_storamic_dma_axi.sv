// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-037C single-beat DMA seam -> AXI4 master, time-shared with an existing
// upstream AXI4 master (the AI-island DMA) on one crossbar slave port.
//
// The Storamic virtio engines issue one 8-byte beat at a time. A beat is
// granted only when the upstream master is quiescent: new upstream AW/AR are
// held off (valid masked, ready low) and every upstream write (AW..B) and read
// (AR..last R) already accepted must complete first. The beat then runs as a
// single-beat INCR transaction with a fixed ID inside the upstream ID space;
// reuse is safe because the two masters never have transactions in flight at
// the same time. Upstream W beats and responses pass through untouched.
//
// Timing: one registered phase FSM and two outstanding counters; the upstream
// pass-through is a combinational mux on the valid/ready path only.
//
// Coherence (InvalEn): after a Storamic write's B response the adapter asks
// the cluster CMO engine to invalidate the 64-byte block holding the address
// (L1 broadcast plus L2/L3 tags) and reports the write complete only after
// that invalidation is done, so the CPU never reads a stale cached copy of
// device-written memory. Reads are not snooped: CPU stores must already be in
// memory (true for the write-through L1). With InvalEn=0 the inval port is
// idle and behaviour is unchanged.
module g6lc_storamic_dma_axi #(
  parameter int unsigned IdWidth = 4,
  parameter logic [IdWidth-1:0] DmaId = '0,
  parameter bit InvalEn = 1'b0,
  parameter type axi_req_t = logic,
  parameter type axi_resp_t = logic
) (
  input logic clk_i,
  input logic rst_ni,
  // Storamic single-beat seam (from g6lc_storamic_virtio_dev)
  input logic dma_req_i,
  output logic dma_gnt_o,
  input logic dma_we_i,
  input logic [63:0] dma_addr_i,
  input logic [63:0] dma_wdata_i,
  input logic [7:0] dma_be_i,
  output logic dma_rvalid_o,
  output logic [63:0] dma_rdata_o,
  output logic dma_err_o,
  // upstream master (e.g. the AI DMA)
  input axi_req_t up_req_i,
  output axi_resp_t up_resp_o,
  // to the crossbar slave port
  output axi_req_t mst_req_o,
  input axi_resp_t mst_resp_i,
  // block invalidation request to the cluster CMO engine (InvalEn)
  output logic inval_valid_o,
  output logic [63:0] inval_addr_o,
  input logic inval_ready_i,
  input logic inval_done_i
);
  typedef enum logic [3:0] {PUp, PDrain, PAw, PWait, PAr, PRWait, PDone, PInv,
                            PInvWait} phase_t;
  phase_t ph_q;
  logic aw_done_q, w_done_q, we_q;
  logic [63:0] addr_q, wdata_q, rdata_q;
  logic [7:0] be_q;
  logic err_q;
  logic [7:0] wr_out_q, rd_out_q;   // upstream transactions in flight

  logic up_owns;
  assign up_owns = (ph_q == PUp) || (ph_q == PDrain);
  logic hold_new;                   // block new upstream AW/AR
  assign hold_new = (ph_q != PUp) || dma_req_i;

  // Upstream outstanding tracking (only while upstream owns the port).
  logic up_aw_hs, up_ar_hs, up_b_hs, up_rl_hs;
  assign up_aw_hs = up_owns && mst_req_o.aw_valid && mst_resp_i.aw_ready;
  assign up_ar_hs = up_owns && mst_req_o.ar_valid && mst_resp_i.ar_ready;
  assign up_b_hs = up_owns && mst_resp_i.b_valid && up_req_i.b_ready;
  assign up_rl_hs = up_owns && mst_resp_i.r_valid && mst_resp_i.r.last && up_req_i.r_ready;

  always_comb begin
    mst_req_o = up_req_i;
    up_resp_o = mst_resp_i;
    if (up_owns) begin
      if (hold_new) begin
        mst_req_o.aw_valid = 1'b0;
        mst_req_o.ar_valid = 1'b0;
        up_resp_o.aw_ready = 1'b0;
        up_resp_o.ar_ready = 1'b0;
      end
    end else begin
      // Storamic owns the port: the upstream sees no handshakes at all.
      up_resp_o = '0;
      mst_req_o = '0;
      mst_req_o.aw.id = DmaId;
      mst_req_o.aw.addr = addr_q;
      mst_req_o.aw.len = 8'd0;
      mst_req_o.aw.size = 3'd3;
      mst_req_o.aw.burst = 2'b01;
      mst_req_o.aw.cache = 4'b0010;
      mst_req_o.aw_valid = (ph_q == PAw) && !aw_done_q;
      mst_req_o.w.data = wdata_q;
      mst_req_o.w.strb = be_q;
      mst_req_o.w.last = 1'b1;
      mst_req_o.w_valid = (ph_q == PAw) && !w_done_q;
      mst_req_o.b_ready = (ph_q == PWait);
      mst_req_o.ar.id = DmaId;
      mst_req_o.ar.addr = addr_q;
      mst_req_o.ar.len = 8'd0;
      mst_req_o.ar.size = 3'd3;
      mst_req_o.ar.burst = 2'b01;
      mst_req_o.ar.cache = 4'b0010;
      mst_req_o.ar_valid = (ph_q == PAr);
      mst_req_o.r_ready = (ph_q == PRWait);
    end
  end

  assign dma_gnt_o = (ph_q == PDrain) && dma_req_i && wr_out_q == 0 && rd_out_q == 0;
  assign dma_rvalid_o = (ph_q == PDone);
  assign dma_rdata_o = rdata_q;
  assign dma_err_o = err_q;
  assign inval_valid_o = InvalEn && (ph_q == PInv);
  assign inval_addr_o = addr_q & ~64'h3F;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ph_q <= PUp; aw_done_q <= 1'b0; w_done_q <= 1'b0; we_q <= 1'b0;
      addr_q <= '0; wdata_q <= '0; rdata_q <= '0; be_q <= '0; err_q <= 1'b0;
      wr_out_q <= '0; rd_out_q <= '0;
    end else begin
      wr_out_q <= wr_out_q + 8'(up_aw_hs) - 8'(up_b_hs);
      rd_out_q <= rd_out_q + 8'(up_ar_hs) - 8'(up_rl_hs);
      unique case (ph_q)
        PUp: if (dma_req_i) ph_q <= PDrain;
        PDrain: begin
          if (!dma_req_i) ph_q <= PUp;      // request withdrawn (device reset)
          else if (dma_gnt_o) begin
            we_q <= dma_we_i; addr_q <= dma_addr_i; wdata_q <= dma_wdata_i;
            be_q <= dma_be_i; aw_done_q <= 1'b0; w_done_q <= 1'b0;
            ph_q <= dma_we_i ? PAw : PAr;
          end
        end
        PAw: begin
          if (mst_req_o.aw_valid && mst_resp_i.aw_ready) aw_done_q <= 1'b1;
          if (mst_req_o.w_valid && mst_resp_i.w_ready) w_done_q <= 1'b1;
          if ((aw_done_q || mst_resp_i.aw_ready) && (w_done_q || mst_resp_i.w_ready))
            ph_q <= PWait;
        end
        PWait: if (mst_resp_i.b_valid) begin
          err_q <= mst_resp_i.b.resp[1]; rdata_q <= '0;
          ph_q <= InvalEn ? PInv : PDone;
        end
        PInv: if (inval_ready_i) ph_q <= inval_done_i ? PDone : PInvWait;
        PInvWait: if (inval_done_i) ph_q <= PDone;
        PAr: if (mst_resp_i.ar_ready) ph_q <= PRWait;
        PRWait: if (mst_resp_i.r_valid) begin
          err_q <= mst_resp_i.r.resp[1]; rdata_q <= mst_resp_i.r.data; ph_q <= PDone;
        end
        PDone: ph_q <= PUp;
        default: ph_q <= PUp;
      endcase
    end
  end
endmodule
