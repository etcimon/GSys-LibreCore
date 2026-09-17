// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_fetch_queue;
  import ariane_pkg::*;
  parameter int unsigned SLOTS = 4;
  parameter int unsigned ISSUE = 2;
  parameter int unsigned HARTS = 2;
  parameter bit RVC = 1;
  localparam int unsigned HW = HARTS > 1 ? $clog2(HARTS) : 1;

  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.GPLEN = 64;
    c.FETCH_WIDTH = SLOTS * (RVC ? 16 : 32);
    c.FETCH_ALIGN_BITS = $clog2(c.FETCH_WIDTH / 8);
    c.INSTR_PER_FETCH = SLOTS;
    c.LOG2_INSTR_PER_FETCH = $clog2(SLOTS);
    c.NrHarts = HARTS;
    c.NrIssuePorts = ISSUE;
    c.RVC = RVC;
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
  logic ready, replay, leftover;
  frontend_exception_t exception;
  logic [63:0] exception_addr, prediction;
  logic [63:0] replay_addr;
  entry_t [ISSUE-1:0] entry;
  logic [ISSUE-1:0] entry_valid, entry_ready;
  entry_t expected[$];
  int unsigned accepted = 0, retired = 0, discarded = 0, serial = 0;
  int unsigned sparse = 0, stalled = 0, flushed = 0, dual = 0, branches = 0;
  int unsigned partial = 0, target_full = 0, faults = 0, concurrent = 0;
  int unsigned read_serial = 0, write_serial = 0, long_accepted = 0;
  bit negative;
  logic [31:0] rng = 32'h6c630123;

  instr_queue #(.CVA6Cfg(cfg()), .fetch_entry_t(entry_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .hart_i(hart),
    .instr_i(instr), .addr_i(addr), .valid_i(valid), .leftover_complete_i(leftover),
    .ready_o(ready), .consumed_o(consumed), .exception_i(exception),
    .exception_addr_i(exception_addr), .exception_gpaddr_i('0), .exception_tinst_i('0),
    .exception_gva_i(1'b0), .predict_address_i(prediction), .cf_type_i(cf),
    .replay_o(replay), .replay_addr_o(replay_addr),
    .fetch_entry_o(entry), .fetch_entry_valid_o(entry_valid), .fetch_entry_ready_i(entry_ready)
  );

  task automatic step(input logic [SLOTS-1:0] mask,
                      input logic [ISSUE-1:0] drain,
                      input bit squash = 0,
                      input int unsigned h = 0,
                      input int cf_slot = -1,
                      input bit carry = 0,
                      input frontend_exception_t fault = FE_NONE);
    entry_t want, got;
    bit prefix, stop, overflow, addr_overflow, has_cf, blocked;
    int fires, rank, targets;
    int occupancy[SLOTS];
    logic [SLOTS-1:0] eligible, accept;
    logic [63:0] retry;
    valid = mask;
    entry_ready = drain;
    flush = squash;
    hart = HW'(h);
    leftover = carry;
    exception = fault;
    exception_addr = 64'h90000000 + 64'(serial * 8);
    prediction = 64'h80000200 + 64'((serial % 17) * 2);
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
        read_serial = 0;
        write_serial = 0;
        flushed++;
      end else begin
        foreach (occupancy[f]) occupancy[f] = 0;
        targets = 0;
        for (int i = 0; i < expected.size(); i++) begin
          occupancy[(read_serial + i) % SLOTS]++;
          if (expected[i].branch_predict.cf != NoCF) targets++;
        end
        eligible = '0;
        stop = 0;
        rank = 0;
        overflow = 0;
        for (int s = 0; s < SLOTS; s++) begin
          eligible[s] = valid[s] && !stop;
          if (eligible[s]) begin
            if (occupancy[(write_serial + rank) % SLOTS] == 8) overflow = 1;
            rank++;
          end
          if (cf[s] != NoCF) stop = 1;
        end
        accept = overflow ? '0 : eligible;
        if (overflow && carry && eligible[0] && occupancy[write_serial % SLOTS] < 8)
          accept[0] = 1;
        has_cf = 0;
        for (int s = 0; s < SLOTS; s++) has_cf |= accept[s] && cf[s] != NoCF;
        addr_overflow = has_cf && targets == FETCH_ADDR_FIFO_DEPTH;
        if (addr_overflow) accept = '0;
        blocked = targets == FETCH_ADDR_FIFO_DEPTH;
        foreach (occupancy[f]) blocked |= occupancy[f] == 8;
        if (ready !== !blocked || consumed !== accept || replay !== (overflow || addr_overflow))
          $fatal(1, "acceptance mismatch expected=%b actual=%b ready=%b replay=%b", accept, consumed, ready, replay);
        retry = exception_addr;
        if (overflow && carry && accept[0]) begin
          stop = 0;
          for (int s = 1; s < SLOTS; s++) begin
            if (eligible[s] && !stop) begin
              retry = addr[s];
              stop = 1;
            end
          end
          partial++;
        end
        if (replay && replay_addr !== retry) $fatal(1, "replay PC mismatch");
        if (addr_overflow) target_full++;
        if (entry_valid[0] !== (expected.size() != 0)) $fatal(1, "empty/valid mismatch");
        prefix = 1;
        fires = 0;
        for (int p = 0; p < ISSUE; p++) begin
          prefix &= entry_valid[p] && entry_ready[p];
          if (prefix) begin
            if (expected.size() == 0) $fatal(1, "queue fabricated entry");
            want = expected.pop_front();
            got = entry[p];
            if (negative) begin
              got.address ^= 64'd2;
              negative = 0;
            end
            if (got.address !== want.address || got.instruction !== want.instruction ||
                got.hart_id !== want.hart_id || got.ex.valid !== want.ex.valid ||
                (want.ex.valid && (got.ex.cause !== want.ex.cause || got.ex.tval !== want.ex.tval)) ||
                got.branch_predict.cf !== want.branch_predict.cf ||
                (want.branch_predict.cf != NoCF &&
                 got.branch_predict.predict_address !== want.branch_predict.predict_address))
              $fatal(1, "order/data mismatch retired=%0d port=%0d expected_pc=%h actual_pc=%h expected_instr=%h actual_instr=%h", retired, p, want.address, got.address, want.instruction, got.instruction);
            retired++;
            read_serial++;
            fires++;
          end
        end
        if (fires > 1) dual++;
        if (fires != 0 && |consumed) concurrent++;
        for (int s = 0; s < SLOTS; s++) begin
          if (consumed[s]) begin
            want = '0;
            want.address = addr[s];
            want.instruction = instr[s];
            want.hart_id = hart;
            want.ex.valid = fault != FE_NONE;
            want.ex.cause = fault == FE_INSTR_ACCESS_FAULT ? riscv::INSTR_ACCESS_FAULT : riscv::INSTR_PAGE_FAULT;
            want.ex.tval = exception_addr;
            want.branch_predict.cf = cf[s];
            want.branch_predict.predict_address = prediction;
            expected.push_back(want);
            accepted++;
            write_serial++;
            if (cf[s] != NoCF) branches++;
            if (fault != FE_NONE) faults++;
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
    negative = $test$plusargs("oracle_negative");
    step('0, '0);
    rst_n = 1;
    step(SLOTS'(2), '0);
    step('1, '0);
    repeat (12) step('0, '1);
    step('0, '0, 1);
    repeat (8) step('1, '0);
    step('0, ISSUE'(1));
    step('1, '0, 0, HARTS-1, -1, 1, FE_INSTR_ACCESS_FAULT);
    repeat (SLOTS * 8 + 2) step('0, '1);
    step('0, '0, 1);
    repeat (FETCH_ADDR_FIFO_DEPTH + 1) step(SLOTS'(1), '0, 0, 0, 0);
    repeat (SLOTS * 8 + 2) step('0, '1);
    for (int n = 0; n < 800; n++) begin
      rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
      step(SLOTS'(rng), ISSUE'(rng >> 4), (n % 73) == 72,
           (n % HARTS), (n % 17) == 0 ? SLOTS-1 : -1, rng[9],
           (n % 29) == 0 ? FE_INSTR_PAGE_FAULT : FE_NONE);
    end
    repeat (SLOTS * 8 + 2) step('0, '1);
    step('0, '0, 1);
    long_accepted = accepted;
    for (int n = 0; n < 70000; n++)
      step(SLOTS'(1) << (n % SLOTS), '1, 0, n % HARTS);
    long_accepted = accepted - long_accepted;
    repeat (SLOTS * 8 + 2) step('0, '1);
    if (expected.size() != 0 || accepted != retired + discarded ||
        long_accepted <= 65536 || (SLOTS > 1 && (sparse == 0 || partial == 0)) ||
        stalled == 0 || flushed == 0 || target_full == 0 || faults == 0 || concurrent == 0 ||
        branches == 0 || (ISSUE > 1 && dual == 0))
      $fatal(1, "incomplete coverage/conservation accepted=%0d retired=%0d discarded=%0d remaining=%0d", accepted, retired, discarded, expected.size());
    $display("FETCH_QUEUE_PASS accepted=%0d retired=%0d discarded=%0d sparse=%0d stalled=%0d flush=%0d dual=%0d branches=%0d partial=%0d target_full=%0d faults=%0d concurrent=%0d long_accepted=%0d", accepted, retired, discarded, sparse, stalled, flushed, dual, branches, partial, target_full, faults, concurrent, long_accepted);
    $finish;
  end
endmodule
