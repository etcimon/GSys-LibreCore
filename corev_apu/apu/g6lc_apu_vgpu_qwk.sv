// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_desc 2: WRITE of the 24-byte response at
// 64'h880A0000. The transfer descriptor and NEXT record nothing.
// A second store keeps the first. This is later than
// g6lc_apu_vgpu_qwd. This is not g6lc_apu_vgpu_txc. The compiler
// TEX opcode still returns -26. This is not Mesa glReadPixels.

// TransferDesc2Keep (qwk): Keep that WRITE descriptor.
module g6lc_apu_vgpu_qwk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qwd_t qwd_i,
  input  apu_vgpu_qfx_t qfx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qwk_cpl_t cpl_o,
  output apu_vgpu_qwk_t qwk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qwk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qwd_i) | (|qfx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qwk_cpl_t cpl_q;
    apu_vgpu_qwk_t qwk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qwk_cpl_t'('0);
    assign qwk_o = qwk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qwk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qwk_q.valid) begin
            cpl_q.status <= APU_VGPU_QWK_FAULT;
          end else if (!qwd_i.valid || !qfx_i.valid) begin
            cpl_q.status <= APU_VGPU_QWK_EMPTY;
          end else if (qwd_i.rsp_addr != APU_VGPU_RFW_ADDR ||
                       qwd_i.rsp_addr == APU_VGPU_TFB_CMD ||
                       qwd_i.rsp_len != APU_VGPU_QWD_LEN ||
                       qwd_i.rsp_len == APU_VGPU_TFB_BYTES ||
                       qfx_i.nxt != 16'd2) begin
            cpl_q.status <= APU_VGPU_QWK_FAULT;
          end else begin
            qwk_q.valid <= 1'b1;
            qwk_q.rsp_addr <= qwd_i.rsp_addr;
            qwk_q.rsp_len <= qwd_i.rsp_len;
            cpl_q.status <= APU_VGPU_QWK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qwk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QWK_OK |->
        qwk_o.valid && qwk_o.rsp_addr == APU_VGPU_RFW_ADDR &&
        qwk_o.rsp_len == APU_VGPU_QWD_LEN);
    `endif
  end
endmodule

// TransferDesc2Keep (qwk) enable-0 fixture: Keep that WRITE descriptor.
module g6lc_apu_vgpu_qwk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qwd_t qwd_i,
  input  apu_vgpu_qfx_t qfx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qwk_cpl_t cpl_o,
  output apu_vgpu_qwk_t qwk_o
);
  g6lc_apu_vgpu_qwk #(.Enable(Enable)) i_dut (.*);
endmodule
