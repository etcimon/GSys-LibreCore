// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Candidate post-crossbar route to the checkpoint service, not native activation.
// The high ID bits must be inserted by the interconnect, never by its requester.
module g6lc_storamic_checkpoint_route #(
  parameter bit Enable = 1'b0,
  parameter int unsigned LocalIdWidth = 4,
  parameter int unsigned NumMasters = 3,
  parameter int unsigned TrustedMaster = 0,
  parameter int unsigned IdWidth = LocalIdWidth + $clog2(NumMasters > 1 ? NumMasters : 2),
  parameter logic [63:0] Base = 64'h5000_0000,
  parameter logic [3:0] DataCache = axi_pkg::CACHE_MODIFIABLE,
  // ST-037C IO-only role: 0 disables the control page (it answers DECERR like
  // the reserved pages) and suppresses every source_ok candidate, since the
  // candidate window is exactly the control page.
  parameter bit CtrlPageEn = 1'b1,
  parameter type req_t = logic,
  parameter type resp_t = logic
) (
  input logic clk_i, rst_ni,
  input req_t req_i,
  output resp_t resp_o,
  input logic policy_ready_i,
  input logic [31:0] policy_epoch_i,
  output g6lc_storamic_pkg::axil_req_t ctrl_req_o,
  input g6lc_storamic_pkg::axil_resp_t ctrl_resp_i,
  output g6lc_storamic_pkg::axil_req_t vctrl_req_o,
  input g6lc_storamic_pkg::axil_resp_t vctrl_resp_i,
  output logic service_enable_o, aw_authorized_o, ar_authorized_o, policy_hold_o,
  output logic aw_source_ok_o, ar_source_ok_o
);
  function automatic bit shapes_legal();
    req_t request_shape;
    resp_t response_shape;
    return $bits(request_shape.aw.id) == IdWidth && $bits(request_shape.ar.id) == IdWidth &&
        $bits(response_shape.b.id) == IdWidth && $bits(response_shape.r.id) == IdWidth &&
        $bits(request_shape.aw.addr) == 64 && $bits(request_shape.ar.addr) == 64 &&
        $bits(request_shape.w.data) == 64 && $bits(request_shape.w.strb) == 8 &&
        $bits(response_shape.r.data) == 64;
  endfunction
  localparam bit ConfigLegal = LocalIdWidth > 0 && LocalIdWidth < 64 &&
      NumMasters >= 2 && TrustedMaster < NumMasters && IdWidth <= 64 &&
      IdWidth == LocalIdWidth + $clog2(NumMasters) && Base[11:0] == 0 &&
      Base <= 64'hFFFF_FFFF_FFF0_0000 && shapes_legal();
  logic write_owned_q, read_owned_q, write_allowed_q, read_allowed_q;
  logic write_revoked_q, read_revoked_q;
  logic write_source_q, read_source_q;
  logic [31:0] write_epoch_q, read_epoch_q;
  logic aw_candidate, ar_candidate;

  // Exact word, nonexclusive, uncached scalar-data packets only. AXI PROT is
  // meaningful here only together with the independently inserted master prefix.
  // cache must equal DataCache — the exact value the qualified CPU emits for
  // uncached scalar data (axi_shim drives CACHE_MODIFIABLE). Alloc/bufferable
  // variants and the cache==0 form the component bench used to drive are all
  // refused here; only the native CPU's real encoding is admitted.
  assign aw_candidate = CtrlPageEn &&
      (64'(req_i.aw.id) >> LocalIdWidth) == 64'(TrustedMaster) &&
      req_i.aw.prot == 3'b001 && req_i.aw.cache == DataCache && !req_i.aw.lock &&
      req_i.aw.len == 0 && req_i.aw.size == 2 && req_i.aw.atop == 0 &&
      req_i.aw.burst <= 1 && req_i.aw.addr[1:0] == 0 &&
      req_i.aw.addr >= Base && req_i.aw.addr - Base < 64'h1000;
  assign ar_candidate = CtrlPageEn &&
      (64'(req_i.ar.id) >> LocalIdWidth) == 64'(TrustedMaster) &&
      req_i.ar.prot == 3'b001 && req_i.ar.cache == DataCache && !req_i.ar.lock &&
      req_i.ar.len == 0 && req_i.ar.size == 2 && req_i.ar.burst <= 1 &&
      req_i.ar.addr[1:0] == 0 &&
      req_i.ar.addr >= Base && req_i.ar.addr - Base < 64'h1000;
  // source_ok reports the pure structural candidate captured at acceptance,
  // independent of Enable/policy/epoch: it stays observable even when the
  // service is disabled, while authorized stays gated on service_enable.
  assign aw_source_ok_o = write_owned_q && write_source_q;
  assign ar_source_ok_o = read_owned_q && read_source_q;
  // Unknown/missing provider or descriptor values must not escape as an X
  // authorization that a downstream procedural condition could treat as granted.
  always_comb begin
    service_enable_o = 1'b0;
    aw_authorized_o = 1'b0;
    ar_authorized_o = 1'b0;
    if (ConfigLegal && Enable && policy_ready_i) begin
      service_enable_o = 1'b1;
      if (write_owned_q && write_allowed_q && !write_revoked_q &&
          write_epoch_q == policy_epoch_i) aw_authorized_o = 1'b1;
      if (read_owned_q && read_allowed_q && !read_revoked_q &&
          read_epoch_q == policy_epoch_i) ar_authorized_o = 1'b1;
    end
  end
  assign policy_hold_o = write_owned_q || read_owned_q;

  // This bridge admits one AW through B, and one AR through final R. Ownership
  // therefore matches these sideband slots without an ID-less AW/W re-pairing.
  g6lc_storamic_ctrl_bridge #(
    .AddrWidth(64), .DataWidth(64), .IdWidth(IdWidth), .UserWidth($bits(req_i.w.user)),
    .Base(Base), .CtrlPageEn(CtrlPageEn), .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) bridge (
    .clk_i, .rst_ni, .axi_req_i(req_i), .axi_resp_o(resp_o),
    .ctrl_req_o, .ctrl_resp_i, .vctrl_req_o, .vctrl_resp_i
  );
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_owned_q <= 0; read_owned_q <= 0;
      write_allowed_q <= 0; read_allowed_q <= 0;
      write_revoked_q <= 0; read_revoked_q <= 0;
      write_source_q <= 0; read_source_q <= 0;
      write_epoch_q <= 0; read_epoch_q <= 0;
    end else begin
      if (write_owned_q && (!service_enable_o || write_epoch_q != policy_epoch_i))
        write_revoked_q <= 1;
      if (read_owned_q && (!service_enable_o || read_epoch_q != policy_epoch_i))
        read_revoked_q <= 1;
      if (resp_o.b_valid && req_i.b_ready) begin
        write_owned_q <= 0; write_source_q <= 0;
      end
      if (resp_o.r_valid && req_i.r_ready && resp_o.r.last) begin
        read_owned_q <= 0; read_source_q <= 0;
      end
      if (req_i.aw_valid && resp_o.aw_ready) begin
        write_owned_q <= 1; write_allowed_q <= service_enable_o && aw_candidate;
        write_source_q <= aw_candidate;
        write_epoch_q <= policy_epoch_i; write_revoked_q <= 0;
      end
      if (req_i.ar_valid && resp_o.ar_ready) begin
        read_owned_q <= 1; read_allowed_q <= service_enable_o && ar_candidate;
        read_source_q <= ar_candidate;
        read_epoch_q <= policy_epoch_i; read_revoked_q <= 0;
      end
    end
  end
  // pragma translate_off
  initial if (!ConfigLegal) $fatal(1, "STORAMIC_CHECKPOINT_ROUTE_CONFIG");
  // pragma translate_on
endmodule
