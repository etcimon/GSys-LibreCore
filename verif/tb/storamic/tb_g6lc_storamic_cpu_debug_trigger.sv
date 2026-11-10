// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Self-terminating Verilator driver for the tdata-trigger interpreter.
module tb_g6lc_storamic_cpu_debug_trigger #(
  parameter bit OriginEnabled = 1,
  parameter int ResponseDelay = 0,
  parameter bit Negative = 0,
  parameter bit Sdtrig = 1,
  parameter int EntryPrivilege = 3,
  // 3 exec, 4 store, 5 load, 6 deny (SDTRIG=0 profile).
  parameter int Mechanism = 3,
  parameter bit NegativeFirmware = 0
);
  logic clk = 0, rst_n = 0;
  logic done, failed, debug_origin_failed, debug_seen;
  logic [7:0] write_checks, read_checks, debug_writes, debug_reads, csr_checks;
  logic [31:0] cycles;
  logic [31:0] trig_dpc, trig_access_cycle, trig_entry2_cycle;
  logic [7:0] trig_access_count;
  always #5 clk = ~clk;

  g6lc_storamic_cpu_debug_trigger_interpreter #(
    .OriginEnabled(OriginEnabled),
    .ResponseDelay(ResponseDelay),
    .Negative(Negative),
    .Sdtrig(Sdtrig),
    .EntryPrivilege(EntryPrivilege),
    .Mechanism(Mechanism),
    .NegativeFirmware(NegativeFirmware)
  ) interpreter (
    .clk(clk), .rst_n(rst_n),
    .done(done), .failed(failed), .debug_origin_failed(debug_origin_failed),
    .debug_seen(debug_seen),
    .write_checks(write_checks), .read_checks(read_checks),
    .debug_writes(debug_writes), .debug_reads(debug_reads),
    .csr_checks(csr_checks), .cycles(cycles),
    .trig_dpc(trig_dpc), .trig_access_cycle(trig_access_cycle),
    .trig_entry2_cycle(trig_entry2_cycle), .trig_access_count(trig_access_count)
  );

  always @(negedge clk) if (rst_n) begin
    if (cycles > 32'd450000)
      $fatal(1, "CPU_DEBUG_TRIGGER_FAIL origin=%0d delay=%0d priv=%0d mech=%0d reason=timeout cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, Mechanism, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen);
    else if (debug_origin_failed)
      $fatal(1, "CPU_DEBUG_TRIGGER_FAIL origin=%0d delay=%0d priv=%0d mech=%0d reason=debug-origin-failed cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, Mechanism, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen);
    else if (failed)
      $fatal(1, "CPU_DEBUG_TRIGGER_FAIL origin=%0d delay=%0d priv=%0d mech=%0d reason=failed cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d dpc=%h ac=%0d e2=%0d acnt=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, Mechanism, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen, trig_dpc, trig_access_cycle, trig_entry2_cycle,
             trig_access_count);
    else if (done) begin
      $display("CPU_DEBUG_TRIGGER_PASS origin=%0d delay=%0d priv=%0d mech=%0d cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d dpc=%h ac=%0d e2=%0d acnt=%0d",
               OriginEnabled, ResponseDelay, EntryPrivilege, Mechanism, cycles,
               write_checks, read_checks, debug_writes, debug_reads, csr_checks,
               debug_seen, trig_dpc, trig_access_cycle, trig_entry2_cycle,
               trig_access_count);
      $finish;
    end
  end

  initial begin
    repeat (8) @(negedge clk);
    rst_n = 1;
  end
endmodule
