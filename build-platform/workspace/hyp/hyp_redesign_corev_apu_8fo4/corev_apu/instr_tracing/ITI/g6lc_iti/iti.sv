// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright (c) 2025 Thales DIS design services SAS
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Author: Maxime Colson - Thales
// Date: 20/03/2025
// Contributors: 
// Darshak Sheladiya, SYSGO GmbH
// Umberto Laghi, UNIBO
// Modified by: Etienne Cimon (+core_notrace gate on the sim-only iti.traces writes)

// For reference : See Section 4.2 Instruction Trace Interface from Efficient Trace for RISC-V v2.0 (may 5 2022)
// iti stand for Instruction Trace Interface, changing because tip (Trace Ingress Port) and "type" are too similar creating confusion 

module g6lc_iti #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter CAUSE_LEN = 5,  //Size is ecause_width_p in the E-Trace SPEC
    parameter ITYPE_LEN = 3,  //Size is itype_width_p in the E-Trace SPEC (3 or 4)
    parameter IRETIRE_LEN = 32,  //Size is iretire_width_p in the E-Trace SPEC
    parameter block_mode = 0,
    parameter type rvfi_to_iti_t = logic,
    parameter type iti_to_encoder_t = logic
) (
    input logic clk_i,
    input logic rst_ni,

    input logic [G6LCCfg.NrCommitPorts-1:0] valid_i,
    input rvfi_to_iti_t rvfi_to_iti_i,

    output logic [G6LCCfg.NrCommitPorts-1:0] valid_o,
    output iti_to_encoder_t iti_to_encoder_o
);

  // pragma translate_off
  int f;
  bit core_trace_en;  // +core_notrace skips the per-packet writes (corev_apu/tb/g6lc_tb.cpp)
  initial begin
    core_trace_en = !$test$plusargs("core_notrace");
    f = $fopen("iti.traces", "w");
    $fwrite(f, "itype_0,cause,tval,priv,iaddr_0,context,ctype,iretire_0,ilastsize_0\n");
  end
  final $fclose(f);
  // pragma translate_on

  /* Structure used for each instr*/
  localparam type uop_entry_t = struct packed {
    logic                    valid;
    logic [G6LCCfg.XLEN-1:0] pc;
    iti_pkg::itype_t         itype;
    logic                    compressed;
    riscv::priv_lvl_t        priv;
    logic [63:0]             cycles;
  };

  /* Structure used to output trace_signals if special instr */
  localparam type itt_out_t = struct packed {
    logic                    valid;
    logic [IRETIRE_LEN-1:0]  iretire;
    iti_pkg::itype_t         itype;
    logic                    ilastsize;
    logic [G6LCCfg.XLEN-1:0] iaddr;
    riscv::priv_lvl_t        priv;
    logic [CAUSE_LEN-1:0]    cause;
    logic [G6LCCfg.XLEN-1:0] tval;
    logic [63:0]             cycles;
  };

  logic interrupt;
  iti_pkg::itype_t [G6LCCfg.NrCommitPorts-1:0] itype;

  logic [IRETIRE_LEN-1:0] counter_d, counter_q;
  logic [G6LCCfg.XLEN-1:0] addr_d, addr_q;
  logic special_d, special_q;

  uop_entry_t [G6LCCfg.NrCommitPorts-1:0] uop_entry;
  itt_out_t [G6LCCfg.NrCommitPorts-1:0] itt_out;

  logic [G6LCCfg.NrCommitPorts-1:0][IRETIRE_LEN-1:0] counter_itt;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] addr_itt;
  logic [G6LCCfg.NrCommitPorts-1:0] special_itt;
  logic [G6LCCfg.NrCommitPorts-1:0][CAUSE_LEN-1:0] cause_itt;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] tval_itt;

  logic [G6LCCfg.NrCommitPorts-1:0][IRETIRE_LEN-1:0] counter;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] addr;
  logic [G6LCCfg.NrCommitPorts-1:0] special;


  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_iti  region=8602  makespan=0.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: addr_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to addr_q
