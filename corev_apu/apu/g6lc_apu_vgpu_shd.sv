// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read virtq_desc 0 at 64'h8800E100 after ring[0] names it after
// scene QueueNotify. The header is at 64'h8800A000, length 32,
// NEXT to 1. The transfer table at 64'h880D0000, INDIRECT, and a
// jump record nothing. This is later than g6lc_apu_vgpu_srx.
// This is not g6lc_apu_vgpu_qhd, not g6lc_apu_vgpu_qsd, and not
// g6lc_apu_vgpu_avail. g6lc_apu_vgpu_avail still rejects NEXT. The
// image is not kept. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneHeaderAfterNotify (shd): Scene virtq_desc 0 after that ring name.
module g6lc_apu_vgpu_shd
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_srx_t srx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_shd_cpl_t cpl_o,
  output apu_vgpu_shd_t shd_o,
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
    assign shd_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|srx_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_shd_cpl_t cpl_q;
    apu_vgpu_shd_t shd_q;
    logic [63:0] hdr_q, addr_q;
    logic [31:0] len_q;
    logic [15:0] nxt_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'd16;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_shd_cpl_t'('0);
    assign shd_o = shd_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        shd_q <= '0;
        hdr_q <= '0;
        len_q <= '0;
        nxt_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (shd_q.valid) begin
            cpl_q.status <= APU_VGPU_SHD_FAULT;
            state_q <= Done;
          end else if (!srx_i.valid) begin
            cpl_q.status <= APU_VGPU_SHD_EMPTY;
            state_q <= Done;
          end else if (srx_i.desc_id != APU_VGPU_QRG_DESC ||
                       srx_i.desc_id == 16'd1) begin
            cpl_q.status <= APU_VGPU_SHD_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_SHD_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_addr_i == APU_VGPU_QHD_ADDR ||
              rd_rsp_addr_i == APU_VGPU_SRG_ADDR ||
              rd_rsp_len_i != 32'd16 ||
              rd_rsp_data_i[63:0] != APU_VGPU_HDR_ADDR ||
              rd_rsp_data_i[63:0] == APU_VGPU_RAB_CMD ||
              rd_rsp_data_i[95:64] != APU_VGPU_QSD_LEN ||
              rd_rsp_data_i[95:64] == APU_VGPU_RAB_BYTES ||
              rd_rsp_data_i[127:96] != APU_VGPU_QHD_META ||
              rd_rsp_data_i[127:96] == APU_VGPU_QHD_IND ||
              rd_rsp_data_i[127:96] == APU_VGPU_QHD_JUMP ||
              rd_rsp_data_i[111:96] != VIRTQ_DESC_F_NEXT ||
              rd_rsp_data_i[111:96] == VIRTQ_DESC_F_WRITE ||
              rd_rsp_data_i[127:112] != 16'd1 ||
              rd_rsp_data_i[127:112] == 16'd2)
            bad_q <= 1'b1;
          hdr_q <= rd_rsp_data_i[63:0];
          len_q <= rd_rsp_data_i[95:64];
          nxt_q <= rd_rsp_data_i[127:112];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_SHD_FAULT;
          else begin
            shd_q.valid <= 1'b1;
            shd_q.hdr_addr <= hdr_q;
            shd_q.hdr_len <= len_q;
            shd_q.nxt <= nxt_q;
            cpl_q.status <= APU_VGPU_SHD_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(shd_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SHD_OK |->
        shd_o.valid && shd_o.hdr_addr == APU_VGPU_HDR_ADDR &&
        shd_o.hdr_addr != APU_VGPU_RAB_CMD &&
        shd_o.hdr_len == APU_VGPU_QSD_LEN &&
        shd_o.nxt == 16'd1);
    `endif
  end
endmodule

// SceneHeaderAfterNotify (shd) enable-0 fixture: Scene virtq_desc 0 after that ring name.
module g6lc_apu_vgpu_shd_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_srx_t srx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_shd_cpl_t cpl_o,
  output apu_vgpu_shd_t shd_o,
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
  g6lc_apu_vgpu_shd #(.Enable(Enable)) i_dut (.*);
endmodule
