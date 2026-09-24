// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// After the guest completion is kept, write the used-buffer interrupt
// reason 32'h1 at 64'h8800E500 and raise the pin. Ack lowers the pin
// and leaves the record. A cancel before the beat writes nothing and
// the pin stays low. This is not g6lc_apu_vgpu_sun and not
// g6lc_apu_vgpu_used. The pin is not PLIC source 9. The shader is not run.

module g6lc_apu_vgpu_viw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  apu_vgpu_gck_t gck_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_viw_cpl_t cpl_o,
  output apu_vgpu_viw_t viw_o,
  output logic irq_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign viw_o = '0;
    assign irq_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | irq_ack_i | req_valid_i |
                        cpl_ready_i | wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i |
                        (|gck_i) | (|gpk_i) | (|ols_i) | (|nxc_i) | (|cwr_i) |
                        (|cxr_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Publish, Done } state_e;
    state_e state_q;
    apu_vgpu_viw_cpl_t cpl_q;
    apu_vgpu_viw_t viw_q;
    logic irq_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = APU_VGPU_VIW_ADDR;
    assign wr_len_o = 32'd4;
    assign wr_data_o = {224'h0, APU_VGPU_VIW_REASON};
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_viw_cpl_t'('0);
    assign viw_o = viw_q;
    assign irq_o = irq_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        viw_q <= '0;
        irq_q <= 1'b0;
        armed_q <= 1'b0;
      end else begin
        if (state_q == Publish) irq_q <= 1'b1;
        else if (irq_ack_i) irq_q <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            if (viw_q.valid) begin
              cpl_q.status <= APU_VGPU_VIW_FAULT;
              state_q <= Done;
            end else if (!gck_i.valid || !gpk_i.valid || !ols_i.valid ||
                         !nxc_i.valid || !cwr_i.valid || !cxr_i.valid) begin
              cpl_q.status <= APU_VGPU_VIW_EMPTY;
              state_q <= Done;
            end else if (cancel_i ||
                         gck_i.resp != VGPU_RESP_OK_NODATA ||
                         gck_i.fence != APU_VGPU_SCENE_FENCE ||
                         gck_i.elem_id != 32'd0 ||
                         gck_i.elem_len != VGPU_RESP_HDR_BYTES ||
                         gck_i.used_idx != 16'd1 ||
                         gpk_i.word != APU_VGPU_CLEAR_WORD ||
                         gpk_i.first != APU_VGPU_GPW_ADDR ||
                         gpk_i.last != APU_VGPU_GPW_TAIL ||
                         gpk_i.word != cwr_i.word ||
                         cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                         ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                         ols_i.resp != VGPU_RESP_OK_NODATA ||
                         nxc_i.head != 16'd0 || nxc_i.avail_idx != 16'd1 ||
                         nxc_i.rsp_addr != APU_VGPU_RSP_ADDR) begin
              cpl_q.status <= APU_VGPU_VIW_FAULT;
              state_q <= Done;
            end else state_q <= Issue;
          end
          Issue: if (cancel_i) begin
            cpl_q.status <= APU_VGPU_VIW_FAULT;
            state_q <= Done;
          end else if (wr_ready_i) state_q <= WaitRsp;
          WaitRsp: if (wr_rsp_valid_i) begin
            if (cancel_i || !wr_rsp_ok_i || wr_rsp_addr_i != APU_VGPU_VIW_ADDR ||
                gck_i.used_idx != 16'd1 || gck_i.resp != VGPU_RESP_OK_NODATA ||
                cxr_i.height != 16'd480)
              begin
                cpl_q.status <= APU_VGPU_VIW_FAULT;
                state_q <= Done;
              end else state_q <= Publish;
          end
          Publish: begin
            viw_q.valid <= 1'b1;
            viw_q.reason <= APU_VGPU_VIW_REASON;
            viw_q.used_idx <= gck_i.used_idx;
            cpl_q.status <= APU_VGPU_VIW_OK;
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
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == Issue |-> irq_o == 1'b0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o) && $stable(wr_len_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_VIW_OK |->
        viw_o.valid && viw_o.reason == APU_VGPU_VIW_REASON &&
        viw_o.used_idx == 16'd1);
    `endif
  end
endmodule

module g6lc_apu_vgpu_viw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  apu_vgpu_gck_t gck_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_viw_cpl_t cpl_o,
  output apu_vgpu_viw_t viw_o,
  output logic irq_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_viw #(.Enable(Enable)) i_dut (.*);
endmodule
