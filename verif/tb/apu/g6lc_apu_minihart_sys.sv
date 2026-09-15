// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Shared mini-hart + fwram + firmware-mailbox DUT. Stimulus stays in the TBs.

`timescale 1ns/1ps

package g6lc_hart_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t fw_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.ExecEn = enabled;
    cfg.ExecQuadThreads = 4;
    cfg.ExecRegs = 8;
    cfg.ExecMemWords = 64;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t fw_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
endpackage

module g6lc_apu_hart_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1'b1) (
  input logic clk_i, rst_ni, testmode_i,
  input apu_axi_req_t guest_req_i, control_req_i,
  output apu_axi_resp_t guest_rsp_o, control_rsp_o,
  input logic control_aw_authorized_i, control_ar_authorized_i,
  output logic guest_irq_o, control_irq_o,
  output apu_vq_state_t vq_state_o [APU_NUM_QUEUES],
  output logic [APU_NUM_QUEUES-1:0] queue_enable_o,
  output logic backend_reset_req_o,
  output logic [APU_NUM_QUEUES-1:0] backend_queue_stop_req_o,
  input logic backend_reset_done_i,
  input logic [APU_NUM_QUEUES-1:0] backend_idle_i,
  input logic used_valid_i,
  input logic [31:0] used_qid_i, used_context_i, used_len_i,
  input logic [63:0] used_fence_i,
  output logic used_ready_o,
  input logic cfg_display_event_i,
  output logic bus_fault_o,
  output apu_dma_axi_req_t dma_req_o,
  input apu_dma_axi_resp_t dma_rsp_i
);
  g6lc_apu_fw #(
    .ApuCfg(g6lc_hart_test_pkg::fw_cfg(Enable)),
    .CoreCfg(g6lc_hart_test_pkg::fw_core())
  ) i_dut (.*);
endmodule

module g6lc_apu_minihart_sys
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic hart_en_i,
  input  apu_axi_req_t tb_ctrl_req_i,
  output apu_axi_resp_t tb_ctrl_rsp_o,
  input  apu_dma_axi_req_t tb_ram_req_i,
  output apu_dma_axi_resp_t tb_ram_rsp_o,
  output logic halt_o,
  output logic [31:0] cookie_o,
  output logic [63:0] pc_o,
  output apu_dma_axi_req_t dma_req_o,
  output axi_pkg::xbar_rule_64_t ram_rule_o
);
  apu_axi_req_t hart_req, guest_req, ctrl_req;
  apu_axi_resp_t guest_rsp, ctrl_rsp, ram_lite_rsp;
  apu_dma_axi_req_t ram_ad_req, fwram_req;
  apu_dma_axi_resp_t fwram_rsp, dma_rsp;
  logic [1:0] queue_enable, stop_req;
  logic guest_irq, control_irq, reset_req, bus_fault, used_ready;
  apu_vq_state_t vq [2];
  logic [63:0] sel_q;

  function automatic logic in_ram(input logic [63:0] a);
    return a >= 64'h9000_0000 && a < 64'h9004_0000;
  endfunction
  wire [63:0] sel_addr = hart_req.aw_valid ? hart_req.aw.addr :
                         hart_req.ar_valid ? hart_req.ar.addr : sel_q;
  wire use_ram = hart_en_i && in_ram(sel_addr);

  g6lc_apu_hart_fixture i_dut (
    .clk_i, .rst_ni, .testmode_i(1'b1),
    .guest_req_i(guest_req), .guest_rsp_o(guest_rsp),
    .control_req_i(ctrl_req), .control_rsp_o(ctrl_rsp),
    .control_aw_authorized_i(1'b1), .control_ar_authorized_i(1'b1),
    .guest_irq_o(guest_irq), .control_irq_o(control_irq),
    .vq_state_o(vq), .queue_enable_o(queue_enable),
    .backend_reset_req_o(reset_req), .backend_queue_stop_req_o(stop_req),
    .backend_reset_done_i(1'b1), .backend_idle_i(2'b11),
    .used_valid_i(1'b0), .used_qid_i('0), .used_context_i('0),
    .used_len_i('0), .used_fence_i('0), .used_ready_o(used_ready),
    .cfg_display_event_i(1'b0), .bus_fault_o(bus_fault),
    .dma_req_o(dma_req_o), .dma_rsp_i(dma_rsp)
  );

  g6lc_apu_fwram #(
    .ApuCfg(g6lc_hart_test_pkg::fw_cfg(1'b1)),
    .RamIdx(12)
  ) i_ram (
    .clk_i, .rst_ni, .testmode_i(1'b1),
    .slv_req_i(fwram_req), .slv_rsp_o(fwram_rsp),
    .ram_rule_o(ram_rule_o), .ram_base_o(), .ram_end_o()
  );

  g6lc_apu_lite_to_axi4 i_ad (
    .clk_i, .rst_ni,
    .lite_req_i(use_ram ? hart_req : '0),
    .lite_rsp_o(ram_lite_rsp),
    .axi4_req_o(ram_ad_req),
    .axi4_rsp_i(fwram_rsp)
  );

  g6lc_apu_mini_hart i_hart (
    .clk_i, .rst_ni, .enable_i(hart_en_i),
    .axi_req_o(hart_req),
    .axi_rsp_i(use_ram ? ram_lite_rsp : ctrl_rsp),
    .cookie_o(cookie_o), .halt_o(halt_o), .pc_o(pc_o)
  );

  assign guest_req = '0;
  assign dma_rsp = '0;
  assign ctrl_req = hart_en_i ? (use_ram ? '0 : hart_req) : tb_ctrl_req_i;
  assign fwram_req = hart_en_i ? ram_ad_req : tb_ram_req_i;
  assign tb_ctrl_rsp_o = ctrl_rsp;
  assign tb_ram_rsp_o = fwram_rsp;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sel_q <= '0;
    else if (hart_req.aw_valid) sel_q <= hart_req.aw.addr;
    else if (hart_req.ar_valid) sel_q <= hart_req.ar.addr;
  end
endmodule
