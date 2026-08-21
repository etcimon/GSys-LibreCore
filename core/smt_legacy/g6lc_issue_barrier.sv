// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E1 — per-hart issue barriers (CF / CSR / SP).
//
// Bit-identical move of hang-6/7 + I4s + I4au + cont.33 from issue_stage
// gen_inorder_issue. Peer SMT harts keep issuing. SI: CF/CSR one bit;
// SP inert (!SuperscalarEn). G0 pointer-liveness hold-FAIL 2026-08-15
// (plat_hc=80 mepc=0x7394 mcause=6) — reverted. Do not re-land that stall.
// G1i unresolved_a0 (stall c.mv s*,a0) hold-FAIL 2026-08-15 — reverted
// (I4af family: cancelled a0-write leaves the bit stuck). Do not re-land.
// G1af spec STQ no-forward HOLD-FAIL — do not re-land.
// G1ag: combinational ID stall of STORE ra vs an older link-jal.
// G1al: same stall vs an older ID addi sp. G1ai missed ID (addi
// not in SB). Not G1aj/G1ak.
// G1at ALU-li alloc HOLD-FAIL — do not re-land.
// G1ax leftover-RVI CF skip unresolved_cf — HOLD-FAIL plat_hc=80.
// Do not re-land.
// G1dt: leftover-complete Jump may issue through
// unresolved leftover Jump (996 jal x0 vs jal@7c6).
// Not G1ax (all leftover CF). Not G1dr G1dc rd.
// G1dt kept (hygiene; ra still 752; no @38e0).
// G1em: a0-Branch waits for older ID CSR-to-a0
// (any line). Did not close 7bc (G1dc leftover
// Jump still first). Keep (hygiene).
// G1ey: dest-FIFO a0-Branch waits for queued
// CSR-to-a0; same-cycle later issue-port CSR
// also stalls the Branch.
// G1ay: same-line Branch waits for older unissued ALU/LOAD dest.
// G1bh: older same-line NoCF dest may issue while that Branch is
// unresolved. Not G1ax (bit stays). Not G1ab/G1bb.
// G1gh: leftover jal x0 waits for same-hart jalr
// commit. Not G1gf stall-all jalr. SMT+SS.
// Timing: same issue-valid AND + per-hart PC flop. No new clock.

