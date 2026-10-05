// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read (1,0) in the 64 by 64 guest rectangle. The lane is the
// half blend, not the clear word. (0,0) or a 64-wide index
// records nothing. This is later than g6lc_apu_vgpu_grd. The
// image is not kept. TEX is not the compiler opcode. This is not
// Mesa glReadPixels.

// GuestReadpixelsLane (grl): (1,0) in that rectangle is the half blend.
module g6lc_apu_vgpu_grl
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_grd_t grd_i,
  input  apu_vgpu_rpx_t rpx_i,
  input  logic [6:0] x_i,
  input  logic [6:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_grl_cpl_t cpl_o,
  output apu_vgpu_grl_t grl_o,
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
  function automatic logic [31:0] lane_word(input logic [2:0] lane,
                                           input logic [255:0] data);
    case (lane)
      3'd0: lane_word = data[31:0];
      3'd1: lane_word = data[63:32];
      3'd2: lane_word = data[95:64];
      3'd3: lane_word = data[127:96];
      3'd4: lane_word = data[159:128];
      3'd5: lane_word = data[191:160];
      3'd6: lane_word = data[223:192];
      default: lane_word = data[255:224];
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign grl_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|grd_i) | (|rpx_i) |
                        (|x_i) | (|y_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_grl_cpl_t cpl_q;
    apu_vgpu_grl_t grl_q;
    logic [31:0] word_q, want_q;
    logic [63:0] addr_q;
    logic [6:0] x_q, y_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_grl_cpl_t'('0);
    assign grl_o = grl_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        grl_q <= '0;
        word_q <= '0;
        want_q <= '0;
        addr_q <= '0;
        x_q <= '0;
        y_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (grl_q.valid) begin
            cpl_q.status <= APU_VGPU_GRL_FAULT;
            state_q <= Done;
          end else if (!grd_i.valid || !rpx_i.valid) begin
            cpl_q.status <= APU_VGPU_GRL_EMPTY;
            state_q <= Done;
          end else if (grd_i.base != APU_VGPU_RPW_DST ||
                       grd_i.base == APU_VGPU_CSW_DST ||
                       grd_i.width != APU_VGPU_GBD_W ||
                       grd_i.height != APU_VGPU_GBD_H ||
                       grd_i.stride != APU_VGPU_GBD_STRIDE ||
                       grd_i.bytes != APU_VGPU_GBD_BYTES ||
                       grd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       grd_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                       grd_i.neighbor != rpx_i.neighbor ||
                       grd_i.origin != rpx_i.origin ||
                       grd_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       x_i != 7'd1 || y_i != 7'd0) begin
            cpl_q.status <= APU_VGPU_GRL_FAULT;
            state_q <= Done;
          end else begin
            x_q <= x_i;
            y_q <= y_i;
            want_q <= grd_i.neighbor;
            word_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_RPW_DST;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic [31:0] lane;
          lane = lane_word(3'd1, rd_rsp_data_i);
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
              lane != want_q || lane == APU_VGPU_CLEAR_WORD ||
              rd_rsp_data_i[31:0] == APU_VGPU_CLEAR_WORD)
            bad_q <= 1'b1;
          else word_q <= lane;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || word_q != want_q || word_q == APU_VGPU_CLEAR_WORD)
            cpl_q.status <= APU_VGPU_GRL_FAULT;
          else begin
            grl_q.valid <= 1'b1;
            grl_q.word <= word_q;
            grl_q.x <= x_q;
            grl_q.y <= y_q;
            grl_q.addr <= addr_q;
            cpl_q.status <= APU_VGPU_GRL_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(grl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GRL_OK |->
        grl_o.valid && grl_o.x == 7'd1 && grl_o.y == 7'd0 &&
        grl_o.addr == APU_VGPU_RPW_DST &&
        grl_o.word != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// GuestReadpixelsLane (grl) enable-0 fixture: (1,0) in that rectangle is the half blend.
module g6lc_apu_vgpu_grl_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_grd_t grd_i,
  input  apu_vgpu_rpx_t rpx_i,
  input  logic [6:0] x_i,
  input  logic [6:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_grl_cpl_t cpl_o,
  output apu_vgpu_grl_t grl_o,
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
  g6lc_apu_vgpu_grl #(.Enable(Enable)) i_dut (.*);
endmodule
