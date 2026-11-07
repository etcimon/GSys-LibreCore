// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_checkpoint_model #(
  parameter int unsigned RspCycles = 0
);
  import g6lc_storamic_pkg::*;
  localparam logic [63:0] Base = 64'h8000_0000;
  logic clk = 0, rst_n = 0, cut = 0, healthy = 1, authorized = 1;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  axi_req_t req;
  axi_resp_t resp;
  logic seal, sealed, pause_req, initialized, busy, locked;
  logic cmd = 0, restoring = 0, ready, result_valid, consume_result = 0, resume_safe = 1;
  logic [31:0] cookie = 0, result_cookie, reset_generation = 0, mapping_generation = 7;
  checkpoint_result_e result;
  logic [1:0] paused = 3, producer_errors = 0;
  logic valid, metadata_ok, degraded;
  logic [63:0] generation, sectors, reserved;
  logic [3:0] phase;
  logic [5:0] media_phase;
  logic mr, mg, mw, mrv, me, mready;
  logic [63:0] ma, md, mdata;
  logic [7:0] mb;
  txn_id_t mt, rt;
  logic sr = 0, sg, sw = 0, srv, se, fr = 0, fa, fe;
  logic [63:0] sa = 0, sd = 0, sdata;
  int checks = 0;
  g6lc_storamic_axi_memory #(.RegionBytes(64)) front (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .quiesce_i(seal), .quiesced_o(sealed),
    .req_i(req), .resp_o(resp), .source_i(8'd1), .reset_generation_i(reset_generation),
    .service_ready_o(), .sequence_exhausted_o(), .faults_o(), .events_o(), .inflight_o(),
    .mem_ready_i(mready), .mem_req_o(mr), .mem_gnt_i(mg), .mem_we_o(mw),
    .mem_addr_o(ma), .mem_wdata_o(md), .mem_be_o(mb), .mem_tag_o(mt), .mem_slot_o(),
    .mem_rvalid_i(mrv), .mem_rdata_i(mdata), .mem_error_i(me), .mem_tag_i(rt),
    .map_valid_i(1'b0), .slot_map_i('0), .region_map_i('0)
  );
  g6lc_storamic_checkpoint_model #(
    .RamRspCycles(RspCycles), .FlashRspCycles(RspCycles)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .present_i(1'b1), .identity_valid_i(1'b1),
    .protection_ok_i(healthy), .power_cut_i(cut), .module_id_i(160'h1234),
    .mapping_generation_i(mapping_generation), .reset_generation_i(reset_generation),
    .command_valid_i(cmd), .command_restore_i(restoring), .authorized_i(authorized),
    .command_cookie_i(cookie), .command_ready_o(ready), .result_valid_o(result_valid),
    .result_ready_i(consume_result), .result_cookie_o(result_cookie), .result_o(result),
    .restore_resume_safe_i(resume_safe), .producer_pause_o(pause_req),
    .producer_paused_i(paused), .producer_error_i(producer_errors),
    .axi_quiesce_o(seal), .axi_quiesced_i(sealed), .media_hold_o(),
    .initialized_o(initialized), .busy_o(busy), .recovery_locked_o(locked),
    .checkpoint_valid_o(valid), .metadata_ok_o(metadata_ok), .degraded_o(degraded),
    .checkpoint_generation_o(generation), .block_sectors_o(sectors), .reserved_bytes_o(reserved),
    .phase_o(phase), .media_phase_o(media_phase), .guard_phase_o(),
    .done_event_o(), .error_event_o(), .refuse_event_o(), .stale_event_o(),
    .mem_ready_o(mready), .mem_req_i(mr), .mem_we_i(mw), .mem_gnt_o(mg),
    .mem_addr_i(ma), .mem_wdata_i(md), .mem_be_i(mb), .mem_tag_i(mt),
    .mem_rvalid_o(mrv), .mem_error_o(me), .mem_rdata_o(mdata), .mem_tag_o(rt),
    .st_req_i(sr), .st_we_i(sw), .st_gnt_o(sg), .st_addr_i(sa), .st_wdata_i(sd),
    .st_be_i(8'hFF), .st_rvalid_o(srv), .st_error_o(se), .st_rdata_o(sdata),
    .st_flush_req_i(fr), .st_flush_ack_o(fa), .st_flush_error_o(fe)
  );
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_MODEL_FAIL %s phase=%0d media=%0d result=%0d",
                          label, phase, media_phase, result);
  endtask
  task automatic command(input bit restore, input logic [31:0] tag);
    restoring = restore; cookie = tag; cmd = 1;
    do @(posedge clk); while (!ready);
    tick(); cmd = 0;
  endtask
  task automatic response(input checkpoint_result_e expected, input logic [31:0] tag);
    while (!result_valid) tick();
    ok(result == expected && result_cookie == tag, "owned-control-completion");
  endtask
  task automatic consume;
    consume_result = 1; tick(); consume_result = 0; tick();
    while (busy) tick();
  endtask
  task automatic write_image(input logic [63:0] seed);
    req.aw = '0; req.aw.addr = Base; req.aw.id = 8'h21; req.aw.len = 7;
    req.aw.size = 3; req.aw.burst = 1; req.aw_valid = 1;
    do @(posedge clk); while (!resp.aw_ready);
    tick(); req.aw_valid = 0;
    for (int i = 0; i < 8; i++) begin
      req.w = '0; req.w.data = seed + 64'(i); req.w.strb = '1; req.w.last = i == 7;
      req.w_valid = 1;
      do @(posedge clk); while (!resp.w_ready);
      tick(); req.w_valid = 0;
    end
    while (!resp.b_valid) tick();
    ok(resp.b.resp == 0 && resp.b.id == 8'h21, "image-write");
    req.b_ready = 1; tick(); req.b_ready = 0; tick();
  endtask
  task automatic offer_read(input int word_index);
    req.ar = '0; req.ar.addr = Base + 64'(word_index * 8); req.ar.id = 8'h42;
    req.ar.size = 3; req.ar.burst = 1; req.ar_valid = 1;
    do @(posedge clk); while (!resp.ar_ready);
    tick(); req.ar_valid = 0;
  endtask
  task automatic read_response(input logic [63:0] value);
    while (!resp.r_valid) tick();
    ok(resp.r.resp == 0 && resp.r.id == 8'h42 && resp.r.data == value, "image-read");
    req.r_ready = 1; tick(); req.r_ready = 0; tick();
  endtask
  task automatic read_image(input logic [63:0] seed);
    for (int i = 0; i < 8; i++) begin offer_read(i); read_response(seed + 64'(i)); end
  endtask
  task automatic store_word(input logic [63:0] offset, input bit write_word,
                            input logic [63:0] value, input bit expected_error);
    sr = 1; sw = write_word; sa = offset; sd = value;
    do @(posedge clk); while (!sg);
    tick(); sr = 0;
    while (!srv) tick();
    ok(se == expected_error, "guarded-word-completion");
    if (!write_word && !expected_error) ok(sdata == value, "user-block-data");
    tick();
  endtask
  task automatic restore(input logic [31:0] tag);
    paused = 3; resume_safe = 1;
    command(1, tag); response(CP_OK, tag); consume();
    ok(!locked && !seal && generation == 1, "explicit-recovery-reopens");
    read_image(64'hA000);
  endtask
  initial begin
    req = '0;
    repeat (3) tick(); rst_n = 1;
    while (!initialized) tick();
    ok(metadata_ok && !valid && !locked && sectors == 1 && reserved == 512, "blank-boot-layout");
    authorized = 0; command(0, 1); response(CP_DENIED, 1); consume(); authorized = 1;
    write_image(64'hA000);
    store_word(0, 1, 64'h1234, 0); store_word(504, 1, 64'h5678, 0);
    store_word(512, 1, 64'hBAD, 1);
    fr = 1; while (!fa) tick(); ok(!fe, "user-flush-owner"); fr = 0; tick();

    $display("CHECKPOINT_MODEL_SECTION actual-publication");
    paused = 1;
    offer_read(2);
    command(0, 10);
    repeat (3) begin tick(); ok(pause_req && !seal, "RAM-open-until-last-writer-pauses"); end
    paused = 3; while (!seal) tick();
    repeat (3) begin
      tick(); ok(!dut.prepared && !result_valid, "backpressured-response-prevents-prepare");
    end
    read_response(64'hA002);
    response(CP_OK, 10);
    ok(valid && generation == 1 && !locked && !seal && !dut.prepared, "real-record-published");
    consume();
    store_word(0, 0, 64'h1234, 0); store_word(504, 0, 64'h5678, 0);
    write_image(64'hB000);
    resume_safe = 0; command(1, 11);
    while (!dut.restore_done) tick();
    tick();
    // A voluntary restore need not set the sticky fault/recovery flag. The
    // actual access boundary must stay sealed and paused until resume.
    repeat (3) begin
      tick(); ok(seal && sealed && pause_req && busy && !result_valid, "restore-waits-real-resume");
    end
    resume_safe = 1; response(CP_OK, 11); consume(); read_image(64'hA000);

    $display("CHECKPOINT_MODEL_SECTION reset-from-media");
    rst_n = 0; repeat (3) tick(); reset_generation++; rst_n = 1;
    while (!initialized) tick();
    ok(locked && seal && valid && generation == 1, "reset-discovers-record-without-selector-fixture");
    healthy = 0; restore(12); healthy = 1;

    $display("CHECKPOINT_MODEL_SECTION cut-during-replacement");
    write_image(64'hC000); command(0, 13);
    while (media_phase != 19) tick();
    cut = 1; response(CP_POWER_CUT, 13);
    consume_result = 1; tick(); consume_result = 0;
    repeat (3) tick(); cut = 0; while (busy) tick();
    ok(locked && seal && generation == 1, "cut-keeps-last-durable-generation");
    restore(14);
    store_word(0, 0, 64'h1234, 0);
    paused = 1; command(0, 15); response(CP_TIMEOUT, 15); consume();
    ok(locked && seal && generation == 1, "missing-writer-cannot-publish");
    restore(16);

    mapping_generation = 8; repeat (3) tick();
    ok(locked && seal && !result_valid, "idle-context-change-locks");
    while (dut.meta_idle == 0) tick();
    ok(!metadata_ok, "foreign-map-does-not-qualify");
    store_word(0, 0, 0, 1);
    mapping_generation = 7; tick();
    while (!metadata_ok) tick();
    ok(locked && seal, "matching-context-does-not-auto-resume");
    restore(17);
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_MODEL_PASS checks=%0d rsp_cycles=%0d", checks, RspCycles);
    $finish;
  end
  initial begin #2000000; $fatal(1, "CHECKPOINT_MODEL_TIMEOUT phase=%0d media=%0d", phase, media_phase); end
endmodule