module g6lc_issue_barrier
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type scoreboard_entry_t = logic,
    parameter type bp_resolve_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic flush_unissued_instr_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0] issue_valid_sb_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0] issue_ack_iro_i,
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_instr_sb_i,
    // G1ag: ID head (unissued). Stall STORE ra if an older same-hart
    // link-jal is still here. Not G1i (no sticky). Not G1af.
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_valid_i,
    input  logic resolve_branch_i,
    input  bp_resolve_t resolved_branch_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack_i,
    input  scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0] commit_instr_i,
    // G1fh: IQ dest-FIFO / presented CSR-to-a0
    input  logic g1fh_csr_a0_i,
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] g1fh_hart_i,
    output logic [CVA6Cfg.NrIssuePorts-1:0] issue_valid_o
);

  localparam int unsigned N_HARTS = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;

  logic [N_HARTS-1:0] unresolved_cf_q, issue_cf_hart, resolve_cf_hart, commit_cf_hart;
  logic [N_HARTS-1:0] unresolved_cf_branch_q;
  logic [N_HARTS-1:0][63:0] unresolved_cf_pc_q;
  logic [N_HARTS-1:0] unresolved_csr_q, issue_csr_hart, commit_csr_hart;
  logic [N_HARTS-1:0] unresolved_sp_q, issue_sp_hart, commit_sp_hart;

  logic [N_HARTS-1:0] issue_cf_is_branch;
  logic [N_HARTS-1:0][63:0] issue_cf_pc;

  always_comb begin
    issue_cf_hart = '0;
    issue_cf_is_branch = '0;
    issue_cf_pc = '0;
    for (int unsigned pi = 0; pi < CVA6Cfg.NrIssuePorts; pi++) begin
      if (issue_valid_sb_i[pi] && issue_ack_iro_i[pi] &&
          (issue_instr_sb_i[pi].fu == CTRL_FLOW) &&
          g6lc_sb_keep::alloc(
              CVA6Cfg,
              flush_unissued_instr_i,
              issue_instr_sb_i[pi].fu,
              issue_instr_sb_i[pi].rd[4:0])) begin
        if (!unresolved_cf_q[issue_instr_sb_i[pi].hart_id]) begin
          issue_cf_hart[issue_instr_sb_i[pi].hart_id] = 1'b1;
          issue_cf_is_branch[issue_instr_sb_i[pi].hart_id] =
              op_is_branch(issue_instr_sb_i[pi].op);
          issue_cf_pc[issue_instr_sb_i[pi].hart_id] =
              64'(issue_instr_sb_i[pi].pc);
        end
      end
    end
  end

  always_comb begin
    resolve_cf_hart = '0;
    if (resolve_branch_i) begin
      resolve_cf_hart[resolved_branch_i.hart_id] = 1'b1;
    end
  end

  always_comb begin
    commit_cf_hart = '0;
    for (int unsigned ci = 0; ci < CVA6Cfg.NrCommitPorts; ci++) begin
      if (commit_ack_i[ci] && (commit_instr_i[ci].fu == CTRL_FLOW)) begin
        commit_cf_hart[commit_instr_i[ci].hart_id] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      unresolved_cf_q        <= '0;
      unresolved_cf_branch_q <= '0;
      unresolved_cf_pc_q     <= '0;
    end else if (flush_i) begin
      unresolved_cf_q        <= '0;
      unresolved_cf_branch_q <= '0;
    end else begin
      for (int unsigned h = 0; h < N_HARTS; h++) begin
        if (resolve_cf_hart[h]) begin
          unresolved_cf_q[h]        <= 1'b0;
          unresolved_cf_branch_q[h] <= 1'b0;
        end else if (issue_cf_hart[h]) begin
          unresolved_cf_q[h]        <= 1'b1;
          unresolved_cf_branch_q[h] <= issue_cf_is_branch[h];
          unresolved_cf_pc_q[h]     <= issue_cf_pc[h];
        end else if (commit_cf_hart[h]) begin
          unresolved_cf_q[h]        <= 1'b0;
          unresolved_cf_branch_q[h] <= 1'b0;
        end
      end
    end
  end

  always_comb begin
    issue_csr_hart = '0;
    for (int unsigned pi = 0; pi < CVA6Cfg.NrIssuePorts; pi++) begin
      if (issue_valid_sb_i[pi] && issue_ack_iro_i[pi] &&
          (issue_instr_sb_i[pi].fu == CSR)) begin
        if (!unresolved_csr_q[issue_instr_sb_i[pi].hart_id]) begin
          issue_csr_hart[issue_instr_sb_i[pi].hart_id] = 1'b1;
        end
      end
    end
  end

  always_comb begin
    commit_csr_hart = '0;
    for (int unsigned ci = 0; ci < CVA6Cfg.NrCommitPorts; ci++) begin
      if (commit_ack_i[ci] && (commit_instr_i[ci].fu == CSR)) begin
        commit_csr_hart[commit_instr_i[ci].hart_id] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      unresolved_csr_q <= '0;
    end else if (flush_i) begin
      unresolved_csr_q <= '0;
    end else begin
      for (int unsigned h = 0; h < N_HARTS; h++) begin
        if (commit_csr_hart[h]) begin
          unresolved_csr_q[h] <= 1'b0;
        end else if (issue_csr_hart[h]) begin
          unresolved_csr_q[h] <= 1'b1;
        end
      end
    end
  end

  always_comb begin
    issue_sp_hart = '0;
    if (CVA6Cfg.SuperscalarEn) begin
      for (int unsigned pi = 0; pi < CVA6Cfg.NrIssuePorts; pi++) begin
        if (issue_valid_sb_i[pi] && issue_ack_iro_i[pi] &&
            (issue_instr_sb_i[pi].rd == 5'd2) &&
            !(CVA6Cfg.FpPresent &&
              is_rd_fpr(issue_instr_sb_i[pi].op))) begin
          if (!unresolved_sp_q[issue_instr_sb_i[pi].hart_id]) begin
            issue_sp_hart[issue_instr_sb_i[pi].hart_id] = 1'b1;
          end
        end
      end
    end
  end

  always_comb begin
    commit_sp_hart = '0;
    if (CVA6Cfg.SuperscalarEn) begin
      for (int unsigned ci = 0; ci < CVA6Cfg.NrCommitPorts; ci++) begin
        if (commit_ack_i[ci] && (commit_instr_i[ci].rd == 5'd2) &&
            !(CVA6Cfg.FpPresent &&
              is_rd_fpr(commit_instr_i[ci].op))) begin
          commit_sp_hart[commit_instr_i[ci].hart_id] = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      unresolved_sp_q <= '0;
    end else if (flush_i) begin
      unresolved_sp_q <= '0;
    end else if (CVA6Cfg.SuperscalarEn) begin
      for (int unsigned h = 0; h < N_HARTS; h++) begin
        if (commit_sp_hart[h]) begin
          unresolved_sp_q[h] <= 1'b0;
        end else if (issue_sp_hart[h]) begin
          unresolved_sp_q[h] <= 1'b1;
        end
      end
    end else begin
      unresolved_sp_q <= '0;
    end
  end

  // G1ag: STORE rs2==ra waits for an unissued older same-hart link-jal
  // in ID. Younger ID jals must not stall (that is hold-unsafe).
  logic [CVA6Cfg.NrIssuePorts-1:0] stall_store_ra_id;
  always_comb begin
    stall_store_ra_id = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            issue_instr_sb_i[p].fu == STORE &&
            issue_instr_sb_i[p].rs2[4:0] == 5'd1) begin
          for (int unsigned d = 0; d < CVA6Cfg.NrIssuePorts; d++) begin
            if (decoded_instr_valid_i[d] &&
                decoded_instr_i[d].fu == CTRL_FLOW &&
                decoded_instr_i[d].rd[4:0] == 5'd1 &&
                decoded_instr_i[d].hart_id == issue_instr_sb_i[p].hart_id &&
                decoded_instr_i[d].pc < issue_instr_sb_i[p].pc) begin
              stall_store_ra_id[p] = 1'b1;
            end
          end
        end
      end
    end
  end

  // G1al: STORE rs2==ra waits for an unissued older same-hart
  // addi sp in ID. G1ai only scanned the SB. Younger ID addi
  // must not stall (hold-unsafe sticky). Not G1aj/G1ak.
  logic [CVA6Cfg.NrIssuePorts-1:0] stall_store_ra_addi_id;
  always_comb begin
    stall_store_ra_addi_id = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            issue_instr_sb_i[p].fu == STORE &&
            issue_instr_sb_i[p].rs2[4:0] == 5'd1) begin
          for (int unsigned d = 0; d < CVA6Cfg.NrIssuePorts; d++) begin
            if (decoded_instr_valid_i[d] &&
                decoded_instr_i[d].hart_id == issue_instr_sb_i[p].hart_id &&
                decoded_instr_i[d].pc < issue_instr_sb_i[p].pc &&
                g6lc_sb_keep::addi_sp(
                    decoded_instr_i[d].fu,
                    decoded_instr_i[d].rd[4:0],
                    decoded_instr_i[d].rs1[4:0])) begin
              stall_store_ra_addi_id[p] = 1'b1;
            end
          end
        end
      end
    end
  end

  // G1eb ID RAW vs older writer — MINI-FAIL hang @400000
  // (tohost=0). Do not re-land (in-order SB head stalled
  // so the older ID writer never allocates).
  // G1ay: Branch waits for an older same-hart NoCF dest on the same
  // 8B line (c.li/c.ldsp before beq@0x4d4). Combinational. Not G1ax
  // (do not drop unresolved_cf). Not G1i. Not G1aq keep_line.
  // G1be: ID insert of that prefix when the Branch is already in
  // issue_q[0] (G1ay only sees ID/SB). Not G1bd. Not G1at.
  logic [CVA6Cfg.NrIssuePorts-1:0] stall_branch_prefix;
  always_comb begin
    stall_branch_prefix = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            issue_instr_sb_i[p].fu == CTRL_FLOW &&
            op_is_branch(issue_instr_sb_i[p].op)) begin
          for (int unsigned d = 0; d < CVA6Cfg.NrIssuePorts; d++) begin
            if (decoded_instr_valid_i[d] &&
                decoded_instr_i[d].hart_id == issue_instr_sb_i[p].hart_id &&
                decoded_instr_i[d].pc < issue_instr_sb_i[p].pc &&
                decoded_instr_i[d].pc[CVA6Cfg.VLEN-1:3] ==
                    issue_instr_sb_i[p].pc[CVA6Cfg.VLEN-1:3] &&
                g6lc_sb_keep::nocf_dest(
                    decoded_instr_i[d].fu,
                    decoded_instr_i[d].rd[4:0]))
              stall_branch_prefix[p] = 1'b1;
          end
          for (int unsigned q = 0; q < CVA6Cfg.NrIssuePorts; q++) begin
            if (q != p && issue_valid_sb_i[q] &&
                issue_instr_sb_i[q].hart_id == issue_instr_sb_i[p].hart_id &&
                issue_instr_sb_i[q].pc < issue_instr_sb_i[p].pc &&
                issue_instr_sb_i[q].pc[CVA6Cfg.VLEN-1:3] ==
                    issue_instr_sb_i[p].pc[CVA6Cfg.VLEN-1:3] &&
                g6lc_sb_keep::nocf_dest(
                    issue_instr_sb_i[q].fu,
                    issue_instr_sb_i[q].rd[4:0]))
              stall_branch_prefix[p] = 1'b1;
          end
        end
      end
    end
  end

  // G1em: Branch on a0 waits for an older same-hart
  // CSR-to-a0 still in ID (any line). 7bc otherwise
  // issues with RF a0=1, then csrr commits, then
  // EX takes 766. Not G1ay same-line ALU/LOAD. Not
  // G1eb stall-all RAW (writer can still allocate).
  // Not G1ea (CSR already in SB). SMT+SS.
  logic [CVA6Cfg.NrIssuePorts-1:0] stall_branch_csr_a0;
  always_comb begin
    stall_branch_csr_a0 = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            issue_instr_sb_i[p].fu == CTRL_FLOW &&
            op_is_branch(issue_instr_sb_i[p].op) &&
            (issue_instr_sb_i[p].rs1[4:0] == 5'd10)) begin
          for (int unsigned d = 0; d < CVA6Cfg.NrIssuePorts; d++) begin
            if (decoded_instr_valid_i[d] &&
                decoded_instr_i[d].fu == CSR &&
                decoded_instr_i[d].rd[4:0] == 5'd10 &&
                decoded_instr_i[d].hart_id ==
                    issue_instr_sb_i[p].hart_id &&
                decoded_instr_i[d].pc < issue_instr_sb_i[p].pc)
              stall_branch_csr_a0[p] = 1'b1;
          end
          // G1ey: same-cycle issue port (G1em/G1ea miss
          // when CSR is a later port than the Branch).
          for (int unsigned q = 0; q < CVA6Cfg.NrIssuePorts; q++) begin
            if (q != p && issue_valid_sb_i[q] &&
                issue_instr_sb_i[q].fu == CSR &&
                issue_instr_sb_i[q].rd[4:0] == 5'd10 &&
                issue_instr_sb_i[q].hart_id ==
                    issue_instr_sb_i[p].hart_id &&
                issue_instr_sb_i[q].pc < issue_instr_sb_i[p].pc)
              stall_branch_csr_a0[p] = 1'b1;
          end
        end
      end
    end
  end

  // G1ev: Branch on a0 waits for an older same-hart
  // ALU to a0 in ID (auipc/addi). G1em is CSR-only.
  // Not G1eb stall-all RAW. Not G1ay same-line.
  // SMT+SS.
  logic [CVA6Cfg.NrIssuePorts-1:0] stall_branch_alu_a0;
  always_comb begin
    stall_branch_alu_a0 = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            issue_instr_sb_i[p].fu == CTRL_FLOW &&
            op_is_branch(issue_instr_sb_i[p].op) &&
            (issue_instr_sb_i[p].rs1[4:0] == 5'd10)) begin
          for (int unsigned d = 0; d < CVA6Cfg.NrIssuePorts; d++) begin
            if (decoded_instr_valid_i[d] &&
                decoded_instr_i[d].fu == ALU &&
                decoded_instr_i[d].rd[4:0] == 5'd10 &&
                decoded_instr_i[d].hart_id ==
                    issue_instr_sb_i[p].hart_id &&
                decoded_instr_i[d].pc < issue_instr_sb_i[p].pc)
              stall_branch_alu_a0[p] = 1'b1;
          end
        end
      end
    end
  end

  // G1dt: leftover-complete Jump (pc[2:1]==11) may
  // issue through unresolved leftover Jump (996 jal
  // x0 is not a Branch). G1ds: 996 and jal@7c6 are
  // sequential; leftover 7c8 then gone, ra stays
  // 752, no @38e0. G1ax leftover-RVI CF skip —
  // HOLD-FAIL. Jump-only vs leftover Jump.
  // Not G1dr. Not G1dc. SMT+SS.
  logic [CVA6Cfg.NrIssuePorts-1:0] leftover_jump_through_cf;
  always_comb begin
    leftover_jump_through_cf = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            issue_instr_sb_i[p].fu == CTRL_FLOW &&
            !op_is_branch(issue_instr_sb_i[p].op) &&
            issue_instr_sb_i[p].op != JALR &&
            (issue_instr_sb_i[p].pc[2:1] == 2'b11) &&
            unresolved_cf_q[issue_instr_sb_i[p].hart_id] &&
            !unresolved_cf_branch_q[issue_instr_sb_i[p].hart_id] &&
            (unresolved_cf_pc_q[issue_instr_sb_i[p].hart_id][2:1] ==
             2'b11))
          leftover_jump_through_cf[p] = 1'b1;
      end
    end
  end

  // G1gh: leftover jal x0 (pc[2:1]==11, rd=0)
  // waits while a same-hart jalr is uncommitted.
  // 766 fetched @20470 beside 7ba cmt @20475.
  // Not G1gf (does not stall jalr). Not G1fo
  // dest-FIFO hide. SMT+SS.
  logic [N_HARTS-1:0] g1gh_seen_q;
  logic [N_HARTS-1:0] g1gh_arm, g1gh_commit;
  always_comb begin
    g1gh_arm = '0;
    g1gh_commit = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned d = 0; d < CVA6Cfg.NrIssuePorts; d++) begin
        if (decoded_instr_valid_i[d] &&
            decoded_instr_i[d].op == JALR)
          g1gh_arm[decoded_instr_i[d].hart_id] = 1'b1;
        if (issue_valid_sb_i[d] &&
            issue_instr_sb_i[d].op == JALR)
          g1gh_arm[issue_instr_sb_i[d].hart_id] = 1'b1;
      end
      for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
        if (commit_ack_i[c] &&
            commit_instr_i[c].op == JALR)
          g1gh_commit[commit_instr_i[c].hart_id] = 1'b1;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      g1gh_seen_q <= '0;
    else if (flush_i)
      g1gh_seen_q <= '0;
    else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned h = 0; h < N_HARTS; h++) begin
        if (g1gh_commit[h])
          g1gh_seen_q[h] <= 1'b0;
        else if (g1gh_arm[h])
          g1gh_seen_q[h] <= 1'b1;
      end
    end else
      g1gh_seen_q <= '0;
  end
  logic [CVA6Cfg.NrIssuePorts-1:0] stall_leftover_jal_x0;
  always_comb begin
    stall_leftover_jal_x0 = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            issue_instr_sb_i[p].fu == CTRL_FLOW &&
            !op_is_branch(issue_instr_sb_i[p].op) &&
            issue_instr_sb_i[p].op != JALR &&
            (issue_instr_sb_i[p].rd[4:0] == 5'd0) &&
            (issue_instr_sb_i[p].pc[2:1] == 2'b11) &&
            (g1gh_seen_q[issue_instr_sb_i[p].hart_id] ||
             g1gh_arm[issue_instr_sb_i[p].hart_id]))
          stall_leftover_jal_x0[p] = 1'b1;
      end
    end
  end

  // G1fh: a0-Branch waits until a seen CSR-to-a0 commits.
  // TRACE G1fg: csrr@7ac commits t=20463 after 7b8 t=20458
  // (7bc already issued). G1ey is dest-FIFO-only; G1em
  // is ID-only; G1ea is SB-only. Arm on IQ sighting /
  // ID / issue; clear on commit or flush. Not G1i
  // unresolved_a0 (that stalled c.mv). SMT+SS.
  logic [N_HARTS-1:0] g1fh_seen_q;
  logic [N_HARTS-1:0] g1fh_arm, g1fh_commit;
  always_comb begin
    g1fh_arm = '0;
    g1fh_commit = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (g1fh_csr_a0_i)
        g1fh_arm[g1fh_hart_i] = 1'b1;
      for (int unsigned d = 0; d < CVA6Cfg.NrIssuePorts; d++) begin
        if (decoded_instr_valid_i[d] &&
            decoded_instr_i[d].fu == CSR &&
            decoded_instr_i[d].rd[4:0] == 5'd10)
          g1fh_arm[decoded_instr_i[d].hart_id] = 1'b1;
        if (issue_valid_sb_i[d] &&
            issue_instr_sb_i[d].fu == CSR &&
            issue_instr_sb_i[d].rd[4:0] == 5'd10)
          g1fh_arm[issue_instr_sb_i[d].hart_id] = 1'b1;
      end
      for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
        if (commit_ack_i[c] &&
            commit_instr_i[c].fu == CSR &&
            commit_instr_i[c].rd[4:0] == 5'd10)
          g1fh_commit[commit_instr_i[c].hart_id] = 1'b1;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      g1fh_seen_q <= '0;
    else if (flush_i)
      g1fh_seen_q <= '0;
    else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned h = 0; h < N_HARTS; h++) begin
        if (g1fh_commit[h])
          g1fh_seen_q[h] <= 1'b0;
        else if (g1fh_arm[h])
          g1fh_seen_q[h] <= 1'b1;
      end
    end else
      g1fh_seen_q <= '0;
  end
  logic [CVA6Cfg.NrIssuePorts-1:0] stall_branch_csr_a0_seen;
  always_comb begin
    stall_branch_csr_a0_seen = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            issue_instr_sb_i[p].fu == CTRL_FLOW &&
            op_is_branch(issue_instr_sb_i[p].op) &&
            (issue_instr_sb_i[p].rs1[4:0] == 5'd10) &&
            g1fh_seen_q[issue_instr_sb_i[p].hart_id])
          stall_branch_csr_a0_seen[p] = 1'b1;
      end
    end
  end

  // G1bh: keep_prefix may issue while the same-line Branch is
  // unresolved. G1ay only fires when both are in ID/issue together.
  logic [CVA6Cfg.NrIssuePorts-1:0] prefix_through_cf;
  always_comb begin
    prefix_through_cf = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_valid_sb_i[p] &&
            unresolved_cf_q[issue_instr_sb_i[p].hart_id] &&
            unresolved_cf_branch_q[issue_instr_sb_i[p].hart_id] &&
            g6lc_sb_keep::keep_prefix(
                CVA6Cfg,
                issue_instr_sb_i[p].fu,
                issue_instr_sb_i[p].rd[4:0],
                64'(issue_instr_sb_i[p].pc),
                unresolved_cf_pc_q[issue_instr_sb_i[p].hart_id],
                ariane_pkg::Branch))
          prefix_through_cf[p] = 1'b1;
      end
    end
  end

  // I13: registered unresolved_csr_q misses a same-cycle pair
  // (csrrw mtvec + probe CSR). Stall younger ports on the older CSR.
  logic [CVA6Cfg.NrIssuePorts-1:0] stall_csr_older;
  always_comb begin
    stall_csr_older = '0;
    if (CVA6Cfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin
        for (int unsigned o = 0; o < p; o++) begin
          if (issue_valid_sb_i[o] && issue_instr_sb_i[o].fu == CSR &&
              issue_valid_sb_i[p] &&
              issue_instr_sb_i[p].hart_id == issue_instr_sb_i[o].hart_id)
            stall_csr_older[p] = 1'b1;
        end
      end
    end
  end

  for (genvar p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin : gen_gate
    assign issue_valid_o[p] =
        issue_valid_sb_i[p]
        && !(unresolved_cf_q[issue_instr_sb_i[p].hart_id] &&
             !prefix_through_cf[p] && !leftover_jump_through_cf[p])
        && !unresolved_csr_q[issue_instr_sb_i[p].hart_id]
        && !stall_csr_older[p]
        && !(CVA6Cfg.SuperscalarEn &&
             unresolved_sp_q[issue_instr_sb_i[p].hart_id])
        && !stall_store_ra_id[p]
        && !stall_store_ra_addi_id[p]
        && !stall_branch_prefix[p]
        && !stall_branch_csr_a0[p]
        && !stall_branch_alu_a0[p]
        && !stall_branch_csr_a0_seen[p]
        && !stall_leftover_jal_x0[p];
  end

endmodule
