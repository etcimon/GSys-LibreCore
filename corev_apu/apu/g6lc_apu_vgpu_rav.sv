// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read virtq_avail.idx at 64'h880D0100 after QueueNotify of
// control queue 0 after scene guest ack. The word is index 2.
// The scene ring at 64'h8800E200 and index 1 record nothing.
// This is later than g6lc_apu_vgpu_rny. This is not
// g6lc_apu_vgpu_qav, not g6lc_apu_vgpu_sav, not
// g6lc_apu_vgpu_avail, and not g6lc_apu_vgpu_txc.
// g6lc_apu_vgpu_avail still rejects NEXT. The image is not
// kept. The compiler TEX opcode still returns -26. This is not
// Mesa glReadPixels.

// TransferAvailAfterAck (rav): virtq_avail.idx 2 after that QueueNotify after scene guest ack.
module g6lc_apu_vgpu_rav
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rny_t rny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rav_cpl_t cpl_o,
  output apu_vgpu_rav_t rav_o,
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
    assign rav_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|rny_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rav_cpl_t cpl_q;
    apu_vgpu_rav_t rav_q;
    logic [15:0] idx_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'd4;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rav_cpl_t'('0);
    assign rav_o = rav_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rav_q <= '0;
        idx_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rav_q.valid) begin
            cpl_q.status <= APU_VGPU_RAV_FAULT;
            state_q <= Done;
          end else if (!rny_i.valid) begin
            cpl_q.status <= APU_VGPU_RAV_EMPTY;
            state_q <= Done;
          end else if (rny_i.qid != APU_VGPU_QNT_QUEUE ||
                       rny_i.qid == APU_VGPU_QNT_CURSOR ||
                       rny_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       rny_i.avail_idx == 16'd1) begin
            cpl_q.status <= APU_VGPU_RAV_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_QAV_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_addr_i == APU_VGPU_NXC_AVAIL ||
              rd_rsp_len_i != 32'd4 ||
              rd_rsp_data_i[31:0] != APU_VGPU_QAV_WORD ||
              rd_rsp_data_i[31:0] == APU_VGPU_QAV_SCENE ||
              rd_rsp_data_i[31:16] != APU_VGPU_TUW_IDXV ||
              rd_rsp_data_i[31:16] == 16'd1)
            bad_q <= 1'b1;
          idx_q <= rd_rsp_data_i[31:16];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_RAV_FAULT;
          else begin
            rav_q.valid <= 1'b1;
            rav_q.avail_idx <= idx_q;
            rav_q.addr <= APU_VGPU_QAV_ADDR;
            cpl_q.status <= APU_VGPU_RAV_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rav_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RAV_OK |->
        rav_o.valid && rav_o.avail_idx == APU_VGPU_TUW_IDXV &&
        rav_o.addr == APU_VGPU_QAV_ADDR &&
        rav_o.addr != APU_VGPU_NXC_AVAIL);
    `endif
  end
endmodule

// TransferAvailAfterAck (rav) enable-0 fixture: virtq_avail.idx 2 after that QueueNotify after scene guest ack.
module g6lc_apu_vgpu_rav_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rny_t rny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rav_cpl_t cpl_o,
  output apu_vgpu_rav_t rav_o,
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
  g6lc_apu_vgpu_rav #(.Enable(Enable)) i_dut (.*);
endmodule
