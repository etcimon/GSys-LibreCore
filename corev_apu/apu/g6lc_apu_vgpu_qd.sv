// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The 24 floats after the inline-write prefix. Each vertex is
// {x, y, 0, 1, u, v}. The four vertices are the NDC square
// (-1,-1), (1,-1), (-1,1), (1,1) with u,v at the same corners.
// A mismatched float records nothing. This is not a transform.

// QuadFloats (qd): The 24 vertex floats of the fullscreen strip.
module g6lc_apu_vgpu_qd
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
  output apu_vgpu_qd_cpl_t cpl_o,
  output apu_vgpu_qd_t qd_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  function automatic logic [31:0] qd_word(input logic [4:0] i);
    case (i)
      5'd0, 5'd1, 5'd7, 5'd12: qd_word = APU_VIRGL_F32_NEG_ONE;
      5'd3, 5'd6, 5'd9, 5'd10, 5'd13, 5'd15, 5'd17, 5'd18, 5'd19, 5'd21, 5'd22, 5'd23:
        qd_word = APU_VIRGL_F32_ONE;
      default: qd_word = 32'h0;
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qd_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|iw_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Read, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_qd_cpl_t cpl_q;
    apu_vgpu_qd_t qd_q;
    logic [31:0] base_q;
    logic [4:0] idx_q;
    logic bad_q, armed_q;
    logic [31:0] byte_at;

    assign byte_at = base_q + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == Read ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qd_cpl_t'('0);
    assign qd_o = qd_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qd_q <= '0;
        base_q <= '0;
        idx_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qd_q.valid) begin
            cpl_q.status <= APU_VGPU_QD_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !iw_i.valid) begin
            cpl_q.status <= APU_VGPU_QD_EMPTY;
            state_q <= Done;
          end else if (iw_i.resource != APU_VIRGL_RES_VBO || iw_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iw_i.next != 32'd792 || iw_i.next < iw_i.nbytes ||
                       buf_i.size < iw_i.next) begin
            cpl_q.status <= APU_VGPU_QD_FAULT;
            state_q <= Done;
          end else begin
            base_q <= iw_i.next - iw_i.nbytes;
            idx_q <= '0;
            bad_q <= 1'b0;
            state_q <= Read;
          end
        end
        Read: begin
          if (peek_word_i != qd_word(idx_q)) bad_q <= 1'b1;
          if (idx_q == 5'd23) state_q <= Commit;
          else idx_q <= idx_q + 5'd1;
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_QD_FAULT;
          end else begin
            qd_q.valid <= 1'b1;
            cpl_q.status <= APU_VGPU_QD_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qd_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QD_OK |-> qd_o.valid);
    `endif
  end
endmodule

// QuadFloats (qd) enable-0 fixture: The 24 vertex floats of the fullscreen strip.
module g6lc_apu_vgpu_qd_fixture
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
  output apu_vgpu_qd_cpl_t cpl_o,
  output apu_vgpu_qd_t qd_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_qd #(.Enable(Enable)) i_dut (.*);
endmodule
