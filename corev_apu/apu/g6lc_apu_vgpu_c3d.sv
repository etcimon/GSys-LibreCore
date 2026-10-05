// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Two RESOURCE_CREATE_3D records after the context. The render target
// is resource 4, 640 by 480, B8G8R8X8. The vertex buffer is resource 3,
// 96 bytes. This does not allocate memory.

// ResourceCreate3d (c3d): The two RESOURCE_CREATE_3D records. Default-off. Not an allocation.
module g6lc_apu_vgpu_c3d
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_ctx_t ctx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_c3d_cpl_t cpl_o,
  output apu_vgpu_c3d_t c3d_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign c3d_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|ctx_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, ReadBody, Commit, Done } state_e;

    state_e state_q;
    apu_vgpu_c3d_cpl_t cpl_q;
    apu_vgpu_c3d_t c3d_q;
    logic [31:0] body_q [0:17];
    logic [4:0] idx_q;
    logic [31:0] base_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = base_q + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_c3d_cpl_t'('0);
    assign c3d_o = c3d_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        c3d_q <= '0;
        body_q <= '{default: '0};
        idx_q <= '0;
        base_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic [31:0] base, need;
          base = c3d_q.rt_valid ? (ctx_i.next + APU_VGPU_C3D_BYTES) : ctx_i.next;
          need = base + APU_VGPU_C3D_BYTES;
          if (c3d_q.rt_valid && c3d_q.vbo_valid) begin
            cpl_q.status <= APU_VGPU_C3D_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !ctx_i.valid) begin
            cpl_q.status <= APU_VGPU_C3D_EMPTY;
            state_q <= Done;
          end else if (ctx_i.next[1:0] != 2'b00 || need < base || need > buf_i.size) begin
            cpl_q.status <= APU_VGPU_C3D_FAULT;
            state_q <= Done;
          end else begin
            base_q <= base;
            idx_q <= '0;
            state_q <= ReadBody;
          end
        end
        ReadBody: begin
          body_q[idx_q] <= peek_word_i;
          if (idx_q == 5'd17) state_q <= Commit;
          else idx_q <= idx_q + 5'd1;
        end
        Commit: begin
          logic hdr_ok, rt_ok, vbo_ok;
          hdr_ok = body_q[0] == VGPU_CMD_RESOURCE_CREATE_3D && body_q[1] == 32'h0 &&
                   body_q[2] == 32'h0 && body_q[3] == 32'h0 && body_q[4] == APU_VGPU_CTX_ID &&
                   body_q[5] == 32'h0 && body_q[12] == 32'd1 && body_q[13] == 32'd1 &&
                   body_q[14] == 32'h0 && body_q[15] == 32'h0 && body_q[17] == 32'h0;
          rt_ok = !c3d_q.rt_valid && body_q[6] == APU_VGPU_RES_RT &&
                  body_q[7] == APU_VGPU_PIPE_TEX_2D && body_q[8] == APU_VIRGL_FMT_B8G8R8X8 &&
                  body_q[9] == APU_VGPU_BIND_RT && body_q[10] == APU_VGPU_RT_W &&
                  body_q[11] == APU_VGPU_RT_H && body_q[16] == APU_VGPU_Y0_TOP;
          vbo_ok = c3d_q.rt_valid && !c3d_q.vbo_valid && body_q[6] == APU_VGPU_RES_VBO &&
                   body_q[7] == APU_VGPU_PIPE_BUFFER && body_q[8] == 32'h0 &&
                   body_q[9] == APU_VGPU_BIND_VBO && body_q[10] == APU_VIRGL_VBO_BYTES &&
                   body_q[11] == 32'd1 && body_q[16] == 32'h0;
          if (!hdr_ok || (!rt_ok && !vbo_ok)) begin
            cpl_q.status <= APU_VGPU_C3D_FAULT;
          end else begin
            if (rt_ok) begin
              c3d_q.rt_valid <= 1'b1;
              c3d_q.rt_w <= body_q[10];
              c3d_q.rt_h <= body_q[11];
            end else begin
              c3d_q.vbo_valid <= 1'b1;
              c3d_q.vbo_bytes <= body_q[10];
            end
            c3d_q.next <= base_q + APU_VGPU_C3D_BYTES;
            cpl_q.status <= APU_VGPU_C3D_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(c3d_o));
    `endif
  end
endmodule

// ResourceCreate3d (c3d) enable-0 fixture: The two RESOURCE_CREATE_3D records. Default-off. Not an allocation.
module g6lc_apu_vgpu_c3d_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_ctx_t ctx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_c3d_cpl_t cpl_o,
  output apu_vgpu_c3d_t c3d_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_c3d #(.Enable(Enable)) i_dut (.*);
endmodule
