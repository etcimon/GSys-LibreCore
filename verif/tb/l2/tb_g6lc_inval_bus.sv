// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_inval_bus;
  import g6lc_coherence_pkg::*;
  parameter int unsigned CORES = 3;
  parameter int unsigned DEPTH = 2;
  logic clk = 0, rst_n = 0;
  coh_inval_t request;
  logic [CORES-1:0] targets, consumer_ready;
  coh_inval_t [CORES-1:0] delivered;
  logic ready, blocked, coalesced;
  coh_inval_t reference[CORES][DEPTH];
  int unsigned count[CORES];
  int unsigned cycles = 0, accepted = 0, pops = 0, merges = 0, stalls = 0;
  logic [31:0] random_state = 32'h59e321a7;
  bit negative, last_ready;
  int scenario;

  g6lc_inval_bus #(.NR_CORES(CORES), .DEPTH(DEPTH)) dut (
    .clk_i(clk), .rst_ni(rst_n), .inv_req_i(request), .inv_target_i(targets),
    .inv_ready_o(ready), .inv_core_o(delivered), .inv_core_ready_i(consumer_ready),
    .inv_drop_o(blocked), .inv_coalesce_o(coalesced)
  );

  function automatic logic [31:0] next_random();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction

  function automatic coh_inval_t command(input logic [55:0] line,
                                         input logic [2:0] flags);
    return '{valid: 1'b1, all_ways: flags[2], dcache: flags[1],
             icache: flags[0], line_addr: line};
  endfunction

  task automatic check_heads;
    for (int c = 0; c < CORES; c++) begin
      if (count[c] == 0) begin
        if (delivered[c].valid)
          $fatal(1, "INVBUS_DELIVERY extra core=%0d cycle=%0d packet=%h", c, cycles, delivered[c]);
      end else if (delivered[c] !== reference[c][0]) begin
        $fatal(1, "INVBUS_DELIVERY core=%0d cycle=%0d expected=%h actual=%h count=%0d", c, cycles, reference[c][0], delivered[c], count[c]);
      end
    end
  endtask

  task automatic cycle;
    bit expected_ready, expected_merge, observed_ready, events_match;
    bit merge_target[CORES];
    bit pop_target[CORES];
    clk = 0;
    #2;
    check_heads();
    expected_ready = 1;
    expected_merge = 0;
    for (int c = 0; c < CORES; c++) begin
      pop_target[c] = count[c] != 0 && consumer_ready[c];
      merge_target[c] = 0;
      if (CORES > 1 && request.valid && targets[c]) begin
        if (count[c] != 0)
          merge_target[c] = reference[c][count[c]-1].line_addr == request.line_addr &&
                            !(count[c] == 1 && pop_target[c]);
        expected_ready &= count[c] < DEPTH || merge_target[c];
        expected_merge |= merge_target[c];
      end
    end
    observed_ready = ready;
    if (negative && request.valid) begin
      observed_ready = !observed_ready;
      negative = 0;
    end
    if (observed_ready !== expected_ready)
      $fatal(1, "INVBUS_READY cycle=%0d targets=%b expected=%b actual=%b", cycles, targets, expected_ready, observed_ready);
    events_match = blocked === (request.valid && !expected_ready) &&
                   coalesced === (request.valid && expected_ready && expected_merge);
    last_ready = expected_ready;
    if (request.valid && expected_ready) accepted++;
    if (request.valid && !expected_ready) stalls++;
    if (CORES > 1) begin
      for (int c = 0; c < CORES; c++) begin
        if (pop_target[c]) begin
          for (int j = 1; j < int'(DEPTH); j++) reference[c][j-1] = reference[c][j];
          count[c]--;
          pops++;
        end
        if (request.valid && expected_ready && targets[c]) begin
          if (merge_target[c]) begin
            reference[c][count[c]-1].dcache |= request.dcache;
            reference[c][count[c]-1].icache |= request.icache;
            reference[c][count[c]-1].all_ways |= request.all_ways;
            merges++;
          end else begin
            if (count[c] >= DEPTH) $fatal(1, "INVBUS_REFERENCE overflow");
            reference[c][count[c]] = request;
            count[c]++;
          end
        end
      end
    end
    clk = 1;
    #2;
    cycles++;
    check_heads();
    if (!events_match) $fatal(1, "INVBUS_EVENTS cycle=%0d", cycles);
    clk = 0;
    #1;
  endtask

  task automatic reset;
    rst_n = 0;
    request = '0;
    targets = '0;
    consumer_ready = '0;
    for (int c = 0; c < CORES; c++) begin
      count[c] = 0;
      for (int j = 0; j < DEPTH; j++) reference[c][j] = '0;
    end
    #2;
    clk = 1;
    #2;
    clk = 0;
    rst_n = 1;
    #2;
    check_heads();
  endtask

  task automatic send(input logic [CORES-1:0] mask,
                      input logic [55:0] line, input logic [2:0] flags);
    int tries;
    request = command(line, flags);
    targets = mask;
    tries = 0;
    do begin
      cycle();
      tries++;
      if (tries > 64) $fatal(1, "INVBUS_PROGRESS send");
    end while (!last_ready);
    request.valid = 0;
  endtask

  task automatic drain;
    request = '0;
    consumer_ready = '1;
    repeat (DEPTH + 1) cycle();
    for (int c = 0; c < CORES; c++)
      if (count[c] != 0) $fatal(1, "INVBUS_PROGRESS drain");
    consumer_ready = '0;
  endtask

  task automatic basic;
    reset();
    send(CORES'(1), 56'h10, 3'b010);
    send(CORES'(1), 56'h10, 3'b101);
    send('0, 56'h77, 3'b010);
    drain();
    consumer_ready = '1;
    for (int n = 0; n < 4 * DEPTH; n++) send(CORES'(1), 56'(n) + 56'd64, 3'b010);
    drain();
  endtask

  task automatic admission;
    reset();
    for (int n = 0; n < DEPTH; n++) send(CORES'(2), 56'(n) + 56'd128, 3'b010);
    send(CORES'(1), 56'h20, 3'b010);
    request = command(56'h20, 3'b101);
    targets = CORES'(3);
    repeat (3) cycle();
    consumer_ready[(CORES > 1) ? 1 : 0] = 1;
    cycle();
    cycle();
    if (!last_ready) $fatal(1, "INVBUS_PROGRESS released target");
    request.valid = 0;
    drain();
  endtask

  task automatic departure;
    reset();
    send(CORES'(1), 56'h30, 3'b010);
    consumer_ready[0] = 1;
    send(CORES'(1), 56'h30, 3'b111);
    drain();
  endtask

  task automatic randomized;
    bit holding;
    logic [31:0] value;
    reset();
    holding = 0;
    for (int n = 0; n < 600; n++) begin
      if (!holding) begin
        value = next_random();
        request = command(56'(value[7:4]), value[10:8]);
        request.valid = value[0];
        targets = CORES'(value >> 12);
      end
      value = next_random();
      consumer_ready = CORES'(value);
      cycle();
      holding = request.valid && !last_ready;
    end
    consumer_ready = '1;
    if (holding) begin
      for (int n = 0; n < DEPTH + 2 && !last_ready; n++) cycle();
      if (!last_ready) $fatal(1, "INVBUS_PROGRESS held request");
    end
    drain();
  endtask

  initial begin
    scenario = 3;
    negative = $test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d", scenario));
    if (scenario < 0 || scenario > 3 || CORES < 1 || DEPTH < 1)
      $fatal(1, "INVBUS_PARAMETERS");
    if (scenario == 0 || scenario == 3) basic();
    if (CORES > 1 && (scenario == 1 || scenario == 3)) admission();
    if (CORES > 1 && (scenario == 2 || scenario == 3)) departure();
    if (scenario == 3) randomized();
    if (cycles == 0 || accepted == 0) $fatal(1, "INVBUS_EMPTY_TEST");
    $display("INVBUS_PASS cores=%0d depth=%0d scenario=%0d cycles=%0d accepted=%0d pops=%0d merges=%0d stalls=%0d", CORES, DEPTH, scenario, cycles, accepted, pops, merges, stalls);
    $finish;
  end
endmodule
