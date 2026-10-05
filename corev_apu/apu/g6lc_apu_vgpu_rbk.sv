// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the ceiling readback record. The image stays in the written
// beats, not here. A second store keeps the first.

// CeilingBeatKeep (rbk): The readback record: byte count, first word, last address.
module g6lc_apu_vgpu_rbk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rbf_t rbf_i,
  input  apu_vgpu_lnr_t lnr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rbk_cpl_t cpl_o,
  output apu_vgpu_rbk_t rbk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rbk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rbf_i) | (|lnr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rbk_cpl_t cpl_q;
    apu_vgpu_rbk_t rbk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rbk_cpl_t'('0);
    assign rbk_o = rbk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rbk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rbk_q.valid) begin
            cpl_q.status <= APU_VGPU_RBK_FAULT;
          end else if (!rbf_i.valid || !lnr_i.valid) begin
            cpl_q.status <= APU_VGPU_RBK_EMPTY;
          end else if (rbf_i.word0 != lnr_i.origin ||
                       rbf_i.bytes != APU_VGPU_CEIL_BYTES ||
                       rbf_i.beats != APU_VGPU_CEIL_BEATS ||
                       rbf_i.last_addr != {32'h0, APU_VGPU_CEIL_RB} +
                         (64'(9'd511) << 5)) begin
            cpl_q.status <= APU_VGPU_RBK_FAULT;
          end else begin
            rbk_q.valid <= 1'b1;
            rbk_q.word0 <= rbf_i.word0;
            rbk_q.beats <= rbf_i.beats;
            rbk_q.last_addr <= rbf_i.last_addr;
            cpl_q.status <= APU_VGPU_RBK_OK;
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

// CeilingBeatKeep (rbk) enable-0 fixture: The readback record: byte count, first word, last address.
module g6lc_apu_vgpu_rbk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rbf_t rbf_i,
  input  apu_vgpu_lnr_t lnr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rbk_cpl_t cpl_o,
  output apu_vgpu_rbk_t rbk_o
);
  g6lc_apu_vgpu_rbk #(.Enable(Enable)) i_dut (.*);
endmodule
