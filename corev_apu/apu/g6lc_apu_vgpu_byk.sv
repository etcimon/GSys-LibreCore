// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the four channels of the clear word. A second store keeps
// the first. The image is not kept. The shader is not run.

// ClearChannelsKeep (byk): The four channels.
module g6lc_apu_vgpu_byk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_byr_t byr_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_byk_cpl_t cpl_o,
  output apu_vgpu_byk_t byk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign byk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|byr_i) | (|gbd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_byk_cpl_t cpl_q;
    apu_vgpu_byk_t byk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_byk_cpl_t'('0);
    assign byk_o = byk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        byk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (byk_q.valid) begin
            cpl_q.status <= APU_VGPU_BYK_FAULT;
          end else if (!byr_i.valid || !gbd_i.valid) begin
            cpl_q.status <= APU_VGPU_BYK_EMPTY;
          end else if (byr_i.r != APU_VGPU_CLEAR_R ||
                       byr_i.g != APU_VGPU_CLEAR_G ||
                       byr_i.b != APU_VGPU_CLEAR_B ||
                       byr_i.a != APU_VGPU_CLEAR_A ||
                       {byr_i.a, byr_i.b, byr_i.g, byr_i.r} != APU_VGPU_CLEAR_WORD ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES) begin
            cpl_q.status <= APU_VGPU_BYK_FAULT;
          end else begin
            byk_q.valid <= 1'b1;
            byk_q.r <= byr_i.r;
            byk_q.g <= byr_i.g;
            byk_q.b <= byr_i.b;
            byk_q.a <= byr_i.a;
            cpl_q.status <= APU_VGPU_BYK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(byk_o));
    `endif
  end
endmodule

// ClearChannelsKeep (byk) enable-0 fixture: The four channels.
module g6lc_apu_vgpu_byk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_byr_t byr_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_byk_cpl_t cpl_o,
  output apu_vgpu_byk_t byk_o
);
  g6lc_apu_vgpu_byk #(.Enable(Enable)) i_dut (.*);
endmodule
