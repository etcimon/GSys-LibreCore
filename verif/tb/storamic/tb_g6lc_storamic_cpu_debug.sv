// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Self-terminating Verilator driver for the external-debug interpreter.
// The interpreter publishes done/failed/debug_origin_failed through registers;
// sampling on negedge keeps this monitor ahead of the interpreter's posedge
// observers, which would otherwise abort on the same edge that sets a flag.
module tb_g6lc_storamic_cpu_debug #(
  parameter bit OriginEnabled = 1,
  parameter int ResponseDelay = 0,
  parameter bit Negative = 0,
  parameter bit RequestEnabled = 1,
  parameter int EntryPrivilege = 3,
  parameter int Mprv = 0,
  parameter int Mechanism = 0,
  parameter bit NegativeFirmware = 0
);
  logic clk = 0, rst_n = 0;
  logic done, failed, debug_origin_failed, debug_seen;
  logic [7:0] write_checks, read_checks, debug_writes, debug_reads, csr_checks;
  logic [31:0] cycles;
  always #5 clk = ~clk;

  g6lc_storamic_cpu_debug_interpreter #(
    .OriginEnabled(OriginEnabled),
    .ResponseDelay(ResponseDelay),
    .Negative(Negative),
    .RequestEnabled(RequestEnabled),
    .EntryPrivilege(EntryPrivilege),
    .Mprv(Mprv),
    .Mechanism(Mechanism),
    .NegativeFirmware(NegativeFirmware)
  ) interpreter (
    .clk(clk), .rst_n(rst_n),
    .done(done), .failed(failed), .debug_origin_failed(debug_origin_failed),
    .debug_seen(debug_seen),
    .write_checks(write_checks), .read_checks(read_checks),
    .debug_writes(debug_writes), .debug_reads(debug_reads),
    .csr_checks(csr_checks), .cycles(cycles)
  );

  always @(negedge clk) if (rst_n) begin
    if (cycles > 32'd200000)
      $fatal(1, "CPU_DEBUG_FAIL origin=%0d delay=%0d priv=%0d mprv=%0d reason=timeout cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, Mprv, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen);
    else if (debug_origin_failed)
      $fatal(1, "CPU_DEBUG_FAIL origin=%0d delay=%0d priv=%0d mprv=%0d reason=debug-origin-failed cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, Mprv, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen);
    else if (failed)
      $fatal(1, "CPU_DEBUG_FAIL origin=%0d delay=%0d priv=%0d mprv=%0d reason=failed cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, Mprv, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen);
    else if (done) begin
      $display("CPU_DEBUG_PASS origin=%0d delay=%0d priv=%0d mprv=%0d cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
               OriginEnabled, ResponseDelay, EntryPrivilege, Mprv, cycles,
               write_checks, read_checks, debug_writes, debug_reads, csr_checks,
               debug_seen);
      $finish;
    end
  end

  initial begin
    repeat (8) @(negedge clk);
    rst_n = 1;
  end
endmodule
