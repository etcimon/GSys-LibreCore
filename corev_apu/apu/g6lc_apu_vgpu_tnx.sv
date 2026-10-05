// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Avail index 2 with NEXT accepted. The scene index 1 and the scene
// table at 64'h8800E100 record nothing. A second store keeps the
// first. This is later than g6lc_apu_vgpu_tnk. This is not
// g6lc_apu_vgpu_avail. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TransferNextCheck (tnx): Avail index 2, NEXT accepted.
module g6lc_apu_vgpu_tnx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tnk_t tnk_i,
  input  apu_vgpu_tnw_t tnw_i,
  input  apu_vgpu_txx_t txx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tnx_cpl_t cpl_o,
  output apu_vgpu_tnx_t tnx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tnx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tnk_i) | (|tnw_i) | (|txx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tnx_cpl_t cpl_q;
    apu_vgpu_tnx_t tnx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tnx_cpl_t'('0);
    assign tnx_o = tnx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tnx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tnx_q.valid) begin
            cpl_q.status <= APU_VGPU_TNX_FAULT;
          end else if (!tnk_i.valid || !tnw_i.valid || !txx_i.valid) begin
            cpl_q.status <= APU_VGPU_TNX_EMPTY;
          end else if (tnk_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       tnk_i.avail_idx == 16'd1 ||
                       tnk_i.device_idx != APU_VGPU_TUW_IDXV ||
                       tnk_i.att_addr != APU_VGPU_RAB_CMD ||
                       tnk_i.att_addr == APU_VGPU_NXC_DESC ||
                       tnk_i.att_addr == APU_VGPU_HDR_ADDR ||
                       tnk_i.avail_idx != tnw_i.avail_idx ||
                       txx_i.avail_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_TNX_FAULT;
          end else begin
            tnx_q.valid <= 1'b1;
            tnx_q.avail_idx <= tnk_i.avail_idx;
            tnx_q.device_idx <= tnk_i.device_idx;
            tnx_q.att_addr <= tnk_i.att_addr;
            cpl_q.status <= APU_VGPU_TNX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tnx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TNX_OK |->
        tnx_o.valid && tnx_o.avail_idx == APU_VGPU_TUW_IDXV &&
        tnx_o.att_addr != APU_VGPU_NXC_DESC);
    `endif
  end
endmodule

// TransferNextCheck (tnx) enable-0 fixture: Avail index 2, NEXT accepted.
module g6lc_apu_vgpu_tnx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tnk_t tnk_i,
  input  apu_vgpu_tnw_t tnw_i,
  input  apu_vgpu_txx_t txx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tnx_cpl_t cpl_o,
  output apu_vgpu_tnx_t tnx_o
);
  g6lc_apu_vgpu_tnx #(.Enable(Enable)) i_dut (.*);
endmodule
