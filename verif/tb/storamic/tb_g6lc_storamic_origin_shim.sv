// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`include "axi/typedef.svh"
module tb_g6lc_storamic_origin_shim #(parameter bit Enabled = 1);
  typedef logic [63:0] addr_t;
  typedef logic [7:0] id_t;
  typedef logic [63:0] data_t;
  typedef logic [7:0] strb_t;
  typedef logic [63:0] user_t;
  `AXI_TYPEDEF_ALL(bus, addr_t, id_t, data_t, strb_t, user_t)
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.AxiAddrWidth = 64; c.AxiIdWidth = 8; c.AxiDataWidth = 64;
    c.AxiUserWidth = 64; c.AXI_USER_EN = 1; c.AxiBurstWriteEn = 1;
    c.StoramicCheckpointEn = Enabled;
    return c;
  endfunction
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  bus_req_t req;
  bus_resp_t resp;
  logic rd = 0, wr = 0, rg, wg;
  logic [2:0] rp = 0, wp = 0;
  int checks = 0;
  axi_shim #(.CVA6Cfg(configuration()), .AxiNumWords(2),
             .axi_req_t(bus_req_t), .axi_rsp_t(bus_resp_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .rd_req_i(rd), .rd_gnt_o(rg),
    .rd_addr_i(64'h1000), .rd_blen_i(1'b0), .rd_size_i(3'd2),
    .rd_id_i(8'd3), .rd_lock_i(1'b0), .rd_prot_i(rp), .rd_rdy_i(1'b1),
    .rd_last_o(), .rd_valid_o(), .rd_data_o(), .rd_user_o(), .rd_id_o(), .rd_exokay_o(),
    .wr_req_i(wr), .wr_gnt_o(wg), .wr_addr_i(64'h1004),
    .wr_data_i(128'h0123), .wr_user_i('1), .wr_be_i(16'h00FF),
    .wr_blen_i(1'b0), .wr_size_i(3'd2), .wr_id_i(8'd4),
    .wr_lock_i(1'b0), .wr_atop_i(6'd0), .wr_prot_i(wp), .wr_rdy_i(1'b1),
    .wr_valid_o(), .wr_id_o(), .wr_exokay_o(), .axi_req_o(req), .axi_resp_i(resp)
  );
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "ORIGIN_SHIM_FAIL %s", label);
  endtask
  initial begin
    resp = '0; repeat (3) tick(); rst_n = 1; tick();
    ok(config_pkg::g6lc_storamic_data_prot(2'b11, 0, 0) == 3'b001, "machine");
    ok(config_pkg::g6lc_storamic_data_prot(2'b01, 0, 0) == 3'b011, "supervisor");
    ok(config_pkg::g6lc_storamic_data_prot(2'b00, 0, 0) == 3'b010, "user");
    ok(config_pkg::g6lc_storamic_data_prot(2'b10, 0, 0) == 0, "reserved-untrusted");
    ok(config_pkg::g6lc_storamic_data_prot(2'b11, 1, 0) == 0, "virtual-untrusted");
    ok(config_pkg::g6lc_storamic_data_prot(2'b11, 0, 1) == 0, "debug-untrusted");
    for (int p = 0; p < 8; p++) begin
      rp = 3'(p); rd = 1;
      repeat (3) begin
        tick(); ok(req.ar_valid && req.ar.prot == (Enabled ? rp : 3'b000),
                   "read-descriptor-held");
      end
      resp.ar_ready = 1; tick(); rd = 0; resp.ar_ready = 0;
    end
    wp = 3'b011; wr = 1;
    while (!req.aw_valid) tick();
    repeat (3) begin
      tick(); ok(req.aw.prot == (Enabled ? wp : 3'b000), "write-descriptor-held");
      ok(req.w.user == '1, "WUSER-is-not-authorization");
    end
    resp.aw_ready = 1; tick(); resp.aw_ready = 0;
    repeat (3) tick();
    ok(!req.aw_valid, "accepted-AW-not-reissued");
    resp.w_ready = 1;
    do @(posedge clk); while (!wg);
    tick(); wr = 0; resp.w_ready = 0; tick();
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("ORIGIN_SHIM_PASS checks=%0d enabled=%0d", checks, Enabled);
    $finish;
  end
  initial begin #100000; $fatal(1, "ORIGIN_SHIM_TIMEOUT"); end
endmodule
