// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The vertex inline write that follows the sampler-view set. The body
// names resource 3 and 96 bytes. The floats stay in the buffer.

module g6lc_apu_vgpu_iw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_svb_t svb_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_iw_cpl_t cpl_o,
  output apu_vgpu_iw_t iw_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  function automatic logic [31:0] iw_word(input logic [5:0] i);
    case (i)
      6'd0: iw_word = APU_VIRGL_RES_VBO;
      6'd8: iw_word = APU_VIRGL_VBO_BYTES;
      6'd9, 6'd10: iw_word = 32'd1;
      6'd11: iw_word = APU_VIRGL_F32_NEG_ONE;
      default: iw_word = 32'h0;
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign iw_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|svb_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, ReadHdr, Decide, ReadBody, Commit, Done
    } state_e;

    state_e state_q;
    apu_vgpu_iw_cpl_t cpl_q;
    apu_vgpu_iw_t iw_q;
    logic [31:0] hdr_q;
    logic [5:0] idx_q;
    logic bad_q;
    logic [31:0] base_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = base_q + ((32'(idx_q) + 32'd1) << 2);
    assign peek_addr_o = state_q == ReadHdr ? base_q[APU_VGPU_BUF_ADDRW-1:0] :
                         state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_iw_cpl_t'('0);
    assign iw_o = iw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        iw_q <= '0;
        hdr_q <= '0;
        idx_q <= '0;
        bad_q <= 1'b0;
        base_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic [31:0] need;
          need = svb_i.next + 32'd4;
          if (iw_q.valid) begin
            cpl_q.status <= APU_VGPU_IW_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !svb_i.valid) begin
            cpl_q.status <= APU_VGPU_IW_EMPTY;
            state_q <= Done;
          end else if (svb_i.next[1:0] != 2'b00 || need < svb_i.next ||
                       need > buf_i.size) begin
            cpl_q.status <= APU_VGPU_IW_FAULT;
            state_q <= Done;
          end else begin
            base_q <= svb_i.next;
            state_q <= ReadHdr;
          end
        end
        ReadHdr: begin
          hdr_q <= peek_word_i;
          state_q <= Decide;
        end
        Decide: begin
          logic [7:0] cmd, obj;
          logic [15:0] nbody;
          logic [31:0] span, endb;
          cmd = hdr_q[7:0];
          obj = hdr_q[15:8];
          nbody = hdr_q[31:16];
          span = (32'(nbody) + 32'd1) << 2;
          endb = base_q + span;
          if (cmd != APU_VIRGL_INLINE_WRITE || obj != 8'd0 || nbody != 16'd35 ||
              endb < base_q || endb > buf_i.size) begin
            cpl_q.status <= APU_VGPU_IW_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            bad_q <= 1'b0;
            state_q <= ReadBody;
          end
        end
        ReadBody: begin
          if (idx_q <= 6'd11 && peek_word_i != iw_word(idx_q))
            bad_q <= 1'b1;
          if (idx_q == 6'd34) state_q <= Commit;
          else idx_q <= idx_q + 6'd1;
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_IW_FAULT;
          end else begin
            iw_q.valid <= 1'b1;
            iw_q.resource <= APU_VIRGL_RES_VBO;
            iw_q.nbytes <= APU_VIRGL_VBO_BYTES;
            iw_q.next <= base_q + 32'd144;
            cpl_q.status <= APU_VGPU_IW_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(iw_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_iw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_svb_t svb_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_iw_cpl_t cpl_o,
  output apu_vgpu_iw_t iw_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_iw #(.Enable(Enable)) i_dut (.*);
endmodule
