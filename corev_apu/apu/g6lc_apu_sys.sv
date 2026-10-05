// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// SoC-facing APU wrapper: transport AXI-Lite plus the firmware mailbox.
// Memory alone, exec alone, or both under g6lc_apu_sched.
// g6lc_apu_axi_lite stays transport-only. Default-off.

// Interplay: guest AXI-Lite ==> VirtioMmio; mailbox <-> ApuMem XOR ExecCluster. Private vgpu leaves --? this module. See AGENTS-impl-interplays.md.
module g6lc_apu_sys
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
  input  dma_rsp_t dma_rsp_i,
  input  logic guest_hold_i,
  input  logic [31:0] guest_epoch_i,
  input  logic ctrl_hold_i,
  input  logic [31:0] ctrl_epoch_i,
  output logic [31:0] epoch_o
);
  localparam bit MemEn = ApuCfg.Enable &&
      (ApuCfg.MaxResources != 0 || ApuCfg.MaxCmdBytes != 0 ||
       ApuCfg.SgEn || ApuCfg.DmaReadEn || ApuCfg.DmaWriteEn);
  localparam bit ExecWant = ApuCfg.Enable && ApuCfg.ExecEn;

  apu_reg_req_t mbox_req;
  apu_reg_rsp_t mbox_rsp;
  logic svc_idle, reset_req, lite_irq;
  logic [APU_NUM_QUEUES-1:0] stop_req;

  assign backend_reset_req_o = reset_req;
  assign backend_queue_stop_req_o = stop_req;
  assign control_irq_o = lite_irq || bus_fault_o;

  `ifndef SYNTHESIS
  initial begin
    assert (apu_mem_exec_split(ApuCfg))
      else $fatal(1, "APU sys: memory and exec are not a legal pair");
  end
  `endif

  g6lc_apu_axi_lite #(
    .ApuCfg(ApuCfg), .CoreCfg(CoreCfg), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t)
  ) i_lite (
    .clk_i, .rst_ni, .testmode_i,
    .guest_req_i, .guest_rsp_o, .control_req_i, .control_rsp_o,
    .control_aw_authorized_i, .control_ar_authorized_i,
    .guest_irq_o, .control_irq_o(lite_irq), .vq_state_o, .queue_enable_o,
    .backend_reset_req_o(reset_req), .backend_queue_stop_req_o(stop_req),
    .backend_reset_done_i,
    .backend_idle_i(backend_idle_i & {APU_NUM_QUEUES{svc_idle}}),
    .used_valid_i, .used_qid_i, .used_context_i, .used_fence_i, .used_len_i,
    .used_ready_o, .cfg_display_event_i, .mbox_req_o(mbox_req), .mbox_rsp_i(mbox_rsp),
    .guest_hold_i, .guest_epoch_i, .ctrl_hold_i, .ctrl_epoch_i, .epoch_o
  );

  if (MemEn && ExecWant) begin : gen_both
    g6lc_apu_sched #(
      .ApuCfg(ApuCfg), .Enable(1'b1),
      .dma_req_t(dma_req_t), .dma_rsp_t(dma_rsp_t)
    ) i_sched (
      .clk_i, .rst_ni, .testmode_i,
      .req_i(mbox_req), .rsp_o(mbox_rsp),
      .cancel_i(reset_req),
      .idle_o(svc_idle), .bus_fault_o,
      .dma_req_o, .dma_rsp_i
    );
  end else if (MemEn) begin : gen_mem
    logic cmd_held;
    logic mem_idle;
    apu_mem_op_e op;
    apu_map_insert_t insert;
    apu_map_lookup_t lookup;
    apu_map_inval_t inval;
    apu_sg_load_t sg_load;
    apu_dma_mapping_t sg_list, sg_back, cmd_map, lmap;
    apu_sg_query_t sg_query;
    apu_cmd_req_t cmd;
    apu_dma_read_req_t cmd_dma;
    apu_used_req_t used;
    apu_exec_job_t unused_exec;
    apu_map_cpl_t cpl;
    logic op_v, op_r, cpl_v, cpl_r;
    logic crv, crr, crdv, crdr;
    logic [31:0] croff;
    logic [63:0] crdata;

    assign svc_idle = mem_idle;
    g6lc_apu_mbox #(.ApuCfg(ApuCfg)) i_mbox (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1), .cancel_i(reset_req),
      .req_i(mbox_req), .rsp_o(mbox_rsp),
      .op_valid_o(op_v), .op_ready_i(op_r), .op_o(op),
      .insert_o(insert), .lookup_o(lookup), .inval_o(inval),
      .sg_load_o(sg_load), .sg_list_o(sg_list), .sg_backing_o(sg_back),
      .sg_query_o(sg_query), .cmd_o(cmd), .cmd_dma_o(cmd_dma), .cmd_map_o(cmd_map),
      .used_o(used), .exec_o(unused_exec), .op_cpl_valid_i(cpl_v), .op_cpl_ready_o(cpl_r), .op_cpl_i(cpl),
      .lookup_mapping_i(lmap), .cmd_rd_valid_o(crv), .cmd_rd_ready_i(crr),
      .cmd_rd_offset_o(croff), .cmd_rd_data_valid_i(crdv),
      .cmd_rd_data_ready_o(crdr), .cmd_rd_data_i(crdata),
      .idle_i(mem_idle), .cmd_held_i(cmd_held)
    );
    g6lc_apu_mem #(.ApuCfg(ApuCfg), .axi_req_t(dma_req_t), .axi_rsp_t(dma_rsp_t)) i_mem (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1),
      .cancel_i(reset_req), .invalidate_i(reset_req),
      .op_valid_i(op_v), .op_ready_o(op_r), .op_i(op),
      .insert_i(insert), .lookup_i(lookup), .inval_i(inval),
      .sg_load_i(sg_load), .sg_list_i(sg_list), .sg_backing_i(sg_back),
      .sg_query_i(sg_query), .cmd_i(cmd), .cmd_dma_i(cmd_dma), .cmd_map_i(cmd_map),
      .used_i(used), .op_cpl_valid_o(cpl_v), .op_cpl_ready_i(cpl_r), .op_cpl_o(cpl),
      .lookup_mapping_o(lmap), .cmd_rd_valid_i(crv), .cmd_rd_ready_o(crr),
      .cmd_rd_offset_i(croff), .cmd_rd_data_valid_o(crdv),
      .cmd_rd_data_ready_i(crdr), .cmd_rd_data_o(crdata),
      .idle_o(mem_idle), .cmd_held_o(cmd_held), .bus_fault_o,
      .axi_req_o(dma_req_o), .axi_rsp_i(dma_rsp_i)
    );
  end else if (ExecWant) begin : gen_exec
    apu_mem_op_e op;
    apu_exec_job_t job;
    apu_map_cpl_t cpl;
    logic op_v, op_r, cpl_v, cpl_r, exec_idle;

    assign bus_fault_o = 1'b0;
    assign dma_req_o = '0;
    assign svc_idle = exec_idle;
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
  end else begin : gen_off
    assign svc_idle = 1'b1;
    assign bus_fault_o = 1'b0;
    assign dma_req_o = '0;
    assign mbox_rsp = '{rdata: '0, error: 1'b1, ready: mbox_req.valid};
  end
endmodule
