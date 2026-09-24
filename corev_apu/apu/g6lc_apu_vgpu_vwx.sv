// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the SET_VIEWPORT at byte 824 of the execbuffer whose draw and
// NDC floats are already accepted. Beat 25 at 64'h8800B320 carries the
// header in bits [223:192]: 7 body dwords, object 0, opcode 4. Beat 26
// at 64'h8800B340 carries scale 320, scale 240, 1, then 320, 240, and 0.
// The frozen square is ndc ±1, so x = ndc_x*320+320 and y = ndc_y*240+240
// land on 0 and 640, 0 and 480. Those integers are the record. This is
// not a floating-point multiply and not a rasterizer. The low 24 bytes
// of beat 25 are the scissor and are not part of this command. This is
// not g6lc_apu_vgpu_vp and not g6lc_apu_vgpu_avail. A failed beat stops
// the read; the request can be repeated. TEX is not executed.

module g6lc_apu_vgpu_vwx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vwx_cpl_t cpl_o,
  output apu_vgpu_vwx_t vwx_o,
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
      beat_bad = data[223:192] != APU_VIRGL_VIEW_HDR || data[255:224] != 32'h0;
    end else begin
      beat_bad = data[31:0] != APU_VIRGL_F32_HALF_W ||
                 data[63:32] != APU_VIRGL_F32_HALF_H ||
                 data[95:64] != APU_VIRGL_F32_ONE ||
                 data[127:96] != APU_VIRGL_F32_HALF_W ||
                 data[159:128] != APU_VIRGL_F32_HALF_H ||
                 data[191:160] != 32'h0;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vwx_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) | (|drd_i) | (|qdr_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_vwx_cpl_t cpl_q;
    apu_vgpu_vwx_t vwx_q;
    logic beat_q;
    logic [31:0] scale_x_q, scale_y_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vwx_cpl_t'('0);
    assign vwx_o = vwx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vwx_q <= '0;
        beat_q <= 1'b0;
        scale_x_q <= '0;
        scale_y_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vwx_q.valid) begin
            cpl_q.status <= APU_VGPU_VWX_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_VWX_EMPTY;
            state_q <= Done;
          end else if (fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       drd_i.count != APU_VIRGL_VERT_COUNT ||
                       drd_i.prim != APU_VIRGL_PRIM_STRIP ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       qdr_i.last != APU_VIRGL_F32_ONE) begin
            cpl_q.status <= APU_VGPU_VWX_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            scale_x_q <= '0;
            scale_y_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_VIEW_ADDR;
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
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_VIEW_LAST;
            state_q <= Issue;
          end else begin
            scale_x_q <= rd_rsp_data_i[31:0];
            scale_y_q <= rd_rsp_data_i[63:32];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || scale_x_q != APU_VIRGL_F32_HALF_W ||
              scale_y_q != APU_VIRGL_F32_HALF_H) cpl_q.status <= APU_VGPU_VWX_FAULT;
          else begin
            vwx_q.valid <= 1'b1;
            vwx_q.scale_x <= scale_x_q;
            vwx_q.scale_y <= scale_y_q;
            vwx_q.x_neg <= 16'd0;
            vwx_q.y_neg <= 16'd0;
            vwx_q.x_pos <= 16'd640;
            vwx_q.y_pos <= 16'd480;
            cpl_q.status <= APU_VGPU_VWX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vwx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_VWX_OK |->
        vwx_o.valid && vwx_o.scale_x == APU_VIRGL_F32_HALF_W &&
        vwx_o.scale_y == APU_VIRGL_F32_HALF_H &&
        vwx_o.x_neg == 16'd0 && vwx_o.y_neg == 16'd0 &&
        vwx_o.x_pos == 16'd640 && vwx_o.y_pos == 16'd480);
    `endif
  end
endmodule

module g6lc_apu_vgpu_vwx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vwx_cpl_t cpl_o,
  output apu_vgpu_vwx_t vwx_o,
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
  g6lc_apu_vgpu_vwx #(.Enable(Enable)) i_dut (.*);
endmodule
