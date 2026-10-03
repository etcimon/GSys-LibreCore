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
    input  logic npc_live_valid_i,
    input logic redirect_valid_i,
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] redirect_hart_i,
    input logic [CVA6Cfg.VLEN-1:0] redirect_pc_i,
    // T6b-2a: second redirect write — the peer-hart restart on a full flush
    // (or an inactive hart's mispredict) lands here so the faulting hart's
    // own commit-side redirect on the primary port is not lost. The two ports
    // always target different harts by construction; constant-0 when
    // SmtDrainedHandoff or NrHarts==1.
    input logic redirect2_valid_i,
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] redirect2_hart_i,
    input logic [CVA6Cfg.VLEN-1:0] redirect2_pc_i,
    input logic [CVA6Cfg.NrCommitPorts-1:0] retire_valid_i,
    input logic [CVA6Cfg.NrCommitPorts-1:0][$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] retire_hart_i,
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.VLEN-1:0] retire_pc_i,
    // Thread select
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] active_hart_i,
    input  logic switch_i,
    // I4bi: when set, snapshot npc_alt_i for the outgoing hart (cookie+size)
    // instead of fetch-ahead npc_live. Unused when NrHarts==1.
    input  logic npc_alt_valid_i,
    input  logic [CVA6Cfg.VLEN-1:0] npc_alt_i,
    // Restored NPC for the newly active hart (valid when restore_o)
    output logic [CVA6Cfg.VLEN-1:0] npc_restore_o,
    output logic restore_o,
    output logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] outgoing_hart_o
);

  localparam int unsigned NH    = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  if (NH <= 1) begin : gen_single
    assign npc_restore_o = '0;
    assign restore_o     = 1'b0;
    assign outgoing_hart_o = '0;
    logic _unused_alt;
    assign _unused_alt = npc_alt_valid_i | (|npc_alt_i) | redirect_valid_i |
        (|redirect_hart_i) | (|redirect_pc_i) | redirect2_valid_i |
        (|redirect2_hart_i) | (|redirect2_pc_i) | (|retire_valid_i) |
        (|retire_hart_i) | (|retire_pc_i) | npc_live_valid_i | (|npc_live_i) |
        switch_i | active_hart_i[0];
  end else begin : gen_banked
    logic [NH-1:0][CVA6Cfg.VLEN-1:0] npc_bank_q;
    logic [HID_W-1:0] prev_hart_q;
    assign outgoing_hart_o = prev_hart_q;

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
        // npc_alt is the N1c forced-drain restart PC under FETCH_B and the
        // A-only t0 rewind elsewhere.
`ifdef G6LC_FETCH_B
`ifdef G6LC_MUT_PCBANK_RETIRE_MIXED
        // Review mutation (T13): keep retirement-driven bank writes under
        // mixed residency — the pre-T13 behaviour that let an inactive
        // hart's surviving retirements move its bank backward past the
        // switch-out frontier (s11 double retirement).
        for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++)
          if (retire_valid_i[p]) npc_bank_q[retire_hart_i[p]] <= retire_pc_i[p];
`else
        // T13: the bank authority depends on the handoff contract.
        // Drained: the scoreboard is empty at every switch, so the last
        // retirement IS the architectural frontier — the next instruction
        // to execute is its successor, maintained by the retire writes.
        // Mixed: the outgoing hart keeps live SB entries, so its frontier
        // is the oldest killed pre-dispatch PC captured at switch-out in
        // npc_live_i (smt_restart_pc); retirements of an inactive hart
        // must never move the bank backward — a re-activated hart would
        // otherwise refetch and double-retire its still-live tail (s11:
        // remu + six c.addi re-retired behind a 64-cycle divu).
        if (CVA6Cfg.SmtDrainedHandoff) begin
          for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++)
            if (retire_valid_i[p]) npc_bank_q[retire_hart_i[p]] <= retire_pc_i[p];
        end else if (switch_i && npc_live_valid_i) begin
          npc_bank_q[prev_hart_q] <= npc_live_i;
        end
`endif
        // Redirects win over both authorities below: the active hart's own
        // trap/set_pc (primary port) and an inactive hart's mispredict or
        // peer flush restart (port 2) must still retarget the bank.
        if (redirect_valid_i)
          npc_bank_q[redirect_hart_i] <= redirect_pc_i;
        // T6b-2a: peer restart / inactive-hart mispredict. Targets a
        // different hart than the primary redirect by construction.
        if (redirect2_valid_i)
          npc_bank_q[redirect2_hart_i] <= redirect2_pc_i;
        // N1c: a forced drain rewinds the outgoing hart's bank to the
        // latched commit-head PC so its killed head (WFI included)
        // re-executes on the next activation. Written last so it wins over
        // a same-cycle retire/redirect into the same bank entry.
        if (switch_i && npc_alt_valid_i && |npc_alt_i)
          npc_bank_q[prev_hart_q] <= npc_alt_i;
`else
        if (switch_i) begin
          if (npc_alt_valid_i && |npc_alt_i)
            npc_bank_q[prev_hart_q] <= npc_alt_i;
          else if (|npc_live_i)
            npc_bank_q[prev_hart_q] <= npc_live_i;
        end
`endif
      end
    end

    // Combinational restore target for the cycle of the switch (new active).
    assign restore_o = switch_i;
`ifdef G6LC_FETCH_B
    assign npc_restore_o = npc_bank_q[active_hart_i];
`ifndef G6LC_MUT_PCBANK_RETIRE_MIXED
    // Whichever authority is inactive under this handoff mode still has its
    // ports wired (constant consumers in cva6.sv); keep lint quiet.
    logic _unused_bank_src;
    assign _unused_bank_src = CVA6Cfg.SmtDrainedHandoff
        ? (npc_live_valid_i | (|npc_live_i))
        : ((|retire_valid_i) | (|retire_hart_i) | (|retire_pc_i));
`endif
`else
    assign npc_restore_o = (|npc_bank_q[active_hart_i]) ? npc_bank_q[active_hart_i]
                                                        : boot_addr_i;
`endif
  end

endmodule
