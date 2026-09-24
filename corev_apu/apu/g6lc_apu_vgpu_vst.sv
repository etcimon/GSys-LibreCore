// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// The 32 dwords of the frozen vertex shader. The text is the
// passthrough VERT program, starting at byte 48. A mismatched dword
// records nothing. This is not a translate.

module g6lc_apu_vgpu_vst
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_sh_t sh_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vst_cpl_t cpl_o,
  output apu_vgpu_vst_t vst_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  function automatic logic [31:0] vst_word(input logic [4:0] i);
    case (i)
      5'd0: vst_word = 32'h5452_4556;
      5'd1: vst_word = 32'h4c43_440a;
      5'd2: vst_word = 32'h5b4e_4920;
      5'd3: vst_word = 32'h440a_5d30;
      5'd4: vst_word = 32'h4920_4c43;
      5'd5: vst_word = 32'h5d31_5b4e;
      5'd6: vst_word = 32'h4c43_440a;
      5'd7: vst_word = 32'h5455_4f20;
      5'd8: vst_word = 32'h2c5d_305b;
      5'd9: vst_word = 32'h534f_5020;
      5'd10: vst_word = 32'h4f49_5449;
      5'd11: vst_word = 32'h4344_0a4e;
      5'd12: vst_word = 32'h554f_204c;
      5'd13: vst_word = 32'h5d31_5b54;
      5'd14: vst_word = 32'h4547_202c;
      5'd15: vst_word = 32'h4952_454e;
      5'd16: vst_word = 32'h5d30_5b43;
      5'd17: vst_word = 32'h3020_200a;
      5'd18: vst_word = 32'h4f4d_203a;
      5'd19: vst_word = 32'h554f_2056;
      5'd20: vst_word = 32'h5d30_5b54;
      5'd21: vst_word = 32'h4e49_202c;
      5'd22: vst_word = 32'h0a5d_305b;
      5'd23: vst_word = 32'h3a31_2020;
      5'd24: vst_word = 32'h564f_4d20;
      5'd25: vst_word = 32'h5455_4f20;
      5'd26: vst_word = 32'h2c5d_315b;
      5'd27: vst_word = 32'h5b4e_4920;
      5'd28: vst_word = 32'h200a_5d31;
      5'd29: vst_word = 32'h203a_3220;
      5'd30: vst_word = 32'h0a44_4e45;
      5'd31: vst_word = 32'h0000_0000;
      default: vst_word = 32'h0;
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vst_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) | (|sh_i) |
                        (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Read, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_vst_cpl_t cpl_q;
    apu_vgpu_vst_t vst_q;
    logic [4:0] idx_q;
    logic bad_q, armed_q;
    logic [31:0] byte_at;

    assign byte_at = APU_VIRGL_VS_TEXT_AT + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == Read ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vst_cpl_t'('0);
    assign vst_o = vst_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vst_q <= '0;
        idx_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vst_q.valid) begin
            cpl_q.status <= APU_VGPU_VST_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !sh_i.valid) begin
            cpl_q.status <= APU_VGPU_VST_EMPTY;
            state_q <= Done;
          end else if (sh_i.handle != APU_VIRGL_VS_HANDLE ||
                       sh_i.stage != APU_VIRGL_SHADER_VERTEX ||
                       sh_i.offlen != APU_VIRGL_VS_OFFLEN ||
                       sh_i.tokens != APU_VIRGL_VS_TOKENS ||
                       sh_i.text_at != APU_VIRGL_VS_TEXT_AT ||
                       sh_i.next != APU_VIRGL_VS_NEXT ||
                       sh_i.text0 != APU_VIRGL_VS_TEXT0 ||
                       buf_i.size < sh_i.next) begin
            cpl_q.status <= APU_VGPU_VST_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            bad_q <= 1'b0;
            state_q <= Read;
          end
        end
        Read: begin
          if (peek_word_i != vst_word(idx_q)) bad_q <= 1'b1;
          if (idx_q == 5'd31) state_q <= Commit;
          else idx_q <= idx_q + 5'd1;
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_VST_FAULT;
          end else begin
            vst_q.valid <= 1'b1;
            cpl_q.status <= APU_VGPU_VST_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vst_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_VST_OK |-> vst_o.valid);
    `endif
  end
endmodule

module g6lc_apu_vgpu_vst_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_sh_t sh_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vst_cpl_t cpl_o,
  output apu_vgpu_vst_t vst_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_vst #(.Enable(Enable)) i_dut (.*);
endmodule
