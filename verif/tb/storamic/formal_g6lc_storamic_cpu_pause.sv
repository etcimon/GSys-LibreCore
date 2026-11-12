// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Bounded formal for g6lc_storamic_cpu_pause (C4 pause sequencer). All bus
// side inputs are free; the checker verifies the pause/drain contract and the
// strict Halt -> Close -> Paused ordering with fail-closed error behaviour.
module formal_g6lc_storamic_cpu_pause (
  clk_i, rst_ni, pause_req_i, paused_o, error_o, core_pause_o,
  core_drained_i, gate_close_o, gate_closed_i, gate_inflight_i
);
  input  logic clk_i, rst_ni, pause_req_i;
  output logic paused_o, error_o, core_pause_o, gate_close_o;
  input  logic core_drained_i, gate_closed_i, gate_inflight_i;

  g6lc_storamic_cpu_pause dut (
    .clk_i, .rst_ni, .pause_req_i, .paused_o, .error_o, .core_pause_o,
    .core_drained_i, .gate_close_o, .gate_closed_i, .gate_inflight_i
  );

  logic past_valid = 1'b0;
  // close_path_q: this pause episode passed through the Close state
  // (core_pause_o && gate_close_o && !paused_o). Cleared on full release.
  logic close_path_q;
  // episode tracking for covers
  logic ep_q, ep_paused_q;

  always @(posedge clk_i) begin
    past_valid <= 1'b1;
    if (!past_valid) assume(!rst_ni);
    if (!rst_ni || !past_valid || !$past(rst_ni)) begin
      close_path_q <= 1'b0;
      ep_q <= 1'b0; ep_paused_q <= 1'b0;
    end else begin
      // ---- Q4 history: record passage through Close; clear on full release --
      if (!core_pause_o && !gate_close_o && !paused_o) begin
        close_path_q <= 1'b0;
        ep_q <= 1'b0; ep_paused_q <= 1'b0;
      end else begin
        if (core_pause_o && gate_close_o && !paused_o)
          close_path_q <= 1'b1;
        ep_q <= 1'b1;
        if (paused_o) ep_paused_q <= 1'b1;
      end
    end

    if (past_valid && rst_ni && $past(rst_ni)) begin
      // Q1: paused_o => core halted && gate closed && live drain invariant
      assert(!(paused_o) ||
             (core_pause_o && gate_close_o && core_drained_i &&
              gate_closed_i && !gate_inflight_i));
      // Q2: error_o sticky until reset and mutually exclusive with paused_o
      assert(!(error_o) || !paused_o);
      if ($past(error_o) && rst_ni) assert(error_o);
      // Q3: never close the gate while the core runs free; core_pause_o may
      //      only fall after gate_close_o has already fallen.
      assert(!(gate_close_o) || core_pause_o);
      if ($past(core_pause_o) && !core_pause_o) assert(!gate_close_o);
      // Q4: PAUSED is reached only via the Close state (Halt -> Close -> Paused)
      if (paused_o && !$past(paused_o)) assert(close_path_q);

      // ================= covers =================
      // full cycle: reached Paused then returned to Run this episode
      cover(ep_paused_q && !core_pause_o && !gate_close_o && !paused_o);
      // withdraw during Halt (core paused, gate not yet closing, not paused)
      cover(ep_q && !ep_paused_q && core_pause_o && !gate_close_o &&
            !paused_o && !pause_req_i);
      // withdraw during Close (gate closing, not yet paused)
      cover(ep_q && !ep_paused_q && core_pause_o && gate_close_o &&
            !paused_o && !pause_req_i);
      // sticky error reached
      cover(error_o);
    end
  end
endmodule
