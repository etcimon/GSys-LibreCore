// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_policy_writer #(
  parameter bit Enabled = 1,
  parameter bit LossWithDriver = 0,
  parameter int unsigned RspCycles = 4
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_cfg_pkg::*;
  localparam logic [63:0] Base = 64'h8000_0000;
  localparam storamic_cfg_t ModelCfg = '{
    Enable: 1, Profile: ProfileModel, MaxSticks: 1, RequestedMediaCaps: 0,
    ModelBase: Base, ModelBytes: 1024
  };
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  axi_req_t req;
  axi_resp_t rsp;
  axil_req_t cp, dev;
  axil_resp_t cpr, dvr;
  logic update_valid = 0, update_ready, ready, pending, quiet, revoked, exhausted;
  logic commit, reject, revoke, exhaust, ack = 0, up_hold = 0, route_hold = 0, maint = 0;
  logic [4:0] providers = '1;
  logic [31:0] offered = 0, policy_word, epoch;
  logic [31:0] reset_generation = 1;
  logic pause_req, wquiet, werror, cq, wi, di, seal, owner, initialized, busy, locked;
  logic valid, metadata, degraded, irq, done_event, error_event;
  logic [63:0] generation, sectors, reserved;
  logic [3:0] phase;
  int checks = 0, commits, rejects;
  string section = "boot";
  always @(section) $display("POLICY_WRITER_SECTION %s", section);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin commits <= 0; rejects <= 0; end
    else begin
      if (commit) commits <= commits + 1;
      if (reject) rejects <= rejects + 1;
    end
  end
  g6lc_storamic_policy_writer_model #(
    .Cfg(Enabled ? ModelCfg : StoramicOff), .RspCycles(RspCycles)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .req_i(req), .resp_o(rsp),
    .ctrl_req_i(cp), .ctrl_resp_o(cpr), .device_ctrl_req_i(dev), .device_ctrl_resp_o(dvr),
    .irq_o(irq), .update_valid_i(update_valid), .update_ready_o(update_ready),
    .update_policy_i(offered), .policy_o(policy_word), .policy_epoch_o(epoch),
    .policy_ready_o(ready), .policy_pending_o(pending), .policy_quiesce_o(quiet),
    .policy_revoked_o(revoked), .policy_exhausted_o(exhausted),
    .policy_commit_o(commit), .policy_revoke_o(revoke), .policy_exhaust_o(exhaust),
    .policy_reject_o(reject), .providers_ready_i(providers),
    .upstream_present_i(1'b1), .upstream_hold_i(up_hold),
    .route_hold_i(route_hold), .maintenance_hold_i(maint),
    .aw_authorized_i(1'b1), .ar_authorized_i(1'b1),
    .present_i(1'b1), .identity_valid_i(1'b1), .protection_ok_i(1'b1), .power_cut_i(1'b0),
    .module_id_i(160'h1234), .mapping_generation_i(32'd7), .reset_generation_i(reset_generation),
    .upstream_paused_i(ack), .upstream_error_i(1'b0), .restore_resume_safe_i(1'b1),
    .upstream_pause_o(pause_req), .writer_quiesced_o(wquiet), .writer_error_o(werror),
    .ctrl_quiesced_o(cq), .writer_inflight_o(wi), .dma_inflight_o(di),
    .axi_quiesce_o(seal), .policy_hold_o(owner), .initialized_o(initialized),
    .busy_o(busy), .recovery_locked_o(locked), .checkpoint_valid_o(valid),
    .metadata_ok_o(metadata), .degraded_o(degraded), .checkpoint_generation_o(generation),
    .block_sectors_o(sectors), .reserved_bytes_o(reserved), .phase_o(phase),
    .issue_event_o(), .refuse_event_o(), .revoke_event_o(),
    .done_event_o(done_event), .error_event_o(error_event)
  );
  task automatic ok(input bit condition, input string name);
    checks++;
    if (!condition) $fatal(1, "POLICY_WRITER_FAIL %s epoch=%0d phase=%0d", name, epoch, phase);
  endtask
  task automatic offer(input logic [31:0] value);
    offered = value; update_valid = 1;
    do @(posedge clk); while (!update_ready);
    tick(); update_valid = 0; offered = ~value;
  endtask
  task automatic old_epoch(input int expected, input string label);
    repeat (5) begin
      tick(); ok(epoch == 32'(expected) && pending && quiet, label);
    end
  endtask
  task automatic published(input int expected, input logic [31:0] value);
    while (epoch != 32'(expected)) tick();
    ok(ready && !pending && policy_word == value && !quiet, "immutable-publication");
  endtask
  task automatic cw(input bit device, input int address, input logic [31:0] value);
    axil_req_t q;
    axil_resp_t p;
    q = '0; q.aw.addr = 64'(address); q.aw_valid = 1;
    if (device) dev = q; else cp = q;
    do begin @(posedge clk); p = device ? dvr : cpr; end while (!p.aw_ready);
    tick(); q.aw_valid = 0; q.w.data = value; q.w.strb = '1; q.w_valid = 1;
    if (device) dev = q; else cp = q;
    do begin @(posedge clk); p = device ? dvr : cpr; end while (!p.w_ready);
    tick(); q.w_valid = 0;
    if (device) dev = q; else cp = q;
    do begin p = device ? dvr : cpr; if (!p.b_valid) tick(); end while (!p.b_valid);
    ok(p.b.resp == (Enabled ? 0 : 2), "control-write-response");
    q.b_ready = 1; if (device) dev = q; else cp = q;
    tick(); if (device) dev = '0; else cp = '0; tick();
  endtask
  task automatic cr(input int address, output logic [31:0] value);
    axil_req_t q;
    q = '0; q.ar.addr = 64'(address); q.ar_valid = 1; cp = q;
    do @(posedge clk); while (!cpr.ar_ready);
    tick(); q.ar_valid = 0; cp = q;
    while (!cpr.r_valid) tick();
    ok(cpr.r.resp == 0, "checkpoint-read-response"); value = cpr.r.data;
    q.r_ready = 1; cp = q; tick(); cp = '0; tick();
  endtask
  task automatic mw(input int offset, input logic [63:0] value);
    axi_req_t q;
    q = '0; q.aw.addr = Base + 64'(offset); q.aw.id = 1;
    q.aw.size = 3; q.aw.burst = 1; q.aw_valid = 1; req = q;
    do @(posedge clk); while (!rsp.aw_ready);
    tick(); q.aw_valid = 0; q.w.data = value; q.w.strb = '1;
    q.w.last = 1; q.w_valid = 1; req = q;
    do @(posedge clk); while (!rsp.w_ready);
    tick(); q.w_valid = 0; req = q;
    while (!rsp.b_valid) tick();
    ok(rsp.b.resp == 0 && rsp.b.id == 1, "RAM-write-response");
    q.b_ready = 1; req = q; tick(); req = '0; tick();
  endtask
  task automatic mr(input int offset, output logic [63:0] value);
    axi_req_t q;
    q = '0; q.ar.addr = Base + 64'(offset); q.ar.id = 2;
    q.ar.size = 3; q.ar.burst = 1; q.ar_valid = 1; req = q;
    do @(posedge clk); while (!rsp.ar_ready);
    tick(); q.ar_valid = 0; req = q;
    while (!rsp.r_valid) tick();
    ok(rsp.r.resp == 0 && rsp.r.id == 2 && rsp.r.last, "RAM-read-response");
    value = rsp.r.data; q.r_ready = 1; req = q; tick(); req = '0; tick();
  endtask
  task automatic driver_init;
    cw(1, 'h70, 0); cw(1, 'h70, 1); cw(1, 'h70, 3);
    cw(1, 'h24, 1); cw(1, 'h20, 1); cw(1, 'h70, 11);
    cw(1, 'h30, 0); cw(1, 'h38, 4);
    cw(1, 'h80, 32'(Base)); cw(1, 'h84, 0);
    cw(1, 'h90, 32'(Base + 'h40)); cw(1, 'h94, 0);
    cw(1, 'ha0, 32'(Base + 'h60)); cw(1, 'ha4, 0);
    cw(1, 'h44, 1); cw(1, 'h70, 15);
  endtask
  initial begin
    logic [31:0] status;
    logic [63:0] value, held_read;
    axil_req_t q;
    req = '0; cp = '0; dev = '0;
    repeat (3) tick(); rst_n = 1; repeat (4) tick();
    if (!Enabled) begin
      update_valid = 1; offered = '1; ack = 1;
      repeat (8) tick();
      ok(!ready && !update_ready && !pending && epoch == 0 && policy_word == 0 &&
         quiet && !wquiet && !cq && locked, "disabled-no-policy-or-synthetic-ACK");
      cw(0, 0, 1); cw(1, 'h70, 1);
    end else begin
      ok(!ready && quiet && epoch == 0 && req == '0, "boot-requires-policy-and-real-drain");
      offer('hA1);
      ack = 1; // The fixture has issued no upstream traffic.
      while (!initialized) tick();
      published(1, 'hA1); ack = 0;
      ok(metadata && !locked && sectors != 0, "boot-metadata-independent-of-policy");
      section = "guest-init";
      for (int i = 0; i < 128; i++) mw(i * 8, 0);
      mw(0, Base + 'h90); mw(8, {16'd1,16'd1,32'd16});
      mw(16, Base + 'h100); mw(24, {16'd2,16'd1,32'd512});
      mw(32, Base + 'h3f8); mw(40, {16'd0,16'd2,32'd1});
      mw('h90, 1); mw('h3f8, 'hEE);
      for (int i = 0; i < 64; i++) mw('h100 + i * 8, 64'hABCD_0000 + 64'(i));
      driver_init();
      mw('h40, 64'h0000_0000_0001_0000); cw(1, 'h50, 0);
      // A ring walk owns traffic but has not yet admitted an OUT to storage.
      while (!dut.writer.sr) tick();
      ok(!wquiet && owner, "actual-writer-job-owned");
      // Admit the real checkpoint flush/save before stopping new commands.
      // A policy replacement never invents a flush for dirty staging.
      cw(0, 0, 10); while (!busy) tick();
      $display("POLICY_WRITER_ADMISSION sr=%b wi=%b di=%b", dut.writer.sr, wi, di);
      section = "accepted-save-and-policy-update";
      offer('hB2);
      while (!wquiet) begin
        ok(epoch == 1 && policy_word == 'hA1 && pending && !commit &&
           !werror && owner, "writer-drains-under-old-epoch");
        tick();
      end
      ok(!di && cq && !seal && pause_req, "no-invented-upstream-pause-ACK");
      mr('h60, value);
      $display("POLICY_WRITER_USED value=%h", value);
      mr('h3f8, held_read);
      $display("POLICY_WRITER_STATUS value=%h", held_read);
      ok(value[31:16] == 1, "accepted-OUT-used-ring-completes");
      mr('h3f8, value);
      $display("POLICY_WRITER_STATUS value=%h", value);
      ok(value[7:0] == 0, "accepted-OUT-status-completes");
      ack = 1;
      do cr('h10, status); while (!status[1]);
      cr('h14, status); ok(status == 10, "accepted-save-cookie");
      cr('h18, status); ok(status == 0 && valid && generation == 1, "accepted-save-completes");
      old_epoch(1, "held-result-keeps-old-epoch");
      up_hold = 1; cw(0, 8, 10);
      old_epoch(1, "external-upstream-owner-blocks-publication");
      route_hold = 1; up_hold = 0;
      old_epoch(1, "external-route-owner-blocks-publication");
      maint = 1; route_hold = 0;
      old_epoch(1, "external-maintenance-owner-blocks-publication");
      maint = 0; published(2, 'hB2); ack = 0;

      section = "partial-MMIO-and-held-responses";
      q = '0; q.aw.addr = 'h64; q.aw_valid = 1;
      q.ar.addr = 0; q.ar_valid = 1; dev = q;
      do @(posedge clk); while (!(dvr.aw_ready && dvr.ar_ready));
      tick(); q.aw_valid = 0; q.ar_valid = 0; dev = q;
      while (!dvr.r_valid) tick();
      held_read = {32'd0, dvr.r.data};
      offer('hC3);
      old_epoch(2, "partial-MMIO-retains-policy-owner");
      ok(!cq && dvr.r_valid && dvr.r.data == held_read[31:0], "held-MMIO-read-stable");
      q.w.data = 1; q.w.strb = '1; q.w_valid = 1; dev = q;
      do @(posedge clk); while (!dvr.w_ready);
      tick(); q.w_valid = 0; dev = q;
      while (!dvr.b_valid) tick();
      old_epoch(2, "held-MMIO-B-R-retain-policy-owner");
      ok(dvr.b.resp == 0 && dvr.r_valid && !cq, "MMIO-late-W-drains-with-seal");
      q.b_ready = 1; dev = q; tick(); q.b_ready = 0; dev = q;
      old_epoch(2, "held-MMIO-R-alone-retains-owner");
      q.r_ready = 1; dev = q; tick(); dev = '0; tick();
      $display("POLICY_WRITER_SEAL_DRAIN ctrl=%b writer=%b wi=%b di=%b owner=%b",
        cq, wquiet, wi, di, owner);
      // A device may still retire an already accepted avail-ring poll after
      // the independent control response. Wait for both actual owners.
      while (wi || di || owner) tick();
      ok(cq && wquiet && !wi && !di && !owner, "actual-control-and-writer-drained");
      old_epoch(2, "upstream-pause-ACK-remains-external");
      ack = 1; published(3, 'hC3);

      section = "provider-loss-and-ABA";
      if (!LossWithDriver) begin
        // Reset the guest device while MMIO is open; a lost provider is not
        // permission to discard an active queue or forge its drain ACK.
        cw(1, 'h70, 0);
        while (wi || di || owner) tick();
        repeat (4) tick();
      end
      up_hold = 1; offer('hD4);
      providers = 5'b11110; tick(); tick(); providers = '1; tick();
      ok(!ready && revoked && epoch == 3 && policy_word == 'hC3,
         "provider-ABA-cannot-revive-policy");
      up_hold = 0;
      if (LossWithDriver) begin
        repeat (400) begin
          tick();
          ok(!ready && epoch == 3 && policy_word == 'hC3,
             "active-provider-loss-cannot-revive-old-or-offered-policy");
        end
        $display("POLICY_WRITER_LOSS pending=%b owner=%b wi=%b di=%b werror=%b locked=%b metadata=%b seal=%b",
          pending, owner, wi, di, werror, locked, metadata, seal);
        // Common-domain reset cancels the old queue/AXI work. No local idle
        // wire is substituted for the missing native recovery provider.
        section = "explicit-common-reset-and-rediscovery";
        req = '0; cp = '0; dev = '0; ack = 0; rst_n = 0;
        reset_generation = reset_generation + 1;
        repeat (3) tick(); rst_n = 1; repeat (4) tick();
        ok(!ready && epoch == 0 && !pending && req == '0, "reset-requires-fresh-publication");
        offer('hE5); ack = 1;
        while (!initialized) tick();
        published(1, 'hE5); tick();
        ok(metadata && valid && generation == 1 && commits == 1,
           "common-reset-rediscovers-prior-durable-image");
      end else begin
        while (pending) tick();
        tick();
        ok(rejects == 1 && commits == 3 && !ready && epoch == 3,
           "revoked-offer-rejected-without-publication");
        offer('hE5); published(4, 'hE5); tick();
        ok(commits == 4 && rejects == 1 && !exhausted, "fresh-offer-requalifies-new-epoch");
      end
    end
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("POLICY_WRITER_PASS checks=%0d enabled=%0d rsp=%0d", checks, Enabled, RspCycles);
    $finish;
  end
  initial begin
    #20000000;
    $fatal(1, "POLICY_WRITER_TIMEOUT section=%s epoch=%0d ready=%b pending=%b hold=%b init=%b busy=%b phase=%0d quiet=%b/%b ack=%b req=%b/%b/%b",
      section, epoch, ready, pending, owner, initialized, busy, phase,
      wquiet, cq, ack, req.aw_valid, req.w_valid, req.ar_valid);
  end
endmodule
