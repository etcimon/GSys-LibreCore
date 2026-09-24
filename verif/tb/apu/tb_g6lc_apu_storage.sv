// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_storage_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  localparam logic [63:0] WindowBase = 64'h8000_0000;
  function automatic apu_cfg_t st_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.MaxResources = enabled ? 8 : 0;
    cfg.MaxCmdBytes = enabled ? 256 : 0;
    cfg.DmaWindowBase = WindowBase;
    cfg.DmaWindowBytes = 64'h1000_0000;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = WindowBase + 64'h1000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
endpackage

module g6lc_apu_storage_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1) (
  input logic clk_i, rst_ni, testmode_i, enable_i, cancel_i, invalidate_i, child_idle_i,
  input logic map_valid_i,
  output logic map_ready_o,
  input apu_map_insert_t map_i,
  output logic map_cpl_valid_o,
  input logic map_cpl_ready_i,
  output apu_map_cpl_t map_cpl_o,
  input logic lookup_valid_i,
  output logic lookup_ready_o,
  input apu_map_lookup_t lookup_i,
  output logic lookup_cpl_valid_o,
  input logic lookup_cpl_ready_i,
  output apu_map_cpl_t lookup_cpl_o,
  output apu_dma_mapping_t lookup_mapping_o,
  input logic inval_valid_i,
  output logic inval_ready_o,
  input apu_map_inval_t inval_i,
  output logic inval_cpl_valid_o,
  input logic inval_cpl_ready_i,
  output apu_map_cpl_t inval_cpl_o,
  input logic cmd_valid_i,
  output logic cmd_ready_o,
  input apu_cmd_req_t cmd_i,
  input logic cmd_data_valid_i,
  output logic cmd_data_ready_o,
  input apu_dma_read_data_t cmd_data_i,
  output logic cmd_cpl_valid_o,
  input logic cmd_cpl_ready_i,
  output apu_map_cpl_t cmd_cpl_o,
  input logic cmd_rd_valid_i,
  output logic cmd_rd_ready_o,
  input logic [31:0] cmd_rd_offset_i,
  output logic cmd_rd_data_valid_o,
  input logic cmd_rd_data_ready_i,
  output logic [63:0] cmd_rd_data_o,
  input logic cmd_release_i,
  output logic idle_o, cmd_held_o, bus_fault_o
);
  g6lc_apu_storage #(.ApuCfg(g6lc_storage_test_pkg::st_cfg(Enable))) i_dut (.*);
endmodule

