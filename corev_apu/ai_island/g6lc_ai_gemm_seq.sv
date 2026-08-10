// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai I1/I3-lite: INT8 GEMM over AXI with banked tc_sram tiles + PE array.
//
//   C[i,j] (i32) = sum_t A[i,t]*B[t,j]  with A,B int8, row-major
//   lda/ldb from descriptor; C uses ldc = n (contiguous rows).
//
// Phases:
//   1) Load A → banked tile SRAM (bank = t % PeLanes)
//      Multi-byte unpack; AXI INCR burst (up to MaxBurstBeats) along the row.
//   2) Load B → banked tile SRAM (bank = t % PeLanes)
//      Dual-write same bank (2 B/cycle) + AXI INCR burst along j; r_ready
//      gated while draining a beat so mid-burst R waits.
//   3) MAC: PeLanes parallel products/cycle via g6lc_ai_pe_dot
//   4) Store C: dual-i32 pack on ≥64-bit bus; multi-beat INCR AW (up to
//      MaxBurstBeats pair-beats) along a C row — same cap as A/B AR.
//
// C multi-banked (j % PeLanes). Beat packing parameterized by DataWidth.
// Bursts stay within a single A row (k), B row (n), or C row (n); never cross.
//
// Bounds: m,n,k ∈ [1, MaxDim]. Timing: multi-cycle; one outstanding AR/AW.

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
    // I3 PMU: sticky after last job (cleared on next start)
    output logic [31:0] pmu_r_beats_o,
    output logic [31:0] pmu_w_beats_o,
    output logic [31:0] pmu_cycles_o,
    output axi_req_t    axi_req_o,
    input  axi_resp_t   axi_resp_i
);

  // Words per bank: MaxDim rows × ceil(MaxDim/PeLanes) cols along t (A/B) or j (C)
  localparam int unsigned KPerBank     = (MaxDim + PeLanes - 1) / PeLanes;
  localparam int unsigned BankWords    = MaxDim * KPerBank;
  localparam int unsigned BankAddrW    = (BankWords > 1) ? $clog2(BankWords) : 1;
  localparam int unsigned LaneW        = (PeLanes > 1) ? $clog2(PeLanes) : 1;
  // AXI beat geometry (I3: wider DataWidth raises BytesPerBeat without RTL rewrite)
  localparam int unsigned BytesPerBeat  = DataWidth / 8;
  localparam int unsigned BeatAlignW    = (BytesPerBeat > 1) ? $clog2(BytesPerBeat) : 1;
  localparam int unsigned BeatLaneW     = (BytesPerBeat > 1) ? $clog2(BytesPerBeat) : 1;
  // Max beats per AR (AXI4 allows 256; 64 balances xbar buffers vs AR overhead)
  localparam int unsigned MaxBurstBeats = 64;

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
  // First R of an A/B burst uses misaligned lane; later Rs are beat-aligned
  logic        burst_first_q, burst_first_d;

  // A multi-byte unpack count (this R cycle); B dual-write count (1 or 2)
  logic [7:0]  la_n_d;
  logic [1:0]  lb_n_d;
  // B beat hold: leftover consecutive j-bytes after AR/R
  logic [DataWidth-1:0] beat_q;
  logic [BeatLaneW-1:0] beat_lane_q, beat_lane_d;
  logic [7:0]           beat_left_q, beat_left_d;
  logic                 beat_load_d;  // capture RDATA into beat_q
  logic [DataWidth-1:0] beat_data_d;

  // C dual-store pack: hold low i32, then write {hi,lo} on ≥64-bit bus.
  // Multi-beat: AW once with len=nbeats-1; stream W; advance j on B by stc_elem.
  logic        c_pair_hold_q, c_pair_hold_d;
  logic [31:0] c_lo_q;
  logic        c_lo_we_d;
  logic [7:0]  stc_w_left_q, stc_w_left_d;  // remaining W beats in open AW
  logic [7:0]  stc_elem_q, stc_elem_d;      // elements covered by open AW (B retire)
  logic [7:0]  stc_n_d;                     // elements retired on B (stc_elem)

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
  // I3-lite dual write on B banks (second address same bank, next j)
  logic                 b_w2_req  [PeLanes];
  logic [BankAddrW-1:0] b_w2_addr [PeLanes];
  logic [7:0]           b_w2_data [PeLanes];

  // C multi-bank (single outstanding R or W; bank = j % PeLanes)
  logic                 c_r_req, c_w_req;
  logic [LaneW-1:0]     c_r_bank, c_w_bank;
  logic [BankAddrW-1:0] c_r_addr, c_w_addr;
  logic [31:0]          c_r_data, c_w_data;
  logic [31:0]          c_r_data_b [PeLanes];

  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_a_banks
    g6lc_ai_tile_sram #(
        .NumWords (BankWords),
        .DataWidth(8),
        .ImplKey  ("g6lc_ai_tile_a")
    ) i_tile_a (
        .clk_i, .rst_ni, .testmode_i,
        .r_req_i (a_r_req[p]), .r_addr_i(a_r_addr[p]), .r_data_o(a_r_data[p]),
        .w_req_i (a_w_req[p]), .w_addr_i(a_w_addr[p]), .w_data_i(a_w_data[p]),
        .w2_req_i(1'b0), .w2_addr_i('0), .w2_data_i('0)
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
        .w_req_i (b_w_req[p]), .w_addr_i(b_w_addr[p]), .w_data_i(b_w_data[p]),
        .w2_req_i(b_w2_req[p]), .w2_addr_i(b_w2_addr[p]), .w2_data_i(b_w2_data[p])
    );
  end

  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_c_banks
    g6lc_ai_tile_sram #(
        .NumWords (BankWords),
        .DataWidth(32),
        .ImplKey  ("g6lc_ai_tile_c")
    ) i_tile_c (
        .clk_i, .rst_ni, .testmode_i,
        .r_req_i (c_r_req && (c_r_bank == LaneW'(p))),
        .r_addr_i(c_r_addr),
        .r_data_o(c_r_data_b[p]),
        .w_req_i (c_w_req && (c_w_bank == LaneW'(p))),
        .w_addr_i(c_w_addr),
        .w_data_i(c_w_data),
        .w2_req_i(1'b0), .w2_addr_i('0), .w2_data_i('0)
    );
  end

  // Latency=0 read mux (one bank selected per cycle)
  always_comb begin
    c_r_data = c_r_data_b[0];
    for (int unsigned p = 1; p < PeLanes; p++) begin
      if (c_r_bank == LaneW'(p))
        c_r_data = c_r_data_b[p];
    end
  end

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

  // I3 PMU accumulators (active while not IDLE/DONE)
  logic [31:0] pmu_r_q, pmu_w_q, pmu_cy_q;

  assign ready_o       = (state_q == ST_IDLE);
  assign done_o        = done_q;
  assign err_o         = err_q;
  assign pmu_r_beats_o = pmu_r_q;
  assign pmu_w_beats_o = pmu_w_q;
  assign pmu_cycles_o  = pmu_cy_q;

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
      input logic [DataWidth-1:0] data,
      input logic [BeatLaneW-1:0] lane
  );
    return data[8*lane +: 8];
  endfunction

  // Align AR address to beat boundary
  function automatic logic [AddrWidth-1:0] beat_align(input logic [AddrWidth-1:0] a);
    return {a[AddrWidth-1:BeatAlignW], BeatAlignW'(0)};
  endfunction

  // Beats needed to transfer `rem` elements starting at byte offset `lane0`
  // (row-contiguous). Caps at MaxBurstBeats. Assumes PeLanes >= BytesPerBeat
  // so each full beat is absorbed in one cycle for A (B drains multi-cycle).
  function automatic logic [7:0] beats_for_rem(
      input logic [31:0] rem,
      input logic [BeatLaneW-1:0] lane0
  );
    automatic logic [31:0] first, after, more, total, epb;
    if (rem == 0) return 8'd1;
    first = 32'(BytesPerBeat) - 32'(lane0);
    if (first > rem) first = rem;
    after = rem - first;
    epb   = 32'(BytesPerBeat);
    if (epb > PeLanes) epb = PeLanes;
    if (epb == 0) epb = 1;
    more  = (after + epb - 1) / epb;
    total = 32'd1 + more;
    if (total > MaxBurstBeats) total = MaxBurstBeats;
    if (total == 0) total = 1;
    return total[7:0];
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

  // C bank map: bank = j % PeLanes; local = i * KPerBank + j / PeLanes
  function automatic logic [LaneW-1:0] c_bank(input logic [31:0] j);
    return LaneW'(j % PeLanes);
  endfunction

  function automatic logic [BankAddrW-1:0] c_bank_addr(
      input logic [31:0] i, j
  );
    return BankAddrW'(int'(i) * KPerBank + int'(j / PeLanes));
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
      b_w2_req[p] = 1'b0;
      b_w2_addr[p] = '0;
      b_w2_data[p] = '0;
      pe_a[p]     = '0;
      pe_b[p]     = '0;
      pe_v[p]     = 1'b0;
    end
    c_r_req  = 1'b0;
    c_r_bank = '0;
    c_r_addr = '0;
    c_w_req  = 1'b0;
    c_w_bank = '0;
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
    axi_req_o.aw.size  = axi_pkg::size_t'(2);  // default 4B; pair path uses 8B
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
    la_n_d          = 8'd0;
    lb_n_d          = 2'd1;
    beat_left_d     = beat_left_q;
    beat_lane_d     = beat_lane_q;
    beat_load_d     = 1'b0;
    beat_data_d     = beat_q;
    burst_first_d   = burst_first_q;
    c_pair_hold_d   = c_pair_hold_q;
    c_lo_we_d       = 1'b0;
    stc_w_left_d    = stc_w_left_q;
    stc_elem_d      = stc_elem_q;
    stc_n_d         = stc_elem_q;  // default: retire full open AW on B

    unique case (state_q)
      ST_IDLE: begin
        ar_sent_d     = 1'b0;
        aw_sent_d     = 1'b0;
        w_sent_d      = 1'b0;
        beat_left_d   = 8'd0;
        burst_first_d = 1'b0;
        c_pair_hold_d = 1'b0;
        stc_w_left_d  = 8'd0;
        stc_elem_d    = 8'd0;
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
          ar_sent_d     = 1'b0;
          beat_left_d   = 8'd0;
          burst_first_d = 1'b0;
          state_d       = ST_LA;
        end
      end

      // Load A: multi-beat INCR along row; multi-byte unpack into t%PeLanes banks
      ST_LA: begin
        axi_req_o.ar.addr = beat_align(a_cur);
        if (!ar_sent_q) begin
          begin
            automatic logic [7:0] nb;
            nb = beats_for_rem(k_q - t_q, a_cur[BeatAlignW-1:0]);
            axi_req_o.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            axi_req_o.ar_valid = 1'b1;
            if (axi_resp_i.ar_ready) begin
              ar_sent_d     = 1'b1;
              burst_first_d = 1'b1;
            end
          end
        end
        axi_req_o.r_ready = 1'b1;
        if (ar_sent_q && axi_resp_i.r_valid) begin
          begin
            automatic logic [BeatLaneW-1:0] lane0;
            automatic logic [31:0] n_take, rem_k, rem_beat;
            lane0    = burst_first_q ? a_cur[BeatAlignW-1:0] : BeatLaneW'(0);
            rem_k    = k_q - t_q;
            rem_beat = 32'(BytesPerBeat) - 32'(lane0);
            n_take   = rem_k;
            if (n_take > rem_beat) n_take = rem_beat;
            if (n_take > PeLanes)  n_take = PeLanes;
            la_n_d = n_take[7:0];
            for (int unsigned p = 0; p < PeLanes; p++) begin
              if (32'(p) < n_take) begin
                automatic logic [31:0] tt;
                tt = t_q + 32'(p);
                a_w_req [t_bank(tt)] = 1'b1;
                a_w_addr[t_bank(tt)] = a_bank_addr(i_q, tt);
                a_w_data[t_bank(tt)] = byte_from_beat(
                    axi_resp_i.r.data, BeatLaneW'(unsigned'(lane0) + p));
              end
            end
          end
          burst_first_d = 1'b0;
          // Keep AR open until r.last of this burst
          if (axi_resp_i.r.last)
            ar_sent_d = 1'b0;
          else
            ar_sent_d = 1'b1;
          if ((t_q + 32'(la_n_d) >= k_q) && (i_q + 1 == m_q))
            state_d = ST_LB;
          else
            state_d = ST_LA;
        end
      end

      // Load B: dual-drain (2/cycle) + multi-beat INCR; r_ready off while draining
      ST_LB: begin
        if (beat_left_q != 8'd0) begin
          // Drain held beat — hold R if a burst is still open
          axi_req_o.r_ready = 1'b0;
          begin
            automatic logic [LaneW-1:0] bk;
            automatic logic            can2;
            bk   = t_bank(t_q);
            can2 = (beat_left_q >= 8'd2) && (j_q + 1 < n_q);
            b_w_req [bk] = 1'b1;
            b_w_addr[bk] = b_bank_addr(t_q, j_q);
            b_w_data[bk] = byte_from_beat(beat_q, beat_lane_q);
            if (can2) begin
              b_w2_req [bk] = 1'b1;
              b_w2_addr[bk] = b_bank_addr(t_q, j_q + 32'd1);
              b_w2_data[bk] = byte_from_beat(beat_q, BeatLaneW'(beat_lane_q + 1));
              lb_n_d        = 2'd2;
              beat_left_d   = beat_left_q - 8'd2;
              beat_lane_d   = BeatLaneW'(beat_lane_q + 2);
            end else begin
              lb_n_d      = 2'd1;
              beat_left_d = beat_left_q - 8'd1;
              beat_lane_d = BeatLaneW'(beat_lane_q + 1);
            end
            if (j_q + 32'(lb_n_d) >= n_q && t_q + 1 == k_q) begin
              state_d     = ST_MAC;
              acc_d       = '0;
              beat_left_d = 8'd0;
              ar_sent_d   = 1'b0;
            end else
              state_d = ST_LB;
          end
        end else begin
          axi_req_o.ar.addr = beat_align(b_cur);
          if (!ar_sent_q) begin
            begin
              automatic logic [7:0] nb;
              nb = beats_for_rem(n_q - j_q, b_cur[BeatAlignW-1:0]);
              axi_req_o.ar.len   = axi_pkg::len_t'(nb - 8'd1);
              axi_req_o.ar_valid = 1'b1;
              if (axi_resp_i.ar_ready) begin
                ar_sent_d     = 1'b1;
                burst_first_d = 1'b1;
              end
            end
          end
          axi_req_o.r_ready = ar_sent_q;
          if (ar_sent_q && axi_resp_i.r_valid) begin
            begin
              automatic logic [LaneW-1:0]     bk;
              automatic logic [BeatLaneW-1:0] lane0;
              automatic logic [31:0]          left_beat, rem_row;
              automatic logic                 can2;
              bk    = t_bank(t_q);
              lane0 = burst_first_q ? b_cur[BeatAlignW-1:0] : BeatLaneW'(0);
              can2  = (j_q + 1 < n_q) && (32'(lane0) + 1 < 32'(BytesPerBeat));
              b_w_req [bk] = 1'b1;
              b_w_addr[bk] = b_bank_addr(t_q, j_q);
              b_w_data[bk] = byte_from_beat(axi_resp_i.r.data, lane0);
              if (can2) begin
                b_w2_req [bk] = 1'b1;
                b_w2_addr[bk] = b_bank_addr(t_q, j_q + 32'd1);
                b_w2_data[bk] = byte_from_beat(
                    axi_resp_i.r.data, BeatLaneW'(lane0 + 1));
                lb_n_d = 2'd2;
                left_beat = 32'(BytesPerBeat) - 32'(lane0) - 32'd2;
                rem_row   = n_q - j_q - 32'd2;
                if (left_beat > rem_row) left_beat = rem_row;
                beat_left_d = left_beat[7:0];
                beat_lane_d = BeatLaneW'(lane0 + 2);
              end else begin
                lb_n_d = 2'd1;
                left_beat = 32'(BytesPerBeat) - 32'(lane0) - 32'd1;
                rem_row   = n_q - j_q - 32'd1;
                if (left_beat > rem_row) left_beat = rem_row;
                beat_left_d = left_beat[7:0];
                beat_lane_d = BeatLaneW'(lane0 + 1);
              end
              burst_first_d = 1'b0;
              beat_load_d   = 1'b1;
              beat_data_d   = axi_resp_i.r.data;
              if (axi_resp_i.r.last)
                ar_sent_d = 1'b0;
              else
                ar_sent_d = 1'b1;
              if (j_q + 32'(lb_n_d) >= n_q && t_q + 1 == k_q) begin
                state_d     = ST_MAC;
                acc_d       = '0;
                beat_left_d = 8'd0;
                ar_sent_d   = 1'b0;
              end else
                state_d = ST_LB;
            end
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
          c_w_bank = c_bank(j_q);
          c_w_addr = c_bank_addr(i_q, j_q);
          c_w_data = pe_acc_out;
          if (j_q + 1 == n_q && i_q + 1 == m_q) begin
            state_d       = ST_STC;
            aw_sent_d     = 1'b0;
            w_sent_d      = 1'b0;
            c_pair_hold_d = 1'b0;
            stc_w_left_d  = 8'd0;
            stc_elem_d    = 8'd0;
          end else
            state_d = ST_MAC;
        end else
          state_d = ST_MAC;
      end

      ST_STC: begin
        // Multi-beat pair path (≥64-bit): AW once, stream {hi,lo} W beats,
        // retire j by stc_elem on B. Single-i32 path when j odd or last col.
        begin
          automatic logic        can_pair;
          automatic logic [31:0] pairs_rem, nbeats, beats_done, j_eff;
          can_pair = (DataWidth >= 64) && !j_q[0] && (j_q + 1 < n_q);

          if (can_pair) begin
            // ---- open AW for up to MaxBurstBeats pair-beats along the row ----
            if (!aw_sent_q) begin
              pairs_rem = (n_q - j_q) >> 1;
              nbeats    = pairs_rem;
              if (nbeats > MaxBurstBeats) nbeats = MaxBurstBeats;
              if (nbeats == 0) nbeats = 1;
              axi_req_o.aw.addr  = c_store_addr;  // j even ⇒ 8B aligned
              axi_req_o.aw.len   = axi_pkg::len_t'(nbeats[7:0] - 8'd1);
              axi_req_o.aw.size  = axi_pkg::size_t'(3);  // 8-byte beats
              axi_req_o.aw_valid = 1'b1;
              if (axi_resp_i.aw_ready) begin
                aw_sent_d    = 1'b1;
                stc_w_left_d = nbeats[7:0];
                stc_elem_d   = nbeats[7:0] << 1;  // 2 i32 per beat
                w_sent_d     = 1'b0;
                c_pair_hold_d = 1'b0;
              end
            end else if (stc_w_left_q != 8'd0) begin
              // beats already written = nbeats - w_left; j_eff = j + 2*done
              beats_done = 32'(stc_elem_q >> 1) - 32'(stc_w_left_q);
              j_eff      = j_q + (beats_done << 1);
              if (!c_pair_hold_q) begin
                // capture C[i, j_eff]
                c_r_req       = 1'b1;
                c_r_bank      = c_bank(j_eff);
                c_r_addr      = c_bank_addr(i_q, j_eff);
                c_lo_we_d     = 1'b1;
                c_pair_hold_d = 1'b1;
              end else begin
                // W beat: {C[i,j_eff+1], C[i,j_eff]}
                c_r_req  = 1'b1;
                c_r_bank = c_bank(j_eff + 32'd1);
                c_r_addr = c_bank_addr(i_q, j_eff + 32'd1);
                axi_req_o.w.data = DataWidth'({c_r_data, c_lo_q});
                axi_req_o.w.strb = {{(DataWidth/8-8){1'b0}}, 8'hFF};
                axi_req_o.w.last = (stc_w_left_q == 8'd1);
                axi_req_o.w_valid = 1'b1;
                if (axi_resp_i.w_ready) begin
                  stc_w_left_d  = stc_w_left_q - 8'd1;
                  c_pair_hold_d = 1'b0;
                  if (stc_w_left_q == 8'd1)
                    w_sent_d = 1'b1;  // all W of this AW done
                end
              end
            end else begin
              // all W issued — wait B, then retire stc_elem columns
              axi_req_o.b_ready = 1'b1;
              stc_n_d = stc_elem_q;
              if (axi_resp_i.b_valid) begin
                if (axi_resp_i.b.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
                  err_d = 1'b1;
                aw_sent_d     = 1'b0;
                w_sent_d      = 1'b0;
                c_pair_hold_d = 1'b0;
                stc_elem_d    = 8'd0;
                if (j_q + 32'(stc_elem_q) >= n_q && i_q + 1 == m_q)
                  state_d = ST_DONE;
                else
                  state_d = ST_STC;
              end
            end
          end else begin
            // Single i32 store (odd j or last column of odd-width row)
            c_r_req  = 1'b1;
            c_r_bank = c_bank(j_q);
            c_r_addr = c_bank_addr(i_q, j_q);
            axi_req_o.aw.addr = c_store_addr;
            axi_req_o.aw.size = axi_pkg::size_t'(2);  // 4B
            if (DataWidth >= 64 && c_store_addr[2]) begin
              axi_req_o.w.data = DataWidth'({c_r_data, 32'h0});
              axi_req_o.w.strb = {{(DataWidth/8-8){1'b0}}, 8'hF0};
            end else begin
              axi_req_o.w.data = DataWidth'(c_r_data);
              axi_req_o.w.strb = {{(DataWidth/8-4){1'b0}}, 4'hF};
            end
            stc_n_d = 8'd1;
            if (!aw_sent_q) begin
              axi_req_o.aw_valid = 1'b1;
              if (axi_resp_i.aw_ready) begin
                aw_sent_d  = 1'b1;
                stc_elem_d = 8'd1;
              end
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
              stc_elem_d    = 8'd0;
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
      burst_first_q <= 1'b0;
      beat_q <= '0;
      beat_lane_q <= '0;
      beat_left_q <= '0;
      c_pair_hold_q <= 1'b0;
      c_lo_q <= '0;
      stc_w_left_q <= '0;
      stc_elem_q <= '0;
      pmu_r_q  <= '0;
      pmu_w_q  <= '0;
      pmu_cy_q <= '0;
    end else begin
      state_q       <= state_d;
      acc_q         <= acc_d;
      err_q         <= err_d;
      ar_sent_q     <= ar_sent_d;
      aw_sent_q     <= aw_sent_d;
      w_sent_q      <= w_sent_d;
      burst_first_q <= burst_first_d;
      beat_left_q   <= beat_left_d;
      beat_lane_q   <= beat_lane_d;
      c_pair_hold_q <= c_pair_hold_d;
      stc_w_left_q  <= stc_w_left_d;
      stc_elem_q    <= stc_elem_d;
      if (beat_load_d) beat_q <= beat_data_d;
      if (c_lo_we_d)   c_lo_q <= c_r_data;
      done_q        <= (state_q == ST_DONE);

      // I3: accumulate traffic while job is running
      // W counts data beats (w handshake), not B responses — multi-beat AW safe
      if (state_q != ST_IDLE && state_q != ST_DONE)
        pmu_cy_q <= pmu_cy_q + 32'd1;
      if (state_q != ST_IDLE && state_q != ST_DONE &&
          axi_req_o.r_ready && axi_resp_i.r_valid)
        pmu_r_q <= pmu_r_q + 32'd1;
      if (state_q != ST_IDLE && state_q != ST_DONE &&
          axi_req_o.w_valid && axi_resp_i.w_ready)
        pmu_w_q <= pmu_w_q + 32'd1;

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
        burst_first_q <= 1'b0;
        c_pair_hold_q <= 1'b0;
        stc_w_left_q  <= '0;
        stc_elem_q    <= '0;
        pmu_r_q  <= '0;
        pmu_w_q  <= '0;
        pmu_cy_q <= '0;
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

      // B load: 1 or 2 elements/cycle (AR/R or dual beat drain)
      if (state_q == ST_LB &&
          ((beat_left_q != 8'd0) || (ar_sent_q && axi_resp_i.r_valid))) begin
        if (ar_sent_q && axi_resp_i.r_valid &&
            (axi_resp_i.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR}))
          err_q <= 1'b1;
        if (j_q + 32'(lb_n_d) >= n_q) begin
          j_q <= '0;
          beat_left_q   <= '0;  // new row needs fresh AR
          ar_sent_q     <= 1'b0;
          burst_first_q <= 1'b0;
          if (t_q + 1 != k_q)
            t_q <= t_q + 1;
          else begin
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
          end
        end else
          j_q <= j_q + 32'(lb_n_d);
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

      // C store: advance by stc_n_d (1 or 2*nbeats) on B complete
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
