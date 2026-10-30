// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.0/U6.2 L2 MSHR — multi-entry outstanding miss table with *line-merge*
// and *multi-waiter* support for multi-core MLP storms.
//
// Contention opts:
//   * Secondary miss to a pending line attaches without a new AXI fill
//   * Waiter mask holds up to MAX_WAITERS ids per line (multi-core same-line)
//   * complete returns primary id; waiter_pop drains additional waiters

module g6lc_l2_mshr #(
    parameter int unsigned DEPTH       = 8,
    parameter int unsigned ADDR_WIDTH  = 64,
    parameter int unsigned ID_WIDTH    = 4,
    parameter int unsigned MAX_WAITERS = 4,  // multi-core same-line attach depth
    // Opaque per-waiter payload carried alongside the waiter id (e.g. the
    // requester's AXI addr/len/size). Purely additive: it never participates in
    // admission, ordering, occupancy or completion.
    parameter int unsigned META_WIDTH  = 1
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         flush_i,
    // Allocate
    input  logic                         alloc_i,
    input  logic [ADDR_WIDTH-1:0]        alloc_line_addr_i,
    input  logic [ID_WIDTH-1:0]          alloc_id_i,
    input  logic [META_WIDTH-1:0]        alloc_meta_i,
    input  logic                         alloc_is_write_i,
    // Per-entry merge mask: an entry that must not accept new waiters (e.g. a
    // fill whose install was killed by a same-line invalidation). Blocked
    // entries stay valid for drain but are invisible to merge/lookup, so a
    // later same-line request allocates a fresh entry instead of attaching to
    // a fill that will never install.
    input  logic [DEPTH-1:0]             merge_block_i,
    output logic                         alloc_ready_o,
    output logic                         alloc_merged_o,
    output logic [$clog2(DEPTH)-1:0]     alloc_idx_o,
    // Lookup (merge probe)
    input  logic [ADDR_WIDTH-1:0]        lookup_line_addr_i,
    output logic                         lookup_hit_o,
    output logic [$clog2(DEPTH)-1:0]     lookup_idx_o,
    output logic [DEPTH-1:0]             id_match_o,
    // Complete primary
    input  logic                         complete_i,
    input  logic [$clog2(DEPTH)-1:0]     complete_idx_i,
    output logic [ID_WIDTH-1:0]          complete_id_o,
    // Extra waiters after fill (pop one per cycle)
    output logic                         waiter_valid_o,
    output logic [ID_WIDTH-1:0]          waiter_id_o,
    output logic [META_WIDTH-1:0]        waiter_meta_o,
    input  logic                         waiter_pop_i,
    // Status
    output logic                         empty_o,
    output logic                         full_o,
    output logic                         merge_full_o,  // line hit but waiter slots full
    output logic [$clog2(DEPTH+1)-1:0]   count_o
);

  localparam int unsigned IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned NW    = (MAX_WAITERS < 1) ? 1 : MAX_WAITERS;
  localparam int unsigned NW_W  = (NW <= 1) ? 1 : $clog2(NW + 1);

  typedef struct packed {
    logic                          valid;
    logic [ADDR_WIDTH-1:0]         line_addr;
    logic [ID_WIDTH-1:0]           id;          // primary requester
    logic                          is_write;
    // Packed multi-dim (not unpacked []) so the struct stays packed for Verilator.
    logic [NW-1:0][ID_WIDTH-1:0]   waiters;     // secondary multi-core waiters
    logic [NW-1:0][META_WIDTH-1:0] wmeta;       // payload paired 1:1 with waiters
    logic [NW_W-1:0]               nwait;       // 0..NW
  } entry_t;

  entry_t [DEPTH-1:0] mem_q, mem_d;
  logic [IDX_W:0] count_q, count_d;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_l2_mshr  region=6229  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: count_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to count_q
