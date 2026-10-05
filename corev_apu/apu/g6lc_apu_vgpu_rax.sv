// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Length of the readpixels backing is 16384. The 640 by 480
// backing is 1,228,800 and records nothing. This is later than
// g6lc_apu_vgpu_rar. This is not g6lc_apu_vgpu_back. TEX is not
// the compiler opcode. This is not Mesa glReadPixels.

// TransferAttachCheck (rax): Length 16384, not the 640 by 480 backing.
module g6lc_apu_vgpu_rax
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rar_t rar_i,
  input  apu_vgpu_rab_t rab_i,
  input  apu_vgpu_tfx_t tfx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rax_cpl_t cpl_o,
  output apu_vgpu_rax_t rax_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rax_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rar_i) | (|rab_i) | (|tfx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rax_cpl_t cpl_q;
    apu_vgpu_rax_t rax_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rax_cpl_t'('0);
    assign rax_o = rax_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rax_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rax_q.valid) begin
            cpl_q.status <= APU_VGPU_RAX_FAULT;
          end else if (!rar_i.valid || !rab_i.valid || !tfx_i.valid) begin
            cpl_q.status <= APU_VGPU_RAX_EMPTY;
          end else if (rar_i.addr != APU_VGPU_RPW_DST ||
                       rar_i.addr == APU_VGPU_CSW_DST ||
                       rar_i.length != APU_VGPU_GBD_BYTES ||
                       rar_i.length == APU_VGPU_SCAN_BYTES ||
                       rar_i.cmd != VGPU_CMD_RESOURCE_ATTACH_BACKING ||
                       rar_i.resource_id != APU_VIRGL_RES_RT ||
                       rar_i.cmd_addr != APU_VGPU_RAB_CMD ||
                       rab_i.length != rar_i.length ||
                       tfx_i.stride != APU_VGPU_TFB_STRIDE) begin
            cpl_q.status <= APU_VGPU_RAX_FAULT;
          end else begin
            rax_q.valid <= 1'b1;
            rax_q.length <= rar_i.length;
            rax_q.addr <= rar_i.addr;
            rax_q.resource_id <= rar_i.resource_id;
            cpl_q.status <= APU_VGPU_RAX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rax_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RAX_OK |->
        rax_o.valid && rax_o.length == APU_VGPU_GBD_BYTES &&
        rax_o.addr == APU_VGPU_RPW_DST);
    `endif
  end
endmodule

// TransferAttachCheck (rax) enable-0 fixture: Length 16384, not the 640 by 480 backing.
module g6lc_apu_vgpu_rax_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rar_t rar_i,
  input  apu_vgpu_rab_t rab_i,
  input  apu_vgpu_tfx_t tfx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rax_cpl_t cpl_o,
  output apu_vgpu_rax_t rax_o
);
  g6lc_apu_vgpu_rax #(.Enable(Enable)) i_dut (.*);
endmodule
