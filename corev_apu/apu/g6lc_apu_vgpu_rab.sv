// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// RESOURCE_ATTACH_BACKING of the 64 by 64 readpixels buffer at
// 64'h88070000. Length is 16384. A 1,228,800-byte attach records
// nothing. This is later than g6lc_apu_vgpu_tfx. This is not
// g6lc_apu_vgpu_back and not g6lc_apu_attach. The image is not
// kept. TEX is not the compiler opcode. This is not Mesa
// glReadPixels.

// TransferAttach (rab): RESOURCE_ATTACH_BACKING of the 64 by 64 readpixels buffer.
module g6lc_apu_vgpu_rab
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tfx_t tfx_i,
  input  apu_vgpu_rpw_t rpw_i,
  input  apu_vgpu_grd_t grd_i,
  input  apu_vgpu_c3d_t c3d_i,
  input  logic [63:0] want_addr_i,
  input  logic [31:0] want_len_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rab_cpl_t cpl_o,
  output apu_vgpu_rab_t rab_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rab_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tfx_i) | (|rpw_i) | (|grd_i) | (|c3d_i) |
                        (|want_addr_i) | (|want_len_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rab_cpl_t cpl_q;
    apu_vgpu_rab_t rab_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rab_cpl_t'('0);
    assign rab_o = rab_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rab_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rab_q.valid) begin
            cpl_q.status <= APU_VGPU_RAB_FAULT;
          end else if (!tfx_i.valid || !rpw_i.valid || !grd_i.valid ||
                       !c3d_i.rt_valid) begin
            cpl_q.status <= APU_VGPU_RAB_EMPTY;
          end else if (tfx_i.stride != APU_VGPU_TFB_STRIDE ||
                       tfx_i.x != 16'd0 || tfx_i.res_w != APU_VGPU_RT_W ||
                       rpw_i.dst != APU_VGPU_RPW_DST ||
                       rpw_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                       rpw_i.resource_id != APU_VIRGL_RES_RT ||
                       grd_i.base != APU_VGPU_RPW_DST ||
                       grd_i.bytes != APU_VGPU_GBD_BYTES ||
                       c3d_i.rt_w != APU_VGPU_RT_W ||
                       c3d_i.rt_h != APU_VGPU_RT_H ||
                       want_addr_i != APU_VGPU_RPW_DST ||
                       want_addr_i == APU_VGPU_CSW_DST ||
                       want_len_i != APU_VGPU_GBD_BYTES ||
                       want_len_i == APU_VGPU_SCAN_BYTES) begin
            cpl_q.status <= APU_VGPU_RAB_FAULT;
          end else begin
            rab_q.valid <= 1'b1;
            rab_q.addr <= APU_VGPU_RPW_DST;
            rab_q.length <= APU_VGPU_GBD_BYTES;
            rab_q.resource_id <= APU_VIRGL_RES_RT;
            rab_q.cmd <= VGPU_CMD_RESOURCE_ATTACH_BACKING;
            cpl_q.status <= APU_VGPU_RAB_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rab_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RAB_OK |->
        rab_o.valid && rab_o.addr == APU_VGPU_RPW_DST &&
        rab_o.length == APU_VGPU_GBD_BYTES &&
        rab_o.cmd == VGPU_CMD_RESOURCE_ATTACH_BACKING);
    `endif
  end
endmodule

// TransferAttach (rab) enable-0 fixture: RESOURCE_ATTACH_BACKING of the 64 by 64 readpixels buffer.
module g6lc_apu_vgpu_rab_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tfx_t tfx_i,
  input  apu_vgpu_rpw_t rpw_i,
  input  apu_vgpu_grd_t grd_i,
  input  apu_vgpu_c3d_t c3d_i,
  input  logic [63:0] want_addr_i,
  input  logic [31:0] want_len_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rab_cpl_t cpl_o,
  output apu_vgpu_rab_t rab_o
);
  g6lc_apu_vgpu_rab #(.Enable(Enable)) i_dut (.*);
endmodule
