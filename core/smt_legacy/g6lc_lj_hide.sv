// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder leftover jal x0 hide (EXTRACT g1gi–g1gm + skip-arm squash).
//
// G1gi/gj/gk: do not present leftover jal x0 while jalr in flight, npc is
// mid-line 01, or 3 cycles after 01. G1gl/gm: do not reseed npc to
// leftover-PC replay in those windows. Skip-arm: hide leftover jal x0
// after a taken same-group skip (mini_sib_cjalr P2 / 766 analog).
// Skip-range latch / leftover-PC replay block of skipped jal x0 —
// HOLD-FAIL cookie 51b1c001 mepc 0x3dc/6, hangj 766 unchanged. Do not
// re-land (c.jalr skip-arm / G1gn class). Off-line leftover-PC replay:
// do not reseed npc to leftover [2:1]==11 unless npc is on that 8B
// line (present-at-npc). Scan loop for see-jalr stays in frontend.
// Mux that applies hide / replay-block stays in frontend. SMT+SS.
//
// ljx0_pc: latch leftover jal x0 PC after serving ends
// so npc 00 first 8B can refuse that leftover-PC fetch
// (n7b0). Not lo_pc any-leftover. Not lo11 shape.
// Not G1gn npc skip. Clear when npc is on the
// leftover 16B line. Keep across flush.
//
// Timing: jalr-seen flop + 2-bit 01-hold + skip-arm flop/PC + 8B-line
// compare on npc-replay + leftover jal x0 PC flop, SMT+SS only.
// No new clock.

module g6lc_lj_hide
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic                    see_jalr_i,
    input  logic                    jump_r_i,
    input  logic                    leftover_lj_gi_i,
    input  logic                    npc01_i,
    input  logic                    arm_i,
    input  logic [CVA6Cfg.VLEN-1:0] arm_pc_i,
    input  logic [CVA6Cfg.VLEN-1:0] arm_br_pc_i,
    input  logic                    leftover_lj_i,
    input  logic [CVA6Cfg.VLEN-1:0] leftover_pc_i,
    input  logic                    br_nt_i,
    input  logic                    br_taken_i,
    input  logic [CVA6Cfg.VLEN-1:0] br_pc_i,
    input  logic [CVA6Cfg.VLEN-1:0] npc_i,
    input  logic [CVA6Cfg.VLEN-1:0] replay_addr_i,
    output logic                    hide_o,
    output logic                    gi_hide_o,
    output logic                    replay_block_o,
    output logic                    pend_o,
    output logic                    clear_leftover_o,
    output logic                    lj_pc_v_o,
    output logic [CVA6Cfg.VLEN-1:0] lj_pc_o
);
  logic                    jalr_q;
  logic [1:0]              cnt_q;
  logic                    pend_q;
  logic [CVA6Cfg.VLEN-1:0] pc_q;
  logic [CVA6Cfg.VLEN-1:0] br_pc_q;
  logic                    lj_pc_v_q;
  logic [CVA6Cfg.VLEN-1:0] lj_pc_q;
  logic                    our_nt;
  logic                    our_taken;
  logic                    skip_rpl;
  logic                    off_rpl;
  logic                    gl_block;
  logic                    gm_block;
  assign our_nt    = br_nt_i && (br_pc_i == br_pc_q);
  assign our_taken = br_taken_i && (br_pc_i == br_pc_q);

  // G1gi: arm on presented jalr; clear on JumpR resolve or flush.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      jalr_q <= 1'b0;
    else if (flush_i)
      jalr_q <= 1'b0;
    else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (jump_r_i)
        jalr_q <= 1'b0;
      else if (see_jalr_i)
        jalr_q <= 1'b1;
    end else
      jalr_q <= 1'b0;
  end
  // G1gk: hold hide 3 cycles after mid-line 01.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      cnt_q <= 2'd0;
    else if (flush_i)
      cnt_q <= 2'd0;
    else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (npc01_i)
        cnt_q <= 2'd3;
      else if (cnt_q != 2'd0)
        cnt_q <= cnt_q - 2'd1;
    end else
      cnt_q <= 2'd0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_q  <= 1'b0;
      pc_q    <= '0;
      br_pc_q <= '0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (arm_i) begin
        pend_q  <= 1'b1;
        pc_q    <= arm_pc_i;
        br_pc_q <= arm_br_pc_i;
      end else if (our_nt) begin
        pend_q <= 1'b0;
      end
    end else begin
      pend_q  <= 1'b0;
      pc_q    <= '0;
      br_pc_q <= '0;
    end
  end

  // G1gi + G1gj npc 01 + G1gk 01-hold.
  assign gi_hide_o = leftover_lj_gi_i &&
      (jalr_q || see_jalr_i ||
       (leftover_lj_gi_i && npc01_i) ||
       (cnt_q != 2'd0));
  // Hide jal x0 present while the skip arm is live.
  assign hide_o = leftover_lj_i && (pend_q || arm_i) && !our_nt;
  assign skip_rpl = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      pend_q && (replay_addr_i[2:1] == 2'b11) &&
      (replay_addr_i == pc_q);
  assign off_rpl = g6lc_leftover::replay_off_line(
      CVA6Cfg, 64'(replay_addr_i), 64'(npc_i));
  // G1gl: leftover-PC replay after mid-line 01 hold.
  assign gl_block = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      (cnt_q != 2'd0) && (replay_addr_i[2:1] == 2'b11);
  // G1gm: leftover-PC replay while jalr seen (no cnt).
  assign gm_block = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      (jalr_q || see_jalr_i) && (replay_addr_i[2:1] == 2'b11);
  assign replay_block_o = skip_rpl || off_rpl || gl_block || gm_block;
  assign pend_o = pend_q || arm_i;
  assign clear_leftover_o = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      pend_q && our_taken;
  // Latch leftover jal x0 PC while serving; keep
  // after serving ends (n7b0 steal is leftover-PC
  // fetch without serving). Not flush-clear. NPC
  // on that 16B line drops the latch so leftover
  // I$ on its own line is not stolen. SMT+SS.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lj_pc_v_q <= 1'b0;
      lj_pc_q   <= '0;
    end else if (!(CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1)) begin
      lj_pc_v_q <= 1'b0;
      lj_pc_q   <= '0;
    end else if (leftover_lj_gi_i) begin
      lj_pc_v_q <= 1'b1;
      lj_pc_q   <= leftover_pc_i;
    end else if (lj_pc_v_q &&
                 (npc_i[CVA6Cfg.VLEN-1:4] ==
                  lj_pc_q[CVA6Cfg.VLEN-1:4])) begin
      lj_pc_v_q <= 1'b0;
    end
  end
  assign lj_pc_v_o = lj_pc_v_q;
  assign lj_pc_o   = lj_pc_q;
endmodule
