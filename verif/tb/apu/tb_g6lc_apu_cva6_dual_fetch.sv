// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Two CVA6 cores at testharness PerCoreBoot PCs: core 0 ROM 0x10000 (spin),
// core 1 firmware RAM 0x90000000 (apu_fw.hex). Not g6lc_cluster, not OpenSBI,
// not TGSI, not FPGA.

`timescale 1ns/1ps
`include "rvfi_types.svh"

package g6lc_cva6_dual_fetch_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t ram_cfg();
    apu_cfg_t cfg = ApuHarness;
    cfg.FirmwareRamBytes = 64'h1000;
    return cfg;
  endfunction
  function automatic apu_cfg_t rom_cfg();
    apu_cfg_t cfg = ApuHarness;
    cfg.FirmwareRamBase = 64'h1_0000;
    cfg.FirmwareRamBytes = 64'h1000;
    return cfg;
  endfunction
endpackage

module tb_g6lc_apu_cva6_dual_fetch;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_cva6_dual_fetch_test_pkg::*;
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
  ariane_axi::req_t [1:0] core_req;
  ariane_axi::resp_t [1:0] core_rsp;
  rvfi_probes_t [1:0] rvfi;
  logic [1:0] saw_ar, saw_commit;
  int errors = 0, checks = 0, cycles = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  for (genvar c = 0; c < 2; c++) begin : gen_core
    ariane #(
      .CVA6Cfg(CoreCfg),
      .rvfi_probes_t(rvfi_probes_t),
      .noc_req_t(ariane_axi::req_t),
      .noc_resp_t(ariane_axi::resp_t)
    ) i_core (
      .clk_i(clk),
      .rst_ni,
      .boot_addr_i(CoreCfg.VLEN'(c ? 64'h9000_0000 : 64'h1_0000)),
      .hart_id_i(CoreCfg.XLEN'(c)),
      .irq_i('0),
      .ipi_i('0),
      .time_irq_i('0),
      .rtc_time_i('0),
      .debug_req_i(1'b0),
      .rvfi_probes_o(rvfi[c]),
      .noc_req_o(core_req[c]),
      .noc_resp_i(core_rsp[c]),
      .l1_inval_addr_i('0),
      .l1_inval_valid_i(1'b0),
      .l1_inval_ready_o(),
      .l2_miss_i(1'b0),
      .l3_hit_i(1'b0),
      .l3_miss_i(1'b0),
      .pf_issue_i(1'b0),
      .pf_train_i(1'b0),
    .l2_pf_issue_i(1'b0), .l2_pf_useful_i(1'b0),
      .l2_pwhold_i(1'b0),
      .l3_pwhold_i(1'b0),
      .ai_sb_enq_valid_o(),
      .ai_sb_enq_ready_i(1'b1),
      .ai_sb_qid_o(),
      .ai_sb_ticket_o(),
      .ai_sb_desc_ptr_o(),
      .ai_isl_has_completion_i(1'b0),
      .ai_isl_retired_valid_i(1'b0),
      .ai_isl_retired_ticket_i('0),
      .ai_isl_attached_i(1'b0),
      .ai_isl_last_ticket_i('0),
      .ai_isl_last_status_i('0)
    );
  end

  g6lc_apu_fwram #(
    .ApuCfg(rom_cfg()),
    .RamIdx(2),
    .HexFile("rom_spin.hex"),
    .axi4_req_t(ariane_axi::req_t),
    .axi4_rsp_t(ariane_axi::resp_t)
  ) i_rom (
    .clk_i(clk),
    .rst_ni,
    .testmode_i(1'b1),
    .aw_hart_i(32'd1),
    .ar_hart_i(32'd1),
    .slv_req_i(core_req[0]),
    .slv_rsp_o(core_rsp[0]),
    .ram_rule_o(),
    .ram_base_o(),
    .ram_end_o()
  );

  g6lc_apu_fwram #(
    .ApuCfg(ram_cfg()),
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
    .slv_req_i(core_req[1]),
    .slv_rsp_o(core_rsp[1]),
    .ram_rule_o(),
    .ram_base_o(),
    .ram_end_o()
  );

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s cycle=%0d", name, cycles);
    end
  endtask

  initial begin
    #4000000;
    $fatal(1, "dual fetch timeout ar=%b commit=%b cycles=%0d",
           saw_ar, saw_commit, cycles);
  end

  always @(posedge clk) begin
    // Core 0 ROM may fetch as a single beat; firmware I$ is a 16-byte fill.
    if (rst_ni && core_req[0].ar_valid && core_rsp[0].ar_ready &&
        core_req[0].ar.addr[31:16] == 16'h1)
      saw_ar[0] <= 1'b1;
    if (rst_ni && core_req[1].ar_valid && core_rsp[1].ar_ready &&
        core_req[1].ar.addr[31:16] == 16'h9000 &&
        core_req[1].ar.size == 3'd3 && core_req[1].ar.len == 8'd1)
      saw_ar[1] <= 1'b1;
    if (rst_ni && rvfi[0].instr.commit_instr_valid[0] &&
        rvfi[0].instr.commit_ack[0] && !rvfi[0].instr.commit_drop[0] &&
        rvfi[0].instr.commit_instr_pc[0] == CoreCfg.VLEN'(64'h1_0000))
      saw_commit[0] <= 1'b1;
    if (rst_ni && rvfi[1].instr.commit_instr_valid[0] &&
        rvfi[1].instr.commit_ack[0] && !rvfi[1].instr.commit_drop[0] &&
        rvfi[1].instr.commit_instr_pc[0] == CoreCfg.VLEN'(64'h9000_0000))
      saw_commit[1] <= 1'b1;
  end

  initial begin
    saw_ar = '0;
    saw_commit = '0;
    repeat (8) @(negedge clk);
    rst_ni = 1;
    while (saw_commit != 2'b11) @(posedge clk);
    @(posedge clk);
    check("core0 I$ fill", saw_ar[0]);
    check("core1 I$ fill", saw_ar[1]);
    check("core0 committed ROM", saw_commit[0]);
    check("core1 committed firmware RAM", saw_commit[1]);
    if (errors != 0) $fatal(1, "APU cva6 dual fetch errors=%0d", errors);
    $display("PASS tb_g6lc_apu_cva6_dual_fetch checks=%0d cycles=%0d errors=0",
             checks, cycles);
    $finish;
  end
endmodule
