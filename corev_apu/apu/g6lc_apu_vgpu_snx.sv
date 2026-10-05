// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Avail index 1 with NEXT accepted. The transfer index 2 and the
// transfer table at 64'h880D0000 record nothing. A second store
// keeps the first. This is later than g6lc_apu_vgpu_snk. This is
// not g6lc_apu_vgpu_snx and not g6lc_apu_vgpu_avail. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneNextCheck (snx): Avail index 1 with NEXT accepted.
module g6lc_apu_vgpu_snx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_snk_t snk_i,
  input  apu_vgpu_snw_t snw_i,
  input  apu_vgpu_qgx_t qgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_snx_cpl_t cpl_o,
  output apu_vgpu_snx_t snx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign snx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|snk_i) | (|snw_i) | (|qgx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_snx_cpl_t cpl_q;
    apu_vgpu_snx_t snx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_snx_cpl_t'('0);
    assign snx_o = snx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        snx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (snx_q.valid) begin
            cpl_q.status <= APU_VGPU_SNX_FAULT;
          end else if (!snk_i.valid || !snw_i.valid || !qgx_i.valid) begin
            cpl_q.status <= APU_VGPU_SNX_EMPTY;
          end else if (snk_i.avail_idx != APU_VGPU_QSU_IDXV ||
                       snk_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       snk_i.device_idx != APU_VGPU_QSU_IDXV ||
                       snk_i.att_addr != APU_VGPU_HDR_ADDR ||
                       snk_i.att_addr == APU_VGPU_RAB_CMD ||
                       snk_i.att_addr == APU_VGPU_TXC_DESC ||
                       snk_i.avail_idx != snw_i.avail_idx ||
                       qgx_i.used_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_SNX_FAULT;
          end else begin
            snx_q.valid <= 1'b1;
            snx_q.avail_idx <= snk_i.avail_idx;
            snx_q.device_idx <= snk_i.device_idx;
            snx_q.att_addr <= snk_i.att_addr;
            cpl_q.status <= APU_VGPU_SNX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(snx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SNX_OK |->
        snx_o.valid && snx_o.avail_idx == APU_VGPU_QSU_IDXV &&
        snx_o.att_addr != APU_VGPU_RAB_CMD);
    `endif
  end
endmodule

// SceneNextCheck (snx) enable-0 fixture: Avail index 1 with NEXT accepted.
module g6lc_apu_vgpu_snx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_snk_t snk_i,
  input  apu_vgpu_snw_t snw_i,
  input  apu_vgpu_qgx_t qgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_snx_cpl_t cpl_o,
  output apu_vgpu_snx_t snx_o
);
  g6lc_apu_vgpu_snx #(.Enable(Enable)) i_dut (.*);
endmodule
