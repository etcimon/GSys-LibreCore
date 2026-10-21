// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
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
// Modified by: Etienne Cimon (ZCMP/ZCMT port-0 slice; Verilator WIDTHTRUNC)
// Date: 15.04.2017
// Description: Instruction decode, contains the logic for decode,
//              issue and read operands.
//
// Modifications (c) 2026 Etienne Cimon: optional three-stage decode path
// (HypCfg.DecodeStages == 3): compressed/macro/Zcmt/CVXIF expansion context is
// captured into a D1 register, g6lc_decode_s2 (instruction-bit decode) feeds a
// D2 register, and g6lc_decode_s3 (privilege/CSR legality + exceptions) feeds
// the existing ID->issue register.  hyp8: rank-4 front-end depth cut, +2
// cycles of decode latency.  HypCfg.DecodeStages == 1 keeps the original
// single-cycle decoder composition.
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

//pragma translate_off
// Post-preload DRAM peek for the I1-at-supply oracle below (implemented in
// corev_apu/tb/g6lc_tb.cpp). Returns 0 outside the preloaded image so bootrom and
// CLINT fetches are skipped rather than falsely reported.
`ifndef G6LC_DRAM_PEEK_T
`define G6LC_DRAM_PEEK_T
import "DPI-C" function int g6lc_dram_peek64(input longint addr, output longint data);
`endif
//pragma translate_on

module id_stage #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
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
    parameter type x_compressed_resp_t = logic,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8
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
    input fetch_entry_t [G6LCCfg.NrIssuePorts-1:0] fetch_entry_i,
    // Handshake's valid between fetch and decode - FRONTEND
    input logic [G6LCCfg.NrIssuePorts-1:0] fetch_entry_valid_i,
    // Handshake's ready between fetch and decode - FRONTEND
    output logic [G6LCCfg.NrIssuePorts-1:0] fetch_entry_ready_o,
    // G1lq: IQ-visible aligned-00 RVI LOAD
    // (frontend g1ct_valid latch). Flop
    // into g1lo_cap only — not G1lm IQ
    // rewrite. G1ma: one latch per hart.
    input logic [G6LCCfg.NrHarts-1:0] g1lq_v_i,
    input logic [G6LCCfg.NrHarts-1:0][4:0] g1lq_rd_i,
    input logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:4] g1lq_line_i,
    input logic [G6LCCfg.NrHarts-1:0] g1lq_a3_i,
    // G1md: commit-visible aligned-00 RVI
    // LOAD into g1lo (G1lq analog from
    // retire). Flop only — not G1lm IQ
    // rewrite.
    input scoreboard_entry_t [G6LCCfg.NrCommitPorts-1:0] commit_instr_i,
    input logic [G6LCCfg.NrCommitPorts-1:0] commit_ack_i,
    // G1mf: SB result-valid aligned-00
    // RVI LOAD (before commit_ack).
    input logic [G6LCCfg.NrHarts-1:0] g1mf_v_i,
    input logic [G6LCCfg.NrHarts-1:0][4:0] g1mf_rd_i,
    input logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:4] g1mf_line_i,
    input logic [G6LCCfg.NrHarts-1:0] g1mf_a3_i,
    // Handshake's data between decode and issue - ISSUE
    output scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0] issue_entry_o,
    output scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0] issue_entry_o_prev,
    // Instruction value - ISSUE
    output logic [G6LCCfg.NrIssuePorts-1:0][31:0] orig_instr_o,
    // Handshake's valid between decode and issue - ISSUE
    output logic [G6LCCfg.NrIssuePorts-1:0] issue_entry_valid_o,
    // Report if instruction is a control flow instruction - ISSUE
    output logic [G6LCCfg.NrIssuePorts-1:0] is_ctrl_flow_o,
    // Handshake's acknowledge between decode and issue - ISSUE
    input logic [G6LCCfg.NrIssuePorts-1:0] issue_instr_ack_i,
    // Information dedicated to RVFI - RVFI
    output logic [G6LCCfg.NrIssuePorts-1:0] rvfi_is_compressed_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][31:0] rvfi_instr_o,
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
    // T6b-2b: per-hart interrupt/privilege context, selected per decode lane by
    // fetch_entry_i[lane].hart_id under mixed residency. Unused (the scalars
    // above are taken) when NrHarts==1 or SmtDrainedHandoff.
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][1:0] irq_b_i,
    input irq_ctrl_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] irq_ctrl_b_i,
    input riscv::priv_lvl_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] priv_lvl_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] v_b_i,
    // T6b-3a: the rest of the per-hart decode context, selected per lane the
    // same way (trap-enable qualifiers, FP/vector state, debug mode, the CBO
    // enables, and the Zcmt jvt table base).
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] tvm_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] tw_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] vtw_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] tsr_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] hu_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] debug_mode_b_i,
    input riscv::xs_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] fs_b_i,
    input riscv::xs_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] vfs_b_i,
    input riscv::xs_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] vs_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][2:0] frm_b_i,
    input riscv::cbie_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] mcbie_b_i,
    input riscv::cbie_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] scbie_b_i,
    input riscv::cbie_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] hcbie_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] mcbcfe_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] scbcfe_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] hcbcfe_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] mcbze_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] scbze_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] hcbze_b_i,
    input jvt_t [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] jvt_b_i,
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
    input logic [G6LCCfg.XLEN-1:0] hart_id_i,
    // U6.1 SMT active thread tag (0 when NrHarts==1)
    input logic [((G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts))-1:0] smt_hart_id_i,
    // Zihintpause yield hint, one bit per hart, pulsed when a PAUSE is accepted
    // into issue. A hint only, never a readiness or correctness signal.
    output logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0] smt_pause_hint_o,
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
  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin id_stage status=proposal target=10-adjusted-FO4
  // svt-plan: cone compressed/macro decode and issue-lane packing feed
  // held issue entries; a new register must respect per-lane consumption.
  // svt-plan: reshape predecode length/class in parallel and use balanced
  // accepted-lane prefixes; prefer shortening this logic before another stage.
  // svt-plan: boundary optional expanded instruction packet -> issue group;
  // reserve packet space before consuming fetch entries or advancing a macro.
  // svt-plan: carry PC, original bits/length, expanded operation, exception,
  // hart/fetch epoch, prediction and macro first/last/double-destination state.
  // svt-plan: ownership hold unaccepted lanes and kill on redirect/flush;
  // Zcmp/Zcmt/CVXIF paths must not repeat or skip a sub-operation.
  // svt-plan: effect separates expansion from issue packing when needed.
  // svt-plan: cost packet storage and decode/mispredict latency.
  // svt-plan: limit near-budget control can lose more to another handshake
  // than it gains in logic depth; no fixed added stage is assumed beneficial.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 10.9 adjusted FO4 on the
  // Nangate45 board): decode: the issue handshake is same-cycle.
  // svt-pipe: require-contract
  // svt-pipe: protocol id valid=fetch_entry_valid_i
  // svt-pipe: no-cut on=issue_n
  // svt-pipe: cycle id q=issue_n d=issue_entry_valid_o hold=fetch_entry_valid_i steps=1

  // ID/ISSUE register stage
  typedef struct packed {
    logic              valid;
    scoreboard_entry_t sbe;
    logic [31:0]       orig_instr;
    logic              is_ctrl_flow;
    // RVFI-only: the issue-aligned instruction encoding (compressed ops
    // truncated to [15:0]) and its RVC flag. Pure probe consumers, pruned
    // in synthesis like rvfi_is_compressed_o.
    logic [31:0]       rvfi_instr;
    logic              rvfi_is_compressed;
  } issue_struct_t;
  issue_struct_t [G6LCCfg.NrIssuePorts-1:0] issue_n, issue_q;
  // stall required for ZCMP ZCMT CVXIF
  logic              [G6LCCfg.NrIssuePorts-1:0]       stall_instr_fetch;

  logic              [G6LCCfg.NrIssuePorts-1:0]       is_control_flow_instr;
  scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0]       decoded_instruction;
  logic              [G6LCCfg.NrIssuePorts-1:0]       decoded_instruction_valid;
  logic              [G6LCCfg.NrIssuePorts-1:0][31:0] orig_instr;

//pragma translate_off
  // I1-at-supply oracle enable, latched once (see the checker further down).
  logic i1_chk_en;
  // Counters for that checker. They live here, next to the enable, purely so
  // the whole oracle's state is declared in one sim-only place. Being 2-state
  // they start at 0, so nothing clears them: the checker's always_ff below is
  // deliberately their only writer.
  int unsigned i1_bad, i1_seen;
  // Early decode-supply trace, opt-in for the same reason as the oracle above.
  logic id_dbg_trace;
  initial begin
    i1_chk_en = $test$plusargs("fetch_i1_check");
    id_dbg_trace = $test$plusargs("id_dbg_trace");
  end
//pragma translate_on

  // Compressed decoder signals
  logic              [G6LCCfg.NrIssuePorts-1:0]       is_illegal_rvc;
  logic              [G6LCCfg.NrIssuePorts-1:0][31:0] instruction_rvc;
  logic              [G6LCCfg.NrIssuePorts-1:0][31:0] instruction_rvc_raw;
  logic              [G6LCCfg.NrIssuePorts-1:0]       is_compressed_rvc;
  logic              [G6LCCfg.NrIssuePorts-1:0]       is_zcmt_instr;
  logic              [G6LCCfg.NrIssuePorts-1:0]       is_macro_instr;

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
  logic              [        G6LCCfg.XLEN-1:0]       jump_address;

  // Decoder signals
  logic              [G6LCCfg.NrIssuePorts-1:0]       is_illegal_deco;
  logic              [G6LCCfg.NrIssuePorts-1:0][31:0] instruction_deco;
  logic              [G6LCCfg.NrIssuePorts-1:0]       is_compressed_deco;

  // ------------------------------------------------------------------
  // hyp8 DecodeStages==3 stage registers (rank 4, +2 cycles).  D1 packs the
  // post-expansion/sequencer context (the g6lc_decode_s1 record plus the raw
  // fetch word the RVFI fields need); D2 holds the g6lc_decode_s2 candidate.
  // One global shift `dec_adv`: when the issue side cannot accept the whole
  // D2 prefix, all stage registers hold.
  typedef struct packed {
    logic [31:0]                                          instr;
    logic [31:0]                                          raw_instr;
    logic [15:0]                                          cinstr;
    logic                                                 is_compressed;
    logic                                                 is_illegal;
    logic                                                 is_macro;
    logic                                                 is_last_macro;
    logic                                                 is_double_macro;
    logic                                                 is_zcmt;
    logic [G6LCCfg.XLEN-1:0]                              jaddr;
    branchpredict_sbe_t                                   bp;
    exception_t                                           ex;
    logic [G6LCCfg.VLEN-1:0]                              pc;
    logic [((G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts))-1:0] hart;
  } d1_entry_t;
  typedef struct packed {
    scoreboard_entry_t                                    sbe;
    logic [31:0]                                          instr;
    logic [31:0]                                          tinst;
    logic [31:0]                                          raw_instr;
    logic [15:0]                                          cinstr;
    logic                                                 is_compressed;
    logic                                                 is_illegal;
    exception_t                                           ex;
    logic                                                 ecall;
    logic                                                 ebreak;
    logic                                                 frm_req;
    logic                                                 check_fprm;
    logic                                                 fp_hit;
    logic                                                 illegal;
    logic                                                 cf;
  } d2_entry_t;
  d1_entry_t [G6LCCfg.NrIssuePorts-1:0]  d1_q, d1_n;
  d2_entry_t [G6LCCfg.NrIssuePorts-1:0]  d2_q, d2_n;
  logic      [G6LCCfg.NrIssuePorts-1:0]  d1_vq, d2_vq;
  logic                                  dec_adv;
  logic                                  dec_macro_ack;


  if (G6LCCfg.RVC) begin
    // ---------------------------------------------------------
    // 1. Check if they are compressed and expand in case they are
    // ---------------------------------------------------------
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
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
          .G6LCCfg(G6LCCfg)
      ) compressed_decoder_i (
          .instr_i         (fetch_entry_i[i].instruction),
          .instr_o         (instruction_rvc_raw[i]),
          .illegal_instr_o (is_illegal_rvc[i]),
          .is_compressed_o (is_compressed_rvc[i]),
          .is_macro_instr_o(is_macro_instr[i]),
          .is_zcmt_instr_o (is_zcmt_instr[i])
      );
      

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=id_stage  region=2719  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: g1hx_hw_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to g1hx_hw_q
// order expect: g1hx_line_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to g1hx_line_q
// order expect: g1hx_rs1_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to g1hx_rs1_q
// order expect: g1hx_v_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to g1hx_v_q
// order expect: g1hy_line_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to g1hy_line_q
// order expect: g1hy_rs1_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to g1hy_rs1_q
// order expect: g1hy_v_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to g1hy_v_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     g1hx_hw_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1hx_line_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1hx_rs1_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1hx_v_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1hy_line_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1hy_rs1_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1hy_v_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node10005 c=3.50 slack=1.00 */
//     /* node10006 c=3.50 slack=1.00 */
//     /* node10007 c=3.50 slack=1.00 */
//     /* node10008 c=3.50 slack=1.00 */
//     /* node10009 c=3.50 slack=1.00 */
//     /* node10010 c=3.50 slack=1.00 */
//     /* node10011 c=3.50 slack=1.00 */
//     /* node10012 c=4.50 slack=0.00 */
//     /* node10013 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=id_stage  region=2721  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: g1lo_a3_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to g1lo_a3_q
// order expect: g1lo_line_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to g1lo_line_q
// order expect: g1lo_rd_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to g1lo_rd_q
// order expect: g1lo_v_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to g1lo_v_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     g1lo_a3_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1lo_line_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1lo_rd_q <= …; // sv-timing: cycle 1/1 on clk_i
//     g1lo_v_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node10022 c=3.50 slack=1.00 */
//     /* node10023 c=3.50 slack=1.00 */
//     /* node10024 c=3.50 slack=1.00 */
//     /* node10025 c=3.50 slack=1.00 */
//     /* node10026 c=4.50 slack=0.00 */
//     /* node10027 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=id_stage  region=2729  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: issue_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to issue_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     issue_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node10051 c=3.50 slack=0.00 */
//     /* node10052 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// sv-timing: origin <src>/core/id_stage.sv:1285:13 edit=235
  // relocation t1_balance_bundle; balance_mux credit path 2728 node 10048 exclusive residual 58.2->29.1 (latency-neutral) extras=0
  // END sv-timing auto-correct (balance_mux rewrite)
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
          (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
           (fetch_entry_i[i].address[2:1] == 2'b01) &&
           (g1gy_lo || g1gy_hi))
              ? {12'b0,
                 (g1gy_lo ? fetch_entry_i[i].instruction[11:7]
                          : fetch_entry_i[i].instruction[27:23]),
                 3'b000, 5'b00001, riscv::OpcodeJalr}
              : instruction_rvc_raw[i];
`endif
    end

    if (G6LCCfg.SuperscalarEn) begin
      // Ports 1..N-1: no ZCMP/ZCMT/CVXIF expansion; stall only on illegal RVC/macro/zcmt
      for (genvar si = 1; si < G6LCCfg.NrIssuePorts; si++) begin : gen_ss_stall
        assign stall_instr_fetch[si] =
            is_illegal_rvc[si] || is_macro_instr[si] || is_zcmt_instr[si];
      end
    end

    if (G6LCCfg.RVZCMP) begin
      macro_decoder #(
          .G6LCCfg(G6LCCfg)
      ) macro_decoder_i (
          .instr_i                   (instruction_rvc[0]),
          .is_macro_instr_i          (is_macro_instr[0]),
          .clk_i                     (clk_i),
          .rst_ni                    (rst_ni),
          .instr_o                   (instruction_zcmp),
          .illegal_instr_i           (is_illegal_rvc[0]),
          .is_compressed_i           (is_compressed_rvc[0]),
          .issue_ack_i               (HypCfg.DecodeStages == 3 ? dec_macro_ack
                                        : issue_instr_ack_i[0]),
          .illegal_instr_o           (is_illegal_zcmp),
          .is_compressed_o           (is_compressed_zcmp),
          .fetch_stall_o             (stall_macro_deco_zcmp),
          .is_last_macro_instr_o     (is_last_macro_instr),
          .is_double_rd_macro_instr_o(is_double_rd_macro_instr)
      );
    end else begin
      assign instruction_zcmp         = instruction_rvc[0];
      assign is_illegal_zcmp          = is_illegal_rvc[0];
      assign is_compressed_zcmp       = is_compressed_rvc[0];
      assign stall_macro_deco_zcmp    = '0;
      assign is_last_macro_instr      = '0;
      assign is_double_rd_macro_instr = '0;
    end

    if (G6LCCfg.RVZCMT) begin
      zcmt_decoder #(
          .G6LCCfg(G6LCCfg),
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
          // The table-jump instruction's own hart owns the jvt base.
          .jvt_i          (SMT_MIXED_DECODE ? jvt_b_i[fetch_entry_i[0].hart_id] : jvt_i),
          .req_port_i     (dcache_req_ports_i),
          .req_port_o     (dcache_req_ports_o),
          .jump_address_o (jump_address)
      );
    end else begin
      assign instruction_zcmt      = instruction_rvc[0];
      assign is_illegal_zcmt       = is_illegal_rvc[0];
      assign is_compressed_zcmt    = is_compressed_rvc[0];
      assign stall_macro_deco_zcmt = '0;
      assign jump_address          = '0;
    end

    if (G6LCCfg.RVZCMT) begin
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

    if (G6LCCfg.CvxifEn) begin
      cvxif_compressed_if_driver #(
          .G6LCCfg(G6LCCfg),
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
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
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
    if (G6LCCfg.RVC) begin
      if (G6LCCfg.CvxifEn) begin
        is_illegal_deco[0]    = is_illegal_cvxif_o;
        instruction_deco[0]   = instruction_cvxif_o;
        is_compressed_deco[0] = is_compressed_cvxif_o;
      end else if (G6LCCfg.RVZCMP || G6LCCfg.RVZCMT) begin
        is_illegal_deco[0]    = is_illegal_cvxif_i;
        instruction_deco[0]   = instruction_cvxif_i;
        is_compressed_deco[0] = is_compressed_cvxif_i;
      end
    end
  end

  // Zihintpause (PAUSE = fence w,0 with rs1=rd=x0, imm=0x010). The decoder folds
  // it into a NOP, so recover it from the expanded instruction and report it to
  // thread select. Wrong-path decode can only cost the hinting hart a voluntary
  // yield, never correctness, and thread select keeps its own service floor.
  always_comb begin
    smt_pause_hint_o = '0;
    if (G6LCCfg.ZihintpauseEn && G6LCCfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        if (HypCfg.DecodeStages == 1) begin
          if (fetch_entry_valid_i[i] && issue_instr_ack_i[i] &&
              instruction_deco[i] == 32'h0100_000F) begin
            smt_pause_hint_o[fetch_entry_i[i].hart_id] = 1'b1;
          end
        end else begin
          // hyp8: in the staged path instruction_deco is three cycles ahead of
          // issue; pulse on the instruction actually leaving issue_q (PAUSE is
          // never compressed, so orig_instr holds the raw encoding).
          if (issue_q[i].valid && issue_instr_ack_i[i] &&
              issue_q[i].orig_instr == 32'h0100_000F) begin
            smt_pause_hint_o[issue_q[i].sbe.hart_id] = 1'b1;
          end
        end
      end
    end
  end

  // Issue-aligned (registered at ID->issue fill), not fetch-aligned: the only
  // consumer is the RVFI probe, which pairs it with the issued instruction.
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    assign rvfi_is_compressed_o[i] = issue_q[i].rvfi_is_compressed;
  end

  // T6b-2b: under mixed residency each decode lane may hold a different hart's
  // instruction, so the interrupt-delivery check (irq lines, mie/mip/delegation
  // and the privilege/virtualization qualifiers it reads) must follow the
  // lane's own hart. Under drained handoff only the active hart's instructions
  // reach decode, so the scalar active-hart inputs are used unchanged.
  localparam bit SMT_MIXED_DECODE = (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;

  // hyp8: two decode organizations behind HypCfg.DecodeStages.  ==1 keeps
  // the original same-cycle decoder; ==3 registers the expansion context (D1)
  // and the instruction-bit decode (D2) so privilege/CSR legality (D3) sees
  // registered state -- rank-4 front-end depth, +2 cycles.
  if (HypCfg.DecodeStages == 1) begin : gen_dec1
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    decoder #(
        .G6LCCfg(G6LCCfg),
        .branchpredict_sbe_t(branchpredict_sbe_t),
        .exception_t(exception_t),
        .irq_ctrl_t(irq_ctrl_t),
        .scoreboard_entry_t(scoreboard_entry_t),
        .interrupts_t(interrupts_t),
        .INTERRUPTS(INTERRUPTS)
    ) decoder_i (
        .debug_req_i,
`ifdef G6LC_MUT_DECODE_ACTIVE_IRQ
        // Review-only mutation: every decode lane takes the active hart's
        // interrupt context — a resident peer vectors on interrupts that are
        // not its own (or misses its own).
        .irq_ctrl_i                (irq_ctrl_i),
        .irq_i                     (irq_i),
`else
        .irq_ctrl_i                (SMT_MIXED_DECODE ? irq_ctrl_b_i[fetch_entry_i[i].hart_id] : irq_ctrl_i),
        .irq_i                     (SMT_MIXED_DECODE ? irq_b_i[fetch_entry_i[i].hart_id] : irq_i),
`endif
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
        .priv_lvl_i                (SMT_MIXED_DECODE ? priv_lvl_b_i[fetch_entry_i[i].hart_id] : priv_lvl_i),
        .v_i                       (SMT_MIXED_DECODE ? v_b_i[fetch_entry_i[i].hart_id] : v_i),
        // T6b-3a: every remaining decode-time CSR qualifier follows the lane's
        // own hart under mixed residency.
        .debug_mode_i              (SMT_MIXED_DECODE ? debug_mode_b_i[fetch_entry_i[i].hart_id] : debug_mode_i),
        .fs_i                      (SMT_MIXED_DECODE ? fs_b_i[fetch_entry_i[i].hart_id] : fs_i),
        .vfs_i                     (SMT_MIXED_DECODE ? vfs_b_i[fetch_entry_i[i].hart_id] : vfs_i),
        .frm_i                     (SMT_MIXED_DECODE ? frm_b_i[fetch_entry_i[i].hart_id] : frm_i),
        .vs_i                      (SMT_MIXED_DECODE ? vs_b_i[fetch_entry_i[i].hart_id] : vs_i),
        .tvm_i                     (SMT_MIXED_DECODE ? tvm_b_i[fetch_entry_i[i].hart_id] : tvm_i),
        .tw_i                      (SMT_MIXED_DECODE ? tw_b_i[fetch_entry_i[i].hart_id] : tw_i),
        .vtw_i                     (SMT_MIXED_DECODE ? vtw_b_i[fetch_entry_i[i].hart_id] : vtw_i),
        .tsr_i                     (SMT_MIXED_DECODE ? tsr_b_i[fetch_entry_i[i].hart_id] : tsr_i),
        .hu_i                      (SMT_MIXED_DECODE ? hu_b_i[fetch_entry_i[i].hart_id] : hu_i),
        .mcbie_i                   (SMT_MIXED_DECODE ? mcbie_b_i[fetch_entry_i[i].hart_id] : mcbie_i),
        .scbie_i                   (SMT_MIXED_DECODE ? scbie_b_i[fetch_entry_i[i].hart_id] : scbie_i),
        .hcbie_i                   (SMT_MIXED_DECODE ? hcbie_b_i[fetch_entry_i[i].hart_id] : hcbie_i),
        .mcbcfe_i                  (SMT_MIXED_DECODE ? mcbcfe_b_i[fetch_entry_i[i].hart_id] : mcbcfe_i),
        .scbcfe_i                  (SMT_MIXED_DECODE ? scbcfe_b_i[fetch_entry_i[i].hart_id] : scbcfe_i),
        .hcbcfe_i                  (SMT_MIXED_DECODE ? hcbcfe_b_i[fetch_entry_i[i].hart_id] : hcbcfe_i),
        .mcbze_i                   (SMT_MIXED_DECODE ? mcbze_b_i[fetch_entry_i[i].hart_id] : mcbze_i),
        .scbze_i                   (SMT_MIXED_DECODE ? scbze_b_i[fetch_entry_i[i].hart_id] : scbze_i),
        .hcbze_i                   (SMT_MIXED_DECODE ? hcbze_b_i[fetch_entry_i[i].hart_id] : hcbze_i),
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

    assign dec_macro_ack = 1'b0;
  end else begin : gen_dec3
    // svt-stage: begin D1
    // per-lane staged datapath: s1 (context pack) -> d1_q -> s2 -> d2_q -> s3
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_lane
      // D1 pack: the expansion chain's outputs for this lane
      g6lc_decode_s1 #(
          .G6LCCfg            (G6LCCfg),
          .branchpredict_sbe_t(branchpredict_sbe_t),
          .exception_t        (exception_t)
      ) i_d1 (
          .instruction_i              (instruction_deco[i]),
          .compressed_instr_i         (fetch_entry_i[i].instruction[15:0]),
          .is_compressed_i            (is_compressed_deco[i]),
          .is_illegal_i               (is_illegal_deco[i]),
          .is_macro_instr_i           (is_macro_instr[i]),
          .is_last_macro_instr_i      (is_last_macro_instr),
          .is_double_rd_macro_instr_i (is_double_rd_macro_instr),
          .is_zcmt_i                  (is_zcmt_instr[i]),
          .jump_address_i             (jump_address),
          .branch_predict_i           (fetch_entry_i[i].branch_predict),
          .ex_i                       (fetch_entry_i[i].ex),
          .pc_i                       (fetch_entry_i[i].address),
`ifdef G6LC_FETCH_B
          .smt_hart_id_i              (fetch_entry_i[i].hart_id),
`else
          .smt_hart_id_i              (smt_hart_id_i),
`endif
          .instruction_o              (d1_n[i].instr),
          .compressed_instr_o         (d1_n[i].cinstr),
          .is_compressed_o            (d1_n[i].is_compressed),
          .is_illegal_o               (d1_n[i].is_illegal),
          .is_macro_instr_o           (d1_n[i].is_macro),
          .is_last_macro_instr_o      (d1_n[i].is_last_macro),
          .is_double_rd_macro_instr_o (d1_n[i].is_double_macro),
          .is_zcmt_o                  (d1_n[i].is_zcmt),
          .jump_address_o             (d1_n[i].jaddr),
          .branch_predict_o           (d1_n[i].bp),
          .ex_o                       (d1_n[i].ex),
          .pc_o                       (d1_n[i].pc),
          .smt_hart_id_o              (d1_n[i].hart)
      );
      assign d1_n[i].raw_instr = fetch_entry_i[i].instruction;

    // svt-stage: end D1
    // svt-stage: begin D2
      // D2: instruction-bit decode of the D1 register
      g6lc_decode_s2 #(
          .G6LCCfg            (G6LCCfg),
          .branchpredict_sbe_t(branchpredict_sbe_t),
          .exception_t        (exception_t),
          .scoreboard_entry_t (scoreboard_entry_t)
      ) i_d2 (
          .instruction_i              (d1_q[i].instr),
          .compressed_instr_i         (d1_q[i].cinstr),
          .is_compressed_i            (d1_q[i].is_compressed),
          .is_illegal_i               (d1_q[i].is_illegal),
          .is_macro_instr_i           (d1_q[i].is_macro),
          .is_last_macro_instr_i      (d1_q[i].is_last_macro),
          .is_double_rd_macro_instr_i (d1_q[i].is_double_macro),
          .is_zcmt_i                  (d1_q[i].is_zcmt),
          .jump_address_i             (d1_q[i].jaddr),
          .branch_predict_i           (d1_q[i].bp),
          .ex_i                       (d1_q[i].ex),
          .pc_i                       (d1_q[i].pc),
          .smt_hart_id_i              (d1_q[i].hart),
          .sbe_o                      (d2_n[i].sbe),
          .instr_o                    (d2_n[i].instr),
          .tinst_o                    (d2_n[i].tinst),
          .compressed_instr_o         (d2_n[i].cinstr),
          .is_compressed_o            (d2_n[i].is_compressed),
          .is_illegal_o               (d2_n[i].is_illegal),
          .ex_o                       (d2_n[i].ex),
          .ecall_o                    (d2_n[i].ecall),
          .ebreak_o                   (d2_n[i].ebreak),
          .frm_req_o                  (d2_n[i].frm_req),
          .check_fprm_o               (d2_n[i].check_fprm),
          .fp_hit_o                   (d2_n[i].fp_hit),
          .illegal_o                  (d2_n[i].illegal),
          .cf_o                       (d2_n[i].cf)
      );
      assign d2_n[i].raw_instr = d1_q[i].raw_instr;

      // D3: privilege/CSR legality + exception/interrupt/debug + final
      // scoreboard entry.  The per-hart context is selected by the hart id
      // recorded in the D2 register (the lane's own hart under mixed
      // residency -- the live fetch_entry may already hold a different lane).
    // svt-stage: end D2
    // svt-stage: begin D3
      g6lc_decode_s3 #(
          .G6LCCfg            (G6LCCfg),
          .exception_t        (exception_t),
          .irq_ctrl_t         (irq_ctrl_t),
          .scoreboard_entry_t (scoreboard_entry_t),
          .interrupts_t       (interrupts_t),
          .INTERRUPTS         (INTERRUPTS)
      ) i_d3 (
          .dec_i                  (d2_q[i].sbe),
          .instr_i                (d2_q[i].instr),
          .tinst_i                (d2_q[i].tinst),
          .compressed_instr_i     (d2_q[i].cinstr),
          .is_compressed_i        (d2_q[i].is_compressed),
          .is_illegal_i           (d2_q[i].is_illegal),
          .ex_i                   (d2_q[i].ex),
          .pc_i                   (d2_q[i].sbe.pc),
          .ecall_i                (d2_q[i].ecall),
          .ebreak_i               (d2_q[i].ebreak),
          .frm_req_i              (d2_q[i].frm_req),
          .check_fprm_i           (d2_q[i].check_fprm),
          .fp_hit_i               (d2_q[i].fp_hit),
          .illegal_i              (d2_q[i].illegal),
          .cf_i                   (d2_q[i].cf),
          .debug_req_i            (debug_req_i),
`ifdef G6LC_MUT_DECODE_ACTIVE_IRQ
          .irq_ctrl_i             (irq_ctrl_i),
          .irq_i                  (irq_i),
`else
          .irq_ctrl_i             (SMT_MIXED_DECODE ? irq_ctrl_b_i[d2_q[i].sbe.hart_id] : irq_ctrl_i),
          .irq_i                  (SMT_MIXED_DECODE ? irq_b_i[d2_q[i].sbe.hart_id] : irq_i),
`endif
          .priv_lvl_i             (SMT_MIXED_DECODE ? priv_lvl_b_i[d2_q[i].sbe.hart_id] : priv_lvl_i),
          .v_i                    (SMT_MIXED_DECODE ? v_b_i[d2_q[i].sbe.hart_id] : v_i),
          .debug_mode_i           (SMT_MIXED_DECODE ? debug_mode_b_i[d2_q[i].sbe.hart_id] : debug_mode_i),
          .fs_i                   (SMT_MIXED_DECODE ? fs_b_i[d2_q[i].sbe.hart_id] : fs_i),
          .vfs_i                  (SMT_MIXED_DECODE ? vfs_b_i[d2_q[i].sbe.hart_id] : vfs_i),
          .frm_i                  (SMT_MIXED_DECODE ? frm_b_i[d2_q[i].sbe.hart_id] : frm_i),
          .vs_i                   (SMT_MIXED_DECODE ? vs_b_i[d2_q[i].sbe.hart_id] : vs_i),
          .tvm_i                  (SMT_MIXED_DECODE ? tvm_b_i[d2_q[i].sbe.hart_id] : tvm_i),
          .tw_i                   (SMT_MIXED_DECODE ? tw_b_i[d2_q[i].sbe.hart_id] : tw_i),
          .vtw_i                  (SMT_MIXED_DECODE ? vtw_b_i[d2_q[i].sbe.hart_id] : vtw_i),
          .tsr_i                  (SMT_MIXED_DECODE ? tsr_b_i[d2_q[i].sbe.hart_id] : tsr_i),
          .hu_i                   (SMT_MIXED_DECODE ? hu_b_i[d2_q[i].sbe.hart_id] : hu_i),
          .mcbie_i                (SMT_MIXED_DECODE ? mcbie_b_i[d2_q[i].sbe.hart_id] : mcbie_i),
          .scbie_i                (SMT_MIXED_DECODE ? scbie_b_i[d2_q[i].sbe.hart_id] : scbie_i),
          .hcbie_i                (SMT_MIXED_DECODE ? hcbie_b_i[d2_q[i].sbe.hart_id] : hcbie_i),
          .mcbcfe_i               (SMT_MIXED_DECODE ? mcbcfe_b_i[d2_q[i].sbe.hart_id] : mcbcfe_i),
          .scbcfe_i               (SMT_MIXED_DECODE ? scbcfe_b_i[d2_q[i].sbe.hart_id] : scbcfe_i),
          .hcbcfe_i               (SMT_MIXED_DECODE ? hcbcfe_b_i[d2_q[i].sbe.hart_id] : hcbcfe_i),
          .mcbze_i                (SMT_MIXED_DECODE ? mcbze_b_i[d2_q[i].sbe.hart_id] : mcbze_i),
          .scbze_i                (SMT_MIXED_DECODE ? scbze_b_i[d2_q[i].sbe.hart_id] : scbze_i),
          .hcbze_i                (SMT_MIXED_DECODE ? hcbze_b_i[d2_q[i].sbe.hart_id] : hcbze_i),
          .instruction_o          (decoded_instruction[i]),
          .orig_instr_o           (orig_instr[i]),
          .is_control_flow_instr_o(is_control_flow_instr[i]),
          .debug_from_trigger_i   (debug_from_trigger_i)
      );
    end

    // stage registers + global shift.  dec_adv is computed by the issue-fill
    // comb block (this module's only ordering owner) and pulses when the whole
    // D2 prefix can move into issue_q or D2 is empty.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        d1_q  <= '0;
        d2_q  <= '0;
        d1_vq <= '0;
        d2_vq <= '0;
      end else if (flush_i) begin
        // hyp8: the staged pipe has no flush_unissued_i port on this module --
        // flush_i is the only kill and clears both stage registers.
        d1_vq <= '0;
        d2_vq <= '0;
      end else if (dec_adv) begin
        for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
          d2_q[i]  <= d2_n[i];
          d2_vq[i] <= d1_vq[i];
          if (fetch_entry_valid_i[i] &&
              ((i == 0) || ~stall_instr_fetch[i])) begin
            // hyp8 lane-0 capture is unconditional on the sequencer stall so
            // macro/Zcmt/CVXIF sub-operations flow through the pipe exactly
            // once (upstream issue-register semantics); the fetch entry is
            // only consumed when ~stall_instr_fetch (see fetch_entry_ready_o).
            d1_q[i]  <= d1_n[i];
            // capture-time validity: same formula as today's
            // decoded_instruction_valid (Zcmt/CVXIF stall marks bubbles)
            d1_vq[i] <= decoded_instruction_valid[i];
          end else begin
            d1_vq[i] <= 1'b0;
          end
        end
      end
    end

    // fetch consumption moved to the D1 capture: a fetch entry leaves the
    // queue when its bundle enters the D1 register and no sequencer stall is
    // pending.  Lane 0 macro/Zcmt sub-ops keep the entry pinned
    // (~stall only on the last emission), matching upstream.
    always_comb begin
      fetch_entry_ready_o = '0;
      if (dec_adv) begin
        for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
          if (fetch_entry_valid_i[i] && ~stall_instr_fetch[i])
            fetch_entry_ready_o[i] = 1'b1;
        end
      end
    end

    // macro sequencer: its issue_ack_i is the D1 fire of lane 0 -- the
    // sub-operation leaving D1 is the staged analogue of the original
    // issue_q[0] pop (the FSM presents the next sub-op on the same edge, which
    // is what the D1 reload captures).
    assign dec_macro_ack = dec_adv && d1_vq[0];
    // svt-stage: end D3
  end
  // G1hd: issued op is JALR when mid-line PC
  // and fetch_entry has exact c.jalr in either
  // half (G1gy analog after ID). Not G1gt
  // any-RVI. Not G1gz. SMT+SS.
  scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0] decoded_hd;
  logic              [G6LCCfg.NrIssuePorts-1:0] is_cf_hd;
  // G1ik: in-ID aligned Branch (issue_q)
  // arms same-line 01 recover the cycle
  // 7b8 sits in ID and 7ba is on fetch.
  // G1je in-ID aligned-00 any op —
  // MINI-FAIL FDT hang @400000. Do not
  // re-land (yanks live mid-line 01
  // Branch after a same-line 00 op).
  logic [G6LCCfg.NrIssuePorts-1:0]       g1ik_id_arm;
  logic [G6LCCfg.NrIssuePorts-1:0][4:0]  g1ik_id_rs1;
  // G1ln: in-ID aligned-00 RVI LOAD
  // (issue_q) arms sibling 01 Branch
  // recover as c.jalr of that rd
  // (G1ik analog; 16-byte line + a3).
  // Keep 01 Branch-bits gate (not G1lm
  // any-01, not G1je any-op). Not G1lk.
  // SMT+SS.
  logic [G6LCCfg.NrIssuePorts-1:0]       g1ln_id_arm;
  logic [G6LCCfg.NrIssuePorts-1:0][4:0]  g1ln_id_rd;
  // G1lz: per-hart g1lo hit (same-hart
  // sibling 01 of that hart's latched
  // 00 LOAD). Not G1lm. SMT+SS.
  logic [G6LCCfg.NrIssuePorts-1:0]       g1lz_hit;
  always_comb begin
    g1ik_id_arm = '0;
    g1ik_id_rs1 = '0;
    g1ln_id_arm = '0;
    g1ln_id_rd  = '0;
    g1lz_hit    = '0;
    // I1: B never arms sibling c.jalr recover. A keeps G1ik/ln/lz.
`ifndef G6LC_FETCH_B
    if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        g1lz_hit[i] = g6lc_sib_cjalr::lz_hit(
            G6LCCfg, g1lo_v_q[fetch_entry_i[i].hart_id],
            fetch_entry_i[i].address[G6LCCfg.VLEN-1:4] ==
                g1lo_line_q[fetch_entry_i[i].hart_id],
            fetch_entry_i[i].address[3] !=
                g1lo_a3_q[fetch_entry_i[i].hart_id]);
        for (int unsigned j = 0; j < G6LCCfg.NrIssuePorts; j++) begin
          if (g6lc_sib_cjalr::ik_arm(
                  G6LCCfg, issue_q[j].valid,
                  issue_q[j].sbe.pc[2:1] == 2'b00,
                  g6lc_core_pkg::op_is_branch(issue_q[j].sbe.op),
                  issue_q[j].sbe.pc[G6LCCfg.VLEN-1:3] ==
                      fetch_entry_i[i].address[G6LCCfg.VLEN-1:3])) begin
            g1ik_id_arm[i] = 1'b1;
            g1ik_id_rs1[i] = issue_q[j].sbe.rs1[4:0];
          end
          if (g6lc_sib_cjalr::ln_arm(
                  G6LCCfg, issue_q[j].valid,
                  issue_q[j].sbe.hart_id ==
                      fetch_entry_i[i].hart_id,
                  issue_q[j].sbe.pc[2:1] == 2'b00,
                  issue_q[j].sbe.fu == g6lc_core_pkg::LOAD,
                  issue_q[j].sbe.rd[4:0] != 5'd0,
                  issue_q[j].sbe.pc[G6LCCfg.VLEN-1:4] ==
                      fetch_entry_i[i].address[G6LCCfg.VLEN-1:4],
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
    if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        if (g6lc_sib_cjalr::mid_cjalr(
                G6LCCfg, decoded_instruction[i].pc[2:1] == 2'b01,
                fetch_entry_i[i].instruction)) begin
          decoded_hd[i].op      = g6lc_core_pkg::JALR;
          decoded_hd[i].fu      = g6lc_core_pkg::CTRL_FLOW;
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
            G6LCCfg, decoded_instruction[i].pc[2:1] == 2'b01,
            g6lc_fe_keep::is_cbranch16(fetch_entry_i[i].instruction[15:0]),
            g6lc_core_pkg::op_is_branch(decoded_instruction[i].op),
            g1hx_v_q &&
                (fetch_entry_i[i].address[G6LCCfg.VLEN-1:3] ==
                 g1hx_line_q) &&
                (fetch_entry_i[i].instruction[15:0] == g1hx_hw_q),
            (i != 0) &&
                (fetch_entry_i[0].address[2:1] == 2'b00) &&
                g6lc_fe_keep::is_cbranch16(
                    fetch_entry_i[0].instruction[15:0]) &&
                (fetch_entry_i[0].address[G6LCCfg.VLEN-1:3] ==
                 fetch_entry_i[i].address[G6LCCfg.VLEN-1:3]) &&
                (fetch_entry_i[0].instruction[15:0] ==
                 fetch_entry_i[i].instruction[15:0]))) begin
          decoded_hd[i].op      = g6lc_core_pkg::JALR;
          decoded_hd[i].fu      = g6lc_core_pkg::CTRL_FLOW;
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
            G6LCCfg, decoded_instruction[i].pc[2:1] == 2'b01,
            g6lc_core_pkg::op_is_branch(decoded_instruction[i].op),
            g1hy_v_q &&
                (fetch_entry_i[i].address[G6LCCfg.VLEN-1:3] ==
                 g1hy_line_q),
            (i != 0) &&
                (fetch_entry_i[0].address[2:1] == 2'b00) &&
                g6lc_rvc_enc::is_cjalr16(
                    fetch_entry_i[0].instruction[31:16]) &&
                (fetch_entry_i[0].address[G6LCCfg.VLEN-1:3] ==
                 fetch_entry_i[i].address[G6LCCfg.VLEN-1:3]))) begin
          decoded_hd[i].op      = g6lc_core_pkg::JALR;
          decoded_hd[i].fu      = g6lc_core_pkg::CTRL_FLOW;
          decoded_hd[i].rs1     = '0;
          decoded_hd[i].rd      = '0;
          decoded_hd[i].result  = '0;
          decoded_hd[i].use_imm = 1'b1;
          decoded_hd[i].use_pc  = 1'b0;
          decoded_hd[i].rs1[4:0] = g1hy_v_q &&
              (fetch_entry_i[i].address[G6LCCfg.VLEN-1:3] ==
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
            G6LCCfg, decoded_instruction[i].pc[2:1] == 2'b01,
            g6lc_core_pkg::op_is_branch(decoded_instruction[i].op),
            g1hx_v_q &&
                (fetch_entry_i[i].address[G6LCCfg.VLEN-1:3] ==
                 g1hx_line_q),
            g1ik_id_arm[i], g1ln_id_arm[i], g1lz_hit[i],
            (i != 0) && fetch_entry_valid_i[0] &&
                (fetch_entry_i[0].address[2:1] == 2'b00) &&
                (fetch_entry_i[0].address[G6LCCfg.VLEN-1:3] ==
                 fetch_entry_i[i].address[G6LCCfg.VLEN-1:3]) &&
                (g6lc_fe_keep::is_cbranch16(
                     fetch_entry_i[0].instruction[15:0]) ||
                 g6lc_sib_cjalr::is_rvi_branch(
                     fetch_entry_i[0].instruction) ||
                 g6lc_core_pkg::op_is_branch(decoded_instruction[0].op)))) begin
          decoded_hd[i].op      = g6lc_core_pkg::JALR;
          decoded_hd[i].fu      = g6lc_core_pkg::CTRL_FLOW;
          decoded_hd[i].rs1     = '0;
          decoded_hd[i].rd      = '0;
          decoded_hd[i].result  = '0;
          decoded_hd[i].use_imm = 1'b1;
          decoded_hd[i].use_pc  = 1'b0;
          decoded_hd[i].rs1[4:0] = (g1hx_v_q &&
              (fetch_entry_i[i].address[G6LCCfg.VLEN-1:3] ==
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
            G6LCCfg, decoded_instruction[i].pc[2:1] == 2'b01,
            g6lc_core_pkg::op_is_branch(decoded_instruction[i].op),
            g6lc_fe_keep::is_cbranch16(fetch_entry_i[i].instruction[15:0]),
            g6lc_sib_cjalr::is_rvi_branch(fetch_entry_i[i].instruction))) begin
          decoded_hd[i].op      = g6lc_core_pkg::ADD;
          decoded_hd[i].fu      = g6lc_core_pkg::ALU;
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
  logic [G6LCCfg.VLEN-1:3] g1hx_line_q;
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
      (G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts);
  logic [G6LCCfg.NrHarts-1:0] g1lo_v_q;
  logic [G6LCCfg.NrHarts-1:0][4:0] g1lo_rd_q;
  logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:4] g1lo_line_q;
  logic [G6LCCfg.NrHarts-1:0] g1lo_a3_q;
  logic [G6LCCfg.NrHarts-1:0] g1lo_cap;
  logic [G6LCCfg.NrHarts-1:0][4:0] g1lo_cap_rd;
  logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:4] g1lo_cap_line;
  logic [G6LCCfg.NrHarts-1:0] g1lo_cap_a3;
  logic [G6LCCfg.NrHarts-1:0] g1lp_01_v;
  logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:4] g1lp_01_line;
  logic [G6LCCfg.NrHarts-1:0] g1md_cmt;
  logic [G6LCCfg.NrHarts-1:0] g1mf_sb;
  logic        g1hy_v_q;
  logic [4:0]  g1hy_rs1_q;
  logic [G6LCCfg.VLEN-1:3] g1hy_line_q;
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
      if (!(G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1))
        g1hx_v_q <= 1'b0;
      g1hy_v_q <= 1'b0;
    end else if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1) begin
