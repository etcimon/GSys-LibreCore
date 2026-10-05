// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// VioScan RESOURCE_CREATE_2D. Resource 1, B8G8R8X8, 640 by 480.
// A 64-wide image and format 67 record nothing. No pixels are stored.
// This is not g6lc_apu_vgpu_cmd.

// ScanCreate2d (s2d): VioScan CREATE_2D for resource 1. Default-off. Not the 64 by 64 create.
module g6lc_apu_vgpu_s2d
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_s2d_cpl_t cpl_o,
  output apu_vgpu_s2d_t s2d_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  function automatic logic [31:0] s2d_word(input logic [3:0] i);
    case (i)
      4'd0: s2d_word = 32'h0000_0101;
      4'd1: s2d_word = 32'h0000_0000;
      4'd2: s2d_word = 32'h0000_0000;
      4'd3: s2d_word = 32'h0000_0000;
      4'd4: s2d_word = 32'h0000_0000;
      4'd5: s2d_word = 32'h0000_0000;
      4'd6: s2d_word = 32'h0000_0001;
      4'd7: s2d_word = 32'h0000_0002;
      4'd8: s2d_word = 32'h0000_0280;
      4'd9: s2d_word = 32'h0000_01e0;
      default: s2d_word = 32'h0;
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign s2d_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Read, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_s2d_cpl_t cpl_q;
    apu_vgpu_s2d_t s2d_q;
    logic [3:0] idx_q;
    logic bad_q, armed_q;
    logic [31:0] byte_at;

    assign byte_at = APU_VGPU_SCAN_C2_AT + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == Read ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_s2d_cpl_t'('0);
    assign s2d_o = s2d_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        s2d_q <= '0;
        idx_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (s2d_q.valid) begin
            cpl_q.status <= APU_VGPU_S2D_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid) begin
            cpl_q.status <= APU_VGPU_S2D_EMPTY;
            state_q <= Done;
          end else if (buf_i.size < APU_VGPU_SCAN_BK_AT) begin
            cpl_q.status <= APU_VGPU_S2D_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            bad_q <= 1'b0;
            state_q <= Read;
          end
        end
        Read: begin
          if (peek_word_i != s2d_word(idx_q)) bad_q <= 1'b1;
          if (idx_q == 4'd9) state_q <= Commit;
          else idx_q <= idx_q + 4'd1;
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_S2D_FAULT;
          end else begin
            s2d_q.valid <= 1'b1;
            s2d_q.resource_id <= APU_VIRGL_RES_SCAN;
            s2d_q.format <= APU_VGPU_SCAN_FMT;
            s2d_q.width <= APU_VGPU_SCAN_W;
            s2d_q.height <= APU_VGPU_SCAN_H;
            cpl_q.status <= APU_VGPU_S2D_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(s2d_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_S2D_OK |->
        s2d_o.valid && s2d_o.resource_id == APU_VIRGL_RES_SCAN &&
        s2d_o.format == APU_VGPU_SCAN_FMT &&
        s2d_o.width == APU_VGPU_SCAN_W && s2d_o.height == APU_VGPU_SCAN_H);
    `endif
  end
endmodule

// ScanCreate2d (s2d) enable-0 fixture: VioScan CREATE_2D for resource 1. Default-off. Not the 64 by 64 create.
module g6lc_apu_vgpu_s2d_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_s2d_cpl_t cpl_o,
  output apu_vgpu_s2d_t s2d_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_s2d #(.Enable(Enable)) i_dut (.*);
endmodule
