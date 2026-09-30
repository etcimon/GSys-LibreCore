// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai V3/V4: N GEMM engines behind one job interface and one AXI master.
//
// One island job C[m][n] = A[m][k] . B[n][k]^T is split along N: cluster c takes
// the column slice [c*ns, min((c+1)*ns, n)) with ns = ceil(n / Clusters) rounded
// up to a multiple of SliceAlign columns, reads the same A rows, its own B rows
// (ptr_b + c*ns*ldb_bytes) and writes its own columns of the same C panel
// (ptr_c + c*ns*4, row pitch ldc = n). Every engine keeps the single-engine
// contract (g6lc_ai_gemm_seq with ldc_i); nothing about the descriptor changes.
// Slices that come out empty (n < Clusters*SliceAlign) idle and complete at once.
//
// The N masters join through axi_mux with Clusters-prefixed IDs so responses
// route back by construction (no ID aliasing between engines). done_o is the
// AND of the engines (one pulse when the last finishes), err_o the OR, PMU
// cycles the slowest engine, beats the sum. The residency inputs fan out: each
// engine keys its own slice (a resident panel is resident per cluster).
//
// Scaling honesty: Clusters engines multiply MAC/cycle by Clusters; the shared
// port does not widen. A V3/V4 point is MAC-bound only where the port already
// feeds one engine (prefill); decode stays bytes-bound (scaling-100tops.md s5).
module g6lc_ai_cluster_dispatch
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned Clusters   = 2,
    parameter int unsigned AddrWidth  = 64,
    parameter int unsigned DataWidth  = 64,
    parameter int unsigned IdWidth    = 4,   // island-side ID width (mux output)
    parameter int unsigned MaxDim     = 8,
    parameter int unsigned MaxM       = 0,
    parameter int unsigned MaxN       = 0,   // per-cluster N box
    parameter int unsigned MaxK       = 0,
    parameter int unsigned PeLanes    = 4,
    parameter int unsigned OutCols    = 1,
    parameter bit          DotPipeFloat = 1'b0,
    parameter int unsigned MaxAROut   = 2,
    parameter int unsigned NrChannels = 1,
    parameter int unsigned ChanShift  = 6,
    parameter bit          ReuseBEn   = 1'b0,
    parameter int unsigned ReuseBSlots = 2,
    parameter bit          ReuseAEn   = 1'b0,
    parameter int unsigned MaxElementBytes = 4,
    // Column slices start on a multiple of this (keeps every slice's C rows
    // beat-aligned for the wide store when n is).
    parameter int unsigned SliceAlign = 16,
    parameter type         axi_req_t  = logic,   // IdWidth
    parameter type         axi_resp_t = logic,
    parameter type         eng_req_t  = logic,   // IdWidth - clog2(Clusters)
    parameter type         eng_resp_t = logic
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
    input  logic [2:0]  numfmt_i,
    input  logic        accumulate_i,
    input  logic [3:0]  ar_max_i,
    input  logic [AddrWidth-1:0] ptr_a_i,
    input  logic [AddrWidth-1:0] ptr_b_i,
    input  logic [AddrWidth-1:0] ptr_c_i,
    output logic        ready_o,
    output logic        done_o,
    output logic        err_o,
    output logic [31:0] pmu_r_beats_o,
    output logic [31:0] pmu_w_beats_o,
    output logic [31:0] pmu_cycles_o,
    output logic [3:0][31:0] pmu_phase_o,
    output logic [2:0][31:0] pmu_stall_o,
    input  logic        reuse_b_i,
    input  logic [31:0] reuse_b_epoch_i,
    input  logic        reuse_b_invalidate_i,
    output logic        pmu_reuse_b_hit_o,
    input  logic        reuse_a_i,
    input  logic [31:0] reuse_a_epoch_i,
    input  logic        reuse_a_invalidate_i,
    output logic        pmu_reuse_a_hit_o,
    output axi_req_t    axi_req_o,
    input  axi_resp_t   axi_resp_i
);
  localparam int unsigned ClW = (Clusters > 1) ? $clog2(Clusters) : 1;
  localparam int unsigned EngIdW = IdWidth - ((Clusters > 1) ? $clog2(Clusters) : 0);

  // pragma translate_off
  initial begin
    assert (Clusters >= 1 && (Clusters & (Clusters - 1)) == 0)
      else $error("g6lc_ai_cluster_dispatch: Clusters=%0d must be a power of two", Clusters);
    assert (Clusters == 1 || IdWidth > $clog2(Clusters))
      else $error("g6lc_ai_cluster_dispatch: IdWidth=%0d too narrow for %0d clusters", IdWidth, Clusters);
    assert ((SliceAlign & (SliceAlign - 1)) == 0)
      else $error("g6lc_ai_cluster_dispatch: SliceAlign must be a power of two");
  end
  // pragma translate_on

  // ---- slice arithmetic (registered at start; the engines start one cycle later) ----
  logic        start_q;
  logic [31:0] m_q, n_q, k_q, slice_q;
  logic [15:0] lda_q, ldb_q;
  logic [2:0]  fmt_q;
  logic        acc_q;
  logic [3:0]  armax_q;
  logic [AddrWidth-1:0] pa_q, pb_q, pc_q;
  logic [31:0] row_bytes_b;

  function automatic logic [31:0] slice_cols(input logic [31:0] n);
    logic [31:0] s;
    s = (n + 32'(Clusters) - 32'd1) / 32'(Clusters);
    s = (s + 32'(SliceAlign) - 32'd1) & ~(32'(SliceAlign) - 32'd1);
    return s;
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_q <= 1'b0;
      m_q <= '0; n_q <= '0; k_q <= '0; slice_q <= '0;
      lda_q <= '0; ldb_q <= '0; fmt_q <= '0; acc_q <= 1'b0; armax_q <= '0;
      pa_q <= '0; pb_q <= '0; pc_q <= '0;
    end else begin
      start_q <= start_i && ready_o;
      if (start_i && ready_o) begin
        m_q <= m_i; n_q <= n_i; k_q <= k_i; slice_q <= slice_cols(n_i);
        lda_q <= lda_i; ldb_q <= ldb_i; fmt_q <= numfmt_i; acc_q <= accumulate_i;
        armax_q <= ar_max_i;
        pa_q <= ptr_a_i; pb_q <= ptr_b_i; pc_q <= ptr_c_i;
      end
    end
  end
  assign row_bytes_b = ai_row_bytes(fmt_q, {16'd0, ldb_q});

  // ---- engines --------------------------------------------------------------------------
  logic        e_start  [Clusters];
  logic [31:0] e_n      [Clusters];
  logic        e_active [Clusters];   // slice is non-empty
  logic        e_ready  [Clusters];
  logic        e_done   [Clusters];
  logic        e_err    [Clusters];
  logic [31:0] e_pmu_r  [Clusters];
  logic [31:0] e_pmu_w  [Clusters];
  logic [31:0] e_pmu_cy [Clusters];
  logic [3:0][31:0] e_phase [Clusters];
  logic [2:0][31:0] e_stall [Clusters];
  logic        e_hit_b  [Clusters];
  logic        e_hit_a  [Clusters];
  logic [AddrWidth-1:0] e_pb [Clusters];
  logic [AddrWidth-1:0] e_pc [Clusters];
  eng_req_t  [Clusters-1:0] e_req;
  eng_resp_t [Clusters-1:0] e_resp;

  // A job is "in flight" from start until every engine has reported done. Idle
  // slices complete on the start cycle.
  logic        busy_q;
  logic [Clusters-1:0] pend_q;     // engines still owed a done
  logic [Clusters-1:0] done_vec;
  logic [Clusters-1:0] active_vec;
  logic                any_err_q;

  for (genvar c = 0; c < int'(Clusters); c++) begin : gen_eng
    always_comb begin
      automatic logic [31:0] col0;
      col0 = 32'(c) * slice_q;
      e_active[c] = col0 < n_q;
      e_n[c] = (n_q - col0 > slice_q) ? slice_q : (n_q - col0);
      e_pb[c] = pb_q + AddrWidth'(col0 * row_bytes_b);
      e_pc[c] = pc_q + AddrWidth'(col0 << 2);
      e_start[c] = start_q && e_active[c];
    end
    assign active_vec[c] = e_active[c];
    assign done_vec[c] = e_done[c];

    g6lc_ai_gemm_seq #(
        .AddrWidth (AddrWidth),
        .DataWidth (DataWidth),
        .IdWidth   (EngIdW),
        .MaxDim    (MaxDim),
        .MaxM      (MaxM),
        .MaxN      (MaxN),
        .MaxK      (MaxK),
        .PeLanes   (PeLanes),
        .OutCols   (OutCols),
        .DotPipeFloat(DotPipeFloat),
        .MaxAROut  (MaxAROut),
        .NrChannels(NrChannels),
        .ChanShift (ChanShift),
        .ReuseBEn  (ReuseBEn),
        .ReuseBSlots(ReuseBSlots),
        .ReuseAEn  (ReuseAEn),
        .MaxElementBytes(MaxElementBytes),
        .axi_req_t (eng_req_t),
        .axi_resp_t(eng_resp_t)
    ) i_eng (
        .clk_i, .rst_ni, .testmode_i,
        .start_i  (e_start[c]),
        .m_i      (m_q),
        .n_i      (e_n[c]),
        .k_i      (k_q),
        .lda_i    (lda_q),
        .ldb_i    (ldb_q),
        .ldc_i    (n_q[15:0]),
        .numfmt_i (fmt_q),
        .accumulate_i(acc_q),
        .ar_max_i (armax_q),
        .ptr_a_i  (pa_q),
        .ptr_b_i  (e_pb[c]),
        .ptr_c_i  (e_pc[c]),
        .ready_o  (e_ready[c]),
        .done_o   (e_done[c]),
        .err_o    (e_err[c]),
        .pmu_r_beats_o(e_pmu_r[c]),
        .pmu_w_beats_o(e_pmu_w[c]),
        .pmu_cycles_o (e_pmu_cy[c]),
        .pmu_phase_o  (e_phase[c]),
        .pmu_stall_o  (e_stall[c]),
        .reuse_b_i(reuse_b_i),
        .reuse_b_epoch_i(reuse_b_epoch_i),
        .reuse_b_invalidate_i(reuse_b_invalidate_i),
        .pmu_reuse_b_hit_o(e_hit_b[c]),
        .reuse_a_i(reuse_a_i),
        .reuse_a_epoch_i(reuse_a_epoch_i),
        .reuse_a_invalidate_i(reuse_a_invalidate_i),
        .pmu_reuse_a_hit_o(e_hit_a[c]),
        .axi_req_o  (e_req[c]),
        .axi_resp_i (e_resp[c])
    );
  end

  // ---- job bookkeeping ---------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q <= 1'b0;
      pend_q <= '0;
      any_err_q <= 1'b0;
    end else begin
      if (start_i && ready_o) begin
        busy_q <= 1'b1;
        any_err_q <= 1'b0;
      end
      if (start_q) begin
        // engines with an empty slice owe nothing
        pend_q <= active_vec;
        if (active_vec == '0) busy_q <= 1'b0;
      end else if (busy_q) begin
        pend_q <= pend_q & ~done_vec;
        if ((pend_q & ~done_vec) == '0) busy_q <= 1'b0;
      end
      for (int unsigned c = 0; c < Clusters; c++)
        if (e_done[c] && e_err[c]) any_err_q <= 1'b1;
    end
  end
  assign ready_o = !busy_q && !start_q;
  // one-cycle done when the last pending engine finishes (or an all-idle start)
  assign done_o = (start_q && active_vec == '0) ||
                  (busy_q && !start_q && pend_q != '0 && (pend_q & ~done_vec) == '0);
  logic err_now;
  always_comb begin
    err_now = any_err_q;
    for (int unsigned c = 0; c < Clusters; c++) if (e_done[c] && e_err[c]) err_now = 1'b1;
  end
  assign err_o = done_o && err_now;

  // PMU: slowest engine's cycles/phases, summed beats and stalls.
  always_comb begin
    pmu_r_beats_o = '0; pmu_w_beats_o = '0; pmu_cycles_o = '0;
    pmu_phase_o = '0; pmu_stall_o = '0;
    pmu_reuse_b_hit_o = 1'b1; pmu_reuse_a_hit_o = 1'b1;
    for (int unsigned c = 0; c < Clusters; c++) begin
      pmu_r_beats_o += e_pmu_r[c];
      pmu_w_beats_o += e_pmu_w[c];
      if (e_pmu_cy[c] > pmu_cycles_o) begin
        pmu_cycles_o = e_pmu_cy[c];
        pmu_phase_o  = e_phase[c];
      end
      for (int unsigned s = 0; s < 3; s++) pmu_stall_o[s] += e_stall[c][s];
      // a job "hit" residency only if every active slice hit
      if (e_active[c] && !e_hit_b[c]) pmu_reuse_b_hit_o = 1'b0;
      if (e_active[c] && !e_hit_a[c]) pmu_reuse_a_hit_o = 1'b0;
    end
  end

  // ---- AXI: Clusters masters -> one, IDs prefixed by the cluster index --------------------
  if (Clusters == 1) begin : gen_single
    assign axi_req_o = e_req[0];
    assign e_resp[0] = axi_resp_i;
  end else begin : gen_mux
    // Channel types taken from the request/response structs themselves.
    typedef type(e_req[0].aw)     eng_aw_chan_t;
    typedef type(e_req[0].w)      w_chan_t;
    typedef type(e_resp[0].b)     eng_b_chan_t;
    typedef type(e_req[0].ar)     eng_ar_chan_t;
    typedef type(e_resp[0].r)     eng_r_chan_t;
    typedef type(axi_req_o.aw)    mst_aw_chan_t;
    typedef type(axi_resp_i.b)    mst_b_chan_t;
    typedef type(axi_req_o.ar)    mst_ar_chan_t;
    typedef type(axi_resp_i.r)    mst_r_chan_t;
    axi_mux #(
        .SlvAxiIDWidth (EngIdW),
        .slv_aw_chan_t (eng_aw_chan_t),
        .mst_aw_chan_t (mst_aw_chan_t),
        .w_chan_t      (w_chan_t),
        .slv_b_chan_t  (eng_b_chan_t),
        .mst_b_chan_t  (mst_b_chan_t),
        .slv_ar_chan_t (eng_ar_chan_t),
        .mst_ar_chan_t (mst_ar_chan_t),
        .slv_r_chan_t  (eng_r_chan_t),
        .mst_r_chan_t  (mst_r_chan_t),
        .slv_req_t     (eng_req_t),
        .slv_resp_t    (eng_resp_t),
        .mst_req_t     (axi_req_t),
        .mst_resp_t    (axi_resp_t),
        .NoSlvPorts    (Clusters),
        .MaxWTrans     (4),
        .FallThrough   (1'b0),
        .SpillAw       (1'b1), .SpillW (1'b0), .SpillB (1'b0),
        .SpillAr       (1'b1), .SpillR (1'b0)
    ) i_mux (
        .clk_i, .rst_ni,
        .test_i     (testmode_i),
        .slv_reqs_i (e_req),
        .slv_resps_o(e_resp),
        .mst_req_o  (axi_req_o),
        .mst_resp_i (axi_resp_i)
    );
  end
endmodule
