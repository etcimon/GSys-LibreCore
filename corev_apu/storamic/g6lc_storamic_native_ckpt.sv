// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Native checkpoint composition (native-composition.md). Bounded profile: one
// hart, in-order, WT cache. Policy (NumIngress=3, NumProviders=5) and endpoint
// (NumProducers=3) share clk/reset. Platform facts arrive packed in plat_in;
// results leave packed in plat_out. The endpoint block-store port (st_*) is
// tied idle: the harness VirtIO device keeps its own model-stick store and the
// endpoint is bound here only as a RAM writer.
module g6lc_storamic_native_ckpt #(
  parameter g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg =
      g6lc_storamic_cfg_pkg::StoramicOff,
  parameter int unsigned NumIngress = 3,
  parameter int unsigned NumProviders = 5,
  parameter int unsigned NumProducers = 3,
  parameter int unsigned RawFlashBytes = 4096,
  parameter int unsigned RspCycles = 0,
  parameter int unsigned TimeoutCycles = 32768,
  // Restore a valid checkpoint automatically after reset (C6b). Off leaves a
  // booted-locked endpoint locked: nothing else can issue that RESTORE.
  parameter bit BootRecovery = 1'b1,
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
  input g6lc_storamic_soc_cfg_pkg::ckpt_plat_in_t plat_in_i,
  output g6lc_storamic_soc_cfg_pkg::ckpt_plat_out_t plat_out_o
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
      Cfg.ModelBytes % 8 == 0 && Cfg.ModelBase % 8 == 0 &&
      Cfg.ModelBytes <= 64'hFFFF_FFFF &&
      64'(TimeoutCycles) >= (Cfg.ModelBytes / 8) * 32 + 64 &&
      NumIngress == 3 && NumProviders == 5 && NumProducers == 3;
  // pragma translate_off
  initial if (!Active) $fatal(1, "STORAMIC_NATIVE_CKPT_CONFIG");
  // pragma translate_on

  // Per-ingress policy observations. Producer/ingress order is fixed by the
  // composition: index 0 = CPU, 1 = debug master, 2 = VirtIO writer/DMA. All
  // three producers are bound, so present is constant; producer errors travel
  // only via producer_error (endpoint) and never revoke presence here.
  // quiesced is the producer drain acknowledgement (paused implies drained);
  // hold is the producer inflight indicator.
  logic [NumIngress-1:0] ingress_present, ingress_quiesced, ingress_hold;
  assign ingress_present = '1;
  assign ingress_quiesced = plat_in_i.producer_paused;
  assign ingress_hold = plat_in_i.ingress_hold;

  logic endpoint_hold;
  logic policy_quiesce, admit, policy_ready, policy_revoked, policy_exhausted;
  logic policy_pending, policy_commit, policy_revoke, policy_exhaust, policy_reject;
  logic update_ready_w;
  logic [31:0] policy_epoch;
  policy_t policy_word;

  // Endpoint service is enabled only when the platform route qualifies it
  // (service_enable) AND the committed policy is ready and un-pending.
  logic control_enable;
  assign control_enable = policy_ready && plat_in_i.service_enable;

  g6lc_storamic_checkpoint_policy #(
    .Enable(Active), .NumIngress(NumIngress), .NumProviders(NumProviders),
    .policy_t(policy_t)
  ) policy (
    .clk_i, .rst_ni,
    .update_valid_i(plat_in_i.update_valid), .update_ready_o(update_ready_w),
    .update_policy_i(plat_in_i.update_policy),
    .providers_ready_i(plat_in_i.providers_ready),
    .ingress_present_i(ingress_present), .ingress_quiesced_i(ingress_quiesced),
    .ingress_hold_i(ingress_hold),
    .route_hold_i(plat_in_i.route_hold), .endpoint_hold_i(endpoint_hold),
    .maintenance_hold_i(plat_in_i.maintenance_hold),
    .quiesce_o(policy_quiesce), .command_admit_o(admit),
    .policy_ready_o(policy_ready), .policy_o(policy_word),
    .policy_epoch_o(policy_epoch), .pending_o(policy_pending),
    .revoked_o(policy_revoked), .exhausted_o(policy_exhausted),
    .commit_event_o(policy_commit), .revoke_event_o(policy_revoke),
    .exhaust_event_o(policy_exhaust), .reject_event_o(policy_reject)
  );

  logic axi_quiesce;
  logic initialized, busy, recovery_locked, checkpoint_valid, metadata_ok;
  logic degraded, issue_event, refuse_event, revoke_event, done_event, error_event;
  logic boot_ready;
  logic [63:0] checkpoint_generation, block_sectors, reserved_bytes;
  logic [3:0] phase;

  // ---- C6b boot recovery agent: sole control-port master while it owns ----
  // The agent only owns the port while pause is held and every producer
  // reports paused, so the platform-side port is idle; it is still held off
  // (not ready, no response) for the duration rather than trusted to be.
  logic rec_hold, rec_own, rec_active, rec_done, rec_failed;
  ctrl_req_t rec_req, ep_ctrl_req;
  ctrl_resp_t ep_ctrl_resp;
  g6lc_storamic_boot_recovery #(
    .Enable(BootRecovery), .req_t(ctrl_req_t), .resp_t(ctrl_resp_t)
  ) i_boot_recovery (
    .clk_i, .rst_ni,
    .initialized_i(initialized), .recovery_locked_i(recovery_locked),
    .checkpoint_valid_i(checkpoint_valid),
    .producers_paused_i(&plat_in_i.producer_paused && !(|plat_in_i.producer_error)),
    .service_usable_i(control_enable && admit && (&plat_in_i.providers_ready)),
    .pause_hold_o(rec_hold), .own_o(rec_own),
    .req_o(rec_req), .resp_i(ep_ctrl_resp),
    .active_o(rec_active), .done_o(rec_done), .failed_o(rec_failed)
  );
  assign ep_ctrl_req = rec_own ? rec_req : ctrl_req_i;
  assign ctrl_resp_o = rec_own ? '0 : ep_ctrl_resp;

  g6lc_storamic_checkpoint_endpoint #(
    .Cfg(Cfg), .NumProducers(NumProducers), .RawFlashBytes(RawFlashBytes),
    .RspCycles(RspCycles), .TimeoutCycles(TimeoutCycles),
    .req_t(req_t), .resp_t(resp_t), .ctrl_req_t(ctrl_req_t), .ctrl_resp_t(ctrl_resp_t)
  ) endpoint (
    .clk_i, .rst_ni, .testmode_i,
    .req_i(req_i), .resp_o(resp_o),
    .ctrl_req_i(ep_ctrl_req), .ctrl_resp_o(ep_ctrl_resp),
    .providers_ready_i(plat_in_i.providers_ready),
    .control_enable_i(control_enable), .command_admit_i(admit),
    .aw_authorized_i(rec_own || plat_in_i.aw_authorized),
    .ar_authorized_i(rec_own || plat_in_i.ar_authorized),
    .policy_epoch_i(policy_epoch),
    .present_i(plat_in_i.present), .identity_valid_i(plat_in_i.identity_valid),
    .protection_ok_i(plat_in_i.protection_ok), .power_cut_i(plat_in_i.power_cut),
    .module_id_i(plat_in_i.module_id),
    .mapping_generation_i(plat_in_i.mapping_generation),
    .reset_generation_i(plat_in_i.reset_generation),
    .producer_paused_i(plat_in_i.producer_paused),
    .producer_error_i(plat_in_i.producer_error),
    .restore_resume_safe_i(plat_in_i.restore_resume_safe),
    // Per-producer checkpoint pause is a step-2 command path; the boot pause is
    // carried by plat_out.pause_req. Left unconnected until command issuance.
    .producer_pause_o(), .axi_quiesce_o(axi_quiesce), .policy_hold_o(endpoint_hold),
    .initialized_o(initialized), .busy_o(busy), .recovery_locked_o(recovery_locked),
    .checkpoint_valid_o(checkpoint_valid), .metadata_ok_o(metadata_ok),
    .degraded_o(degraded), .checkpoint_generation_o(checkpoint_generation),
    .block_sectors_o(block_sectors), .reserved_bytes_o(reserved_bytes),
    .phase_o(phase), .boot_ready_o(boot_ready),
    .issue_event_o(issue_event), .refuse_event_o(refuse_event),
    .revoke_event_o(revoke_event), .done_event_o(done_event), .error_event_o(error_event),
    .st_req_i(1'b0), .st_we_i(1'b0), .st_gnt_o(),
    .st_addr_i('0), .st_wdata_i('0), .st_be_i('0),
    .st_rvalid_o(), .st_error_o(), .st_rdata_o(),
    .st_flush_req_i(1'b0), .st_flush_ack_o(), .st_flush_error_o()
  );

  // Global pause request: hold the hart until the endpoint is initialized and
  // idle AND the committed policy no longer requires quiescence.
  assign plat_out_o = '{
    pause_req: !initialized || busy || policy_quiesce || rec_hold,
    policy_quiesce: policy_quiesce,
    update_ready: update_ready_w,
    policy_ready: policy_ready,
    policy_epoch: policy_epoch,
    policy_revoked: policy_revoked,
    initialized: initialized,
    busy: busy,
    recovery_locked: recovery_locked,
    checkpoint_valid: checkpoint_valid,
    metadata_ok: metadata_ok,
    axi_quiesce: axi_quiesce,
    checkpoint_generation: checkpoint_generation,
    phase: phase,
    boot_ready: boot_ready,
    recovery_active: rec_active,
    recovery_failed: rec_failed,
    events: '{
      issue: issue_event, refuse: refuse_event, revoke: revoke_event,
      done: done_event, error: error_event,
      policy_commit: policy_commit, policy_revoke: policy_revoke,
      policy_exhaust: policy_exhaust, policy_reject: policy_reject}};

  // Unused endpoint status is observable only inside the composition for now.
  // pragma translate_off
  initial begin
    if (Active) $display("[native_ckpt] NumIngress=%0d NumProviders=%0d NumProducers=%0d",
                         NumIngress, NumProviders, NumProducers);
  end
  // pragma translate_on
endmodule
