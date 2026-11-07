// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Disabled/illegal composition only. Active policy safety is proved separately;
// full writer/policy coupling uses real-job simulation, not native liveness.
module formal_g6lc_storamic_policy_writer #(
  parameter bit Invalid = 0,
  parameter bit OracleNegative = 0
) (
  input logic clk_i, rst_ni, update_i, upstream_ack_i,
  input logic [4:0] providers_i,
  input g6lc_storamic_pkg::axi_req_t req_i,
  input g6lc_storamic_pkg::axil_req_t ctrl_i, device_i,
  output logic cover_read_o, cover_held_o
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_cfg_pkg::*;
  localparam storamic_cfg_t BadCfg = '{
    Enable: 1, Profile: ProfileModel, MaxSticks: 1, RequestedMediaCaps: 0,
    ModelBase: 64'h8000_0000, ModelBytes: 64
  };
  axi_resp_t rsp;
  axil_resp_t cp, dev;
  logic ready, update_ready, pending, quiet, revoked, exhausted, owner, irq;
  logic pause_req, wquiet, werror, cq, wi, di, seal, initialized, busy, locked, valid, metadata;
  logic [31:0] policy_word, epoch;
  g6lc_storamic_policy_writer_model #(
    .Cfg(Invalid ? BadCfg : StoramicOff), .RawFlashBytes(Invalid ? 256 : 4096)
  ) dut (
    .clk_i, .rst_ni, .testmode_i(1'b0), .req_i, .resp_o(rsp),
    .ctrl_req_i(ctrl_i), .ctrl_resp_o(cp), .device_ctrl_req_i(device_i),
    .device_ctrl_resp_o(dev), .irq_o(irq), .update_valid_i(update_i), .update_ready_o(update_ready),
    .update_policy_i(32'hFFFF_FFFF), .policy_o(policy_word), .policy_epoch_o(epoch),
    .policy_ready_o(ready), .policy_pending_o(pending), .policy_quiesce_o(quiet),
    .policy_revoked_o(revoked), .policy_exhausted_o(exhausted),
    .policy_commit_o(), .policy_revoke_o(), .policy_exhaust_o(), .policy_reject_o(),
    .providers_ready_i(providers_i), .upstream_present_i(1'b1), .upstream_hold_i(1'b0),
    .route_hold_i(1'b0), .maintenance_hold_i(1'b0), .aw_authorized_i(1'b1), .ar_authorized_i(1'b1),
    .present_i(1'b1), .identity_valid_i(1'b1), .protection_ok_i(1'b1), .power_cut_i(1'b0),
    .module_id_i(160'd1), .mapping_generation_i(32'd7), .reset_generation_i(32'd1),
    .upstream_paused_i(upstream_ack_i), .upstream_error_i(1'b0), .restore_resume_safe_i(1'b1),
    .upstream_pause_o(pause_req), .writer_quiesced_o(wquiet), .writer_error_o(werror),
    .ctrl_quiesced_o(cq), .writer_inflight_o(wi), .dma_inflight_o(di),
    .axi_quiesce_o(seal), .policy_hold_o(owner), .initialized_o(initialized),
    .busy_o(busy), .recovery_locked_o(locked), .checkpoint_valid_o(valid),
    .metadata_ok_o(metadata), .degraded_o(), .checkpoint_generation_o(),
    .block_sectors_o(), .reserved_bytes_o(), .phase_o(),
    .issue_event_o(), .refuse_event_o(), .revoke_event_o(), .done_event_o(), .error_event_o()
  );
  always_comb if (rst_ni) begin
    assert (!ready && !update_ready && !pending && epoch == 0 && policy_word == 0 && quiet);
    assert (!initialized && !busy && locked && seal && !valid && !metadata);
    assert (!irq && pause_req && !wquiet && !werror && !cq && !wi && !di);
    if (rsp.b_valid) assert (rsp.b.resp == 2);
    if (rsp.r_valid) assert (rsp.r.resp == 2 && rsp.r.data == 0);
    if (cp.b_valid) assert (cp.b.resp == 2 && owner);
    if (dev.b_valid) assert (dev.b.resp == 2 && owner);
    if (dev.r_valid) assert (dev.r.resp == 2 && dev.r.data == 0 && owner);
    if (OracleNegative) assert (ready);
  end
  assign cover_read_o = rst_ni && dev.r_valid && dev.r.resp == 2;
  assign cover_held_o = rst_ni && dev.b_valid && !device_i.b_ready && owner;
endmodule
