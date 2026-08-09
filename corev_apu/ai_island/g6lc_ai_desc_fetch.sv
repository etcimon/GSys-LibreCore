// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai T2 descriptor memory fetch (P3).
//
// Reads a 64-byte descriptor from system memory over AXI (read-only master)
// into a flat desc_bits_t. One outstanding transaction; 8 beats of 64-bit
// data (INCR). Completes with ok or bus error. Timing: multi-cycle FSM;
// does not lengthen any core pipeline path.

module g6lc_ai_desc_fetch
  import g6lc_ai_desc_pkg::*;
#(
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned DataWidth = 64,
    parameter int unsigned IdWidth   = 4,
    parameter type         axi_req_t  = logic,
    parameter type         axi_resp_t = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    // Kick
    input  logic        start_i,
    input  logic [AddrWidth-1:0] addr_i,
    output logic        ready_o,
    output logic        done_o,
    output logic        err_o,
    output desc_bits_t  desc_o,
    // AXI master (read channel only; write tied idle)
    output axi_req_t    axi_req_o,
    input  axi_resp_t   axi_resp_i
);

  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam int unsigned Beats     = DescBytes / (DataWidth / 8);  // 8 for 64-bit
  localparam int unsigned BeatW     = (Beats <= 1) ? 1 : $clog2(Beats);

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_AR   = 2'd1,
    ST_R    = 2'd2,
    ST_DONE = 2'd3
  } state_e;

  state_e state_q, state_d;
  logic [AddrWidth-1:0] addr_q;
  logic [BeatW-1:0]     beat_q, beat_d;
  desc_bits_t           desc_q, desc_d;
  logic                 err_q, err_d;
  logic                 done_d;

  assign ready_o = (state_q == ST_IDLE);
  assign done_o  = (state_q == ST_DONE);
  assign err_o   = err_q;
  assign desc_o  = desc_q;

  // Default AXI idle / AR template (ariane_axi::req_t layout)
  always_comb begin
    axi_req_o          = '0;
    axi_req_o.b_ready  = 1'b1;
    axi_req_o.ar.id    = '0;
    axi_req_o.ar.addr  = addr_q;
    axi_req_o.ar.len   = axi_pkg::len_t'(Beats - 1);
    axi_req_o.ar.size  = axi_pkg::size_t'($clog2(DataWidth / 8));
    axi_req_o.ar.burst = axi_pkg::BURST_INCR;
    axi_req_o.ar.lock  = 1'b0;
    axi_req_o.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    axi_req_o.ar.prot  = '0;
    axi_req_o.ar.qos   = '0;
    axi_req_o.ar.region = '0;
    axi_req_o.ar.user  = '0;
    axi_req_o.ar_valid = 1'b0;
    axi_req_o.r_ready  = 1'b0;

    state_d = state_q;
    beat_d  = beat_q;
    desc_d  = desc_q;
    err_d   = err_q;
    done_d  = 1'b0;

    unique case (state_q)
      ST_IDLE: begin
        if (start_i) begin
          beat_d  = '0;
          err_d   = 1'b0;
          desc_d  = '0;
          state_d = ST_AR;
        end
      end
      ST_AR: begin
        axi_req_o.ar_valid = 1'b1;
        if (axi_resp_i.ar_ready) state_d = ST_R;
      end
      ST_R: begin
        axi_req_o.r_ready = 1'b1;
        if (axi_resp_i.r_valid) begin
          desc_d[beat_q*DataWidth +: DataWidth] = axi_resp_i.r.data;
          if (axi_resp_i.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
            err_d = 1'b1;
          if (axi_resp_i.r.last || (beat_q == BeatW'(Beats - 1))) begin
            state_d = ST_DONE;
          end else begin
            beat_d = beat_q + BeatW'(1);
          end
        end
      end
      ST_DONE: begin
        done_d  = 1'b1;
        state_d = ST_IDLE;
      end
      default: state_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_IDLE;
      addr_q  <= '0;
      beat_q  <= '0;
      desc_q  <= '0;
      err_q   <= 1'b0;
    end else begin
      state_q <= state_d;
      beat_q  <= beat_d;
      desc_q  <= desc_d;
      err_q   <= err_d;
      if (state_q == ST_IDLE && start_i) addr_q <= addr_i;
    end
  end

endmodule
