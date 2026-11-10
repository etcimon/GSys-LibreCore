// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Real-CPU tdata-trigger debug-entry interpreter. Mechanisms:
//   3 exec  — mcontrol6 execute-address on T (Probe+48 store commits)
//   4 store — mcontrol6 store-address on Probe+48 (pre-commit match)
//   5 load  — mcontrol6 load-address on a firmware load of Probe+52
//   6 deny  — SDTRIG=0: csrr tselect -> illegal-instruction, no debug entry
// Oracles: the triggering access appears on AXI at most once with the
// firmware origin; recorded DPC == T+4 iff that access was accepted before
// the second debug entry's first fetch, else T; debugger accesses stay 000.
module g6lc_storamic_cpu_debug_trigger_interpreter #(
  parameter bit OriginEnabled = 1,
  parameter int ResponseDelay = 0,
  parameter bit Negative = 0,
  parameter bit Sdtrig = 1,
  parameter int EntryPrivilege = 3,
  // 3 exec, 4 store, 5 load, 6 deny (SDTRIG=0 profile).
  parameter int Mechanism = 3,
  // When set, the Probe+48 firmware store is expected to carry origin 000,
  // so an origin-enabled run must reject via `failed` (not debug-origin).
  parameter bit NegativeFirmware = 0
) (
  input logic clk, rst_n,
  output logic done, failed, debug_origin_failed, debug_seen,
  output logic [7:0] write_checks, read_checks, debug_writes, debug_reads, csr_checks,
  output logic [31:0] cycles,
  output logic [31:0] trig_dpc, trig_access_cycle, trig_entry2_cycle,
  output logic [7:0] trig_access_count
);
  localparam logic [63:0] Boot = 64'h8000_0000, Probe = 64'h5000_0000;
  localparam logic [31:0] T_PC = 32'h8000_0140, T_PC4 = T_PC + 4;
  localparam logic [63:0] T_VADDR = 64'h5000_0030;   // Probe+48
  localparam logic [63:0] T_LVADDR = 64'h5000_0034;  // Probe+52
  // Generous sim deadline; a hung firmware path must reject `failed`, not
  // time out as incomplete.
  localparam int MaxCycles = 400000;
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
  // Trigger bookkeeping.
  logic trig48_seen, trig48_absent, trig52_seen, trig52_absent;
  logic in_dbg_burst;
  logic [31:0] access_cycle, entry2_cycle;
  logic [7:0] access_count;
  initial begin
    assert (EntryPrivilege inside {0, 3});
    assert (Mechanism inside {3, 4, 5, 6});
    assert (Mechanism == 6 || Sdtrig == 1'b1);
    assert (Mechanism != 6 || EntryPrivilege == 3);
    $readmemh("program.hex", rom);
    $readmemh("debug.hex", debug_rom);
  end
  function automatic logic is_probe(input logic [63:0] a);
    return a >= Probe && a < Probe + 64;
  endfunction
  function automatic logic is_debug_data(input logic [63:0] a);
    return a == Probe + 8 || a == Probe + 16 || a == Probe + 24 ||
           (Mechanism inside {3, 4, 5} && a == Probe + 56);
  endfunction
  function automatic logic is_trig_access(input logic [63:0] a);
    if (Mechanism inside {3, 4}) return a == T_VADDR;
    if (Mechanism == 5) return a == T_LVADDR;
    return 1'b0;
  endfunction
  // Fixed (non-optional) expected write address for a sequence position.
  function automatic logic [63:0] expected_write_fixed(input logic [7:0] index);
    if (Mechanism == 6) begin
      case (index)
        0: return Probe + 44;
        1: return Probe + 8;
        2: return Probe + 32;
        3: return Probe + 40;
        default: return Probe + 36;
      endcase
    end else if (Mechanism == 5) begin
      // Optional Probe+52 load AR is a read; writes never include it.
      case (index)
        0: return Probe;
        1: return Probe + 8;
        2: return Probe + 24;
        3: return Probe + 16;
        4: return Probe + 56;
        5: return Probe + 32;
        6: return Probe + 40;
        default: return Probe + 36;
      endcase
    end else if (Mechanism == 4) begin
      case (index)
        0: return Probe;
        1: return Probe + 8;
        2: return Probe + 24;
        3: return Probe + 16;
        default: return Probe + 36;
      endcase
    end else begin  // Mechanism 3 exec: fixed like ebreak/step.
      case (index)
        0: return Probe;
        1: return Probe + 8;
        2: return Probe + 24;
        3: return Probe + 16;
        4: return Probe + 48;
        5: return Probe + 56;
        6: return Probe + 32;
        7: return Probe + 40;
        default: return Probe + 36;
      endcase
    end
  endfunction
  function automatic logic [2:0] expected_prot(input logic [63:0] a);
    if (Negative && a == Probe + 8) return 3'b001;
    if (NegativeFirmware && a == T_VADDR) return 3'b000;
    if (!OriginEnabled || is_debug_data(a)) return 3'b000;
    case (EntryPrivilege)
      0: return 3'b010;
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
  // Mechanism 4 expected write at a position, honouring the optional @48.
  function automatic logic [63:0] expected_write4(input logic [7:0] index);
    if (index < 4) return expected_write_fixed(index);
    if (trig48_seen) begin
      case (index)
        4: return Probe + 48;
        5: return Probe + 56;
        6: return Probe + 32;
        7: return Probe + 40;
        default: return Probe + 36;
      endcase
    end else begin
      case (index)
        4: return Probe + 56;
        5: return Probe + 32;
        6: return Probe + 40;
        default: return Probe + 36;
      endcase
    end
  endfunction
  // Mechanism 5 expected read at a position, honouring the optional @52 AR.
  function automatic logic [63:0] expected_read5(input logic [7:0] index);
    if (index < 2) begin
      case (index)
        0: return Probe + 8;
        1: return Probe + 16;
        default: return Probe + 36;
      endcase
    end else if (trig52_seen) begin
      case (index)
        2: return Probe + 52;
        3: return Probe;
        4: return Probe + 32;
        default: return Probe + 36;
      endcase
    end else begin
      case (index)
        2: return Probe;
        3: return Probe + 32;
        default: return Probe + 36;
      endcase
    end
  endfunction
  assign awr = !write_owned && !bv && cycles[2:0] != 2;
  assign wr = write_owned && !bv && cycles[2:0] != 3;
  assign arr = !read_owned && cycles[2:0] != 1;
  assign rv = read_owned && wait_cycles == 0;
  assign rl = read_beat == read_len;
  assign rd = read_data(read_addr + (64'(read_beat) << read_size));
  assign trig_dpc = {memory[59], memory[58], memory[57], memory[56]};
  assign trig_access_cycle = access_cycle;
  assign trig_entry2_cycle = entry2_cycle;
  assign trig_access_count = access_count;

  g6lc_storamic_cpu_debug_netlist #(.OriginEnabled(OriginEnabled), .Sdtrig(Sdtrig)) cpu (
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
      trig48_seen <= 0;
      trig48_absent <= 0;
      trig52_seen <= 0;
      trig52_absent <= 0;
      in_dbg_burst <= 0;
      access_cycle <= '0;
      entry2_cycle <= '0;
      access_count <= '0;
      for (int b = 0; b < 64; b++) memory[b] <= '0;
    end else begin
      cycles <= cycles + 1;
      if (wait_cycles != 0) wait_cycles <= wait_cycles - 1;
      // Sim deadline: a hung path must reject `failed`, never pass silently.
      if (cycles == MaxCycles && !done) failed <= 1;
      if (bv && br) begin
        bv <= 0;
        if (completing) begin
          if (Mechanism == 6) begin
            if (write_checks == 4 && read_checks == 0 && !debug_seen &&
                debug_writes == 0 && debug_reads == 0 && csr_checks == 0 &&
                !failed && !debug_origin_failed &&
                memory[44] == 8'h02 && memory[8] == 8'h22 &&
                memory[32] == 8'h55 && memory[40] == 8'h77) done <= 1;
            else failed <= 1;
          end else begin
            // DPC consistency: recorded dpc must be T+4 iff the trigger
            // access was accepted before the second debug entry began.
            begin : dpc_check
              logic access_preceded, dpc_ok, mem48_ok, count_ok;
              access_preceded = (access_cycle != 0) && (entry2_cycle != 0) &&
                                (access_cycle < entry2_cycle);
              dpc_ok = (trig_dpc == (access_preceded ? T_PC4 : T_PC));
              mem48_ok = (Mechanism == 5) ||
                         (trig48_seen ? (memory[48] == 8'h33) : (memory[48] == 8'h00));
              count_ok = (access_count <= 8'd1);
              if (Mechanism == 3) begin
                if (write_checks == 8 && read_checks == 4 && debug_seen &&
                    debug_writes == 4 && debug_reads == 2 && csr_checks == 2 &&
                    !failed && !debug_origin_failed && dpc_ok && mem48_ok && count_ok &&
                    memory[0] == 8'h11 && memory[16] == 8'h66 &&
                    memory[32] == 8'h22 && memory[40] == 8'h55) done <= 1;
                else failed <= 1;
              end else if (Mechanism == 4) begin
                if (write_checks == (trig48_seen ? 8 : 7) && read_checks == 4 && debug_seen &&
                    debug_writes == 4 && debug_reads == 2 && csr_checks == 2 &&
                    !failed && !debug_origin_failed && dpc_ok && mem48_ok && count_ok &&
                    memory[0] == 8'h11 && memory[16] == 8'h66 &&
                    memory[32] == 8'h22 && memory[40] == 8'h55) done <= 1;
                else failed <= 1;
              end else begin  // Mechanism 5 load
                if (write_checks == 7 && read_checks == (trig52_seen ? 5 : 4) && debug_seen &&
                    debug_writes == 4 && debug_reads == 2 && csr_checks == 2 &&
                    !failed && !debug_origin_failed && dpc_ok && mem48_ok && count_ok &&
                    memory[0] == 8'h11 && memory[16] == 8'h66 &&
                    memory[32] == 8'h22 && memory[40] == 8'h55) done <= 1;
                else failed <= 1;
              end
            end
          end
          completing <= 0;
        end
      end
      if (awv && awr) begin
        write_owned <= 1;
        write_addr <= awa;
        bid <= awid;
        write_checks <= write_checks + 1;
        // Mechanism 4 optional Probe+48 slot at sequence index 4.
        if (Mechanism == 4 && write_checks == 4) begin
          if (awa == Probe + 48) trig48_seen <= 1;
          else if (awa == Probe + 56) trig48_absent <= 1;
          else failed <= 1;
        end
        begin : wr_exp
          logic [63:0] exp_w;
          logic exp_ok;
          if (Mechanism == 4) exp_w = expected_write4(write_checks);
          else exp_w = expected_write_fixed(write_checks);
          exp_ok = (awa == exp_w);
          if (Mechanism == 4 && write_checks == 4)
            exp_ok = (awa == Probe + 48 || awa == Probe + 56);
          if (!exp_ok || awlen != 0 || awsize != 2 || awatop != 0) failed <= 1;
        end
        if (awprot != expected_prot(awa)) begin
          if (is_debug_data(awa)) debug_origin_failed <= 1;
          else failed <= 1;
        end
        if (is_debug_data(awa)) debug_writes <= debug_writes + 1;
        if (is_trig_access(awa)) begin
          access_count <= access_count + 1;
          if (access_cycle == 0) access_cycle <= cycles;
        end
        if (write_checks == 0 && Mechanism != 6) debug_req <= 1;
      end
      if (wv && wr) begin
        write_owned <= 0;
        bv <= 1;
        if (!wl || !is_probe(write_addr) || write_addr == Probe + 36 || ws != 8'h0f) failed <= 1;
        if (Mechanism inside {3, 4, 5} && write_addr == Probe + 8) begin
          if ((wd[31:0] & 32'h1c3) == (32'hc0 | 32'(EntryPrivilege)))
            csr_checks <= csr_checks + 1;
          else failed <= 1;
        end
        if ((Mechanism == 3 || Mechanism == 4) && write_addr == Probe + 48 && wd[31:0] != 32'h33)
          failed <= 1;
        if (write_addr == Probe + 24 && Mechanism inside {3, 4, 5}) begin
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
        // Debug-fetch burst tracking: instruction fetches to the debug ROM
        // (0x800-0x1000) form bursts; a firmware (Boot) fetch ends a burst.
        // Probe data reads do not disturb the burst. Any debug fetch is
        // unexpected for the denial profile and sets debug_seen.
        if (ara >= 'h800 && ara < 'h1000) begin
          debug_req <= 0;
          debug_seen <= 1;
          if (Mechanism != 6 && !in_dbg_burst) begin
            in_dbg_burst <= 1;
            if (entry2_cycle == 0 && debug_seen) entry2_cycle <= cycles;
          end
        end else if (ara >= Boot && ara < Boot + 4096) begin
          in_dbg_burst <= 0;
        end
        if (is_probe(ara)) begin
          read_checks <= read_checks + 1;
          // Mechanism 5 optional Probe+52 load AR at read index 2 (0-based):
          // it may be absent when the load is squashed before issuing.
          if (Mechanism == 5 && read_checks == 2) begin
            if (ara == Probe + 52) trig52_seen <= 1;
            else if (ara == Probe) trig52_absent <= 1;
            else failed <= 1;
          end
          begin : rd_exp
            logic exp_ok;
            if (Mechanism == 5 && read_checks == 2)
              exp_ok = (ara == Probe + 52 || ara == Probe);
            else if (Mechanism == 5)
              exp_ok = (ara == expected_read5(read_checks));
            else begin : rd_fixed
              logic [63:0] exp_r;
              case (read_checks)
                0: exp_r = Probe + 8;
                1: exp_r = Probe + 16;
                2: exp_r = Probe;
                3: exp_r = Probe + 32;
                default: exp_r = Probe + 36;
              endcase
              exp_ok = (ara == exp_r);
            end
            if (!exp_ok || arlen != 0 || arsize != 2) failed <= 1;
          end
          if (arprot != expected_prot(ara)) begin
            if (is_debug_data(ara)) debug_origin_failed <= 1;
            else failed <= 1;
          end
          if (is_debug_data(ara)) debug_reads <= debug_reads + 1;
          if (is_trig_access(ara)) begin
            access_count <= access_count + 1;
            if (access_cycle == 0) access_cycle <= cycles;
          end
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
endmodule
