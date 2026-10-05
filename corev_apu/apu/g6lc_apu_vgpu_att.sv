// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Three CTX_ATTACH records: resource 4, resource 3, then resource 1.
// This does not map guest memory.

// ContextAttach (att): The three CTX_ATTACH records. Default-off. Not a guest mapping.
module g6lc_apu_vgpu_att
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_c3d_t c3d_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_att_cpl_t cpl_o,
  output apu_vgpu_att_t att_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign att_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|c3d_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, ReadBody, Commit, Done } state_e;

    state_e state_q;
    apu_vgpu_att_cpl_t cpl_q;
    apu_vgpu_att_t att_q;
    logic [31:0] body_q [0:7];
    logic [2:0] idx_q;
    logic [31:0] base_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = base_q + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_att_cpl_t'('0);
    assign att_o = att_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        att_q <= '0;
        body_q <= '{default: '0};
        idx_q <= '0;
        base_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic [31:0] base, need, skip;
          skip = att_q.rt ? APU_VGPU_ATT_BYTES : 32'h0;
          if (att_q.vbo) skip = APU_VGPU_ATT_BYTES + APU_VGPU_ATT_BYTES;
          if (att_q.scan) skip = APU_VGPU_ATT_BYTES + APU_VGPU_ATT_BYTES + APU_VGPU_ATT_BYTES;
          base = c3d_i.next + skip;
          need = base + APU_VGPU_ATT_BYTES;
          if (att_q.rt && att_q.vbo && att_q.scan) begin
            cpl_q.status <= APU_VGPU_ATT_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !c3d_i.rt_valid || !c3d_i.vbo_valid) begin
            cpl_q.status <= APU_VGPU_ATT_EMPTY;
            state_q <= Done;
          end else if (c3d_i.next[1:0] != 2'b00 || need < base || need > buf_i.size) begin
            cpl_q.status <= APU_VGPU_ATT_FAULT;
            state_q <= Done;
          end else begin
            base_q <= base;
            idx_q <= '0;
            state_q <= ReadBody;
          end
        end
        ReadBody: begin
          body_q[idx_q] <= peek_word_i;
          if (idx_q == 3'd7) state_q <= Commit;
          else idx_q <= idx_q + 3'd1;
        end
        Commit: begin
          logic hdr_ok, which_ok;
          logic [31:0] want;
          want = !att_q.rt ? APU_VGPU_RES_RT : (!att_q.vbo ? APU_VGPU_RES_VBO : APU_VGPU_RES_SCAN);
          hdr_ok = body_q[0] == VGPU_CMD_CTX_ATTACH_RESOURCE && body_q[1] == 32'h0 &&
                   body_q[2] == 32'h0 && body_q[3] == 32'h0 && body_q[4] == APU_VGPU_CTX_ID &&
                   body_q[5] == 32'h0 && body_q[7] == 32'h0;
          which_ok = body_q[6] == want;
          if (!hdr_ok || !which_ok) begin
            cpl_q.status <= APU_VGPU_ATT_FAULT;
          end else begin
            if (!att_q.rt) att_q.rt <= 1'b1;
            else if (!att_q.vbo) att_q.vbo <= 1'b1;
            else att_q.scan <= 1'b1;
            att_q.next <= base_q + APU_VGPU_ATT_BYTES;
            cpl_q.status <= APU_VGPU_ATT_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(att_o));
    `endif
  end
endmodule

// ContextAttach (att) enable-0 fixture: The three CTX_ATTACH records. Default-off. Not a guest mapping.
module g6lc_apu_vgpu_att_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_c3d_t c3d_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_att_cpl_t cpl_o,
  output apu_vgpu_att_t att_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_att #(.Enable(Enable)) i_dut (.*);
endmodule
