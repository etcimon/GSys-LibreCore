// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_desc 0: attach at 64'h88090000, length 64, NEXT to
// 1 after scene guest ack. The scene table and a jump record
// nothing. A second store keeps the first. This is later than
// g6lc_apu_vgpu_rhd. This is not g6lc_apu_vgpu_qhk and not
// g6lc_apu_vgpu_txc. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TransferDesc0AfterAckKeep (rhk): Guest keep of that attach descriptor.
module g6lc_apu_vgpu_rhk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rhd_t rhd_i,
  input  apu_vgpu_rrx_t rrx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rhk_cpl_t cpl_o,
  output apu_vgpu_rhk_t rhk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rhk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rhd_i) | (|rrx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rhk_cpl_t cpl_q;
    apu_vgpu_rhk_t rhk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rhk_cpl_t'('0);
    assign rhk_o = rhk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rhk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rhk_q.valid) begin
            cpl_q.status <= APU_VGPU_RHK_FAULT;
          end else if (!rhd_i.valid || !rrx_i.valid) begin
            cpl_q.status <= APU_VGPU_RHK_EMPTY;
          end else if (rhd_i.att_addr != APU_VGPU_RAB_CMD ||
                       rhd_i.att_addr == APU_VGPU_NXC_DESC ||
                       rhd_i.att_len != APU_VGPU_RAB_BYTES ||
                       rhd_i.att_len == APU_VGPU_TFB_BYTES ||
                       rhd_i.nxt != 16'd1 ||
                       rhd_i.nxt == 16'd2 ||
                       rrx_i.desc_id != APU_VGPU_QRG_DESC) begin
            cpl_q.status <= APU_VGPU_RHK_FAULT;
          end else begin
            rhk_q.valid <= 1'b1;
            rhk_q.att_addr <= rhd_i.att_addr;
            rhk_q.att_len <= rhd_i.att_len;
            rhk_q.nxt <= rhd_i.nxt;
            cpl_q.status <= APU_VGPU_RHK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rhk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RHK_OK |->
        rhk_o.valid && rhk_o.att_addr == APU_VGPU_RAB_CMD &&
        rhk_o.nxt == 16'd1);
    `endif
  end
endmodule

// TransferDesc0AfterAckKeep (rhk) enable-0 fixture: Guest keep of that attach descriptor.
module g6lc_apu_vgpu_rhk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rhd_t rhd_i,
  input  apu_vgpu_rrx_t rrx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rhk_cpl_t cpl_o,
  output apu_vgpu_rhk_t rhk_o
);
  g6lc_apu_vgpu_rhk #(.Enable(Enable)) i_dut (.*);
endmodule
