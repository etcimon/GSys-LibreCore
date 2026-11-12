// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// C4 CPU producer pause/drain provider, part 2: the pause sequencer.
//
// Drives the core pause sideband and the AXI gate close line in a strict
// order so that `paused_o` is only ever reported once BOTH the core commit
// path is drained (core_drained_i) AND the CPU's AXI boundary is fully closed
// (gate_closed_i). The order is Halt -> Close -> Paused; release unwinds in
// reverse (Open1 releases the gate, Open2 releases the core) so no new AXI
// request can be accepted before the core is allowed to run again.
//
// Fail-closed: once Paused, if core_drained_i drops or gate_inflight_i rises
// the drain invariant is broken. error_o latches sticky, paused_o is forced
// low and the FSM stays frozen (core_pause_o and gate_close_o held) until
// reset — a violated drain is never silently resumed.
//
//   RUN   : idle; pause_req_i -> HALT
//   HALT  : core_pause_o=1; wait core_drained_i -> CLOSE (withdraw -> RUN)
//   CLOSE : gate_close_o=1;  wait gate_closed_i -> PAUSED (withdraw -> OPEN1)
//   PAUSED: paused_o=1; monitor drained/inflight; !pause_req_i -> OPEN1
//   OPEN1 : gate_close_o=0, core_pause_o=1 -> OPEN2
//   OPEN2 : core_pause_o=0 -> RUN
//
// Formal contract (small formal wrapper): paused_o implies
// core_pause_o && gate_close_o && core_drained_i && gate_closed_i; error_o is
// sticky; no path reaches PAUSED without passing through CLOSE.
//
// Timing impact: outputs are a function of a 3-bit state register plus the
// sticky error flag; the only sequential element is the FSM state and error_q.
// paused_o adds one AND of live monitor inputs so it can never assert while
// the drain invariant is violated. No new clock, async-active-low reset only.
module g6lc_storamic_cpu_pause (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic pause_req_i,
  output logic paused_o,
  output logic error_o,
  output logic core_pause_o,
  input  logic core_drained_i,
  output logic gate_close_o,
  input  logic gate_closed_i,
  input  logic gate_inflight_i
);
  typedef enum logic [2:0] {
    S_RUN, S_HALT, S_CLOSE, S_PAUSED, S_OPEN1, S_OPEN2
  } state_t;

  state_t state_q;
  logic error_q;

  // Live drain-invariant monitor, only meaningful while Paused.
  logic paused_ok;
  assign paused_ok = core_drained_i && gate_closed_i && !gate_inflight_i;

  // paused_o can never assert unless the live drain invariant holds, even if
  // the FSM state were to reach PAUSED through an unexpected path.
  assign paused_o   = (state_q == S_PAUSED) && !error_q && paused_ok;
  assign error_o    = error_q;
  assign core_pause_o = (state_q == S_HALT)  || (state_q == S_CLOSE)  ||
                        (state_q == S_PAUSED) || (state_q == S_OPEN1);
  assign gate_close_o = (state_q == S_CLOSE) || (state_q == S_PAUSED);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_RUN;
      error_q <= 1'b0;
    end else begin
      // Sticky fail-closed error: once the drain invariant breaks in PAUSED it
      // stays broken until reset.
      if (state_q == S_PAUSED && !paused_ok) error_q <= 1'b1;

      unique case (state_q)
        S_RUN: begin
          if (pause_req_i) state_q <= S_HALT;
        end
        S_HALT: begin
          if (!pause_req_i)      state_q <= S_RUN;
          else if (core_drained_i) state_q <= S_CLOSE;
        end
        S_CLOSE: begin
          if (!pause_req_i)      state_q <= S_OPEN1;
          else if (gate_closed_i) state_q <= S_PAUSED;
        end
        S_PAUSED: begin
          // Release is only allowed while the invariant still holds and no
          // error has latched; otherwise stay frozen.
          if (!error_q && !pause_req_i) state_q <= S_OPEN1;
        end
        S_OPEN1: state_q <= S_OPEN2;
        S_OPEN2: state_q <= S_RUN;
        default: state_q <= S_RUN;
      endcase
    end
  end
endmodule
