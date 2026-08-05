// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.1 per-hart status fabric for thread select.
//
// Tracks readiness and contention signals that drive g6lc_thread_select.
// For NrHarts==1 this is a thin combinational map (identity). For NrHarts==2
// it latches miss/block edges so a one-cycle cache-miss pulse still forces a
// switch under SMT_SWITCH_ON_MISS / SMT_HYBRID.
//
// Architectural state (RF banks, CSR banks, PC) lives elsewhere; this module
// only owns the *scheduling* view of each hart.

module g6lc_hart_state
  import config_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Events from shared pipeline / caches (tagged by active hart when SMT)
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] active_hart_i,
    input  logic dcache_miss_i,   // pulse or level from L1 D$
    input  logic icache_miss_i,   // pulse or level from L1 I$
    input  logic issue_stall_i,   // scoreboard / structural stall
    input  logic long_block_i,    // div/sqrt, CSR side-effect, WFI, fence
    input  logic [CVA6Cfg.NrHarts-1:0] hart_halt_i,  // per-hart halt/WFI
    input  logic [CVA6Cfg.NrHarts-1:0] hart_enable_i, // soft enable (default all-1)
    input  logic flush_i,
    input  logic miss_clear_i,    // fill returned / pipeline resumed
    // Outputs to thread select
    output logic [CVA6Cfg.NrHarts-1:0] hart_ready_o,
    output logic [CVA6Cfg.NrHarts-1:0] hart_dmiss_o,
    output logic [CVA6Cfg.NrHarts-1:0] hart_imiss_o,
    output logic [CVA6Cfg.NrHarts-1:0] hart_block_o
);

  localparam int unsigned NH    = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  if (NH <= 1) begin : gen_single
    // Single hart: always ready unless globally halted / long-blocked.
    assign hart_ready_o = ~hart_halt_i & hart_enable_i & ~{NH{long_block_i}};
    assign hart_dmiss_o = {NH{dcache_miss_i}};
    assign hart_imiss_o = {NH{icache_miss_i}};
    assign hart_block_o = {NH{long_block_i | issue_stall_i}};
  end else begin : gen_multi

    logic [NH-1:0] dmiss_q, dmiss_d;
    logic [NH-1:0] imiss_q, imiss_d;
    logic [NH-1:0] block_q, block_d;

    always_comb begin
      dmiss_d = dmiss_q;
      imiss_d = imiss_q;
      block_d = block_q;

      // Tag events onto the active hart
      if (dcache_miss_i)
        dmiss_d[active_hart_i] = 1'b1;
      if (icache_miss_i)
        imiss_d[active_hart_i] = 1'b1;
      if (long_block_i | issue_stall_i)
        block_d[active_hart_i] = 1'b1;

      // Clear on fill / resume / flush
      if (miss_clear_i || flush_i) begin
        dmiss_d[active_hart_i] = 1'b0;
        imiss_d[active_hart_i] = 1'b0;
        block_d[active_hart_i] = 1'b0;
      end
      // Global flush clears all contention sticky bits
      if (flush_i) begin
        dmiss_d = '0;
        imiss_d = '0;
        block_d = '0;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        dmiss_q <= '0;
        imiss_q <= '0;
        block_q <= '0;
      end else begin
        dmiss_q <= dmiss_d;
        imiss_q <= imiss_d;
        block_q <= block_d;
      end
    end

    assign hart_dmiss_o = dmiss_q;
    assign hart_imiss_o = imiss_q;
    assign hart_block_o = block_q | hart_halt_i;

    for (genvar h = 0; h < NH; h++) begin : gen_ready
      assign hart_ready_o[h] = hart_enable_i[h] &
                               ~hart_halt_i[h] &
                               ~dmiss_q[h] &
                               ~imiss_q[h] &
                               ~block_q[h];
    end

  end

endmodule
