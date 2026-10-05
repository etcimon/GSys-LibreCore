// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_desc 1: transfer at 64'h88080000, length 96, NEXT
// to 2 after scene guest ack. The attach descriptor and a jump
// record nothing. A second store keeps the first. This is later
// than g6lc_apu_vgpu_rfd. This is not g6lc_apu_vgpu_qfk and not
// g6lc_apu_vgpu_txc. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TransferDesc1AfterAckKeep (rfk): Guest keep of that transfer descriptor.
module g6lc_apu_vgpu_rfk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rfd_t rfd_i,
  input  apu_vgpu_rhx_t rhx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rfk_cpl_t cpl_o,
  output apu_vgpu_rfk_t rfk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rfk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rfd_i) | (|rhx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rfk_cpl_t cpl_q;
    apu_vgpu_rfk_t rfk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rfk_cpl_t'('0);
    assign rfk_o = rfk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rfk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rfk_q.valid) begin
            cpl_q.status <= APU_VGPU_RFK_FAULT;
          end else if (!rfd_i.valid || !rhx_i.valid) begin
            cpl_q.status <= APU_VGPU_RFK_EMPTY;
          end else if (rfd_i.xfer_addr != APU_VGPU_TFB_CMD ||
                       rfd_i.xfer_addr == APU_VGPU_RAB_CMD ||
                       rfd_i.xfer_len != APU_VGPU_TFB_BYTES ||
                       rfd_i.xfer_len == APU_VGPU_RAB_BYTES ||
                       rfd_i.nxt != 16'd2 ||
                       rfd_i.nxt == 16'd1 ||
                       rhx_i.nxt != 16'd1) begin
            cpl_q.status <= APU_VGPU_RFK_FAULT;
          end else begin
            rfk_q.valid <= 1'b1;
            rfk_q.xfer_addr <= rfd_i.xfer_addr;
            rfk_q.xfer_len <= rfd_i.xfer_len;
            rfk_q.nxt <= rfd_i.nxt;
            cpl_q.status <= APU_VGPU_RFK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rfk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RFK_OK |->
        rfk_o.valid && rfk_o.xfer_addr == APU_VGPU_TFB_CMD &&
        rfk_o.nxt == 16'd2);
    `endif
  end
endmodule

// TransferDesc1AfterAckKeep (rfk) enable-0 fixture: Guest keep of that transfer descriptor.
module g6lc_apu_vgpu_rfk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rfd_t rfd_i,
  input  apu_vgpu_rhx_t rhx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rfk_cpl_t cpl_o,
  output apu_vgpu_rfk_t rfk_o
);
  g6lc_apu_vgpu_rfk #(.Enable(Enable)) i_dut (.*);
endmodule
