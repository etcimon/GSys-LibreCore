// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq_event — hyp8 LSQ staged event records.
//
// hyp8: the live AGU / store-data / complete / commit / physical update
// paths of the emit base are removed; every update is captured into one
// registered event record per input port.  The event register IS the
// retimed AGU output register (cut_minimization rank-2 move): downstream
// consumers see the update one cycle after the port asserted, and the
// entry next-state cone is no longer reachable from a live input.
//
// Record kinds (per update port u): `addr` (load or store address, the
//   retimed AGU result), `data` (store data).  Side ports produce their
//   own records: `complete` (one per WB port), `commit` (one per commit
//   port, ld and st released by id as today), `phys` (two, the
//   PHYS_VALIDATE physical-validate updates), `mod` (two, the coherence
//   modification notifications), and `query` (one, the explicit
//   ld_query_* port, kept for emit-port parity — see g6lc_lsq.sv).
//
// Records are depth-1 pipelines, never queues: each port asserts at most
// once per cycle, the record applies to the entry arrays the following
// cycle, then clears.  No back-pressure exists on this path.
//
// Kill identities (contract §3): every speculative record carries its
// transaction id; a record whose id is already dead at capture time is
// never staged, and consumers re-check `cancelled_mask_i[id]` at apply
// time (the staged cycle) so a record killed in flight is suppressed in
// place.  `flush_i` clears every record.  Commit records carry no
// speculative id of their own — commit is an architectural event — and
// are only cleared by flush (the speculative pipe state), never by the
// cancel mask.
//
// `ev_count_o` conservatively reports every staged record so the wrapper
// can fold in-flight updates into the occupancy outputs — a record that
// will free an entry (commit) is still counted busy until it applies.

