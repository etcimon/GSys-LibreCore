// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the CLEAR at byte 872 of the execbuffer whose scissor matches
// the window. Beat 27 at 64'h8800B360 carries the header in bits
// [95:64]: 8 body dwords, object 0, opcode 7, then the color floats
// 0.05, 0.05, 0.10, 1. Beat 28 at 64'h8800B380 carries depth 1 and
// is also the draw beat. The packed word of those floats is
// 32'hFF1A0D0D, byte 0 red. This does not convert a float and does
// not write a pixel. The framebuffer tail in beat 27 and the draw
// header in beat 28 are not part of this command. This is not
// g6lc_apu_vgpu_clr and not g6lc_apu_vgpu_avail. A failed beat stops
// the read; the request can be repeated. TEX is not executed.

// ClearColorRead (cwr): Clear color of the fetched draw.
module g6lc_apu_vgpu_cwr
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
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cwr_cpl_t cpl_o,
  output apu_vgpu_cwr_t cwr_o,
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

  function automatic logic beat_bad(input logic beat, input logic [255:0] data);
    if (beat == 1'b0) begin
      beat_bad = data[95:64] != APU_VIRGL_CLR_HDR ||
                 data[127:96] != APU_VIRGL_CLEAR_COLOR ||
                 data[159:128] != APU_VIRGL_F32_P05 ||
                 data[191:160] != APU_VIRGL_F32_P05 ||
                 data[223:192] != APU_VIRGL_F32_P10 ||
                 data[255:224] != APU_VIRGL_F32_ONE;
    end else begin
      beat_bad = data[31:0] != 32'h0 ||
                 data[63:32] != APU_VIRGL_DEPTH_HI ||
                 data[95:64] != 32'h0;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cwr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) | (|drd_i) |
                        (|qdr_i) | (|vwx_i) | (|cxr_i) | (|rd_rsp_addr_i) |
                        (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_cwr_cpl_t cpl_q;
    apu_vgpu_cwr_t cwr_q;
    logic beat_q;
    logic [31:0] red_q, blue_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cwr_cpl_t'('0);
    assign cwr_o = cwr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cwr_q <= '0;
        beat_q <= 1'b0;
        red_q <= '0;
        blue_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cwr_q.valid) begin
            cpl_q.status <= APU_VGPU_CWR_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid || !qdr_i.valid ||
                       !vwx_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_CWR_EMPTY;
            state_q <= Done;
          end else if (fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       drd_i.count != APU_VIRGL_VERT_COUNT ||
                       drd_i.prim != APU_VIRGL_PRIM_STRIP ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       qdr_i.last != APU_VIRGL_F32_ONE ||
                       vwx_i.x_neg != 16'd0 || vwx_i.y_neg != 16'd0 ||
                       vwx_i.x_pos != 16'd640 || vwx_i.y_pos != 16'd480 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_CWR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            red_q <= '0;
            blue_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_CLR_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES);
          if (bad_bus || beat_bad(beat_q, rd_rsp_data_i)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b0) begin
            red_q <= rd_rsp_data_i[159:128];
            blue_q <= rd_rsp_data_i[223:192];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_CLR_LAST;
            state_q <= Issue;
          end else state_q <= Commit;
        end
        Commit: begin
          if (bad_q || red_q != APU_VIRGL_F32_P05 || blue_q != APU_VIRGL_F32_P10)
            cpl_q.status <= APU_VGPU_CWR_FAULT;
          else begin
            cwr_q.valid <= 1'b1;
            cwr_q.red <= red_q;
            cwr_q.blue <= blue_q;
            cwr_q.word <= APU_VGPU_CLEAR_WORD;
            cpl_q.status <= APU_VGPU_CWR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cwr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CWR_OK |->
        cwr_o.valid && cwr_o.red == APU_VIRGL_F32_P05 &&
        cwr_o.blue == APU_VIRGL_F32_P10 && cwr_o.word == APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// ClearColorRead (cwr) enable-0 fixture: Clear color of the fetched draw.
module g6lc_apu_vgpu_cwr_fixture
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
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cwr_cpl_t cpl_o,
  output apu_vgpu_cwr_t cwr_o,
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
  g6lc_apu_vgpu_cwr #(.Enable(Enable)) i_dut (.*);
endmodule
