// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Supervisor for a quarantined firmware-RAM transaction. reset_o is asserted
// on the clock after fault_i and stays asserted until fault_i is low. There
// is no timeout. This module's own reset must not be reset_o: the fabric
// reset it requests is what clears the RAM fault.

module g6lc_apu_fault_sup #(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic fault_i,
  output logic reset_o
);
  if (!Enable) begin : gen_off
    assign reset_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | fault_i;
  end else begin : gen_on
    typedef enum logic { Idle, Hold } state_e;
    state_e state_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) state_q <= Idle;
      else unique case (state_q)
        Idle: if (fault_i) state_q <= Hold;
        Hold: if (!fault_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end
    assign reset_o = (state_q == Hold);
    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fault_i && !reset_o |=> reset_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      reset_o && fault_i |=> reset_o);
    `endif
  end
endmodule

// Synth wrapper. Enable=0 must stay ports only. Enable=1 is the hold flop.
module g6lc_apu_fault_sup_fixture #(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic fault_i,
  output logic reset_o
);
  g6lc_apu_fault_sup #(.Enable(Enable)) i_dut (.*);
endmodule
