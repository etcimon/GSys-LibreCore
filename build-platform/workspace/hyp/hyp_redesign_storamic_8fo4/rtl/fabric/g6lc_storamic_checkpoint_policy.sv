// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Platform-owned policy publication, not a requester-accessible unlock CSR.
// All owners/providers share clk_i and the common reset with route/endpoint.
module g6lc_storamic_checkpoint_policy #(
  parameter bit Enable = 1'b0,
  parameter int unsigned NumIngress = 1,
  parameter int unsigned NumProviders = 5,
  parameter int unsigned EpochWidth = 32,
  parameter type policy_t = logic [255:0]
) (
  input logic clk_i, rst_ni,
  input logic update_valid_i,
  output logic update_ready_o,
  input policy_t update_policy_i,
  input logic [NumProviders-1:0] providers_ready_i,
  input logic [NumIngress-1:0] ingress_present_i, ingress_quiesced_i, ingress_hold_i,
  input logic route_hold_i, endpoint_hold_i, maintenance_hold_i,
  output logic quiesce_o, command_admit_o, policy_ready_o,
  output policy_t policy_o,
  output logic [EpochWidth-1:0] policy_epoch_o,
  output logic pending_o, revoked_o, exhausted_o,
  output logic commit_event_o, revoke_event_o, exhaust_event_o, reject_event_o
);
  localparam bit ConfigLegal = NumIngress >= 1 && NumIngress <= 32 &&
      NumProviders >= 1 && NumProviders <= 32 && EpochWidth >= 2 && EpochWidth <= 64;
  logic pending_q, valid_q, revoked_q, exhausted_q, drained_q, offer_revoked_q;
  logic [EpochWidth-1:0] epoch_q;
  policy_t active_q, offered_q;
  logic providers_ok, all_drained;

  // Procedural defaults deny unknown/missing providers and owner observations.
  always_comb begin
    providers_ok = 0;
    all_drained = 0;
    if ((&providers_ready_i) && (&ingress_present_i)) providers_ok = 1;
    if ((&ingress_quiesced_i) && ingress_hold_i == '0 &&
        !route_hold_i && !endpoint_hold_i && !maintenance_hold_i) all_drained = 1;
    update_ready_o = 0;
    policy_ready_o = 0;
    command_admit_o = 0;
    quiesce_o = 1;
    if (ConfigLegal && Enable && !exhausted_q) begin
      update_ready_o = !pending_q && providers_ok;
      if (valid_q && !revoked_q && providers_ok) policy_ready_o = 1;
      if (policy_ready_o && !pending_q) begin
        quiesce_o = 0;
        command_admit_o = 1;
      end
    end
  end
  assign policy_o = ConfigLegal && Enable ? active_q : '0;
  assign policy_epoch_o = ConfigLegal && Enable ? epoch_q : '0;
  // Inactive status is structural, independent of reset-only state lowering.
  assign pending_o = ConfigLegal && Enable ? pending_q : 1'b0;
  assign revoked_o = ConfigLegal && Enable ? revoked_q : 1'b0;
  assign exhausted_o = ConfigLegal && Enable ? exhausted_q : 1'b0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q <= 0; valid_q <= 0; revoked_q <= 0; exhausted_q <= 0; drained_q <= 0;
      offer_revoked_q <= 0;
      epoch_q <= '0; active_q <= '0; offered_q <= '0;
      commit_event_o <= 0; revoke_event_o <= 0; exhaust_event_o <= 0; reject_event_o <= 0;
    end else begin
      commit_event_o <= 0; revoke_event_o <= 0; exhaust_event_o <= 0; reject_event_o <= 0;
      drained_q <= 0;
      if (ConfigLegal && Enable) begin
        if (valid_q && !providers_ok) begin
          revoked_q <= 1;
          if (!revoked_q) revoke_event_o <= 1;
        end
        if (update_valid_i && update_ready_o) begin
          offered_q <= update_policy_i;
          pending_q <= 1;
          offer_revoked_q <= 0;
        end
        if (pending_q && !providers_ok) offer_revoked_q <= 1;
        // Two consecutive observations after requesting quiescence. Ingress
        // acknowledgements promise no further policy-owned arrivals, including
        // late AW/W partners. Completion/ACK traffic must drain before that ACK.
        if (pending_q && all_drained && (providers_ok || offer_revoked_q)) begin
          drained_q <= 1;
          if (drained_q) begin
            pending_q <= 0;
            drained_q <= 0;
            if (offer_revoked_q) begin
              reject_event_o <= 1;
            end else if (&epoch_q) begin
              exhausted_q <= 1; valid_q <= 0; revoked_q <= 1;
              exhaust_event_o <= 1;
            end else begin
              active_q <= offered_q;
              epoch_q <= epoch_q + 1'b1;
              valid_q <= 1; revoked_q <= 0;
              commit_event_o <= 1;
            end
          end
        end
      end
    end
  end
  // pragma translate_off
  initial if (!ConfigLegal) $fatal(1, "STORAMIC_CHECKPOINT_POLICY_CONFIG");
  // pragma translate_on
endmodule
