// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// used.idx 2 after the guest OK_NODATA. The scene index 1 and
// descriptor id 0 record nothing. A second store keeps the
// first. This is later than g6lc_apu_vgpu_qul. This is not
// g6lc_apu_vgpu_tux. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TransferUsedWriteCheck (qux): used.idx 2 after the guest WRITE.
module g6lc_apu_vgpu_qux
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qul_t qul_i,
  input  apu_vgpu_quw_t quw_i,
  input  apu_vgpu_qox_t qox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qux_cpl_t cpl_o,
  output apu_vgpu_qux_t qux_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qux_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qul_i) | (|quw_i) | (|qox_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qux_cpl_t cpl_q;
    apu_vgpu_qux_t qux_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qux_cpl_t'('0);
    assign qux_o = qux_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qux_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qux_q.valid) begin
            cpl_q.status <= APU_VGPU_QUX_FAULT;
          end else if (!qul_i.valid || !quw_i.valid || !qox_i.valid) begin
            cpl_q.status <= APU_VGPU_QUX_EMPTY;
          end else if (qul_i.used_idx != APU_VGPU_TUW_IDXV ||
                       qul_i.used_idx == 16'd1 ||
                       qul_i.elem_id != APU_VGPU_TUW_ID ||
                       qul_i.elem_id == 32'd0 ||
                       qul_i.elem_addr == APU_VGPU_GCW_ELEM ||
                       qul_i.used_idx != quw_i.used_idx ||
                       qul_i.elem_id != quw_i.elem_id ||
                       qox_i.fence != APU_VGPU_RFW_FENCE) begin
            cpl_q.status <= APU_VGPU_QUX_FAULT;
          end else begin
            qux_q.valid <= 1'b1;
            qux_q.used_idx <= qul_i.used_idx;
            qux_q.elem_id <= qul_i.elem_id;
            cpl_q.status <= APU_VGPU_QUX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qux_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QUX_OK |->
        qux_o.valid && qux_o.used_idx == APU_VGPU_TUW_IDXV &&
        qux_o.elem_id == APU_VGPU_TUW_ID);
    `endif
  end
endmodule

// TransferUsedWriteCheck (qux) enable-0 fixture: used.idx 2 after the guest WRITE.
module g6lc_apu_vgpu_qux_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qul_t qul_i,
  input  apu_vgpu_quw_t quw_i,
  input  apu_vgpu_qox_t qox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qux_cpl_t cpl_o,
  output apu_vgpu_qux_t qux_o
);
  g6lc_apu_vgpu_qux #(.Enable(Enable)) i_dut (.*);
endmodule
