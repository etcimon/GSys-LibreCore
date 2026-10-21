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
  logic [LANES-1:0]    ev_be;
  logic                ev_qual;
  logic [ENTRIES-1:0]  match_d, unres_d, nodata_d;
  assign ev_qual = ev_valid_i && !cancelled_mask_i[ev_id_i];
  always_comb ev_be = ev_qual ? lane_be(ev_addr_i, ev_size_i) : '0;
  for (genvar i = 0; i < ENTRIES; i++) begin : gen_cam_cmp
    logic same_h, addr_ok, word_hit;
    assign same_h  = ev_qual && ent_i[i].valid && (ent_i[i].hart == ev_hart_i);
    assign addr_ok = same_h && ent_i[i].addr_v;
    assign word_hit = addr_ok && same_word(ent_i[i].addr, ev_addr_i) &&
                      ((lane_be(ent_i[i].addr, ent_i[i].size) & ev_be) != '0);
    // Live, same hart, no address yet: it may alias when it resolves —
    // the verdict stage combines this with age.
    assign unres_d[i]  = same_h && !ent_i[i].addr_v;
    assign match_d[i]  = word_hit;
    assign nodata_d[i] = word_hit && !ent_i[i].data_v;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      match_o  <= '0;
      unres_o  <= '0;
      nodata_o <= '0;
    end else if (flush_i) begin
      match_o  <= '0;
      unres_o  <= '0;
      nodata_o <= '0;
    end else begin
      match_o  <= match_d;
      unres_o  <= unres_d;
      nodata_o <= nodata_d;
    end
  end

  // svt-stage: end C
  // svt-stage: class C value
endmodule
