// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Unrestricted Boolean provider/owner inputs: no constant-ready assumptions.
module formal_g6lc_storamic_checkpoint_policy #(
  parameter bit Enabled = 1,
  parameter bit OracleNegative = 0
) (
  input logic clk_i, rst_ni, update_i,
  input logic [7:0] policy_i,
  input logic [1:0] providers_i, present_i, quiesced_i, hold_i,
  input logic route_i, endpoint_i, maintenance_i,
  output logic cover_commit_o, cover_revoke_o, cover_blocked_o, cover_exhaust_o, cover_reject_o
);
  logic ready, active, admit, quiesce, pending, revoked, exhausted, commit_event, revoke_event, exhaust_event;
  logic reject_event, captured_revoked;
  logic [1:0] epoch;
  logic [7:0] policy;
  g6lc_storamic_checkpoint_policy #(
    .Enable(Enabled), .NumIngress(2), .NumProviders(2), .EpochWidth(2), .policy_t(logic [7:0])
  ) dut (
    .clk_i, .rst_ni, .update_valid_i(update_i), .update_ready_o(ready),
    .update_policy_i(policy_i), .providers_ready_i(providers_i),
    .ingress_present_i(present_i), .ingress_quiesced_i(quiesced_i), .ingress_hold_i(hold_i),
    .route_hold_i(route_i), .endpoint_hold_i(endpoint_i), .maintenance_hold_i(maintenance_i),
    .quiesce_o(quiesce), .command_admit_o(admit), .policy_ready_o(active),
    .policy_o(policy), .policy_epoch_o(epoch), .pending_o(pending),
    .revoked_o(revoked), .exhausted_o(exhausted), .commit_event_o(commit_event),
    .revoke_event_o(revoke_event), .exhaust_event_o(exhaust_event), .reject_event_o(reject_event)
  );
  logic past_valid, past_idle, past_pending, past_qualified, past_exhausted, past_revoked;
  logic [1:0] old_epoch;
  logic [7:0] old_policy, captured;
  logic qualified, idle;
  logic initialized = 0;
  always_ff @(posedge clk_i) begin
    initialized <= 1;
    if (!initialized) assume (!rst_ni);
  end
  assign qualified = (&providers_i) && (&present_i);
  assign idle = (&quiesced_i) && hold_i == 0 && !route_i && !endpoint_i && !maintenance_i;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      past_valid <= 0; past_idle <= 0; past_pending <= 0; past_qualified <= 0;
      past_exhausted <= 0; past_revoked <= 0; old_epoch <= 0; old_policy <= 0; captured <= 0;
      cover_commit_o <= 0; cover_revoke_o <= 0; cover_blocked_o <= 0; cover_exhaust_o <= 0;
      cover_reject_o <= 0; captured_revoked <= 0;
    end else begin
      assert (admit == !quiesce);
      if (!Enabled) assert (!active && !admit && !ready && epoch == 0 && policy == 0);
      if (!qualified || revoked || exhausted || epoch == 0) assert (!active && !admit);
      if (pending) assert (quiesce && !admit && !ready);
      if (past_valid) begin
        if (!past_pending || !past_idle || !past_qualified) begin
          assert (epoch == old_epoch && policy == old_policy && !commit_event && !exhaust_event);
        end
        if (commit_event) begin
          assert (past_pending && past_idle && past_qualified);
          assert (old_epoch != 3 && epoch == old_epoch + 2'd1 && policy == captured);
          assert (!pending && !revoked && !exhausted);
          assert (!captured_revoked);
        end else assert (epoch == old_epoch && policy == old_policy);
        if (past_revoked && !commit_event) assert (revoked);
        if (past_exhausted) assert (exhausted && epoch == old_epoch && !ready);
      end
      if (exhaust_event) assert (exhausted && revoked && epoch == 3);
      if (OracleNegative) assert (!commit_event);
      if (update_i && ready) begin captured <= policy_i; captured_revoked <= 0; end
      if (pending && !qualified) captured_revoked <= 1;
      if (commit_event) cover_commit_o <= 1;
      if (revoke_event) cover_revoke_o <= 1;
      if (pending && !idle) cover_blocked_o <= 1;
      if (exhaust_event) cover_exhaust_o <= 1;
      if (reject_event) cover_reject_o <= 1;
      cover (cover_commit_o);
      cover (cover_revoke_o);
      cover (cover_blocked_o);
      cover (cover_exhaust_o);
      cover (cover_reject_o);
      past_valid <= 1; past_idle <= idle; past_pending <= pending; past_qualified <= qualified;
      past_exhausted <= exhausted; past_revoked <= revoked;
      old_epoch <= epoch; old_policy <= policy;
    end
  end
endmodule
