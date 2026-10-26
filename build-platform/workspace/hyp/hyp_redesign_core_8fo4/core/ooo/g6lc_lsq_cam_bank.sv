// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq_cam_bank — hyp8 LSQ hazard CAM, one bank of entries.
//
// hyp8: the emit's ST-wide / LD-wide combinational scans are split into
// HypCfg.LsqCamBanks banks of at most four entries each.  This module is
// one bank: a staged event address is compared against the bank's
// entries and the per-entry verdict bits are REGISTERED (pipeline
// stage C in the E->C->R->V chain — the verdict lands three cycles
// after the event was staged).
//
// Per entry the bank reports:
//   match_o   — entry is live, address-resolved, same aligned word, and
//               the byte lanes of the two accesses overlap; the hart
//               tag must match (T6b: loads order only within their hart).
//   unres_o   — entry is live and hart-matched but its address is still
//               unresolved: it may yet alias (the STL "wait" source).
//   nodata_o  — matched but the entry's data has not landed (store
//               forward must wait for the data event).
//
// Kill identities: an event killed in flight is gated here by
// cancelled_mask_i[ev_id_i] so it produces no candidates; flush_i
// clears the bank registers.

module g6lc_lsq_cam_bank #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned ENTRIES = 4,
    // Canonical projected entry record (valid/addr_v/addr/size/hart/
    // data_v), declared in the g6lc_lsq wrapper and injected here.
    parameter type cam_ent_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,

    // Staged address event (registered upstream this cycle).
    input  logic                            ev_valid_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] ev_id_i,
    input  logic [G6LCCfg.PLEN-1:0]          ev_addr_i,
    input  logic [1:0]                       ev_size_i,
    // hyp8 T1 item 2: the event's byte-lane footprint and the cancel
    // read both carried as stage-E registrations.
    input  logic [(G6LCCfg.XLEN+7)/8-1:0]    ev_be_i,
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ev_hart_i,

    // The bank's projected entries (registered state).
    input  cam_ent_t [ENTRIES-1:0]           ent_i,

    output logic [ENTRIES-1:0]               match_o,
    output logic [ENTRIES-1:0]               unres_o,
    output logic [ENTRIES-1:0]               nodata_o
);
  // svt-stage: begin C

  localparam int unsigned LANES = (G6LCCfg.XLEN + 7) / 8;

  // Byte-lane footprint of an access inside its aligned XLEN word — the
  // emit base's lane_be, verbatim.
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

  // Same aligned word? — the emit base's same_word, verbatim.
  function automatic logic same_word(
      input logic [G6LCCfg.PLEN-1:0] a,
      input logic [G6LCCfg.PLEN-1:0] b
  );
    if (G6LCCfg.PLEN > 6)
      same_word = (a[G6LCCfg.PLEN-1:3] == b[G6LCCfg.PLEN-1:3]);
    else
      same_word = (a == b);
  endfunction

  // hyp8: per-entry compare vectors (independent LHS) instead of the
  // procedural serial scan — identical dataflow, parallel depth.
  // hyp8 T1 item 2: the entry's byte-lane footprint is a stored field
  // (written with the address) and the event's is the staged ev_be_i,
  // so no variable shift sits on this cone.  The cancelled-mask read
  // registers beside the compare (ccl_q): (raw & valid & !cancelled)
  // delayed is bit-identical to (raw & valid) delayed AND !cancelled
  // delayed, so the dynamic index leaves the per-entry series.
  logic [ENTRIES-1:0]  match_d, unres_d, nodata_d;
  logic                ccl_q;
  logic [ENTRIES-1:0]  match_q, unres_q, nodata_q;
