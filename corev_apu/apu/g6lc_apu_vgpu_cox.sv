// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (0,0) in the sample rectangle is the sample red. The
// word is the clamp texel, not the (1,0) blend. A first byte of
// the clear red 8'h0D, of blue 8'h1A, or of 8'hFF records
// nothing. A second store keeps the first. This is later than
// g6lc_apu_vgpu_cor. TEX is not the compiler opcode. This is not
// Mesa glReadPixels.

// ColorWindowOffsetCheck (cox): Byte 0 of (0,0) is the sample, not the clear.
module g6lc_apu_vgpu_cox
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cor_t cor_i,
  input  apu_vgpu_crd_t crd_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cox_cpl_t cpl_o,
  output apu_vgpu_cox_t cox_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cox_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|cor_i) | (|crd_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_cox_cpl_t cpl_q;
    apu_vgpu_cox_t cox_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cox_cpl_t'('0);
    assign cox_o = cox_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cox_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cox_q.valid) begin
            cpl_q.status <= APU_VGPU_COX_FAULT;
          end else if (!cor_i.valid || !crd_i.valid) begin
            cpl_q.status <= APU_VGPU_COX_EMPTY;
          end else if (cor_i.x != 7'd0 || cor_i.y != 7'd0 ||
                       cor_i.offset != 16'd0 ||
                       cor_i.addr != APU_VGPU_CSW_DST ||
                       cor_i.word == APU_VGPU_CLEAR_WORD ||
                       cor_i.word != crd_i.origin ||
                       cor_i.word == crd_i.neighbor ||
                       crd_i.base != APU_VGPU_CSW_DST ||
                       b0_i != cor_i.word[7:0] ||
                       b0_i == APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_COX_FAULT;
          end else begin
            cox_q.valid <= 1'b1;
            cox_q.b0 <= b0_i;
            cox_q.word <= cor_i.word;
            cox_q.offset <= cor_i.offset;
            cox_q.x <= cor_i.x;
            cox_q.y <= cor_i.y;
            cpl_q.status <= APU_VGPU_COX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cox_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_COX_OK |->
        cox_o.valid && cox_o.b0 != APU_VGPU_CLEAR_R &&
        cox_o.x == 7'd0 && cox_o.offset == 16'd0 &&
        cox_o.word != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// ColorWindowOffsetCheck (cox) enable-0 fixture: Byte 0 of (0,0) is the sample, not the clear.
module g6lc_apu_vgpu_cox_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cor_t cor_i,
  input  apu_vgpu_crd_t crd_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cox_cpl_t cpl_o,
  output apu_vgpu_cox_t cox_o
);
  g6lc_apu_vgpu_cox #(.Enable(Enable)) i_dut (.*);
endmodule
