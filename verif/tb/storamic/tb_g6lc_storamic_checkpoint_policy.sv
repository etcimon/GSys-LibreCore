// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Component owners below are fixtures, never native provider qualification.
module tb_g6lc_storamic_checkpoint_policy;
  import g6lc_storamic_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  logic update = 0, update_ready, quiesce, admit, enabled, pending, revoked, exhausted;
  logic committed, revocation, exhaustion, rejected;
  logic [63:0] offered = 0, policy;
  logic [2:0] epoch;
  logic [4:0] providers = '1;
  logic [1:0] present = '1, quiesced = 0, upstream = 0;
  logic route_hold = 0, maintenance = 0, endpoint_hold;
  axil_req_t req;
  axil_resp_t resp;
  logic command, authorized, accept_command = 1, ack;
  logic [31:0] command_cookie, result_cookie = 0;
  logic busy = 0, result_valid = 0, finish_work = 0;
  logic [31:0] accepted_cookie = 0;
  int checks = 0, commits = 0, executed = 0;
  g6lc_storamic_checkpoint_policy #(
    .Enable(1), .NumIngress(2), .EpochWidth(3), .policy_t(logic [63:0])
  ) manager (
    .clk_i(clk), .rst_ni(rst_n), .update_valid_i(update), .update_ready_o(update_ready),
    .update_policy_i(offered), .providers_ready_i(providers),
    .ingress_present_i(present), .ingress_quiesced_i(quiesced), .ingress_hold_i(upstream),
    .route_hold_i(route_hold), .endpoint_hold_i(endpoint_hold), .maintenance_hold_i(maintenance),
    .quiesce_o(quiesce), .command_admit_o(admit), .policy_ready_o(enabled),
    .policy_o(policy), .policy_epoch_o(epoch), .pending_o(pending), .revoked_o(revoked),
    .exhausted_o(exhausted), .commit_event_o(committed), .revoke_event_o(revocation),
    .exhaust_event_o(exhaustion), .reject_event_o(rejected)
  );
  g6lc_storamic_checkpoint_service service (
    .clk_i(clk), .rst_ni(rst_n), .req_i(req), .resp_o(resp),
    .service_enable_i(enabled), .command_admit_i(admit),
    .aw_authorized_i(1'b1), .ar_authorized_i(1'b1), .policy_epoch_i(32'(epoch)),
    .command_valid_o(command), .command_restore_o(), .command_authorized_o(authorized),
    .command_cookie_o(command_cookie), .command_ready_i(accept_command && !busy && !result_valid),
    .result_valid_i(result_valid), .result_cookie_i(result_cookie), .result_i(CP_OK),
    .result_ready_o(ack), .initialized_i(1'b1), .busy_i(busy), .recovery_locked_i(1'b0),
    .metadata_ok_i(1'b1), .protection_ok_i(1'b1), .checkpoint_valid_i(1'b1),
    .checkpoint_generation_i(64'h1234_5678), .issue_event_o(), .refuse_event_o(),
    .revoke_event_o(), .policy_hold_o(endpoint_hold)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      commits <= 0; executed <= 0; busy <= 0; result_valid <= 0;
      accepted_cookie <= 0; result_cookie <= 0;
    end else begin
      if (committed) commits <= commits + 1;
      if (command && accept_command && !busy && !result_valid) begin
        if (authorized) begin
          busy <= 1; executed <= executed + 1; accepted_cookie <= command_cookie;
        end
      end
      if (finish_work && busy) begin busy <= 0; result_valid <= 1; result_cookie <= accepted_cookie; end
      if (ack) result_valid <= 0;
    end
  end
  task automatic ok(input bit condition, input string name);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_POLICY_FAIL %s epoch=%0d", name, epoch);
  endtask
  task automatic propose(input logic [63:0] value);
    offered = value; update = 1;
    do @(posedge clk); while (!update_ready);
    tick(); update = 0;
  endtask
  task automatic wait_epoch(input logic [2:0] value);
    for (int n = 0; n < 12 && epoch != value; n++) tick();
    ok(epoch == value && !pending && enabled, "trusted-policy-published");
  endtask
  task automatic unchanged(input logic [2:0] expected, input string name);
    repeat (4) begin tick(); ok(epoch == expected && pending && quiesce && !admit, name); end
  endtask
  task automatic aw(input int address);
    req.aw.addr = 64'(address); req.aw_valid = 1;
    do @(posedge clk); while (!resp.aw_ready);
    tick(); req.aw_valid = 0;
  endtask
  task automatic w(input logic [31:0] value);
    req.w.data = value; req.w.strb = '1; req.w_valid = 1;
    do @(posedge clk); while (!resp.w_ready);
    tick(); req.w_valid = 0;
  endtask
  task automatic retire_b(input bit denied = 0);
    while (!resp.b_valid) tick();
    ok(resp.b.resp == (denied ? RespSlvErr : 0), "write-response");
    req.b_ready = 1; tick(); req.b_ready = 0; tick();
  endtask
  task automatic retire_r;
    req.r_ready = 1; tick(); req.r_ready = 0; tick();
  endtask
  task automatic finish_and_ack(input logic [31:0] cookie);
    finish_work = 1; tick(); finish_work = 0; tick();
    ok(result_valid && result_cookie == cookie && endpoint_hold, "held-result-owner");
    aw(8); w(cookie); retire_b(); tick();
    ok(!result_valid && !busy, "old-result-drained-not-discarded");
  endtask
  initial begin
    req = '0;
    repeat (3) tick(); rst_n = 1; tick();
    ok(!enabled && quiesce && !admit && epoch == 0, "reset-sealed");
    propose(64'h1111);
    unchanged(0, "missing-quiesce-ack");
    quiesced = '1; wait_epoch(1);
    ok(policy == 'h1111 && admit && !quiesce, "initial-snapshot");

    // AW is accepted with old admission before the manager starts draining.
    aw(0);
    ok(endpoint_hold, "partial-AW-owner-exported");
    propose(64'h2222); offered = 64'hBAD;
    unchanged(1, "policy-immutable-under-partial-AW");
    w('h44);
    while (!resp.b_valid) tick();
    accept_command = 0;
    unchanged(1, "held-B-and-command-owner");
    ok(command && authorized && command_cookie == 'h44, "old-AW-admission-survives-freeze");
    retire_b(); unchanged(1, "queued-command-owner-after-B");
    accept_command = 1; tick(); tick();
    ok(busy && executed == 1, "old-command-finishes-once");
    unchanged(1, "backend-execution-owner");
    finish_and_ack('h44);
    wait_epoch(2);
    ok(policy == 'h2222, "captured-not-live-candidate");

    // W-first and a held read response independently own the old epoch.
    w('h55); propose(64'h3333);
    unchanged(2, "policy-immutable-under-partial-W");
    aw(0); retire_b(1);  // New command AW arrived after admission closed.
    ok(executed == 1, "new-command-refused-while-draining");
    wait_epoch(3);
    req.ar.addr = 'h20; req.ar_valid = 1;
    do @(posedge clk); while (!resp.ar_ready);
    tick(); req.ar_valid = 0;
    propose(64'h4444); unchanged(3, "held-R-owner");
    ok(resp.r_valid && resp.r.data == 32'h1234_5678, "read-data-remains-stable");
    retire_r(); wait_epoch(4);
    // A cached generation low word is not an immortal policy lease.
    aw(0); w('h66); retire_b(); tick();
    ok(busy && executed == 2, "second-command");
    finish_and_ack('h66); tick();
    propose(64'h5555);
    upstream = 2'b01; unchanged(4, "upstream-queued-owner");
    upstream = 0; route_hold = 1; unchanged(4, "route-response-owner");
    route_hold = 0; maintenance = 1; unchanged(4, "maintenance-owner");
    maintenance = 0; quiesced = 2'b01; unchanged(4, "every-ingress-must-close");
    quiesced = '1; tick(); maintenance = 1; tick();
    unchanged(4, "idle-observation-must-remain-true");
    maintenance = 0; wait_epoch(5);
    ok(policy == 'h5555, "all-owners-drained");

    providers[2] = 0; #1;
    ok(!enabled && !admit && quiesce, "provider-loss-immediate-denial");
    tick(); providers[2] = 1; tick();
    ok(revoked && !enabled, "provider-ABA-denied");
    maintenance = 1; propose(64'h6666); present[1] = 0;
    unchanged(5, "missing-owner-cannot-rebind");
    present = '1; maintenance = 0; repeat (3) tick();
    ok(epoch == 5 && !pending && !enabled && revoked, "stale-pending-offer-does-not-revive");
    propose(64'h6666); wait_epoch(6);
    ok(!revoked, "fresh-qualified-policy-clears-revocation");
    propose(64'h7777); wait_epoch(7);
    propose(64'h8888); repeat (5) tick();
    ok(exhausted && revoked && !enabled && !admit && quiesce && !update_ready &&
       epoch == 7 && policy == 'h7777, "epoch-exhaustion-never-wraps");
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_POLICY_PASS checks=%0d", checks); $finish;
  end
  initial begin #100000; $fatal(1, "CHECKPOINT_POLICY_TIMEOUT"); end
endmodule
