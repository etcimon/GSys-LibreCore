// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_mem_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  localparam logic [63:0] WindowBase = 64'h8000_0000;
  function automatic apu_cfg_t mem_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.MaxResources = enabled ? 8 : 0;
    cfg.MaxCmdBytes = enabled ? 256 : 0;
    cfg.DmaReadEn = enabled;
    cfg.DmaReadBurstBeats = 1;
    cfg.DmaWriteEn = enabled;
    cfg.SgEn = enabled;
    cfg.SgMaxEntries = 64;
    cfg.SgMaxTransferBytes = 65536;
    cfg.DmaReadMaxBytes = 65536;
    cfg.DmaWindowBase = WindowBase;
    cfg.DmaWindowBytes = 64'h1000_0000;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = WindowBase + 64'h1000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
endpackage

module g6lc_apu_mem_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1) (
  input logic clk_i, rst_ni, testmode_i, enable_i, cancel_i, invalidate_i,
  input logic op_valid_i,
  output logic op_ready_o,
  input apu_mem_op_e op_i,
  input apu_map_insert_t insert_i,
  input apu_map_lookup_t lookup_i,
  input apu_map_inval_t inval_i,
  input apu_sg_load_t sg_load_i,
  input apu_dma_mapping_t sg_list_i, sg_backing_i,
  input apu_sg_query_t sg_query_i,
  input apu_cmd_req_t cmd_i,
  input apu_dma_read_req_t cmd_dma_i,
  input apu_dma_mapping_t cmd_map_i,
  input apu_used_req_t used_i,
  output logic op_cpl_valid_o,
  input logic op_cpl_ready_i,
  output apu_map_cpl_t op_cpl_o,
  output apu_dma_mapping_t lookup_mapping_o,
  input logic cmd_rd_valid_i,
  output logic cmd_rd_ready_o,
  input logic [31:0] cmd_rd_offset_i,
  output logic cmd_rd_data_valid_o,
  input logic cmd_rd_data_ready_i,
  output logic [63:0] cmd_rd_data_o,
  output logic idle_o, cmd_held_o, bus_fault_o,
  output apu_dma_axi_req_t axi_req_o,
  input apu_dma_axi_resp_t axi_rsp_i
);
  g6lc_apu_mem #(.ApuCfg(g6lc_mem_test_pkg::mem_cfg(Enable))) i_dut (.*);
endmodule

