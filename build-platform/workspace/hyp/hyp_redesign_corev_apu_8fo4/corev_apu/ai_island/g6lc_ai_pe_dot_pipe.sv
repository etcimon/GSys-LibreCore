// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Pipelined integer (INT8 / packed-INT4) dot product -- the registered form
// of g6lc_ai_pe_dot for the live PeLanes=256 cell.
//
// Why. The combinational g6lc_ai_pe_dot is one 8x8 signed multiply followed
// by a ceil(log2(2*Lanes))-level 32-bit adder tree in a single cycle: at
// Lanes=256 that is nine carry-propagate adds behind a multiplier, measured
// at ~130 structural FO4 (architecture/ai-matrix/AI-ISLAND-TIMING.md), i.e.
// a ~385 MHz island on a 20 ps/FO4 process against the 2 GHz the 2.048 TOPS
// nameplate assumes. The floating path already pipelines one tree level per
// stage (g6lc_ai_pe_dot_float_pipe); the integer path -- the one that
// carries the dense INT8 TOPS figure -- did not. This module gives it the
// same shape so a register sits between every pair of adder levels and the
// multiply is itself two stages.
//
// Stages (Latency = $clog2(Lanes) + 5, identical to the float pipe so the
// sequencer's single metadata shift register and dot_pending counter serve
// both; one dot per cycle once filled):
//   M1  per product: the partial-product ROWS of the two half products --
//       pp_lo[r] = b[3:0][r] ? (a << r) : 0 for r=0..3 (unsigned nibble,
//       sign-extended a), pp_hi[r] likewise for the signed nibble with the
//       Baugh-Wooley sign row pp_hi[3] = b[7] ? -(a << 3) : 0 -- registered
//       as rows: an AND level behind the operand unpack, no carry chain;
//   M2  two 4-operand sums p_lo = sum(pp_lo), p_hi = sum(pp_hi), registered;
//   M3  p = p_lo + (p_hi << 4) masked by the lane valid: the exact 16-bit
//       signed product (a*b = a*b_lo + 16*a*b_hi);
//   T1..Tk  balanced signed adder tree, one level per stage, operands
//       growing one bit per level (16 + level); k = $clog2(2*Lanes);
//   O1  sign-extend to the 32-bit wrapped sum; one output register.
//
// Bit-identity. The combinational tree sums 32-bit sign-extended products with
// wrapping addition; 2*Lanes products of magnitude <= 2^14 never exceed
// 2^(14 + k) <= 2^24 in absolute value for Lanes <= 512, so the narrow
// growing-width tree computes the same mathematical sum and its sign
// extension equals the 32-bit wrapped result. INT4 unpacking is the same as
// the combinational module (two sign-extended nibbles per byte, upper slot
// zero for 8-bit formats), so the existing GEMM goldens are the regression.
//
// Timing (structural, not STA): the longest reg->reg cone is one 8x4
// signed multiply (M1) or one (16+k)-bit add (Tk) -- of the order of 10
// FO4 on the fo4-v1 model, against ~130 for the combinational cell.
// Area: the tree registers are 2*Lanes*(16..16+k) bits, not 2*Lanes*32.
//
// Not a throughput number: the MAC issue rate is still bounded by the
// operand port (architecture/ai-matrix/scaling-100tops.md §4.2).

