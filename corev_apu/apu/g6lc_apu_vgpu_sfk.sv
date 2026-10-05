// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_desc 1: execbuffer at 64'h8800B000, length 960,
// NEXT to 2. The header descriptor and a jump record nothing.
// A second store keeps the first. This is later than
// g6lc_apu_vgpu_sfd. This is not g6lc_apu_vgpu_qfk and not
// g6lc_apu_vgpu_qed. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneExecAfterNotifyKeep (sfk): Guest keep of that scene execbuffer descriptor.
module g6lc_apu_vgpu_sfk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sfd_t sfd_i,
  input  apu_vgpu_shx_t shx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sfk_cpl_t cpl_o,
  output apu_vgpu_sfk_t sfk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sfk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|sfd_i) | (|shx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_sfk_cpl_t cpl_q;
    apu_vgpu_sfk_t sfk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sfk_cpl_t'('0);
    assign sfk_o = sfk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sfk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sfk_q.valid) begin
            cpl_q.status <= APU_VGPU_SFK_FAULT;
          end else if (!sfd_i.valid || !shx_i.valid) begin
            cpl_q.status <= APU_VGPU_SFK_EMPTY;
          end else if (sfd_i.exec_addr != APU_VGPU_EXEC_ADDR ||
                       sfd_i.exec_addr == APU_VGPU_HDR_ADDR ||
                       sfd_i.exec_len != APU_VGPU_SCENE_BYTES ||
                       sfd_i.exec_len == APU_VGPU_TFB_BYTES ||
                       sfd_i.nxt != 16'd2 ||
                       sfd_i.nxt == 16'd1 ||
                       shx_i.nxt != 16'd1) begin
            cpl_q.status <= APU_VGPU_SFK_FAULT;
          end else begin
            sfk_q.valid <= 1'b1;
            sfk_q.exec_addr <= sfd_i.exec_addr;
            sfk_q.exec_len <= sfd_i.exec_len;
            sfk_q.nxt <= sfd_i.nxt;
            cpl_q.status <= APU_VGPU_SFK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sfk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SFK_OK |->
        sfk_o.valid && sfk_o.exec_addr == APU_VGPU_EXEC_ADDR &&
        sfk_o.nxt == 16'd2);
    `endif
  end
endmodule

// SceneExecAfterNotifyKeep (sfk) enable-0 fixture: Guest keep of that scene execbuffer descriptor.
module g6lc_apu_vgpu_sfk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sfd_t sfd_i,
  input  apu_vgpu_shx_t shx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sfk_cpl_t cpl_o,
  output apu_vgpu_sfk_t sfk_o
);
  g6lc_apu_vgpu_sfk #(.Enable(Enable)) i_dut (.*);
endmodule
