// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// APU DMA read initiator through the testharness compositor DRAM-hole map.
// Legal DMA window is DRAM lo (not firmware RAM). Default-off is idle.
// Not full testharness, not OpenSBI, not TEX, not FPGA.

`timescale 1ns/1ps

package g6lc_dma_init_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  import axi_pkg::*;
  localparam int unsigned NRules = 3;
  localparam int unsigned DramIdx = 0;
  localparam int unsigned RamIdx = 12;
  localparam logic [63:0] DramBase = 64'h8000_0000;
  localparam logic [63:0] DramBytes = 64'h4000_0000;
  localparam logic [63:0] WindowBytes = 64'h1000_0000;

  function automatic apu_cfg_t dma_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.DmaReadEn = enabled;
    cfg.DmaWindowBase = DramBase;
    cfg.DmaWindowBytes = WindowBytes;
    cfg.DmaReadBurstBeats = 16;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  function automatic apu_cfg_t dram_stub();
    apu_cfg_t cfg = ApuHarness;
    cfg.FirmwareRamBase = DramBase;
    cfg.FirmwareRamBytes = 64'h1000;
    return cfg;
  endfunction
  function automatic apu_cfg_t ram_stub();
    apu_cfg_t cfg = ApuHarness;
    cfg.FirmwareRamBytes = 64'h1000;
    return cfg;
  endfunction
  function automatic int last_match(input logic [63:0] a,
      input xbar_rule_64_t [NRules-1:0] rules);
    int idx;
    int i;
    idx = -1;
    for (i = 0; i < int'(NRules); i++)
      if (a >= rules[i].start_addr && a < rules[i].end_addr)
        idx = int'(rules[i].idx);
    return idx;
  endfunction
endpackage

module g6lc_apu_dma_hole_mux
  import axi_pkg::*;
  import g6lc_dma_init_test_pkg::*;
#(
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  axi_req_t mem_req_i,
  output axi_rsp_t mem_rsp_o,
  output axi_req_t ram_req_o,
  input  axi_rsp_t ram_rsp_i,
  output axi_req_t dram_req_o,
  input  axi_rsp_t dram_rsp_i,
  input  xbar_rule_64_t [NRules-1:0] rules_i
);
  typedef enum logic { DestDram, DestRam } dest_e;
  function automatic dest_e dest_of(input int idx);
    return (idx == int'(RamIdx)) ? DestRam : DestDram;
  endfunction

  dest_e r_dest_q, w_dest_q, dest_ar, dest_aw;
  logic r_busy_q, w_busy_q, ar_ok, aw_ok;
  axi_rsp_t sel, ar_pick, aw_pick, w_pick;

  assign dest_ar = dest_of(last_match(mem_req_i.ar.addr, rules_i));
  assign dest_aw = dest_of(last_match(mem_req_i.aw.addr, rules_i));
  assign ar_ok = last_match(mem_req_i.ar.addr, rules_i) >= 0;
  assign aw_ok = last_match(mem_req_i.aw.addr, rules_i) >= 0;
  assign sel = r_busy_q ? (r_dest_q == DestRam ? ram_rsp_i : dram_rsp_i) :
               w_busy_q ? (w_dest_q == DestRam ? ram_rsp_i : dram_rsp_i) :
               dram_rsp_i;
  assign ar_pick = dest_ar == DestRam ? ram_rsp_i : dram_rsp_i;
  assign aw_pick = dest_aw == DestRam ? ram_rsp_i : dram_rsp_i;
  assign w_pick = (w_busy_q ? w_dest_q : dest_aw) == DestRam ?
                  ram_rsp_i : dram_rsp_i;

  always_comb begin
    ram_req_o = mem_req_i;
    dram_req_o = mem_req_i;
    ram_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q && ar_ok &&
                         dest_ar == DestRam;
    dram_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q && ar_ok &&
                          dest_ar == DestDram;
    ram_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q && aw_ok &&
                         dest_aw == DestRam;
    dram_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q && aw_ok &&
                          dest_aw == DestDram;
    ram_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestRam) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestRam));
    dram_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestDram) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestDram));
    ram_req_o.r_ready = mem_req_i.r_ready && r_busy_q && r_dest_q == DestRam;
    dram_req_o.r_ready = mem_req_i.r_ready && r_busy_q && r_dest_q == DestDram;
    ram_req_o.b_ready = mem_req_i.b_ready && w_busy_q && w_dest_q == DestRam;
    dram_req_o.b_ready = mem_req_i.b_ready && w_busy_q && w_dest_q == DestDram;

    mem_rsp_o = sel;
    mem_rsp_o.ar_ready = !r_busy_q && ar_ok && ar_pick.ar_ready;
    mem_rsp_o.aw_ready = !w_busy_q && aw_ok && aw_pick.aw_ready;
    mem_rsp_o.w_ready = w_busy_q ? w_pick.w_ready :
        (mem_req_i.aw_valid && aw_ok && aw_pick.w_ready);
    if (r_busy_q) begin
      mem_rsp_o.r_valid = sel.r_valid;
      mem_rsp_o.r = sel.r;
    end else
      mem_rsp_o.r_valid = 1'b0;
    if (w_busy_q) begin
      mem_rsp_o.b_valid = sel.b_valid;
      mem_rsp_o.b = sel.b;
    end else
      mem_rsp_o.b_valid = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_busy_q <= 1'b0;
      w_busy_q <= 1'b0;
      r_dest_q <= DestDram;
      w_dest_q <= DestDram;
    end else begin
      if (!r_busy_q && mem_req_i.ar_valid && mem_rsp_o.ar_ready) begin
        r_busy_q <= 1'b1;
        r_dest_q <= dest_ar;
      end else if (r_busy_q && mem_rsp_o.r_valid && mem_req_i.r_ready &&
                   mem_rsp_o.r.last)
        r_busy_q <= 1'b0;
      if (!w_busy_q && mem_req_i.aw_valid && mem_rsp_o.aw_ready) begin
        w_busy_q <= 1'b1;
        w_dest_q <= dest_aw;
      end else if (w_busy_q && mem_rsp_o.b_valid && mem_req_i.b_ready)
        w_busy_q <= 1'b0;
    end
  end
endmodule

module tb_g6lc_apu_dma_init;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_dma_init_test_pkg::*;
  import axi_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic enable, cancel, req_valid, req_ready, data_valid, data_ready;
  logic cpl_valid, cpl_ready, idle, bus_fault;
  logic off_req_ready, off_data_valid, off_cpl_valid, off_idle, off_fault;
  apu_dma_read_req_t req;
  apu_dma_mapping_t mapping;
  apu_dma_read_data_t data, off_data;
  apu_dma_read_cpl_t cpl, off_cpl;
  apu_dma_axi_req_t axi_req, ram_req, dram_req, off_axi;
  apu_dma_axi_resp_t axi_rsp, ram_rsp, dram_rsp;
  xbar_rule_64_t [NRules-1:0] rules;
  logic saw_dram, saw_ram;
  int errors = 0, checks = 0, cycles = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  assign rules[0] = '{idx: DramIdx, start_addr: DramBase,
                      end_addr: apu_dram_lo_end(64'h9000_0000)};
  assign rules[1] = '{idx: RamIdx, start_addr: 64'h9000_0000,
                      end_addr: 64'h9004_0000};
  assign rules[2] = '{idx: DramIdx, start_addr: 64'h9004_0000,
                      end_addr: DramBase + DramBytes};

  g6lc_apu_dma_read #(.ApuCfg(dma_cfg(1'b1))) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req),
    .mapping_i(mapping), .data_valid_o(data_valid), .data_ready_i(data_ready),
    .data_o(data), .cpl_valid_o(cpl_valid), .cpl_ready_i(cpl_ready), .cpl_o(cpl),
    .idle_o(idle), .bus_fault_o(bus_fault), .axi_req_o(axi_req), .axi_rsp_i(axi_rsp)
  );
  g6lc_apu_dma_read #(.ApuCfg(dma_cfg(1'b0))) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .req_valid_i(req_valid), .req_ready_o(off_req_ready), .req_i(req),
    .mapping_i(mapping), .data_valid_o(off_data_valid), .data_ready_i(data_ready),
    .data_o(off_data), .cpl_valid_o(off_cpl_valid), .cpl_ready_i(cpl_ready),
    .cpl_o(off_cpl), .idle_o(off_idle), .bus_fault_o(off_fault),
    .axi_req_o(off_axi), .axi_rsp_i(axi_rsp)
  );

  g6lc_apu_dma_hole_mux #(
    .axi_req_t(apu_dma_axi_req_t),
    .axi_rsp_t(apu_dma_axi_resp_t)
  ) i_mux (
    .clk_i(clk), .rst_ni, .mem_req_i(axi_req), .mem_rsp_o(axi_rsp),
    .ram_req_o(ram_req), .ram_rsp_i(ram_rsp),
    .dram_req_o(dram_req), .dram_rsp_i(dram_rsp), .rules_i(rules)
  );

  g6lc_apu_fwram #(
    .ApuCfg(dram_stub()), .RamIdx(DramIdx), .HexFile("dram_dma.hex"),
    .axi4_req_t(apu_dma_axi_req_t), .axi4_rsp_t(apu_dma_axi_resp_t)
  ) i_dram (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .aw_hart_i(32'd1),
    .ar_hart_i(32'd1),
    .slv_req_i(dram_req), .slv_rsp_o(dram_rsp),
    .ram_rule_o(), .ram_base_o(), .ram_end_o()
  );
  g6lc_apu_fwram #(
    .ApuCfg(ram_stub()), .RamIdx(RamIdx), .HexFile("none"),
    .axi4_req_t(apu_dma_axi_req_t), .axi4_rsp_t(apu_dma_axi_resp_t)
  ) i_ram (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .aw_hart_i(32'd1),
    .ar_hart_i(32'd1),
    .slv_req_i(ram_req), .slv_rsp_o(ram_rsp),
    .ram_rule_o(), .ram_base_o(), .ram_end_o()
  );

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s cycle=%0d", name, cycles);
    end
  endtask

  always @(posedge clk) begin
    if (axi_req.ar_valid)
      saw_dram <= 1'b1;
    if (ram_req.ar_valid)
      saw_ram <= 1'b1;
  end
  always @(negedge clk) begin
    #1;
    if ({off_req_ready, off_data_valid, off_data, off_cpl_valid, off_cpl,
         off_fault, off_axi} !== '0 || off_idle !== 1'b1)
      $fatal(1, "disabled DMA initiator active");
  end

  initial begin
    #800000;
    $fatal(1, "dma init timeout idle=%0d cpl=%0d cycles=%0d", idle, cpl_valid,
           cycles);
  end

  initial begin
    enable = 1;
    cancel = 0;
    req_valid = 0;
    data_ready = 1;
    cpl_ready = 0;
    req = '0;
    mapping = '0;
    saw_dram = 0;
    saw_ram = 0;
    repeat (8) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);

    check("window legal vs firmware RAM",
          apu_cfg_legal(dma_cfg(1'b1)));
    check("firmware RAM is not DMA backing",
          !apu_ranges_overlap(DramBase, WindowBytes, 64'h9000_0000, 64'h40000));
    check("decode DRAM lo", last_match(DramBase, rules) == int'(DramIdx));
    check("decode RAM hole", last_match(64'h9000_0000, rules) == int'(RamIdx));
    check("decode DRAM hi", last_match(64'h9004_0000, rules) == int'(DramIdx));

    mapping = '{valid: 1'b1, permissions: 2'b01, resource_id: 32'h1,
                context_id: 32'h2, epoch: 32'h3, base: DramBase, bytes: 64'h1000};
    req = '{resource_id: 32'h1, context_id: 32'h2, epoch: 32'h3, offset: 64'h0,
            bytes: 32'd8, tag: 64'h11};
    @(negedge clk);
    while (!req_ready) @(negedge clk);
    req_valid = 1;
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    @(negedge clk);
    req_valid = 0;
    while (!axi_req.ar_valid) @(posedge clk);
    check("DRAM lo AR", axi_req.ar.addr[31:28] == 4'h8);
    while (!data_valid) @(posedge clk);
    check("DRAM lo payload", data.data[31:0] == 32'haabbccdd &&
          data.keep == 8'hff && data.last);
    @(negedge clk); data_ready = 1;
    @(posedge clk);
    while (!cpl_valid) @(posedge clk);
    check("DMA OK", cpl.status == APU_DMA_OK && cpl.bytes == 32'd8);
    @(negedge clk); cpl_ready = 1;
    @(posedge clk); @(negedge clk); cpl_ready = 0;
    @(posedge clk);
    check("firmware RAM not stolen", !saw_ram);
    check("no bus fault", !bus_fault);

    if (errors != 0) $fatal(1, "APU dma init errors=%0d", errors);
    $display("PASS tb_g6lc_apu_dma_init checks=%0d cycles=%0d errors=0",
             checks, cycles);
    $finish;
  end
endmodule
