// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The walked chain, the submit record, and the response name the same
// 960-byte buffer and the same response address. A mismatch links nothing.

module g6lc_apu_vgpu_cmx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_chn_t chn_i,
  input  apu_vgpu_sub_t sub_i,
  input  apu_vgpu_rsp_t rsp_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cmx_cpl_t cpl_o,
  output apu_vgpu_cmx_t cmx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cmx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|chn_i) | (|sub_i) | (|rsp_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_cmx_cpl_t cpl_q;
    apu_vgpu_cmx_t cmx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cmx_cpl_t'('0);
    assign cmx_o = cmx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cmx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic agree;
          agree = chn_i.head == 16'd0 && chn_i.device_idx == 16'd1 &&
                  chn_i.buf_len == APU_VGPU_SCENE_BYTES &&
                  chn_i.buf_addr == APU_VGPU_EXEC_ADDR &&
                  chn_i.rsp_addr == APU_VGPU_RSP_ADDR &&
                  sub_i.ctx_id == APU_VGPU_CTX_ID &&
                  sub_i.size == APU_VGPU_SCENE_BYTES &&
                  sub_i.buf_addr == APU_VGPU_EXEC_ADDR &&
                  sub_i.rsp_addr == APU_VGPU_RSP_ADDR &&
                  rsp_i.addr == APU_VGPU_RSP_ADDR &&
                  rsp_i.ctx_id == APU_VGPU_CTX_ID &&
                  rsp_i.fence == APU_VGPU_SCENE_FENCE;
          if (cmx_q.linked) begin
            cpl_q.status <= APU_VGPU_CMX_FAULT;
          end else if (!chn_i.valid || !sub_i.valid || !rsp_i.valid) begin
            cpl_q.status <= APU_VGPU_CMX_EMPTY;
          end else if (!agree) begin
            cpl_q.status <= APU_VGPU_CMX_FAULT;
          end else begin
            cmx_q.linked <= 1'b1;
            cpl_q.status <= APU_VGPU_CMX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cmx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CMX_OK |-> cmx_o.linked);
    `endif
  end
endmodule

module g6lc_apu_vgpu_cmx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_chn_t chn_i,
  input  apu_vgpu_sub_t sub_i,
  input  apu_vgpu_rsp_t rsp_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cmx_cpl_t cpl_o,
  output apu_vgpu_cmx_t cmx_o
);
  g6lc_apu_vgpu_cmx #(.Enable(Enable)) i_dut (.*);
endmodule
