// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the QueueNotify word at 64'h880D0200 after scene guest
// ack. The low word is control queue 0. The cursor queue, the
// scene doorbell at 64'h8800E220, and the avail ring at
// 64'h880D0100 record nothing. This is later than
// g6lc_apu_vgpu_rnt. This is not g6lc_apu_vgpu_qnr and not
// g6lc_apu_virtio_mmio. The image is not kept. The compiler TEX
// opcode still returns -26. This is not Mesa glReadPixels.

// TransferNotifyAfterAckKeep (rnr): Guest keep of that notify word.
module g6lc_apu_vgpu_rnr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rnt_t rnt_i,
  input  apu_vgpu_rnx_t rnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnr_cpl_t cpl_o,
  output apu_vgpu_rnr_t rnr_o,
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
    assign rnr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|rnt_i) | (|rnx_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rnr_cpl_t cpl_q;
    apu_vgpu_rnr_t rnr_q;
    logic [31:0] qid_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'd4;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rnr_cpl_t'('0);
    assign rnr_o = rnr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rnr_q <= '0;
        qid_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rnr_q.valid) begin
            cpl_q.status <= APU_VGPU_RNR_FAULT;
            state_q <= Done;
          end else if (!rnt_i.valid || !rnx_i.valid) begin
            cpl_q.status <= APU_VGPU_RNR_EMPTY;
            state_q <= Done;
          end else if (rnt_i.qid != APU_VGPU_QNT_QUEUE ||
                       rnt_i.qid == APU_VGPU_QNT_CURSOR ||
                       rnt_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       rnt_i.addr != APU_VGPU_QNT_ADDR ||
                       rnt_i.addr == APU_VGPU_TXC_AVAIL || rnt_i.addr == APU_VGPU_SNT_ADDR ||
                       rnx_i.avail_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_RNR_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            qid_q <= rnt_i.qid;
            addr_q <= APU_VGPU_QNT_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_addr_i == APU_VGPU_TXC_AVAIL || rd_rsp_addr_i == APU_VGPU_SNT_ADDR ||
              rd_rsp_len_i != 32'd4 ||
              rd_rsp_data_i[31:0] != APU_VGPU_QNT_QUEUE ||
              rd_rsp_data_i[31:0] == APU_VGPU_QNT_CURSOR)
            bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_RNR_FAULT;
          else begin
            rnr_q.valid <= 1'b1;
            rnr_q.qid <= qid_q;
            rnr_q.avail_idx <= APU_VGPU_TUW_IDXV;
            rnr_q.addr <= APU_VGPU_QNT_ADDR;
            cpl_q.status <= APU_VGPU_RNR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rnr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RNR_OK |->
        rnr_o.valid && rnr_o.qid == APU_VGPU_QNT_QUEUE &&
        rnr_o.addr != APU_VGPU_TXC_AVAIL && rnr_o.addr != APU_VGPU_SNT_ADDR);
    `endif
  end
endmodule

// TransferNotifyAfterAckKeep (rnr) enable-0 fixture: Guest keep of that notify word.
module g6lc_apu_vgpu_rnr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rnt_t rnt_i,
  input  apu_vgpu_rnx_t rnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnr_cpl_t cpl_o,
  output apu_vgpu_rnr_t rnr_o,
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
  g6lc_apu_vgpu_rnr #(.Enable(Enable)) i_dut (.*);
endmodule
