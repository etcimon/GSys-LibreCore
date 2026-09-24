// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// VioScan RESOURCE_FLUSH of resource 1. The rectangle is the top
// band, 640 by 64. A 480-high flush records nothing. Nothing is
// presented. This is not g6lc_apu_vgpu_flu.

module g6lc_apu_vgpu_sfl
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_ssc_t ssc_i,
  input  apu_vgpu_sxf_t sxf_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sfl_cpl_t cpl_o,
  output apu_vgpu_sfl_t sfl_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  function automatic logic [31:0] sfl_word(input logic [3:0] i);
    case (i)
      4'd0: sfl_word = 32'h0000_0104;
      4'd1: sfl_word = 32'h0000_0000;
      4'd2: sfl_word = 32'h0000_0000;
      4'd3: sfl_word = 32'h0000_0000;
      4'd4: sfl_word = 32'h0000_0000;
      4'd5: sfl_word = 32'h0000_0000;
      4'd6: sfl_word = 32'h0000_0000;
      4'd7: sfl_word = 32'h0000_0000;
      4'd8: sfl_word = 32'h0000_0280;
      4'd9: sfl_word = 32'h0000_0040;
      4'd10: sfl_word = 32'h0000_0001;
      4'd11: sfl_word = 32'h0000_0000;
      default: sfl_word = 32'h0;
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sfl_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|ssc_i) | (|sxf_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Read, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_sfl_cpl_t cpl_q;
    apu_vgpu_sfl_t sfl_q;
    logic [3:0] idx_q;
    logic bad_q, armed_q;
    logic [31:0] byte_at;

    assign byte_at = APU_VGPU_SFL_AT + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == Read ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sfl_cpl_t'('0);
    assign sfl_o = sfl_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sfl_q <= '0;
        idx_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sfl_q.valid) begin
            cpl_q.status <= APU_VGPU_SFL_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !ssc_i.valid || !sxf_i.valid) begin
            cpl_q.status <= APU_VGPU_SFL_EMPTY;
            state_q <= Done;
          end else if (ssc_i.shown || ssc_i.scanout_id != 32'd0 ||
                       ssc_i.resource_id != APU_VIRGL_RES_SCAN ||
                       ssc_i.width != APU_VGPU_SCAN_W ||
                       ssc_i.height != APU_VGPU_SCAN_H ||
                       sxf_i.copied || sxf_i.word != APU_VGPU_CLEAR_WORD ||
                       sxf_i.width != APU_VGPU_SCAN_W ||
                       sxf_i.height != APU_VGPU_SCAN_BAND ||
                       buf_i.size < (APU_VGPU_SFL_AT + 32'd48)) begin
            cpl_q.status <= APU_VGPU_SFL_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            bad_q <= 1'b0;
            state_q <= Read;
          end
        end
        Read: begin
          if (peek_word_i != sfl_word(idx_q)) bad_q <= 1'b1;
          if (idx_q == 4'd11) state_q <= Commit;
          else idx_q <= idx_q + 4'd1;
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_SFL_FAULT;
          end else begin
            sfl_q.valid <= 1'b1;
            sfl_q.shown <= 1'b0;
            sfl_q.resource_id <= APU_VIRGL_RES_SCAN;
            sfl_q.width <= APU_VGPU_SCAN_W;
            sfl_q.height <= APU_VGPU_SCAN_BAND;
            cpl_q.status <= APU_VGPU_SFL_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sfl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SFL_OK |->
        sfl_o.valid && !sfl_o.shown &&
        sfl_o.resource_id == APU_VIRGL_RES_SCAN &&
        sfl_o.width == APU_VGPU_SCAN_W && sfl_o.height == APU_VGPU_SCAN_BAND);
    `endif
  end
endmodule

module g6lc_apu_vgpu_sfl_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_ssc_t ssc_i,
  input  apu_vgpu_sxf_t sxf_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sfl_cpl_t cpl_o,
  output apu_vgpu_sfl_t sfl_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_sfl #(.Enable(Enable)) i_dut (.*);
endmodule
