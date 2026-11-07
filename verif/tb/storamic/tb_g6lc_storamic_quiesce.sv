// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_storamic_quiesce;
  import g6lc_storamic_pkg::*;
  localparam logic [63:0] Base = 64'h8000_0000;
  logic clk = 0, rst_n = 0, quiesce = 0, quiesced, inflight;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  axi_req_t req;
  axi_resp_t resp;
  logic mem_req, mem_gnt, mem_we, mem_rvalid, mem_error, mem_ready;
  logic grant_enable = 1;
  logic [63:0] mem_addr, mem_wdata, mem_rdata;
  logic [7:0] mem_be;
  txn_id_t mem_tag, reply_tag;
  int checks = 0, failures = 0, commands = 0;

  g6lc_storamic_axi_memory #(.RegionBytes(256)) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .quiesce_i(quiesce), .quiesced_o(quiesced), .inflight_o(inflight),
    .req_i(req), .resp_o(resp), .source_i(8'h3a), .reset_generation_i(32'd0),
    .service_ready_o(), .sequence_exhausted_o(), .faults_o(), .events_o(),
    .mem_ready_i(mem_ready), .mem_req_o(mem_req), .mem_gnt_i(mem_gnt),
    .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata),
    .mem_be_o(mem_be), .mem_tag_o(mem_tag), .mem_slot_o(),
    .mem_rvalid_i(mem_rvalid), .mem_rdata_i(mem_rdata),
    .mem_error_i(mem_error), .mem_tag_i(reply_tag),
    .map_valid_i(1'b0), .slot_map_i('0), .region_map_i('0)
  );
  g6lc_storamic_sram_model #(.Capacity(256), .Latency(4)) ram (
    .clk_i(clk), .rst_ni(rst_n), .available_i(1'b1),
    .grant_enable_i(grant_enable), .reply_enable_i(1'b1), .error_i(1'b0),
    .ready_o(mem_ready), .req_i(mem_req), .gnt_o(mem_gnt), .we_i(mem_we),
    .addr_i(mem_addr), .data_i(mem_wdata), .be_i(mem_be), .tag_i(mem_tag),
    .rvalid_o(mem_rvalid), .data_o(mem_rdata), .error_o(mem_error), .tag_o(reply_tag)
  );

  always @(posedge clk) begin
    if (rst_n && mem_req && mem_gnt) commands++;
    if (rst_n && quiesce) begin
      assert (!resp.aw_ready && !resp.ar_ready)
        else $fatal(1, "QUIESCE_ADDRESS_ADMITTED");
      if (quiesced)
        assert (!inflight && !mem_req && !resp.b_valid && !resp.r_valid)
          else $fatal(1, "QUIESCE_EARLY_ACK");
    end
  end
  initial begin
    repeat (5000) tick;
    $fatal(1, "QUIESCE_TIMEOUT");
  end
  task automatic chk(input logic condition, input string label);
    checks++;
    if (!condition) begin
      failures++;
      $display("QUIESCE_CHECK_FAIL %s", label);
    end
  endtask
  task automatic aw(input logic [63:0] addr, input logic [7:0] len);
    req.aw = '0;
    req.aw.addr = addr; req.aw.id = 8'h21; req.aw.len = len;
    req.aw.size = 3; req.aw.burst = 1; req.aw_valid = 1;
    do @(posedge clk); while (!resp.aw_ready);
    tick; req.aw_valid = 0;
  endtask
  task automatic ar(input logic [63:0] addr, input logic [7:0] len);
    req.ar = '0;
    req.ar.addr = addr; req.ar.id = 8'h42; req.ar.len = len;
    req.ar.size = 3; req.ar.burst = 1; req.ar_valid = 1;
    do @(posedge clk); while (!resp.ar_ready);
    tick; req.ar_valid = 0;
  endtask
  task automatic w(input logic [63:0] data, input logic last);
    req.w = '0;
    req.w.data = data; req.w.strb = '1; req.w.last = last; req.w_valid = 1;
    do @(posedge clk); while (!resp.w_ready);
    tick; req.w_valid = 0;
  endtask
  task automatic retire_b;
    while (!resp.b_valid) tick;
    chk(resp.b.id == 8'h21 && resp.b.resp == 0, "write response retained");
    req.b_ready = 1; tick; req.b_ready = 0;
  endtask
  task automatic retire_r(input logic [63:0] expected, input logic last);
    while (!resp.r_valid) tick;
    chk(resp.r.id == 8'h42 && resp.r.resp == 0 &&
        resp.r.data == expected && resp.r.last == last, "read response retained");
    req.r_ready = 1; tick; req.r_ready = 0;
  endtask

  initial begin
    req = '0;
    quiesce = 1;
    tick; chk(!quiesced, "reset does not acknowledge");
    tick; rst_n = 1; tick;
    chk(quiesced && !inflight, "idle quiesce acknowledged");
    req.aw_valid = 1; req.ar_valid = 1;
    repeat (4) tick;
    chk(commands == 0 && quiesced, "sealed addresses have no side effects");
    req.aw_valid = 0; req.ar_valid = 0; quiesce = 0; tick;

    // An accepted AW still owns every W beat, including a delayed final beat.
    aw(Base, 1);
    quiesce = 1; tick;
    chk(!quiesced && resp.w_ready, "accepted AW can receive W while sealed");
    req.ar_valid = 1; req.aw_valid = 1;
    w(64'h1122_3344_5566_7788, 0);
    repeat (3) tick;
    chk(!quiesced, "incomplete write burst keeps drain open");
    w(64'h99AA_BBCC_DDEE_FF00, 1);
    while (!resp.b_valid) tick;
    repeat (3) begin
      chk(!quiesced && resp.b_valid, "B backpressure prevents acknowledgement");
      tick;
    end
    retire_b();
    chk(quiesced && commands == 2, "write burst drains before acknowledgement");
    req.aw_valid = 0; req.ar_valid = 0; quiesce = 0; tick;

    // An offered memory command remains live even while its grant is stalled.
    grant_enable = 0;
    ar(Base, 1);
    quiesce = 1;
    while (!mem_req) tick;
    repeat (3) begin
      chk(mem_req && mem_addr == 0 && !quiesced, "stalled memory offer drains");
      tick;
    end
    grant_enable = 1;
    while (!resp.r_valid) tick;
    repeat (3) begin
      chk(!quiesced && resp.r_valid, "R backpressure prevents acknowledgement");
      tick;
    end
    retire_r(64'h1122_3344_5566_7788, 0);
    chk(!quiesced, "read burst tail still owns context");
    retire_r(64'h99AA_BBCC_DDEE_FF00, 1);
    chk(quiesced, "last R retirement acknowledges drain");
    quiesce = 0; tick;

    // Read and write contexts both predate the pause; neither may disappear.
    req.aw = '0; req.ar = '0;
    req.aw.addr = Base + 16; req.aw.id = 8'h21;
    req.aw.size = 3; req.aw.burst = 1;
    req.ar.addr = Base; req.ar.id = 8'h42;
    req.ar.size = 3; req.ar.burst = 1;
    req.aw_valid = 1; req.ar_valid = 1;
    do @(posedge clk); while (!(resp.aw_ready && resp.ar_ready));
    tick; req.aw_valid = 0; req.ar_valid = 0; quiesce = 1;
    w(64'hCAFE_BABE_1234_5678, 1);
    while (!(resp.b_valid && resp.r_valid)) tick;
    chk(!quiesced, "simultaneous contexts held");
    retire_b();
    chk(!quiesced, "retiring B alone does not acknowledge pending R");
    retire_r(64'h1122_3344_5566_7788, 1);
    chk(quiesced, "both contexts retired");

    // Resuming service preserves data and does not reset ownership epochs.
    quiesce = 0; tick;
    ar(Base + 16, 0);
    retire_r(64'hCAFE_BABE_1234_5678, 1);
    chk(!quiesced && !inflight, "normal service resumes");

    // Refused accesses also own a response that must drain before ack.
    ar(Base + 512, 0);
    quiesce = 1;
    while (!resp.r_valid) tick;
    chk(!quiesced && resp.r.resp == 2, "error response drains before ack");
    req.r_ready = 1; tick; req.r_ready = 0;
    chk(quiesced && commands == 7, "refusal does not touch memory");
    if ($test$plusargs("oracle_negative")) chk(1'b0, "negative oracle");
    if (failures != 0) $fatal(1, "QUIESCE_FAILED checks=%0d failures=%0d", checks, failures);
    $display("QUIESCE_PASS checks=%0d", checks);
    $finish;
  end
endmodule
