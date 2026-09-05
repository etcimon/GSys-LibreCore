// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

module tb_g6lc_ai_policy_resource #(
  parameter int unsigned SramReadBytes = 128,
  parameter int unsigned ExternalBytes = 8
) (
  input logic clk_i,
  input logic rst_ni,
  input logic start_i,
  input logic decision_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [2:0] numfmt_i,
  input logic [2:0] rows_log2_i, cols_log2_i,
  input logic [3:0] reduction_log2_i,
  output logic busy_o, done_o, rejected_o,
  output logic [63:0] cycles_o, compute_cycles_o, external_cycles_o,
  output logic [63:0] useful_macs_o, read_bytes_o, operand_bytes_o, c_bytes_o,
  output logic [63:0] steps_o
);
  typedef enum logic [1:0] {IDLE, DECISION, EXTERNAL, COMPUTE} phase_t;
  phase_t phase_q;
  int unsigned m_q, n_q, k_q, r_q, c_q, p_q, bits_q;
  int unsigned row_q, col_q, red_q, actual_r, actual_c, actual_k;
  logic [63:0] external_left_q, step_left_q, step_bytes, step_cost;
  logic [63:0] input_operands, input_c, input_external;
  int unsigned input_bits;
  logic finish_step;

  function automatic logic [63:0] row_bytes(input int unsigned count, bits);
    return (64'(count) * 64'(bits) + 64'd7) / 64'd8;
  endfunction

  always_comb begin
    case (numfmt_i)
      3'd1: input_bits = 4;
      3'd5, 3'd6: input_bits = 16;
      3'd7: input_bits = 32;
      default: input_bits = 8;
    endcase
    input_operands = (64'(m_i) + 64'(n_i)) * row_bytes(32'(k_i), input_bits);
    input_c = 64'd8 * 64'(m_i) * 64'(n_i);
    input_external = (input_operands + input_c + 64'(ExternalBytes) - 64'd1) /
        64'(ExternalBytes);
    actual_r = ((m_q - row_q) < r_q) ? m_q - row_q : r_q;
    actual_c = ((n_q - col_q) < c_q) ? n_q - col_q : c_q;
    actual_k = ((k_q - red_q) < p_q) ? k_q - red_q : p_q;
    step_bytes = (64'(actual_r) + 64'(actual_c)) * row_bytes(actual_k, bits_q);
    step_cost = (step_bytes + 64'(SramReadBytes) - 64'd1) / 64'(SramReadBytes);
    if (step_cost == 64'd0) step_cost = 64'd1;
    finish_step = (step_left_q == 64'd1) ||
        (step_left_q == 64'd0 && step_cost == 64'd1);
    busy_o = phase_q != IDLE;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase_q <= IDLE;
      m_q <= 0;
      n_q <= 0;
      k_q <= 0;
      r_q <= 1;
      c_q <= 1;
      p_q <= 1;
      bits_q <= 8;
      row_q <= 0;
      col_q <= 0;
      red_q <= 0;
      external_left_q <= '0;
      step_left_q <= '0;
      done_o <= 1'b0;
      rejected_o <= 1'b0;
      cycles_o <= '0;
      compute_cycles_o <= '0;
      external_cycles_o <= '0;
      useful_macs_o <= '0;
      read_bytes_o <= '0;
      operand_bytes_o <= '0;
      c_bytes_o <= '0;
      steps_o <= '0;
    end else begin
      done_o <= 1'b0;
      if (phase_q == IDLE && start_i) begin
        m_q <= 32'(m_i);
        n_q <= 32'(n_i);
        k_q <= 32'(k_i);
        r_q <= 32'd1 << rows_log2_i;
        c_q <= 32'd1 << cols_log2_i;
        p_q <= 32'd1 << reduction_log2_i;
        bits_q <= input_bits;
        row_q <= 0;
        col_q <= 0;
        red_q <= 0;
        external_left_q <= input_external;
        step_left_q <= '0;
        cycles_o <= '0;
        compute_cycles_o <= '0;
        external_cycles_o <= '0;
        useful_macs_o <= '0;
        read_bytes_o <= '0;
        operand_bytes_o <= input_operands;
        c_bytes_o <= input_c;
        steps_o <= '0;
        rejected_o <= 1'b0;
        if (numfmt_i == 3'd2 || m_i == '0 || n_i == '0 || k_i == '0) begin
          rejected_o <= 1'b1;
          done_o <= 1'b1;
        end else phase_q <= decision_i ? DECISION : EXTERNAL;
      end else if (phase_q != IDLE) begin
        cycles_o <= cycles_o + 64'd1;
        case (phase_q)
          DECISION: phase_q <= EXTERNAL;
          EXTERNAL: begin
            external_cycles_o <= external_cycles_o + 64'd1;
            external_left_q <= external_left_q - 64'd1;
            if (external_left_q == 64'd1) phase_q <= COMPUTE;
          end
          COMPUTE: begin
            compute_cycles_o <= compute_cycles_o + 64'd1;
            if (step_left_q == '0) begin
              step_left_q <= step_cost - 64'd1;
              read_bytes_o <= read_bytes_o + step_bytes;
              useful_macs_o <= useful_macs_o +
                  64'(actual_r) * 64'(actual_c) * 64'(actual_k);
              steps_o <= steps_o + 64'd1;
            end else step_left_q <= step_left_q - 64'd1;
            if (finish_step) begin
              if (red_q + p_q < k_q) red_q <= red_q + p_q;
              else begin
                red_q <= 0;
                if (col_q + c_q < n_q) col_q <= col_q + c_q;
                else begin
                  col_q <= 0;
                  if (row_q + r_q < m_q) row_q <= row_q + r_q;
                  else begin
                    phase_q <= IDLE;
                    done_o <= 1'b1;
                  end
                end
              end
            end
          end
          default: phase_q <= IDLE;
        endcase
      end
    end
  end
endmodule
