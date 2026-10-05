// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the walked transfer chain after scene guest ack. Avail
// index 2. The scene index 1 and the scene table record nothing.
// A second store keeps the first. This is later than
// g6lc_apu_vgpu_rnw. This is not g6lc_apu_vgpu_tnk and not
// g6lc_apu_vgpu_chn. g6lc_apu_vgpu_avail still rejects NEXT. The
// compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// TransferNextAfterAckKeep (rnk): Guest keep of that walked transfer chain.
module g6lc_apu_vgpu_rnk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rnw_t rnw_i,
  input  apu_vgpu_sgx_t sgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnk_cpl_t cpl_o,
  output apu_vgpu_rnk_t rnk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rnk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rnw_i) | (|sgx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rnk_cpl_t cpl_q;
    apu_vgpu_rnk_t rnk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rnk_cpl_t'('0);
    assign rnk_o = rnk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rnk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rnk_q.valid) begin
            cpl_q.status <= APU_VGPU_RNK_FAULT;
          end else if (!rnw_i.valid || !sgx_i.valid) begin
            cpl_q.status <= APU_VGPU_RNK_EMPTY;
          end else if (rnw_i.head != 16'd0 ||
                       rnw_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       rnw_i.avail_idx == 16'd1 ||
                       rnw_i.device_idx != APU_VGPU_TUW_IDXV ||
                       rnw_i.att_addr != APU_VGPU_RAB_CMD ||
                       rnw_i.att_addr == APU_VGPU_NXC_DESC ||
                       rnw_i.xfer_addr != APU_VGPU_TFB_CMD ||
                       rnw_i.rsp_addr != APU_VGPU_RFW_ADDR ||
                       sgx_i.used_idx != APU_VGPU_QSU_IDXV ||
                       sgx_i.ack != APU_VGPU_QSI_REASON) begin
            cpl_q.status <= APU_VGPU_RNK_FAULT;
          end else begin
            rnk_q.valid <= 1'b1;
            rnk_q.head <= rnw_i.head;
            rnk_q.avail_idx <= rnw_i.avail_idx;
            rnk_q.device_idx <= rnw_i.device_idx;
            rnk_q.att_addr <= rnw_i.att_addr;
            rnk_q.xfer_addr <= rnw_i.xfer_addr;
            rnk_q.rsp_addr <= rnw_i.rsp_addr;
            cpl_q.status <= APU_VGPU_RNK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rnk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RNK_OK |->
        rnk_o.valid && rnk_o.avail_idx == APU_VGPU_TUW_IDXV &&
        rnk_o.att_addr != APU_VGPU_NXC_DESC);
    `endif
  end
endmodule

// TransferNextAfterAckKeep (rnk) enable-0 fixture: Guest keep of that walked transfer chain.
module g6lc_apu_vgpu_rnk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rnw_t rnw_i,
  input  apu_vgpu_sgx_t sgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnk_cpl_t cpl_o,
  output apu_vgpu_rnk_t rnk_o
);
  g6lc_apu_vgpu_rnk #(.Enable(Enable)) i_dut (.*);
endmodule
