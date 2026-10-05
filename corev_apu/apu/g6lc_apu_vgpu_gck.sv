// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the response type, the fence, the used element, and the used
// index. A second store keeps the first. The bytes are not kept.
// The shader is not run.

// SceneCompleteKeep (gck): The response type, the fence, and the used index.
module g6lc_apu_vgpu_gck
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gcr_t gcr_i,
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
  output apu_vgpu_gck_cpl_t cpl_o,
  output apu_vgpu_gck_t gck_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gck_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gcr_i) | (|gcw_i) | (|gpk_i) | (|ols_i) |
                        (|nxc_i) | (|cwr_i) | (|cxr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gck_cpl_t cpl_q;
    apu_vgpu_gck_t gck_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gck_cpl_t'('0);
    assign gck_o = gck_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gck_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gck_q.valid) begin
            cpl_q.status <= APU_VGPU_GCK_FAULT;
          end else if (!gcr_i.valid || !gcw_i.valid || !gpk_i.valid ||
                       !ols_i.valid || !nxc_i.valid || !cwr_i.valid ||
                       !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_GCK_EMPTY;
          end else if (gcr_i.resp != gcw_i.resp || gcr_i.fence != gcw_i.fence ||
                       gcr_i.elem_id != gcw_i.elem_id ||
                       gcr_i.elem_len != gcw_i.elem_len ||
                       gcr_i.used_idx != gcw_i.used_idx ||
                       gcr_i.resp != VGPU_RESP_OK_NODATA ||
                       gcr_i.fence != APU_VGPU_SCENE_FENCE ||
                       gcr_i.elem_id != 32'd0 ||
                       gcr_i.elem_len != VGPU_RESP_HDR_BYTES ||
                       gcr_i.used_idx != 16'd1 ||
                       gcr_i.used_idx != nxc_i.avail_idx ||
                       nxc_i.head != 16'd0 ||
                       nxc_i.rsp_addr != APU_VGPU_RSP_ADDR ||
                       nxc_i.buf_len != APU_VGPU_SCENE_BYTES ||
                       ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       ols_i.resp != VGPU_RESP_OK_NODATA ||
                       gpk_i.word != APU_VGPU_CLEAR_WORD ||
                       gpk_i.word != cwr_i.word ||
                       gpk_i.first != APU_VGPU_GPW_ADDR ||
                       gpk_i.last != APU_VGPU_GPW_TAIL ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_GCK_FAULT;
          end else begin
            gck_q.valid <= 1'b1;
            gck_q.resp <= gcr_i.resp;
            gck_q.fence <= gcr_i.fence;
            gck_q.elem_id <= gcr_i.elem_id;
            gck_q.elem_len <= gcr_i.elem_len;
            gck_q.used_idx <= gcr_i.used_idx;
            cpl_q.status <= APU_VGPU_GCK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gck_o));
    `endif
  end
endmodule

// SceneCompleteKeep (gck) enable-0 fixture: The response type, the fence, and the used index.
module g6lc_apu_vgpu_gck_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gcr_t gcr_i,
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
  output apu_vgpu_gck_cpl_t cpl_o,
  output apu_vgpu_gck_t gck_o
);
  g6lc_apu_vgpu_gck #(.Enable(Enable)) i_dut (.*);
endmodule
