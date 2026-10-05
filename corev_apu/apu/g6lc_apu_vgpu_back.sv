// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One RESOURCE_ATTACH_BACKING command and its single memory entry.
// The 48-byte little-endian word is the virtio header, resource id,
// nr_entries, and one virtio_gpu_mem_entry. The entry is stored only
// when that resource already exists, nr_entries is 1, and the length
// is width*height*4. A second attach does not replace it. This is not
// g6lc_apu_attach. It does not read guest memory, walk an avail ring,
// or write a used element.

// ResourceBacking (back): One guest backing entry for an existing resource. Default-off. Not a guest-memory read and not a descriptor chain.
module g6lc_apu_vgpu_back
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_res_t slot0_i,
  input  apu_vgpu_res_t slot1_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [383:0] cmd_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output apu_vgpu_back_t back0_o,
  output apu_vgpu_back_t back1_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign back0_o = '0;
    assign back1_o = '0;
    logic unused_cmd;
    assign unused_cmd = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|cmd_i) |
                        (|slot0_i) | (|slot1_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    typedef struct packed {
      apu_vgpu_cpl_t cpl;
      logic write;
      logic which;
      apu_vgpu_back_t back;
    } dec_t;

    state_e state_q;
    apu_vgpu_cpl_t cpl_q;
    apu_vgpu_back_t back_q [0:1];
    logic armed_q;

    function automatic dec_t decode(
      input logic [383:0] cmd,
      input apu_vgpu_res_t s0,
      input apu_vgpu_res_t s1,
      input apu_vgpu_back_t b0,
      input apu_vgpu_back_t b1
    );
      logic [31:0] cmd_type, flags, ctx_id, hdr_pad, rid, nr, length, ent_pad;
      logic [31:0] rw, rh;
      logic [63:0] fence_id, addr, need;
      logic bad_flags, hit0, hit1;
      decode = '0;
      cmd_type = cmd[31:0];
      flags = cmd[63:32];
      fence_id = cmd[127:64];
      ctx_id = cmd[159:128];
      hdr_pad = cmd[191:160];
      rid = cmd[223:192];
      nr = cmd[255:224];
      addr = cmd[319:256];
      length = cmd[351:320];
      ent_pad = cmd[383:352];
      hit0 = s0.valid && s0.resource_id == rid;
      hit1 = s1.valid && s1.resource_id == rid;
      rw = hit0 ? s0.width : s1.width;
      rh = hit0 ? s0.height : s1.height;
      need = (64'(rw) * 64'(rh)) * 64'd4;
      decode.cpl.ctx_id = ctx_id;
      if (flags[0]) begin
        decode.cpl.flags = VGPU_FLAG_FENCE;
        decode.cpl.fence_id = fence_id;
      end
      bad_flags = |flags[31:1];
      if (cmd_type != VGPU_CMD_RESOURCE_ATTACH_BACKING || bad_flags ||
          hdr_pad != 32'h0 || ent_pad != 32'h0 || nr != 32'd1) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (!hit0 && !hit1) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_RESOURCE_ID;
      end else if (hit0 && hit1) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if ((hit0 && b0.valid) || (hit1 && b1.valid)) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_UNSPEC;
      end else if (addr == 64'h0 || addr[1:0] != 2'b0 || length == 32'h0 ||
                   (addr + 64'(length)) < addr || 64'(length) != need) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else begin
        decode.cpl.resp_type = VGPU_RESP_OK_NODATA;
        decode.write = 1'b1;
        decode.which = hit1;
        decode.back.valid = 1'b1;
        decode.back.resource_id = rid;
        decode.back.addr = addr;
        decode.back.length = length;
      end
    endfunction

    assign back0_o = back_q[0];
    assign back1_o = back_q[1];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cpl_t'('0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        back_q[0] <= '0;
        back_q[1] <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          dec_t got;
          got = decode(cmd_i, slot0_i, slot1_i, back_q[0], back_q[1]);
          cpl_q <= got.cpl;
          if (got.write && !got.which) back_q[0] <= got.back;
          else if (got.write && got.which) back_q[1] <= got.back;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(back0_o) && $stable(back1_o));
    `endif
  end
endmodule

// ResourceBacking (back) enable-0 fixture: One guest backing entry for an existing resource.
module g6lc_apu_vgpu_back_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_res_t slot0_i,
  input  apu_vgpu_res_t slot1_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [383:0] cmd_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output apu_vgpu_back_t back0_o,
  output apu_vgpu_back_t back1_o
);
  g6lc_apu_vgpu_back #(.Enable(Enable)) i_dut (.*);
endmodule
