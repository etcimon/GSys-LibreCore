// hyp8 provenance: ADAPTED (sv-timing emit base; in-ALU forward select)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
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
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    // hyp8: staged-ALU / IQ spec-wakeup configuration.
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
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
    input scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0] issue_instr_i,
    input scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0] issue_instr_i_prev,
    // Instruction to issue - SCOREBOARD
    input logic [G6LCCfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    // Is there an instruction to issue - SCOREBOARD
    input logic [G6LCCfg.NrIssuePorts-1:0] issue_instr_valid_i,
    // Issue stage acknowledge - SCOREBOARD
    output logic [G6LCCfg.NrIssuePorts-1:0] issue_ack_o,
    // hyp8 g7: per-operand spec-arm bits + ALU-class producer tids from the
    // OoO issue queue (zero on in-order paths). spec_ab[i][0]=rs1, [1]=rs2.
    input  logic [G6LCCfg.NrIssuePorts-1:0][1:0] issue_spec_ab_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][1:0][G6LCCfg.TRANS_ID_BITS-1:0] issue_ptid_i,
    // hyp8 g7: the shared ALU0 pipe-stage tids (A1 slot and the registered
    // A2/WB-record slot) -- the producer identities the forward select
    // compares against.
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] alu_fwd_tid_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] alu_fwd_qtid_i,
    // hyp8 r5: tid of the op in the registered A3 result slot
    // (LAT_ALU_FULL producers under AluStages==3).
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] alu_fwd_rtid_i,
    // hyp8 g7: per-operand in-ALU forward select for ALU0, in the fu_data_o
    // domain: bit 0 picks the live A2-comb result (producer in the A1
    // registers), bit 1 the registered A2 result (producer in the A2
    // record), bit 2 the registered A3 result (producer in the A3
    // record). All zero for every non-spec-armed operand.
    output logic [G6LCCfg.NrIssuePorts-1:0][2:0] alu_fwd_a_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][2:0] alu_fwd_b_o,
    // Forwarding - SCOREBOARD
    input forwarding_t fwd_i,
    // U5 OoO PRF operands (valid when OoOEn && issue_instr.ooo_renamed)
    input logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] ooo_op_a_i,
    input logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] ooo_op_b_i,
    input logic [G6LCCfg.NrIssuePorts-1:0]                   ooo_op_a_valid_i,
    input logic [G6LCCfg.NrIssuePorts-1:0]                   ooo_op_b_valid_i,
    // FP third operand from the OoO FP PRF (rs3). FLen wide, not XLEN: the FP
    // class has its own width, which can exceed XLEN on RV32+D.
    input logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.FLen-1:0] ooo_op_c_i,
    input logic [G6LCCfg.NrIssuePorts-1:0]                   ooo_op_c_valid_i,
    // FU data useful to execute instruction - EX_STAGE
    output fu_data_t [G6LCCfg.NrIssuePorts-1:0] fu_data_o,
    // ALU to ALU bypass control - EX_STAGE
    output alu_bypass_t alu_bypass_o,
    // Unregistered version of fu_data_o.operanda - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.VLEN-1:0] rs1_forwarding_o,
    // Unregistered version of fu_data_o.operandb - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.VLEN-1:0] rs2_forwarding_o,
    // Program Counter - EX_STAGE
    output logic [G6LCCfg.VLEN-1:0] pc_o,
    // FSE S5: SMT hart of the CTRL_FLOW instruction forwarded to EX
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] branch_hart_o,
    // Is zcmt - EX_STAGE
    output logic is_zcmt_o,
    // Is compressed instruction - EX_STAGE
    output logic is_compressed_instr_o,
    // Fixed Latency Unit is ready - EX_STAGE
    input logic flu_ready_i,
    // CSR buffer admission credit - EX_STAGE (OoO only)
    input logic csr_ready_i,
    // ALU output is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] alu_valid_o,
    // AES output is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] aes_valid_o,
    // Branch unit is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] branch_valid_o,
    // Transformed trap instruction - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0][31:0] tinst_o,
    // Information of branch prediction - EX_STAGE
    output branchpredict_sbe_t branch_predict_o,
    // Load store unit FU is ready - EX_STAGE
    input logic lsu_ready_i,
    // Load store unit FU is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] lsu_valid_o,
    // Mult FU is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] mult_valid_o,
    // FPU FU is ready - EX_STAGE
    input logic fpu_ready_i,
    // FPU FU will perform a writeback in the next cycle - EX_STAGE
    input logic fpu_early_valid_i,
    // FPU FU is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] fpu_valid_o,
    // FPU fmt field - EX_STAGE
    output logic [1:0] fpu_fmt_o,
    // FPU rm field - EX_STAGE
    output logic [2:0] fpu_rm_o,
    // FP-2: SMT hart of the FPU op accepted this cycle - EX_STAGE; under
    // mixed residency the issuing op's hart owns frm/fprec.
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] fpu_hart_o,
    // ALU2 FU is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] alu2_valid_o,
    // CSR is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] csr_valid_o,
    // CVXIF FU is valid - EX_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] cvxif_valid_o,
    // CVXIF is FU ready - EX_STAGE
    input logic cvxif_ready_i,
    // CVXIF offloader instruction value - EX_STAGE
    output logic [31:0] cvxif_off_instr_o,
    // G6LC Hart ID - SUBSYSTEM
    input logic [G6LCCfg.XLEN-1:0] hart_id_i,
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
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] x_id_o,
    // Destination register in the register file - COMMIT_STAGE
    input logic [G6LCCfg.NrCommitPorts-1:0][4:0] waddr_i,
    // Value to write to register file - COMMIT_STAGE
    input logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] wdata_i,
    // GPR write enable - COMMIT_STAGE
    input logic [G6LCCfg.NrCommitPorts-1:0] we_gpr_i,
    // SMT hart tag for RF write banking - COMMIT_STAGE
    input logic [G6LCCfg.NrCommitPorts-1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] whart_i,
    // FPR write enable - COMMIT_STAGE
    input logic [G6LCCfg.NrCommitPorts-1:0] we_fpr_i,
    // Issue stall - PERF_COUNTERS
    output logic stall_issue_o,
    // Information dedicated to RVFI - RVFI
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] rvfi_rs1_o,
    // Information dedicated to RVFI - RVFI
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] rvfi_rs2_o,
    // RVFI: identity of the instruction whose operands are on rvfi_rs*_o this
    // cycle. Under OoO the entry issued here is NOT the one being dispatched
    // into the scoreboard, so the tracer cannot key these by dispatch port.
    output logic [G6LCCfg.NrIssuePorts-1:0] rvfi_operand_valid_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] rvfi_operand_tid_o,
    // Original instruction bits for AES
    output logic [5:0] orig_instr_aes_bits,
    // G1gq: extra RF peek of commit JALR rs1
    input logic [4:0] g1gq_raddr_i,
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] g1gq_rhart_i,
    output logic [G6LCCfg.XLEN-1:0] g1gq_rdata_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin issue_read_operands status=proposal target=10-adjusted-FO4
  // svt-plan: cone source hazards/forwarding and FU availability determine
  // issue_ack_o; FU valid outputs already come from *_valid_q registers.
  // svt-plan: boundary operand selection -> reserved execution packet;
  // extend the existing issue register rather than adding duplicate capture.
  // svt-plan: carry instruction/TID generation, hart, FU/op, all operands,
  // PC/length, exception and RVFI operand association as one held packet.
  // svt-plan: capacity ack only against a real packet/FU reservation;
  // yesterday's ready bit is not a credit unless capacity was reserved then.
  // svt-plan: bypass form balanced priority over eligible producers and
  // preserve CSR, FP, CASQ and same-cycle forwarding restrictions.
  // svt-plan: effect separates source resolution from downstream ready
  // propagation; bounded credit logic can shorten the acknowledgement path.
  // svt-plan: cost held packets and resource accounting; extra stages change
  // dependence distance and redirect latency unless absorbed by existing capture.
  // svt-plan: limit FU completion-port scheduling must be solved with
  // ex_stage; a stale-ready approximation can lose acknowledged instructions.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 65.9 adjusted FO4 on the
  // Nangate45 board): operand read and FU issue: the issue handshake with the scoreboard is same-cycle.
  // svt-pipe: require-contract
  // svt-pipe: protocol iro valid=issue_instr_valid_i
  // svt-pipe: no-cut on=fpu_hart_n
  // svt-pipe: cycle iro q=fpu_hart_n d=fpu_valid_o hold=issue_instr_valid_i steps=1

  localparam OPERANDS_PER_INSTR = G6LCCfg.NrRgprPorts / G6LCCfg.NrIssuePorts;
  // CASQ pair-high index: only reachable when OPERANDS_PER_INSTR == 3 (the
  // procedural guards on casq_active ensure that), but slang checks indices
  // statically, so clamp the index to stay in bounds on narrower regfiles.
  localparam int unsigned CASQ_HI_IDX = OPERANDS_PER_INSTR > 2 ? 2 : 0;

  typedef struct packed {
    logic none, load, store, alu, alu2, ctrl_flow, mult, csr, fpu, fpu_vec, cvxif, accel, aes;
  } fus_busy_t;

  // hyp8 g7: spec-arm/producer-tid shadow of the issue packet (same
  // register as the FU valids below).
  logic [G6LCCfg.NrIssuePorts-1:0][1:0] spec_ab_q;
  logic [G6LCCfg.NrIssuePorts-1:0][1:0][G6LCCfg.TRANS_ID_BITS-1:0] ptid_q;

  logic [G6LCCfg.NrIssuePorts-1:0] stall_raw, stall_rs1, stall_rs2, stall_rs3;
  logic [G6LCCfg.NrIssuePorts-1:0] fu_busy;  // functional unit is busy
  fus_busy_t [G6LCCfg.NrIssuePorts-1:0] fus_busy;  // which functional units are considered busy
  logic [G6LCCfg.NrIssuePorts-1:0] issue_ack;
  // operands coming from regfile
  logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] operand_a_regfile, operand_b_regfile;
  // third operand from fp regfile or gp regfile if NR_RGPR_PORTS == 3
  rs3_len_t [G6LCCfg.NrIssuePorts-1:0] operand_c_regfile, operand_c_gpr;
  rs3_len_t operand_c_fpr;
  // output flipflop (ID <-> EX)
  fu_data_t [G6LCCfg.NrIssuePorts-1:0] fu_data_n, fu_data_q;
  logic               [        G6LCCfg.VLEN-1:0]                   pc_n;
  logic               [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] branch_hart_n;
  logic                                                            is_compressed_instr_n;
  logic                                                            is_zcmt_n;
  branchpredict_sbe_t                                              branch_predict_n;
  logic               [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] imm_forward_rs3;

  logic [G6LCCfg.NrIssuePorts-1:0] alu_valid_n, alu_valid_q;
  logic [G6LCCfg.NrIssuePorts-1:0] aes_valid_n, aes_valid_q;
  logic [G6LCCfg.NrIssuePorts-1:0] mult_valid_n, mult_valid_q;
  logic [G6LCCfg.NrIssuePorts-1:0] fpu_valid_n, fpu_valid_q;
  logic [1:0] fpu_fmt_n, fpu_fmt_q;
  logic [2:0] fpu_rm_n, fpu_rm_q;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] fpu_hart_n, fpu_hart_q;
  logic [G6LCCfg.NrIssuePorts-1:0] alu2_valid_n, alu2_valid_q;
  logic [G6LCCfg.NrIssuePorts-1:0] lsu_valid_n, lsu_valid_q;
  logic [G6LCCfg.NrIssuePorts-1:0] csr_valid_n, csr_valid_q;
  logic [G6LCCfg.NrIssuePorts-1:0] branch_valid_n, branch_valid_q;
  logic [G6LCCfg.NrIssuePorts-1:0] cvxif_valid_n, cvxif_valid_q;
  logic [31:0] cvxif_off_instr_n, cvxif_off_instr_q;
  logic                                                            cvxif_instruction_valid;

  //RAW detection
  logic [ G6LCCfg.NrIssuePorts-1:0][    G6LCCfg.TRANS_ID_BITS-1:0] idx_hzd_rs1;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs1_raw_check;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs1_has_raw;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs1_fpr;

  logic [ G6LCCfg.NrIssuePorts-1:0][    G6LCCfg.TRANS_ID_BITS-1:0] idx_hzd_rs2;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs2_raw_check;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs2_has_raw;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs2_fpr;

  logic [ G6LCCfg.NrIssuePorts-1:0][    G6LCCfg.TRANS_ID_BITS-1:0] idx_hzd_rs3;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs3_raw_check;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs3_has_raw;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs3_fpr;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs3_gpr_cvxif;


  logic [G6LCCfg.NR_SB_ENTRIES-1:0][g6lc_core_pkg::REG_ADDR_SIZE-1:0] rd_list;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                                rd_fpr;

  //fwd logic
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][             G6LCCfg.XLEN-1:0] fwd_res;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                                fwd_res_valid;

  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                                rs1_is_not_csr;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                                rs2_is_not_csr;

  logic [ G6LCCfg.NrIssuePorts-1:0][             G6LCCfg.XLEN-1:0] rs3;

  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs1_valid;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs2_valid;
  logic [ G6LCCfg.NrIssuePorts-1:0]                                rs3_valid;

  logic [ G6LCCfg.NrIssuePorts-1:0][             G6LCCfg.XLEN-1:0] rs1_res;
  logic [ G6LCCfg.NrIssuePorts-1:0][             G6LCCfg.XLEN-1:0] rs2_res;
  logic [ G6LCCfg.NrIssuePorts-1:0][             G6LCCfg.XLEN-1:0] rs3_res;

  logic [G6LCCfg.NrIssuePorts-1:0][31:0] tinst_n, tinst_q;  // transformed instruction

  // forwarding signals
  logic [G6LCCfg.NrIssuePorts-1:0] forward_rs1, forward_rs2, forward_rs3;

  // original instruction
  riscv::instruction_t [G6LCCfg.NrIssuePorts-1:0] orig_instr;
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=issue_read_operands  region=2795  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: aes_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to aes_valid_q
// order expect: alu2_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to alu2_valid_q
// order expect: alu_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to alu_valid_q
// order expect: branch_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to branch_valid_q
// order expect: csr_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to csr_valid_q
// order expect: fpu_fmt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fpu_fmt_q
// order expect: fpu_hart_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fpu_hart_q
// order expect: fpu_rm_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fpu_rm_q
// order expect: fpu_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fpu_valid_q
// order expect: lsu_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to lsu_valid_q
// order expect: mult_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to mult_valid_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     aes_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     alu2_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     alu_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     branch_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     csr_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fpu_fmt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fpu_hart_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fpu_rm_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fpu_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     lsu_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     mult_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node10282 c=3.50 slack=0.00 */
//     /* node10283 c=3.50 slack=0.00 */
//     /* node10284 c=3.50 slack=0.00 */
//     /* node10285 c=3.50 slack=0.00 */
//     /* node10286 c=3.50 slack=0.00 */
//     /* node10287 c=3.50 slack=0.00 */
//     /* node10288 c=3.50 slack=0.00 */
//     /* node10289 c=3.50 slack=0.00 */
//     /* node10290 c=3.50 slack=0.00 */
//     /* node10291 c=3.50 slack=0.00 */
//     /* node10292 c=3.50 slack=0.00 */
//     /* node10293 c=3.50 slack=0.00 */
//     /* node10294 c=3.50 slack=0.00 */
//     /* node10295 c=3.50 slack=0.00 */
//     /* node10296 c=3.50 slack=0.00 */
//     /* node10297 c=3.50 slack=0.00 */
//     /* node10298 c=3.50 slack=0.00 */
//     /* node10299 c=3.50 slack=0.00 */
//     /* node10300 c=3.50 slack=0.00 */
//     /* node10301 c=3.50 slack=0.00 */
//     /* node10302 c=3.50 slack=0.00 */
//     /* node10303 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=issue_read_operands  region=2798  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: lr_sc_pair_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to lr_sc_pair_q
// order expect: lr_sc_tid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to lr_sc_tid_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     lr_sc_pair_q <= …; // sv-timing: cycle 1/1 on clk_i
//     lr_sc_tid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node10320 c=3.50 slack=0.00 */
//     /* node10321 c=3.50 slack=0.00 */
//     /* node10322 c=3.50 slack=0.00 */
//     /* node10323 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=issue_read_operands  region=2806  makespan=10.500 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: casq_exp_hi_q  ready_cycle=2  ready_fo4=10.500  OpenSTA: report_timing -from clk_i -to casq_exp_hi_q
// order expect: casq_exp_lo_q  ready_cycle=2  ready_fo4=10.500  OpenSTA: report_timing -from clk_i -to casq_exp_lo_q
// order expect: casq_new_hi_q  ready_cycle=2  ready_fo4=10.500  OpenSTA: report_timing -from clk_i -to casq_new_hi_q
// order expect: casq_new_lo_q  ready_cycle=2  ready_fo4=10.500  OpenSTA: report_timing -from clk_i -to casq_new_lo_q
// order expect: casq_phase_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to casq_phase_q
// order expect: casq_ready_q  ready_cycle=2  ready_fo4=10.500  OpenSTA: report_timing -from clk_i -to casq_ready_q
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node10341 c=3.50 slack=7.00 */
//     /* node10342 c=3.50 slack=7.00 */
//     /* node10343 c=3.50 slack=7.00 */
//     /* node10344 c=3.50 slack=7.00 */
//     /* node10345 c=3.50 slack=7.00 */
//     /* node10346 c=3.50 slack=7.00 */
//     /* node10347 c=4.50 slack=6.00 */
//     /* node10348 c=4.50 slack=6.00 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     casq_exp_hi_q <= …; // sv-timing: cycle 2/2 on clk_i
//     casq_exp_lo_q <= …; // sv-timing: cycle 2/2 on clk_i
//     casq_new_hi_q <= …; // sv-timing: cycle 2/2 on clk_i
//     casq_new_lo_q <= …; // sv-timing: cycle 2/2 on clk_i
//     casq_phase_q <= …; // sv-timing: cycle 2/2 on clk_i
//     casq_ready_q <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node10349 c=9.50 slack=1.00 */
//     /* node10350 c=9.50 slack=1.00 */
//     /* node10351 c=9.50 slack=1.00 */
//     /* node10352 c=10.50 slack=0.00 */
//     /* node10353 c=10.50 slack=0.00 */
//     /* node10354 c=10.50 slack=0.00 */
//     /* node10355 c=10.50 slack=0.00 */
//     /* node10356 c=10.50 slack=0.00 */
//     /* node10357 c=10.50 slack=0.00 */
//     /* node10358 c=9.50 slack=1.00 */
//     /* node10359 c=9.50 slack=1.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=issue_read_operands  region=2820  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: alu_bypass_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to alu_bypass_q
// order expect: branch_hart_o  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to branch_hart_o
// order expect: branch_predict_o  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to branch_predict_o
// order expect: fu_data_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fu_data_q
// order expect: is_compressed_instr_o  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to is_compressed_instr_o
// order expect: is_zcmt_o  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to is_zcmt_o
// order expect: orig_instr_aes_bits  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to orig_instr_aes_bits
// order expect: pc_o  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to pc_o
// order expect: tinst_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to tinst_q
// order expect: x_transaction_rejected_o  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to x_transaction_rejected_o
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     alu_bypass_q <= …; // sv-timing: cycle 1/1 on clk_i
//     branch_hart_o <= …; // sv-timing: cycle 1/1 on clk_i
//     branch_predict_o <= …; // sv-timing: cycle 1/1 on clk_i
//     fu_data_q <= …; // sv-timing: cycle 1/1 on clk_i
//     is_compressed_instr_o <= …; // sv-timing: cycle 1/1 on clk_i
//     is_zcmt_o <= …; // sv-timing: cycle 1/1 on clk_i
//     orig_instr_aes_bits <= …; // sv-timing: cycle 1/1 on clk_i
//     pc_o <= …; // sv-timing: cycle 1/1 on clk_i
//     tinst_q <= …; // sv-timing: cycle 1/1 on clk_i
//     x_transaction_rejected_o <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node10394 c=3.50 slack=0.00 */
//     /* node10395 c=0.00 slack=3.50 */
//     /* node10396 c=3.50 slack=0.00 */
//     /* node10397 c=3.50 slack=0.00 */
//     /* node10398 c=3.50 slack=0.00 */
//     /* node10399 c=3.50 slack=0.00 */
//     /* node10400 c=3.50 slack=0.00 */
//     /* node10401 c=3.50 slack=0.00 */
//     /* node10402 c=3.50 slack=0.00 */
//     /* node10403 c=3.50 slack=0.00 */
//     /* node10404 c=3.50 slack=0.00 */
//     /* node10405 c=3.50 slack=0.00 */
//     /* node10406 c=0.00 slack=3.50 */
//     /* node10407 c=3.50 slack=0.00 */
//     /* node10408 c=3.50 slack=0.00 */
//     /* node10409 c=3.50 slack=0.00 */
//     /* node10410 c=3.50 slack=0.00 */
//     /* node10411 c=3.50 slack=0.00 */
//     /* node10412 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign orig_instr[i] = riscv::instruction_t'(orig_instr_i[i]);
  end

  // ALU-ALU bypass signals
  alu_bypass_t alu_bypass, alu_bypass_n, alu_bypass_q;
  logic is_alu_bypass;
  logic [G6LCCfg.NrIssuePorts-1:0] use_alu2;

  // CVXIF Signals
  logic cvxif_req_allowed;
  logic x_transaction_rejected, x_transaction_rejected_n;
  logic [OPERANDS_PER_INSTR-1:0] rs_valid;
  logic [OPERANDS_PER_INSTR-1:0][G6LCCfg.XLEN-1:0] rs;

  cvxif_issue_register_commit_if_driver #(
      .G6LCCfg       (G6LCCfg),
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
  // Port 0 only, and check_cfg forbids CvxifEn with NrIssuePorts>1: a CVXIF op
  // arriving on any other port would never be offered to the coprocessor.
  assign cvxif_req_allowed = (issue_instr_i[0].fu == CVXIF);
  assign cvxif_instruction_valid = !issue_instr_i[0].ex.valid && issue_instr_valid_i[0] && cvxif_req_allowed;
  assign x_transaction_accepted_o = x_issue_valid_o && x_issue_ready_i && x_issue_resp_i.accept;
  assign x_transaction_rejected = x_issue_valid_o && x_issue_ready_i && ~x_issue_resp_i.accept;
  assign x_issue_writeback_o = x_issue_resp_i.writeback;
  assign x_id_o = x_issue_req_o.id;

  // ID <-> EX registers

  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    assign rs1_forwarding_o[i] = fu_data_n[i].operand_a[G6LCCfg.VLEN-1:0];  //forwarding or unregistered rs1 value
    assign rs2_forwarding_o[i] = fu_data_n[i].operand_b[G6LCCfg.VLEN-1:0];  //forwarding or unregistered rs2 value
    assign rvfi_rs1_o[i] = fu_data_n[i].operand_a;
    assign rvfi_rs2_o[i] = fu_data_n[i].operand_b;
    assign rvfi_operand_valid_o[i] = issue_ack_o[i];
    assign rvfi_operand_tid_o[i] = issue_instr_i[i].trans_id;
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
  assign fpu_hart_o = fpu_hart_q;
  assign alu2_valid_o = alu2_valid_q;
  assign cvxif_valid_o = G6LCCfg.CvxifEn ? cvxif_valid_q : '0;
  assign cvxif_off_instr_o = G6LCCfg.CvxifEn ? cvxif_off_instr_q : '0;

  // pragma translate_off
  // Port-0 steering contract (config_pkg check_cfg relies on it): a CVXIF-class
  // instruction is never issued from a port other than 0, whatever the issue width.
  // Its illegal-instruction trap therefore always reaches the coprocessor handshake.
  if (G6LCCfg.CvxifEn && G6LCCfg.NrIssuePorts > 1) begin : gen_cvxif_port0_contract
    always_ff @(posedge clk_i) if (rst_ni) begin
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        assert (!cvxif_valid_o[p])
          else $error("issue_read_operands: CVXIF instruction issued from port %0d (port-0 steering broken)", p);
        assert (!(issue_instr_valid_i[p] && issue_ack_o[p] && issue_instr_i[p].fu == CVXIF))
          else $error("issue_read_operands: CVXIF instruction acknowledged on port %0d", p);
      end
    end
  end
  // pragma translate_on
  assign stall_issue_o = stall_raw[0];
  assign tinst_o = G6LCCfg.RVH ? tinst_q : '0;

  // ALU bypass signals (port0→port1 only; requires at least dual-issue)
  if (G6LCCfg.ALUBypass && G6LCCfg.NrIssuePorts > 1) begin
    assign is_alu_bypass =
      (issue_instr_i[0].fu == ALU && issue_instr_i[1].fu == ALU) &&
      !((issue_instr_i[0].op inside {CPOP, CPOPW}) || (issue_instr_i[1].op inside {CPOP, CPOPW}));
  end else begin
    assign is_alu_bypass = 1'b0;
  end

  if (G6LCCfg.SuperscalarEn && G6LCCfg.NrALUs >= 2 && G6LCCfg.NrIssuePorts > 1) begin
    // Prefer secondary ALU unless bypass / FPU on port 1 forces primary.
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
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

    // OoO: the CSR buffer holds two outstanding entries, so csr_ready is a
    // table credit and no longer rides flu_ready_i (which would block ALU/CF).
    if (G6LCCfg.OoOEn && !csr_ready_i) fus_busy[0].csr = 1'b1;

    // after a multiplication was issued we can only issue another multiplication
    // otherwise we will get contentions on the fixed latency bus
    if (|mult_valid_q) begin
      fus_busy[0].alu = 1'b1;
      fus_busy[0].aes = 1'b1;
      fus_busy[0].ctrl_flow = 1'b1;
      fus_busy[0].csr = 1'b1;
    end

    if (G6LCCfg.FpPresent && !fpu_ready_i) begin
      fus_busy[0].fpu = 1'b1;
      fus_busy[0].fpu_vec = 1'b1;
    end

    if (!lsu_ready_i) begin
      fus_busy[0].load  = 1'b1;
      fus_busy[0].store = 1'b1;
    end

    if (G6LCCfg.SuperscalarEn) begin
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
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        fus_busy[p] = fus_busy[p-1];

        // CSR / CVXIF only on port 0
        fus_busy[p].csr   = 1'b1;
        fus_busy[p].cvxif = 1'b1;

        unique case (issue_instr_i[p-1].fu)
          NONE: fus_busy[p].none = 1'b1;
          CTRL_FLOW: begin
            // Full post-CF serialize under SS (jal/ret RA poison under partial).
            if (G6LCCfg.SuperscalarEn) begin
              fus_busy[p] = '1;
            end else if (issue_instr_i[p-1].op == g6lc_core_pkg::ADD) begin
              fus_busy[p].alu = 1'b1;
              fus_busy[p].ctrl_flow = 1'b1;
              fus_busy[p].csr = 1'b1;
            end else begin
              fus_busy[p] = '1;
            end
          end
          ALU: begin
            // One ALU issue/cycle under SS until dual-WB clean on OpenSBI.
            if (G6LCCfg.SuperscalarEn) begin
              fus_busy[p] = '1;
            end else if (use_alu2[p-1] && G6LCCfg.NrALUs >= 2) begin
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
            if (G6LCCfg.SuperscalarEn) fus_busy[p] = '1;
          end
          FPU, FPU_VEC: begin
            fus_busy[p].fpu = 1'b1;
            fus_busy[p].fpu_vec = 1'b1;
            if (issue_instr_i[p].op inside {[FLD : FSB]}) begin
              fus_busy[p].load  = 1'b1;
              fus_busy[p].store = 1'b1;
            end
            if (G6LCCfg.SuperscalarEn) fus_busy[p] = '1;
          end
          LOAD, STORE: begin
            // Includes AMO (STORE FU). Full LSU serialize under SS.
            fus_busy[p].load  = 1'b1;
            fus_busy[p].store = 1'b1;
            if (issue_instr_i[p-1].op inside {[FLD : FSB]}) begin
              fus_busy[p].fpu = 1'b1;
              fus_busy[p].fpu_vec = 1'b1;
            end
            if (G6LCCfg.SuperscalarEn) begin
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
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    always_comb begin
      unique case (issue_instr_i[i].fu)
        NONE: fu_busy[i] = fus_busy[i].none;
        ALU: begin
          if (G6LCCfg.SuperscalarEn && use_alu2[i]) begin
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
        if (G6LCCfg.FpPresent) begin
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

  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    assign rs1_fpr[i] = (G6LCCfg.FpPresent && g6lc_core_pkg::is_rs1_fpr(issue_instr_i[i].op));
    assign rs2_fpr[i] = (G6LCCfg.FpPresent && g6lc_core_pkg::is_rs2_fpr(issue_instr_i[i].op));
    assign rs3_fpr[i] = (G6LCCfg.FpPresent && g6lc_core_pkg::is_imm_fpr(issue_instr_i[i].op));
    // Third GPR source: CVXIF offload or Zacas AMOCAS (rd = expected)
    assign rs3_gpr_cvxif[i] = (OPERANDS_PER_INSTR == 3) && (
        (G6LCCfg.CvxifEn && issue_instr_i[i].op == OFFLOAD) ||
        (G6LCCfg.RVZacas && g6lc_core_pkg::is_amo_cas(issue_instr_i[i].op))
    );
  end

  // ----------------------------------
  // Renaming
  // ----------------------------------
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] rd_hart;
  for (genvar i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
    assign rd_list[i] = fwd_i.sbe[i].rd;
    assign rd_fpr[i]  = G6LCCfg.FpPresent && g6lc_core_pkg::is_rd_fpr(fwd_i.sbe[i].op);
    assign rd_hart[i] = fwd_i.sbe[i].hart_id;
  end

  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_raw_checks
    raw_checker #(
        .G6LCCfg(G6LCCfg)
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
        .G6LCCfg(G6LCCfg)
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
        .G6LCCfg(G6LCCfg)
    ) i_rs3_last_raw (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .rs_i(issue_instr_i[i].result[g6lc_core_pkg::REG_ADDR_SIZE-1:0]),
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
  // Per scoreboard slot, constant index. The old loop wrote
  // fwd_res[wb.trans_id], a variable index of the whole vector. The highest
  // matching writeback port wins, same as the ascending overwrite. AMO still
  // clears valid after that forward. hyp8 has four writeback ports.
  for (genvar s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin : gen_fwd_slot
    logic [G6LCCfg.NrWbPorts-1:0] wb_hit;
    logic [2:0] fwd_src;
    logic [31:0] fwd_hi, fwd_lo;
    logic v_raw;
    for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_wb_hit
      assign wb_hit[w] = fwd_i.wb[w].valid && !fwd_i.wb[w].ex_valid &&
                         (fwd_i.wb[w].trans_id == s);
    end
    always_comb begin
      fwd_src = 3'd7;
      for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
        if (wb_hit[w]) fwd_src = 3'(w);
    end
    always_comb begin
      unique case (fwd_src)
        3'd0:    fwd_hi = fwd_i.wb[0].data[63:32];
        3'd1:    fwd_hi = fwd_i.wb[1].data[63:32];
        3'd2:    fwd_hi = fwd_i.wb[2].data[63:32];
        3'd3:    fwd_hi = fwd_i.wb[3].data[63:32];
        default: fwd_hi = fwd_i.sbe[s].result[63:32];
      endcase
    end
    always_comb begin
      unique case (fwd_src)
        3'd0:    fwd_lo = fwd_i.wb[0].data[31:0];
        3'd1:    fwd_lo = fwd_i.wb[1].data[31:0];
        3'd2:    fwd_lo = fwd_i.wb[2].data[31:0];
        3'd3:    fwd_lo = fwd_i.wb[3].data[31:0];
        default: fwd_lo = fwd_i.sbe[s].result[31:0];
      endcase
    end
    assign fwd_res[s] = {fwd_hi, fwd_lo};
    assign v_raw = (fwd_src != 3'd7) ||
                   (fwd_i.sbe[s].valid & ~fwd_i.sbe[s].ex.valid);
    assign fwd_res_valid[s] = v_raw &&
        !(G6LCCfg.RVA && g6lc_core_pkg::is_amo(fwd_i.sbe[s].op));
  end

  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    assign rs1_res[i] = fwd_res[idx_hzd_rs1[i]];
    assign rs1_is_not_csr[i] = rs1_fpr[i] || (fwd_i.sbe[idx_hzd_rs1[i]].fu != g6lc_core_pkg::CSR) || (G6LCCfg.RVS && issue_instr_i[i].op == g6lc_core_pkg::SFENCE_VMA);
    assign rs1_valid[i] = fwd_res_valid[idx_hzd_rs1[i]] && rs1_is_not_csr[i];

    assign rs2_res[i] = fwd_res[idx_hzd_rs2[i]];
    assign rs2_is_not_csr[i] = rs2_fpr[i] || (fwd_i.sbe[idx_hzd_rs2[i]].fu != g6lc_core_pkg::CSR) || (G6LCCfg.RVS && issue_instr_i[i].op == g6lc_core_pkg::SFENCE_VMA);
    assign rs2_valid[i] = fwd_res_valid[idx_hzd_rs2[i]] && rs2_is_not_csr[i];

    assign rs3[i] = fwd_res[idx_hzd_rs3[i]];
    assign rs3_valid[i] = fwd_res_valid[idx_hzd_rs3[i]];

    if (G6LCCfg.NrRgprPorts == 3) begin
      assign rs3_res[i] = rs3[i][G6LCCfg.XLEN-1:0];
    end else begin
      assign rs3_res[i] = rs3[i][G6LCCfg.FLen-1:0];
    end
  end

  // ---------------
  // Register stage
  // ---------------
  // check that all operands are available, otherwise stall
  // forward corresponding register
  // hyp8: accumulate form -- the emit's per-loop `stall_*[i] = 1` sets
  // serialized into one patch chain. Every bit below is a single OR of
  // precomputed condition masks (same semantics: the sets never cleared
  // except the documented CVXIF/JALR overrides).
  logic [G6LCCfg.NrIssuePorts-1:0] oa_en;
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_oaen
    // U5: renamed ops already waited in IQ -- PRF is authoritative; skip
    // the arch-RAW stall/forward section entirely for that port.
    assign oa_en[i] = !(G6LCCfg.OoOEn && issue_instr_i[i].ooo_renamed);
  end

`ifndef G6LC_FETCH_B
  // G1o/G1an/G1ea keep conditions as compare masks (SMT+SS only).
  logic [G6LCCfg.NrIssuePorts-1:0] k_jal, k_asp, e_asp;
  logic [G6LCCfg.NrIssuePorts-1:0] k_ld1, k_ld2, e_ld1, e_ld2;
  logic [G6LCCfg.NrIssuePorts-1:0] k_cs1, k_cs2, e_cs1, e_cs2;
  if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1) begin : gen_hkeep
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_hkp
      logic [G6LCCfg.NR_SB_ENTRIES-1:0] m_jal, m_asp, m_ld1, m_ld2,
                                        m_cs1, m_cs2;
      logic [G6LCCfg.NrIssuePorts-1:0]  me_asp, me_ld1, me_ld2,
                                        me_cs1, me_cs2;
      for (genvar k = 0; k < G6LCCfg.NR_SB_ENTRIES; k++) begin : gen_km
        logic live_k;
        assign live_k = fwd_i.still_issued[k] || fwd_i.sbe[k].valid;
        assign m_jal[k] = live_k &&
            fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id &&
            fwd_i.sbe[k].fu == g6lc_core_pkg::CTRL_FLOW &&
            fwd_i.sbe[k].rd[4:0] == 5'd1;
        assign m_asp[k] = live_k &&
            fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id &&
            g6lc_sb_keep::addi_sp(
                fwd_i.sbe[k].fu,
                fwd_i.sbe[k].rd[4:0],
                fwd_i.sbe[k].rs1[4:0]);
        assign m_ld1[k] = !fwd_i.still_issued[k] && fwd_i.sbe[k].valid &&
            fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id &&
            fwd_i.sbe[k].fu == g6lc_core_pkg::LOAD &&
            fwd_i.sbe[k].rd[4:0] != 5'd0 &&
            fwd_i.sbe[k].rd == issue_instr_i[i].rs1;
        assign m_ld2[k] = !fwd_i.still_issued[k] && fwd_i.sbe[k].valid &&
            fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id &&
            fwd_i.sbe[k].fu == g6lc_core_pkg::LOAD &&
            fwd_i.sbe[k].rd[4:0] != 5'd0 &&
            fwd_i.sbe[k].rd == issue_instr_i[i].rs2;
        assign m_cs1[k] = live_k &&
            fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id &&
            fwd_i.sbe[k].fu == g6lc_core_pkg::CSR &&
            fwd_i.sbe[k].rd[4:0] != 5'd0 &&
            fwd_i.sbe[k].rd == issue_instr_i[i].rs1;
        assign m_cs2[k] = live_k &&
            fwd_i.sbe[k].hart_id == issue_instr_i[i].hart_id &&
            fwd_i.sbe[k].fu == g6lc_core_pkg::CSR &&
            fwd_i.sbe[k].rd[4:0] != 5'd0 &&
            fwd_i.sbe[k].rd == issue_instr_i[i].rs2;
      end
      for (genvar e = 0; e < G6LCCfg.NrIssuePorts; e++) begin : gen_em
        logic e_same;
        assign e_same = (e < i) && issue_instr_valid_i[e] &&
            issue_instr_i[e].hart_id == issue_instr_i[i].hart_id;
        assign me_asp[e] = e_same &&
            g6lc_sb_keep::addi_sp(
                issue_instr_i[e].fu,
                issue_instr_i[e].rd[4:0],
                issue_instr_i[e].rs1[4:0]);
        assign me_ld1[e] = e_same &&
            issue_instr_i[e].fu == g6lc_core_pkg::LOAD &&
            issue_instr_i[e].rd[4:0] != 5'd0 &&
            issue_instr_i[e].rd == issue_instr_i[i].rs1;
        assign me_ld2[e] = e_same &&
            issue_instr_i[e].fu == g6lc_core_pkg::LOAD &&
            issue_instr_i[e].rd[4:0] != 5'd0 &&
            issue_instr_i[e].rd == issue_instr_i[i].rs2;
        assign me_cs1[e] = e_same &&
            issue_instr_i[e].fu == g6lc_core_pkg::CSR &&
            issue_instr_i[e].rd[4:0] != 5'd0 &&
            issue_instr_i[e].rd == issue_instr_i[i].rs1;
        assign me_cs2[e] = e_same &&
            issue_instr_i[e].fu == g6lc_core_pkg::CSR &&
            issue_instr_i[e].rd[4:0] != 5'd0 &&
            issue_instr_i[e].rd == issue_instr_i[i].rs2;
      end
      assign k_jal[i] = |m_jal;
      assign k_asp[i] = |m_asp;
      assign e_asp[i] = |me_asp;
      assign k_ld1[i] = |m_ld1;
      assign k_ld2[i] = |m_ld2;
      assign e_ld1[i] = |me_ld1;
      assign e_ld2[i] = |me_ld2;
      assign k_cs1[i] = |m_cs1;
      assign k_cs2[i] = |m_cs2;
      assign e_cs1[i] = |me_cs1;
      assign e_cs2[i] = |me_cs2;
    end
  end else begin : gen_hkeep_off
    assign k_jal = '0; assign k_asp = '0; assign e_asp = '0;
    assign k_ld1 = '0; assign k_ld2 = '0; assign e_ld1 = '0; assign e_ld2 = '0;
    assign k_cs1 = '0; assign k_cs2 = '0; assign e_cs1 = '0; assign e_cs2 = '0;
  end
`else
  logic [G6LCCfg.NrIssuePorts-1:0] k_jal, k_asp, e_asp;
  logic [G6LCCfg.NrIssuePorts-1:0] k_ld1, k_ld2, e_ld1, e_ld2;
  logic [G6LCCfg.NrIssuePorts-1:0] k_cs1, k_cs2, e_cs1, e_cs2;
  assign k_jal = '0; assign k_asp = '0; assign e_asp = '0;
  assign k_ld1 = '0; assign k_ld2 = '0; assign e_ld1 = '0; assign e_ld2 = '0;
  assign k_cs1 = '0; assign k_cs2 = '0; assign e_cs1 = '0; assign e_cs2 = '0;
`endif

  // I11/G1gu: JALR base usability (SMT+SS only).
  logic [G6LCCfg.NrIssuePorts-1:0] j_cond, j_clr, j_stall;
  // hyp8 NrHarts is 1, so this arm is not live. The struct compare does not
  // fold and the usable() variable shift was the 17.5 node on the forward cone.
  if (1'b0) begin : gen_jalr
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_jalr_p
      logic f_ok, r_ok;
      assign j_cond[i] = issue_instr_i[i].op == g6lc_core_pkg::JALR;
      assign f_ok = rs1_has_raw[i] && rs1_valid[i] &&
                    g6lc_jalr_usable::usable(
                        G6LCCfg, G6LCCfg.VLEN, 64'(rs1_res[i]));
      assign r_ok = g6lc_jalr_usable::usable(
                        G6LCCfg, G6LCCfg.VLEN, 64'(operand_a_regfile[i]));
      // forward kept iff the SB forward is usable; otherwise cleared.
      assign j_clr[i]   = j_cond[i] && !f_ok;
      assign j_stall[i] = j_cond[i] && !f_ok && !r_ok;
    end
  end else begin : gen_jalr_off
    assign j_cond = '0;
    assign j_clr  = '0;
    assign j_stall = '0;
  end

  // Same-cycle RAW across earlier issue ports + ALU bypass (0->1 only).
  logic [G6LCCfg.NrIssuePorts-1:0] ss_raw;
  logic                            ss_bp1, ss_bp2;
  if (G6LCCfg.SuperscalarEn && G6LCCfg.NrIssuePorts > 1) begin : gen_ssraw
    assign ss_bp1 = is_alu_bypass &&
        !issue_instr_i[1].use_zimm &&
        (!G6LCCfg.FpPresent ||
         (is_rs1_fpr(issue_instr_i[1].op) == is_rd_fpr(issue_instr_i[0].op))) &&
        issue_instr_i[1].rs1 == issue_instr_i[0].rd &&
        issue_instr_i[1].rs1 != '0;
    assign ss_bp2 = is_alu_bypass &&
        (!G6LCCfg.FpPresent ||
         (is_rs2_fpr(issue_instr_i[1].op) == is_rd_fpr(issue_instr_i[0].op))) &&
        issue_instr_i[1].rs2 == issue_instr_i[0].rd &&
        issue_instr_i[1].rs2 != '0;
    for (genvar p = 1; p < G6LCCfg.NrIssuePorts; p++) begin : gen_ssp
      logic [G6LCCfg.NrIssuePorts-1:0] m_r1, m_r2, m_r3;
      for (genvar e = 0; e < G6LCCfg.NrIssuePorts; e++) begin : gen_sse
        logic c1, c2, c3;
        assign c1 = (e < p) &&
            !issue_instr_i[p].use_zimm &&
            (!G6LCCfg.FpPresent ||
             (is_rs1_fpr(issue_instr_i[p].op) ==
              is_rd_fpr(issue_instr_i[e].op))) &&
            issue_instr_i[p].rs1 == issue_instr_i[e].rd &&
            issue_instr_i[p].rs1 != '0;
        assign c2 = (e < p) &&
            (!G6LCCfg.FpPresent ||
             (is_rs2_fpr(issue_instr_i[p].op) ==
              is_rd_fpr(issue_instr_i[e].op))) &&
            issue_instr_i[p].rs2 == issue_instr_i[e].rd &&
            issue_instr_i[p].rs2 != '0;
        assign c3 = (e < p) &&
            ((G6LCCfg.FpPresent && is_imm_fpr(issue_instr_i[p].op)) ?
                is_rd_fpr(issue_instr_i[e].op) &&
                issue_instr_i[e].rd ==
                    issue_instr_i[p].result[REG_ADDR_SIZE-1:0] :
                issue_instr_i[p].op == OFFLOAD && OPERANDS_PER_INSTR == 3 ?
                issue_instr_i[e].rd ==
                    issue_instr_i[p].result[REG_ADDR_SIZE-1:0] : 1'b0);
        assign m_r1[e] = c1 && !(is_alu_bypass && e == 0 && p == 1);
        assign m_r2[e] = c2 && !(is_alu_bypass && e == 0 && p == 1);
        assign m_r3[e] = c3;
      end
      assign ss_raw[p] = |m_r1 || |m_r2 || |m_r3;
    end
    assign ss_raw[0] = 1'b0;
  end else begin : gen_ssraw_off
    assign ss_raw = '0;
    assign ss_bp1 = 1'b0;
    assign ss_bp2 = 1'b0;
  end

  // Stall OR is a tree of named terms. One statement of every raw/load/CSR
  // term was the 17 FO4 field on the operand-forward cone.
  logic [G6LCCfg.NrIssuePorts-1:0] stall_raw_w;
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_sraw
    logic st2_i, rs_bad, st_bad, ld_bad, cs_bad;
    assign st2_i  = issue_instr_i[i].fu == g6lc_core_pkg::STORE &&
                    issue_instr_i[i].rs2[4:0] == 5'd1;
    assign rs_bad = (rs1_has_raw[i] && !rs1_valid[i]) ||
                    (rs2_has_raw[i] && !rs2_valid[i]) ||
                    (rs3_has_raw[i] && !rs3_valid[i]);
    assign st_bad = st2_i && (k_jal[i] || k_asp[i] || e_asp[i]);
    assign ld_bad = k_ld1[i] || e_ld1[i] || k_ld2[i] || e_ld2[i];
    assign cs_bad = k_cs1[i] || e_cs1[i] || k_cs2[i] || e_cs2[i];
    assign stall_raw_w[i] = stall_i || (oa_en[i] && (rs_bad || st_bad || ld_bad ||
                              cs_bad || j_stall[i])) || ss_raw[i];
  end

  always_comb begin : operands_available
    logic [G6LCCfg.NrIssuePorts-1:0] s_raw, s_r1, s_r2, s_r3,
                                   f_r1, f_r2, f_r3;
    for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
      logic en_i, st2_i;
      en_i  = oa_en[i];
      st2_i = issue_instr_i[i].fu == g6lc_core_pkg::STORE &&
              issue_instr_i[i].rs2[4:0] == 5'd1;
      f_r1[i] = en_i && rs1_has_raw[i] && rs1_valid[i] && !j_clr[i];
      f_r2[i] = en_i && rs2_has_raw[i] && rs2_valid[i];
      f_r3[i] = en_i && rs3_has_raw[i] && rs3_valid[i];
      s_r1[i] = stall_i || (en_i && (
          (rs1_has_raw[i] && !rs1_valid[i]) ||
          (st2_i && (k_asp[i] || e_asp[i])) ||
          k_ld1[i] || e_ld1[i] || k_cs1[i] || e_cs1[i] ||
          j_stall[i]));
      s_r2[i] = stall_i || (en_i && (
          (rs2_has_raw[i] && !rs2_valid[i]) ||
          (st2_i && k_jal[i]) ||
          k_ld2[i] || e_ld2[i] || k_cs2[i] || e_cs2[i]));
      s_r3[i] = stall_i || (en_i &&
          (rs3_has_raw[i] && !rs3_valid[i]));
      s_raw[i] = stall_raw_w[i];
    end

    // CVXIF port-0 adjustments (last writer in the emit).
    forward_rs1 = f_r1;
    forward_rs2 = f_r2;
    forward_rs3 = f_r3;
    stall_rs1   = s_r1;
    stall_rs2   = s_r2;
    stall_rs3   = s_r3;
    stall_raw   = s_raw;
    if (G6LCCfg.CvxifEn) begin
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

    alu_bypass            = '0;
    alu_bypass.rs1_from_rd = ss_bp1;
    alu_bypass.rs2_from_rd = ss_bp2;
  end

  // third operand from fp regfile or gp regfile if NR_RGPR_PORTS == 3
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    if (OPERANDS_PER_INSTR == 3) begin : gen_gp_rs3
      assign imm_forward_rs3[i] = rs3_res[i];
    end else begin : gen_fp_rs3
      assign imm_forward_rs3[i] = {{G6LCCfg.XLEN - G6LCCfg.FLen{1'b0}}, rs3_res[i]};
    end
  end

  // AMOCAS.Q: 2-phase RF gather for register pairs (rd/rd+1, rs2/rs2+1)
  logic casq_phase_q, casq_phase_d;
  logic [G6LCCfg.XLEN-1:0] casq_new_lo_q, casq_exp_lo_q;
  logic [G6LCCfg.XLEN-1:0] casq_new_hi_q, casq_exp_hi_q;
  logic casq_active;
  assign casq_active = G6LCCfg.RVZacas && issue_instr_valid_i[0] &&
                       (issue_instr_i[0].op == g6lc_core_pkg::AMO_CASQ);
  logic casq_ready_q;
  logic casq_stall;
  // Stall until both pair halves are latched (casq_ready_q). Do not issue on
  // phase1: raddr is remapped to hi so live RF lo would be wrong.
  assign casq_stall = casq_active && (OPERANDS_PER_INSTR == 3) && !casq_ready_q
                      && !issue_instr_i[0].ex.valid;

  // Forwarding/Output MUX
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
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
      if (G6LCCfg.RVZacas && g6lc_core_pkg::is_amo_cas(issue_instr_i[i].op) && OPERANDS_PER_INSTR == 3) begin
        fu_data_n[i].imm = '0;
        fu_data_n[i].operand_c = operand_c_regfile[i];
      end else if (OPERANDS_PER_INSTR == 3) begin
        fu_data_n[i].imm = (G6LCCfg.FpPresent && is_imm_fpr(issue_instr_i[i].op)) ?
            {{G6LCCfg.XLEN - G6LCCfg.FLen{1'b0}}, operand_c_regfile[i]} :
            issue_instr_i[i].op == OFFLOAD ? operand_c_regfile[i] : issue_instr_i[i].result;
      end else begin
        fu_data_n[i].imm = (G6LCCfg.FpPresent && is_imm_fpr(issue_instr_i[i].op)) ?
            {{G6LCCfg.XLEN - G6LCCfg.FLen{1'b0}}, operand_c_regfile[i]} : issue_instr_i[i].result;
      end
      fu_data_n[i].trans_id  = issue_instr_i[i].trans_id;
      // T6b: carry the issuing instruction's hart so the LSU can tag the
      // store's speculative-buffer entry and the load's forward query.
      fu_data_n[i].hart      = issue_instr_i[i].hart_id;
      fu_data_n[i].fu        = issue_instr_i[i].fu;
      fu_data_n[i].operation = issue_instr_i[i].op;
      if (G6LCCfg.RVH) begin
        tinst_n[i] = issue_instr_i[i].ex.tinst;
      end

      // or should we forward
      if (forward_rs1[i]) begin
        fu_data_n[i].operand_a = rs1_res[i];
      end
      // I17: B never picks forwarded vs RF by inspecting the value.
      // I4by / G1k / G1gg / G1h stay A-only (LEDGER). FDT offset_ptr /
      // c.lw fdt+0x28 / c.mv a0↔s* were the named sites.
`ifndef G6LC_FETCH_B
      // I4by: offset_ptr `c.add a0,a1` (rd==x10 && rs1==x10 && rs2==x11 &&
      // !use_imm). No a0-dest between last `lbu 38(a0)` and that add. A
      // forwarded page-0 a0 (wrong-port / leftover `c.li a0,0`) makes
      // fdt+offset = 9 (PEEL c.lw@129f8 mtval=9). Fall back to RF.
      // SMT+SS only. SI: NrHarts==1 const-folds the guard.
      // G0 LOAD/STORE small_nz forward drop hold-FAIL 2026-08-15 — reverted.
      if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
          forward_rs1[i] &&
          issue_instr_i[i].fu == g6lc_core_pkg::ALU &&
          !issue_instr_i[i].use_imm &&
          issue_instr_i[i].rd == 5'd10 &&
          issue_instr_i[i].rs1[4:0] == 5'd10 &&
          issue_instr_i[i].rs2[4:0] == 5'd11 &&
          rs1_res[i][G6LCCfg.XLEN-1:12] == '0) begin
        fu_data_n[i].operand_a = operand_a_regfile[i];
      end
      // G1k: LOAD address. P4 c.lw of fdt+0x28 retired a5=0x010dfeec
      // (DRAM word is 1). Architectural a0 was s2+0x28; a leftover
      // non-cached forward (magic/assemble) can still feed the LSU.
      // If RF is already a cached pointer, do not replace it with a
      // non-cached forward. Not G0 (no stall). Not G1i. SMT+SS only.
      if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
          forward_rs1[i] &&
          issue_instr_i[i].fu == g6lc_core_pkg::LOAD &&
          config_pkg::is_inside_cacheable_regions(
              G6LCCfg, 64'(operand_a_regfile[i])) &&
          !config_pkg::is_inside_cacheable_regions(
              G6LCCfg, 64'(rs1_res[i]))) begin
        fu_data_n[i].operand_a = operand_a_regfile[i];
      end
      // G1gg: jalr prefers usable RF rs1 over
      // an unusable forward. No stall (G1gf
      // HOLD-FAIL hung OpenSBI). Not G0. SMT+SS.
      if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
          issue_instr_i[i].op == g6lc_core_pkg::JALR &&
          forward_rs1[i] &&
          !g6lc_jalr_usable::usable(
              G6LCCfg, G6LCCfg.VLEN, 64'(rs1_res[i])) &&
          g6lc_jalr_usable::usable(
              G6LCCfg, G6LCCfg.VLEN, 64'(operand_a_regfile[i]))) begin
        fu_data_n[i].operand_a = operand_a_regfile[i];
      end
`endif
      if (forward_rs2[i]) begin
        fu_data_n[i].operand_b = rs2_res[i];
      end
      // G1h: c.mv a0↔s* (rd/rs2 ABI pointer copy). A forwarded
      // execute-region base (boot 0x80000000) made s0=_start, so
      // offset_ptr's 2nd load_be32 assembled _start+8 (mini 0x32,
      // leftover a0=0xB7010100). Fall back to RF. Not G0 (no stall).
      // SMT+SS only. SI: NrHarts==1 const-folds the guard.
`ifndef G6LC_FETCH_B
      if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
          forward_rs2[i] &&
          issue_instr_i[i].fu == g6lc_core_pkg::ALU &&
          g6lc_sb_keep::cmv_abi_ptr(
              issue_instr_i[i].rd,
              issue_instr_i[i].rs1[4:0],
              issue_instr_i[i].rs2[4:0],
              issue_instr_i[i].use_imm) &&
          g6lc_sb_keep::exec_region_base(
              G6LCCfg, 64'(rs2_res[i]))) begin
        fu_data_n[i].operand_b = operand_b_regfile[i];
      end
`endif
      if ((G6LCCfg.FpPresent || (G6LCCfg.CvxifEn && OPERANDS_PER_INSTR == 3) ||
           (G6LCCfg.RVZacas && g6lc_core_pkg::is_amo_cas(issue_instr_i[i].op))) && forward_rs3[i]) begin
        if (G6LCCfg.RVZacas && g6lc_core_pkg::is_amo_cas(issue_instr_i[i].op))
          fu_data_n[i].operand_c = imm_forward_rs3[i];
        else
          fu_data_n[i].imm = imm_forward_rs3[i];
      end

      // use the PC as operand a
      if (issue_instr_i[i].use_pc) begin
        fu_data_n[i].operand_a = {
          {G6LCCfg.XLEN - G6LCCfg.VLEN{issue_instr_i[i].pc[G6LCCfg.VLEN-1]}}, issue_instr_i[i].pc
        };
      end
      // I14: CF PC / compressed / bp ride the issue-port identity pick
      // (below), not operand_c. operand_c stays the Zacas/FP third source.

      // use the zimm as operand a
      if (issue_instr_i[i].use_zimm) begin
        // zero extend operand a
        fu_data_n[i].operand_a = {{G6LCCfg.XLEN - 5{1'b0}}, issue_instr_i[i].rs1[4:0]};
      end
      // or is it an immediate (including PC), this is not the case for a store, control flow, and accelerator instructions
      // also make sure operand B is not already used as an FP operand
      if (issue_instr_i[i].use_imm && (issue_instr_i[i].fu != STORE) && (issue_instr_i[i].fu != CTRL_FLOW) && (issue_instr_i[i].fu != ACCEL) && !(G6LCCfg.FpPresent && is_rs2_fpr(
              issue_instr_i[i].op
          ))) begin
        fu_data_n[i].operand_b = issue_instr_i[i].result;
      end
      // AMOCAS.Q: after all forwards, force pair-gather (latched lo + hi)
      if (G6LCCfg.RVZacas && issue_instr_i[i].op == g6lc_core_pkg::AMO_CASQ && casq_ready_q) begin
        fu_data_n[i].operand_b    = casq_new_lo_q;
        fu_data_n[i].operand_c    = casq_exp_lo_q;
        fu_data_n[i].operand_b_hi = casq_new_hi_q;
        fu_data_n[i].operand_c_hi = casq_exp_hi_q;
      end
      // I17: JALR base is forwarded rs1 (operand_a). Do not stash a
      // second copy in operand_b.
    end
  end

  // hyp8: per-bit FU-valid decode — the emit's case inside a serial loop
  // over issue ports billed every valid vector as one patch chain.
  logic [G6LCCfg.NrIssuePorts-1:0] fuv_en, fuv_brkeep;
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_fuv
    assign fuv_en[i] = !issue_instr_i[i].ex.valid &&
                       issue_instr_valid_i[i] && issue_ack_o[i];
`ifdef G6LC_FETCH_B
    assign fuv_brkeep[i] = 1'b0;
`else
    // G1t: flush_i is flush_unissued. An acked link-jal keeps its branch
    // valid — SB allocates it and EX must still compute the link.
    assign fuv_brkeep[i] = G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
        g6lc_sb_keep::link_jal(
            G6LCCfg.SuperscalarEn,
            issue_instr_i[i].fu,
            issue_instr_i[i].rd[4:0]);
`endif
    assign alu_valid_n[i]    = fuv_en[i] && !flush_i &&
        issue_instr_i[i].fu == ALU &&
        !(G6LCCfg.SuperscalarEn && use_alu2[i]);
    assign alu2_valid_n[i]   = fuv_en[i] && !flush_i &&
        issue_instr_i[i].fu == ALU &&
        (G6LCCfg.SuperscalarEn && use_alu2[i]);
    assign branch_valid_n[i] = fuv_en[i] &&
        issue_instr_i[i].fu == CTRL_FLOW &&
        (!flush_i || fuv_brkeep[i]);
    assign mult_valid_n[i]   = fuv_en[i] && !flush_i &&
        issue_instr_i[i].fu == MULT;
    assign lsu_valid_n[i]    = fuv_en[i] && !flush_i &&
        (issue_instr_i[i].fu == LOAD || issue_instr_i[i].fu == STORE);
    assign csr_valid_n[i]    = fuv_en[i] && !flush_i &&
        issue_instr_i[i].fu == CSR;
    assign aes_valid_n[i]    = fuv_en[i] && !flush_i &&
        issue_instr_i[i].fu == AES;
    assign fpu_valid_n[i]    = fuv_en[i] && !flush_i && G6LCCfg.FpPresent &&
        (issue_instr_i[i].fu == FPU || issue_instr_i[i].fu == FPU_VEC);
  end
  // fpu fmt/rm/hart are scalars: the emit's ascending loop keeps the LAST
  // matching port's record — a last-wins gather, not gated by flush.
  always_comb begin
    fpu_fmt_n  = '0;
    fpu_rm_n   = '0;
    fpu_hart_n = '0;
    for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
      if (fuv_en[i] && G6LCCfg.FpPresent &&
          issue_instr_i[i].fu == FPU) begin
        fpu_fmt_n  = orig_instr[i].rftype.fmt;
        fpu_rm_n   = orig_instr[i].rftype.rm;
        fpu_hart_n = issue_instr_i[i].hart_id;  // FP-2: issuing hart owns frm/fprec
      end else if (fuv_en[i] && G6LCCfg.FpPresent &&
                   issue_instr_i[i].fu == FPU_VEC) begin
        fpu_fmt_n  = orig_instr[i].rvftype.vfmt;
        fpu_rm_n   = {2'b0, orig_instr[i].rvftype.repl};
        fpu_hart_n = issue_instr_i[i].hart_id;
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
      fpu_hart_q     <= '0;
      alu2_valid_q   <= '0;
      csr_valid_q    <= '0;
      branch_valid_q <= '0;
      spec_ab_q      <= '0;
      ptid_q         <= '0;
    end else begin
      alu_valid_q    <= alu_valid_n;
      aes_valid_q    <= aes_valid_n;
      lsu_valid_q    <= lsu_valid_n;
      mult_valid_q   <= mult_valid_n;
      fpu_valid_q    <= fpu_valid_n;
      fpu_fmt_q      <= fpu_fmt_n;
      fpu_rm_q       <= fpu_rm_n;
      fpu_hart_q     <= fpu_hart_n;
      alu2_valid_q   <= alu2_valid_n;
      csr_valid_q    <= csr_valid_n;
      branch_valid_q <= branch_valid_n;
      // hyp8 g7: spec-arm metadata rides the issue packet alongside the
      // FU valids; a cleared ack clears the select (no stale forward).
      spec_ab_q <= issue_spec_ab_i;
      ptid_q    <= issue_ptid_i;
    end
  end

  // hyp8 g7: in-ALU forward select. The operand in fu_data_q may carry a
  // spec-armed (pre-writeback) producer; when the producer is still inside
  // the ALU0 pipe the A1 capture substitutes its live stage result instead
  // of the packet operand. The ALU has no valid line on the tid outputs,
  // so the spec-arm bit is the guard: a non-armed operand never selects.
  always_comb begin
    for (int unsigned p = 0; p < G6LCCfg.NrIssuePorts; p++) begin
      alu_fwd_a_o[p][0] = spec_ab_q[p][0] && (ptid_q[p][0] == alu_fwd_tid_i);
      alu_fwd_a_o[p][1] = spec_ab_q[p][0] && (ptid_q[p][0] == alu_fwd_qtid_i);
      // hyp8 r5: bit 2 -- the registered A3 slot, the LAT_ALU_FULL
      // producer's publish point under AluStages==3.
      alu_fwd_a_o[p][2] = spec_ab_q[p][0] && (ptid_q[p][0] == alu_fwd_rtid_i);
      alu_fwd_b_o[p][0] = spec_ab_q[p][1] && (ptid_q[p][1] == alu_fwd_tid_i);
      alu_fwd_b_o[p][1] = spec_ab_q[p][1] && (ptid_q[p][1] == alu_fwd_qtid_i);
      alu_fwd_b_o[p][2] = spec_ab_q[p][1] && (ptid_q[p][1] == alu_fwd_rtid_i);
    end
  end

  if (G6LCCfg.CvxifEn) begin
    always_comb begin
      cvxif_valid_n = '0;
      cvxif_off_instr_n = 32'b0;
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
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
  // Identity of the LR that opened the window, so the window can be bounded by
  // that instruction's own lifetime under OoO (see gen_lr_sc_pair below).
  logic [G6LCCfg.TRANS_ID_BITS-1:0] lr_sc_tid_q, lr_sc_tid_d;

  // We can issue an instruction if we do not detect that any other instruction is writing the same
  // destination register.
  // We also need to check if there is an unresolved branch in the scoreboard.
  always_comb begin : issue_scoreboard
    for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
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
    if (G6LCCfg.RVA && lr_sc_pair_q) begin
      for (int unsigned p = 0; p < G6LCCfg.NrIssuePorts; p++) begin
        if (issue_instr_i[p].fu == STORE && !g6lc_core_pkg::is_amo_sc(issue_instr_i[p].op)) begin
          issue_ack_o[p] = 1'b0;
        end
      end
    end
    // In-order multi-issue: a bubble on port k kills ports k+1..N-1
    if (G6LCCfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        if (!issue_ack_o[p-1]) issue_ack_o[p] = 1'b0;
      end
      // Soft-ladder B1 (b1-amo-spin-lock): AMO only on issue port 0 under SS.
      // Port-1 AMO + hang-7 younger-cancel left amo_buffer wedged (depth 1,
      // no flush_ex on mispredict). store_unit cancel kill recovers that;
      // keep AMO serial for commit/amo_valid_commit_o coupling.
      if (G6LCCfg.RVA) begin
        for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
          if (g6lc_core_pkg::is_amo(issue_instr_i[p].op)) issue_ack_o[p] = 1'b0;
        end
      end
      // iter-012 note: force SI (issue_ack_o[p>0]=0) was PEEL_FDT-negative
      // (fw64e, same 12eb2/12b2a) — residual is not residual dual-issue pairs.
    end
  end

  always_comb begin : gen_lr_sc_pair
    lr_sc_pair_d = lr_sc_pair_q;
    lr_sc_tid_d  = lr_sc_tid_q;
    if (G6LCCfg.RVA) begin
      for (int unsigned p = 0; p < G6LCCfg.NrIssuePorts; p++) begin
        if (issue_instr_valid_i[p] && issue_ack_o[p] && !issue_instr_i[p].ex.valid) begin
          if (g6lc_core_pkg::is_amo_lr(issue_instr_i[p].op)) begin
            lr_sc_pair_d = 1'b1;
            lr_sc_tid_d  = issue_instr_i[p].trans_id;
          end
          if (g6lc_core_pkg::is_amo_sc(issue_instr_i[p].op)) lr_sc_pair_d = 1'b0;
        end
      end
      // The window must not outlive the LR that opened it.
      //
      // It is closed by an SC issue or a flush. Under in-order issue one of
      // those always arrives while the LR is still live, so the window is
      // inherently bounded. Out of order it is not: a program whose LR is not
      // followed by an SC -- which is entirely legal -- leaves the window open,
      // and every later non-SC store is then refused an issue acknowledge
      // forever. The store is allocated, becomes the commit head and never
      // issues, so nothing retires behind it. still_issued is cleared when the
      // LR retires or is cancelled, which is precisely when the reservation it
      // was protecting can no longer be completed by a younger SC.
      if (G6LCCfg.OoOEn && lr_sc_pair_q && !fwd_i.still_issued[lr_sc_tid_q])
        lr_sc_pair_d = 1'b0;
    end
    if (flush_i) lr_sc_pair_d = 1'b0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lr_sc_pair_q <= 1'b0;
      lr_sc_tid_q  <= '0;
    end else begin
      lr_sc_pair_q <= lr_sc_pair_d;
      lr_sc_tid_q  <= lr_sc_tid_d;
    end
  end

  // ----------------------
  // Integer Register File
  // ----------------------
  // G1gq: one extra combo read of commit JALR rs1 (SMT+SS).
  localparam int unsigned G1GQ_RF_PORTS =
      (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1) ?
          (G6LCCfg.NrRgprPorts + 1) : G6LCCfg.NrRgprPorts;
  logic [  G6LCCfg.NrRgprPorts-1:0][G6LCCfg.XLEN-1:0] rdata;
  logic [  G6LCCfg.NrRgprPorts-1:0][             4:0] raddr_pack;
  logic [  G6LCCfg.NrRgprPorts-1:0][             4:0] raddr_pack_base;
  logic [G1GQ_RF_PORTS-1:0][G6LCCfg.XLEN-1:0]         g1gq_rdata;
  logic [G1GQ_RF_PORTS-1:0][4:0]                      g1gq_raddr;

  // pack signals
  logic [G6LCCfg.NrCommitPorts-1:0][             4:0] waddr_pack;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] wdata_pack;
  logic [G6LCCfg.NrCommitPorts-1:0]                   we_pack;

  //adjust address to read from register file (when synchronous RAM is used reads take one cycle, so we advance the address)
  for (genvar i = 0; i <= G6LCCfg.NrIssuePorts - 1; i++) begin
    assign raddr_pack_base[i*OPERANDS_PER_INSTR+0] = G6LCCfg.FpgaEn && G6LCCfg.FpgaAlteraEn ? issue_instr_i_prev[i].rs1[4:0] : issue_instr_i[i].rs1[4:0];
    assign raddr_pack_base[i*OPERANDS_PER_INSTR+1] = G6LCCfg.FpgaEn && G6LCCfg.FpgaAlteraEn ? issue_instr_i_prev[i].rs2[4:0] : issue_instr_i[i].rs2[4:0];
    if (OPERANDS_PER_INSTR == 3) begin
      assign raddr_pack_base[i*OPERANDS_PER_INSTR+2] = G6LCCfg.FpgaEn && G6LCCfg.FpgaAlteraEn ? issue_instr_i_prev[i].result[4:0] : issue_instr_i[i].result[4:0];
      // CASQ phase1: read rs2+1 and rd+1 on ports 1 and 2 (port0 unused/addr already latched)
      // Applied after generate via always_comb override below.
    end
  end

  for (genvar i = 0; i < G6LCCfg.NrCommitPorts; i++) begin : gen_write_back_port
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
        raddr_pack[CASQ_HI_IDX] = issue_instr_i[0].result[4:0] | 5'b00001;  // rd+1
        casq_phase_d = 1'b0;
      end
    end else begin
      casq_phase_d = 1'b0;
    end
    g1gq_raddr = '0;
    for (int unsigned p = 0; p < G6LCCfg.NrRgprPorts; p++)
      g1gq_raddr[p] = raddr_pack[p];
    if (G1GQ_RF_PORTS > G6LCCfg.NrRgprPorts)
      g1gq_raddr[G6LCCfg.NrRgprPorts] = g1gq_raddr_i;
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
          casq_exp_lo_q <= rdata[CASQ_HI_IDX];
          casq_ready_q  <= 1'b0;
        end else begin
          casq_new_hi_q <= rdata[1];
          casq_exp_hi_q <= rdata[CASQ_HI_IDX];
          casq_ready_q  <= 1'b1;
        end
      end
    end else begin
      casq_phase_q <= 1'b0;
      casq_ready_q <= 1'b0;
    end
  end

  if (G6LCCfg.FpgaEn) begin : gen_fpga_regfile
    g6lc_regfile_fpga #(
        .G6LCCfg      (G6LCCfg),
        .DATA_WIDTH   (G6LCCfg.XLEN),
        .NR_READ_PORTS(G1GQ_RF_PORTS),
        .ZERO_REG_ZERO(1)
    ) i_g6lc_regfile_fpga (
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
    // contention). NrHarts==1 collapses to a single g6lc_regfile (identity).
    localparam int unsigned SMT_HID_W =
        (G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts);
    logic [G1GQ_RF_PORTS-1:0][SMT_HID_W-1:0] rhart_pack;
    logic [G6LCCfg.NrCommitPorts-1:0][SMT_HID_W-1:0] whart_pack;
    // Tag reads from issuing instr hart_id; writes from commit instr hart_id.
    // (Previously whart was stuck at 0 — peer commits corrupted primary RF.)
    always_comb begin
      rhart_pack = '0;
      whart_pack = '0;
      if (G6LCCfg.NrHarts > 1) begin
        for (int unsigned p = 0; p < G6LCCfg.NrIssuePorts; p++) begin
          for (int unsigned k = 0; k < OPERANDS_PER_INSTR; k++) begin
            rhart_pack[p*OPERANDS_PER_INSTR+k] = issue_instr_i[p].hart_id;
          end
        end
        if (G1GQ_RF_PORTS > G6LCCfg.NrRgprPorts)
          rhart_pack[G6LCCfg.NrRgprPorts] = g1gq_rhart_i;
        for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++) begin
          whart_pack[c] = whart_i[c];
        end
      end
    end
    g6lc_smt_regfile #(
        .G6LCCfg      (G6LCCfg),
        .DATA_WIDTH   (G6LCCfg.XLEN),
        .NR_READ_PORTS(G1GQ_RF_PORTS),
        .NR_HARTS     (G6LCCfg.NrHarts),
        .ZERO_REG_ZERO(1)
    ) i_g6lc_regfile (
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

  assign rdata = g1gq_rdata[G6LCCfg.NrRgprPorts-1:0];
  if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1) begin : gen_g1gq_rdata
    assign g1gq_rdata_o = g1gq_rdata[G6LCCfg.NrRgprPorts];
  end else begin : gen_g1gq_rdata_si
    assign g1gq_rdata_o = '0;
  end
  // -----------------------------
  // Floating-Point Register File
  // -----------------------------
  logic [2:0][G6LCCfg.FLen-1:0] fprdata;

  // pack signals
  logic [2:0][4:0] fp_raddr_pack;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] fp_wdata_pack;

  always_comb begin : assign_fp_raddr_pack
    fp_raddr_pack = {
      issue_instr_i[0].result[4:0], issue_instr_i[0].rs2[4:0], issue_instr_i[0].rs1[4:0]
    };

    if (G6LCCfg.SuperscalarEn) begin
      if (!(issue_instr_i[0].fu inside {FPU, FPU_VEC} || issue_instr_i[0].op inside {[FLD:FSB]})) begin
        fp_raddr_pack = {
          issue_instr_i[1].result[4:0], issue_instr_i[1].rs2[4:0], issue_instr_i[1].rs1[4:0]
        };
      end
    end
  end

  generate
    if (G6LCCfg.FpPresent) begin : float_regfile_gen
      for (genvar i = 0; i < G6LCCfg.NrCommitPorts; i++) begin : gen_fp_wdata_pack
        assign fp_wdata_pack[i] = {wdata_i[i][G6LCCfg.FLen-1:0]};
      end
      if (G6LCCfg.FpgaEn) begin : gen_fpga_fp_regfile
        g6lc_regfile_fpga #(
            .G6LCCfg      (G6LCCfg),
            .DATA_WIDTH   (G6LCCfg.FLen),
            .NR_READ_PORTS(3),
            .ZERO_REG_ZERO(0)
        ) i_g6lc_fp_regfile_fpga (
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
        g6lc_regfile #(
            .G6LCCfg      (G6LCCfg),
            .DATA_WIDTH   (G6LCCfg.FLen),
            .NR_READ_PORTS(3),
            .ZERO_REG_ZERO(0)
        ) i_g6lc_fp_regfile (
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
    assign operand_c_fpr = {{G6LCCfg.XLEN - G6LCCfg.FLen{1'b0}}, fprdata[2]};
  end else begin
    assign operand_c_fpr = fprdata[2];
  end

  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    if (OPERANDS_PER_INSTR == 3) begin : gen_operand_c
      assign operand_c_gpr[i] = rdata[i*OPERANDS_PER_INSTR+2];
    end

    // U5 production: prefer PRF operand when renamed (bypassed WB already applied)
    // The FP exclusion that used to sit here was wrong once the OoO FP
    // register class existed: it sent every FP source to the ARCHITECTURAL
    // f-register file, which by construction holds no in-flight renamed value,
    // so a dependent fadd.d read a stale operand. Dispatch now supplies FP
    // sources from the FP physical file on the same ports, and holds back a
    // second FP consumer in the group rather than issuing it unreadable
    // operands, so the renamed value is preferred for BOTH classes.
    // Renamed PRF, then FPR, then GPR. Priority stays in a 2-bit code so each
    // half is one unique mux (hyp8 XLEN and FLen are 64, so the FPR arm is
    // the register itself, not a variable-width zero extend).
    logic [1:0] a_src, b_src, c_src;
    always_comb begin
      if (G6LCCfg.OoOEn && ooo_op_a_valid_i[i] && issue_instr_i[i].ooo_renamed)
        a_src = 2'd0;
      else if (G6LCCfg.FpPresent && is_rs1_fpr(issue_instr_i[i].op))
        a_src = 2'd1;
      else a_src = 2'd2;
    end
    always_comb begin
      if (G6LCCfg.OoOEn && ooo_op_b_valid_i[i] && issue_instr_i[i].ooo_renamed)
        b_src = 2'd0;
      else if (G6LCCfg.FpPresent && is_rs2_fpr(issue_instr_i[i].op))
        b_src = 2'd1;
      else b_src = 2'd2;
    end
    always_comb begin
      if (G6LCCfg.OoOEn && ooo_op_c_valid_i[i] && issue_instr_i[i].ooo_renamed &&
          G6LCCfg.FpPresent && is_imm_fpr(issue_instr_i[i].op))
        c_src = 2'd0;
      else if ((OPERANDS_PER_INSTR == 3) &&
               !(G6LCCfg.FpPresent && is_imm_fpr(issue_instr_i[i].op)))
        c_src = 2'd2;
      else c_src = 2'd1;
    end
    always_comb begin
      unique case (a_src)
        2'd0:    operand_a_regfile[i] = ooo_op_a_i[i];
        2'd1:    operand_a_regfile[i] = {{G6LCCfg.XLEN - G6LCCfg.FLen{1'b0}}, fprdata[0]};
        default: operand_a_regfile[i] = rdata[i*OPERANDS_PER_INSTR+0];
      endcase
    end
    always_comb begin
      unique case (b_src)
        2'd0:    operand_b_regfile[i] = ooo_op_b_i[i];
        2'd1:    operand_b_regfile[i] = {{G6LCCfg.XLEN - G6LCCfg.FLen{1'b0}}, fprdata[1]};
        default: operand_b_regfile[i] = rdata[i*OPERANDS_PER_INSTR+1];
      endcase
    end
    always_comb begin
      unique case (c_src)
        2'd0:    operand_c_regfile[i] = ooo_op_c_i[i];
        2'd2:    operand_c_regfile[i] = operand_c_gpr[i];
        default: operand_c_regfile[i] = operand_c_fpr;
      endcase
    end
  end

  // ----------------------
  // Registers (ID <-> EX)
  // ----------------------

  always_comb begin
    // I14: EX identity is the CF issue port this cycle (same pick as
    // branch_valid_n / ex_stage branch_data). No G1p hold of the last CF.
    // SI (one port) const-folds to port 0. No CF → zeros; branch_unit is
    // silent when |branch_valid is 0.
    pc_n                  = '0;
    is_compressed_instr_n = 1'b0;
    is_zcmt_n             = 1'b0;
    branch_predict_n      = {cf_t'(0), {G6LCCfg.VLEN{1'b0}}};
    branch_hart_n         = '0;
    if (G6LCCfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        if (branch_valid_n[p]) begin
          pc_n                  = issue_instr_i[p].pc;
          is_compressed_instr_n = issue_instr_i[p].is_compressed;
          is_zcmt_n             = issue_instr_i[p].is_zcmt;
          branch_predict_n      = issue_instr_i[p].bp;
          branch_hart_n         = issue_instr_i[p].hart_id;
        end
      end
    end
    if (branch_valid_n[0]) begin
      pc_n                  = issue_instr_i[0].pc;
      is_compressed_instr_n = issue_instr_i[0].is_compressed;
      is_zcmt_n             = issue_instr_i[0].is_zcmt;
      branch_predict_n      = issue_instr_i[0].bp;
      branch_hart_n         = issue_instr_i[0].hart_id;
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
      if (G6LCCfg.RVH) begin
        tinst_q <= '0;
      end
      pc_o                     <= '0;
      branch_hart_o            <= '0;
      is_zcmt_o                <= '0;
      is_compressed_instr_o    <= 1'b0;
      branch_predict_o         <= {cf_t'(0), {G6LCCfg.VLEN{1'b0}}};
      x_transaction_rejected_o <= 1'b0;
      alu_bypass_q             <= '0;
    end else begin
      fu_data_q <= fu_data_n;
      alu_bypass_q <= alu_bypass_n;
      if (G6LCCfg.ZKN) begin
        orig_instr_aes_bits <= {orig_instr_i[0][31:30], orig_instr_i[0][23:20]};
      end
      if (G6LCCfg.RVH) begin
        tinst_q <= tinst_n;
      end
      pc_o <= pc_n;
      branch_hart_o <= branch_hart_n;
      is_compressed_instr_o <= is_compressed_instr_n;
      branch_predict_o <= branch_predict_n;
      is_zcmt_o <= (G6LCCfg.RVZCMT) ? is_zcmt_n : 1'b0;
      x_transaction_rejected_o <= x_transaction_rejected_n;
    end
  end

  //pragma translate_off
  bit smt_issue_trace;
  int unsigned smt_issue_idle = 0;
  initial smt_issue_trace = $test$plusargs("smt_flow_trace");
  always @(posedge clk_i) begin
    if (!rst_ni) smt_issue_idle = 0;
    else if (smt_issue_trace) begin
      for (int p = 0; p < G6LCCfg.NrIssuePorts; p++)
        if (issue_instr_valid_i[p] && issue_ack_o[p] && !flush_i)
          $display("[smt-flow] operands time=%0t port=%0d id=%0d hart=%0d pc=%h fu=%0d a=%h b=%h imm=%h forward=%b%b",
                   $time, p, issue_instr_i[p].trans_id, issue_instr_i[p].hart_id,
                   issue_instr_i[p].pc, issue_instr_i[p].fu, fu_data_n[p].operand_a,
                   fu_data_n[p].operand_b, fu_data_n[p].imm, forward_rs1[p], forward_rs2[p]);
      smt_issue_idle = (issue_instr_valid_i[0] && !issue_ack_o[0]) ? smt_issue_idle + 1 : 0;
      if (smt_issue_idle != 0 && smt_issue_idle <= 4096 && smt_issue_idle % 1024 == 0) begin
        $display("[smt-flow] issue_stall time=%0t idle=%0d stall_i=%b valid=%b ack=%b busy=%b raw=%b rs1=%b rs2=%b rs3=%b flu_ready=%b lsu_ready=%b mult=%b casq=%b lrsc=%b live=%b",
                 $time, smt_issue_idle, stall_i, issue_instr_valid_i, issue_ack_o,
                 fu_busy, stall_raw, stall_rs1, stall_rs2, stall_rs3, flu_ready_i,
                 lsu_ready_i, mult_valid_q, casq_stall, lr_sc_pair_q, fwd_i.still_issued);
        for (int p = 0; p < G6LCCfg.NrIssuePorts; p++)
          $display("[smt-flow] operand port=%0d hart=%0d pc=%h fu=%0d op=%0d forward=%b%b raw_check=%b%b",
                   p, issue_instr_i[p].hart_id, issue_instr_i[p].pc, issue_instr_i[p].fu,
                   issue_instr_i[p].op, forward_rs1[p], forward_rs2[p], rs1_raw_check[p], rs2_raw_check[p]);
      end
    end
  end
  initial begin
    assert (OPERANDS_PER_INSTR == 2 || (OPERANDS_PER_INSTR == 3 && (G6LCCfg.CvxifEn || G6LCCfg.RVZacas)))
    else
      $fatal(
          1,
          "RF ports/instr must be 2, or 3 when CVXIF or Zacas (AMOCAS expected source)."
      );
  end

  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    assert property (@(posedge clk_i) (branch_valid_q[i]) |-> (!$isunknown(
        fu_data_q[i].operand_a
    ) && !$isunknown(
        fu_data_q[i].operand_b
    )))
    else $warning("Got unknown value in one of the operands");
  end
  //pragma translate_on


endmodule


