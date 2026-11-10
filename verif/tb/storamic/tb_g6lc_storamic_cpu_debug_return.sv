// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Self-terminating Verilator driver for the seven-write debug-return
// interpreter (debug-issued B response crossing DRET, HoldStage 3).
module tb_g6lc_storamic_cpu_debug_return #(
  parameter bit OriginEnabled = 1,
  parameter int ResponseDelay = 0,
  parameter bit Negative = 0,
  parameter bit RequestEnabled = 1,
  parameter int EntryPrivilege = 3
);
  logic clk = 0, rst_n = 0;
  logic done, failed, debug_origin_failed, debug_seen;
  logic [7:0] write_checks, read_checks, debug_writes, debug_reads, csr_checks;
  logic [31:0] cycles;
  always #5 clk = ~clk;

  g6lc_storamic_cpu_debug_return_interpreter #(
    .OriginEnabled(OriginEnabled),
    .ResponseDelay(ResponseDelay),
    .Negative(Negative),
    .RequestEnabled(RequestEnabled),
    .EntryPrivilege(EntryPrivilege)
  ) interpreter (
    .clk(clk), .rst_n(rst_n),
    .done(done), .failed(failed), .debug_origin_failed(debug_origin_failed),
    .debug_seen(debug_seen),
    .write_checks(write_checks), .read_checks(read_checks),
    .debug_writes(debug_writes), .debug_reads(debug_reads),
    .csr_checks(csr_checks), .cycles(cycles),
    .hold_started(), .hold_finished()
  );

  always @(negedge clk) if (rst_n) begin
    if (cycles > 32'd200000)
      $fatal(1, "CPU_DEBUG_RETURN_FAIL origin=%0d delay=%0d priv=%0d reason=timeout cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen);
    else if (debug_origin_failed)
      $fatal(1, "CPU_DEBUG_RETURN_FAIL origin=%0d delay=%0d priv=%0d reason=debug-origin-failed cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen);
    else if (failed)
      $fatal(1, "CPU_DEBUG_RETURN_FAIL origin=%0d delay=%0d priv=%0d reason=failed cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
             OriginEnabled, ResponseDelay, EntryPrivilege, cycles,
             write_checks, read_checks, debug_writes, debug_reads, csr_checks,
             debug_seen);
    else if (done) begin
      $display("CPU_DEBUG_RETURN_PASS origin=%0d delay=%0d priv=%0d cycles=%0d writes=%0d reads=%0d dwrites=%0d dreads=%0d csr=%0d seen=%0d",
               OriginEnabled, ResponseDelay, EntryPrivilege, cycles,
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
