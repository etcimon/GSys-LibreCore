// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai I1-lite: INT8 GEMM over AXI with banked tc_sram tiles + PE array.
//
//   C[i,j] (i32) = sum_t A[i,t]*B[t,j]  with A,B int8, row-major
//   lda/ldb from descriptor; C uses ldc = n (contiguous rows).
//
// Phases:
//   1) Load A → banked tile SRAM (bank = t % PeLanes)
//      Multi-byte: one AXI beat unpacks up to min(8, PeLanes, k-t) consecutive
//      A[i,t..] into distinct banks in one cycle (row-major).
//   2) Load B → banked tile SRAM (bank = t % PeLanes)
//      Beat-buffered: after AR/R, drain remaining j-bytes from the held beat
//      without re-AR (same-bank writes, one/cycle).
//   3) MAC: PeLanes parallel products/cycle via g6lc_ai_pe_dot
//   4) Store C: when j is even and j+1 < n, pack two i32 into one 64-bit
//      AXI beat (Latency=0 C read: capture lo, then store {hi,lo}).
//
// Bounds: m,n,k ∈ [1, MaxDim]. Larger jobs return err without traffic.
// Timing: multi-cycle; one outstanding AXI beat; no core critical path.

module g6lc_ai_gemm_seq #(
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned DataWidth = 64,
    parameter int unsigned IdWidth   = 4,
    parameter int unsigned MaxDim    = 8,
    parameter int unsigned PeLanes   = 4,  // parallel MACs / cycle (power of 2 preferred)
    parameter type         axi_req_t  = logic,
    parameter type         axi_resp_t = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,
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

  // Words per bank: MaxDim rows × ceil(MaxDim/PeLanes) cols along t (or j for B)
  localparam int unsigned KPerBank  = (MaxDim + PeLanes - 1) / PeLanes;
  localparam int unsigned BankWords = MaxDim * KPerBank;
  localparam int unsigned BankAddrW = (BankWords > 1) ? $clog2(BankWords) : 1;
  localparam int unsigned CElems    = MaxDim * MaxDim;
  localparam int unsigned CAddrW    = (CElems > 1) ? $clog2(CElems) : 1;
  localparam int unsigned LaneW     = (PeLanes > 1) ? $clog2(PeLanes) : 1;

  typedef enum logic [3:0] {
    ST_IDLE  = 4'd0,
    ST_CHK   = 4'd1,
    ST_LA    = 4'd2,
    ST_LB    = 4'd3,
    ST_MAC   = 4'd4,
    ST_STC   = 4'd5,
    ST_DONE  = 4'd6
  } state_e;

  state_e state_q, state_d;
  logic [31:0] m_q, n_q, k_q;
  logic [15:0] lda_q, ldb_q;
  logic [AddrWidth-1:0] pa_q, pb_q, pc_q;

  // i,j element indices; t is reduction base (multiple of PeLanes during MAC)
  logic [31:0] i_q, j_q, t_q;
  logic [31:0] acc_q, acc_d;
  logic        err_q, err_d;
  logic        done_q;
  logic        ar_sent_q, ar_sent_d;
  logic        aw_sent_q, aw_sent_d;
  logic        w_sent_q, w_sent_d;

  // A multi-byte unpack count (this R cycle)
  logic [3:0]  la_n_d;
  // B beat hold: leftover consecutive j-bytes after AR/R
  logic [63:0] beat_q;
  logic [2:0]  beat_lane_q, beat_lane_d;
  logic [3:0]  beat_left_q, beat_left_d;
  logic        beat_load_d;  // capture RDATA into beat_q
  logic [63:0] beat_data_d;

  // C dual-store pack: hold low i32, then write {hi,lo} on 64-bit bus
  logic        c_pair_hold_q, c_pair_hold_d;
  logic [31:0] c_lo_q;
  logic        c_lo_we_d;
  logic [3:0]  stc_n_d;  // 1 or 2 elements retired on B resp

  // ---- Banked A/B tile ports ----
  logic                 a_r_req  [PeLanes];
  logic [BankAddrW-1:0] a_r_addr [PeLanes];
  logic [7:0]           a_r_data [PeLanes];
  logic                 a_w_req  [PeLanes];
  logic [BankAddrW-1:0] a_w_addr [PeLanes];
  logic [7:0]           a_w_data [PeLanes];

  logic                 b_r_req  [PeLanes];
  logic [BankAddrW-1:0] b_r_addr [PeLanes];
  logic [7:0]           b_r_data [PeLanes];
  logic                 b_w_req  [PeLanes];
  logic [BankAddrW-1:0] b_w_addr [PeLanes];
  logic [7:0]           b_w_data [PeLanes];

  logic                 c_r_req, c_w_req;
  logic [CAddrW-1:0]    c_r_addr, c_w_addr;
  logic [31:0]          c_r_data, c_w_data;

  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_a_banks
    g6lc_ai_tile_sram #(
        .NumWords (BankWords),
        .DataWidth(8),
        .ImplKey  ("g6lc_ai_tile_a")
    ) i_tile_a (
        .clk_i, .rst_ni, .testmode_i,
        .r_req_i (a_r_req[p]), .r_addr_i(a_r_addr[p]), .r_data_o(a_r_data[p]),
        .w_req_i (a_w_req[p]), .w_addr_i(a_w_addr[p]), .w_data_i(a_w_data[p])
    );
  end

  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_b_banks
    g6lc_ai_tile_sram #(
        .NumWords (BankWords),
        .DataWidth(8),
        .ImplKey  ("g6lc_ai_tile_b")
    ) i_tile_b (
        .clk_i, .rst_ni, .testmode_i,
        .r_req_i (b_r_req[p]), .r_addr_i(b_r_addr[p]), .r_data_o(b_r_data[p]),
        .w_req_i (b_w_req[p]), .w_addr_i(b_w_addr[p]), .w_data_i(b_w_data[p])
    );
  end

  g6lc_ai_tile_sram #(
      .NumWords (CElems),
      .DataWidth(32),
      .ImplKey  ("g6lc_ai_tile_c")
  ) i_tile_c (
      .clk_i, .rst_ni, .testmode_i,
      .r_req_i (c_r_req), .r_addr_i(c_r_addr), .r_data_o(c_r_data),
      .w_req_i (c_w_req), .w_addr_i(c_w_addr), .w_data_i(c_w_data)
  );

  // PE: multi-lane MAC (driven only in ST_MAC)
  logic signed [7:0] pe_a [PeLanes];
  logic signed [7:0] pe_b [PeLanes];
  logic              pe_v [PeLanes];
  logic       [31:0] pe_acc_out;

  g6lc_ai_pe_dot #(.Lanes(PeLanes)) i_pe (
      .a_i     (pe_a),
      .b_i     (pe_b),
      .valid_i (pe_v),
      .acc_i   (acc_q),
      .acc_o   (pe_acc_out)
  );

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

  // Bank map: bank = t % PeLanes (or t for A / B along reduction);
  // local index = i * KPerBank + t / PeLanes  (A); for B: j * KPerBank + t / PeLanes
  function automatic logic [LaneW-1:0] t_bank(input logic [31:0] t);
    return LaneW'(t % PeLanes);
  endfunction

  function automatic logic [BankAddrW-1:0] a_bank_addr(
      input logic [31:0] i, t
  );
    return BankAddrW'(int'(i) * KPerBank + int'(t / PeLanes));
  endfunction

  function automatic logic [BankAddrW-1:0] b_bank_addr(
      input logic [31:0] t, j
  );
    return BankAddrW'(int'(j) * KPerBank + int'(t / PeLanes));
  endfunction

  function automatic logic [CAddrW-1:0] c_idx(input logic [31:0] i, j);
    return CAddrW'(int'(i) * MaxDim + int'(j));
  endfunction

  logic [AddrWidth-1:0] a_cur, b_cur, c_store_addr;
  assign a_cur        = a_addr(pa_q, i_q, t_q, lda_q);
  assign b_cur        = b_addr(pb_q, t_q, j_q, ldb_q);
  assign c_store_addr = c_addr(pc_q, i_q, j_q, n_q);

  always_comb begin
    // defaults: idle banks + AXI
    for (int unsigned p = 0; p < PeLanes; p++) begin
      a_r_req[p]  = 1'b0;
      a_r_addr[p] = '0;
      a_w_req[p]  = 1'b0;
      a_w_addr[p] = '0;
      a_w_data[p] = '0;
      b_r_req[p]  = 1'b0;
      b_r_addr[p] = '0;
      b_w_req[p]  = 1'b0;
      b_w_addr[p] = '0;
      b_w_data[p] = '0;
      pe_a[p]     = '0;
      pe_b[p]     = '0;
      pe_v[p]     = 1'b0;
    end
    c_r_req  = 1'b0;
    c_r_addr = '0;
    c_w_req  = 1'b0;
    c_w_addr = '0;
    c_w_data = '0;

    axi_req_o = '0;
    axi_req_o.b_ready  = 1'b0;
    axi_req_o.r_ready  = 1'b0;
    axi_req_o.ar_valid = 1'b0;
    axi_req_o.aw_valid = 1'b0;
    axi_req_o.w_valid  = 1'b0;
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

    state_d     = state_q;
    acc_d       = acc_q;
    err_d       = err_q;
    ar_sent_d   = ar_sent_q;
    aw_sent_d   = aw_sent_q;
    w_sent_d    = w_sent_q;
    la_n_d        = 4'd0;
    beat_left_d   = beat_left_q;
    beat_lane_d   = beat_lane_q;
    beat_load_d   = 1'b0;
    beat_data_d   = beat_q;
    c_pair_hold_d = c_pair_hold_q;
    c_lo_we_d     = 1'b0;
    stc_n_d       = 4'd1;

    unique case (state_q)
      ST_IDLE: begin
        ar_sent_d     = 1'b0;
        aw_sent_d     = 1'b0;
        w_sent_d      = 1'b0;
        beat_left_d   = 4'd0;
        c_pair_hold_d = 1'b0;
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
          ar_sent_d   = 1'b0;
          beat_left_d = 4'd0;
          state_d     = ST_LA;
        end
      end

      // Load A: multi-byte unpack from one beat into distinct banks (t%PeLanes)
      ST_LA: begin
        axi_req_o.ar.addr = {a_cur[AddrWidth-1:3], 3'b000};
        if (!ar_sent_q) begin
          axi_req_o.ar_valid = 1'b1;
          if (axi_resp_i.ar_ready) ar_sent_d = 1'b1;
        end
        axi_req_o.r_ready = 1'b1;
        if (ar_sent_q && axi_resp_i.r_valid) begin
          // n = min(k-t, 8-lane, PeLanes) consecutive elements
          begin
            automatic logic [2:0]  lane0;
            automatic logic [31:0] n_take, rem_k, rem_beat;
            lane0    = a_cur[2:0];
            rem_k    = k_q - t_q;
            rem_beat = 32'(8) - 32'(lane0);
            n_take   = rem_k;
            if (n_take > rem_beat) n_take = rem_beat;
            if (n_take > PeLanes)  n_take = PeLanes;
            la_n_d = n_take[3:0];
            for (int unsigned p = 0; p < PeLanes; p++) begin
              if (32'(p) < n_take) begin
                automatic logic [31:0] tt;
                tt = t_q + 32'(p);
                a_w_req [t_bank(tt)] = 1'b1;
                a_w_addr[t_bank(tt)] = a_bank_addr(i_q, tt);
                a_w_data[t_bank(tt)] = byte_from_beat(
                    axi_resp_i.r.data, 3'(unsigned'(lane0) + p));
              end
            end
          end
          ar_sent_d = 1'b0;
          // end-of-A if this finishes last row
          if ((t_q + 32'(la_n_d) >= k_q) && (i_q + 1 == m_q))
            state_d = ST_LB;
          else
            state_d = ST_LA;
        end
      end

      // Load B: AR/R then drain rest of beat along j (same t-bank, 1/cycle)
      ST_LB: begin
        if (beat_left_q != 4'd0) begin
          // Drain held beat — no AXI
          b_w_req [t_bank(t_q)] = 1'b1;
          b_w_addr[t_bank(t_q)] = b_bank_addr(t_q, j_q);
          b_w_data[t_bank(t_q)] = byte_from_beat(beat_q, beat_lane_q);
          beat_left_d = beat_left_q - 4'd1;
          beat_lane_d = beat_lane_q + 3'd1;
          if (j_q + 1 == n_q && t_q + 1 == k_q) begin
            state_d     = ST_MAC;
            acc_d       = '0;
            beat_left_d = 4'd0;
          end else
            state_d = ST_LB;
        end else begin
          axi_req_o.ar.addr = {b_cur[AddrWidth-1:3], 3'b000};
          if (!ar_sent_q) begin
            axi_req_o.ar_valid = 1'b1;
            if (axi_resp_i.ar_ready) ar_sent_d = 1'b1;
          end
          axi_req_o.r_ready = 1'b1;
          if (ar_sent_q && axi_resp_i.r_valid) begin
            b_w_req [t_bank(t_q)] = 1'b1;
            b_w_addr[t_bank(t_q)] = b_bank_addr(t_q, j_q);
            b_w_data[t_bank(t_q)] = byte_from_beat(axi_resp_i.r.data, b_cur[2:0]);
            ar_sent_d   = 1'b0;
            beat_load_d = 1'b1;
            beat_data_d = axi_resp_i.r.data[63:0];
            // leftover bytes in beat after this lane, limited by row remainder
            begin
              automatic logic [31:0] left_beat, rem_row;
              left_beat = 32'(7) - 32'(b_cur[2:0]);
              rem_row   = n_q - j_q - 32'd1;
              if (left_beat > rem_row) left_beat = rem_row;
              beat_left_d = left_beat[3:0];
              beat_lane_d = b_cur[2:0] + 3'd1;
            end
            if (j_q + 1 == n_q && t_q + 1 == k_q) begin
              state_d     = ST_MAC;
              acc_d       = '0;
              beat_left_d = 4'd0;
            end else
              state_d = ST_LB;
          end
        end
      end

      // Parallel MAC: lanes cover t_q .. t_q+PeLanes-1
      ST_MAC: begin
        for (int unsigned p = 0; p < PeLanes; p++) begin
          automatic logic [31:0] tt;
          tt = t_q + 32'(p);
          if (tt < k_q) begin
            a_r_req [p] = 1'b1;
            a_r_addr[p] = a_bank_addr(i_q, tt);
            b_r_req [p] = 1'b1;
            b_r_addr[p] = b_bank_addr(tt, j_q);
            pe_a[p]     = $signed(a_r_data[p]);
            pe_b[p]     = $signed(b_r_data[p]);
            pe_v[p]     = 1'b1;
          end
        end
        acc_d = pe_acc_out;
        // Advance reduction base by PeLanes
        if (t_q + PeLanes >= k_q) begin
          // C[i,j] complete this cycle
          c_w_req  = 1'b1;
          c_w_addr = c_idx(i_q, j_q);
          c_w_data = pe_acc_out;
          if (j_q + 1 == n_q && i_q + 1 == m_q) begin
            state_d       = ST_STC;
            aw_sent_d     = 1'b0;
            w_sent_d      = 1'b0;
            c_pair_hold_d = 1'b0;
          end else
            state_d = ST_MAC;
        end else
          state_d = ST_MAC;
      end

      ST_STC: begin
        // Pack two i32 when j even, j+1 exists, and bus is ≥64-bit
        begin
          automatic logic can_pair;
          can_pair = (DataWidth >= 64) && !j_q[0] && (j_q + 1 < n_q);

          if (can_pair && !c_pair_hold_q) begin
            // Phase 0: capture C[i,j] (combo read → FF)
            c_r_req   = 1'b1;
            c_r_addr  = c_idx(i_q, j_q);
            c_lo_we_d = 1'b1;
            c_pair_hold_d = 1'b1;
            state_d   = ST_STC;
          end else if (can_pair && c_pair_hold_q) begin
            // Phase 1: C[i,j+1] + full-beat store {hi, lo}
            c_r_req  = 1'b1;
            c_r_addr = c_idx(i_q, j_q + 32'd1);
            axi_req_o.aw.addr = c_store_addr;  // j even ⇒ 8-byte aligned
            axi_req_o.w.data  = DataWidth'({c_r_data, c_lo_q});
            axi_req_o.w.strb  = {{(DataWidth/8-8){1'b0}}, 8'hFF};
            stc_n_d = 4'd2;
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
              aw_sent_d     = 1'b0;
              w_sent_d      = 1'b0;
              c_pair_hold_d = 1'b0;
              if (j_q + 2 >= n_q && i_q + 1 == m_q)
                state_d = ST_DONE;
              else
                state_d = ST_STC;
            end
          end else begin
            // Single i32 store
            c_r_req  = 1'b1;
            c_r_addr = c_idx(i_q, j_q);
            axi_req_o.aw.addr = c_store_addr;
            if (DataWidth >= 64 && c_store_addr[2]) begin
              axi_req_o.w.data = DataWidth'({c_r_data, 32'h0});
              axi_req_o.w.strb = {{(DataWidth/8-8){1'b0}}, 8'hF0};
            end else begin
              axi_req_o.w.data = DataWidth'(c_r_data);
              axi_req_o.w.strb = {{(DataWidth/8-4){1'b0}}, 4'hF};
            end
            stc_n_d = 4'd1;
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
              aw_sent_d     = 1'b0;
              w_sent_d      = 1'b0;
              c_pair_hold_d = 1'b0;
              if (j_q + 1 == n_q && i_q + 1 == m_q)
                state_d = ST_DONE;
              else
                state_d = ST_STC;
            end
          end
        end
      end

      ST_DONE: state_d = ST_IDLE;
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
      beat_q <= '0;
      beat_lane_q <= '0;
      beat_left_q <= '0;
      c_pair_hold_q <= 1'b0;
      c_lo_q <= '0;
    end else begin
      state_q       <= state_d;
      acc_q         <= acc_d;
      err_q         <= err_d;
      ar_sent_q     <= ar_sent_d;
      aw_sent_q     <= aw_sent_d;
      w_sent_q      <= w_sent_d;
      beat_left_q   <= beat_left_d;
      beat_lane_q   <= beat_lane_d;
      c_pair_hold_q <= c_pair_hold_d;
      if (beat_load_d) beat_q <= beat_data_d;
      if (c_lo_we_d)   c_lo_q <= c_r_data;
      done_q        <= (state_q == ST_DONE);

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
        beat_left_q   <= '0;
        c_pair_hold_q <= 1'b0;
      end

      // A load: advance t by la_n_d (multi-byte unpack)
      if (state_q == ST_LA && ar_sent_q && axi_resp_i.r_valid) begin
        if (axi_resp_i.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
        if (t_q + 32'(la_n_d) >= k_q) begin
          t_q <= '0;
          if (i_q + 1 != m_q)
            i_q <= i_q + 1;
          else begin
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
          end
        end else
          t_q <= t_q + 32'(la_n_d);
      end

      // B load: one element per cycle (AR/R or beat drain)
      if (state_q == ST_LB &&
          ((beat_left_q != 4'd0) || (ar_sent_q && axi_resp_i.r_valid))) begin
        if (ar_sent_q && axi_resp_i.r_valid &&
            (axi_resp_i.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR}))
          err_q <= 1'b1;
        if (j_q + 1 == n_q) begin
          j_q <= '0;
          beat_left_q <= '0;  // new row needs fresh AR (overrides comb drain)
          if (t_q + 1 != k_q)
            t_q <= t_q + 1;
          else begin
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
          end
        end else
          j_q <= j_q + 1;
      end

      // MAC: t_q is reduction base; advance by PeLanes, then (i,j)
      if (state_q == ST_MAC) begin
        if (t_q + PeLanes >= k_q) begin
          t_q   <= '0;
          acc_q <= '0;
          if (j_q + 1 == n_q) begin
            j_q <= '0;
            if (i_q + 1 != m_q)
              i_q <= i_q + 1;
            else begin
              i_q <= '0;
              j_q <= '0;
            end
          end else
            j_q <= j_q + 1;
        end else
          t_q <= t_q + PeLanes;
      end

      // C store: advance by stc_n_d (1 or 2) on B complete
      if (state_q == ST_STC && aw_sent_q && w_sent_q && axi_resp_i.b_valid) begin
        if (j_q + 32'(stc_n_d) >= n_q) begin
          j_q <= '0;
          if (i_q + 1 != m_q)
            i_q <= i_q + 1;
        end else
          j_q <= j_q + 32'(stc_n_d);
      end
    end
  end

endmodule