// order expect: counter_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to counter_q
// order expect: special_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to special_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     addr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     counter_q <= …; // sv-timing: cycle 1/1 on clk_i
//     special_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node28003 c=0.00 slack=0.00 */
//     /* node28004 c=0.00 slack=0.00 */
//     /* node28005 c=0.00 slack=0.00 */
//     /* node28006 c=0.00 slack=0.00 */
//     /* node28007 c=0.00 slack=0.00 */
//     /* node28008 c=0.00 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign interrupt = rvfi_to_iti_i.cause[G6LCCfg.XLEN-1];  // determined based on the MSB of cause

  for (genvar i = 0; i < G6LCCfg.NrCommitPorts; i++) begin
    itype_detector #(
        .ITYPE_LEN(ITYPE_LEN)
    ) i_itype_detector (
        .valid_i       (valid_i[i]),
        .exception_i   (rvfi_to_iti_i.ex_valid),
        .interrupt_i   (interrupt),
        .op_i          (rvfi_to_iti_i.op[i]),
        .branch_taken_i(rvfi_to_iti_i.is_taken[i]),
        .itype_o       (itype[i])
    );

    // Adding this to ensure that interrupt/exception happen only in commit port 0 of g6lc
    assign cause_itt[i] = i == 0 ? rvfi_to_iti_i.cause[CAUSE_LEN-1:0] : '0;
    assign tval_itt[i]  = i == 0 ? rvfi_to_iti_i.tval : '0;

    if (block_mode) begin
      // Systolic logic (First block_retirement is connected to D Flip-Flop to continue computation if needed)
      assign counter_itt[i] = i == 0 ? counter_q : counter[i-1];
      assign addr_itt[i] = i == 0 ? addr_q : addr[i-1];
      assign special_itt[i] = i == 0 ? special_q : special[i-1];

      block_retirement #(
          .G6LCCfg(G6LCCfg),
          .uop_entry_t(uop_entry_t),
          .itt_out_t(itt_out_t),
          .CAUSE_LEN(CAUSE_LEN),
          .ITYPE_LEN(ITYPE_LEN),
          .IRETIRE_LEN(IRETIRE_LEN)
      ) i_block_retirement (
          .uop_entry_i(uop_entry[i]),
          .cause_i(cause_itt[i]),
          .tval_i(tval_itt[i]),
          .counter_i(counter_itt[i]),
          .iaddr_i(addr_itt[i]),
          .was_special_i(special_itt[i]),
          .itt_out_o(itt_out[i]),
          .counter_o(counter[i]),
          .iaddr_o(addr[i]),
          .is_special_o(special[i])
      );

    end else begin
      single_retirement #(
          .G6LCCfg(G6LCCfg),
          .uop_entry_t(uop_entry_t),
          .itt_out_t(itt_out_t),
          .CAUSE_LEN(CAUSE_LEN),
          .ITYPE_LEN(ITYPE_LEN),
          .IRETIRE_LEN(IRETIRE_LEN)
      ) i_single_retirement (
          .uop_entry_i(uop_entry[i]),
          .cause_i(cause_itt[i]),
          .tval_i(tval_itt[i]),
          .itt_out_o(itt_out[i])
      );

    end
  end


  always_comb begin
    iti_to_encoder_o.cause  = '0;
    iti_to_encoder_o.tval   = '0;
    iti_to_encoder_o.priv   = riscv::PRIV_LVL_U;
    iti_to_encoder_o.cycles = '0;
    for (int i = 0; i < G6LCCfg.NrCommitPorts; i++) begin
      uop_entry[i].valid = valid_i[i];
      uop_entry[i].pc = rvfi_to_iti_i.pc[i];
      uop_entry[i].itype = itype[i];
      uop_entry[i].compressed = rvfi_to_iti_i.is_compressed[i];
      uop_entry[i].priv = rvfi_to_iti_i.priv_lvl;
      uop_entry[i].cycles = rvfi_to_iti_i.cycles;

      iti_to_encoder_o.valid[i] = 1'b0;
      iti_to_encoder_o.iretire[i] = '0;
      iti_to_encoder_o.ilastsize[i] = '0;
      iti_to_encoder_o.itype[i] = iti_pkg::STANDARD;
      iti_to_encoder_o.iaddr[i] = '0;

      valid_o[i] = 1'b0;

      if (itt_out[i].valid) begin
        valid_o[i] = itt_out[i].valid;
        iti_to_encoder_o.valid[i] = itt_out[i].valid;
        iti_to_encoder_o.iretire[i] = itt_out[i].iretire;
        iti_to_encoder_o.ilastsize[i] = itt_out[i].ilastsize;
        iti_to_encoder_o.itype[i] = itt_out[i].itype;
        iti_to_encoder_o.iaddr[i] = itt_out[i].iaddr;
        iti_to_encoder_o.priv = itt_out[i].priv; // privilege don't change between 2 instr committed in the same cycle
        iti_to_encoder_o.cycles = itt_out[i].cycles;  // Same here (same time at same cycle)
      end
    end
    if (itt_out[0].valid) begin  // interrupt & exception only in port 0
      iti_to_encoder_o.cause = itt_out[0].cause;
      iti_to_encoder_o.tval  = itt_out[0].tval;
    end
  end
  if (block_mode) begin
    assign counter_d = counter[G6LCCfg.NrCommitPorts-1];
    assign addr_d = addr[G6LCCfg.NrCommitPorts-1];
    assign special_d = special[G6LCCfg.NrCommitPorts-1];
  end

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (block_mode) begin
      if (!rst_ni) begin
        counter_q <= '0;
        addr_q <= '0;
        special_q <= 1'b1;
      end else begin
        counter_q <= counter_d;
        addr_q <= addr_d;
        special_q <= special_d;
      end
    end
    //pragma translate_off
    for (int i = 0; i < G6LCCfg.NrCommitPorts; i++) begin
      if (itt_out[i].valid && core_trace_en) begin
        $fwrite(f, "%d,%0d,%0d,%d,%h,0,0,%0d,%0d\n", itt_out[i].itype, itt_out[i].cause,
                itt_out[i].tval, itt_out[i].priv, itt_out[i].iaddr, itt_out[i].iretire,
                itt_out[i].ilastsize);
      end
    end
    //pragma translate_on
  end


endmodule
