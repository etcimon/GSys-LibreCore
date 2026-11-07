// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Directed unit bench for g6lc_storamic_durable_store — the flash-chip
// commit-boundary model. Covers the paths the end-to-end VirtIO test does
// not reach: byte-enable merge into staging, out-of-range completion,
// spill-on-full, staged drops and journaled replay across a power cut, and
// the recovery counters. Small parameters make staging fill quickly.
module tb_g6lc_storamic_durable_store #(
  parameter int unsigned StoreRspCycles = 0
);
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask

  logic req = 0, gnt, we = 0;
  logic [63:0] addr = 0, wdata = 0, rdata;
  logic [7:0] be = 0;
  logic rv, err, cut = 0;
  logic freq = 0, fack, ferr;
  logic [31:0] cuts, gen;
  logic save = 0, save_done, idle, drained;
  logic [31:0] unlock_key = 0;

  // Second DUT: the volatile RAM chip (sim_mem) — save/restore shadow.
  logic mreq = 0, mgnt, mwe = 0, mrv, merr, mcut = 0, msave = 0, mrest = 0;
  logic mbusy, mdone;
  logic [63:0] maddr = 0, mwdata = 0, mrdata;
  logic [7:0] mbe = 0;
  g6lc_storamic_pkg::txn_id_t mtag_i, mtag_o;
  assign mtag_i = '0;
  g6lc_storamic_sim_mem #(
    .DataWidth(64), .NumWords(16), .ModelBytes(64'd128), .RspDelay(StoreRspCycles)
  ) i_ram (
    .clk_i(clk), .rst_ni(rst_n),
    .mem_ready_o(), .mem_req_i(mreq), .mem_gnt_o(mgnt), .mem_we_i(mwe),
    .mem_addr_i(maddr), .mem_wdata_i(mwdata), .mem_be_i(mbe),
    .mem_tag_i(mtag_i), .mem_rvalid_o(mrv), .mem_rdata_o(mrdata),
    .mem_error_o(merr), .mem_tag_o(mtag_o),
    .power_cut_i(mcut), .save_i(msave), .restore_i(mrest),
    .checkpoint_valid_i(1'b0), .checkpoint_bank_i(1'b0),
    .checkpoint_commit_i(1'b0), .checkpoint_abort_i(1'b0), .maintenance_i(1'b0),
    .checkpoint_prepared_o(), .checkpoint_prepared_bank_o(),
    .save_busy_o(mbusy), .restore_done_o(mdone)
  );

  task automatic mwr(input logic [63:0] a, input logic [63:0] d);
    mreq = 1; mwe = 1; maddr = a; mwdata = d; mbe = 8'hFF;
    do tick; while (!mrv);
    mreq = 0; mwe = 0;
    tick;
  endtask
  task automatic mrd(input logic [63:0] a);
    mreq = 1; mwe = 0; maddr = a;
    do tick; while (!mrv);
    rdv = mrdata;
    mreq = 0;
    tick;
  endtask

  g6lc_storamic_durable_store #(
    .NumWords(64), .StageEntries(4), .RspCycles(StoreRspCycles), .CommitCycles(4)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .power_cut_i(cut),
    .st_req_i(req), .st_gnt_o(gnt), .st_we_i(we), .st_addr_i(addr),
    .st_wdata_i(wdata), .st_be_i(be), .st_rvalid_o(rv),
    .st_rdata_o(rdata), .st_err_o(err),
    .st_flush_req_i(freq), .st_flush_ack_o(fack), .st_flush_err_o(ferr),
    .cut_count_o(cuts), .commit_gen_o(gen),
    .journal_gen_o(jgen), .journal_id_o(jid),
    .save_i(save), .save_done_o(save_done),
    .unlock_key_i(unlock_key), .restore_i(1'b0), .restore_done_o(),
    .idle_o(idle), .drained_o(drained)
  );
  logic [31:0] jgen, jid;
  int grants = 0, responses = 0;
  int flush_errors = 0, flush_successes = 0;

  initial begin
    repeat (10000) tick;
    $fatal(1, "DSTORE_TIMEOUT");
  end

  always @(posedge clk) begin
    if (rst_n) begin
      if (gnt) grants++;
      if (rv) responses++;
      if (fack && ferr) flush_errors++;
      if (fack && !ferr) flush_successes++;
      if (responses > grants) $fatal(1, "DSTORE_UNOWNED_RESPONSE");
    end
    if (rst_n && dut.sram_write &&
        (cut || dut.commit_cnt_q != 0))
      $fatal(1, "DSTORE_EARLY_COMMIT");
    if (rst_n && cut && drained) $fatal(1, "DSTORE_DRAINED_DURING_CUT");
    if (rst_n && i_ram.scan_saving &&
        (mrv || i_ram.rsp_cnt_q != 0))
      $fatal(1, "RAM_SAVE_BEFORE_RESPONSE_DRAIN");
    if (rst_n && mcut && (i_ram.sram_req || i_ram.checkpoint_req || mdone))
      $fatal(1, "RAM_WRITE_OR_RESTORE_DONE_DURING_CUT");
  end

  int checks = 0, fails = 0;
  task automatic chk(input logic c, input string n);
    checks++;
    if (!c) begin fails++; $display("DSTORE_CHECK_FAIL %s", n); end
  endtask

  // Hold the request until rvalid arrives (registered, sampled at negedge).
  // The grant is implied by rvalid's response window, so there is no need to
  // sample the combinational grant at a clock edge.
  logic werr;
  task automatic wr(input logic [63:0] a, input logic [63:0] d,
                    input logic [7:0] b = 8'hFF);
    req = 1; we = 1; addr = a; wdata = d; be = b;
    do tick; while (!rv);
    werr = err;                         // err is valid only in the rsp window
    req = 0; we = 0;
    tick;
  endtask

  logic [63:0] rdv;
  logic rde;
  task automatic rd(input logic [63:0] a);
    req = 1; we = 0; addr = a;
    do tick; while (!rv);
    rdv = rdata; rde = err;
    req = 0;
    tick;
  endtask

  task automatic fl;
    freq = 1;
    do tick; while (!fack);
    freq = 0;
    tick;
  endtask

  task automatic pcut(input int n);
    cut = 1;
    repeat (n) tick;
    cut = 0;
    tick;
  endtask

  initial begin
    tick; tick; rst_n = 1; tick;
    chk(idle && drained, "empty powered store is drained");
    $display("PHASE A");

    // A: staged read-own-writes, byte-enable merge, OOB completion.
    wr(64'h00, 64'hAAAA_0000_1111_2222);
    chk(idle && !drained, "idle dirty staging retains ownership");
    wr(64'h08, 64'hBBBB_CCCC_DDDD_EEEE);
    rd(64'h08); chk(rdv == 64'hBBBB_CCCC_DDDD_EEEE, "staging read-own");
    wr(64'h08, 64'h0000_0000_DEAD_BEEF, 8'h0F);
    rd(64'h08); chk(rdv == 64'hBBBB_CCCC_DEAD_BEEF, "staging merge");
    wr(64'h208, 64'h0);                 // out of range: grant + error
    chk(werr, "oob write error");
    rd(64'h208); chk(rde, "oob read error");
    fl();    chk(gen == 1, "flush 1 gen");
             chk(idle && drained, "completed flush releases ownership");
             chk(cuts == 0, "no cuts yet");

    // B: commit a baseline X0..X19.
    $display("PHASE B");
    for (int i = 0; i < 20; i++) wr(64'(i * 8), 64'h1000 + i);
    fl();
    rd(64'h28); chk(rdv == 64'h1005, "committed baseline");

    // C: staged writes drop on a cut; committed data survives.
    $display("PHASE C");
    for (int i = 4; i < 8; i++) wr(64'(i * 8), 64'h2BAD_0000 + i);
    pcut(8);
    for (int i = 4; i < 8; i++) begin
      rd(64'(i * 8)); chk(rdv == 64'h1000 + i, "staged drop");
    end
    chk(cuts == 1, "cut counted");

    // D: spill commits the head when staging fills mid-request.
    $display("PHASE D");
    for (int i = 8; i < 13; i++) wr(64'(i * 8), 64'h3000 + i);
    fl();
    for (int i = 8; i < 13; i++) begin
      rd(64'(i * 8)); chk(rdv == 64'h3000 + i, "spill+flush");
    end

    // E: journal replay — cut inside the spill drain keeps the in-commit
    // head (word 16) while the rest of staging drops.
    $display("PHASE E");
    for (int i = 16; i < 20; i++) wr(64'(i * 8), 64'h4000 + i);
    // w20 needs a slot: the spill drain of w16 starts; cut mid-drain.
    req = 1; we = 1; addr = 64'hA0; wdata = 64'h5000; be = 8'hFF;
    tick; tick;                       // drain of w16 in progress
    chk(!dut.sram_write, "no SRAM write before commit boundary");
    pcut(8);
    chk(dut.replay_q && dut.count_q == 1, "held cut retains journal head");
    pcut(3);                          // interrupt the replay itself
    do tick; while (!rv);             // held until replay + grant completes
    req = 0; we = 0;
    tick;
    fl();
    rd(64'h80); chk(rdv == 64'h4010, "journaled head replayed");
    rd(64'h88); chk(rdv == 64'h1011, "staged tail dropped");
    rd(64'h90); chk(rdv == 64'h1012, "staged tail dropped 2");
    rd(64'h98); chk(rdv == 64'h1013, "staged tail dropped 3");
    rd(64'hA0); chk(rdv == 64'h5000, "post-cut write lands");
    chk(cuts == 3, "repeated cut counted");
    chk(gen == 4, "recovery epochs");

    // F: RAM volatility + save/restore (stick's RAM chip).
    $display("PHASE F");
    mrest = 1; tick; mrest = 0;
    repeat (3) tick;
    chk(!mdone && !mbusy, "restore without checkpoint refused");
    for (int i = 0; i < 4; i++) mwr(64'(i * 8), 64'hA000 + i);
    mrd(64'h08); chk(rdv == 64'hA001, "ram baseline");
    mcut = 1; tick; tick; mcut = 0; tick;
    mrd(64'h08); chk(rdv == 64'h0, "ram volatile loss");
    mwr(64'h00, 64'hB000); mwr(64'h08, 64'hB001);
    mwr(64'h10, 64'hB002); mwr(64'h18, 64'hB003);
    msave = 1; tick; msave = 0;       // snapshot (scan ~NumWords+1 cycles)
    while (mbusy) tick;
    mwr(64'h00, 64'hC000);              // post-save change must not restore
    mcut = 1; tick; tick; mcut = 0; tick;
    mrd(64'h00); chk(rdv == 64'h0, "ram lost after save");
    mrest = 1; tick; mrest = 0;
    while (!mdone) tick; tick;
    mrd(64'h00); chk(rdv == 64'hB000, "restore word0");
    mrd(64'h18); chk(rdv == 64'hB003, "restore word3");
    // A torn replacement must retain the previous complete checkpoint.
    mwr(64'h00, 64'hC111);
    msave = 1; tick; msave = 0;
    while (!i_ram.scan_saving) tick;
    repeat (3) tick;
    mcut = 1; tick; mcut = 0; tick;   // tear the in-flight save
    while (mbusy) tick;
    mrd(64'h00); chk(rdv == 64'h0, "save tear drops contents");
    mrest = 1; tick; mrest = 0;
    while (!mdone) tick;
    tick;
    mrd(64'h00); chk(rdv == 64'hB000, "torn save retains previous checkpoint");
    mrd(64'h18); chk(rdv == 64'hB003, "previous checkpoint tail retained");
    // Restore interruption must not destroy the retained checkpoint either.
    mrest = 1; tick; mrest = 0;
    while (!i_ram.scan_restoring) tick;
    repeat (3) tick;
    mcut = 1; repeat (3) tick; mcut = 0; tick;
    while (mbusy) tick;
    mrd(64'h00); chk(rdv == 0, "partial restore hidden after cut");
    mrest = 1; tick; mrest = 0;
    while (!mdone) tick;
    tick;
    mrd(64'h00); chk(rdv == 64'hB000, "restore can retry after interruption");

    // A save pulse during a pending write must drain its completion. Keep
    // live WE asserted throughout the scan to expose accidental scan writes.
    for (int i = 0; i < 16; i++) mwr(64'(i * 8), 64'hD000 + 64'(i));
    mreq = 1; mwe = 1; maddr = 0; mwdata = 64'hE000; mbe = '1;
    tick; mreq = 0;
    msave = 1; tick; msave = 0;
    while (mbusy) tick;
    mwe = 0;
    mcut = 1; tick; tick; mcut = 0; tick;
    mrest = 1; tick; mrest = 0;     // queue restore behind volatile clear
    while (!mdone) tick;
    tick;
    for (int i = 0; i < 16; i++) begin
      mrd(64'(i * 8));
      chk(rdv == (i == 0 ? 64'hE000 : 64'hD000 + 64'(i)),
          "new complete checkpoint published");
    end
    mwr(0, 64'hF000);
    msave = 1; tick; msave = 0;
    while (!(i_ram.scan_saving &&
             i_ram.scan_has_q && i_ram.scan_rd_q == 15)) tick;
    mcut = 1; tick; tick; mcut = 0; tick;  // cut at publication boundary
    while (mbusy) tick;
    mrest = 1; tick; mrest = 0;
    while (!mdone) tick;
    tick;
    mrd(0); chk(rdv == 64'hE000, "publication-edge cut keeps last valid image");

    // G: save drains exactly once, including the already-empty case.
    $display("PHASE G");
    save = 1; tick; save = 0;
    chk(!save_done, "locked save refused");
    unlock_key = 32'h5354524D;
    save = 1; tick; save = 0;
    chk(save_done, "empty save completes");
    tick;
    chk(!save_done, "save completion is a pulse");
    wr(64'h00, 64'hABCD);
    wr(64'h08, 64'hEF01);
    save = 1; tick; save = 0;
    while (!save_done) tick;
    chk(dut.count_q == 0, "save drained all entries");
    tick;
    pcut(4);
    rd(64'h00); chk(rdv == 64'hABCD, "saved flash survives cut");
    rd(64'h08); chk(rdv == 64'hEF01, "saved flash tail survives cut");
    begin
      logic [31:0] before_gen;
      before_gen = gen;
      freq = 1;
      do tick; while (!fack);
      repeat (3) tick;
      chk(gen == before_gen + 1, "held flush increments generation once");
      chk(!fack, "held flush does not repeat acknowledgement");
      freq = 0; tick;
    end

    // H: staged byte masks overlay committed bytes, never raw invalid lanes.
    $display("PHASE H");
    wr(64'h30, 64'h1122_3344_5566_7788);
    fl();
    wr(64'h30, 64'hFFFF_FFFF_DEAD_BEEF, 8'h0F);
    rd(64'h30);
    chk(rdv == 64'h1122_3344_DEAD_BEEF, "partial stage overlays committed bytes");
    wr(64'h30, 64'hAABB_CCDD_0000_0000, 8'hF0);
    rd(64'h30);
    chk(rdv == 64'hAABB_CCDD_DEAD_BEEF, "complementary stage masks merge");
    wr(64'h30, '0, 8'h00);
    rd(64'h30);
    chk(rdv == 64'hAABB_CCDD_DEAD_BEEF, "zero mask preserves staged bytes");
    fl();
    wr(64'h30, 64'h1234, 8'h03);
    rd(64'h30);
    chk(rdv == 64'hAABB_CCDD_DEAD_1234, "partial stage after flush");
    pcut(3);
    rd(64'h30);
    chk(rdv == 64'hAABB_CCDD_DEAD_BEEF, "cut drops partial overlay");

    // I: changing live inputs cannot replace the response owned at grant.
    $display("PHASE I");
    req = 1; we = 0; addr = 64'h30;
    tick;                            // idle DUT accepted exactly one command
    addr = 64'h208; we = 1; wdata = '1; be = '1;
    while (!rv) begin
      chk(!gnt, "no second grant before response");
      tick;
    end
    chk(!gnt, "no grant in response window");
    chk(!err && rdata == 64'hAABB_CCDD_DEAD_BEEF, "response ignores live inputs");
    req = 0; we = 0; tick;
    chk(grants == responses, "one completion per accepted access");

    // A flush must wait for the outstanding store response as well as data.
    req = 1; we = 1; addr = 64'h38; wdata = 64'hCAFE; be = '1;
    tick; req = 0; we = 0; freq = 1;
    while (!rv) begin
      chk(!fack, "flush waits for pending response");
      tick;
    end
    chk(!fack, "flush cannot acknowledge in response window");
    do tick; while (!fack);
    freq = 0; tick;
    rd(64'h38); chk(rdv == 64'hCAFE, "flush commits delayed write");

    if (StoreRspCycles > 0) begin
      // A held cut completes an accepted access with one error, not a stream.
      req = 1; we = 0; addr = 64'h30;
      tick; req = 0; cut = 1;
      tick;
      chk(rv && err && rdata == 0, "pending read cut completes with error");
      repeat (4) tick;
      chk(!rv, "held cut does not repeat completion");
      cut = 0; tick;
      chk(grants == responses, "cut response retires exactly once");
      rd(64'h30);
      chk(!rde && rdv == 64'hAABB_CCDD_DEAD_BEEF, "post-cut response recovers");
    end
    // A cut cannot turn an interrupted FLUSH into a fresh successful one
    // merely because the requester keeps its valid asserted.
    $display("PHASE J");
    begin : flush_cut_case
      logic [63:0] committed_tail;
      logic [31:0] before_gen;
      int errors_before, successes_before;
      fl();
      rd(64'h08); committed_tail = rdv;
      before_gen = gen;
      errors_before = flush_errors; successes_before = flush_successes;
      wr(64'h00, 64'hD00D_0000);
      wr(64'h08, 64'hD00D_0001);
      freq = 1; tick; tick;
      cut = 1; tick;
      chk(fack && ferr, "interrupted flush returns error");
      repeat (5) tick;
      chk(!fack && !ferr, "held cut does not repeat flush completion");
      cut = 0; repeat (32) tick;
      chk(flush_errors == errors_before + 1 && flush_successes == successes_before,
          "held request cannot become post-cut success");
      chk(gen == before_gen, "failed flush does not advance generation");
      freq = 0; tick;
      rd(64'h08); chk(rdv == committed_tail, "interrupted flush drops uncommitted tail");
      fl();
      chk(gen == before_gen + 1, "new flush can retry after failed request retires");
    end
    $display("PHASE K");
    begin : flush_cut_edges
      logic [31:0] completed_gen;
      int errors_before;
      freq = 1;
      do tick; while (!fack);
      chk(!ferr, "empty flush succeeds before cut");
      completed_gen = gen; errors_before = flush_errors;
      cut = 1; repeat (3) tick;
      chk(!fack && !ferr && flush_errors == errors_before,
          "completed held flush is not failed again by cut");
      cut = 0; repeat (5) tick;
      chk(!fack && gen == completed_gen, "completed held flush is not acknowledged again");
      freq = 0; tick;

      cut = 1; repeat (3) tick;
      freq = 1; tick;
      chk(fack && ferr, "flush offered during held cut fails once");
      repeat (3) tick;
      cut = 0; repeat (5) tick;
      chk(!fack && !ferr && gen == completed_gen,
          "late cut flush does not become powered success");
      freq = 0; tick;
      fl();
      chk(gen == completed_gen + 1, "flush resumes after late cut refusal retires");
    end
    chk(grants == responses, "all commands retired");
    if ($test$plusargs("oracle_negative"))
      chk(rdv == 64'hBAD0_BAD0_BAD0_BAD0, "negative oracle");

    if (fails == 0)
      $display("DSTORE_PASS checks=%0d rsp_cycles=%0d", checks, StoreRspCycles);
    else            $display("DSTORE_FAIL fails=%0d/%0d", fails, checks);
    if (fails != 0) $fatal(1, "DSTORE_FAILED");
    $finish;
  end
endmodule