// order expect: mem_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to mem_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     count_q <= …; // sv-timing: cycle 1/1 on clk_i
//     mem_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node21982 c=3.50 slack=0.00 */
//     /* node21983 c=3.50 slack=0.00 */
//     /* node21984 c=3.50 slack=0.00 */
//     /* node21985 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_comb begin
    id_match_o='0;
    for(int unsigned e=0;e<DEPTH;e++)begin
      if(mem_q[e].valid)begin
        id_match_o[e]=(mem_q[e].id==alloc_id_i);
        for(int unsigned w=0;w<NW;w++)
          if(w<int'(mem_q[e].nwait) && mem_q[e].waiters[w]==alloc_id_i)
            id_match_o[e]=1'b1;
      end
    end
  end

  // CAM lookup
  always_comb begin
    lookup_hit_o = 1'b0;
    lookup_idx_o = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (mem_q[i].valid && !merge_block_i[i] &&
          (mem_q[i].line_addr == lookup_line_addr_i)) begin
        lookup_hit_o = 1'b1;
        lookup_idx_o = IDX_W'(i);
      end
    end
  end

  logic free_found, merge_found, merge_can_attach;
  logic [IDX_W-1:0] free_idx, merge_idx;
  always_comb begin
    free_found       = 1'b0;
    free_idx         = '0;
    merge_found      = 1'b0;
    merge_idx        = '0;
    merge_can_attach = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (mem_q[i].valid && !merge_block_i[i] &&
          (mem_q[i].line_addr == alloc_line_addr_i)) begin
        merge_found = 1'b1;
        merge_idx   = IDX_W'(i);
        merge_can_attach = (mem_q[i].nwait < NW[NW_W-1:0]) ||
            (waiter_pop_i && complete_idx_i == IDX_W'(i) && mem_q[i].nwait != '0);
      end
      if (!mem_q[i].valid && !free_found) begin
        free_found = 1'b1;
        free_idx   = IDX_W'(i);
      end
    end
  end

  assign alloc_ready_o  = merge_found ? merge_can_attach : free_found;
  assign alloc_merged_o = alloc_i && merge_found && merge_can_attach;
  assign alloc_idx_o    = merge_found ? merge_idx : free_idx;
  assign merge_full_o   = merge_found && !merge_can_attach;
  assign empty_o        = (count_q == '0);
  assign full_o         = (count_q == DEPTH[IDX_W:0]);
  assign count_o        = count_q;
  assign complete_id_o  = mem_q[complete_idx_i].id;

  // Waiter pop port (drain after primary complete — controller may sequence)
  assign waiter_valid_o = mem_q[complete_idx_i].valid && (mem_q[complete_idx_i].nwait != '0);
  assign waiter_id_o    = mem_q[complete_idx_i].waiters[0];
  assign waiter_meta_o  = mem_q[complete_idx_i].wmeta[0];

  logic [DEPTH-1:0] new_entry_mask, free_entry_mask;
  for (genvar e = 0; e < DEPTH; e++) begin : gen_entry_next
    logic pop, attach, new_entry, free_entry;
    always_comb begin
      // Procedural predicates retain the old treatment of unknown controls.
      pop = 1'b0;
      attach = 1'b0;
      new_entry = 1'b0;
      free_entry = 1'b0;
      if (waiter_pop_i && complete_idx_i == IDX_W'(e) &&
          mem_q[e].valid && mem_q[e].nwait != '0) pop = 1'b1;
      if (alloc_i && merge_found && merge_can_attach &&
          merge_idx == IDX_W'(e)) attach = 1'b1;
      if (alloc_i && free_found && !merge_found &&
          free_idx == IDX_W'(e)) new_entry = 1'b1;
      // Completion observes the post-pop/post-attach queue. An attachment
      // retains the owner even when the old last waiter was popped.
      if (complete_i && complete_idx_i == IDX_W'(e) && mem_q[e].valid &&
          !attach && (mem_q[e].nwait == '0 ||
                      (pop && mem_q[e].nwait == NW_W'(1)))) free_entry = 1'b1;
      new_entry_mask[e] = new_entry;
      free_entry_mask[e] = free_entry;
      mem_d[e] = mem_q[e];
      if (flush_i) begin
        mem_d[e].valid = 1'b0;
        mem_d[e].nwait = '0;
      end else begin
        case ({attach, pop})
          2'b10: mem_d[e].nwait = mem_q[e].nwait + 1'b1;
          2'b01: mem_d[e].nwait = mem_q[e].nwait - 1'b1;
          default: ;
        endcase
        for (int unsigned w = 0; w < NW; w++) begin
          if (pop && w < NW-1) begin
            mem_d[e].waiters[w] = mem_q[e].waiters[w+1];
            mem_d[e].wmeta[w] = mem_q[e].wmeta[w+1];
          end
          if (attach && (pop ? mem_q[e].nwait == NW_W'(w+1) :
                              mem_q[e].nwait == NW_W'(w))) begin
            mem_d[e].waiters[w] = alloc_id_i;
            mem_d[e].wmeta[w] = alloc_meta_i;
          end
        end
        if (new_entry) begin
          mem_d[e].valid = 1'b1;
          mem_d[e].line_addr = alloc_line_addr_i;
          mem_d[e].id = alloc_id_i;
          mem_d[e].is_write = alloc_is_write_i;
          mem_d[e].nwait = '0;
        end
        if (free_entry) mem_d[e].valid = 1'b0;
      end
    end
  end
  always_comb begin
    count_d = count_q;
    if (flush_i) count_d = '0;
    else begin
      case ({(|new_entry_mask), (|free_entry_mask)})
        2'b10: count_d = count_q + (IDX_W+1)'(1);
        2'b01: count_d = count_q - (IDX_W+1)'(1);
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < DEPTH; i++) mem_q[i] <= '0;
      count_q <= '0;
    end else begin
      mem_q   <= mem_d;
      count_q <= count_d;
    end
  end

endmodule

