// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One owned request at a time. Shape work is independent of the codec's history:
// prepare every code's topology, then let the wrapper select by the committed
// code. valid_o publishes the entire array. Flush cancels every pending stage.
module g6lc_ai_policy_topology
  import g6lc_ai_policy_pkg::*;
#(
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinGain16ths = 2,
  parameter logic [31:0] FormatSlotsLog2 = 32'h67788098
) (
  input logic clk_i, rst_ni, flush_i, valid_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [2:0] numfmt_i,
  input logic [1:0] balance_i,
  output logic valid_o,
  output policy_topology_t topology_o [8]
);
  typedef struct packed {
    logic valid;
    logic [3:0] gain, total;
    logic [2:0] row_log, col_log;
  } candidate_t;

  function automatic logic [2:0] aligned_max(input logic [15:0] dim);
    if (dim == 0) return 3'd0;
    if (dim[3:0] == 0) return 3'd4;
    if (dim[2:0] == 0) return 3'd3;
    if (dim[1:0] == 0) return 3'd2;
    if (dim[0] == 0) return 3'd1;
    return 3'd0;
  endfunction

  // Only the 15 pairs with row+column <=4 can reach this lookup.
  function automatic logic [3:0] gain_at(input logic [2:0] r, c);
    case ({r,c})
      {3'd0,3'd1}, {3'd1,3'd0}: return 4'd4;
      {3'd0,3'd2}, {3'd2,3'd0}: return 4'd6;
      {3'd0,3'd3}, {3'd3,3'd0},
      {3'd0,3'd4}, {3'd4,3'd0}: return 4'd7;
      {3'd1,3'd1}: return 4'd8;
      {3'd1,3'd2}, {3'd2,3'd1}: return 4'd10;
      {3'd1,3'd3}, {3'd3,3'd1}: return 4'd11;
      {3'd2,3'd2}: return 4'd12;
      default: return 4'd0;
    endcase
  endfunction

  function automatic candidate_t better(input candidate_t a, b);
    if (!a.valid) return b;
    if (!b.valid) return a;
    if (a.gain != b.gain) return a.gain > b.gain ? a : b;
    if (a.total != b.total) return a.total > b.total ? a : b;
    return a.row_log <= b.row_log ? a : b;
  endfunction

  function automatic logic [7:0] service_free_mask();
    logic [7:0] mask;
    int unsigned slots, bits, lower_bytes;
    mask = '0;
    for (int f = 0; f < 8; f++) begin
      slots = 32'(FormatSlotsLog2[f*4 +: 4]);
      bits = 32'(policy_element_bits_log2(3'(f)));
      if (policy_format_known(3'(f)) && slots >= 1 && slots <= 9) begin
        lower_bytes = 9 * (((((1 << (slots-1)) + 1) << bits) + 7) >> 3);
        mask[f] = ReadBytesPerCycle <= lower_bytes;
      end else mask[f] = 1'b1; // invalid shapes never apply
    end
    return mask;
  endfunction
  localparam logic [7:0] ServiceFree = service_free_mask();
  localparam int ServiceW = $clog2(ReadBytesPerCycle) + 1;

  logic [5:0] token_q;
  logic known_q, large_q, underfilled_q, free_q;
  logic [2:0] row_max_q, col_max_q, bits_q;
  logic [3:0] slots_q;
  logic [1:0] balance_q;
  logic [16:0] extent_q;
  logic [11:0] rowbytes_q;
  logic [3:0] slots;
  logic [2:0] bits;
  logic [15:0] active_k;
  assign slots = FormatSlotsLog2[numfmt_i*4 +: 4];
  assign bits = policy_element_bits_log2(numfmt_i);
  assign active_k = k_i < (16'd1 << slots) ? k_i : (16'd1 << slots);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) token_q <= '0;
    else if (flush_i) token_q <= '0;
    else token_q <= {token_q[4:0], valid_i};
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      known_q <= 1'b0; large_q <= 1'b0;
      row_max_q <= '0; col_max_q <= '0; slots_q <= '0; bits_q <= '0;
      balance_q <= '0; underfilled_q <= 1'b0; free_q <= 1'b0;
      extent_q <= '0; rowbytes_q <= '0;
    end else if (valid_i && !flush_i) begin
      known_q <= policy_format_known(numfmt_i) && m_i != 0 && n_i != 0 &&
                 k_i != 0 && slots >= 1 && slots <= 9;
      large_q <= m_i >= 8 || n_i >= 8;
      row_max_q <= aligned_max(m_i);
      col_max_q <= aligned_max(n_i);
      slots_q <= slots;
      bits_q <= bits;
      balance_q <= balance_i;
      underfilled_q <= slots != 0 && k_i <= (16'd1 << (slots - 4'd1));
      free_q <= ServiceFree[numfmt_i];
      extent_q <= {1'b0,m_i} + {1'b0,n_i};
      // active_k <=512 for a legal request, so rowbytes <=2048.
      rowbytes_q <= 12'(((32'(active_k) << bits) + 32'd7) >> 3);
    end
  end

  candidate_t tree_q [5][16];
  for (genvar r = 0; r <= 4; r++) begin : gen_row
    for (genvar c = 0; c <= 4-r; c++) begin : gen_col
      localparam int Index = 5*r - r*(r-1)/2 + c;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) tree_q[0][Index] <= '0;
        else if (token_q[0]) begin
          tree_q[0][Index].valid <= row_max_q >= 3'(r) && col_max_q >= 3'(c) &&
                                    slots_q >= 4'(r+c);
          tree_q[0][Index].gain <= gain_at(3'(r),3'(c));
          tree_q[0][Index].total <= 4'(r+c);
          tree_q[0][Index].row_log <= 3'(r);
          tree_q[0][Index].col_log <= 3'(c);
        end
      end
    end
  end
  assign tree_q[0][15] = '0;
  for (genvar level = 1; level <= 4; level++) begin : gen_level
    for (genvar node = 0; node < (16 >> level); node++) begin : gen_node
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) tree_q[level][node] <= '0;
        else if (token_q[level])
          tree_q[level][node] <= better(tree_q[level-1][2*node], tree_q[level-1][2*node+1]);
      end
    end
  end

  candidate_t native_q [8];
  candidate_t native_gain_q [8];
  for (genvar code = 0; code < 8; code++) begin : gen_native
    localparam int RowCap = (code == 1 || code == 5) ? 1 :
                             (code == 2) ? 3 : (code == 3 || code == 7) ? 0 : 2;
    localparam int ColCap = code == 1 ? 3 : code == 2 ? 1 :
                             code == 3 ? 4 : code == 7 ? 0 : 2;
    logic [2:0] row_log, col_cap, col_log;
    logic [3:0] row_limit, remaining;
    assign row_limit = slots_q < 4'(RowCap) ? slots_q : 4'(RowCap);
    assign row_log = {1'b0,row_max_q} < row_limit ? row_max_q : row_limit[2:0];
    assign col_cap = col_max_q < 3'(ColCap) ? col_max_q : 3'(ColCap);
    assign remaining = slots_q - {1'b0,row_log};
    assign col_log = {1'b0,col_cap} < remaining ? col_cap : remaining[2:0];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) native_q[code] <= '0;
      else if (token_q[0]) begin
        native_q[code].valid <= 1'b1;
        native_q[code].gain <= '0;
        native_q[code].total <= {1'b0,row_log} + {1'b0,col_log};
        native_q[code].row_log <= row_log;
        native_q[code].col_log <= col_log;
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) native_gain_q[code] <= '0;
      else if (token_q[1]) begin
        native_gain_q[code] <= native_q[code];
        native_gain_q[code].gain <= gain_at(native_q[code].row_log, native_q[code].col_log);
      end
    end
  end

  logic service_done, service_ok;
  if (&ServiceFree) begin : gen_service_constant
    assign service_done = 1'b1;
    assign service_ok = 1'b1;
  end else begin : gen_service_window
    // Exact threshold product for custom parameters. Saturate at the constant
    // service threshold; at most 17 shift/add steps, no variable multiply/divide.
    logic busy_q, done_q, ok_q;
    logic [16:0] factor_q;
    logic [ServiceW-1:0] addend_q, sum_q;
    logic [ServiceW:0] sum_ext;
    logic [4:0] left_q;
    assign sum_ext = {1'b0,sum_q} + (factor_q[0] ? {1'b0,addend_q} : '0);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        busy_q <= 1'b0; done_q <= 1'b0; ok_q <= 1'b0;
        factor_q <= '0; addend_q <= '0; sum_q <= '0; left_q <= '0;
      end else if (flush_i || valid_i) begin
        busy_q <= 1'b0; done_q <= 1'b0; ok_q <= 1'b0;
      end else if (token_q[0]) begin
        done_q <= free_q || underfilled_q || !known_q || !large_q;
        ok_q <= free_q || underfilled_q;
        busy_q <= !(free_q || underfilled_q || !known_q || !large_q);
        factor_q <= extent_q;
        addend_q <= (32'(rowbytes_q) >= ReadBytesPerCycle) ?
                     ServiceW'(ReadBytesPerCycle) : ServiceW'(rowbytes_q);
        sum_q <= '0;
        left_q <= 5'd17;
      end else if (busy_q) begin
        if (sum_ext >= (ServiceW+1)'(ReadBytesPerCycle) || left_q == 1) begin
          busy_q <= 1'b0; done_q <= 1'b1;
          ok_q <= sum_ext >= (ServiceW+1)'(ReadBytesPerCycle);
        end
        sum_q <= sum_ext[ServiceW-1:0];
        // Threshold is a power of two; this clamp also covers a left-shift carry.
        addend_q <= (32'(addend_q) >= (ReadBytesPerCycle+1)/2) ?
                     ServiceW'(ReadBytesPerCycle) : (addend_q << 1);
        factor_q <= factor_q >> 1;
        left_q <= left_q - 5'd1;
      end
    end
    assign service_done = done_q;
    assign service_ok = ok_q;
  end

  logic shape_done_q, publish;
  assign publish = shape_done_q && service_done && !flush_i;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin shape_done_q <= 1'b0; valid_o <= 1'b0; end
    else if (flush_i) begin shape_done_q <= 1'b0; valid_o <= 1'b0; end
    else begin
      valid_o <= publish;
      if (valid_i || publish) shape_done_q <= 1'b0;
      else if (token_q[5]) shape_done_q <= 1'b1;
    end
  end
  for (genvar code = 0; code < 8; code++) begin : gen_result
    candidate_t selected;
    policy_topology_t result;
    // Native wins an exact gain/group tie; tournament orientation applies only
    // within the balanced candidates.
    assign selected = (tree_q[4][0].gain > native_gain_q[code].gain ||
        (tree_q[4][0].gain == native_gain_q[code].gain &&
         tree_q[4][0].total > native_gain_q[code].total)) ?
        tree_q[4][0] : native_gain_q[code];
    always_comb begin
      result = '0;
      if (known_q) begin
        result.valid = 1'b1;
        result.slots_log2 = slots_q;
        result.reduction_log2 = slots_q;
        result.element_bits_log2 = bits_q;
        if (code != 7 && (balance_q != 0 || code == 3) && large_q &&
            selected.total != 0 && 32'(selected.gain) >= MinGain16ths && service_ok) begin
          result.apply = 1'b1;
          result.rows_log2 = selected.row_log;
          result.cols_log2 = selected.col_log;
          result.reduction_log2 = slots_q - selected.total;
          result.gain_16ths = selected.gain;
        end
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) topology_o[code] <= '0;
      else if (flush_i) topology_o[code] <= '0;
      else if (publish) topology_o[code] <= result;
    end
  end
endmodule
