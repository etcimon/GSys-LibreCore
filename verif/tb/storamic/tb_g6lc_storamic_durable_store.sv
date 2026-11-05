// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Directed unit bench for g6lc_storamic_durable_store — the flash-chip
// commit-boundary model. Covers the paths the end-to-end VirtIO test does
// not reach: byte-enable merge into staging, out-of-range completion,
// spill-on-full, staged drops and journaled replay across a power cut, and
// the recovery counters. Small parameters make staging fill quickly.
module tb_g6lc_storamic_durable_store;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask

  logic req = 0, gnt, we = 0;
  logic [63:0] addr = 0, wdata = 0, rdata;
  logic [7:0] be = 0;
  logic rv, err, cut = 0;
  logic freq = 0, fack, ferr;
  logic [31:0] cuts, gen;

  // Second DUT: the volatile RAM chip (sim_mem) — save/restore shadow.
  logic mreq = 0, mgnt, mwe = 0, mrv, merr, mcut = 0, msave = 0, mrest = 0;
  logic mbusy, mdone;
  logic [63:0] maddr = 0, mwdata = 0, mrdata;
  logic [7:0] mbe = 0;
  g6lc_storamic_pkg::txn_id_t mtag_i, mtag_o;
  assign mtag_i = '0;
  g6lc_storamic_sim_mem #(
    .DataWidth(64), .NumWords(16), .ModelBytes(64'd128), .RspDelay(0)
  ) i_ram (
    .clk_i(clk), .rst_ni(rst_n),
    .mem_ready_o(), .mem_req_i(mreq), .mem_gnt_o(mgnt), .mem_we_i(mwe),
    .mem_addr_i(maddr), .mem_wdata_i(mwdata), .mem_be_i(mbe),
    .mem_tag_i(mtag_i), .mem_rvalid_o(mrv), .mem_rdata_o(mrdata),
    .mem_error_o(merr), .mem_tag_o(mtag_o),
    .power_cut_i(mcut), .save_i(msave), .restore_i(mrest),
    .save_busy_o(mbusy), .restore_done_o(mdone)
  );

  task automatic mwr(input logic [63:0] a, input logic [63:0] d);
    mreq <= 1; mwe <= 1; maddr <= a; mwdata <= d; mbe <= 8'hFF;
    do @(posedge clk); while (!mgnt);
    mreq <= 0; mwe <= 0;
    tick; while (!mrv) tick;
    tick;
  endtask
  task automatic mrd(input logic [63:0] a);
    mreq <= 1; mwe <= 0; maddr <= a;
    do @(posedge clk); while (!mgnt);
    mreq <= 0;
    tick; while (!mrv) tick;
    rdv = mrdata;
    tick;
  endtask

  g6lc_storamic_durable_store #(
    .NumWords(64), .StageEntries(4), .RspCycles(0), .CommitCycles(4)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .power_cut_i(cut),
    .st_req_i(req), .st_gnt_o(gnt), .st_we_i(we), .st_addr_i(addr),
    .st_wdata_i(wdata), .st_be_i(be), .st_rvalid_o(rv),
    .st_rdata_o(rdata), .st_err_o(err),
    .st_flush_req_i(freq), .st_flush_ack_o(fack), .st_flush_err_o(ferr),
    .cut_count_o(cuts), .commit_gen_o(gen)
  );

  int checks = 0, fails = 0;
  task automatic chk(input logic c, input string n);
    checks++;
    if (!c) begin fails++; $display("DSTORE_CHECK_FAIL %s", n); end
  endtask

  task automatic wr(input logic [63:0] a, input logic [63:0] d,
                    input logic [7:0] b = 8'hFF);
    req <= 1; we <= 1; addr <= a; wdata <= d; be <= b;
    begin int guard = 0;
      repeat (10) begin
        @(posedge clk);
        $display("wrw: req=%b we=%b gnt=%b room=%b merge=%b commit=%b flush=%b cut=%b cnt=%0d spill=%b save=%b",
                 req, we, gnt, dut.write_room, dut.merge_hit, dut.commit_q,
                 dut.flush_q, cut, dut.count_q, dut.need_spill, dut.save_q);
        if (gnt) break;
      end
    end
    req <= 0; we <= 0;
    tick; while (!rv) tick;            // rvalid is high in [pos,pos+1)
    tick;
  endtask

  logic [63:0] rdv;
  logic rde;
  task automatic rd(input logic [63:0] a);
    req <= 1; we <= 0; addr <= a;
    do @(posedge clk); while (!gnt);
    req <= 0;
    tick; while (!rv) tick;
    rdv = rdata; rde = err;
    tick;
  endtask

  task automatic fl;
    freq <= 1;
    do @(posedge clk); while (!fack);
    freq <= 0;
    tick;
  endtask

  task automatic pcut(input int n);
    cut <= 1;
    repeat (n) tick;
    cut <= 0;
    tick;
  endtask

  initial begin
    tick; tick; rst_n <= 1; tick;
    $display("PHASE A");

    // A: staged read-own-writes, byte-enable merge, OOB completion.
    $display("probe: gnt=%b in_range=%b commit=%b flush=%b count=%0d cut=%b",
             gnt, dut.in_range, dut.commit_q, dut.flush_q, dut.count_q, cut);
    wr(64'h00, 64'hAAAA_0000_1111_2222); $display("A1");
    wr(64'h08, 64'hBBBB_CCCC_DDDD_EEEE); $display("A2");
    rd(64'h08); chk(rdv == 64'hBBBB_CCCC_DDDD_EEEE, "staging read-own"); $display("A3");
    wr(64'h08, 64'h0000_0000_DEAD_BEEF, 8'h0F); $display("A4");
    rd(64'h08); chk(rdv == 64'hBBBB_CCCC_DEAD_BEEF, "staging merge"); $display("A5");
    wr(64'h208, 64'h0);                 // out of range: grant + error
    chk(err, "oob write error"); $display("A6");
    rd(64'h208); chk(rde, "oob read error"); $display("A7");
    fl();    chk(gen == 1, "flush 1 gen"); $display("A8");
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
    req <= 1; we <= 1; addr <= 64'hA0; wdata <= 64'h5000; be <= 8'hFF;
    tick; tick;                       // drain of w16 in progress
    pcut(8);
    do @(posedge clk); while (!gnt);  // held until replay completes
    req <= 0; we <= 0;
    tick; while (!rv) tick;
    tick;
    fl();
    rd(64'h80); chk(rdv == 64'h4010, "journaled head replayed");
    rd(64'h88); chk(rdv == 64'h1011, "staged tail dropped");
    rd(64'h90); chk(rdv == 64'h1012, "staged tail dropped 2");
    rd(64'h98); chk(rdv == 64'h1013, "staged tail dropped 3");
    rd(64'hA0); chk(rdv == 64'h5000, "post-cut write lands");
    chk(cuts == 2, "second cut counted");
    chk(gen == 4, "recovery epochs");

    // F: RAM volatility + save/restore (stick's RAM chip).
    $display("PHASE F");
    for (int i = 0; i < 4; i++) mwr(64'(i * 8), 64'hA000 + i);
    mrd(64'h08); chk(rdv == 64'hA001, "ram baseline");
    mcut <= 1; tick; tick; mcut <= 0; tick;
    mrd(64'h08); chk(rdv == 64'h0, "ram volatile loss");
    mwr(64'h00, 64'hB000); mwr(64'h08, 64'hB001);
    mwr(64'h10, 64'hB002); mwr(64'h18, 64'hB003);
    msave <= 1; tick; msave <= 0;       // snapshot (scan ~NumWords+1 cycles)
    while (mbusy) tick;
    mwr(64'h00, 64'hC000);              // post-save change must not restore
    mcut <= 1; tick; tick; mcut <= 0; tick;
    mrd(64'h00); chk(rdv == 64'h0, "ram lost after save");
    mrest <= 1; tick; mrest <= 0;
    while (!mdone) tick; tick;
    mrd(64'h00); chk(rdv == 64'hB000, "restore word0");
    mrd(64'h18); chk(rdv == 64'hB003, "restore word3");
    // Restore without a save must be refused (nothing to restore after
    // another cut that tore a save — saved flag cleared on save-tear).
    msave <= 1; tick; msave <= 0;
    mcut <= 1; tick; mcut <= 0; tick;   // tear the in-flight save
    while (mbusy) tick;
    mrd(64'h00); chk(rdv == 64'h0, "save tear drops contents");

    if (fails == 0) $display("DSTORE_PASS checks=%0d", checks);

    if (fails == 0) $display("DSTORE_PASS checks=%0d", checks);
    else            $display("DSTORE_FAIL fails=%0d/%0d", fails, checks);
    $finish;
  end
endmodule
