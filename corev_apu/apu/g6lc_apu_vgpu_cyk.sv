// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the four channels of that TEX sample. A second store
// keeps the first. The clear channels record nothing. This is
// later than g6lc_apu_vgpu_cyr. This is not g6lc_apu_vgpu_byk.
// The compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// TexSampleChannelsKeep (cyk): Guest keep of those TEX channels.
module g6lc_apu_vgpu_cyk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cyr_t cyr_i,
  input  apu_vgpu_wlk_t wlk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cyk_cpl_t cpl_o,
  output apu_vgpu_cyk_t cyk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cyk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|cyr_i) | (|wlk_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_cyk_cpl_t cpl_q;
    apu_vgpu_cyk_t cyk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cyk_cpl_t'('0);
    assign cyk_o = cyk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cyk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cyk_q.valid) begin
            cpl_q.status <= APU_VGPU_CYK_FAULT;
          end else if (!cyr_i.valid || !wlk_i.valid) begin
            cpl_q.status <= APU_VGPU_CYK_EMPTY;
          end else if (cyr_i.r == APU_VGPU_CLEAR_R ||
                       cyr_i.a == APU_VGPU_CLEAR_A ||
                       cyr_i.word == APU_VGPU_CLEAR_WORD ||
                       cyr_i.word != wlk_i.word ||
                       {cyr_i.a, cyr_i.b, cyr_i.g, cyr_i.r} != cyr_i.word) begin
            cpl_q.status <= APU_VGPU_CYK_FAULT;
          end else begin
            cyk_q.valid <= 1'b1;
            cyk_q.r <= cyr_i.r;
            cyk_q.g <= cyr_i.g;
            cyk_q.b <= cyr_i.b;
            cyk_q.a <= cyr_i.a;
            cyk_q.word <= cyr_i.word;
            cyk_q.addr <= cyr_i.addr;
            cpl_q.status <= APU_VGPU_CYK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cyk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CYK_OK |->
        cyk_o.valid && cyk_o.r != APU_VGPU_CLEAR_R &&
        cyk_o.word != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// TexSampleChannelsKeep (cyk) enable-0 fixture: Guest keep of those TEX channels.
module g6lc_apu_vgpu_cyk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cyr_t cyr_i,
  input  apu_vgpu_wlk_t wlk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cyk_cpl_t cpl_o,
  output apu_vgpu_cyk_t cyk_o
);
  g6lc_apu_vgpu_cyk #(.Enable(Enable)) i_dut (.*);
endmodule
