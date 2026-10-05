// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Firmware mailbox bound to the native exec cluster. Transport AXI-lite plus
// EXEC_IMEM/POKE/PEEK/RUN. No DRAM DMA in this wrapper. Default-off.
// Not on the production testharness xbar. FeatureVirgl stays illegal.

// Interplay: resident image path: AxiLiteTransport --> Mailbox --> ExecBind. See AGENTS-impl-interplays.md.
module g6lc_apu_fw
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter config_pkg::cva6_cfg_t CoreCfg = config_pkg::cva6_cfg_t'(0),
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
  input  logic control_aw_authorized_i,
  input  logic control_ar_authorized_i,
  output logic guest_irq_o,
  output logic control_irq_o,
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
  localparam bit ExecEn = ApuCfg.Enable && ApuCfg.ExecEn;

  apu_reg_req_t mbox_req;
  apu_reg_rsp_t mbox_rsp;
  logic exec_idle, reset_req, lite_irq;
  logic [APU_NUM_QUEUES-1:0] stop_req;

  assign backend_reset_req_o = reset_req;
  assign backend_queue_stop_req_o = stop_req;
  assign control_irq_o = lite_irq;
  assign bus_fault_o = 1'b0;
  assign dma_req_o = '0;

  g6lc_apu_axi_lite #(
    .ApuCfg(ApuCfg), .CoreCfg(CoreCfg), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t)
  ) i_lite (
    .clk_i, .rst_ni, .testmode_i,
    .guest_req_i, .guest_rsp_o, .control_req_i, .control_rsp_o,
    .control_aw_authorized_i, .control_ar_authorized_i,
    .guest_irq_o, .control_irq_o(lite_irq), .vq_state_o, .queue_enable_o,
    .backend_reset_req_o(reset_req), .backend_queue_stop_req_o(stop_req),
    .backend_reset_done_i,
    .backend_idle_i(backend_idle_i & {APU_NUM_QUEUES{exec_idle}}),
    .used_valid_i, .used_qid_i, .used_context_i, .used_fence_i, .used_len_i,
    .used_ready_o, .cfg_display_event_i, .mbox_req_o(mbox_req), .mbox_rsp_i(mbox_rsp),
    .guest_hold_i(1'b0), .guest_epoch_i('0), .ctrl_hold_i(1'b0), .ctrl_epoch_i('0),
    .epoch_o()
  );

  if (!ExecEn) begin : gen_off
    assign exec_idle = 1'b1;
    assign mbox_rsp = '{rdata: '0, error: 1'b1, ready: mbox_req.valid};
  end else begin : gen_on
    apu_mem_op_e op;
    apu_exec_job_t job;
    apu_map_cpl_t cpl;
    logic op_v, op_r, cpl_v, cpl_r;

    g6lc_apu_mbox #(.ApuCfg(ApuCfg)) i_mbox (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1), .cancel_i(reset_req),
      .req_i(mbox_req), .rsp_o(mbox_rsp),
      .op_valid_o(op_v), .op_ready_i(op_r), .op_o(op),
      .insert_o(), .lookup_o(), .inval_o(),
      .sg_load_o(), .sg_list_o(), .sg_backing_o(),
      .sg_query_o(), .cmd_o(), .cmd_dma_o(), .cmd_map_o(),
      .used_o(), .exec_o(job),
      .op_cpl_valid_i(cpl_v), .op_cpl_ready_o(cpl_r), .op_cpl_i(cpl),
      .lookup_mapping_i('0), .cmd_rd_valid_o(), .cmd_rd_ready_i(1'b0),
      .cmd_rd_offset_o(), .cmd_rd_data_valid_i(1'b0),
      .cmd_rd_data_ready_o(), .cmd_rd_data_i('0),
      .idle_i(exec_idle), .cmd_held_i(1'b0)
    );
    g6lc_apu_exec_bind #(.ApuCfg(ApuCfg)) i_bind (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1), .cancel_i(reset_req),
      .op_valid_i(op_v), .op_ready_o(op_r), .op_i(op), .exec_i(job),
      .op_cpl_valid_o(cpl_v), .op_cpl_ready_i(cpl_r), .op_cpl_o(cpl),
      .idle_o(exec_idle)
    );
  end

  logic unused_dma;
  assign unused_dma = |dma_rsp_i;
endmodule
