// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Direct command-seam component bench. Host quiescence is supplied by the
// driver; this is not native CPU/AXI or physical-persistence qualification.
module tb_g6lc_storamic_checkpoint_media #(
  parameter int unsigned RspCycles = 4
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_checkpoint_pkg::*;
  localparam checkpoint_layout_t Layout = checkpoint_layout(1024, 64, 0, 0);
  logic clk = 0, rst_n = 0, media_rst_n = 1, cut = 1, abort_cp = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  logic [159:0] module_id = 160'h1234;
  logic [31:0] map_generation = 7, reset_generation = 0;
  logic health = 1, pub_req = 0, pub_ack, pub_error, restore = 0, done, restore_error;
  logic [63:0] pub_generation = 0, generation, capacity, reserved;
  logic pub_bank = 0, valid, bank, idle, recovered, metadata_ok, maintenance, degraded;
  logic [5:0] phase;
  logic prepare = 0, commit_cp = 0, prepared, prepared_bank, ram_busy;
  logic mreq, mgnt, mwe, mrv, merr;
  logic [63:0] maddr, mwdata, mrdata;
  logic [7:0] mbe;
  txn_id_t mtag, rtag;
  logic req = 0, we = 0, cpu_gnt, cpu_rv;
  logic [63:0] addr = 0, wdata = 0;
  txn_id_t cpu_tag;
  assign cpu_tag = '{source: 8'd1, default: '0};
  logic ram_gnt, ram_rv, ram_error, ram_owner = 0, grant_enable = 1;
  logic [63:0] ram_rdata;
  assign mgnt = ram_gnt && maintenance;
  assign mrv = ram_rv && ram_owner;
  assign cpu_gnt = ram_gnt && !maintenance;
  assign cpu_rv = ram_rv && !ram_owner;
  assign mrdata = ram_rdata;
  assign merr = ram_error;
  g6lc_storamic_sim_mem #(
    .NumWords(8), .ModelBytes(64), .RspDelay(RspCycles),
    .ExternalCheckpointCommit(1'b1), .ExternalFlashCheckpoint(1'b1)
  ) ram (
    .clk_i(clk), .rst_ni(rst_n), .mem_ready_o(),
    .mem_req_i(grant_enable && (maintenance ? mreq : req)), .mem_gnt_o(ram_gnt),
    .mem_we_i(maintenance ? mwe : we), .mem_addr_i(maintenance ? maddr : addr),
    .mem_wdata_i(maintenance ? mwdata : wdata), .mem_be_i(maintenance ? mbe : 8'hFF),
    .mem_tag_i(maintenance ? mtag : cpu_tag),
    .mem_rvalid_o(ram_rv), .mem_rdata_o(ram_rdata), .mem_error_o(ram_error), .mem_tag_o(rtag),
    .power_cut_i(cut), .save_i(prepare), .restore_i(1'b0),
    .checkpoint_valid_i(valid), .checkpoint_bank_i(bank),
    .checkpoint_commit_i(commit_cp), .checkpoint_abort_i(abort_cp), .maintenance_i(maintenance),
    .checkpoint_prepared_o(prepared), .checkpoint_prepared_bank_o(prepared_bank),
    .save_busy_o(ram_busy), .restore_done_o()
  );
  logic sreq, sgnt, swe, srv, serr, sfreq, sfack, sferr, store_idle;
  logic [63:0] saddr, swdata, srdata;
  logic [7:0] sbe;
  logic raw_mode = 0, raw_req = 0, raw_we = 0, raw_flush = 0;
  logic [63:0] raw_addr = 0, raw_data = 0;
  logic flash_gnt, flash_rv, flash_error, flash_fack, flash_ferr;
  logic [63:0] flash_data;
  assign sgnt = flash_gnt && !raw_mode;
  assign srv = flash_rv && !raw_mode;
  assign srdata = flash_data; assign serr = flash_error;
  assign sfack = flash_fack && !raw_mode; assign sferr = flash_ferr;
  g6lc_storamic_durable_store #(
    .NumWords(128), .StageEntries(4), .RspCycles(RspCycles), .CommitCycles(4)
  ) flash (
    .clk_i(clk), .rst_ni(rst_n), .power_cut_i(cut), .idle_o(store_idle), .drained_o(),
    .st_req_i(raw_mode ? raw_req : sreq), .st_gnt_o(flash_gnt),
    .st_we_i(raw_mode ? raw_we : swe), .st_addr_i(raw_mode ? raw_addr : saddr),
    .st_wdata_i(raw_mode ? raw_data : swdata), .st_be_i(raw_mode ? 8'hFF : sbe),
    .st_rvalid_o(flash_rv), .st_rdata_o(flash_data), .st_err_o(flash_error),
    .st_flush_req_i(raw_mode ? raw_flush : sfreq),
    .st_flush_ack_o(flash_fack), .st_flush_err_o(flash_ferr),
    .save_i(1'b0), .save_done_o(), .cut_count_o(), .commit_gen_o(),
    .journal_gen_o(), .journal_id_o(), .unlock_key_i(32'd0),
    .restore_i(1'b0), .restore_done_o()
  );
  g6lc_storamic_checkpoint_media media (
    .clk_i(clk), .rst_ni(rst_n && media_rst_n),
    .available_i(1'b1), .exclusive_i(1'b1), .protection_ok_i(health),
    .power_cut_i(cut), .module_id_i(module_id), .mapping_generation_i(map_generation),
    .reset_generation_i(reset_generation),
    .publish_req_i(pub_req), .publish_ack_o(pub_ack), .publish_error_o(pub_error),
    .publish_module_id_i(module_id), .publish_mapping_generation_i(map_generation),
    .publish_generation_i(pub_generation), .publish_bank_i(pub_bank), .abort_i(abort_cp),
    .restore_i(restore), .restore_done_o(done), .restore_error_o(restore_error), .restore_busy_o(),
    .idle_o(idle), .recovered_o(recovered), .metadata_ok_o(metadata_ok),
    .checkpoint_valid_o(valid), .checkpoint_bank_o(bank), .checkpoint_generation_o(generation),
    .layout_legal_o(), .user_capacity_bytes_o(capacity), .reserved_bytes_o(reserved),
    .maintenance_o(maintenance), .media_owned_o(), .degraded_o(degraded), .tag_exhausted_o(),
    .stale_event_o(), .error_event_o(), .phase_o(phase), .store_idle_i(store_idle),
    .mem_req_o(mreq), .mem_gnt_i(mgnt), .mem_we_o(mwe),
    .mem_addr_o(maddr), .mem_wdata_o(mwdata), .mem_be_o(mbe), .mem_tag_o(mtag),
    .mem_rvalid_i(mrv), .mem_rdata_i(mrdata), .mem_error_i(merr), .mem_tag_i(rtag),
    .st_req_o(sreq), .st_gnt_i(sgnt), .st_we_o(swe), .st_addr_o(saddr),
    .st_wdata_o(swdata), .st_be_o(sbe), .st_rvalid_i(srv),
    .st_rdata_i(srdata), .st_error_i(serr),
    .st_flush_req_o(sfreq), .st_flush_ack_i(sfack), .st_flush_error_i(sferr)
  );
  int checks = 0, ram_writes = 0, media_writes = 0;
  always @(posedge clk) if (rst_n) begin
    if (ram_gnt) ram_owner <= maintenance;
    if (ram_gnt && maintenance && mwe) ram_writes++;
    if (sgnt && swe) media_writes++;
    assert (!ram.scan_restoring) else $fatal(1, "CHECKPOINT_MEDIA_SHADOW_RESTORE");
    if (prepared && ram_gnt) assert (maintenance && !mwe)
      else $fatal(1, "CHECKPOINT_MEDIA_PREPARED_WRITE");
  end
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_MEDIA_FAIL %s phase=%0d gen=%0d", label, phase, generation);
  endtask
  task automatic wait_idle;
    while (!idle || !recovered) tick();
  endtask
  task automatic access_word(input bit write_word, input int index, input logic [63:0] value);
    req = 1; we = write_word; addr = 64'(index * 8); wdata = value;
    do @(posedge clk); while (!cpu_gnt);
    tick(); req = 0;
    while (!cpu_rv) tick();
    ok(!ram_error && (write_word || ram_rdata == value), "RAM-word");
    tick();
  endtask
  task automatic image(input bit write_words, input logic [63:0] seed);
    for (int i = 0; i < 8; i++) access_word(write_words, i, seed + 64'(i));
  endtask
  task automatic start_save;
    prepare = 1; tick(); prepare = 0;
    while (!prepared) tick();
    pub_bank = prepared_bank; pub_generation = generation + 1; pub_req = 1;
  endtask
  task automatic finish_save(input bit expected_error);
    while (!pub_ack) tick();
    ok(pub_error == expected_error, "publication-verdict");
    pub_req = 0;
    if (!expected_error) begin commit_cp = 1; tick(); commit_cp = 0; end
    wait_idle();
  endtask
  task automatic restore_image(input logic [63:0] seed);
    int before_writes;
    before_writes = ram_writes;
    restore = 1; tick(); restore = 0;
    while (!done) tick();
    ok(!restore_error && ram_writes == before_writes + 8, "flash-to-RAM-restore-completes-all-writes");
    tick(); wait_idle(); image(0, seed);
  endtask
  task automatic reset_controllers;
    rst_n = 0; repeat (3) tick(); reset_generation++;
    rst_n = 1; tick(); wait_idle();
  endtask
  task automatic raw_write(input logic [63:0] offset, input logic [63:0] value);
    ok(idle, "fault-injection-only-while-idle");
    raw_mode = 1; raw_req = 1; raw_we = 1; raw_addr = offset; raw_data = value;
    do @(posedge clk); while (!flash_gnt);
    tick(); raw_req = 0;
    while (!flash_rv) tick();
    ok(!flash_error, "raw-word");
    tick(); raw_flush = 1;
    do tick(); while (!flash_fack);
    ok(!flash_ferr, "raw-flush");
    raw_flush = 0; tick(); raw_mode = 0; raw_we = 0;
  endtask
  task automatic read_record(input logic [63:0] offset, output checkpoint_record_t value);
    value = '0;
    raw_mode = 1; raw_we = 0;
    for (int i = 0; i < 8; i++) begin
      raw_addr = offset + 64'(i * 8); raw_req = 1;
      do @(posedge clk); while (!flash_gnt);
      tick(); raw_req = 0;
      while (!flash_rv) tick();
      ok(!flash_error, "record-read");
      value = decode_word(value, 3'(i), flash_data);
      tick();
    end
    raw_mode = 0;
  endtask
  function automatic checkpoint_record_t rebuild(input checkpoint_record_t original);
    checkpoint_record_t value;
    logic [31:0] crc;
    logic [63:0] word_value;
    value = original; crc = '1;
    for (int i = 0; i < 7; i++) begin
      word_value = record_crc_word(value, 3'(i));
      for (int j = 0; j < 64; j++)
        crc = (crc >> 1) ^ ((crc[0] ^ word_value[j]) ? 32'h82F6_3B78 : 32'd0);
    end
    value.record_crc = ~crc; value.marker = commit_marker(value);
    return value;
  endfunction
  task automatic program_record(input logic [63:0] offset, input checkpoint_record_t value);
    raw_write(offset + 56, 0);
    for (int i = 0; i < 7; i++) raw_write(offset + 64'(i*8), record_word(value, 3'(i)));
    raw_write(offset + 56, value.marker);
  endtask
  checkpoint_record_t original_record, foreign_record, old_record;
  initial begin
    repeat (3) tick(); rst_n = 1; repeat (3) tick(); cut = 0;
    wait_idle();
    ok(metadata_ok && !valid && generation == 0, "factory-blank-recovery");
    ok(capacity == 512 && reserved == 512, "backup-and-records-excluded-from-block-capacity");
    image(1, 64'hA000); start_save(); finish_save(0);
    ok(valid && generation == 1 && bank, "first-record-published");
    image(1, 64'hB000); start_save(); finish_save(0);
    ok(valid && generation == 2 && !bank, "replacement-record-published");

    cut = 1; repeat (3) tick(); cut = 0; wait_idle();
    ok(metadata_ok && valid && generation == 2, "power-loss-rediscovers-latest-complete-record");
    restore_image(64'hB000);

    $display("CHECKPOINT_MEDIA_SECTION interrupted-copy");
    image(1, 64'hC000); start_save();
    while (phase != 19) tick(); // ECopyNvmWait: an inactive-bank write is owned.
    cut = 1; abort_cp = 1; repeat (3) tick(); cut = 0;
    finish_save(1); abort_cp = 0; tick();
    ok(metadata_ok && valid && generation == 2 && !degraded, "cut-retains-old-image-without-false-media-fault");
    restore_image(64'hB000);
    image(1, 64'hC000); start_save(); finish_save(0);
    ok(generation == 3, "save-retries-after-interruption");

    $display("CHECKPOINT_MEDIA_SECTION offered-RAM-drain");
    image(1, 64'hD000); start_save();
    grant_enable = 0;
    while (!mreq) tick();
    abort_cp = 1; repeat (4) tick();
    ok(mreq && !pub_ack, "abort-retains-ungranted-offer");
    grant_enable = 1;
    finish_save(1); abort_cp = 0; tick();
    ok(generation == 3 && metadata_ok, "aborted-offer-drains-under-RAM-abort");
    restore_image(64'hC000);
    image(1, 64'hD000); start_save();
    while (phase != 26 || media.q.word_index < 2) tick(); // EWriteBodyWait.
    cut = 1; abort_cp = 1; repeat (3) tick(); cut = 0;
    finish_save(1); abort_cp = 0; tick();
    ok(generation == 3 && metadata_ok, "torn-record-body-cannot-replace-old-checkpoint");
    restore_image(64'hC000);
    image(1, 64'hD000); start_save();
    while (phase != 29) tick(); // Body is durable; final marker is not issued.
    cut = 1; abort_cp = 1; repeat (3) tick(); cut = 0;
    finish_save(1); abort_cp = 0; tick();
    ok(generation == 3 && metadata_ok, "complete-body-with-zero-marker-is-not-published");
    restore_image(64'hC000);
    image(1, 64'hD000); start_save();
    while (phase != 30 || !flash_rv) tick(); // Marker accepted, final flush not issued.
    media_rst_n = 0; pub_req = 0; abort_cp = 1;
    repeat (3) tick(); reset_generation++; media_rst_n = 1;
    tick(); wait_idle();
    ok(generation == 4 && metadata_ok && !pub_ack,
       "owner-only-reset-rolls-forward-without-fabricated-command-ack");
    cut = 1; repeat (3) tick(); cut = 0; wait_idle(); abort_cp = 0; tick();
    ok(generation == 4 && metadata_ok, "recovery-selection-survives-loss-of-staging");
    restore_image(64'hD000);

    reset_controllers();
    ok(valid && generation == 4 && metadata_ok, "controller-reset-recovers-media-not-selector-flops");
    restore_image(64'hD000);

    $display("CHECKPOINT_MEDIA_SECTION interrupted-restore");
    image(1, 64'hE000);
    restore = 1; tick(); restore = 0;
    while (phase != 34 || media.q.index < 2) tick(); // EWriteRamWait.
    cut = 1; abort_cp = 1; repeat (3) tick(); cut = 0;
    while (!done) tick();
    ok(restore_error, "partial-restore-never-completes-successfully");
    wait_idle(); abort_cp = 0; tick();
    ok(valid && generation == 4, "restore-does-not-change-backup-generation");
    restore_image(64'hD000);

    module_id = module_id ^ 160'd1; tick(); wait_idle();
    ok(!metadata_ok && !valid, "foreign-identity-is-not-factory-blank-or-rollback");
    module_id = module_id ^ 160'd1; tick(); wait_idle();
    ok(metadata_ok && generation == 4, "original-identity-can-recover");
    map_generation = 8; tick(); wait_idle();
    ok(!metadata_ok && !valid, "foreign-map-rejected");
    map_generation = 7; tick(); wait_idle();
    restore_image(64'hD000);

    $display("CHECKPOINT_MEDIA_SECTION foreign-layout-and-exhaustion");
    read_record(Layout.record0, original_record);
    foreign_record = original_record; foreign_record.image_bytes = 128;
    foreign_record = rebuild(foreign_record);
    program_record(Layout.record0, foreign_record);
    reset_controllers();
    ok(!metadata_ok && !valid, "newer-foreign-size-blocks-silent-rollback-to-old-map");
    program_record(Layout.record0, original_record);
    reset_controllers();
    ok(metadata_ok && generation == 4, "fixed-slot-can-recover-original-layout");
    read_record(Layout.record1, old_record);
    foreign_record = old_record; foreign_record.generation = '1;
    foreign_record = rebuild(foreign_record);
    program_record(Layout.record1, foreign_record);
    reset_controllers();
    ok(metadata_ok && generation == '1, "maximum-generation-is-recoverable");
    start_save();
    begin : generation_refusal
      int before_writes;
      before_writes = media_writes;
      finish_save(1); abort_cp = 1; tick(); abort_cp = 0;
      ok(media_writes == before_writes && generation == '1, "maximum-generation-refuses-wrap-without-writes");
    end
    program_record(Layout.record1, old_record);
    reset_controllers();
    restore_image(64'hD000);

    $display("CHECKPOINT_MEDIA_SECTION CRC-fallback");
    raw_write(Layout.image0, 64'hBAD0_BAD0);
    reset_controllers();
    ok(metadata_ok && valid && generation == 3 && degraded, "corrupt-newest-image-falls-back-degraded");
    restore_image(64'hC000);
    start_save();
    begin : degraded_refusal
      int before_writes;
      before_writes = media_writes;
      finish_save(1); abort_cp = 1; tick(); abort_cp = 0;
      ok(media_writes == before_writes && generation == 3, "degraded-save-refuses-without-media-writes");
    end
    raw_write(Layout.record1 + 56, 0);
    reset_controllers();
    ok(recovered && !metadata_ok && !valid, "nonblank-invalid-media-is-not-factory-empty");
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_MEDIA_PASS checks=%0d rsp_cycles=%0d", checks, RspCycles);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "CHECKPOINT_MEDIA_TIMEOUT phase=%0d", phase);
  end
endmodule
