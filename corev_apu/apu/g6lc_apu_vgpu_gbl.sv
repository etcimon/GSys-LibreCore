// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read one lane of the 64 by 64 readback buffer. The lane is the
// clear word. x or y of 64 reads nothing. (1,0) is byte 4 of beat 0.
// (63,63) is the top lane of the last beat. The image is not kept.
// The shader is not run.

// ReadbackRectLane (gbl): One lane of that rectangle.
module g6lc_apu_vgpu_gbl
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_gbk_t gbk_i,
  input  logic [6:0] x_i,
  input  logic [6:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbl_cpl_t cpl_o,
  output apu_vgpu_gbl_t gbl_o,
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
  function automatic logic [63:0] pix_addr(input logic [6:0] x, input logic [6:0] y);
    logic [8:0] beat;
    beat = {y[5:0], x[5:3]};
    pix_addr = APU_VGPU_GBW_ADDR + (64'(beat) << 5);
  endfunction

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
    assign gbl_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gbd_i) | (|gbk_i) |
                        (|x_i) | (|y_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_gbl_cpl_t cpl_q;
    apu_vgpu_gbl_t gbl_q;
    logic [31:0] word_q;
    logic [63:0] addr_q;
    logic [6:0] x_q, y_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gbl_cpl_t'('0);
    assign gbl_o = gbl_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gbl_q <= '0;
        word_q <= '0;
        addr_q <= '0;
        x_q <= '0;
        y_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gbl_q.valid) begin
            cpl_q.status <= APU_VGPU_GBL_FAULT;
            state_q <= Done;
          end else if (!gbd_i.valid || !gbk_i.valid) begin
            cpl_q.status <= APU_VGPU_GBL_EMPTY;
            state_q <= Done;
          end else if (gbd_i.width != APU_VGPU_GBD_W ||
                       gbd_i.height != APU_VGPU_GBD_H ||
                       gbd_i.stride != APU_VGPU_GBD_STRIDE ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbk_i.word != APU_VGPU_CLEAR_WORD ||
                       gbk_i.dst != gbd_i.base ||
                       x_i >= 7'd64 || y_i >= 7'd64) begin
            cpl_q.status <= APU_VGPU_GBL_FAULT;
            state_q <= Done;
          end else begin
            x_q <= x_i;
            y_q <= y_i;
            word_q <= '0;
            bad_q <= 1'b0;
            addr_q <= pix_addr(x_i, y_i);
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic [31:0] lane;
          lane = lane_word(x_q[2:0], rd_rsp_data_i);
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
              lane != APU_VGPU_CLEAR_WORD) begin
            bad_q <= 1'b1;
          end else word_q <= lane;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || word_q != APU_VGPU_CLEAR_WORD ||
              word_q != gbk_i.word)
            cpl_q.status <= APU_VGPU_GBL_FAULT;
          else begin
            gbl_q.valid <= 1'b1;
            gbl_q.word <= word_q;
            gbl_q.x <= x_q;
            gbl_q.y <= y_q;
            gbl_q.addr <= addr_q;
            cpl_q.status <= APU_VGPU_GBL_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_GBL_OK |->
        gbl_o.valid && gbl_o.word == APU_VGPU_CLEAR_WORD &&
        gbl_o.x < 7'd64 && gbl_o.y < 7'd64);
    `endif
  end
endmodule

// ReadbackRectLane (gbl) enable-0 fixture: One lane of that rectangle.
module g6lc_apu_vgpu_gbl_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_gbk_t gbk_i,
  input  logic [6:0] x_i,
  input  logic [6:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbl_cpl_t cpl_o,
  output apu_vgpu_gbl_t gbl_o,
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
  g6lc_apu_vgpu_gbl #(.Enable(Enable)) i_dut (.*);
endmodule
