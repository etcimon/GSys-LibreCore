// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai I1-lite: sequential INT8 GEMM over AXI with on-chip tile buffers.
//
//   C[i,j] (i32) = sum_t A[i,t]*B[t,j]  with A,B int8, row-major
//   lda/ldb from descriptor; C uses ldc = n (contiguous rows).
//
// Phases (I1 cluster shape, tiny MaxDim):
//   1) Load A tile into local flops  2) Load B tile  3) MAC into local C
//   4) Store C tile. AXI only in load/store; compute is pure multi-cycle.
//
// Bounds: m,n,k ∈ [1, MaxDim]. Larger jobs return err without traffic.
// Local buffers are the pre-`tc_sram` stand-in (MaxDim≤8 ⇒ ≤256 B C).
// Timing: multi-cycle; one outstanding AXI beat; no core critical path.

module g6lc_ai_gemm_seq #(
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned DataWidth = 64,
    parameter int unsigned IdWidth   = 4,
    parameter int unsigned MaxDim    = 8,
    parameter type         axi_req_t  = logic,
    parameter type         axi_resp_t = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,
    input  logic [31:0] m_i,
    input  logic [31:0] n_i,
    input  logic [31:0] k_i,
    input  logic [15:0] lda_i,
    input  logic [15:0] ldb_i,
    input  logic [AddrWidth-1:0] ptr_a_i,
    input  logic [AddrWidth-1:0] ptr_b_i,
    input  logic [AddrWidth-1:0] ptr_c_i,
    output logic        ready_o,
    output logic        done_o,
    output logic        err_o,
    output axi_req_t    axi_req_o,
    input  axi_resp_t   axi_resp_i
);

  localparam int unsigned TileElems = MaxDim * MaxDim;

  typedef enum logic [3:0] {
    ST_IDLE  = 4'd0,
    ST_CHK   = 4'd1,
    ST_LA    = 4'd2,  // load A tile
    ST_LB    = 4'd3,  // load B tile
    ST_MAC   = 4'd4,  // pure compute
    ST_STC   = 4'd5,  // store C tile
    ST_DONE  = 4'd6
  } state_e;

  state_e state_q, state_d;
  logic [31:0] m_q, n_q, k_q;
  logic [15:0] lda_q, ldb_q;
  logic [AddrWidth-1:0] pa_q, pb_q, pc_q;

  // Tile indices: load (i,t) or (t,j); compute (i,j,t); store (i,j)
  logic [31:0] i_q, j_q, t_q;
  logic [31:0] acc_q, acc_d;
  logic        err_q, err_d;
  logic        done_q;
  logic        ar_sent_q, ar_sent_d;
  logic        aw_sent_q, aw_sent_d;
  logic        w_sent_q, w_sent_d;

  // On-chip tiles (flop array; maps to tc_sram banks at full I1)
  logic signed [7:0]  a_mem_q [TileElems];
  logic signed [7:0]  b_mem_q [TileElems];
  logic        [31:0] c_mem_q [TileElems];

  assign ready_o = (state_q == ST_IDLE);
  assign done_o  = done_q;
  assign err_o   = err_q;

  function automatic logic [AddrWidth-1:0] a_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] i, t,
      input logic [15:0] lda
  );
    return base + AddrWidth'((i * 32'(lda) + t));
  endfunction

  function automatic logic [AddrWidth-1:0] b_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] t, j,
      input logic [15:0] ldb
  );
    return base + AddrWidth'((t * 32'(ldb) + j));
  endfunction

  function automatic logic [AddrWidth-1:0] c_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] i, j, n
  );
    return base + AddrWidth'(((i * n + j) << 2));
  endfunction

  function automatic logic signed [7:0] byte_from_beat(
      input logic [63:0] data,
      input logic [2:0]  lane
  );
    return data[8*lane +: 8];
  endfunction

  function automatic int unsigned a_idx(input logic [31:0] i, t);
    return int'(i) * MaxDim + int'(t);
  endfunction

  function automatic int unsigned b_idx(input logic [31:0] t, j);
    return int'(t) * MaxDim + int'(j);
  endfunction

  function automatic int unsigned c_idx(input logic [31:0] i, j);
    return int'(i) * MaxDim + int'(j);
  endfunction

  logic [AddrWidth-1:0] a_cur, b_cur, c_store_addr;
  assign a_cur        = a_addr(pa_q, i_q, t_q, lda_q);
  assign b_cur        = b_addr(pb_q, t_q, j_q, ldb_q);
  assign c_store_addr = c_addr(pc_q, i_q, j_q, n_q);

  always_comb begin
    axi_req_o = '0;
    axi_req_o.b_ready  = 1'b0;
    axi_req_o.r_ready  = 1'b0;
    axi_req_o.ar_valid = 1'b0;
    axi_req_o.aw_valid = 1'b0;
    axi_req_o.w_valid  = 1'b0;

    // ID=2: distinguish from desc-fetch (0) and completion store (1)
    axi_req_o.ar.id    = IdWidth'(2);
    axi_req_o.ar.len   = '0;
    axi_req_o.ar.size  = axi_pkg::size_t'($clog2(DataWidth / 8));
    axi_req_o.ar.burst = axi_pkg::BURST_INCR;
    axi_req_o.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    axi_req_o.aw.id    = IdWidth'(2);
    axi_req_o.aw.len   = '0;
    axi_req_o.aw.size  = axi_pkg::size_t'(2);
    axi_req_o.aw.burst = axi_pkg::BURST_INCR;
    axi_req_o.aw.cache = '0;
    axi_req_o.w.last   = 1'b1;
    axi_req_o.w.strb   = '0;

    state_d   = state_q;
    acc_d     = acc_q;
    err_d     = err_q;
    ar_sent_d = ar_sent_q;
    aw_sent_d = aw_sent_q;
    w_sent_d  = w_sent_q;

    unique case (state_q)
      ST_IDLE: begin
        ar_sent_d = 1'b0;
        aw_sent_d = 1'b0;
        w_sent_d  = 1'b0;
        if (start_i) begin
          err_d   = 1'b0;
          state_d = ST_CHK;
        end
      end

      ST_CHK: begin
        if (m_q == 0 || n_q == 0 || k_q == 0
            || m_q > MaxDim || n_q > MaxDim || k_q > MaxDim
            || lda_q < k_q[15:0] || ldb_q < n_q[15:0]) begin
          err_d   = 1'b1;
          state_d = ST_DONE;
        end else begin
          ar_sent_d = 1'b0;
          state_d   = ST_LA;
        end
      end

      // ---- Load A[i,t] for i=0..m-1, t=0..k-1 ----
      ST_LA: begin
        axi_req_o.ar.addr  = {a_cur[AddrWidth-1:3], 3'b000};
        if (!ar_sent_q) begin
          axi_req_o.ar_valid = 1'b1;
          if (axi_resp_i.ar_ready) ar_sent_d = 1'b1;
        end
        axi_req_o.r_ready = 1'b1;
        if (ar_sent_q && axi_resp_i.r_valid) begin
          ar_sent_d = 1'b0;
          // index advance in FF; decide next state from current indices
          if (t_q + 1 == k_q && i_q + 1 == m_q)
            state_d = ST_LB;
          else
            state_d = ST_LA;
        end
      end

      // ---- Load B[t,j] for t=0..k-1, j=0..n-1 ----
      ST_LB: begin
        axi_req_o.ar.addr  = {b_cur[AddrWidth-1:3], 3'b000};
        if (!ar_sent_q) begin
          axi_req_o.ar_valid = 1'b1;
          if (axi_resp_i.ar_ready) ar_sent_d = 1'b1;
        end
        axi_req_o.r_ready = 1'b1;
        if (ar_sent_q && axi_resp_i.r_valid) begin
          ar_sent_d = 1'b0;
          if (j_q + 1 == n_q && t_q + 1 == k_q) begin
            state_d = ST_MAC;
            acc_d   = '0;
          end else
            state_d = ST_LB;
        end
      end

      // ---- MAC: one product/cycle, walk t fastest then j then i ----
      ST_MAC: begin
        // Full reduction sum for this cycle (used to commit C when t ends)
        acc_d = acc_q
              + 32'($signed(a_mem_q[a_idx(i_q, t_q)]))
              * 32'($signed(b_mem_q[b_idx(t_q, j_q)]));
        if (t_q + 1 == k_q) begin
          // C[i,j] = acc_d (FF block commits before clear)
          if (j_q + 1 == n_q && i_q + 1 == m_q) begin
            state_d   = ST_STC;
            aw_sent_d = 1'b0;
            w_sent_d  = 1'b0;
            // leave acc_d as final sum (unused after)
          end else begin
            // next (i,j) starts a fresh accumulator next cycle
            state_d = ST_MAC;
          end
        end
      end

      // ---- Store C[i,j] ----
      ST_STC: begin
        axi_req_o.aw.addr = c_store_addr;
        if (DataWidth >= 64 && c_store_addr[2]) begin
          axi_req_o.w.data = DataWidth'({c_mem_q[c_idx(i_q, j_q)], 32'h0});
          axi_req_o.w.strb = {{(DataWidth/8-8){1'b0}}, 8'hF0};
        end else begin
          axi_req_o.w.data = DataWidth'(c_mem_q[c_idx(i_q, j_q)]);
          axi_req_o.w.strb = {{(DataWidth/8-4){1'b0}}, 4'hF};
        end
        if (!aw_sent_q) begin
          axi_req_o.aw_valid = 1'b1;
          if (axi_resp_i.aw_ready) aw_sent_d = 1'b1;
        end
        if (!w_sent_q) begin
          axi_req_o.w_valid = 1'b1;
          if (axi_resp_i.w_ready) w_sent_d = 1'b1;
        end
        axi_req_o.b_ready = 1'b1;
        if (aw_sent_q && w_sent_q && axi_resp_i.b_valid) begin
          if (axi_resp_i.b.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
            err_d = 1'b1;
          aw_sent_d = 1'b0;
          w_sent_d  = 1'b0;
          if (j_q + 1 == n_q && i_q + 1 == m_q)
            state_d = ST_DONE;
          else
            state_d = ST_STC;
        end
      end

      ST_DONE: begin
        state_d = ST_IDLE;
      end

      default: state_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= ST_IDLE;
      m_q <= '0; n_q <= '0; k_q <= '0;
      lda_q <= '0; ldb_q <= '0;
      pa_q <= '0; pb_q <= '0; pc_q <= '0;
      i_q <= '0; j_q <= '0; t_q <= '0;
      acc_q <= '0;
      err_q <= 1'b0;
      done_q <= 1'b0;
      ar_sent_q <= 1'b0;
      aw_sent_q <= 1'b0;
      w_sent_q <= 1'b0;
      for (int unsigned e = 0; e < TileElems; e++) begin
        a_mem_q[e] <= '0;
        b_mem_q[e] <= '0;
        c_mem_q[e] <= '0;
      end
    end else begin
      state_q   <= state_d;
      acc_q     <= acc_d;
      err_q     <= err_d;
      ar_sent_q <= ar_sent_d;
      aw_sent_q <= aw_sent_d;
      w_sent_q  <= w_sent_d;
      done_q    <= (state_q == ST_DONE);

      if (state_q == ST_IDLE && start_i) begin
        m_q   <= m_i;
        n_q   <= n_i;
        k_q   <= k_i;
        lda_q <= lda_i;
        ldb_q <= ldb_i;
        pa_q  <= ptr_a_i;
        pb_q  <= ptr_b_i;
        pc_q  <= ptr_c_i;
        i_q   <= '0;
        j_q   <= '0;
        t_q   <= '0;
      end

      // Capture A load + advance (i,t) with t fastest
      if (state_q == ST_LA && ar_sent_q && axi_resp_i.r_valid) begin
        a_mem_q[a_idx(i_q, t_q)] <= byte_from_beat(axi_resp_i.r.data, a_cur[2:0]);
        if (axi_resp_i.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
        if (t_q + 1 == k_q) begin
          t_q <= '0;
          if (i_q + 1 != m_q)
            i_q <= i_q + 1;
          else begin
            // A complete → reset for B load (t,j)
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
          end
        end else
          t_q <= t_q + 1;
      end

      // Capture B load + advance (t,j) with j fastest
      if (state_q == ST_LB && ar_sent_q && axi_resp_i.r_valid) begin
        b_mem_q[b_idx(t_q, j_q)] <= byte_from_beat(axi_resp_i.r.data, b_cur[2:0]);
        if (axi_resp_i.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
        if (j_q + 1 == n_q) begin
          j_q <= '0;
          if (t_q + 1 != k_q)
            t_q <= t_q + 1;
          else begin
            // B complete → reset for MAC (i,j,t)
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
          end
        end else
          j_q <= j_q + 1;
      end

      // MAC index walk + commit C element when t exhausts
      if (state_q == ST_MAC) begin
        if (t_q + 1 == k_q) begin
          // Commit full reduction (acc_d still holds the sum this cycle)
          c_mem_q[c_idx(i_q, j_q)] <= acc_d;
          t_q   <= '0;
          acc_q <= '0;  // next (i,j) starts at zero (overrides comb acc_d)
          if (j_q + 1 == n_q) begin
            j_q <= '0;
            if (i_q + 1 != m_q)
              i_q <= i_q + 1;
            else begin
              // all C done → reset for store walk
              i_q <= '0;
              j_q <= '0;
            end
          end else
            j_q <= j_q + 1;
        end else
          t_q <= t_q + 1;
      end

      // Store walk (i,j) with j fastest after successful B
      if (state_q == ST_STC && aw_sent_q && w_sent_q && axi_resp_i.b_valid) begin
        if (j_q + 1 == n_q) begin
          j_q <= '0;
          if (i_q + 1 != m_q)
            i_q <= i_q + 1;
        end else
          j_q <= j_q + 1;
      end
    end
  end

endmodule
