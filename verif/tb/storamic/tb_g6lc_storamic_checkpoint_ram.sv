// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// The external selector is a metadata-owner fixture, not a persistence record.
module tb_g6lc_storamic_checkpoint_ram #(
  parameter int unsigned RspCycles = 0
);
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  logic req = 0, gnt, we = 0, rv, err;
  logic [63:0] addr = 0, wdata = 0, rdata;
  logic cut = 0, save = 0, restore = 0, busy, done;
  logic valid = 0, bank = 0, commit_cp = 0, abort_cp = 0, prepared, prepared_bank;
  int checks = 0;
  logic response_owned = 0;
  always @(posedge clk) begin
    if (!rst_n) response_owned <= 0;
    else begin
      if (gnt) begin
        assert (!response_owned) else $fatal(1, "CHECKPOINT_RAM_ASSERT duplicate-grant");
        response_owned <= 1;
      end
      if (rv) begin
        assert (response_owned) else $fatal(1, "CHECKPOINT_RAM_ASSERT unsolicited-response");
        response_owned <= 0;
      end
      if (prepared) assert (busy && !gnt)
        else $fatal(1, "CHECKPOINT_RAM_ASSERT prepared-not-frozen");
      if (cut || abort_cp) assert (!done)
        else $fatal(1, "CHECKPOINT_RAM_ASSERT cancelled-completion");
    end
  end

  g6lc_storamic_sim_mem #(
    .DataWidth(64), .NumWords(8), .ModelBytes(64'd64), .RspDelay(RspCycles),
    .ExternalCheckpointCommit(1'b1)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .mem_ready_o(),
    .mem_req_i(req), .mem_gnt_o(gnt), .mem_we_i(we), .mem_addr_i(addr),
    .mem_wdata_i(wdata), .mem_be_i(8'hFF), .mem_tag_i('0),
    .mem_rvalid_o(rv), .mem_rdata_o(rdata), .mem_error_o(err), .mem_tag_o(),
    .power_cut_i(cut), .save_i(save), .restore_i(restore),
    .checkpoint_valid_i(valid), .checkpoint_bank_i(bank),
    .checkpoint_commit_i(commit_cp), .checkpoint_abort_i(abort_cp), .maintenance_i(1'b0),
    .checkpoint_prepared_o(prepared), .checkpoint_prepared_bank_o(prepared_bank),
    .save_busy_o(busy), .restore_done_o(done)
  );

  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_RAM_FAIL %s", label);
  endtask
  task automatic access_word(input bit write_word, input int index,
                             input logic [63:0] value);
    req = 1; we = write_word; addr = 64'(index * 8); wdata = value;
    do @(posedge clk); while (!gnt);
    tick(); req = 0;
    while (!rv) tick();
    ok(!err && (write_word || rdata == value), "memory-word");
    tick();
  endtask
  task automatic image(input bit write_image, input logic [63:0] seed);
    for (int i = 0; i < 8; i++) access_word(write_image, i, seed + 64'(i));
  endtask
  task automatic start_save;
    save = 1; tick(); save = 0;
  endtask
  task automatic prepare_image;
    start_save();
    while (!prepared) tick();
    ok(busy && prepared_bank != bank, "inactive-bank-prepared");
  endtask
  task automatic publish_image;
    bank = prepared_bank; valid = 1;
    commit_cp = 1; tick(); commit_cp = 0; tick();
    ok(!prepared && !busy, "published-image-released");
  endtask
  task automatic restore_image;
    restore = 1; tick(); restore = 0;
    while (!done) tick();
    ok(!busy, "restore-completes-after-scan");
    tick();
  endtask
  task automatic cut_and_clear;
    cut = 1; repeat (3) tick();
    ok(!prepared && !done, "cut-without-publication-or-completion");
    cut = 0; tick();
    abort_cp = 1; repeat (2) tick(); abort_cp = 0;
    ok(busy, "abort-does-not-cancel-volatile-clear");
    while (busy) tick();
  endtask

  initial begin
    repeat (3) tick(); rst_n = 1; repeat (2) tick();
    restore = 1; tick(); restore = 0; repeat (3) tick();
    ok(!busy && !done && !prepared, "invalid-checkpoint-not-restored");

    image(1, 64'h1000);
    start_save();
    commit_cp = 1; tick(); commit_cp = 0;
    ok(!prepared && !valid, "premature-commit-cannot-publish");
    while (!prepared) tick();
    req = 1;
    repeat (4) begin tick(); ok(!gnt && busy && prepared, "prepared-freezes-admission"); end
    req = 0;
    abort_cp = 1; tick(); abort_cp = 0; tick();
    ok(!busy && !prepared && !valid, "abort-releases-unpublished-image");
    image(0, 64'h1000);
    prepare_image(); publish_image();

    image(1, 64'h2000);
    prepare_image();
    cut_and_clear();
    // Clearing is zero fill, not the patterned image helper.
    for (int i = 0; i < 8; i++) access_word(0, i, 0);
    restore_image(); image(0, 64'h1000);

    image(1, 64'h3000);
    start_save(); repeat (3) tick();
    abort_cp = 1; tick(); abort_cp = 0; tick();
    ok(!busy && !prepared, "mid-save-aborted");
    restore_image(); image(0, 64'h1000);

    // Selected-bank lifetime starts at control acceptance, not scan completion.
    restore = 1; tick(); restore = 0;
    bank = !bank;
    while (!done) tick();
    bank = !bank; tick();
    image(0, 64'h1000);

    // Reset the controller only. Checkpoint SRAM bytes and fixture metadata
    // remain, while the DUT's legacy saved/bank flops are reset.
    image(1, 64'h4000);
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (2) tick();
    restore_image(); image(0, 64'h1000);

    image(1, 64'h5000);
    prepare_image(); publish_image();
    cut_and_clear(); restore_image(); image(0, 64'h5000);

    restore = 1; tick(); restore = 0; repeat (3) tick();
    cut_and_clear(); restore_image(); image(0, 64'h5000);

    // Abort at the last restore write must not emit false completion.
    restore = 1; tick(); restore = 0; repeat (9) tick();
    abort_cp = 1;
    tick(); ok(!done, "aborted-restore-has-no-completion");
    abort_cp = 0; tick();
    ok(!done, "no-delayed-abort-completion");
    restore_image(); image(0, 64'h5000);

    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_RAM_PASS checks=%0d rsp_cycles=%0d", checks, RspCycles);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "CHECKPOINT_RAM_TIMEOUT");
  end
endmodule