module tb_g6lc_apu_storage;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_storage_test_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic enable, cancel, invalidate, child_idle = 1;
  logic mv, mr, mcv, mcr, lv, lr, lcv, lcr, iv, ir, icv, icr;
  logic cv, cr, dv, dr, ccv, ccr, rv, rr, rdv, rdr, rel;
  logic idle, held, fault;
  apu_map_insert_t minst;
  apu_map_lookup_t look;
  apu_map_inval_t inval;
  apu_cmd_req_t creq;
  apu_dma_read_data_t cdata;
  apu_map_cpl_t mcpl, lcpl, icpl, ccpl;
  apu_dma_mapping_t lmap;
  logic [31:0] rdoff;
  logic [63:0] rddata;
  logic off_mr, off_mcv, off_lr, off_lcv, off_ir, off_icv, off_cr, off_dr, off_ccv;
  logic off_rr, off_rdv, off_idle, off_held, off_fault;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int source_sent;
  logic [7:0] cmd_mem [0:255];

  g6lc_apu_storage_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .invalidate_i(invalidate), .child_idle_i(child_idle),
    .map_valid_i(mv), .map_ready_o(mr), .map_i(minst),
    .map_cpl_valid_o(mcv), .map_cpl_ready_i(mcr), .map_cpl_o(mcpl),
    .lookup_valid_i(lv), .lookup_ready_o(lr), .lookup_i(look),
    .lookup_cpl_valid_o(lcv), .lookup_cpl_ready_i(lcr), .lookup_cpl_o(lcpl),
    .lookup_mapping_o(lmap), .inval_valid_i(iv), .inval_ready_o(ir), .inval_i(inval),
    .inval_cpl_valid_o(icv), .inval_cpl_ready_i(icr), .inval_cpl_o(icpl),
    .cmd_valid_i(cv), .cmd_ready_o(cr), .cmd_i(creq),
    .cmd_data_valid_i(dv), .cmd_data_ready_o(dr), .cmd_data_i(cdata),
    .cmd_cpl_valid_o(ccv), .cmd_cpl_ready_i(ccr), .cmd_cpl_o(ccpl),
    .cmd_rd_valid_i(rv), .cmd_rd_ready_o(rr), .cmd_rd_offset_i(rdoff),
    .cmd_rd_data_valid_o(rdv), .cmd_rd_data_ready_i(rdr), .cmd_rd_data_o(rddata),
    .cmd_release_i(rel), .idle_o(idle), .cmd_held_o(held), .bus_fault_o(fault)
  );
  g6lc_apu_storage_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .invalidate_i(invalidate), .child_idle_i(child_idle),
    .map_valid_i(mv), .map_ready_o(off_mr), .map_i(minst),
    .map_cpl_valid_o(off_mcv), .map_cpl_ready_i(mcr), .map_cpl_o(),
    .lookup_valid_i(lv), .lookup_ready_o(off_lr), .lookup_i(look),
    .lookup_cpl_valid_o(off_lcv), .lookup_cpl_ready_i(lcr), .lookup_cpl_o(),
    .lookup_mapping_o(), .inval_valid_i(iv), .inval_ready_o(off_ir), .inval_i(inval),
    .inval_cpl_valid_o(off_icv), .inval_cpl_ready_i(icr), .inval_cpl_o(),
    .cmd_valid_i(cv), .cmd_ready_o(off_cr), .cmd_i(creq),
    .cmd_data_valid_i(dv), .cmd_data_ready_o(off_dr), .cmd_data_i(cdata),
    .cmd_cpl_valid_o(off_ccv), .cmd_cpl_ready_i(ccr), .cmd_cpl_o(),
    .cmd_rd_valid_i(rv), .cmd_rd_ready_o(off_rr), .cmd_rd_offset_i(rdoff),
    .cmd_rd_data_valid_o(off_rdv), .cmd_rd_data_ready_i(rdr), .cmd_rd_data_o(),
    .cmd_release_i(rel), .idle_o(off_idle), .cmd_held_o(off_held), .bus_fault_o(off_fault)
  );
  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #10000000; $fatal(1, "storage timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_mr, off_mcv, off_lr, off_lcv, off_ir, off_icv, off_cr, off_dr, off_ccv,
         off_rr, off_rdv, off_held, off_fault} !== '0 || off_idle !== 1'b1)
      $fatal(1, "disabled storage active");
  end
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin errors++; $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles); end
  endtask
  function automatic logic [7:0] pattern(input int off);
    return 8'(off ^ 8'h5a);
  endfunction
  function automatic apu_dma_mapping_t mkmap(input logic [31:0] res, ctx, epoch, input logic [63:0] base, bytes);
    mkmap = '{valid: 1, permissions: 2'b11, resource_id: res, context_id: ctx, epoch: epoch,
              base: base, bytes: bytes};
  endfunction
  task automatic reset_all;
    @(negedge clk); rst_ni = 0; mv = 0; lv = 0; iv = 0; cv = 0; dv = 0; rv = 0; rel = 0;
    mcr = 0; lcr = 0; icr = 0; ccr = 0; rdr = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1; enable = 1; cancel = 0; invalidate = 0; child_idle = 1;
  endtask
  task automatic do_insert(input apu_map_insert_t req, input apu_dma_status_e st);
    apu_map_cpl_t saved;
    @(negedge clk); while (!mr) @(negedge clk);
    cases++; minst = req; mv = 1; @(posedge clk); @(negedge clk); mv = 0; minst = '0;
    while (!mcv) @(negedge clk);
    saved = mcpl;
    check("insert status", mcpl.status == st);
    repeat (3) begin @(negedge clk); check("insert held", mcv && mcpl === saved && !mr); end
    mcr = 1; @(posedge clk); @(negedge clk); mcr = 0;
  endtask
  task automatic do_lookup(input apu_map_lookup_t req, input apu_dma_status_e st);
    apu_map_cpl_t saved;
    @(negedge clk); while (!lr) @(negedge clk);
    cases++; look = req; lv = 1; @(posedge clk); @(negedge clk); lv = 0; look = '0;
    while (!lcv) @(negedge clk);
    saved = lcpl;
    check("lookup status", lcpl.status == st);
    if (st == APU_DMA_OK)
      check("lookup mapping live", lmap.valid && lmap.resource_id == req.resource_id &&
            lmap.context_id == req.context_id && lmap.epoch == req.epoch);
    repeat (3) begin @(negedge clk); check("lookup held", lcv && lcpl === saved); end
    lcr = 1; @(posedge clk); @(negedge clk); lcr = 0;
  endtask
  task automatic do_inval(input apu_map_inval_t req);
    @(negedge clk); while (!ir) @(negedge clk);
    cases++; inval = req; iv = 1; @(posedge clk); @(negedge clk); iv = 0; inval = '0;
    while (!icv) @(negedge clk);
    icr = 1; @(posedge clk); @(negedge clk); icr = 0;
  endtask
  task automatic fill_cmd(input int nbytes, input apu_dma_status_e st, input bit do_cancel = 0,
                          input int bad = 0);
    int n;
    @(negedge clk); while (!cr) @(negedge clk);
    cases++; source_sent = 0;
    creq = '{bytes: 32'(nbytes), resource_id: 9, context_id: 3, epoch: 4, tag: 64'(cases)};
    cv = 1; @(posedge clk); @(negedge clk); cv = 0; creq = '0; dv = 0;
    while (!ccv) begin
      @(negedge clk);
      if (do_cancel && source_sent >= 8) cancel = 1;
      if (!dv && !ccv && source_sent < nbytes) begin
        n = nbytes - source_sent;
        if (n > 8) n = 8;
        cdata = '0;
        cdata.offset = 32'(source_sent);
        cdata.keep = 8'((1 << n) - 1);
        cdata.last = source_sent + n == nbytes;
        for (int b = 0; b < n; b++) cdata.data[8*b +: 8] = pattern(source_sent + b);
        if (bad == 1) cdata.keep = 8'h5;
        if (bad == 2) cdata.offset += 1;
        dv = 1;
        @(posedge clk);
        if (dv && dr) source_sent += n;
        @(negedge clk);
        dv = 0;
      end
    end
    check("cmd status", ccpl.status == st);
    check("cmd hold matches success", held == (st == APU_DMA_OK));
    ccr = 1; @(posedge clk); @(negedge clk); ccr = 0; cancel = 0; dv = 0;
  endtask
  task automatic read_cmd(input int nbytes);
    logic [63:0] word;
    for (int off = 0; off < nbytes; off += 8) begin
      @(negedge clk); while (!rr) @(negedge clk);
      rdoff = 32'(off); rv = 1; rdr = 0;
      @(posedge clk); @(negedge clk); rv = 0;
      while (!rdv) @(negedge clk);
      word = rddata;
      for (int b = 0; b < 8 && off + b < nbytes; b++)
        check("cmd byte", word[8*b +: 8] == pattern(off + b));
      rdr = 1; @(posedge clk); @(negedge clk); rdr = 0;
    end
  endtask

  initial begin
    apu_cfg_t cfg;
    apu_dma_mapping_t xmap;
    minst = '0; look = '0; inval = '0; creq = '0; cdata = '0;
    reset_all();
    cfg = st_cfg(1); cfg.MaxResources = 7;
    check("resource table power of two", !apu_cfg_legal(cfg));
    cfg = st_cfg(1); cfg.MaxCmdBytes = 200;
    check("command SRAM minimum", !apu_cfg_legal(cfg));
    xmap = mkmap(1, 1, 1, WindowBase, 256);
    check("tight 8x8 rgba8", apu_xfer_check(xmap, 0, 8, 8, 1, 0, 0, 4) == APU_DMA_OK);
    check("stride too small", apu_xfer_check(xmap, 0, 8, 8, 1, 16, 0, 4) == APU_DMA_BOUNDS);
    xmap.bytes = 64;
    check("overflows backing", apu_xfer_check(xmap, 40, 8, 8, 1, 32, 0, 4) == APU_DMA_BOUNDS);
    xmap.bytes = 256;
    check("zero size", apu_xfer_check(xmap, 0, 0, 8, 1, 0, 0, 4) == APU_DMA_BOUNDS);
    check("packed last row", apu_xfer_check(xmap, 0, 8, 2, 1, 32, 0, 4) == APU_DMA_OK);

    do_insert('{slot: 1, mapping: mkmap(11, 21, 31, WindowBase + 64'h1000, 4096), tag: 1}, APU_DMA_OK);
    do_lookup('{resource_id: 11, context_id: 21, epoch: 31, write_access: 1, tag: 2}, APU_DMA_OK);
    do_lookup('{resource_id: 11, context_id: 99, epoch: 31, write_access: 0, tag: 3}, APU_DMA_PERMISSION);
    do_lookup('{resource_id: 11, context_id: 21, epoch: 1, write_access: 0, tag: 4}, APU_DMA_STALE);
    do_lookup('{resource_id: 99, context_id: 21, epoch: 31, write_access: 0, tag: 5}, APU_DMA_BAD_RESOURCE);
    do_insert('{slot: 2, mapping: mkmap(11, 21, 31, WindowBase + 64'h2000, 64), tag: 6}, APU_DMA_BAD_RESOURCE);
    do_insert('{slot: 1, mapping: mkmap(12, 21, 32, WindowBase + 64'h2000, 128), tag: 7}, APU_DMA_OK);
    do_lookup('{resource_id: 11, context_id: 21, epoch: 31, write_access: 0, tag: 8}, APU_DMA_BAD_RESOURCE);
    do_lookup('{resource_id: 12, context_id: 21, epoch: 32, write_access: 0, tag: 9}, APU_DMA_OK);
    do_insert('{slot: 8, mapping: mkmap(13, 21, 1, WindowBase, 16), tag: 10}, APU_DMA_BAD_RESOURCE);
    do_insert('{slot: 3, mapping: mkmap(13, 22, 1, WindowBase, 16), tag: 11}, APU_DMA_OK);
    do_inval('{mode: APU_INVAL_RESOURCE, slot: 0, resource_id: 12, context_id: 0, tag: 12});
    do_lookup('{resource_id: 12, context_id: 21, epoch: 32, write_access: 0, tag: 13}, APU_DMA_BAD_RESOURCE);
    do_lookup('{resource_id: 13, context_id: 22, epoch: 1, write_access: 0, tag: 14}, APU_DMA_OK);
    do_inval('{mode: APU_INVAL_CONTEXT, slot: 0, resource_id: 0, context_id: 22, tag: 15});
    do_lookup('{resource_id: 13, context_id: 22, epoch: 1, write_access: 0, tag: 16}, APU_DMA_BAD_RESOURCE);
    do_insert('{slot: 0, mapping: mkmap(14, 21, 1, WindowBase + 64'h3000, 32), tag: 17}, APU_DMA_OK);
    do_inval('{mode: APU_INVAL_ALL, slot: 0, resource_id: 0, context_id: 0, tag: 18});
    do_lookup('{resource_id: 14, context_id: 21, epoch: 1, write_access: 0, tag: 19}, APU_DMA_BAD_RESOURCE);

    do_insert('{slot: 4, mapping: mkmap(15, 21, 7, WindowBase + 64'h4000, 64), tag: 20}, APU_DMA_OK);
    do_lookup('{resource_id: 15, context_id: 21, epoch: 7, write_access: 0, tag: 21}, APU_DMA_OK);
    reset_all();
    do_lookup('{resource_id: 15, context_id: 21, epoch: 7, write_access: 0, tag: 22}, APU_DMA_BAD_RESOURCE);
    do_insert('{slot: 4, mapping: mkmap(15, 21, 8, WindowBase + 64'h4000, 64), tag: 23}, APU_DMA_OK);
    do_lookup('{resource_id: 15, context_id: 21, epoch: 8, write_access: 0, tag: 24}, APU_DMA_OK);
    @(negedge clk); invalidate = 1;
    @(posedge clk); @(negedge clk); invalidate = 0;
    do_lookup('{resource_id: 15, context_id: 21, epoch: 8, write_access: 0, tag: 25}, APU_DMA_BAD_RESOURCE);
    reset_all();
    i_on.i_dut.gen_on.gen_map.i_map.sram[1] =
        apu_map_pack(mkmap(40, 21, 1, WindowBase, 32));
    do_lookup('{resource_id: 40, context_id: 21, epoch: 1, write_access: 0, tag: 26}, APU_DMA_BAD_RESOURCE);

    fill_cmd(512, APU_DMA_LIMIT);
    fill_cmd(20, APU_DMA_OK);
    read_cmd(20);
    check("still held after read", held && !cr);
    @(negedge clk); rel = 1; @(posedge clk); @(negedge clk); rel = 0;
    while (!cr) @(negedge clk);
    fill_cmd(8, APU_DMA_OK);
    @(negedge clk); rel = 1; @(posedge clk); @(negedge clk); rel = 0;
    fill_cmd(16, APU_DMA_STREAM, 0, 1);
    fill_cmd(24, APU_DMA_CANCELLED, 1, 0);
    fill_cmd(12, APU_DMA_OK);
    check("snapshot survives idle", held);
    repeat (8) @(negedge clk);
    read_cmd(12);

    do_insert('{slot: 2, mapping: mkmap(16, 21, 3, WindowBase + 64'h200, 32), tag: 30},
              APU_DMA_OK);
    child_idle = 0;
    @(negedge clk);
    check("insert waits while the child DMA is busy", !mr);
    check("inval waits while the child DMA is busy", !ir);
    invalidate = 1;
    repeat (4) @(negedge clk);
    invalidate = 0;
    do_lookup('{resource_id: 16, context_id: 21, epoch: 3, write_access: 0, tag: 31},
               APU_DMA_OK);
    child_idle = 1;
    @(posedge clk); @(negedge clk);
    do_lookup('{resource_id: 16, context_id: 21, epoch: 3, write_access: 0, tag: 32},
               APU_DMA_BAD_RESOURCE);

    fill_cmd(8, APU_DMA_OK);
    child_idle = 0;
    @(negedge clk);
    check("command stays held while the child DMA is busy", held);
    rel = 1; @(posedge clk); @(negedge clk); rel = 0;
    repeat (3) @(negedge clk);
    check("release waits for the child DMA", held);
    child_idle = 1;
    @(posedge clk); @(negedge clk);
    check("release retires after the child DMA is idle", !held);

    if (errors != 0) $fatal(1, "APU storage errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_storage cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
