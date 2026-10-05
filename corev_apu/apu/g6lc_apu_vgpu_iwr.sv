// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the INLINE_WRITE at byte 648 that holds the quad already
// accepted. Beat 20 at 64'h8800B280 carries the header in bits
// [95:64]: 35 body dwords, object 0, opcode 9, and resource 3.
// Beat 21 at 64'h8800B2A0 carries the length 96 and the first float.
// The 96 bytes are not kept. This does not fetch vertices. The
// sampler-view handle in beat 20 and the second float in beat 21
// are not part of this check. This is not g6lc_apu_vgpu_iw and not
// g6lc_apu_vgpu_avail. A failed beat stops the read; the request
// can be repeated. TEX is not executed.

// InlineWriteRead (iwr): Inline write that holds the fetched quad.
module g6lc_apu_vgpu_iwr
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
  input  apu_vgpu_vbf_t vbf_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_iwr_cpl_t cpl_o,
  output apu_vgpu_iwr_t iwr_o,
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
      beat_bad = data[95:64] != APU_VIRGL_IW_HDR ||
                 data[127:96] != APU_VIRGL_RES_VBO ||
                 data[159:128] != 32'h0 || data[191:160] != 32'h0 ||
                 data[223:192] != 32'h0 || data[255:224] != 32'h0;
    end else begin
      beat_bad = data[31:0] != 32'h0 || data[63:32] != 32'h0 ||
                 data[95:64] != 32'h0 || data[127:96] != APU_VIRGL_VBO_BYTES ||
                 data[159:128] != 32'd1 || data[191:160] != 32'd1 ||
                 data[223:192] != APU_VIRGL_F32_NEG_ONE;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign iwr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) | (|drd_i) |
                        (|qdr_i) | (|vwx_i) | (|cxr_i) | (|cwr_i) | (|fbr_i) |
                        (|vbf_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_iwr_cpl_t cpl_q;
    apu_vgpu_iwr_t iwr_q;
    logic beat_q;
    logic [31:0] resource_q, nbytes_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_iwr_cpl_t'('0);
    assign iwr_o = iwr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        iwr_q <= '0;
        beat_q <= 1'b0;
        resource_q <= '0;
        nbytes_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (iwr_q.valid) begin
            cpl_q.status <= APU_VGPU_IWR_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid || !qdr_i.valid ||
                       !vwx_i.valid || !cxr_i.valid || !cwr_i.valid ||
                       !fbr_i.valid || !vbf_i.valid) begin
            cpl_q.status <= APU_VGPU_IWR_EMPTY;
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
                       fbr_i.surface != APU_VIRGL_SURFACE_HANDLE ||
                       fbr_i.word != APU_VGPU_CLEAR_WORD ||
                       vbf_i.stride != APU_VIRGL_VERT_STRIDE ||
                       vbf_i.offset != 32'h0 ||
                       vbf_i.resource != APU_VIRGL_RES_VBO) begin
            cpl_q.status <= APU_VGPU_IWR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            resource_q <= '0;
            nbytes_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_IW_ADDR;
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
            resource_q <= rd_rsp_data_i[127:96];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_IW_LAST;
            state_q <= Issue;
          end else begin
            nbytes_q <= rd_rsp_data_i[127:96];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || resource_q != APU_VIRGL_RES_VBO ||
              nbytes_q != APU_VIRGL_VBO_BYTES ||
              resource_q != vbf_i.resource)
            cpl_q.status <= APU_VGPU_IWR_FAULT;
          else begin
            iwr_q.valid <= 1'b1;
            iwr_q.resource <= resource_q;
            iwr_q.nbytes <= nbytes_q;
            cpl_q.status <= APU_VGPU_IWR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(iwr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_IWR_OK |->
        iwr_o.valid && iwr_o.resource == APU_VIRGL_RES_VBO &&
        iwr_o.nbytes == APU_VIRGL_VBO_BYTES);
    `endif
  end
endmodule

// InlineWriteRead (iwr) enable-0 fixture: Inline write that holds the fetched quad.
module g6lc_apu_vgpu_iwr_fixture
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
  input  apu_vgpu_vbf_t vbf_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_iwr_cpl_t cpl_o,
  output apu_vgpu_iwr_t iwr_o,
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
  g6lc_apu_vgpu_iwr #(.Enable(Enable)) i_dut (.*);
endmodule
