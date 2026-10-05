// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the 24 NDC floats the recognized DRAW_VBO names. They start at
// byte 696 of the execbuffer g6lc_apu_vgpu_fet already accepted.
// Beat 21 at 64'h8800B2A0 holds the inline-write length and the first
// two floats. Beats 22 and 23 hold the middle sixteen. Beat 24 at
// 64'h8800B300 holds the last six. Each vertex is {x, y, 0, 1, u, v}.
// The corners are (-1,-1), (1,-1), (-1,1), (1,1). The 96 bytes are
// not kept. This does not transform a vertex and does not execute
// the draw. This is not g6lc_apu_vgpu_qd and not g6lc_apu_vgpu_avail.
// A failed beat stops the read; the request can be repeated.
// TEX is not executed.

// NdcFloatsRead (qdr): The 24 NDC floats of the fetched draw.
module g6lc_apu_vgpu_qdr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qdr_cpl_t cpl_o,
  output apu_vgpu_qdr_t qdr_o,
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

  function automatic logic [31:0] quad_word(input logic [4:0] i);
    case (i)
      5'd0, 5'd1, 5'd7, 5'd12: quad_word = APU_VIRGL_F32_NEG_ONE;
      5'd3, 5'd6, 5'd9, 5'd10, 5'd13, 5'd15, 5'd17, 5'd18, 5'd19,
      5'd21, 5'd22, 5'd23: quad_word = APU_VIRGL_F32_ONE;
      default: quad_word = 32'h0;
    endcase
  endfunction

  function automatic logic beat_bad(input logic [1:0] beat, input logic [255:0] data);
    if (beat == 2'd0) begin
      beat_bad = data[31:0] != 32'h0 || data[63:32] != 32'h0 || data[95:64] != 32'h0 ||
                 data[127:96] != APU_VIRGL_VBO_BYTES || data[159:128] != 32'd1 ||
                 data[191:160] != 32'd1 || data[223:192] != quad_word(5'd0) ||
                 data[255:224] != quad_word(5'd1);
    end else if (beat == 2'd1) begin
      beat_bad = data[31:0] != quad_word(5'd2) || data[63:32] != quad_word(5'd3) ||
                 data[95:64] != quad_word(5'd4) || data[127:96] != quad_word(5'd5) ||
                 data[159:128] != quad_word(5'd6) || data[191:160] != quad_word(5'd7) ||
                 data[223:192] != quad_word(5'd8) || data[255:224] != quad_word(5'd9);
    end else if (beat == 2'd2) begin
      beat_bad = data[31:0] != quad_word(5'd10) || data[63:32] != quad_word(5'd11) ||
                 data[95:64] != quad_word(5'd12) || data[127:96] != quad_word(5'd13) ||
                 data[159:128] != quad_word(5'd14) || data[191:160] != quad_word(5'd15) ||
                 data[223:192] != quad_word(5'd16) || data[255:224] != quad_word(5'd17);
    end else begin
      beat_bad = data[31:0] != quad_word(5'd18) || data[63:32] != quad_word(5'd19) ||
                 data[95:64] != quad_word(5'd20) || data[127:96] != quad_word(5'd21) ||
                 data[159:128] != quad_word(5'd22) || data[191:160] != quad_word(5'd23);
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qdr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) | (|drd_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_qdr_cpl_t cpl_q;
    apu_vgpu_qdr_t qdr_q;
    logic [1:0] beat_q;
    logic [31:0] x0_q, last_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qdr_cpl_t'('0);
    assign qdr_o = qdr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qdr_q <= '0;
        beat_q <= '0;
        x0_q <= '0;
        last_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qdr_q.valid) begin
            cpl_q.status <= APU_VGPU_QDR_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid) begin
            cpl_q.status <= APU_VGPU_QDR_EMPTY;
            state_q <= Done;
          end else if (fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       drd_i.count != APU_VIRGL_VERT_COUNT ||
                       drd_i.prim != APU_VIRGL_PRIM_STRIP) begin
            cpl_q.status <= APU_VGPU_QDR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= '0;
            x0_q <= '0;
            last_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_QUAD_ADDR;
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
          end else if (beat_q != 2'd3) begin
            if (beat_q == 2'd0) x0_q <= rd_rsp_data_i[223:192];
            beat_q <= beat_q + 2'd1;
            addr_q <= APU_VGPU_QUAD_ADDR + (64'(beat_q + 2'd1) << 5);
            state_q <= Issue;
          end else begin
            last_q <= rd_rsp_data_i[191:160];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || x0_q != APU_VIRGL_F32_NEG_ONE ||
              last_q != APU_VIRGL_F32_ONE) cpl_q.status <= APU_VGPU_QDR_FAULT;
          else begin
            qdr_q.valid <= 1'b1;
            qdr_q.x0 <= x0_q;
            qdr_q.last <= last_q;
            cpl_q.status <= APU_VGPU_QDR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qdr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QDR_OK |->
        qdr_o.valid && qdr_o.x0 == APU_VIRGL_F32_NEG_ONE &&
        qdr_o.last == APU_VIRGL_F32_ONE);
    `endif
  end
endmodule

// NdcFloatsRead (qdr) enable-0 fixture: The 24 NDC floats of the fetched draw.
module g6lc_apu_vgpu_qdr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qdr_cpl_t cpl_o,
  output apu_vgpu_qdr_t qdr_o,
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
  g6lc_apu_vgpu_qdr #(.Enable(Enable)) i_dut (.*);
endmodule