module g6lc_lsq_event #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned NR_UPDATE = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,

    // Live AGU address updates (issue cycle) — captured, never forwarded.
    input  logic [NR_UPDATE-1:0]                                  addr_valid_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.TRANS_ID_BITS-1:0]       addr_id_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.PLEN-1:0]                addr_i,
    input  logic [NR_UPDATE-1:0]                                  addr_is_st_i,
    input  logic [NR_UPDATE-1:0][1:0]                             addr_size_i,
    input  logic [NR_UPDATE-1:0]                                  st_data_valid_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.TRANS_ID_BITS-1:0]       st_data_id_i,
    input  logic [NR_UPDATE-1:0][G6LCCfg.XLEN-1:0]                st_data_i,

    // Multi-WB complete.
    input  logic [G6LCCfg.NrWbPorts-1:0]                          complete_valid_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] complete_id_i,
    input  logic [G6LCCfg.NrWbPorts-1:0]                          complete_is_st_i,

    // Store commit / physical-validate load release, by id per commit port.
    input  logic [G6LCCfg.NrCommitPorts-1:0]                      commit_st_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0]                      commit_ld_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_id_i,

    // Explicit STL query port (emit-port parity; deduplicated in the
    // wrapper against a same-cycle load address event for the same id).
    input  logic                                                  ld_query_i,
    input  logic [G6LCCfg.PLEN-1:0]                               ld_query_addr_i,
    input  logic [1:0]                                            ld_query_size_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]                      ld_query_id_i,
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ld_query_hart_i,

    // PHYS_VALIDATE inputs (kept syntactically; folded off in the WT
    // config exactly as the emit base folded them).
    input  logic [1:0]                                            phys_valid_i,
    input  logic [1:0][G6LCCfg.PLEN-1:0]                          phys_addr_i,
    input  logic [1:0][G6LCCfg.TRANS_ID_BITS-1:0]                 phys_id_i,
    input  logic [1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] phys_hart_i,
    input  logic [1:0][1:0]                                       phys_size_i,
    input  logic [1:0]                                            mod_valid_i,
    input  logic [1:0][G6LCCfg.PLEN-1:0]                          mod_addr_i,

    // Staged records — all registered, all killable.
    output logic [NR_UPDATE-1:0]                                  ev_addr_valid_o,
    output logic [NR_UPDATE-1:0]                                  ev_addr_is_st_o,
    output logic [NR_UPDATE-1:0][G6LCCfg.TRANS_ID_BITS-1:0]       ev_addr_id_o,
    output logic [NR_UPDATE-1:0][G6LCCfg.PLEN-1:0]                ev_addr_o,
    output logic [NR_UPDATE-1:0][1:0]                             ev_addr_size_o,
    // hyp8 T1 item 2: the address event's byte-lane footprint staged
    // beside the address (the CAM stage shifts nothing).
    output logic [NR_UPDATE-1:0][(G6LCCfg.XLEN+7)/8-1:0]            ev_addr_be_o,
    output logic [NR_UPDATE-1:0]                                  ev_data_valid_o,
    output logic [NR_UPDATE-1:0][G6LCCfg.TRANS_ID_BITS-1:0]       ev_data_id_o,
    output logic [NR_UPDATE-1:0][G6LCCfg.XLEN-1:0]                ev_data_o,

    output logic [G6LCCfg.NrWbPorts-1:0]                          ev_complete_valid_o,
    output logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] ev_complete_id_o,
    output logic [G6LCCfg.NrWbPorts-1:0]                          ev_complete_is_st_o,

    output logic [G6LCCfg.NrCommitPorts-1:0]                      ev_commit_st_o,
    output logic [G6LCCfg.NrCommitPorts-1:0]                      ev_commit_ld_o,
    output logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] ev_commit_id_o,

    output logic                                                  ev_query_valid_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]                      ev_query_id_o,
    output logic [G6LCCfg.PLEN-1:0]                               ev_query_addr_o,
    output logic [1:0]                                            ev_query_size_o,
    // hyp8 T1 item 2: the query event's byte-lane footprint, staged.
    output logic [(G6LCCfg.XLEN+7)/8-1:0]                          ev_query_be_o,
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ev_query_hart_o,

    output logic [1:0]                                            ev_phys_valid_o,
    output logic [1:0][G6LCCfg.PLEN-1:0]                          ev_phys_addr_o,
    output logic [1:0][G6LCCfg.TRANS_ID_BITS-1:0]                 ev_phys_id_o,
    output logic [1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ev_phys_hart_o,
    output logic [1:0][1:0]                                       ev_phys_size_o,
    output logic [1:0]                                            ev_mod_valid_o,
    output logic [1:0][G6LCCfg.PLEN-1:0]                          ev_mod_addr_o,

    // Conservative in-flight count for the occupancy outputs.
    output logic [$clog2(2*NR_UPDATE+G6LCCfg.NrWbPorts+G6LCCfg.NrCommitPorts+7+1)-1:0] ev_count_o
);
  // svt-stage: begin E

  // hyp8: a live record is captured exactly when its port asserts and its
  // id is not already dead; the record lives exactly one cycle (it is
  // applied by the slot/CAM stage on the following cycle and clears), so
  // a kill that arrives *during* the staged cycle is seen by the
  // consumers, which re-check cancelled_mask_i[id] at apply time — the
  // in-place kill is therefore the consumer-side gate, while capture-time
  // gating keeps an already-dead id out of the pipe entirely.
  // hyp8 T1 item 2: byte-lane footprint of an access inside its aligned
  // XLEN word — the emit base's lane_be, verbatim.
  localparam int unsigned LANES = (G6LCCfg.XLEN + 7) / 8;
  function automatic logic [LANES-1:0] lane_be(
      input logic [G6LCCfg.PLEN-1:0] a,
      input logic [1:0]              size
  );
    automatic logic [LANES-1:0] m;
    m = '0;
    for (int unsigned b = 0; b < LANES; b++)
      if (b < (1 << size)) m[b] = 1'b1;
    if (G6LCCfg.XLEN == 64)
      lane_be = m << a[2:0];
    else
      lane_be = m << a[1:0];
  endfunction

  for (genvar u = 0; u < NR_UPDATE; u++) begin : gen_upd
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ev_addr_valid_o[u]  <= 1'b0;
        ev_addr_is_st_o[u]  <= 1'b0;
        ev_addr_id_o[u]     <= '0;
        ev_addr_o[u]        <= '0;
        ev_addr_size_o[u]   <= '0;
        ev_addr_be_o[u]     <= '0;
        ev_data_valid_o[u]  <= 1'b0;
        ev_data_id_o[u]     <= '0;
        ev_data_o[u]        <= '0;
      end else if (flush_i) begin
        ev_addr_valid_o[u]  <= 1'b0;
        ev_data_valid_o[u]  <= 1'b0;
      end else begin
        ev_addr_valid_o[u] <= addr_valid_i[u] && !cancelled_mask_i[addr_id_i[u]];
        if (addr_valid_i[u]) begin
          ev_addr_is_st_o[u] <= addr_is_st_i[u];
          ev_addr_id_o[u]    <= addr_id_i[u];
          ev_addr_o[u]       <= addr_i[u];
          ev_addr_size_o[u]  <= addr_size_i[u];
          ev_addr_be_o[u]    <= lane_be(addr_i[u], addr_size_i[u]);
        end
        ev_data_valid_o[u] <= st_data_valid_i[u] && !cancelled_mask_i[st_data_id_i[u]];
        if (st_data_valid_i[u]) begin
          ev_data_id_o[u] <= st_data_id_i[u];
          ev_data_o[u]    <= st_data_i[u];
        end
      end
    end
  end

  for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_cmp
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ev_complete_valid_o[w] <= 1'b0;
        ev_complete_id_o[w]    <= '0;
        ev_complete_is_st_o[w] <= 1'b0;
      end else if (flush_i) begin
        ev_complete_valid_o[w] <= 1'b0;
      end else begin
        ev_complete_valid_o[w] <= complete_valid_i[w] &&
                                  !cancelled_mask_i[complete_id_i[w]];
        if (complete_valid_i[w]) begin
          ev_complete_id_o[w]    <= complete_id_i[w];
          ev_complete_is_st_o[w] <= complete_is_st_i[w];
        end
      end
    end
  end

  // Commit records carry no speculative id of their own — commit_st_i /
  // commit_ld_i are architectural events, so the record is never killed by
  // the cancel mask (the mask bit for a committing tid is already clear);
  // flush still clears the record itself, matching the emit's flush of
  // speculative state (committed architectural state survives).
  for (genvar c = 0; c < G6LCCfg.NrCommitPorts; c++) begin : gen_com
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ev_commit_st_o[c] <= 1'b0;
        ev_commit_ld_o[c] <= 1'b0;
        ev_commit_id_o[c] <= '0;
      end else if (flush_i) begin
        ev_commit_st_o[c] <= 1'b0;
        ev_commit_ld_o[c] <= 1'b0;
      end else begin
        ev_commit_st_o[c] <= commit_st_i[c];
        ev_commit_ld_o[c] <= commit_ld_i[c];
        if (commit_st_i[c] || commit_ld_i[c])
          ev_commit_id_o[c] <= commit_id_i[c];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ev_query_valid_o <= 1'b0;
      ev_query_id_o    <= '0;
      ev_query_addr_o  <= '0;
      ev_query_size_o  <= '0;
      ev_query_be_o    <= '0;
      ev_query_hart_o  <= '0;
    end else if (flush_i) begin
      ev_query_valid_o <= 1'b0;
    end else begin
      ev_query_valid_o <= ld_query_i && !cancelled_mask_i[ld_query_id_i];
      if (ld_query_i) begin
        ev_query_id_o   <= ld_query_id_i;
        ev_query_addr_o <= ld_query_addr_i;
        ev_query_size_o <= ld_query_size_i;
        ev_query_be_o   <= lane_be(ld_query_addr_i, ld_query_size_i);
        ev_query_hart_o <= ld_query_hart_i;
      end
    end
  end

  for (genvar p = 0; p < 2; p++) begin : gen_phys
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ev_phys_valid_o[p] <= 1'b0;
        ev_phys_addr_o[p]  <= '0;
        ev_phys_id_o[p]    <= '0;
        ev_phys_hart_o[p]  <= '0;
        ev_phys_size_o[p]  <= '0;
        ev_mod_valid_o[p]  <= 1'b0;
        ev_mod_addr_o[p]   <= '0;
      end else if (flush_i) begin
        ev_phys_valid_o[p] <= 1'b0;
        ev_mod_valid_o[p]  <= 1'b0;
      end else begin
        ev_phys_valid_o[p] <= phys_valid_i[p] && !cancelled_mask_i[phys_id_i[p]];
        if (phys_valid_i[p]) begin
          ev_phys_addr_o[p] <= phys_addr_i[p];
          ev_phys_id_o[p]   <= phys_id_i[p];
          ev_phys_hart_o[p] <= phys_hart_i[p];
          ev_phys_size_o[p] <= phys_size_i[p];
        end
        ev_mod_valid_o[p] <= mod_valid_i[p];
        if (mod_valid_i[p]) ev_mod_addr_o[p] <= mod_addr_i[p];
      end
    end
  end

  // Conservative occupancy: every staged record keeps the queue busy.
  // hyp8 T1 item 12: the count is a balanced pairwise sum over a packed
  // source vector (SelectIncrement — same popcount, log depth instead
  // of the serial accumulator chain).
  localparam int unsigned NSRC =
      2*NR_UPDATE + G6LCCfg.NrWbPorts + G6LCCfg.NrCommitPorts + 3;
  localparam int unsigned CNTW = $bits(ev_count_o);
  logic [NSRC-1:0] ev_cnt_src;
  always_comb begin
    ev_cnt_src = '0;
    for (int unsigned u = 0; u < NR_UPDATE; u++) begin
      ev_cnt_src[u]                = ev_addr_valid_o[u];
      ev_cnt_src[NR_UPDATE+u]      = ev_data_valid_o[u];
    end
    for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
      ev_cnt_src[2*NR_UPDATE+w] = ev_complete_valid_o[w];
    for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
      ev_cnt_src[2*NR_UPDATE+G6LCCfg.NrWbPorts+c] =
          ev_commit_st_o[c] | ev_commit_ld_o[c];
    ev_cnt_src[NSRC-3] = ev_query_valid_o;
    ev_cnt_src[NSRC-2] = |ev_phys_valid_o;
    ev_cnt_src[NSRC-1] = |ev_mod_valid_o;
  end
  always_comb begin : p_ev_count
    logic [CNTW-1:0] acc [NSRC];
    int unsigned nn;
    for (int unsigned i = 0; i < NSRC; i++)
      acc[i] = CNTW'(ev_cnt_src[i]);
    nn = NSRC;
    while (nn > 1) begin
      for (int unsigned i = 0; i < nn/2; i++)
        acc[i] = acc[2*i] + acc[2*i+1];
      if (nn % 2 != 0) acc[nn/2] = acc[nn-1];
      nn = (nn + 1) / 2;
    end