`ifdef G6LC_MUT_T1_CAMBE
  // Review mutant: pre-T1 recomputed lane_be and in-cone cancel.
  logic [LANES-1:0] ev_be;
  logic             ev_qual;
  assign ev_qual = ev_valid_i && !cancelled_mask_i[ev_id_i];
  always_comb ev_be = ev_qual ? lane_be(ev_addr_i, ev_size_i) : '0;
  for (genvar i = 0; i < ENTRIES; i++) begin : gen_cam_cmp
    logic same_h, addr_ok, word_hit;
    assign same_h  = ev_qual && ent_i[i].valid && (ent_i[i].hart == ev_hart_i);
    assign addr_ok = same_h && ent_i[i].addr_v;
    assign word_hit = addr_ok && same_word(ent_i[i].addr, ev_addr_i) &&
                      ((lane_be(ent_i[i].addr, ent_i[i].size) & ev_be) != '0);
    assign unres_d[i]  = same_h && !ent_i[i].addr_v;
    assign match_d[i]  = word_hit;
    assign nodata_d[i] = word_hit && !ent_i[i].data_v;
  end
`else
  for (genvar i = 0; i < ENTRIES; i++) begin : gen_cam_cmp
    logic same_h, addr_ok, word_hit;
    assign same_h  = ev_valid_i && ent_i[i].valid && (ent_i[i].hart == ev_hart_i);
    assign addr_ok = same_h && ent_i[i].addr_v;
    assign word_hit = addr_ok && same_word(ent_i[i].addr, ev_addr_i) &&
                      ((ent_i[i].be & ev_be_i) != '0);
    // Live, same hart, no address yet: it may alias when it resolves —
    // the verdict stage combines this with age.
    assign unres_d[i]  = same_h && !ent_i[i].addr_v;
    assign match_d[i]  = word_hit;
    assign nodata_d[i] = word_hit && !ent_i[i].data_v;
  end
`endif

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      match_q  <= '0;
      unres_q  <= '0;
      nodata_q <= '0;
      ccl_q    <= 1'b0;
    end else if (flush_i) begin
      match_q  <= '0;
      unres_q  <= '0;
      nodata_q <= '0;
      ccl_q    <= 1'b0;
    end else begin
      match_q  <= match_d;
      unres_q  <= unres_d;
      nodata_q <= nodata_d;
`ifdef G6LC_MUT_T1_CAMBE
      ccl_q    <= 1'b1;
`else
      ccl_q    <= !cancelled_mask_i[ev_id_i];
`endif
    end
  end
  // r68: the mask is sampled at E (ccl_q); a cancel landing in the C cycle
  // itself would otherwise publish a match for an event the scoreboard has
  // already killed (hyp8-osbi-scalar-r39 stopped at cyc 42,914 on
  // g6lc_t1_cam_oa). The live mask re-qualifies the registered outputs: a
  // cancelled event's match has no architectural meaning, so this is the
  // conservative direction (channel 3), and the assertion below holds by
  // construction. Cost: one dynamic mask read + AND on the reg->out cone.
  logic [G6LCCfg.TRANS_ID_BITS-1:0] ev_id_c_q;
  logic                             ccl_live;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ev_id_c_q <= '0;
    else         ev_id_c_q <= ev_id_i;
  end
  assign ccl_live = ccl_q && !cancelled_mask_i[ev_id_c_q];
  assign match_o  = match_q  & {ENTRIES{ccl_live}};
  assign unres_o  = unres_q  & {ENTRIES{ccl_live}};
  assign nodata_o = nodata_q & {ENTRIES{ccl_live}};

  //pragma translate_off
  // hyp8 T1 item 2: equivalence + the plan's cancel guard.
  //  - ent.be is a pure function of the stored {addr,size} written at
  //    the address edge — checked live.
  //  - ev_be_i is the same function of the staged {ev_addr_i,ev_size_i}.
  //  - the whole pre-T1 datapath (in-cone ev_qual + recomputed lane_be)
  //    is rebuilt and its registered form compared against the outputs.
  //  - plan guard: a match bit must never survive for a killed event.
  logic [ENTRIES-1:0] ref_match_d, ref_unres_d, ref_nodata_d;
  logic [ENTRIES-1:0] ref_match_q, ref_unres_q, ref_nodata_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] ev_id_q;
  logic                     ref_ev_qual;
  assign ref_ev_qual = ev_valid_i && !cancelled_mask_i[ev_id_i];
  always_comb begin : p_t1_cam_ref
    automatic logic [LANES-1:0] rbe;
    rbe = ref_ev_qual ? lane_be(ev_addr_i, ev_size_i) : '0;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      ref_match_d[i]  = ref_ev_qual && ent_i[i].valid &&
                        (ent_i[i].hart == ev_hart_i) && ent_i[i].addr_v &&
                        same_word(ent_i[i].addr, ev_addr_i) &&
                        ((lane_be(ent_i[i].addr, ent_i[i].size) & rbe) != '0);
      ref_unres_d[i]  = ref_ev_qual && ent_i[i].valid &&
                        (ent_i[i].hart == ev_hart_i) && !ent_i[i].addr_v;
      ref_nodata_d[i] = ref_match_d[i] && !ent_i[i].data_v;
    end
  end
  int unsigned t1_cam_n = 0;
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_t1_cam_eq
    if (!rst_ni) begin
      ref_match_q  <= '0;
      ref_unres_q  <= '0;
      ref_nodata_q <= '0;
      ev_id_q      <= '0;
      t1_cam_n     <= 0;
    end else if (flush_i) begin
      ref_match_q  <= '0;
      ref_unres_q  <= '0;
      ref_nodata_q <= '0;
      ev_id_q      <= '0;
    end else begin
      ref_match_q  <= ref_match_d;
      ref_unres_q  <= ref_unres_d;
      ref_nodata_q <= ref_nodata_d;
      ev_id_q      <= ev_id_i;
      if (!$isunknown({match_o, unres_o, nodata_o})) begin
        t1_cam_n <= t1_cam_n + 1;
        g6lc_t1_cam_eq: assert (match_o === (ref_match_q & {ENTRIES{!cancelled_mask_i[ev_id_q]}}) &&
                                unres_o === (ref_unres_q & {ENTRIES{!cancelled_mask_i[ev_id_q]}}) &&
                                nodata_o === (ref_nodata_q & {ENTRIES{!cancelled_mask_i[ev_id_q]}}))
          else $error("g6lc_lsq_cam_bank: equiv cambe");
        for (int unsigned i = 0; i < ENTRIES; i++) begin
          g6lc_t1_cam_oa: assert (!(match_o[i]) ||
                                  !cancelled_mask_i[ev_id_q])
            else $error("g6lc_lsq_cam_bank: equiv cambe (killed match)");
        end
      end
      if (ev_valid_i && !$isunknown(ev_be_i)) begin
        g6lc_t1_cam_be: assert (ev_be_i === lane_be(ev_addr_i, ev_size_i))
          else $error("g6lc_lsq_cam_bank: equiv cambe (ev_be)");
      end
      for (int unsigned i = 0; i < ENTRIES; i++) begin
        if (ent_i[i].valid && ent_i[i].addr_v && !$isunknown(ent_i[i].be)) begin
          g6lc_t1_cam_eb: assert (
              ent_i[i].be === lane_be(ent_i[i].addr, ent_i[i].size))
            else $error("g6lc_lsq_cam_bank: equiv cambe (ent be %0d)", i);
        end
      end
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_lsq_cam_bank cambe: checked=%0d", t1_cam_n);
  end
  //pragma translate_on

  // svt-stage: end C
  // svt-stage: class C value
endmodule
