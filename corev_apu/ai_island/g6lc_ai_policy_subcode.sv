module g6lc_ai_policy_subcode
  import g6lc_ai_policy_pkg::*;
#(
    parameter bit Enabled = 1'b0,
    parameter bit CacheEn = 1'b0,
    parameter int unsigned ReadBytesPerCycle = 128,
    parameter int unsigned MinSavingsCycles = 2,
    parameter int unsigned SwitchCycles = 2,
    parameter logic [31:0] FormatStepCycles = 32'h11111111,
    parameter logic [31:0] FormatMinReductionLog2 = 32'h00000000,
    parameter logic [23:0] GroupShapeLog2 = 24'h4420ca
) (
    input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, cancel_i, start_i,
    input policy_code_t code_i,
    input logic [2:0] numfmt_i,
    input logic [15:0] m_i, n_i, k_i,
    input policy_topology_t baseline_i,
    output logic ready_o, busy_o, valid_o, evaluated_o, cache_hit_o,
    output logic [2:0] subcode_o,
    output policy_topology_t topology_o,
    output logic [31:0] baseline_cycles_o, selected_cycles_o
);
  localparam int unsigned EvaluationCycles = 32;
  localparam int unsigned ReadShift = $clog2(ReadBytesPerCycle);

`ifndef SYNTHESIS
  initial begin
    assert (!CacheEn || Enabled)
      else $fatal(1, "Subcode cache requires the evaluator");
    assert (ReadBytesPerCycle >= 1 && ReadBytesPerCycle <= 4096 &&
        (ReadBytesPerCycle & (ReadBytesPerCycle - 1)) == 0)
      else $fatal(1, "Subcode read service must be a power of two in [1,4096]");
    assert (MinSavingsCycles <= 65535 && SwitchCycles <= 65535)
      else $fatal(1, "Subcode cost margins must fit 16 bits");
    for (int f = 0; f < 8; f++) begin
      assert (FormatStepCycles[f*4 +: 4] != 0 && FormatMinReductionLog2[f*4 +: 4] <= 9)
        else $fatal(1, "Invalid subcode format service parameters");
    end
    for (int g = 0; g < 4; g++) begin
      assert (GroupShapeLog2[g*6+3 +: 3] <= 4 && GroupShapeLog2[g*6 +: 3] <= 4 &&
          int'(GroupShapeLog2[g*6+3 +: 3]) + int'(GroupShapeLog2[g*6 +: 3]) <= 4)
        else $fatal(1, "Subcode group shape exceeds 16 output slots");
    end
  end
`endif

  if (Enabled) begin : gen_on
    typedef enum logic [2:0] {IDLE, PREP, SERVICE, TOTAL, COMPARE, CACHED} state_t;
    state_t state_q;
    policy_topology_t base_q, candidate_q, candidate_d, best_q, winner;
    logic [8:0] m_q, n_q, k_q;
    logic [2:0] fmt_q, index_q, best_index_q, winner_index;
    logic [1:0] group_q, input_group;
    logic cache_valid_q, cache_match;
    logic candidate_ok_q, candidate_ok, eligible, better, choose;
    logic [2:0] r, c;
    logic [3:0] d;
    logic [5:0] group_shape;
    logic [8:0] mgroups, ngroups;
    logic [16:0] groups_q;
    logic [8:0] full_q;
    logic [15:0] full_service_q, tail_service_q;
    logic [14:0] service_q;
    logic [27:0] cost_q, best_cost_q, base_cost_q, winner_cost;
    logic [9:0] depth, tail;
    logic [5:0] inputs_per_group;
    logic [15:0] full_bytes, tail_bytes;
    logic [15:0] full_service, tail_service;
    logic [3:0] step_cycles;

    function automatic logic [11:0] row_bytes(input logic [9:0] count, input logic [2:0] fmt);
      logic [14:0] bits;
      bits = 15'(count) << policy_element_bits_log2(fmt);
      return 12'((bits + 15'd7) >> 3);
    endfunction

    assign ready_o = enable_i && !flush_i && !cancel_i && state_q == IDLE;
    assign busy_o = state_q != IDLE;
    always_comb begin
      case (code_i)
        POLICY_DECODE: input_group = 2'd1;
        POLICY_ROUTED: input_group = 2'd2;
        POLICY_SPARSE: input_group = 2'd3;
        default: input_group = 2'd0;
      endcase
    end
    assign cache_match = CacheEn && cache_valid_q && eligible && baseline_i == base_q &&
        m_i == {7'd0, m_q} && n_i == {7'd0, n_q} && k_i == {7'd0, k_q} &&
        numfmt_i == fmt_q && input_group == group_q;
    assign eligible = baseline_i.valid && policy_format_known(numfmt_i) &&
        m_i != 0 && n_i != 0 && k_i != 0 && m_i <= 256 && n_i <= 256 && k_i <= 256 &&
        (code_i inside {POLICY_BULK, POLICY_DECODE, POLICY_ROUTED, POLICY_SPARSE}) &&
        baseline_i.slots_log2 >= 1 && baseline_i.slots_log2 <= 9 &&
        baseline_i.rows_log2 <= 4 && baseline_i.cols_log2 <= 4 &&
        int'(baseline_i.rows_log2) + int'(baseline_i.cols_log2) <= 4 &&
        int'(baseline_i.rows_log2) + int'(baseline_i.cols_log2) +
            int'(baseline_i.reduction_log2) == int'(baseline_i.slots_log2) &&
        baseline_i.element_bits_log2 == policy_element_bits_log2(numfmt_i) &&
        (m_i & ((16'd1 << baseline_i.rows_log2) - 16'd1)) == 0 &&
        (n_i & ((16'd1 << baseline_i.cols_log2) - 16'd1)) == 0;

    always_comb begin
      group_shape = GroupShapeLog2[int'(group_q)*6 +: 6];
      r = '0;
      c = '0;
      case (index_q)
        3'd0: begin r = base_q.rows_log2; c = base_q.cols_log2; end
        3'd2: c = 3'd4;
        3'd3: begin r = 3'd1; c = 3'd3; end
        3'd4: begin r = 3'd2; c = 3'd2; end
        3'd5: begin r = 3'd3; c = 3'd1; end
        3'd6: r = 3'd4;
        3'd7: begin r = group_shape[5:3]; c = group_shape[2:0]; end
        default: begin end
      endcase
      d = base_q.slots_log2 - {1'b0, r} - {1'b0, c};
      candidate_ok = r <= 4 && c <= 4 && int'(r) + int'(c) <= 4 &&
          int'(r) + int'(c) <= int'(base_q.slots_log2) &&
          (m_q & ((9'd1 << r) - 9'd1)) == 0 &&
          (n_q & ((9'd1 << c) - 9'd1)) == 0 &&
          (index_q == 0 || d >= FormatMinReductionLog2[int'(fmt_q)*4 +: 4]);
      candidate_d = base_q;
      if (index_q != 0) begin
        candidate_d.rows_log2 = r;
        candidate_d.cols_log2 = c;
        candidate_d.reduction_log2 = d;
        candidate_d.apply = r != 0 || c != 0;
        candidate_d.gain_16ths = policy_reuse_gain(r, c);
      end
      mgroups = m_q >> r;
      ngroups = n_q >> c;
      depth = 10'd1 << d;
      tail = {1'b0, k_q} & (depth - 10'd1);
      inputs_per_group = (6'd1 << r) + (6'd1 << c);
      full_bytes = 16'(inputs_per_group) * 16'(row_bytes(depth, fmt_q));
      tail_bytes = 16'(inputs_per_group) * 16'(row_bytes(tail, fmt_q));
      step_cycles = FormatStepCycles[int'(fmt_q)*4 +: 4];
      full_service = 16'((32'(full_bytes) + ReadBytesPerCycle - 1) >> ReadShift);
      tail_service = 16'((32'(tail_bytes) + ReadBytesPerCycle - 1) >> ReadShift);
      if (full_service < {12'd0, step_cycles}) full_service = {12'd0, step_cycles};
      if (tail_service < {12'd0, step_cycles}) tail_service = {12'd0, step_cycles};
      if (tail == 0) tail_service = '0;
      better = candidate_ok_q && cost_q < best_cost_q;
      winner = better ? candidate_q : best_q;
      winner_index = better ? index_q : best_index_q;
      winner_cost = better ? cost_q : best_cost_q;
      choose = winner_index != 0 &&
          64'(winner_cost) + 64'(SwitchCycles) + 64'(EvaluationCycles) +
          64'(MinSavingsCycles) < 64'(base_cost_q);
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= IDLE;
        base_q <= '0; candidate_q <= '0; best_q <= '0;
        m_q <= '0; n_q <= '0; k_q <= '0; fmt_q <= '0; group_q <= '0;
        index_q <= '0; best_index_q <= '0; candidate_ok_q <= 1'b0;
        groups_q <= '0; full_q <= '0; full_service_q <= '0; tail_service_q <= '0;
        service_q <= '0; cost_q <= '0; best_cost_q <= '0; base_cost_q <= '0;
        valid_o <= 1'b0; evaluated_o <= 1'b0; subcode_o <= '0; topology_o <= '0;
        baseline_cycles_o <= '0; selected_cycles_o <= '0;
        cache_valid_q <= 1'b0; cache_hit_o <= 1'b0;
      end else if (flush_i || !enable_i || (!CacheEn && cancel_i)) begin
        state_q <= IDLE;
        base_q <= '0; candidate_q <= '0; best_q <= '0;
        m_q <= '0; n_q <= '0; k_q <= '0; fmt_q <= '0; group_q <= '0;
        index_q <= '0; best_index_q <= '0; candidate_ok_q <= 1'b0;
        groups_q <= '0; full_q <= '0; full_service_q <= '0; tail_service_q <= '0;
        service_q <= '0; cost_q <= '0; best_cost_q <= '0; base_cost_q <= '0;
        valid_o <= 1'b0; evaluated_o <= 1'b0; subcode_o <= '0; topology_o <= '0;
        baseline_cycles_o <= '0; selected_cycles_o <= '0;
        cache_valid_q <= 1'b0; cache_hit_o <= 1'b0;
      end else if (cancel_i) begin
        state_q <= IDLE;
        valid_o <= 1'b0; evaluated_o <= 1'b0; cache_hit_o <= 1'b0;
        subcode_o <= '0; topology_o <= '0;
        baseline_cycles_o <= '0; selected_cycles_o <= '0;
      end else if (testmode_i || state_q != IDLE || start_i) begin
        case (state_q)
          IDLE: if (start_i) begin
            valid_o <= !eligible;
            evaluated_o <= 1'b0;
            subcode_o <= '0;
            topology_o <= baseline_i;
            baseline_cycles_o <= '0;
            selected_cycles_o <= '0;
            cache_hit_o <= 1'b0;
            cache_valid_q <= cache_match;
            if (cache_match) begin
              state_q <= CACHED;
            end else if (eligible) begin
              base_q <= baseline_i;
              m_q <= m_i[8:0]; n_q <= n_i[8:0]; k_q <= k_i[8:0]; fmt_q <= numfmt_i;
              group_q <= input_group;
              index_q <= '0;
              best_index_q <= '0;
              best_q <= baseline_i;
              state_q <= PREP;
            end
          end
          PREP: begin
            candidate_q <= candidate_d;
            candidate_ok_q <= candidate_ok;
            groups_q <= 17'(mgroups) * 17'(ngroups);
            full_q <= k_q >> d;
            full_service_q <= full_service;
            tail_service_q <= tail_service;
            state_q <= SERVICE;
          end
          SERVICE: begin
            service_q <= 15'(25'(full_q) * 25'(full_service_q) + 25'(tail_service_q));
            state_q <= TOTAL;
          end
          TOTAL: begin
            cost_q <= 28'(groups_q) * 28'(service_q);
            state_q <= COMPARE;
          end
          COMPARE: begin
            if (index_q == 0) begin
              best_cost_q <= cost_q;
              base_cost_q <= cost_q;
            end else if (better) begin
              best_cost_q <= cost_q;
              best_index_q <= index_q;
              best_q <= candidate_q;
            end
            if (index_q == 7) begin
              topology_o <= choose ? winner : base_q;
              subcode_o <= choose ? winner_index : 3'd0;
              baseline_cycles_o <= 32'(base_cost_q);
              selected_cycles_o <= (choose ? 32'(winner_cost) + SwitchCycles : 32'(base_cost_q)) + EvaluationCycles;
              if (CacheEn) begin
                best_q <= choose ? winner : base_q;
                best_index_q <= choose ? winner_index : 3'd0;
                best_cost_q <= choose ? winner_cost : base_cost_q;
                cache_valid_q <= 1'b1;
              end
              evaluated_o <= 1'b1;
              valid_o <= 1'b1;
              state_q <= IDLE;
            end else begin
              index_q <= index_q + 3'd1;
              state_q <= PREP;
            end
          end
          CACHED: begin
            if (CacheEn) begin
              topology_o <= best_q;
              subcode_o <= best_index_q;
              baseline_cycles_o <= 32'(base_cost_q);
              selected_cycles_o <= 32'(best_cost_q) + (best_index_q != 0 ? SwitchCycles : 0) + 1;
              evaluated_o <= 1'b1;
              valid_o <= 1'b1;
              cache_hit_o <= 1'b1;
            end
            state_q <= IDLE;
          end
          default: state_q <= IDLE;
        endcase
      end
    end
  end else begin : gen_off
    assign ready_o = 1'b0;
    assign busy_o = 1'b0;
    assign valid_o = 1'b0;
    assign evaluated_o = 1'b0;
    assign cache_hit_o = 1'b0;
    assign subcode_o = '0;
    assign topology_o = '0;
    assign baseline_cycles_o = '0;
    assign selected_cycles_o = '0;
  end
endmodule
