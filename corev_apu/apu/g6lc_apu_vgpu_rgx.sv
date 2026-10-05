// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Ack 32'h1 and remain 0 with used.idx 2 after scene guest ack.
// The scene ack at 64'h8800E510 and index 1 record nothing. A
// second store keeps the first. This is later than
// g6lc_apu_vgpu_rgk. This is not g6lc_apu_vgpu_qay and not
// g6lc_apu_vgpu_tax. TEX is not the compiler opcode. This is
// not Mesa glReadPixels.

// TransferAckAfterAckCheck (rgx): Ack 32'h1 and remain 0 after scene guest ack.
module g6lc_apu_vgpu_rgx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rgk_t rgk_i,
  input  apu_vgpu_rga_t rga_i,
  input  apu_vgpu_rix_t rix_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rgx_cpl_t cpl_o,
  output apu_vgpu_rgx_t rgx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rgx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rgk_i) | (|rga_i) | (|rix_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rgx_cpl_t cpl_q;
    apu_vgpu_rgx_t rgx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rgx_cpl_t'('0);
    assign rgx_o = rgx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rgx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rgx_q.valid) begin
            cpl_q.status <= APU_VGPU_RGX_FAULT;
          end else if (!rgk_i.valid || !rga_i.valid || !rix_i.valid) begin
            cpl_q.status <= APU_VGPU_RGX_EMPTY;
          end else if (rgk_i.ack != APU_VGPU_TIW_REASON ||
                       rgk_i.remain != APU_VGPU_VAW_CLEAR ||
                       rgk_i.used_idx != APU_VGPU_TUW_IDXV ||
                       rgk_i.used_idx == 16'd1 ||
                       rgk_i.ack == rgk_i.remain ||
                       rgk_i.ack_addr != APU_VGPU_TAW_ADDR ||
                       rgk_i.ack_addr == APU_VGPU_VAW_ADDR ||
                       rgk_i.status_addr != APU_VGPU_TIW_ADDR ||
                       rgk_i.ack != rga_i.ack ||
                       rgk_i.remain != rga_i.remain ||
                       rix_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_RGX_FAULT;
          end else begin
            rgx_q.valid <= 1'b1;
            rgx_q.ack <= rgk_i.ack;
            rgx_q.remain <= rgk_i.remain;
            rgx_q.used_idx <= rgk_i.used_idx;
            cpl_q.status <= APU_VGPU_RGX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rgx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RGX_OK |->
        rgx_o.valid && rgx_o.ack == APU_VGPU_TIW_REASON &&
        rgx_o.remain == APU_VGPU_VAW_CLEAR &&
        rgx_o.used_idx == APU_VGPU_TUW_IDXV);
    `endif
  end
endmodule

// TransferAckAfterAckCheck (rgx) enable-0 fixture: Ack 32'h1 and remain 0 after scene guest ack.
module g6lc_apu_vgpu_rgx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rgk_t rgk_i,
  input  apu_vgpu_rga_t rga_i,
  input  apu_vgpu_rix_t rix_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rgx_cpl_t cpl_o,
  output apu_vgpu_rgx_t rgx_o
);
  g6lc_apu_vgpu_rgx #(.Enable(Enable)) i_dut (.*);
endmodule
