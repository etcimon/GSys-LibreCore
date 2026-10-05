// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (0,0) in the scene window is the sample red. A first
// byte of the clear red 8'h0D, of blue 8'h1A, or of 8'hFF records
// nothing. The word is not the clear color. A second store keeps
// the first. This is later than g6lc_apu_vgpu_ocr. This is not
// g6lc_apu_vgpu_acx. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneWindowTexCheck (ocx): (0,0) is the clamp texel, not the clear word.
module g6lc_apu_vgpu_ocx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ocr_t ocr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ocx_cpl_t cpl_o,
  output apu_vgpu_ocx_t ocx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ocx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|ocr_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_ocx_cpl_t cpl_q;
    apu_vgpu_ocx_t ocx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ocx_cpl_t'('0);
    assign ocx_o = ocx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ocx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ocx_q.valid) begin
            cpl_q.status <= APU_VGPU_OCX_FAULT;
          end else if (!ocr_i.valid) begin
            cpl_q.status <= APU_VGPU_OCX_EMPTY;
          end else if (ocr_i.base != APU_VGPU_OCW_ADDR ||
                       ocr_i.base == APU_VGPU_ACW_ADDR ||
                       ocr_i.off0 != APU_VGPU_ACW_AT0 ||
                       ocr_i.off1 != APU_VGPU_ACW_AT1 ||
                       ocr_i.x0 != 7'd0 || ocr_i.x1 != 7'd1 ||
                       ocr_i.origin == APU_VGPU_CLEAR_WORD ||
                       ocr_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       ocr_i.origin == ocr_i.neighbor ||
                       ocr_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b0_i != ocr_i.origin[7:0] ||
                       b0_i == APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_OCX_FAULT;
          end else begin
            ocx_q.valid <= 1'b1;
            ocx_q.format <= ocr_i.format;
            ocx_q.off0 <= ocr_i.off0;
            ocx_q.off1 <= ocr_i.off1;
            ocx_q.x0 <= ocr_i.x0;
            ocx_q.x1 <= ocr_i.x1;
            ocx_q.b0 <= b0_i;
            ocx_q.origin <= ocr_i.origin;
            ocx_q.neighbor <= ocr_i.neighbor;
            cpl_q.status <= APU_VGPU_OCX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(ocx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_OCX_OK |->
        ocx_o.valid && ocx_o.origin != APU_VGPU_CLEAR_WORD &&
        ocx_o.b0 != APU_VGPU_CLEAR_R);
    `endif
  end
endmodule

// SceneWindowTexCheck (ocx) enable-0 fixture: (0,0) is the clamp texel, not the clear word.
module g6lc_apu_vgpu_ocx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ocr_t ocr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ocx_cpl_t cpl_o,
  output apu_vgpu_ocx_t ocx_o
);
  g6lc_apu_vgpu_ocx #(.Enable(Enable)) i_dut (.*);
endmodule
