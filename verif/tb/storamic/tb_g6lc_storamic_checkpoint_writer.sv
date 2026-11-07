// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_checkpoint_writer #(
  parameter bit Enabled = 1,
  parameter bit EarlyUpstreamAck = 0,
  parameter bit ExpectTimeout = 0,
  parameter bit ResetDuringSave = 0,
  parameter int unsigned TimeoutCycles = 32768,
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
  axi_resp_t resp;
  axil_req_t cp, dev;
  axil_resp_t cpr, dvr;
  logic ack = 0, resume_safe = 1, pause_req, seal, hold_owner, initialized, busy;
  logic locked, valid, metadata, degraded, wquiet, werror, wi, di, cq, irq;
  logic [63:0] generation, sectors, reserved;
  logic [3:0] phase;
  logic done_event, error_event, writer_error_seen;
  int done_count, error_count;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_count <= 0; error_count <= 0; writer_error_seen <= 0;
    end else begin
      if (done_event) done_count <= done_count + 1;
      if (error_event) error_count <= error_count + 1;
      if (busy && werror) writer_error_seen <= 1;
    end
  end
  int checks = 0;
  string step_name = "reset";
  int last_offset = -1;
  task automatic section(input string label);
    step_name = label; $display("CHECKPOINT_WRITER_SECTION %s", label);
  endtask
  g6lc_storamic_checkpoint_writer_model #(
    .Cfg(Enabled ? ModelCfg : StoramicOff), .RspCycles(RspCycles),
    .TimeoutCycles(TimeoutCycles)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .req_i(req), .resp_o(resp),
    .ctrl_req_i(cp), .ctrl_resp_o(cpr), .device_ctrl_req_i(dev), .device_ctrl_resp_o(dvr),
    .irq_o(irq), .providers_ready_i(5'b11111), .control_enable_i(1'b1),
    .command_admit_i(1'b1), .aw_authorized_i(1'b1), .ar_authorized_i(1'b1),
    .policy_epoch_i(32'd7), .present_i(1'b1), .identity_valid_i(1'b1),
    .protection_ok_i(1'b1), .power_cut_i(1'b0), .module_id_i(160'h1234),
    .mapping_generation_i(32'd7), .reset_generation_i(32'd1),
    .upstream_paused_i(ack), .upstream_error_i(1'b0), .restore_resume_safe_i(resume_safe),
    .writer_quiesce_i(1'b0), .ctrl_quiesce_i(1'b0),
    .upstream_pause_o(pause_req), .writer_quiesced_o(wquiet), .writer_error_o(werror),
    .ctrl_quiesced_o(cq), .writer_inflight_o(wi), .dma_inflight_o(di),
    .axi_quiesce_o(seal), .policy_hold_o(hold_owner), .initialized_o(initialized),
    .busy_o(busy), .recovery_locked_o(locked), .checkpoint_valid_o(valid),
    .metadata_ok_o(metadata), .degraded_o(degraded),
    .checkpoint_generation_o(generation), .block_sectors_o(sectors), .reserved_bytes_o(reserved),
    .phase_o(phase), .issue_event_o(), .refuse_event_o(), .revoke_event_o(),
    .done_event_o(done_event), .error_event_o(error_event)
  );
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_WRITER_FAIL %s phase=%0d", label, phase);
  endtask
  task automatic drive(input bit device, input axil_req_t value);
    if (device) dev = value; else cp = value;
  endtask
  function automatic axil_resp_t response(input bit device);
    return device ? dvr : cpr;
  endfunction
  task automatic cw(input bit device, input int address, input logic [31:0] value,
                    input bit denied = 0);
    axil_req_t q;
    axil_resp_t p;
    q = '0; q.aw.addr = 64'(address); q.aw_valid = 1; drive(device, q);
    do begin @(posedge clk); p = response(device); end while (!p.aw_ready);
    tick(); q.aw_valid = 0; q.w.data = value; q.w.strb = '1; q.w_valid = 1; drive(device, q);
    do begin @(posedge clk); p = response(device); end while (!p.w_ready);
    tick(); q.w_valid = 0; drive(device, q);
    do begin p = response(device); if (!p.b_valid) tick(); end while (!p.b_valid);
    ok(p.b.resp == (denied ? 2 : 0), "control-write");
    q.b_ready = 1; drive(device, q); tick(); drive(device, '0); tick();
  endtask
  task automatic cr(input int address, output logic [31:0] value);
    axil_req_t q;
    q = '0; q.ar.addr = 64'(address); q.ar_valid = 1; cp = q;
    do @(posedge clk); while (!cpr.ar_ready);
    tick(); q.ar_valid = 0; cp = q;
    while (!cpr.r_valid) tick();
    ok(cpr.r.resp == 0, "control-read"); value = cpr.r.data;
    q.r_ready = 1; cp = q; tick(); cp = '0; tick();
  endtask
  task automatic device_read(input int address, output logic [31:0] value);
    axil_req_t q;
    q = '0; q.ar.addr = 64'(address); q.ar_valid = 1; dev = q;
    do @(posedge clk); while (!dvr.ar_ready);
    tick(); q.ar_valid = 0; dev = q;
    while (!dvr.r_valid) tick();
    ok(dvr.r.resp == 0, "device-read"); value = dvr.r.data;
    q.r_ready = 1; dev = q; tick(); dev = '0; tick();
  endtask
  task automatic mw(input int offset, input logic [63:0] value);
    axi_req_t q;
    last_offset = offset;
    q = '0; q.aw.addr = Base + 64'(offset); q.aw.id = 8'h21;
    q.aw.size = 3; q.aw.burst = 1; q.aw_valid = 1; req = q;
    do @(posedge clk); while (!resp.aw_ready);
    tick(); q.aw_valid = 0; q.w.data = value; q.w.strb = '1;
    q.w.last = 1; q.w_valid = 1; req = q;
    do @(posedge clk); while (!resp.w_ready);
    tick(); q.w_valid = 0; req = q;
    while (!resp.b_valid) tick();
    ok(resp.b.resp == 0 && resp.b.id == 'h21, "CPU-write");
    q.b_ready = 1; req = q; tick(); req = '0; tick();
  endtask
  task automatic mr(input int offset, output logic [63:0] value);
    axi_req_t q;
    q = '0; q.ar.addr = Base + 64'(offset); q.ar.id = 8'h42;
    q.ar.size = 3; q.ar.burst = 1; q.ar_valid = 1; req = q;
    do @(posedge clk); while (!resp.ar_ready);
    tick(); q.ar_valid = 0; req = q;
    while (!resp.r_valid) tick();
    ok(resp.r.resp == 0 && resp.r.id == 'h42 && resp.r.last, "CPU-read");
    value = resp.r.data; q.r_ready = 1; req = q; tick(); req = '0; tick();
  endtask
  task automatic result(input logic [31:0] cookie,
                        input checkpoint_result_e expected = CP_OK);
    logic [31:0] v;
    do cr('h10, v); while (!v[1]);
    cr('h14, v); ok(v == cookie, "cookie");
    cr('h18, v);
    $display("CHECKPOINT_WRITER_RESULT cookie=%0d code=%0d phase=%0d", cookie, v, phase);
    ok(v == 32'(expected), expected == CP_PRODUCER_ERROR ?
       "real-writer-reset-error-reaches-checkpoint" : "checkpoint-result");
    cw(0, 8, cookie); while (busy) tick();
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
  function automatic logic [63:0] pattern(input int i);
    return 64'hABCD_1234_0000_0000 ^ 64'(i);
  endfunction
  task automatic reset_during_save;
    logic [63:0] v;
    logic [31:0] status;
    int saved_done, saved_errors;
    saved_done = done_count; saved_errors = error_count;
    section("reset-job-admission"); ack = 0;
    cw(1, 'h64, 1);
    for (int i = 0; i < 64; i++) mw('h100 + i * 8, ~pattern(i));
    mw('h3f8, 'hEE); mw('h40, 64'h0000_0000_0002_0000); cw(1, 'h50, 0);
    while (!dut.sr) tick();
    ok(wi && hold_owner && !wquiet, "reset-job-is-real-owner");
    cw(0, 0, 12);
    while (!pause_req) tick();
    // Reset through the real transport, not an invented producer-error input.
    section("reset-while-checkpoint-pauses"); cw(1, 'h70, 0);
    while (di) tick();
    ok(req == '0, "reset-upstream-no-owned-traffic");
    ack = 1; result(12, CP_PRODUCER_ERROR);
    do device_read('h70, status); while (status != 0);
    while (wi || di || werror) tick();
    ok(writer_error_seen && error_count == saved_errors + 1 &&
       done_count == saved_done, "real-reset-error-exactly-once-no-false-done");
    ok(valid && generation == 1 && metadata, "failed-save-keeps-prior-checkpoint");
    mr('h60, v); ok(v[31:16] == 1, "reset-does-not-publish-cancelled-used-entry");
    mr('h3f8, v); ok(v[7:0] == 'hEE, "reset-does-not-invent-cancelled-status");
    section("reset-recover"); resume_safe = 0; cw(0, 4, 13);
    // CSync is the controller's public phase10, after real media/RAM completion.
    while (phase != 10) tick();
    repeat (500) tick();
    ok(busy && seal && pause_req && hold_owner, "reset-resume-provider-still-external");
    device_read('h70, status);
    ok(status == 0 && !wi && !di && req == '0 && wquiet,
       "resume-only-with-inactive-reset-device-and-idle-upstream");
    resume_safe = 1; result(13);
    ok(!locked && generation == 1 && done_count == saved_done + 1,
       "prior-generation-restored-after-reset");
    ack = 0;
    for (int i = 0; i < 64; i++) begin
      mr('h100 + i * 8, v); ok(v == pattern(i), "reset-restore-uses-prior-image");
    end
    // Reset dropped device queue indices; rebuild guest rings before enabling it.
    mw('h40, 0); mw('h60, 0); mw('h90, 0);
    mw(24, {16'd2,16'd3,32'd512}); mw('h3f8, 'hEE);
    for (int i = 0; i < 64; i++) mw('h100 + i * 8, 0);
    driver_init();
    section("reset-driver-resumes"); mw('h40, 64'h0000_0000_0001_0000); cw(1, 'h50, 0);
    while (!irq) tick();
    mr('h3f8, v); ok(v[7:0] == 0, "reset-reinitialized-IN-completes");
    mr('h60, v); ok(v[31:16] == 1, "reset-queue-restarts-from-zero");
  endtask
  initial begin
    logic [63:0] v;
    req = '0; cp = '0; dev = '0;
    repeat (3) tick(); rst_n = 1; repeat (4) tick();
    if (!Enabled) begin
      cw(0, 0, 1, 1); cw(1, 'h70, 1, 1);
      ok(!initialized && locked && !wquiet && !cq && !wi && !di && !irq,
         "default-off-no-writer-or-synthetic-ack");
    end else begin
      section("boot");
      while (!pause_req) tick();
      ok(req == '0 && !di, "boot-upstream-has-issued-no-traffic");
      ack = 1;
      while (!initialized) tick();
      ok(metadata && !locked && sectors != 0 && !valid, "model-boot");
      ack = 0;
      section("guest-init");
      for (int i = 0; i < 128; i++) mw(i * 8, 0);
      mw(0, Base + 'h90); mw(8, {16'd1,16'd1,32'd16});
      mw(16, Base + 'h100); mw(24, {16'd2,16'd1,32'd512});
      mw(32, Base + 'h3f8); mw(40, {16'd0,16'd2,32'd1});
      mw('h90, 1); mw('h98, 0); mw('h3f8, 'hEE);
      for (int i = 0; i < 64; i++) mw('h100 + i * 8, pattern(i));
      section("driver-init"); driver_init();
      section("OUT-admission");
      mw('h40, 64'h0000_0000_0001_0000); cw(1, 'h50, 0);
      while (!dut.sr) tick();
      ok(wi && hold_owner && !wquiet, "accepted-OUT-is-real-owner");
      section("checkpoint-active-writer"); cw(0, 0, 10);
      while (!pause_req) tick();
      ack = EarlyUpstreamAck;
      while (!wquiet) begin
        ok(!seal && hold_owner && !werror, "real-writer-not-a-fixture-ack"); tick();
      end
      if (!EarlyUpstreamAck) begin
        repeat (3) tick();
        ok(!seal && !di && !werror, "writer-drains-before-external-upstream");
        mr('h60, v); ok(v[31:16] == 1, "used-ring-before-writer-ack");
        mr('h3f8, v); ok(v[7:0] == 0, "status-before-writer-ack");
      end
      section("save-drain"); ack = 1; result(10);
      ok(valid && generation == 1 && !locked, "real-flush-and-snapshot-publish");
      mr('h60, v); ok(v[31:16] == 1, "used-publication-precedes-snapshot");
      mr('h3f8, v); ok(v[7:0] == 0, "status-publication-precedes-snapshot");
      if (ResetDuringSave) begin
        reset_during_save();
      end else begin
        ack = 0; mw('h100, 'hBAD);
        section("restore"); ack = 1; resume_safe = 0; cw(0, 4, 11);
        repeat (500) tick();
        ok(busy && seal && pause_req && hold_owner, "external-resume-provider-not-invented");
        resume_safe = 1; result(11, ExpectTimeout ? CP_TIMEOUT : CP_OK);
        if (ExpectTimeout) begin
          ok(locked && valid && generation == 1, "short-deadline-retains-lock-and-generation");
        end else begin
          ack = 0;
          mr('h100, v); ok(v == pattern(0), "snapshot-restores-guest-memory");
          // Read the user sector through a real job, not a store probe.
          section("IN"); cw(1, 'h64, 1); mw('h90, 0);
          mw(24, {16'd2,16'd3,32'd512});
          for (int i = 0; i < 64; i++) mw('h100 + i * 8, 0);
          mw('h3f8, 'hEE); mw('h40, 64'h0000_0000_0002_0000); cw(1, 'h50, 0);
          while (!irq) tick();
          mr('h3f8, v); ok(v[7:0] == 0, $sformatf("IN-status code=%0d", v[7:0]));
          for (int i = 0; i < 64; i++) begin
            mr('h100 + i * 8, v); ok(v == pattern(i), "real-OUT-IN-user-sector");
          end
        end
      end
    end
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_WRITER_PASS checks=%0d enabled=%0d rsp_cycles=%0d",
             checks, Enabled, RspCycles);
    $finish;
  end
  if (Enabled) initial begin
    #20000000;
    $display("WRITER_STATE ring=%0d blk=%0d dma=%0d driver_ok=%b queue_ready=%b sr=%b sg=%b wi=%b di=%b",
      dut.gen_model.writer.i_ring.state_q, dut.gen_model.writer.i_blk.state_q,
      dut.gen_model.dma.ph_q, dut.gen_model.writer.driver_ok, dut.gen_model.writer.queue_ready,
      dut.sr, dut.sg, wi, di);
  end
  if (Enabled) begin : gen_phase_trace
    logic [3:0] previous = 0;
    always @(negedge clk) if (rst_n && previous != phase) begin
      $display("WRITER_PHASE t=%0t phase=%0d timer=%0d ack=%b/%b err=%b seal=%b ram=%b done=%b rerr=%b flash=%b meta_idle=%b result=%0d",
        $time, phase, dut.endpoint.gen_model.media.i_ctrl.q.timer, ack, wquiet, werror,
        seal, dut.endpoint.gen_model.media.ram_busy, dut.endpoint.gen_model.media.restore_done,
        dut.endpoint.gen_model.media.restore_error, dut.endpoint.gen_model.media.flash_idle,
        dut.endpoint.gen_model.media.meta_idle, dut.endpoint.result);
      previous = phase;
    end
  end
  initial begin
    #20000000; #1;
    $fatal(1, "CHECKPOINT_WRITER_TIMEOUT section=%s offset=%0h phase=%0d init=%b meta=%b locked=%b aw=%b/%b w=%b/%b b=%b ar=%b/%b r=%b",
      step_name, last_offset, phase, initialized, metadata, locked, req.aw_valid, resp.aw_ready,
      req.w_valid, resp.w_ready, resp.b_valid, req.ar_valid, resp.ar_ready, resp.r_valid);
  end
endmodule
