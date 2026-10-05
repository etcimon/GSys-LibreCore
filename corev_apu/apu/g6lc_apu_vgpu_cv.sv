// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The checked NDC square, mapped by viewport scales 320 and 240, covers
// 0..640 by 0..480. The 64 by 64 ceiling is inside that rectangle, so
// every one of its 4096 samples is covered. The stored color stays the
// clear word. The fragment shader is not run. This is not g6lc_apu_cover.

// QuadCoverage (cv): That strip covers the ceiling. Default-off. The color stays the clear.
module g6lc_apu_vgpu_cv
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qd_t qd_i,
  input  apu_vgpu_vp_t vp_i,
  input  apu_vgpu_fil_t fil_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cv_cpl_t cpl_o,
  output apu_vgpu_cv_t cv_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cv_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qd_i) | (|vp_i) | (|fil_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_cv_cpl_t cpl_q;
    apu_vgpu_cv_t cv_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cv_cpl_t'('0);
    assign cv_o = cv_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cv_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic map_ok;
          map_ok = vp_i.scale_x == APU_VIRGL_F32_HALF_W &&
                   vp_i.scale_y == APU_VIRGL_F32_HALF_H &&
                   fil_i.word == APU_VGPU_CLEAR_WORD &&
                   fil_i.samples == APU_VGPU_FILL_N;
          if (cv_q.valid) begin
            cpl_q.status <= APU_VGPU_CV_FAULT;
          end else if (!qd_i.valid || !vp_i.valid || !fil_i.valid) begin
            cpl_q.status <= APU_VGPU_CV_EMPTY;
          end else if (!map_ok) begin
            cpl_q.status <= APU_VGPU_CV_FAULT;
          end else begin
            cv_q.valid <= 1'b1;
            cv_q.covered <= 1'b1;
            cv_q.word <= fil_i.word;
            cv_q.samples <= fil_i.samples;
            cpl_q.status <= APU_VGPU_CV_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cv_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CV_OK |->
        cv_o.valid && cv_o.covered && cv_o.word == APU_VGPU_CLEAR_WORD &&
        cv_o.samples == APU_VGPU_FILL_N);
    `endif
  end
endmodule

// QuadCoverage (cv) enable-0 fixture: That strip covers the ceiling. Default-off. The color stays the clear.
module g6lc_apu_vgpu_cv_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qd_t qd_i,
  input  apu_vgpu_vp_t vp_i,
  input  apu_vgpu_fil_t fil_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cv_cpl_t cpl_o,
  output apu_vgpu_cv_t cv_o
);
  g6lc_apu_vgpu_cv #(.Enable(Enable)) i_dut (.*);
endmodule
