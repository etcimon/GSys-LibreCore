// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write the used element at 64'h8800E400 and used.idx 1 at
// 64'h8800E480 after the scene OK_NODATA after QueueNotify.
// Descriptor id is 0, not the transfer's 1. This is later than
// g6lc_apu_vgpu_sox. This is not g6lc_apu_vgpu_quw, not
// g6lc_apu_vgpu_qsu, and not g6lc_apu_vgpu_gcw. The image is not
// kept. The compiler TEX opcode still returns -26. This is not
// Mesa glReadPixels.

// SceneUsedAfterNotify (slw): Scene used element after that OK_NODATA.
module g6lc_apu_vgpu_slw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sox_t sox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_slw_cpl_t cpl_o,
  output apu_vgpu_slw_t slw_o,
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
    step_addr = beat == 1'b0 ? APU_VGPU_QSU_ELEM : APU_VGPU_QSU_IDX;
  endfunction

  function automatic logic [31:0] step_len(input logic beat);
    step_len = beat == 1'b0 ? 32'd8 : 32'd4;
  endfunction

  function automatic logic [255:0] step_data(input logic beat);
    if (beat == 1'b0)
      step_data = {192'h0, VGPU_RESP_HDR_BYTES, APU_VGPU_QSU_ID};
    else
      step_data = {224'h0, APU_VGPU_QSU_IDXV, 16'd0};
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign slw_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|sox_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_slw_cpl_t cpl_q;
    apu_vgpu_slw_t slw_q;
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
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_slw_cpl_t'('0);
    assign slw_o = slw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        slw_q <= '0;
        beat_q <= 1'b0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (slw_q.valid) begin
            cpl_q.status <= APU_VGPU_SLW_FAULT;
            state_q <= Done;
          end else if (!sox_i.valid) begin
            cpl_q.status <= APU_VGPU_SLW_EMPTY;
            state_q <= Done;
          end else if (sox_i.fence != APU_VGPU_SCENE_FENCE ||
                       sox_i.fence == APU_VGPU_RFW_FENCE ||
                       sox_i.resp != VGPU_RESP_OK_NODATA) begin
            cpl_q.status <= APU_VGPU_SLW_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_QSU_ELEM;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q ||
              wr_rsp_addr_i == APU_VGPU_TUW_ELEM) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b1) begin
            state_q <= Commit;
          end else begin
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_QSU_IDX;
            state_q <= Issue;
          end
        end
        Commit: begin
          if (bad_q || beat_q != 1'b1)
            cpl_q.status <= APU_VGPU_SLW_FAULT;
          else begin
            slw_q.valid <= 1'b1;
            slw_q.elem_id <= APU_VGPU_QSU_ID;
            slw_q.elem_len <= VGPU_RESP_HDR_BYTES;
            slw_q.used_idx <= APU_VGPU_QSU_IDXV;
            slw_q.elem_addr <= APU_VGPU_QSU_ELEM;
            slw_q.idx_addr <= APU_VGPU_QSU_IDX;
            cpl_q.status <= APU_VGPU_SLW_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(slw_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SLW_OK |->
        slw_o.valid && slw_o.elem_id == APU_VGPU_QSU_ID &&
        slw_o.used_idx == APU_VGPU_QSU_IDXV &&
        slw_o.elem_addr != APU_VGPU_TUW_ELEM);
    `endif
  end
endmodule

// SceneUsedAfterNotify (slw) enable-0 fixture: Scene used element after that OK_NODATA.
module g6lc_apu_vgpu_slw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sox_t sox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_slw_cpl_t cpl_o,
  output apu_vgpu_slw_t slw_o,
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
  g6lc_apu_vgpu_slw #(.Enable(Enable)) i_dut (.*);
endmodule
