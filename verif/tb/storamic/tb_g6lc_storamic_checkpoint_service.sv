// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Authorization/transaction ownership only; the observer is not a persistence
// or platform privilege provider. Full native binding remains independently gated.
module tb_g6lc_storamic_checkpoint_service;
  import g6lc_storamic_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  axil_req_t req;
  axil_resp_t resp;
  logic enable = 0, aw_auth = 1, ar_auth = 1, command_ready = 1;
  logic [31:0] epoch = 7, command_cookie;
  logic command, restoring, authorized, ack, policy_hold;
  logic result_valid = 0;
  logic [31:0] result_cookie = 32'h99;
  logic [63:0] generation = 64'h1234_5678_89AB_CDEF;
  int checks = 0, commands = 0, grants = 0, acks = 0;
  logic [31:0] last_cookie;
  logic last_restore, last_authorized;
  g6lc_storamic_checkpoint_service dut (
    .clk_i(clk), .rst_ni(rst_n), .req_i(req), .resp_o(resp),
    .service_enable_i(enable), .aw_authorized_i(aw_auth), .ar_authorized_i(ar_auth),
    .command_admit_i(1'b1),
    .policy_epoch_i(epoch), .command_valid_o(command), .command_restore_o(restoring),
    .command_authorized_o(authorized), .command_cookie_o(command_cookie),
    .command_ready_i(command_ready), .result_valid_i(result_valid),
    .result_cookie_i(result_cookie), .result_i(CP_OK), .result_ready_o(ack),
    .initialized_i(1'b1), .busy_i(1'b0), .recovery_locked_i(1'b0),
    .metadata_ok_i(1'b1), .protection_ok_i(1'b1), .checkpoint_valid_i(1'b1),
    .checkpoint_generation_i(generation), .issue_event_o(), .refuse_event_o(), .revoke_event_o(),
    .policy_hold_o(policy_hold)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      commands <= 0; grants <= 0; acks <= 0; last_cookie <= 0;
      last_restore <= 0; last_authorized <= 0;
    end else begin
      if (command && command_ready) begin
        commands <= commands + 1;
        if (authorized) grants <= grants + 1;
        last_cookie <= command_cookie; last_restore <= restoring; last_authorized <= authorized;
      end
      if (ack) acks <= acks + 1;
    end
  end
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_SERVICE_FAIL %s", label);
  endtask
  task automatic aw(input logic [63:0] address);
    req.aw = '0; req.aw.addr = address; req.aw_valid = 1;
    do @(posedge clk); while (!resp.aw_ready);
    tick(); req.aw_valid = 0; ok(policy_hold, "AW-owns-policy");
  endtask
  task automatic w(input logic [31:0] value, input logic [3:0] strb = 4'hF);
    req.w.data = value; req.w.strb = strb; req.w_valid = 1;
    do @(posedge clk); while (!resp.w_ready);
    tick(); req.w_valid = 0; ok(policy_hold, "W-owns-policy");
  endtask
  task automatic b(input logic [1:0] expected);
    while (!resp.b_valid) tick();
    ok(resp.b.resp == expected, "owned-write-response");
  endtask
  task automatic retire_b;
    req.b_ready = 1; tick(); req.b_ready = 0; tick();
  endtask
  task automatic write_word(input logic [63:0] address, input logic [31:0] value,
                            input logic [1:0] expected);
    aw(address); w(value); b(expected); retire_b();
  endtask
  task automatic ar(input logic [63:0] address);
    req.ar = '0; req.ar.addr = address; req.ar_valid = 1;
    do @(posedge clk); while (!resp.ar_ready);
    tick(); req.ar_valid = 0;
    while (!resp.r_valid) tick();
  endtask
  task automatic retire_r;
    req.r_ready = 1; tick(); req.r_ready = 0; tick();
  endtask
  task automatic read_word(input logic [63:0] address, input logic [31:0] value,
                           input logic [1:0] expected);
    ar(address); ok(resp.r.resp == expected && resp.r.data == value, "owned-read-response");
    retire_r();
  endtask
  initial begin
    req = '0;
    repeat (3) tick(); rst_n = 1; tick();
    write_word(0, 1, 2); read_word('h10, 0, 2);
    ok(commands == 0 && acks == 0, "disabled-service-has-no-control-effects");
    enable = 1;

    aw_auth = 0; aw(0); aw_auth = 1; w('h11); b(2); retire_b();
    ok(commands == 0, "AW-denial-does-not-use-later-authorization");
    aw(0); aw_auth = 0; w('h12); b(0);
    command_ready = 0;
    repeat (4) begin
      tick(); ok(command && command_cookie == 'h12 && !restoring && authorized &&
                 resp.b_valid && resp.b.resp == 0, "command-and-B-retain-owned-frame");
    end
    command_ready = 1; tick(); retire_b();
    ok(commands == 1 && grants == 1 && last_cookie == 'h12 && !last_restore,
       "AW-authorization-survives-unrelated-live-channel");
    w('h21); aw_auth = 0; aw(4); b(2); retire_b();
    ok(commands == 1, "W-first-does-not-authorize-AW");
    w('h22); aw_auth = 1; aw(4); b(0); retire_b();
    ok(commands == 2 && grants == 2 && last_restore && last_cookie == 'h22,
       "authorized-W-first-restore");

    aw(0); epoch = 8; tick(); epoch = 7; tick();
    w('h33); b(2); retire_b();
    ok(commands == 2, "pending-AW-policy-ABA-stays-revoked");
    aw(0); w('h44); b(0); command_ready = 0;
    epoch = 8; tick(); epoch = 7; tick();
    ok(command && !authorized && command_cookie == 'h44, "queued-command-ABA-retains-denied-owner");
    command_ready = 1; tick(); retire_b();
    ok(commands == 3 && grants == 2 && !last_authorized, "revoked-command-is-not-privileged");
    aw(0); w('h55); b(0); command_ready = 0;
    enable = 0; tick(); enable = 1; tick();
    ok(command && !authorized, "disable-cannot-revive-queued-command");
    command_ready = 1; tick(); retire_b();
    ok(commands == 4 && grants == 2, "disabled-offer-completes-denied");

    aw(0); w('h66, 4'h7); b(2); retire_b();
    write_word(1, 'h66, 2); write_word('h100, 'h66, 2);
    ok(commands == 4, "partial-or-unknown-writes-cannot-issue");
    result_valid = 1;
    write_word(8, 'h98, 2); ok(acks == 0, "wrong-result-cookie-does-not-consume");
    aw_auth = 0; write_word(8, 'h99, 2); aw_auth = 1;
    ok(acks == 0, "unauthorized-ack-does-not-consume");
    aw(8); w('h99); b(0); ok(ack, "matching-result-consume-pulse"); retire_b();
    ok(acks == 1, "exactly-one-result-consume"); result_valid = 0;

    ar_auth = 0; read_word('h14, 0, 2); ar_auth = 1;
    ar('h14);
    result_cookie = 'h88; ar_auth = 0;
    repeat (4) begin
      tick(); ok(resp.r_valid && resp.r.resp == 0 && resp.r.data == 'h99, "read-snapshot-backpressure");
    end
    retire_r(); ar_auth = 1;
    read_word('h24, 0, 2);
    read_word('h20, 32'h89AB_CDEF, 0);
    generation = 64'hFFFF_FFFE_7654_3210;
    read_word('h24, 32'h1234_5678, 0);
    epoch = 8; tick(); epoch = 7; tick();
    read_word('h24, 0, 2);
    read_word('h20, 32'h7654_3210, 0); read_word('h24, 32'hFFFF_FFFE, 0);
    read_word('h1C, 0, 2);

    req.aw.addr = 0; req.aw_valid = 1; req.w.data = 'h77; req.w.strb = '1; req.w_valid = 1;
    @(posedge clk); ok(resp.aw_ready && resp.w_ready, "simultaneous-AW-W");
    tick(); req.aw_valid = 0; req.w_valid = 0; b(0);
    repeat (3) begin tick(); ok(resp.b_valid && resp.b.resp == 0, "held-B-is-not-reissued"); end
    retire_b();
    ok(commands == 5 && grants == 3 && last_cookie == 'h77, "one-command-per-complete-packet");
    aw(0); rst_n = 0; req = '0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    ok(!command && !resp.b_valid && !resp.r_valid && acks == 0, "common-reset-cancels-partial-frame");
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_SERVICE_PASS checks=%0d", checks);
    $finish;
  end
  initial begin #100000; $fatal(1, "CHECKPOINT_SERVICE_TIMEOUT"); end
endmodule
