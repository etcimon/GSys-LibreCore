// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Scene descriptor 2 is the WRITE of the 24-byte response at
// 64'h8800A800. The execbuffer descriptor and NEXT record
// nothing. A second store keeps the first. This is later than
// g6lc_apu_vgpu_qrt. This is not g6lc_apu_vgpu_qwx and not
// g6lc_apu_vgpu_avail. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneDesc2Check (qru): WRITE of the 24-byte scene response at 64'h8800A800.
module g6lc_apu_vgpu_qru
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qrt_t qrt_i,
  input  apu_vgpu_qrs_t qrs_i,
  input  apu_vgpu_qex_t qex_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qru_cpl_t cpl_o,
  output apu_vgpu_qru_t qru_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qru_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qrt_i) | (|qrs_i) | (|qex_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qru_cpl_t cpl_q;
    apu_vgpu_qru_t qru_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qru_cpl_t'('0);
    assign qru_o = qru_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qru_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qru_q.valid) begin
            cpl_q.status <= APU_VGPU_QRU_FAULT;
          end else if (!qrt_i.valid || !qrs_i.valid || !qex_i.valid) begin
            cpl_q.status <= APU_VGPU_QRU_EMPTY;
          end else if (qrt_i.rsp_addr != APU_VGPU_RSP_ADDR ||
                       qrt_i.rsp_addr == APU_VGPU_RFW_ADDR ||
                       qrt_i.rsp_len != APU_VGPU_QWD_LEN ||
                       qrt_i.rsp_addr != qrs_i.rsp_addr ||
                       qrt_i.rsp_len != qrs_i.rsp_len ||
                       qex_i.nxt != 16'd2 ||
                       qex_i.nxt == 16'd1) begin
            cpl_q.status <= APU_VGPU_QRU_FAULT;
          end else begin
            qru_q.valid <= 1'b1;
            qru_q.rsp_addr <= qrt_i.rsp_addr;
            cpl_q.status <= APU_VGPU_QRU_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qru_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QRU_OK |->
        qru_o.valid && qru_o.rsp_addr == APU_VGPU_RSP_ADDR);
    `endif
  end
endmodule

// SceneDesc2Check (qru) enable-0 fixture: WRITE of the 24-byte scene response at 64'h8800A800.
module g6lc_apu_vgpu_qru_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qrt_t qrt_i,
  input  apu_vgpu_qrs_t qrs_i,
  input  apu_vgpu_qex_t qex_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qru_cpl_t cpl_o,
  output apu_vgpu_qru_t qru_o
);
  g6lc_apu_vgpu_qru #(.Enable(Enable)) i_dut (.*);
endmodule
