// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai I1-lite: sequential INT8 GEMM over AXI (bring-up / bit-exact slice).
//
//   C[i,j] (i32) = sum_t A[i,t]*B[t,j]  with A,B int8, row-major
//   lda/ldb from descriptor; C uses ldc = n (contiguous rows).
//
// Bounds: m,n,k ∈ [1, MaxDim]. Larger jobs return err without traffic.
// Timing: multi-cycle; one outstanding AXI beat; does not lengthen core paths.

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

  typedef enum logic [3:0] {
    ST_IDLE  = 4'd0,
    ST_CHK   = 4'd1,
    ST_LDA   = 4'd2,
    ST_LDB   = 4'd3,
    ST_MAC   = 4'd4,
    ST_STC   = 4'd5,
    ST_NEXT  = 4'd6,
    ST_DONE  = 4'd7
  } state_e;

  state_e state_q, state_d;
  logic [31:0] m_q, n_q, k_q;
  logic [15:0] lda_q, ldb_q;
  logic [AddrWidth-1:0] pa_q, pb_q, pc_q;
  logic [31:0] i_q, j_q, t_q;
  logic [31:0] acc_q, acc_d;
  logic signed [7:0] a_q, b_q;
  logic        err_q, err_d;
  logic        done_q;
  logic        ar_sent_q, ar_sent_d;
  logic        aw_sent_q, aw_sent_d;
  logic        w_sent_q, w_sent_d;

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

  // Extract byte from 64-bit beat given address[2:0]
  function automatic logic signed [7:0] byte_from_beat(
      input logic [63:0] data,
      input logic [2:0]  lane
  );
    return data[8*lane +: 8];
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
    // Full-beat load; extract the needed byte by address lane (slave-friendly).
    axi_req_o.ar.size  = axi_pkg::size_t'($clog2(DataWidth / 8));
    axi_req_o.ar.burst = axi_pkg::BURST_INCR;
    axi_req_o.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    axi_req_o.aw.id    = IdWidth'(2);
    axi_req_o.aw.len   = '0;
    axi_req_o.aw.size  = axi_pkg::size_t'(2); // 4-byte C element
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
          acc_d   = '0;
          state_d = ST_LDA;
          ar_sent_d = 1'b0;
        end
      end

      ST_LDA: begin
        // Beat-aligned AR; byte lane selected on RDATA capture
        axi_req_o.ar.addr  = {a_cur[AddrWidth-1:3], 3'b000};
        if (!ar_sent_q) begin
          axi_req_o.ar_valid = 1'b1;
          if (axi_resp_i.ar_ready) ar_sent_d = 1'b1;
        end
        axi_req_o.r_ready = 1'b1;
        if (ar_sent_q && axi_resp_i.r_valid) begin
          // capture in FF block via a_q
          ar_sent_d = 1'b0;
          state_d   = ST_LDB;
        end
      end

      ST_LDB: begin
        axi_req_o.ar.addr  = {b_cur[AddrWidth-1:3], 3'b000};
        if (!ar_sent_q) begin
          axi_req_o.ar_valid = 1'b1;
          if (axi_resp_i.ar_ready) ar_sent_d = 1'b1;
        end
        axi_req_o.r_ready = 1'b1;
        if (ar_sent_q && axi_resp_i.r_valid) begin
          ar_sent_d = 1'b0;
          state_d   = ST_MAC;
        end
      end

      ST_MAC: begin
        acc_d = acc_q + 32'($signed(a_q)) * 32'($signed(b_q));
        if (t_q + 1 == k_q) begin
          state_d   = ST_STC;
          aw_sent_d = 1'b0;
          w_sent_d  = 1'b0;
        end else begin
          // next k
          state_d   = ST_LDA;
          ar_sent_d = 1'b0;
        end
      end

      ST_STC: begin
        // C is 4-byte aligned; place i32 in the correct 32-bit lane of the beat
        axi_req_o.aw.addr = c_store_addr;
        if (DataWidth >= 64 && c_store_addr[2]) begin
          axi_req_o.w.data = DataWidth'({acc_q, 32'h0});
          axi_req_o.w.strb = {{(DataWidth/8-8){1'b0}}, 8'hF0};
        end else begin
          axi_req_o.w.data = DataWidth'(acc_q);
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
          state_d = ST_NEXT;
        end
      end

      ST_NEXT: begin
        // advance j, then i
        if (j_q + 1 == n_q) begin
          if (i_q + 1 == m_q) begin
            state_d = ST_DONE;
          end else begin
            // i++, j=0, t=0, acc=0
            state_d   = ST_LDA;
            ar_sent_d = 1'b0;
            acc_d     = '0;
          end
        end else begin
          state_d   = ST_LDA;
          ar_sent_d = 1'b0;
          acc_d     = '0;
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
      a_q <= '0; b_q <= '0;
      err_q <= 1'b0;
      done_q <= 1'b0;
      ar_sent_q <= 1'b0;
      aw_sent_q <= 1'b0;
      w_sent_q <= 1'b0;
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

      // Capture load data
      if (state_q == ST_LDA && ar_sent_q && axi_resp_i.r_valid) begin
        a_q <= byte_from_beat(axi_resp_i.r.data, a_cur[2:0]);
        if (axi_resp_i.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
      end
      if (state_q == ST_LDB && ar_sent_q && axi_resp_i.r_valid) begin
        b_q <= byte_from_beat(axi_resp_i.r.data, b_cur[2:0]);
        if (axi_resp_i.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
      end

      // Index updates on transitions
      if (state_q == ST_MAC && (t_q + 1 != k_q) && state_d == ST_LDA)
        t_q <= t_q + 1;
      if (state_q == ST_MAC && (t_q + 1 == k_q))
        t_q <= '0; // will store c; t reset for next (i,j)

      if (state_q == ST_NEXT) begin
        t_q <= '0;
        if (j_q + 1 == n_q) begin
          j_q <= '0;
          if (i_q + 1 != m_q)
            i_q <= i_q + 1;
        end else begin
          j_q <= j_q + 1;
        end
      end
    end
  end

endmodule
