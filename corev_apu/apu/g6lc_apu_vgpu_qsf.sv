// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Scene descriptor 0 is the header at 64'h8800A000 with NEXT to 1.
// The transfer table and a jump record nothing. A second store
// keeps the first. This is later than g6lc_apu_vgpu_qse. This is
// not g6lc_apu_vgpu_qhx and not g6lc_apu_vgpu_avail. The compiler
// TEX opcode still returns -26. This is not Mesa glReadPixels.

// SceneDesc0Check (qsf): Header at 64'h8800A000 with NEXT to 1.
module g6lc_apu_vgpu_qsf
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qse_t qse_i,
  input  apu_vgpu_qsd_t qsd_i,
  input  apu_vgpu_qsy_t qsy_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsf_cpl_t cpl_o,
  output apu_vgpu_qsf_t qsf_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qsf_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qse_i) | (|qsd_i) | (|qsy_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qsf_cpl_t cpl_q;
    apu_vgpu_qsf_t qsf_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsf_cpl_t'('0);
    assign qsf_o = qsf_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsf_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qsf_q.valid) begin
            cpl_q.status <= APU_VGPU_QSF_FAULT;
          end else if (!qse_i.valid || !qsd_i.valid || !qsy_i.valid) begin
            cpl_q.status <= APU_VGPU_QSF_EMPTY;
          end else if (qse_i.hdr_addr != APU_VGPU_HDR_ADDR ||
                       qse_i.hdr_addr == APU_VGPU_RAB_CMD ||
                       qse_i.hdr_len != APU_VGPU_QSD_LEN ||
                       qse_i.nxt != 16'd1 ||
                       qse_i.nxt == 16'd2 ||
                       qse_i.hdr_addr != qsd_i.hdr_addr ||
                       qse_i.nxt != qsd_i.nxt ||
                       qsy_i.desc_id != APU_VGPU_QRG_DESC ||
                       qsy_i.desc_id == 16'd1) begin
            cpl_q.status <= APU_VGPU_QSF_FAULT;
          end else begin
            qsf_q.valid <= 1'b1;
            qsf_q.hdr_addr <= qse_i.hdr_addr;
            qsf_q.nxt <= qse_i.nxt;
            cpl_q.status <= APU_VGPU_QSF_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qsf_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSF_OK |->
        qsf_o.valid && qsf_o.hdr_addr == APU_VGPU_HDR_ADDR &&
        qsf_o.nxt == 16'd1);
    `endif
  end
endmodule

// SceneDesc0Check (qsf) enable-0 fixture: Header at 64'h8800A000 with NEXT to 1.
module g6lc_apu_vgpu_qsf_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qse_t qse_i,
  input  apu_vgpu_qsd_t qsd_i,
  input  apu_vgpu_qsy_t qsy_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsf_cpl_t cpl_o,
  output apu_vgpu_qsf_t qsf_o
);
  g6lc_apu_vgpu_qsf #(.Enable(Enable)) i_dut (.*);
endmodule
