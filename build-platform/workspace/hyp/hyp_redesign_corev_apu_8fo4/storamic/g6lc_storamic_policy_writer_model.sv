// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Same-clock model composition, not native authorization. Platform policy and
// upstream/provider/resume facts remain external; actual writer ACKs are bound.
module g6lc_storamic_policy_writer_model #(
  parameter g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg = g6lc_storamic_cfg_pkg::StoramicOff,
  parameter int unsigned RawFlashBytes = 4096,
  parameter int unsigned RspCycles = 0,
  parameter int unsigned TimeoutCycles = 32768,
  parameter type policy_t = logic [31:0],
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
  input logic update_valid_i,
  output logic update_ready_o,
  input policy_t update_policy_i,
  output policy_t policy_o,
  output logic [31:0] policy_epoch_o,
  output logic policy_ready_o, policy_pending_o, policy_quiesce_o,
  output logic policy_revoked_o, policy_exhausted_o,
  output logic policy_commit_o, policy_revoke_o, policy_exhaust_o, policy_reject_o,
  input logic [4:0] providers_ready_i,
  input logic upstream_present_i, upstream_hold_i, route_hold_i, maintenance_hold_i,
  input logic aw_authorized_i, ar_authorized_i,
  input logic present_i, identity_valid_i, protection_ok_i, power_cut_i,
  input logic [159:0] module_id_i,
  input logic [31:0] mapping_generation_i, reset_generation_i,
  input logic upstream_paused_i, upstream_error_i, restore_resume_safe_i,
  output logic upstream_pause_o, writer_quiesced_o, writer_error_o, ctrl_quiesced_o,
  output logic writer_inflight_o, dma_inflight_o, axi_quiesce_o, policy_hold_o,
  output logic initialized_o, busy_o, recovery_locked_o, checkpoint_valid_o,
  output logic metadata_ok_o, degraded_o,
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
  localparam bit Active = shapes_legal() && cfg_legal(Cfg) && Cfg.Enable &&
      Cfg.Profile == ProfileModel && Layout.legal && Cfg.ModelBytes >= 16 &&
      Cfg.ModelBytes % 8 == 0 && Cfg.ModelBase % 8 == 0 && Cfg.ModelBytes <= 64'hFFFF_FFFF &&
      64'(TimeoutCycles) >= (Cfg.ModelBytes / 8) * 32 + 64;
  logic admit;
  logic [1:0] ingress_present, ingress_quiet, ingress_hold;
  assign ingress_present = {Active, upstream_present_i};
  // DMA/job pause and MMIO sealing are different contracts; both must retire.
  assign ingress_quiet = {writer_quiesced_o && ctrl_quiesced_o, upstream_paused_i};
  assign ingress_hold = {writer_inflight_o || dma_inflight_o, upstream_hold_i};
  g6lc_storamic_checkpoint_policy #(
    .Enable(Active), .NumIngress(2), .NumProviders(5), .policy_t(policy_t)
  ) policy (
    .clk_i, .rst_ni, .update_valid_i, .update_ready_o, .update_policy_i,
    .providers_ready_i, .ingress_present_i(ingress_present),
    .ingress_quiesced_i(ingress_quiet), .ingress_hold_i(ingress_hold),
    .route_hold_i, .endpoint_hold_i(policy_hold_o), .maintenance_hold_i,
    .quiesce_o(policy_quiesce_o), .command_admit_o(admit),
    .policy_ready_o, .policy_o, .policy_epoch_o, .pending_o(policy_pending_o),
    .revoked_o(policy_revoked_o), .exhausted_o(policy_exhausted_o),
    .commit_event_o(policy_commit_o), .revoke_event_o(policy_revoke_o),
    .exhaust_event_o(policy_exhaust_o), .reject_event_o(policy_reject_o)
  );
  g6lc_storamic_checkpoint_writer_model #(
    .Cfg(Cfg), .RawFlashBytes(RawFlashBytes), .RspCycles(RspCycles),
    .TimeoutCycles(TimeoutCycles), .req_t(req_t), .resp_t(resp_t),
    .ctrl_req_t(ctrl_req_t), .ctrl_resp_t(ctrl_resp_t)
  ) writer (
    .clk_i, .rst_ni, .testmode_i, .req_i, .resp_o,
    .ctrl_req_i, .ctrl_resp_o, .device_ctrl_req_i, .device_ctrl_resp_o, .irq_o,
    .providers_ready_i, .control_enable_i(policy_ready_o), .command_admit_i(admit),
    .aw_authorized_i, .ar_authorized_i, .policy_epoch_i(policy_epoch_o),
    .present_i, .identity_valid_i, .protection_ok_i, .power_cut_i,
    .module_id_i, .mapping_generation_i, .reset_generation_i,
    .upstream_paused_i, .upstream_error_i, .restore_resume_safe_i,
    .writer_quiesce_i(policy_quiesce_o), .ctrl_quiesce_i(policy_quiesce_o),
    .upstream_pause_o, .writer_quiesced_o, .writer_error_o, .ctrl_quiesced_o,
    .writer_inflight_o, .dma_inflight_o, .axi_quiesce_o, .policy_hold_o,
    .initialized_o, .busy_o, .recovery_locked_o, .checkpoint_valid_o,
    .metadata_ok_o, .degraded_o, .checkpoint_generation_o, .block_sectors_o, .reserved_bytes_o,
    .phase_o, .issue_event_o, .refuse_event_o, .revoke_event_o, .done_event_o, .error_event_o
  );
endmodule
