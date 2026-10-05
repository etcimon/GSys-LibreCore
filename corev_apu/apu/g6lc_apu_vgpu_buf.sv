// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One read of the execbuffer named by a recorded SUBMIT_3D. The bytes
// arrive 32 at a time and stay in a byte memory. valid rises after the
// last good beat. A failed beat leaves valid clear and can be retried.
// A second read does not replace the buffer. This does not decode the
// commands, write the response, or draw.

// ExecBufferRead (buf): One read of the execbuffer named by that submit. Default-off. Not a command decode and not a draw.
// Interplay: Submit3dChain (sub) <-> ExecBufferRead (buf); CREATE/BIND spine. See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_buf
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sub_t sub_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_buf_cpl_t cpl_o,
  output apu_vgpu_buf_t buf_o,
  input  logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_i,
  output logic [31:0] peek_word_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign buf_o = '0;
    assign peek_word_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|sub_i) | (|peek_addr_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    localparam int unsigned BufBytes = APU_VGPU_SUB_MAX;
    localparam int unsigned BufAddrW = $clog2(BufBytes);
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;
    typedef struct packed {
      apu_vgpu_buf_status_e status;
      logic do_read;
      logic [31:0] ctx_id;
      logic [31:0] size;
      logic [63:0] addr;
    } dec_t;

    state_e state_q;
    apu_vgpu_buf_cpl_t cpl_q;
    apu_vgpu_buf_t buf_q;
    logic [7:0] mem [0:BufBytes-1];
    logic armed_q;
    logic [63:0] base_q, addr_q;
    logic [31:0] ctx_q, total_q, off_q, len_q;

    function automatic logic range_ok(
      input logic [63:0] addr, input logic [31:0] len
    );
      range_ok = addr != 64'h0 && addr[1:0] == 2'b00 && len != 32'h0 &&
                 len <= APU_VGPU_SUB_MAX && (addr + 64'(len)) >= addr;
    endfunction

    function automatic logic [31:0] beat_len(
      input logic [31:0] off, input logic [31:0] total
    );
      logic [31:0] remain;
      remain = total - off;
      beat_len = remain > APU_VGPU_BEAT_BYTES ? APU_VGPU_BEAT_BYTES : remain;
    endfunction

    function automatic dec_t decode(
      input apu_vgpu_sub_t sub,
      input logic already
    );
      decode = '0;
      if (!sub.valid) begin
        decode.status = APU_VGPU_BUF_EMPTY;
      end else if (already || !range_ok(sub.buf_addr, sub.size)) begin
        decode.status = APU_VGPU_BUF_FAULT;
      end else begin
        decode.status = APU_VGPU_BUF_OK;
        decode.do_read = 1'b1;
        decode.ctx_id = sub.ctx_id;
        decode.size = sub.size;
        decode.addr = sub.buf_addr;
      end
    endfunction

    assign buf_o = buf_q;
    assign peek_word_o = {
      mem[peek_addr_i + APU_VGPU_BUF_ADDRW'(3)],
      mem[peek_addr_i + APU_VGPU_BUF_ADDRW'(2)],
      mem[peek_addr_i + APU_VGPU_BUF_ADDRW'(1)],
      mem[peek_addr_i]
    };
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_buf_cpl_t'('0);
    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = len_q;
    assign rd_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        buf_q <= '0;
        mem <= '{default: '0};
        armed_q <= 1'b0;
        base_q <= '0;
        addr_q <= '0;
        ctx_q <= '0;
        total_q <= '0;
        off_q <= '0;
        len_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          dec_t got;
          got = decode(sub_i, buf_q.valid);
          if (!got.do_read) begin
            cpl_q <= '{status: got.status, ctx_id: '0, size: '0};
            state_q <= Done;
          end else begin
            ctx_q <= got.ctx_id;
            total_q <= got.size;
            base_q <= got.addr;
            off_q <= '0;
            addr_q <= got.addr;
            len_q <= beat_len(32'h0, got.size);
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic [31:0] next_off, sum;
          logic [BufAddrW-1:0] ia;
          next_off = off_q + len_q;
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q || rd_rsp_len_i != len_q) begin
            cpl_q <= '{status: APU_VGPU_BUF_BUS, ctx_id: '0, size: '0};
            state_q <= Done;
          end else begin
            for (int i = 0; i < APU_VGPU_BEAT_BYTES; i++) begin
              if (32'(i) < len_q) begin
                sum = off_q + 32'(i);
                ia = sum[BufAddrW-1:0];
                mem[ia] <= rd_rsp_data_i[i*8 +: 8];
              end
            end
            if (next_off >= total_q) begin
              buf_q.valid <= 1'b1;
              buf_q.ctx_id <= ctx_q;
              buf_q.size <= total_q;
              buf_q.buf_addr <= base_q;
              cpl_q <= '{status: APU_VGPU_BUF_OK, ctx_id: ctx_q, size: total_q};
              state_q <= Done;
            end else begin
              off_q <= next_off;
              addr_q <= base_q + next_off;
              len_q <= beat_len(next_off, total_q);
              state_q <= Issue;
            end
          end
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
      rd_valid_o && !rd_ready_i |=> rd_valid_o && $stable(rd_addr_o) &&
                     $stable(rd_len_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(buf_o));
    `endif
  end
endmodule

// ExecBufferRead (buf) enable-0 fixture: One read of the execbuffer named by that submit.
module g6lc_apu_vgpu_buf_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sub_t sub_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_buf_cpl_t cpl_o,
  output apu_vgpu_buf_t buf_o,
  input  logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_i,
  output logic [31:0] peek_word_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  g6lc_apu_vgpu_buf #(.Enable(Enable)) i_dut (.*);
endmodule
