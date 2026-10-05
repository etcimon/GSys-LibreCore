// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the response, the used element, and the used index written for
// the kept clear-word window. Upper bytes of each beat are not part of
// the check. The 24 bytes are not kept. This is not g6lc_apu_vgpu_rsp.
// The shader is not run.

// SceneCompleteRead (gcr): Those three beats read back.
module g6lc_apu_vgpu_gcr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gcw_t gcw_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gcr_cpl_t cpl_o,
  output apu_vgpu_gcr_t gcr_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
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

  function automatic logic step_bad(input logic [1:0] step, input logic [255:0] data);
    case (step)
      2'd0: step_bad = data[191:0] != {32'h0, APU_VGPU_CTX_ID, APU_VGPU_SCENE_FENCE,
                                       VGPU_FLAG_FENCE, VGPU_RESP_OK_NODATA};
      2'd1: step_bad = data[63:0] != {VGPU_RESP_HDR_BYTES, 32'd0};
      default: step_bad = data[31:0] != {16'd1, 16'd0};
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gcr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gcw_i) | (|gpk_i) |
                        (|ols_i) | (|nxc_i) | (|cwr_i) | (|cxr_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_gcr_cpl_t cpl_q;
    apu_vgpu_gcr_t gcr_q;
    logic [1:0] beat_q;
    logic [31:0] resp_q, elem_id_q, elem_len_q;
    logic [63:0] fence_q, addr_q;
    logic [15:0] used_idx_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = step_len(beat_q);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gcr_cpl_t'('0);
    assign gcr_o = gcr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gcr_q <= '0;
        beat_q <= '0;
        resp_q <= '0;
        fence_q <= '0;
        elem_id_q <= '0;
        elem_len_q <= '0;
        used_idx_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gcr_q.valid) begin
            cpl_q.status <= APU_VGPU_GCR_FAULT;
            state_q <= Done;
          end else if (!gcw_i.valid || !gpk_i.valid || !ols_i.valid ||
                       !nxc_i.valid || !cwr_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_GCR_EMPTY;
            state_q <= Done;
          end else if (gcw_i.resp != VGPU_RESP_OK_NODATA ||
                       gcw_i.fence != APU_VGPU_SCENE_FENCE ||
                       gcw_i.elem_id != 32'd0 ||
                       gcw_i.elem_len != VGPU_RESP_HDR_BYTES ||
                       gcw_i.used_idx != 16'd1 ||
                       gpk_i.word != APU_VGPU_CLEAR_WORD ||
                       gpk_i.first != APU_VGPU_GPW_ADDR ||
                       gpk_i.last != APU_VGPU_GPW_TAIL ||
                       cwr_i.word != gpk_i.word ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       nxc_i.head != 16'd0 || nxc_i.rsp_addr != APU_VGPU_RSP_ADDR) begin
            cpl_q.status <= APU_VGPU_GCR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 2'd0;
            resp_q <= '0;
            fence_q <= '0;
            elem_id_q <= '0;
            elem_len_q <= '0;
            used_idx_q <= '0;
            bad_q <= 1'b0;
            addr_q <= step_addr(2'd0);
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != step_len(beat_q);
          if (bad_bus || step_bad(beat_q, rd_rsp_data_i)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 2'd0) begin
            resp_q <= rd_rsp_data_i[31:0];
            fence_q <= rd_rsp_data_i[127:64];
            beat_q <= 2'd1;
            addr_q <= step_addr(2'd1);
            state_q <= Issue;
          end else if (beat_q == 2'd1) begin
            elem_id_q <= rd_rsp_data_i[31:0];
            elem_len_q <= rd_rsp_data_i[63:32];
            beat_q <= 2'd2;
            addr_q <= step_addr(2'd2);
            state_q <= Issue;
          end else begin
            used_idx_q <= rd_rsp_data_i[31:16];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || beat_q != APU_VGPU_GCW_LAST ||
              resp_q != VGPU_RESP_OK_NODATA ||
              fence_q != APU_VGPU_SCENE_FENCE ||
              elem_id_q != 32'd0 || elem_len_q != VGPU_RESP_HDR_BYTES ||
              used_idx_q != 16'd1 || used_idx_q != gcw_i.used_idx)
            cpl_q.status <= APU_VGPU_GCR_FAULT;
          else begin
            gcr_q.valid <= 1'b1;
            gcr_q.resp <= resp_q;
            gcr_q.fence <= fence_q;
            gcr_q.elem_id <= elem_id_q;
            gcr_q.elem_len <= elem_len_q;
            gcr_q.used_idx <= used_idx_q;
            cpl_q.status <= APU_VGPU_GCR_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_GCR_OK |->
        gcr_o.valid && gcr_o.resp == VGPU_RESP_OK_NODATA &&
        gcr_o.fence == APU_VGPU_SCENE_FENCE &&
        gcr_o.elem_id == 32'd0 && gcr_o.elem_len == VGPU_RESP_HDR_BYTES &&
        gcr_o.used_idx == 16'd1);
    `endif
  end
endmodule

// SceneCompleteRead (gcr) enable-0 fixture: Those three beats read back.
module g6lc_apu_vgpu_gcr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gcw_t gcw_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gcr_cpl_t cpl_o,
  output apu_vgpu_gcr_t gcr_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  g6lc_apu_vgpu_gcr #(.Enable(Enable)) i_dut (.*);
endmodule
