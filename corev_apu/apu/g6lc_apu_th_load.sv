// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness load compositor: guest/control xbar + firmware RAM + DRAM-hole
// rules + per-core boot PCs. Does not instantiate a CVA6. FeatureVirgl stays
// illegal. FPGA/Altera maps do not use this module.

module g6lc_apu_th_load
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter config_pkg::cva6_cfg_t CoreCfg = config_pkg::cva6_cfg_t'(0),
  parameter logic [63:0] AppBoot = 64'h0001_0000,
  parameter logic [63:0] DramBase = 64'h8000_0000,
  parameter logic [63:0] DramBytes = 64'h4000_0000,
  parameter int unsigned GuestIdx = 10,
  parameter int unsigned CtrlIdx = 11,
  parameter int unsigned RamIdx = 12,
  parameter int unsigned DramIdx = 0,
  parameter int unsigned NumCores = 2,
  parameter int unsigned Vlen = 39,
  parameter HexFile = "none",
  parameter int unsigned HartIdWidth = 32,
  parameter int unsigned NumSources = 30,
  parameter type axi4_req_t = apu_dma_axi_req_t,
  parameter type axi4_rsp_t = apu_dma_axi_resp_t,
  parameter type dma_req_t = apu_dma_axi_req_t,
  parameter type dma_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  axi4_req_t guest_req_i,
  output axi4_rsp_t guest_rsp_o,
  input  axi4_req_t control_req_i,
  output axi4_rsp_t control_rsp_o,
  input  axi4_req_t ram_req_i,
  output axi4_rsp_t ram_rsp_o,
  input  logic [HartIdWidth-1:0] control_aw_hart_i,
  input  logic [HartIdWidth-1:0] control_ar_hart_i,
  input  logic [NumSources-1:0] irq_sources_i,
  output logic [NumSources-1:0] irq_sources_o,
  output logic plic_irq_o,
  output logic fw_ready_o,
  output logic [NumCores-1:0][Vlen-1:0] boot_addr_core_o,
  output axi_pkg::xbar_rule_64_t guest_rule_o,
  output axi_pkg::xbar_rule_64_t control_rule_o,
  output axi_pkg::xbar_rule_64_t ram_rule_o,
  output axi_pkg::xbar_rule_64_t dram_lo_rule_o,
  output axi_pkg::xbar_rule_64_t dram_hi_rule_o,
  output dma_req_t dma_req_o,
  input  dma_rsp_t dma_rsp_i
);
  `ifndef SYNTHESIS
  initial begin
    if (ApuCfg.Enable) begin
      assert (apu_soc_legal(ApuCfg, CoreCfg))
        else $fatal(1, "APU th_load: need 2 cores and NrHarts=1");
      assert (apu_dram_hole_legal(ApuCfg.FirmwareRamBase, ApuCfg.FirmwareRamBytes,
                                  DramBase, DramBytes))
        else $fatal(1, "APU th_load: firmware RAM is not a DRAM hole");
      assert (apu_boot_split_legal(ApuCfg, CoreCfg, AppBoot))
        else $fatal(1, "APU th_load: firmware hart boot is not split from ROM");
      assert (GuestIdx != CtrlIdx && CtrlIdx != RamIdx && GuestIdx != RamIdx)
        else $fatal(1, "APU th_load: idx collide");
    end
  end
  `endif

  assign dram_lo_rule_o = '{
      idx: DramIdx,
      start_addr: DramBase,
      end_addr: apu_dram_lo_end(ApuCfg.FirmwareRamBase)
  };
  assign dram_hi_rule_o = '{
      idx: DramIdx,
      start_addr: apu_dram_hi_start(ApuCfg.FirmwareRamBase, ApuCfg.FirmwareRamBytes),
      end_addr: DramBase + DramBytes
  };

  for (genvar c = 0; c < NumCores; c++) begin : gen_boot
    logic [63:0] boot_full;
    assign boot_full = apu_core_boot_addr(ApuCfg, c, AppBoot);
    assign boot_addr_core_o[c] = boot_full[Vlen-1:0];
  end

`ifdef SYNTHESIS
  assign fw_ready_o = 1'b1;
`else
  logic fw_ready_q;
  assign fw_ready_o = fw_ready_q;
  initial begin
    fw_ready_q = 1'b0;
    // One time unit, not #0: Verilator 5.008 rejects zero-delay Inactive
    // scheduling. Hex $readmemh initials complete at time 0 first.
    #1;
    fw_ready_q = 1'b1;
  end
`endif

  logic [31:0] unused_src;
  g6lc_apu_xbar #(
    .ApuCfg(ApuCfg), .CoreCfg(CoreCfg), .GuestIdx(GuestIdx), .CtrlIdx(CtrlIdx),
    .HartIdWidth(HartIdWidth), .NumSources(NumSources),
    .axi4_req_t(axi4_req_t), .axi4_rsp_t(axi4_rsp_t),
    .dma_req_t(dma_req_t), .dma_rsp_t(dma_rsp_t)
  ) i_xbar (
    .clk_i, .rst_ni, .testmode_i,
    .guest_req_i, .guest_rsp_o, .control_req_i, .control_rsp_o,
    .control_aw_hart_i, .control_ar_hart_i,
    .irq_sources_i, .irq_sources_o,
    .plic_irq_o, .plic_source_o(unused_src),
    .guest_rule_o, .control_rule_o,
    .guest_base_o(), .guest_end_o(), .control_base_o(), .control_end_o(),
    .dma_req_o, .dma_rsp_i
  );

  g6lc_apu_fwram #(
    .ApuCfg(ApuCfg), .RamIdx(RamIdx), .HexFile(HexFile),
    .axi4_req_t(axi4_req_t), .axi4_rsp_t(axi4_rsp_t)
  ) i_fwram (
    .clk_i, .rst_ni, .testmode_i,
    .slv_req_i(ram_req_i), .slv_rsp_o(ram_rsp_o),
    .ram_rule_o, .ram_base_o(), .ram_end_o()
  );
endmodule
