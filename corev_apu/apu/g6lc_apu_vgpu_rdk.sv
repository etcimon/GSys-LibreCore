// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the two words collected from the ceiling read. The image is
// not here. A second store keeps the first.

// CeilingBeatReadKeep (rdk): The two words collected from that read.
module g6lc_apu_vgpu_rdk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rdr_t rdr_i,
  input  apu_vgpu_rbk_t rbk_i,
  input  apu_vgpu_smx_t smx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rdk_cpl_t cpl_o,
  output apu_vgpu_rdk_t rdk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rdk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rdr_i) | (|rbk_i) | (|smx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rdk_cpl_t cpl_q;
    apu_vgpu_rdk_t rdk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rdk_cpl_t'('0);
    assign rdk_o = rdk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rdk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rdk_q.valid) begin
            cpl_q.status <= APU_VGPU_RDK_FAULT;
          end else if (!rdr_i.valid || !rbk_i.valid || !smx_i.valid) begin
            cpl_q.status <= APU_VGPU_RDK_EMPTY;
          end else if (rdr_i.beats != APU_VGPU_CEIL_BEATS ||
                       rdr_i.word0 != rbk_i.word0 ||
                       rdr_i.at03 != smx_i.word ||
                       rdr_i.word0 == rdr_i.at03) begin
            cpl_q.status <= APU_VGPU_RDK_FAULT;
          end else begin
            rdk_q.valid <= 1'b1;
            rdk_q.word0 <= rdr_i.word0;
            rdk_q.at03 <= rdr_i.at03;
            cpl_q.status <= APU_VGPU_RDK_OK;
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
    `endif
  end
endmodule

// CeilingBeatReadKeep (rdk) enable-0 fixture: The two words collected from that read.
module g6lc_apu_vgpu_rdk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rdr_t rdr_i,
  input  apu_vgpu_rbk_t rbk_i,
  input  apu_vgpu_smx_t smx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rdk_cpl_t cpl_o,
  output apu_vgpu_rdk_t rdk_o
);
  g6lc_apu_vgpu_rdk #(.Enable(Enable)) i_dut (.*);
endmodule
