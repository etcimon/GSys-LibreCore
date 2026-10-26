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
//   M1  per product: two 8x4 half products  p_lo = a * b[3:0] (unsigned
//       nibble), p_hi = a * b[7:4] (signed nibble) -- each a 4-row partial
//       product array with its own short CPA, so no stage carries the full
//       8x8 depth;
//   M2  p = p_lo + (p_hi << 4) masked by the lane valid: the exact 16-bit
//       signed product (a*b = a*b_lo + 16*a*b_hi);
//   T1..Tk  balanced signed adder tree, one level per stage, operands
//       growing one bit per level (16 + level); k = $clog2(2*Lanes);
//   O1,O2 sign-extend to the 32-bit wrapped sum; two output registers.
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
  // Latency: M1 + M2 + LEVELS tree stages + two output registers. The
  // float pipe's valid_o is observed $clog2(Lanes)+5 edges after start_i
  // (its header says +4; the sequencer's metadata shift register is tuned
  // to the observed value), so the second output stage keeps both pipes on
  // one dot_pending/metadata path.
  localparam int unsigned LATENCY = LEVELS + 4;
  // Widest tree node: products are 16-bit signed, one bit per level.
  localparam int unsigned WMAX = 16 + LEVELS;

  // ---------------------------------------------------------------------------
  // Operand unpack (combinational into M1): per product slot the two 8-bit
  // signed operands, as the combinational cell forms them.
  // ---------------------------------------------------------------------------
  logic signed [7:0] op_a [P2];
  logic signed [7:0] op_b [P2];
  logic              op_v [P2];
  always_comb begin
    for (int unsigned s = 0; s < P2; s++) begin
      op_a[s] = '0;
      op_b[s] = '0;
      op_v[s] = 1'b0;
      if (s < NP) begin
        if (numfmt_i == AI_FMT_INT4) begin
          if (s[0]) begin
            op_a[s] = $signed(a_i[s >> 1][7:4]);
            op_b[s] = $signed(b_i[s >> 1][7:4]);
          end else begin
            op_a[s] = $signed(a_i[s >> 1][3:0]);
            op_b[s] = $signed(b_i[s >> 1][3:0]);
          end
          op_v[s] = valid_i[s >> 1];
        end else if (!s[0]) begin
          op_a[s] = a_i[s >> 1];
          op_b[s] = b_i[s >> 1];
          op_v[s] = valid_i[s >> 1];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // M1: half products. a (signed 8) x b[3:0] (unsigned 4) -> signed 13 bits
  // (fits 12 but keep the sign slot explicit); a x b[7:4] (signed 4) -> 12.
  // ---------------------------------------------------------------------------
  logic signed [12:0] m1_lo_q [P2];
  logic signed [11:0] m1_hi_q [P2];
  logic               m1_v_q  [P2];
  logic               m1_start_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m1_start_q <= 1'b0;
      for (int unsigned s = 0; s < P2; s++) begin
        m1_lo_q[s] <= '0;
        m1_hi_q[s] <= '0;
        m1_v_q[s]  <= 1'b0;
      end
    end else begin
      m1_start_q <= start_i;
      for (int unsigned s = 0; s < P2; s++) begin
        // signed 8 x unsigned 4: zero-extend the nibble into a 5-bit signed
        m1_lo_q[s] <= 13'($signed(op_a[s]) * $signed({1'b0, op_b[s][3:0]}));
        m1_hi_q[s] <= 12'($signed(op_a[s]) * $signed(op_b[s][7:4]));
        m1_v_q[s]  <= start_i && op_v[s];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // M2: full 16-bit product, lane-valid masked.
  // ---------------------------------------------------------------------------
  logic signed [15:0] m2_q [P2];
  logic               m2_start_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m2_start_q <= 1'b0;
      for (int unsigned s = 0; s < P2; s++) m2_q[s] <= '0;
    end else begin
      m2_start_q <= m1_start_q;
      for (int unsigned s = 0; s < P2; s++)
        m2_q[s] <= m1_v_q[s]
                 ? (16'($signed(m1_lo_q[s])) + (16'($signed(m1_hi_q[s])) <<< 4))
                 : 16'sd0;
    end
  end

  // ---------------------------------------------------------------------------
  // T1..Tk: balanced tree, one level per stage. Level l holds P2>>l nodes of
  // (16+l) bits. Stored in a WMAX-wide array; only the low 16+l bits of level
  // l are meaningful (sign-extended on write so the array is well-defined).
  // ---------------------------------------------------------------------------
  // Every element of the two arrays below is written by exactly one
  // always_ff (level l by stage l); level 0 is read directly from M2 so no
  // array element has both a combinational and a sequential driver.
  // Index l-1 holds stage l (1..LEVELS).
  logic signed [WMAX-1:0] tree_q [LEVELS][P2];
  logic                   tree_start_q [LEVELS];
  for (genvar l = 1; l <= int'(LEVELS); l++) begin : gen_lvl
    localparam int unsigned N = P2 >> l;
    logic signed [WMAX-1:0] src [P2];
    logic                   src_start;
    if (l == 1) begin : gen_src_m2
      always_comb begin
        for (int unsigned s = 0; s < P2; s++) src[s] = WMAX'($signed(m2_q[s]));
        src_start = m2_start_q;
      end
    end else begin : gen_src_prev
      always_comb begin
        for (int unsigned s = 0; s < P2; s++) src[s] = tree_q[l-2][s];
        src_start = tree_start_q[l-2];
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        tree_start_q[l-1] <= 1'b0;
        for (int unsigned i = 0; i < P2; i++) tree_q[l-1][i] <= '0;
      end else begin
        tree_start_q[l-1] <= src_start;
        for (int unsigned i = 0; i < P2; i++) begin
          if (i < N)
            tree_q[l-1][i] <= WMAX'($signed(src[2*i]) + $signed(src[2*i+1]));
          else
            tree_q[l-1][i] <= '0;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // O1/O2: sign-extend to the 32-bit wrapped sum; second stage aligns the
  // latency with g6lc_ai_pe_dot_float_pipe (see LATENCY).
  // ---------------------------------------------------------------------------
  logic        o1_valid_q;
  logic [31:0] o1_sum_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      o1_valid_q <= 1'b0;
      o1_sum_q   <= '0;
      valid_o    <= 1'b0;
      sum_o      <= '0;
    end else begin
      o1_valid_q <= tree_start_q[LEVELS-1];
      o1_sum_q   <= 32'($signed(tree_q[LEVELS-1][0]));
      valid_o    <= o1_valid_q;
      sum_o      <= o1_sum_q;
    end
  end

  // pragma translate_off
  initial begin
    assert (Lanes >= 1) else $error("g6lc_ai_pe_dot_pipe: Lanes must be >= 1");
    // The narrow tree is exact only while 2*Lanes*2^14 < 2^31.
    assert (WMAX <= 31)
      else $error("g6lc_ai_pe_dot_pipe: Lanes=%0d exceeds the exact-sum width", Lanes);
    // Shared handshake with g6lc_ai_pe_dot_float_pipe: equal latency.
    assert (LATENCY == $clog2(Lanes < 1 ? 1 : Lanes) + 5)
      else $error("g6lc_ai_pe_dot_pipe: latency %0d != float pipe %0d",
                  LATENCY, $clog2(Lanes) + 5);
  end
  // pragma translate_on

endmodule
