// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the y = 1 sample at x = 2. The recorded pair at x = 0 and x = 1
// stays put.

// VerticalBeatSample (vbr): The y = 1 sample at x = 2.
module g6lc_apu_vgpu_vbr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vbx_t vbx_i,
  input  apu_vgpu_vlr_t vlr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vbr_cpl_t cpl_o,
  output apu_vgpu_vbr_t vbr_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vbr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|vbx_i) | (|vlr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_vbr_cpl_t cpl_q;
    apu_vgpu_vbr_t vbr_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vbr_cpl_t'('0);
    assign vbr_o = vbr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vbr_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vbr_q.valid) begin
            cpl_q.status <= APU_VGPU_VBR_FAULT;
          end else if (!vbx_i.valid || !vlr_i.valid) begin
            cpl_q.status <= APU_VGPU_VBR_EMPTY;
          end else if (vbx_i.x != 3'd2 || vlr_i.at0 == vlr_i.at1) begin
            cpl_q.status <= APU_VGPU_VBR_FAULT;
          end else begin
            vbr_q.valid <= 1'b1;
            vbr_q.word <= vbx_i.word;
            cpl_q.status <= APU_VGPU_VBR_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_VBR_OK |->
        vbr_o.valid && vbr_o.word == vbx_i.word);
    `endif
  end
endmodule

// VerticalBeatSample (vbr) enable-0 fixture: The y = 1 sample at x = 2.
module g6lc_apu_vgpu_vbr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vbx_t vbx_i,
  input  apu_vgpu_vlr_t vlr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vbr_cpl_t cpl_o,
  output apu_vgpu_vbr_t vbr_o
);
  g6lc_apu_vgpu_vbr #(.Enable(Enable)) i_dut (.*);
endmodule
