// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// CTX_CREATE for context 1, debug name "main". The payload is the
// control record, not the execbuffer. This is not an OS context.

// ContextCreate (ctx): CTX_CREATE for context 1. Default-off. Not an OS context.
module g6lc_apu_vgpu_ctx
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
  output apu_vgpu_ctx_cpl_t cpl_o,
  output apu_vgpu_ctx_t ctx_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ctx_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, ReadBody, Commit, Done } state_e;

    state_e state_q;
    apu_vgpu_ctx_cpl_t cpl_q;
    apu_vgpu_ctx_t ctx_q;
    logic [31:0] body_q [0:23];
    logic [4:0] idx_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = (32'(idx_q) << 2);
    assign peek_addr_o = state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ctx_cpl_t'('0);
    assign ctx_o = ctx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ctx_q <= '0;
        body_q <= '{default: '0};
        idx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ctx_q.valid) begin
            cpl_q.status <= APU_VGPU_CTX_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid) begin
            cpl_q.status <= APU_VGPU_CTX_EMPTY;
            state_q <= Done;
          end else if (APU_VGPU_CTX_BYTES > buf_i.size) begin
            cpl_q.status <= APU_VGPU_CTX_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            state_q <= ReadBody;
          end
        end
        ReadBody: begin
          body_q[idx_q] <= peek_word_i;
          if (idx_q == 5'd23) state_q <= Commit;
          else idx_q <= idx_q + 5'd1;
        end
        Commit: begin
          logic name_tail;
          name_tail = body_q[9] == 32'h0 && body_q[10] == 32'h0 && body_q[11] == 32'h0 &&
                      body_q[12] == 32'h0 && body_q[13] == 32'h0 && body_q[14] == 32'h0 &&
                      body_q[15] == 32'h0 && body_q[16] == 32'h0 && body_q[17] == 32'h0 &&
                      body_q[18] == 32'h0 && body_q[19] == 32'h0 && body_q[20] == 32'h0 &&
                      body_q[21] == 32'h0 && body_q[22] == 32'h0 && body_q[23] == 32'h0;
          if (body_q[0] != VGPU_CMD_CTX_CREATE || body_q[1] != 32'h0 || body_q[2] != 32'h0 ||
              body_q[3] != 32'h0 || body_q[4] != APU_VGPU_CTX_ID || body_q[5] != 32'h0 ||
              body_q[6] != APU_VGPU_CTX_NLEN || body_q[7] != 32'h0 ||
              body_q[8] != APU_VGPU_CTX_NAME0 || !name_tail) begin
            cpl_q.status <= APU_VGPU_CTX_FAULT;
          end else begin
            ctx_q.valid <= 1'b1;
            ctx_q.ctx_id <= body_q[4];
            ctx_q.next <= APU_VGPU_CTX_BYTES;
            cpl_q.status <= APU_VGPU_CTX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(ctx_o));
    `endif
  end
endmodule

// ContextCreate (ctx) enable-0 fixture: CTX_CREATE for context 1. Default-off. Not an OS context.
module g6lc_apu_vgpu_ctx_fixture
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
  output apu_vgpu_ctx_cpl_t cpl_o,
  output apu_vgpu_ctx_t ctx_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_ctx #(.Enable(Enable)) i_dut (.*);
endmodule
