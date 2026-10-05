// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Avail index 2 with NEXT accepted after scene guest ack. The
// scene index 1 and the scene table at 64'h8800E100 record
// nothing. A second store keeps the first. This is later than
// g6lc_apu_vgpu_rnk. This is not g6lc_apu_vgpu_tnx and not
// g6lc_apu_vgpu_avail. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TransferNextAfterAckCheck (rnx): Avail index 2 with NEXT after scene guest ack.
module g6lc_apu_vgpu_rnx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rnk_t rnk_i,
  input  apu_vgpu_rnw_t rnw_i,
  input  apu_vgpu_sgx_t sgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnx_cpl_t cpl_o,
  output apu_vgpu_rnx_t rnx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rnx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rnk_i) | (|rnw_i) | (|sgx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rnx_cpl_t cpl_q;
    apu_vgpu_rnx_t rnx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rnx_cpl_t'('0);
    assign rnx_o = rnx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rnx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rnx_q.valid) begin
            cpl_q.status <= APU_VGPU_RNX_FAULT;
          end else if (!rnk_i.valid || !rnw_i.valid || !sgx_i.valid) begin
            cpl_q.status <= APU_VGPU_RNX_EMPTY;
          end else if (rnk_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       rnk_i.avail_idx == 16'd1 ||
                       rnk_i.device_idx != APU_VGPU_TUW_IDXV ||
                       rnk_i.att_addr != APU_VGPU_RAB_CMD ||
                       rnk_i.att_addr == APU_VGPU_NXC_DESC ||
                       rnk_i.att_addr == APU_VGPU_HDR_ADDR ||
                       rnk_i.avail_idx != rnw_i.avail_idx ||
                       sgx_i.used_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_RNX_FAULT;
          end else begin
            rnx_q.valid <= 1'b1;
            rnx_q.avail_idx <= rnk_i.avail_idx;
            rnx_q.device_idx <= rnk_i.device_idx;
            rnx_q.att_addr <= rnk_i.att_addr;
            cpl_q.status <= APU_VGPU_RNX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rnx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RNX_OK |->
        rnx_o.valid && rnx_o.avail_idx == APU_VGPU_TUW_IDXV &&
        rnx_o.att_addr != APU_VGPU_NXC_DESC);
    `endif
  end
endmodule

// TransferNextAfterAckCheck (rnx) enable-0 fixture: Avail index 2 with NEXT after scene guest ack.
module g6lc_apu_vgpu_rnx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rnk_t rnk_i,
  input  apu_vgpu_rnw_t rnw_i,
  input  apu_vgpu_sgx_t sgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnx_cpl_t cpl_o,
  output apu_vgpu_rnx_t rnx_o
);
  g6lc_apu_vgpu_rnx #(.Enable(Enable)) i_dut (.*);
endmodule
