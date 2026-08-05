// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5 production OoO dispatch (config-gated; OoOEn=0 is netlist identity):
// multi-port rename + IQ + ROB + LSQ/CAM + PRF operands for IRO cutover + live AGU.
//
// Recovery timeline (FSE S3 — single ordering for mispredict vs full flush):
//   1. Same cycle as branch resolve mispredict:
//        - controller: flush_if + flush_unissued (not full flush_i)
//        - scoreboard: SpeculativeSb cancels younger TIDs → cancelled_mask_i
//        - rename: mispredict_i restores map/free/busy from branch ckpt
//        - IQ / ROB / LSQ: squash entries whose TID is in cancelled_mask_i
//        - PRF: WB gated by !cancelled_mask[wb_tid]
//        - memdep: flush_i | mispredict_i clears store-set table
//   2. Exception / fence / CSR side-effect:
//        - controller asserts flush_i (and more) → full structure clear
//        - rename full reset; IQ/ROB/LSQ flush_i; memdep flush
//   3. commit_drop retires cancelled SB slots without architectural write.
//
// Bottleneck optimizations:
//   * Single-cycle multi-port rename (later ports see earlier allocs)
//   * Precise free+busy+map checkpoint on branch / restore on mispredict
//   * WB → busy-table wakeup + PRF write-through + issue bypass
//   * IQ same-cycle chain wakeup + multi age-ordered grant
//   * Live AGU (rs1+imm) / store data into LSQ at issue
//   * LSQ CAM / STL forward; memdep train on store + observed dependence
//   * Multi-WB ROB complete by trans_id; multi freelist free at commit
//   * LSQ full only blocks mem dispatch (ALU continues)