`ifdef G6LC_MUT_T1_EVCOUNT
    // Review mutant: pre-T1 serial accumulator on the live path.
    ev_count_o = '0;
    for (int unsigned u = 0; u < NR_UPDATE; u++) begin
      ev_count_o = ev_count_o + ev_addr_valid_o[u] + ev_data_valid_o[u];
    end
    for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
      ev_count_o = ev_count_o + ev_complete_valid_o[w];
    for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
      ev_count_o = ev_count_o + (ev_commit_st_o[c] | ev_commit_ld_o[c]);
    ev_count_o = ev_count_o + ev_query_valid_o
               + (|ev_phys_valid_o) + (|ev_mod_valid_o);
`else
    ev_count_o = acc[0];
`endif
  end

  //pragma translate_off
  // hyp8 T1 item 12: equivalence — the serial form is recomputed and
  // compared against the balanced tree every cycle.
  logic [CNTW-1:0] t1_ref_count;
  always_comb begin : p_t1_evc_ref
    t1_ref_count = '0;
    for (int unsigned u = 0; u < NR_UPDATE; u++)
      t1_ref_count = t1_ref_count + ev_addr_valid_o[u] + ev_data_valid_o[u];
    for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
      t1_ref_count = t1_ref_count + ev_complete_valid_o[w];
    for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++)
      t1_ref_count = t1_ref_count + (ev_commit_st_o[c] | ev_commit_ld_o[c]);
    t1_ref_count = t1_ref_count + ev_query_valid_o
                 + (|ev_phys_valid_o) + (|ev_mod_valid_o);
  end
  int unsigned t1_evc_n = 0;
  always_ff @(posedge clk_i) begin : p_t1_evc_eq
    if (rst_ni) begin
      if (!$isunknown(ev_count_o)) begin
        t1_evc_n <= t1_evc_n + 1;
        g6lc_t1_evc_eq: assert (ev_count_o === t1_ref_count)
          else $error("g6lc_lsq_event: equiv evcount");
      end
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_lsq_event evcount: checked=%0d", t1_evc_n);
  end
  //pragma translate_on

  // svt-stage: end E
  // svt-stage: class E value

//pragma translate_off
  // Evidence retention for the complete-event capture boundary: shadow
  // each port's capture condition one edge, and if the staged output
  // did not assert on the next edge, count it and report a bounded set
  // of [lsq-ev-miss] lines. Non-fatal observation only.
  logic [G6LCCfg.NrWbPorts-1:0]                          lsq_cap_d, lsq_cap_q;
  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] lsq_cap_id_q;
  int unsigned                                          lsq_miss_cnt[G6LCCfg.NrWbPorts];
  int unsigned                                          lsq_miss_printed = 0;
  int unsigned                                          lsq_ev_cyc = 0;

  always_comb
    for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
      lsq_cap_d[w] = complete_valid_i[w] &&
                     !cancelled_mask_i[complete_id_i[w]] && !flush_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsq_cap_q    <= '0;
      lsq_cap_id_q <= '0;
      lsq_ev_cyc   <= 0;
      foreach (lsq_miss_cnt[w]) lsq_miss_cnt[w] <= 0;
    end else begin
      lsq_ev_cyc <= lsq_ev_cyc + 1;
      lsq_cap_q  <= lsq_cap_d;
      for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
        if (complete_valid_i[w]) lsq_cap_id_q[w] <= complete_id_i[w];
      for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
        if (lsq_cap_q[w] && !ev_complete_valid_o[w]) begin
          lsq_miss_cnt[w] <= lsq_miss_cnt[w] + 1;
          if (lsq_miss_printed < 8) begin
            lsq_miss_printed++;
            $display("[lsq-ev-miss] c=%0d w=%0d id=%0d (capture seen last edge, ev_complete never asserted)",
                     lsq_ev_cyc, w, lsq_cap_id_q[w]);
          end
        end
    end
  end

  final begin
    for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
      $display("[lsq-ev-miss] summary w=%0d count=%0d", w, lsq_miss_cnt[w]);
  end

  // +lsq_trace: event-stage boundary probe — shows what gen_cmp captured.
  bit lev_trace;
  int unsigned lev_cyc = 0;
  int unsigned lev_lo, lev_hi;
  initial begin
    lev_trace = $test$plusargs("lsq_trace");
    lev_lo = 0;
    lev_hi = 3000;
    void'($value$plusargs("trace_from=%d", lev_lo));
    void'($value$plusargs("trace_to=%d", lev_hi));
  end
  always @(posedge clk_i) begin
    if (!rst_ni) lev_cyc = 0;
    else if (lev_trace) begin
      lev_cyc++;
      if (lev_cyc >= lev_lo && lev_cyc <= lev_hi)
      for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++) begin
        if (complete_valid_i[w] || ev_complete_valid_o[w])
          $display("[lsq-ev] c=%0d w=%0d in_v=%b in_id=%0d in_st=%b canc=%b flush=%b out_v=%b out_id=%0d",
                   lev_cyc, w, complete_valid_i[w], complete_id_i[w],
                   complete_is_st_i[w], cancelled_mask_i[complete_id_i[w]],
                   flush_i, ev_complete_valid_o[w], ev_complete_id_o[w]);
      end
    end
  end
//pragma translate_on
endmodule
