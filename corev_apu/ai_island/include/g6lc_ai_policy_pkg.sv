// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

package g6lc_ai_policy_pkg;
  typedef enum logic [2:0] {
    POLICY_BULK      = 3'd0,
    POLICY_WIDE      = 3'd1,
    POLICY_TALL      = 3'd2,
    POLICY_DECODE    = 3'd3,
    POLICY_ATTENTION = 3'd4,
    POLICY_ROUTED    = 3'd5,
    POLICY_SPARSE    = 3'd6,
    POLICY_MOVEMENT  = 3'd7
  } policy_code_t;

  typedef struct packed {
    logic [1:0] dataflow;
    logic [3:0] tile_m_log2;
    logic [3:0] tile_n_log2;
    logic [3:0] tile_k_log2;
    logic       sparse_check;
    logic [1:0] prefetch_depth;
  } policy_t;

  typedef struct packed {
    logic [1:0] m;
    logic [1:0] n;
    logic [1:0] k;
    logic [2:0] opcode;
    logic [1:0] balance;
    logic       sparse;
    logic       continuous;
    logic       shape_valid;
  } policy_features_t;

  typedef struct packed {
    logic valid;
    logic apply;
    logic [2:0] rows_log2;
    logic [2:0] cols_log2;
    logic [3:0] reduction_log2;
    logic [3:0] slots_log2;
    logic [2:0] element_bits_log2;
    logic [3:0] gain_16ths;
  } policy_topology_t;

  function automatic logic policy_format_known(input logic [2:0] numfmt);
    return numfmt != 3'(config_pkg::AI_FMT_SP24);
  endfunction

  function automatic logic policy_integer_format(input logic [2:0] numfmt);
    return numfmt == 3'(config_pkg::AI_FMT_INT) || numfmt == 3'(config_pkg::AI_FMT_INT4);
  endfunction

  function automatic logic [2:0] policy_element_bits_log2(input logic [2:0] numfmt);
    case (numfmt)
      3'(config_pkg::AI_FMT_INT4): return 3'd2;
      3'(config_pkg::AI_FMT_FP16), 3'(config_pkg::AI_FMT_BF16): return 3'd4;
      3'(config_pkg::AI_FMT_FP32): return 3'd5;
      default: return 3'd3;
    endcase
  endfunction

  // Lane grouping, fitted to measured RTL cycles rather than to the cost model.
  //
  // The remote provisioning basis (verif/regress/ai-gemm-codec-basis.py, run
  // ai-gemm-codec-basis-20260906T165957Z-718434a9a9d1: six provisioning points x
  // five shape classes x seven formats x every legal AR depth, digest-stable)
  // showed the best PeLanes count depends on the numeric format and NOT on the
  // matrix shape - the winning point was identical across all five shape classes
  // for every format.  Measured optima were 8 lanes for INT4, 16 for INT8 and
  // both FP8 formats, and 32 for FP16/BF16/FP32, i.e. exactly twice the element
  // width in lanes, which is what these two functions encode.
  //
  // `policy_dot_lanes_log2` is the lane count one dot product can keep busy for
  // a format.  `policy_lane_groups_log2` is how many independent lane groups a
  // provisioned array can therefore be split into: narrow formats leave lanes
  // idle (INT4 gained 0% from going past 8 lanes) and those lanes are only
  // useful as separate groups working on separate outputs, while wide formats
  // want every lane ganged onto one dot (FP32 gained up to +188.2%).
  //
  // SCOPE, important: this fit is k=16-specific.  The mechanism in
  // g6lc_ai_gemm_seq is mac_step = 2*PeLanes for INT4 and PeLanes/bytes
  // otherwise, and a reduction ends when mac_step >= k, so the lanes a dot can
  // actually use is fmt_row_bytes(k) -- the operand row in bytes -- not a
  // function of the element width alone.  At k=16 those coincide (8/16/32/64 for
  // INT4/INT8/FP16/FP32), which is why "twice the element width" reproduces the
  // measurements.  For other k it does not follow, and the whole basis was
  // measured at k=16 only because MaxDim caps k there.  Treat these functions as
  // valid at k=16 and re-derive against k_bytes before using them elsewhere; see
  // the sub-code hypothesis section in architecture/ai-matrix/README.md.
  //
  // FP32's 64-lane requirement was confirmed by a follow-up 8/32/64-lane run
  // (ai-gemm-codec-basis-20260906T172019Z): FP32 wins at 64 lanes for every
  // shape class, up to +320.0% against the shipped 8-lane provisioning on 16x16,
  // while INT4 still gains nothing past 8 and INT8/FP8 nothing past 16.  The
  // "twice the element width" rule therefore holds across the whole measured
  // range rather than being extrapolated at its top end.
  //
  // Unknown/unsupported formats fail closed to "gang everything, split nothing".
  // Both functions are pure decisions: no datapath consumes them yet, so they
  // change no behaviour on their own.
  function automatic logic [2:0] policy_dot_lanes_log2(input logic [2:0] numfmt);
    if (!policy_format_known(numfmt)) return 3'd6;
    return 3'(policy_element_bits_log2(numfmt) + 3'd1);
  endfunction

  function automatic logic [2:0] policy_lane_groups_log2(
      input logic [2:0] numfmt, input logic [2:0] lanes_log2
  );
    logic [2:0] wanted;
    wanted = policy_dot_lanes_log2(numfmt);
    return (lanes_log2 > wanted) ? 3'(lanes_log2 - wanted) : 3'd0;
  endfunction

  function automatic logic [63:0] policy_normalize_sample(
      input logic [255:0] sample, input logic [2:0] numfmt
  );
    logic [63:0] normalized;
    logic is_zero;
    for (int i = 0; i < 8; i++) begin
      case (numfmt)
        3'(config_pkg::AI_FMT_INT): is_zero = sample[i*8 +: 8] == 8'd0;
        3'(config_pkg::AI_FMT_INT4): is_zero = sample[i*4 +: 4] == 4'd0;
        3'(config_pkg::AI_FMT_FP8_E4M3), 3'(config_pkg::AI_FMT_FP8_E5M2):
          is_zero = sample[i*8 +: 7] == 7'd0;
        3'(config_pkg::AI_FMT_FP16), 3'(config_pkg::AI_FMT_BF16):
          is_zero = sample[i*16 +: 15] == 15'd0;
        3'(config_pkg::AI_FMT_FP32): is_zero = sample[i*32 +: 31] == 31'd0;
        default: is_zero = 1'b0;
      endcase
      normalized[i*8 +: 8] = is_zero ? 8'd0 : 8'd1;
    end
    return normalized;
  endfunction

  function automatic logic [2:0] policy_aligned_log2(
      input logic [15:0] dim, input logic [2:0] cap
  );
    logic [2:0] result;
    result = '0;
    for (int unsigned level = 1; level <= 4; level++) begin
      if (level <= int'(cap) && dim >= (16'd1 << level) &&
          (dim & ((16'd1 << level) - 16'd1)) == 16'd0)
        result = 3'(level);
    end
    return result;
  endfunction

  function automatic logic [3:0] policy_reuse_gain(
      input logic [2:0] row_log, col_log
  );
    logic [5:0] rows, cols, outputs;
    logic [10:0] dividend;
    rows = 6'd1 << row_log;
    cols = 6'd1 << col_log;
    outputs = 6'd1 << (int'(row_log) + int'(col_log));
    dividend = (({5'd0, outputs} << 1) - {5'd0, rows} - {5'd0, cols}) << 4;
    return 4'(dividend >> (int'(row_log) + int'(col_log) + 1));
  endfunction

  function automatic logic [63:0] policy_rowbytes(
      input logic [15:0] k,
      input logic [2:0] numfmt
  );
    logic [2:0] bits;
    logic [63:0] num;
    bits = policy_element_bits_log2(numfmt);
    num = 64'(k) * (64'd1 << bits);
    return (num + 64'd7) >> 3;
  endfunction

  function automatic policy_topology_t policy_topology(
      input policy_code_t code,
      input logic [2:0] numfmt,
      input logic [15:0] m, n, k,
      input logic [1:0] balance,
      input int unsigned read_bytes,
      input int unsigned min_gain,
      input logic [31:0] slots
  );
    policy_topology_t t;
    logic [2:0] row_cap, col_cap, row_log, col_log;
    logic [2:0] row_max, col_max, balanced_row, balanced_col;
    logic [3:0] gain, balanced_gain, group_log;
    logic [15:0] active_k;
    logic [63:0] base_step;
    logic underfilled;
    logic balance_ok;
    t = '0;
    if (!policy_format_known(numfmt) || m == 16'd0 || n == 16'd0 || k == 16'd0 ||
        slots[numfmt*4 +: 4] == 4'd0 || slots[numfmt*4 +: 4] > 4'd9)
      return t;
    t.valid = 1'b1;
    t.slots_log2 = slots[numfmt*4 +: 4];
    t.reduction_log2 = t.slots_log2;
    t.element_bits_log2 = policy_element_bits_log2(numfmt);
    row_cap = '0;
    col_cap = '0;
    case (code)
      POLICY_BULK, POLICY_ATTENTION, POLICY_SPARSE: begin
        row_cap = 3'd2;
        col_cap = 3'd2;
      end
      POLICY_WIDE: begin
        row_cap = 3'd1;
        col_cap = 3'd3;
      end
      POLICY_TALL: begin
        row_cap = 3'd3;
        col_cap = 3'd1;
      end
      POLICY_DECODE: col_cap = 3'd4;
      POLICY_ROUTED: begin
        row_cap = 3'd1;
        col_cap = 3'd2;
      end
      default: begin end
    endcase
    row_log = policy_aligned_log2(m, row_cap);
    col_log = policy_aligned_log2(n, col_cap);
    if (int'(row_log) > int'(t.slots_log2)) row_log = 3'(t.slots_log2);
    if (int'(row_log) + int'(col_log) > int'(t.slots_log2))
      col_log = 3'(t.slots_log2 - {1'b0, row_log});
    gain = policy_reuse_gain(row_log, col_log);
    row_max = policy_aligned_log2(m, 3'd4);
    col_max = policy_aligned_log2(n, 3'd4);
    group_log = {1'b0, row_max} + {1'b0, col_max};
    if (group_log > 4'd4) group_log = 4'd4;
    if (group_log > t.slots_log2) group_log = t.slots_log2;
    balanced_row = 3'(group_log >> 1);
    if (balanced_row > row_max) balanced_row = row_max;
    balanced_col = 3'(group_log - {1'b0, balanced_row});
    if (balanced_col > col_max) begin
      balanced_col = col_max;
      balanced_row = 3'(group_log - {1'b0, balanced_col});
    end
    balanced_gain = policy_reuse_gain(balanced_row, balanced_col);
    if (balanced_gain > gain || (balanced_gain == gain &&
        int'(group_log) > int'(row_log) + int'(col_log))) begin
      row_log = balanced_row;
      col_log = balanced_col;
      gain = balanced_gain;
    end

    active_k = (k < (16'd1 << t.slots_log2)) ? k : (16'd1 << t.slots_log2);
    base_step = (64'(m) + 64'(n)) * policy_rowbytes(active_k, numfmt);
    underfilled = k <= (16'd1 << (int'(t.slots_log2) - 1));

    balance_ok = balance != 2'd0 || (code == POLICY_DECODE);
    if (code != POLICY_MOVEMENT && balance_ok && (row_log != 3'd0 || col_log != 3'd0) &&
        (m >= 16'd8 || n >= 16'd8) && int'(gain) >= min_gain &&
        (underfilled || base_step >= 64'(read_bytes))) begin
      t.apply = 1'b1;
      t.rows_log2 = row_log;
      t.cols_log2 = col_log;
      t.reduction_log2 = 4'(int'(t.slots_log2) - int'(row_log) - int'(col_log));
      t.gain_16ths = gain;
    end
    return t;
  endfunction

  function automatic logic [1:0] policy_bucket(input logic [15:0] dim);
    if (dim <= 16'd1) return 2'd0;
    if (dim <= 16'd8) return 2'd1;
    if (dim <= 16'd64) return 2'd2;
    return 2'd3;
  endfunction

  function automatic logic policy_sparse_residue(input logic [63:0] sample);
    logic [7:0] zero_byte;
    logic [1:0] pair0, pair1, pair2, pair3;
    logic [2:0] half0, half1;
    logic [3:0] count;
    for (int i = 0; i < 8; i++) zero_byte[i] = (sample[i*8 +: 8] == 8'd0);
    pair0 = {1'b0, zero_byte[0]} + {1'b0, zero_byte[1]};
    pair1 = {1'b0, zero_byte[2]} + {1'b0, zero_byte[3]};
    pair2 = {1'b0, zero_byte[4]} + {1'b0, zero_byte[5]};
    pair3 = {1'b0, zero_byte[6]} + {1'b0, zero_byte[7]};
    half0 = {1'b0, pair0} + {1'b0, pair1};
    half1 = {1'b0, pair2} + {1'b0, pair3};
    count = {1'b0, half0} + {1'b0, half1};
    return count >= 4'd6;
  endfunction

  function automatic policy_code_t policy_encode(input policy_features_t f);
    if (!f.shape_valid || f.opcode >= 3'd4) return POLICY_MOVEMENT;
    if (f.opcode == 3'd1) return POLICY_ATTENTION;
    if (f.opcode == 3'd2) return POLICY_ROUTED;
    if (f.m <= 2'd1 && f.n >= 2'd2 && f.k >= 2'd2) return POLICY_DECODE;
    if (f.sparse && f.continuous && f.balance == 2'd2 && f.m >= 2'd2)
      return POLICY_SPARSE;
    if (f.balance == 2'd0) return POLICY_MOVEMENT;
    if (f.n > f.m) return POLICY_WIDE;
    if (f.m > f.n) return POLICY_TALL;
    return POLICY_BULK;
  endfunction

  function automatic policy_code_t policy_successor(input policy_code_t code);
    case (code)
      POLICY_BULK:      return POLICY_ATTENTION;
      POLICY_WIDE:      return POLICY_BULK;
      POLICY_TALL:      return POLICY_WIDE;
      POLICY_DECODE:    return POLICY_DECODE;
      POLICY_ATTENTION: return POLICY_WIDE;
      POLICY_ROUTED:    return POLICY_DECODE;
      POLICY_SPARSE:    return POLICY_WIDE;
      default:          return POLICY_BULK;
    endcase
  endfunction

  function automatic policy_t policy_decode(input policy_code_t code);
    case (code)
      POLICY_BULK:      return {2'd0, 4'd6, 4'd6, 4'd6, 1'b0, 2'd2};
      POLICY_WIDE:      return {2'd1, 4'd4, 4'd8, 4'd6, 1'b0, 2'd3};
      POLICY_TALL:      return {2'd2, 4'd8, 4'd4, 4'd6, 1'b0, 2'd2};
      POLICY_DECODE:    return {2'd2, 4'd0, 4'd7, 4'd8, 1'b0, 2'd1};
      POLICY_ATTENTION: return {2'd0, 4'd5, 4'd5, 4'd6, 1'b0, 2'd2};
      POLICY_ROUTED:    return {2'd2, 4'd3, 4'd5, 4'd7, 1'b0, 2'd1};
      POLICY_SPARSE:    return {2'd1, 4'd5, 4'd6, 4'd7, 1'b1, 2'd1};
      default:          return {2'd3, 4'd3, 4'd6, 4'd3, 1'b0, 2'd3};
    endcase
  endfunction
endpackage
