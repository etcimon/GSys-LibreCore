// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Descriptor 0 is the attach at 64'h88090000 with NEXT to 1.
// The scene table and a jump record nothing. A second store
// keeps the first. This is later than g6lc_apu_vgpu_qhk. This is
// not g6lc_apu_vgpu_avail. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// TransferDesc0Check (qhx): Descriptor 0 is the attach, NEXT to 1.
module g6lc_apu_vgpu_qhx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qhk_t qhk_i,
  input  apu_vgpu_qhd_t qhd_i,
  input  apu_vgpu_qrx_t qrx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qhx_cpl_t cpl_o,
  output apu_vgpu_qhx_t qhx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qhx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qhk_i) | (|qhd_i) | (|qrx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qhx_cpl_t cpl_q;
    apu_vgpu_qhx_t qhx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qhx_cpl_t'('0);
    assign qhx_o = qhx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qhx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qhx_q.valid) begin
            cpl_q.status <= APU_VGPU_QHX_FAULT;
          end else if (!qhk_i.valid || !qhd_i.valid || !qrx_i.valid) begin
            cpl_q.status <= APU_VGPU_QHX_EMPTY;
          end else if (qhk_i.att_addr != APU_VGPU_RAB_CMD ||
                       qhk_i.att_addr == APU_VGPU_NXC_DESC ||
                       qhk_i.att_len != APU_VGPU_RAB_BYTES ||
                       qhk_i.nxt != 16'd1 ||
                       qhk_i.nxt == 16'd2 ||
                       qhk_i.att_addr != qhd_i.att_addr ||
                       qhk_i.nxt != qhd_i.nxt ||
                       qrx_i.desc_id != APU_VGPU_QRG_DESC ||
                       qrx_i.desc_id == 16'd1) begin
            cpl_q.status <= APU_VGPU_QHX_FAULT;
          end else begin
            qhx_q.valid <= 1'b1;
            qhx_q.att_addr <= qhk_i.att_addr;
            qhx_q.nxt <= qhk_i.nxt;
            cpl_q.status <= APU_VGPU_QHX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qhx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QHX_OK |->
        qhx_o.valid && qhx_o.att_addr == APU_VGPU_RAB_CMD &&
        qhx_o.nxt == 16'd1);
    `endif
  end
endmodule

// TransferDesc0Check (qhx) enable-0 fixture: Descriptor 0 is the attach, NEXT to 1.
module g6lc_apu_vgpu_qhx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qhk_t qhk_i,
  input  apu_vgpu_qhd_t qhd_i,
  input  apu_vgpu_qrx_t qrx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qhx_cpl_t cpl_o,
  output apu_vgpu_qhx_t qhx_o
);
  g6lc_apu_vgpu_qhx #(.Enable(Enable)) i_dut (.*);
endmodule
