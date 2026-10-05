// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_desc 0: header at 64'h8800A000, length 32, NEXT to
// 1. The transfer table and a jump record nothing. A second
// store keeps the first. This is later than g6lc_apu_vgpu_shd.
// This is not g6lc_apu_vgpu_qhk and not g6lc_apu_vgpu_qsd. The
// compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// SceneHeaderAfterNotifyKeep (shk): Guest keep of that scene header descriptor.
module g6lc_apu_vgpu_shk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_shd_t shd_i,
  input  apu_vgpu_srx_t srx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_shk_cpl_t cpl_o,
  output apu_vgpu_shk_t shk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign shk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|shd_i) | (|srx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_shk_cpl_t cpl_q;
    apu_vgpu_shk_t shk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_shk_cpl_t'('0);
    assign shk_o = shk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        shk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (shk_q.valid) begin
            cpl_q.status <= APU_VGPU_SHK_FAULT;
          end else if (!shd_i.valid || !srx_i.valid) begin
            cpl_q.status <= APU_VGPU_SHK_EMPTY;
          end else if (shd_i.hdr_addr != APU_VGPU_HDR_ADDR ||
                       shd_i.hdr_addr == APU_VGPU_RAB_CMD ||
                       shd_i.hdr_len != APU_VGPU_QSD_LEN ||
                       shd_i.hdr_len == APU_VGPU_RAB_BYTES ||
                       shd_i.nxt != 16'd1 ||
                       shd_i.nxt == 16'd2 ||
                       srx_i.desc_id != APU_VGPU_QRG_DESC) begin
            cpl_q.status <= APU_VGPU_SHK_FAULT;
          end else begin
            shk_q.valid <= 1'b1;
            shk_q.hdr_addr <= shd_i.hdr_addr;
            shk_q.hdr_len <= shd_i.hdr_len;
            shk_q.nxt <= shd_i.nxt;
            cpl_q.status <= APU_VGPU_SHK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(shk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SHK_OK |->
        shk_o.valid && shk_o.hdr_addr == APU_VGPU_HDR_ADDR &&
        shk_o.nxt == 16'd1);
    `endif
  end
endmodule

// SceneHeaderAfterNotifyKeep (shk) enable-0 fixture: Guest keep of that scene header descriptor.
module g6lc_apu_vgpu_shk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_shd_t shd_i,
  input  apu_vgpu_srx_t srx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_shk_cpl_t cpl_o,
  output apu_vgpu_shk_t shk_o
);
  g6lc_apu_vgpu_shk #(.Enable(Enable)) i_dut (.*);
endmodule
