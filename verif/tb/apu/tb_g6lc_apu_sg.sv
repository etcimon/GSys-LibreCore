// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_sg_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  localparam logic [63:0] WindowBase = 64'h4_0000_0000;
  localparam logic [63:0] WireBase = WindowBase + 64'h1003;
  function automatic apu_cfg_t sg_cfg(input bit enabled, input int entries);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled; cfg.SgEn = enabled; cfg.SgMaxEntries = entries;
    cfg.SgMaxTransferBytes = 65536;
    cfg.DmaReadEn = enabled; cfg.DmaWriteEn = enabled;
    cfg.DmaReadMaxBytes = 32'(entries * 16); cfg.DmaWriteMaxBytes = 37;
    cfg.DmaWindowBase = WindowBase; cfg.DmaWindowBytes = 64'h4_0000_0000;
    cfg.FirmwareHart = 1; cfg.FirmwareRamBase = 64'h8_0000_0000; cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  function automatic logic [7:0] mem_byte(input logic [63:0] addr);
    return 8'(addr ^ (addr >> 8) ^ (addr >> 32) ^ 64'h5a);
  endfunction
  function automatic logic [7:0] source_byte(input logic [63:0] offset);
    return 8'(offset ^ (offset >> 8) ^ 64'h3d);
  endfunction
endpackage

module g6lc_sg_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1, parameter int Entries = 64) (
  input logic clk_i, rst_ni, testmode_i, enable_i, cancel_i, invalidate_i,
  input logic load_valid_i,
  output logic load_ready_o,
  input apu_sg_load_t load_i,
  input apu_dma_mapping_t list_mapping_i, backing_mapping_i,
  output logic load_cpl_valid_o,
  input logic load_cpl_ready_i,
  output apu_dma_read_cpl_t load_cpl_o,
  input logic query_valid_i,
  output logic query_ready_o,
  input apu_sg_query_t query_i,
  output logic query_cpl_valid_o,
  input logic query_cpl_ready_i,
  output apu_dma_read_cpl_t query_cpl_o,
  output logic fragment_valid_o,
  input logic fragment_ready_i,
  output apu_sg_fragment_t fragment_o,
  output logic fragment_cancel_o,
  input logic fragment_cpl_valid_i,
  output logic fragment_cpl_ready_o,
  input apu_dma_read_cpl_t fragment_cpl_i,
  input logic fragment_idle_i, fragment_bus_fault_i,
  output logic table_valid_o, idle_o, bus_fault_o,
  output apu_dma_axi_req_t axi_req_o,
  input apu_dma_axi_resp_t axi_rsp_i
);
  g6lc_apu_sg #(.ApuCfg(g6lc_sg_test_pkg::sg_cfg(Enable, Entries))) i_dut (.*);
endmodule

module g6lc_sg_memory
  import g6lc_apu_bus_pkg::*;
  import g6lc_sg_test_pkg::*;
