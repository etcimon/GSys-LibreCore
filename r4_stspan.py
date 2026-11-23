from pathlib import Path
p = Path('build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_desc_engine.sv')
s = p.read_text()

# 1) enum: add ST_SPAN (free slot 10)
old = """    ST_GEMM       = 4'd7,
    ST_WR_DONE    = 4'd8,"""
new = """    ST_GEMM       = 4'd7,
    ST_WR_DONE    = 4'd8,
    ST_SPAN       = 4'd10,"""
assert old in s; s = s.replace(old, new)

# 2) prev_state_q + span machinery decls (before the state register block)
old = """  state_e state_q, state_d;"""
new = """  state_e state_q, state_d, prev_state_q;
  // r7 R4: ST_SPAN computes the descriptor's three spans through
  // g6lc_ai_mul_seq instead of the in-check combinational functions.
  logic        sp_kick, spa_seen_q, spb_seen_q, spc_seen_q;
  logic        spa_done, spb_done, spc_done;
  logic [95:0] spa_prod, spb_prod;
  logic [63:0] spc_prod;
  logic [63:0] span_a_q, span_b_q, span_c_q;
  logic [63:0] sp_tail_b, sp_stride_a, sp_stride_b;
  logic [63:0] sp_prod_a, sp_prod_b;
  logic [2:0]  sp_fmt;"""
assert old in s; s = s.replace(old, new)

# 3) prev_state_q latch + seen flags + span regs (own always_ff, rank-0)
old = """  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q           <= 1'b0;"""
new = """  // r7 R4: ST_SPAN machinery -- prev_state for the kick edge, sticky
  // done flags (cleared on IDLE), span registers latched at each mul's
  // done with the functions' saturation arithmetic.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_state_q <= ST_IDLE;
      spa_seen_q   <= 1'b0; spb_seen_q <= 1'b0; spc_seen_q <= 1'b0;
      span_a_q     <= '0; span_b_q <= '0; span_c_q <= '0;
    end else begin
      prev_state_q <= state_q;
      if (state_q == ST_IDLE) begin
        spa_seen_q <= 1'b0; spb_seen_q <= 1'b0; spc_seen_q <= 1'b0;
      end else begin
        if (spa_done) spa_seen_q <= 1'b1;
        if (spb_done) spb_seen_q <= 1'b1;
        if (spc_done) spc_seen_q <= 1'b1;
      end
      if (spa_done)
        span_a_q <= (|spa_prod[95:64])                          ? {64{1'b1}}
                  : (sp_tail_b > ({64{1'b1}} - sp_prod_a))      ? {64{1'b1}}
                  : ((sp_prod_a + sp_tail_b) == '0)             ? 64'd1
                  :  sp_prod_a + sp_tail_b;
      if (spb_done)
        span_b_q <= (|spb_prod[95:64])                          ? {64{1'b1}}
                  : (sp_tail_b > ({64{1'b1}} - sp_prod_b))      ? {64{1'b1}}
                  : ((sp_prod_b + sp_tail_b) == '0)             ? 64'd1
                  :  sp_prod_b + sp_tail_b;
      if (spc_done)
        span_c_q <= (spc_prod > ({64{1'b1}} >> 2)) ? {64{1'b1}}
                  : spc_prod << 2;
    end
  end

  // Operand composition (ai_row_bytes = elems << elem shift): strides at
  // kick time from desc_q; tails are the k-element row bytes shared by A/B.
  assign sp_fmt      = desc_compute_numfmt(desc_q);
  assign sp_stride_a = 64'(g6lc_ai_island_cfg_pkg::ai_row_bytes(
      sp_fmt, 32'(desc_q.ld_ab[15:0])));
  assign sp_stride_b = 64'(g6lc_ai_island_cfg_pkg::ai_row_bytes(
      sp_fmt, 32'(desc_q.ld_ab[31:16])));
  assign sp_tail_b   = 64'(g6lc_ai_island_cfg_pkg::ai_row_bytes(
      sp_fmt, desc_q.k));
  assign sp_prod_a   = spa_prod[63:0];
  assign sp_prod_b   = spb_prod[63:0];
  assign sp_kick     = (state_q == ST_SPAN) && (prev_state_q != ST_SPAN);

  g6lc_ai_mul_seq #(.WA(32), .WB(64)) i_span_a_mul (
      .clk_i, .rst_ni,
      .start_i   (sp_kick),
      .a_i       (32'(desc_q.m) - 32'd1),
      .b_i       (sp_stride_a),
      .done_o    (spa_done),
      .product_o (spa_prod));
  g6lc_ai_mul_seq #(.WA(32), .WB(64)) i_span_b_mul (
      .clk_i, .rst_ni,
      .start_i   (sp_kick),
      .a_i       (32'(desc_q.n) - 32'd1),
      .b_i       (sp_stride_b),
      .done_o    (spb_done),
      .product_o (spb_prod));
  g6lc_ai_mul_seq #(.WA(32), .WB(32)) i_span_c_mul (
      .clk_i, .rst_ni,
      .start_i   (sp_kick),
      .a_i       (desc_q.m),
      .b_i       (desc_q.n),
      .done_o    (spc_done),
      .product_o (spc_prod));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q           <= 1'b0;"""
