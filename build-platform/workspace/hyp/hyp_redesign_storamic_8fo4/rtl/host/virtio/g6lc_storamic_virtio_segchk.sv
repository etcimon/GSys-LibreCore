// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Pipelined balanced-tree segment checker for g6lc_storamic_virtio_blk
// (hyp8 8-FO4 redesign). Replaces the 107.1-FO4 serial MaxSegs 40-bit adder
// chain with a 2-stage balanced tree that settles during the multi-cycle SHdr
// DMA header fetch (0 extra cycles before SCheck).

module g6lc_storamic_virtio_segchk #(
  parameter int unsigned MaxSegs = 16,
  parameter int unsigned SegW    = $clog2(MaxSegs + 1)
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic [SegW-1:0]           last_i,
  input  logic [MaxSegs-1:0][63:0]  saddr_i,
  input  logic [MaxSegs-1:0][31:0]  slen_i,
  input  logic [MaxSegs-1:0]        swr_i,
  input  logic [63:0]               dma_base_i,
  input  logic [64:0]               win_end_i,
  input  logic [31:0]               type_i,
  input  logic [63:0]               sector_i,
  output logic [39:0]               data_total_o,
  output logic                      align_ok_o,
  output logic                      win_ok_o,
  output logic                      dir_ok_o,
  output logic                      ok_len_o,
  output logic [64:0]               end_sector_o
);
  localparam logic [31:0] TIn  = 32'd0;
  localparam logic [31:0] TOut = 32'd1;

  // Pad to 16 entries (or power-of-2 >= MaxSegs) for a balanced binary tree.
  localparam int unsigned PowN = (MaxSegs <= 4)  ? 4  :
                                 (MaxSegs <= 8)  ? 8  :
                                 (MaxSegs <= 16) ? 16 : 32;
  localparam int unsigned HalfN = PowN / 2;
  localparam int unsigned QtrN  = PowN / 4;

  // Stage 1: per-segment parallel validation + pair sums (depth 1 add).
  logic [PowN-1:0][39:0]  seg_len;
  logic [PowN-1:0]        seg_align_bad, seg_win_bad, seg_in_bad, seg_out_bad;
  for (genvar i = 0; i < PowN; i++) begin : gen_seg_eval
    if ((i >= 1) && (i < MaxSegs)) begin : gen_live
      logic active_i;
      logic [64:0] seg_end_i;
      assign active_i      = (i < int'(last_i));
      assign seg_len[i]    = active_i ? {8'd0, slen_i[i]} : 40'd0;
      assign seg_end_i     = {1'b0, saddr_i[i]} + 65'(slen_i[i]);
      assign seg_align_bad[i] = active_i &&
          ((saddr_i[i][2:0] != 3'd0) || (slen_i[i][2:0] != 3'd0) || (slen_i[i] == 32'd0));
      assign seg_win_bad[i] = active_i &&
          (({1'b0, saddr_i[i]} < {1'b0, dma_base_i}) || (seg_end_i > win_end_i));
      assign seg_in_bad[i]  = active_i && !swr_i[i];
      assign seg_out_bad[i] = active_i &&  swr_i[i];
    end else begin : gen_pad
      assign seg_len[i]       = 40'd0;
      assign seg_align_bad[i] = 1'b0;
      assign seg_win_bad[i]   = 1'b0;
      assign seg_in_bad[i]    = 1'b0;
      assign seg_out_bad[i]   = 1'b0;
    end
  end

  logic [HalfN-1:0][39:0] sum_l1;
  for (genvar p = 0; p < HalfN; p++) begin : gen_sum_l1
    assign sum_l1[p] = seg_len[2*p] + seg_len[2*p+1];
  end

  // Register stage 1 (captures while SHdr fetches header beat 0).
  logic [HalfN-1:0][39:0] sum_l1_q;
  logic                   align_ok_q, win_ok_q, in_dir_ok_q, out_dir_ok_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sum_l1_q     <= '0;
      align_ok_q   <= 1'b1;
      win_ok_q     <= 1'b1;
      in_dir_ok_q  <= 1'b1;
      out_dir_ok_q <= 1'b1;
    end else begin
      sum_l1_q     <= sum_l1;
      align_ok_q   <= !(|seg_align_bad);
      win_ok_q     <= !(|seg_win_bad);
      in_dir_ok_q  <= !(|seg_in_bad);
      out_dir_ok_q <= !(|seg_out_bad);
    end
  end

  // Stage 2: reduce 8 -> 2 sums and register (captures on SHdr beat 1).
  logic [1:0][39:0] sum_l3, sum_l3_q;
  if (HalfN >= 8) begin : gen_s2_8
    logic [3:0][39:0] sum_l2;
    for (genvar q = 0; q < 4; q++) begin : gen_sum_l2
      assign sum_l2[q] = sum_l1_q[2*q] + sum_l1_q[2*q+1];
    end
    assign sum_l3[0] = sum_l2[0] + sum_l2[1];
    assign sum_l3[1] = sum_l2[2] + sum_l2[3];
  end else if (HalfN >= 4) begin : gen_s2_4
    assign sum_l3[0] = sum_l1_q[0] + sum_l1_q[1];
    assign sum_l3[1] = sum_l1_q[2] + sum_l1_q[3];
  end else begin : gen_s2_2
    assign sum_l3[0] = sum_l1_q[0];
    assign sum_l3[1] = (HalfN > 1) ? sum_l1_q[1] : 40'd0;
  end

  logic align_ok_q2, win_ok_q2, in_dir_ok_q2, out_dir_ok_q2;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sum_l3_q      <= '0;
      align_ok_q2   <= 1'b1;
      win_ok_q2     <= 1'b1;
      in_dir_ok_q2  <= 1'b1;
      out_dir_ok_q2 <= 1'b1;
    end else begin
      sum_l3_q      <= sum_l3;
      align_ok_q2   <= align_ok_q;
      win_ok_q2     <= win_ok_q;
      in_dir_ok_q2  <= in_dir_ok_q;
      out_dir_ok_q2 <= out_dir_ok_q;
    end
  end

  // Stage 3: final 40-bit add registered during SParse (settles before SCheck).
  logic [39:0] final_sum_q;
  logic        ok_len_q, align_ok_q3, win_ok_q3, in_dir_ok_q3, out_dir_ok_q3;
  logic [39:0] final_sum_d;
  assign final_sum_d = sum_l3_q[0] + sum_l3_q[1];
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      final_sum_q   <= '0;
      ok_len_q      <= 1'b1;
      align_ok_q3   <= 1'b1;
      win_ok_q3     <= 1'b1;
      in_dir_ok_q3  <= 1'b1;
      out_dir_ok_q3 <= 1'b1;
    end else begin
      final_sum_q   <= final_sum_d;
      ok_len_q      <= (final_sum_d[8:0] == 9'd0) && (final_sum_d < 40'hFFFF_FFFF);
      align_ok_q3   <= align_ok_q2;
      win_ok_q3     <= win_ok_q2;
      in_dir_ok_q3  <= in_dir_ok_q2;
      out_dir_ok_q3 <= out_dir_ok_q2;
    end
  end

  assign data_total_o = final_sum_q;
  assign align_ok_o   = align_ok_q3;
  assign win_ok_o     = win_ok_q3;
  assign dir_ok_o     = (type_i == TIn)  ? in_dir_ok_q3 :
                        (type_i == TOut) ? out_dir_ok_q3 : 1'b1;
  assign ok_len_o     = ok_len_q;
  assign end_sector_o = {1'b0, sector_i} + {34'd0, final_sum_q[39:9]};
endmodule
