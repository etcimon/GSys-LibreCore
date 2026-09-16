// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness bus adapter: two AXI4-64 slave ports (guest + control) converted
// to AXI-Lite 32, then g6lc_apu_attach. PLIC source 9 is spliced; source 8
// stays the AI island. Default-off. Not instantiated on the production
// testharness xbar. FeatureVirgl stays illegal.

module g6lc_apu_th
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter config_pkg::cva6_cfg_t CoreCfg = config_pkg::cva6_cfg_t'(0),
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
  input  logic [HartIdWidth-1:0] control_aw_hart_i,
  input  logic [HartIdWidth-1:0] control_ar_hart_i,
  input  logic [NumSources-1:0] irq_sources_i,
  output logic [NumSources-1:0] irq_sources_o,
  output logic guest_irq_o,
  output logic control_irq_o,
  output logic plic_irq_o,
  output logic [31:0] plic_source_o,
  output logic [63:0] guest_base_o,
  output logic [63:0] guest_end_o,
  output logic [63:0] control_base_o,
  output logic [63:0] control_end_o,
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
  input  dma_rsp_t dma_rsp_i
);
  localparam bit Enable = ApuCfg.Enable;
  apu_axi_req_t guest_lite, control_lite;
  apu_axi_resp_t guest_lite_rsp, control_lite_rsp;
  logic [HartIdWidth-1:0] control_aw_hart_q, control_ar_hart_q;

  if (Enable) begin : gen_source
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        control_aw_hart_q <= '0;
        control_ar_hart_q <= '0;
      end else begin
        if (control_req_i.aw_valid && control_rsp_o.aw_ready)
          control_aw_hart_q <= control_aw_hart_i;
        if (control_req_i.ar_valid && control_rsp_o.ar_ready)
          control_ar_hart_q <= control_ar_hart_i;
      end
    end
  end else begin : gen_source_off
    assign control_aw_hart_q = '0;
    assign control_ar_hart_q = '0;
  end

  g6lc_apu_axi4_lite #(.Enable(Enable), .axi4_req_t(axi4_req_t),
                       .axi4_rsp_t(axi4_rsp_t)) i_guest (
    .clk_i, .rst_ni, .testmode_i,
    .slv_req_i(guest_req_i), .slv_rsp_o(guest_rsp_o),
    .lite_req_o(guest_lite), .lite_rsp_i(guest_lite_rsp)
  );
  g6lc_apu_axi4_lite #(.Enable(Enable), .axi4_req_t(axi4_req_t),
                       .axi4_rsp_t(axi4_rsp_t)) i_control (
    .clk_i, .rst_ni, .testmode_i,
    .slv_req_i(control_req_i), .slv_rsp_o(control_rsp_o),
    .lite_req_o(control_lite), .lite_rsp_i(control_lite_rsp)
  );
  g6lc_apu_attach #(
    .ApuCfg(ApuCfg), .CoreCfg(CoreCfg), .HartIdWidth(HartIdWidth),
    .NumSources(NumSources), .dma_req_t(dma_req_t), .dma_rsp_t(dma_rsp_t)
  ) i_attach (
    .clk_i, .rst_ni, .testmode_i,
    .guest_req_i(guest_lite), .guest_rsp_o(guest_lite_rsp),
    .control_req_i(control_lite), .control_rsp_o(control_lite_rsp),
    .control_aw_hart_i(control_aw_hart_q), .control_ar_hart_i(control_ar_hart_q),
    .irq_sources_i, .irq_sources_o,
    .guest_irq_o, .control_irq_o, .plic_irq_o, .plic_source_o,
    .guest_base_o, .guest_end_o, .control_base_o, .control_end_o,
    .vq_state_o, .queue_enable_o, .backend_reset_req_o,
    .backend_queue_stop_req_o, .backend_reset_done_i, .backend_idle_i,
    .used_valid_i, .used_qid_i, .used_context_i, .used_fence_i, .used_len_i,
    .used_ready_o, .cfg_display_event_i, .bus_fault_o, .dma_req_o, .dma_rsp_i
  );
endmodule
