// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the lane at the byte offset of one readback point. The lane
// is the clear word. The image is not kept. The shader is not run.

// ReadbackOffsetLane (gbo): The lane at that offset.
module g6lc_apu_vgpu_gbo
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gof_t gof_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_gbk_t gbk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbo_cpl_t cpl_o,
  output apu_vgpu_gbo_t gbo_o,
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
  function automatic logic [15:0] pix_off(input logic [6:0] x, input logic [6:0] y);
    pix_off = {2'b0, y[5:0], 8'h00} + {8'h00, x[5:0], 2'b00};
  endfunction

  function automatic logic [63:0] pix_addr(input logic [15:0] off);
    pix_addr = APU_VGPU_GBW_ADDR + (64'(off[13:5]) << 5);
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
    assign gbo_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gof_i) | (|gbd_i) |
                        (|gbk_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_gbo_cpl_t cpl_q;
    apu_vgpu_gbo_t gbo_q;
    logic [31:0] word_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gbo_cpl_t'('0);
    assign gbo_o = gbo_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gbo_q <= '0;
        word_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gbo_q.valid) begin
            cpl_q.status <= APU_VGPU_GBO_FAULT;
            state_q <= Done;
          end else if (!gof_i.valid || !gbd_i.valid || !gbk_i.valid) begin
            cpl_q.status <= APU_VGPU_GBO_EMPTY;
            state_q <= Done;
          end else if (gof_i.x >= 7'd64 || gof_i.y >= 7'd64 ||
                       gof_i.offset != pix_off(gof_i.x, gof_i.y) ||
                       gof_i.addr != pix_addr(gof_i.offset) ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbk_i.word != APU_VGPU_CLEAR_WORD ||
                       gbk_i.dst != gbd_i.base) begin
            cpl_q.status <= APU_VGPU_GBO_FAULT;
            state_q <= Done;
          end else begin
            word_q <= '0;
            bad_q <= 1'b0;
            addr_q <= gof_i.addr;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic [31:0] lane;
          lane = lane_word(gof_i.offset[4:2], rd_rsp_data_i);
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
              lane != APU_VGPU_CLEAR_WORD)
            bad_q <= 1'b1;
          else word_q <= lane;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || word_q != APU_VGPU_CLEAR_WORD || word_q != gbk_i.word)
            cpl_q.status <= APU_VGPU_GBO_FAULT;
          else begin
            gbo_q.valid <= 1'b1;
            gbo_q.word <= word_q;
            gbo_q.offset <= gof_i.offset;
            gbo_q.x <= gof_i.x;
            gbo_q.y <= gof_i.y;
            cpl_q.status <= APU_VGPU_GBO_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_GBO_OK |->
        gbo_o.valid && gbo_o.word == APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// ReadbackOffsetLane (gbo) enable-0 fixture: The lane at that offset.
module g6lc_apu_vgpu_gbo_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gof_t gof_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_gbk_t gbk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbo_cpl_t cpl_o,
  output apu_vgpu_gbo_t gbo_o,
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
  g6lc_apu_vgpu_gbo #(.Enable(Enable)) i_dut (.*);
endmodule
