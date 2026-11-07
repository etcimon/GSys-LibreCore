// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module formal_g6lc_storamic_checkpoint_route (
  clk_i, rst_ni, req_i, ctrl_resp_i, vctrl_resp_i, policy_ready_i, policy_epoch_i,
  response, control, virtio, enabled, aw_auth, ar_auth, hold_policy
);
  import g6lc_storamic_pkg::*;
  parameter bit Enabled = 1, BadOracle = 0;
  localparam int unsigned IdW = 6;
  localparam logic [63:0] Base = 64'h5000_0000;
  `include "route-axi-types.svh"
  input logic clk_i, rst_ni, policy_ready_i;
  input logic [31:0] policy_epoch_i;
  input req_t req_i;
  input axil_resp_t ctrl_resp_i, vctrl_resp_i;
  output resp_t response;
  output axil_req_t control, virtio;
  output logic enabled, aw_auth, ar_auth, hold_policy;
  g6lc_storamic_checkpoint_route #(
    .Enable(Enabled), .LocalIdWidth(4), .NumMasters(3), .TrustedMaster(0),
    .IdWidth(IdW), .Base(Base), .req_t(req_t), .resp_t(resp_t)
  ) dut (
    .clk_i, .rst_ni, .req_i, .resp_o(response), .policy_ready_i, .policy_epoch_i,
    .ctrl_req_o(control), .ctrl_resp_i, .vctrl_req_o(virtio), .vctrl_resp_i,
    .service_enable_o(enabled), .aw_authorized_o(aw_auth),
    .ar_authorized_o(ar_auth), .policy_hold_o(hold_policy)
  );
  // Reference lifetime comes only from upstream channel handshakes, not DUT state.
  logic w_owned = 0, r_owned = 0, w_source = 0, r_source = 0;
  logic w_poison = 0, r_poison = 0;
  logic [31:0] w_epoch = 0, r_epoch = 0;
  logic past_valid = 0;
  always @(posedge clk_i) begin
    past_valid <= 1;
    if (!past_valid) assume(!rst_ni);
    if (!rst_ni) begin
      w_owned <= 0; r_owned <= 0; w_source <= 0; r_source <= 0;
      w_poison <= 0; r_poison <= 0; w_epoch <= 0; r_epoch <= 0;
    end else begin
      if (response.b_valid && req_i.b_ready) w_owned <= 0;
      if (response.r_valid && req_i.r_ready && response.r.last) r_owned <= 0;
      if (w_owned && (!policy_ready_i || w_epoch != policy_epoch_i)) w_poison <= 1;
      if (r_owned && (!policy_ready_i || r_epoch != policy_epoch_i)) r_poison <= 1;
      if (req_i.aw_valid && response.aw_ready) begin
        w_owned <= 1; w_epoch <= policy_epoch_i; w_poison <= 0;
        w_source <= Enabled && policy_ready_i && req_i.aw.id[5:4] == 0 &&
                    req_i.aw.prot == 1;
      end
      if (req_i.ar_valid && response.ar_ready) begin
        r_owned <= 1; r_epoch <= policy_epoch_i; r_poison <= 0;
        r_source <= Enabled && policy_ready_i && req_i.ar.id[5:4] == 0 &&
                    req_i.ar.prot == 1;
      end
    end
    if (past_valid && rst_ni && $past(rst_ni)) begin
      // B is passed through the bridge. Each trusted downstream AXI-Lite
      // responder must hold an offered response until the bridge consumes it.
      if ($past(ctrl_resp_i.b_valid && !control.b_ready))
        assume(ctrl_resp_i.b_valid && ctrl_resp_i.b == $past(ctrl_resp_i.b));
      if ($past(vctrl_resp_i.b_valid && !virtio.b_ready))
        assume(vctrl_resp_i.b_valid && vctrl_resp_i.b == $past(vctrl_resp_i.b));
      assert(hold_policy == (w_owned || r_owned));
      assert(enabled == (Enabled && policy_ready_i));
      if (aw_auth) begin
        assert(w_owned && w_source && !w_poison && policy_ready_i && w_epoch == policy_epoch_i);
      end
      if (ar_auth) begin
        assert(r_owned && r_source && !r_poison && policy_ready_i && r_epoch == policy_epoch_i);
      end
      if ($past(response.b_valid && !req_i.b_ready))
        assert(response.b_valid && response.b == $past(response.b));
      if ($past(response.r_valid && !req_i.r_ready))
        assert(response.r_valid && response.r == $past(response.r));
      if (!Enabled) assert(!aw_auth && !ar_auth);
      if (BadOracle) assert(!aw_auth);
      if (Enabled) begin
        cover(control.aw_valid && ctrl_resp_i.aw_ready && aw_auth);
        cover(control.aw_valid && ctrl_resp_i.aw_ready && w_owned && !w_source);
        cover(w_owned && w_source && w_poison && w_epoch == policy_epoch_i && policy_ready_i);
        cover(control.ar_valid && ctrl_resp_i.ar_ready && ar_auth);
      end
    end
  end
endmodule
