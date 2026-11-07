// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module formal_g6lc_storamic_checkpoint_endpoint #(
  parameter bit BadLayout = 0,
  parameter bit OracleNegative = 0
) (
  input logic clk_i, rst_ni,
  input g6lc_storamic_pkg::axi_req_t req_i,
  input g6lc_storamic_pkg::axil_req_t ctrl_i,
  input logic [4:0] providers_i,
  input logic enable_i, aw_auth_i, ar_auth_i, present_i, identity_i, protection_i,
  input logic [31:0] policy_epoch_i,
  input logic st_req_i, st_we_i, flush_i,
  input logic [63:0] st_addr_i, st_data_i
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_cfg_pkg::*;
  localparam storamic_cfg_t RequestedModel = '{
    Enable: 1, Profile: ProfileModel, MaxSticks: 1, RequestedMediaCaps: 0,
    ModelBase: 64'h8000_0000, ModelBytes: 64
  };
  axi_resp_t resp;
  axil_resp_t ctrl;
  logic pause_req, seal, policy_hold, initialized, busy, locked, valid, metadata, degraded;
  logic [63:0] generation, sectors, reserved, st_data;
  logic sg, srv, se, fa, fe;
  g6lc_storamic_checkpoint_endpoint #(
    .Cfg(BadLayout ? RequestedModel : StoramicOff),
    .RawFlashBytes(BadLayout ? 256 : 1024)
  ) dut (
    .clk_i, .rst_ni, .testmode_i(1'b0), .req_i, .resp_o(resp),
    .ctrl_req_i(ctrl_i), .ctrl_resp_o(ctrl), .providers_ready_i(providers_i),
    .control_enable_i(enable_i), .command_admit_i(1'b1),
    .aw_authorized_i(aw_auth_i), .ar_authorized_i(ar_auth_i),
    .policy_epoch_i, .present_i, .identity_valid_i(identity_i), .protection_ok_i(protection_i),
    .power_cut_i(1'b0), .module_id_i(160'd1), .mapping_generation_i(32'd1),
    .reset_generation_i(32'd1), .producer_paused_i(2'b11), .producer_error_i(2'b00),
    .restore_resume_safe_i(1'b1), .producer_pause_o(pause_req), .axi_quiesce_o(seal),
    .policy_hold_o(policy_hold), .initialized_o(initialized), .busy_o(busy),
    .recovery_locked_o(locked), .checkpoint_valid_o(valid), .metadata_ok_o(metadata),
    .degraded_o(degraded), .checkpoint_generation_o(generation), .block_sectors_o(sectors),
    .reserved_bytes_o(reserved), .phase_o(), .issue_event_o(), .refuse_event_o(),
    .revoke_event_o(), .done_event_o(), .error_event_o(),
    .st_req_i, .st_we_i, .st_gnt_o(sg), .st_addr_i, .st_wdata_i(st_data_i),
    .st_be_i(8'hFF), .st_rvalid_o(srv), .st_error_o(se), .st_rdata_o(st_data),
    .st_flush_req_i(flush_i), .st_flush_ack_o(fa), .st_flush_error_o(fe)
  );
  always_ff @(posedge clk_i) if (rst_ni) begin
    assert (pause_req && seal && locked && !initialized && !busy);
    if (ctrl.b_valid || ctrl.r_valid) assert (policy_hold);
    assert (!valid && !metadata && !degraded && generation == 0 && sectors == 0 && reserved == 0);
    assert (!sg && !srv && !fa);
    if (resp.b_valid) assert (resp.b.resp == RespSlvErr);
    if (resp.r_valid) assert (resp.r.resp == RespSlvErr && resp.r.data == 0);
    if (ctrl.b_valid) assert (ctrl.b.resp == RespSlvErr);
    if (ctrl.r_valid) assert (ctrl.r.resp == RespSlvErr && ctrl.r.data == 0);
    if (OracleNegative) assert (!ctrl.aw_ready);
  end
endmodule
