// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_checkpoint_endpoint #(
  parameter int unsigned RspCycles = 0,
  parameter bit Enabled = 1,
  parameter int unsigned RawFlashBytes = 1024
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_cfg_pkg::*;
  localparam storamic_cfg_t ModelCfg = '{
    Enable: 1, Profile: ProfileModel, MaxSticks: 1, RequestedMediaCaps: 0,
    ModelBase: 64'h8000_0000, ModelBytes: 64
  };
  logic clk = 0, rst_n = 0, cut = 0, healthy = 1, auth = 1, resume_safe = 1;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  axi_req_t req;
  axi_resp_t resp;
  axil_req_t ctrl;
  axil_resp_t cr;
  logic [4:0] providers = 0;
  logic [1:0] paused = 0;
  logic pause_req, seal, policy_hold, initialized, busy, locked, valid, metadata, degraded;
  logic [63:0] generation, sectors, reserved;
  logic [3:0] phase;
  logic sr = 0, sg, sw = 0, srv, se, fr = 0, fa, fe;
  logic media_empty;
  int checks = 0;
  g6lc_storamic_checkpoint_endpoint #(
    .Cfg(Enabled ? ModelCfg : StoramicOff), .RspCycles(RspCycles), .RawFlashBytes(RawFlashBytes)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .req_i(req), .resp_o(resp),
    .ctrl_req_i(ctrl), .ctrl_resp_o(cr), .providers_ready_i(providers),
    .control_enable_i(1'b1), .command_admit_i(1'b1),
    .aw_authorized_i(auth), .ar_authorized_i(auth), .policy_epoch_i(32'd7),
    .present_i(1'b1), .identity_valid_i(1'b1), .protection_ok_i(healthy), .power_cut_i(cut),
    .module_id_i(160'h1234), .mapping_generation_i(32'd7), .reset_generation_i(32'd1),
    .producer_paused_i(paused), .producer_error_i(2'b00), .restore_resume_safe_i(resume_safe),
    .producer_pause_o(pause_req), .axi_quiesce_o(seal), .policy_hold_o(policy_hold),
    .initialized_o(initialized), .busy_o(busy), .recovery_locked_o(locked),
    .checkpoint_valid_o(valid), .metadata_ok_o(metadata), .degraded_o(degraded),
    .checkpoint_generation_o(generation), .block_sectors_o(sectors), .reserved_bytes_o(reserved),
    .phase_o(phase), .issue_event_o(), .refuse_event_o(), .revoke_event_o(),
    .done_event_o(), .error_event_o(), .st_req_i(sr), .st_we_i(sw), .st_gnt_o(sg),
    .st_addr_i(64'd0), .st_wdata_i(64'hB10C_0001), .st_be_i(8'hFF),
    .st_rvalid_o(srv), .st_error_o(se), .st_rdata_o(), .st_flush_req_i(fr),
    .st_flush_ack_o(fa), .st_flush_error_o(fe)
  );
  if (Enabled && RawFlashBytes == 1024) begin : gen_media_probe
    assign media_empty = dut.gen_model.media.flash_drained;
  end else begin : gen_no_media_probe
    assign media_empty = 0;
  end
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_ENDPOINT_FAIL %s phase=%0d", label, phase);
  endtask
  task automatic cw(input int address, input logic [31:0] value, input bit denied = 0);
    ctrl.aw.addr = 64'(address); ctrl.aw_valid = 1;
    do @(posedge clk); while (!cr.aw_ready);
    tick(); ctrl.aw_valid = 0;
    ctrl.w.data = value; ctrl.w.strb = '1; ctrl.w_valid = 1;
    do @(posedge clk); while (!cr.w_ready);
    tick(); ctrl.w_valid = 0;
    while (!cr.b_valid) tick();
    ok(cr.b.resp == (denied ? 2 : 0), "control-write-owned-response");
    ctrl.b_ready = 1; tick(); ctrl.b_ready = 0; tick();
  endtask
  task automatic read_control(input int address, output logic [31:0] data);
    ctrl.ar.addr = 64'(address); ctrl.ar_valid = 1;
    do @(posedge clk); while (!cr.ar_ready);
    tick(); ctrl.ar_valid = 0;
    while (!cr.r_valid) tick();
    ok(cr.r.resp == 0, "authorized-control-read"); data = cr.r.data;
    ctrl.r_ready = 1; tick(); ctrl.r_ready = 0; tick();
  endtask
  task automatic result(input checkpoint_result_e expected, input logic [31:0] cookie,
                         input bit wait_idle = 1);
    logic [31:0] data;
    do read_control('h10, data); while (!data[1]);
    read_control('h14, data); ok(data == cookie, "result-cookie");
    read_control('h18, data);
    ok(data == 32'(expected), $sformatf("result-code cookie=%0d got=%0d expected=%0d",
                                      cookie, data, expected));
    cw(8, cookie);
    if (wait_idle) while (busy) tick();
  endtask
  task automatic write_word(input logic [63:0] data, input bit error = 0,
                            input bit ownership_probe = 0);
    req.aw = '0; req.aw.addr = ModelCfg.ModelBase; req.aw.id = 'h21;
    req.aw.size = 3; req.aw.burst = 1; req.aw_valid = 1;
    do @(posedge clk); while (!resp.aw_ready);
    tick(); req.aw_valid = 0;
    if (ownership_probe) repeat (3) begin
      tick(); ok(policy_hold && !busy, "accepted-RAM-AW-owns-policy-before-W");
    end
    req.w = '0; req.w.data = data; req.w.strb = '1; req.w.last = 1; req.w_valid = 1;
    do @(posedge clk); while (!resp.w_ready);
    tick(); req.w_valid = 0;
    while (!resp.b_valid) tick();
    ok(resp.b.id == 'h21 && resp.b.resp == (error ? 2 : 0), "RAM-write");
    if (ownership_probe) repeat (3) begin
      tick(); ok(policy_hold && resp.b_valid && !busy, "held-RAM-B-owns-policy");
    end
    req.b_ready = 1; tick(); req.b_ready = 0; tick();
  endtask
  task automatic offer_read;
    req.ar = '0; req.ar.addr = ModelCfg.ModelBase; req.ar.id = 'h42;
    req.ar.size = 3; req.ar.burst = 1; req.ar_valid = 1;
    do @(posedge clk); while (!resp.ar_ready);
    tick(); req.ar_valid = 0;
  endtask
  task automatic retire_read(input logic [63:0] data);
    while (!resp.r_valid) tick();
    ok(resp.r.data == data && resp.r.id == 'h42 && resp.r.resp == 0, "RAM-image-read");
    req.r_ready = 1; tick(); req.r_ready = 0; tick();
  endtask
  task automatic block_write;
    sr = 1; sw = 1;
    do @(posedge clk); while (!sg);
    tick(); sr = 0; sw = 0;
    while (!srv) begin
      ok(policy_hold && !busy, "accepted-block-word-owns-policy"); tick();
    end
    ok(!se && policy_hold, "block-response-retains-owner");
    tick();
  endtask
  task automatic block_ownership;
    while (policy_hold) tick();
    block_write();
    repeat (3) begin
      tick(); ok(policy_hold && !busy, "dirty-staging-is-not-drained");
    end
    fr = 1;
    do begin tick(); ok(policy_hold, "user-flush-owns-policy"); end while (!fa);
    ok(!fe, "owned-flush-completes");
    fr = 0; tick(); tick();
    ok(!policy_hold && !busy, "real-flush-releases-media-owner");
  endtask
  task automatic abandoned_flush_owner;
    while (policy_hold) tick();
    block_write();
    fr = 1; tick(); fr = 0;
    repeat (30 + 2 * RspCycles) tick();
    ok(media_empty && policy_hold && !fa && !busy,
       "abandoned-flush-retains-owner-after-media-drains");
  endtask
  initial begin
    req = '0; ctrl = '0;
    repeat (3) tick(); rst_n = 1; repeat (4) tick();
    if (!Enabled) begin
      providers = '1; paused = '1;
      cw(0, 1, 1); write_word(64'hBAD, 1);
      ok(locked && seal && !initialized && !valid && sectors == 0, "disabled-profile-is-refuse-only");
    end else begin
      ok(seal && locked && !req.aw_valid, "missing-providers-start-sealed");
      cw(0, 1, 1);
      providers = '1; paused = '1;
      while (!initialized) tick();
      ok(!locked && metadata && !valid && sectors == 1 && reserved == 512, "qualified-fixture-blank-boot");
      auth = 0; cw(0, 2, 1); auth = 1;
      ok(!busy && generation == 0, "unauthorized-MMIO-never-reaches-save");
      block_ownership();
      write_word(64'hA000, 0, 1);
      offer_read();
      repeat (3) begin
        tick(); ok(policy_hold && !busy, "accepted-RAM-read-owns-policy-before-command");
      end
      paused = 1; cw(0, 10);
      repeat (3) begin tick(); ok(pause_req && !seal && policy_hold, "real-last-writer-still-running"); end
      paused = 3; while (!seal) tick();
      repeat (3) begin tick(); ok(busy && !valid, "accepted-read-must-retire-before-save"); end
      retire_read(64'hA000);
      result(CP_OK, 10);
      ok(valid && generation == 1 && !locked, "MMIO-publishes-real-record");
      write_word(64'hB000);
      resume_safe = 0; cw(4, 11);
      repeat (400 + 40 * RspCycles) tick();
      ok(busy && seal && pause_req && policy_hold, "restore-cannot-bypass-resume-provider");
      resume_safe = 1; result(CP_OK, 11);
      offer_read(); retire_read(64'hA000);
      rst_n = 0; repeat (3) tick(); rst_n = 1;
      while (!initialized) tick();
      ok(locked && valid && seal && generation == 1, "reset-discovers-media-without-selector");
      cw(4, 12); result(CP_OK, 12); offer_read(); retire_read(64'hA000);
      cw(0, 15);
      while (phase != 4) tick();
      providers[3] = 0; tick();
      cw(0, 16, 1);
      providers[3] = 1; while (!metadata) tick();
      result(CP_CONTEXT_CHANGED, 15);
      ok(locked && generation == 1, "active-provider-loss-keeps-last-generation");
      cw(4, 17); result(CP_OK, 17); offer_read(); retire_read(64'hA000);
      offer_read(); while (!resp.r_valid) tick();
      providers[3] = 0; tick();
      ok(seal && !resp.aw_ready && !resp.ar_ready, "missing-descriptor-provider-immediately-seals");
      repeat (3) begin tick(); ok(resp.r_valid && resp.r.data == 64'hA000, "provider-loss-retains-owned-read"); end
      cw(0, 13, 1);
      retire_read(64'hA000);
      providers[3] = 1; repeat (4) tick();
      ok(locked && seal, "provider-reappearance-does-not-auto-resume");
      while (!metadata) tick();
      cw(4, 14); result(CP_OK, 14); offer_read(); retire_read(64'hA000);
      write_word(64'hC000); cw(0, 20);
      while (phase != 4) tick();
      cut = 1; result(CP_POWER_CUT, 20, 0);
      repeat (3) tick(); cut = 0; while (busy) tick();
      ok(locked && generation == 1, "interrupted-MMIO-save-retains-generation");
      cw(4, 21); result(CP_OK, 21); offer_read(); retire_read(64'hA000);
      abandoned_flush_owner();
    end
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_ENDPOINT_PASS checks=%0d rsp_cycles=%0d enabled=%0d", checks, RspCycles, Enabled);
    $finish;
  end
  initial begin #2000000; $fatal(1, "CHECKPOINT_ENDPOINT_TIMEOUT phase=%0d", phase); end
endmodule
