// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Avail ring[0] names descriptor 0 at 64'h8800E204 after idx 1.
// The transfer ring and a nonzero id record nothing. A second
// store keeps the first. This is later than g6lc_apu_vgpu_srk.
// This is not g6lc_apu_vgpu_qrx and not g6lc_apu_vgpu_avail. The compiler TEX opcode still
// returns -26. This is not Mesa glReadPixels.

// SceneRingAfterNotifyCheck (srx): Descriptor 0 at 64'h8800E204 after notify.
module g6lc_apu_vgpu_srx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_srk_t srk_i,
  input  apu_vgpu_srg_t srg_i,
  input  apu_vgpu_sax_t sax_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_srx_cpl_t cpl_o,
  output apu_vgpu_srx_t srx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign srx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|srk_i) | (|srg_i) | (|sax_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_srx_cpl_t cpl_q;
    apu_vgpu_srx_t srx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_srx_cpl_t'('0);
    assign srx_o = srx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        srx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (srx_q.valid) begin
            cpl_q.status <= APU_VGPU_SRX_FAULT;
          end else if (!srk_i.valid || !srg_i.valid || !sax_i.valid) begin
            cpl_q.status <= APU_VGPU_SRX_EMPTY;
          end else if (srk_i.desc_id != APU_VGPU_QRG_DESC ||
                       srk_i.desc_id == 16'd1 ||
                       srk_i.addr != APU_VGPU_SRG_ADDR ||
                       srk_i.addr == APU_VGPU_QRG_ADDR ||
                       srk_i.addr == APU_VGPU_SAV_ADDR ||
                       srk_i.desc_id != srg_i.desc_id ||
                       sax_i.avail_idx != APU_VGPU_QSU_IDXV ||
                       sax_i.avail_idx == APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_SRX_FAULT;
          end else begin
            srx_q.valid <= 1'b1;
            srx_q.desc_id <= srk_i.desc_id;
            cpl_q.status <= APU_VGPU_SRX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(srx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SRX_OK |->
        srx_o.valid && srx_o.desc_id == APU_VGPU_QRG_DESC);
    `endif
  end
endmodule

// SceneRingAfterNotifyCheck (srx) enable-0 fixture: Descriptor 0 at 64'h8800E204 after notify.
module g6lc_apu_vgpu_srx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_srk_t srk_i,
  input  apu_vgpu_srg_t srg_i,
  input  apu_vgpu_sax_t sax_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_srx_cpl_t cpl_o,
  output apu_vgpu_srx_t srx_o
);
  g6lc_apu_vgpu_srx #(.Enable(Enable)) i_dut (.*);
endmodule
