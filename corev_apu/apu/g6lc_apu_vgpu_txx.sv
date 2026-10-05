// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Avail index 2 with attach at 64'h88090000. The scene table at
// 64'h8800E100 and index 1 record nothing. This is later than
// g6lc_apu_vgpu_txk. This is not g6lc_apu_vgpu_nxc. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// TransferChainCheck (txx): Avail index 2, not the scene index 1.
module g6lc_apu_vgpu_txx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_txk_t txk_i,
  input  apu_vgpu_txc_t txc_i,
  input  apu_vgpu_tax_t tax_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_txx_cpl_t cpl_o,
  output apu_vgpu_txx_t txx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign txx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|txk_i) | (|txc_i) | (|tax_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_txx_cpl_t cpl_q;
    apu_vgpu_txx_t txx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_txx_cpl_t'('0);
    assign txx_o = txx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        txx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (txx_q.valid) begin
            cpl_q.status <= APU_VGPU_TXX_FAULT;
          end else if (!txk_i.valid || !txc_i.valid || !tax_i.valid) begin
            cpl_q.status <= APU_VGPU_TXX_EMPTY;
          end else if (txk_i.head != 16'd0 ||
                       txk_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       txk_i.avail_idx == 16'd1 ||
                       txk_i.att_addr != APU_VGPU_RAB_CMD ||
                       txk_i.att_addr == APU_VGPU_NXC_DESC ||
                       txk_i.xfer_addr != APU_VGPU_TFB_CMD ||
                       txk_i.rsp_addr != APU_VGPU_RFW_ADDR ||
                       txk_i.head == txk_i.avail_idx ||
                       txk_i.avail_idx != txc_i.avail_idx ||
                       tax_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_TXX_FAULT;
          end else begin
            txx_q.valid <= 1'b1;
            txx_q.head <= txk_i.head;
            txx_q.avail_idx <= txk_i.avail_idx;
            txx_q.att_addr <= txk_i.att_addr;
            cpl_q.status <= APU_VGPU_TXX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(txx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TXX_OK |->
        txx_o.valid && txx_o.avail_idx == APU_VGPU_TUW_IDXV &&
        txx_o.att_addr != APU_VGPU_NXC_DESC);
    `endif
  end
endmodule

// TransferChainCheck (txx) enable-0 fixture: Avail index 2, not the scene index 1.
module g6lc_apu_vgpu_txx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_txk_t txk_i,
  input  apu_vgpu_txc_t txc_i,
  input  apu_vgpu_tax_t tax_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_txx_cpl_t cpl_o,
  output apu_vgpu_txx_t txx_o
);
  g6lc_apu_vgpu_txx #(.Enable(Enable)) i_dut (.*);
endmodule
