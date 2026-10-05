// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One sample of the filled ceiling. Any (x,y) in 0..63 returns the clear
// word at y * 256 + x * 4. A sample outside the ceiling records nothing.
// The triangle is not walked. g6lc_apu_vgpu_pxr still reports an interior
// corner-record miss.

// ClearCeilingRead (frd): Read of one sample in that ceiling. Default-off. Not a triangle walk.
module g6lc_apu_vgpu_frd
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fil_t fil_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_frd_cpl_t cpl_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|fil_i) | (|x_i) | (|y_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_frd_cpl_t cpl_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_frd_cpl_t'('0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic [13:0] row, col, addr;
          row = {y_i[5:0], 8'b0};
          col = {6'b0, x_i[5:0], 2'b0};
          addr = row + col;
          if (!fil_i.valid) begin
            cpl_q <= '{status: APU_VGPU_FRD_EMPTY, word: '0, addr: '0};
          end else if (fil_i.word != APU_VGPU_CLEAR_WORD || fil_i.samples != APU_VGPU_FILL_N) begin
            cpl_q <= '{status: APU_VGPU_FRD_FAULT, word: '0, addr: '0};
          end else if (x_i > 16'd63 || y_i > 16'd63) begin
            cpl_q <= '{status: APU_VGPU_FRD_FAULT, word: '0, addr: '0};
          end else begin
            cpl_q <= '{status: APU_VGPU_FRD_OK, word: fil_i.word, addr: addr};
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
      cpl_valid_o && cpl_o.status == APU_VGPU_FRD_OK |->
        cpl_o.word == APU_VGPU_CLEAR_WORD);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status != APU_VGPU_FRD_OK |-> cpl_o.word == 32'h0);
    `endif
  end
endmodule

// ClearCeilingRead (frd) enable-0 fixture: Read of one sample in that ceiling. Default-off. Not a triangle walk.
module g6lc_apu_vgpu_frd_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fil_t fil_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_frd_cpl_t cpl_o
);
  g6lc_apu_vgpu_frd #(.Enable(Enable)) i_dut (.*);
endmodule
