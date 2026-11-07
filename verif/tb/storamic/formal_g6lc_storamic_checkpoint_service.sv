// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Bus-observed transaction scoreboard. No source stability/authorization/epoch
// assumptions: even payloads changing while not accepted cannot gain ownership.
module formal_g6lc_storamic_checkpoint_service #(
  parameter bit OracleNegative = 0
) (
  input logic clk_i, rst_ni,
  input g6lc_storamic_pkg::axil_req_t req_i,
  input logic enable_i, admit_i, aw_auth_i, ar_auth_i,
  input logic [31:0] epoch_i,
  input logic ready_i, result_valid_i,
  input logic [31:0] result_cookie_i,
  input g6lc_storamic_pkg::checkpoint_result_e result_i,
  input logic initialized_i, busy_i, locked_i, metadata_i, protection_i, valid_i,
  input logic [63:0] generation_i,
  output logic cover_command_o, cover_revoked_o, cover_ack_o
);
  import g6lc_storamic_pkg::*;
  axil_resp_t resp;
  logic command, restoring, authorized, ack, policy_hold;
  logic [31:0] cookie;
  g6lc_storamic_checkpoint_service dut (
    .clk_i, .rst_ni, .req_i, .resp_o(resp), .service_enable_i(enable_i),
    .aw_authorized_i(aw_auth_i), .ar_authorized_i(ar_auth_i), .policy_epoch_i(epoch_i),
    .command_admit_i(admit_i),
    .command_valid_o(command), .command_restore_o(restoring), .command_authorized_o(authorized),
    .command_cookie_o(cookie), .command_ready_i(ready_i), .result_valid_i,
    .result_cookie_i, .result_i, .result_ready_o(ack), .initialized_i, .busy_i,
    .recovery_locked_i(locked_i), .metadata_ok_i(metadata_i), .protection_ok_i(protection_i),
    .checkpoint_valid_i(valid_i), .checkpoint_generation_i(generation_i),
    .issue_event_o(), .refuse_event_o(), .revoke_event_o(), .policy_hold_o(policy_hold)
  );
  logic aw_seen, w_seen, executed, aw_granted, aw_revoked, expected_ack;
  logic [63:0] address;
  logic [31:0] aw_epoch, data;
  logic [3:0] strb;
  logic [1:0] expected_b;
  logic cmd_pending, cmd_restore, cmd_revoked;
  logic [31:0] cmd_cookie, cmd_epoch;
  logic read_pending;
  logic [31:0] expected_data;
  logic [1:0] expected_r;
  logic gen_valid, gen_revoked;
  logic [63:0] gen_snapshot;
  logic [31:0] gen_epoch;
  logic permitted, creates_command, consumes_result;
  logic command_admitted;
  logic initialized = 0;
  always_ff @(posedge clk_i) begin
    initialized <= 1;
    if (!initialized) assume (!rst_ni);
  end
  assign permitted = enable_i && aw_granted && !aw_revoked && aw_epoch == epoch_i && (&strb);
  assign creates_command = permitted && command_admitted && (address == 0 || address == 4) &&
                           !cmd_pending && ready_i && !result_valid_i;
  assign consumes_result = permitted && address == 8 &&
                           result_valid_i && result_cookie_i == data;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_seen <= 0; w_seen <= 0; executed <= 0; aw_granted <= 0; aw_revoked <= 0;
      expected_ack <= 0; address <= 0; aw_epoch <= 0; data <= 0; strb <= 0; expected_b <= 0;
      cmd_pending <= 0; cmd_restore <= 0; cmd_revoked <= 0; cmd_cookie <= 0; cmd_epoch <= 0;
      read_pending <= 0; expected_data <= 0; expected_r <= 0;
      gen_valid <= 0; gen_revoked <= 0; gen_snapshot <= 0; gen_epoch <= 0;
      cover_command_o <= 0; cover_revoked_o <= 0; cover_ack_o <= 0;
      command_admitted <= 0;
    end else begin
      assert (resp.aw_ready == (!aw_seen && !executed));
      assert (resp.w_ready == (!w_seen && !executed));
      assert (resp.b_valid == executed);
      if (executed) assert (resp.b.resp == expected_b);
      assert (resp.ar_ready == !read_pending);
      assert (resp.r_valid == read_pending);
      if (read_pending) assert (resp.r.data == expected_data && resp.r.resp == expected_r);
      assert (ack == expected_ack);
      assert (command == cmd_pending);
      assert (policy_hold == (aw_seen || w_seen || executed || read_pending ||
                             cmd_pending || busy_i || result_valid_i || ack));
      cover (cover_command_o);
      cover (cover_revoked_o);
      cover (cover_ack_o);
      if (cmd_pending) begin
        assert (cookie == cmd_cookie && restoring == cmd_restore);
        assert (authorized == (enable_i && !cmd_revoked && cmd_epoch == epoch_i));
      end
      if (OracleNegative) assert (!command);
      expected_ack <= 0;
      if (req_i.aw_valid && resp.aw_ready) begin
        aw_seen <= 1; address <= req_i.aw.addr;
        aw_granted <= aw_auth_i && enable_i; aw_epoch <= epoch_i; aw_revoked <= 0;
        command_admitted <= admit_i;
      end
      if (req_i.w_valid && resp.w_ready) begin
        w_seen <= 1; data <= req_i.w.data; strb <= req_i.w.strb;
      end
      if (aw_seen && (aw_epoch != epoch_i || !enable_i)) aw_revoked <= 1;
      if (cmd_pending && (cmd_epoch != epoch_i || !enable_i)) cmd_revoked <= 1;
      if (cmd_pending && ready_i) begin
        cmd_pending <= 0;
        if (authorized) cover_command_o <= 1;
        else cover_revoked_o <= 1;
      end
      if (resp.b_valid && req_i.b_ready) begin
        executed <= 0; aw_seen <= 0; w_seen <= 0;
      end
      if (aw_seen && w_seen && !executed) begin
        executed <= 1;
        expected_b <= creates_command || consumes_result ? 2'b00 : RespSlvErr;
        expected_ack <= consumes_result;
        if (creates_command) begin
          cmd_pending <= 1; cmd_cookie <= data; cmd_restore <= address == 4;
          cmd_epoch <= aw_epoch; cmd_revoked <= 0;
        end
        if (consumes_result) cover_ack_o <= 1;
      end
      if (gen_valid && (gen_epoch != epoch_i || !enable_i)) gen_revoked <= 1;
      if (read_pending && req_i.r_ready) read_pending <= 0;
      if (req_i.ar_valid && resp.ar_ready) begin
        read_pending <= 1; expected_data <= 0; expected_r <= RespSlvErr;
        if (enable_i && ar_auth_i) begin
          expected_r <= 0;
          case (req_i.ar.addr)
            'h10: expected_data <= {24'd0, valid_i, protection_i, metadata_i, initialized_i,
                                   locked_i, busy_i, result_valid_i, admit_i && ready_i && !cmd_pending};
            'h14: expected_data <= result_cookie_i;
            'h18: expected_data <= 32'(result_i);
            'h20: begin
              expected_data <= generation_i[31:0]; gen_snapshot <= generation_i;
              gen_epoch <= epoch_i; gen_valid <= 1; gen_revoked <= 0;
            end
            'h24: begin
              if (gen_valid && !gen_revoked && gen_epoch == epoch_i)
                expected_data <= gen_snapshot[63:32];
              else expected_r <= RespSlvErr;
            end
            default: expected_r <= RespSlvErr;
          endcase
        end
      end
    end
  end
endmodule
