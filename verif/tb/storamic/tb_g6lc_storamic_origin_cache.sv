// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_origin_cache;
  import ariane_pkg::*;
  import wt_cache_pkg::*;
  parameter bit Enabled = 1;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
    c.StoramicEn = 1; c.StoramicIoEn = 1; c.StoramicCheckpointEn = Enabled;
    c.NrHarts = 1; c.OoOEn = 0; c.RVH = 0;
    c.EnableAccelerator = 0; c.CoproType = config_pkg::COPRO_NONE;
    c.CohPolicy = config_pkg::COH_WRITE_INVAL;
    c.WtDcacheFixupDepth = 0;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t CVA6Cfg = configuration();
  typedef logic [7:0] cbo_t;
  `include "cpu-dcache-types.svh"
  `include "wt-types.svh"

  logic clk = 0, rst_n = 0;
  logic source_valid = 0, source_write = 0;
  logic [2:0] source_prot = 0;
  logic [CVA6Cfg.PLEN-1:0] source_address = '0;
  logic [CVA6Cfg.XLEN-1:0] source_data = 0;
  dcache_req_i_t [3:0] requests;
  dcache_req_o_t [3:0] responses;
  logic mem_req, mem_ack = 0, return_valid = 0;
  logic [CVA6Cfg.MEM_TID_WIDTH-1:0] return_id = 0;
  dcache_in_t return_type = DCACHE_STORE_ACK;
  dcache_req_t memory_request;
  dcache_rtrn_t memory_return;
  amo_req_t amo_request = '0;
  int checks = 0;
  bit negative;

  always_comb begin
    requests = '0;
    requests[source_write ? 3 : 1].address_index =
        source_address[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
    requests[source_write ? 3 : 1].address_tag =
        source_address[CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_INDEX_WIDTH];
    requests[source_write ? 3 : 1].data_req = source_valid;
    requests[source_write ? 3 : 1].tag_valid = 1;
    requests[source_write ? 3 : 1].data_we = source_write;
    requests[source_write ? 3 : 1].data_wdata = source_data;
    requests[source_write ? 3 : 1].data_wuser = '1;
    requests[source_write ? 3 : 1].data_be = '1;
    requests[source_write ? 3 : 1].data_size = 2'b11;
    requests[source_write ? 3 : 1].data_prot = source_prot;
    requests[source_write ? 3 : 1].cbo_op = CBO_NONE;
    memory_return = '0;
    memory_return.rtype = return_type;
    memory_return.tid = return_id;
  end

  wt_dcache #(.CVA6Cfg(CVA6Cfg), .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t), .dcache_req_t(dcache_req_t),
      .dcache_rtrn_t(dcache_rtrn_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .enable_i(1'b0), .flush_i(1'b0),
    .flush_ack_o(), .miss_o(), .wbuffer_empty_o(), .wbuffer_not_ni_o(),
    .cmo_valid_o(), .cmo_op_o(), .cmo_addr_o(), .cmo_ready_i(1'b0), .cmo_done_i(1'b0),
    .amo_req_i(amo_request), .amo_resp_o(), .mbe_i(1'b0),
    .req_ports_i(requests), .req_ports_o(responses), .miss_vld_bits_o(),
    .pm_void_ack_o(), .pm_fixup_write_o(), .pm_fixup_inval_o(), .pm_fixup_full_o(),
    .mem_rtrn_vld_i(return_valid), .mem_rtrn_i(memory_return),
    .mem_data_req_o(mem_req), .mem_data_ack_i(mem_ack), .mem_data_o(memory_request)
  );

  task automatic tick; #2; clk = 1; #2; clk = 0; #2; endtask
  task automatic check(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "ORIGIN_CACHE_FAIL %s", label);
  endtask
  task automatic access(input bit write_access, input logic [CVA6Cfg.PLEN-1:0] address,
                        input logic [2:0] prot);
    logic [2:0] expected;
    int port_index;
    dcache_req_t held;
    source_write = write_access; source_address = address;
    source_prot = prot; source_data = 64'hDEAD_BEEF_1234_5678;
    port_index = write_access ? 3 : 1;
    expected = Enabled && !config_pkg::is_inside_cacheable_regions(
        CVA6Cfg, 64'(address)) ? prot : 3'b000;
    source_valid = 1;
    #1;
    for (int n = 0; n < 4096 && !responses[port_index].data_gnt; n++) tick();
    check(responses[port_index].data_gnt, "core-grant");
    tick(); source_valid = 0;
    for (int n = 0; n < 4096 && !mem_req; n++) tick();
    check(mem_req, "memory-offer");
    held = memory_request;
    check(held.rtype == (write_access ? DCACHE_STORE_REQ : DCACHE_LOAD_REQ), "request-class");
    check(held.data_prot == (expected ^ (negative ? 3'b001 : 3'b000)), "origin");
    repeat (7) begin
      source_prot ^= 3'b111; source_data = ~source_data;
      tick();
      check(mem_req && memory_request == held, "held-descriptor-under-backpressure");
    end
    return_id = held.tid;
    return_type = write_access ? DCACHE_STORE_ACK : DCACHE_LOAD_ACK;
    mem_ack = 1; tick(); mem_ack = 0;
    repeat (2) tick();
    return_valid = 1; tick(); return_valid = 0;
    repeat (12) tick();
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    repeat (3) tick(); rst_n = 1;
    repeat (1024) tick();
    access(1, CVA6Cfg.PLEN'(64'h1000_0000), 3'b001);
    access(1, CVA6Cfg.PLEN'(64'h1000_0008), 3'b011);
    access(1, CVA6Cfg.PLEN'(64'h1000_0010), 3'b010);
    access(0, CVA6Cfg.PLEN'(64'h1000_0000), 3'b001);
    access(0, CVA6Cfg.PLEN'(64'h1000_0008), 3'b011);
    access(0, CVA6Cfg.PLEN'(64'h1000_0010), 3'b010);
    // Cache disable must not turn a PMA-cacheable RAM descriptor into authority.
    access(1, CVA6Cfg.PLEN'(64'h8000_0000), 3'b001);
    access(0, CVA6Cfg.PLEN'(64'h8000_0008), 3'b001);
    $display("ORIGIN_CACHE_PASS checks=%0d enabled=%0d", checks, Enabled);
    $finish;
  end
  initial begin #1000000; $fatal(1, "ORIGIN_CACHE_TIMEOUT"); end
endmodule
