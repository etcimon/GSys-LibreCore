// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// One CVA6 (hart_id=1) fetches preloaded apu_fw.hex from g6lc_apu_fwram.
// I$ fill is size=3 len=1 INCR. Not testharness PerCoreBoot, not OpenSBI,
// not TGSI, not dual-core.

`timescale 1ns/1ps
`include "rvfi_types.svh"

package g6lc_cva6_fetch_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t fetch_cfg();
    apu_cfg_t cfg = ApuHarness;
    cfg.FirmwareRamBytes = 64'h1000;
    return cfg;
  endfunction
endpackage

module tb_g6lc_apu_cva6_fetch;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_cva6_fetch_test_pkg::*;
  import axi_pkg::*;
  localparam config_pkg::cva6_cfg_t CoreCfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  typedef `RVFI_PROBES_INSTR_T(CoreCfg) rvfi_instr_t;
  typedef `RVFI_PROBES_CSR_T(CoreCfg) rvfi_csr_t;
  typedef struct packed {
    rvfi_csr_t csr;
    rvfi_instr_t instr;
  } rvfi_probes_t;

  logic clk = 0, rst_ni = 0;
  ariane_axi::req_t core_req;
  ariane_axi::resp_t core_rsp;
  rvfi_probes_t rvfi;
  axi_pkg::xbar_rule_64_t ram_rule;
  logic [63:0] ram_base, ram_end;
  logic saw_ar = 0, saw_commit = 0;
  int errors = 0, checks = 0, cycles = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  ariane #(
    .CVA6Cfg(CoreCfg),
    .rvfi_probes_t(rvfi_probes_t),
    .noc_req_t(ariane_axi::req_t),
    .noc_resp_t(ariane_axi::resp_t)
  ) i_core (
    .clk_i(clk),
    .rst_ni,
    .boot_addr_i(CoreCfg.VLEN'(64'h9000_0000)),
    .hart_id_i(CoreCfg.XLEN'(1)),
    .irq_i('0),
    .ipi_i('0),
    .time_irq_i('0),
    .rtc_time_i('0),
    .debug_req_i(1'b0),
    .rvfi_probes_o(rvfi),
    .noc_req_o(core_req),
    .noc_resp_i(core_rsp),
    .l1_inval_addr_i('0),
    .l1_inval_valid_i(1'b0),
    .l1_inval_ready_o(),
    .l2_miss_i(1'b0),
    .l3_hit_i(1'b0),
    .l3_miss_i(1'b0),
    .pf_issue_i(1'b0),
    .pf_train_i(1'b0),
    .ai_sb_enq_valid_o(),
    .ai_sb_qid_o(),
    .ai_sb_ticket_o(),
    .ai_sb_desc_ptr_o(),
    .ai_isl_has_completion_i(1'b0),
    .ai_isl_last_ticket_i('0),
    .ai_isl_last_status_i('0)
  );

  g6lc_apu_fwram #(
    .ApuCfg(fetch_cfg()),
    .RamIdx(12),
    .HexFile("apu_fw.hex"),
    .axi4_req_t(ariane_axi::req_t),
    .axi4_rsp_t(ariane_axi::resp_t)
  ) i_ram (
    .clk_i(clk),
    .rst_ni,
    .testmode_i(1'b1),
    .aw_hart_i(32'd1),
    .ar_hart_i(32'd1),
    .slv_req_i(core_req),
    .slv_rsp_o(core_rsp),
    .ram_rule_o(ram_rule),
    .ram_base_o(ram_base),
    .ram_end_o(ram_end)
  );

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s cycle=%0d", name, cycles);
    end
  endtask

  initial begin
    #2000000;
    $fatal(1, "cva6 fetch timeout ar=%0d commit=%0d cycles=%0d",
           saw_ar, saw_commit, cycles);
  end

  always @(posedge clk) begin
    if (rst_ni && core_req.ar_valid && core_rsp.ar_ready &&
        core_req.ar.addr[63:12] == 52'h90000 && !saw_ar) begin
      saw_ar <= 1'b1;
      check("I$ AR size-3", core_req.ar.size == 3'd3);
      check("I$ AR INCR", core_req.ar.burst == BURST_INCR);
      check("I$ AR len-1", core_req.ar.len == 8'd1);
    end
    if (rst_ni && rvfi.instr.commit_instr_valid[0] &&
        rvfi.instr.commit_ack[0] && !rvfi.instr.commit_drop[0] &&
        rvfi.instr.commit_instr_pc[0] == CoreCfg.VLEN'(64'h9000_0000))
      saw_commit <= 1'b1;
  end

  initial begin
    repeat (8) @(negedge clk);
    rst_ni = 1;
    while (!saw_commit) @(posedge clk);
    @(posedge clk);
    check("I$ fill issued", saw_ar);
    check("CVA6 committed boot PC", saw_commit);
    if (errors != 0) $fatal(1, "APU cva6 fetch errors=%0d", errors);
    $display("PASS tb_g6lc_apu_cva6_fetch checks=%0d cycles=%0d errors=0",
             checks, cycles);
    $finish;
  end
endmodule
