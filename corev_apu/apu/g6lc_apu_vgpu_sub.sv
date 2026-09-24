// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One SUBMIT_3D three-descriptor chain. Descriptor 0 is the 32-byte
// virtio_gpu_cmd_submit header, descriptor 1 names the execbuffer, and
// descriptor 2 is the writable response. The header is read from guest
// memory. This unit does not read the execbuffer or write the response.
// A second submit does not replace the first. This is not a draw.

module g6lc_apu_vgpu_sub
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_sub_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output apu_vgpu_sub_t sub_o,
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
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sub_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|req_i) | (|rd_rsp_addr_i) |
                        (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;
    typedef struct packed {
      apu_vgpu_cpl_t cpl;
      logic do_read;
      logic [63:0] addr;
      logic [31:0] buf_len;
      logic [63:0] buf_addr;
      logic [63:0] rsp_addr;
    } dec_t;

    state_e state_q;
    apu_vgpu_cpl_t cpl_q;
    apu_vgpu_sub_t sub_q;
    logic armed_q;
    logic [63:0] addr_q, buf_addr_q, rsp_addr_q;
    logic [31:0] buf_len_q;

    function automatic logic range_ok(
      input logic [63:0] addr, input logic [31:0] len
    );
      range_ok = addr != 64'h0 && addr[1:0] == 2'b00 && len != 32'h0 &&
                 (addr + 64'(len)) >= addr;
    endfunction

    function automatic dec_t decode(
      input apu_vgpu_sub_req_t req,
      input logic already
    );
      logic shape;
      decode = '0;
      shape = req.d0.flags == VIRTQ_DESC_F_NEXT && req.d0.next == 16'd1 &&
              req.d0.len == VGPU_SUBMIT_BYTES &&
              req.d1.flags == VIRTQ_DESC_F_NEXT && req.d1.next == 16'd2 &&
              req.d1.len != 32'h0 && req.d1.len <= APU_VGPU_SUB_MAX &&
              req.d2.flags == VIRTQ_DESC_F_WRITE && req.d2.next == 16'd0 &&
              req.d2.len == VGPU_RESP_HDR_BYTES &&
              range_ok(req.d0.addr, req.d0.len) &&
              range_ok(req.d1.addr, req.d1.len) &&
              range_ok(req.d2.addr, req.d2.len);
      if (!shape) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (already) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_UNSPEC;
      end else begin
        decode.do_read = 1'b1;
        decode.addr = req.d0.addr;
        decode.buf_len = req.d1.len;
        decode.buf_addr = req.d1.addr;
        decode.rsp_addr = req.d2.addr;
      end
    endfunction

    function automatic apu_vgpu_cpl_t hdr_cpl(
      input logic [APU_VGPU_BEAT_BYTES*8-1:0] data,
      input logic [31:0] buf_len
    );
      logic [31:0] cmd_type, flags, ctx_id, hdr_pad, size, tail_pad;
      logic [63:0] fence_id;
      logic bad_flags;
      hdr_cpl = '0;
      cmd_type = data[31:0];
      flags = data[63:32];
      fence_id = data[127:64];
      ctx_id = data[159:128];
      hdr_pad = data[191:160];
      size = data[223:192];
      tail_pad = data[255:224];
      hdr_cpl.ctx_id = ctx_id;
      if (flags[0]) begin
        hdr_cpl.flags = VGPU_FLAG_FENCE;
        hdr_cpl.fence_id = fence_id;
      end
      bad_flags = |flags[31:1];
      if (cmd_type != VGPU_CMD_SUBMIT_3D || bad_flags || hdr_pad != 32'h0 ||
          tail_pad != 32'h0 || size != buf_len) begin
        hdr_cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else begin
        hdr_cpl.resp_type = VGPU_RESP_OK_NODATA;
      end
    endfunction

    assign sub_o = sub_q;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cpl_t'('0);
    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = VGPU_SUBMIT_BYTES;
    assign rd_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sub_q <= '0;
        armed_q <= 1'b0;
        addr_q <= '0;
        buf_addr_q <= '0;
        rsp_addr_q <= '0;
        buf_len_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          dec_t got;
          got = decode(req_i, sub_q.valid);
          if (!got.do_read) begin
            cpl_q <= got.cpl;
            state_q <= Done;
          end else begin
            addr_q <= got.addr;
            buf_len_q <= got.buf_len;
            buf_addr_q <= got.buf_addr;
            rsp_addr_q <= got.rsp_addr;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          apu_vgpu_cpl_t nxt;
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != VGPU_SUBMIT_BYTES) begin
            nxt = '0;
            nxt.resp_type = VGPU_RESP_ERR_UNSPEC;
          end else begin
            nxt = hdr_cpl(rd_rsp_data_i, buf_len_q);
            if (nxt.resp_type == VGPU_RESP_OK_NODATA) begin
              sub_q.valid <= 1'b1;
              sub_q.ctx_id <= nxt.ctx_id;
              sub_q.size <= buf_len_q;
              sub_q.buf_addr <= buf_addr_q;
              sub_q.rsp_addr <= rsp_addr_q;
            end
          end
          cpl_q <= nxt;
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
      cpl_valid_o |-> cpl_o.resource_id == 32'h0 && cpl_o.format == 32'h0 &&
                      cpl_o.width == 32'h0 && cpl_o.height == 32'h0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      rd_valid_o && !rd_ready_i |=> rd_valid_o && $stable(rd_addr_o) &&
                     $stable(rd_len_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(sub_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_sub_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_sub_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output apu_vgpu_sub_t sub_o,
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
  g6lc_apu_vgpu_sub #(.Enable(Enable)) i_dut (.*);
endmodule
