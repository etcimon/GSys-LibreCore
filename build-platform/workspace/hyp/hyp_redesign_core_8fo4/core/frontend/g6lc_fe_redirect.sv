// hyp8 provenance: REWRITTEN for the 8-FO4 frontend (staged redirect record)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_fe_redirect — the frontend's single redirect point.
//
// All redirect sources are arbitrated ONCE, combinationally, with the
// original priority (trap > eret > commit/peer > debug > SMT restore >
// mispredict), then the prediction-path sources at lower priority
// (replay reseed > BTB override > response override). The winning record —
// {pc, step, reseed, trap, src} — is REGISTERED and applied for exactly one
// cycle: g6lc_fe_nextline takes red_pc_i into the npc_d mux and the FTQ
// reseeds from it.
//
// The register is also where the fetch epoch lives: every captured record
// increments epoch_q, so during the apply cycle epoch_o already reads the
// new epoch. Stages and queues stamp their state with epoch_i at accept;
// anything stamped with an older epoch once epoch_o advances is dead
// (FTQ head/peek, realign stage B, the queue's per-lane heads, the RAS
// speculative update, the registered restore).
//
// A registered record is squashable only by a STRONGER arbiter winner in its
// apply cycle (an architectural redirect or a mispredict squashes a pending
// replay/override — the replay is re-presented by its own hold anyway, and
// an override loses only wrong-path work). An architectural record pending
// while another wins still applies that cycle; both land in order.
//
// Timing contract (rank 3, overlap + epoch kill): arch/mispredict redirect
// latency to npc_d is +1 cycle versus the combinational npc_select of the
// reference. npc_d itself is not registered: the fetch loop stays
// npc_q -> line table read-ahead -> npc_d (see g6lc_fe_nextline).

