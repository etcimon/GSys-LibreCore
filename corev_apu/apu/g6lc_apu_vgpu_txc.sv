// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the 64 by 64 transfer descriptor chain from guest memory after
// the interrupt is acked. Beat 0 at 64'h880D0000 carries descriptor 0
// (attach at 64'h88090000, NEXT to 1) and descriptor 1 (transfer at
// 64'h88080000, NEXT to 2). Beat 1 carries descriptor 2 (24-byte WRITE
// at 64'h880A0000). Beat 2 at 64'h880D0100 is avail index 2 naming
// descriptor 0. INDIRECT, a broken link, and the scene index record
// nothing. This is later than g6lc_apu_vgpu_tax. This is not
// g6lc_apu_vgpu_avail, not g6lc_apu_vgpu_chn, and not
// g6lc_apu_vgpu_nxc. g6lc_apu_vgpu_avail still rejects NEXT. A failed
// beat stops the read. The image is not kept. TEX is not the compiler
// opcode. This is not Mesa glReadPixels.

// TransferChain (txc): Guest descriptor chain of the 64 by 64 transfer.
module g6lc_apu_vgpu_txc
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tax_t tax_i,
  input  apu_vgpu_rax_t rax_i,
  input  apu_vgpu_tfx_t tfx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_txc_cpl_t cpl_o,
  output apu_vgpu_txc_t txc_o,
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
  localparam logic [31:0] D0Meta = {16'd1, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D1Meta = {16'd2, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D2Meta = {16'd0, VIRTQ_DESC_F_WRITE};
  localparam logic [31:0] AvailWord = {16'd2, 16'h0};

  function automatic logic beat_bad(input logic [1:0] beat, input logic [255:0] data);
    if (beat == 2'd0) begin
      beat_bad = data[63:0] != APU_VGPU_RAB_CMD ||
                 data[95:64] != APU_VGPU_RAB_BYTES ||
                 data[127:96] != D0Meta ||
                 data[191:128] != APU_VGPU_TFB_CMD ||
                 data[223:192] != APU_VGPU_TFB_BYTES ||
                 data[255:224] != D1Meta;
    end else if (beat == 2'd1) begin
      beat_bad = data[63:0] != APU_VGPU_RFW_ADDR ||
                 data[95:64] != VGPU_RESP_HDR_BYTES ||
                 data[127:96] != D2Meta;
    end else begin
      beat_bad = data[31:0] != AvailWord || data[47:32] != 16'd0;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign txc_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|tax_i) | (|rax_i) |
                        (|tfx_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_txc_cpl_t cpl_q;
    apu_vgpu_txc_t txc_q;
    logic [1:0] beat_q;
    logic [15:0] head_q, avail_q;
    logic [31:0] att_len_q;
    logic [63:0] att_addr_q, xfer_addr_q, rsp_addr_q, addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_txc_cpl_t'('0);
    assign txc_o = txc_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        txc_q <= '0;
        beat_q <= 2'd0;
        head_q <= '0;
        avail_q <= '0;
        att_len_q <= '0;
        att_addr_q <= '0;
        xfer_addr_q <= '0;
        rsp_addr_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (txc_q.valid) begin
            cpl_q.status <= APU_VGPU_TXC_FAULT;
            state_q <= Done;
          end else if (!tax_i.valid || !rax_i.valid || !tfx_i.valid) begin
            cpl_q.status <= APU_VGPU_TXC_EMPTY;
            state_q <= Done;
          end else if (tax_i.ack != APU_VGPU_TIW_REASON ||
                       tax_i.remain != APU_VGPU_VAW_CLEAR ||
                       tax_i.used_idx != APU_VGPU_TUW_IDXV ||
                       tax_i.used_idx == 16'd1 ||
                       rax_i.length != APU_VGPU_GBD_BYTES ||
                       rax_i.addr != APU_VGPU_RPW_DST ||
                       rax_i.resource_id != APU_VIRGL_RES_RT ||
                       tfx_i.stride != APU_VGPU_TFB_STRIDE ||
                       tfx_i.x != 16'd0 ||
                       tfx_i.y != 16'd0 ||
                       tfx_i.res_w != APU_VGPU_RT_W) begin
            cpl_q.status <= APU_VGPU_TXC_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 2'd0;
            head_q <= '0;
            avail_q <= '0;
            att_len_q <= '0;
            att_addr_q <= '0;
            xfer_addr_q <= '0;
            rsp_addr_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_TXC_DESC;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_addr_i == APU_VGPU_NXC_DESC ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES);
          if (bad_bus || beat_bad(beat_q, rd_rsp_data_i)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 2'd0) begin
            att_addr_q <= rd_rsp_data_i[63:0];
            att_len_q <= rd_rsp_data_i[95:64];
            xfer_addr_q <= rd_rsp_data_i[191:128];
            beat_q <= 2'd1;
            addr_q <= APU_VGPU_TXC_LAST;
            state_q <= Issue;
          end else if (beat_q == 2'd1) begin
            rsp_addr_q <= rd_rsp_data_i[63:0];
            beat_q <= 2'd2;
            addr_q <= APU_VGPU_TXC_AVAIL;
            state_q <= Issue;
          end else begin
            avail_q <= rd_rsp_data_i[31:16];
            head_q <= rd_rsp_data_i[47:32];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || head_q != 16'd0 || avail_q != APU_VGPU_TUW_IDXV ||
              avail_q == 16'd1 || att_len_q != APU_VGPU_RAB_BYTES ||
              att_addr_q != APU_VGPU_RAB_CMD ||
              att_addr_q == APU_VGPU_NXC_DESC ||
              xfer_addr_q != APU_VGPU_TFB_CMD ||
              rsp_addr_q != APU_VGPU_RFW_ADDR ||
              rsp_addr_q == APU_VGPU_RSP_ADDR ||
              att_addr_q == rsp_addr_q ||
              head_q == avail_q)
            cpl_q.status <= APU_VGPU_TXC_FAULT;
          else begin
            txc_q.valid <= 1'b1;
            txc_q.head <= head_q;
            txc_q.avail_idx <= avail_q;
            txc_q.att_len <= att_len_q;
            txc_q.att_addr <= att_addr_q;
            txc_q.xfer_addr <= xfer_addr_q;
            txc_q.rsp_addr <= rsp_addr_q;
            cpl_q.status <= APU_VGPU_TXC_OK;
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
      rd_valid_o && !rd_ready_i |=> rd_valid_o && $stable(rd_addr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TXC_OK |->
        txc_o.valid && txc_o.head == 16'd0 &&
        txc_o.avail_idx == APU_VGPU_TUW_IDXV &&
        txc_o.att_addr != APU_VGPU_NXC_DESC &&
        txc_o.rsp_addr != APU_VGPU_RSP_ADDR);
    `endif
  end
endmodule

// TransferChain (txc) enable-0 fixture: Guest descriptor chain of the 64 by 64 transfer.
module g6lc_apu_vgpu_txc_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tax_t tax_i,
  input  apu_vgpu_rax_t rax_i,
  input  apu_vgpu_tfx_t tfx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_txc_cpl_t cpl_o,
  output apu_vgpu_txc_t txc_o,
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
  g6lc_apu_vgpu_txc #(.Enable(Enable)) i_dut (.*);
endmodule
