// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness xbar-port glue: exported guest/control addr_map rules plus
// g6lc_apu_th. Firmware RAM and the DRAM hole live in g6lc_apu_th_load.
// DMA AXI master is exported (idle when DmaReadEn=0). Default-off. Not on
// the production testharness flist until +define+G6LC_APU. FeatureVirgl
// stays illegal.

// Interplay: TestharnessLoad --> ApuXbar --> TestharnessAttach. Opt-in G6LC_APU. See AGENTS-impl-interplays.md.
module g6lc_apu_xbar
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter config_pkg::cva6_cfg_t CoreCfg = config_pkg::cva6_cfg_t'(0),
  parameter int unsigned GuestIdx = 10,
  parameter int unsigned CtrlIdx = 11,
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
  output logic plic_irq_o,
  output logic [31:0] plic_source_o,
  output axi_pkg::xbar_rule_64_t guest_rule_o,
  output axi_pkg::xbar_rule_64_t control_rule_o,
  output logic [63:0] guest_base_o,
  output logic [63:0] guest_end_o,
  output logic [63:0] control_base_o,
  output logic [63:0] control_end_o,
  // Reset and queue-stop stay asserted until the platform reports the
  // backend idle and, for device reset, teardown done. They are not tied off.
  output logic backend_reset_req_o,
  output logic [APU_NUM_QUEUES-1:0] backend_queue_stop_req_o,
  input  logic backend_reset_done_i,
  input  logic [APU_NUM_QUEUES-1:0] backend_idle_i,
  output dma_req_t dma_req_o,
  input  dma_rsp_t dma_rsp_i
);
  `ifndef SYNTHESIS
  initial begin
    assert (ApuCfg.MmioBase == APU_MMIO_BASE && ApuCfg.ControlBase == APU_CONTROL_BASE)
      else $fatal(1, "APU xbar: unexpected window");
    assert (GuestIdx != CtrlIdx)
      else $fatal(1, "APU xbar: guest and control idx collide");
  end
  `endif

  assign guest_rule_o = '{
      idx: GuestIdx,
      start_addr: ApuCfg.MmioBase,
      end_addr: ApuCfg.MmioBase + ApuCfg.MmioLength
  };
  assign control_rule_o = '{
      idx: CtrlIdx,
      start_addr: ApuCfg.ControlBase,
      end_addr: ApuCfg.ControlBase + ApuCfg.ControlLength
  };

  logic unused_girq, unused_cirq, unused_fault, unused_ready;
  logic [APU_NUM_QUEUES-1:0] unused_qe;
  apu_vq_state_t unused_vq [APU_NUM_QUEUES];

  g6lc_apu_th #(
    .ApuCfg(ApuCfg), .CoreCfg(CoreCfg), .HartIdWidth(HartIdWidth),
    .NumSources(NumSources), .axi4_req_t(axi4_req_t), .axi4_rsp_t(axi4_rsp_t),
    .dma_req_t(dma_req_t), .dma_rsp_t(dma_rsp_t)
  ) i_th (
    .clk_i, .rst_ni, .testmode_i,
    .guest_req_i, .guest_rsp_o, .control_req_i, .control_rsp_o,
    .control_aw_hart_i, .control_ar_hart_i,
    .irq_sources_i, .irq_sources_o,
    .guest_irq_o(unused_girq), .control_irq_o(unused_cirq),
    .plic_irq_o, .plic_source_o,
    .guest_base_o, .guest_end_o, .control_base_o, .control_end_o,
    .vq_state_o(unused_vq), .queue_enable_o(unused_qe),
    .backend_reset_req_o, .backend_queue_stop_req_o,
    .backend_reset_done_i, .backend_idle_i,
    .used_valid_i(1'b0), .used_qid_i('0), .used_context_i('0),
    .used_fence_i('0), .used_len_i('0), .used_ready_o(unused_ready),
    .cfg_display_event_i(1'b0), .bus_fault_o(unused_fault),
    .dma_req_o, .dma_rsp_i
  );

  logic unused;
  assign unused = unused_girq | unused_cirq | unused_fault |
                  unused_ready | |unused_qe | testmode_i;
endmodule
