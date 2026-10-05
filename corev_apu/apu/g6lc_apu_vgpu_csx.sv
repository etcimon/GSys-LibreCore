// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (1,0) in the color window is the sample red. A first
// byte of the clear red 8'h0D, of blue 8'h1A, or of 8'hFF records
// nothing. A second store keeps the first. This is later than
// g6lc_apu_vgpu_csr. TEX is not the compiler opcode. This is not
// the screenshot.

// ColorWindowCheck (csx): Byte 0 of (1,0) in that window is the sample.
module g6lc_apu_vgpu_csx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_csr_t csr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_csx_cpl_t cpl_o,
  output apu_vgpu_csx_t csx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign csx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|csr_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_csx_cpl_t cpl_q;
    apu_vgpu_csx_t csx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_csx_cpl_t'('0);
    assign csx_o = csx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        csx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (csx_q.valid) begin
            cpl_q.status <= APU_VGPU_CSX_FAULT;
          end else if (!csr_i.valid) begin
            cpl_q.status <= APU_VGPU_CSX_EMPTY;
          end else if (csr_i.base != APU_VGPU_CSW_DST ||
                       csr_i.base == APU_VGPU_ACW_ADDR ||
                       csr_i.off0 != APU_VGPU_ACW_AT0 ||
                       csr_i.off1 != APU_VGPU_ACW_AT1 ||
                       csr_i.x0 != 7'd0 || csr_i.x1 != 7'd1 ||
                       csr_i.origin == APU_VGPU_CLEAR_WORD ||
                       csr_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       csr_i.origin == csr_i.neighbor ||
                       b0_i != csr_i.neighbor[7:0] ||
                       b0_i == APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_CSX_FAULT;
          end else begin
            csx_q.valid <= 1'b1;
            csx_q.b0 <= b0_i;
            csx_q.off0 <= csr_i.off0;
            csx_q.off1 <= csr_i.off1;
            csx_q.x0 <= csr_i.x0;
            csx_q.x1 <= csr_i.x1;
            csx_q.origin <= csr_i.origin;
            csx_q.neighbor <= csr_i.neighbor;
            cpl_q.status <= APU_VGPU_CSX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(csx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CSX_OK |->
        csx_o.valid && csx_o.b0 != APU_VGPU_CLEAR_R &&
        csx_o.b0 != APU_VGPU_CLEAR_A && csx_o.b0 != APU_VGPU_CLEAR_B &&
        csx_o.off1 == APU_VGPU_ACW_AT1 &&
        csx_o.neighbor != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// ColorWindowCheck (csx) enable-0 fixture: Byte 0 of (1,0) in that window is the sample.
module g6lc_apu_vgpu_csx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_csr_t csr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_csx_cpl_t cpl_o,
  output apu_vgpu_csx_t csx_o
);
  g6lc_apu_vgpu_csx #(.Enable(Enable)) i_dut (.*);
endmodule
