// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Integrated AXI/RAM/flash maintenance bench. Metadata is explicitly a retained
// fixture; it is not the persistent record/recovery implementation of ST-025D.
module tb_g6lc_storamic_checkpoint_ctrl #(
  parameter int unsigned RamRspCycles = 4,
  parameter int unsigned FlashRspCycles = 4
);
  import g6lc_storamic_pkg::*;
  localparam logic [63:0] Base = 64'h8000_0000;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  logic cmd = 0, cmd_ready, cmd_restore = 0, authorized = 1, health = 1;
  logic [31:0] cookie = 0, result_cookie;
  logic result_valid, result_ready = 0, initialized, busy, locked;
  checkpoint_result_e result;
  logic [3:0] phase;
  logic done_event, error_event;
  logic cut = 0, boot_cut = 1, boot_ready = 0, resume_safe = 1;
  logic [159:0] module_id = 160'h1234;
  logic [31:0] mapping_generation = 32'd7;
  logic pause_req, seal, sealed;
  logic [1:0] paused = 2'b11, producer_error = 0;
  logic prepare, prepared, prepared_bank, ram_busy, ram_commit, ram_abort;
  logic ram_restore, ram_done;
  logic f_req, f_ack, f_err;
  logic flash_idle;
  logic m_req, m_ack = 0, m_err = 0, m_abort, m_pending = 0, m_seen = 0;
  logic hold_metadata = 0, fail_metadata = 0, exhaust_generation = 0;
  int m_count = 0;
  logic cp_valid = 0, cp_bank = 0;
  logic [63:0] cp_generation = 0, pub_generation;
  logic [159:0] cp_id = 0, pub_id;
  logic [31:0] cp_map = 0, pub_map;
  logic pub_bank;
  logic metadata_ok;
  assign metadata_ok = !cp_valid || (cp_id == module_id && cp_map == mapping_generation);

  g6lc_storamic_checkpoint_ctrl #(.NumProducers(2), .TimeoutCycles(256)) ctrl (
    .clk_i(clk), .rst_ni(rst_n),
    .command_valid_i(cmd), .command_ready_o(cmd_ready), .command_restore_i(cmd_restore),
    .command_cookie_i(cookie), .authorized_i(authorized), .protection_ok_i(health),
    .power_cut_i(cut), .identity_valid_i(1'b1), .module_id_i(module_id),
    .mapping_generation_i(mapping_generation), .boot_memory_ready_i(boot_ready),
    .metadata_recovered_i(1'b1), .metadata_ok_i(metadata_ok),
    .checkpoint_valid_i(cp_valid), .checkpoint_bank_i(cp_bank),
    .checkpoint_generation_i(exhaust_generation ? '1 : cp_generation),
    .restore_resume_safe_i(resume_safe),
    .result_valid_o(result_valid), .result_ready_i(result_ready),
    .result_cookie_o(result_cookie), .result_o(result),
    .initialized_o(initialized), .busy_o(busy), .recovery_locked_o(locked),
    .phase_o(phase), .event_done_o(done_event), .event_error_o(error_event),
    .producer_pause_o(pause_req), .producer_paused_i(paused), .producer_error_i(producer_error),
    .axi_quiesce_o(seal), .axi_quiesced_i(sealed),
    .ram_prepare_o(prepare), .ram_prepared_i(prepared), .ram_prepared_bank_i(prepared_bank),
    .ram_busy_i(ram_busy), .ram_error_i(1'b0), .ram_commit_o(ram_commit),
    .ram_abort_o(ram_abort), .ram_restore_o(ram_restore), .ram_restore_done_i(ram_done),
    .flash_flush_req_o(f_req), .flash_flush_ack_i(f_ack), .flash_flush_error_i(f_err),
    .flash_idle_i(flash_idle),
    .metadata_publish_req_o(m_req), .metadata_publish_ack_i(m_ack),
    .metadata_publish_error_i(m_err), .metadata_abort_o(m_abort),
    .metadata_idle_i(!m_pending),
    .publish_module_id_o(pub_id), .publish_mapping_generation_o(pub_map),
    .publish_generation_o(pub_generation), .publish_bank_o(pub_bank)
  );
  axi_req_t req;
  axi_resp_t resp;
  logic mem_ready, mem_req, mem_gnt, mem_we, mem_rv, mem_err;
  logic [63:0] mem_addr, mem_wdata, mem_rdata;
  logic [7:0] mem_be;
  txn_id_t mem_tag, reply_tag;
  g6lc_storamic_axi_memory #(.RegionBytes(64)) front (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .quiesce_i(seal), .quiesced_o(sealed), .inflight_o(),
    .req_i(req), .resp_o(resp), .source_i(8'd1), .reset_generation_i(32'd0),
    .service_ready_o(), .sequence_exhausted_o(), .faults_o(), .events_o(),
    .mem_ready_i(mem_ready), .mem_req_o(mem_req), .mem_gnt_i(mem_gnt),
    .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata),
    .mem_be_o(mem_be), .mem_tag_o(mem_tag), .mem_slot_o(),
    .mem_rvalid_i(mem_rv), .mem_rdata_i(mem_rdata), .mem_error_i(mem_err), .mem_tag_i(reply_tag),
    .map_valid_i(1'b0), .slot_map_i('0), .region_map_i('0)
  );
  g6lc_storamic_sim_mem #(
    .NumWords(8), .ModelBytes(64'd64), .RspDelay(RamRspCycles), .ExternalCheckpointCommit(1'b1)
  ) ram (
    .clk_i(clk), .rst_ni(rst_n), .mem_ready_o(mem_ready),
    .mem_req_i(mem_req), .mem_gnt_o(mem_gnt), .mem_we_i(mem_we),
    .mem_addr_i(mem_addr), .mem_wdata_i(mem_wdata), .mem_be_i(mem_be), .mem_tag_i(mem_tag),
    .mem_rvalid_o(mem_rv), .mem_rdata_o(mem_rdata), .mem_error_o(mem_err), .mem_tag_o(reply_tag),
    .power_cut_i(cut || boot_cut), .save_i(prepare), .restore_i(ram_restore),
    .checkpoint_valid_i(cp_valid), .checkpoint_bank_i(cp_bank),
    .checkpoint_commit_i(ram_commit), .checkpoint_abort_i(ram_abort), .maintenance_i(1'b0),
    .checkpoint_prepared_o(prepared), .checkpoint_prepared_bank_o(prepared_bank),
    .save_busy_o(ram_busy), .restore_done_o(ram_done)
  );

  logic sreq = 0, sgnt, swe = 0, srv, serr;
  logic [63:0] saddr = 0, swdata = 0, srdata;
  g6lc_storamic_durable_store #(
    .NumWords(16), .StageEntries(4), .RspCycles(FlashRspCycles), .CommitCycles(4)
  ) flash (
    .clk_i(clk), .rst_ni(rst_n), .power_cut_i(cut),
    .idle_o(flash_idle), .drained_o(),
    .st_req_i(sreq), .st_gnt_o(sgnt), .st_we_i(swe), .st_addr_i(saddr),
    .st_wdata_i(swdata), .st_be_i(8'hFF), .st_rvalid_o(srv), .st_rdata_o(srdata), .st_err_o(serr),
    .st_flush_req_i(f_req), .st_flush_ack_o(f_ack), .st_flush_err_o(f_err),
    .save_i(1'b0), .save_done_o(), .cut_count_o(), .commit_gen_o(),
    .journal_gen_o(), .journal_id_o(), .unlock_key_i(32'd0),
    .restore_i(1'b0), .restore_done_o()
  );
  always @(posedge clk) begin
    m_ack <= 0; m_err <= 0;
    if (!rst_n) begin
      m_pending <= 0; m_seen <= 0;
    end else begin
      if (!m_req) m_seen <= 0;
      if (m_req && !m_seen) begin
        assert (prepared && sealed && (&paused) && !f_req)
          else $fatal(1, "CHECKPOINT_CTRL_EARLY_PUBLICATION");
        m_seen <= 1; m_pending <= 1; m_count <= 4;
      end
      if (m_pending) begin
        if (cut || m_abort || fail_metadata) begin
          m_pending <= 0; m_ack <= 1; m_err <= 1;
        end else if (!hold_metadata) begin
          if (m_count != 0) m_count <= m_count - 1;
          else begin
            m_pending <= 0; m_ack <= 1;
            cp_valid <= 1; cp_bank <= pub_bank; cp_generation <= pub_generation;
            cp_id <= pub_id; cp_map <= pub_map;
          end
        end
      end
    end
  end

  int checks = 0;
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_CTRL_FAIL %s phase=%0d result=%0d", label, phase, result);
  endtask
  task automatic command(input bit restoring, input logic [31:0] tag);
    cmd_restore = restoring; cookie = tag; cmd = 1;
    do @(posedge clk); while (!cmd_ready);
    tick(); cmd = 0;
  endtask
  task automatic response(input checkpoint_result_e expected, input logic [31:0] tag);
    while (!result_valid) tick();
    ok(result == expected && result_cookie == tag, "command-result");
  endtask
  task automatic consume;
    result_ready = 1; tick(); result_ready = 0; tick();
    while (busy) tick();
  endtask
  task automatic aw(input logic [7:0] length);
    req.aw = '0; req.aw.addr = Base; req.aw.id = 8'h21; req.aw.len = length;
    req.aw.size = 3; req.aw.burst = 1; req.aw_valid = 1;
    do @(posedge clk); while (!resp.aw_ready);
    tick(); req.aw_valid = 0;
  endtask
  task automatic w(input logic [63:0] data, input bit last);
    req.w = '0; req.w.data = data; req.w.strb = '1; req.w.last = last; req.w_valid = 1;
    do @(posedge clk); while (!resp.w_ready);
    tick(); req.w_valid = 0;
  endtask
  task automatic retire_b;
    while (!resp.b_valid) tick();
    ok(resp.b.resp == 0 && resp.b.id == 8'h21, "write-response");
    req.b_ready = 1; tick(); req.b_ready = 0;
  endtask
  task automatic ar(input int index);
    req.ar = '0; req.ar.addr = Base + 64'(index * 8); req.ar.id = 8'h42;
    req.ar.size = 3; req.ar.burst = 1; req.ar_valid = 1;
    do @(posedge clk); while (!resp.ar_ready);
    tick(); req.ar_valid = 0;
  endtask
  task automatic retire_r(input logic [63:0] value);
    while (!resp.r_valid) tick();
    ok(resp.r.resp == 0 && resp.r.id == 8'h42 && resp.r.data == value, "read-response");
    req.r_ready = 1; tick(); req.r_ready = 0;
  endtask
  task automatic write_image(input logic [63:0] seed);
    aw(7);
    for (int i = 0; i < 8; i++) w(seed + 64'(i), i == 7);
    retire_b();
  endtask
  task automatic read_image(input logic [63:0] seed);
    for (int i = 0; i < 8; i++) begin ar(i); retire_r(seed + 64'(i)); end
  endtask
  task automatic store_write(input int index, input logic [63:0] value);
    sreq = 1; swe = 1; saddr = 64'(index * 8); swdata = value;
    do tick(); while (!srv);
    ok(!serr, "store-write");
    sreq = 0; swe = 0; tick();
  endtask
  task automatic recover(input logic [31:0] tag);
    paused = 3; producer_error = 0; resume_safe = 1; health = 0;
    command(1, tag); response(CP_OK, tag); consume();
    ok(!locked && !seal && !pause_req, "recovery-reopens-safe-window");
    read_image(64'hA000);
    health = 1;
  endtask

  initial begin
    req = '0;
    repeat (3) tick(); rst_n = 1; repeat (2) tick(); boot_cut = 0;
    while (ram_busy) tick();
    ok(locked && !initialized && seal, "boot-holds-uninitialized-window");
    boot_ready = 1;
    while (!initialized) tick();
    ok(!locked && !seal, "blank-media-initialized-boot");
    authorized = 0;
    command(0, 1); response(CP_DENIED, 1); consume();
    ok(!seal && !pause_req && !cp_valid, "denied-command-has-no-side-effects");
    authorized = 1; health = 0;
    command(0, 2); response(CP_NOT_READY, 2); consume();
    health = 1;

    $display("CHECKPOINT_CTRL_SECTION drain-and-publish");
    write_image(64'hA000);
    store_write(0, 64'h1234); store_write(1, 64'h5678);
    paused = 1; hold_metadata = 1;
    aw(1); w(64'hA000, 0); ar(2);
    command(0, 11);
    repeat (3) begin
      tick();
      ok(pause_req && !seal && !prepare && !m_req, "RAM-open-until-every-producer-drains");
    end
    paused = 3;
    while (!seal) tick();
    w(64'hA001, 1);
    while (!resp.b_valid || !resp.r_valid) tick();
    repeat (3) begin
      tick();
      ok(!prepare && !m_req && !result_valid, "accepted-B-and-R-backpressure-delays-scan");
    end
    retire_b(); retire_r(64'hA002);
    while (!m_req) tick();
    repeat (5) begin
      tick();
      ok(prepared && seal && sealed && cp_generation == 0 && !result_valid,
         "metadata-is-last-publication-boundary");
    end
    hold_metadata = 0;
    response(CP_OK, 11);
    ok(cp_valid && cp_generation == 1 && !prepared && !seal && !pause_req,
       "success-reopens-before-result-is-polled");
    write_image(64'hB000); read_image(64'hB000);
    ok(result_valid && result_cookie == 11 && result == CP_OK, "sticky-result-does-not-block-RAM");
    consume();

    $display("CHECKPOINT_CTRL_SECTION metadata-failure-and-restore-sync");
    fail_metadata = 1;
    command(0, 12); response(CP_MEDIA_ERROR, 12); consume();
    ok(locked && seal && cp_generation == 1, "failed-publication-retains-old-generation");
    fail_metadata = 0; health = 0; resume_safe = 0;
    command(1, 13);
    while (!ram_done) tick();
    tick();
    repeat (3) begin
      tick(); ok(locked && seal && !result_valid, "restore-waits-platform-synchronization");
    end
    // Device cursor reset is allowed only after reconstruction, while sealed.
    producer_error = 1; paused = 0; repeat (2) tick();
    ok(!result_valid && locked, "restore-sync-allows-explicit-device-reinitialization");
    producer_error = 0; paused = 3; resume_safe = 1;
    response(CP_OK, 13); consume();
    read_image(64'hA000); health = 1;

    $display("CHECKPOINT_CTRL_SECTION cut-and-recover");
    write_image(64'hC000);
    store_write(2, 64'hC001); store_write(3, 64'hC002);
    command(0, 14);
    while (!prepare) tick();
    repeat (2) tick(); cut = 1;
    response(CP_POWER_CUT, 14);
    result_ready = 1; tick(); result_ready = 0;
    repeat (3) tick(); cut = 0;
    while (busy) tick();
    ok(locked && seal && cp_generation == 1, "cut-leaves-recovery-lock-and-old-generation");
    recover(15);

    $display("CHECKPOINT_CTRL_SECTION context-and-deadline");
    paused = 0;
    command(0, 20); repeat (2) tick();
    module_id = module_id ^ 160'd1;
    response(CP_CONTEXT_CHANGED, 20); consume();
    ok(locked && seal && cp_generation == 1, "identity-change-fails-locked");
    module_id = module_id ^ 160'd1;
    recover(21);
    paused = 0;
    command(0, 22); response(CP_TIMEOUT, 22); consume();
    ok(locked && seal && cp_generation == 1, "deadline-does-not-publish");
    command(1, 23); response(CP_RECOVERY_REQUIRED, 23); consume();
    ok(locked, "locked-retry-requires-producer-reset-or-drain");
    recover(24);

    exhaust_generation = 1;
    command(0, 30); response(CP_GENERATION_EXHAUSTED, 30); consume();
    exhaust_generation = 0;
    ok(!locked && !seal && cp_generation == 1, "generation-never-wraps");

    module_id = module_id ^ 160'd1; repeat (2) tick();
    ok(locked && seal && !result_valid, "idle-identity-loss-locks-without-fabricated-result");
    command(1, 32); response(CP_NOT_READY, 32); consume();
    module_id = module_id ^ 160'd1; repeat (2) tick();
    ok(locked && seal, "returning-context-does-not-auto-open-old-live-RAM");
    recover(33);

    $display("CHECKPOINT_CTRL_SECTION controller-reset");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    ok(initialized && locked && seal && cp_generation == 1,
       "controller-reset-does-not-open-unrestored-checkpoint");
    recover(31);

    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_CTRL_PASS checks=%0d", checks);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "CHECKPOINT_CTRL_TIMEOUT phase=%0d", phase);
  end
endmodule
