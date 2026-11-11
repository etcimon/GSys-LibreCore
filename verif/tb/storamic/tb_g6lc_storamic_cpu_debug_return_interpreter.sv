// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Separate seven-write return-direction gate; original six-write fixtures are unchanged.
module g6lc_storamic_cpu_debug_return_interpreter #(
  parameter bit OriginEnabled = 1,
  parameter int ResponseDelay = 0,
  parameter bit Negative = 0,
  parameter bit RequestEnabled = 1,
  parameter int EntryPrivilege = 3,
  parameter int HoldStage = 3,
  parameter int HoldCycles = 384
) (
  input logic clk, rst_n,
  output logic done, failed, debug_origin_failed, debug_seen,
  output logic [7:0] write_checks, read_checks, debug_writes, debug_reads, csr_checks,
  output logic [31:0] cycles,
  output logic hold_started, hold_finished
);
  localparam logic [63:0] Boot = 64'h8000_0000, Probe = 64'h5000_0000;
  logic debug_req;
  logic awv, awr, wv, wr, wl, bv, br, arv, arr, rv, rr, rl;
  logic [63:0] awa, wd, ara, rd;
  logic [7:0] awid, awlen, ws, bid, arid, arlen, rid;
  logic [2:0] awprot, awsize, arprot, arsize;
  logic [5:0] awatop;
  logic [31:0] rom [1024], debug_rom [1024];
  logic [7:0] memory [64];
  logic write_owned, read_owned, completing;
  logic [63:0] write_addr, read_addr;
  logic [7:0] read_len, read_beat;
  logic [2:0] read_size;
  logic [31:0] wait_cycles;
  logic [15:0] hold_remaining;
  logic b_pending, aw_stalled, w_stalled;
  logic [91:0] stalled_aw;
  logic [72:0] stalled_w;
  initial begin
    assert (EntryPrivilege inside {0, 1, 3});
    assert (HoldStage == 3 && HoldCycles == 384);
    $readmemh("program.hex", rom);
    $readmemh("debug.hex", debug_rom);
  end
  function automatic logic is_probe(input logic [63:0] a);
    return a >= Probe && a < Probe + 64;
  endfunction
  function automatic logic is_debug_data(input logic [63:0] a);
    return a == Probe + 8 || a == Probe + 16 || a == Probe + 24 || a == Probe + 28;
  endfunction
  function automatic logic [63:0] expected_write(input logic [7:0] index);
    case (index)
      0: return Probe;
      1: return Probe + 8;
      2: return Probe + 24;
      3: return Probe + 16;
      4: return Probe + 28;
      5: return Probe + 32;
      6: return Probe + 40;
      default: return Probe + 36;
    endcase
  endfunction
  function automatic logic [63:0] expected_read(input logic [7:0] index);
    case (index)
      0: return Probe + 8;
      1: return Probe + 16;
      2: return Probe;
      3: return Probe + 32;
      default: return Probe + 36;
    endcase
  endfunction
  function automatic logic [2:0] expected_prot(input logic [63:0] a);
    if (Negative && a == Probe + 28) return 3'b001;
    if (!OriginEnabled || is_debug_data(a)) return 3'b000;
    case (EntryPrivilege)
      0: return 3'b010;
      1: return 3'b011;
      default: return 3'b001;
    endcase
  endfunction
  function automatic logic [63:0] read_data(input logic [63:0] a);
    logic [63:0] aligned, result;
    aligned = a & ~64'h7;
    result = '0;
    if (is_probe(aligned)) begin
      for (int b = 0; b < 8; b++)
        result[8*b+:8] = memory[6'(aligned - Probe + 64'(b))];
    end else if (aligned >= Boot && aligned < Boot + 4096)
      result = {rom[10'(((aligned - Boot) >> 2) + 1)], rom[10'((aligned - Boot) >> 2)]};
    else if (aligned < 4096)
      result = {debug_rom[10'((aligned >> 2) + 1)], debug_rom[10'(aligned >> 2)]};
    return result;
  endfunction
  assign awr = !write_owned && !bv && !b_pending && cycles[2:0] != 2 &&
               !(HoldStage == 1 && !hold_finished);
  assign wr = write_owned && !bv && cycles[2:0] != 3 &&
              !(HoldStage == 2 && !hold_finished);
  assign arr = !read_owned && cycles[2:0] != 1;
  assign rv = read_owned && wait_cycles == 0;
  assign rl = read_beat == read_len;
  assign rd = read_data(read_addr + (64'(read_beat) << read_size));

  g6lc_storamic_cpu_debug_netlist #(
    .OriginEnabled(OriginEnabled)
  ) cpu (
    .clk, .rst_n, .debug_req, .awv, .awr, .awa, .awid, .awlen, .awprot, .awsize, .awatop,
    .wv, .wr, .wd, .ws, .wl, .bv, .br, .bid, .bresp(2'b00),
    .arv, .arr, .ara, .arid, .arlen, .arprot, .arsize,
    .rv, .rr, .rd, .rid, .rl, .rresp(2'b00)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycles <= '0;
      done <= 0;
      failed <= 0;
      debug_origin_failed <= 0;
      debug_seen <= 0;
      debug_req <= 0;
      write_checks <= '0;
      read_checks <= '0;
      debug_writes <= '0;
      debug_reads <= '0;
      csr_checks <= '0;
      write_owned <= 0;
      read_owned <= 0;
      completing <= 0;
      bv <= 0;
      bid <= '0;
      rid <= '0;
      write_addr <= '0;
      read_addr <= '0;
      read_len <= '0;
      read_beat <= '0;
      read_size <= '0;
      wait_cycles <= '0;
      hold_started <= 0;
      hold_finished <= 0;
      hold_remaining <= '0;
      b_pending <= 0;
      for (int b = 0; b < 64; b++) memory[b] <= '0;
    end else begin
      cycles <= cycles + 1;
      if (hold_started && !hold_finished) begin
        if (hold_remaining > 1) hold_remaining <= hold_remaining - 1;
        else begin
          hold_remaining <= 0;
          hold_finished <= 1;
        end
      end
      if (!hold_started &&
          ((HoldStage == 1 && awv && write_checks == 0) ||
           (HoldStage == 2 && wv && write_owned) ||
           (HoldStage == 3 && wv && wr && write_addr == Probe + 28))) begin
        hold_started <= 1;
        hold_remaining <= 16'(HoldCycles);
      end
      if (HoldStage == 1 && awv && write_checks == 0 && !hold_started && RequestEnabled) debug_req <= 1;
      if (b_pending && hold_finished && !bv) begin
        b_pending <= 0;
        bv <= 1;
      end
      if (wait_cycles != 0) wait_cycles <= wait_cycles - 1;
      if (bv && br) begin
        bv <= 0;
        if (completing) begin
          if (write_checks == 7 && read_checks == 4 && debug_seen &&
              debug_writes == 4 && debug_reads == 2 && csr_checks == 2 &&
              !failed && !debug_origin_failed && hold_started && hold_finished &&
              memory[0] == 8'h11 && memory[16] == 8'h66 && memory[28] == 8'h66 &&
              memory[32] == 8'h22 && memory[40] == 8'h55) done <= 1;
          else failed <= 1;
          completing <= 0;
        end
      end
      if (awv && awr) begin
        write_owned <= 1;
        write_addr <= awa;
        bid <= awid;
        write_checks <= write_checks + 1;
        if (awa != expected_write(write_checks) || awlen != 0 || awsize != 2 || awatop != 0)
          failed <= 1;
        if (awprot != expected_prot(awa)) begin
          if (is_debug_data(awa)) debug_origin_failed <= 1;
          else failed <= 1;
        end
        if (is_debug_data(awa)) debug_writes <= debug_writes + 1;
        if (write_checks == 0 && RequestEnabled) debug_req <= 1;
      end
      if (wv && wr) begin
        write_owned <= 0;
        if (HoldStage == 3 && write_addr == Probe + 28) b_pending <= 1;
        else bv <= 1;
        if (!wl || !is_probe(write_addr) || write_addr == Probe + 36 ||
            ws != (write_addr == Probe + 28 ? 8'hf0 : 8'h0f)) failed <= 1;
        if (write_addr == Probe + 8) begin
          if ((wd[31:0] & 32'h1c3) == (32'hc0 | 32'(EntryPrivilege))) csr_checks <= csr_checks + 1;
          else failed <= 1;
        end
        if (write_addr == Probe + 24) begin
          if ((EntryPrivilege == 3 && wd[31:0] >= 32'h8000_0000 && wd[31:0] < 32'h8000_0100) ||
              (EntryPrivilege != 3 && wd[31:0] >= 32'h8000_0180 && wd[31:0] < 32'h8000_0200))
            csr_checks <= csr_checks + 1;
          else failed <= 1;
        end
        if (is_probe(write_addr))
          for (int b = 0; b < 8; b++)
            if (ws[b]) memory[6'((write_addr & ~64'h7) - Probe + 64'(b))] <= wd[8*b+:8];
        completing <= write_addr == Probe + 40;
      end
      if (arv && arr) begin
        read_owned <= 1;
        read_addr <= ara;
        rid <= arid;
        read_len <= arlen;
        read_size <= arsize;
        read_beat <= '0;
        wait_cycles <= ResponseDelay;
        if (ara >= 'h800 && ara < 'h1000) begin
          debug_req <= 0;
          debug_seen <= 1;
        end
        if (is_probe(ara)) begin
          read_checks <= read_checks + 1;
          if (ara != expected_read(read_checks) || arlen != 0 || arsize != 2) failed <= 1;
          if (arprot != expected_prot(ara)) begin
            if (is_debug_data(ara)) debug_origin_failed <= 1;
            else failed <= 1;
          end
          if (is_debug_data(ara)) debug_reads <= debug_reads + 1;
        end
      end
      if (rv && rr) begin
        if (rl) read_owned <= 0;
        else begin
          read_beat <= read_beat + 1;
          wait_cycles <= ResponseDelay;
        end
      end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_stalled <= 0;
      w_stalled <= 0;
      stalled_aw <= '0;
      stalled_w <= '0;
    end else begin
      aw_stalled <= awv && !awr;
      w_stalled <= wv && !wr;
      stalled_aw <= {awa, awid, awlen, awprot, awsize, awatop};
      stalled_w <= {wd, ws, wl};
    end
  end
  always @(posedge clk) if (rst_n) begin
    cpu_debug_observer: assert(!failed);
    debug_origin_observer: assert(!debug_origin_failed);
    queued_aw_stability: assert(!aw_stalled ||
        (awv && {awa, awid, awlen, awprot, awsize, awatop} == stalled_aw));
    queued_w_stability: assert(!w_stalled || (wv && {wd, ws, wl} == stalled_w));
  end
endmodule
