// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One TRANSFER_FROM_HOST_3D of a fragment surface. The 72-byte
// little-endian word is virtio_gpu_transfer_host_3d: header, box,
// offset, resource, level, stride, layer stride. The box is the
// whole resource, the offset and level are 0, and the stride is
// tight. Bytes come from the image memory and land at the stored
// backing address, 32 bytes per beat. wrote rises after the last
// good beat. A second readback of that resource does not replace
// them. This does not draw, follow a descriptor chain, or sample.

// FragReadback (rdb): One guest readback of the fragment surface. Default-off. Not a draw, not a descriptor chain, and not the HDMI buffer.
module g6lc_apu_vgpu_rdb
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
  input  apu_vgpu_img_t surf_i,
  input  logic img_we_i,
  input  logic [APU_FRAG_ADDR_BITS-1:0] img_wa_i,
  input  logic [31:0] img_wd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [575:0] cmd_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output logic [1:0] wrote_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i,
  input  logic [31:0] wr_rsp_len_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign wrote_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_cmd;
    assign unused_cmd = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|cmd_i) | (|slot0_i) |
                        (|slot1_i) | (|back0_i) | (|back1_i) | (|surf_i) |
                        img_we_i | (|img_wa_i) | (|img_wd_i) |
                        (|wr_rsp_addr_i) | (|wr_rsp_len_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;
    typedef struct packed {
      apu_vgpu_cpl_t cpl;
      logic do_write;
      logic which;
      logic [63:0] addr;
      logic [31:0] len;
    } dec_t;

    state_e state_q;
    apu_vgpu_cpl_t cpl_q, hold_q;
    logic [1:0] wrote_q;
    logic armed_q, which_q;
    logic [7:0] img_mem [0:APU_VGPU_IMG_BYTES-1];
    logic [63:0] addr_q, base_q;
    logic [31:0] len_q, off_q, total_q;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] data_q;

    function automatic dec_t decode(
      input logic [575:0] cmd,
      input apu_vgpu_res_t s0,
      input apu_vgpu_res_t s1,
      input apu_vgpu_back_t b0,
      input apu_vgpu_back_t b1,
      input apu_vgpu_img_t surf,
      input logic [1:0] wrote
    );
      logic [31:0] cmd_type, flags, ctx_id, hdr_pad;
      logic [31:0] x, y, z, width, height, depth;
      logic [31:0] rid, level, stride, layer_stride, rw, rh, blen, row_b;
      logic [63:0] fence_id, offset, need, baddr;
      logic bad_flags, hit0, hit1, bvalid, tight, layer_ok, already;
      decode = '0;
      cmd_type = cmd[31:0];
      flags = cmd[63:32];
      fence_id = cmd[127:64];
      ctx_id = cmd[159:128];
      hdr_pad = cmd[191:160];
      x = cmd[223:192];
      y = cmd[255:224];
      z = cmd[287:256];
      width = cmd[319:288];
      height = cmd[351:320];
      depth = cmd[383:352];
      offset = cmd[447:384];
      rid = cmd[479:448];
      level = cmd[511:480];
      stride = cmd[543:512];
      layer_stride = cmd[575:544];
      hit0 = s0.valid && s0.resource_id == rid;
      hit1 = s1.valid && s1.resource_id == rid;
      rw = hit0 ? s0.width : s1.width;
      rh = hit0 ? s0.height : s1.height;
      bvalid = hit0 ? b0.valid : b1.valid;
      baddr = hit0 ? b0.addr : b1.addr;
      blen = hit0 ? b0.length : b1.length;
      already = hit1 ? wrote[1] : wrote[0];
      row_b = rw * 32'd4;
      need = (64'(rw) * 64'(rh)) * 64'd4;
      decode.cpl.ctx_id = ctx_id;
      if (flags[0]) begin
        decode.cpl.flags = VGPU_FLAG_FENCE;
        decode.cpl.fence_id = fence_id;
      end
      bad_flags = |flags[31:1];
      tight = stride == 32'h0 || stride == row_b;
      layer_ok = layer_stride == 32'h0 || layer_stride == row_b * rh;
      if (cmd_type != VGPU_CMD_TRANSFER_FROM_HOST_3D || bad_flags ||
          hdr_pad != 32'h0 || x != 32'h0 || y != 32'h0 || z != 32'h0 ||
          depth != 32'h1 || offset != 64'h0 || level != 32'h0) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (!hit0 && !hit1) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_RESOURCE_ID;
      end else if (hit0 && hit1) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (width != rw || height != rh || !tight || !layer_ok ||
                   !bvalid || (hit0 ? b0.resource_id : b1.resource_id) != rid ||
                   64'(blen) != need || need == 64'h0 || need > APU_VGPU_IMG_BYTES ||
                   !surf.valid || surf.resource_id != rid ||
                   64'(surf.length) != need || baddr == 64'h0 ||
                   baddr[1:0] != 2'b00 || (baddr + 64'(blen)) < baddr) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (already) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_UNSPEC;
      end else begin
        decode.cpl.resp_type = VGPU_RESP_OK_NODATA;
        decode.do_write = 1'b1;
        decode.which = hit1;
        decode.addr = baddr;
        decode.len = blen;
      end
    endfunction

    function automatic logic [31:0] beat_len(
      input logic [31:0] off, input logic [31:0] total
    );
      logic [31:0] remain;
      remain = total - off;
      beat_len = remain > APU_VGPU_BEAT_BYTES ? APU_VGPU_BEAT_BYTES : remain;
    endfunction

    function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] beat_data(
      input logic [31:0] off, input logic [31:0] total
    );
      logic [31:0] n, sum;
      logic [APU_FRAG_ADDR_BITS-1:0] ia;
      beat_data = '0;
      n = beat_len(off, total);
      for (int k = 0; k < APU_VGPU_BEAT_BYTES; k++) begin
        if (32'(k) < n) begin
          sum = off + 32'(k);
          ia = sum[APU_FRAG_ADDR_BITS-1:0];
          beat_data[k*8 +: 8] = img_mem[ia];
        end
      end
    endfunction

    assign wrote_o = wrote_q;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cpl_t'('0);
    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = len_q;
    assign wr_data_o = data_q;
    assign wr_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        hold_q <= '0;
        wrote_q <= '0;
        armed_q <= 1'b0;
        which_q <= 1'b0;
        addr_q <= '0;
        base_q <= '0;
        len_q <= '0;
        off_q <= '0;
        total_q <= '0;
        data_q <= '0;
        img_mem <= '{default: '0};
      end else begin
        if (img_we_i) begin
          img_mem[img_wa_i] <= img_wd_i[7:0];
          img_mem[img_wa_i + APU_FRAG_ADDR_BITS'(1)] <= img_wd_i[15:8];
          img_mem[img_wa_i + APU_FRAG_ADDR_BITS'(2)] <= img_wd_i[23:16];
          img_mem[img_wa_i + APU_FRAG_ADDR_BITS'(3)] <= img_wd_i[31:24];
        end
        unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          dec_t got;
          got = decode(cmd_i, slot0_i, slot1_i, back0_i, back1_i, surf_i, wrote_q);
          if (!got.do_write) begin
            cpl_q <= got.cpl;
            state_q <= Done;
          end else begin
            hold_q <= got.cpl;
            base_q <= got.addr;
            off_q <= '0;
            total_q <= got.len;
            addr_q <= got.addr;
            len_q <= beat_len(32'h0, got.len);
            data_q <= beat_data(32'h0, got.len);
            which_q <= got.which;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          apu_vgpu_cpl_t nxt;
          logic [31:0] next_off;
          nxt = hold_q;
          next_off = off_q + len_q;
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q || wr_rsp_len_i != len_q) begin
            nxt.resp_type = VGPU_RESP_ERR_UNSPEC;
            cpl_q <= nxt;
            state_q <= Done;
          end else if (next_off >= total_q) begin
            nxt.resp_type = VGPU_RESP_OK_NODATA;
            wrote_q[which_q] <= 1'b1;
            cpl_q <= nxt;
            state_q <= Done;
          end else begin
            off_q <= next_off;
            addr_q <= base_q + next_off;
            len_q <= beat_len(next_off, total_q);
            data_q <= beat_data(next_off, total_q);
            state_q <= Issue;
          end
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
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_len_o) && $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(wrote_o));
    `endif
  end
endmodule

// FragReadback (rdb) enable-0 fixture: One guest readback of the fragment surface.
module g6lc_apu_vgpu_rdb_fixture
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
  input  apu_vgpu_img_t surf_i,
  input  logic img_we_i,
  input  logic [APU_FRAG_ADDR_BITS-1:0] img_wa_i,
  input  logic [31:0] img_wd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [575:0] cmd_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output logic [1:0] wrote_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i,
  input  logic [31:0] wr_rsp_len_i
);
  g6lc_apu_vgpu_rdb #(.Enable(Enable)) i_dut (.*);
endmodule
