// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One virtio-gpu control payload. The low 32 bits are the little-endian
// command type. RESOURCE_CREATE_2D records a resource when the format is
// R8G8B8A8, the id is nonzero, and width/height fit the local 4x2 image.
// VIRTIO_GPU_FLAG_FENCE echoes fence_id on the response, including errors.
// Unknown commands, including SUBMIT_3D, do not create a resource.
// Enable=0 keeps no table. This does not walk an avail ring and does not
// raise an interrupt.

// CmdPayloadDecode (proto): Virtio-gpu command payload decode. Default-off. Not a virtqueue walk.
// Interplay: CmdPayloadDecode (proto) on the virtio command header. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_cmd
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [319:0] cmd_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output apu_vgpu_res_t slot0_o,
  output apu_vgpu_res_t slot1_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign slot0_o = '0;
    assign slot1_o = '0;
    logic unused_cmd;
    assign unused_cmd = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|cmd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    typedef struct packed {
      apu_vgpu_cpl_t cpl;
      logic write;
      logic which;
      apu_vgpu_res_t slot;
    } dec_t;

    state_e state_q;
    apu_vgpu_cpl_t cpl_q;
    apu_vgpu_res_t slot_q [0:1];
    logic armed_q;

    function automatic dec_t decode(
      input logic [319:0] cmd,
      input apu_vgpu_res_t s0,
      input apu_vgpu_res_t s1
    );
      logic [31:0] cmd_type, flags, ctx_id, pad, rid, fmt, width, height;
      logic [63:0] fence_id;
      logic bad_flags;
      decode = '0;
      cmd_type = cmd[31:0];
      flags = cmd[63:32];
      fence_id = cmd[127:64];
      ctx_id = cmd[159:128];
      pad = cmd[191:160];
      rid = cmd[223:192];
      fmt = cmd[255:224];
      width = cmd[287:256];
      height = cmd[319:288];
      decode.cpl.ctx_id = ctx_id;
      if (flags[0]) begin
        decode.cpl.flags = VGPU_FLAG_FENCE;
        decode.cpl.fence_id = fence_id;
      end
      bad_flags = |flags[31:1];
      if (cmd_type != VGPU_CMD_RESOURCE_CREATE_2D || bad_flags || pad != 32'h0 ||
          fmt != VGPU_FORMAT_R8G8B8A8_UNORM || width == 0 || height == 0 ||
          width > APU_FRAG_MAX_W || height > APU_FRAG_MAX_H) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (rid == 32'h0) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_RESOURCE_ID;
      end else if ((s0.valid && s0.resource_id == rid) ||
                   (s1.valid && s1.resource_id == rid)) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_INVALID_PARAMETER;
      end else if (s0.valid && s1.valid) begin
        decode.cpl.resp_type = VGPU_RESP_ERR_OUT_OF_MEMORY;
      end else begin
        decode.cpl.resp_type = VGPU_RESP_OK_NODATA;
        decode.cpl.resource_id = rid;
        decode.cpl.format = fmt;
        decode.cpl.width = width;
        decode.cpl.height = height;
        decode.write = 1'b1;
        decode.which = s0.valid;
        decode.slot.valid = 1'b1;
        decode.slot.resource_id = rid;
        decode.slot.format = fmt;
        decode.slot.width = width;
        decode.slot.height = height;
      end
    endfunction

    assign slot0_o = slot_q[0];
    assign slot1_o = slot_q[1];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cpl_t'('0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        slot_q[0] <= '0;
        slot_q[1] <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          dec_t got;
          got = decode(cmd_i, slot_q[0], slot_q[1]);
          cpl_q <= got.cpl;
          if (got.write && !got.which) slot_q[0] <= got.slot;
          else if (got.write && got.which) slot_q[1] <= got.slot;
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
      cpl_valid_o && cpl_o.resp_type != VGPU_RESP_OK_NODATA |->
      cpl_o.resource_id == 32'h0);
    `endif
  end
endmodule

// CmdPayloadDecode (proto) enable-0 fixture: Virtio-gpu command payload decode. Default-off. Not a virtqueue walk.
module g6lc_apu_vgpu_cmd_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [319:0] cmd_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cpl_t cpl_o,
  output apu_vgpu_res_t slot0_o,
  output apu_vgpu_res_t slot1_o
);
  g6lc_apu_vgpu_cmd #(.Enable(Enable)) i_dut (.*);
endmodule