assert old in s; s = s.replace(old, new)

# 4) ST_PARSE transition to ST_SPAN
old = """        end else begin
          // Priority is clamped by software/S-mode policy; engine accepts 0..15.
          state_d = ST_CHK_A;
        end
      end"""
new = """        end else begin
          // Priority is clamped by software/S-mode policy; engine accepts 0..15.
          state_d = ST_SPAN;
        end
      end

      ST_SPAN: begin
        if (spa_seen_q && spb_seen_q && spc_seen_q) state_d = ST_CHK_A;
      end"""
assert old in s; s = s.replace(old, new)

# 5) check_len_o reads span registers
old = """        check_len_o = AddrWidth'(g6lc_ai_island_cfg_pkg::ai_bus_len(
            state_q == ST_CHK_A ? desc_q.ptr_a : desc_q.ptr_b,
            g6lc_ai_island_cfg_pkg::ai_operand_span(
                state_q == ST_CHK_A ? desc_q.m : desc_q.n,
                state_q == ST_CHK_A ? 32'(desc_q.ld_ab[15:0]) : 32'(desc_q.ld_ab[31:16]),
                desc_q.k, desc_compute_numfmt(desc_q)), BeatBytes));"""
new = """        check_len_o = AddrWidth'(g6lc_ai_island_cfg_pkg::ai_bus_len(
            state_q == ST_CHK_A ? desc_q.ptr_a : desc_q.ptr_b,
            state_q == ST_CHK_A ? span_a_q : span_b_q, BeatBytes));"""
assert old in s; s = s.replace(old, new)

old = """        check_len_o = AddrWidth'(g6lc_ai_island_cfg_pkg::ai_result_span(desc_q.m, desc_q.n));"""
new = """        check_len_o = AddrWidth'(span_c_q);"""
assert old in s; s = s.replace(old, new)

# 6) span_eq miter + counter
anchor = """      ST_CHK_DONE: begin
        // Null ptr_done: no completion word; else check writable before execute"""
miter = """  // pragma translate_off
  // r7 R4: the registered span must equal the function evaluated on the
  // same descriptor the checker sees -- per check state, with a counter.
  int unsigned g6lc_ai_span_eq;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) g6lc_ai_span_eq <= 0;
    else if (check_req_o) begin
      g6lc_ai_span_eq <= g6lc_ai_span_eq + 1;
      if (state_q == ST_CHK_A)
        assert (check_len_o == AddrWidth'(g6lc_ai_island_cfg_pkg::ai_bus_len(
            desc_q.ptr_a,
            g6lc_ai_island_cfg_pkg::ai_operand_span(
                desc_q.m, 32'(desc_q.ld_ab[15:0]), desc_q.k,
                desc_compute_numfmt(desc_q)), BeatBytes)))
          else $error("desc_engine: span_a mismatch span=%0d fn=%0d",
                      span_a_q, g6lc_ai_island_cfg_pkg::ai_operand_span(
                          desc_q.m, 32'(desc_q.ld_ab[15:0]), desc_q.k,
                          desc_compute_numfmt(desc_q)));
      if (state_q == ST_CHK_B)
        assert (check_len_o == AddrWidth'(g6lc_ai_island_cfg_pkg::ai_bus_len(
            desc_q.ptr_b,
            g6lc_ai_island_cfg_pkg::ai_operand_span(
                desc_q.n, 32'(desc_q.ld_ab[31:16]), desc_q.k,
                desc_compute_numfmt(desc_q)), BeatBytes)))
          else $error("desc_engine: span_b mismatch span=%0d fn=%0d",
                      span_b_q, g6lc_ai_island_cfg_pkg::ai_operand_span(
                          desc_q.n, 32'(desc_q.ld_ab[31:16]), desc_q.k,
                          desc_compute_numfmt(desc_q)));
      if (state_q == ST_CHK_C)
        assert (check_len_o == AddrWidth'(
            g6lc_ai_island_cfg_pkg::ai_result_span(desc_q.m, desc_q.n)))
          else $error("desc_engine: span_c mismatch span=%0d fn=%0d",
                      span_c_q,
                      g6lc_ai_island_cfg_pkg::ai_result_span(desc_q.m, desc_q.n));
    end
  end
  final $display("[equiv] g6lc_ai_desc_engine span_eq: checked=%0d",
                 g6lc_ai_span_eq);
  // pragma translate_on

""" + anchor
assert anchor in s; s = s.replace(anchor, miter)
p.write_text(s, newline='\n')
print('R4 ST_SPAN applied')