module tb_g6lc_apu_mem;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_mem_test_pkg::*;
  logic clk = 0, rst_ni = 0, enable, cancel, invalidate;
  logic ov, ordy, ocv, ocr, crv, crr, crdv, crdr, idle, held, fault;
  apu_mem_op_e op;
  apu_map_insert_t ins;
  apu_map_lookup_t look;
  apu_map_inval_t inval;
  apu_sg_load_t sgl;
  apu_dma_mapping_t slist, sback, cmap, lmap;
  apu_sg_query_t sgq;
  apu_cmd_req_t cmd;
  apu_dma_read_req_t cdma;
  apu_used_req_t used;
  apu_map_cpl_t ocpl;
  apu_dma_mapping_t saved_lmap;
  logic [31:0] rdoff;
  logic [63:0] rddata;
  apu_dma_axi_req_t axi_req;
  apu_dma_axi_resp_t axi_rsp;
  logic off_ordy, off_ocv, off_idle, off_held, off_fault, off_crr, off_crdv;
  apu_dma_axi_req_t off_axi;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  logic [7:0] memory [0:8191];
  logic r_active, rvalid, aw_seen, w_seen, bvalid, executed;
  logic [63:0] raddr;
  int rleft, rstep;
  apu_dma_axi_r_chan_t rch;
  apu_dma_axi_aw_chan_t waw;
  apu_dma_axi_w_chan_t ww;

  g6lc_apu_mem_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .invalidate_i(invalidate), .op_valid_i(ov), .op_ready_o(ordy), .op_i(op),
    .insert_i(ins), .lookup_i(look), .inval_i(inval), .sg_load_i(sgl),
    .sg_list_i(slist), .sg_backing_i(sback), .sg_query_i(sgq), .cmd_i(cmd),
    .cmd_dma_i(cdma), .cmd_map_i(cmap), .used_i(used),
    .op_cpl_valid_o(ocv), .op_cpl_ready_i(ocr), .op_cpl_o(ocpl),
    .lookup_mapping_o(lmap), .cmd_rd_valid_i(crv), .cmd_rd_ready_o(crr),
    .cmd_rd_offset_i(rdoff), .cmd_rd_data_valid_o(crdv), .cmd_rd_data_ready_i(crdr),
    .cmd_rd_data_o(rddata), .idle_o(idle), .cmd_held_o(held), .bus_fault_o(fault),
    .axi_req_o(axi_req), .axi_rsp_i(axi_rsp)
  );
  g6lc_apu_mem_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .invalidate_i(invalidate), .op_valid_i(ov), .op_ready_o(off_ordy), .op_i(op),
    .insert_i(ins), .lookup_i(look), .inval_i(inval), .sg_load_i(sgl),
    .sg_list_i(slist), .sg_backing_i(sback), .sg_query_i(sgq), .cmd_i(cmd),
    .cmd_dma_i(cdma), .cmd_map_i(cmap), .used_i(used),
    .op_cpl_valid_o(off_ocv), .op_cpl_ready_i(ocr), .op_cpl_o(),
    .lookup_mapping_o(), .cmd_rd_valid_i(crv), .cmd_rd_ready_o(off_crr),
    .cmd_rd_offset_i(rdoff), .cmd_rd_data_valid_o(off_crdv), .cmd_rd_data_ready_i(crdr),
    .cmd_rd_data_o(), .idle_o(off_idle), .cmd_held_o(off_held), .bus_fault_o(off_fault),
    .axi_req_o(off_axi), .axi_rsp_i(axi_rsp)
  );
  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #20000000; $fatal(1, "mem timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_ordy, off_ocv, off_held, off_fault, off_crr, off_crdv, off_axi} !== '0 ||
        off_idle !== 1'b1) $fatal(1, "disabled mem active");
  end
  always_comb begin
    axi_rsp = '0;
    axi_rsp.ar_ready = !r_active && !rvalid && cycles % 4 != 0;
    axi_rsp.r_valid = rvalid;
    axi_rsp.r = rch;
    axi_rsp.aw_ready = !aw_seen && !bvalid;
    axi_rsp.w_ready = !w_seen && !bvalid && cycles % 3 != 0;
    axi_rsp.b_valid = bvalid;
    axi_rsp.b.id = 1;
  end
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_active <= 0; rvalid <= 0; raddr <= 0; rleft <= 0; rstep <= 0; rch <= '0;
      aw_seen <= 0; w_seen <= 0; bvalid <= 0; executed <= 0; waw <= '0; ww <= '0;
    end else begin
      if (axi_req.ar_valid && axi_rsp.ar_ready) begin
        r_active <= 1; raddr <= axi_req.ar.addr; rleft <= 32'(axi_req.ar.len) + 1;
        rstep <= 1 << axi_req.ar.size;
      end
      if (r_active && !rvalid && cycles % 3 != 0) begin
        rvalid <= 1;
        for (int b = 0; b < 8; b++)
          rch.data[8*b +: 8] <= memory[int'(((raddr & ~64'd7) + 64'(b)) - WindowBase)];
        rch.id <= 0; rch.last <= rleft == 1; rch.resp <= 2'b00;
      end
      if (rvalid && axi_req.r_ready) begin
        rvalid <= 0; raddr <= raddr + 64'(rstep); rleft <= rleft - 1;
        if (rch.last) r_active <= 0;
      end
      if (axi_req.aw_valid && axi_rsp.aw_ready) begin aw_seen <= 1; waw <= axi_req.aw; end
      if (axi_req.w_valid && axi_rsp.w_ready) begin w_seen <= 1; ww <= axi_req.w; end
      if (aw_seen && w_seen && !executed) begin
        executed <= 1;
        for (int b = 0; b < 8; b++) if (ww.strb[b])
          memory[int'((waw.addr & ~64'd7) + 64'(b) - WindowBase)] <= ww.data[8*b +: 8];
      end
      if (executed && !bvalid && cycles % 4 != 0) bvalid <= 1;
      if (bvalid && axi_req.b_ready) begin
        bvalid <= 0; aw_seen <= 0; w_seen <= 0; executed <= 0;
      end
    end
  end
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin errors++; $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles); end
  endtask
  function automatic logic [7:0] pattern(input logic [63:0] addr);
    return 8'(addr ^ (addr >> 8) ^ 64'h3c);
  endfunction
  function automatic apu_dma_mapping_t mkmap(input logic [31:0] res, input logic [63:0] base, bytes);
    mkmap = '{valid: 1, permissions: 2'b11, resource_id: res, context_id: 3, epoch: 5,
              base: base, bytes: bytes};
  endfunction
  task automatic reset_all;
    integer i;
    @(negedge clk); rst_ni = 0; ov = 0; ocr = 0; crv = 0; crdr = 0; cancel = 0; invalidate = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1; enable = 1;
    for (i = 0; i < 8192; i++) memory[i] = pattern(WindowBase + 64'(i));
  endtask
  task automatic issue(input apu_mem_op_e operation, input apu_dma_status_e st);
    @(negedge clk); while (!ordy) @(negedge clk);
    cases++; op = operation; ov = 1; @(posedge clk); @(negedge clk); ov = 0;
    while (!ocv) @(negedge clk);
    check("op status", ocpl.status == st);
    saved_lmap = lmap;
    ocr = 1; @(posedge clk); @(negedge clk); ocr = 0;
    while (!idle) @(negedge clk);
  endtask

  initial begin
    ins = '0; look = '0; inval = '0; sgl = '0; slist = '0; sback = '0; sgq = '0;
    cmd = '0; cdma = '0; cmap = '0; used = '0; rdoff = 0;
    reset_all();
    ins = '{slot: 1, mapping: mkmap(11, WindowBase + 64'h100, 4096), tag: 1};
    issue(APU_MEM_MAP_INSERT, APU_DMA_OK);
    look = '{resource_id: 11, context_id: 3, epoch: 5, write_access: 1, tag: 2};
    issue(APU_MEM_MAP_LOOKUP, APU_DMA_OK);
    check("lookup base", saved_lmap.base == WindowBase + 64'h100);

    used = '{
      mapping: mkmap(7, WindowBase, 64'h1000), offset: 64'h40, queue_num: 64, idx: 0,
      desc_id: 32'h21, len: 32'h10, qid: 0, context_id: 9, fence: 64'h55, tag: 4
    };
    issue(APU_MEM_USED, APU_DMA_OK);
    check("used id", {memory[71], memory[70], memory[69], memory[68]} == 32'h21);

    cmd = '{bytes: 16, resource_id: 11, context_id: 3, epoch: 5, tag: 7};
    cdma = '{resource_id: 11, context_id: 3, epoch: 5, offset: 0, bytes: 16, tag: 7};
    cmap = mkmap(11, WindowBase + 64'h200, 64);
    issue(APU_MEM_CMD_DMA, APU_DMA_OK);
    check("cmd held", held);
    begin
      logic [63:0] word;
      rdoff = 0; crv = 1; crdr = 0;
      @(negedge clk); while (!crr) @(negedge clk);
      @(posedge clk); @(negedge clk); crv = 0;
      while (!crdv) @(negedge clk);
      word = rddata;
      check("cmd byte0", word[7:0] == pattern(WindowBase + 64'h200));
      crdr = 1; @(posedge clk); @(negedge clk); crdr = 0;
    end
    issue(APU_MEM_CMD_RELEASE, APU_DMA_OK);
    check("released", !held);

    slist = mkmap(12, WindowBase + 64'h400, 64);
    sback = mkmap(13, WindowBase + 64'h500, 256);
    begin
      logic [63:0] eaddr;
      logic [31:0] elen;
      eaddr = WindowBase + 64'h500;
      elen = 32'd32;
      for (int b = 0; b < 8; b++) memory[int'(64'h400) + b] = eaddr[8*b +: 8];
      for (int b = 0; b < 4; b++) memory[int'(64'h408) + b] = elen[8*b +: 8];
    end
    sgl = '{resource_id: 13, context_id: 3, epoch: 5, permissions: 2'b11, bytes: 32,
            entries: 1, list_offset: 0, tag: 8};
    issue(APU_MEM_SG_LOAD, APU_DMA_OK);
    sgq.req = '{resource_id: 13, context_id: 3, epoch: 5, offset: 0, bytes: 32, tag: 9};
    sgq.write_access = 0;
    issue(APU_MEM_SG_XFER, APU_DMA_OK);

    if (errors != 0) $fatal(1, "APU mem errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_mem cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
