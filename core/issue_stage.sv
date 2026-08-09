// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 21.05.2017
// Description: Issue stage dispatches instructions to the FUs and keeps track of them
//              in a scoreboard like data-structure.


module issue_stage
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type branchpredict_sbe_t = logic,
    parameter type exception_t = logic,
    parameter type fu_data_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type writeback_t = logic,
    parameter type x_issue_req_t = logic,
    parameter type x_issue_resp_t = logic,
    parameter type x_register_t = logic,
    parameter type x_commit_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Is scoreboard full - PERF_COUNTERS
    output logic sb_full_o,
    // FSE: SpeculativeSb younger cancel - PERF_COUNTERS
    output logic spec_cancel_o,
    // U5 production: SB cancel mask for OoO squash
    output logic [CVA6Cfg.NR_SB_ENTRIES-1:0] cancelled_mask_o,
    // Prevent from issuing - CONTROLLER
    input logic flush_unissued_instr_i,
    // Flush whole scoreboard - CONTROLLER
    input logic flush_i,
    // Stall inserted by Acc dispatcher - ACC_DISPATCHER
    input logic stall_i,
    // Handshake's data with decode stage - ID_STAGE
    input scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_i,
    input scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_i_prev,
    // instruction value - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    // Handshake's valid with decode stage - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_valid_i,
    // Is instruction a control flow instruction - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] is_ctrl_flow_i,
    // Handshake's acknowledge with decode stage - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_ack_o,
    // rs1 forwarding - EX_STAGE
    output [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] rs1_forwarding_o,
    // rs2 forwarding - EX_STAGE
    output [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] rs2_forwarding_o,
    // FU data useful to execute instruction - EX_STAGE
    output fu_data_t [CVA6Cfg.NrIssuePorts-1:0] fu_data_o,
    // ALU to ALU bypass control - EX_STAGE
    output alu_bypass_t alu_bypass_o,
    // Program Counter - EX_STAGE
    output logic [CVA6Cfg.VLEN-1:0] pc_o,
    // FSE S5: SMT hart of CTRL_FLOW instruction - EX_STAGE
    output logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] branch_hart_o,
    // Is zcmt instruction - EX_STAGE
    output logic is_zcmt_o,
    // Is compressed instruction - EX_STAGE
    output logic is_compressed_instr_o,
    // Transformed trap instruction - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0][31:0] tinst_o,
    // Fixed Latency Unit is ready - EX_STAGE
    input logic flu_ready_i,
    // ALU output is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] alu_valid_o,
    // AES output is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] aes_valid_o,
    // Branch unit is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] branch_valid_o,
    // Information of branch prediction - EX_STAGE
    output branchpredict_sbe_t branch_predict_o,
    // Signaling that we resolved the branch - EX_STAGE
    input logic resolve_branch_i,
    // Load store unit FU is ready - EX_STAGE
    input logic lsu_ready_i,
    // Load store unit FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] lsu_valid_o,
    // Mult FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] mult_valid_o,
    // FPU FU is ready - EX_STAGE
    input logic fpu_ready_i,
    // FPU FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fpu_valid_o,
    // FPU fmt field - EX_STAGE
    output logic [1:0] fpu_fmt_o,
    // FPU rm field - EX_STAGE
    output logic [2:0] fpu_rm_o,
    // FPU early valid - EX_STAGE
    input logic fpu_early_valid_i,
    // ALU2 FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] alu2_valid_o,
    // CSR is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] csr_valid_o,
    // CVXIF FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] xfu_valid_o,
    // CVXIF is FU ready - EX_STAGE
    input logic xfu_ready_i,
    // CVXIF offloader instruction value - EX_STAGE
    output logic [31:0] x_off_instr_o,
    // CVA6 Hart ID - SUBSYSTEM
    input logic [CVA6Cfg.XLEN-1:0] hart_id_i,
    // CVXIF Issue interface - EX_STAGE
    input logic x_issue_ready_i,
    // TO_BE_COMPLETED - EX_STAGE
    input x_issue_resp_t x_issue_resp_i,
    // TO_BE_COMPLETED - EX_STAGE
    output logic x_issue_valid_o,
    // TO_BE_COMPLETED - EX_STAGE
    output x_issue_req_t x_issue_req_o,
    // CVXIF Register interface - EX_STAGE
    input logic x_register_ready_i,
    // TO_BE_COMPLETED - EX_STAGE
    output logic x_register_valid_o,
    // TO_BE_COMPLETED - EX_STAGE
    output x_register_t x_register_o,
    // CVXIF Commit interface - EX_STAGE
    output logic x_commit_valid_o,
    // TO_BE_COMPLETED - EX_STAGE
    output x_commit_t x_commit_o,
    // CVXIF Transaction rejected -> instruction is illegal - EX_STAGE
    output logic x_transaction_rejected_o,
    // Issue scoreboard entry - ACC_DISPATCHER
    output scoreboard_entry_t issue_instr_o,
    // TO_BE_COMPLETED - ACC_DISPATCHER
    output logic issue_instr_hs_o,
    // Transaction ID - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_i,
    // Result from branch unit - EX_STAGE
    input bp_resolve_t resolved_branch_i,
    // Results to write back - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0] wbdata_i,
    // exception from execute stage or CVXIF - EX_STAGE
    input exception_t [CVA6Cfg.NrWbPorts-1:0] ex_ex_i,
    // Indicates valid results - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0] wt_valid_i,
    // CVXIF write enable - EX_STAGE
    input logic x_we_i,
    // CVXIF destination register - EX_STAGE
    input logic [4:0] x_rd_i,
    // Destination register in register file - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][4:0] waddr_i,
    // Value to write to register file - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.XLEN-1:0] wdata_i,
    // GPR write enable - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] we_gpr_i,
    // SMT hart tag for RF write banking - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] whart_i,
    // FPR write enable - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] we_fpr_i,
    // Instructions to commit - COMMIT_STAGE
    output scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0] commit_instr_o,
    // Instruction is cancelled - COMMIT_STAGE
    output logic [CVA6Cfg.NrCommitPorts-1:0] commit_drop_o,
    // Commit acknowledge - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack_i,
    // Issue stall - PERF_COUNTERS
    output logic stall_issue_o,
    // U5 OoO PMU probes (tied 0 when OoOEn=0)
    output logic ooo_rename_stall_o,
    output logic ooo_iq_full_o,
    output logic ooo_rob_full_o,
    output logic ooo_lsq_stall_o,
    output logic ooo_stl_forward_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_issue_pointer_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_commit_pointer_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] rvfi_rs1_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] rvfi_rs2_o,
    // Original instruction bits for AES
    output logic [5:0] orig_instr_aes_bits
);
  // ---------------------------------------------------
  // Scoreboard (SB) <-> Issue and Read Operands (IRO)
  // ---------------------------------------------------
  typedef logic [(CVA6Cfg.NrRgprPorts == 3 ? CVA6Cfg.XLEN : CVA6Cfg.FLen)-1:0] rs3_len_t;
  typedef struct packed {
    logic [CVA6Cfg.NR_SB_ENTRIES-1:0] still_issued;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] issue_pointer;
    writeback_t [CVA6Cfg.NrWbPorts-1:0] wb;
    scoreboard_entry_t [CVA6Cfg.NR_SB_ENTRIES-1:0] sbe;
  } forwarding_t;

  forwarding_t                                        fwd;
  // Scoreboard dispatch stream (program-order alloc)
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       issue_instr_sb;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_sb;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_instr_valid_sb;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_ack_sb;
  // FU issue stream into IRO (identity or U4-selected)
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       issue_instr_iro;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_iro;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_instr_valid_iro;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_ack_iro;

  assign issue_instr_o    = issue_instr_iro[0];
  assign issue_instr_hs_o = issue_instr_valid_iro[0] & issue_ack_iro[0];

  logic x_transaction_accepted_iro_sb, x_issue_writeback_iro_sb;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] x_id_iro_sb;

  // ---------------------------------------------------------
  // 2. Manage instructions in a scoreboard
  // ---------------------------------------------------------
  scoreboard #(
      .CVA6Cfg   (CVA6Cfg),
      .rs3_len_t (rs3_len_t),
      .bp_resolve_t(bp_resolve_t),
      .writeback_t(writeback_t),
      .forwarding_t(forwarding_t),
      .exception_t(exception_t),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_scoreboard (
      .clk_i,
      .rst_ni,
      .sb_full_o               (sb_full_o),
      .spec_cancel_o           (spec_cancel_o),
      .cancelled_mask_o        (cancelled_mask_o),
      .flush_unissued_instr_i,
      .flush_i,
      .x_transaction_accepted_i(x_transaction_accepted_iro_sb),
      .x_issue_writeback_i     (x_issue_writeback_iro_sb),
      .x_id_i                  (x_id_iro_sb),
      .commit_instr_o,
      .commit_drop_o,
      .commit_ack_i,
      .decoded_instr_i         (decoded_instr_i),
      .orig_instr_i,
      .decoded_instr_valid_i   (decoded_instr_valid_i),
      .decoded_instr_ack_o     (decoded_instr_ack_o),
      .issue_instr_o           (issue_instr_sb),
      .orig_instr_o            (orig_instr_sb),
      .issue_instr_valid_o     (issue_instr_valid_sb),
      .issue_ack_i             (issue_ack_sb),
      .fwd_o                   (fwd),
      .resolved_branch_i       (resolved_branch_i),
      .trans_id_i              (trans_id_i),
      .wbdata_i                (wbdata_i),
      .ex_i                    (ex_ex_i),
      .wt_valid_i,
      .x_we_i,
      .x_rd_i,
      .rvfi_issue_pointer_o,
      .rvfi_commit_pointer_o
  );

  // ---------------------------------------------------------
  // 2b. U4 slice-OoO / U5 full OoO dispatch (mutually exclusive)
  // ---------------------------------------------------------
  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] ooo_op_a, ooo_op_b;
  logic [CVA6Cfg.NrIssuePorts-1:0] ooo_op_a_v, ooo_op_b_v;

  if (CVA6Cfg.OoOEn) begin : gen_full_ooo
    logic [CVA6Cfg.NrWbPorts-1:0] wb_exc_bits;
    for (genvar wi = 0; wi < CVA6Cfg.NrWbPorts; wi++) begin : gen_wb_exc
      assign wb_exc_bits[wi] = ex_ex_i[wi].valid;
    end
    g6lc_ooo_dispatch #(
        .CVA6Cfg(CVA6Cfg),
        .scoreboard_entry_t(scoreboard_entry_t)
    ) i_ooo_dispatch (
        .clk_i,
        .rst_ni,
        .flush_i          (flush_i),
        .flush_unissued_i (flush_unissued_instr_i),
        .cancelled_mask_i (cancelled_mask_o),
        .dispatch_sbe_i   (issue_instr_sb),
        .dispatch_orig_i  (orig_instr_sb),
        .dispatch_valid_i (issue_instr_valid_sb),
        .dispatch_ack_o   (issue_ack_sb),
        .issue_sbe_o      (issue_instr_iro),
        .issue_orig_o     (orig_instr_iro),
        .issue_valid_o    (issue_instr_valid_iro),
        .issue_ack_i      (issue_ack_iro),
        .issue_op_a_o     (ooo_op_a),
        .issue_op_b_o     (ooo_op_b),
        .issue_op_a_valid_o(ooo_op_a_v),
        .issue_op_b_valid_o(ooo_op_b_v),
        .wb_valid_i       (wt_valid_i),
        .wb_id_i          (trans_id_i),
        .wb_data_i        (wbdata_i),
        .wb_exc_i         (wb_exc_bits),
        .commit_ack_i     (commit_ack_i),
        .commit_instr_i   (commit_instr_o),
        .mispredict_i     (resolved_branch_i.valid && resolved_branch_i.is_mispredict),
        .freelist_empty_o (),
        .rob_full_o       (ooo_rob_full_o),
        .iq_full_o        (ooo_iq_full_o),
        .lsq_stall_o      (ooo_lsq_stall_o),
        .rename_stall_o   (ooo_rename_stall_o),
        .stl_forward_o    (ooo_stl_forward_o)
    );
  end else if (CVA6Cfg.SliceOoOEn) begin : gen_slice_ooo
    assign ooo_op_a   = '0;
    assign ooo_op_b   = '0;
    assign ooo_op_a_v = '0;
    assign ooo_op_b_v = '0;
    assign ooo_rename_stall_o = 1'b0;
    assign ooo_iq_full_o      = 1'b0;
    assign ooo_rob_full_o     = 1'b0;
    assign ooo_lsq_stall_o    = 1'b0;
    assign ooo_stl_forward_o  = 1'b0;
    g6lc_slice_dispatch #(
        .CVA6Cfg(CVA6Cfg),
        .scoreboard_entry_t(scoreboard_entry_t)
    ) i_slice_dispatch (
        .clk_i,
        .rst_ni,
        .flush_i          (flush_i),
        .flush_unissued_i (flush_unissued_instr_i),
        .dispatch_sbe_i   (issue_instr_sb),
        .dispatch_orig_i  (orig_instr_sb),
        .dispatch_valid_i (issue_instr_valid_sb),
        .dispatch_ack_o   (issue_ack_sb),
        .issue_sbe_o      (issue_instr_iro),
        .issue_orig_o     (orig_instr_iro),
        .issue_valid_o    (issue_instr_valid_iro),
        .issue_ack_i      (issue_ack_iro),
        .wb_valid_i       (wt_valid_i),
        .wb_id_i          (trans_id_i)
    );
  end else begin : gen_inorder_issue
    // Netlist-identity path: SB dispatch is FU issue
    assign issue_instr_iro = issue_instr_sb;
    assign orig_instr_iro  = orig_instr_sb;
    assign issue_ack_sb    = issue_ack_iro;
    assign ooo_op_a   = '0;
    assign ooo_op_b   = '0;
    assign ooo_op_a_v = '0;
    assign ooo_op_b_v = '0;
    assign ooo_rename_stall_o = 1'b0;
    assign ooo_iq_full_o      = 1'b0;
    assign ooo_rob_full_o     = 1'b0;
    assign ooo_lsq_stall_o    = 1'b0;
    assign ooo_stl_forward_o  = 1'b0;

    // Hang-7 / hang-6 residual: do not issue past an unresolved CTRL_FLOW,
    // even when SpeculativeSb is forced on with SuperscalarEn (build_config_pkg).
    //
    // History: stall was gated on !SpeculativeSb so dual-issue (SpeculativeSb=1)
    // could issue fallthrough past RAS-miss Return / predicted Jump before
    // resolve — younger cancel recovered some paths but FDT walks still saw
    // pointer corruption (BADOFFSET / memchr-low). Classic Ariane stalls issue
    // until resolve; keep SpeculativeSb younger-cancel as a second line of
    // defense without re-opening the issue window early.
    //
    // Clear only on resolve or full SB flush — not flush_unissued alone (that
    // fires same cycle as resolve and would re-open too early).
    begin : gen_unresolved_cf_stall
      // Per-hart unresolved CF (R3a 2026-08-07):
      // - Arm when **any** issue port accepts CTRL_FLOW for that hart (port-0-only
      //   missed ALU||JAL on port 1 under dual-issue).
      // - Gate only instructions of the stalled hart so peer SMT harts keep
      //   issuing (global all-ports stall hung smt_dual_concurrent).
      // - Clear on same-hart resolve or full SB flush.
      // NrHarts==1 → single bit, identical netlist intent to classic stall.
      localparam int unsigned N_HARTS = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
      logic [N_HARTS-1:0] unresolved_cf_q, issue_cf_hart;
      logic [N_HARTS-1:0] resolve_cf_hart;

      // Detect CF accept from SB path (not gated iro) so the cycle that issues
      // CTRL_FLOW still sees valid_sb && ack before the stall latches.
      always_comb begin
        issue_cf_hart = '0;
        for (int unsigned pi = 0; pi < CVA6Cfg.NrIssuePorts; pi++) begin
          if (issue_instr_valid_sb[pi] && issue_ack_iro[pi] &&
              (issue_instr_sb[pi].fu == CTRL_FLOW)) begin
            // hart_id width is HART_ID_BITS (1 when NrHarts==1)
            if (!unresolved_cf_q[issue_instr_sb[pi].hart_id]) begin
              issue_cf_hart[issue_instr_sb[pi].hart_id] = 1'b1;
            end
          end
        end
      end

      always_comb begin
        resolve_cf_hart = '0;
        // resolve_branch_i is the in-order resolve pulse; hart from EX resolve bus
        if (resolve_branch_i) begin
          resolve_cf_hart[resolved_branch_i.hart_id] = 1'b1;
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          unresolved_cf_q <= '0;
        end else if (flush_i) begin
          unresolved_cf_q <= '0;
        end else begin
          for (int unsigned h = 0; h < N_HARTS; h++) begin
            // resolve wins same-cycle over re-arm (matches prior else-if order)
            if (resolve_cf_hart[h]) begin
              unresolved_cf_q[h] <= 1'b0;
            end else if (issue_cf_hart[h]) begin
              unresolved_cf_q[h] <= 1'b1;
            end
          end
        end
      end

      // Soft-ladder B1 (b1-csr-expected-trap / cont.33): after a CSR issues for
      // a hart, do not issue anything younger on that hart until the CSR leaves
      // the scoreboard (commit_ack or flush). OpenSBI expected-trap is:
      //   csrrw mtvec, handler;  <probe CSR>;  csrw mtvec, old
      // If younger ops (or the restore) race the illegal probe, mtvec is already
      // restored when the trap is taken and __sbi_expected_trap never runs.
      // csr_buffer already single-entries CSR FU, but non-CSR / timing under DI
      // still allowed younger issue; this mirrors unresolved_cf for CSR.
      logic [N_HARTS-1:0] unresolved_csr_q, issue_csr_hart, commit_csr_hart;

      always_comb begin
        issue_csr_hart = '0;
        for (int unsigned pi = 0; pi < CVA6Cfg.NrIssuePorts; pi++) begin
          if (issue_instr_valid_sb[pi] && issue_ack_iro[pi] &&
              (issue_instr_sb[pi].fu == CSR)) begin
            if (!unresolved_csr_q[issue_instr_sb[pi].hart_id]) begin
              issue_csr_hart[issue_instr_sb[pi].hart_id] = 1'b1;
            end
          end
        end
      end

      always_comb begin
        commit_csr_hart = '0;
        for (int unsigned ci = 0; ci < CVA6Cfg.NrCommitPorts; ci++) begin
          if (commit_ack_i[ci] && (commit_instr_o[ci].fu == CSR)) begin
            commit_csr_hart[commit_instr_o[ci].hart_id] = 1'b1;
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
            // Commit/flush wins over re-arm (same as CF).
            if (commit_csr_hart[h]) begin
              unresolved_csr_q[h] <= 1'b0;
            end else if (issue_csr_hart[h]) begin
              unresolved_csr_q[h] <= 1'b1;
            end
          end
        end
      end

      for (genvar p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin : gen_gate
        assign issue_instr_valid_iro[p] =
            issue_instr_valid_sb[p]
            && !unresolved_cf_q[issue_instr_sb[p].hart_id]
            && !unresolved_csr_q[issue_instr_sb[p].hart_id];
      end
    end
  end

  // ---------------------------------------------------------
  // 3. Issue instruction and read operand, also commit
  // ---------------------------------------------------------
  issue_read_operands #(
      .CVA6Cfg(CVA6Cfg),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .fu_data_t(fu_data_t),
      .scoreboard_entry_t(scoreboard_entry_t),
      .rs3_len_t(rs3_len_t),
      .writeback_t(writeback_t),
      .forwarding_t(forwarding_t),
      .x_issue_req_t(x_issue_req_t),
      .x_issue_resp_t(x_issue_resp_t),
      .x_register_t(x_register_t),
      .x_commit_t(x_commit_t)
  ) i_issue_read_operands (
      .clk_i,
      .rst_ni,
      .flush_i                 (flush_unissued_instr_i),
      .stall_i,
      .issue_instr_i           (issue_instr_iro),
      .issue_instr_i_prev      (decoded_instr_i_prev),
      .orig_instr_i            (orig_instr_iro),
      .issue_instr_valid_i     (issue_instr_valid_iro),
      .issue_ack_o             (issue_ack_iro),
      .fwd_i                   (fwd),
      .ooo_op_a_i              (ooo_op_a),
      .ooo_op_b_i              (ooo_op_b),
      .ooo_op_a_valid_i        (ooo_op_a_v),
      .ooo_op_b_valid_i        (ooo_op_b_v),
      .fu_data_o               (fu_data_o),
      .alu_bypass_o            (alu_bypass_o),
      .rs1_forwarding_o        (rs1_forwarding_o),
      .rs2_forwarding_o        (rs2_forwarding_o),
      .pc_o,
      .branch_hart_o,
      .is_zcmt_o,
      .is_compressed_instr_o,
      .flu_ready_i             (flu_ready_i),
      .alu_valid_o             (alu_valid_o),
      .aes_valid_o             (aes_valid_o),
      .branch_valid_o          (branch_valid_o),
      .tinst_o                 (tinst_o),
      .branch_predict_o,
      .lsu_ready_i,
      .lsu_valid_o,
      .mult_valid_o,
      .fpu_ready_i,
      .fpu_valid_o,
      .fpu_fmt_o,
      .fpu_rm_o,
      .fpu_early_valid_i,
      .alu2_valid_o,
      .csr_valid_o,
      .cvxif_valid_o           (xfu_valid_o),
      .cvxif_ready_i           (xfu_ready_i),
      .cvxif_off_instr_o       (x_off_instr_o),
      .hart_id_i               (hart_id_i),
      .x_issue_ready_i         (x_issue_ready_i),
      .x_issue_resp_i          (x_issue_resp_i),
      .x_issue_valid_o         (x_issue_valid_o),
      .x_issue_req_o           (x_issue_req_o),
      .x_register_ready_i      (x_register_ready_i),
      .x_register_valid_o      (x_register_valid_o),
      .x_register_o            (x_register_o),
      .x_commit_valid_o        (x_commit_valid_o),
      .x_commit_o              (x_commit_o),
      .x_transaction_accepted_o(x_transaction_accepted_iro_sb),
      .x_transaction_rejected_o(x_transaction_rejected_o),
      .x_issue_writeback_o     (x_issue_writeback_iro_sb),
      .x_id_o                  (x_id_iro_sb),
      .waddr_i,
      .wdata_i,
      .we_gpr_i,
      .whart_i,
      .we_fpr_i,
      .stall_issue_o,
      .rvfi_rs1_o              (rvfi_rs1_o),
      .rvfi_rs2_o              (rvfi_rs2_o),
      .orig_instr_aes_bits     (orig_instr_aes_bits)
  );

endmodule
