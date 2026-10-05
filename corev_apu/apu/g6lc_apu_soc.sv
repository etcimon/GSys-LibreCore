// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// SoC attach box: trusted hart grant plus g6lc_apu_sys. Default-off.
// Guest virtio IRQ is PLIC source ApuCfg.IrqSource. Control authorization
// never inspects PROT. Testharness-shaped PLIC splice and xbar windows
// live in g6lc_apu_attach; this module is not on the production xbar.

// Interplay: ApuSoc --> TrustedGrant --> ApuSys. No g6lc_apu_vgpu_* child. See AGENTS-impl-interplays.md.
module g6lc_apu_soc
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter config_pkg::cva6_cfg_t CoreCfg = config_pkg::cva6_cfg_t'(0),
  parameter int unsigned HartIdWidth = 32,
  parameter type axi_req_t = apu_axi_req_t,
  parameter type axi_rsp_t = apu_axi_resp_t,
  parameter type dma_req_t = apu_dma_axi_req_t,
  parameter type dma_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  axi_req_t guest_req_i,
  output axi_rsp_t guest_rsp_o,
  input  axi_req_t control_req_i,
  output axi_rsp_t control_rsp_o,
  input  logic [HartIdWidth-1:0] control_aw_hart_i,
  input  logic [HartIdWidth-1:0] control_ar_hart_i,
  output logic guest_irq_o,
  output logic control_irq_o,
  output logic plic_irq_o,
  output logic [31:0] plic_source_o,
  output apu_vq_state_t vq_state_o [APU_NUM_QUEUES],
  output logic [APU_NUM_QUEUES-1:0] queue_enable_o,
  output logic backend_reset_req_o,
  output logic [APU_NUM_QUEUES-1:0] backend_queue_stop_req_o,
  input  logic backend_reset_done_i,
  input  logic [APU_NUM_QUEUES-1:0] backend_idle_i,
  input  logic used_valid_i,
  input  logic [31:0] used_qid_i,
  input  logic [31:0] used_context_i,
  input  logic [63:0] used_fence_i,
  input  logic [31:0] used_len_i,
  output logic used_ready_o,
  input  logic cfg_display_event_i,
  output logic bus_fault_o,
  output dma_req_t dma_req_o,
  input  dma_rsp_t dma_rsp_i,
  input  logic guest_hold_i,
  input  logic [31:0] guest_epoch_i,
  input  logic ctrl_hold_i,
  input  logic [31:0] ctrl_epoch_i,
  output logic [31:0] epoch_o
);
  logic aw_auth, ar_auth, fw_irq;

  g6lc_apu_grant #(.ApuCfg(ApuCfg), .HartIdWidth(HartIdWidth)) i_grant (
    .clk_i, .rst_ni, .testmode_i,
    .aw_hart_i(control_aw_hart_i), .ar_hart_i(control_ar_hart_i),
    .aw_addr_i(control_req_i.aw.addr), .ar_addr_i(control_req_i.ar.addr),
    .guest_irq_i(guest_irq_o), .control_irq_i(control_irq_o),
    .control_aw_authorized_o(aw_auth), .control_ar_authorized_o(ar_auth),
    .plic_irq_o, .plic_source_o, .fw_irq_o(fw_irq)
  );

  g6lc_apu_sys #(
    .ApuCfg(ApuCfg), .CoreCfg(CoreCfg),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .dma_req_t(dma_req_t), .dma_rsp_t(dma_rsp_t)
  ) i_sys (
    .clk_i, .rst_ni, .testmode_i,
    .guest_req_i, .guest_rsp_o, .control_req_i, .control_rsp_o,
    .control_aw_authorized_i(aw_auth), .control_ar_authorized_i(ar_auth),
    .guest_irq_o, .control_irq_o, .vq_state_o, .queue_enable_o,
    .backend_reset_req_o, .backend_queue_stop_req_o,
    .backend_reset_done_i, .backend_idle_i,
    .used_valid_i, .used_qid_i, .used_context_i, .used_fence_i, .used_len_i,
    .used_ready_o, .cfg_display_event_i, .bus_fault_o,
    .dma_req_o, .dma_rsp_i,
    .guest_hold_i, .guest_epoch_i, .ctrl_hold_i, .ctrl_epoch_i, .epoch_o
  );

  logic unused_fw;
  assign unused_fw = fw_irq;
endmodule
