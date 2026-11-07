// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Same-clock, uncached model composition only. Native authority, upstream
// producer acknowledgement and resume synchronization are never fabricated.
module g6lc_storamic_checkpoint_writer_model #(
  parameter g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg = g6lc_storamic_cfg_pkg::StoramicOff,
  parameter int unsigned RawFlashBytes = 4096,
  parameter int unsigned RspCycles = 0,
  parameter int unsigned TimeoutCycles = 32768,
  parameter int unsigned QueueNumMax = 4,
  parameter int unsigned MaxSegs = 4,
  parameter type req_t = g6lc_storamic_pkg::axi_req_t,
  parameter type resp_t = g6lc_storamic_pkg::axi_resp_t,
  parameter type ctrl_req_t = g6lc_storamic_pkg::axil_req_t,
  parameter type ctrl_resp_t = g6lc_storamic_pkg::axil_resp_t
) (
  input logic clk_i, rst_ni, testmode_i,
  input req_t req_i,
  output resp_t resp_o,
  input ctrl_req_t ctrl_req_i,
  output ctrl_resp_t ctrl_resp_o,
  input g6lc_storamic_pkg::axil_req_t device_ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t device_ctrl_resp_o,
  output logic irq_o,
  input logic [4:0] providers_ready_i,
  input logic control_enable_i, command_admit_i, aw_authorized_i, ar_authorized_i,
  input logic [31:0] policy_epoch_i,
  input logic present_i, identity_valid_i, protection_ok_i, power_cut_i,
  input logic [159:0] module_id_i,
  input logic [31:0] mapping_generation_i, reset_generation_i,
  input logic upstream_paused_i, upstream_error_i, restore_resume_safe_i,
  input logic writer_quiesce_i, ctrl_quiesce_i,
  output logic upstream_pause_o, writer_quiesced_o, writer_error_o, ctrl_quiesced_o,
  output logic writer_inflight_o, dma_inflight_o,
  output logic axi_quiesce_o, policy_hold_o,
  output logic initialized_o, busy_o, recovery_locked_o,
  output logic checkpoint_valid_o, metadata_ok_o, degraded_o,
  output logic [63:0] checkpoint_generation_o, block_sectors_o, reserved_bytes_o,
  output logic [3:0] phase_o,
  output logic issue_event_o, refuse_event_o, revoke_event_o, done_event_o, error_event_o
);
  import g6lc_storamic_cfg_pkg::*;
  import g6lc_storamic_checkpoint_pkg::*;
  function automatic bit shapes_legal();
    req_t q;
    resp_t r;
    ctrl_req_t c;
    ctrl_resp_t s;
    return $bits(q.w.data) == 64 && $bits(q.w.strb) == 8 && $bits(r.r.data) == 64 &&
        $bits(q.aw.addr) <= 64 && $bits(q.ar.addr) <= 64 &&
        $bits(q.aw.id) <= 16 && $bits(q.ar.id) <= 16 &&
        $bits(q.aw.id) == $bits(r.b.id) && $bits(q.ar.id) == $bits(r.r.id) &&
        $bits(c.w.data) == 32 && $bits(c.w.strb) == 4 && $bits(s.r.data) == 32 &&
        $bits(c.aw.addr) <= 64 && $bits(c.ar.addr) <= 64;
  endfunction
  localparam checkpoint_layout_t Layout = checkpoint_layout(
      64'(RawFlashBytes), Cfg.ModelBytes, 64'd0, 1'b0);
  localparam bit ModelLegal = shapes_legal() && cfg_legal(Cfg) && QueueNumMax >= 1 &&
      QueueNumMax <= 128 && (QueueNumMax & (QueueNumMax - 1)) == 0 && MaxSegs >= 2 &&
      (!Cfg.Enable || (Cfg.Profile == ProfileModel && Layout.legal &&
       Cfg.ModelBytes >= 16 && Cfg.ModelBytes % 8 == 0 && Cfg.ModelBase % 8 == 0 &&
       Cfg.ModelBytes <= 64'hFFFF_FFFF &&
       64'(TimeoutCycles) >= (Cfg.ModelBytes / 8) * 32 + 64));
  localparam bit Active = ModelLegal && Cfg.Enable;
  req_t memory_req;
  resp_t memory_resp;
  logic producer_pause, endpoint_hold, device_off_hold;
  logic sr, sg, sw, srv, se, fr, fa, fe;
  logic [63:0] sa, sd, sdata;
  logic [7:0] sb;
  assign upstream_pause_o = producer_pause || (Active && writer_quiesce_i);
  assign policy_hold_o = endpoint_hold || writer_inflight_o ||
                         dma_inflight_o || device_off_hold;
  // pragma translate_off
  initial if (!ModelLegal) $fatal(1, "STORAMIC_CHECKPOINT_WRITER_MODEL_CONFIG");
  // pragma translate_on

  g6lc_storamic_checkpoint_endpoint #(
    .Cfg(Cfg), .NumProducers(2), .RawFlashBytes(RawFlashBytes),
    .RspCycles(RspCycles), .TimeoutCycles(TimeoutCycles),
    .req_t(req_t), .resp_t(resp_t), .ctrl_req_t(ctrl_req_t), .ctrl_resp_t(ctrl_resp_t)
  ) endpoint (
    .clk_i, .rst_ni, .testmode_i, .req_i(memory_req), .resp_o(memory_resp),
    .ctrl_req_i, .ctrl_resp_o, .providers_ready_i,
    .control_enable_i, .command_admit_i, .aw_authorized_i, .ar_authorized_i, .policy_epoch_i,
    .present_i, .identity_valid_i, .protection_ok_i, .power_cut_i, .module_id_i,
    .mapping_generation_i, .reset_generation_i,
    .producer_paused_i({writer_quiesced_o, upstream_paused_i}),
    .producer_error_i({writer_error_o, upstream_error_i}),
    .restore_resume_safe_i, .producer_pause_o(producer_pause),
    .axi_quiesce_o, .policy_hold_o(endpoint_hold),
    .initialized_o, .busy_o, .recovery_locked_o, .checkpoint_valid_o,
    .metadata_ok_o, .degraded_o, .checkpoint_generation_o, .block_sectors_o, .reserved_bytes_o,
    .phase_o, .issue_event_o, .refuse_event_o, .revoke_event_o, .done_event_o, .error_event_o,
    .st_req_i(sr), .st_we_i(sw), .st_gnt_o(sg), .st_addr_i(sa), .st_wdata_i(sd),
    .st_be_i(sb), .st_rvalid_o(srv), .st_error_o(se), .st_rdata_o(sdata),
    .st_flush_req_i(fr), .st_flush_ack_o(fa), .st_flush_error_o(fe)
  );
  if (Active) begin : gen_model
    logic dr, dg, dw, drv, de, usable;
    logic [63:0] da, dd, ddata;
    logic [7:0] db;
    assign usable = initialized_o && metadata_ok_o && !recovery_locked_o &&
                    present_i && identity_valid_i && protection_ok_i && (&providers_ready_i);
    assign device_off_hold = 0;
    g6lc_storamic_virtio_dev #(.QueueNumMax(QueueNumMax), .MaxSegs(MaxSegs)) writer (
      .clk_i, .rst_ni, .quiesce_i(upstream_pause_o),
      .quiesced_o(writer_quiesced_o), .quiesce_error_o(writer_error_o),
      .ctrl_quiesce_i, .ctrl_quiesced_o, .inflight_o(writer_inflight_o),
      .ctrl_req_i(device_ctrl_req_i), .ctrl_resp_o(device_ctrl_resp_o), .irq_o,
      .device_usable_i(usable), .capacity_i(block_sectors_o), .capacity_update_i(1'b0),
      .serial_i(module_id_i), .store_ready_i(usable),
      .dma_base_i(Cfg.ModelBase), .dma_size_i(Cfg.ModelBytes),
      .dma_req_o(dr), .dma_gnt_i(dg), .dma_we_o(dw), .dma_addr_o(da),
      .dma_wdata_o(dd), .dma_be_o(db), .dma_rvalid_i(drv), .dma_rdata_i(ddata), .dma_err_i(de),
      .st_req_o(sr), .st_gnt_i(sg), .st_we_o(sw), .st_addr_o(sa), .st_wdata_o(sd),
      .st_be_o(sb), .st_rvalid_i(srv), .st_rdata_i(sdata), .st_err_i(se),
      .st_durable_i(1'b1), .st_flush_req_o(fr), .st_flush_ack_i(fa), .st_flush_err_i(fe)
    );
    // No cache/coherence claim: this explicit model presents uncached RAM.
    g6lc_storamic_dma_axi #(
      .IdWidth($bits(req_i.aw.id)), .DmaId('0), .InvalEn(1'b0),
      .axi_req_t(req_t), .axi_resp_t(resp_t)
    ) dma (
      .clk_i, .rst_ni, .inflight_o(dma_inflight_o),
      .dma_req_i(dr), .dma_gnt_o(dg), .dma_we_i(dw), .dma_addr_i(da),
      .dma_wdata_i(dd), .dma_be_i(db), .dma_rvalid_o(drv), .dma_rdata_o(ddata), .dma_err_o(de),
      .up_req_i(req_i), .up_resp_o(resp_o), .mst_req_o(memory_req), .mst_resp_i(memory_resp),
      .inval_valid_o(), .inval_addr_o(), .inval_ready_i(1'b0), .inval_done_i(1'b0)
    );
  end else begin : gen_off
    assign memory_req = req_i;
    assign resp_o = memory_resp;
    assign irq_o = 0;
    assign writer_quiesced_o = 0;
    assign writer_error_o = 0;
    assign ctrl_quiesced_o = 0;
    assign writer_inflight_o = 0;
    assign dma_inflight_o = 0;
    assign sr = 0;
    assign sw = 0;
    assign sa = 0;
    assign sd = 0;
    assign sb = 0;
    assign fr = 0;
    // The inactive device still retires control packets with explicit denial.
    g6lc_storamic_checkpoint_service refuse_device (
      .clk_i, .rst_ni, .req_i(device_ctrl_req_i), .resp_o(device_ctrl_resp_o),
      .service_enable_i(1'b0), .command_admit_i(1'b0),
      .aw_authorized_i(1'b0), .ar_authorized_i(1'b0), .policy_epoch_i(32'd0),
      .command_valid_o(), .command_restore_o(), .command_authorized_o(), .command_cookie_o(),
      .command_ready_i(1'b0), .result_valid_i(1'b0), .result_cookie_i(32'd0),
      .result_i(g6lc_storamic_pkg::CP_NOT_READY), .result_ready_o(),
      .initialized_i(1'b0), .busy_i(1'b0), .recovery_locked_i(1'b1),
      .metadata_ok_i(1'b0), .protection_ok_i(1'b0), .checkpoint_valid_i(1'b0),
      .checkpoint_generation_i(64'd0), .issue_event_o(), .refuse_event_o(), .revoke_event_o(),
      .policy_hold_o(device_off_hold)
    );
  end
endmodule
