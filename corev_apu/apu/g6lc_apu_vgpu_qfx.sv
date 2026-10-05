// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Descriptor 1 is the transfer at 64'h88080000 with NEXT to 2.
// The attach descriptor and a jump record nothing. A second
// store keeps the first. This is later than g6lc_apu_vgpu_qfk.
// This is not g6lc_apu_vgpu_avail. The compiler TEX opcode still
// returns -26. This is not Mesa glReadPixels.

// TransferDesc1Check (qfx): Descriptor 1 is the transfer, NEXT to 2.
module g6lc_apu_vgpu_qfx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qfk_t qfk_i,
  input  apu_vgpu_qfd_t qfd_i,
  input  apu_vgpu_qhx_t qhx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qfx_cpl_t cpl_o,
  output apu_vgpu_qfx_t qfx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qfx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qfk_i) | (|qfd_i) | (|qhx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qfx_cpl_t cpl_q;
    apu_vgpu_qfx_t qfx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qfx_cpl_t'('0);
    assign qfx_o = qfx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qfx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qfx_q.valid) begin
            cpl_q.status <= APU_VGPU_QFX_FAULT;
          end else if (!qfk_i.valid || !qfd_i.valid || !qhx_i.valid) begin
            cpl_q.status <= APU_VGPU_QFX_EMPTY;
          end else if (qfk_i.xfer_addr != APU_VGPU_TFB_CMD ||
                       qfk_i.xfer_addr == APU_VGPU_RAB_CMD ||
                       qfk_i.xfer_len != APU_VGPU_TFB_BYTES ||
                       qfk_i.nxt != 16'd2 ||
                       qfk_i.nxt == 16'd1 ||
                       qfk_i.xfer_addr != qfd_i.xfer_addr ||
                       qfk_i.nxt != qfd_i.nxt ||
                       qhx_i.nxt != 16'd1 ||
                       qhx_i.nxt == 16'd2) begin
            cpl_q.status <= APU_VGPU_QFX_FAULT;
          end else begin
            qfx_q.valid <= 1'b1;
            qfx_q.xfer_addr <= qfk_i.xfer_addr;
            qfx_q.nxt <= qfk_i.nxt;
            cpl_q.status <= APU_VGPU_QFX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qfx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QFX_OK |->
        qfx_o.valid && qfx_o.xfer_addr == APU_VGPU_TFB_CMD &&
        qfx_o.nxt == 16'd2);
    `endif
  end
endmodule

// TransferDesc1Check (qfx) enable-0 fixture: Descriptor 1 is the transfer, NEXT to 2.
module g6lc_apu_vgpu_qfx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qfk_t qfk_i,
  input  apu_vgpu_qfd_t qfd_i,
  input  apu_vgpu_qhx_t qhx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qfx_cpl_t cpl_o,
  output apu_vgpu_qfx_t qfx_o
);
  g6lc_apu_vgpu_qfx #(.Enable(Enable)) i_dut (.*);
endmodule
