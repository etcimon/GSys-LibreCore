// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// g6lc_cluster PerCoreBoot: core 0 ROM 0x10000, core 1 firmware RAM
// 0x90000000, one shared mem port. L2/L3 off. Not testharness, not OpenSBI,
// not TGSI, not FPGA.

`timescale 1ns/1ps
`include "rvfi_types.svh"

package g6lc_cluster_fetch_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic config_pkg::cva6_cfg_t cluster_cfg();
    config_pkg::cva6_cfg_t c;
    c = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
    c.L2En = 1'b0;
    c.L3En = 1'b0;
    c.ServerPrefetchEn = 1'b0;
    return c;
  endfunction
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

module g6lc_apu_fetch_split
  import axi_pkg::*;
#(
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  axi_req_t mem_req_i,
  output axi_rsp_t mem_rsp_o,
  output axi_req_t ram_req_o,
  input  axi_rsp_t ram_rsp_i,
  output axi_req_t rom_req_o,
  input  axi_rsp_t rom_rsp_i
);
  function automatic logic in_ram(input logic [63:0] a);
    return a[31:16] == 16'h9000;
  endfunction
  function automatic logic in_rom(input logic [63:0] a);
    return a[31:16] == 16'h0001;
  endfunction

  logic r_busy_q, w_busy_q;
  logic ram_r_q, ram_w_q;

  wire ram_ar = in_ram(mem_req_i.ar.addr);
  wire rom_ar = in_rom(mem_req_i.ar.addr);
  wire ram_aw = in_ram(mem_req_i.aw.addr);
  wire rom_aw = in_rom(mem_req_i.aw.addr);

  always_comb begin
    ram_req_o = mem_req_i;
    rom_req_o = mem_req_i;
    ram_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q && ram_ar;
    rom_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q && rom_ar;
    ram_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q && ram_aw;
    rom_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q && rom_aw;
    ram_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && ram_w_q) || (!w_busy_q && mem_req_i.aw_valid && ram_aw));
    rom_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && !ram_w_q) || (!w_busy_q && mem_req_i.aw_valid && rom_aw));
    ram_req_o.r_ready = mem_req_i.r_ready && r_busy_q && ram_r_q;
    rom_req_o.r_ready = mem_req_i.r_ready && r_busy_q && !ram_r_q;
    ram_req_o.b_ready = mem_req_i.b_ready && w_busy_q && ram_w_q;
    rom_req_o.b_ready = mem_req_i.b_ready && w_busy_q && !ram_w_q;

    mem_rsp_o = r_busy_q && ram_r_q ? ram_rsp_i :
                r_busy_q && !ram_r_q ? rom_rsp_i :
                w_busy_q && ram_w_q ? ram_rsp_i : rom_rsp_i;
    mem_rsp_o.ar_ready = !r_busy_q && (ram_ar ? ram_rsp_i.ar_ready :
                                       rom_ar ? rom_rsp_i.ar_ready : 1'b0);
    mem_rsp_o.aw_ready = !w_busy_q && (ram_aw ? ram_rsp_i.aw_ready :
                                       rom_aw ? rom_rsp_i.aw_ready : 1'b0);
    mem_rsp_o.w_ready = w_busy_q && (ram_w_q ? ram_rsp_i.w_ready :
                                     rom_rsp_i.w_ready);
    if (r_busy_q) begin
      mem_rsp_o.r_valid = ram_r_q ? ram_rsp_i.r_valid : rom_rsp_i.r_valid;
      mem_rsp_o.r = ram_r_q ? ram_rsp_i.r : rom_rsp_i.r;
    end else begin
      mem_rsp_o.r_valid = 1'b0;
    end
    if (w_busy_q) begin
      mem_rsp_o.b_valid = ram_w_q ? ram_rsp_i.b_valid : rom_rsp_i.b_valid;
      mem_rsp_o.b = ram_w_q ? ram_rsp_i.b : rom_rsp_i.b;
    end else
      mem_rsp_o.b_valid = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_busy_q <= 1'b0;
      w_busy_q <= 1'b0;
      ram_r_q <= 1'b0;
      ram_w_q <= 1'b0;
    end else begin
      if (!r_busy_q && mem_req_i.ar_valid && mem_rsp_o.ar_ready) begin
        r_busy_q <= 1'b1;
        ram_r_q <= ram_ar;
      end else if (r_busy_q && mem_rsp_o.r_valid && mem_req_i.r_ready &&
                   mem_rsp_o.r.last)
        r_busy_q <= 1'b0;
      if (!w_busy_q && mem_req_i.aw_valid && mem_rsp_o.aw_ready) begin
        w_busy_q <= 1'b1;
        ram_w_q <= ram_aw;
      end else if (w_busy_q && mem_rsp_o.b_valid && mem_req_i.b_ready)
        w_busy_q <= 1'b0;
    end
  end
endmodule

module tb_g6lc_apu_cluster_fetch;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_cluster_fetch_test_pkg::*;
  import axi_pkg::*;
  localparam config_pkg::cva6_cfg_t CoreCfg = cluster_cfg();
  typedef `RVFI_PROBES_INSTR_T(CoreCfg) rvfi_instr_t;
  typedef `RVFI_PROBES_CSR_T(CoreCfg) rvfi_csr_t;
  typedef struct packed {
    rvfi_csr_t csr;
    rvfi_instr_t instr;
  } rvfi_probes_t;

  logic clk = 0, rst_ni = 0;
  logic [1:0][CoreCfg.VLEN-1:0] boot;
  ariane_axi::req_t mem_req, ram_req, rom_req;
  ariane_axi::resp_t mem_rsp, ram_rsp, rom_rsp;
  rvfi_probes_t rvfi0, rvfi1;
  logic [1:0] saw_ar, saw_commit;
  int errors = 0, checks = 0, cycles = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  assign boot[0] = CoreCfg.VLEN'(64'h1_0000);
  assign boot[1] = CoreCfg.VLEN'(64'h9000_0000);

  g6lc_cluster #(
    .CVA6Cfg(CoreCfg),
    .NR_CORES(2),
    .L2_ENABLE(1'b0),
    .IDENTITY_FAST(1'b1),
    .INCLUSIVE_L3(1'b0),
    .PerCoreBoot(1'b1),
    .AXI_ADDR_WIDTH(ariane_axi::AddrWidth),
    .AXI_DATA_WIDTH(ariane_axi::DataWidth),
    .AXI_ID_WIDTH(ariane_axi::IdWidth),
    .AXI_USER_WIDTH(ariane_axi::UserWidth),
    .axi_req_t(ariane_axi::req_t),
    .axi_resp_t(ariane_axi::resp_t),
    .rvfi_probes_t(rvfi_probes_t)
  ) i_cluster (
    .clk_i(clk),
    .rst_ni,
    .boot_addr_i(boot[0]),
    .boot_addr_core_i(boot),
    .irq_i('0),
    .ipi_i('0),
    .time_irq_i('0),
    .rtc_time_i('0),
    .debug_req_i('0),
    .mem_req_o(mem_req),
    .mem_resp_i(mem_rsp),
    .rvfi_probes_o(rvfi0),
    .l2_miss_o(),
    .l3_hit_o(),
    .l3_miss_o(),
    .pf_issue_o(),
    .pf_train_o(),
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

  assign rvfi1 = i_cluster.gen_core[1].i_ariane.rvfi_probes_o;

  g6lc_apu_fetch_split #(
    .axi_req_t(ariane_axi::req_t),
    .axi_rsp_t(ariane_axi::resp_t)
  ) i_split (
    .clk_i(clk),
    .rst_ni,
    .mem_req_i(mem_req),
    .mem_rsp_o(mem_rsp),
    .ram_req_o(ram_req),
    .ram_rsp_i(ram_rsp),
    .rom_req_o(rom_req),
    .rom_rsp_i(rom_rsp)
  );

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
    .slv_req_i(rom_req),
    .slv_rsp_o(rom_rsp),
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
    .slv_req_i(ram_req),
    .slv_rsp_o(ram_rsp),
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
    #8000000;
    $fatal(1, "cluster fetch timeout ar=%b commit=%b cycles=%0d",
           saw_ar, saw_commit, cycles);
  end

  always @(posedge clk) begin
    if (rst_ni && mem_req.ar_valid && mem_rsp.ar_ready &&
        mem_req.ar.addr[31:16] == 16'h1)
      saw_ar[0] <= 1'b1;
    if (rst_ni && mem_req.ar_valid && mem_rsp.ar_ready &&
        mem_req.ar.addr[31:16] == 16'h9000 &&
        mem_req.ar.size == 3'd3 && mem_req.ar.len == 8'd1)
      saw_ar[1] <= 1'b1;
    if (rst_ni && rvfi0.instr.commit_instr_valid[0] &&
        rvfi0.instr.commit_ack[0] && !rvfi0.instr.commit_drop[0] &&
        rvfi0.instr.commit_instr_pc[0] == CoreCfg.VLEN'(64'h1_0000))
      saw_commit[0] <= 1'b1;
    if (rst_ni && rvfi1.instr.commit_instr_valid[0] &&
        rvfi1.instr.commit_ack[0] && !rvfi1.instr.commit_drop[0] &&
        rvfi1.instr.commit_instr_pc[0] == CoreCfg.VLEN'(64'h9000_0000))
      saw_commit[1] <= 1'b1;
  end

  initial begin
    saw_ar = '0;
    saw_commit = '0;
    repeat (8) @(negedge clk);
    rst_ni = 1;
    while (saw_commit != 2'b11) @(posedge clk);
    @(posedge clk);
    check("shared ROM AR", saw_ar[0]);
    check("shared firmware I$ fill", saw_ar[1]);
    check("core0 committed ROM", saw_commit[0]);
    check("core1 committed firmware RAM", saw_commit[1]);
    if (errors != 0) $fatal(1, "APU cluster fetch errors=%0d", errors);
    $display("PASS tb_g6lc_apu_cluster_fetch checks=%0d cycles=%0d errors=0",
             checks, cycles);
    $finish;
  end
endmodule
