// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the walked scene chain. Avail index 1. The transfer index 2
// and the transfer table record nothing. A second store keeps the
// first. This is later than g6lc_apu_vgpu_snw. This is not
// g6lc_apu_vgpu_snk and not g6lc_apu_vgpu_chn. g6lc_apu_vgpu_avail still rejects NEXT. The
// compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// SceneNextKeep (snk): Guest keep of that walked scene chain.
module g6lc_apu_vgpu_snk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_snw_t snw_i,
  input  apu_vgpu_qgx_t qgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_snk_cpl_t cpl_o,
  output apu_vgpu_snk_t snk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign snk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|snw_i) | (|qgx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_snk_cpl_t cpl_q;
    apu_vgpu_snk_t snk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_snk_cpl_t'('0);
    assign snk_o = snk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        snk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (snk_q.valid) begin
            cpl_q.status <= APU_VGPU_SNK_FAULT;
          end else if (!snw_i.valid || !qgx_i.valid) begin
            cpl_q.status <= APU_VGPU_SNK_EMPTY;
          end else if (snw_i.head != 16'd0 ||
                       snw_i.avail_idx != APU_VGPU_QSU_IDXV ||
                       snw_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       snw_i.device_idx != APU_VGPU_QSU_IDXV ||
                       snw_i.att_addr != APU_VGPU_HDR_ADDR ||
                       snw_i.att_addr == APU_VGPU_RAB_CMD ||
                       snw_i.xfer_addr != APU_VGPU_EXEC_ADDR ||
                       snw_i.rsp_addr != APU_VGPU_RSP_ADDR ||
                       snw_i.avail_idx != qgx_i.used_idx) begin
            cpl_q.status <= APU_VGPU_SNK_FAULT;
          end else begin
            snk_q.valid <= 1'b1;
            snk_q.head <= snw_i.head;
            snk_q.avail_idx <= snw_i.avail_idx;
            snk_q.device_idx <= snw_i.device_idx;
            snk_q.att_addr <= snw_i.att_addr;
            snk_q.xfer_addr <= snw_i.xfer_addr;
            snk_q.rsp_addr <= snw_i.rsp_addr;
            cpl_q.status <= APU_VGPU_SNK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(snk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SNK_OK |->
        snk_o.valid && snk_o.avail_idx == APU_VGPU_QSU_IDXV &&
        snk_o.att_addr != APU_VGPU_RAB_CMD);
    `endif
  end
endmodule

// SceneNextKeep (snk) enable-0 fixture: Guest keep of that walked scene chain.
module g6lc_apu_vgpu_snk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_snw_t snw_i,
  input  apu_vgpu_qgx_t qgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_snk_cpl_t cpl_o,
  output apu_vgpu_snk_t snk_o
);
  g6lc_apu_vgpu_snk #(.Enable(Enable)) i_dut (.*);
endmodule
