// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read virtq_desc 1 at 64'h880D0010 after NEXT from desc 0. The
// transfer is at 64'h88080000, length 96, NEXT to 2. The attach
// descriptor, the scene table, INDIRECT, and WRITE record
// nothing. This is later than g6lc_apu_vgpu_qhx. This is not
// g6lc_apu_vgpu_avail and not g6lc_apu_vgpu_txc.
// g6lc_apu_vgpu_avail still rejects NEXT. The image is not kept.
// The compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// TransferDesc1 (qfd): Guest descriptor 1 after that NEXT.
module g6lc_apu_vgpu_qfd
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qhx_t qhx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qfd_cpl_t cpl_o,
  output apu_vgpu_qfd_t qfd_o,
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
    assign qfd_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|qhx_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_qfd_cpl_t cpl_q;
    apu_vgpu_qfd_t qfd_q;
    logic [63:0] xfer_q, addr_q;
    logic [31:0] len_q;
    logic [15:0] nxt_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'd16;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qfd_cpl_t'('0);
    assign qfd_o = qfd_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qfd_q <= '0;
        xfer_q <= '0;
        len_q <= '0;
        nxt_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qfd_q.valid) begin
            cpl_q.status <= APU_VGPU_QFD_FAULT;
            state_q <= Done;
          end else if (!qhx_i.valid) begin
            cpl_q.status <= APU_VGPU_QFD_EMPTY;
            state_q <= Done;
          end else if (qhx_i.nxt != 16'd1 ||
                       qhx_i.nxt == 16'd2 ||
                       qhx_i.att_addr != APU_VGPU_RAB_CMD ||
                       qhx_i.att_addr == APU_VGPU_NXC_DESC) begin
            cpl_q.status <= APU_VGPU_QFD_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_QFD_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_addr_i == APU_VGPU_QFD_SCENE ||
              rd_rsp_addr_i == APU_VGPU_QHD_ADDR ||
              rd_rsp_addr_i == APU_VGPU_TXC_LAST ||
              rd_rsp_len_i != 32'd16 ||
              rd_rsp_data_i[63:0] != APU_VGPU_TFB_CMD ||
              rd_rsp_data_i[63:0] == APU_VGPU_RAB_CMD ||
              rd_rsp_data_i[95:64] != APU_VGPU_TFB_BYTES ||
              rd_rsp_data_i[95:64] == APU_VGPU_RAB_BYTES ||
              rd_rsp_data_i[127:96] != APU_VGPU_QFD_META ||
              rd_rsp_data_i[127:96] == APU_VGPU_QFD_IND ||
              rd_rsp_data_i[127:96] == APU_VGPU_QFD_WR ||
              rd_rsp_data_i[127:96] == APU_VGPU_QHD_META ||
              rd_rsp_data_i[111:96] != VIRTQ_DESC_F_NEXT ||
              rd_rsp_data_i[111:96] == VIRTQ_DESC_F_WRITE ||
              rd_rsp_data_i[127:112] != 16'd2 ||
              rd_rsp_data_i[127:112] == 16'd1)
            bad_q <= 1'b1;
          xfer_q <= rd_rsp_data_i[63:0];
          len_q <= rd_rsp_data_i[95:64];
          nxt_q <= rd_rsp_data_i[127:112];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_QFD_FAULT;
          else begin
            qfd_q.valid <= 1'b1;
            qfd_q.xfer_addr <= xfer_q;
            qfd_q.xfer_len <= len_q;
            qfd_q.nxt <= nxt_q;
            cpl_q.status <= APU_VGPU_QFD_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qfd_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QFD_OK |->
        qfd_o.valid && qfd_o.xfer_addr == APU_VGPU_TFB_CMD &&
        qfd_o.xfer_addr != APU_VGPU_RAB_CMD &&
        qfd_o.xfer_len == APU_VGPU_TFB_BYTES &&
        qfd_o.nxt == 16'd2);
    `endif
  end
endmodule

// TransferDesc1 (qfd) enable-0 fixture: Guest descriptor 1 after that NEXT.
module g6lc_apu_vgpu_qfd_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qhx_t qhx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qfd_cpl_t cpl_o,
  output apu_vgpu_qfd_t qfd_o,
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
  g6lc_apu_vgpu_qfd #(.Enable(Enable)) i_dut (.*);
endmodule
