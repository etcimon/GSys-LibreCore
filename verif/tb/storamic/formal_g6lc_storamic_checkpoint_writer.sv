// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Disabled/illegal-profile refusal only; not an active native liveness proof.
module formal_g6lc_storamic_checkpoint_writer #(
  parameter bit Invalid = 0,
  parameter bit OracleNegative = 0
) (
  input logic clk_i, rst_ni,
  input g6lc_storamic_pkg::axi_req_t req_i,
  input g6lc_storamic_pkg::axil_req_t ctrl_i, device_i,
  input logic [4:0] providers_i,
  input logic upstream_ack_i, resume_i,
  output logic cover_read_o, cover_held_o
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_cfg_pkg::*;
  localparam storamic_cfg_t BadCfg = '{
    Enable: 1, Profile: ProfileModel, MaxSticks: 1, RequestedMediaCaps: 0,
    ModelBase: 64'h8000_0000, ModelBytes: 64
  };
  axi_resp_t resp;
  axil_resp_t cp, dev;
  logic irq, pause_req, wquiet, werror, cq, wi, di, seal, owner;
  logic initialized, busy, locked, valid, metadata, degraded;
  logic [63:0] generation, sectors, reserved;
  logic [3:0] phase;
  g6lc_storamic_checkpoint_writer_model #(
    .Cfg(Invalid ? BadCfg : StoramicOff), .RawFlashBytes(Invalid ? 256 : 4096)
  ) dut (
    .clk_i, .rst_ni, .testmode_i(1'b0), .req_i, .resp_o(resp),
    .ctrl_req_i(ctrl_i), .ctrl_resp_o(cp),
    .device_ctrl_req_i(device_i), .device_ctrl_resp_o(dev), .irq_o(irq),
    .providers_ready_i(providers_i), .control_enable_i(1'b1), .command_admit_i(1'b1),
    .aw_authorized_i(1'b1), .ar_authorized_i(1'b1), .policy_epoch_i(32'd7),
    .present_i(1'b1), .identity_valid_i(1'b1), .protection_ok_i(1'b1), .power_cut_i(1'b0),
    .module_id_i(160'd1), .mapping_generation_i(32'd7), .reset_generation_i(32'd1),
    .upstream_paused_i(upstream_ack_i), .upstream_error_i(1'b0),
    .restore_resume_safe_i(resume_i), .writer_quiesce_i(1'b1), .ctrl_quiesce_i(1'b1),
    .upstream_pause_o(pause_req), .writer_quiesced_o(wquiet), .writer_error_o(werror),
    .ctrl_quiesced_o(cq), .writer_inflight_o(wi), .dma_inflight_o(di),
    .axi_quiesce_o(seal), .policy_hold_o(owner),
    .initialized_o(initialized), .busy_o(busy), .recovery_locked_o(locked),
    .checkpoint_valid_o(valid), .metadata_ok_o(metadata), .degraded_o(degraded),
    .checkpoint_generation_o(generation), .block_sectors_o(sectors), .reserved_bytes_o(reserved),
    .phase_o(phase), .issue_event_o(), .refuse_event_o(), .revoke_event_o(),
    .done_event_o(), .error_event_o()
  );
  always_comb if (rst_ni) begin
    assert(!initialized && !busy && locked && seal && !valid && !metadata);
    // The endpoint requests fail-closed pause, but no inactive writer ACK exists.
    assert(!irq && pause_req && !wquiet && !werror && !cq && !wi && !di);
    assert(generation == 0 && sectors == 0);
    if (resp.b_valid) assert(resp.b.resp == 2);
    if (resp.r_valid) assert(resp.r.resp == 2 && resp.r.data == 0);
    if (cp.b_valid) assert(cp.b.resp == 2 && owner);
    if (cp.r_valid) assert(cp.r.resp == 2 && cp.r.data == 0 && owner);
    if (dev.b_valid) assert(dev.b.resp == 2 && owner);
    if (dev.r_valid) assert(dev.r.resp == 2 && dev.r.data == 0 && owner);
    if (OracleNegative) assert(wquiet);
  end
  assign cover_read_o = rst_ni && dev.r_valid && dev.r.resp == 2;
  assign cover_held_o = rst_ni && dev.b_valid && !device_i.b_ready && owner;
endmodule
