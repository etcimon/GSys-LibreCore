// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_desc 0: attach at 64'h88090000, length 64, NEXT to
// 1. The scene table and a jump record nothing. A second store
// keeps the first. This is later than g6lc_apu_vgpu_qhd. This is
// not g6lc_apu_vgpu_txc. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// TransferDesc0Keep (qhk): Keep that descriptor.
module g6lc_apu_vgpu_qhk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qhd_t qhd_i,
  input  apu_vgpu_qrx_t qrx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qhk_cpl_t cpl_o,
  output apu_vgpu_qhk_t qhk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qhk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qhd_i) | (|qrx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qhk_cpl_t cpl_q;
    apu_vgpu_qhk_t qhk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qhk_cpl_t'('0);
    assign qhk_o = qhk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qhk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qhk_q.valid) begin
            cpl_q.status <= APU_VGPU_QHK_FAULT;
          end else if (!qhd_i.valid || !qrx_i.valid) begin
            cpl_q.status <= APU_VGPU_QHK_EMPTY;
          end else if (qhd_i.att_addr != APU_VGPU_RAB_CMD ||
                       qhd_i.att_addr == APU_VGPU_NXC_DESC ||
                       qhd_i.att_len != APU_VGPU_RAB_BYTES ||
                       qhd_i.att_len == APU_VGPU_TFB_BYTES ||
                       qhd_i.nxt != 16'd1 ||
                       qhd_i.nxt == 16'd2 ||
                       qrx_i.desc_id != APU_VGPU_QRG_DESC) begin
            cpl_q.status <= APU_VGPU_QHK_FAULT;
          end else begin
            qhk_q.valid <= 1'b1;
            qhk_q.att_addr <= qhd_i.att_addr;
            qhk_q.att_len <= qhd_i.att_len;
            qhk_q.nxt <= qhd_i.nxt;
            cpl_q.status <= APU_VGPU_QHK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qhk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QHK_OK |->
        qhk_o.valid && qhk_o.att_addr == APU_VGPU_RAB_CMD &&
        qhk_o.nxt == 16'd1);
    `endif
  end
endmodule

// TransferDesc0Keep (qhk) enable-0 fixture: Keep that descriptor.
module g6lc_apu_vgpu_qhk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qhd_t qhd_i,
  input  apu_vgpu_qrx_t qrx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qhk_cpl_t cpl_o,
  output apu_vgpu_qhk_t qhk_o
);
  g6lc_apu_vgpu_qhk #(.Enable(Enable)) i_dut (.*);
endmodule
