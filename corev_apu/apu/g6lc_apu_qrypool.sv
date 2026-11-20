// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded query pool.  Eight result slots, four open Begin windows.
// Counter layout and copy records come from g6lc_apu_qry_pkg, the
// same functions g6lc_apu_qrydelta exposes.  This pool is not wired
// into the product.  timestampValidBits stays 0.
//
// op_i: 0 reset, 1 write-timestamp, 2 begin, 3 end, 4 copy,
// 5 host readback, 6 submit-end.  stat_i is
// {fs_invocations, occlusion, ia_primitives, ia_vertices}.
// err_o refuses the command and changes nothing.  nrdy_o is only a
// host read whose range still holds an unavailable slot: the read
// still returns ordered values for the available slots and zeros for
// the others.  WAIT does not block.
module g6lc_apu_qrypool #(
  parameter int unsigned SLOTS = 8,
  parameter int unsigned OPEN  = 4,
  parameter int unsigned DST_W = 16
) (
  input  logic                     clk_i,
  input  logic                     rst_ni,
  input  logic                     req_i,
  input  logic [2:0]               op_i,
  input  logic [7:0]               qtype_i,
  input  logic [31:0]              mask_i,
  input  logic [15:0]              index_i,
  input  logic [15:0]              count_i,
  input  logic [31:0]              flags_i,
  input  logic [31:0]              sub_i,
  input  logic [31:0]              dst_off_i,
  input  logic [63:0]              stride_i,
  input  logic [31:0]              extent_i,
  input  logic [127:0]             stat_i,
  output logic                     err_o,
  output logic                     nrdy_o,
  output logic [4:0]               nw_o,
  output logic [9:0][31:0]         rec_o,
  output logic [DST_W-1:0][31:0]   dst_o
);
  import g6lc_apu_qry_pkg::*;
  localparam logic [2:0] OP_RST  = 3'd0;
  localparam logic [2:0] OP_TS   = 3'd1;
  localparam logic [2:0] OP_BEG  = 3'd2;
  localparam logic [2:0] OP_END  = 3'd3;
  localparam logic [2:0] OP_CPY  = 3'd4;
  localparam logic [2:0] OP_HOST = 3'd5;
  localparam logic [2:0] OP_SUB  = 3'd6;

  logic              av_q   [SLOTS];
  logic [3:0]        nc_q   [SLOTS];
  logic [3:0][31:0]  cw_q   [SLOTS];
  logic              ov_q   [OPEN];
  logic [15:0]       oi_q   [OPEN];
  logic [127:0]      os_q   [OPEN];
  logic [DST_W-1:0][31:0] dst_q;

  logic              hit_v, free_v, any_open, in_range, mask_bad;
  logic              range_ok, geom_bad, host_bad, copy_bad;
  logic [1:0]        hit, free_i;
  logic [2:0]        idx;
  logic [3:0]        nc_w, dn;
  logic [3:0][31:0]  dd;
  logic [127:0]      base_w;
  logic              use_st, slot_av, wide, with_av;
  logic [31:0]       fl_w, rec_bytes;
  logic [63:0]       span;
  logic [3:0]        st_n;
  logic [3:0][31:0]  st_w;
  logic [4:0]        nw_w;
  logic [9:0][31:0]  rec_w;
  logic [319:0]      rec_p;
  logic [DST_W-1:0][31:0] dst_n;
  integer            q, t, w;
  logic [63:0]       base_b, word_i;
  logic [4:0]        one_nw;
  logic [319:0]      one_rec;
  logic [127:0]      one_words;

  assign nc_w = (qtype_i == 8'd1)
      ? (4'(mask_i[0]) + 4'(mask_i[1]) + 4'(mask_i[2]) + 4'(mask_i[7]))
      : 4'd1;
  assign in_range = (index_i < 16'(SLOTS));
  assign idx = index_i[2:0];
  assign mask_bad = f_mask_bad(qtype_i, mask_i);
  assign range_ok = ({16'h0, index_i} + {16'h0, count_i}) <= SLOTS;
  assign wide = flags_i[0];
  assign with_av = flags_i[3];
  assign rec_bytes = f_rec_bytes(nc_w, wide, with_av);
  // 64-bit footprint.  A 32-bit sum wraps a stride near 2^32 into the
  // extent and would store the next record at the wrapped word.
  assign span = (count_i == 16'd0) ? 64'h0
      : ({32'h0, dst_off_i}
         + (64'(count_i) - 64'd1) * stride_i
         + {32'h0, rec_bytes});

  always_comb begin
    hit_v = 1'b0; hit = 2'd0;
    free_v = 1'b0; free_i = 2'd0;
    any_open = 1'b0;
    for (int k = 0; k < OPEN; k++) begin
      if (ov_q[k]) any_open = 1'b1;
      if (ov_q[k] && oi_q[k] == index_i && !hit_v) begin
        hit_v = 1'b1;
        hit = 2'(k);
      end
      if (!ov_q[k] && !free_v) begin
        free_v = 1'b1;
        free_i = 2'(k);
      end
    end
  end

  assign base_w = hit_v ? os_q[hit] : '0;
  assign use_st = (op_i == OP_CPY) || (op_i == OP_HOST);
  assign slot_av = in_range ? av_q[idx] : 1'b0;
  assign st_n = in_range ? nc_q[idx] : 4'd0;
  always_comb begin
    for (int c = 0; c < 4; c++)
      st_w[c] = in_range ? cw_q[idx][c] : 32'h0;
  end
  assign fl_w = use_st ? flags_i : 32'h0;

  g6lc_apu_qrydelta i_delta (
    .qtype_i(qtype_i), .mask_i(mask_i),
    .now_i(stat_i), .base_i(base_w),
    .slot_avail_i(use_st ? slot_av : 1'b1),
    .flags_i(fl_w),
    .use_stored_i(use_st),
    .stored_n_i(st_n), .stored_i(st_w),
    .n_o(dn), .delta_o(dd),
    .nw_o(nw_w), .rec_o(rec_w)
  );
  assign nw_o  = (use_st && count_i != 16'd0) ? nw_w : 5'd0;
  assign rec_o = (use_st && count_i != 16'd0) ? rec_w : '{default: '0};
  assign dst_o = dst_q;

  always_comb begin
    geom_bad = 1'b0;
    if (count_i != 16'd0) begin
      if (!range_ok) geom_bad = 1'b1;
      else if (dst_off_i[1:0] != 2'b00) geom_bad = 1'b1;
      else if (stride_i[1:0] != 2'b00 || stride_i[63:32] != 32'h0)
        geom_bad = 1'b1;
      else if (wide && dst_off_i[2]) geom_bad = 1'b1;
      else if (wide && count_i > 16'd1 && stride_i[2:0] != 3'b000)
        geom_bad = 1'b1;
      else if (count_i > 16'd1 && stride_i == 64'h0) geom_bad = 1'b1;
      else if (count_i > 16'd1 && stride_i < {32'h0, rec_bytes})
        geom_bad = 1'b1;
      else if (count_i == 16'd1 && stride_i != 64'h0 &&
               stride_i < {32'h0, rec_bytes}) geom_bad = 1'b1;
      else if (span > {32'h0, extent_i}) geom_bad = 1'b1;
      else if ((span >> 2) > 64'(DST_W)) geom_bad = 1'b1;
    end
  end

  assign copy_bad = |(flags_i & ~32'h9);
  assign host_bad = !flags_i[0] || |(flags_i & ~32'hB);

  always_comb begin
    nrdy_o = 1'b0;
    if (op_i == OP_HOST && count_i != 16'd0 && !geom_bad && !host_bad &&
        !mask_bad && sub_i == 32'h0) begin
      for (int s = 0; s < SLOTS; s++) begin
        if (s >= int'(index_i) && s < int'(index_i) + int'(count_i) &&
            !av_q[s])
          nrdy_o = 1'b1;
      end
    end
  end

  always_comb begin
    err_o = mask_bad;
    if (sub_i != 32'h0 &&
        (op_i == OP_TS || op_i == OP_BEG || op_i == OP_END))
      err_o = 1'b1;
    unique case (op_i)
      OP_RST: if (({16'h0, index_i} + {16'h0, count_i}) > SLOTS)
        err_o = 1'b1;
      OP_TS: if (qtype_i != 8'd2 || !in_range) err_o = 1'b1;
      OP_BEG: begin
        if (!in_range) err_o = 1'b1;
        else if (qtype_i == 8'd2) begin
          if (flags_i != 32'h0) err_o = 1'b1;
        end else if (qtype_i == 8'd0 || qtype_i == 8'd1) begin
          if (flags_i > 32'd1 || hit_v || !free_v) err_o = 1'b1;
        end else err_o = 1'b1;
      end
      OP_END: begin
        if (!in_range || flags_i != 32'h0) err_o = 1'b1;
        else if (qtype_i == 8'd2) err_o = err_o;
        else if (qtype_i == 8'd0 || qtype_i == 8'd1) begin
          if (!hit_v) err_o = 1'b1;
        end else err_o = 1'b1;
      end
      OP_CPY: if (geom_bad || copy_bad) err_o = 1'b1;
      OP_HOST: if (geom_bad || host_bad) err_o = 1'b1;
      OP_SUB: if (any_open) err_o = 1'b1;
      default: err_o = 1'b1;
    endcase
  end

  // Next destination image.  Held unless this command is a non-empty
  // copy or host read that the error term accepts.
  always_comb begin
    one_nw = 5'd0;
    one_rec = '0;
    one_words = '0;
    base_b = 64'h0;
    word_i = 64'h0;
    for (w = 0; w < DST_W; w++) dst_n[w] = dst_q[w];
    if ((op_i == OP_CPY || op_i == OP_HOST) && !err_o &&
        count_i != 16'd0) begin
      for (w = 0; w < DST_W; w++) begin
        if ((64'(w) << 2) >= {32'h0, dst_off_i} && (64'(w) << 2) < span)
          dst_n[w] = 32'h0;
      end
      for (q = 0; q < SLOTS; q++) begin
        if (q >= int'(index_i) && q < int'(index_i) + int'(count_i)) begin
          one_words = '0;
          for (t = 0; t < 4; t++)
            one_words[32*t +: 32] = cw_q[q][t];
          one_nw = f_rec(nc_q[q], one_words, av_q[q], wide, with_av, one_rec);
          base_b = {32'h0, dst_off_i}
                 + (64'(q) - 64'(index_i)) * stride_i;
          for (t = 0; t < 10; t++) begin
            word_i = (base_b >> 2) + 64'(t);
            if (t < int'(one_nw) && word_i < 64'(DST_W))
              dst_n[word_i[3:0]] = one_rec[32*t +: 32];
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < SLOTS; i++) begin
        av_q[i] <= 1'b0;
        nc_q[i] <= 4'd0;
        cw_q[i] <= '{default: '0};
      end
      for (int k = 0; k < OPEN; k++) begin
        ov_q[k] <= 1'b0;
        oi_q[k] <= '0;
        os_q[k] <= '0;
      end
      dst_q <= '{default: '0};
    end else if (req_i && !err_o) begin
      if ((op_i == OP_CPY || op_i == OP_HOST) && count_i != 16'd0)
        dst_q <= dst_n;
      unique case (op_i)
        OP_RST: begin
          for (int i = 0; i < SLOTS; i++) begin
            if (i >= int'(index_i) &&
                i < int'(index_i) + int'(count_i)) begin
              av_q[i] <= 1'b0;
              nc_q[i] <= nc_w;
              cw_q[i] <= '{default: '0};
            end
          end
        end
        OP_TS: begin
          av_q[idx] <= 1'b1;
          nc_q[idx] <= 4'd1;
          cw_q[idx] <= '{default: '0};
        end
        OP_BEG: begin
          if (qtype_i == 8'd2) begin
            av_q[idx] <= 1'b1;
            nc_q[idx] <= 4'd1;
            cw_q[idx] <= '{default: '0};
          end else begin
            ov_q[free_i] <= 1'b1;
            oi_q[free_i] <= index_i;
            os_q[free_i] <= stat_i;
          end
        end
        OP_END: begin
          if (qtype_i == 8'd2) begin
            av_q[idx] <= 1'b1;
            nc_q[idx] <= 4'd1;
            cw_q[idx] <= '{default: '0};
          end else begin
            ov_q[hit] <= 1'b0;
            av_q[idx] <= 1'b1;
            nc_q[idx] <= dn;
            for (int c = 0; c < 4; c++) cw_q[idx][c] <= dd[c];
          end
        end
        default: ;
      endcase
    end
  end

endmodule
