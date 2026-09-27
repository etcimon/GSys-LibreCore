// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai single-beat AXI store (P3 completion word).
// Writes the 64-bit completion word. On a 64-bit bus that is the whole beat.
// On a wider bus the same 8 bytes are placed at addr % DataWidth so the
// store does not zero the rest of the beat. A pointer that is not aligned
// to those 8 bytes completes with err and issues no write. An aligned
// 8-byte store fits in any stripe whose size is a multiple of 8.
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

  localparam int unsigned BusBytes   = DataWidth / 8;
  // Completion word is 64 bits. DataWidth=64 keeps a full-strobe beat.
  localparam int unsigned StoreBytes = (BusBytes > 8) ? 8 : BusBytes;

  typedef enum logic [2:0] {
    ST_IDLE = 3'd0,
    ST_AW   = 3'd1,
    ST_W    = 3'd2,
    ST_B    = 3'd3,
    ST_FAIL = 3'd4
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
    // ID 1 keeps the completion word distinguishable from the descriptor fetch
    // (0) and the GEMM traffic (2) on the one shared island DMA master.
    axi_req_o.aw.id     = IdWidth'(1);
    axi_req_o.aw.addr   = addr_q;
    axi_req_o.aw.len    = '0;
    axi_req_o.aw.size   = axi_pkg::size_t'($clog2(StoreBytes));
    axi_req_o.aw.burst  = axi_pkg::BURST_INCR;
    axi_req_o.aw.lock   = 1'b0;
    axi_req_o.aw.cache  = '0;
    axi_req_o.aw.prot   = '0;
    axi_req_o.aw.qos    = '0;
    axi_req_o.aw.region = '0;
    axi_req_o.aw.atop   = '0;
    axi_req_o.aw.user   = '0;
    begin
      int unsigned lane;
      lane = 0;
      if (StoreBytes == BusBytes) begin
        axi_req_o.w.data = data_q;
        axi_req_o.w.strb = '1;
      end else begin
        lane = unsigned'(addr_q) & (BusBytes - 1);
        axi_req_o.w.data = DataWidth'(data_q[63:0]) << (8 * lane);
        axi_req_o.w.strb = {{(DataWidth/8-8){1'b0}}, 8'hFF} << lane;
      end
    end
    axi_req_o.w.last    = 1'b1;
    axi_req_o.w.user    = '0;

    state_d = state_q;
    err_d   = err_q;

    unique case (state_q)
      ST_IDLE: begin
        if (start_i) begin
          if ((StoreBytes >= 8
               && !g6lc_ai_island_cfg_pkg::ai_completion_aligned(AddrWidth'(addr_i)))
              || (StoreBytes < 8 && (addr_i & (StoreBytes - 1)) != '0)) begin
            err_d   = 1'b1;
            state_d = ST_FAIL;
          end else begin
            err_d   = 1'b0;
            state_d = ST_AW;
          end
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
      // One cycle after start, so the descriptor engine has wr_issued set
      // before it samples done. Same-cycle done leaves ST_WR_DONE wedged.
      ST_FAIL: begin
        err_d   = 1'b1;
        state_d = ST_IDLE;
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
      done_q  <= ((state_q == ST_B) && axi_resp_i.b_valid && axi_req_o.b_ready)
                 || (state_q == ST_FAIL);
      if (state_q == ST_IDLE && start_i) begin
        addr_q <= addr_i;
        data_q <= data_i;
      end
    end
  end

endmodule
