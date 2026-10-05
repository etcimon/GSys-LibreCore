// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness-shaped APU attach: g6lc_apu_soc plus PLIC source splice and
// xbar window exports. Guest virtio IRQ occupies irq_sources[IrqSource-1]
// (PLIC source 9 → bit 8). Source 8 / irq_sources[7] stays the AI island.
// Windows sit after GPIO/AI at 0x40001000 / 0x40002000 and are never an
// alias of that 4 KiB aperture. Default-off. Not instantiated on the
// production testharness xbar; FeatureVirgl stays illegal.

// Interplay: TestharnessAttach --> ApuSoc; PLIC 9 --? ai_island PLIC 8. See AGENTS-impl-interplays.md.
module g6lc_apu_attach
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter config_pkg::cva6_cfg_t CoreCfg = config_pkg::cva6_cfg_t'(0),
  parameter int unsigned HartIdWidth = 32,
  parameter int unsigned NumSources = 30,
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
  input  dma_rsp_t dma_rsp_i,
  input  logic guest_hold_i,
  input  logic [31:0] guest_epoch_i,
  input  logic ctrl_hold_i,
  input  logic [31:0] ctrl_epoch_i,
  output logic [31:0] epoch_o
);
  localparam int unsigned PlicBit = ApuCfg.IrqSource - 1;
  localparam logic [63:0] GpioBase = 64'h0000_0000_4000_0000;
  localparam logic [63:0] GpioLen  = 64'h1000;

  `ifndef SYNTHESIS
  initial begin
    assert (apu_soc_legal(ApuCfg, CoreCfg))
      else $fatal(1, "APU attach: illegal SoC configuration");
    assert (ApuCfg.IrqSource != 8)
      else $fatal(1, "APU attach: PLIC source 8 is the AI island");
    assert (ApuCfg.IrqSource != 0 && ApuCfg.IrqSource <= NumSources)
      else $fatal(1, "APU attach: PLIC source out of range");
    assert (!apu_ranges_overlap(ApuCfg.MmioBase, ApuCfg.MmioLength, GpioBase, GpioLen))
      else $fatal(1, "APU attach: guest window aliases GPIO/AI");
    assert (!apu_ranges_overlap(ApuCfg.ControlBase, ApuCfg.ControlLength,
                                GpioBase, GpioLen))
      else $fatal(1, "APU attach: control window aliases GPIO/AI");
  end
  `endif

  assign guest_base_o    = ApuCfg.MmioBase;
  assign guest_end_o     = ApuCfg.MmioBase + ApuCfg.MmioLength;
  assign control_base_o  = ApuCfg.ControlBase;
  assign control_end_o   = ApuCfg.ControlBase + ApuCfg.ControlLength;

  g6lc_apu_soc #(
    .ApuCfg(ApuCfg), .CoreCfg(CoreCfg), .HartIdWidth(HartIdWidth),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .dma_req_t(dma_req_t), .dma_rsp_t(dma_rsp_t)
  ) i_soc (
    .clk_i, .rst_ni, .testmode_i,
    .guest_req_i, .guest_rsp_o, .control_req_i, .control_rsp_o,
    .control_aw_hart_i, .control_ar_hart_i,
    .guest_irq_o, .control_irq_o, .plic_irq_o, .plic_source_o,
    .vq_state_o, .queue_enable_o, .backend_reset_req_o,
    .backend_queue_stop_req_o, .backend_reset_done_i, .backend_idle_i,
    .used_valid_i, .used_qid_i, .used_context_i, .used_fence_i, .used_len_i,
    .used_ready_o, .cfg_display_event_i, .bus_fault_o, .dma_req_o, .dma_rsp_i,
    .guest_hold_i, .guest_epoch_i, .ctrl_hold_i, .ctrl_epoch_i, .epoch_o
  );

  if (!ApuCfg.Enable) begin : gen_off
    assign irq_sources_o = irq_sources_i;
  end else begin : gen_on
    always_comb begin
      irq_sources_o = irq_sources_i;
      irq_sources_o[PlicBit] = plic_irq_o;
    end
  end
endmodule