#(parameter int Entries = 64, parameter bit List = 0) (
  input logic clk, rst_ni, allow_ar, allow_r, allow_b,
  input logic [Entries-1:0][127:0] list,
  input logic read_error,
  input apu_dma_axi_req_t req,
  output apu_dma_axi_resp_t rsp,
  output logic commit,
  output apu_dma_axi_aw_chan_t written_aw,
  output apu_dma_axi_w_chan_t written_w
);
  logic active, rvalid, aw_seen, w_seen, executed, bvalid;
  logic [63:0] addr;
  int left, step, cycles;
  apu_dma_axi_r_chan_t r;
  function automatic logic [7:0] get_byte(input logic [63:0] a);
    logic [63:0] off;
    off = a - WireBase;
    if (List && a >= WireBase && off < 64'(Entries * 16))
      return list[int'(off >> 4)][int'(off[3:0])*8 +: 8];
    return mem_byte(a);
  endfunction
  always_comb begin
    rsp = '0;
    rsp.ar_ready = allow_ar && !active && !rvalid && cycles % 4 != 0;
    rsp.r_valid = rvalid;
    rsp.r = r;
    rsp.aw_ready = !aw_seen && !bvalid;
    rsp.w_ready = !w_seen && !bvalid && cycles % 3 != 0;
    rsp.b_valid = bvalid;
    rsp.b.id = 1;
  end
  assign commit = aw_seen && w_seen && !executed;
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      active <= 0; rvalid <= 0; addr <= 0; left <= 0; step <= 0; cycles <= 0; r <= '0;
      aw_seen <= 0; w_seen <= 0; executed <= 0; bvalid <= 0; written_aw <= '0; written_w <= '0;
    end else begin
      cycles <= cycles + 1;
      if (req.ar_valid && rsp.ar_ready) begin
        active <= 1; addr <= req.ar.addr; left <= 32'(req.ar.len) + 1; step <= 1 << req.ar.size;
      end
      if (active && !rvalid && allow_r && cycles % 3 != 0) begin
        rvalid <= 1;
        for (int b = 0; b < 8; b++) r.data[8*b +: 8] <= get_byte((addr & ~64'd7) + 64'(b));
        r.id <= 0; r.last <= left == 1; r.resp <= read_error ? 2'b10 : 2'b00;
      end
      if (rvalid && req.r_ready) begin
        rvalid <= 0; addr <= addr + 64'(step); left <= left - 1;
        if (r.last) active <= 0;
      end
      if (req.aw_valid && rsp.aw_ready) begin aw_seen <= 1; written_aw <= req.aw; end
      if (req.w_valid && rsp.w_ready) begin w_seen <= 1; written_w <= req.w; end
      if (commit) executed <= 1;
      if (executed && !bvalid && allow_b && cycles % 4 != 0) bvalid <= 1;
      if (bvalid && req.b_ready) begin bvalid <= 0; aw_seen <= 0; w_seen <= 0; executed <= 0; end
    end
  end
endmodule

module tb_g6lc_apu_sg;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_sg_test_pkg::*;
  parameter int Entries = 64;
  localparam apu_cfg_t Cfg = sg_cfg(1, Entries);
  logic clk = 0, rst_ni = 0;
  logic enable, cancel, invalidate, lv, lr, lcv, lcr, qv, qr, qcv, qcr;
  apu_sg_load_t load, expected_load;
  apu_dma_mapping_t list_map, backing;
  apu_sg_query_t query, expected_query;
  apu_dma_read_cpl_t lcpl, qcpl;
  logic fv, fr, fc, fcv, fcr, fi, ff, valid_table, idle, fault;
  apu_sg_fragment_t frag, active_frag;
  apu_dma_read_cpl_t fcpl, read_cpl, write_cpl;
  logic allow_fragment, hold_idle, corrupt_cpl, read_rdy, write_rdy, read_cv, write_cv;
  logic read_idle, write_idle, read_fault, write_fault, dv, dr;
  apu_dma_read_data_t rd;
  apu_dma_write_data_t wd;
  logic wv, wr, active_write, active_valid, wtaken;
  logic [2:0] allow_ar, allow_r, allow_b, inject_read;
  apu_dma_axi_req_t [2:0] axi_req;
  apu_dma_axi_resp_t [2:0] axi_rsp;
  logic [2:0] commits;
  apu_dma_axi_aw_chan_t [2:0] written_aw;
  apu_dma_axi_w_chan_t [2:0] written_w;
  logic [Entries-1:0][127:0] wire_entries, reference_entries;
  int ref_count, errors = 0, checks = 0, cycles = 0, cases = 0;
  int list_ar, fragments, completed, stream_bytes, write_sent;
  logic off_lr, off_lcv, off_qr, off_qcv, off_fv, off_fc, off_fcr, off_valid, off_idle, off_fault;
  apu_dma_read_cpl_t off_lcpl, off_qcpl;
  apu_sg_fragment_t off_frag;
  apu_dma_axi_req_t off_axi;

  g6lc_sg_fixture #(.Enable(0), .Entries(Entries)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel), .invalidate_i(invalidate),
    .load_valid_i(lv), .load_ready_o(off_lr), .load_i(load), .list_mapping_i(list_map), .backing_mapping_i(backing),
    .load_cpl_valid_o(off_lcv), .load_cpl_ready_i(lcr), .load_cpl_o(off_lcpl),
    .query_valid_i(qv), .query_ready_o(off_qr), .query_i(query), .query_cpl_valid_o(off_qcv),
    .query_cpl_ready_i(qcr), .query_cpl_o(off_qcpl), .fragment_valid_o(off_fv), .fragment_ready_i(fr),
    .fragment_o(off_frag), .fragment_cancel_o(off_fc), .fragment_cpl_valid_i(fcv), .fragment_cpl_ready_o(off_fcr),
    .fragment_cpl_i(fcpl), .fragment_idle_i(fi), .fragment_bus_fault_i(ff),
    .table_valid_o(off_valid), .idle_o(off_idle), .bus_fault_o(off_fault), .axi_req_o(off_axi), .axi_rsp_i(axi_rsp[0])
  );
  always @(negedge clk) begin
    #1;
    if ({off_lr, off_lcv, off_lcpl, off_qr, off_qcv, off_qcpl, off_fv, off_frag,
         off_fc, off_fcr, off_valid, off_fault, off_axi} !== '0 || off_idle !== 1'b1)
      $fatal(1, "disabled SG active");
  end

  g6lc_sg_fixture #(.Entries(Entries)) i_sg (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel), .invalidate_i(invalidate),
    .load_valid_i(lv), .load_ready_o(lr), .load_i(load), .list_mapping_i(list_map), .backing_mapping_i(backing),
    .load_cpl_valid_o(lcv), .load_cpl_ready_i(lcr), .load_cpl_o(lcpl),
    .query_valid_i(qv), .query_ready_o(qr), .query_i(query), .query_cpl_valid_o(qcv),
    .query_cpl_ready_i(qcr), .query_cpl_o(qcpl), .fragment_valid_o(fv), .fragment_ready_i(fr),
    .fragment_o(frag), .fragment_cancel_o(fc), .fragment_cpl_valid_i(fcv), .fragment_cpl_ready_o(fcr),
    .fragment_cpl_i(fcpl), .fragment_idle_i(fi), .fragment_bus_fault_i(ff),
    .table_valid_o(valid_table), .idle_o(idle), .bus_fault_o(fault), .axi_req_o(axi_req[0]), .axi_rsp_i(axi_rsp[0])
  );
  g6lc_apu_dma_read #(.ApuCfg(Cfg)) i_read (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(1'b1), .cancel_i(fc),
    .req_valid_i(fv && !frag.write_access && allow_fragment), .req_ready_o(read_rdy),
    .req_i(frag.req), .mapping_i(frag.mapping), .data_valid_o(dv), .data_ready_i(dr), .data_o(rd),
    .cpl_valid_o(read_cv), .cpl_ready_i(fcr && !active_write), .cpl_o(read_cpl),
    .idle_o(read_idle), .bus_fault_o(read_fault), .axi_req_o(axi_req[1]), .axi_rsp_i(axi_rsp[1])
  );
  g6lc_apu_dma_write #(.ApuCfg(Cfg)) i_write (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(1'b1), .cancel_i(fc),
    .req_valid_i(fv && frag.write_access && allow_fragment), .req_ready_o(write_rdy),
    .req_i(frag.req), .mapping_i(frag.mapping), .data_valid_i(wv), .data_ready_o(wr), .data_i(wd),
    .cpl_valid_o(write_cv), .cpl_ready_i(fcr && active_write), .cpl_o(write_cpl),
    .idle_o(write_idle), .bus_fault_o(write_fault), .axi_req_o(axi_req[2]), .axi_rsp_i(axi_rsp[2])
  );
  for (genvar p = 0; p < 3; p++) begin : gen_memory
    g6lc_sg_memory #(.Entries(Entries), .List(p == 0)) i_mem (
      .clk, .rst_ni, .allow_ar(allow_ar[p]), .allow_r(allow_r[p]), .allow_b(allow_b[p]),
      .list(wire_entries), .read_error(inject_read[p]), .req(axi_req[p]), .rsp(axi_rsp[p]),
      .commit(commits[p]), .written_aw(written_aw[p]), .written_w(written_w[p])
    );
  end
  assign fr = allow_fragment && (frag.write_access ? write_rdy : read_rdy);
  assign fcv = active_write ? write_cv : read_cv;
  always_comb begin
    fcpl = active_write ? write_cpl : read_cpl;
    if (corrupt_cpl) fcpl.tag ^= 64'h8000_0000_0000_0000;
  end
  assign fi = read_idle && write_idle && !hold_idle;
  assign ff = read_fault || write_fault;
  always @(negedge clk) dr = cycles % 5 != 0;
  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #10000000; $fatal(1, "SG timeout case=%0d load=%b query=%b fragment=%b", cases, lcv, qcv, fv); end
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin errors++; $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles); end
  endtask
  function automatic logic [63:0] physical(input logic [63:0] logical);
    logic [63:0] remaining;
    remaining = logical;
    for (int e = 0; e < Entries; e++) begin
      if (e < ref_count) begin
        if (remaining < 64'(reference_entries[e][95:64])) return reference_entries[e][63:0] + remaining;
        remaining -= 64'(reference_entries[e][95:64]);
      end
    end
    return '1;
  endfunction
  always @(posedge clk) begin
    wtaken = 0;
    if (rst_ni) begin
      if (axi_req[0].ar_valid && axi_rsp[0].ar_ready) begin
        logic [63:0] last;
        last = axi_req[0].ar.addr + ((64'(axi_req[0].ar.len) + 1) << axi_req[0].ar.size) - 1;
        list_ar++;
        check("list DMA bounded", axi_req[0].ar.addr >= WireBase && last - WireBase < 64'(expected_load.entries) * 16);
      end
      if (fv && fr) begin
        fragments++;
        active_frag = frag; active_write = frag.write_access; active_valid = 1; write_sent = 0;
        check("fragment metadata", frag.req.resource_id == expected_query.req.resource_id &&
          frag.req.context_id == expected_query.req.context_id && frag.req.epoch == expected_query.req.epoch &&
          frag.req.tag == expected_query.req.tag && frag.write_access == expected_query.write_access);
        check("fragment logical progress", frag.transfer_offset == 32'(completed));
        check("fragment start mapping", frag.mapping.base + frag.req.offset == physical(expected_query.req.offset + 64'(completed)));
        check("fragment positive and bounded", frag.req.bytes > 0 &&
          frag.req.bytes <= (frag.write_access ? Cfg.DmaWriteMaxBytes : Cfg.DmaReadMaxBytes) &&
          frag.req.bytes <= expected_query.req.bytes - 32'(completed));
        check("fragment stays in one entry", frag.req.offset + 64'(frag.req.bytes) <= frag.mapping.bytes);
        check("fragment last", frag.last == (32'(completed) + frag.req.bytes == expected_query.req.bytes));
      end
      if (dv && dr) begin
        for (int b = 0; b < 8; b++) if (rd.keep[b]) begin
          check("SG read data exact", rd.data[8*b +: 8] == mem_byte(physical(expected_query.req.offset +
            64'(active_frag.transfer_offset) + 64'(rd.offset) + 64'(b))));
          stream_bytes++;
        end
      end
      if (wv && wr) begin write_sent += $countones(wd.keep); wtaken = 1; end
      if (commits[2]) begin
        for (int b = 0; b < 8; b++) if (written_w[2].strb[b]) begin
          logic [63:0] address, off;
          address = (written_aw[2].addr & ~64'd7) + 64'(b);
          off = address - (active_frag.mapping.base + active_frag.req.offset);
          check("SG write within fragment", address >= active_frag.mapping.base + active_frag.req.offset && off < 64'(active_frag.req.bytes));
          check("SG write address", address == physical(expected_query.req.offset + 64'(active_frag.transfer_offset) + off));
          check("SG write data exact", written_w[2].data[8*b +: 8] == source_byte(expected_query.req.offset + 64'(active_frag.transfer_offset) + off));
          stream_bytes++;
        end
      end
      if (fcv && fcr) begin completed += int'(fcpl.bytes); active_valid = 0; end
    end
  end
  always @(negedge clk) begin
    if (!rst_ni || !active_valid || !active_write) wv = 0;
    else begin
      if (wtaken) wv = 0;
      if (!wv && write_sent < int'(active_frag.req.bytes)) begin
        int n;
        n = int'(active_frag.req.bytes) - write_sent;
        if (n > 8) n = 8;
        wd = '0; wd.offset = 32'(write_sent); wd.keep = 8'((1 << n) - 1);
        wd.last = write_sent + n == int'(active_frag.req.bytes);
        for (int b = 0; b < 8; b++) wd.data[8*b +: 8] = source_byte(expected_query.req.offset +
          64'(active_frag.transfer_offset) + 64'(write_sent + b));
        wv = 1;
      end
    end
  end
  task automatic reset_all;
    @(negedge clk); rst_ni = 0; lv = 0; qv = 0;
    active_valid = 0; active_write = 0; wv = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1; enable = 1; cancel = 0; invalidate = 0;
    allow_ar = '1; allow_r = '1; allow_b = '1; inject_read = 0;
    allow_fragment = 1; hold_idle = 0; corrupt_cpl = 0; lcr = 0; qcr = 0;
  endtask
  task automatic setup_list(input int count, input logic [63:0] bytes);
    load = '{resource_id: 32'h8000_0001, context_id: 32'hf000_0002, epoch: 32'h1234_5678,
      permissions: 2'b11, bytes: bytes, entries: 32'(count), list_offset: 3, tag: 64'hfedc_ba98_0000_0000 | 64'(cases)};
    list_map = '{valid: 1, permissions: 1, resource_id: 32'h7000_0003, context_id: load.context_id,
      epoch: 99, base: WindowBase + 64'h1000, bytes: 64'h10000};
    backing = '{valid: 1, permissions: 3, resource_id: load.resource_id, context_id: load.context_id,
      epoch: load.epoch, base: WindowBase + 64'h10000, bytes: Cfg.DmaWindowBytes - 64'h10000};
  endtask
  task automatic start_load;
    @(negedge clk); while (!lr) @(negedge clk);
    cases++; list_ar = 0; expected_load = load; reference_entries = wire_entries; ref_count = int'(load.entries);
    lv = 1; @(posedge clk); @(negedge clk); lv = 0;
    load = '0; list_map = '0; backing = '0;
  endtask
  task automatic finish_load(input apu_dma_status_e status, input bit no_dma = 0);
    apu_dma_read_cpl_t saved;
    @(negedge clk); while (!lcv) @(negedge clk);
    saved = lcpl;
    if (lcpl.status != status) $display("load status got=%0d expected=%0d", lcpl.status, status);
    check("load status", lcpl.status == status);
    check("load metadata", lcpl.tag == expected_load.tag && lcpl.resource_id == expected_load.resource_id);
    check("table publication", valid_table == (status == APU_DMA_OK));
    if (no_dma) check("load rejection has no DMA", list_ar == 0);
    repeat (4) begin @(negedge clk); check("load completion held", lcv && lcpl === saved && !lr && !qr); end
    lcr = 1; @(posedge clk); @(negedge clk); lcr = 0; cancel = 0; invalidate = 0;
  endtask
  task automatic start_query(input logic [63:0] offset, input logic [31:0] bytes,
                             input bit write_access = 0, input int bad_field = 0);
    @(negedge clk); while (!qr) @(negedge clk);
    cases++; completed = 0; fragments = 0; stream_bytes = 0;
    query = '{req: '{resource_id: expected_load.resource_id, context_id: expected_load.context_id,
      epoch: expected_load.epoch, offset: offset, bytes: bytes, tag: 64'h8123_4567_0000_0000 | 64'(cases)}, write_access: write_access};
    if (bad_field == 1) query.req.resource_id ^= 32'h8000_0000;
    if (bad_field == 2) query.req.context_id ^= 32'h8000_0000;
    if (bad_field == 3) query.req.epoch ^= 32'h8000_0000;
    expected_query = query; qv = 1;
    @(posedge clk); @(negedge clk); qv = 0; query = '0;
  endtask
  task automatic finish_query(input apu_dma_status_e status, input bit no_fragment = 0);
    apu_dma_read_cpl_t saved;
    @(negedge clk); while (!qcv) @(negedge clk);
    saved = qcpl;
    if (qcpl.status != status) $display("query status got=%0d expected=%0d", qcpl.status, status);
    check("query status", qcpl.status == status);
    check("query metadata", qcpl.tag == expected_query.req.tag && qcpl.context_id == expected_query.req.context_id);
    if (status != APU_DMA_PROTOCOL) check("query count", qcpl.bytes == 32'(completed));
    if (status == APU_DMA_OK) check("full transfer", qcpl.bytes == expected_query.req.bytes && stream_bytes == int'(expected_query.req.bytes));
    if (no_fragment) check("query refused before handoff", fragments == 0);
    repeat (4) begin @(negedge clk); check("query completion held", qcv && qcpl === saved && !lr && !qr); end
    qcr = 1; @(posedge clk); @(negedge clk); qcr = 0; cancel = 0; invalidate = 0;
    if (status == APU_DMA_PROTOCOL) begin
      check("SG quarantined", fault && !idle && !lr && !qr && !valid_table);
      reset_all();
    end
  endtask
  task automatic normal_list;
    wire_entries[0] = {32'hdead_beef, 32'd17, WindowBase + 64'h20000};
    wire_entries[1] = {32'd0, 32'd23, WindowBase + 64'h80000};
    wire_entries[2] = {32'd0, 32'd31, WindowBase + 64'h30000};
    setup_list(3, 71); start_load(); finish_load(APU_DMA_OK);
  endtask
  initial begin
    apu_sg_fragment_t saved_frag;
    int saved_list_ar;
    lv = 0; qv = 0; lcr = 0; qcr = 0; enable = 1; cancel = 0; invalidate = 0;
    allow_ar = '1; allow_r = '1; allow_b = '1; inject_read = 0;
    allow_fragment = 1; hold_idle = 0; corrupt_cpl = 0;
    load = '0; list_map = '0; backing = '0; query = '0; active_frag = '0;
    active_write = 0; active_valid = 0; wv = 0; wd = '0; wtaken = 0;
    ref_count = 0; list_ar = 0; fragments = 0; completed = 0; stream_bytes = 0; write_sent = 0;
    for (int e = 0; e < Entries; e++) begin wire_entries[e] = '0; reference_entries[e] = '0; end
    reset_all();
    begin
      apu_cfg_t cfg;
      cfg = Cfg;
      cfg.DmaReadEn = 0;
      check("SG requires DMA reader", !apu_cfg_legal(cfg));
      cfg = Cfg; cfg.SgMaxEntries = 63;
      check("SG macro minimum enforced", !apu_cfg_legal(cfg));
      cfg = Cfg; cfg.SgMaxEntries = 65;
      check("SG geometry is power of two", !apu_cfg_legal(cfg));
      cfg = Cfg; cfg.DmaReadMaxBytes = 16;
      check("SG list fits fetch budget", !apu_cfg_legal(cfg));
      cfg = Cfg; cfg.SgMaxTransferBytes = 0;
      check("SG transfer limit nonzero", !apu_cfg_legal(cfg));
    end
    normal_list();
    saved_list_ar = list_ar;
    for (int e = 0; e < Entries; e++) wire_entries[e] = '0;
    for (int offset = 0; offset < 71; offset++) begin
      int len;
      len = 71 - offset; if (len > 9) len = 9;
      start_query(64'(offset), 32'(len), offset % 3 == 0); finish_query(APU_DMA_OK);
    end
    check("queries never refetch guest list", list_ar == saved_list_ar && !axi_req[0].ar_valid);
    start_query(0, 1, 0, 1); finish_query(APU_DMA_BAD_RESOURCE, 1);
    start_query(0, 1, 0, 2); finish_query(APU_DMA_PERMISSION, 1);
    start_query(0, 1, 0, 3); finish_query(APU_DMA_STALE, 1);
    start_query(0, 65537); finish_query(APU_DMA_LIMIT, 1);
    start_query(70, 2); finish_query(APU_DMA_BOUNDS, 1);
    start_query(71, 1); finish_query(APU_DMA_BOUNDS, 1);
    start_query(0, 0); finish_query(APU_DMA_LIMIT, 1);
    start_query(64'hffff_ffff_ffff_ffff, 1); finish_query(APU_DMA_BOUNDS, 1);

    wire_entries[0] = {32'd0, 32'd3000, WindowBase + 64'h20000};
    wire_entries[1] = {32'd0, 32'd3000, WindowBase + 64'h80000};
    setup_list(2, 5000); start_load(); finish_load(APU_DMA_OK);
    start_query(997, 3500); finish_query(APU_DMA_OK);
    check("leaf quota splits SG entries", fragments >= 2);
    start_query(2990, 83, 1); finish_query(APU_DMA_OK);
    check("write quota splits SG entries", fragments >= 3);
    start_query(4999, 2); finish_query(APU_DMA_BOUNDS, 1);

    wire_entries[0] = {32'd0, 32'hffff_fff0, WindowBase + 64'h20000};
    wire_entries[1] = wire_entries[0];
    setup_list(2, 64'h1_ffff_ffe0); start_load(); finish_load(APU_DMA_BOUNDS);
    wire_entries[0] = {32'd0, 32'd64, WindowBase + 64'h20000};
    wire_entries[1] = {32'd0, 32'd64, WindowBase + 64'h20020};
    setup_list(2, 128); start_load(); finish_load(APU_DMA_BOUNDS);
    check("overlapping SG entries reject before handoff", fragments == 0);

    for (int e = 0; e < Entries; e++) wire_entries[e] = {32'd0, 32'd1, WindowBase + 64'h20000 + 64'(e*16)};
    setup_list(Entries, 64'(Entries)); start_load(); finish_load(APU_DMA_OK);
    start_query(64'(Entries-1), 1); finish_query(APU_DMA_OK);
    setup_list(0, 1); start_load(); finish_load(APU_DMA_LIMIT, 1);
    start_query(0, 1); finish_query(APU_DMA_BAD_RESOURCE, 1);
    setup_list(Entries+1, 1); start_load(); finish_load(APU_DMA_LIMIT, 1);
    setup_list(1, 0); start_load(); finish_load(APU_DMA_LIMIT, 1);
    setup_list(1, 1); backing.valid = 0; start_load(); finish_load(APU_DMA_BAD_RESOURCE, 1);
    setup_list(1, 1); backing.resource_id ^= 1; start_load(); finish_load(APU_DMA_BAD_RESOURCE, 1);
    setup_list(1, 1); backing.context_id ^= 1; start_load(); finish_load(APU_DMA_PERMISSION, 1);
    setup_list(1, 1); list_map.context_id ^= 1; start_load(); finish_load(APU_DMA_PERMISSION, 1);
    setup_list(1, 1); load.permissions = 0; start_load(); finish_load(APU_DMA_PERMISSION, 1);
    setup_list(1, 1); backing.epoch ^= 1; start_load(); finish_load(APU_DMA_STALE, 1);
    setup_list(1, 1); backing.permissions = 1; start_load(); finish_load(APU_DMA_PERMISSION, 1);
    setup_list(1, 1); list_map.permissions = 0; start_load(); finish_load(APU_DMA_PERMISSION, 1);
    setup_list(3, 3); list_map.bytes = 50; start_load(); finish_load(APU_DMA_BOUNDS, 1);
    wire_entries[2][95:64] = 0;
    setup_list(3, 3); start_load(); finish_load(APU_DMA_BOUNDS);
    wire_entries[2] = {32'd0, 32'd1, WireBase};
    setup_list(3, 3); start_load(); finish_load(APU_DMA_BOUNDS);
    wire_entries[2] = {32'd0, 32'd32, 64'hffff_ffff_ffff_fff8};
    setup_list(3, 3); start_load(); finish_load(APU_DMA_BOUNDS);
    wire_entries[2] = {32'd0, 32'd1, WindowBase + 64'h20020};
    setup_list(3, 4); start_load(); finish_load(APU_DMA_BOUNDS);
    inject_read[0] = 1;
    setup_list(3, 3); start_load(); finish_load(APU_DMA_BUS_ERROR);
    inject_read[0] = 0;
    allow_ar[0] = 0;
    setup_list(3, 3); start_load();
    while (!axi_req[0].ar_valid) @(negedge clk);
    cancel = 1;
    repeat (6) begin @(negedge clk); check("load cancellation waits for AXI", !lcv && !idle && !valid_table); end
    allow_ar[0] = 1; finish_load(APU_DMA_CANCELLED);

    normal_list();
    inject_read[1] = 1;
    start_query(0, 33); finish_query(APU_DMA_BUS_ERROR);
    inject_read[1] = 0;
    start_query(0, 9); cancel = 1; finish_query(APU_DMA_CANCELLED, 1);
    allow_r[1] = 0;
    start_query(14, 43);
    while (!gen_memory[1].i_mem.active) @(negedge clk);
    cancel = 1;
    repeat (6) begin @(negedge clk); check("SG cancellation waits for read R", !qcv && !lr && !idle); end
    allow_r[1] = 1; finish_query(APU_DMA_CANCELLED);
    allow_b[2] = 0;
    start_query(14, 43, 1);
    while (stream_bytes == 0) @(negedge clk);
    cancel = 1;
    repeat (6) begin @(negedge clk); check("SG cancellation waits for write B", !qcv && !lr && !idle); end
    allow_b[2] = 1; finish_query(APU_DMA_CANCELLED);
    check("SG cancellation retains partial write count", completed > 0 && completed < 43);
    start_query(0, 1); hold_idle = 1;
    while (completed == 0) @(negedge clk);
    repeat (6) begin @(negedge clk); check("fragment lease survives completion until idle", !qcv && !lr && !idle); end
    hold_idle = 0; finish_query(APU_DMA_OK);
    allow_fragment = 0;
    start_query(0, 32);
    while (!fv) @(negedge clk);
    saved_frag = frag; invalidate = 1;
    repeat (6) begin
      @(negedge clk);
      check("invalidate holds offered fragment and the table",
            fv && frag === saved_frag && !fc && !lr && !idle && valid_table);
    end
    allow_fragment = 1; finish_query(APU_DMA_CANCELLED);
    check("cancelled offered fragment does no data work", stream_bytes == 0);
    start_query(0, 1); finish_query(APU_DMA_BAD_RESOURCE, 1);
    normal_list();
    setup_list(3, 71); load.permissions = 1; start_load(); finish_load(APU_DMA_OK);
    start_query(0, 1, 1); finish_query(APU_DMA_PERMISSION, 1);
    corrupt_cpl = 1;
    start_query(0, 1); finish_query(APU_DMA_PROTOCOL);
    start_query(0, 1); finish_query(APU_DMA_BAD_RESOURCE, 1);
    normal_list(); start_query(14, 43, 1); finish_query(APU_DMA_OK);
    if (errors != 0) $fatal(1, "APU SG errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_sg entries=%0d cases=%0d checks=%0d cycles=%0d errors=0", Entries, cases, checks, cycles);
      $finish;
    end
  end
endmodule