module g6lc_ooo_dispatch
  import ariane_pkg::*;
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type scoreboard_entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic flush_unissued_i,
    // Younger wrong-path SB slots (SpeculativeSb cancel + same-cycle bmiss)
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]                   cancelled_mask_i,
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       dispatch_sbe_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] dispatch_orig_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]       dispatch_valid_i,
    output logic              [CVA6Cfg.NrIssuePorts-1:0]       dispatch_ack_o,
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       issue_sbe_o,
    output logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] issue_orig_o,
    output logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_valid_o,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_ack_i,
    // PRF operands for IRO (production cutover when OoOEn)
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] issue_op_a_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] issue_op_b_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                   issue_op_a_valid_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                   issue_op_b_valid_o,
    // WB
    input  logic [CVA6Cfg.NrWbPorts-1:0]                            wb_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] wb_id_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0]          wb_data_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0]                            wb_exc_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0]                        commit_ack_i,
    input  scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0]           commit_instr_i,
    input  logic                                                    mispredict_i,
    // PMU group-1 probes
    output logic freelist_empty_o,
    output logic rob_full_o,
    output logic iq_full_o,
    output logic lsq_stall_o,
    output logic rename_stall_o,
    output logic stl_forward_o
);

  localparam int unsigned ROB_N = (CVA6Cfg.RobEntries == 0) ? CVA6Cfg.NR_SB_ENTRIES
                                                            : CVA6Cfg.RobEntries;
  localparam int unsigned PRF_N = (CVA6Cfg.PrfEntries == 0) ? (32 + ROB_N + 8)
                                                            : CVA6Cfg.PrfEntries;
  localparam int unsigned IQ_N  = (CVA6Cfg.IqEntries == 0) ? ROB_N : CVA6Cfg.IqEntries;
  localparam int unsigned LD_N  = (CVA6Cfg.LsqLoadEntries == 0) ? 8 : CVA6Cfg.LsqLoadEntries;
  localparam int unsigned ST_N  = (CVA6Cfg.LsqStoreEntries == 0) ? 8 : CVA6Cfg.LsqStoreEntries;
  localparam int unsigned PRF_W = ooo_prf_w(PRF_N);
  localparam int unsigned ROB_W = ooo_rob_w(ROB_N);
  localparam int unsigned CKPT  = (CVA6Cfg.BPCkptDepth == 0) ? 8 : CVA6Cfg.BPCkptDepth;
  localparam int unsigned NP    = CVA6Cfg.NrIssuePorts;

  logic [NP-1:0] need_rd, is_br, is_ld, is_st;
  logic [NP-1:0][4:0] rs1_a, rs2_a, rd_a;
  logic ren_stall, can_go, lsq_disp_block;
  logic [NP-1:0][PRF_W-1:0] prs1, prs2, prd, prd_old;
  logic [NP-1:0] rs1_rdy, rs2_rdy;
  logic [CVA6Cfg.NrWbPorts-1:0][PRF_W-1:0] wb_prd;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][PRF_W-1:0] tid_prd_q, tid_prd_d;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][PRF_W-1:0] tid_old_q, tid_old_d;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] tid_is_st_q, tid_is_st_d;

  for (genvar p = 0; p < NP; p++) begin : gen_ports
    assign rs1_a[p] = dispatch_sbe_i[p].rs1[4:0];
    assign rs2_a[p] = dispatch_sbe_i[p].rs2[4:0];
    assign rd_a[p]  = dispatch_sbe_i[p].rd;
    assign need_rd[p] = dispatch_valid_i[p] && (rd_a[p] != 5'd0) &&
                        !(CVA6Cfg.FpPresent && is_rd_fpr(dispatch_sbe_i[p].op));
    assign is_br[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == CTRL_FLOW);
    assign is_ld[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == LOAD);
    assign is_st[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == STORE);
  end

  logic rob_full, iq_full, ld_full, st_full;
  logic older_st, stl_fwd, stl_stall, lsq_busy, md_stall, mem_stall;

  assign rob_full_o = rob_full;
  assign iq_full_o  = iq_full;
  // LSQ pressure only blocks when a mem op wants to dispatch
  assign lsq_disp_block = ((|is_ld) && ld_full) || ((|is_st) && st_full);
  assign can_go = !rob_full && !iq_full && !ren_stall && !flush_unissued_i && !lsq_disp_block;
  assign rename_stall_o = (|dispatch_valid_i) && !can_go;
  assign freelist_empty_o = ren_stall;
  assign stl_forward_o = stl_fwd;

  always_comb begin
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++)
      wb_prd[w] = tid_prd_q[wb_id_i[w]];
  end

  // Multi-port freelist free on all commit ports
  logic [CVA6Cfg.NrCommitPorts-1:0] free_en;
  logic [CVA6Cfg.NrCommitPorts-1:0][PRF_W-1:0] free_prd;
  always_comb begin
    for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
      free_en[c]  = commit_ack_i[c] && (commit_instr_i[c].rd != 5'd0) &&
                    (tid_old_q[commit_instr_i[c].trans_id] != '0);
      free_prd[c] = tid_old_q[commit_instr_i[c].trans_id];
    end
  end

  g6lc_rename #(
      .PRF_ENTRIES(PRF_N),
      .PRF_W      (PRF_W),
      .NR_PORTS   (NP),
      .NR_FREE    (CVA6Cfg.NrCommitPorts),
      .NR_WB      (CVA6Cfg.NrWbPorts),
      .CKPT_DEPTH (CKPT)
  ) i_rename (
      .clk_i,
      .rst_ni,
      .flush_i,
      .mispredict_i,
      .valid_i   (dispatch_valid_i & {NP{can_go}}),
      .rs1_i     (rs1_a),
      .rs2_i     (rs2_a),
      .rd_i      (rd_a),
      .need_rd_i (need_rd),
      .is_branch_i(is_br),
      .prs1_o    (prs1),
      .prs2_o    (prs2),
      .prd_o     (prd),
      .prd_old_o (prd_old),
      .rs1_ready_o(rs1_rdy),
      .rs2_ready_o(rs2_rdy),
      .stall_o   (ren_stall),
      .wb_valid_i(wb_valid_i),
      .wb_prd_i  (wb_prd),
      .free_i    (free_en),
      .free_prd_i(free_prd),
      .enable_i  (can_go)
  );

  scoreboard_entry_t [NP-1:0] tagged_sbe;
  always_comb begin
    tagged_sbe = dispatch_sbe_i;
    for (int unsigned p = 0; p < NP; p++) begin
      tagged_sbe[p].p_rs1 = 8'(prs1[p]);
      tagged_sbe[p].p_rs2 = 8'(prs2[p]);
      tagged_sbe[p].p_rd  = 8'(prd[p]);
      tagged_sbe[p].ooo_renamed = can_go && dispatch_valid_i[p];
    end
  end

  always_comb begin
    tid_prd_d = tid_prd_q;
    tid_old_d = tid_old_q;
    tid_is_st_d = tid_is_st_q;
    for (int unsigned p = 0; p < NP; p++) begin
      if (dispatch_ack_o[p]) begin
        tid_prd_d[dispatch_sbe_i[p].trans_id] = prd[p];
        tid_old_d[dispatch_sbe_i[p].trans_id] = prd_old[p];
        tid_is_st_d[dispatch_sbe_i[p].trans_id] = is_st[p];
      end
    end
    if (flush_i) begin
      tid_prd_d = '0;
      tid_old_d = '0;
      tid_is_st_d = '0;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tid_prd_q <= '0;
      tid_old_q <= '0;
      tid_is_st_q <= '0;
    end else begin
      tid_prd_q <= tid_prd_d;
      tid_old_q <= tid_old_d;
      tid_is_st_q <= tid_is_st_d;
    end
  end

  // ROB — multi-WB complete by scoreboard trans_id
  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rob_c_tid;
  always_comb begin
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) rob_c_tid[w] = wb_id_i[w];
  end

  logic [NP-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rob_alloc_tid;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) rob_alloc_tid[p] = dispatch_sbe_i[p].trans_id;
  end

  g6lc_rob #(
      .ROB_ENTRIES(ROB_N),
      .ROB_W      (ROB_W),
      .NR_ALLOC   (NP),
      .NR_RETIRE  (CVA6Cfg.NrCommitPorts),
      .NR_COMPLETE(CVA6Cfg.NrWbPorts),
      .TID_W      (CVA6Cfg.TRANS_ID_BITS),
      .NR_SB      (CVA6Cfg.NR_SB_ENTRIES),
      .entry_t    (scoreboard_entry_t)
  ) i_rob (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .alloc_valid_i (dispatch_ack_o),
      .alloc_entry_i (tagged_sbe),
      .alloc_tid_i   (rob_alloc_tid),
      .alloc_id_o    (),
      .full_o        (rob_full),
      .complete_valid_i(wb_valid_i),
      .complete_tid_i  (rob_c_tid),
      .complete_exc_i  (wb_exc_i),
      .retire_valid_o(),
      .retire_entry_o(),
      .retire_id_o   (),
      .retire_ack_i  (commit_ack_i)
  );

  // ---- PRF first (needed for live AGU) — issue selects feed PRF read ----
  // IQ + LSQ need issue_valid; PRF reads issue_sbe tags. Order: IQ, then PRF/AGU/LSQ.

  logic [NP-1:0][PRF_W-1:0] issue_prd;
  scoreboard_entry_t [NP-1:0] tagged_from_rename;
  assign tagged_from_rename = tagged_sbe;

  // LSQ + memdep (declared before IQ mem_stall)
  logic [NP-1:0]                 agu_valid;
  logic [NP-1:0][CVA6Cfg.PLEN-1:0] agu_addr;
  logic [NP-1:0]                 agu_is_st;
  logic [NP-1:0][1:0]            agu_size;
  logic [NP-1:0]                 st_data_v;
  logic [NP-1:0][CVA6Cfg.XLEN-1:0] st_data;
  logic [NP-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] agu_id;
  logic [NP-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] st_data_id;
  logic [CVA6Cfg.XLEN-1:0] stl_data;
  logic [CVA6Cfg.PLEN-1:0] ld_qaddr;
  logic [CVA6Cfg.NrWbPorts-1:0] complete_is_st;

  // IQ (mem_stall from LSQ/memdep below — combinational loop risk:
  // mem_stall uses issue_valid; IQ uses mem_stall. Break: mem_stall only from
  // LSQ state + memdep on issue candidate ports is OK if stl uses registered
  // LSQ and memdep table. issue_valid is comb from IQ; stl_stall uses ld_query
  // which is issue_valid. That forms IQ→mem_stall→IQ. Mitigate: mem_stall for
  // select uses only older_st/md from registered state + ld_full, NOT stl_stall
  // of current select. STL applied as post-select recheck / op forward only.

  // Prefer: stall mem issue when memdep predicts or older stores in flight.
  // Use registered older_st + md_stall only inside IQ to avoid combo loop
  // through issue_valid → stl_stall → mem_stall → issue_valid.
  assign mem_stall = md_stall || stl_stall;

  g6lc_iq #(
      .CVA6Cfg(CVA6Cfg),
      .DEPTH  (IQ_N),
      .PRF_W  (PRF_W),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_iq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .disp_valid_i    (dispatch_valid_i & {NP{can_go && !ren_stall}}),
      .disp_sbe_i      (tagged_from_rename),
      .disp_orig_i     (dispatch_orig_i),
      .disp_prs1_i     (prs1),
      .disp_prs2_i     (prs2),
      .disp_prd_i      (prd),
      .disp_rs1_ready_i(rs1_rdy),
      .disp_rs2_ready_i(rs2_rdy),
      .disp_ack_o      (dispatch_ack_o),
      .full_o          (iq_full),
      .wb_valid_i      (wb_valid_i),
      .wb_prd_i        (wb_prd),
      .issue_sbe_o     (issue_sbe_o),
      .issue_orig_o    (issue_orig_o),
      .issue_prd_o     (issue_prd),
      .issue_valid_o   (issue_valid_o),
      .issue_ack_i     (issue_ack_i),
      // Use md_stall || older_st for IQ select (no stl combo through issue_valid)
      .mem_stall_i     (md_stall || older_st)
  );

  // Block PRF writeback for cancelled SB slots (wrong-path after mispredict)
  logic [CVA6Cfg.NrWbPorts-1:0] wb_not_cancelled;
  always_comb begin
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++)
      wb_not_cancelled[w] = !cancelled_mask_i[wb_id_i[w]];
  end

  // PRF dual-read per issue port + multi-write WB with write-through
  logic [NP*2-1:0][PRF_W-1:0] prf_raddr;
  logic [NP*2-1:0][CVA6Cfg.XLEN-1:0] prf_rdata;
  logic [CVA6Cfg.NrWbPorts-1:0][PRF_W-1:0] prf_waddr;
  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0] prf_wdata;
  logic [CVA6Cfg.NrWbPorts-1:0] prf_we;

  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      prf_raddr[p*2+0] = issue_sbe_o[p].ooo_renamed ? PRF_W'(issue_sbe_o[p].p_rs1) : '0;
      prf_raddr[p*2+1] = issue_sbe_o[p].ooo_renamed ? PRF_W'(issue_sbe_o[p].p_rs2) : '0;
    end
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
      prf_waddr[w] = wb_prd[w];
      prf_wdata[w] = wb_data_i[w];
      prf_we[w]    = wb_valid_i[w] && !wb_exc_i[w] && (wb_prd[w] != '0) &&
                     wb_not_cancelled[w];
    end
  end

  g6lc_prf #(
      .DATA_WIDTH (CVA6Cfg.XLEN),
      .PRF_ENTRIES(PRF_N),
      .NR_READ    (NP * 2),
      .NR_WRITE   (CVA6Cfg.NrWbPorts),
      .PRF_W      (PRF_W)
  ) i_prf (
      .clk_i,
      .rst_ni,
      .raddr_i(prf_raddr),
      .rdata_o(prf_rdata),
      .waddr_i(prf_waddr),
      .wdata_i(prf_wdata),
      .we_i   (prf_we)
  );

  // Operand assemble + WB bypass + STL into load op A
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      automatic logic [CVA6Cfg.XLEN-1:0] a, b;
      a = prf_rdata[p*2+0];
      b = prf_rdata[p*2+1];
      for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
        if (wb_valid_i[w] && !wb_exc_i[w] && issue_sbe_o[p].ooo_renamed) begin
          if (wb_prd[w] == PRF_W'(issue_sbe_o[p].p_rs1) && wb_prd[w] != '0)
            a = wb_data_i[w];
          if (wb_prd[w] == PRF_W'(issue_sbe_o[p].p_rs2) && wb_prd[w] != '0)
            b = wb_data_i[w];
        end
      end
      if (p == 0 && stl_fwd && issue_sbe_o[0].fu == LOAD) a = stl_data;
      issue_op_a_o[p] = a;
      issue_op_b_o[p] = b;
      issue_op_a_valid_o[p] = issue_valid_o[p] && issue_sbe_o[p].ooo_renamed;
      issue_op_b_valid_o[p] = issue_valid_o[p] && issue_sbe_o[p].ooo_renamed;
    end
  end

  // Live AGU at issue: vaddr = imm + rs1 (matches load_store_unit AGU)
  always_comb begin
    agu_valid = '0;
    agu_addr  = '0;
    agu_is_st = '0;
    agu_size  = '0;
    agu_id    = '0;
    st_data_v = '0;
    st_data   = '0;
    st_data_id = '0;
    for (int unsigned p = 0; p < NP; p++) begin
      if (issue_valid_o[p] && issue_ack_i[p] && issue_sbe_o[p].ooo_renamed &&
          (issue_sbe_o[p].fu == LOAD || issue_sbe_o[p].fu == STORE)) begin
        automatic logic [CVA6Cfg.XLEN-1:0] vaddr_x;
        vaddr_x = $unsigned($signed(issue_sbe_o[p].result) + $signed(issue_op_a_o[p]));
        agu_valid[p] = 1'b1;
        agu_addr[p]  = CVA6Cfg.PLEN'(vaddr_x[CVA6Cfg.PLEN-1:0]);
        agu_is_st[p] = (issue_sbe_o[p].fu == STORE);
        agu_size[p]  = 2'b11; // full XLEN transfer; LSU still enforces exact size
        agu_id[p]    = issue_sbe_o[p].trans_id;
        if (issue_sbe_o[p].fu == STORE) begin
          st_data_v[p]  = 1'b1;
          st_data[p]    = issue_op_b_o[p];
          st_data_id[p] = issue_sbe_o[p].trans_id;
        end
      end
    end
  end

  // Load query address for CAM (port 0)
  always_comb begin
    ld_qaddr = '0;
    if (issue_valid_o[0] && issue_sbe_o[0].fu == LOAD && issue_sbe_o[0].ooo_renamed) begin
      automatic logic [CVA6Cfg.XLEN-1:0] v;
      v = $unsigned($signed(issue_sbe_o[0].result) + $signed(issue_op_a_o[0]));
      ld_qaddr = CVA6Cfg.PLEN'(v[CVA6Cfg.PLEN-1:0]);
    end
  end

  always_comb begin
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++)
      complete_is_st[w] = tid_is_st_q[wb_id_i[w]];
  end

  logic [NP-1:0] ld_alloc, st_alloc;
  logic [NP-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] alloc_ids;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      ld_alloc[p]  = dispatch_ack_o[p] && is_ld[p];
      st_alloc[p]  = dispatch_ack_o[p] && is_st[p];
      alloc_ids[p] = dispatch_sbe_i[p].trans_id;
    end
  end

  g6lc_lsq #(
      .CVA6Cfg   (CVA6Cfg),
      .LD_ENTRIES(LD_N),
      .ST_ENTRIES(ST_N),
      .NR_ALLOC  (NP),
      .NR_UPDATE (NP)
  ) i_lsq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .ld_alloc_i (ld_alloc),
      .st_alloc_i (st_alloc),
      .alloc_id_i (alloc_ids),
      .ld_full_o  (ld_full),
      .st_full_o  (st_full),
      .addr_valid_i(agu_valid),
      .addr_id_i   (agu_id),
      .addr_i      (agu_addr),
      .addr_is_st_i(agu_is_st),
      .addr_size_i (agu_size),
      .st_data_valid_i(st_data_v),
      .st_data_id_i   (st_data_id),
      .st_data_i      (st_data),
      .complete_valid_i(wb_valid_i),
      .complete_id_i   (wb_id_i),
      .complete_is_st_i(complete_is_st),
      .commit_st_i(commit_ack_i[0] && commit_instr_i[0].fu == STORE),
      .ld_query_i (issue_valid_o[0] && issue_sbe_o[0].fu == LOAD),
      .ld_query_addr_i(ld_qaddr),
      .ld_query_id_i  (issue_sbe_o[0].trans_id),
      .older_store_pending_o(older_st),
      .stl_forward_o(stl_fwd),
      .stl_data_o   (stl_data),
      .stl_stall_o  (stl_stall),
      .lsq_busy_o   (lsq_busy)
  );

  // Multi-port store train + observed-dependence train; clear on full flush or mispredict
  logic [NP-1:0] memdep_st_v;
  logic [NP-1:0][CVA6Cfg.VLEN-1:0] memdep_st_pc;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      memdep_st_v[p]  = dispatch_ack_o[p] && is_st[p];
      memdep_st_pc[p] = dispatch_sbe_i[p].pc;
    end
  end

  g6lc_memdep #(
      .CVA6Cfg (CVA6Cfg),
      .NR_SETS (64),
      .NR_TRAIN(NP)
  ) i_memdep (
      .clk_i,
      .rst_ni,
      .flush_i (flush_i | mispredict_i),
      .enable_i(CVA6Cfg.MemDepPredEn),
      .st_valid_i(memdep_st_v),
      .st_pc_i   (memdep_st_pc),
      .ld_query_i(issue_valid_o[0] && issue_sbe_o[0].fu == LOAD),
      .ld_pc_i   (issue_sbe_o[0].pc),
      .dep_observe_i(stl_stall || (older_st && issue_valid_o[0] && issue_sbe_o[0].fu == LOAD)),
      .older_store_pending_i(older_st),
      .stall_o   (md_stall),
      .predict_o ()
  );

  assign lsq_stall_o = mem_stall || lsq_disp_block;

endmodule
