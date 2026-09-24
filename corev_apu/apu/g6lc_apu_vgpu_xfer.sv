// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One TRANSFER_TO_HOST_2D of a stored backing entry. The 56-byte
// little-endian word names the whole resource: x, y, and offset are 0
// and the rectangle matches the resource. The read uses the stored
// address and length. One response stores one 32-byte beat in that
// resource and nowhere else.
// A mismatched response does not commit. This does not write guest
// memory, attach a second entry, or follow a descriptor chain.

module g6lc_apu_vgpu_xfer
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_res_t slot0_i,
  input  apu_vgpu_res_t slot1_i,
  input  apu_vgpu_back_t back0_i,
  input  apu_vgpu_back_t back1_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [447:0] cmd_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output apu_vgpu_img_t img0_o,
  output apu_vgpu_img_t img1_o,
  input  logic peek_slot_i,
  input  logic [APU_FRAG_ADDR_BITS-1:0] peek_addr_i,
  output logic [31:0] peek_word_o,
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
    assign img0_o = '0;
    assign img1_o = '0;
    assign peek_word_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_cmd;
    assign unused_cmd = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|cmd_i) | (|slot0_i) |
                        (|slot1_i) | (|back0_i) | (|back1_i) | (|rd_rsp_addr_i) |
                        (|rd_rsp_len_i) | (|rd_rsp_data_i) | peek_slot_i |
                        (|peek_addr_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;
    typedef struct packed {
      apu_vgpu_cpl_t cpl;
      logic do_read;
      logic which;
      logic [31:0] resource_id;
      logic [63:0] addr;
      logic [31:0] len;
    } dec_t;

    state_e state_q;
    apu_vgpu_cpl_t cpl_q, hold_q;
    apu_vgpu_img_t img_q [0:1];
    logic [7:0] mem0 [0:APU_VGPU_IMG_BYTES-1];
    logic [7:0] mem1 [0:APU_VGPU_IMG_BYTES-1];
    logic armed_q, which_q;
    logic [31:0] rid_q, len_q;
    logic [63:0] addr_q;

    function automatic dec_t decode(
      input logic [447:0] cmd,
      input apu_vgpu_res_t s0,
      input apu_vgpu_res_t s1,
      input apu_vgpu_back_t b0,
      input apu_vgpu_back_t b1
    );
      logic [31:0] cmd_type, flags, ctx_id, hdr_pad, x, y, width, height;
      logic [31:0] rid, tail_pad, rw, rh, blen;
      logic [63:0] fence_id, offset, need, baddr;
      logic bad_flags, hit0, hit1, bvalid;
      decode = '0;
      cmd_type = cmd[31:0];
      flags = cmd[63:32];
      fence_id = cmd[127:64];
      ctx_id = cmd[159:128];
      hdr_pad = cmd[191:160];
      x = cmd[223:192];
      y = cmd[255:224];
      width = cmd[287:256];
      height = cmd[319:288];
      offset = cmd[383:320];
      rid = cmd[415:384];
      tail_pad = cmd[447:416];
      hit0 = s0.valid && s0.resource_id == rid;
      hit1 = s1.valid && s1.resource_id == rid;
      rw = hit0 ? s0.width : s1.width;
      rh = hit0 ? s0.height : s1.height;
      bvalid = hit0 ? b0.valid : b1.valid;
      baddr = hit0 ? b0.addr : b1.addr;
      blen = hit0 ? b0.length : b1.length;
      need = (64'(rw) * 64'(rh)) * 64'd4;
      decode.cpl.ctx_id = ctx_id;
      if (flags[0]) begin
        decode.cpl.flags = VGPU_FLAG_FENCE;
        decode.cpl.fence_id = fence_id;
      end
      bad_flags = |flags[31:1];
      if (cmd_type != VGPU_CMD_TRANSFER_TO_HOST_2D || bad_flags ||
          hdr_pad != 32'h0 || tail_pad != 32'h0 || x != 32'h0 || y != 32'h0 ||
          offset != 64'h0) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (!hit0 && !hit1) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_RESOURCE_ID;
      end else if (hit0 && hit1) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (width != rw || height != rh || !bvalid ||
                   (hit0 ? b0.resource_id : b1.resource_id) != rid ||
                   64'(blen) != need || need == 64'h0 ||
                   need > APU_VGPU_IMG_BYTES) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else begin
        decode.cpl.resp_type = VGPU_RESP_OK_NODATA;
        decode.do_read = 1'b1;
        decode.which = hit1;
        decode.resource_id = rid;
        decode.addr = baddr;
        decode.len = blen;
      end
    endfunction

    assign img0_o = img_q[0];
    assign img1_o = img_q[1];
    assign peek_word_o = peek_slot_i ? {
      mem1[peek_addr_i + APU_FRAG_ADDR_BITS'(3)],
      mem1[peek_addr_i + APU_FRAG_ADDR_BITS'(2)],
      mem1[peek_addr_i + APU_FRAG_ADDR_BITS'(1)],
      mem1[peek_addr_i]
    } : {
      mem0[peek_addr_i + APU_FRAG_ADDR_BITS'(3)],
      mem0[peek_addr_i + APU_FRAG_ADDR_BITS'(2)],
      mem0[peek_addr_i + APU_FRAG_ADDR_BITS'(1)],
      mem0[peek_addr_i]
    };
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cpl_t'('0);
    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = len_q;
    assign rd_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        hold_q <= '0;
        img_q[0] <= '0;
        img_q[1] <= '0;
        mem0 <= '{default: '0};
        mem1 <= '{default: '0};
        armed_q <= 1'b0;
        which_q <= 1'b0;
        rid_q <= '0;
        len_q <= '0;
        addr_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          dec_t got;
          got = decode(cmd_i, slot0_i, slot1_i, back0_i, back1_i);
          if (!got.do_read) begin
            cpl_q <= got.cpl;
            state_q <= Done;
          end else begin
            hold_q <= got.cpl;
            addr_q <= got.addr;
            len_q <= got.len;
            which_q <= got.which;
            rid_q <= got.resource_id;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          apu_vgpu_cpl_t nxt;
          nxt = hold_q;
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q || rd_rsp_len_i != len_q) begin
            nxt.resp_type = VGPU_RESP_ERR_UNSPEC;
          end else begin
            nxt.resp_type = VGPU_RESP_OK_NODATA;
            for (int i = 0; i < APU_VGPU_BEAT_BYTES; i++) begin
              if (32'(i) < len_q) begin
                if (!which_q)
                  mem0[i] <= rd_rsp_data_i[i*8 +: 8];
                else
                  mem1[i] <= rd_rsp_data_i[i*8 +: 8];
              end
            end
            if (!which_q) begin
              img_q[0].valid <= 1'b1;
              img_q[0].resource_id <= rid_q;
              img_q[0].length <= len_q;
            end else begin
              img_q[1].valid <= 1'b1;
              img_q[1].resource_id <= rid_q;
              img_q[1].length <= len_q;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(img0_o) && $stable(img1_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_xfer_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_res_t slot0_i,
  input  apu_vgpu_res_t slot1_i,
  input  apu_vgpu_back_t back0_i,
  input  apu_vgpu_back_t back1_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [447:0] cmd_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output apu_vgpu_img_t img0_o,
  output apu_vgpu_img_t img1_o,
  input  logic peek_slot_i,
  input  logic [APU_FRAG_ADDR_BITS-1:0] peek_addr_i,
  output logic [31:0] peek_word_o,
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
  g6lc_apu_vgpu_xfer #(.Enable(Enable)) i_dut (.*);
endmodule
