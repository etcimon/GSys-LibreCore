// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// TRANSFER_TO_HOST_2D of the scanout resource. The rectangle is
// 0,0,640 by 64, the top band, not the full frame and not the 64 by 64
// ceiling. No byte is copied. The refused clear word stays in place.

// ScanBandTransfer (sxf): The 64-row transfer of that resource. Default-off. No bytes are copied.
module g6lc_apu_vgpu_sxf
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_s2d_t s2d_i,
  input  apu_vgpu_sbk_t sbk_i,
  input  apu_vgpu_den_t den_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sxf_cpl_t cpl_o,
  output apu_vgpu_sxf_t sxf_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  function automatic logic [31:0] sxf_word(input logic [3:0] i);
    case (i)
      4'd0: sxf_word = 32'h0000_0105;
      4'd1: sxf_word = 32'h0000_0000;
      4'd2: sxf_word = 32'h0000_0000;
      4'd3: sxf_word = 32'h0000_0000;
      4'd4: sxf_word = 32'h0000_0000;
      4'd5: sxf_word = 32'h0000_0000;
      4'd6: sxf_word = 32'h0000_0000;
      4'd7: sxf_word = 32'h0000_0000;
      4'd8: sxf_word = 32'h0000_0280;
      4'd9: sxf_word = 32'h0000_0040;
      4'd10: sxf_word = 32'h0000_0000;
      4'd11: sxf_word = 32'h0000_0000;
      4'd12: sxf_word = 32'h0000_0001;
      4'd13: sxf_word = 32'h0000_0000;
      default: sxf_word = 32'h0;
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sxf_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|s2d_i) | (|sbk_i) | (|den_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Read, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_sxf_cpl_t cpl_q;
    apu_vgpu_sxf_t sxf_q;
    logic [3:0] idx_q;
    logic bad_q, armed_q;
    logic [31:0] byte_at;

    assign byte_at = APU_VGPU_SCAN_XF_AT + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == Read ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sxf_cpl_t'('0);
    assign sxf_o = sxf_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sxf_q <= '0;
        idx_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sxf_q.valid) begin
            cpl_q.status <= APU_VGPU_SXF_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !s2d_i.valid || !sbk_i.valid ||
                       !den_i.valid) begin
            cpl_q.status <= APU_VGPU_SXF_EMPTY;
            state_q <= Done;
          end else if (!den_i.refused || den_i.word != APU_VGPU_CLEAR_WORD ||
                       den_i.samples != APU_VGPU_FILL_N ||
                       den_i.resource_id != APU_VIRGL_RES_SCAN ||
                       s2d_i.width != APU_VGPU_SCAN_W ||
                       s2d_i.height != APU_VGPU_SCAN_H ||
                       sbk_i.resource_id != APU_VIRGL_RES_SCAN ||
                       sbk_i.length != APU_VGPU_SCAN_BYTES ||
                       sbk_i.addr == 32'h0 ||
                       buf_i.size < (APU_VGPU_SCAN_XF_AT + 32'd56)) begin
            cpl_q.status <= APU_VGPU_SXF_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            bad_q <= 1'b0;
            state_q <= Read;
          end
        end
        Read: begin
          if (peek_word_i != sxf_word(idx_q)) bad_q <= 1'b1;
          if (idx_q == 4'd13) state_q <= Commit;
          else idx_q <= idx_q + 4'd1;
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_SXF_FAULT;
          end else begin
            sxf_q.valid <= 1'b1;
            sxf_q.copied <= 1'b0;
            sxf_q.width <= APU_VGPU_SCAN_W;
            sxf_q.height <= APU_VGPU_SCAN_BAND;
            sxf_q.word <= den_i.word;
            cpl_q.status <= APU_VGPU_SXF_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sxf_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SXF_OK |->
        sxf_o.valid && !sxf_o.copied &&
        sxf_o.width == APU_VGPU_SCAN_W &&
        sxf_o.height == APU_VGPU_SCAN_BAND &&
        sxf_o.word == APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// ScanBandTransfer (sxf) enable-0 fixture: The 64-row transfer of that resource. Default-off. No bytes are copied.
module g6lc_apu_vgpu_sxf_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_s2d_t s2d_i,
  input  apu_vgpu_sbk_t sbk_i,
  input  apu_vgpu_den_t den_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sxf_cpl_t cpl_o,
  output apu_vgpu_sxf_t sxf_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_sxf #(.Enable(Enable)) i_dut (.*);
endmodule
