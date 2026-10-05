// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the SET_SCISSOR at byte 808 of the execbuffer whose window
// edges are already accepted. The command shares beat 25 at
// 64'h8800B320 with the viewport. The header is in bits [95:64]:
// 3 body dwords, object 0, opcode 15. The box is 640 by 480, and
// the window edges are 0 and 640, 0 and 480. No pixel is clipped.
// The vertex-buffer tail and the viewport header in this beat are
// not part of this command. This is not g6lc_apu_vgpu_sci and not
// g6lc_apu_vgpu_avail. A failed beat stops the read; the request
// can be repeated. TEX is not executed.

// ScissorRead (cxr): Scissor of the fetched draw, matched to the window.
module g6lc_apu_vgpu_cxr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  apu_vgpu_vwx_t vwx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cxr_cpl_t cpl_o,
  output apu_vgpu_cxr_t cxr_o,
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
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cxr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) | (|drd_i) |
                        (|qdr_i) | (|vwx_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_cxr_cpl_t cpl_q;
    apu_vgpu_cxr_t cxr_q;
    logic [15:0] width_q, height_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cxr_cpl_t'('0);
    assign cxr_o = cxr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cxr_q <= '0;
        width_q <= '0;
        height_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cxr_q.valid) begin
            cpl_q.status <= APU_VGPU_CXR_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid || !qdr_i.valid || !vwx_i.valid) begin
            cpl_q.status <= APU_VGPU_CXR_EMPTY;
            state_q <= Done;
          end else if (fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       drd_i.count != APU_VIRGL_VERT_COUNT ||
                       drd_i.prim != APU_VIRGL_PRIM_STRIP ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       qdr_i.last != APU_VIRGL_F32_ONE ||
                       vwx_i.scale_x != APU_VIRGL_F32_HALF_W ||
                       vwx_i.scale_y != APU_VIRGL_F32_HALF_H ||
                       vwx_i.x_neg != 16'd0 || vwx_i.y_neg != 16'd0 ||
                       vwx_i.x_pos != 16'd640 || vwx_i.y_pos != 16'd480) begin
            cpl_q.status <= APU_VGPU_CXR_FAULT;
            state_q <= Done;
          end else begin
            width_q <= '0;
            height_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_SCI_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus, bad_sci;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES);
          bad_sci = rd_rsp_data_i[95:64] != APU_VIRGL_SCI_HDR ||
                    rd_rsp_data_i[127:96] != 32'h0 ||
                    rd_rsp_data_i[159:128] != 32'h0 ||
                    rd_rsp_data_i[191:160] != APU_VIRGL_SCISSOR_BOX;
          if (bad_bus || bad_sci) bad_q <= 1'b1;
          else begin
            width_q <= rd_rsp_data_i[175:160];
            height_q <= rd_rsp_data_i[191:176];
          end
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || width_q != 16'd640 || height_q != 16'd480)
            cpl_q.status <= APU_VGPU_CXR_FAULT;
          else begin
            cxr_q.valid <= 1'b1;
            cxr_q.width <= width_q;
            cxr_q.height <= height_q;
            cpl_q.status <= APU_VGPU_CXR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cxr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CXR_OK |->
        cxr_o.valid && cxr_o.width == 16'd640 && cxr_o.height == 16'd480);
    `endif
  end
endmodule

// ScissorRead (cxr) enable-0 fixture: Scissor of the fetched draw, matched to the window.
module g6lc_apu_vgpu_cxr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  apu_vgpu_vwx_t vwx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cxr_cpl_t cpl_o,
  output apu_vgpu_cxr_t cxr_o,
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
  g6lc_apu_vgpu_cxr #(.Enable(Enable)) i_dut (.*);
endmodule
