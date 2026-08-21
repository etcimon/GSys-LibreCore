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
// Date: 15.04.2017
// Description: Instruction decode, contains the logic for decode,
//              issue and read operands.

module id_stage #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type branchpredict_sbe_t = logic,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type exception_t = logic,
    parameter type fetch_entry_t = logic,
    parameter type jvt_t = logic,
    parameter type irq_ctrl_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type interrupts_t = logic,
    parameter interrupts_t INTERRUPTS = '0,
    parameter type x_compressed_req_t = logic,
    parameter type x_compressed_resp_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Fetch flush request - CONTROLLER
    input logic flush_i,
    // Debug (async) request - SUBSYSTEM
    input logic debug_req_i,
    // Handshake's data between fetch and decode - FRONTEND
    input fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_i,
    // Handshake's valid between fetch and decode - FRONTEND
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_i,
    // Handshake's ready between fetch and decode - FRONTEND
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_o,
    // G1lq: IQ-visible aligned-00 RVI LOAD
    // (frontend g1ct_valid latch). Flop
    // into g1lo_cap only — not G1lm IQ
    // rewrite. G1ma: one latch per hart.
    input logic [CVA6Cfg.NrHarts-1:0] g1lq_v_i,
    input logic [CVA6Cfg.NrHarts-1:0][4:0] g1lq_rd_i,
    input logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1lq_line_i,
    input logic [CVA6Cfg.NrHarts-1:0] g1lq_a3_i,
    // G1md: commit-visible aligned-00 RVI
    // LOAD into g1lo (G1lq analog from
    // retire). Flop only — not G1lm IQ
    // rewrite.
    input scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0] commit_instr_i,
    input logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack_i,
    // G1mf: SB result-valid aligned-00
    // RVI LOAD (before commit_ack).
    input logic [CVA6Cfg.NrHarts-1:0] g1mf_v_i,
    input logic [CVA6Cfg.NrHarts-1:0][4:0] g1mf_rd_i,
    input logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1mf_line_i,
    input logic [CVA6Cfg.NrHarts-1:0] g1mf_a3_i,
    // Handshake's data between decode and issue - ISSUE
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_entry_o,
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_entry_o_prev,
    // Instruction value - ISSUE
    output logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_o,
    // Handshake's valid between decode and issue - ISSUE
    output logic [CVA6Cfg.NrIssuePorts-1:0] issue_entry_valid_o,
    // Report if instruction is a control flow instruction - ISSUE
    output logic [CVA6Cfg.NrIssuePorts-1:0] is_ctrl_flow_o,
    // Handshake's acknowledge between decode and issue - ISSUE
    input logic [CVA6Cfg.NrIssuePorts-1:0] issue_instr_ack_i,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0] rvfi_is_compressed_o,
    // Current privilege level - CSR_REGFILE
    input riscv::priv_lvl_t priv_lvl_i,
    // Current virtualization mode - CSR_REGFILE
    input logic v_i,
    // Floating point extension status - CSR_REGFILE
    input riscv::xs_t fs_i,
    // Floating point extension virtual status - CSR_REGFILE
    input riscv::xs_t vfs_i,
    // Floating point dynamic rounding mode - CSR_REGFILE
    input logic [2:0] frm_i,
    // Vector extension status - CSR_REGFILE
    input riscv::xs_t vs_i,
    // Level sensitive (async) interrupts - SUBSYSTEM
    input logic [1:0] irq_i,
    // Interrupt control status - CSR_REGFILE
    input irq_ctrl_t irq_ctrl_i,
    // Is current mode debug ? - CSR_REGFILE
    input logic debug_mode_i,
    // Trap virtual memory - CSR_REGFILE
    input logic tvm_i,
    // Timeout wait - CSR_REGFILE
    input logic tw_i,
    // Virtual timeout wait - CSR_REGFILE
    input logic vtw_i,
    // Trap sret - CSR_REGFILE
    input logic tsr_i,
    // Hypervisor user mode - CSR_REGFILE
    input logic hu_i,
    // machine-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t mcbie_i,
    // supervisor-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t scbie_i,
    // hypervisor-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t hcbie_i,
    // machine-mode clean/flush cache block enable - CSR_REGFILE
    input logic mcbcfe_i,
    // supervisor-mode clean/flush cache block enable - CSR_REGFILE
    input logic scbcfe_i,
    // hypervisor-mode clean/flush cache block enable - CSR_REGFILE
    input logic hcbcfe_i,
    // cbo.zero enable (menvcfg/senvcfg/henvcfg.CBZE) - CSR_REGFILE
    input logic mcbze_i,
    input logic scbze_i,
    input logic hcbze_i,
    // CVXIF Compressed interface
    input logic [CVA6Cfg.XLEN-1:0] hart_id_i,
    // U6.1 SMT active thread tag (0 when NrHarts==1)
    input logic [((CVA6Cfg.NrHarts <= 1) ? 1 : $clog2(CVA6Cfg.NrHarts))-1:0] smt_hart_id_i,
    input logic compressed_ready_i,
    //JVT
    input jvt_t jvt_i,
    input x_compressed_resp_t compressed_resp_i,
    output logic compressed_valid_o,
    output x_compressed_req_t compressed_req_o,
    // breakpoint request from trigger module
    input debug_from_trigger_i,
    // Data cache request ouput - CACHE
    input dcache_req_o_t dcache_req_ports_i,
    // Data cache request input - CACHE
    output dcache_req_i_t dcache_req_ports_o
);
  // ID/ISSUE register stage
  typedef struct packed {
    logic              valid;
    scoreboard_entry_t sbe;
    logic [31:0]       orig_instr;
    logic              is_ctrl_flow;
  } issue_struct_t;
  issue_struct_t [CVA6Cfg.NrIssuePorts-1:0] issue_n, issue_q;
  // stall required for ZCMP ZCMT CVXIF
  logic              [CVA6Cfg.NrIssuePorts-1:0]       stall_instr_fetch;

  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_control_flow_instr;
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       decoded_instruction;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       decoded_instruction_valid;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr;

  // Compressed decoder signals
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_illegal_rvc;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] instruction_rvc;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] instruction_rvc_raw;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_compressed_rvc;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_zcmt_instr;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_macro_instr;

  // CVXIF compressed interface driver signals
  // Inputs
  logic                                               is_illegal_cvxif_i;
  logic              [                    31:0]       instruction_cvxif_i;
  logic                                               is_compressed_cvxif_i;
  logic                                               stall_macro_deco;
  // Outputs
  logic                                               is_illegal_cvxif_o;
  logic              [                    31:0]       instruction_cvxif_o;
  logic                                               is_compressed_cvxif_o;

  // ZCMP decoder signals
  logic                                               is_illegal_zcmp;
  logic              [                    31:0]       instruction_zcmp;
  logic                                               is_compressed_zcmp;
  logic                                               stall_macro_deco_zcmp;
  logic                                               is_last_macro_instr;
  logic                                               is_double_rd_macro_instr;

  // ZCMT decoder signals
  logic                                               is_illegal_zcmt;
  logic              [                    31:0]       instruction_zcmt;
  logic                                               is_compressed_zcmt;
  logic                                               stall_macro_deco_zcmt;
  logic              [        CVA6Cfg.XLEN-1:0]       jump_address;

  // Decoder signals
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_illegal_deco;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] instruction_deco;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_compressed_deco;


  if (CVA6Cfg.RVC) begin
    // ---------------------------------------------------------
    // 1. Check if they are compressed and expand in case they are
    // ---------------------------------------------------------
    for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      // G1gw: mid-line [2:1]==01 whose 16-bit
      // encoding is already c.jalr ([15:12]
      // ==1001, [6:2]==0, rs1!=0) must expand
      // as jalr. Not G1gv [6:2] mash. Not
      // G1gt any-RVI. SMT+SS.
      // G1gy: same when the *high* 16-bit is
      // exact c.jalr (unshifted {c.jalr,
      // c.beqz} at 7ba). G1gw sees only the
      // low half (c.beqz). Not G1gt any-RVI.
      // Not G1gu BRANCH-low. SMT+SS.
      logic g1gy_lo;
      logic g1gy_hi;
      compressed_decoder #(
          .CVA6Cfg(CVA6Cfg)
      ) compressed_decoder_i (
          .instr_i         (fetch_entry_i[i].instruction),
          .instr_o         (instruction_rvc_raw[i]),
          .illegal_instr_o (is_illegal_rvc[i]),
          .is_compressed_o (is_compressed_rvc[i]),
          .is_macro_instr_o(is_macro_instr[i]),
          .is_zcmt_instr_o (is_zcmt_instr[i])
      );
      assign g1gy_lo =
          (fetch_entry_i[i].instruction[15:12] == 4'b1001) &&
          (fetch_entry_i[i].instruction[6:2] == 5'd0) &&
          (fetch_entry_i[i].instruction[11:7] != 5'd0);
      assign g1gy_hi =
          (fetch_entry_i[i].instruction[31:28] == 4'b1001) &&
          (fetch_entry_i[i].instruction[22:18] == 5'd0) &&
          (fetch_entry_i[i].instruction[27:23] != 5'd0) &&
          (fetch_entry_i[i].instruction[17:16] == 2'b10);
      // I1: B never synthesises a JALR. G1gw/gy matched c.srli
      // (shamt=32, [15:12]=1001 [6:2]=0) at pc[2:1]==01 because they
      // omitted the C2 quadrant. A/slfix keeps the recover.
`ifdef G6LC_FETCH_B
      assign instruction_rvc[i] = instruction_rvc_raw[i];
`else
      assign instruction_rvc[i] =
          (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
           (fetch_entry_i[i].address[2:1] == 2'b01) &&
           (g1gy_lo || g1gy_hi))
              ? {12'b0,
                 (g1gy_lo ? fetch_entry_i[i].instruction[11:7]
                          : fetch_entry_i[i].instruction[27:23]),
                 3'b000, 5'b00001, riscv::OpcodeJalr}
              : instruction_rvc_raw[i];
`endif
    end

    if (CVA6Cfg.SuperscalarEn) begin
      // Ports 1..N-1: no ZCMP/ZCMT/CVXIF expansion; stall only on illegal RVC/macro/zcmt
      for (genvar si = 1; si < CVA6Cfg.NrIssuePorts; si++) begin : gen_ss_stall
        assign stall_instr_fetch[si] =
            is_illegal_rvc[si] || is_macro_instr[si] || is_zcmt_instr[si];
      end
    end

    if (CVA6Cfg.RVZCMP) begin
      macro_decoder #(
          .CVA6Cfg(CVA6Cfg)
      ) macro_decoder_i (
          .instr_i                   (instruction_rvc[0]),
          .is_macro_instr_i          (is_macro_instr[0]),
          .clk_i                     (clk_i),
          .rst_ni                    (rst_ni),
          .instr_o                   (instruction_zcmp),
          .illegal_instr_i           (is_illegal_rvc[0]),
          .is_compressed_i           (is_compressed_rvc[0]),
          .issue_ack_i               (issue_instr_ack_i[0]),
          .illegal_instr_o           (is_illegal_zcmp),
          .is_compressed_o           (is_compressed_zcmp),
          .fetch_stall_o             (stall_macro_deco_zcmp),
          .is_last_macro_instr_o     (is_last_macro_instr),
          .is_double_rd_macro_instr_o(is_double_rd_macro_instr)
      );
    end else begin
      assign instruction_zcmp         = instruction_rvc;
      assign is_illegal_zcmp          = is_illegal_rvc;
      assign is_compressed_zcmp       = is_compressed_rvc;
      assign stall_macro_deco_zcmp    = '0;
      assign is_last_macro_instr      = '0;
      assign is_double_rd_macro_instr = '0;
    end

    if (CVA6Cfg.RVZCMT) begin
      zcmt_decoder #(
          .CVA6Cfg(CVA6Cfg),
          .dcache_req_i_t(dcache_req_i_t),
          .dcache_req_o_t(dcache_req_o_t),
          .jvt_t(jvt_t),
          .branchpredict_sbe_t(branchpredict_sbe_t)
      ) zcmt_decoder_i (
          .instr_i        (instruction_rvc[0]),
          .pc_i           (fetch_entry_i[0].address),
          .is_zcmt_instr_i(is_zcmt_instr[0]),
          .clk_i          (clk_i),
          .rst_ni         (rst_ni),
          .instr_o        (instruction_zcmt),
          .illegal_instr_i(is_illegal_rvc[0]),
          .is_compressed_i(is_compressed_rvc[0]),
          .illegal_instr_o(is_illegal_zcmt),
          .is_compressed_o(is_compressed_zcmt),
          .fetch_stall_o  (stall_macro_deco_zcmt),
          .jvt_i          (jvt_i),
          .req_port_i     (dcache_req_ports_i),
          .req_port_o     (dcache_req_ports_o),
          .jump_address_o (jump_address)
      );
    end else begin
      assign instruction_zcmt      = instruction_rvc;
      assign is_illegal_zcmt       = is_illegal_rvc;
      assign is_compressed_zcmt    = is_compressed_rvc;
      assign stall_macro_deco_zcmt = '0;
      assign jump_address          = '0;
    end

    if (CVA6Cfg.RVZCMT) begin
      assign instruction_cvxif_i = is_zcmt_instr[0] ? instruction_zcmt : instruction_zcmp;
      assign is_illegal_cvxif_i = is_zcmt_instr[0] ? is_illegal_zcmt : is_illegal_zcmp;
      assign is_compressed_cvxif_i = is_zcmt_instr[0] ? is_compressed_zcmt : is_compressed_zcmp;
      assign stall_macro_deco = is_zcmt_instr[0] ? stall_macro_deco_zcmt : stall_macro_deco_zcmp;
    end else begin  // Do not instantiate the mux which is not optimized cross-boundaries
      assign instruction_cvxif_i = instruction_zcmp;
      assign is_illegal_cvxif_i = is_illegal_zcmp;
      assign is_compressed_cvxif_i = is_compressed_zcmp;
      assign stall_macro_deco = stall_macro_deco_zcmp;
    end

    if (CVA6Cfg.CvxifEn) begin
      cvxif_compressed_if_driver #(
          .CVA6Cfg(CVA6Cfg),
          .x_compressed_req_t(x_compressed_req_t),
          .x_compressed_resp_t(x_compressed_resp_t)
      ) i_cvxif_compressed_if_driver_i (
          .clk_i             (clk_i),
          .rst_ni            (rst_ni),
          .flush_i           (flush_i),
          .hart_id_i         (hart_id_i),
          .is_compressed_i   (is_compressed_cvxif_i),
          .is_illegal_i      (is_illegal_cvxif_i),
          .instruction_i     (instruction_cvxif_i),
          .is_compressed_o   (is_compressed_cvxif_o),
          .is_illegal_o      (is_illegal_cvxif_o),
          .instruction_o     (instruction_cvxif_o),
          .stall_i           (stall_macro_deco),
          .stall_o           (stall_instr_fetch[0]),
          .compressed_ready_i(compressed_ready_i),
          .compressed_resp_i (compressed_resp_i),
          .compressed_valid_o(compressed_valid_o),
          .compressed_req_o  (compressed_req_o)
      );
    end else begin
      assign stall_instr_fetch[0] = stall_macro_deco;
    end
  end else begin
    for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      assign is_illegal_rvc[i] = 1'b0;
      assign instruction_rvc[i] = fetch_entry_i[i].instruction;
      assign is_compressed_rvc[i] = 1'b0;
      assign stall_instr_fetch[i] = 1'b0;
    end
  end

  // ---------------------------------------------------------
  // 2. Decode and emit instruction to issue stage
  // ---------------------------------------------------------

  always_comb begin
    // No CVXIF, No ZCMP, No ZCMT => Connect directly compressed decoder to decoder
    is_illegal_deco    = is_illegal_rvc;
    instruction_deco   = instruction_rvc;
    is_compressed_deco = is_compressed_rvc;
    if (CVA6Cfg.RVC) begin
      if (CVA6Cfg.CvxifEn) begin
        is_illegal_deco[0]    = is_illegal_cvxif_o;
        instruction_deco[0]   = instruction_cvxif_o;
        is_compressed_deco[0] = is_compressed_cvxif_o;
      end else if (CVA6Cfg.RVZCMP || CVA6Cfg.RVZCMT) begin
        is_illegal_deco[0]    = is_illegal_cvxif_i;
        instruction_deco[0]   = instruction_cvxif_i;
        is_compressed_deco[0] = is_compressed_cvxif_i;
      end
    end
  end

  assign rvfi_is_compressed_o = is_compressed_rvc;

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    decoder #(
        .CVA6Cfg(CVA6Cfg),
        .branchpredict_sbe_t(branchpredict_sbe_t),
        .exception_t(exception_t),
        .irq_ctrl_t(irq_ctrl_t),
        .scoreboard_entry_t(scoreboard_entry_t),
        .interrupts_t(interrupts_t),
        .INTERRUPTS(INTERRUPTS)
    ) decoder_i (
        .debug_req_i,
        .irq_ctrl_i,
        .irq_i,
        .pc_i                      (fetch_entry_i[i].address),
        .is_compressed_i           (is_compressed_deco[i]),
        .is_macro_instr_i          (is_macro_instr[i]),
        .is_zcmt_i                 (is_zcmt_instr[i]),
        .is_last_macro_instr_i     (is_last_macro_instr),
        .is_double_rd_macro_instr_i(is_double_rd_macro_instr),
        .jump_address_i            (jump_address),
        .is_illegal_i              (is_illegal_deco[i]),
        .instruction_i             (instruction_deco[i]),
        .compressed_instr_i        (fetch_entry_i[i].instruction[15:0]),
        .branch_predict_i          (fetch_entry_i[i].branch_predict),
        .ex_i                      (fetch_entry_i[i].ex),
        .priv_lvl_i                (priv_lvl_i),
        .v_i                       (v_i),
        .debug_mode_i              (debug_mode_i),
        .fs_i,
        .vfs_i,
        .frm_i,
        .vs_i,
        .tvm_i,
        .tw_i,
        .vtw_i,
        .tsr_i,
        .hu_i,
        .mcbie_i,
        .scbie_i,
        .hcbie_i,
        .mcbcfe_i,
        .scbcfe_i,
        .hcbcfe_i,
        .mcbze_i,
        .scbze_i,
        .hcbze_i,
`ifdef G6LC_FETCH_B
        .smt_hart_id_i             (fetch_entry_i[i].hart_id),
`else
        .smt_hart_id_i             (smt_hart_id_i),
`endif
        .instruction_o             (decoded_instruction[i]),
        .orig_instr_o              (orig_instr[i]),
        .is_control_flow_instr_o   (is_control_flow_instr[i]),
        .debug_from_trigger_i      (debug_from_trigger_i)
    );
  end

  // G1hd: issued op is JALR when mid-line PC
  // and fetch_entry has exact c.jalr in either
  // half (G1gy analog after ID). Not G1gt
  // any-RVI. Not G1gz. SMT+SS.
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_hd;
  logic              [CVA6Cfg.NrIssuePorts-1:0] is_cf_hd;
  // G1ik: in-ID aligned Branch (issue_q)
  // arms same-line 01 recover the cycle
  // 7b8 sits in ID and 7ba is on fetch.
  // G1je in-ID aligned-00 any op —
  // MINI-FAIL FDT hang @400000. Do not
  // re-land (yanks live mid-line 01
  // Branch after a same-line 00 op).
  logic [CVA6Cfg.NrIssuePorts-1:0]       g1ik_id_arm;
  logic [CVA6Cfg.NrIssuePorts-1:0][4:0]  g1ik_id_rs1;
  // G1ln: in-ID aligned-00 RVI LOAD
  // (issue_q) arms sibling 01 Branch
  // recover as c.jalr of that rd
  // (G1ik analog; 16-byte line + a3).
  // Keep 01 Branch-bits gate (not G1lm
  // any-01, not G1je any-op). Not G1lk.
  // SMT+SS.
  logic [CVA6Cfg.NrIssuePorts-1:0]       g1ln_id_arm;
  logic [CVA6Cfg.NrIssuePorts-1:0][4:0]  g1ln_id_rd;
  // G1lz: per-hart g1lo hit (same-hart
  // sibling 01 of that hart's latched
  // 00 LOAD). Not G1lm. SMT+SS.
  logic [CVA6Cfg.NrIssuePorts-1:0]       g1lz_hit;
  always_comb begin
    g1ik_id_arm = '0;
    g1ik_id_rs1 = '0;
    g1ln_id_arm = '0;
    g1ln_id_rd  = '0;
    g1lz_hit    = '0;
    // I1: B never arms sibling c.jalr recover. A keeps G1ik/ln/lz.
`ifndef G6LC_FETCH_B
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
        g1lz_hit[i] = g6lc_sib_cjalr::lz_hit(
            CVA6Cfg, g1lo_v_q[fetch_entry_i[i].hart_id],
            fetch_entry_i[i].address[CVA6Cfg.VLEN-1:4] ==
                g1lo_line_q[fetch_entry_i[i].hart_id],
            fetch_entry_i[i].address[3] !=
                g1lo_a3_q[fetch_entry_i[i].hart_id]);
        for (int unsigned j = 0; j < CVA6Cfg.NrIssuePorts; j++) begin
          if (g6lc_sib_cjalr::ik_arm(
                  CVA6Cfg, issue_q[j].valid,
                  issue_q[j].sbe.pc[2:1] == 2'b00,
                  ariane_pkg::op_is_branch(issue_q[j].sbe.op),
                  issue_q[j].sbe.pc[CVA6Cfg.VLEN-1:3] ==
                      fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3])) begin
            g1ik_id_arm[i] = 1'b1;
            g1ik_id_rs1[i] = issue_q[j].sbe.rs1[4:0];
          end
          if (g6lc_sib_cjalr::ln_arm(
                  CVA6Cfg, issue_q[j].valid,
                  issue_q[j].sbe.hart_id ==
                      fetch_entry_i[i].hart_id,
                  issue_q[j].sbe.pc[2:1] == 2'b00,
                  issue_q[j].sbe.fu == ariane_pkg::LOAD,
                  issue_q[j].sbe.rd[4:0] != 5'd0,
                  issue_q[j].sbe.pc[CVA6Cfg.VLEN-1:4] ==
                      fetch_entry_i[i].address[CVA6Cfg.VLEN-1:4],
                  issue_q[j].sbe.pc[3] !=
                      fetch_entry_i[i].address[3])) begin
            g1ln_id_arm[i] = 1'b1;
            g1ln_id_rd[i]  = issue_q[j].sbe.rd[4:0];
          end
        end
      end
    end
`endif
  end
  always_comb begin
    decoded_hd = decoded_instruction;
    is_cf_hd   = is_control_flow_instr;
    // I1: B issues the decoder's class. sib_cjalr / G1hd–ij stay A only.
`ifndef G6LC_FETCH_B
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
        if (g6lc_sib_cjalr::mid_cjalr(
                CVA6Cfg, decoded_instruction[i].pc[2:1] == 2'b01,
                fetch_entry_i[i].instruction)) begin
          decoded_hd[i].op      = ariane_pkg::JALR;
          decoded_hd[i].fu      = ariane_pkg::CTRL_FLOW;
          decoded_hd[i].rs1     = '0;
          decoded_hd[i].rd      = '0;
          decoded_hd[i].result  = '0;
          decoded_hd[i].use_imm = 1'b1;
          decoded_hd[i].use_pc  = 1'b0;
          decoded_hd[i].rs1[4:0] =
              g6lc_sib_cjalr::cjalr_rs1(fetch_entry_i[i].instruction);
          decoded_hd[i].rd[4:0] = 5'd1;
          is_cf_hd[i] = 1'b1;
        // G1hx: same 8B line, aligned
        // compressed Branch then mid-line
        // 01 Branch with the same 16-bit
        // is a mis-attributed copy (7b8
        // c.beqz at 7ba). Force JALR;
        // rs1 is the C2 rs1'. Not G1he
        // all mid-line Branch. Not G1hg
        // exact c.jalr. SMT+SS.
        end else if (g6lc_sib_cjalr::hx_rec(
            CVA6Cfg, decoded_instruction[i].pc[2:1] == 2'b01,
            g6lc_fe_keep::is_cbranch16(fetch_entry_i[i].instruction[15:0]),
            ariane_pkg::op_is_branch(decoded_instruction[i].op),
            g1hx_v_q &&
                (fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3] ==
                 g1hx_line_q) &&
                (fetch_entry_i[i].instruction[15:0] == g1hx_hw_q),
            (i != 0) &&
                (fetch_entry_i[0].address[2:1] == 2'b00) &&
                g6lc_fe_keep::is_cbranch16(
                    fetch_entry_i[0].instruction[15:0]) &&
                (fetch_entry_i[0].address[CVA6Cfg.VLEN-1:3] ==
                 fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3]) &&
                (fetch_entry_i[0].instruction[15:0] ==
                 fetch_entry_i[i].instruction[15:0]))) begin
          decoded_hd[i].op      = ariane_pkg::JALR;
          decoded_hd[i].fu      = ariane_pkg::CTRL_FLOW;
          decoded_hd[i].rs1     = '0;
          decoded_hd[i].rd      = '0;
          decoded_hd[i].result  = '0;
          decoded_hd[i].use_imm = 1'b1;
          decoded_hd[i].use_pc  = 1'b0;
          decoded_hd[i].rs1[4:0] = g6lc_sib_cjalr::cbranch_rs1(
              fetch_entry_i[i].instruction[15:0]);
          decoded_hd[i].rd[4:0] = 5'd1;
          is_cf_hd[i] = 1'b1;
        // G1hy: aligned compressed Branch
        // whose fetch_entry [31:16] is
        // exact c.jalr (7b8 {c.jalr,
        // c.beqz}). A later same-line
        // mid-line 01 Branch is that
        // jalr even if the 01 bits are
        // +4 c.bnez. Not G1hx
        // duplicate. Not G1he. Not
        // G1gy on the 01 slot. SMT+SS.
        end else if (g6lc_sib_cjalr::hy_rec(
            CVA6Cfg, decoded_instruction[i].pc[2:1] == 2'b01,
            ariane_pkg::op_is_branch(decoded_instruction[i].op),
            g1hy_v_q &&
                (fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3] ==
                 g1hy_line_q),
            (i != 0) &&
                (fetch_entry_i[0].address[2:1] == 2'b00) &&
                g6lc_rvc_enc::is_cjalr16(
                    fetch_entry_i[0].instruction[31:16]) &&
                (fetch_entry_i[0].address[CVA6Cfg.VLEN-1:3] ==
                 fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3]))) begin
          decoded_hd[i].op      = ariane_pkg::JALR;
          decoded_hd[i].fu      = ariane_pkg::CTRL_FLOW;
          decoded_hd[i].rs1     = '0;
          decoded_hd[i].rd      = '0;
          decoded_hd[i].result  = '0;
          decoded_hd[i].use_imm = 1'b1;
          decoded_hd[i].use_pc  = 1'b0;
          decoded_hd[i].rs1[4:0] = g1hy_v_q &&
              (fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3] ==
               g1hy_line_q)
              ? g1hy_rs1_q
              : fetch_entry_i[0].instruction[27:23];
          decoded_hd[i].rd[4:0] = 5'd1;
          is_cf_hd[i] = 1'b1;
        // G1id: G1hx needs the same 16-bit
        // (7ba bits are not 7b8 c.beqz).
        // G1hy needs aligned [31:16] exact
        // c.jalr. A mid-line 01 Branch on
        // the same 8B line as a just-seen
        // aligned compressed Branch is that
        // line's +2. JALR through the
        // aligned Branch's C2 rs1'. Not
        // G1he all mid-line. Not G1hx
        // duplicate bits. SMT+SS.
        // G1ik: G1id latched only compressed
        // Branch bits. 7b8 commits but is
        // not that encoding (G1ii analog
        // at ID). Arm on aligned Branch
        // (compressed, RVI, decoded
        // op_is_branch, or in-ID issue_q).
        // G1ln: also in-ID aligned-00 RVI
        // LOAD (issue_q) sibling 01.
        // Not G1he. Not G1if. Not G1je.
        // Not G1lm. SMT+SS.
        end else if (g6lc_sib_cjalr::id_rec(
            CVA6Cfg, decoded_instruction[i].pc[2:1] == 2'b01,
            ariane_pkg::op_is_branch(decoded_instruction[i].op),
            g1hx_v_q &&
                (fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3] ==
                 g1hx_line_q),
            g1ik_id_arm[i], g1ln_id_arm[i], g1lz_hit[i],
            (i != 0) && fetch_entry_valid_i[0] &&
                (fetch_entry_i[0].address[2:1] == 2'b00) &&
                (fetch_entry_i[0].address[CVA6Cfg.VLEN-1:3] ==
                 fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3]) &&
                (g6lc_fe_keep::is_cbranch16(
                     fetch_entry_i[0].instruction[15:0]) ||
                 g6lc_sib_cjalr::is_rvi_branch(
                     fetch_entry_i[0].instruction) ||
                 ariane_pkg::op_is_branch(decoded_instruction[0].op)))) begin
          decoded_hd[i].op      = ariane_pkg::JALR;
          decoded_hd[i].fu      = ariane_pkg::CTRL_FLOW;
          decoded_hd[i].rs1     = '0;
          decoded_hd[i].rd      = '0;
          decoded_hd[i].result  = '0;
          decoded_hd[i].use_imm = 1'b1;
          decoded_hd[i].use_pc  = 1'b0;
          decoded_hd[i].rs1[4:0] = (g1hx_v_q &&
              (fetch_entry_i[i].address[CVA6Cfg.VLEN-1:3] ==
               g1hx_line_q))
              ? g1hx_rs1_q
              : (g1ik_id_arm[i] ? g1ik_id_rs1[i]
                 : g1ln_id_arm[i] ? g1ln_id_rd[i]
                 : g1lz_hit[i]
                   ? g1lo_rd_q[fetch_entry_i[i].hart_id]
                 : (((fetch_entry_i[0].instruction[1:0] == 2'b11) &&
                     (fetch_entry_i[0].instruction[6:0] == 7'b1100011))
                        ? fetch_entry_i[0].instruction[19:15]
                        : ((fetch_entry_i[0].instruction[1:0] == 2'b01)
                               ? {2'b01, fetch_entry_i[0].instruction[9:7]}
                               : decoded_instruction[0].rs1[4:0])));
          decoded_hd[i].rd[4:0] = 5'd1;
          is_cf_hd[i] = 1'b1;
        // G1ij: mid-line 01 Branch whose
        // fetch 16-bit is not a Branch
        // encoding is a mash (G1bj analog:
        // CF class follows the 16-bit at
        // that PC). Not G1he all mid-line
        // Branch. Not G1ig leftover-PC.
        // Not G1id same-line latch. SMT+SS.
        end else if (g6lc_sib_cjalr::mash_drop(
            CVA6Cfg, decoded_instruction[i].pc[2:1] == 2'b01,
            ariane_pkg::op_is_branch(decoded_instruction[i].op),
            g6lc_fe_keep::is_cbranch16(fetch_entry_i[i].instruction[15:0]),
            g6lc_sib_cjalr::is_rvi_branch(fetch_entry_i[i].instruction))) begin
          decoded_hd[i].op      = ariane_pkg::ADD;
          decoded_hd[i].fu      = ariane_pkg::ALU;
          decoded_hd[i].rs1     = '0;
          decoded_hd[i].rd      = '0;
          decoded_hd[i].result  = '0;
          decoded_hd[i].use_imm = 1'b0;
          decoded_hd[i].use_pc  = 1'b0;
          is_cf_hd[i] = 1'b0;
        end
        // G1im aligned either-half compressed
        // Branch — HOLD-FAIL no cookie
        // @250000. Do not re-land (yanks
        // live aligned ops whose high half
        // looks like c.beqz/c.bnez).
      end
    end
`endif
  end
  logic        g1hx_v_q;
  logic [15:0] g1hx_hw_q;
  logic [4:0]  g1hx_rs1_q;
  logic [CVA6Cfg.VLEN-1:3] g1hx_line_q;
  // G1lo: ID latch of aligned-00 RVI
  // LOAD (rd!=0). Survives flush_i
  // (G1il analog). 16-byte line + a3.
  // Keep 01 Branch-bits gate (not
  // G1lm, not G1je). G1lp: keep until
  // sibling 01. G1lz: one latch per
  // hart — a peer 00 LOAD must not
  // occupy hart0's 7b0. g1lq
  // overwrite indexes smt_hart_id_i.
  // Not G1ki sticky. Not G1lk. Not
  // G1lm. SMT+SS.
  localparam int unsigned G1LZ_HID =
      (CVA6Cfg.NrHarts <= 1) ? 1 : $clog2(CVA6Cfg.NrHarts);
  logic [CVA6Cfg.NrHarts-1:0] g1lo_v_q;
  logic [CVA6Cfg.NrHarts-1:0][4:0] g1lo_rd_q;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1lo_line_q;
  logic [CVA6Cfg.NrHarts-1:0] g1lo_a3_q;
  logic [CVA6Cfg.NrHarts-1:0] g1lo_cap;
  logic [CVA6Cfg.NrHarts-1:0][4:0] g1lo_cap_rd;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1lo_cap_line;
  logic [CVA6Cfg.NrHarts-1:0] g1lo_cap_a3;
  logic [CVA6Cfg.NrHarts-1:0] g1lp_01_v;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1lp_01_line;
  logic [CVA6Cfg.NrHarts-1:0] g1md_cmt;
  logic [CVA6Cfg.NrHarts-1:0] g1mf_sb;
  logic        g1hy_v_q;
  logic [4:0]  g1hy_rs1_q;
  logic [CVA6Cfg.VLEN-1:3] g1hy_line_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1hx_v_q    <= 1'b0;
      g1hx_hw_q   <= 16'b0;
      g1hx_rs1_q  <= 5'd0;
      g1hx_line_q <= '0;
      g1hy_v_q    <= 1'b0;
      g1hy_rs1_q  <= 5'd0;
      g1hy_line_q <= '0;
    end else if (flush_i) begin
      // G1il: leftover jal@766 flush_i
      // (t=20470) must not drop the
      // aligned-Branch latch before 7ba
      // is at ID. Same-line 01 Branch
      // gate stays (not G1if). Not G1bn
      // dest-FIFO. SMT+SS. SI clears.
      if (!(CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1))
        g1hx_v_q <= 1'b0;
      g1hy_v_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
`ifndef G6LC_FETCH_B
      for (int unsigned s = 0; s < CVA6Cfg.NrIssuePorts; s++) begin
        if (g6lc_sib_cjalr::aligned_br_op(
                CVA6Cfg, issue_q[s].valid,
                issue_q[s].sbe.pc[2:1] == 2'b00,
                ariane_pkg::op_is_branch(issue_q[s].sbe.op))) begin
          g1hx_v_q    <= 1'b1;
          g1hx_rs1_q  <= issue_q[s].sbe.rs1[4:0];
          g1hx_line_q <= issue_q[s].sbe.pc[CVA6Cfg.VLEN-1:3];
        end
        if (g6lc_sib_cjalr::aligned_br_fetch(
                CVA6Cfg, fetch_entry_valid_i[s],
                fetch_entry_i[s].address[2:1] == 2'b00,
                fetch_entry_i[s].instruction,
                ariane_pkg::op_is_branch(decoded_instruction[s].op))) begin
          g1hx_v_q    <= 1'b1;
          g1hx_hw_q   <= fetch_entry_i[s].instruction[15:0];
          g1hx_rs1_q  <= g6lc_sib_cjalr::aligned_br_rs1(
              fetch_entry_i[s].instruction,
              decoded_instruction[s].rs1[4:0]);
          g1hx_line_q <= fetch_entry_i[s].address[CVA6Cfg.VLEN-1:3];
        end
        if (g6lc_sib_cjalr::aligned_hi_cjalr(
                CVA6Cfg, fetch_entry_valid_i[s],
                fetch_entry_i[s].address[2:1] == 2'b00,
                fetch_entry_i[s].instruction)) begin
          g1hy_v_q    <= 1'b1;
          g1hy_rs1_q  <= fetch_entry_i[s].instruction[27:23];
          g1hy_line_q <= fetch_entry_i[s].address[CVA6Cfg.VLEN-1:3];
        end
      end
`endif
    end
  end
  always_comb begin
    g1lo_cap      = '0;
    g1lo_cap_rd   = '0;
    g1lo_cap_line = '0;
    g1lo_cap_a3   = '0;
    g1lp_01_v     = '0;
    g1lp_01_line  = '0;
    g1md_cmt      = '0;
    g1mf_sb       = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64) begin
`ifndef G6LC_FETCH_B
      for (int unsigned s = 0; s < CVA6Cfg.NrIssuePorts; s++) begin
        if (g6lc_sib_cjalr::load00(
                CVA6Cfg, issue_q[s].valid,
                issue_q[s].sbe.pc[2:1] == 2'b00,
                issue_q[s].sbe.fu == ariane_pkg::LOAD,
                issue_q[s].sbe.rd[4:0] != 5'd0)) begin
          g1lo_cap[issue_q[s].sbe.hart_id]      = 1'b1;
          g1lo_cap_rd[issue_q[s].sbe.hart_id]   = issue_q[s].sbe.rd[4:0];
          g1lo_cap_line[issue_q[s].sbe.hart_id] = issue_q[s].sbe.pc[CVA6Cfg.VLEN-1:4];
          g1lo_cap_a3[issue_q[s].sbe.hart_id]   = issue_q[s].sbe.pc[3];
        end
        if (g6lc_sib_cjalr::load00(
                CVA6Cfg, fetch_entry_valid_i[s],
                fetch_entry_i[s].address[2:1] == 2'b00,
                decoded_instruction[s].fu == ariane_pkg::LOAD,
                decoded_instruction[s].rd[4:0] != 5'd0)) begin
          g1lo_cap[fetch_entry_i[s].hart_id]      = 1'b1;
          g1lo_cap_rd[fetch_entry_i[s].hart_id]   = decoded_instruction[s].rd[4:0];
          g1lo_cap_line[fetch_entry_i[s].hart_id] = fetch_entry_i[s].address[CVA6Cfg.VLEN-1:4];
          g1lo_cap_a3[fetch_entry_i[s].hart_id]   = fetch_entry_i[s].address[3];
        end
        if (fetch_entry_valid_i[s] &&
            (fetch_entry_i[s].address[2:1] == 2'b01)) begin
          g1lp_01_v[fetch_entry_i[s].hart_id]    = 1'b1;
          g1lp_01_line[fetch_entry_i[s].hart_id] = fetch_entry_i[s].address[CVA6Cfg.VLEN-1:4];
        end
        if (issue_q[s].valid &&
            (issue_q[s].sbe.pc[2:1] == 2'b01)) begin
          g1lp_01_v[issue_q[s].sbe.hart_id]    = 1'b1;
          g1lp_01_line[issue_q[s].sbe.hart_id] = issue_q[s].sbe.pc[CVA6Cfg.VLEN-1:4];
        end
      end
      // G1lq: IQ-visible 00 LOAD last-
      // overwrite into g1lo_cap (G1li
      // analog). G1lx/G1ly gates.
      // G1ma: each hart's g1lq into
      // that hart's g1lo (not the
      // active-hart scalar). Flop only
      // — keep 01 Branch-bits recover
      // (not G1lm IQ rewrite). Not
      // G1ki. Not G1lk. SMT+SS.
      for (int unsigned h = 0; h < CVA6Cfg.NrHarts; h++) begin
        if (g1lq_v_i[h] &&
            (!g1lo_v_q[h] ||
             (g1lq_line_i[h] ==
              g1lo_line_q[h]) ||
             (g1lp_01_v[h] &&
              (g1lq_line_i[h] ==
               g1lp_01_line[h])))) begin
          g1lo_cap[h]      = 1'b1;
          g1lo_cap_rd[h]   = g1lq_rd_i[h];
          g1lo_cap_line[h] = g1lq_line_i[h];
          g1lo_cap_a3[h]   = g1lq_a3_i[h];
        end
      end
      // G1md: retire of aligned-00 RVI
      // LOAD last-replaces that hart's
      // g1lo (keep-until would block
      // 7b0 behind an earlier LOAD).
      // Flop only — keep 01 Branch-
      // bits recover (not G1lm). Not
      // G1ki. Not G1lk. SMT+SS.
      for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
        if (g6lc_sib_cjalr::cmt_load00(
                CVA6Cfg, commit_ack_i[c],
                commit_instr_i[c].ex.valid,
                commit_instr_i[c].is_compressed,
                commit_instr_i[c].pc[2:1] == 2'b00,
                commit_instr_i[c].fu == ariane_pkg::LOAD,
                commit_instr_i[c].rd[4:0] != 5'd0)) begin
          g1lo_cap[commit_instr_i[c].hart_id]      = 1'b1;
          g1lo_cap_rd[commit_instr_i[c].hart_id]   = commit_instr_i[c].rd[4:0];
          g1lo_cap_line[commit_instr_i[c].hart_id] = commit_instr_i[c].pc[CVA6Cfg.VLEN-1:4];
          g1lo_cap_a3[commit_instr_i[c].hart_id]   = commit_instr_i[c].pc[3];
          g1md_cmt[commit_instr_i[c].hart_id]      = 1'b1;
        end
      end
      // G1mf: SB result-valid 00 RVI
      // LOAD last-replaces (WB done,
      // before commit_ack). Keep 01
      // Branch-bits recover. Not G1lm.
      // Not G1lk. SMT+SS.
      for (int unsigned h = 0; h < CVA6Cfg.NrHarts; h++) begin
        if (g1mf_v_i[h]) begin
          g1lo_cap[h]      = 1'b1;
          g1lo_cap_rd[h]   = g1mf_rd_i[h];
          g1lo_cap_line[h] = g1mf_line_i[h];
          g1lo_cap_a3[h]   = g1mf_a3_i[h];
          g1mf_sb[h]       = 1'b1;
        end
      end
`endif
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1lo_v_q    <= '0;
      g1lo_rd_q   <= '0;
      g1lo_line_q <= '0;
      g1lo_a3_q   <= '0;
    end else if (flush_i) begin
      // G1il analog: leftover jal flush
      // must not drop the LOAD latch
      // before sibling 01 is at ID.
      // SI clears. SMT+SS keeps.
      if (!(CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1))
        g1lo_v_q <= '0;
      // G1me: commit capture beats
      // flush_i (G1kp analog). A
      // retiring 00 LOAD on leftover
      // jal flush was skipped. Not
      // consume. Not G1lk. SMT+SS.
      // I1: B does not keep a sibling-LOAD latch across flush.
`ifndef G6LC_FETCH_B
      else if (CVA6Cfg.FETCH_WIDTH >= 64) begin
        for (int unsigned h = 0; h < CVA6Cfg.NrHarts; h++) begin
          if (g1lo_cap[h] && (g1md_cmt[h] || g1mf_sb[h])) begin
            g1lo_v_q[h]    <= 1'b1;
            g1lo_rd_q[h]   <= g1lo_cap_rd[h];
            g1lo_line_q[h] <= g1lo_cap_line[h];
            g1lo_a3_q[h]   <= g1lo_cap_a3[h];
          end
        end
      end
`else
      else g1lo_v_q <= '0;
`endif
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
                 CVA6Cfg.FETCH_WIDTH >= 64) begin
`ifndef G6LC_FETCH_B
      for (int unsigned h = 0; h < CVA6Cfg.NrHarts; h++) begin
        if (g1lo_cap[h] &&
            (g1md_cmt[h] || g1mf_sb[h] ||
             !(g1lo_v_q[h] &&
               (g1lo_cap_line[h] !=
                g1lo_line_q[h]) &&
               (!g1lp_01_v[h] ||
                (g1lo_cap_line[h] !=
                 g1lp_01_line[h]))))) begin
          // G1lp: keep until sibling 01
          // (G1lf analog). Per-hart
          // (G1lz). Not G1ki sticky.
          // Not G1lb. Not G1lk. Not
          // G1lm. SMT+SS.
          g1lo_v_q[h]    <= 1'b1;
          g1lo_rd_q[h]   <= g1lo_cap_rd[h];
          g1lo_line_q[h] <= g1lo_cap_line[h];
          g1lo_a3_q[h]   <= g1lo_cap_a3[h];
        end else begin
          for (int unsigned s = 0; s < CVA6Cfg.NrIssuePorts; s++) begin
            // G1ks analog: consume only
            // at same-hart sibling 01.
            // Not G1if any-slot. SMT+SS.
            if (g1lo_v_q[h] &&
                fetch_entry_valid_i[s] &&
                (fetch_entry_i[s].hart_id == G1LZ_HID'(h)) &&
                (fetch_entry_i[s].address[2:1] == 2'b01) &&
                (fetch_entry_i[s].address[CVA6Cfg.VLEN-1:4] ==
                 g1lo_line_q[h]) &&
                (fetch_entry_i[s].address[3] != g1lo_a3_q[h]))
              g1lo_v_q[h] <= 1'b0;
            if (g1lo_v_q[h] &&
                issue_q[s].valid &&
                (issue_q[s].sbe.hart_id == G1LZ_HID'(h)) &&
                (issue_q[s].sbe.pc[2:1] == 2'b01) &&
                (issue_q[s].sbe.pc[CVA6Cfg.VLEN-1:4] ==
                 g1lo_line_q[h]) &&
                (issue_q[s].sbe.pc[3] != g1lo_a3_q[h]))
              g1lo_v_q[h] <= 1'b0;
          end
        end
      end
`endif
    end
  end

  // ------------------
  // 3. Pipeline Register
  // ------------------
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assign issue_entry_o[i] = issue_q[i].sbe;
    assign issue_entry_o_prev[i] = CVA6Cfg.FpgaAlteraEn ? issue_n[i].sbe : '0;
    assign issue_entry_valid_o[i] = issue_q[i].valid;
    assign is_ctrl_flow_o[i] = issue_q[i].is_ctrl_flow;
    assign orig_instr_o[i] = issue_q[i].orig_instr;
  end

  if (CVA6Cfg.SuperscalarEn) begin
    // N-wide (2..8) ID↔issue register: compact on ack, then fill from fetch ports.
    always_comb begin
      issue_struct_t [CVA6Cfg.NrIssuePorts-1:0] compacted;
      int unsigned wptr;
      int unsigned rptr;
      logic took_fetch;

      issue_n = issue_q;
      fetch_entry_ready_o = '0;
      took_fetch = 1'b0;

      // Port 0 validity accounts for ZCMT/CVXIF stalls; other ports are simple.
      decoded_instruction_valid[0] = (CVA6Cfg.RVZCMT && is_zcmt_instr[0] && stall_macro_deco_zcmt) ||
                                     (CVA6Cfg.CvxifEn && is_illegal_cvxif_i && ~stall_macro_deco) && stall_instr_fetch[0]
                                     ? 1'b0 : 1'b1;
      for (int unsigned i = 1; i < CVA6Cfg.NrIssuePorts; i++) begin
        decoded_instruction_valid[i] = ~stall_instr_fetch[i];
      end

      // Clear acked slots
      for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
        if (issue_instr_ack_i[i]) issue_n[i].valid = 1'b0;
      end

      // Compact remaining valids toward port 0 (preserve program order)
      compacted = '0;
      wptr = 0;
      for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
        if (issue_n[i].valid) begin
          compacted[wptr] = issue_n[i];
          wptr++;
        end
      end
      issue_n = compacted;

      // I6: B issues IQ order. G1be/cy/em/ev splice an older fetch in
      // front of a parked branch — A-only (smt_legacy).
`ifndef G6LC_FETCH_B
      // G1be: ID[0] is a Branch and fetch[0] is an older same-line
      // NoCF dest (c.li@0x4d0 vs beq@0x4d4). Insert the prefix at
      // port 0, shift the Branch to port 1. Only when port 1 is
      // empty (do not drop a live ID insn). SMT+SS. Not G1ay (that
      // stalls SB). Not G1bd replay. Not G1at alloc. Not G1ac.
      if (CVA6Cfg.NrHarts > 1 &&
          issue_n[0].valid && !issue_n[1].valid &&
          issue_n[0].sbe.fu == ariane_pkg::CTRL_FLOW &&
          ariane_pkg::op_is_branch(issue_n[0].sbe.op) &&
          fetch_entry_valid_i[0] && ~stall_instr_fetch[0] &&
          decoded_instruction_valid[0] &&
          (decoded_instruction[0].fu == ariane_pkg::ALU ||
           decoded_instruction[0].fu == ariane_pkg::LOAD) &&
          decoded_instruction[0].rd[4:0] != 5'd0 &&
          decoded_instruction[0].hart_id == issue_n[0].sbe.hart_id &&
          decoded_instruction[0].pc < issue_n[0].sbe.pc &&
          decoded_instruction[0].pc[CVA6Cfg.VLEN-1:3] ==
              issue_n[0].sbe.pc[CVA6Cfg.VLEN-1:3]) begin
        issue_n[1] = issue_n[0];
        issue_n[0] = '{
            decoded_instruction_valid[0],
            decoded_hd[0],
            orig_instr[0],
            is_cf_hd[0]
        };
        fetch_entry_ready_o[0] = 1'b1;
      end

      // G1cy: leftover-complete slot0 Jump (jal@0x3f6, pc[2:1]==11)
      // must issue before later-slot fallthrough (li@0x3fa / bne@0x3fc
      // on the next 8B line). G1be same-line dest-before-Branch does
      // not fire (0x3f6 and 0x3fa are different lines). Without this
      // the fill loop parks leftover jal at port 1 behind a younger
      // ID[0]. SMT+SS. Not G1bi IQ hold. Not G1cu NPC. Not G1be.
      if (CVA6Cfg.NrHarts > 1 &&
          issue_n[0].valid && !issue_n[1].valid &&
          fetch_entry_valid_i[0] && ~stall_instr_fetch[0] &&
          decoded_instruction_valid[0] &&
          decoded_instruction[0].fu == ariane_pkg::CTRL_FLOW &&
          is_control_flow_instr[0] &&
          !ariane_pkg::op_is_branch(decoded_instruction[0].op) &&
          decoded_instruction[0].op != ariane_pkg::JALR &&
          decoded_instruction[0].pc[2:1] == 2'b11 &&
          decoded_instruction[0].hart_id == issue_n[0].sbe.hart_id &&
          decoded_instruction[0].pc < issue_n[0].sbe.pc) begin
        issue_n[1] = issue_n[0];
        issue_n[0] = '{
            decoded_instruction_valid[0],
            decoded_hd[0],
            orig_instr[0],
            is_cf_hd[0]
        };
        fetch_entry_ready_o[0] = 1'b1;
      end

      // G1em: ID[0] is a Branch on a0 and fetch[0] is an
      // older same-hart CSR to a0 (7ac vs 7bc, different
      // 8B lines). Insert CSR at port 0. Port 1 empty.
      // Not G1be same-line ALU/LOAD. Not G1eb stall-all.
      // Not G1cy leftover Jump. SMT+SS.
      if (CVA6Cfg.NrHarts > 1 &&
          issue_n[0].valid && !issue_n[1].valid &&
          issue_n[0].sbe.fu == ariane_pkg::CTRL_FLOW &&
          ariane_pkg::op_is_branch(issue_n[0].sbe.op) &&
          (issue_n[0].sbe.rs1[4:0] == 5'd10) &&
          fetch_entry_valid_i[0] && ~stall_instr_fetch[0] &&
          decoded_instruction_valid[0] &&
          decoded_instruction[0].fu == ariane_pkg::CSR &&
          decoded_instruction[0].rd[4:0] == 5'd10 &&
          decoded_instruction[0].hart_id == issue_n[0].sbe.hart_id &&
          decoded_instruction[0].pc < issue_n[0].sbe.pc) begin
        issue_n[1] = issue_n[0];
        issue_n[0] = '{
            decoded_instruction_valid[0],
            decoded_hd[0],
            orig_instr[0],
            is_cf_hd[0]
        };
        fetch_entry_ready_o[0] = 1'b1;
      end

      // G1ev: ID[0] is a Branch on a0 and fetch[0] is an
      // older same-hart ALU to a0 (auipc@7a4 / addi@7a8
      // vs 7bc). G1em is CSR-only. Port 1 empty. Not
      // G1eb stall-all RAW. Not G1be same-line. SMT+SS.
      if (CVA6Cfg.NrHarts > 1 &&
          issue_n[0].valid && !issue_n[1].valid &&
          issue_n[0].sbe.fu == ariane_pkg::CTRL_FLOW &&
          ariane_pkg::op_is_branch(issue_n[0].sbe.op) &&
          (issue_n[0].sbe.rs1[4:0] == 5'd10) &&
          fetch_entry_valid_i[0] && ~stall_instr_fetch[0] &&
          decoded_instruction_valid[0] &&
          decoded_instruction[0].fu == ariane_pkg::ALU &&
          decoded_instruction[0].rd[4:0] == 5'd10 &&
          decoded_instruction[0].hart_id == issue_n[0].sbe.hart_id &&
          decoded_instruction[0].pc < issue_n[0].sbe.pc) begin
        issue_n[1] = issue_n[0];
        issue_n[0] = '{
            decoded_instruction_valid[0],
            decoded_hd[0],
            orig_instr[0],
            is_cf_hd[0]
        };
        fetch_entry_ready_o[0] = 1'b1;
      end
`endif

      // Fill empty tail from fetch ports as a *strict prefix* starting at
      // fetch port 0. Never skip a stalled/invalid earlier fetch port to take
      // a later one — instr_queue only pops/advances PC on a fire prefix from
      // port 0 (non-prefix ready[1]&&!ready[0] drops the second IQ slot).
      rptr = 0;
      for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
        if (!issue_n[i].valid) begin
          took_fetch = 1'b0;
          if (rptr < CVA6Cfg.NrIssuePorts && fetch_entry_valid_i[rptr] &&
              !fetch_entry_ready_o[rptr] && ~stall_instr_fetch[rptr]) begin
            fetch_entry_ready_o[rptr] = 1'b1;
            issue_n[i] = '{
                decoded_instruction_valid[rptr],
                decoded_hd[rptr],
                orig_instr[rptr],
                is_cf_hd[rptr]
            };
            rptr = rptr + 1;
            took_fetch = 1'b1;
          end else begin
            // Gap in the fetch stream: stop filling further issue slots.
            break;
          end
        end
      end

      if (flush_i) begin
        for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) issue_n[i].valid = 1'b0;
      end
    end
  end else begin
    always_comb begin
      issue_n = issue_q;
      fetch_entry_ready_o = '0;
      // instruction is not valid if we stall due to ZCMT or CVXIF
      decoded_instruction_valid[0] = (CVA6Cfg.RVZCMT && is_zcmt_instr[0] && stall_macro_deco_zcmt) ||
                                     (CVA6Cfg.CvxifEn && is_illegal_cvxif_i && ~stall_macro_deco && stall_instr_fetch[0])
                                     ? 1'b0 : 1'b1;
      // Clear the valid flag if issue has acknowledged the instruction
      if (issue_instr_ack_i[0]) issue_n[0].valid = 1'b0;

      // TODO: redo
      // if we have a space in the register and the fetch is valid, go get it
      // or the issue stage is currently acknowledging an instruction, which means that we will have space
      // for a new instruction
      if (!issue_n[0].valid && fetch_entry_valid_i[0]) begin
        fetch_entry_ready_o[0] = ~stall_instr_fetch[0];
        issue_n[0] = '{
            decoded_instruction_valid[0],
            decoded_hd[0],
            orig_instr[0],
            is_cf_hd[0]
        };
      end

      // invalidate the pipeline register on a flush
      if (flush_i) issue_n[0].valid = 1'b0;
    end
  end
  // -------------------------
  // Registers (ID <-> Issue)
  // -------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      issue_q <= '0;
    end else begin
      issue_q <= issue_n;
    end
  end

endmodule
