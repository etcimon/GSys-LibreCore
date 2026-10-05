// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// One backing entry for the scanout resource. The length is
// 640 by 480 by 4. The address is nonzero, 4-byte aligned, and not a
// lab backing address. The bytes are not read.

// ScanBacking (sbk): Backing entry for that resource. Default-off. Not a guest read.
module g6lc_apu_vgpu_sbk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_s2d_t s2d_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sbk_cpl_t cpl_o,
  output apu_vgpu_sbk_t sbk_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  function automatic logic [31:0] sbk_word(input logic [3:0] i);
    case (i)
      4'd0: sbk_word = 32'h0000_0106;
      4'd1: sbk_word = 32'h0000_0000;
      4'd2: sbk_word = 32'h0000_0000;
      4'd3: sbk_word = 32'h0000_0000;
      4'd4: sbk_word = 32'h0000_0000;
      4'd5: sbk_word = 32'h0000_0000;
      4'd6: sbk_word = 32'h0000_0001;
      4'd7: sbk_word = 32'h0000_0001;
      4'd8: sbk_word = 32'h0000_0000;
      4'd9: sbk_word = 32'h0000_0000;
      4'd10: sbk_word = 32'h0012_c000;
      4'd11: sbk_word = 32'h0000_0000;
      default: sbk_word = 32'h0;
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sbk_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|s2d_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Read, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_sbk_cpl_t cpl_q;
    apu_vgpu_sbk_t sbk_q;
    logic [31:0] addr_q;
    logic [3:0] idx_q;
    logic bad_q, armed_q;
    logic [31:0] byte_at;

    assign byte_at = APU_VGPU_SCAN_BK_AT + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == Read ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sbk_cpl_t'('0);
    assign sbk_o = sbk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sbk_q <= '0;
        addr_q <= '0;
        idx_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sbk_q.valid) begin
            cpl_q.status <= APU_VGPU_SBK_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !s2d_i.valid) begin
            cpl_q.status <= APU_VGPU_SBK_EMPTY;
            state_q <= Done;
          end else if (s2d_i.resource_id != APU_VIRGL_RES_SCAN ||
                       s2d_i.format != APU_VGPU_SCAN_FMT ||
                       s2d_i.width != APU_VGPU_SCAN_W ||
                       s2d_i.height != APU_VGPU_SCAN_H ||
                       buf_i.size < APU_VGPU_SCAN_XF_AT) begin
            cpl_q.status <= APU_VGPU_SBK_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            bad_q <= 1'b0;
            addr_q <= '0;
            state_q <= Read;
          end
        end
        Read: begin
          if (idx_q == 4'd8) begin
            if (peek_word_i == 32'h0 || peek_word_i[1:0] != 2'b00 ||
                peek_word_i == 32'h8800_1000 || peek_word_i == 32'h8800_2000)
              bad_q <= 1'b1;
            else addr_q <= peek_word_i;
          end else if (peek_word_i != sbk_word(idx_q)) bad_q <= 1'b1;
          if (idx_q == 4'd11) state_q <= Commit;
          else idx_q <= idx_q + 4'd1;
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_SBK_FAULT;
          end else begin
            sbk_q.valid <= 1'b1;
            sbk_q.resource_id <= APU_VIRGL_RES_SCAN;
            sbk_q.addr <= addr_q;
            sbk_q.length <= APU_VGPU_SCAN_BYTES;
            cpl_q.status <= APU_VGPU_SBK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sbk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SBK_OK |->
        sbk_o.valid && sbk_o.resource_id == APU_VIRGL_RES_SCAN &&
        sbk_o.addr != 32'h0 && sbk_o.length == APU_VGPU_SCAN_BYTES);
    `endif
  end
endmodule

// ScanBacking (sbk) enable-0 fixture: Backing entry for that resource. Default-off. Not a guest read.
module g6lc_apu_vgpu_sbk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_s2d_t s2d_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sbk_cpl_t cpl_o,
  output apu_vgpu_sbk_t sbk_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_sbk #(.Enable(Enable)) i_dut (.*);
endmodule
