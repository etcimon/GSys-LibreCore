// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The vertex-buffer set that follows the inline write. Buffer 0 uses
// stride 24, offset 0, and resource 3. This does not fetch vertices.

// VertexBuffersSet (vb): The vertex-buffer set that follows the inline write. Default-off. Not a vertex fetch.
module g6lc_apu_vgpu_vb
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_iw_t iw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vb_cpl_t cpl_o,
  output apu_vgpu_vb_t vb_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vb_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|iw_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, ReadHdr, Decide, ReadBody, Commit, Done
    } state_e;

    state_e state_q;
    apu_vgpu_vb_cpl_t cpl_q;
    apu_vgpu_vb_t vb_q;
    logic [31:0] hdr_q, body_q [0:2];
    logic [1:0] idx_q;
    logic [31:0] base_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = base_q + ((32'(idx_q) + 32'd1) << 2);
    assign peek_addr_o = state_q == ReadHdr ? base_q[APU_VGPU_BUF_ADDRW-1:0] :
                         state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vb_cpl_t'('0);
    assign vb_o = vb_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vb_q <= '0;
        hdr_q <= '0;
        body_q <= '{default: '0};
        idx_q <= '0;
        base_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic [31:0] need;
          need = iw_i.next + 32'd4;
          if (vb_q.valid) begin
            cpl_q.status <= APU_VGPU_VB_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !iw_i.valid) begin
            cpl_q.status <= APU_VGPU_VB_EMPTY;
            state_q <= Done;
          end else if (iw_i.next[1:0] != 2'b00 || need < iw_i.next ||
                       need > buf_i.size) begin
            cpl_q.status <= APU_VGPU_VB_FAULT;
            state_q <= Done;
          end else begin
            base_q <= iw_i.next;
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
          if (cmd != APU_VIRGL_SET_VERTEX_BUFFERS || obj != 8'd0 ||
              nbody != 16'd3 || endb < base_q || endb > buf_i.size) begin
            cpl_q.status <= APU_VGPU_VB_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            state_q <= ReadBody;
          end
        end
        ReadBody: begin
          body_q[idx_q] <= peek_word_i;
          if (idx_q == 2'd2) state_q <= Commit;
          else idx_q <= idx_q + 2'd1;
        end
        Commit: begin
          if (body_q[0] != APU_VIRGL_VERT_STRIDE || body_q[1] != 32'h0 ||
              body_q[2] != APU_VIRGL_RES_VBO) begin
            cpl_q.status <= APU_VGPU_VB_FAULT;
          end else begin
            vb_q.valid <= 1'b1;
            vb_q.stride <= body_q[0];
            vb_q.offset <= body_q[1];
            vb_q.resource <= body_q[2];
            vb_q.next <= base_q + 32'd16;
            cpl_q.status <= APU_VGPU_VB_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vb_o));
    `endif
  end
endmodule

// VertexBuffersSet (vb) enable-0 fixture: The vertex-buffer set that follows the inline write.
module g6lc_apu_vgpu_vb_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_iw_t iw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vb_cpl_t cpl_o,
  output apu_vgpu_vb_t vb_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_vb #(.Enable(Enable)) i_dut (.*);
endmodule
