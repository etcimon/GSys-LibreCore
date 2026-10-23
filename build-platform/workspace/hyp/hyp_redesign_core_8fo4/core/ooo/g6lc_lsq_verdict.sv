// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq_verdict — hyp8 LSQ verdict stage (V).
//
// Registers the reduce-stage results into the LSQ's hazard outputs,
// exactly three cycles after the address event was staged (E -> C -> R
// -> V):
//
//   * Load direction (one verdict per staged load address/query event):
//     outcome {forward, wait, clear}.  `stl_stall_o`/`stl_forward_o`/
//     `stl_data_o` are kept as REGISTERED observability outputs of the
//     latest load verdict — the functional publish path is
//     `ld_checked_o` in the wrapper plus the store-buffer forward pair
//     (L2), not a same-cycle stall.
//   * Store direction (one candidate set per staged store address
//     event): `mem_violation_o/id_o/pc_o` — the oldest violating load
//     across all events' tournaments, registered (+3 vs the emit's
//     same-cycle report; the checked bit bounds the window — a load
//     cannot publish before its verdict is final).  `replay_valid_o`/
//     `replay_tid_o` pulse on a reported violation AND on a `wait` load
//     verdict (hyp8 H3: a waiting load's dependents may already have been
//     woken by the IQ countdown and must be re-armed once; publication
//     still holds via ld_checked until the verdict is non-wait).
//
// `final_o[tid]` records "a verdict has been produced for the load with
// this transaction id".  The wrapper combines it with the release
// module's drain masks to form `ld_checked_o`.  The bit clears when a
// new load allocates the same scoreboard slot (tid reuse), when the
// mask cancels the tid, and on flush.
//
// Kill identities: stage registers carry ids; cancelled records never
// produce a verdict (already dead upstream) and final_o clears on a
// killed alloc'd slot; flush clears everything speculative (H7 — LSU
// tombstones and committed state are not owned here).

