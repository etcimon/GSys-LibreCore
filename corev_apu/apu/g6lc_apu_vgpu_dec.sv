// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The first command in a fetched execbuffer. The header is
// cmd | object<<8 | body_dwords<<16. A CREATE_OBJECT surface with five
// body words records handle, resource, and format. Any other command
// that fits records its header and stops. The following command is not
// decoded. This is not a draw.

// FirstCommandDecode (dec): One decode of the first command in that buffer. Default-off. Not the rest of the stream and not a draw.
module g6lc_apu_vgpu_dec
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
  output apu_vgpu_dec_cpl_t cpl_o,
  output apu_vgpu_dec_t dec_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign dec_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, ReadHdr, Decide, ReadBody, Commit, Done
    } state_e;

    state_e state_q;
    apu_vgpu_dec_cpl_t cpl_q;
    apu_vgpu_dec_t dec_q;
    logic [31:0] hdr_q, body_q [0:4];
    logic [2:0] idx_q;
    logic [15:0] nbody_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = (32'(idx_q) + 32'd1) << 2;
    assign peek_addr_o = state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_dec_cpl_t'('0);
    assign dec_o = dec_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        dec_q <= '0;
        hdr_q <= '0;
        body_q <= '{default: '0};
        idx_q <= '0;
        nbody_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (dec_q.valid) begin
            cpl_q.status <= APU_VGPU_DEC_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid) begin
            cpl_q.status <= APU_VGPU_DEC_EMPTY;
            state_q <= Done;
          end else if (buf_i.size < 32'd4) begin
            cpl_q.status <= APU_VGPU_DEC_FAULT;
            state_q <= Done;
          end else begin
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
          logic [31:0] bytes;
          cmd = hdr_q[7:0];
          obj = hdr_q[15:8];
          nbody = hdr_q[31:16];
          bytes = (32'(nbody) + 32'd1) << 2;
          if (bytes > buf_i.size || bytes > APU_VGPU_SUB_MAX) begin
            cpl_q.status <= APU_VGPU_DEC_FAULT;
            state_q <= Done;
          end else if (cmd == APU_VIRGL_CREATE_OBJECT &&
                       obj == APU_VIRGL_OBJ_SURFACE) begin
            if (nbody != APU_VIRGL_SURFACE_DWORDS) begin
              cpl_q.status <= APU_VGPU_DEC_FAULT;
              state_q <= Done;
            end else begin
              nbody_q <= nbody;
              idx_q <= '0;
              state_q <= ReadBody;
            end
          end else begin
            dec_q.valid <= 1'b1;
            dec_q.surface <= 1'b0;
            dec_q.cmd <= cmd;
            dec_q.obj <= obj;
            dec_q.nbody <= nbody;
            dec_q.handle <= '0;
            dec_q.resource_id <= '0;
            dec_q.format <= '0;
            dec_q.next <= bytes;
            cpl_q.status <= APU_VGPU_DEC_OK;
            state_q <= Done;
          end
        end
        ReadBody: begin
          body_q[idx_q] <= peek_word_i;
          if (idx_q == 3'd4) state_q <= Commit;
          else idx_q <= idx_q + 3'd1;
        end
        Commit: begin
          if (body_q[0] != 32'h0 && body_q[3] == 32'h0 && body_q[4] == 32'h0) begin
            dec_q.valid <= 1'b1;
            dec_q.surface <= 1'b1;
            dec_q.cmd <= APU_VIRGL_CREATE_OBJECT;
            dec_q.obj <= APU_VIRGL_OBJ_SURFACE;
            dec_q.nbody <= nbody_q;
            dec_q.handle <= body_q[0];
            dec_q.resource_id <= body_q[1];
            dec_q.format <= body_q[2];
            dec_q.next <= 32'd24;
            cpl_q.status <= APU_VGPU_DEC_OK;
          end else begin
            cpl_q.status <= APU_VGPU_DEC_FAULT;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(dec_o));
    `endif
  end
endmodule

// FirstCommandDecode (dec) enable-0 fixture: One decode of the first command in that buffer.
module g6lc_apu_vgpu_dec_fixture
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
  output apu_vgpu_dec_cpl_t cpl_o,
  output apu_vgpu_dec_t dec_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_dec #(.Enable(Enable)) i_dut (.*);
endmodule
