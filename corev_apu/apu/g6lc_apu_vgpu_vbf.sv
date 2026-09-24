// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the SET_VERTEX_BUFFERS at byte 792 of the execbuffer whose
// framebuffer is already accepted. Beat 24 at 64'h8800B300 carries
// the header in bits [223:192]: 3 body dwords, object 0, opcode 6,
// and stride 24 in bits [255:224]. Beat 25 at 64'h8800B320 carries
// offset 0 and resource 3. This does not fetch vertices. The last
// quad float in beat 24 and the scissor in beat 25 are not part of
// this command. This is not g6lc_apu_vgpu_vb and not
// g6lc_apu_vgpu_avail. A failed beat stops the read; the request
// can be repeated. TEX is not executed.

module g6lc_apu_vgpu_vbf
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
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vbf_cpl_t cpl_o,
  output apu_vgpu_vbf_t vbf_o,
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
      beat_bad = data[223:192] != APU_VIRGL_VB_HDR ||
                 data[255:224] != APU_VIRGL_VERT_STRIDE;
    end else begin
      beat_bad = data[31:0] != 32'h0 || data[63:32] != APU_VIRGL_RES_VBO;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vbf_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) | (|drd_i) |
                        (|qdr_i) | (|vwx_i) | (|cxr_i) | (|cwr_i) | (|fbr_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_vbf_cpl_t cpl_q;
    apu_vgpu_vbf_t vbf_q;
    logic beat_q;
    logic [31:0] stride_q, offset_q, resource_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vbf_cpl_t'('0);
    assign vbf_o = vbf_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vbf_q <= '0;
        beat_q <= 1'b0;
        stride_q <= '0;
        offset_q <= '0;
        resource_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vbf_q.valid) begin
            cpl_q.status <= APU_VGPU_VBF_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid || !qdr_i.valid ||
                       !vwx_i.valid || !cxr_i.valid || !cwr_i.valid ||
                       !fbr_i.valid) begin
            cpl_q.status <= APU_VGPU_VBF_EMPTY;
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
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       cwr_i.word != APU_VGPU_CLEAR_WORD ||
                       fbr_i.nr_cbufs != 32'd1 ||
                       fbr_i.surface != APU_VIRGL_SURFACE_HANDLE ||
                       fbr_i.word != APU_VGPU_CLEAR_WORD) begin
            cpl_q.status <= APU_VGPU_VBF_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            stride_q <= '0;
            offset_q <= '0;
            resource_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_VB_ADDR;
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
            stride_q <= rd_rsp_data_i[255:224];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_VB_LAST;
            state_q <= Issue;
          end else begin
            offset_q <= rd_rsp_data_i[31:0];
            resource_q <= rd_rsp_data_i[63:32];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || stride_q != APU_VIRGL_VERT_STRIDE || offset_q != 32'h0 ||
              resource_q != APU_VIRGL_RES_VBO)
            cpl_q.status <= APU_VGPU_VBF_FAULT;
          else begin
            vbf_q.valid <= 1'b1;
            vbf_q.stride <= stride_q;
            vbf_q.offset <= offset_q;
            vbf_q.resource <= resource_q;
            cpl_q.status <= APU_VGPU_VBF_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vbf_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_VBF_OK |->
        vbf_o.valid && vbf_o.stride == APU_VIRGL_VERT_STRIDE &&
        vbf_o.offset == 32'h0 && vbf_o.resource == APU_VIRGL_RES_VBO);
    `endif
  end
endmodule

module g6lc_apu_vgpu_vbf_fixture
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
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vbf_cpl_t cpl_o,
  output apu_vgpu_vbf_t vbf_o,
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
  g6lc_apu_vgpu_vbf #(.Enable(Enable)) i_dut (.*);
endmodule
