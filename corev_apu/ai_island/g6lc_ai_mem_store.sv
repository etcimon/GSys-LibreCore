// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai single-beat AXI store (P3 completion word).
// Writes one DataWidth beat (64-bit default) with full strobes.
// Strict AW → W → B order (no parallel AW/W) for conservative xbar behavior.
// Timing: multi-cycle FSM; idle when not busy. Island mux must not select this
// master while idle (see g6lc_ai_island_top) so b_ready cannot siphon B beats.

module g6lc_ai_mem_store #(
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned DataWidth = 64,
    parameter int unsigned IdWidth   = 4,
    parameter type         axi_req_t  = logic,
    parameter type         axi_resp_t = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,
    input  logic [AddrWidth-1:0] addr_i,
    input  logic [DataWidth-1:0] data_i,
    output logic        ready_o,
    output logic        done_o,
    output logic        err_o,
    output axi_req_t    axi_req_o,
    input  axi_resp_t   axi_resp_i
);

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_AW   = 2'd1,
    ST_W    = 2'd2,
    ST_B    = 2'd3
  } state_e;

  state_e state_q, state_d;
  logic [AddrWidth-1:0] addr_q;
  logic [DataWidth-1:0] data_q;
  logic                 err_q, err_d;
  logic                 done_q;

  assign ready_o = (state_q == ST_IDLE);
  assign done_o  = done_q;
  assign err_o   = err_q;

  always_comb begin
    axi_req_o          = '0;
    axi_req_o.b_ready  = 1'b0;
    axi_req_o.r_ready  = 1'b1;
    axi_req_o.ar_valid = 1'b0;
    axi_req_o.aw_valid = 1'b0;
    axi_req_o.w_valid  = 1'b0;

    // Non-modifiable / non-bufferable: completion word is a device write.
    // ID=1 distinguishes from desc-fetch (id=0) on the shared DMA master port.
    axi_req_o.aw.id     = IdWidth'(1);
    axi_req_o.aw.addr   = addr_q;
    axi_req_o.aw.len    = '0;
    axi_req_o.aw.size   = axi_pkg::size_t'($clog2(DataWidth / 8));
    axi_req_o.aw.burst  = axi_pkg::BURST_INCR;
    axi_req_o.aw.lock   = 1'b0;
    axi_req_o.aw.cache  = '0;
    axi_req_o.aw.prot   = '0;
    axi_req_o.aw.qos    = '0;
    axi_req_o.aw.region = '0;
    axi_req_o.aw.atop   = '0;
    axi_req_o.aw.user   = '0;
    axi_req_o.w.data    = data_q;
    axi_req_o.w.strb    = '1;
    axi_req_o.w.last    = 1'b1;
    axi_req_o.w.user    = '0;

    state_d = state_q;
    err_d   = err_q;

    unique case (state_q)
      ST_IDLE: begin
        if (start_i) begin
          err_d   = 1'b0;
          state_d = ST_AW;
        end
      end
      ST_AW: begin
        axi_req_o.aw_valid = 1'b1;
        if (axi_resp_i.aw_ready) state_d = ST_W;
      end
      ST_W: begin
        axi_req_o.w_valid = 1'b1;
        if (axi_resp_i.w_ready) state_d = ST_B;
      end
      ST_B: begin
        axi_req_o.b_ready = 1'b1;
        if (axi_resp_i.b_valid) begin
          if (axi_resp_i.b.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
            err_d = 1'b1;
          state_d = ST_IDLE;
        end
      end
      default: state_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_IDLE;
      addr_q  <= '0;
      data_q  <= '0;
      err_q   <= 1'b0;
      done_q  <= 1'b0;
    end else begin
      state_q <= state_d;
      err_q   <= err_d;
      done_q  <= (state_q == ST_B) && axi_resp_i.b_valid && axi_req_o.b_ready;
      if (state_q == ST_IDLE && start_i) begin
        addr_q <= addr_i;
        data_q <= data_i;
      end
    end
  end

endmodule
