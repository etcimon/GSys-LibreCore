// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (1,0) in the guest buffer is the sample red. A first
// byte of the clear red 8'h0D, of blue 8'h1A, or of 8'hFF records
// nothing. A second store keeps the first. This is later than
// g6lc_apu_vgpu_rpr. TEX is not the compiler opcode. This is not
// Mesa glReadPixels.

// TransferDestCheck (rpx): Byte 0 of (1,0) in that buffer is the sample.
module g6lc_apu_vgpu_rpx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rpr_t rpr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rpx_cpl_t cpl_o,
  output apu_vgpu_rpx_t rpx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rpx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rpr_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rpx_cpl_t cpl_q;
    apu_vgpu_rpx_t rpx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rpx_cpl_t'('0);
    assign rpx_o = rpx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rpx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rpx_q.valid) begin
            cpl_q.status <= APU_VGPU_RPX_FAULT;
          end else if (!rpr_i.valid) begin
            cpl_q.status <= APU_VGPU_RPX_EMPTY;
          end else if (rpr_i.base != APU_VGPU_RPW_DST ||
                       rpr_i.base == APU_VGPU_CSW_DST ||
                       rpr_i.off0 != APU_VGPU_ACW_AT0 ||
                       rpr_i.off1 != APU_VGPU_ACW_AT1 ||
                       rpr_i.x0 != 7'd0 || rpr_i.x1 != 7'd1 ||
                       rpr_i.origin == APU_VGPU_CLEAR_WORD ||
                       rpr_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       rpr_i.origin == rpr_i.neighbor ||
                       b0_i != rpr_i.neighbor[7:0] ||
                       b0_i == APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_RPX_FAULT;
          end else begin
            rpx_q.valid <= 1'b1;
            rpx_q.b0 <= b0_i;
            rpx_q.off0 <= rpr_i.off0;
            rpx_q.off1 <= rpr_i.off1;
            rpx_q.x0 <= rpr_i.x0;
            rpx_q.x1 <= rpr_i.x1;
            rpx_q.origin <= rpr_i.origin;
            rpx_q.neighbor <= rpr_i.neighbor;
            cpl_q.status <= APU_VGPU_RPX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rpx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RPX_OK |->
        rpx_o.valid && rpx_o.b0 != APU_VGPU_CLEAR_R &&
        rpx_o.b0 != APU_VGPU_CLEAR_A && rpx_o.b0 != APU_VGPU_CLEAR_B &&
        rpx_o.off1 == APU_VGPU_ACW_AT1 &&
        rpx_o.neighbor != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// TransferDestCheck (rpx) enable-0 fixture: Byte 0 of (1,0) in that buffer is the sample.
module g6lc_apu_vgpu_rpx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rpr_t rpr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rpx_cpl_t cpl_o,
  output apu_vgpu_rpx_t rpx_o
);
  g6lc_apu_vgpu_rpx #(.Enable(Enable)) i_dut (.*);
endmodule
