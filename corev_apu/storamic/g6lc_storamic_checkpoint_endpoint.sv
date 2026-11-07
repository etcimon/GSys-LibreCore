// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Inactive-by-default model integration candidate. Cfg is the existing
// Storamic SoC configuration seam derived from CVA6Cfg, not a PMEM capability.
module g6lc_storamic_checkpoint_endpoint #(
  parameter g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg = g6lc_storamic_cfg_pkg::StoramicOff,
  parameter int unsigned NumProducers = 2,
  parameter int unsigned RawFlashBytes = 1024,
  parameter int unsigned RspCycles = 0,
  parameter int unsigned TimeoutCycles = 4096,
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
  // Transaction policy, persistent identity, qualified protection, descriptor
  // binding and resume synchronization providers, respectively. No tie-high
  // substitute is supplied here. The platform must qualify each provider.
  input logic [4:0] providers_ready_i,
  input logic control_enable_i, command_admit_i, aw_authorized_i, ar_authorized_i,
  input logic [31:0] policy_epoch_i,
  input logic present_i, identity_valid_i, protection_ok_i, power_cut_i,
  input logic [159:0] module_id_i,
  input logic [31:0] mapping_generation_i, reset_generation_i,
  input logic [NumProducers-1:0] producer_paused_i, producer_error_i,
  input logic restore_resume_safe_i,
  output logic producer_pause_o, axi_quiesce_o, policy_hold_o,
  output logic initialized_o, busy_o, recovery_locked_o,
  output logic checkpoint_valid_o, metadata_ok_o, degraded_o,
  output logic [63:0] checkpoint_generation_o, block_sectors_o, reserved_bytes_o,
  output logic [3:0] phase_o,
  output logic issue_event_o, refuse_event_o, revoke_event_o, done_event_o, error_event_o,
  input logic st_req_i, st_we_i,
  output logic st_gnt_o,
  input logic [63:0] st_addr_i, st_wdata_i,
  input logic [7:0] st_be_i,
  output logic st_rvalid_o, st_error_o,
  output logic [63:0] st_rdata_o,
  input logic st_flush_req_i,
  output logic st_flush_ack_o, st_flush_error_o
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_cfg_pkg::*;
  import g6lc_storamic_checkpoint_pkg::*;
  function automatic bit shapes_legal();
    req_t data_req;
    resp_t data_resp;
    ctrl_req_t control_req;
    ctrl_resp_t control_resp;
    return $bits(data_req.w.data) == 64 && $bits(data_req.w.strb) == 8 &&
        $bits(data_resp.r.data) == 64 &&
        $bits(data_req.aw.addr) <= 64 && $bits(data_req.ar.addr) <= 64 &&
        $bits(data_req.aw.id) <= 16 && $bits(data_req.ar.id) <= 16 &&
        $bits(data_resp.b.id) == $bits(data_req.aw.id) &&
        $bits(data_resp.r.id) == $bits(data_req.ar.id) &&
        $bits(control_req.w.data) == 32 && $bits(control_req.w.strb) == 4 &&
        $bits(control_resp.r.data) == 32 &&
        $bits(control_req.aw.addr) <= 64 && $bits(control_req.ar.addr) <= 64;
  endfunction
  localparam checkpoint_layout_t Layout = checkpoint_layout(
      64'(RawFlashBytes), Cfg.ModelBytes, 64'd0, 1'b0);
  localparam bit ConfigLegal = shapes_legal() && cfg_legal(Cfg) &&
      NumProducers >= 1 && NumProducers <= 8 &&
      (!Cfg.Enable ||
      (Cfg.Profile == ProfileModel && Cfg.ModelBytes >= 16 && Cfg.ModelBytes % 8 == 0 &&
       Cfg.ModelBase % 8 == 0 && Cfg.ModelBytes <= 64'hFFFF_FFFF && Layout.legal &&
       64'(TimeoutCycles) >= (Cfg.ModelBytes / 8) * 32 + 64));
  localparam bit Active = ConfigLegal && Cfg.Enable;
  logic providers_ready, seal, command, restoring, authorized, ready, result_valid, consume;
  logic [31:0] cookie, result_cookie;
  logic control_hold, data_hold, media_hold;
  checkpoint_result_e result;
  assign providers_ready = &providers_ready_i;
  assign axi_quiesce_o = seal || !providers_ready || !present_i || !identity_valid_i;
  assign policy_hold_o = control_hold || data_hold || media_hold;
  // A real policy manager must serialize updates against this ownership signal.
  g6lc_storamic_checkpoint_service #(.req_t(ctrl_req_t), .resp_t(ctrl_resp_t)) control (
    .clk_i, .rst_ni, .req_i(ctrl_req_i), .resp_o(ctrl_resp_o),
    .service_enable_i(Active && control_enable_i && providers_ready),
    .command_admit_i,
    .aw_authorized_i, .ar_authorized_i, .policy_epoch_i,
    .command_valid_o(command), .command_restore_o(restoring), .command_authorized_o(authorized),
    .command_cookie_o(cookie), .command_ready_i(ready), .result_valid_i(result_valid),
    .result_cookie_i(result_cookie), .result_i(result), .result_ready_o(consume),
    .initialized_i(initialized_o), .busy_i(busy_o), .recovery_locked_i(recovery_locked_o),
    .metadata_ok_i(metadata_ok_o), .protection_ok_i(protection_ok_i && providers_ready),
    .checkpoint_valid_i(checkpoint_valid_o), .checkpoint_generation_i(checkpoint_generation_o),
    .issue_event_o, .refuse_event_o, .revoke_event_o, .policy_hold_o(control_hold)
  );
  // pragma translate_off
  initial if (!ConfigLegal) $fatal(1, "STORAMIC_CHECKPOINT_ENDPOINT_CONFIG");
  // pragma translate_on
  if (Active) begin : gen_model
    logic mr, mg, mw, mrv, me, mready, sealed;
    logic [63:0] ma, md, mdata;
    logic [7:0] mb;
    txn_id_t mt, rt;
    g6lc_storamic_axi_memory #(
      .req_t(req_t), .resp_t(resp_t), .BaseAddr(Cfg.ModelBase), .RegionBytes(Cfg.ModelBytes)
    ) ingress (
      .clk_i, .rst_ni, .testmode_i, .quiesce_i(axi_quiesce_o), .quiesced_o(sealed),
      .req_i, .resp_o, .source_i(8'd1), .reset_generation_i,
      .service_ready_o(), .sequence_exhausted_o(), .faults_o(), .events_o(), .inflight_o(data_hold),
      .mem_ready_i(mready), .mem_req_o(mr), .mem_gnt_i(mg), .mem_we_o(mw),
      .mem_addr_o(ma), .mem_wdata_o(md), .mem_be_o(mb), .mem_tag_o(mt), .mem_slot_o(),
      .mem_rvalid_i(mrv), .mem_rdata_i(mdata), .mem_error_i(me), .mem_tag_i(rt),
      .map_valid_i(1'b0), .slot_map_i('0), .region_map_i('0)
    );
    g6lc_storamic_checkpoint_model #(
      .NumProducers(NumProducers), .ModelBytes(int'(Cfg.ModelBytes)),
      .RawFlashBytes(RawFlashBytes), .RamRspCycles(RspCycles), .FlashRspCycles(RspCycles),
      .TimeoutCycles(TimeoutCycles)
    ) media (
      .clk_i, .rst_ni, .present_i, .identity_valid_i(identity_valid_i && providers_ready),
      .protection_ok_i(protection_ok_i && providers_ready), .power_cut_i, .module_id_i,
      .mapping_generation_i, .reset_generation_i,
      .command_valid_i(command), .command_restore_i(restoring), .authorized_i(authorized),
      .command_cookie_i(cookie), .command_ready_o(ready), .result_valid_o(result_valid),
      .result_ready_i(consume), .result_cookie_o(result_cookie), .result_o(result),
      .restore_resume_safe_i, .producer_pause_o, .producer_paused_i, .producer_error_i,
      .axi_quiesce_o(seal), .axi_quiesced_i(sealed), .media_hold_o(media_hold),
      .initialized_o, .busy_o, .recovery_locked_o, .checkpoint_valid_o,
      .metadata_ok_o, .degraded_o, .checkpoint_generation_o, .block_sectors_o, .reserved_bytes_o,
      .phase_o, .media_phase_o(), .guard_phase_o(),
      .done_event_o, .error_event_o, .refuse_event_o(), .stale_event_o(),
      .mem_ready_o(mready), .mem_req_i(mr), .mem_we_i(mw), .mem_gnt_o(mg),
      .mem_addr_i(ma), .mem_wdata_i(md), .mem_be_i(mb), .mem_tag_i(mt),
      .mem_rvalid_o(mrv), .mem_error_o(me), .mem_rdata_o(mdata), .mem_tag_o(rt),
      .st_req_i, .st_we_i, .st_gnt_o, .st_addr_i, .st_wdata_i, .st_be_i,
      .st_rvalid_o, .st_error_o, .st_rdata_o,
      .st_flush_req_i, .st_flush_ack_o, .st_flush_error_o
    );
  end else begin : gen_refuse
    g6lc_storamic_axi_refuse #(.req_t(req_t), .resp_t(resp_t)) ingress (
      .clk_i, .rst_ni, .req_i, .resp_o
    );
    assign ready = 0;
    assign data_hold = 0;
    assign media_hold = 0;
    assign result_valid = 0;
    assign result_cookie = 0;
    assign result = CP_NOT_READY;
    assign seal = 1;
    assign producer_pause_o = 1;
    assign initialized_o = 0;
    assign busy_o = 0;
    assign recovery_locked_o = 1;
    assign checkpoint_valid_o = 0;
    assign metadata_ok_o = 0;
    assign degraded_o = 0;
    assign checkpoint_generation_o = 0;
    assign block_sectors_o = 0;
    assign reserved_bytes_o = 0;
    assign phase_o = 0;
    assign done_event_o = 0;
    assign error_event_o = 0;
    assign st_gnt_o = 0;
    assign st_rvalid_o = 0;
    assign st_error_o = 0;
    assign st_rdata_o = 0;
    assign st_flush_ack_o = 0;
    assign st_flush_error_o = 0;
  end
endmodule
