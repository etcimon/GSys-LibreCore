// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The draw that follows the clear. Four vertices, triangle strip. This does not walk a triangle.

// DrawVbo (drw): The draw that follows the clear. Default-off. Not a raster walk.
module g6lc_apu_vgpu_drw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_clr_t clr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_drw_cpl_t cpl_o,
  output apu_vgpu_drw_t drw_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign drw_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|clr_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, ReadHdr, Decide, ReadBody, Commit, Done
    } state_e;

    state_e state_q;
    apu_vgpu_drw_cpl_t cpl_q;
    apu_vgpu_drw_t drw_q;
    logic [31:0] hdr_q, body_q [0:11];
    logic [3:0] idx_q;
    logic [31:0] base_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = base_q + ((32'(idx_q) + 32'd1) << 2);
    assign peek_addr_o = state_q == ReadHdr ? base_q[APU_VGPU_BUF_ADDRW-1:0] :
                         state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_drw_cpl_t'('0);
    assign drw_o = drw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        drw_q <= '0;
        hdr_q <= '0;
        body_q <= '{default: '0};
        idx_q <= '0;
        base_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic [31:0] need;
          need = clr_i.next + 32'd4;
          if (drw_q.valid) begin
            cpl_q.status <= APU_VGPU_DRW_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !clr_i.valid) begin
            cpl_q.status <= APU_VGPU_DRW_EMPTY;
            state_q <= Done;
          end else if (clr_i.next[1:0] != 2'b00 || need < clr_i.next ||
                       need > buf_i.size) begin
            cpl_q.status <= APU_VGPU_DRW_FAULT;
            state_q <= Done;
          end else begin
            base_q <= clr_i.next;
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
          if (cmd != APU_VIRGL_DRAW_VBO || obj != 8'd0 || nbody != 16'd12 ||
              endb < base_q || endb > buf_i.size) begin
            cpl_q.status <= APU_VGPU_DRW_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            state_q <= ReadBody;
          end
        end
        ReadBody: begin
          body_q[idx_q] <= peek_word_i;
          if (idx_q == 4'd11) state_q <= Commit;
          else idx_q <= idx_q + 4'd1;
        end
        Commit: begin
          if (body_q[0] != 32'h0 || body_q[1] != APU_VIRGL_VERT_COUNT || body_q[2] != APU_VIRGL_PRIM_STRIP ||
              body_q[3] != 32'h0 || body_q[4] != 32'd1 || body_q[5] != 32'h0 ||
              body_q[6] != 32'h0 || body_q[7] != 32'h0 || body_q[8] != 32'h0 ||
              body_q[9] != 32'h0 || body_q[10] != 32'd3 || body_q[11] != 32'h0) begin
            cpl_q.status <= APU_VGPU_DRW_FAULT;
          end else begin
            drw_q.valid <= 1'b1;
            drw_q.count <= body_q[1];
            drw_q.prim <= body_q[2];
            drw_q.next <= base_q + 32'd52;
            cpl_q.status <= APU_VGPU_DRW_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(drw_o));
    `endif
  end
endmodule

// DrawVbo (drw) enable-0 fixture: The draw that follows the clear. Default-off. Not a raster walk.
module g6lc_apu_vgpu_drw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_clr_t clr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_drw_cpl_t cpl_o,
  output apu_vgpu_drw_t drw_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_drw #(.Enable(Enable)) i_dut (.*);
endmodule
