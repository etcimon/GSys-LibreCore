// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Fence 2 OK_NODATA at 64'h880A0000 after the guest WRITE after
// scene guest ack. The scene fence and a missing fence bit
// record nothing. A second store keeps the first. This is later
// than g6lc_apu_vgpu_rol. This is not g6lc_apu_vgpu_qox and not
// g6lc_apu_vgpu_rox. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TransferOkAfterAckCheck (roy): Fence 2 OK_NODATA at 64'h880A0000 after scene guest ack.
module g6lc_apu_vgpu_roy
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rol_t rol_i,
  input  apu_vgpu_rok_t rok_i,
  input  apu_vgpu_rwx_t rwx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_roy_cpl_t cpl_o,
  output apu_vgpu_roy_t roy_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign roy_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rol_i) | (|rok_i) | (|rwx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_roy_cpl_t cpl_q;
    apu_vgpu_roy_t roy_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_roy_cpl_t'('0);
    assign roy_o = roy_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        roy_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (roy_q.valid) begin
            cpl_q.status <= APU_VGPU_ROY_FAULT;
          end else if (!rol_i.valid || !rok_i.valid || !rwx_i.valid) begin
            cpl_q.status <= APU_VGPU_ROY_EMPTY;
          end else if (rol_i.fence != APU_VGPU_RFW_FENCE ||
                       rol_i.fence == APU_VGPU_SCENE_FENCE ||
                       rol_i.flg != VGPU_FLAG_FENCE ||
                       rol_i.resp != VGPU_RESP_OK_NODATA ||
                       rol_i.addr != APU_VGPU_RFW_ADDR ||
                       rol_i.addr == APU_VGPU_RSP_ADDR ||
                       rol_i.fence != rok_i.fence ||
                       rol_i.resp != rok_i.resp ||
                       rwx_i.rsp_addr != APU_VGPU_RFW_ADDR) begin
            cpl_q.status <= APU_VGPU_ROY_FAULT;
          end else begin
            roy_q.valid <= 1'b1;
            roy_q.fence <= rol_i.fence;
            roy_q.resp <= rol_i.resp;
            cpl_q.status <= APU_VGPU_ROY_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(roy_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_ROY_OK |->
        roy_o.valid && roy_o.fence == APU_VGPU_RFW_FENCE &&
        roy_o.resp == VGPU_RESP_OK_NODATA);
    `endif
  end
endmodule

// TransferOkAfterAckCheck (roy) enable-0 fixture: Fence 2 OK_NODATA at 64'h880A0000 after scene guest ack.
module g6lc_apu_vgpu_roy_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rol_t rol_i,
  input  apu_vgpu_rok_t rok_i,
  input  apu_vgpu_rwx_t rwx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_roy_cpl_t cpl_o,
  output apu_vgpu_roy_t roy_o
);
  g6lc_apu_vgpu_roy #(.Enable(Enable)) i_dut (.*);
endmodule
