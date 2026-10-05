// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte offset of one point in the 64 by 64 sample rectangle at
// 64'h88060000. offset is y * 256 + x * 4. x or y of 64 records
// nothing. This is later than g6lc_apu_vgpu_crx. The image is not
// kept. TEX is not the compiler opcode. This is not Mesa
// glReadPixels.

// ColorWindowOffset (cof): Byte offset in the sample rectangle.
module g6lc_apu_vgpu_cof
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_crd_t crd_i,
  input  apu_vgpu_crx_t crx_i,
  input  logic [6:0] x_i,
  input  logic [6:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cof_cpl_t cpl_o,
  output apu_vgpu_cof_t cof_o
);
  function automatic logic [15:0] pix_off(input logic [6:0] x, input logic [6:0] y);
    pix_off = {2'b0, y[5:0], 8'h00} + {8'h00, x[5:0], 2'b00};
  endfunction

  function automatic logic [63:0] pix_addr(input logic [15:0] off);
    pix_addr = APU_VGPU_CSW_DST + (64'(off[13:5]) << 5);
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cof_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|crd_i) | (|crx_i) | (|x_i) | (|y_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_cof_cpl_t cpl_q;
    apu_vgpu_cof_t cof_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cof_cpl_t'('0);
    assign cof_o = cof_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cof_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cof_q.valid) begin
            cpl_q.status <= APU_VGPU_COF_FAULT;
          end else if (!crd_i.valid || !crx_i.valid) begin
            cpl_q.status <= APU_VGPU_COF_EMPTY;
          end else if (crd_i.base != APU_VGPU_CSW_DST ||
                       crd_i.base == APU_VGPU_GBW_ADDR ||
                       crd_i.width != APU_VGPU_GBD_W ||
                       crd_i.height != APU_VGPU_GBD_H ||
                       crd_i.stride != APU_VGPU_GBD_STRIDE ||
                       crd_i.bytes != APU_VGPU_GBD_BYTES ||
                       crd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       crd_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       crx_i.word != crd_i.neighbor ||
                       crx_i.x != 7'd1 || crx_i.y != 7'd0 ||
                       x_i > 7'd63 || y_i > 7'd63) begin
            cpl_q.status <= APU_VGPU_COF_FAULT;
          end else begin
            cof_q.valid <= 1'b1;
            cof_q.offset <= pix_off(x_i, y_i);
            cof_q.addr <= pix_addr(pix_off(x_i, y_i));
            cof_q.x <= x_i;
            cof_q.y <= y_i;
            cpl_q.status <= APU_VGPU_COF_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cof_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_COF_OK |->
        cof_o.valid && cof_o.addr[63:14] == APU_VGPU_CSW_DST[63:14] &&
        cof_o.addr != APU_VGPU_GBW_ADDR);
    `endif
  end
endmodule

// ColorWindowOffset (cof) enable-0 fixture: Byte offset in the sample rectangle.
module g6lc_apu_vgpu_cof_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_crd_t crd_i,
  input  apu_vgpu_crx_t crx_i,
  input  logic [6:0] x_i,
  input  logic [6:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cof_cpl_t cpl_o,
  output apu_vgpu_cof_t cof_o
);
  g6lc_apu_vgpu_cof #(.Enable(Enable)) i_dut (.*);
endmodule
