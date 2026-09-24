// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// The 35 dwords of the frozen fragment shader. The text is the
// TEX program, starting at byte 200. A mismatched dword records
// nothing. TEX is not executed.

module g6lc_apu_vgpu_fst
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_sh_t fs_i,
  input  apu_vgpu_vst_t vst_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fst_cpl_t cpl_o,
  output apu_vgpu_fst_t fst_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  function automatic logic [31:0] fst_word(input logic [5:0] i);
    case (i)
      6'd0: fst_word = 32'h4741_5246;
      6'd1: fst_word = 32'h4c43_440a;
      6'd2: fst_word = 32'h5b4e_4920;
      6'd3: fst_word = 32'h202c_5d30;
      6'd4: fst_word = 32'h454e_4547;
      6'd5: fst_word = 32'h5b43_4952;
      6'd6: fst_word = 32'h202c_5d30;
      6'd7: fst_word = 32'h5352_4550;
      6'd8: fst_word = 32'h5443_4550;
      6'd9: fst_word = 32'h0a45_5649;
      6'd10: fst_word = 32'h204c_4344;
      6'd11: fst_word = 32'h5b54_554f;
      6'd12: fst_word = 32'h202c_5d30;
      6'd13: fst_word = 32'h4f4c_4f43;
      6'd14: fst_word = 32'h4344_0a52;
      6'd15: fst_word = 32'h4153_204c;
      6'd16: fst_word = 32'h305b_504d;
      6'd17: fst_word = 32'h4344_0a5d;
      6'd18: fst_word = 32'h5653_204c;
      6'd19: fst_word = 32'h5b57_4549;
      6'd20: fst_word = 32'h202c_5d30;
      6'd21: fst_word = 32'h202c_4432;
      6'd22: fst_word = 32'h524f_4e55;
      6'd23: fst_word = 32'h2020_0a4d;
      6'd24: fst_word = 32'h5420_3a30;
      6'd25: fst_word = 32'h4f20_5845;
      6'd26: fst_word = 32'h305b_5455;
      6'd27: fst_word = 32'h4920_2c5d;
      6'd28: fst_word = 32'h5d30_5b4e;
      6'd29: fst_word = 32'h4153_202c;
      6'd30: fst_word = 32'h305b_504d;
      6'd31: fst_word = 32'h3220_2c5d;
      6'd32: fst_word = 32'h2020_0a44;
      6'd33: fst_word = 32'h4520_3a31;
      6'd34: fst_word = 32'h000a_444e;
      default: fst_word = 32'h0;
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign fst_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) | (|fs_i) | (|vst_i) |
                        (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Read, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_fst_cpl_t cpl_q;
    apu_vgpu_fst_t fst_q;
    logic [5:0] idx_q;
    logic bad_q, armed_q;
    logic [31:0] byte_at;

    assign byte_at = APU_VIRGL_FS_TEXT_AT + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == Read ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_fst_cpl_t'('0);
    assign fst_o = fst_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        fst_q <= '0;
        idx_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (fst_q.valid) begin
            cpl_q.status <= APU_VGPU_FST_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !fs_i.valid || !vst_i.valid) begin
            cpl_q.status <= APU_VGPU_FST_EMPTY;
            state_q <= Done;
          end else if (!vst_i.valid ||
                       fs_i.handle != APU_VIRGL_FS_HANDLE ||
                       fs_i.stage != APU_VIRGL_SHADER_FRAGMENT ||
                       fs_i.offlen != APU_VIRGL_FS_OFFLEN ||
                       fs_i.tokens != APU_VIRGL_FS_TOKENS ||
                       fs_i.text_at != APU_VIRGL_FS_TEXT_AT ||
                       fs_i.next != APU_VIRGL_FS_NEXT ||
                       fs_i.text0 != APU_VIRGL_FS_TEXT0 ||
                       buf_i.size < fs_i.next) begin
            cpl_q.status <= APU_VGPU_FST_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            bad_q <= 1'b0;
            state_q <= Read;
          end
        end
        Read: begin
          if (peek_word_i != fst_word(idx_q)) bad_q <= 1'b1;
          if (idx_q == 6'd34) state_q <= Commit;
          else idx_q <= idx_q + 6'd1;
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_FST_FAULT;
          end else begin
            fst_q.valid <= 1'b1;
            fst_q.tex <= 1'b1;
            cpl_q.status <= APU_VGPU_FST_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(fst_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_FST_OK |-> fst_o.valid && fst_o.tex);
    `endif
  end
endmodule

module g6lc_apu_vgpu_fst_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_sh_t fs_i,
  input  apu_vgpu_vst_t vst_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fst_cpl_t cpl_o,
  output apu_vgpu_fst_t fst_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_fst #(.Enable(Enable)) i_dut (.*);
endmodule
