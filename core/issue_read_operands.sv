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
// Modified by: Etienne Cimon
// Date: 08.04.2017
// Description: Issues instruction from the scoreboard and fetches the operands
//              This also includes all the forwarding logic


module issue_read_operands
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type branchpredict_sbe_t = logic,
    parameter type fu_data_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type forwarding_t = logic,
    parameter type writeback_t = logic,
    parameter type rs3_len_t = logic,
    parameter type x_issue_req_t = logic,
    parameter type x_issue_resp_t = logic,
    parameter type x_register_t = logic,
    parameter type x_commit_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Prevent from issuing - CONTROLLER
    input logic flush_i,
    // Stall inserted by Acc dispatcher - ACC_DISPATCHER
    input logic stall_i,
    // Entry about the instruction to issue - SCOREBOARD
    input scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_instr_i,
    input scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_instr_i_prev,
    // Instruction to issue - SCOREBOARD
    input logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    // Is there an instruction to issue - SCOREBOARD
    input logic [CVA6Cfg.NrIssuePorts-1:0] issue_instr_valid_i,
    // Issue stage acknowledge - SCOREBOARD
    output logic [CVA6Cfg.NrIssuePorts-1:0] issue_ack_o,
    // Forwarding - SCOREBOARD
    input forwarding_t fwd_i,
    // U5 OoO PRF operands (valid when OoOEn && issue_instr.ooo_renamed)
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] ooo_op_a_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] ooo_op_b_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0]                   ooo_op_a_valid_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0]                   ooo_op_b_valid_i,
    // FU data useful to execute instruction - EX_STAGE
    output fu_data_t [CVA6Cfg.NrIssuePorts-1:0] fu_data_o,
    // ALU to ALU bypass control - EX_STAGE
    output alu_bypass_t alu_bypass_o,
    // Unregistered version of fu_data_o.operanda - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] rs1_forwarding_o,
    // Unregistered version of fu_data_o.operandb - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] rs2_forwarding_o,
    // Program Counter - EX_STAGE
    output logic [CVA6Cfg.VLEN-1:0] pc_o,
    // FSE S5: SMT hart of the CTRL_FLOW instruction forwarded to EX
    output logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] branch_hart_o,
    // Is zcmt - EX_STAGE
    output logic is_zcmt_o,
    // Is compressed instruction - EX_STAGE
    output logic is_compressed_instr_o,
    // Fixed Latency Unit is ready - EX_STAGE
    input logic flu_ready_i,
    // ALU output is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] alu_valid_o,
    // AES output is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] aes_valid_o,
    // Branch unit is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] branch_valid_o,
    // Transformed trap instruction - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0][31:0] tinst_o,
    // Information of branch prediction - EX_STAGE
    output branchpredict_sbe_t branch_predict_o,
    // Load store unit FU is ready - EX_STAGE
    input logic lsu_ready_i,
    // Load store unit FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] lsu_valid_o,
    // Mult FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] mult_valid_o,
    // FPU FU is ready - EX_STAGE
    input logic fpu_ready_i,
    // FPU FU will perform a writeback in the next cycle - EX_STAGE
    input logic fpu_early_valid_i,
    // FPU FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fpu_valid_o,
    // FPU fmt field - EX_STAGE
    output logic [1:0] fpu_fmt_o,
    // FPU rm field - EX_STAGE
    output logic [2:0] fpu_rm_o,
    // ALU2 FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] alu2_valid_o,
    // CSR is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] csr_valid_o,
    // CVXIF FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] cvxif_valid_o,
    // CVXIF is FU ready - EX_STAGE
    input logic cvxif_ready_i,
    // CVXIF offloader instruction value - EX_STAGE
    output logic [31:0] cvxif_off_instr_o,
    // CVA6 Hart ID - SUBSYSTEM
    input logic [CVA6Cfg.XLEN-1:0] hart_id_i,
    // CVXIF Issue interface
    input logic x_issue_ready_i,
    input x_issue_resp_t x_issue_resp_i,
    output logic x_issue_valid_o,
    output x_issue_req_t x_issue_req_o,
    // CVXIF Register interface
    input logic x_register_ready_i,
    output logic x_register_valid_o,
    output x_register_t x_register_o,
    // CVXIF Commit interface
    output logic x_commit_valid_o,
    output x_commit_t x_commit_o,
    // Writeback Handling of CVXIF
    output logic x_transaction_accepted_o,
    output logic x_transaction_rejected_o,
    output logic x_issue_writeback_o,
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0] x_id_o,
    // Destination register in the register file - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][4:0] waddr_i,
    // Value to write to register file - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.XLEN-1:0] wdata_i,
    // GPR write enable - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] we_gpr_i,
    // SMT hart tag for RF write banking - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] whart_i,
    // FPR write enable - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] we_fpr_i,
    // Issue stall - PERF_COUNTERS
    output logic stall_issue_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] rvfi_rs1_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] rvfi_rs2_o,
    // Original instruction bits for AES
    output logic [5:0] orig_instr_aes_bits,
    // G1gq: extra RF peek of commit JALR rs1
    input logic [4:0] g1gq_raddr_i,
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] g1gq_rhart_i,
    output logic [CVA6Cfg.XLEN-1:0] g1gq_rdata_o
);

  localparam OPERANDS_PER_INSTR = CVA6Cfg.NrRgprPorts / CVA6Cfg.NrIssuePorts;

  typedef struct packed {
    logic none, load, store, alu, alu2, ctrl_flow, mult, csr, fpu, fpu_vec, cvxif, accel, aes;
  } fus_busy_t;

  logic [CVA6Cfg.NrIssuePorts-1:0] stall_raw, stall_rs1, stall_rs2, stall_rs3;
  logic [CVA6Cfg.NrIssuePorts-1:0] fu_busy;  // functional unit is busy
  fus_busy_t [CVA6Cfg.NrIssuePorts-1:0] fus_busy;  // which functional units are considered busy
  logic [CVA6Cfg.NrIssuePorts-1:0] issue_ack;
  // operands coming from regfile
  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] operand_a_regfile, operand_b_regfile;
  // third operand from fp regfile or gp regfile if NR_RGPR_PORTS == 3
  rs3_len_t [CVA6Cfg.NrIssuePorts-1:0] operand_c_regfile, operand_c_gpr;
  rs3_len_t operand_c_fpr;
  // output flipflop (ID <-> EX)
  fu_data_t [CVA6Cfg.NrIssuePorts-1:0] fu_data_n, fu_data_q;
  logic               [        CVA6Cfg.VLEN-1:0]                   pc_n;
  logic               [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] branch_hart_n;
  logic                                                            is_compressed_instr_n;
  branchpredict_sbe_t                                              branch_predict_n;
  logic               [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] imm_forward_rs3;

  logic [CVA6Cfg.NrIssuePorts-1:0] alu_valid_n, alu_valid_q;
  logic [CVA6Cfg.NrIssuePorts-1:0] aes_valid_n, aes_valid_q;
  logic [CVA6Cfg.NrIssuePorts-1:0] mult_valid_n, mult_valid_q;
  logic [CVA6Cfg.NrIssuePorts-1:0] fpu_valid_n, fpu_valid_q;
  logic [1:0] fpu_fmt_n, fpu_fmt_q;
  logic [2:0] fpu_rm_n, fpu_rm_q;
  logic [CVA6Cfg.NrIssuePorts-1:0] alu2_valid_n, alu2_valid_q;
  logic [CVA6Cfg.NrIssuePorts-1:0] lsu_valid_n, lsu_valid_q;
  logic [CVA6Cfg.NrIssuePorts-1:0] csr_valid_n, csr_valid_q;
  logic [CVA6Cfg.NrIssuePorts-1:0] branch_valid_n, branch_valid_q;
  logic [CVA6Cfg.NrIssuePorts-1:0] cvxif_valid_n, cvxif_valid_q;
  logic [31:0] cvxif_off_instr_n, cvxif_off_instr_q;
  logic                                                            cvxif_instruction_valid;

  //RAW detection
  logic [ CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.TRANS_ID_BITS-1:0] idx_hzd_rs1;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs1_raw_check;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs1_has_raw;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs1_fpr;

  logic [ CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.TRANS_ID_BITS-1:0] idx_hzd_rs2;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs2_raw_check;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs2_has_raw;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs2_fpr;

  logic [ CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.TRANS_ID_BITS-1:0] idx_hzd_rs3;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs3_raw_check;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs3_has_raw;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs3_fpr;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs3_gpr_cvxif;


  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][ariane_pkg::REG_ADDR_SIZE-1:0] rd_list;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]                                rd_fpr;

  //fwd logic
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][             CVA6Cfg.XLEN-1:0] fwd_res;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]                                fwd_res_valid;

  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]                                rs1_is_not_csr;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]                                rs2_is_not_csr;

  logic [ CVA6Cfg.NrIssuePorts-1:0][             CVA6Cfg.XLEN-1:0] rs3;

  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs1_valid;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs2_valid;
  logic [ CVA6Cfg.NrIssuePorts-1:0]                                rs3_valid;

  logic [ CVA6Cfg.NrIssuePorts-1:0][             CVA6Cfg.XLEN-1:0] rs1_res;
  logic [ CVA6Cfg.NrIssuePorts-1:0][             CVA6Cfg.XLEN-1:0] rs2_res;
  logic [ CVA6Cfg.NrIssuePorts-1:0][             CVA6Cfg.XLEN-1:0] rs3_res;

  logic [CVA6Cfg.NrIssuePorts-1:0][31:0] tinst_n, tinst_q;  // transformed instruction

  // forwarding signals
  logic [CVA6Cfg.NrIssuePorts-1:0] forward_rs1, forward_rs2, forward_rs3;

  // original instruction
  riscv::instruction_t [CVA6Cfg.NrIssuePorts-1:0] orig_instr;
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assign orig_instr[i] = riscv::instruction_t'(orig_instr_i[i]);
  end

  // ALU-ALU bypass signals
  alu_bypass_t alu_bypass, alu_bypass_n, alu_bypass_q;
  logic is_alu_bypass;
  logic [CVA6Cfg.NrIssuePorts-1:0] use_alu2;

  // CVXIF Signals
  logic cvxif_req_allowed;
  logic x_transaction_rejected, x_transaction_rejected_n;
  logic [OPERANDS_PER_INSTR-1:0] rs_valid;
  logic [OPERANDS_PER_INSTR-1:0][CVA6Cfg.XLEN-1:0] rs;

  cvxif_issue_register_commit_if_driver #(
      .CVA6Cfg       (CVA6Cfg),
      .x_issue_req_t (x_issue_req_t),
      .x_issue_resp_t(x_issue_resp_t),
      .x_register_t  (x_register_t),
      .x_commit_t    (x_commit_t)
  ) i_cvxif_issue_register_commit_if_driver (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .flush_i         (flush_i),
      .hart_id_i       (hart_id_i),
      .issue_ready_i   (x_issue_ready_i),
      .issue_resp_i    (x_issue_resp_i),
      .issue_valid_o   (x_issue_valid_o),
      .issue_req_o     (x_issue_req_o),
      .register_ready_i(x_register_ready_i),
      .register_valid_o(x_register_valid_o),
      .register_o      (x_register_o),
      .commit_valid_o  (x_commit_valid_o),
      .commit_o        (x_commit_o),
      .valid_i         (cvxif_instruction_valid),
      .x_off_instr_i   (orig_instr_i[0]),
      .x_trans_id_i    (issue_instr_i[0].trans_id),
      .register_i      (rs),
      .rs_valid_i      (rs_valid)
  );
  if (OPERANDS_PER_INSTR == 3) begin
    assign rs_valid = {~stall_rs3[0], ~stall_rs2[0], ~stall_rs1[0]};
    assign rs = {fu_data_n[0].imm, fu_data_n[0].operand_b, fu_data_n[0].operand_a};
  end else begin
    assign rs_valid = {~stall_rs2[0], ~stall_rs1[0]};
    assign rs = {fu_data_n[0].operand_b, fu_data_n[0].operand_a};
  end

  // TODO check only for 1st instruction ??
  // Allow a cvxif transaction if we WaW condition are ok.
  assign cvxif_req_allowed = (issue_instr_i[0].fu == CVXIF);
  assign cvxif_instruction_valid = !issue_instr_i[0].ex.valid && issue_instr_valid_i[0] && cvxif_req_allowed;
  assign x_transaction_accepted_o = x_issue_valid_o && x_issue_ready_i && x_issue_resp_i.accept;
  assign x_transaction_rejected = x_issue_valid_o && x_issue_ready_i && ~x_issue_resp_i.accept;
  assign x_issue_writeback_o = x_issue_resp_i.writeback;
  assign x_id_o = x_issue_req_o.id;

  // ID <-> EX registers

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assign rs1_forwarding_o[i] = fu_data_n[i].operand_a[CVA6Cfg.VLEN-1:0];  //forwarding or unregistered rs1 value
    assign rs2_forwarding_o[i] = fu_data_n[i].operand_b[CVA6Cfg.VLEN-1:0];  //forwarding or unregistered rs2 value
    assign rvfi_rs1_o[i] = fu_data_n[i].operand_a;
    assign rvfi_rs2_o[i] = fu_data_n[i].operand_b;
  end

  assign alu_bypass_o = alu_bypass_q;
  assign fu_data_o = fu_data_q;
  assign alu_valid_o = alu_valid_q;
  assign aes_valid_o = aes_valid_q;
  assign branch_valid_o = branch_valid_q;
  assign lsu_valid_o = lsu_valid_q;
  assign csr_valid_o = csr_valid_q;
  assign mult_valid_o = mult_valid_q;
  assign fpu_valid_o = fpu_valid_q;
  assign fpu_fmt_o = fpu_fmt_q;
  assign fpu_rm_o = fpu_rm_q;
  assign alu2_valid_o = alu2_valid_q;
  assign cvxif_valid_o = CVA6Cfg.CvxifEn ? cvxif_valid_q : '0;
  assign cvxif_off_instr_o = CVA6Cfg.CvxifEn ? cvxif_off_instr_q : '0;
  assign stall_issue_o = stall_raw[0];
  assign tinst_o = CVA6Cfg.RVH ? tinst_q : '0;

  // ALU bypass signals (port0→port1 only; requires at least dual-issue)
  if (CVA6Cfg.ALUBypass && CVA6Cfg.NrIssuePorts > 1) begin
    assign is_alu_bypass =
      (issue_instr_i[0].fu == ALU && issue_instr_i[1].fu == ALU) &&
      !((issue_instr_i[0].op inside {CPOP, CPOPW}) || (issue_instr_i[1].op inside {CPOP, CPOPW}));
  end else begin
    assign is_alu_bypass = 1'b0;
  end

  if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrALUs >= 2 && CVA6Cfg.NrIssuePorts > 1) begin
    // Prefer secondary ALU unless bypass / FPU on port 1 forces primary.
    for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      assign use_alu2[i] = is_alu_bypass || (issue_instr_i[1].fu inside {FPU, FPU_VEC})
                               ? fus_busy[i].alu : !fus_busy[i].alu2;
    end
  end else begin
    assign use_alu2 = '0;
  end

  // ---------------
  // Issue Stage
  // ---------------

  always_comb begin : structural_hazards
    fus_busy = '0;
    // CVXIF is always ready to try a new transaction on 1st issue port
    // If a transaction is already pending then we stall until the transaction is done.(issue_ack_o[0] = 0)
    // Since we can not have two CVXIF instruction on 1st issue port, CVXIF is always ready for the pending instruction.
    if (!flu_ready_i) begin
      fus_busy[0].alu = 1'b1;
      fus_busy[0].aes = 1'b1;
      fus_busy[0].ctrl_flow = 1'b1;
      fus_busy[0].csr = 1'b1;
      fus_busy[0].mult = 1'b1;
    end

    // after a multiplication was issued we can only issue another multiplication
    // otherwise we will get contentions on the fixed latency bus
    if (|mult_valid_q) begin
      fus_busy[0].alu = 1'b1;
      fus_busy[0].aes = 1'b1;
      fus_busy[0].ctrl_flow = 1'b1;
      fus_busy[0].csr = 1'b1;
    end

    if (CVA6Cfg.FpPresent && !fpu_ready_i) begin
      fus_busy[0].fpu = 1'b1;
      fus_busy[0].fpu_vec = 1'b1;
    end

    if (!lsu_ready_i) begin
      fus_busy[0].load  = 1'b1;
      fus_busy[0].store = 1'b1;
    end

    if (CVA6Cfg.SuperscalarEn) begin
      if (fpu_early_valid_i) begin
        fus_busy[0].alu2 = 1'b1;
      end

      // Propagate structural hazards port-by-port (in-order multi-issue).
      //
      // Soft-ladder / monorepo-soak integration (R3a cont.6/14/15/18, hang-6/7):
      // Under SuperscalarEn, after CTRL_FLOW / ALU / MULT / FPU / LOAD / STORE
      // block *all* younger ports. This is intentional dual-issue throttle for
      // OpenSBI FDT / callee-saved correctness until precise WAW dual-WB is
      // proven. CSR/CVXIF remain port-0 only. See architecture/multi-threading/
      // soft-ladder/monorepo-soak-integration.md and inventory b1-fdt-lenp-store.
      for (int unsigned p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin
        fus_busy[p] = fus_busy[p-1];

        // CSR / CVXIF only on port 0
        fus_busy[p].csr   = 1'b1;
        fus_busy[p].cvxif = 1'b1;

        unique case (issue_instr_i[p-1].fu)
          NONE: fus_busy[p].none = 1'b1;
          CTRL_FLOW: begin
            // Full post-CF serialize under SS (jal/ret RA poison under partial).
            if (CVA6Cfg.SuperscalarEn) begin
              fus_busy[p] = '1;
            end else if (issue_instr_i[p-1].op == ariane_pkg::ADD) begin
              fus_busy[p].alu = 1'b1;
              fus_busy[p].ctrl_flow = 1'b1;
              fus_busy[p].csr = 1'b1;
            end else begin
              fus_busy[p] = '1;
            end
          end
          ALU: begin
            // One ALU issue/cycle under SS until dual-WB clean on OpenSBI.
            if (CVA6Cfg.SuperscalarEn) begin
              fus_busy[p] = '1;
            end else if (use_alu2[p-1] && CVA6Cfg.NrALUs >= 2) begin
              fus_busy[p].alu2 = 1'b1;
            end else begin
              fus_busy[p].alu = 1'b1;
              fus_busy[p].ctrl_flow = 1'b1;
              fus_busy[p].csr = 1'b1;
            end
          end
          CSR: fus_busy[p] = '1;
          MULT: begin
            fus_busy[p].mult = 1'b1;
            if (CVA6Cfg.SuperscalarEn) fus_busy[p] = '1;
          end
          FPU, FPU_VEC: begin
            fus_busy[p].fpu = 1'b1;
            fus_busy[p].fpu_vec = 1'b1;
            if (issue_instr_i[p].op inside {[FLD : FSB]}) begin
              fus_busy[p].load  = 1'b1;
              fus_busy[p].store = 1'b1;
            end
            if (CVA6Cfg.SuperscalarEn) fus_busy[p] = '1;
          end
          LOAD, STORE: begin
            // Includes AMO (STORE FU). Full LSU serialize under SS.
            fus_busy[p].load  = 1'b1;
            fus_busy[p].store = 1'b1;
            if (issue_instr_i[p-1].op inside {[FLD : FSB]}) begin
              fus_busy[p].fpu = 1'b1;
              fus_busy[p].fpu_vec = 1'b1;
            end
            if (CVA6Cfg.SuperscalarEn) begin
              fus_busy[p] = '1;
            end
          end
          CVXIF: ;
          default: ;
        endcase
      end
    end
  end

  // select the right busy signal
  // this obviously depends on the functional unit we need
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    always_comb begin
      unique case (issue_instr_i[i].fu)
        NONE: fu_busy[i] = fus_busy[i].none;
        ALU: begin
          if (CVA6Cfg.SuperscalarEn && use_alu2[i]) begin
            fu_busy[i] = fus_busy[i].alu2;
          end else begin
            fu_busy[i] = fus_busy[i].alu;
          end
        end
        CTRL_FLOW: fu_busy[i] = fus_busy[i].ctrl_flow;
        CSR: fu_busy[i] = fus_busy[i].csr;
        MULT: fu_busy[i] = fus_busy[i].mult;
        LOAD: fu_busy[i] = fus_busy[i].load;
        STORE: fu_busy[i] = fus_busy[i].store;
        CVXIF: fu_busy[i] = fus_busy[i].cvxif;
        AES: fu_busy[i] = fus_busy[i].aes;
        default:
        if (CVA6Cfg.FpPresent) begin
          unique case (issue_instr_i[i].fu)
            FPU: fu_busy[i] = fus_busy[i].fpu;
            FPU_VEC: fu_busy[i] = fus_busy[i].fpu_vec;
            default: fu_busy[i] = 1'b0;
          endcase
        end else begin
          fu_busy[i] = 1'b0;
        end
      endcase
    end
  end

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assign rs1_fpr[i] = (CVA6Cfg.FpPresent && ariane_pkg::is_rs1_fpr(issue_instr_i[i].op));
    assign rs2_fpr[i] = (CVA6Cfg.FpPresent && ariane_pkg::is_rs2_fpr(issue_instr_i[i].op));
    assign rs3_fpr[i] = (CVA6Cfg.FpPresent && ariane_pkg::is_imm_fpr(issue_instr_i[i].op));
    // Third GPR source: CVXIF offload or Zacas AMOCAS (rd = expected)
    assign rs3_gpr_cvxif[i] = (OPERANDS_PER_INSTR == 3) && (
        (CVA6Cfg.CvxifEn && issue_instr_i[i].op == OFFLOAD) ||
        (CVA6Cfg.RVZacas && ariane_pkg::is_amo_cas(issue_instr_i[i].op))
    );
  end

  // ----------------------------------
  // Renaming
  // ----------------------------------
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] rd_hart;
  for (genvar i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
    assign rd_list[i] = fwd_i.sbe[i].rd;
    assign rd_fpr[i]  = CVA6Cfg.FpPresent && ariane_pkg::is_rd_fpr(fwd_i.sbe[i].op);
    assign rd_hart[i] = fwd_i.sbe[i].hart_id;
  end

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : gen_raw_checks
    raw_checker #(
        .CVA6Cfg(CVA6Cfg)
    ) i_rs1_last_raw (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .rs_i(issue_instr_i[i].rs1),
        .rs_fpr_i(rs1_fpr[i]),
        .rd_i(rd_list),
        .rd_fpr_i(rd_fpr),
        .still_issued_i(fwd_i.still_issued),
        .issue_pointer_i(fwd_i.issue_pointer),
        .rs_hart_i(issue_instr_i[i].hart_id),
        .rd_hart_i(rd_hart),
        .idx_o(idx_hzd_rs1[i]),
        .valid_o(rs1_raw_check[i])
    );
    assign rs1_has_raw[i] = rs1_raw_check[i] && !issue_instr_i[i].use_zimm;

    raw_checker #(
        .CVA6Cfg(CVA6Cfg)
    ) i_rs2_last_raw (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .rs_i(issue_instr_i[i].rs2),
        .rs_fpr_i(rs2_fpr[i]),
        .rd_i(rd_list),
        .rd_fpr_i(rd_fpr),
        .still_issued_i(fwd_i.still_issued),
        .issue_pointer_i(fwd_i.issue_pointer),
        .rs_hart_i(issue_instr_i[i].hart_id),
        .rd_hart_i(rd_hart),
        .idx_o(idx_hzd_rs2[i]),
        .valid_o(rs2_raw_check[i])
    );
    assign rs2_has_raw[i] = rs2_raw_check[i];

    raw_checker #(
        .CVA6Cfg(CVA6Cfg)
    ) i_rs3_last_raw (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .rs_i(issue_instr_i[i].result[ariane_pkg::REG_ADDR_SIZE-1:0]),
        .rs_fpr_i(rs3_fpr[i]),
        .rd_i(rd_list),
        .rd_fpr_i(rd_fpr),
        .still_issued_i(fwd_i.still_issued),
        .issue_pointer_i(fwd_i.issue_pointer),
        .rs_hart_i(issue_instr_i[i].hart_id),
        .rd_hart_i(rd_hart),
        .idx_o(idx_hzd_rs3[i]),
        .valid_o(rs3_raw_check[i])
    );
    assign rs3_has_raw[i] = rs3_raw_check[i] && (rs3_fpr[i] || rs3_gpr_cvxif[i]);
  end

  // ----------------------------------
  // Read Operands (a.k.a forwarding)
  // ----------------------------------
  always_comb begin
    for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
      fwd_res[i] = fwd_i.sbe[i].result;
      fwd_res_valid[i] = fwd_i.sbe[i].valid & (~fwd_i.sbe[i].ex.valid);
    end
    for (int unsigned i = 0; i < CVA6Cfg.NrWbPorts; i++) begin
      if (fwd_i.wb[i].valid && !fwd_i.wb[i].ex_valid) begin
        fwd_res[fwd_i.wb[i].trans_id] = fwd_i.wb[i].data;
        fwd_res_valid[fwd_i.wb[i].trans_id] = 1'b1;
      end
    end
  end

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assign rs1_res[i] = fwd_res[idx_hzd_rs1[i]];
    assign rs1_is_not_csr[i] = rs1_fpr[i] || (fwd_i.sbe[idx_hzd_rs1[i]].fu != ariane_pkg::CSR) || (CVA6Cfg.RVS && issue_instr_i[i].op == ariane_pkg::SFENCE_VMA);
    assign rs1_valid[i] = fwd_res_valid[idx_hzd_rs1[i]] && rs1_is_not_csr[i];

    assign rs2_res[i] = fwd_res[idx_hzd_rs2[i]];
    assign rs2_is_not_csr[i] = rs2_fpr[i] || (fwd_i.sbe[idx_hzd_rs2[i]].fu != ariane_pkg::CSR) || (CVA6Cfg.RVS && issue_instr_i[i].op == ariane_pkg::SFENCE_VMA);
    assign rs2_valid[i] = fwd_res_valid[idx_hzd_rs2[i]] && rs2_is_not_csr[i];

    assign rs3[i] = fwd_res[idx_hzd_rs3[i]];
    assign rs3_valid[i] = fwd_res_valid[idx_hzd_rs3[i]];

    if (CVA6Cfg.NrRgprPorts == 3) begin
      assign rs3_res[i] = rs3[i][CVA6Cfg.XLEN-1:0];
    end else begin
      assign rs3_res[i] = rs3[i][CVA6Cfg.FLen-1:0];
    end
  end

  // ---------------
  // Register stage
  // ---------------
  // check that all operands are available, otherwise stall
  // forward corresponding register
  always_comb begin : operands_available
    alu_bypass  = '0;

    stall_raw   = '{default: stall_i};
    stall_rs1   = '{default: stall_i};
    stall_rs2   = '{default: stall_i};
    stall_rs3   = '{default: stall_i};
    // operand forwarding signals
    forward_rs1 = '0;
    forward_rs2 = '0;
    forward_rs3 = '0;  // FPR and CV-X-IF only

    for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      // U5: renamed ops already waited in IQ — skip arch RAW stall (PRF ready)
      if (CVA6Cfg.OoOEn && issue_instr_i[i].ooo_renamed) begin
        // still allow scoreboard forward for same-cycle precision if valid
        if (rs1_has_raw[i] && rs1_valid[i]) forward_rs1[i] = 1'b1;
        if (rs2_has_raw[i] && rs2_valid[i]) forward_rs2[i] = 1'b1;
        if (rs3_has_raw[i] && rs3_valid[i]) forward_rs3[i] = 1'b1;
      end else begin
      if (rs1_has_raw[i]) begin
        if (rs1_valid[i]) begin
          forward_rs1[i] = 1'b1;
        end else begin  // the operand is not available -> stall
          stall_raw[i] = 1'b1;
          stall_rs1[i] = 1'b1;
        end
      end

      if (rs2_has_raw[i]) begin
        if (rs2_valid[i]) begin
          forward_rs2[i] = 1'b1;
        end else begin  // the operand is not available -> stall
          stall_raw[i] = 1'b1;
          stall_rs2[i] = 1'b1;
        end
      end

      if (rs3_has_raw[i]) begin
        if (rs3_valid[i]) begin
          forward_rs3[i] = 1'b1;
        end else begin  // the operand is not available -> stall
          stall_raw[i] = 1'b1;
          stall_rs3[i] = 1'b1;
        end
      end
      // G1o: stall STORE rs2==ra while a same-hart link-jal is
      // still_issued. G1ae: also when that jal is cancelled
      // (still_issued=0, sbe.valid=1 — cancel sets valid). TRACE after
      // G1ad: sd ra fetched with stale ra; jal wrote pc+4 only at
      // commit. Combinational; no sticky bit (not G1i). SMT+SS only.
      // G1ai: also stall while a same-hart addi sp is still in the SB
      // or on an earlier issue port. TRACE: sd @0x4b8 fetched with
      // sp=0x80008000; 0x68 used 0x80007ff0. c.sdsp may miss RAW.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
          issue_instr_i[i].fu == ariane_pkg::STORE &&
          issue_instr_i[i].rs2[4:0] == 5'd1) begin
        for (int unsigned k = 0; k < CVA6Cfg.NR_SB_ENTRIES; k++) begin
          if ((fwd_i.still_issued[k] || fwd_i.sbe[k].valid) &&
              fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id) begin
            if (fwd_i.sbe[k].fu == ariane_pkg::CTRL_FLOW &&
                fwd_i.sbe[k].rd[4:0] == 5'd1) begin
              stall_raw[i] = 1'b1;
              stall_rs2[i] = 1'b1;
            end
            if (g6lc_sb_keep::addi_sp(
                    fwd_i.sbe[k].fu,
                    fwd_i.sbe[k].rd[4:0],
                    fwd_i.sbe[k].rs1[4:0])) begin
              stall_raw[i] = 1'b1;
              stall_rs1[i] = 1'b1;
            end
          end
        end
        for (int unsigned e = 0; e < i; e++) begin
          if (issue_instr_valid_i[e] &&
              issue_instr_i[e].hart_id == issue_instr_i[i].hart_id &&
              g6lc_sb_keep::addi_sp(
                  issue_instr_i[e].fu,
                  issue_instr_i[e].rd[4:0],
                  issue_instr_i[e].rs1[4:0])) begin
            stall_raw[i] = 1'b1;
            stall_rs1[i] = 1'b1;
          end
        end
      end
      // G1an: stall a use while a same-hart cancelled-valid LOAD
      // of that rs is still in the SB. raw_checker only sees
      // still_issued (issued & ~cancelled); cancel + valid leaves
      // the consumer reading stale RF. Do not stall still_issued
      // (that path already forwards). TRACE G1am: c.ldsp t3 left
      // t3=0xed. Earlier-port LOAD dest too. SMT+SS. Combinational.
      // Not G1i/G1af/G1aj/G1ak.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
        for (int unsigned k = 0; k < CVA6Cfg.NR_SB_ENTRIES; k++) begin
          if (!fwd_i.still_issued[k] && fwd_i.sbe[k].valid &&
              fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id &&
              fwd_i.sbe[k].fu == ariane_pkg::LOAD &&
              fwd_i.sbe[k].rd[4:0] != 5'd0) begin
            if (fwd_i.sbe[k].rd == issue_instr_i[i].rs1) begin
              stall_raw[i] = 1'b1;
              stall_rs1[i] = 1'b1;
            end
            if (fwd_i.sbe[k].rd == issue_instr_i[i].rs2) begin
              stall_raw[i] = 1'b1;
              stall_rs2[i] = 1'b1;
            end
          end
        end
        for (int unsigned e = 0; e < i; e++) begin
          if (issue_instr_valid_i[e] &&
              issue_instr_i[e].hart_id == issue_instr_i[i].hart_id &&
              issue_instr_i[e].fu == ariane_pkg::LOAD &&
              issue_instr_i[e].rd[4:0] != 5'd0) begin
            if (issue_instr_i[e].rd == issue_instr_i[i].rs1) begin
              stall_raw[i] = 1'b1;
              stall_rs1[i] = 1'b1;
            end
            if (issue_instr_i[e].rd == issue_instr_i[i].rs2) begin
              stall_raw[i] = 1'b1;
              stall_rs2[i] = 1'b1;
            end
          end
        end
      end
      // G1ea: stall a use while a same-hart CSR to that rs is
      // in the SB. idx_hzd can pick an older jalr/ALU writer
      // of a0 (71e4 return=1) so c.mv s1,a0 forwards stale 1
      // and 7be skips scratch_init. CSR is never forwarded
      // (rs1_is_not_csr). G1dz rdata mux did not change this.
      // Not G1an LOAD. Not leftover keep. SMT+SS.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
        for (int unsigned k = 0; k < CVA6Cfg.NR_SB_ENTRIES; k++) begin
          if ((fwd_i.still_issued[k] || fwd_i.sbe[k].valid) &&
              fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id &&
              fwd_i.sbe[k].fu == ariane_pkg::CSR &&
              fwd_i.sbe[k].rd[4:0] != 5'd0) begin
            if (fwd_i.sbe[k].rd == issue_instr_i[i].rs1) begin
              stall_raw[i] = 1'b1;
              stall_rs1[i] = 1'b1;
            end
            if (fwd_i.sbe[k].rd == issue_instr_i[i].rs2) begin
              stall_raw[i] = 1'b1;
              stall_rs2[i] = 1'b1;
            end
          end
        end
        for (int unsigned e = 0; e < i; e++) begin
          if (issue_instr_valid_i[e] &&
              issue_instr_i[e].hart_id == issue_instr_i[i].hart_id &&
              issue_instr_i[e].fu == ariane_pkg::CSR &&
              issue_instr_i[e].rd[4:0] != 5'd0) begin
            if (issue_instr_i[e].rd == issue_instr_i[i].rs1) begin
              stall_raw[i] = 1'b1;
              stall_rs1[i] = 1'b1;
            end
            if (issue_instr_i[e].rd == issue_instr_i[i].rs2) begin
              stall_raw[i] = 1'b1;
              stall_rs2[i] = 1'b1;
            end
          end
        end
      end
      end
    end

    if (CVA6Cfg.CvxifEn) begin
      // Remove unnecessary forward and stall in case source register is not needed by coprocessor.
      if (x_issue_valid_o && x_issue_resp_i.accept) begin
        if (~x_issue_resp_i.register_read[0]) begin
          forward_rs1[0] = 1'b0;
          stall_rs1[0]   = 1'b0;
        end
        if (~x_issue_resp_i.register_read[1]) begin
          forward_rs2[0] = 1'b0;
          stall_rs2[0]   = 1'b0;
        end
        if (OPERANDS_PER_INSTR == 3 && ~x_issue_resp_i.register_read[2]) begin
          forward_rs3[0] = 1'b0;
          stall_rs3[0]   = 1'b0;
        end
      end
      stall_raw[0] = x_transaction_rejected ? 1'b0 : stall_rs1[0] || stall_rs2[0] || stall_rs3[0];
    end

    // Same-cycle RAW across earlier issue ports (in-order multi-issue 2..8).
    if (CVA6Cfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin
        for (int unsigned e = 0; e < p; e++) begin
          // rs1 of p depends on rd of e
          if (!issue_instr_i[p].use_zimm && (!CVA6Cfg.FpPresent || (is_rs1_fpr(
                  issue_instr_i[p].op
              ) == is_rd_fpr(
                  issue_instr_i[e].op
              ))) && issue_instr_i[p].rs1 == issue_instr_i[e].rd &&
              issue_instr_i[p].rs1 != '0) begin
            // ALU bypass only between port 0→1 when enabled
            if (is_alu_bypass && e == 0 && p == 1) begin
              alu_bypass.rs1_from_rd = 1'b1;
            end else begin
              stall_raw[p] = 1'b1;
            end
          end
          if ((!CVA6Cfg.FpPresent || (is_rs2_fpr(
                  issue_instr_i[p].op
              ) == is_rd_fpr(
                  issue_instr_i[e].op
              ))) && issue_instr_i[p].rs2 == issue_instr_i[e].rd &&
              issue_instr_i[p].rs2 != '0) begin
            if (is_alu_bypass && e == 0 && p == 1) begin
              alu_bypass.rs2_from_rd = 1'b1;
            end else begin
              stall_raw[p] = 1'b1;
            end
          end
          // FP imm / CVXIF third operand clobber
          if ((CVA6Cfg.FpPresent && is_imm_fpr(
                  issue_instr_i[p].op
              )) ? is_rd_fpr(
                  issue_instr_i[e].op
              ) && issue_instr_i[e].rd == issue_instr_i[p].result[REG_ADDR_SIZE-1:0] :
                  issue_instr_i[p].op == OFFLOAD && OPERANDS_PER_INSTR == 3 ?
                  issue_instr_i[e].rd == issue_instr_i[p].result[REG_ADDR_SIZE-1:0] : 1'b0) begin
            stall_raw[p] = 1'b1;
          end
        end
      end
    end
    // G1gf stall jalr until rs1 usable —
    // HOLD-FAIL no cookie (hung OpenSBI jalr).
    // Do not re-land (G0/G1i class).
  end

  // third operand from fp regfile or gp regfile if NR_RGPR_PORTS == 3
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    if (OPERANDS_PER_INSTR == 3) begin : gen_gp_rs3
      assign imm_forward_rs3[i] = rs3_res[i];
    end else begin : gen_fp_rs3
      assign imm_forward_rs3[i] = {{CVA6Cfg.XLEN - CVA6Cfg.FLen{1'b0}}, rs3_res[i]};
    end
  end

  // AMOCAS.Q: 2-phase RF gather for register pairs (rd/rd+1, rs2/rs2+1)
  logic casq_phase_q, casq_phase_d;
  logic [CVA6Cfg.XLEN-1:0] casq_new_lo_q, casq_exp_lo_q;
  logic [CVA6Cfg.XLEN-1:0] casq_new_hi_q, casq_exp_hi_q;
  logic casq_active;
  assign casq_active = CVA6Cfg.RVZacas && issue_instr_valid_i[0] &&
                       (issue_instr_i[0].op == ariane_pkg::AMO_CASQ);
  logic casq_ready_q;
  logic casq_stall;
  // Stall until both pair halves are latched (casq_ready_q). Do not issue on
  // phase1: raddr is remapped to hi so live RF lo would be wrong.
  assign casq_stall = casq_active && (OPERANDS_PER_INSTR == 3) && !casq_ready_q
                      && !issue_instr_i[0].ex.valid;

  // Forwarding/Output MUX
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    always_comb begin : forwarding_operand_select
      // default is regfiles (gpr or fpr)
      fu_data_n[i].operand_a = operand_a_regfile[i];
      fu_data_n[i].operand_b = operand_b_regfile[i];
      fu_data_n[i].operand_c = '0;

      // immediates are the third operands in the store case
      // for FP operations, the imm field can also be the third operand from the regfile
      // Zacas AMOCAS: third GPR (rd=expected) goes to operand_c; imm stays 0 so
      // vaddr = rs1 (AMOs do not use an address offset).
      // Default Q hi halves unused
      fu_data_n[i].operand_b_hi = '0;
      fu_data_n[i].operand_c_hi = '0;
      if (CVA6Cfg.RVZacas && ariane_pkg::is_amo_cas(issue_instr_i[i].op) && OPERANDS_PER_INSTR == 3) begin
        fu_data_n[i].imm = '0;
        fu_data_n[i].operand_c = operand_c_regfile[i];
      end else if (OPERANDS_PER_INSTR == 3) begin
        fu_data_n[i].imm = (CVA6Cfg.FpPresent && is_imm_fpr(issue_instr_i[i].op)) ?
            {{CVA6Cfg.XLEN - CVA6Cfg.FLen{1'b0}}, operand_c_regfile[i]} :
            issue_instr_i[i].op == OFFLOAD ? operand_c_regfile[i] : issue_instr_i[i].result;
      end else begin
        fu_data_n[i].imm = (CVA6Cfg.FpPresent && is_imm_fpr(issue_instr_i[i].op)) ?
            {{CVA6Cfg.XLEN - CVA6Cfg.FLen{1'b0}}, operand_c_regfile[i]} : issue_instr_i[i].result;
      end
      fu_data_n[i].trans_id  = issue_instr_i[i].trans_id;
      fu_data_n[i].fu        = issue_instr_i[i].fu;
      fu_data_n[i].operation = issue_instr_i[i].op;
      if (CVA6Cfg.RVH) begin
        tinst_n[i] = issue_instr_i[i].ex.tinst;
      end

      // or should we forward
      if (forward_rs1[i]) begin
        fu_data_n[i].operand_a = rs1_res[i];
      end
      // I4by: offset_ptr `c.add a0,a1` (rd==x10 && rs1==x10 && rs2==x11 &&
      // !use_imm). No a0-dest between last `lbu 38(a0)` and that add. A
      // forwarded page-0 a0 (wrong-port / leftover `c.li a0,0`) makes
      // fdt+offset = 9 (PEEL c.lw@129f8 mtval=9). Fall back to RF.
      // SMT+SS only. SI: NrHarts==1 const-folds the guard.
      // G0 LOAD/STORE small_nz forward drop hold-FAIL 2026-08-15 — reverted.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
          forward_rs1[i] &&
          issue_instr_i[i].fu == ariane_pkg::ALU &&
          !issue_instr_i[i].use_imm &&
          issue_instr_i[i].rd == 5'd10 &&
          issue_instr_i[i].rs1[4:0] == 5'd10 &&
          issue_instr_i[i].rs2[4:0] == 5'd11 &&
          rs1_res[i][CVA6Cfg.XLEN-1:12] == '0) begin
        fu_data_n[i].operand_a = operand_a_regfile[i];
      end
      // G1k: LOAD address. P4 c.lw of fdt+0x28 retired a5=0x010dfeec
      // (DRAM word is 1). Architectural a0 was s2+0x28; a leftover
      // non-cached forward (magic/assemble) can still feed the LSU.
      // If RF is already a cached pointer, do not replace it with a
      // non-cached forward. Not G0 (no stall). Not G1i. SMT+SS only.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
          forward_rs1[i] &&
          issue_instr_i[i].fu == ariane_pkg::LOAD &&
          config_pkg::is_inside_cacheable_regions(
              CVA6Cfg, 64'(operand_a_regfile[i])) &&
          !config_pkg::is_inside_cacheable_regions(
              CVA6Cfg, 64'(rs1_res[i]))) begin
        fu_data_n[i].operand_a = operand_a_regfile[i];
      end
      // G1gg: jalr prefers usable RF rs1 over
      // an unusable forward. No stall (G1gf
      // HOLD-FAIL hung OpenSBI). Not G0. SMT+SS.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
          issue_instr_i[i].op == ariane_pkg::JALR &&
          forward_rs1[i] &&
          !g6lc_jalr_usable::usable(
              CVA6Cfg, CVA6Cfg.VLEN, 64'(rs1_res[i])) &&
          g6lc_jalr_usable::usable(
              CVA6Cfg, CVA6Cfg.VLEN, 64'(operand_a_regfile[i]))) begin
        fu_data_n[i].operand_a = operand_a_regfile[i];
      end
      if (forward_rs2[i]) begin
        fu_data_n[i].operand_b = rs2_res[i];
      end
      // G1h: c.mv a0↔s* (rd/rs2 ABI pointer copy). A forwarded
      // execute-region base (boot 0x80000000) made s0=_start, so
      // offset_ptr's 2nd load_be32 assembled _start+8 (mini 0x32,
      // leftover a0=0xB7010100). Fall back to RF. Not G0 (no stall).
      // SMT+SS only. SI: NrHarts==1 const-folds the guard.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
          forward_rs2[i] &&
          issue_instr_i[i].fu == ariane_pkg::ALU &&
          g6lc_sb_keep::cmv_abi_ptr(
              issue_instr_i[i].rd,
              issue_instr_i[i].rs1[4:0],
              issue_instr_i[i].rs2[4:0],
              issue_instr_i[i].use_imm) &&
          g6lc_sb_keep::exec_region_base(
              CVA6Cfg, 64'(rs2_res[i]))) begin
        fu_data_n[i].operand_b = operand_b_regfile[i];
      end
      if ((CVA6Cfg.FpPresent || (CVA6Cfg.CvxifEn && OPERANDS_PER_INSTR == 3) ||
           (CVA6Cfg.RVZacas && ariane_pkg::is_amo_cas(issue_instr_i[i].op))) && forward_rs3[i]) begin
        if (CVA6Cfg.RVZacas && ariane_pkg::is_amo_cas(issue_instr_i[i].op))
          fu_data_n[i].operand_c = imm_forward_rs3[i];
        else
          fu_data_n[i].imm = imm_forward_rs3[i];
      end

      // use the PC as operand a
      if (issue_instr_i[i].use_pc) begin
        fu_data_n[i].operand_a = {
          {CVA6Cfg.XLEN - CVA6Cfg.VLEN{issue_instr_i[i].pc[CVA6Cfg.VLEN-1]}}, issue_instr_i[i].pc
        };
      end
      // G1r: carry this CF's PC in operand_c so branch_unit next_pc /
      // non-JALR jump_base are not the shared EX pc_o (G1p). Mini P6
      // jal retired P5's 0x14c. SMT+SS only. SI: operand_c stays 0.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
          issue_instr_i[i].fu == CTRL_FLOW) begin
        fu_data_n[i].operand_c = {
          {CVA6Cfg.XLEN - CVA6Cfg.VLEN{issue_instr_i[i].pc[CVA6Cfg.VLEN-1]}},
          issue_instr_i[i].pc
        };
        // G1hg: carry orig 16-bit in
        // operand_c_hi so EX can recover a
        // mid-line Branch that is exact
        // c.jalr. Not G1he all Branch.
        // SMT+SS. SI: stays 0.
        fu_data_n[i].operand_c_hi = {
          {CVA6Cfg.XLEN - 32{1'b0}}, orig_instr_i[i]
        };
      end

      // use the zimm as operand a
      if (issue_instr_i[i].use_zimm) begin
        // zero extend operand a
        fu_data_n[i].operand_a = {{CVA6Cfg.XLEN - 5{1'b0}}, issue_instr_i[i].rs1[4:0]};
      end
      // or is it an immediate (including PC), this is not the case for a store, control flow, and accelerator instructions
      // also make sure operand B is not already used as an FP operand
      if (issue_instr_i[i].use_imm && (issue_instr_i[i].fu != STORE) && (issue_instr_i[i].fu != CTRL_FLOW) && (issue_instr_i[i].fu != ACCEL) && !(CVA6Cfg.FpPresent && is_rs2_fpr(
              issue_instr_i[i].op
          ))) begin
        fu_data_n[i].operand_b = issue_instr_i[i].result;
      end
      // AMOCAS.Q: after all forwards, force pair-gather (latched lo + hi)
      if (CVA6Cfg.RVZacas && issue_instr_i[i].op == ariane_pkg::AMO_CASQ && casq_ready_q) begin
        fu_data_n[i].operand_b    = casq_new_lo_q;
        fu_data_n[i].operand_c    = casq_exp_lo_q;
        fu_data_n[i].operand_b_hi = casq_new_hi_q;
        fu_data_n[i].operand_c_hi = casq_exp_hi_q;
      end
      // G1gp: carry RF rs1 in operand_b so EX
      // jalr resolve can salvage a usable
      // target when operand_a is unusable.
      // Not G1gg mux-only. Not G1gf stall.
      // SMT+SS. JALR is CTRL_FLOW so use_imm
      // does not occupy operand_b.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
          issue_instr_i[i].op == ariane_pkg::JALR)
        fu_data_n[i].operand_b = operand_a_regfile[i];
    end
  end

  always_comb begin
    alu_valid_n    = '0;
    aes_valid_n    = '0;
    lsu_valid_n    = '0;
    mult_valid_n   = '0;
    fpu_valid_n    = '0;
    fpu_fmt_n      = '0;
    fpu_rm_n       = '0;
    alu2_valid_n   = '0;
    csr_valid_n    = '0;
    branch_valid_n = '0;
    for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      if (!issue_instr_i[i].ex.valid && issue_instr_valid_i[i] && issue_ack_o[i]) begin
        case (issue_instr_i[i].fu)
          ALU: begin
            if (CVA6Cfg.SuperscalarEn && use_alu2[i]) begin
              alu2_valid_n[i] = 1'b1;
            end else begin
              alu_valid_n[i] = 1'b1;
            end
          end
          CTRL_FLOW: begin
            branch_valid_n[i] = 1'b1;
          end
          MULT: begin
            mult_valid_n[i] = 1'b1;
          end
          LOAD, STORE: begin
            lsu_valid_n[i] = 1'b1;
          end
          CSR: begin
            csr_valid_n[i] = 1'b1;
          end
          AES: begin
            aes_valid_n[i] = 1'b1;
          end
          default: begin
            if (issue_instr_i[i].fu == FPU && CVA6Cfg.FpPresent) begin
              fpu_valid_n[i] = 1'b1;
              fpu_fmt_n      = orig_instr[i].rftype.fmt;  // fmt bits from instruction
              fpu_rm_n       = orig_instr[i].rftype.rm;  // rm bits from instruction
            end else if (issue_instr_i[i].fu == FPU_VEC && CVA6Cfg.FpPresent) begin
              fpu_valid_n[i] = 1'b1;
              fpu_fmt_n      = orig_instr[i].rvftype.vfmt;  // vfmt bits from instruction
              fpu_rm_n       = {2'b0, orig_instr[i].rvftype.repl};  // repl bit from instruction
            end
          end
        endcase
      end
    end
    // if we got a flush request, de-assert the valid flag, otherwise we will start this
    // functional unit with the wrong inputs
    // G1t: flush_i is flush_unissued. Do not kill an acked link-jal —
    // SB allocates it and EX must still compute the link.
    if (flush_i) begin
      alu_valid_n    = '0;
      aes_valid_n    = '0;
      lsu_valid_n    = '0;
      mult_valid_n   = '0;
      fpu_valid_n    = '0;
      alu2_valid_n   = '0;
      csr_valid_n    = '0;
      if (!(CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1)) begin
        branch_valid_n = '0;
      end else begin
        for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
          if (!g6lc_sb_keep::link_jal(
                  CVA6Cfg.SuperscalarEn,
                  issue_instr_i[i].fu,
                  issue_instr_i[i].rd[4:0]))
            branch_valid_n[i] = 1'b0;
        end
      end
    end
  end
  // FU select, assert the correct valid out signal (in the next cycle)
  // This needs to be like this to make verilator happy. I know it's ugly.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      alu_valid_q    <= '0;
      aes_valid_q    <= '0;
      lsu_valid_q    <= '0;
      mult_valid_q   <= '0;
      fpu_valid_q    <= '0;
      fpu_fmt_q      <= '0;
      fpu_rm_q       <= '0;
      alu2_valid_q   <= '0;
      csr_valid_q    <= '0;
      branch_valid_q <= '0;
    end else begin
      alu_valid_q    <= alu_valid_n;
      aes_valid_q    <= aes_valid_n;
      lsu_valid_q    <= lsu_valid_n;
      mult_valid_q   <= mult_valid_n;
      fpu_valid_q    <= fpu_valid_n;
      fpu_fmt_q      <= fpu_fmt_n;
      fpu_rm_q       <= fpu_rm_n;
      alu2_valid_q   <= alu2_valid_n;
      csr_valid_q    <= csr_valid_n;
      branch_valid_q <= branch_valid_n;
    end
  end

  if (CVA6Cfg.CvxifEn) begin
    always_comb begin
      cvxif_valid_n = '0;
      cvxif_off_instr_n = 32'b0;
      for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
        if (!issue_instr_i[i].ex.valid && issue_instr_valid_i[i] && issue_ack_o[i]) begin
          case (issue_instr_i[i].fu)
            CVXIF: begin
              cvxif_valid_n[i]  = 1'b1;
              cvxif_off_instr_n = orig_instr_i[i];
            end
            default: ;
          endcase
        end
      end
      if (flush_i) begin
        cvxif_valid_n = '0;
        cvxif_off_instr_n = 32'b0;
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cvxif_valid_q <= '0;
        cvxif_off_instr_q <= 32'b0;
      end else begin
        cvxif_valid_q <= cvxif_valid_n;
        cvxif_off_instr_q <= cvxif_off_instr_n;
      end
    end
  end

  // Soft-ladder B1 (b1-lrsc-cmpxchg): LR→SC exclusive pair window.
  // Set on LR issue ack; clear on SC issue or pipeline flush. While live,
  // block non-SC STORE issue so intervening stores cannot clear AXI exclusive
  // reservation (axi_riscv_lrsc → forever-fail SC under OpenSBI cmpxchg).
  logic lr_sc_pair_q, lr_sc_pair_d;

  // We can issue an instruction if we do not detect that any other instruction is writing the same
  // destination register.
  // We also need to check if there is an unresolved branch in the scoreboard.
  always_comb begin : issue_scoreboard
    for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      // default assignment
      issue_ack[i] = 1'b0;
      // check that the instruction we got is valid
      // and that the functional unit we need is not busy
      if (issue_instr_valid_i[i] && !fu_busy[i]) begin
        if (!stall_raw[i]) begin
          issue_ack[i] = 1'b1;
        end
        if (issue_instr_i[i].ex.valid) begin
          issue_ack[i] = 1'b1;
        end
      end
    end

    issue_ack_o = issue_ack;
    if (casq_stall) issue_ack_o[0] = 1'b0;
    // Do not acknowledge the issued instruction if transaction is not completed.
    if (issue_instr_i[0].fu == CVXIF && !(x_transaction_accepted_o || x_transaction_rejected)) begin
      issue_ack_o[0] = issue_instr_i[0].ex.valid && issue_instr_valid_i[0];
    end
    if (CVA6Cfg.RVA && lr_sc_pair_q) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_instr_i[p].fu == STORE && !ariane_pkg::is_amo_sc(issue_instr_i[p].op)) begin
          issue_ack_o[p] = 1'b0;
        end
      end
    end
    // In-order multi-issue: a bubble on port k kills ports k+1..N-1
    if (CVA6Cfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (!issue_ack_o[p-1]) issue_ack_o[p] = 1'b0;
      end
      // Soft-ladder B1 (b1-amo-spin-lock): AMO only on issue port 0 under SS.
      // Port-1 AMO + hang-7 younger-cancel left amo_buffer wedged (depth 1,
      // no flush_ex on mispredict). store_unit cancel kill recovers that;
      // keep AMO serial for commit/amo_valid_commit_o coupling.
      if (CVA6Cfg.RVA) begin
        for (int unsigned p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin
          if (ariane_pkg::is_amo(issue_instr_i[p].op)) issue_ack_o[p] = 1'b0;
        end
      end
      // iter-012 note: force SI (issue_ack_o[p>0]=0) was PEEL_FDT-negative
      // (fw64e, same 12eb2/12b2a) — residual is not residual dual-issue pairs.
    end
  end

  always_comb begin : gen_lr_sc_pair
    lr_sc_pair_d = lr_sc_pair_q;
    if (CVA6Cfg.RVA) begin
      for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_instr_valid_i[p] && issue_ack_o[p] && !issue_instr_i[p].ex.valid) begin
          if (ariane_pkg::is_amo_lr(issue_instr_i[p].op)) lr_sc_pair_d = 1'b1;
          if (ariane_pkg::is_amo_sc(issue_instr_i[p].op)) lr_sc_pair_d = 1'b0;
        end
      end
    end
    if (flush_i) lr_sc_pair_d = 1'b0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lr_sc_pair_q <= 1'b0;
    else lr_sc_pair_q <= lr_sc_pair_d;
  end

  // ----------------------
  // Integer Register File
  // ----------------------
  // G1gq: one extra combo read of commit JALR rs1 (SMT+SS).
  localparam int unsigned G1GQ_RF_PORTS =
      (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) ?
          (CVA6Cfg.NrRgprPorts + 1) : CVA6Cfg.NrRgprPorts;
  logic [  CVA6Cfg.NrRgprPorts-1:0][CVA6Cfg.XLEN-1:0] rdata;
  logic [  CVA6Cfg.NrRgprPorts-1:0][             4:0] raddr_pack;
  logic [  CVA6Cfg.NrRgprPorts-1:0][             4:0] raddr_pack_base;
  logic [G1GQ_RF_PORTS-1:0][CVA6Cfg.XLEN-1:0]         g1gq_rdata;
  logic [G1GQ_RF_PORTS-1:0][4:0]                      g1gq_raddr;

  // pack signals
  logic [CVA6Cfg.NrCommitPorts-1:0][             4:0] waddr_pack;
  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.XLEN-1:0] wdata_pack;
  logic [CVA6Cfg.NrCommitPorts-1:0]                   we_pack;

  //adjust address to read from register file (when synchronous RAM is used reads take one cycle, so we advance the address)
  for (genvar i = 0; i <= CVA6Cfg.NrIssuePorts - 1; i++) begin
    assign raddr_pack_base[i*OPERANDS_PER_INSTR+0] = CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn ? issue_instr_i_prev[i].rs1[4:0] : issue_instr_i[i].rs1[4:0];
    assign raddr_pack_base[i*OPERANDS_PER_INSTR+1] = CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn ? issue_instr_i_prev[i].rs2[4:0] : issue_instr_i[i].rs2[4:0];
    if (OPERANDS_PER_INSTR == 3) begin
      assign raddr_pack_base[i*OPERANDS_PER_INSTR+2] = CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn ? issue_instr_i_prev[i].result[4:0] : issue_instr_i[i].result[4:0];
      // CASQ phase1: read rs2+1 and rd+1 on ports 1 and 2 (port0 unused/addr already latched)
      // Applied after generate via always_comb override below.
    end
  end

  for (genvar i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin : gen_write_back_port
    assign waddr_pack[i] = waddr_i[i];
    assign wdata_pack[i] = wdata_i[i];
    assign we_pack[i]    = we_gpr_i[i];
  end
  // Force pair addresses during CASQ second RF phase (issue port 0 only)
  always_comb begin
    casq_phase_d = casq_phase_q;
    raddr_pack = raddr_pack_base;
    if (casq_active && OPERANDS_PER_INSTR == 3) begin
      if (casq_ready_q) begin
        casq_phase_d = 1'b0;
      end else if (!casq_phase_q) begin
        // phase0: normal rs1/rs2/rd — after RF, latch lo and advance
        casq_phase_d = 1'b1;
      end else begin
        // phase1: reread high halves
        raddr_pack[1] = issue_instr_i[0].rs2[4:0] | 5'b00001;  // rs2+1
        raddr_pack[2] = issue_instr_i[0].result[4:0] | 5'b00001;  // rd+1
        casq_phase_d = 1'b0;
      end
    end else begin
      casq_phase_d = 1'b0;
    end
    g1gq_raddr = '0;
    for (int unsigned p = 0; p < CVA6Cfg.NrRgprPorts; p++)
      g1gq_raddr[p] = raddr_pack[p];
    if (G1GQ_RF_PORTS > CVA6Cfg.NrRgprPorts)
      g1gq_raddr[CVA6Cfg.NrRgprPorts] = g1gq_raddr_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      casq_phase_q  <= 1'b0;
      casq_ready_q  <= 1'b0;
      casq_new_lo_q <= '0;
      casq_exp_lo_q <= '0;
      casq_new_hi_q <= '0;
      casq_exp_hi_q <= '0;
    end else if (flush_i) begin
      casq_phase_q <= 1'b0;
      casq_ready_q <= 1'b0;
    end else if (casq_active && OPERANDS_PER_INSTR == 3) begin
      if (casq_ready_q) begin
        // Hold gathered pair until issue_ack drops the instr (casq_active clears)
        casq_phase_q <= 1'b0;
        casq_ready_q <= 1'b1;
      end else begin
        casq_phase_q <= casq_phase_d;
        if (!casq_phase_q) begin
          casq_new_lo_q <= rdata[1];
          casq_exp_lo_q <= rdata[2];
          casq_ready_q  <= 1'b0;
        end else begin
          casq_new_hi_q <= rdata[1];
          casq_exp_hi_q <= rdata[2];
          casq_ready_q  <= 1'b1;
        end
      end
    end else begin
      casq_phase_q <= 1'b0;
      casq_ready_q <= 1'b0;
    end
  end

  if (CVA6Cfg.FpgaEn) begin : gen_fpga_regfile
    ariane_regfile_fpga #(
        .CVA6Cfg      (CVA6Cfg),
        .DATA_WIDTH   (CVA6Cfg.XLEN),
        .NR_READ_PORTS(G1GQ_RF_PORTS),
        .ZERO_REG_ZERO(1)
    ) i_ariane_regfile_fpga (
        .clk_i,
        .rst_ni,
        .test_en_i(1'b0),
        .raddr_i  (g1gq_raddr),
        .rdata_o  (g1gq_rdata),
        .waddr_i  (waddr_pack),
        .wdata_i  (wdata_pack),
        .we_i     (we_pack)
    );
  end else begin : gen_asic_regfile
    // U6.1: banked RF when NrHarts>1 (per-hart isolation / no cross-hart port
    // contention). NrHarts==1 collapses to a single ariane_regfile (identity).
    localparam int unsigned SMT_HID_W =
        (CVA6Cfg.NrHarts <= 1) ? 1 : $clog2(CVA6Cfg.NrHarts);
    logic [G1GQ_RF_PORTS-1:0][SMT_HID_W-1:0] rhart_pack;
    logic [CVA6Cfg.NrCommitPorts-1:0][SMT_HID_W-1:0] whart_pack;
    // Tag reads from issuing instr hart_id; writes from commit instr hart_id.
    // (Previously whart was stuck at 0 — peer commits corrupted primary RF.)
    always_comb begin
      rhart_pack = '0;
      whart_pack = '0;
      if (CVA6Cfg.NrHarts > 1) begin
        for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
          for (int unsigned k = 0; k < OPERANDS_PER_INSTR; k++) begin
            rhart_pack[p*OPERANDS_PER_INSTR+k] = issue_instr_i[p].hart_id;
          end
        end
        if (G1GQ_RF_PORTS > CVA6Cfg.NrRgprPorts)
          rhart_pack[CVA6Cfg.NrRgprPorts] = g1gq_rhart_i;
        for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
          whart_pack[c] = whart_i[c];
        end
      end
    end
    g6lc_smt_regfile #(
        .CVA6Cfg      (CVA6Cfg),
        .DATA_WIDTH   (CVA6Cfg.XLEN),
        .NR_READ_PORTS(G1GQ_RF_PORTS),
        .NR_HARTS     (CVA6Cfg.NrHarts),
        .ZERO_REG_ZERO(1)
    ) i_ariane_regfile (
        .clk_i,
        .rst_ni,
        .test_en_i(1'b0),
        .raddr_i  (g1gq_raddr),
        .rhart_i  (rhart_pack),
        .rdata_o  (g1gq_rdata),
        .waddr_i  (waddr_pack),
        .wdata_i  (wdata_pack),
        .we_i     (we_pack),
        .whart_i  (whart_pack)
    );
  end

  assign rdata = g1gq_rdata[CVA6Cfg.NrRgprPorts-1:0];
  if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin : gen_g1gq_rdata
    assign g1gq_rdata_o = g1gq_rdata[CVA6Cfg.NrRgprPorts];
  end else begin : gen_g1gq_rdata_si
    assign g1gq_rdata_o = '0;
  end
  // -----------------------------
  // Floating-Point Register File
  // -----------------------------
  logic [2:0][CVA6Cfg.FLen-1:0] fprdata;

  // pack signals
  logic [2:0][4:0] fp_raddr_pack;
  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.XLEN-1:0] fp_wdata_pack;

  always_comb begin : assign_fp_raddr_pack
    fp_raddr_pack = {
      issue_instr_i[0].result[4:0], issue_instr_i[0].rs2[4:0], issue_instr_i[0].rs1[4:0]
    };

    if (CVA6Cfg.SuperscalarEn) begin
      if (!(issue_instr_i[0].fu inside {FPU, FPU_VEC} || issue_instr_i[0].op inside {[FLD:FSB]})) begin
        fp_raddr_pack = {
          issue_instr_i[1].result[4:0], issue_instr_i[1].rs2[4:0], issue_instr_i[1].rs1[4:0]
        };
      end
    end
  end

  generate
    if (CVA6Cfg.FpPresent) begin : float_regfile_gen
      for (genvar i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin : gen_fp_wdata_pack
        assign fp_wdata_pack[i] = {wdata_i[i][CVA6Cfg.FLen-1:0]};
      end
      if (CVA6Cfg.FpgaEn) begin : gen_fpga_fp_regfile
        ariane_regfile_fpga #(
            .CVA6Cfg      (CVA6Cfg),
            .DATA_WIDTH   (CVA6Cfg.FLen),
            .NR_READ_PORTS(3),
            .ZERO_REG_ZERO(0)
        ) i_ariane_fp_regfile_fpga (
            .clk_i,
            .rst_ni,
            .test_en_i(1'b0),
            .raddr_i  (fp_raddr_pack),
            .rdata_o  (fprdata),
            .waddr_i  (waddr_pack),
            .wdata_i  (fp_wdata_pack),
            .we_i     (we_fpr_i)
        );
      end else begin : gen_asic_fp_regfile
        ariane_regfile #(
            .CVA6Cfg      (CVA6Cfg),
            .DATA_WIDTH   (CVA6Cfg.FLen),
            .NR_READ_PORTS(3),
            .ZERO_REG_ZERO(0)
        ) i_ariane_fp_regfile (
            .clk_i,
            .rst_ni,
            .test_en_i(1'b0),
            .raddr_i  (fp_raddr_pack),
            .rdata_o  (fprdata),
            .waddr_i  (waddr_pack),
            .wdata_i  (fp_wdata_pack),
            .we_i     (we_fpr_i)
        );
      end
    end else begin : no_fpr_gen
      assign fprdata = '{default: '0};
    end
  endgenerate

  if (OPERANDS_PER_INSTR == 3) begin : gen_operand_c
    assign operand_c_fpr = {{CVA6Cfg.XLEN - CVA6Cfg.FLen{1'b0}}, fprdata[2]};
  end else begin
    assign operand_c_fpr = fprdata[2];
  end

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    if (OPERANDS_PER_INSTR == 3) begin : gen_operand_c
      assign operand_c_gpr[i] = rdata[i*OPERANDS_PER_INSTR+2];
    end

    // U5 production: prefer PRF operand when renamed (bypassed WB already applied)
    assign operand_a_regfile[i] =
        (CVA6Cfg.OoOEn && ooo_op_a_valid_i[i] && issue_instr_i[i].ooo_renamed &&
         !(CVA6Cfg.FpPresent && is_rs1_fpr(issue_instr_i[i].op)))
            ? ooo_op_a_i[i]
            : ((CVA6Cfg.FpPresent && is_rs1_fpr(
                issue_instr_i[i].op
            )) ? {{CVA6Cfg.XLEN - CVA6Cfg.FLen{1'b0}}, fprdata[0]} : rdata[i*OPERANDS_PER_INSTR+0]);
    assign operand_b_regfile[i] =
        (CVA6Cfg.OoOEn && ooo_op_b_valid_i[i] && issue_instr_i[i].ooo_renamed &&
         !(CVA6Cfg.FpPresent && is_rs2_fpr(issue_instr_i[i].op)))
            ? ooo_op_b_i[i]
            : ((CVA6Cfg.FpPresent && is_rs2_fpr(
                issue_instr_i[i].op
            )) ? {{CVA6Cfg.XLEN - CVA6Cfg.FLen{1'b0}}, fprdata[1]} : rdata[i*OPERANDS_PER_INSTR+1]);
    assign operand_c_regfile[i] = (OPERANDS_PER_INSTR == 3) ? ((CVA6Cfg.FpPresent && is_imm_fpr(
        issue_instr_i[i].op
    )) ? operand_c_fpr : operand_c_gpr[i]) : operand_c_fpr;
  end

  // ----------------------
  // Registers (ID <-> EX)
  // ----------------------

  always_comb begin
    // G1p: do not zero the EX PC on a non-CF issue cycle. pc_o used to
    // default to 0 every cycle; a jal then retired next_pc=4 and I4as
    // dropped we_gpr to ra (RF stayed the previous link — mini P6 0x65
    // P5 0x14c). SMT+SS: hold and capture only an acked CF. SI keeps
    // the old default-0 path (const-fold).
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      pc_n                  = pc_o;
      is_compressed_instr_n = is_compressed_instr_o;
      branch_predict_n      = branch_predict_o;
      branch_hart_n         = branch_hart_o;
      for (int unsigned p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (issue_instr_valid_i[p] && issue_ack_o[p] &&
            issue_instr_i[p].fu == CTRL_FLOW) begin
          pc_n                  = issue_instr_i[p].pc;
          is_compressed_instr_n = issue_instr_i[p].is_compressed;
          branch_predict_n      = issue_instr_i[p].bp;
          branch_hart_n         = issue_instr_i[p].hart_id;
        end
      end
      if (issue_instr_valid_i[0] && issue_ack_o[0] &&
          issue_instr_i[0].fu == CTRL_FLOW) begin
        pc_n                  = issue_instr_i[0].pc;
        is_compressed_instr_n = issue_instr_i[0].is_compressed;
        branch_predict_n      = issue_instr_i[0].bp;
        branch_hart_n         = issue_instr_i[0].hart_id;
      end
    end else begin
      pc_n = '0;
      is_compressed_instr_n = 1'b0;
      branch_predict_n = {cf_t'(0), {CVA6Cfg.VLEN{1'b0}}};
      branch_hart_n = '0;
      if (CVA6Cfg.SuperscalarEn) begin
        for (int unsigned p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin
          if (issue_instr_i[p].fu == CTRL_FLOW) begin
            pc_n                  = issue_instr_i[p].pc;
            is_compressed_instr_n = issue_instr_i[p].is_compressed;
            branch_predict_n      = issue_instr_i[p].bp;
            branch_hart_n         = issue_instr_i[p].hart_id;
          end
        end
      end
      if (issue_instr_i[0].fu == CTRL_FLOW) begin
        pc_n                  = issue_instr_i[0].pc;
        is_compressed_instr_n = issue_instr_i[0].is_compressed;
        branch_predict_n      = issue_instr_i[0].bp;
        branch_hart_n         = issue_instr_i[0].hart_id;
      end
    end
    x_transaction_rejected_n = 1'b0;
    if (issue_instr_i[0].fu == CVXIF) begin
      x_transaction_rejected_n = x_transaction_rejected;
    end
  end

  assign alu_bypass_n = &issue_ack_o ? alu_bypass : '0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fu_data_q <= '0;
      if (CVA6Cfg.RVH) begin
        tinst_q <= '0;
      end
      pc_o                     <= '0;
      branch_hart_o            <= '0;
      is_zcmt_o                <= '0;
      is_compressed_instr_o    <= 1'b0;
      branch_predict_o         <= {cf_t'(0), {CVA6Cfg.VLEN{1'b0}}};
      x_transaction_rejected_o <= 1'b0;
      alu_bypass_q             <= '0;
    end else begin
      fu_data_q <= fu_data_n;
      alu_bypass_q <= alu_bypass_n;
      if (CVA6Cfg.ZKN) begin
        orig_instr_aes_bits <= {orig_instr_i[0][31:30], orig_instr_i[0][23:20]};
      end
      if (CVA6Cfg.RVH) begin
        tinst_q <= tinst_n;
      end
      pc_o <= pc_n;
      branch_hart_o <= branch_hart_n;
      is_compressed_instr_o <= is_compressed_instr_n;
      branch_predict_o <= branch_predict_n;
      if (issue_instr_i[0].fu == CTRL_FLOW) begin
        if (CVA6Cfg.RVZCMT) is_zcmt_o <= issue_instr_i[0].is_zcmt;
        else is_zcmt_o <= '0;
      end
      x_transaction_rejected_o <= x_transaction_rejected_n;
    end
  end

  //pragma translate_off
  initial begin
    assert (OPERANDS_PER_INSTR == 2 || (OPERANDS_PER_INSTR == 3 && (CVA6Cfg.CvxifEn || CVA6Cfg.RVZacas)))
    else
      $fatal(
          1,
          "RF ports/instr must be 2, or 3 when CVXIF or Zacas (AMOCAS expected source)."
      );
  end

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assert property (@(posedge clk_i) (branch_valid_q) |-> (!$isunknown(
        fu_data_q[i].operand_a
    ) && !$isunknown(
        fu_data_q[i].operand_b
    )))
    else $warning("Got unknown value in one of the operands");
  end
  //pragma translate_on


endmodule



