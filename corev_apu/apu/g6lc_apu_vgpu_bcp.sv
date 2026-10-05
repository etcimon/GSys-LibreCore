// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the top band of resource 1 from its backing address.
// 640 by 64 is 163840 bytes, 5120 beats of 32. The image is not
// stored. Beat 0's low word is kept. The ceiling color is not written.
// TEX is not executed. This is not g6lc_apu_vgpu_sxf and not
// g6lc_apu_vgpu_xfer.

// BandCopy (bcp): Band copy of resource 1. Default-off. Does not store the image.
module g6lc_apu_vgpu_bcp
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sxf_t sxf_i,
  input  apu_vgpu_sbk_t sbk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_bcp_cpl_t cpl_o,
  output apu_vgpu_bcp_t bcp_o,
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
    assign bcp_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|sxf_i) | (|sbk_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_bcp_cpl_t cpl_q;
    apu_vgpu_bcp_t bcp_q;
    logic [12:0] beat_q;
    logic [31:0] word_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;
    logic [63:0] issue_addr;
    logic last_beat;

    assign issue_addr = {32'h0, sbk_i.addr} + (64'(beat_q) << 5);
    assign last_beat = beat_q == (APU_VGPU_SCAN_BAND_BEATS - 13'd1);
    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = issue_addr;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_bcp_cpl_t'('0);
    assign bcp_o = bcp_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        bcp_q <= '0;
        beat_q <= '0;
        word_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (bcp_q.valid) begin
            cpl_q.status <= APU_VGPU_BCP_FAULT;
            state_q <= Done;
          end else if (!sxf_i.valid || !sbk_i.valid) begin
            cpl_q.status <= APU_VGPU_BCP_EMPTY;
            state_q <= Done;
          end else if (sxf_i.copied || sxf_i.word != APU_VGPU_CLEAR_WORD ||
                       sxf_i.width != APU_VGPU_SCAN_W ||
                       sxf_i.height != APU_VGPU_SCAN_BAND ||
                       sbk_i.resource_id != APU_VIRGL_RES_SCAN ||
                       sbk_i.length != APU_VGPU_SCAN_BYTES ||
                       sbk_i.addr == 32'h0 || sbk_i.addr[1:0] != 2'b00) begin
            cpl_q.status <= APU_VGPU_BCP_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= '0;
            word_q <= '0;
            bad_q <= 1'b0;
            addr_q <= {32'h0, sbk_i.addr};
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) begin
          addr_q <= issue_addr;
          state_q <= WaitRsp;
        end
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else begin
            if (beat_q == 13'd0) word_q <= rd_rsp_data_i[31:0];
            if (last_beat) state_q <= Commit;
            else begin
              beat_q <= beat_q + 13'd1;
              state_q <= Issue;
            end
          end
        end
        Commit: begin
          if (bad_q) begin
            cpl_q.status <= APU_VGPU_BCP_FAULT;
          end else begin
            bcp_q.valid <= 1'b1;
            bcp_q.beats <= APU_VGPU_SCAN_BAND_BEATS;
            bcp_q.bytes <= APU_VGPU_SCAN_BAND_BYTES;
            bcp_q.word <= word_q;
            cpl_q.status <= APU_VGPU_BCP_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(bcp_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_BCP_OK |->
        bcp_o.valid && bcp_o.beats == APU_VGPU_SCAN_BAND_BEATS &&
        bcp_o.bytes == APU_VGPU_SCAN_BAND_BYTES);
    `endif
  end
endmodule

// BandCopy (bcp) enable-0 fixture: Band copy of resource 1. Default-off. Does not store the image.
module g6lc_apu_vgpu_bcp_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sxf_t sxf_i,
  input  apu_vgpu_sbk_t sbk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_bcp_cpl_t cpl_o,
  output apu_vgpu_bcp_t bcp_o,
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
  g6lc_apu_vgpu_bcp #(.Enable(Enable)) i_dut (.*);
endmodule
