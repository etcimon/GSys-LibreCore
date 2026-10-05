// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_desc 2: WRITE of the 24-byte response at
// 64'h880A0000 after scene guest ack. The transfer descriptor
// and NEXT record nothing. A second store keeps the first. This
// is later than g6lc_apu_vgpu_rwd. This is not g6lc_apu_vgpu_qwk
// and not g6lc_apu_vgpu_txc. The compiler TEX opcode still
// returns -26. This is not Mesa glReadPixels.

// TransferDesc2AfterAckKeep (rwk): Guest keep of that WRITE descriptor.
module g6lc_apu_vgpu_rwk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rwd_t rwd_i,
  input  apu_vgpu_rfy_t rfy_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rwk_cpl_t cpl_o,
  output apu_vgpu_rwk_t rwk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rwk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rwd_i) | (|rfy_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rwk_cpl_t cpl_q;
    apu_vgpu_rwk_t rwk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rwk_cpl_t'('0);
    assign rwk_o = rwk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rwk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rwk_q.valid) begin
            cpl_q.status <= APU_VGPU_RWK_FAULT;
          end else if (!rwd_i.valid || !rfy_i.valid) begin
            cpl_q.status <= APU_VGPU_RWK_EMPTY;
          end else if (rwd_i.rsp_addr != APU_VGPU_RFW_ADDR ||
                       rwd_i.rsp_addr == APU_VGPU_TFB_CMD ||
                       rwd_i.rsp_len != APU_VGPU_QWD_LEN ||
                       rwd_i.rsp_len == APU_VGPU_TFB_BYTES ||
                       rfy_i.nxt != 16'd2) begin
            cpl_q.status <= APU_VGPU_RWK_FAULT;
          end else begin
            rwk_q.valid <= 1'b1;
            rwk_q.rsp_addr <= rwd_i.rsp_addr;
            rwk_q.rsp_len <= rwd_i.rsp_len;
            cpl_q.status <= APU_VGPU_RWK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rwk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RWK_OK |->
        rwk_o.valid && rwk_o.rsp_addr == APU_VGPU_RFW_ADDR &&
        rwk_o.rsp_len == APU_VGPU_QWD_LEN);
    `endif
  end
endmodule

// TransferDesc2AfterAckKeep (rwk) enable-0 fixture: Guest keep of that WRITE descriptor.
module g6lc_apu_vgpu_rwk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rwd_t rwd_i,
  input  apu_vgpu_rfy_t rfy_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rwk_cpl_t cpl_o,
  output apu_vgpu_rwk_t rwk_o
);
  g6lc_apu_vgpu_rwk #(.Enable(Enable)) i_dut (.*);
endmodule
