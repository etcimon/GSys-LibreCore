// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_store_guard;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  logic enabled = 1, req = 0, gnt, we = 1, rv, err, idle, refuse;
  logic [63:0] capacity = 512, addr = 0, data = 0, rdata;
  logic [7:0] be = 8'h5A;
  logic dr, dg, dw, dv = 0, de = 0, grant_enable = 1, force_error = 0;
  logic [63:0] da, dd, rd = 0, saved_addr, saved_data;
  logic [7:0] db;
  logic pending = 0, saved_error, last_allowed;
  logic [63:0] expected_addr, expected_data;
  logic [7:0] expected_be;
  logic expected_we;
  int delay_q = 0, grants = 0, checks = 0, refusals = 0;
  assign dg = dr && grant_enable && !pending && !dv;
  g6lc_storamic_store_guard dut (
    .clk_i(clk), .rst_ni(rst_n), .enable_i(enabled), .capacity_bytes_i(capacity),
    .idle_o(idle), .refuse_event_o(refuse), .phase_o(),
    .st_req_i(req), .st_gnt_o(gnt), .st_we_i(we), .st_addr_i(addr),
    .st_wdata_i(data), .st_be_i(be), .st_rvalid_o(rv), .st_rdata_o(rdata), .st_error_o(err),
    .down_req_o(dr), .down_gnt_i(dg), .down_we_o(dw), .down_addr_o(da),
    .down_wdata_o(dd), .down_be_o(db), .down_rvalid_i(dv),
    .down_rdata_i(rd), .down_error_i(de)
  );
  always @(posedge clk) if (rst_n) begin
    dv <= 0;
    if (gnt) begin
      expected_addr <= addr; expected_data <= data; expected_be <= be; expected_we <= we;
      last_allowed <= enabled && addr[2:0] == 0 &&
                      ({1'b0, addr} + 65'd8 <= {1'b0, capacity});
    end
    if (dg) begin
      assert (last_allowed && da == expected_addr && dd == expected_data &&
              db == expected_be && dw == expected_we)
        else $fatal(1, "STORE_GUARD_ASSERT forwarded-bound-or-payload");
      pending <= 1; delay_q <= 4; saved_addr <= da; saved_data <= dd;
      saved_error <= force_error; grants++;
    end
    if (pending) begin
      delay_q <= delay_q - 1;
      if (delay_q == 1) begin
        pending <= 0; dv <= 1; rd <= saved_addr ^ saved_data; de <= saved_error;
      end
    end
    if (refuse) refusals++;
    if (rv) assert (!gnt && !dr) else $fatal(1, "STORE_GUARD_ASSERT response-owned");
  end
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "STORE_GUARD_FAIL %s", label);
  endtask
  task automatic access_word(input logic [63:0] offset, input bit expected_error,
                             input bit forwarded);
    int before_grants;
    before_grants = grants;
    req = 1; addr = offset; data = 64'h1234_5678; we = 1; be = 8'h5A;
    do @(posedge clk); while (!gnt);
    tick(); req = 0; addr = '1; data = 0; we = 0; be = 0;
    while (!rv) tick();
    ok(err == expected_error && rdata == (expected_error ? 64'd0 : offset ^ 64'h1234_5678),
       "terminal-response-snapshot");
    ok(grants == before_grants + int'(forwarded), "only-legal-command-reaches-media");
    tick(); ok(idle, "response-retires-before-idle");
  endtask
  initial begin
    repeat (3) tick(); rst_n = 1; tick();
    access_word(0, 0, 1); access_word(504, 0, 1);
    access_word(512, 1, 0); access_word(1, 1, 0);
    access_word(64'hFFFF_FFFF_FFFF_FFF8, 1, 0);
    capacity = 0; access_word(0, 1, 0);
    capacity = 15; access_word(0, 0, 1); access_word(8, 1, 0);
    capacity = 64'h1_0000_0000;
    access_word(64'hFFFF_FFF8, 0, 1); access_word(64'h1_0000_0000, 1, 0);
    capacity = 64'h1_0000_0008; access_word(64'h1_0000_0000, 0, 1);
    capacity = '1;
    access_word(64'hFFFF_FFFF_FFFF_FFF0, 0, 1);
    access_word(64'hFFFF_FFFF_FFFF_FFF8, 1, 0);
    enabled = 0; access_word(0, 1, 0);
    enabled = 1; capacity = 512; grant_enable = 0;
    req = 1; addr = 8; data = 64'hABCD; be = 8'h5A; we = 1;
    do @(posedge clk); while (!gnt);
    tick(); req = 0; addr = '1; data = 0; be = 0; we = 0;
    while (!dr) tick();
    enabled = 0; capacity = 0;
    repeat (4) begin
      tick(); ok(dr && da == 8 && dd == 64'hABCD && !rv && !idle,
                 "accepted-offer-survives-disable-and-capacity-change");
    end
    grant_enable = 1;
    while (!rv) tick();
    ok(!err && rdata == (64'd8 ^ 64'hABCD), "accepted-command-drains-before-disable");
    tick(); access_word(0, 1, 0);
    enabled = 1; capacity = 512; force_error = 1;
    access_word(0, 1, 1);
    ok(refusals == 9, "exactly-one-refusal-event-per-denied-command");
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("STORE_GUARD_PASS checks=%0d", checks);
    $finish;
  end
  initial begin #100000; $fatal(1, "STORE_GUARD_TIMEOUT"); end
endmodule
