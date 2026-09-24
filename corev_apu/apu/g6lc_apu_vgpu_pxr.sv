// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One read of a stored clear-color corner. (0,0), (63,0), (0,63), and
// (63,63) return the word. Another sample inside the ceiling is a miss.
// A sample outside the ceiling records a fault. This does not walk a
// triangle.

module g6lc_apu_vgpu_pxr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_pix_t pix_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pxr_cpl_t cpl_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|pix_i) | (|x_i) | (|y_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_pxr_cpl_t cpl_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_pxr_cpl_t'('0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          apu_vgpu_pxr_status_e st;
          logic [31:0] word;
          logic [13:0] addr;
          st = APU_VGPU_PXR_FAULT;
          word = '0;
          addr = '0;
          if (!pix_i.valid) begin
            st = APU_VGPU_PXR_EMPTY;
          end else if (x_i <= 16'd63 && y_i <= 16'd63) begin
            if (x_i == 16'd0 && y_i == 16'd0) begin
              st = APU_VGPU_PXR_OK;
              word = pix_i.word;
              addr = pix_i.a00;
            end else if (x_i == 16'd63 && y_i == 16'd0) begin
              st = APU_VGPU_PXR_OK;
              word = pix_i.word;
              addr = pix_i.ax;
            end else if (x_i == 16'd0 && y_i == 16'd63) begin
              st = APU_VGPU_PXR_OK;
              word = pix_i.word;
              addr = pix_i.ay;
            end else if (x_i == 16'd63 && y_i == 16'd63) begin
              st = APU_VGPU_PXR_OK;
              word = pix_i.word;
              addr = pix_i.axy;
            end else begin
              st = APU_VGPU_PXR_MISS;
            end
          end
          cpl_q <= '{status: st, word: word, addr: addr};
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
      cpl_valid_o && cpl_o.status == APU_VGPU_PXR_OK |->
        cpl_o.word == APU_VGPU_CLEAR_WORD);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status != APU_VGPU_PXR_OK |-> cpl_o.word == 32'h0);
    `endif
  end
endmodule

module g6lc_apu_vgpu_pxr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_pix_t pix_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pxr_cpl_t cpl_o
);
  g6lc_apu_vgpu_pxr #(.Enable(Enable)) i_dut (.*);
endmodule
