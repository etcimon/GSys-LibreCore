// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the guest ack, the cleared status, and the used index. A second
// store keeps the first. The pin is not kept. The shader is not run.

module g6lc_apu_vgpu_vak
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_var_t var_i,
  input  apu_vgpu_vaw_t vaw_i,
  input  apu_vgpu_vik_t vik_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vak_cpl_t cpl_o,
  output apu_vgpu_vak_t vak_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vak_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|var_i) | (|vaw_i) | (|vik_i) | (|gpk_i) | (|ols_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_vak_cpl_t cpl_q;
    apu_vgpu_vak_t vak_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vak_cpl_t'('0);
    assign vak_o = vak_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vak_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vak_q.valid) begin
            cpl_q.status <= APU_VGPU_VAK_FAULT;
          end else if (!var_i.valid || !vaw_i.valid || !vik_i.valid ||
                       !gpk_i.valid || !ols_i.valid) begin
            cpl_q.status <= APU_VGPU_VAK_EMPTY;
          end else if (var_i.ack != vaw_i.ack || var_i.remain != vaw_i.remain ||
                       var_i.used_idx != vaw_i.used_idx ||
                       var_i.ack != APU_VGPU_VIW_REASON ||
                       var_i.remain != APU_VGPU_VAW_CLEAR ||
                       var_i.ack == var_i.remain ||
                       var_i.used_idx != 16'd1 ||
                       var_i.used_idx != vik_i.used_idx ||
                       vik_i.reason != APU_VGPU_VIW_REASON ||
                       gpk_i.word != APU_VGPU_CLEAR_WORD ||
                       gpk_i.last != APU_VGPU_GPW_TAIL ||
                       ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       ols_i.resp != VGPU_RESP_OK_NODATA) begin
            cpl_q.status <= APU_VGPU_VAK_FAULT;
          end else begin
            vak_q.valid <= 1'b1;
            vak_q.ack <= var_i.ack;
            vak_q.remain <= var_i.remain;
            vak_q.used_idx <= var_i.used_idx;
            cpl_q.status <= APU_VGPU_VAK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vak_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_vak_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_var_t var_i,
  input  apu_vgpu_vaw_t vaw_i,
  input  apu_vgpu_vik_t vik_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vak_cpl_t cpl_o,
  output apu_vgpu_vak_t vak_o
);
  g6lc_apu_vgpu_vak #(.Enable(Enable)) i_dut (.*);
endmodule