module g6lc_ai_pe_dot_pipe #(
    parameter int unsigned Lanes = 4
) (
    input  logic               clk_i,
    input  logic               rst_ni,
    input  logic               start_i,
    input  logic signed [7:0]  a_i     [Lanes],
    input  logic signed [7:0]  b_i     [Lanes],
    input  logic               valid_i [Lanes],
    input  logic        [2:0]  numfmt_i,  // AI_FMT_*; only INT4 changes unpacking
    output logic               valid_o,
    output logic        [31:0] sum_o
);

  localparam logic [2:0] AI_FMT_INT4 = 3'd1;

  // 2*Lanes product slots (INT4 fills both per byte), padded to a power of
  // two so every tree level is a clean pairing.
  localparam int unsigned NP     = 2 * Lanes;
  localparam int unsigned LEVELS = (NP <= 1) ? 1 : $clog2(NP);
  localparam int unsigned P2     = 1 << LEVELS;
  // M1/M2/M3 + LEVELS tree stages + O1/O2. Both numeric pipelines return
  // after $clog2(Lanes)+6 sampled edges, sharing GEMM's metadata pipeline.
  localparam int unsigned LATENCY = LEVELS + 5;
  // Widest tree node: products are 16-bit signed, one bit per level.
  localparam int unsigned WMAX = 16 + LEVELS;

  // ---------------------------------------------------------------------------
  // Operand unpack (combinational into M1): per product slot the two 8-bit
  // signed operands, as the combinational cell forms them.
  // ---------------------------------------------------------------------------
  logic signed [7:0] op_a [P2];
  logic signed [7:0] op_b [P2];
  logic              op_v [P2];
  logic              fmt_int4;
  assign fmt_int4 = (numfmt_i == AI_FMT_INT4);
  // Per-slot generate: s < NP and s[0] are elaboration constants, so each
  // operand is ONE continuous assign (no default-then-overwrite chain).
  // Unused slots feed don't-care operands; op_v zeroes their M1 rows.
  for (genvar s = 0; s < P2; s++) begin : gen_unpack
    if (s < NP) begin : g_used
      if (s[0]) begin : g_odd
        // Odd slots exist only for INT4 (hi element); their operands have
        // no fmt select at all. Dead under INT8 via op_v.
        assign op_a[s] = $signed(a_i[s>>1][7:4]);
        assign op_b[s] = $signed(b_i[s>>1][7:4]);
        assign op_v[s] = fmt_int4 & valid_i[s>>1];
      end else begin : g_even
        // The operand's low nibble is format-independent (a[3:0]/b[3:0]
        // serve both int8 and int4-lo); fmt_int4 reaches only the upper
        // nibble (sign-extension vs raw bits) -- a 4-bit late select
        // instead of an 8-bit select in series with the row gates.
        assign op_a[s][3:0] = a_i[s>>1][3:0];
        assign op_a[s][7:4] = fmt_int4 ? {4{a_i[s>>1][3]}}
                                       : a_i[s>>1][7:4];
        assign op_b[s][3:0] = b_i[s>>1][3:0];
        assign op_b[s][7:4] = fmt_int4 ? {4{b_i[s>>1][3]}}
                                       : b_i[s>>1][7:4];
        assign op_v[s]      = valid_i[s>>1];
      end
    end else begin : g_pad
      assign op_a[s] = '0;
      assign op_b[s] = '0;
      assign op_v[s] = 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // M1: partial-product rows. a (signed 8) x b[3:0] (unsigned 4): four rows
  // b[r] ? (a << r) : 0 sign-extended to 13 bits; a x b[7:4] (signed 4):
  // three positive rows plus the Baugh-Wooley inverted sign row ~(a << 3)
  // with the +1 correction carried on m1_b7_q into the M2 hi sum. Rows are
  // AND-gated shifted operands -- no carry propagates across this stage.
  // ---------------------------------------------------------------------------
  logic signed [12:0] m1_pp_lo_q [P2][4];
  logic signed [11:0] m1_pp_hi_q [P2][4];
  logic               m1_b7_q  [P2];   // b[7]&live, feeds the +1 correction
  logic               m1_start_q;
  // Combinational rows (non-delayed array writes); one delayed assign per
  // array keeps the register legal at P2=512 (BLKLOOPINIT). Lane-valid is
  // folded into the row enables (start_i && op_v[s]): a masked lane drives
  // every row and the b7 carry to zero, so M3 is the bare lo + hi<<4.
  logic signed [12:0] m1_pp_lo_d [P2][4];
  logic signed [11:0] m1_pp_hi_d [P2][4];
  logic               m1_b7_d   [P2];
  logic               m1_live   [P2];
  always_comb begin
    for (int unsigned s = 0; s < P2; s++) begin
      m1_live[s] = start_i && op_v[s];
      for (int unsigned r = 0; r < 4; r++)
        m1_pp_lo_d[s][r] = (op_b[s][r] && m1_live[s])
                         ? (13'($signed(op_a[s])) <<< r) : 13'sd0;
      for (int unsigned r = 0; r < 3; r++)
        m1_pp_hi_d[s][r] = (op_b[s][4+r] && m1_live[s])
                         ? (12'($signed(op_a[s])) <<< r) : 12'sd0;
`ifdef G6LC_MUT_AI_PP_SIGNROW
      // Review mutant: sign row taken positive, correction dropped
      // (INT8 neg x neg fails).
      m1_pp_hi_d[s][3] = (op_b[s][7] && m1_live[s])
                       ? (12'($signed(op_a[s])) <<< 3) : 12'sd0;
      m1_b7_d[s]       = 1'b0;
`else
      // Baugh-Wooley without the negate: -a<<3 = ~(a<<3) + 1; the +1
      // enters the M2 hi sum as a fifth operand carried on m1_b7_q.
      m1_pp_hi_d[s][3] = (op_b[s][7] && m1_live[s])
                       ? ~(12'($signed(op_a[s])) <<< 3) : 12'sd0;
      m1_b7_d[s]       = op_b[s][7] && m1_live[s];
`endif
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m1_start_q <= 1'b0;
      m1_pp_lo_q <= '{default:'{default:'0}};
      m1_pp_hi_q <= '{default:'{default:'0}};
      m1_b7_q    <= '{default:'0};
    end else begin
      m1_start_q <= start_i;
      m1_pp_lo_q <= m1_pp_lo_d;
      m1_pp_hi_q <= m1_pp_hi_d;
      m1_b7_q    <= m1_b7_d;
    end
  end

  // ---------------------------------------------------------------------------
  // M2: two 4-operand row sums. p_lo fits 13-bit signed (a*15 >= -1920);
  // p_hi fits 12-bit signed (|a*b_hi| <= 1024).
  // ---------------------------------------------------------------------------
  logic signed [12:0] m2_lo_q [P2];
  logic signed [11:0] m2_hi_q [P2];
  logic               m2_start_q;
  logic signed [12:0] m2_lo_d [P2];
  logic signed [11:0] m2_hi_d [P2];
  always_comb begin
    for (int unsigned s = 0; s < P2; s++) begin
      m2_lo_d[s] = m1_pp_lo_q[s][0] + m1_pp_lo_q[s][1]
                 + m1_pp_lo_q[s][2] + m1_pp_lo_q[s][3];
      // 5th operand is the Baugh-Wooley +1 carried on m1_b7_q.
      m2_hi_d[s] = m1_pp_hi_q[s][0] + m1_pp_hi_q[s][1]
                 + m1_pp_hi_q[s][2] + m1_pp_hi_q[s][3]
                 + 12'({11'd0, m1_b7_q[s]});
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m2_start_q <= 1'b0;
      m2_lo_q    <= '{default:'0};
      m2_hi_q    <= '{default:'0};
    end else begin
      m2_start_q <= m1_start_q;
      m2_lo_q    <= m2_lo_d;
      m2_hi_q    <= m2_hi_d;
    end
  end

  // ---------------------------------------------------------------------------
  // M3: full 16-bit product. Masked lanes already contribute zero through
  // the M1 row enables, so this stage is the bare lo + hi<<4.
  // ---------------------------------------------------------------------------
  logic signed [15:0] m3_q [P2];
  logic               m3_start_q;
  logic signed [15:0] m3_d [P2];
  always_comb begin
    for (int unsigned s = 0; s < P2; s++)
      m3_d[s] = 16'($signed(m2_lo_q[s])) + (16'($signed(m2_hi_q[s])) <<< 4);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m3_start_q <= 1'b0;
      m3_q       <= '{default:'0};
    end else begin
      m3_start_q <= m2_start_q;
      m3_q       <= m3_d;
    end
  end

  // ---------------------------------------------------------------------------
  // T1..Tk: balanced tree, one level per stage, exact-width arrays. Level l
  // holds P2>>l nodes of (16+l) bits in its own generate scope; level 1 reads
  // M3, level l reads gen_lvl[l-1] directly -- no padded array, no guard.
  // ---------------------------------------------------------------------------
  logic tree_start_q [LEVELS];
  for (genvar l = 1; l <= int'(LEVELS); l++) begin : gen_lvl
    localparam int unsigned N = P2 >> l;
    logic signed [15+l:0] lvl_q [N];
    logic signed [15+l:0] lvl_d [N];
    if (l == 1) begin : gen_src_m3
      always_comb begin
        for (int unsigned i = 0; i < N; i++) begin
`ifdef G6LC_MUT_AI_TREE_LSB
          // Review mutant: odd operand's LSB dropped.
          lvl_d[i] = $signed(m3_q[2*i]) +
                     $signed({m3_q[2*i+1][15:1], 1'b0});
`else
          lvl_d[i] = $signed(m3_q[2*i]) + $signed(m3_q[2*i+1]);
`endif
        end
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          tree_start_q[l-1] <= 1'b0;
          lvl_q <= '{default:'0};
        end else begin
          tree_start_q[l-1] <= m3_start_q;
          lvl_q <= lvl_d;
        end
      end
    end else begin : gen_src_prev
      always_comb begin
        for (int unsigned i = 0; i < N; i++) begin
`ifdef G6LC_MUT_AI_TREE_LSB
          lvl_d[i] = $signed(gen_lvl[l-1].lvl_q[2*i]) +
            $signed({gen_lvl[l-1].lvl_q[2*i+1][15+l-1:1], 1'b0});
`else
          lvl_d[i] = $signed(gen_lvl[l-1].lvl_q[2*i]) +
                     $signed(gen_lvl[l-1].lvl_q[2*i+1]);
`endif
        end
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          tree_start_q[l-1] <= 1'b0;
          lvl_q <= '{default:'0};
        end else begin
          tree_start_q[l-1] <= tree_start_q[l-2];
          lvl_q <= lvl_d;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // O1/O2: extend the sum and match the float pipeline's decode-stage latency.
  // ---------------------------------------------------------------------------
  logic o1_valid_q;
  logic [31:0] o1_sum_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      o1_valid_q <= 1'b0;
      o1_sum_q <= '0;
      valid_o <= 1'b0;
      sum_o   <= '0;
    end else begin
      o1_valid_q <= tree_start_q[LEVELS-1];
      o1_sum_q <= 32'($signed(gen_lvl[LEVELS].lvl_q[0]));
      valid_o <= o1_valid_q;
      sum_o <= o1_sum_q;
    end
  end

  // pragma translate_off
  initial begin
    assert (Lanes >= 1) else $error("g6lc_ai_pe_dot_pipe: Lanes must be >= 1");
    // The narrow tree is exact only while 2*Lanes*2^14 < 2^31.
    assert (WMAX <= 31)
      else $error("g6lc_ai_pe_dot_pipe: Lanes=%0d exceeds the exact-sum width", Lanes);
    // Shared handshake with g6lc_ai_pe_dot_float_pipe: equal latency.
    assert (LATENCY == $clog2(Lanes < 1 ? 1 : Lanes) + 6)
      else $error("g6lc_ai_pe_dot_pipe: latency %0d != float pipe %0d",
                  LATENCY, $clog2(Lanes) + 6);
  end

  // B1 reference: the pre-rewrite two-multiplier product computed from the
  // same operand values registered through the M1/M2 delay line, asserted
  // against m3_q every cycle. Catches a wrong row/sign by gold-standard.
  // Per-element genvar blocks: Verilator cannot do delayed array writes
  // inside runtime loops at this scale (BLKLOOPINIT).
  int unsigned pp_eq_cnt;
  always_ff @(posedge clk_i or negedge rst_ni)
    pp_eq_cnt <= !rst_ni ? 0 : pp_eq_cnt + 1;
  for (genvar gs = 0; gs < int'(P2); gs++) begin : gen_pp_ref
    logic signed [7:0]  a1, a2, b1, b2;
    logic               v1, v2;
    logic signed [15:0] pref;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        a1 <= '0; a2 <= '0; b1 <= '0; b2 <= '0;
        v1 <= 1'b0; v2 <= 1'b0; pref <= '0;
      end else begin
        a1 <= op_a[gs]; b1 <= op_b[gs];
        v1 <= start_i && op_v[gs];
        a2 <= a1; b2 <= b1; v2 <= v1;
        pref <= v2 ? 16'($signed(a2) * $signed(b2)) : 16'sd0;
        g6lc_ai_pp_eq: assert (m3_q[gs] == pref)
          else $error("g6lc_ai_pe_dot_pipe: pp_eq mismatch slot %0d", gs);
      end
    end
  end
  final $display("[equiv] g6lc_ai_pe_dot_pipe pp_eq: checked=%0d", pp_eq_cnt);

  // B2 reference: the pre-rewrite WMAX-padded tree, run in parallel; every
  // live node of every level is asserted against its exact-width counterpart.
  // Per-node genvar blocks (same BLKLOOPINIT reason as above).
  int unsigned tree_eq_cnt;
  always_ff @(posedge clk_i or negedge rst_ni)
    tree_eq_cnt <= !rst_ni ? 0 : tree_eq_cnt + 1;
  logic signed [WMAX-1:0] tree_ref_q [LEVELS][P2];
  logic                   tree_ref_start_q [LEVELS];
  for (genvar gl = 1; gl <= int'(LEVELS); gl++) begin : gen_tref
    for (genvar gi = 0; gi < int'(P2 >> gl); gi++) begin : gen_tref_n
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          tree_ref_q[gl-1][gi] <= '0;
          if (gi == 0) tree_ref_start_q[gl-1] <= 1'b0;
        end else begin
          if (gi == 0)
            tree_ref_start_q[gl-1] <= (gl == 1) ? m3_start_q : tree_start_q[gl-2];
          if (gl == 1)
            tree_ref_q[gl-1][gi] <= WMAX'($signed(m3_q[2*gi])) + WMAX'($signed(m3_q[2*gi+1]));
          else
            tree_ref_q[gl-1][gi] <= tree_ref_q[gl-2][2*gi] + tree_ref_q[gl-2][2*gi+1];
        end
      end
      always_ff @(posedge clk_i) begin
        if (rst_ni) begin
          g6lc_ai_tree_eq: assert
            (gen_lvl[gl].lvl_q[gi] == tree_ref_q[gl-1][gi][15+gl:0])
            else $error("g6lc_ai_pe_dot_pipe: tree_eq mismatch lvl %0d node %0d",
                        gl, gi);
          if (gi == 0)
            g6lc_ai_tree_vld_eq: assert (tree_start_q[gl-1] == tree_ref_start_q[gl-1])
              else $error("g6lc_ai_pe_dot_pipe: tree start mismatch lvl %0d", gl);
        end
      end
    end
  end
  final $display("[equiv] g6lc_ai_pe_dot_pipe tree_eq: checked=%0d", tree_eq_cnt);
  // pragma translate_on

endmodule
