// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Scene-fence OK_NODATA at 64'h8800A800 after the guest WRITE.
// Fence 2 and a missing fence bit record nothing. A second store
// keeps the first. This is later than g6lc_apu_vgpu_qsp. This is
// not g6lc_apu_vgpu_qox. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// SceneOkNodataCheck (qsq): Scene fence OK_NODATA at 64'h8800A800.
module g6lc_apu_vgpu_qsq
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qsp_t qsp_i,
  input  apu_vgpu_qso_t qso_i,
  input  apu_vgpu_qru_t qru_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsq_cpl_t cpl_o,
  output apu_vgpu_qsq_t qsq_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qsq_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qsp_i) | (|qso_i) | (|qru_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qsq_cpl_t cpl_q;
    apu_vgpu_qsq_t qsq_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsq_cpl_t'('0);
    assign qsq_o = qsq_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsq_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qsq_q.valid) begin
            cpl_q.status <= APU_VGPU_QSQ_FAULT;
          end else if (!qsp_i.valid || !qso_i.valid || !qru_i.valid) begin
            cpl_q.status <= APU_VGPU_QSQ_EMPTY;
          end else if (qsp_i.fence != APU_VGPU_SCENE_FENCE ||
                       qsp_i.fence == APU_VGPU_RFW_FENCE ||
                       qsp_i.flg != VGPU_FLAG_FENCE ||
                       qsp_i.resp != VGPU_RESP_OK_NODATA ||
                       qsp_i.addr != APU_VGPU_RSP_ADDR ||
                       qsp_i.addr == APU_VGPU_RFW_ADDR ||
                       qsp_i.fence != qso_i.fence ||
                       qsp_i.resp != qso_i.resp ||
                       qru_i.rsp_addr != APU_VGPU_RSP_ADDR) begin
            cpl_q.status <= APU_VGPU_QSQ_FAULT;
          end else begin
            qsq_q.valid <= 1'b1;
            qsq_q.fence <= qsp_i.fence;
            qsq_q.resp <= qsp_i.resp;
            cpl_q.status <= APU_VGPU_QSQ_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qsq_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSQ_OK |->
        qsq_o.valid && qsq_o.fence == APU_VGPU_SCENE_FENCE &&
        qsq_o.resp == VGPU_RESP_OK_NODATA);
    `endif
  end
endmodule

// SceneOkNodataCheck (qsq) enable-0 fixture: Scene fence OK_NODATA at 64'h8800A800.
module g6lc_apu_vgpu_qsq_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qsp_t qsp_i,
  input  apu_vgpu_qso_t qso_i,
  input  apu_vgpu_qru_t qru_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsq_cpl_t cpl_o,
  output apu_vgpu_qsq_t qsq_o
);
  g6lc_apu_vgpu_qsq #(.Enable(Enable)) i_dut (.*);
endmodule
