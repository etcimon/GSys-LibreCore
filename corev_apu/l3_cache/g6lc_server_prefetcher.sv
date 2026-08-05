// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Server-ready multi-stream + next-line prefetcher at the L2/L3 miss boundary.
//
// Observes demand misses (line-aligned addresses) and generates prefetch
// requests for:
//   1. Next-line(s) at ServerPfDistance
//   2. Stride continuation when a stream is trained
//
// Prefetch traffic is merged onto the memory AXI master via a simple arbiter
// (demand always wins). When Enable=0 this is a pure AXI identity.

module g6lc_server_prefetcher #(
    parameter bit          Enable        = 1'b1,
    parameter int unsigned NR_STREAMS    = 4,
    parameter int unsigned PF_DISTANCE   = 2,   // lines ahead
    parameter int unsigned LINE_BYTES    = 64,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter type axi_req_t  = logic,
    parameter type axi_resp_t = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    // From upper level (L2 or L3 master toward memory)
    input  axi_req_t  up_req_i,
    output axi_resp_t up_resp_o,
    // Toward DRAM
    output axi_req_t  dn_req_o,
    input  axi_resp_t dn_resp_i,
    // Observability
    output logic      pf_issue_o,
    output logic      pf_train_o
);

  if (!Enable) begin : gen_off
    assign dn_req_o  = up_req_i;
    assign up_resp_o = dn_resp_i;
    assign pf_issue_o = 1'b0;
    assign pf_train_o = 1'b0;
  end else begin : gen_pf

    localparam int unsigned OFF = $clog2(LINE_BYTES);

    typedef struct packed {
      logic                      valid;
      logic [AXI_ADDR_WIDTH-1:0] addr;   // last demand line
      logic signed [31:0]        stride; // bytes
      logic [2:0]                conf;   // train confidence
    } stream_t;

    stream_t [NR_STREAMS-1:0] st_q, st_d;
    logic [NR_STREAMS-1:0] hit_stream;
    logic train, issue;
    logic [AXI_ADDR_WIDTH-1:0] pf_addr, demand_line;
    logic demand_ar;

    assign demand_ar = up_req_i.ar_valid;
    assign demand_line = {up_req_i.ar.addr[AXI_ADDR_WIDTH-1:OFF], {OFF{1'b0}}};

    // Match / allocate stream on demand AR
    always_comb begin
      st_d = st_q;
      train = 1'b0;
      issue = 1'b0;
      pf_addr = '0;
      hit_stream = '0;

      if (demand_ar) begin
        // Find matching stream (same or strided)
        for (int unsigned s = 0; s < NR_STREAMS; s++) begin
          if (st_q[s].valid) begin
            automatic logic signed [31:0] delta;
            delta = signed'(demand_line - st_q[s].addr);
            if (demand_line == st_q[s].addr + (st_q[s].stride)) begin
              hit_stream[s] = 1'b1;
              st_d[s].addr = demand_line;
              if (st_q[s].conf != 3'b111) st_d[s].conf = st_q[s].conf + 1'b1;
              train = 1'b1;
              // Issue stride + next-line prefetch
              issue = (st_q[s].conf >= 3'd2);
              pf_addr = demand_line + (st_q[s].stride * PF_DISTANCE[31:0]);
            end else if (delta != 0 && st_q[s].conf < 3'd2) begin
              // Re-train stride
              st_d[s].stride = delta;
              st_d[s].addr = demand_line;
              st_d[s].conf = 3'd1;
              hit_stream[s] = 1'b1;
              train = 1'b1;
            end
          end
        end
        // Allocate free stream if no hit
        if (hit_stream == '0) begin
          for (int unsigned s = 0; s < NR_STREAMS; s++) begin
            if (!st_q[s].valid && hit_stream == '0) begin
              st_d[s].valid = 1'b1;
              st_d[s].addr = demand_line;
              st_d[s].stride = LINE_BYTES[31:0]; // default next-line
              st_d[s].conf = 3'd0;
              hit_stream[s] = 1'b1;
              train = 1'b1;
              // Always next-line PF at distance
              issue = 1'b1;
              pf_addr = demand_line + (LINE_BYTES * PF_DISTANCE);
            end
          end
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) st_q <= '0;
      else st_q <= st_d;
    end

    // --- AXI merge: demand always preferred; PF only when AR idle ---
    // Track PF request + outstanding so R beats are absorbed here and never
    // forwarded to L2 (L2 r_ready is 0 outside S_MISS_R/S_BYPASS_R — a PF R
    // left unabsorbed deadlocks axi2mem forever).
    logic pf_pending_q, pf_pending_d;
    logic pf_ot_q, pf_ot_d;  // PF AR accepted, waiting for R last
    logic [AXI_ADDR_WIDTH-1:0] pf_addr_q, pf_addr_d;

    always_comb begin
      pf_pending_d = pf_pending_q;
      pf_addr_d    = pf_addr_q;
      pf_ot_d      = pf_ot_q;
      if (issue && !pf_ot_q) begin
        pf_pending_d = 1'b1;
        pf_addr_d    = pf_addr;
      end
      // PF AR accepted by downstream
      if (pf_pending_q && !up_req_i.ar_valid && !pf_ot_q && dn_resp_i.ar_ready) begin
        pf_pending_d = 1'b0;
        pf_ot_d      = 1'b1;
      end
      // PF R completed (absorb last beat)
      if (pf_ot_q && dn_resp_i.r_valid && dn_resp_i.r.last) begin
        pf_ot_d = 1'b0;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pf_pending_q <= 1'b0;
        pf_ot_q      <= 1'b0;
        pf_addr_q    <= '0;
      end else begin
        pf_pending_q <= pf_pending_d;
        pf_ot_q      <= pf_ot_d;
        pf_addr_q    <= pf_addr_d;
      end
    end

    // Default: pass through demand. Hold demand AR while a PF is outstanding
    // so R demux stays unambiguous (PF uses a reserved id).
    always_comb begin
      dn_req_o  = up_req_i;
      up_resp_o = dn_resp_i;

      // Block demand AR while PF in flight (avoid id/R collision)
      if (pf_ot_q || (pf_pending_q && !up_req_i.ar_valid)) begin
        dn_req_o.ar_valid = 1'b0;
        up_resp_o.ar_ready = 1'b0;
      end

      // Inject PF AR when upper AR idle and no PF OT
      if (pf_pending_q && !up_req_i.ar_valid && !pf_ot_q) begin
        dn_req_o.ar_valid = 1'b1;
        dn_req_o.ar       = up_req_i.ar;  // inherit size/burst/cache defaults
        dn_req_o.ar.addr  = pf_addr_q;
        dn_req_o.ar.id    = '1;           // reserved PF id (all-ones)
        dn_req_o.ar.len   = '0;           // single-beat probe
      end

      // Absorb PF R: do not present to upper; assert r_ready toward memory
      if (pf_ot_q) begin
        up_resp_o.r_valid = 1'b0;
        dn_req_o.r_ready  = 1'b1;
      end
    end

    assign pf_issue_o = issue;
    assign pf_train_o = train;

  end

endmodule
