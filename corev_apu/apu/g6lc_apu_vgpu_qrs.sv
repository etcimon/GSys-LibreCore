// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read scene virtq_desc 2 at 64'h8800E120 after NEXT from desc 1.
// The WRITE is the 24-byte response at 64'h8800A800. The
// execbuffer descriptor, the transfer table, NEXT, and INDIRECT
// record nothing. This is later than g6lc_apu_vgpu_qex. This is
// not g6lc_apu_vgpu_qwd, not g6lc_apu_vgpu_avail, and not
// g6lc_apu_vgpu_nxc. g6lc_apu_vgpu_avail still rejects NEXT. The
// image is not kept. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneDesc2 (qrs): Scene virtq_desc 2 WRITE after that NEXT.
module g6lc_apu_vgpu_qrs
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qex_t qex_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qrs_cpl_t cpl_o,
  output apu_vgpu_qrs_t qrs_o,
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
    assign qrs_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|qex_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_qrs_cpl_t cpl_q;
    apu_vgpu_qrs_t qrs_q;
    logic [63:0] rsp_q, addr_q;
    logic [31:0] len_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'd16;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qrs_cpl_t'('0);
    assign qrs_o = qrs_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qrs_q <= '0;
        rsp_q <= '0;
        len_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qrs_q.valid) begin
            cpl_q.status <= APU_VGPU_QRS_FAULT;
            state_q <= Done;
          end else if (!qex_i.valid) begin
            cpl_q.status <= APU_VGPU_QRS_EMPTY;
            state_q <= Done;
          end else if (qex_i.nxt != 16'd2 ||
                       qex_i.nxt == 16'd1 ||
                       qex_i.exec_addr != APU_VGPU_EXEC_ADDR ||
                       qex_i.exec_addr == APU_VGPU_HDR_ADDR) begin
            cpl_q.status <= APU_VGPU_QRS_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_QRS_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_addr_i == APU_VGPU_QWD_ADDR ||
              rd_rsp_addr_i == APU_VGPU_QED_ADDR ||
              rd_rsp_addr_i == APU_VGPU_QSD_ADDR ||
              rd_rsp_len_i != 32'd16 ||
              rd_rsp_data_i[63:0] != APU_VGPU_RSP_ADDR ||
              rd_rsp_data_i[63:0] == APU_VGPU_RFW_ADDR ||
              rd_rsp_data_i[63:0] == APU_VGPU_EXEC_ADDR ||
              rd_rsp_data_i[95:64] != APU_VGPU_QWD_LEN ||
              rd_rsp_data_i[95:64] == APU_VGPU_SCENE_BYTES ||
              rd_rsp_data_i[95:64] == APU_VGPU_TFB_BYTES ||
              rd_rsp_data_i[127:96] != APU_VGPU_QWD_META ||
              rd_rsp_data_i[127:96] == APU_VGPU_QWD_NXT ||
              rd_rsp_data_i[127:96] == APU_VGPU_QWD_IND ||
              rd_rsp_data_i[127:96] == APU_VGPU_QFD_META ||
              rd_rsp_data_i[111:96] != VIRTQ_DESC_F_WRITE ||
              rd_rsp_data_i[111:96] == VIRTQ_DESC_F_NEXT ||
              rd_rsp_data_i[127:112] != 16'd0 ||
              rd_rsp_data_i[127:112] == 16'd2)
            bad_q <= 1'b1;
          rsp_q <= rd_rsp_data_i[63:0];
          len_q <= rd_rsp_data_i[95:64];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_QRS_FAULT;
          else begin
            qrs_q.valid <= 1'b1;
            qrs_q.rsp_addr <= rsp_q;
            qrs_q.rsp_len <= len_q;
            cpl_q.status <= APU_VGPU_QRS_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qrs_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QRS_OK |->
        qrs_o.valid && qrs_o.rsp_addr == APU_VGPU_RSP_ADDR &&
        qrs_o.rsp_addr != APU_VGPU_RFW_ADDR &&
        qrs_o.rsp_len == APU_VGPU_QWD_LEN);
    `endif
  end
endmodule

// SceneDesc2 (qrs) enable-0 fixture: Scene virtq_desc 2 WRITE after that NEXT.
module g6lc_apu_vgpu_qrs_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qex_t qex_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qrs_cpl_t cpl_o,
  output apu_vgpu_qrs_t qrs_o,
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
  g6lc_apu_vgpu_qrs #(.Enable(Enable)) i_dut (.*);
endmodule
