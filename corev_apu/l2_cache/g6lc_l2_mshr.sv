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
    parameter int unsigned MAX_WAITERS = 4  // multi-core same-line attach depth
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         flush_i,
    // Allocate
    input  logic                         alloc_i,
    input  logic [ADDR_WIDTH-1:0]        alloc_line_addr_i,
    input  logic [ID_WIDTH-1:0]          alloc_id_i,
    input  logic                         alloc_is_write_i,
    output logic                         alloc_ready_o,
    output logic                         alloc_merged_o,
    output logic [$clog2(DEPTH)-1:0]     alloc_idx_o,
    // Lookup (merge probe)
    input  logic [ADDR_WIDTH-1:0]        lookup_line_addr_i,
    output logic                         lookup_hit_o,
    output logic [$clog2(DEPTH)-1:0]     lookup_idx_o,
    // Complete primary
    input  logic                         complete_i,
    input  logic [$clog2(DEPTH)-1:0]     complete_idx_i,
    output logic [ID_WIDTH-1:0]          complete_id_o,
    // Extra waiters after fill (pop one per cycle)
    output logic                         waiter_valid_o,
    output logic [ID_WIDTH-1:0]          waiter_id_o,
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
    logic [NW_W-1:0]               nwait;       // 0..NW
  } entry_t;

  entry_t [DEPTH-1:0] mem_q, mem_d;
  logic [IDX_W:0] count_q, count_d;

  // CAM lookup
  always_comb begin
    lookup_hit_o = 1'b0;
    lookup_idx_o = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (mem_q[i].valid && (mem_q[i].line_addr == lookup_line_addr_i)) begin
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
      if (mem_q[i].valid && (mem_q[i].line_addr == alloc_line_addr_i)) begin
        merge_found = 1'b1;
        merge_idx   = IDX_W'(i);
        merge_can_attach = (mem_q[i].nwait < NW[NW_W-1:0]);
      end
      if (!mem_q[i].valid && !free_found) begin
        free_found = 1'b1;
        free_idx   = IDX_W'(i);
      end
    end
  end

  assign alloc_ready_o  = free_found || (merge_found && merge_can_attach);
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

  always_comb begin
    mem_d   = mem_q;
    count_d = count_q;
    if (flush_i) begin
      for (int unsigned i = 0; i < DEPTH; i++) begin
        mem_d[i].valid = 1'b0;
        mem_d[i].nwait = '0;
      end
      count_d = '0;
    end else begin
      // Pop one waiter (shift queue)
      if (waiter_pop_i && mem_q[complete_idx_i].valid && mem_q[complete_idx_i].nwait != '0) begin
        for (int unsigned w = 0; w < NW - 1; w++)
          mem_d[complete_idx_i].waiters[w] = mem_q[complete_idx_i].waiters[w+1];
        mem_d[complete_idx_i].nwait = mem_q[complete_idx_i].nwait - 1'b1;
      end
      // Complete frees entry only when no waiters left
      if (complete_i && mem_q[complete_idx_i].valid) begin
        if (mem_d[complete_idx_i].nwait == '0) begin
          mem_d[complete_idx_i].valid = 1'b0;
          count_d = count_q - (IDX_W+1)'(1);
        end
      end
      // Alloc new or attach waiter
      if (alloc_i && merge_found && merge_can_attach) begin
        automatic logic [NW_W-1:0] wi;
        wi = mem_q[merge_idx].nwait;
        mem_d[merge_idx].waiters[wi] = alloc_id_i;
        mem_d[merge_idx].nwait       = wi + 1'b1;
      end else if (alloc_i && free_found && !merge_found) begin
        mem_d[free_idx].valid     = 1'b1;
        mem_d[free_idx].line_addr = alloc_line_addr_i;
        mem_d[free_idx].id        = alloc_id_i;
        mem_d[free_idx].is_write  = alloc_is_write_i;
        mem_d[free_idx].nwait     = '0;
        count_d = count_d + (IDX_W+1)'(1);
      end
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

