// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Test-only bus environment for interpreting the actual CPU netlist.
module g6lc_storamic_cpu_interpreter #(
  parameter bit OriginEnabled = 1,
  parameter int ResponseDelay = 0,
  parameter bit Negative = 0,
  parameter bit ExtraMprv = 0
) (
  input logic clk, rst_n,
  output logic done, failed,
  output logic [7:0] write_checks, read_checks,
  output logic [31:0] cycles
);
  localparam logic [63:0] Boot = 64'h8000_0000, Probe = 64'h5000_0000;
  localparam int ExpectedWrites = ExtraMprv ? 7 : 5, ExpectedReads = ExtraMprv ? 6 : 4;
  logic awv, awr, wv, wr, wl, bv, br, arv, arr, rv, rr, rl;
  logic [63:0] awa, wd, ara, rd;
  logic [7:0] awid, awlen, ws, bid, arid, arlen, rid;
  logic [2:0] awprot, awsize, arprot, arsize;
  logic [5:0] awatop;
  logic [31:0] rom [1024];
  logic [7:0] memory [64];
  logic write_owned, read_owned, completing;
  logic [63:0] write_addr, read_addr;
  logic [7:0] read_len, read_beat;
  logic [2:0] read_size;
  logic [31:0] wait_cycles;
  initial $readmemh("program.hex", rom);
  function automatic logic is_probe(input logic [63:0] a);
    return a >= Probe && a < Probe + 64;
  endfunction
  function automatic logic [2:0] expected_prot(input logic [63:0] a);
    logic [2:0] result;
    case (a - Probe)
      0: result = 3'b001;
      8, 24: result = 3'b011;
      16, 32: result = 3'b010;
      40: result = ExtraMprv ? 3'b010 : 3'b000;
      48: result = ExtraMprv ? 3'b001 : 3'b000;
      default: result = 3'b000;
    endcase
    if (!OriginEnabled) result = '0;
    if (Negative && a == Probe) result[0] = ~result[0];
    return result;
  endfunction
  function automatic logic [63:0] read_data(input logic [63:0] a);
    logic [63:0] aligned;
    logic [63:0] result;
    aligned = a & ~64'h7;
    result = '0;
    if (is_probe(aligned)) begin
      for (int b = 0; b < 8; b++)
        result[8*b+:8] = memory[6'(aligned - Probe + 64'(b))];
    end else if (aligned >= Boot && aligned < Boot + 4096)
      result = {rom[10'(((aligned - Boot) >> 2) + 1)],
                rom[10'((aligned - Boot) >> 2)]};
    return result;
  endfunction
  assign awr = !write_owned && !bv && cycles[2:0] != 2;
  assign wr = write_owned && !bv && cycles[2:0] != 3;
  assign arr = !read_owned && cycles[2:0] != 1;
  assign rv = read_owned && wait_cycles == 0;
  assign rl = read_beat == read_len;
  assign rd = read_data(read_addr + (64'(read_beat) << read_size));

  // This module is supplied by the frozen RTLIL, with its profile recorded by the runner.
  g6lc_storamic_cpu_netlist cpu (
    .clk, .rst_n, .awv, .awr, .awa, .awid, .awlen, .awprot, .awsize, .awatop,
    .wv, .wr, .wd, .ws, .wl, .bv, .br, .bid, .bresp(2'b00),
    .arv, .arr, .ara, .arid, .arlen, .arprot, .arsize,
    .rv, .rr, .rd, .rid, .rl, .rresp(2'b00)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycles <= '0;
      done <= 0;
      failed <= 0;
      write_checks <= '0;
      read_checks <= '0;
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
      for (int b = 0; b < 64; b++) memory[b] <= '0;
    end else begin
      cycles <= cycles + 1;
      if (wait_cycles != 0) wait_cycles <= wait_cycles - 1;
      if (bv && br) begin
        bv <= 0;
        if (completing) begin
          if (write_checks == ExpectedWrites && read_checks == ExpectedReads &&
              memory[0] == 8'h11 && memory[8] == 8'h22 &&
              memory[16] == 8'h33 && memory[24] == 8'h44 &&
              memory[32] == 8'h55 &&
              (!ExtraMprv || (memory[40] == 8'h66 && memory[48] == 8'h77))) done <= 1;
          else failed <= 1;
          completing <= 0;
        end
      end
      if (awv && awr) begin
        write_owned <= 1;
        write_addr <= awa;
        bid <= awid;
        write_checks <= write_checks + 1;
        if (!is_probe(awa) || awprot != expected_prot(awa) ||
            awlen != 0 || awsize != 2 || awatop != 0) failed <= 1;
      end
      if (wv && wr) begin
        write_owned <= 0;
        bv <= 1;
        if (!wl || !is_probe(write_addr) || write_addr == Probe + 36) failed <= 1;
        if (is_probe(write_addr))
          for (int b = 0; b < 8; b++)
            if (ws[b])
              memory[6'((write_addr & ~64'h7) - Probe + 64'(b))] <= wd[8*b+:8];
        completing <= write_addr == Probe + 32;
      end
      if (arv && arr) begin
        read_owned <= 1;
        read_addr <= ara;
        rid <= arid;
        read_len <= arlen;
        read_size <= arsize;
        read_beat <= '0;
        wait_cycles <= ResponseDelay;
        if (is_probe(ara)) begin
          read_checks <= read_checks + 1;
          if (arprot != expected_prot(ara) || arlen != 0 || arsize != 2) failed <= 1;
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
  always @(posedge clk) if (rst_n) begin
    cpu_origin_observer: assert(!failed);
  end
endmodule
