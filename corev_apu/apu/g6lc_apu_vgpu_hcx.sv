// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (0,0) in the guest transfer buffer after that guest
// ack is the sample red. A first byte of the clear red 8'h0D, of
// blue 8'h1A, or of 8'hFF records nothing. The word is not the
// clear color. A second store keeps the first. This is later
// than g6lc_apu_vgpu_hcr. This is not g6lc_apu_vgpu_ocx. The
// compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// GuestTransferTexCheck (hcx): Byte 0 of (0,0) in that guest buffer is sample red.
module g6lc_apu_vgpu_hcx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_hcr_t hcr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_hcx_cpl_t cpl_o,
  output apu_vgpu_hcx_t hcx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign hcx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|hcr_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_hcx_cpl_t cpl_q;
    apu_vgpu_hcx_t hcx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_hcx_cpl_t'('0);
    assign hcx_o = hcx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        hcx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (hcx_q.valid) begin
            cpl_q.status <= APU_VGPU_HCX_FAULT;
          end else if (!hcr_i.valid) begin
            cpl_q.status <= APU_VGPU_HCX_EMPTY;
          end else if (hcr_i.base != APU_VGPU_RPW_DST ||
                       hcr_i.base == APU_VGPU_ACW_ADDR ||
                       hcr_i.off0 != APU_VGPU_ACW_AT0 ||
                       hcr_i.off1 != APU_VGPU_ACW_AT1 ||
                       hcr_i.x0 != 7'd0 || hcr_i.x1 != 7'd1 ||
                       hcr_i.origin == APU_VGPU_CLEAR_WORD ||
                       hcr_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       hcr_i.origin == hcr_i.neighbor ||
                       hcr_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b0_i != hcr_i.origin[7:0] ||
                       b0_i == APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_HCX_FAULT;
          end else begin
            hcx_q.valid <= 1'b1;
            hcx_q.format <= hcr_i.format;
            hcx_q.off0 <= hcr_i.off0;
            hcx_q.off1 <= hcr_i.off1;
            hcx_q.x0 <= hcr_i.x0;
            hcx_q.x1 <= hcr_i.x1;
            hcx_q.b0 <= b0_i;
            hcx_q.origin <= hcr_i.origin;
            hcx_q.neighbor <= hcr_i.neighbor;
            cpl_q.status <= APU_VGPU_HCX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(hcx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_HCX_OK |->
        hcx_o.valid && hcx_o.origin != APU_VGPU_CLEAR_WORD &&
        hcx_o.b0 != APU_VGPU_CLEAR_R);
    `endif
  end
endmodule

// GuestTransferTexCheck (hcx) enable-0 fixture: Byte 0 of (0,0) in that guest buffer is sample red.
module g6lc_apu_vgpu_hcx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_hcr_t hcr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_hcx_cpl_t cpl_o,
  output apu_vgpu_hcx_t hcx_o
);
  g6lc_apu_vgpu_hcx #(.Enable(Enable)) i_dut (.*);
endmodule
