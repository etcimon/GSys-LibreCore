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
  for (genvar u = 0; u < NR_UPDATE; u++) begin : gen_upd
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ev_addr_valid_o[u]  <= 1'b0;
        ev_addr_is_st_o[u]  <= 1'b0;
        ev_addr_id_o[u]     <= '0;
        ev_addr_o[u]        <= '0;
        ev_addr_size_o[u]   <= '0;
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
      ev_query_hart_o  <= '0;
    end else if (flush_i) begin
      ev_query_valid_o <= 1'b0;
    end else begin
      ev_query_valid_o <= ld_query_i && !cancelled_mask_i[ld_query_id_i];
      if (ld_query_i) begin
        ev_query_id_o   <= ld_query_id_i;
        ev_query_addr_o <= ld_query_addr_i;
        ev_query_size_o <= ld_query_size_i;
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
  always_comb begin
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
  end

  // svt-stage: end E
  // svt-stage: class E value
endmodule