module g6lc_lsq_verdict #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned NLD = 3,   // staged load events (update + query)
    parameter int unsigned NSV = 2,   // staged store events
    parameter int unsigned NR_ALLOC = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,

    // Load-event context (registered beside the reduce stage).
    input  logic [NLD-1:0]                              ld_ev_valid_i,
    input  logic [NLD-1:0][G6LCCfg.TRANS_ID_BITS-1:0]   ld_ev_id_i,
    // Load-direction reduce results.
    input  logic [NLD-1:0]                              ld_win_valid_i,
    input  logic [NLD-1:0][G6LCCfg.XLEN-1:0]            ld_win_pay_i,
    input  logic [NLD-1:0]                              ld_wait_i,
    input  logic [NLD-1:0][G6LCCfg.NR_SB_ENTRIES-1:0]   ld_dwait_i,

    // Store-event context + violation reduce results.
    input  logic [NSV-1:0]                              st_ev_valid_i,
    input  logic [NSV-1:0]                              st_win_valid_i,
    input  logic [NSV-1:0][G6LCCfg.TRANS_ID_BITS-1:0]   st_win_id_i,
    input  logic [NSV-1:0][G6LCCfg.TRANS_ID_BITS-1:0]   st_win_dist_i,
    input  logic [NSV-1:0][G6LCCfg.VLEN-1:0]            st_win_pay_i,

    // Tid-reuse clear for the final bits (load allocation).
    input  logic [NR_ALLOC-1:0]                         ld_alloc_i,
    input  logic [NR_ALLOC-1:0][G6LCCfg.TRANS_ID_BITS-1:0] alloc_id_i,

    // Registered load verdicts (one per event, for release + publish).
    output logic [NLD-1:0]                              ld_verdict_valid_o,
    output logic [NLD-1:0][G6LCCfg.TRANS_ID_BITS-1:0]   ld_verdict_id_o,
    output logic [NLD-1:0]                              ld_verdict_wait_o,
    output logic [NLD-1:0][G6LCCfg.XLEN-1:0]            ld_verdict_data_o,
    output logic [NLD-1:0][G6LCCfg.NR_SB_ENTRIES-1:0]   ld_verdict_dwait_o,

    // Observability STL outputs (latest load verdict, registered).
    output logic                                        stl_stall_o,
    output logic                                        stl_forward_o,
    output logic [G6LCCfg.XLEN-1:0]                     stl_data_o,

    // Violation report (registered, +3 vs the emit base).
    output logic                                        mem_violation_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]            mem_violation_id_o,
    output logic [G6LCCfg.VLEN-1:0]                     mem_violation_pc_o,

    // IQ re-arm / replay — violation or wait verdict (see header).
    output logic                                        replay_valid_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]            replay_tid_o,

    // "Verdict final" bit per transaction id — combined in the wrapper
    // with the release masks into ld_checked_o.
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]            final_o
);
  // svt-stage: begin V window=3

  logic [G6LCCfg.NR_SB_ENTRIES-1:0] final_q;
  assign final_o = final_q;

  // Oldest violating load across all staged store events.
  logic                          viol_d;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] viol_id_d, viol_dist_d;
  logic [G6LCCfg.VLEN-1:0]             viol_pay_d;

  // hyp8: serial best-so-far loop -> per-source compare vector + balanced
  // min-distance tree + one-hot masked-OR gathers (log depth).
  localparam int unsigned VLV = (NSV > 1) ? $clog2(NSV) : 1;
  logic [NSV-1:0]                            vcand;
  logic [NSV-1:0][G6LCCfg.TRANS_ID_BITS-1:0] vmt [VLV+1];
  logic [NSV-1:0]                            v_oh;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]          v_min;
  for (genvar s = 0; s < NSV; s++) begin : gen_vcand
    assign vcand[s]  = st_ev_valid_i[s] && st_win_valid_i[s] &&
                       !cancelled_mask_i[st_win_id_i[s]];
    assign vmt[0][s] = vcand[s] ? st_win_dist_i[s] : '1;
  end
  for (genvar l = 0; l < VLV; l++) begin : gen_vlvl
    localparam int unsigned NW = (NSV + (1 << l) - 1) >> l;
    localparam int unsigned NX = (NSV + (1 << (l + 1)) - 1) >> (l + 1);
    for (genvar t = 0; t < NSV; t++) begin : gen_vt
      if (t < NX) begin : gen_in
        if (2 * t + 1 < NW) begin : gen_pair
          assign vmt[l+1][t] = (vmt[l][2*t] < vmt[l][2*t+1])
                               ? vmt[l][2*t] : vmt[l][2*t+1];
        end else begin : gen_odd
          assign vmt[l+1][t] = vmt[l][2*t];
        end
      end else begin : gen_pad
        assign vmt[l+1][t] = '1;
      end
    end
  end
  assign v_min = vmt[VLV][0];
  for (genvar s = 0; s < NSV; s++)
    assign v_oh[s] = vcand[s] && (st_win_dist_i[s] == v_min);
  // Per-bit column of the one-hot masked OR. A function that walked
  // every source billed that walk in series with the distance tree.
  assign viol_d = |v_oh;
  for (genvar b = 0; b < G6LCCfg.TRANS_ID_BITS; b++) begin : gen_vid
    logic [NSV-1:0] id_col, dist_col;
    for (genvar s = 0; s < NSV; s++) begin : gen_col
      assign id_col[s]   = st_win_id_i[s][b];
      assign dist_col[s] = st_win_dist_i[s][b];
    end
    assign viol_id_d[b]   = |(v_oh & id_col);
    assign viol_dist_d[b] = |(v_oh & dist_col);
  end
  for (genvar b = 0; b < G6LCCfg.VLEN; b++) begin : gen_vpay
    logic [NSV-1:0] pay_col;
    for (genvar s = 0; s < NSV; s++) begin : gen_col
      assign pay_col[s] = st_win_pay_i[s][b];
    end
    assign viol_pay_d[b] = |(v_oh & pay_col);
  end

  // hyp8 H3: a `wait` load verdict (an older store unresolved or a matched
  // store without data) means the load's dependents may already have been
  // released by the speculative-wakeup countdown — pulse replay once so the
  // IQ re-arms them. One tid per pulse (lowest staged event); the dispatch
  // merge queues coincident losers, and the bank-wide re-arm fallback makes
  // a single tid sufficient regardless.
  logic                          wait_d;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] wait_id_d;
  // Lowest staged wait wins, which is what the descending overwrite kept.
  logic [NLD-1:0] wait_ok, wait_oh;
  for (genvar l = 0; l < NLD; l++) begin : gen_wait_ok
    assign wait_ok[l] = ld_ev_valid_i[l] && ld_wait_i[l] &&
                        !cancelled_mask_i[ld_ev_id_i[l]];
  end
  assign wait_oh = wait_ok & (~wait_ok + {{NLD-1{1'b0}}, 1'b1});
  assign wait_d  = |wait_oh;
  for (genvar b = 0; b < G6LCCfg.TRANS_ID_BITS; b++) begin : gen_wait_id
    logic [NLD-1:0] id_col;
    for (genvar l = 0; l < NLD; l++) begin : gen_col
      assign id_col[l] = ld_ev_id_i[l][b];
    end
    assign wait_id_d[b] = |(wait_oh & id_col);
  end
  // Lowest live load event, for the registered STL mirror. No match
  // leaves stall and forward clear; data holds in the flop.
  logic [NLD-1:0] stl_ok, stl_oh;
  logic           stl_any;
  logic           stl_stall_d, stl_forward_d;
  logic [G6LCCfg.XLEN-1:0] stl_data_d;
  for (genvar l = 0; l < NLD; l++) begin : gen_stl_ok
    assign stl_ok[l] = ld_ev_valid_i[l] && !cancelled_mask_i[ld_ev_id_i[l]];
  end
  assign stl_oh = stl_ok & (~stl_ok + {{NLD-1{1'b0}}, 1'b1});
  assign stl_any = |stl_oh;
  assign stl_stall_d   = |(stl_oh & ld_wait_i);
  assign stl_forward_d = |(stl_oh & ~ld_wait_i & ld_win_valid_i);
  for (genvar b = 0; b < G6LCCfg.XLEN; b++) begin : gen_stl_data
    logic [NLD-1:0] pay_col;
    for (genvar l = 0; l < NLD; l++) begin : gen_col
      assign pay_col[l] = ld_win_pay_i[l][b];
    end
    assign stl_data_d[b] = |(stl_oh & pay_col);
  end

  // final_q bookkeeping: set when a load verdict lands, cleared when the
  // tid is re-allocated to a new load, killed, or the pipe flushes.
  // Set on the registered V-stage verdict, not the input event: the
  // release module's dwait bookkeeping lands on this same edge
  // (vld -> dwait_q), so final becoming visible one edge earlier lets
  // ld_checked_o publish while the store data the load must still wait
  // on is in flight (dwait_q reads '0 for one cycle).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      final_q <= '0;
    end else if (flush_i) begin
      final_q <= '0;
    end else begin
      for (int unsigned t = 0; t < G6LCCfg.NR_SB_ENTRIES; t++)
        if (cancelled_mask_i[t]) final_q[t] <= 1'b0;
      for (int unsigned p = 0; p < NR_ALLOC; p++)
        if (ld_alloc_i[p]) final_q[alloc_id_i[p]] <= 1'b0;
      for (int unsigned l = 0; l < NLD; l++)
        if (ld_verdict_valid_o[l] &&
            !cancelled_mask_i[ld_verdict_id_o[l]])
          final_q[ld_verdict_id_o[l]] <= 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ld_verdict_valid_o <= '0;
      ld_verdict_id_o    <= '0;
      ld_verdict_wait_o  <= '0;
      ld_verdict_data_o  <= '0;
      ld_verdict_dwait_o <= '0;
      stl_stall_o        <= 1'b0;
      stl_forward_o      <= 1'b0;
      stl_data_o         <= '0;
      mem_violation_o    <= 1'b0;
      mem_violation_id_o <= '0;
      mem_violation_pc_o <= '0;
      replay_valid_o     <= 1'b0;
      replay_tid_o       <= '0;
    end else if (flush_i) begin
      ld_verdict_valid_o <= '0;
      ld_verdict_wait_o  <= '0;
      stl_stall_o        <= 1'b0;
      stl_forward_o      <= 1'b0;
      mem_violation_o    <= 1'b0;
      replay_valid_o     <= 1'b0;
    end else begin
      // Per-event load verdicts.
      ld_verdict_valid_o <= '0;
      ld_verdict_wait_o  <= '0;
      for (int unsigned l = 0; l < NLD; l++) begin
        ld_verdict_valid_o[l] <= ld_ev_valid_i[l] &&
                                 !cancelled_mask_i[ld_ev_id_i[l]];
        ld_verdict_id_o[l]    <= ld_ev_id_i[l];
        ld_verdict_wait_o[l]  <= ld_wait_i[l];
        ld_verdict_data_o[l]  <= ld_win_pay_i[l];
        ld_verdict_dwait_o[l] <= ld_dwait_i[l];
      end
      // Observability STL outputs mirror the latest live load verdict
      // (functional publication is via ld_checked_o + the store-buffer
      // forward pair — L2).  A `wait` verdict appears on stl_stall_o.
      stl_stall_o   <= stl_stall_d;
      stl_forward_o <= stl_forward_d;
      if (stl_any) stl_data_o <= stl_data_d;
      // Violation: registered report + the IQ/scoreboard re-arm pulse; a
      // wait verdict pulses the same re-arm (violation wins the tid slot —
      // the dispatch merge's pending set carries a coincident loser).
      mem_violation_o    <= viol_d;
      mem_violation_id_o <= viol_d ? viol_id_d : '0;
      mem_violation_pc_o <= viol_d ? viol_pay_d : '0;
      replay_valid_o     <= viol_d | wait_d;
      replay_tid_o       <= viol_d ? viol_id_d : wait_id_d;
    end
  end

  // svt-stage: end V
  // svt-stage: class V value
endmodule
