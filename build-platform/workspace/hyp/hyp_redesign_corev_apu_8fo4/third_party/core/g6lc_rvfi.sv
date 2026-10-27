// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2024 Thales DIS France SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Yannick Casamatta - Thales
// Date: 09/01/2024
// Modified by: Etienne Cimon (RVFI CSR XLEN-cast; Verilator WIDTHTRUNC)


module g6lc_rvfi
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type rvfi_instr_t = logic,
    parameter type rvfi_csr_t = logic,
    parameter type rvfi_probes_instr_t = logic,
    parameter type rvfi_probes_csr_t = logic,
    parameter type rvfi_probes_t = logic,
    parameter type rvfi_to_iti_t = logic

) (

    input logic clk_i,
    input logic rst_ni,

    input rvfi_probes_t rvfi_probes_i,
    output rvfi_instr_t [G6LCCfg.NrCommitPorts-1:0] rvfi_instr_o,
    output rvfi_to_iti_t rvfi_to_iti_o,
    output rvfi_csr_t rvfi_csr_o,
    // SMT: hart of each retired instruction (0 when NrHarts == 1); sampled with rvfi_instr_o
    output logic [G6LCCfg.NrCommitPorts-1:0][7:0] rvfi_hart_o
);

  localparam logic [G6LCCfg.XLEN-1:0] IsaCode =
    (G6LCCfg.XLEN'(G6LCCfg.RVA) << 0)   // A - Atomic Instructions extension
  | (G6LCCfg.XLEN'(G6LCCfg.RVB) << 1)  // C - Bitmanip extension
  | (G6LCCfg.XLEN'(G6LCCfg.RVC) << 2)  // C - Compressed extension
  | (G6LCCfg.XLEN'(G6LCCfg.RVD) << 3)  // D - Double precision floating-point extension
  | (G6LCCfg.XLEN'(G6LCCfg.RVF) << 5)  // F - Single precision floating-point extension
  | (G6LCCfg.XLEN'(G6LCCfg.RVH) << 7)  // H - Hypervisor extension
  | (G6LCCfg.XLEN'(1) << 8)  // I - RV32I/64I/128I base ISA
  | (G6LCCfg.XLEN'(1) << 12)  // M - Integer Multiply/Divide extension
  | (G6LCCfg.XLEN'(0) << 13)  // N - User level interrupts supported
  | (G6LCCfg.XLEN'(G6LCCfg.RVS) << 18)  // S - Supervisor mode implemented
  | (G6LCCfg.XLEN'(G6LCCfg.RVU) << 20)  // U - User mode implemented
  | (G6LCCfg.XLEN'(G6LCCfg.RVV) << 21)  // V - Vector extension
  | (G6LCCfg.XLEN'(G6LCCfg.NSX) << 23)  // X - Non-standard extensions present
  | ((G6LCCfg.IS_XLEN64 ? 2 : 1) << G6LCCfg.XLEN - 2);  // MXL

  localparam logic [G6LCCfg.XLEN-1:0] hart_id_i = '0;

  // Function to compute AMO write value for RVFI logging
  // This mirrors the AMO ALU behaviour so the tracer sees the value actually written
  // back to memory. This is post-alignment data (lower bytes contain the payload) so
  // the tracer can rotate it using the write mask and address offset.
  function automatic logic [G6LCCfg.XLEN-1:0] compute_amo_wdata(
      input fu_op amo_op, input logic [G6LCCfg.XLEN-1:0] mem_old_val,
      input logic [G6LCCfg.XLEN-1:0] reg_val);
    g6lc_core_pkg::amo_t amo_kind;
    logic is_word_op;
    logic [63:0] operand_a_sext, operand_b_sext;
    logic [63:0] operand_a_zext, operand_b_zext;
    logic [63:0] result64;
    logic [64:0] adder_operand_a, adder_operand_b, adder_sum;

    // Decode functional unit opcode into AMO class and width information
    amo_kind   = AMO_NONE;
    is_word_op = 1'b0;
    unique case (amo_op)
      AMO_LRW: begin
        amo_kind   = AMO_LR;
        is_word_op = 1'b1;
      end
      AMO_LRD: begin
        amo_kind   = AMO_LR;
        is_word_op = 1'b0;
      end
      AMO_SCW: begin
        amo_kind   = AMO_SC;
        is_word_op = 1'b1;
      end
      AMO_SCD: begin
        amo_kind   = AMO_SC;
        is_word_op = 1'b0;
      end
      AMO_SWAPW: begin
        amo_kind   = AMO_SWAP;
        is_word_op = 1'b1;
      end
      AMO_SWAPD: begin
        amo_kind   = AMO_SWAP;
        is_word_op = 1'b0;
      end
      AMO_ADDW: begin
        amo_kind   = AMO_ADD;
        is_word_op = 1'b1;
      end
      AMO_ADDD: begin
        amo_kind   = AMO_ADD;
        is_word_op = 1'b0;
      end
      AMO_ANDW: begin
        amo_kind   = AMO_AND;
        is_word_op = 1'b1;
      end
      AMO_ANDD: begin
        amo_kind   = AMO_AND;
        is_word_op = 1'b0;
      end
      AMO_ORW: begin
        amo_kind   = AMO_OR;
        is_word_op = 1'b1;
      end
      AMO_ORD: begin
        amo_kind   = AMO_OR;
        is_word_op = 1'b0;
      end
      AMO_XORW: begin
        amo_kind   = AMO_XOR;
        is_word_op = 1'b1;
      end
      AMO_XORD: begin
        amo_kind   = AMO_XOR;
        is_word_op = 1'b0;
      end
      AMO_MAXW: begin
        amo_kind   = AMO_MAX;
        is_word_op = 1'b1;
      end
      AMO_MAXD: begin
        amo_kind   = AMO_MAX;
        is_word_op = 1'b0;
      end
      AMO_MAXWU: begin
        amo_kind   = AMO_MAXU;
        is_word_op = 1'b1;
      end
      AMO_MAXDU: begin
        amo_kind   = AMO_MAXU;
        is_word_op = 1'b0;
      end
      AMO_MINW: begin
        amo_kind   = AMO_MIN;
        is_word_op = 1'b1;
      end
      AMO_MIND: begin
        amo_kind   = AMO_MIN;
        is_word_op = 1'b0;
      end
      AMO_MINWU: begin
        amo_kind   = AMO_MINU;
        is_word_op = 1'b1;
      end
      AMO_MINDU: begin
        amo_kind   = AMO_MINU;
        is_word_op = 1'b0;
      end
      default: begin
        amo_kind   = AMO_NONE;
        is_word_op = 1'b0;
      end
    endcase

    // Create signed and unsigned 64-bit views of the operands (word ops use 32-bit payloads)
    if (is_word_op) begin
      operand_a_sext = {{32{mem_old_val[31]}}, mem_old_val[31:0]};
      operand_b_sext = {{32{reg_val[31]}}, reg_val[31:0]};
      operand_a_zext = {32'b0, mem_old_val[31:0]};
      operand_b_zext = {32'b0, reg_val[31:0]};
    end else begin
      operand_a_sext = $signed(mem_old_val);
      operand_b_sext = $signed(reg_val);
      operand_a_zext = $unsigned(mem_old_val);
      operand_b_zext = $unsigned(reg_val);
    end

    // Default to returning the register operand (SWAP/SC path)
    result64        = operand_b_zext;
    adder_operand_a = {operand_a_sext[63], operand_a_sext};
    adder_operand_b = {operand_b_sext[63], operand_b_sext};
    adder_sum       = '0;

    unique case (amo_kind)
      AMO_SC, AMO_SWAP: begin
        result64 = operand_b_zext;
      end
      AMO_ADD: begin
        adder_sum = adder_operand_a + adder_operand_b;
        result64  = adder_sum[63:0];
      end
      AMO_AND: result64 = operand_a_zext & operand_b_zext;
      AMO_OR:  result64 = operand_a_zext | operand_b_zext;
      AMO_XOR: result64 = operand_a_zext ^ operand_b_zext;
      AMO_MAX: begin
        adder_operand_b = -{operand_b_sext[63], operand_b_sext};
        adder_sum       = adder_operand_a + adder_operand_b;
        result64        = adder_sum[64] ? operand_b_zext : operand_a_zext;
      end
      AMO_MIN: begin
        adder_operand_b = -{operand_b_sext[63], operand_b_sext};
        adder_sum       = adder_operand_a + adder_operand_b;
        result64        = adder_sum[64] ? operand_a_zext : operand_b_zext;
      end
      AMO_MAXU: begin
        adder_operand_a = {1'b0, operand_a_zext};
        adder_operand_b = -{1'b0, operand_b_zext};
        adder_sum       = adder_operand_a + adder_operand_b;
        result64        = adder_sum[64] ? operand_b_zext : operand_a_zext;
      end
      AMO_MINU: begin
        adder_operand_a = {1'b0, operand_a_zext};
        adder_operand_b = -{1'b0, operand_b_zext};
        adder_sum       = adder_operand_a + adder_operand_b;
        result64        = adder_sum[64] ? operand_a_zext : operand_b_zext;
      end
      default: begin
        result64 = operand_b_zext;
      end
    endcase

    if (is_word_op) begin
      return {{G6LCCfg.XLEN - 32{1'b0}}, result64[31:0]};
    end else begin
      return result64[G6LCCfg.XLEN-1:0];
    end
  endfunction

  localparam logic [63:0] SMODE_STATUS_READ_MASK = g6lc_core_pkg::smode_status_read_mask(G6LCCfg);

  logic flush;
  logic [G6LCCfg.NrIssuePorts-1:0] issue_instr_ack;
  logic [G6LCCfg.NrIssuePorts-1:0] fetch_entry_valid;
  logic [G6LCCfg.NrIssuePorts-1:0][31:0] instruction;
  logic [G6LCCfg.NrIssuePorts-1:0] is_compressed;

  logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] issue_pointer;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_pointer;

  logic flush_unissued_instr;
  logic [G6LCCfg.NrIssuePorts-1:0] decoded_instr_valid;
  logic [G6LCCfg.NrIssuePorts-1:0] decoded_instr_ack;

  logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] rs1;
  logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] rs2;
  logic [G6LCCfg.NrIssuePorts-1:0] operand_valid;
  logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] operand_tid;

  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] rvfi_intr;

  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.VLEN-1:0] commit_instr_pc;
  fu_op [G6LCCfg.NrCommitPorts-1:0] commit_instr_op;
  logic [G6LCCfg.NrCommitPorts-1:0][REG_ADDR_SIZE-1:0] commit_instr_rs1;
  logic [G6LCCfg.NrCommitPorts-1:0][REG_ADDR_SIZE-1:0] commit_instr_rs2;
  logic [G6LCCfg.NrCommitPorts-1:0][REG_ADDR_SIZE-1:0] commit_instr_rd;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] commit_instr_result;
  logic [G6LCCfg.NrCommitPorts-1:0] commit_instr_valid;
  logic [G6LCCfg.NrCommitPorts-1:0] commit_drop;

  logic [G6LCCfg.XLEN-1:0] ex_commit_cause;
  logic ex_commit_valid;

  logic [G6LCCfg.NrCommitPorts-1:0] valid_iti;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.VLEN-1:0] pc_iti;
  g6lc_core_pkg::fu_op [G6LCCfg.NrCommitPorts-1:0] op_iti;
  logic branch_valid_iti;
  logic is_taken_iti;
  logic [G6LCCfg.XLEN-1:0] tval_iti;
  logic [63:0] time_iti;

  riscv::priv_lvl_t priv_lvl;

  logic [G6LCCfg.VLEN-1:0] lsu_ctrl_vaddr;
  fu_t lsu_ctrl_fu;
  logic [(G6LCCfg.XLEN/8)-1:0] lsu_ctrl_be;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] lsu_ctrl_trans_id;

  logic [((G6LCCfg.CvxifEn || G6LCCfg.RVV) ? 5 : 4)-1:0][G6LCCfg.XLEN-1:0] wbdata;
  logic [G6LCCfg.NrCommitPorts-1:0] commit_ack;
  logic [G6LCCfg.PLEN-1:0] mem_paddr;
  logic debug_mode;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] wdata;

  logic [G6LCCfg.VLEN-1:0] lsu_addr;
  logic [(G6LCCfg.XLEN/8)-1:0] lsu_rmask;
  logic [(G6LCCfg.XLEN/8)-1:0] lsu_wmask;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] lsu_addr_trans_id;

  logic [G6LCCfg.TRANS_ID_BITS-1:0] branch_trans_id;

  riscv::pmpcfg_t [15:0] pmpcfg_q, pmpcfg_d;

  rvfi_probes_csr_t   csr;
  rvfi_probes_instr_t instr;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5796  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: mem_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to mem_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     mem_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20938 c=3.50 slack=0.00 */
//     /* node20939 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5798  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.fflags.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.fflags.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.fflags.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20978 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5802  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.frm.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.frm.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.frm.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20982 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5806  makespan=0.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.fcsr.rdata  ready_cycle=1  ready_fo4=0.500  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.fcsr.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.fcsr.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20986 c=0.50 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5810  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.ftran.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.ftran.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.ftran.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20990 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5814  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.dcsr.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.dcsr.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.dcsr.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20994 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5818  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.dpc.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.dpc.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.dpc.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20998 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5822  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.dscratch0.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.dscratch0.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.dscratch0.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21002 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5826  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.dscratch1.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.dscratch1.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.dscratch1.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21006 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5830  makespan=1.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.sstatus.rdata  ready_cycle=1  ready_fo4=1.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.sstatus.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.sstatus.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21010 c=1.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5834  makespan=1.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.sie.rdata  ready_cycle=1  ready_fo4=1.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.sie.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.sie.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21014 c=1.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5838  makespan=1.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.sip.rdata  ready_cycle=1  ready_fo4=1.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.sip.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.sip.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21018 c=1.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5842  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.stvec.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.stvec.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.stvec.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21022 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5846  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.scounteren.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.scounteren.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.scounteren.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21026 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5850  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.sscratch.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.sscratch.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.sscratch.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21030 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5854  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.sepc.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.sepc.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.sepc.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21034 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5858  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.scause.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.scause.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.scause.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21038 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5862  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.stval.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.stval.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.stval.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21042 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5866  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.satp.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.satp.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.satp.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21046 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5870  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mstatus.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mstatus.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mstatus.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21050 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5874  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mstatush.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mstatush.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mstatush.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21054 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5878  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.misa.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.misa.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.misa.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21058 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5882  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.medeleg.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.medeleg.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.medeleg.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21062 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5886  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mideleg.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mideleg.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mideleg.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21066 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5890  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mie.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mie.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mie.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21070 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5894  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mtvec.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mtvec.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mtvec.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21074 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5898  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mcounteren.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mcounteren.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mcounteren.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21078 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5902  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mscratch.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mscratch.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mscratch.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21082 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5906  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mepc.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mepc.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mepc.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21086 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5910  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mcause.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mcause.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mcause.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21090 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5914  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mtval.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mtval.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mtval.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21094 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5918  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mip.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mip.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mip.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21098 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5922  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.menvcfg.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.menvcfg.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.menvcfg.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21102 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5926  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.menvcfgh.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.menvcfgh.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.menvcfgh.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21106 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5930  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mvendorid.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mvendorid.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mvendorid.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21110 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5934  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.marchid.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.marchid.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.marchid.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21114 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5938  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mhartid.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mhartid.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mhartid.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21118 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5942  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mcountinhibit.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mcountinhibit.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mcountinhibit.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21122 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5946  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mcycle.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mcycle.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mcycle.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21126 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5950  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.mcycleh.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.mcycleh.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.mcycleh.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21130 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5954  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.minstret.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.minstret.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.minstret.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21134 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5958  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.minstreth.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.minstreth.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.minstreth.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21138 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5962  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.cycle.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.cycle.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.cycle.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21142 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5966  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.cycleh.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.cycleh.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.cycleh.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21146 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5970  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.instret.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.instret.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.instret.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21150 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5974  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.instreth.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.instreth.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.instreth.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21154 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5978  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.dcache.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.dcache.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.dcache.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21158 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5982  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.icache.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.icache.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.icache.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21162 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5986  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.acc_cons.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.acc_cons.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.acc_cons.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21166 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5990  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.aicfg.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.aicfg.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.aicfg.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21170 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5994  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.aistatus.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.aistatus.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.aistatus.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21174 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=5998  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.jvt.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.jvt.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.jvt.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21178 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=6002  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.pmpcfg0.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.pmpcfg0.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.pmpcfg0.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21182 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=6006  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.pmpcfg1.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.pmpcfg1.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.pmpcfg1.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21186 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=6010  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.pmpcfg2.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.pmpcfg2.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.pmpcfg2.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21190 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=6014  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.pmpcfg3.rdata  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.pmpcfg3.rdata
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.pmpcfg3.rdata <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21194 c=0.00 slack=0.00 */
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_rvfi  region=6018  makespan=3.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: rvfi_csr_o.pmpaddr  ready_cycle=1  ready_fo4=3.000  OpenSTA: report_timing -from clk_i -to rvfi_csr_o.pmpaddr
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     rvfi_csr_o.pmpaddr <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21198 c=3.00 slack=0.00 */
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_comb begin
    csr   = '0;
    instr = '0;

    if ($bits(rvfi_probes_i.instr) == $bits(instr)) begin
      instr = rvfi_probes_i.instr;
    end

    if ($bits(rvfi_probes_i.csr) == $bits(csr)) begin
      csr = rvfi_probes_i.csr;
    end

  end


  assign flush = instr.flush;
  assign issue_instr_ack = instr.issue_instr_ack;
  assign fetch_entry_valid = instr.fetch_entry_valid;
  assign instruction = instr.instruction;
  assign is_compressed = instr.is_compressed;

  assign issue_pointer = instr.issue_pointer;
  assign commit_pointer = instr.commit_pointer;

  assign flush_unissued_instr = instr.flush_unissued_instr;
  assign decoded_instr_valid = instr.decoded_instr_valid;
  assign decoded_instr_ack = instr.decoded_instr_ack;

  assign rs1 = instr.rs1;
  assign rs2 = instr.rs2;
  assign operand_valid = instr.operand_valid;
  assign operand_tid = instr.operand_tid;

  assign commit_instr_pc = instr.commit_instr_pc;
  assign commit_instr_op = instr.commit_instr_op;
  assign commit_instr_rs1 = instr.commit_instr_rs1;
  assign commit_instr_rs2 = instr.commit_instr_rs2;
  assign commit_instr_rd = instr.commit_instr_rd;
  assign commit_instr_result = instr.commit_instr_result;
  assign commit_instr_valid = instr.commit_instr_valid;
  assign commit_drop = instr.commit_drop;

  assign ex_commit_cause = instr.ex_commit_cause;
  assign ex_commit_valid = instr.ex_commit_valid;

  assign valid_iti = instr.commit_ack;
  assign pc_iti = instr.commit_instr_pc;
  assign op_iti = instr.commit_instr_op;
  assign branch_valid_iti = instr.branch_valid;
  assign is_taken_iti = instr.is_taken;
  assign tval_iti = instr.tval;
  assign time_iti = csr.cycle_q;

  assign priv_lvl = instr.priv_lvl;

  assign wbdata = instr.wbdata;
  assign commit_ack = instr.commit_ack;
  assign mem_paddr = instr.mem_paddr;
  assign debug_mode = instr.debug_mode;
  assign wdata = instr.wdata;

  assign lsu_addr = instr.lsu_ctrl_vaddr;
  assign lsu_rmask = instr.lsu_ctrl_fu == LOAD ? instr.lsu_ctrl_be : '0;
  // A load-reserved is dispatched down the STORE path like every other AMO, but
  // it only reads memory. Reporting a write mask for it makes the tracer emit a
  // memory write the architecture never performs, which diverges from any
  // reference model on the first LR.
  assign lsu_wmask = (instr.lsu_ctrl_fu == STORE &&
                      !(G6LCCfg.RVA && instr.lsu_ctrl_op inside {AMO_LRW, AMO_LRD}))
      ? instr.lsu_ctrl_be : '0;
  assign lsu_addr_trans_id = instr.lsu_ctrl_trans_id;
  assign branch_trans_id = instr.branch_trans_id;



  //ID STAGE

  // The per-port instruction encoding and RVC flag arrive issue-aligned from
  // id_stage's issue register (rvfi_instr_o / rvfi_is_compressed_o), so no
  // local capture model is needed. instr.issue_instr_ack and
  // instr.fetch_entry_valid remain in the probe struct for compatibility but
  // are no longer read here.

  //ISSUE STAGE

  // this is the FIFO struct of the issue queue
  typedef struct packed {
    logic [G6LCCfg.XLEN-1:0] rs1_rdata;
    logic [G6LCCfg.XLEN-1:0] rs2_rdata;
    logic [G6LCCfg.VLEN-1:0] lsu_addr;
    logic [(G6LCCfg.XLEN/8)-1:0] lsu_rmask;
    logic [(G6LCCfg.XLEN/8)-1:0] lsu_wmask;
    logic [G6LCCfg.XLEN-1:0] lsu_wdata;
    // r76 F14: the store/AMO's own translated paddr, captured at its
    // queue-accept strobe (mem_paddr is the spec STQ head at commit,
    // not this instruction, under OoO issue).
    logic [G6LCCfg.PLEN-1:0] lsu_paddr;
    logic paddr_valid;
    logic [31:0] instr;
    logic branch_valid;
    logic is_taken;
    logic is_compressed;
  } sb_mem_t;
  sb_mem_t [G6LCCfg.NR_SB_ENTRIES-1:0] mem_q, mem_n;

  always_comb begin : issue_fifo
    mem_n = mem_q;

    for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
      if (decoded_instr_valid[i] && decoded_instr_ack[i] && !flush_unissued_instr) begin
        mem_n[issue_pointer[i]] = '{
            rs1_rdata: rs1[i],
            rs2_rdata: rs2[i],
            lsu_addr: '0,
            lsu_rmask: '0,
            lsu_wmask: '0,
            lsu_wdata: '0,
            lsu_paddr: '0,
            paddr_valid: 1'b0,
            instr: instruction[i],
            branch_valid: 1'b0,
            is_taken: 1'b0,
            is_compressed: is_compressed[i]
        };
      end
    end
    // Operands are READ at issue, not at dispatch. In order those are the same
    // instruction in the same cycle, so the capture above is sound. Under OoO
    // the issue queue offers an older ready entry while a different instruction
    // is being dispatched, so keying rs1/rs2 by dispatch port records another
    // instruction's operand values -- which is how AMO mem_wdata, computed from
    // rs2, came out as the pre-operation value. Re-capture them against the
    // identity that actually owns them.
    if (G6LCCfg.OoOEn) begin
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        if (operand_valid[i]) begin
          mem_n[operand_tid[i]].rs1_rdata = rs1[i];
          mem_n[operand_tid[i]].rs2_rdata = rs2[i];
        end
      end
    end
    if (branch_valid_iti) begin
      mem_n[branch_trans_id].branch_valid = branch_valid_iti;
      mem_n[branch_trans_id].is_taken = is_taken_iti;
    end
    if (lsu_rmask != 0) begin
      mem_n[lsu_addr_trans_id].lsu_addr  = lsu_addr;
      mem_n[lsu_addr_trans_id].lsu_rmask = lsu_rmask;
    end else if (lsu_wmask != 0) begin
      mem_n[lsu_addr_trans_id].lsu_addr  = lsu_addr;
      mem_n[lsu_addr_trans_id].lsu_wmask = lsu_wmask;
      mem_n[lsu_addr_trans_id].lsu_wdata = wbdata[STORE_WB];
    end
    // r76 F14: per-instruction paddr capture — a store enters the
    // speculative STQ (and an AMO the amo_buffer) strictly before its
    // own commit, so the record is complete when the entry retires.
    if (instr.st_push_valid) begin
      mem_n[instr.st_push_tid].lsu_paddr   = instr.st_push_paddr;
      mem_n[instr.st_push_tid].paddr_valid = 1'b1;
    end
    if (instr.amo_push_valid) begin
      mem_n[instr.amo_push_tid].lsu_paddr   = instr.amo_push_paddr;
      mem_n[instr.amo_push_tid].paddr_valid = 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : regs
    if (!rst_ni) begin
      mem_q <= '{default: sb_mem_t'(0)};
    end else begin
      mem_q <= mem_n;
    end
  end

  //----------------------------------------------------------------------------------------------------------
  // PACK
  //----------------------------------------------------------------------------------------------------------

  always_ff @(posedge clk_i) begin
    for (int i = 0; i < G6LCCfg.NrCommitPorts; i++) begin
      logic exception;
      logic valid;
      exception = (i == 0) && commit_instr_valid[i] && ex_commit_valid && !commit_drop[i];
      valid     = (commit_ack[i] && !ex_commit_valid && !commit_drop[i]) ||
        (exception && (ex_commit_cause == riscv::ENV_CALL_MMODE ||
                  ex_commit_cause == riscv::ENV_CALL_SMODE ||
                  ex_commit_cause == riscv::ENV_CALL_UMODE));
      rvfi_instr_o[i].valid <= valid;
      rvfi_instr_o[i].insn  <= mem_q[commit_pointer[i]].instr;
      // when synchronous trap, the instruction is not executed
      rvfi_instr_o[i].trap  <= exception && !ex_commit_cause[31];

      if (exception && ex_commit_cause[31]) begin
        rvfi_intr[i] <= 'b101;
      end else if (exception) begin
        rvfi_intr[i] <= 'b11;
      end
      if (valid) begin
        rvfi_intr[i] <= 0;
      end

      rvfi_instr_o[i].intr <= rvfi_intr[i];

      rvfi_instr_o[i].cause <= ex_commit_cause;
      rvfi_instr_o[i].mode <= (G6LCCfg.DebugEn && debug_mode) ? 2'b10 : priv_lvl;
      rvfi_instr_o[i].ixl <= G6LCCfg.IS_XLEN64 ? 2 : 1;
      rvfi_instr_o[i].rs1_addr <= commit_instr_rs1[i];
      rvfi_instr_o[i].rs2_addr <= commit_instr_rs2[i];
      rvfi_instr_o[i].rd_addr <= commit_instr_rd[i];
      rvfi_instr_o[i].rd_wdata <= (G6LCCfg.FpPresent && is_rd_fpr(
          commit_instr_op[i]
      )) ? commit_instr_result[i] : wdata[i];
      rvfi_instr_o[i].pc_rdata <= commit_instr_pc[i];
      rvfi_hart_o[i] <= instr.commit_instr_hart[i];
      rvfi_instr_o[i].mem_addr <= mem_q[commit_pointer[i]].lsu_addr;
      // So far, only write paddr is reported. TODO: read paddr.
      // r76 F14: a store/AMO reports the paddr captured at its own
      // queue-accept strobe — the bus is the speculative STQ head at
      // commit time, which under OoO issue is not the committing
      // store (hyp8_f14_store_offset reported tohost=0xAD this way).
      rvfi_instr_o[i].mem_paddr <=
          mem_q[commit_pointer[i]].paddr_valid
              ? mem_q[commit_pointer[i]].lsu_paddr : mem_paddr;
      // A store-conditional that fails performs no memory write. The mask is
      // captured at LSU time, before the outcome is known, so it has to be
      // suppressed here where the result is available: rd == 0 is success.
      rvfi_instr_o[i].mem_wmask <= (G6LCCfg.RVA &&
                                    is_amo_sc(commit_instr_op[i]) && |wdata[i])
          ? '0 : mem_q[commit_pointer[i]].lsu_wmask;

      // For AMO operations, compute the actual write value
      // Note: AMO operations write a computed value to memory, not the original register value
      if (is_amo(commit_instr_op[i])) begin
        rvfi_instr_o[i].mem_wdata <= compute_amo_wdata(
            commit_instr_op[i],  // AMO operation type
            wdata[i],  // Old memory value (the value returned to rd)
            mem_q[commit_pointer[i]].rs2_rdata  // Register operand (rs2)
        );
      end else begin
        rvfi_instr_o[i].mem_wdata <= mem_q[commit_pointer[i]].lsu_wdata;
      end

      rvfi_instr_o[i].mem_rmask <= mem_q[commit_pointer[i]].lsu_rmask;
      rvfi_instr_o[i].mem_rdata <= commit_instr_result[i];
      rvfi_instr_o[i].rs1_rdata <= mem_q[commit_pointer[i]].rs1_rdata;
      rvfi_instr_o[i].rs2_rdata <= mem_q[commit_pointer[i]].rs2_rdata;
      rvfi_to_iti_o.branch_valid[i] <= mem_q[commit_pointer[i]].branch_valid;
      rvfi_to_iti_o.is_taken[i] <= mem_q[commit_pointer[i]].is_taken;
      rvfi_to_iti_o.is_compressed[i] <= mem_q[commit_pointer[i]].is_compressed;
      rvfi_to_iti_o.valid[i] <= valid_iti[i];
      rvfi_to_iti_o.pc[i] <= pc_iti[i];
      rvfi_to_iti_o.op[i] <= op_iti[i];
    end
    rvfi_to_iti_o.ex_valid <= ex_commit_valid;
    rvfi_to_iti_o.cycles <= time_iti;
    rvfi_to_iti_o.cause <= ex_commit_cause;
    rvfi_to_iti_o.tval <= tval_iti;
    rvfi_to_iti_o.priv_lvl <= priv_lvl;
  end


  //----------------------------------------------------------------------------------------------------------
  // CSR
  //----------------------------------------------------------------------------------------------------------
  // Changing verible formating to fix vivado synthesis errors and warnings
  // verilog_format: off
  // Zero-extend with XLEN'(src). `{ {XLEN-$bits(src)}, src }` is integer concat
  // (32+src bits), which Verilator WIDTHTRUNCs into the XLEN CSR fields.
  `define CONNECT_RVFI_FULL(CSR_ENABLE_COND, CSR_NAME, CSR_SOURCE_NAME) \
  always_ff @(posedge clk_i) begin \
      if (CSR_ENABLE_COND) begin \
          rvfi_csr_o.``CSR_NAME``.rdata <= G6LCCfg.XLEN'(CSR_SOURCE_NAME); \
      end \
  end \
  assign rvfi_csr_o.``CSR_NAME``.wdata = CSR_ENABLE_COND ? G6LCCfg.XLEN'(CSR_SOURCE_NAME) : '0; \
  assign rvfi_csr_o.``CSR_NAME``.rmask = CSR_ENABLE_COND ? G6LCCfg.XLEN'(1'b1) : '0; \
  assign rvfi_csr_o.``CSR_NAME``.wmask = G6LCCfg.XLEN'( \
      (rvfi_csr_o.``CSR_NAME``.rdata != G6LCCfg.XLEN'(CSR_SOURCE_NAME)) && CSR_ENABLE_COND);

  `define CONNECT_RVFI_SAME(CSR_ENABLE_COND, CSR_NAME) \
          `CONNECT_RVFI_FULL(CSR_ENABLE_COND, CSR_NAME, csr.``CSR_NAME``_q)

  if ($bits(rvfi_csr_o) != 1) begin
    `CONNECT_RVFI_FULL(G6LCCfg.FpPresent, fflags, csr.fcsr_q.fflags)
    `CONNECT_RVFI_FULL(G6LCCfg.FpPresent, frm, csr.fcsr_q.frm)
    `CONNECT_RVFI_FULL(G6LCCfg.FpPresent, fcsr, {csr.fcsr_q.frm, csr.fcsr_q.fflags})

    `CONNECT_RVFI_FULL(G6LCCfg.FpPresent, ftran, csr.fcsr_q.fprec)
    `CONNECT_RVFI_SAME(G6LCCfg.FpPresent, dcsr)

    `CONNECT_RVFI_SAME(G6LCCfg.DebugEn, dpc)

    `CONNECT_RVFI_SAME(G6LCCfg.DebugEn, dscratch0)
    `CONNECT_RVFI_SAME(G6LCCfg.DebugEn, dscratch1)

    `CONNECT_RVFI_FULL(G6LCCfg.RVS, sstatus, csr.mstatus_extended & SMODE_STATUS_READ_MASK[G6LCCfg.XLEN-1:0])

    `CONNECT_RVFI_FULL(G6LCCfg.RVS, sie, csr.mie_q & csr.mideleg_q)
    `CONNECT_RVFI_FULL(G6LCCfg.RVS, sip, csr.mip_q & csr.mideleg_q)

    `CONNECT_RVFI_SAME(G6LCCfg.RVS, stvec)

    `CONNECT_RVFI_SAME(G6LCCfg.RVS, scounteren)

    `CONNECT_RVFI_SAME(G6LCCfg.RVS, sscratch)
    `CONNECT_RVFI_SAME(G6LCCfg.RVS, sepc)

    `CONNECT_RVFI_SAME(G6LCCfg.RVS, scause)

    `CONNECT_RVFI_SAME(G6LCCfg.RVS, stval)
    `CONNECT_RVFI_SAME(G6LCCfg.RVS, satp)

    `CONNECT_RVFI_FULL(1'b1, mstatus, csr.mstatus_extended)

    bit [31:0] mstatush_q;
    `CONNECT_RVFI_FULL(1'b1, mstatush, mstatush_q)

    `CONNECT_RVFI_FULL(1'b1, misa, IsaCode)

    `CONNECT_RVFI_SAME(G6LCCfg.RVS, medeleg)
    `CONNECT_RVFI_SAME(G6LCCfg.RVS, mideleg)

    `CONNECT_RVFI_SAME(1'b1, mie)
    `CONNECT_RVFI_SAME(1'b1, mtvec)
    `CONNECT_RVFI_SAME(1'b1, mcounteren)

    `CONNECT_RVFI_SAME(1'b1, mscratch)

    `CONNECT_RVFI_SAME(1'b1, mepc)
    `CONNECT_RVFI_SAME(1'b1, mcause)
    `CONNECT_RVFI_SAME(1'b1, mtval)
    `CONNECT_RVFI_SAME(1'b1, mip)

    `CONNECT_RVFI_FULL(1'b1, menvcfg, csr.fiom_q)

    `CONNECT_RVFI_FULL(G6LCCfg.IS_XLEN32, menvcfgh, 32'h0)

    `CONNECT_RVFI_FULL(1'b1, mvendorid, G6LC_MVENDORID)
    `CONNECT_RVFI_FULL(1'b1, marchid, G6LC_MARCHID)
    `CONNECT_RVFI_FULL(1'b1, mhartid, hart_id_i)

    `CONNECT_RVFI_SAME(1'b1, mcountinhibit)

    `CONNECT_RVFI_FULL(1'b1, mcycle, csr.cycle_q[G6LCCfg.XLEN-1:0])
    `CONNECT_RVFI_FULL(G6LCCfg.IS_XLEN32, mcycleh, csr.cycle_q[63:32])

    `CONNECT_RVFI_FULL(1'b1, minstret, csr.instret_q[G6LCCfg.XLEN-1:0])
    `CONNECT_RVFI_FULL(G6LCCfg.IS_XLEN32, minstreth, csr.instret_q[63:32])

    `CONNECT_RVFI_FULL(1'b1, cycle, csr.cycle_q[G6LCCfg.XLEN-1:0])
    `CONNECT_RVFI_FULL(G6LCCfg.IS_XLEN32, cycleh, csr.cycle_q[63:32])

    `CONNECT_RVFI_FULL(1'b1, instret, csr.instret_q[G6LCCfg.XLEN-1:0])
    `CONNECT_RVFI_FULL(G6LCCfg.IS_XLEN32, instreth, csr.instret_q[63:32])

    `CONNECT_RVFI_SAME(1'b1, dcache)
    `CONNECT_RVFI_SAME(1'b1, icache)

    `CONNECT_RVFI_SAME(G6LCCfg.EnableAccelerator, acc_cons)
    `CONNECT_RVFI_SAME(G6LCCfg.AiCfg.MatrixEn, aicfg)
    `CONNECT_RVFI_SAME(G6LCCfg.AiCfg.MatrixEn, aistatus)
    `CONNECT_RVFI_SAME(G6LCCfg.RVZCMT, jvt)
    `CONNECT_RVFI_FULL(1'b1, pmpcfg0, csr.pmpcfg_q[G6LCCfg.XLEN/8-1:0])
    `CONNECT_RVFI_FULL(G6LCCfg.IS_XLEN32, pmpcfg1, csr.pmpcfg_q[7:4])

    `CONNECT_RVFI_FULL(1'b1, pmpcfg2, csr.pmpcfg_q[8+:G6LCCfg.XLEN/8])
    `CONNECT_RVFI_FULL(G6LCCfg.IS_XLEN32, pmpcfg3, csr.pmpcfg_q[15:12])

    bit [G6LCCfg.XLEN-1:0] pmpaddr_q;
    genvar i;
    for (i = 0; i < 16; i++) begin
      `CONNECT_RVFI_FULL(1'b1, pmpaddr[i], {csr.pmpaddr_q[i][G6LCCfg.PLEN-3:1], pmpcfg_q[i].addr_mode[1]})
    end
    ;
  end
  // verilog_format: on
  //------------------------------------------------------------------------
  // r76 F14: a committing store/AMO must have its own paddr captured.
  //------------------------------------------------------------------------
`ifndef SYNTHESIS
  for (genvar gi = 0; gi < G6LCCfg.NrCommitPorts; gi++) begin : gen_paddr_chk
    lu_paddr_captured :
    assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (commit_ack[gi] && !ex_commit_valid && !commit_drop[gi] &&
         mem_q[commit_pointer[gi]].lsu_wmask != '0)
        |-> mem_q[commit_pointer[gi]].paddr_valid)
      else $error("rvfi F14: committing store/AMO tid=%0d with no captured paddr (wmask=%b)",
                  commit_pointer[gi],
                  mem_q[commit_pointer[gi]].lsu_wmask);
  end
`endif

endmodule
