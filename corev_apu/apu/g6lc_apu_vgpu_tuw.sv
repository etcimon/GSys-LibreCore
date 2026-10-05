// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write the used element of the 64 by 64 TRANSFER_FROM_HOST_3D at
// 64'h880B0000 and used.idx 2 at 64'h880B0008. Descriptor id is 1,
// not the scene's 0. This is later than g6lc_apu_vgpu_rfx. This is
// not g6lc_apu_vgpu_gcw and not g6lc_apu_vgpu_suw. The image is
// not kept. TEX is not the compiler opcode. This is not Mesa
// glReadPixels.

// TransferUsed (tuw): Used element of the 64 by 64 transfer.
module g6lc_apu_vgpu_tuw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rfx_t rfx_i,
  input  apu_vgpu_rfw_t rfw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tuw_cpl_t cpl_o,
  output apu_vgpu_tuw_t tuw_o,
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
  function automatic logic [63:0] step_addr(input logic beat);
    step_addr = beat == 1'b0 ? APU_VGPU_TUW_ELEM : APU_VGPU_TUW_IDX;
  endfunction

  function automatic logic [31:0] step_len(input logic beat);
    step_len = beat == 1'b0 ? 32'd8 : 32'd4;
  endfunction

  function automatic logic [255:0] step_data(input logic beat);
    if (beat == 1'b0)
      step_data = {192'h0, VGPU_RESP_HDR_BYTES, APU_VGPU_TUW_ID};
    else
      step_data = {224'h0, APU_VGPU_TUW_IDXV, 16'd0};
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tuw_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|rfx_i) | (|rfw_i) |
                        (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_tuw_cpl_t cpl_q;
    apu_vgpu_tuw_t tuw_q;
    logic beat_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = step_len(beat_q);
    assign wr_data_o = step_data(beat_q);
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tuw_cpl_t'('0);
    assign tuw_o = tuw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tuw_q <= '0;
        beat_q <= 1'b0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tuw_q.valid) begin
            cpl_q.status <= APU_VGPU_TUW_FAULT;
            state_q <= Done;
          end else if (!rfx_i.valid || !rfw_i.valid) begin
            cpl_q.status <= APU_VGPU_TUW_EMPTY;
            state_q <= Done;
          end else if (rfx_i.fence != APU_VGPU_RFW_FENCE ||
                       rfx_i.fence == APU_VGPU_SCENE_FENCE ||
                       rfx_i.flags != VGPU_FLAG_FENCE ||
                       rfx_i.resp != VGPU_RESP_OK_NODATA ||
                       rfw_i.addr != APU_VGPU_RFW_ADDR ||
                       rfw_i.addr == APU_VGPU_RSP_ADDR) begin
            cpl_q.status <= APU_VGPU_TUW_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_TUW_ELEM;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b1) begin
            state_q <= Commit;
          end else begin
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_TUW_IDX;
            state_q <= Issue;
          end
        end
        Commit: begin
          if (bad_q || beat_q != 1'b1)
            cpl_q.status <= APU_VGPU_TUW_FAULT;
          else begin
            tuw_q.valid <= 1'b1;
            tuw_q.elem_id <= APU_VGPU_TUW_ID;
            tuw_q.elem_len <= VGPU_RESP_HDR_BYTES;
            tuw_q.used_idx <= APU_VGPU_TUW_IDXV;
            tuw_q.elem_addr <= APU_VGPU_TUW_ELEM;
            tuw_q.idx_addr <= APU_VGPU_TUW_IDX;
            cpl_q.status <= APU_VGPU_TUW_OK;
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
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(tuw_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TUW_OK |->
        tuw_o.valid && tuw_o.elem_id == APU_VGPU_TUW_ID &&
        tuw_o.elem_id != 32'd0 && tuw_o.used_idx == APU_VGPU_TUW_IDXV &&
        tuw_o.used_idx != 16'd1 && tuw_o.elem_addr != APU_VGPU_GCW_ELEM);
    `endif
  end
endmodule

// TransferUsed (tuw) enable-0 fixture: Used element of the 64 by 64 transfer.
module g6lc_apu_vgpu_tuw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rfx_t rfx_i,
  input  apu_vgpu_rfw_t rfw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tuw_cpl_t cpl_o,
  output apu_vgpu_tuw_t tuw_o,
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
  g6lc_apu_vgpu_tuw #(.Enable(Enable)) i_dut (.*);
endmodule
