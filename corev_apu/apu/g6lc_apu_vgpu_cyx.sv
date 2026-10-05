// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of the held TEX sample is red 8'h00. A first byte of
// the clear red 8'h0D or of 8'hFF records nothing. A second
// store keeps the first. This is later than g6lc_apu_vgpu_cyk.
// This is not g6lc_apu_vgpu_byx. The compiler TEX opcode still
// returns -26. This is not Mesa glReadPixels.

// TexSampleChannelsCheck (cyx): Byte 0 of the held TEX sample is red 8'h00.
module g6lc_apu_vgpu_cyx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cyk_t cyk_i,
  input  apu_vgpu_cyr_t cyr_i,
  input  apu_vgpu_wlk_t wlk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cyx_cpl_t cpl_o,
  output apu_vgpu_cyx_t cyx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cyx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|cyk_i) | (|cyr_i) | (|wlk_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_cyx_cpl_t cpl_q;
    apu_vgpu_cyx_t cyx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cyx_cpl_t'('0);
    assign cyx_o = cyx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cyx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cyx_q.valid) begin
            cpl_q.status <= APU_VGPU_CYX_FAULT;
          end else if (!cyk_i.valid || !cyr_i.valid || !wlk_i.valid) begin
            cpl_q.status <= APU_VGPU_CYX_EMPTY;
          end else if (cyk_i.r != 8'h00 ||
                       cyk_i.r == APU_VGPU_CLEAR_R ||
                       cyk_i.a == APU_VGPU_CLEAR_A ||
                       cyk_i.word == APU_VGPU_CLEAR_WORD ||
                       cyk_i.r != cyr_i.r ||
                       cyk_i.word != wlk_i.word) begin
            cpl_q.status <= APU_VGPU_CYX_FAULT;
          end else begin
            cyx_q.valid <= 1'b1;
            cyx_q.b0 <= cyk_i.r;
            cyx_q.a <= cyk_i.a;
            cyx_q.word <= cyk_i.word;
            cpl_q.status <= APU_VGPU_CYX_OK;
          end
          state_q <= Done;
        end
        Done: begin
          if (!armed_q) armed_q <= 1'b1;
          else if (cpl_ready_i) begin
            armed_q <= 1'b0;
            state_q <= Idle;
          end
        end
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(cyx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CYX_OK |->
        cyx_o.valid && cyx_o.b0 == 8'h00 &&
        cyx_o.b0 != APU_VGPU_CLEAR_R);
    `endif
  end
endmodule

// TexSampleChannelsCheck (cyx) enable-0 fixture: Byte 0 of the held TEX sample is red 8'h00.
module g6lc_apu_vgpu_cyx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cyk_t cyk_i,
  input  apu_vgpu_cyr_t cyr_i,
  input  apu_vgpu_wlk_t wlk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cyx_cpl_t cpl_o,
  output apu_vgpu_cyx_t cyx_o
);
  g6lc_apu_vgpu_cyx #(.Enable(Enable)) i_dut (.*);
endmodule
