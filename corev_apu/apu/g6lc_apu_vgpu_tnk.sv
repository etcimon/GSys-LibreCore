// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the walked transfer chain. Avail index 2. The scene index 1
// and the scene table record nothing. A second store keeps the
// first. This is later than g6lc_apu_vgpu_tnw. This is not
// g6lc_apu_vgpu_chn. g6lc_apu_vgpu_avail still rejects NEXT. The
// compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// TransferNextKeep (tnk): Keep that walked chain.
module g6lc_apu_vgpu_tnk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tnw_t tnw_i,
  input  apu_vgpu_txx_t txx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tnk_cpl_t cpl_o,
  output apu_vgpu_tnk_t tnk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tnk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tnw_i) | (|txx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tnk_cpl_t cpl_q;
    apu_vgpu_tnk_t tnk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tnk_cpl_t'('0);
    assign tnk_o = tnk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tnk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tnk_q.valid) begin
            cpl_q.status <= APU_VGPU_TNK_FAULT;
          end else if (!tnw_i.valid || !txx_i.valid) begin
            cpl_q.status <= APU_VGPU_TNK_EMPTY;
          end else if (tnw_i.head != 16'd0 ||
                       tnw_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       tnw_i.avail_idx == 16'd1 ||
                       tnw_i.device_idx != APU_VGPU_TUW_IDXV ||
                       tnw_i.att_addr != APU_VGPU_RAB_CMD ||
                       tnw_i.att_addr == APU_VGPU_NXC_DESC ||
                       tnw_i.xfer_addr != APU_VGPU_TFB_CMD ||
                       tnw_i.rsp_addr != APU_VGPU_RFW_ADDR ||
                       tnw_i.avail_idx != txx_i.avail_idx) begin
            cpl_q.status <= APU_VGPU_TNK_FAULT;
          end else begin
            tnk_q.valid <= 1'b1;
            tnk_q.head <= tnw_i.head;
            tnk_q.avail_idx <= tnw_i.avail_idx;
            tnk_q.device_idx <= tnw_i.device_idx;
            tnk_q.att_addr <= tnw_i.att_addr;
            tnk_q.xfer_addr <= tnw_i.xfer_addr;
            tnk_q.rsp_addr <= tnw_i.rsp_addr;
            cpl_q.status <= APU_VGPU_TNK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tnk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TNK_OK |->
        tnk_o.valid && tnk_o.avail_idx == APU_VGPU_TUW_IDXV &&
        tnk_o.att_addr != APU_VGPU_NXC_DESC);
    `endif
  end
endmodule

// TransferNextKeep (tnk) enable-0 fixture: Keep that walked chain.
module g6lc_apu_vgpu_tnk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tnw_t tnw_i,
  input  apu_vgpu_txx_t txx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tnk_cpl_t cpl_o,
  output apu_vgpu_tnk_t tnk_o
);
  g6lc_apu_vgpu_tnk #(.Enable(Enable)) i_dut (.*);
endmodule
