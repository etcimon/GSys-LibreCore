// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.1 dual (N-way) PC bank for coarse-grain SMT.
//
// Holds one NPC per hart. On a thread switch the outgoing hart's live NPC is
// saved and the incoming hart's banked NPC is restored to the frontend.
// When NrHarts==1 this is a pure wire-through (identity).

module g6lc_smt_pc_bank
  import config_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Live NPC from frontend (belongs to previous/active hart on switch cycle)
    input  logic [CVA6Cfg.VLEN-1:0] npc_live_i,
    // Thread select
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] active_hart_i,
    input  logic switch_i,
    // I4bi: when set, snapshot npc_alt_i for the outgoing hart (cookie+size)
    // instead of fetch-ahead npc_live. Unused when NrHarts==1.
    input  logic npc_alt_valid_i,
    input  logic [CVA6Cfg.VLEN-1:0] npc_alt_i,
    // Restored NPC for the newly active hart (valid when restore_o)
    output logic [CVA6Cfg.VLEN-1:0] npc_restore_o,
    output logic restore_o
);

  localparam int unsigned NH    = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  if (NH <= 1) begin : gen_single
    assign npc_restore_o = '0;
    assign restore_o     = 1'b0;
    logic _unused_alt;
    assign _unused_alt = npc_alt_valid_i | (|npc_alt_i);
  end else begin : gen_banked
    logic [NH-1:0][CVA6Cfg.VLEN-1:0] npc_bank_q;
    logic [HID_W-1:0] prev_hart_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        prev_hart_q <= '0;
        for (int unsigned h = 0; h < NH; h++) begin
          // Each hart boots at the same reset vector; software may diverge later.
          npc_bank_q[h] <= boot_addr_i;
        end
      end else begin
        prev_hart_q <= active_hart_i;
        // I4u: snapshot *only* on switch, into the outgoing bank (prev_hart).
        // Continuous snapshot of npc_q into active_hart is unsafe: on the
        // cycle after a switch, npc_q can still hold the *previous* hart's
        // stream for one beat (restore writes npc_d; npc_q updates next).
        // That poisons the incoming bank with the outgoing PC — hart1 then
        // executes boot-hart code with a reset SP (I4q hold sp1=0x20 / I4t
        // ecall_unregister mcause=4). I4p still applies: never bank 0.
        // I10: snapshot only on switch into the outgoing bank. Never bank 0.
        // npc_alt is A-only t0 rewind (tied off under G6LC_FETCH_B).
        if (switch_i) begin
          if (npc_alt_valid_i && |npc_alt_i)
            npc_bank_q[prev_hart_q] <= npc_alt_i;
          else if (|npc_live_i)
            npc_bank_q[prev_hart_q] <= npc_live_i;
        end
      end
    end

    // Combinational restore target for the cycle of the switch (new active).
    assign restore_o = switch_i;
    assign npc_restore_o = (|npc_bank_q[active_hart_i]) ? npc_bank_q[active_hart_i]
                                                        : boot_addr_i;
  end

endmodule