module g6lc_fe_redirect
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter type bp_resolve_t = logic
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    // ---- architectural sources (same inputs as the reference encoder)
    input  logic                    flush_i,
    input  logic                    ex_valid_i,
    input  logic                    eret_i,
    input  logic [G6LCCfg.VLEN-1:0] epc_i,
    input  logic [G6LCCfg.VLEN-1:0] trap_vector_base_i,
    input  logic                    set_pc_commit_i,
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] commit_hart_i,
    input  logic [G6LCCfg.VLEN-1:0] pc_commit_i,
    input  logic                    halt_i,
    input  logic                    mem_replay_pc_i,
    input  logic                    set_debug_pc_i,
    input  logic                    smt_restore_i,
    input  logic [G6LCCfg.VLEN-1:0] smt_npc_restore_i,
    input  logic                    peer_restart_valid_i,
    input  logic [G6LCCfg.VLEN-1:0] peer_restart_pc_i,
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] smt_hart_i,
    // ---- resolve-side mispredict
    input  bp_resolve_t             resolved_branch_i,
    // ---- replay reseed (registered in the frontend, lowest hard priority)
    input  logic                    replay_i,
    input  logic [G6LCCfg.VLEN-1:0] replay_addr_i,
    // ---- prediction overrides (registered upstream)
    input  logic                    ov1_valid_i,    // g6lc_fe_btb_check
    input  logic [G6LCCfg.VLEN-1:0] ov1_pc_i,
    input  logic                    ov2_valid_i,    // g6lc_fe_override
    input  logic [G6LCCfg.VLEN-1:0] ov2_pc_i,

    // ---- registered redirect record, applied for one cycle
    output logic                    red_valid_o,
    output logic [G6LCCfg.VLEN-1:0] red_pc_o,
    output logic                    red_step_o,    // npc steps past pc (FTQ pushed it)
    output logic                    red_reseed_o,  // FTQ flush+push this cycle
    output logic                    red_trap_o,    // trap-class redirect (switch hold)
    output logic [3:0]              red_src_o,     // g6lc_fetch_pkg SRC_* or local
    // hyp8 H27: perf pulses — the override verdict won arbitration and its
    // redirect record is applying this cycle.
    output logic                    ov1_taken_o,
    output logic                    ov2_taken_o,
    // ---- same-cycle arbiter outcomes for the kill/replay plumbing
    // (these events must still take effect the cycle they arrive: kill_s1,
    //  checkpoint suppression, replay clear — they are not delayed by the
    //  record register)
    output logic                    misp_now_o,    // qualified mispredict this cycle
    output logic                    arch_now_o,    // any arch/misp winner this cycle
    output logic                    resolve_active_o, // active-hart resolve this cycle
    // ---- fetch epoch (advances on every captured record)
    output logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] epoch_o
);

  localparam g6lc_fetch_pkg::fetch_geo_t Geo = g6lc_fetch_pkg::geo(G6LCCfg);
  localparam bit FtqEn  = Geo.ftq;
  localparam bit SmtEn  = Geo.smt;
  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;

  // local redirect classes appended below the shared SRC_* encoder range
  localparam logic [3:0] SRC_REPLAY = 4'd8;
  localparam logic [3:0] SRC_OV1    = 4'd9;
  localparam logic [3:0] SRC_OV2    = 4'd10;

  // ------------------------------------------------------------------
  // Same-cycle arbitration (verbatim priority of the reference encoder)
  // ------------------------------------------------------------------
  logic resolution_for_active, misp_outranked, is_mispredict;

  // T19 (defect 1): hart-qualify the redirect under MIXED residency only.
  assign resolution_for_active = g6lc_fetch_pkg::redirect_for_hart(
      SmtEn && !G6LCCfg.SmtDrainedHandoff, resolved_branch_i.valid,
      8'(resolved_branch_i.hart_id), 8'(smt_hart_i));
  // A branch resolving in the cycle an older architectural redirect fires is
  // younger than that redirect and squashed by it: its resolution must not arm
  // the mispredict target filter or kill the redirect's fetch (see frontend).
  assign misp_outranked = ex_valid_i | eret_i |
      g6lc_fetch_pkg::commit_for_hart(SmtEn, set_pc_commit_i, 8'(commit_hart_i), 8'(smt_hart_i));
  assign is_mispredict = resolution_for_active && resolved_branch_i.is_mispredict && !misp_outranked;

  logic [G6LCCfg.VLEN-1:0] commit_next_pc, debug_halt_pc;
  // CSR or AMO instructions do not exist in a compressed form, so commit + 4;
  // if commit is halted just take the PC of the instruction sitting there.
  assign commit_next_pc = pc_commit_i + ((halt_i || mem_replay_pc_i) ? '0 : {{G6LCCfg.VLEN - 3{1'b0}}, 3'b100});
  assign debug_halt_pc = G6LCCfg.DmBaseAddress[G6LCCfg.VLEN-1:0]
                         + G6LCCfg.HaltAddress[G6LCCfg.VLEN-1:0];

  logic [3:0] arch_src;
  assign arch_src = g6lc_fetch_pkg::arch_src_sel(
      SmtEn, smt_restore_i, G6LCCfg.DebugEn && set_debug_pc_i,
      g6lc_fetch_pkg::commit_for_hart(SmtEn, set_pc_commit_i,
          8'(commit_hart_i), 8'(smt_hart_i)),
      peer_restart_valid_i,
      g6lc_fetch_pkg::commit_for_hart(SmtEn, ex_valid_i,
          8'(commit_hart_i), 8'(smt_hart_i)),
      g6lc_fetch_pkg::commit_for_hart(SmtEn, eret_i,
          8'(commit_hart_i), 8'(smt_hart_i)),
      is_mispredict);

  // Arbiter winner record (combinational)
  logic                    arb_valid;
  logic [G6LCCfg.VLEN-1:0] arb_pc;
  logic                    arb_step;
  logic                    arb_reseed;
  logic                    arb_trap;
  logic [3:0]              arb_src;

  always_comb begin : arb_select
    arb_valid  = 1'b1;
    arb_step   = FtqEn;
    arb_reseed = 1'b1;
    arb_trap   = 1'b0;
    arb_pc     = '0;
    arb_src    = arch_src;

    unique case (arch_src)
      g6lc_fetch_pkg::SRC_EX: begin
        arb_pc   = trap_vector_base_i;
        arb_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_ERET: begin
        arb_pc   = epc_i;
        arb_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_COMMIT: begin
        arb_pc     = commit_next_pc;
        arb_step   = FtqEn & ~halt_i;
        arb_reseed = flush_i;
      end
      g6lc_fetch_pkg::SRC_PEER: begin
        arb_pc = peer_restart_pc_i;
      end
      g6lc_fetch_pkg::SRC_DEBUG: begin
        arb_pc   = debug_halt_pc;
        arb_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_RESTORE: begin
        arb_pc = smt_npc_restore_i;
        // With an FTQ the reseeded entry owns the restore window, so the NPC
        // enqueue cursor must step past it like any other reseed.
        arb_step = FtqEn;
      end
      g6lc_fetch_pkg::SRC_MISP: begin
        arb_pc = resolved_branch_i.target_address;
      end
      default: begin
        arb_valid  = 1'b0;
        arb_step   = 1'b0;
        arb_reseed = 1'b0;
      end
    endcase

    // ---- lower-priority sources, only when no arch/misp winner ----
    if (!arb_valid) begin
      if (replay_i) begin
        // Refused-window reseed: present the window again and, with an FTQ,
        // step the enqueue cursor past it (same semantics as the reference
        // seq_base = replay_addr_q path).
        arb_valid  = 1'b1;
        arb_src    = SRC_REPLAY;
        arb_pc     = replay_addr_i;
        arb_step   = FtqEn;
        arb_reseed = 1'b1;
      end else if (ov1_valid_i) begin
        // Override #1 (BTB/RAS disagreement with the line guess)
        arb_valid  = 1'b1;
        arb_src    = SRC_OV1;
        arb_pc     = ov1_pc_i;
        arb_step   = FtqEn;
        arb_reseed = 1'b1;
      end else if (ov2_valid_i) begin
        // Override #2 (response-side predictor verdict)
        arb_valid  = 1'b1;
        arb_src    = SRC_OV2;
        arb_pc     = ov2_pc_i;
        arb_step   = FtqEn;
        arb_reseed = 1'b1;
      end
    end
  end

  assign misp_now_o = is_mispredict;
  assign resolve_active_o = resolution_for_active;
  assign arch_now_o = arb_valid && (arb_src != SRC_REPLAY) &&
                      (arb_src != SRC_OV1) && (arb_src != SRC_OV2);

  // ------------------------------------------------------------------
  // Registered record + epoch
  // ------------------------------------------------------------------
  logic                    red_valid_q;
  logic [G6LCCfg.VLEN-1:0] red_pc_q;
  logic                    red_step_q;
  logic                    red_reseed_q;
  logic                    red_trap_q;
  logic [3:0]              red_src_q;
  logic [EW-1:0]           epoch_q;

  // A pending weak record (replay/override) is squashed by a stronger winner;
  // a pending hard record still applies — the new winner queues behind it.
  logic pending_weak, squash;
  assign pending_weak = red_valid_q &&
      ((red_src_q == SRC_REPLAY) || (red_src_q == SRC_OV1) || (red_src_q == SRC_OV2));
  assign squash = pending_weak && arch_now_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      red_valid_q  <= 1'b0;
      red_pc_q     <= '0;
      red_step_q   <= 1'b0;
      red_reseed_q <= 1'b0;
      red_trap_q   <= 1'b0;
      red_src_q    <= g6lc_fetch_pkg::SRC_NONE;
      epoch_q      <= '0;
    end else begin
      if (arb_valid) begin
        red_valid_q  <= 1'b1;
        red_pc_q     <= arb_pc;
        red_step_q   <= arb_step;
        red_reseed_q <= arb_reseed;
        red_trap_q   <= arb_trap;
        red_src_q    <= arb_src;
        // the record creates the next epoch; during its apply cycle the
        // pipeline already sees it
        epoch_q      <= epoch_q + EW'(1);
      end else begin
        red_valid_q <= 1'b0;
      end
    end
  end

  assign red_valid_o  = red_valid_q && !squash;
  assign red_pc_o     = red_pc_q;
  assign red_step_o   = red_step_q;
  assign red_reseed_o = red_reseed_q;
  assign red_trap_o   = red_trap_q;
  assign red_src_o    = red_src_q;
  assign ov1_taken_o  = red_valid_o && (red_src_q == SRC_OV1);
  assign ov2_taken_o  = red_valid_o && (red_src_q == SRC_OV2);
  assign epoch_o      = epoch_q;

endmodule
