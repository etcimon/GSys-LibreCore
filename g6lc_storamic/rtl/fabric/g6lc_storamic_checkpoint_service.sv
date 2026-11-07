// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Policy-bound model control seam, not a qualified native/software PMEM ABI.
// Authorization comes from the transaction's protection-domain provider, never
// AXI PROT alone or a key written by the requester. All ports share clk_i.
module g6lc_storamic_checkpoint_service #(
  parameter logic [63:0] BaseAddr = 0,
  parameter type req_t = g6lc_storamic_pkg::axil_req_t,
  parameter type resp_t = g6lc_storamic_pkg::axil_resp_t
) (
  input logic clk_i, rst_ni,
  input req_t req_i,
  output resp_t resp_o,
  input logic service_enable_i, command_admit_i, aw_authorized_i, ar_authorized_i,
  input logic [31:0] policy_epoch_i,
  output logic command_valid_o, command_restore_o, command_authorized_o,
  output logic [31:0] command_cookie_o,
  input logic command_ready_i,
  input logic result_valid_i,
  input logic [31:0] result_cookie_i,
  input g6lc_storamic_pkg::checkpoint_result_e result_i,
  output logic result_ready_o,
  input logic initialized_i, busy_i, recovery_locked_i,
  input logic metadata_ok_i, protection_ok_i, checkpoint_valid_i,
  input logic [63:0] checkpoint_generation_i,
  output logic issue_event_o, refuse_event_o, revoke_event_o, policy_hold_o
);
  import g6lc_storamic_pkg::*;
  localparam logic [1:0] RespOkay = 2'b00;
  localparam bit ConfigLegal = BaseAddr[1:0] == 0 &&
                               BaseAddr <= 64'hFFFF_FFFF_FFFF_FFDB;
  logic aw_q, w_q, b_q, r_q, aw_auth_q, aw_revoked_q, cmd_q, cmd_restore_q, cmd_revoked_q;
  logic [63:0] aw_addr_q;
  logic [31:0] aw_epoch_q, w_data_q, cmd_cookie_q, cmd_epoch_q, read_data_q;
  logic [3:0] w_strb_q;
  logic [1:0] b_resp_q, r_resp_q;
  logic generation_valid_q, generation_revoked_q;
  logic [63:0] generation_q;
  logic [31:0] generation_epoch_q;
  logic aw_command_admit_q;
  logic write_allowed, read_allowed;
  // Includes split packets and held responses, not just checkpoint execution.
  // The generation cache is epoch-checked, not a perpetual policy lease.
  assign policy_hold_o = aw_q || w_q || b_q || r_q || cmd_q ||
                         busy_i || result_valid_i || result_ready_o;
  assign write_allowed = ConfigLegal && service_enable_i && aw_auth_q &&
                         !aw_revoked_q && aw_epoch_q == policy_epoch_i && (&w_strb_q);
  assign read_allowed = ConfigLegal && service_enable_i && ar_authorized_i;
  assign command_valid_o = cmd_q;
  assign command_cookie_o = cmd_cookie_q;
  assign command_restore_o = cmd_restore_q;
  assign command_authorized_o = service_enable_i && !cmd_revoked_q &&
                                cmd_epoch_q == policy_epoch_i;
  always_comb begin
    resp_o = '0;
    resp_o.aw_ready = !aw_q && !b_q;
    resp_o.w_ready = !w_q && !b_q;
    resp_o.b_valid = b_q;
    resp_o.b.resp = b_resp_q;
    resp_o.ar_ready = !r_q;
    resp_o.r_valid = r_q;
    resp_o.r.data = read_data_q;
    resp_o.r.resp = r_resp_q;
  end
  // pragma translate_off
  initial begin
    if (!ConfigLegal || $bits(req_i.aw.addr) > 64 || $bits(req_i.ar.addr) > 64 ||
        $bits(req_i.w.data) != 32 || $bits(req_i.w.strb) != 4)
      $fatal(1, "STORAMIC_CHECKPOINT_SERVICE_CONFIG");
  end
  // pragma translate_on
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_q <= 0; w_q <= 0; b_q <= 0; r_q <= 0;
      aw_auth_q <= 0; aw_revoked_q <= 0; aw_addr_q <= 0; aw_epoch_q <= 0;
      aw_command_admit_q <= 0;
      w_data_q <= 0; w_strb_q <= 0; b_resp_q <= 0; r_resp_q <= 0; read_data_q <= 0;
      cmd_q <= 0; cmd_restore_q <= 0; cmd_cookie_q <= 0;
      cmd_epoch_q <= 0; cmd_revoked_q <= 0; result_ready_o <= 0;
      generation_valid_q <= 0; generation_q <= 0;
      generation_epoch_q <= 0; generation_revoked_q <= 0;
      issue_event_o <= 0; refuse_event_o <= 0; revoke_event_o <= 0;
    end else begin
      result_ready_o <= 0;
      issue_event_o <= 0; refuse_event_o <= 0; revoke_event_o <= 0;
      if (resp_o.aw_ready && req_i.aw_valid) begin
        aw_q <= 1; aw_addr_q <= 64'(req_i.aw.addr);
        aw_auth_q <= aw_authorized_i && service_enable_i;
        aw_command_admit_q <= command_admit_i;
        aw_epoch_q <= policy_epoch_i; aw_revoked_q <= 0;
      end
      if (resp_o.w_ready && req_i.w_valid) begin
        w_q <= 1; w_data_q <= req_i.w.data; w_strb_q <= req_i.w.strb;
      end
      // Revocation is sticky for an owned packet, including epoch ABA. An
      // offered command is never withdrawn: the coordinator accepts it denied.
      if (aw_q && (aw_epoch_q != policy_epoch_i || !service_enable_i)) aw_revoked_q <= 1;
      if (cmd_q && (cmd_epoch_q != policy_epoch_i || !service_enable_i)) begin
        cmd_revoked_q <= 1;
        if (!cmd_revoked_q) revoke_event_o <= 1;
      end
      if (generation_valid_q && (generation_epoch_q != policy_epoch_i || !service_enable_i))
        generation_revoked_q <= 1;
      if (cmd_q && command_ready_i) begin
        cmd_q <= 0;
        issue_event_o <= command_authorized_o;
      end
      if (b_q && req_i.b_ready) b_q <= 0;
      if (aw_q && w_q && !b_q) begin
        aw_q <= 0; w_q <= 0; b_q <= 1; b_resp_q <= RespSlvErr;
        if (!write_allowed) refuse_event_o <= 1;
        else case (aw_addr_q)
          BaseAddr, BaseAddr + 64'h04: begin
            if (aw_command_admit_q && !cmd_q && command_ready_i && !result_valid_i) begin
              cmd_q <= 1; cmd_restore_q <= aw_addr_q == BaseAddr + 64'h04;
              cmd_cookie_q <= w_data_q; cmd_epoch_q <= aw_epoch_q; cmd_revoked_q <= 0;
              b_resp_q <= RespOkay;
            end else refuse_event_o <= 1;
          end
          BaseAddr + 64'h08: begin
            if (result_valid_i && result_cookie_i == w_data_q) begin
              result_ready_o <= 1; b_resp_q <= RespOkay;
            end else refuse_event_o <= 1;
          end
          default: refuse_event_o <= 1;
        endcase
      end
      if (r_q && req_i.r_ready) r_q <= 0;
      if (resp_o.ar_ready && req_i.ar_valid) begin
        r_q <= 1; read_data_q <= 0; r_resp_q <= RespSlvErr;
        if (!read_allowed) refuse_event_o <= 1;
        else begin
          r_resp_q <= RespOkay;
          case (64'(req_i.ar.addr))
            BaseAddr + 64'h10: read_data_q <= {
                24'd0, checkpoint_valid_i, protection_ok_i, metadata_ok_i, initialized_i,
                recovery_locked_i, busy_i, result_valid_i, command_admit_i && command_ready_i && !cmd_q};
            BaseAddr + 64'h14: read_data_q <= result_cookie_i;
            BaseAddr + 64'h18: read_data_q <= 32'(result_i);
            BaseAddr + 64'h20: begin
              generation_q <= checkpoint_generation_i;
              generation_valid_q <= 1; generation_epoch_q <= policy_epoch_i;
              generation_revoked_q <= 0;
              read_data_q <= checkpoint_generation_i[31:0];
            end
            BaseAddr + 64'h24: begin
              if (generation_valid_q && !generation_revoked_q &&
                  generation_epoch_q == policy_epoch_i) read_data_q <= generation_q[63:32];
              else begin r_resp_q <= RespSlvErr; refuse_event_o <= 1; end
            end
            default: begin r_resp_q <= RespSlvErr; refuse_event_o <= 1; end
          endcase
        end
      end
    end
  end
endmodule
