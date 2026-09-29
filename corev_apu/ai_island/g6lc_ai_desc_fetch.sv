// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai T2 descriptor memory fetch (P3).
//
// Reads a 64-byte descriptor from system memory over AXI (read-only master)
// into a flat desc_bits_t. One outstanding transaction. Beats stay 8 bytes
// (8 beats on a 64-bit bus, and still 8 beats on a wider bus) so a pointer
// that is only 8-byte aligned stays a legal size. Completes with ok or bus
// error. Timing: multi-cycle FSM; does not lengthen any core pipeline path.
//
// When DramChannels>1 the default stripe is 64 B (= DescBytes). A pointer that
// is not 64 B-aligned would straddle a channel. The engine does not split the
// AR: it completes with err and issues no read. N=1 accepts every pointer.

module g6lc_ai_desc_fetch
  import g6lc_ai_desc_pkg::*;
#(
    parameter int unsigned AddrWidth  = 64,
    parameter int unsigned DataWidth  = 64,
    parameter int unsigned IdWidth    = 4,
    parameter int unsigned NrChannels = 1,
    parameter int unsigned ChanShift  = 6,
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
    // 1 when this master owns the shared DMA response. Held 0 while a GEMM
    // or completion store is using that response, so their beats are ignored.
    input  logic        grant_i,
    // AXI master (read channel only; write tied idle)
    output axi_req_t    axi_req_o,
    input  axi_resp_t   axi_resp_i
);

  // Bit-granular copies of the AXI aggregates. The master's ready signals may depend
  // on the slave's valids (legal), but on a whole-struct view that reads as a
  // request<->response loop; splitting keeps Verilator's cycle check exact.
  axi_req_t  axi_req_d /*verilator split_var*/;
  axi_resp_t axi_resp_s /*verilator split_var*/;
  assign axi_req_o  = axi_req_d;
  assign axi_resp_s = axi_resp_i;

  localparam int unsigned BusBytes  = DataWidth / 8;
  // 8-byte beats on a wide bus. At DataWidth=64, BeatBytes is the whole bus.
  localparam int unsigned BeatBytes = (BusBytes > 8) ? 8 : BusBytes;
  localparam int unsigned Beats     = DescBytes / BeatBytes;
  localparam int unsigned BeatBits  = BeatBytes * 8;
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
    axi_req_d          = '0;
    axi_req_d.b_ready  = 1'b1;
    // Read-only master, but the request struct still carries a write channel;
    // ID 0 is this unit's identity on the shared DMA port (store uses 1, GEMM 2).
    axi_req_d.ar.id    = '0;
    axi_req_d.ar.addr  = addr_q;
    axi_req_d.ar.len   = axi_pkg::len_t'(Beats - 1);
    axi_req_d.ar.size  = axi_pkg::size_t'($clog2(BeatBytes));
    axi_req_d.ar.burst = axi_pkg::BURST_INCR;
    axi_req_d.ar.lock  = 1'b0;
    axi_req_d.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    axi_req_d.ar.prot  = '0;
    axi_req_d.ar.qos   = '0;
    axi_req_d.ar.region = '0;
    axi_req_d.ar.user  = '0;
    axi_req_d.ar_valid = state_q == ST_AR && grant_i;
    axi_req_d.r_ready  = state_q == ST_R && grant_i;
  end

  always_comb begin
    int unsigned lane;
    lane = 0;
    state_d = state_q;
    beat_d  = beat_q;
    desc_d  = desc_q;
    err_d   = err_q;
    done_d  = 1'b0;

    unique case (state_q)
      ST_IDLE: begin
        if (start_i) begin
          beat_d = '0;
          desc_d = '0;
          // One 64-byte INCR. N=1 always fits. N>1 refuses a stripe cross
          // instead of letting the demux pin the whole burst to one channel.
          if (!g6lc_ai_island_cfg_pkg::dram_burst_fits_stripe(
                  NrChannels, ChanShift, 64'(addr_i), DescBytes)) begin
            err_d   = 1'b1;
            state_d = ST_DONE;
          end else begin
            err_d   = 1'b0;
            state_d = ST_AR;
          end
        end
      end
      ST_AR: begin
        // Drive AR only in a granted cycle. Otherwise ar_valid stays high
        // across a grant that arrives late and the slave accepts two ARs.
        if (grant_i) begin
          if (axi_resp_s.ar_ready) state_d = ST_R;
        end
      end
      ST_R: begin
        if (grant_i) begin
          if (axi_resp_s.r_valid) begin
          // Lane 0 on a bus that is already the beat width. A wider bus
          // carries the same 8 bytes at (addr + beat*BeatBytes) % BusBytes.
          lane = (BusBytes == BeatBytes) ? 0
               : (unsigned'(addr_q) + unsigned'(beat_q) * BeatBytes) & (BusBytes - 1);
          desc_d[beat_q*BeatBits +: BeatBits] =
              BeatBits'(axi_resp_s.r.data >> (8 * lane));
          if (axi_resp_s.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
            err_d = 1'b1;
          // Two exit conditions, not one: r.last is the slave's word, the beat
          // count is ours. A slave that under- or over-runs the burst cannot
          // leave this FSM stuck or let it write past the descriptor.
          if (axi_resp_s.r.last || (beat_q == BeatW'(Beats - 1))) begin
            state_d = ST_DONE;
          end else begin
            beat_d = beat_q + BeatW'(1);
          end
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
