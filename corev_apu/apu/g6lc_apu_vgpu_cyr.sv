// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Four channels of the covered TEX sample after the guest
// transfer beat. Byte 0 is red. The clamp texel 32'hA5000000 is
// the bytes 00 00 00 A5. The half blend 32'hD2008000 is the
// bytes 00 80 00 D2. The clear channels 0D 0D 1A FF record
// nothing. This is later than g6lc_apu_vgpu_wlk. This is not
// g6lc_apu_vgpu_byr. The compiler TEX opcode still returns -26.
// The image is not kept. This is not Mesa glReadPixels.

// TexSampleChannels (cyr): Four channels of that covered TEX sample.
// Interplay: CoveredTexSample (wld) <-> TexSampleChannels (cyr)(wlk). See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_cyr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_wlk_t wlk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cyr_cpl_t cpl_o,
  output apu_vgpu_cyr_t cyr_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cyr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|wlk_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_cyr_cpl_t cpl_q;
    apu_vgpu_cyr_t cyr_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cyr_cpl_t'('0);
    assign cyr_o = cyr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cyr_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cyr_q.valid) begin
            cpl_q.status <= APU_VGPU_CYR_FAULT;
          end else if (!wlk_i.valid) begin
            cpl_q.status <= APU_VGPU_CYR_EMPTY;
          end else if (wlk_i.refused == 1'b1 ||
                       wlk_i.word == APU_VGPU_CLEAR_WORD ||
                       wlk_i.word[7:0] == APU_VGPU_CLEAR_R ||
                       wlk_i.word[31:24] == APU_VGPU_CLEAR_A ||
                       (wlk_i.addr != 14'd0 && wlk_i.addr != 14'd4) ||
                       (wlk_i.addr == 14'd0 &&
                        wlk_i.word != APU_VGPU_FTX_ORIGIN) ||
                       (wlk_i.addr == 14'd4 &&
                        wlk_i.word != APU_VGPU_FTX_NEIGHBOR)) begin
            cpl_q.status <= APU_VGPU_CYR_FAULT;
          end else begin
            cyr_q.valid <= 1'b1;
            cyr_q.r <= wlk_i.word[7:0];
            cyr_q.g <= wlk_i.word[15:8];
            cyr_q.b <= wlk_i.word[23:16];
            cyr_q.a <= wlk_i.word[31:24];
            cyr_q.word <= wlk_i.word;
            cyr_q.addr <= wlk_i.addr;
            cpl_q.status <= APU_VGPU_CYR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cyr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CYR_OK |->
        cyr_o.valid && cyr_o.r != APU_VGPU_CLEAR_R &&
        cyr_o.word != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// TexSampleChannels (cyr) enable-0 fixture: Four channels of that covered TEX sample.
module g6lc_apu_vgpu_cyr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_wlk_t wlk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cyr_cpl_t cpl_o,
  output apu_vgpu_cyr_t cyr_o
);
  g6lc_apu_vgpu_cyr #(.Enable(Enable)) i_dut (.*);
endmodule
