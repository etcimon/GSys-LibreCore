// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_fetch_queue;
  import ariane_pkg::*;
  parameter int unsigned SLOTS = 4;
  parameter int unsigned ISSUE = 2;
  parameter int unsigned HARTS = 2;
  localparam int unsigned HW = HARTS > 1 ? $clog2(HARTS) : 1;

  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.GPLEN = 64;
    c.FETCH_WIDTH = SLOTS * 16;
    c.FETCH_ALIGN_BITS = $clog2(SLOTS * 2);
    c.INSTR_PER_FETCH = SLOTS;
    c.LOG2_INSTR_PER_FETCH = $clog2(SLOTS);
    c.NrHarts = HARTS;
    c.NrIssuePorts = ISSUE;
    c.RVC = 1;
    c.SuperscalarEn = ISSUE > 1;
    c.TvalEn = 1;
    return c;
  endfunction

  typedef struct packed {
    logic [63:0] cause, tval, tval2;
    logic [31:0] tinst;
    logic gva, valid;
  } exc_t;
  typedef struct packed {
    cf_t cf;
    logic [63:0] predict_address;
  } bp_t;
  typedef struct packed {
    logic [63:0] address;
    logic [31:0] instruction;
    bp_t branch_predict;
    exc_t ex;
    logic [HW-1:0] hart_id;
  } entry_t;

  logic clk = 0, rst_n = 0, flush;
  logic [HW-1:0] hart;
  logic [SLOTS-1:0][31:0] instr;
  logic [SLOTS-1:0][63:0] addr;
  logic [SLOTS-1:0] valid, consumed;
  cf_t [SLOTS-1:0] cf;
  logic ready, replay;
  logic [63:0] replay_addr;
  entry_t [ISSUE-1:0] entry;
  logic [ISSUE-1:0] entry_valid, entry_ready;
  entry_t expected[$];
  int unsigned accepted = 0, retired = 0, discarded = 0, serial = 0;
  int unsigned sparse = 0, stalled = 0, flushed = 0, dual = 0, branches = 0;
  logic [31:0] rng = 32'h6c630123;

  instr_queue #(.CVA6Cfg(cfg()), .fetch_entry_t(entry_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .hart_i(hart),
    .instr_i(instr), .addr_i(addr), .valid_i(valid), .leftover_complete_i(1'b0),
    .ready_o(ready), .consumed_o(consumed), .exception_i(FE_NONE),
    .exception_addr_i(addr[0]), .exception_gpaddr_i('0), .exception_tinst_i('0),
    .exception_gva_i(1'b0), .predict_address_i(64'h80000200), .cf_type_i(cf),
    .replay_o(replay), .replay_addr_o(replay_addr), .fetch_entry_o(entry),
    .fetch_entry_valid_o(entry_valid), .fetch_entry_ready_i(entry_ready)
  );

  task automatic step(input logic [SLOTS-1:0] mask,
                      input logic [ISSUE-1:0] drain,
                      input bit squash = 0,
                      input int unsigned h = 0,
                      input int cf_slot = -1);
    entry_t want, got;
    bit prefix;
    int fires;
    valid = mask;
    entry_ready = drain;
    flush = squash;
    hart = HW'(h);
    cf = '0;
    for (int s = 0; s < SLOTS; s++) begin
      instr[s] = 32'h00000013 | (32'(serial + s) << 20);
      addr[s] = 64'h80000000 + 64'((serial % 64) * 16 + s * 4);
      if (s == cf_slot) cf[s] = Branch;
    end
    serial += SLOTS;
    #5;
    if (rst_n) begin
      if (squash) begin
        discarded += expected.size();
        expected.delete();
        flushed++;
      end else begin
        prefix = 1;
        fires = 0;
        for (int p = 0; p < ISSUE; p++) begin
          prefix &= entry_valid[p] && entry_ready[p];
          if (prefix) begin
            if (expected.size() == 0) $fatal(1, "queue fabricated entry");
            want = expected.pop_front();
            got = entry[p];
            if (got.address != want.address || got.instruction != want.instruction ||
                got.hart_id != want.hart_id || got.ex.valid ||
                got.branch_predict.cf != want.branch_predict.cf ||
                (want.branch_predict.cf != NoCF &&
                 got.branch_predict.predict_address != want.branch_predict.predict_address))
              $fatal(1, "order/data mismatch retired=%0d port=%0d expected_pc=%h actual_pc=%h expected_instr=%h actual_instr=%h", retired, p, want.address, got.address, want.instruction, got.instruction);
            retired++;
            fires++;
          end
        end
        if (fires > 1) dual++;
        for (int s = 0; s < SLOTS; s++) begin
          if (consumed[s]) begin
            if (!valid[s]) $fatal(1, "consumed invalid slot");
            want = '0;
            want.address = addr[s];
            want.instruction = instr[s];
            want.hart_id = hart;
            want.branch_predict.cf = cf[s];
            want.branch_predict.predict_address = 64'h80000200;
            expected.push_back(want);
            accepted++;
            if (cf[s] != NoCF) branches++;
          end
        end
        if (mask != '0 && !mask[0]) sparse++;
        if (expected.size() != 0 && drain == '0) stalled++;
      end
    end
    clk = 1;
    #5;
    clk = 0;
  endtask

  initial begin
    step('0, '0);
    rst_n = 1;
    step(SLOTS'(2), '0);
    step('1, '0);
    repeat (12) step('0, '1);
    for (int n = 0; n < 800; n++) begin
      rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
      step(SLOTS'(rng), rng[4] ? '1 : '0, (n % 73) == 72,
           (n % HARTS), (n % 17) == 0 ? SLOTS-1 : -1);
    end
    repeat (80) step('0, '1);
    if (expected.size() != 0 || accepted != retired + discarded ||
        accepted < 100 || sparse == 0 || stalled == 0 || flushed == 0 ||
        branches == 0 || (ISSUE > 1 && dual == 0))
      $fatal(1, "incomplete coverage/conservation accepted=%0d retired=%0d discarded=%0d remaining=%0d", accepted, retired, discarded, expected.size());
    $display("FETCH_QUEUE_PASS accepted=%0d retired=%0d discarded=%0d sparse=%0d stalled=%0d flush=%0d dual=%0d branches=%0d", accepted, retired, discarded, sparse, stalled, flushed, dual, branches);
    $finish;
  end
endmodule
