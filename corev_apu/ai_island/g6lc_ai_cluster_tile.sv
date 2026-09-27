// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Fixed-width strip engine for the non-default cluster.
// LANES is the elaborated integer multiplier count. The 4096 MAC/cycle field
// on AiIslandThroughputSku is a sketch, not this array. K walks in strips of
// LANES, and the strip sum is registered before the next strip, so the comb
// cloud is LANES products, not K.
// Float codes are refused unless FP_REAL_MODEL is set. That mode instantiates
// the simulation reference g6lc_ai_fp_dot and is not a synthesis target.
// Structured 2:4 is refused in both modes.

module g6lc_ai_cluster_tile
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned CLUSTERS   = 2,
    parameter int unsigned LANES      = AI_THROUGHPUT_LANES,
    parameter int unsigned MAX_DIM    = 4,
    parameter logic [15:0] DTYPE_MASK = AiIslandFastDtypeMask,
    // 0: integer strip only, synthesizable. Float formats return ST_BAD_FMT
    //    even when DTYPE_MASK has their bit.
    // 1: simulation reference. Not for a synthesis netlist.
    parameter bit          FP_REAL_MODEL = 1'b0
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    input  logic                          load_i,
    input  logic                          ab_i,
    input  logic [7:0]                    cluster_i,
    input  logic [$clog2(MAX_DIM)-1:0]    row_i,
    input  logic [$clog2(MAX_DIM)-1:0]    col_i,
    input  logic [31:0]                   elem_i,
    input  logic                          start_i,
    input  logic [2:0]                    fmt_i,
    input  logic [15:0]                   m_i,
    input  logic [15:0]                   n_i,
    input  logic [15:0]                   k_i,
    output logic                          busy_o,
    output logic                          done_o,
    output logic [15:0]                   status_o
);
  localparam logic [15:0] ST_OK      = 16'd0;
  localparam logic [15:0] ST_BAD_FMT = 16'd8;
  localparam int unsigned IDX = $clog2(MAX_DIM);
  localparam logic [1:0]  S_IDLE = 2'd0;
  localparam logic [1:0]  S_MAC  = 2'd1;
  localparam logic [1:0]  S_DONE = 2'd2;

  logic [31:0] a_mem [CLUSTERS][MAX_DIM][MAX_DIM];
  logic [31:0] b_mem [CLUSTERS][MAX_DIM][MAX_DIM];
  logic [31:0] c_mem [CLUSTERS][MAX_DIM][MAX_DIM];

  logic [1:0]  state_q;
  logic [7:0]  cl_q;
  logic [2:0]  fmt_q;
  logic        is_int_q;
  logic [15:0] m_q, n_q, k_q, ii_q, jj_q, kk_q;
  logic [31:0] acc_q;

  function automatic bit granted(input logic [2:0] fmt);
    if (fmt == 3'd2) return 1'b0;
    if (fmt > 3'd1 && !FP_REAL_MODEL) return 1'b0;
    return DTYPE_MASK[fmt];
  endfunction

  logic [31:0] strip_acc;
  logic [IDX-1:0] kidx;

  if (FP_REAL_MODEL) begin : gen_fp_model
    g6lc_ai_fp_dot i_fp ();
    always_comb begin
      strip_acc = acc_q;
      kidx = '0;
      if (state_q == S_MAC) begin
        for (int unsigned lane = 0; lane < LANES; lane++) begin
          kidx = kk_q[IDX-1:0] + lane[IDX-1:0];
          if ((kk_q + 16'(lane)) < k_q &&
              (kk_q + 16'(lane)) < MAX_DIM) begin
            if (is_int_q)
              strip_acc = strip_acc
                + a_mem[cl_q][ii_q[IDX-1:0]][kidx]
                * b_mem[cl_q][kidx][jj_q[IDX-1:0]];
            else
              strip_acc = gen_fp_model.i_fp.mac(
                32'(fmt_q), strip_acc,
                a_mem[cl_q][ii_q[IDX-1:0]][kidx],
                b_mem[cl_q][kidx][jj_q[IDX-1:0]]);
          end
        end
      end
    end
  end else begin : gen_int_only
    always_comb begin
      strip_acc = acc_q;
      kidx = '0;
      if (state_q == S_MAC && is_int_q) begin
        for (int unsigned lane = 0; lane < LANES; lane++) begin
          kidx = kk_q[IDX-1:0] + lane[IDX-1:0];
          if ((kk_q + 16'(lane)) < k_q &&
              (kk_q + 16'(lane)) < MAX_DIM) begin
            strip_acc = strip_acc
              + a_mem[cl_q][ii_q[IDX-1:0]][kidx]
              * b_mem[cl_q][kidx][jj_q[IDX-1:0]];
          end
        end
      end
    end
  end

  assign busy_o = state_q != S_IDLE;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      done_o <= 1'b0;
      status_o <= ST_OK;
      acc_q <= '0;
      ii_q <= '0; jj_q <= '0; kk_q <= '0;
      cl_q <= '0; fmt_q <= '0; is_int_q <= 1'b1;
      m_q <= '0; n_q <= '0; k_q <= '0;
      for (int unsigned c = 0; c < CLUSTERS; c++)
        for (int unsigned r = 0; r < MAX_DIM; r++)
          for (int unsigned col = 0; col < MAX_DIM; col++) begin
            a_mem[c][r][col] <= '0;
            b_mem[c][r][col] <= '0;
            c_mem[c][r][col] <= '0;
          end
    end else begin
      done_o <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (load_i && int'(cluster_i) < CLUSTERS &&
              int'(row_i) < MAX_DIM && int'(col_i) < MAX_DIM) begin
            if (!ab_i) a_mem[cluster_i][row_i][col_i] <= elem_i;
            else       b_mem[cluster_i][row_i][col_i] <= elem_i;
          end else if (start_i) begin
            if (int'(cluster_i) >= CLUSTERS || !granted(fmt_i) ||
                m_i == 0 || n_i == 0 || k_i == 0 ||
                m_i > MAX_DIM || n_i > MAX_DIM || k_i > MAX_DIM) begin
              status_o <= ST_BAD_FMT;
              state_q <= S_DONE;
            end else begin
              status_o <= ST_OK;
              cl_q <= cluster_i;
              fmt_q <= fmt_i;
              is_int_q <= (fmt_i <= 3'd1);
              m_q <= m_i; n_q <= n_i; k_q <= k_i;
              ii_q <= '0; jj_q <= '0; kk_q <= '0;
              acc_q <= '0;
              state_q <= S_MAC;
            end
          end
        end
        S_MAC: begin
          if ((kk_q + LANES) >= k_q) begin
            c_mem[cl_q][ii_q[$clog2(MAX_DIM)-1:0]][jj_q[$clog2(MAX_DIM)-1:0]] <= strip_acc;
            acc_q <= '0;
            kk_q <= '0;
            if ((jj_q + 16'd1) == n_q) begin
              jj_q <= '0;
              if ((ii_q + 16'd1) == m_q) state_q <= S_DONE;
              else ii_q <= ii_q + 16'd1;
            end else begin
              jj_q <= jj_q + 16'd1;
            end
          end else begin
            kk_q <= kk_q + 16'(LANES);
            acc_q <= strip_acc;
          end
        end
        default: begin
          done_o <= 1'b1;
          state_q <= S_IDLE;
        end
      endcase
    end
  end
endmodule
