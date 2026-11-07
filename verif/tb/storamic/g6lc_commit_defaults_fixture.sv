// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Minimal conforming injected types; the full CPU type is checked separately.
package g6lc_commit_defaults_pkg;
  import ariane_pkg::*;
  localparam config_pkg::cva6_cfg_t CVA6Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  localparam int HartBits = CVA6Cfg.NrHarts > 1 ? $clog2(CVA6Cfg.NrHarts) : 1;
  typedef struct packed {
    logic [CVA6Cfg.XLEN-1:0] cause, tval;
    logic [CVA6Cfg.GPLEN-1:0] tval2;
    logic [31:0] tinst;
    logic gva, valid;
  } exception_t;
  typedef struct packed {
    logic [CVA6Cfg.VLEN-1:0] pc;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;
    fu_t fu;
    fu_op op;
    logic [REG_ADDR_SIZE-1:0] rd;
    logic [CVA6Cfg.XLEN-1:0] result;
    logic valid;
    exception_t ex;
    logic is_macro_instr, is_last_macro_instr, vfp;
    logic [HartBits-1:0] hart_id;
  } scoreboard_entry_t;
endpackage

module g6lc_commit_defaults_dut
  import g6lc_commit_defaults_pkg::*;
  import ariane_pkg::*;
#(parameter int Ports = 2) (
  input logic clk_i, rst_ni, halt_i,
  input scoreboard_entry_t [Ports-1:0] entries_i,
  input logic [Ports-1:0] drop_i, replay_i,
  input amo_resp_t amo_i,
  output logic [Ports-1:0] ack_o, gpr_o, fpr_o,
  output logic [Ports-1:0][CVA6Cfg.XLEN-1:0] data_o,
  output logic [Ports-1:0][4:0] addr_o
);
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = CVA6Cfg;
    c.NrCommitPorts = Ports;
    c.SuperscalarEn = Ports > 1;
    return c;
  endfunction
  commit_stage #(.CVA6Cfg(cfg()), .exception_t(exception_t),
                 .scoreboard_entry_t(scoreboard_entry_t)) dut (
    .clk_i, .rst_ni, .halt_i, .flush_dcache_i(1'b0), .flush_i(1'b0),
    .exception_o(), .dirty_fp_state_o(), .single_step_i(1'b0), .step_hart_i('0),
    .commit_instr_i(entries_i), .commit_drop_i(drop_i), .commit_replay_i(replay_i),
    .commit_ack_o(ack_o), .commit_macro_ack_o(), .waddr_o(addr_o), .wdata_o(data_o),
    .we_gpr_o(gpr_o), .whart_o(), .we_fpr_o(fpr_o), .amo_resp_i(amo_i), .pc_o(),
    .csr_op_o(), .csr_wdata_o(), .csr_rdata_i('0), .csr_write_fflags_o(),
    .csr_exception_i('0), .commit_lsu_o(), .commit_lsu_ready_i(1'b1), .commit_tran_id_o(),
    .amo_valid_commit_o(), .no_st_pending_i(1'b1), .commit_csr_o(), .fence_i_o(), .fence_o(),
    .flush_commit_o(), .replay_o(), .sfence_vma_o(), .hfence_vvma_o(), .hfence_gvma_o(),
    .shared_tlb_flush_busy_i(1'b0), .break_from_trigger_i(1'b0)
  );
endmodule