`ifndef G6LC_FETCH_B
      for (int unsigned s = 0; s < G6LCCfg.NrIssuePorts; s++) begin
        if (g6lc_sib_cjalr::aligned_br_op(
                G6LCCfg, issue_q[s].valid,
                issue_q[s].sbe.pc[2:1] == 2'b00,
                g6lc_core_pkg::op_is_branch(issue_q[s].sbe.op))) begin
          g1hx_v_q    <= 1'b1;
          g1hx_rs1_q  <= issue_q[s].sbe.rs1[4:0];
          g1hx_line_q <= issue_q[s].sbe.pc[G6LCCfg.VLEN-1:3];
        end
        if (g6lc_sib_cjalr::aligned_br_fetch(
                G6LCCfg, fetch_entry_valid_i[s],
                fetch_entry_i[s].address[2:1] == 2'b00,
                fetch_entry_i[s].instruction,
                g6lc_core_pkg::op_is_branch(decoded_instruction[s].op))) begin
          g1hx_v_q    <= 1'b1;
          g1hx_hw_q   <= fetch_entry_i[s].instruction[15:0];
          g1hx_rs1_q  <= g6lc_sib_cjalr::aligned_br_rs1(
              fetch_entry_i[s].instruction,
              decoded_instruction[s].rs1[4:0]);
          g1hx_line_q <= fetch_entry_i[s].address[G6LCCfg.VLEN-1:3];
        end
        if (g6lc_sib_cjalr::aligned_hi_cjalr(
                G6LCCfg, fetch_entry_valid_i[s],
                fetch_entry_i[s].address[2:1] == 2'b00,
                fetch_entry_i[s].instruction)) begin
          g1hy_v_q    <= 1'b1;
          g1hy_rs1_q  <= fetch_entry_i[s].instruction[27:23];
          g1hy_line_q <= fetch_entry_i[s].address[G6LCCfg.VLEN-1:3];
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
    if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
        G6LCCfg.FETCH_WIDTH >= 64) begin
`ifndef G6LC_FETCH_B
      for (int unsigned s = 0; s < G6LCCfg.NrIssuePorts; s++) begin
        if (g6lc_sib_cjalr::load00(
                G6LCCfg, issue_q[s].valid,
                issue_q[s].sbe.pc[2:1] == 2'b00,
                issue_q[s].sbe.fu == g6lc_core_pkg::LOAD,
                issue_q[s].sbe.rd[4:0] != 5'd0)) begin
          g1lo_cap[issue_q[s].sbe.hart_id]      = 1'b1;
          g1lo_cap_rd[issue_q[s].sbe.hart_id]   = issue_q[s].sbe.rd[4:0];
          g1lo_cap_line[issue_q[s].sbe.hart_id] = issue_q[s].sbe.pc[G6LCCfg.VLEN-1:4];
          g1lo_cap_a3[issue_q[s].sbe.hart_id]   = issue_q[s].sbe.pc[3];
        end
        if (g6lc_sib_cjalr::load00(
                G6LCCfg, fetch_entry_valid_i[s],
                fetch_entry_i[s].address[2:1] == 2'b00,
                decoded_instruction[s].fu == g6lc_core_pkg::LOAD,
                decoded_instruction[s].rd[4:0] != 5'd0)) begin
          g1lo_cap[fetch_entry_i[s].hart_id]      = 1'b1;
          g1lo_cap_rd[fetch_entry_i[s].hart_id]   = decoded_instruction[s].rd[4:0];
          g1lo_cap_line[fetch_entry_i[s].hart_id] = fetch_entry_i[s].address[G6LCCfg.VLEN-1:4];
          g1lo_cap_a3[fetch_entry_i[s].hart_id]   = fetch_entry_i[s].address[3];
        end
        if (fetch_entry_valid_i[s] &&
            (fetch_entry_i[s].address[2:1] == 2'b01)) begin
          g1lp_01_v[fetch_entry_i[s].hart_id]    = 1'b1;
          g1lp_01_line[fetch_entry_i[s].hart_id] = fetch_entry_i[s].address[G6LCCfg.VLEN-1:4];
        end
        if (issue_q[s].valid &&
            (issue_q[s].sbe.pc[2:1] == 2'b01)) begin
          g1lp_01_v[issue_q[s].sbe.hart_id]    = 1'b1;
          g1lp_01_line[issue_q[s].sbe.hart_id] = issue_q[s].sbe.pc[G6LCCfg.VLEN-1:4];
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
      for (int unsigned h = 0; h < G6LCCfg.NrHarts; h++) begin
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
      for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++) begin
        if (g6lc_sib_cjalr::cmt_load00(
                G6LCCfg, commit_ack_i[c],
                commit_instr_i[c].ex.valid,
                commit_instr_i[c].is_compressed,
                commit_instr_i[c].pc[2:1] == 2'b00,
                commit_instr_i[c].fu == g6lc_core_pkg::LOAD,
                commit_instr_i[c].rd[4:0] != 5'd0)) begin
          g1lo_cap[commit_instr_i[c].hart_id]      = 1'b1;
          g1lo_cap_rd[commit_instr_i[c].hart_id]   = commit_instr_i[c].rd[4:0];
          g1lo_cap_line[commit_instr_i[c].hart_id] = commit_instr_i[c].pc[G6LCCfg.VLEN-1:4];
          g1lo_cap_a3[commit_instr_i[c].hart_id]   = commit_instr_i[c].pc[3];
          g1md_cmt[commit_instr_i[c].hart_id]      = 1'b1;
        end
      end
      // G1mf: SB result-valid 00 RVI
      // LOAD last-replaces (WB done,
      // before commit_ack). Keep 01
      // Branch-bits recover. Not G1lm.
      // Not G1lk. SMT+SS.
      for (int unsigned h = 0; h < G6LCCfg.NrHarts; h++) begin
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
      if (!(G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1))
        g1lo_v_q <= '0;
      // G1me: commit capture beats
      // flush_i (G1kp analog). A
      // retiring 00 LOAD on leftover
      // jal flush was skipped. Not
      // consume. Not G1lk. SMT+SS.
      // I1: B does not keep a sibling-LOAD latch across flush.
`ifndef G6LC_FETCH_B
      else if (G6LCCfg.FETCH_WIDTH >= 64) begin
        for (int unsigned h = 0; h < G6LCCfg.NrHarts; h++) begin
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
    end else if (G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
                 G6LCCfg.FETCH_WIDTH >= 64) begin
`ifndef G6LC_FETCH_B
      for (int unsigned h = 0; h < G6LCCfg.NrHarts; h++) begin
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
          for (int unsigned s = 0; s < G6LCCfg.NrIssuePorts; s++) begin
            // G1ks analog: consume only
            // at same-hart sibling 01.
            // Not G1if any-slot. SMT+SS.
            if (g1lo_v_q[h] &&
                fetch_entry_valid_i[s] &&
                (fetch_entry_i[s].hart_id == G1LZ_HID'(h)) &&
                (fetch_entry_i[s].address[2:1] == 2'b01) &&
                (fetch_entry_i[s].address[G6LCCfg.VLEN-1:4] ==
                 g1lo_line_q[h]) &&
                (fetch_entry_i[s].address[3] != g1lo_a3_q[h]))
              g1lo_v_q[h] <= 1'b0;
            if (g1lo_v_q[h] &&
                issue_q[s].valid &&
                (issue_q[s].sbe.hart_id == G1LZ_HID'(h)) &&
                (issue_q[s].sbe.pc[2:1] == 2'b01) &&
                (issue_q[s].sbe.pc[G6LCCfg.VLEN-1:4] ==
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
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    assign issue_entry_o[i] = issue_q[i].sbe;
    assign issue_entry_o_prev[i] = G6LCCfg.FpgaAlteraEn ? issue_n[i].sbe : '0;
    assign issue_entry_valid_o[i] = issue_q[i].valid;
    assign is_ctrl_flow_o[i] = issue_q[i].is_ctrl_flow;
    assign orig_instr_o[i] = issue_q[i].orig_instr;
    assign rvfi_instr_o[i] = issue_q[i].rvfi_instr;
  end

  if (G6LCCfg.SuperscalarEn) begin : gen_ss_drain
    // N-wide (2..8) ID↔issue register: compact on ack, then fill from fetch ports.
    // hyp8: staged-assign form — each pipeline step (ack-clear -> compact ->
    // G1* override -> free-rank fill -> flush) is a named signal with single
    // writes per LHS, so the structural model bills each step's cone once
    // instead of chaining ~30 sequential issue_n patches.
    localparam int unsigned NIP = G6LCCfg.NrIssuePorts;
    localparam int unsigned ISW = $bits(issue_struct_t);
    localparam int unsigned FRW = (NIP > 1) ? $clog2(NIP + 1) : 1;

    // Port 0 validity accounts for ZCMT/CVXIF stalls; other ports are simple.
    // hyp8 RVZCMT and CvxifEn are 0. The struct compares do not fold, so the
    // old priority ternary was still timed at the head of the drain cone.
    assign decoded_instruction_valid[0] = 1'b1;
    for (genvar i = 1; i < NIP; i++)
      assign decoded_instruction_valid[i] = ~stall_instr_fetch[i];

    // S0: post-ack valids
    logic [NIP-1:0] vpost;
    for (genvar i = 0; i < NIP; i++)
      assign vpost[i] = issue_q[i].valid && !issue_instr_ack_i[i];

    // S1: compact remaining valids toward port 0 (preserve program order).
    // crank[i] = # live slots below i; ca[j] gathers the entry whose rank
    // is j (one-hot masked-OR; ranks are unique so no two writers collide).
    logic [NIP-1:0][FRW-1:0] crank;
    logic [NIP-1:0][NIP-1:0][ISW-1:0] cm;
    logic [NIP-1:0][ISW-1:0]       ca;
    logic [FRW:0]                wptr;
    issue_struct_t               ca0s;
    for (genvar i = 0; i < NIP; i++) begin : gen_crank
      if (i == 0) begin : gen_r0
        assign crank[i] = '0;
      end else begin : gen_rn
        assign crank[i] = FRW'($countones(vpost[i-1:0]));
      end
    end
    assign wptr = (FRW + 1)'($countones(vpost));
    for (genvar j = 0; j < NIP; j++) begin : gen_cj
      for (genvar i = 0; i < NIP; i++) begin : gen_ci
        assign cm[j][i] = {ISW{vpost[i] && (crank[i] == FRW'(j))}} &
                          {vpost[i], issue_q[i][ISW-2:0]};
      end
      // Per-bit OR across the lane rows (ranks are unique -- at most one
      // lane wins each j). A scalar |cm[j] reduce would collapse to a
      // single bit in bit 0 and leave ca[j].valid = 0: issue_q would then
      // read as permanently empty and refill every cycle, retracting the
      // scoreboard's hold-until-ack offer.
      always_comb begin
        ca[j] = '0;
        for (int unsigned i = 0; i < NIP; i++) ca[j] = ca[j] | cm[j][i];
      end
    end
    assign ca0s = issue_struct_t'(ca[0]);

    // S2: G1* overrides — splice an older fetch in front of a parked branch
    // (I6: B issues IQ order; A-only, smt_legacy). All four cases take the
    // same action: literal at port 0, compacted[0] pushed to port 1.
    logic         ovr_any, fet_ok0;
    logic [ISW-1:0] ovr_lit;
    assign fet_ok0 = fetch_entry_valid_i[0] && ~stall_instr_fetch[0];
    assign ovr_lit = {decoded_instruction_valid[0],
                      decoded_hd[0],
                      orig_instr[0],
                      is_cf_hd[0],
                      is_compressed_rvc[0]
                          ? {16'b0, fetch_entry_i[0].instruction[15:0]}
                          : fetch_entry_i[0].instruction,
                      is_compressed_rvc[0]};
`ifndef G6LC_FETCH_B
    logic o_g1be, o_g1cy, o_g1em, o_g1ev;
    // G1be: ID[0] is a Branch and fetch[0] is an older same-line
    // NoCF dest (c.li@0x4d0 vs beq@0x4d4). Insert the prefix at
    // port 0, shift the Branch to port 1. Only when port 1 is
    // empty (do not drop a live ID insn). SMT+SS. Not G1ay (that
    // stalls SB). Not G1bd replay. Not G1at alloc. Not G1ac.
    assign o_g1be = G6LCCfg.NrHarts > 1 &&
        ca0s.valid && !(wptr >= 2) &&
        ca0s.sbe.fu == g6lc_core_pkg::CTRL_FLOW &&
        g6lc_core_pkg::op_is_branch(ca0s.sbe.op) &&
        fet_ok0 && decoded_instruction_valid[0] &&
        (decoded_instruction[0].fu == g6lc_core_pkg::ALU ||
         decoded_instruction[0].fu == g6lc_core_pkg::LOAD) &&
        decoded_instruction[0].rd[4:0] != 5'd0 &&
        decoded_instruction[0].hart_id == ca0s.sbe.hart_id &&
        decoded_instruction[0].pc < ca0s.sbe.pc &&
        decoded_instruction[0].pc[G6LCCfg.VLEN-1:3] ==
            ca0s.sbe.pc[G6LCCfg.VLEN-1:3];
    // G1cy: leftover-complete slot0 Jump (jal@0x3f6, pc[2:1]==11)
    // must issue before later-slot fallthrough. SMT+SS.
    assign o_g1cy = G6LCCfg.NrHarts > 1 &&
        ca0s.valid && !(wptr >= 2) &&
        fet_ok0 && decoded_instruction_valid[0] &&
        decoded_instruction[0].fu == g6lc_core_pkg::CTRL_FLOW &&
        is_control_flow_instr[0] &&
        !g6lc_core_pkg::op_is_branch(decoded_instruction[0].op) &&
        decoded_instruction[0].op != g6lc_core_pkg::JALR &&
        decoded_instruction[0].pc[2:1] == 2'b11 &&
        decoded_instruction[0].hart_id == ca0s.sbe.hart_id &&
        decoded_instruction[0].pc < ca0s.sbe.pc;
    // G1em: ID[0] is a Branch on a0 and fetch[0] is an
    // older same-hart CSR to a0. SMT+SS.
    assign o_g1em = G6LCCfg.NrHarts > 1 &&
        ca0s.valid && !(wptr >= 2) &&
        ca0s.sbe.fu == g6lc_core_pkg::CTRL_FLOW &&
        g6lc_core_pkg::op_is_branch(ca0s.sbe.op) &&
        (ca0s.sbe.rs1[4:0] == 5'd10) &&
        fet_ok0 && decoded_instruction_valid[0] &&
        decoded_instruction[0].fu == g6lc_core_pkg::CSR &&
        decoded_instruction[0].rd[4:0] == 5'd10 &&
        decoded_instruction[0].hart_id == ca0s.sbe.hart_id &&
        decoded_instruction[0].pc < ca0s.sbe.pc;
    // G1ev: ID[0] is a Branch on a0 and fetch[0] is an
    // older same-hart ALU to a0. G1em is CSR-only. SMT+SS.
    assign o_g1ev = G6LCCfg.NrHarts > 1 &&
        ca0s.valid && !(wptr >= 2) &&
        ca0s.sbe.fu == g6lc_core_pkg::CTRL_FLOW &&
        g6lc_core_pkg::op_is_branch(ca0s.sbe.op) &&
        (ca0s.sbe.rs1[4:0] == 5'd10) &&
        fet_ok0 && decoded_instruction_valid[0] &&
        decoded_instruction[0].fu == g6lc_core_pkg::ALU &&
        decoded_instruction[0].rd[4:0] == 5'd10 &&
        decoded_instruction[0].hart_id == ca0s.sbe.hart_id &&
        decoded_instruction[0].pc < ca0s.sbe.pc;
    assign ovr_any = o_g1be || o_g1cy || o_g1em || o_g1ev;
`else
    assign ovr_any = 1'b0;
`endif

    // S3: post-override entries (ib) and their valids (vb).
    logic [NIP-1:0][ISW-1:0] ib;
    logic [NIP-1:0]          vb;
    assign ib[0] = ovr_any ? ovr_lit : ca[0];
    assign vb[0] = ib[0][ISW-1];
    for (genvar i = 1; i < NIP; i++) begin : gen_ib
      if (i == 1) begin : gen_i1
        assign ib[i] = ovr_any ? ca[0] : ca[i];
      end else begin : gen_in
        assign ib[i] = ca[i];
      end
      assign vb[i] = ib[i][ISW-1];
    end

    // S4: free-slot ranks and the fill source pack (fetch for the 1-stage
    // path, the D2 prefix for DecodeStages==3). fr[i] is the rank of free
    // slot i among the free slots; slot i takes the source lane of that
    // rank when the lane's valid prefix holds.
    logic [NIP-1:0][FRW-1:0] fr;
    logic [FRW:0]            free_cnt;
    for (genvar i = 0; i < NIP; i++) begin : gen_fr
      if (i == 0) begin : gen_f0
        assign fr[i] = '0;
      end else begin : gen_fn
        assign fr[i] = FRW'($countones(~vb[i-1:0]));
      end
    end
    assign free_cnt = (FRW + 1)'($countones(~vb));

    logic [NIP-1:0]          fok, fpref, d2pref;
    logic [NIP-1:0][ISW-1:0] fpack, d2pack;
    for (genvar k = 0; k < NIP; k++) begin : gen_src
      // fet_used mirrors the ready port state at the point the emit sampled
      // it: '0 base plus the port-0 override set.
      assign fok[k] = fetch_entry_valid_i[k] &&
                      !(k == 0 && ovr_any) && ~stall_instr_fetch[k];
      assign fpref[k] = (k == 0) ? fok[0] : (fpref[k-1] & fok[k]);
      assign fpack[k] = {decoded_instruction_valid[k],
                         decoded_hd[k],
                         orig_instr[k],
                         is_cf_hd[k],
                         is_compressed_rvc[k]
                             ? {16'b0, fetch_entry_i[k].instruction[15:0]}
                             : fetch_entry_i[k].instruction,
                         is_compressed_rvc[k]};
      // Prefix AND as a reduction, not a serial chain through d2pref[k-1].
      assign d2pref[k] = &d2_vq[k:0];
      assign d2pack[k] = {1'b1,
                          decoded_hd[k],
                          orig_instr[k],
                          is_cf_hd[k],
                          d2_q[k].is_compressed ? {16'b0, d2_q[k].cinstr}
                                                : d2_q[k].raw_instr,
                          d2_q[k].is_compressed};
    end

    // dec_adv: the D2 prefix drains only when every valid lane fits the
    // free slots; the whole pipe shifts together.
    logic [FRW:0] nd2;
    assign nd2 = (FRW + 1)'($countones(d2_vq));
    // hyp8 DecodeStages is 3. The ==1 arm does not fold and muxed the
    // whole issue entry. D2 is the live fill source.
    assign dec_adv = (nd2 == '0) || ((FRW + 1)'(wptr) + nd2 <= NIP);

    // S5: per-port next-state = fill ? pack[fr] : post-override entry,
    // valid cleared on flush (payload preserved, matching the emit).
    logic [NIP-1:0][ISW-1:0] pack_sel;
    logic [NIP-1:0]          pref_sel;
    assign pack_sel = d2pack;
    assign pref_sel = d2pref;
    for (genvar i = 0; i < NIP; i++) begin : gen_issue_n
      logic [ISW-1:0] sel_i, pack_i;
      logic [NIP-1:0][ISW-1:0] pack_lane;
      logic           fill_i;
      assign fill_i = !vb[i] && (fr[i] < NIP) && pref_sel[fr[i]] && dec_adv;
      // Rank select is a one-hot of the constant lanes, not pack_sel[fr].
      for (genvar k = 0; k < NIP; k++) begin : gen_pack_lane
        assign pack_lane[k] = (fr[i] == FRW'(k)) ? pack_sel[k] : '0;
      end
      always_comb begin
        pack_i = '0;
        for (int unsigned k = 0; k < NIP; k++) pack_i = pack_i | pack_lane[k];
      end
      always_comb begin
        unique case (fill_i)
          1'b1:    sel_i = pack_i;
          default: sel_i = ib[i];
        endcase
      end
      assign issue_n[i] = issue_struct_t'({~flush_i && sel_i[ISW-1],
                                           sel_i[ISW-2:0]});
    end

    // Fetch handshake: strict-prefix acceptance in the 1-stage path plus
    // the override's port-0 grab. Under DecodeStages==3 the D1-capture
    // comb owns fetch_entry_ready_o (the emit's override write raced it).
    if (HypCfg.DecodeStages == 1) begin : gen_fready
      for (genvar k = 0; k < NIP; k++) begin : gen_rdy
        assign fetch_entry_ready_o[k] =
            ((k == 0) && ovr_any) || (fpref[k] && (free_cnt > (FRW + 1)'(k)));
      end
    end

//pragma translate_off
    // Opt-in: ungated this floods ~134 MB into every run's log, which both
    // hides real output and costs the verdict reader time and memory.
    always_comb begin
      if (id_dbg_trace && $time() < 200000)
        for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++)
          if (fetch_entry_valid_i[i])
            $display("[id-dbg] t=%0t port=%0d fetch_addr=%h instr=%h is_illegal=%b dec_pc=%h dec_ex=%b",
                     $time, i, fetch_entry_i[i].address, fetch_entry_i[i].instruction, is_illegal_rvc[i],
                     decoded_instruction[i].pc, decoded_instruction[i].ex.valid);
    end
//pragma translate_on
  end else if (1'b0) begin
    // Scalar drain. hyp8 SuperscalarEn is 1; a literal false keeps this arm
    // out of the timing walk (the struct compare does not fold).
    always_comb begin
      issue_n = issue_q;
      if (HypCfg.DecodeStages == 1) fetch_entry_ready_o = '0;
      // instruction is not valid if we stall due to ZCMT or CVXIF
      decoded_instruction_valid[0] = (G6LCCfg.RVZCMT && is_zcmt_instr[0] && stall_macro_deco_zcmt) ||
                                     (G6LCCfg.CvxifEn && is_illegal_cvxif_i && ~stall_macro_deco && stall_instr_fetch[0])
                                     ? 1'b0 : 1'b1;
      // Clear the valid flag if issue has acknowledged the instruction
      if (issue_instr_ack_i[0]) issue_n[0].valid = 1'b0;

      // TODO: redo
      // if we have a space in the register and the fetch is valid, go get it
      // or the issue stage is currently acknowledging an instruction, which means that we will have space
      // for a new instruction
      if (HypCfg.DecodeStages == 1) begin
        if (!issue_n[0].valid && fetch_entry_valid_i[0]) begin
          fetch_entry_ready_o[0] = ~stall_instr_fetch[0];
          issue_n[0] = '{
              decoded_instruction_valid[0],
              decoded_hd[0],
              orig_instr[0],
              is_cf_hd[0],
              is_compressed_rvc[0] ? {16'b0, fetch_entry_i[0].instruction[15:0]} : fetch_entry_i[0].instruction,
              is_compressed_rvc[0]
          };
        end
        dec_adv = 1'b0;
      end else begin
        // hyp8 DecodeStages==3: D2 drains into issue_q[0] when the slot is
        // free (post-ack); the whole pipe shifts on dec_adv.  Fetch handshake
        // lives at the D1 capture in gen_dec3.
        dec_adv = ~d2_vq[0] || !issue_n[0].valid;
        if (dec_adv && d2_vq[0] && !issue_n[0].valid) begin
          issue_n[0] = '{
              1'b1,
              decoded_hd[0],
              orig_instr[0],
              is_cf_hd[0],
              d2_q[0].is_compressed ? {16'b0, d2_q[0].cinstr} : d2_q[0].raw_instr,
              d2_q[0].is_compressed
          };
        end
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

//pragma translate_off
  // M3 bring-up probe (+icf_trace): why the SB offer retracts/changes before
  // the dispatch ack arrives.
  logic idq_trace;
  initial idq_trace = $test$plusargs("icf_trace");
  if (G6LCCfg.SuperscalarEn) begin : gen_idq_probe
    always_ff @(negedge clk_i) begin
      if (rst_ni && idq_trace && $time() < 420 && $time() > 280 &&
          (issue_q[0].valid || issue_q[1].valid || |issue_instr_ack_i || flush_i)) begin
        $display("[idq] t=%0t q0v=%b q0pc=%h q1v=%b q1pc=%h | ack=%b vp=%b w=%0d | adv=%b d2v=%b nd2=%0d f=%b fv=%b",
          $time, issue_q[0].valid, issue_q[0].sbe.pc, issue_q[1].valid,
          issue_q[1].sbe.pc, issue_instr_ack_i, gen_ss_drain.vpost,
          gen_ss_drain.wptr, dec_adv, d2_vq, gen_ss_drain.nd2,
          flush_i, fetch_entry_valid_i);
      end
    end
  end
//pragma translate_on

//pragma translate_off
  // -------------------------------------------------------------------------
  // I1 AT SUPPLY (`+fetch_i1_check`): the instruction presented at address A is
  // the instruction at A in memory.
  //
  // This is the promise nothing in the repo owned. Every fetch formal contract
  // takes the response bytes as a FREE input and proves the realigner and queue
  // are faithful to whatever they are handed -- the right contract for those
  // modules, and exactly why an 11/11 green gate coexisted with a core executing
  // instructions offset 0x10 from its own PC. The realigner was faultless; it was
  // handed the wrong window.
  //
  // Checked at the DELIVERY point rather than the I$ port: this covers the I$, the
  // realigner and the queue in one sentence, and (address, instruction) is the
  // pair decode actually consumes. L3 is the earliest rung that can express it at
  // all -- the claim relates the DUT to the memory image, which no bounded module
  // proof can see -- so per the push-left rule it belongs here, not in a soak.
  //
  // In its own clocked block, not inside the combinational decode block: nested
  // automatics there are not assigned on every control path and get reported as
  // inferred latches (AGENTS.md s0.1), and a checker should sample state rather
  // than participate in it. Read-only and opt-in -- an oracle must not perturb
  // what it observes -- and silent outside the preloaded DRAM image (bootrom,
  // CLINT), which the DPI reports by returning 0.
  // -------------------------------------------------------------------------
  longint unsigned i1_a;
  longint          i1_lo, i1_hi;
  logic [127:0]    i1_win;
  logic [31:0]     i1_want;
  int unsigned     i1_sh;
  // i1_bad / i1_seen are declared with i1_chk_en at the top of the module;
  // the always_ff below is their only writer.

  // verilog_lint: waive always-ff-non-reset
  always_ff @(posedge clk_i) begin
    if (rst_ni && i1_chk_en) begin
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        if (fetch_entry_valid_i[i]) begin
          i1_a = longint'(fetch_entry_i[i].address);
          // Two adjacent 64-bit words, so a 32-bit instruction straddling the
          // 8-byte boundary is still compared against the right bytes.
          if (g6lc_dram_peek64(longint'(i1_a & ~64'h7), i1_lo) == 1 &&
              g6lc_dram_peek64(longint'((i1_a & ~64'h7) + 8), i1_hi) == 1) begin
            i1_win  = {i1_hi, i1_lo};
            i1_sh   = 8 * int'(i1_a & 64'h7);
            i1_want = i1_win[i1_sh+:32];
            i1_seen = i1_seen + 1;
            // RVC: only the low halfword is architecturally the instruction.
            if (fetch_entry_i[i].instruction[1:0] == 2'b11) begin
              if (fetch_entry_i[i].instruction !== i1_want) begin
                i1_bad = i1_bad + 1;
                $display(
                    "[fetch-i1] VIOLATION addr=%h got=%h want=%h (bytes presented are not the bytes at this address)",
                    i1_a, fetch_entry_i[i].instruction, i1_want);
              end
            end else if (fetch_entry_i[i].instruction[15:0] !== i1_want[15:0]) begin
              i1_bad = i1_bad + 1;
              $display("[fetch-i1] VIOLATION addr=%h got=%h want=%h (rvc halfword mismatch)",
                       i1_a, fetch_entry_i[i].instruction[15:0], i1_want[15:0]);
            end
          end
        end
      end
    end
  end

  final begin
    if (i1_chk_en) $display("[fetch-i1] checked=%0d violations=%0d", i1_seen, i1_bad);
  end
//pragma translate_on

  // svt-stage: use D1 on=d1_q,d1_vq
  // svt-stage: use D2 on=d2_q,d2_vq
  // svt-stage: class D1 value
  // svt-stage: class D2 value
  // svt-stage: class D3 value
endmodule
