// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// After the clear-word window is kept, write the 24-byte response at
// 64'h8800A800, the used element at 64'h8800E400, and the used index
// at 64'h8800E480. Three beats. The bytes are not kept. A 64-high
// scissor writes nothing. This is not g6lc_apu_vgpu_rsp, not
// g6lc_apu_vgpu_suw, and not g6lc_apu_vgpu_sux. The shader is not run.
// A failed beat stops the write; the request can be repeated.

module g6lc_apu_vgpu_gcw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gcw_cpl_t cpl_o,
  output apu_vgpu_gcw_t gcw_o,
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
  function automatic logic [63:0] step_addr(input logic [1:0] step);
    case (step)
      2'd0: step_addr = APU_VGPU_RSP_ADDR;
      2'd1: step_addr = APU_VGPU_GCW_ELEM;
      default: step_addr = APU_VGPU_GCW_IDX;
    endcase
  endfunction

  function automatic logic [31:0] step_len(input logic [1:0] step);
    case (step)
      2'd0: step_len = VGPU_RESP_HDR_BYTES;
      2'd1: step_len = 32'd8;
      default: step_len = 32'd4;
    endcase
  endfunction

  function automatic logic [255:0] step_data(input logic [1:0] step);
    case (step)
      2'd0: step_data = {64'h0, 32'h0, APU_VGPU_CTX_ID, APU_VGPU_SCENE_FENCE,
                         VGPU_FLAG_FENCE, VGPU_RESP_OK_NODATA};
      2'd1: step_data = {192'h0, VGPU_RESP_HDR_BYTES, 32'd0};
      default: step_data = {224'h0, 16'd1, 16'd0};
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gcw_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|gpk_i) | (|ols_i) |
                        (|nxc_i) | (|cwr_i) | (|cxr_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_gcw_cpl_t cpl_q;
    apu_vgpu_gcw_t gcw_q;
    logic [1:0] beat_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = step_len(beat_q);
    assign wr_data_o = step_data(beat_q);
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gcw_cpl_t'('0);
    assign gcw_o = gcw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gcw_q <= '0;
        beat_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gcw_q.valid) begin
            cpl_q.status <= APU_VGPU_GCW_FAULT;
            state_q <= Done;
          end else if (!gpk_i.valid || !ols_i.valid || !nxc_i.valid ||
                       !cwr_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_GCW_EMPTY;
            state_q <= Done;
          end else if (gpk_i.word != APU_VGPU_CLEAR_WORD ||
                       gpk_i.first != APU_VGPU_GPW_ADDR ||
                       gpk_i.last != APU_VGPU_GPW_TAIL ||
                       gpk_i.first == gpk_i.last ||
                       cwr_i.word != gpk_i.word ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       ols_i.resp != VGPU_RESP_OK_NODATA ||
                       ols_i.capset_id == APU_VGPU_CAPSET_VIRGL ||
                       nxc_i.head != 16'd0 || nxc_i.avail_idx != 16'd1 ||
                       nxc_i.buf_addr != APU_VGPU_EXEC_ADDR ||
                       nxc_i.buf_len != APU_VGPU_SCENE_BYTES ||
                       nxc_i.rsp_addr != APU_VGPU_RSP_ADDR) begin
            cpl_q.status <= APU_VGPU_GCW_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 2'd0;
            bad_q <= 1'b0;
            addr_q <= step_addr(2'd0);
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == APU_VGPU_GCW_LAST) begin
            state_q <= Commit;
          end else begin
            beat_q <= beat_q + 2'd1;
            addr_q <= step_addr(beat_q + 2'd1);
            state_q <= Issue;
          end
        end
        Commit: begin
          if (bad_q || beat_q != APU_VGPU_GCW_LAST ||
              cwr_i.word != APU_VGPU_CLEAR_WORD ||
              cxr_i.height != 16'd480 ||
              nxc_i.rsp_addr != APU_VGPU_RSP_ADDR)
            cpl_q.status <= APU_VGPU_GCW_FAULT;
          else begin
            gcw_q.valid <= 1'b1;
            gcw_q.resp <= VGPU_RESP_OK_NODATA;
            gcw_q.fence <= APU_VGPU_SCENE_FENCE;
            gcw_q.elem_id <= 32'd0;
            gcw_q.elem_len <= VGPU_RESP_HDR_BYTES;
            gcw_q.used_idx <= 16'd1;
            cpl_q.status <= APU_VGPU_GCW_OK;
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
                     $stable(wr_data_o) && $stable(wr_len_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GCW_OK |->
        gcw_o.valid && gcw_o.resp == VGPU_RESP_OK_NODATA &&
        gcw_o.fence == APU_VGPU_SCENE_FENCE &&
        gcw_o.elem_id == 32'd0 && gcw_o.elem_len == VGPU_RESP_HDR_BYTES &&
        gcw_o.used_idx == 16'd1);
    `endif
  end
endmodule

module g6lc_apu_vgpu_gcw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gcw_cpl_t cpl_o,
  output apu_vgpu_gcw_t gcw_o,
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
  g6lc_apu_vgpu_gcw #(.Enable(Enable)) i_dut (.*);
endmodule
