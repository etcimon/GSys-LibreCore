// hyp8 provenance: REWRITTEN for the 8-FO4 frontend (next-line kernel)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_fe_nextline — the only single-cycle next-PC kernel.
//
//     npc_d = red_apply    ? (red_step ? next_block(red_pc) : red_pc)
//           : hold_i       ? hold_pc_i
//           : advance_i    ? (line_taken_q ? line_target_q : next_block(npc_q))
//           :                npc_q
//
// The response-side predictor no longer sits in this recurrence. Its place is
// taken by an untagged line table of FeNextlineEntries entries, each holding
// {taken, target-block} for one fetch block, written by the override stages
// and by resolve. The table is READ ONE CYCLE AHEAD: the index is npc_d's
// index field — computed by a narrow LIDX-bit select/increment, not the
// full-width npc_d path (see gen_line_table) — so the registered lookup
// product (line_taken_q/line_target_q) describes the block npc_q is
// fetching right now and steers only the *following* address.
// No flop is added to npc_d (svt-pipe contract: no-cut on npc_d/seq_base/
// fetch_address); the recurrence shortens to mux + table-read + next_block.
//
// Training (line_train): on a taken override or a taken resolve the entry for
// the *source block* records the target; a not-taken outcome clears the entry
// (train_taken_i=0), so a mispredicted line guess unlearns itself.
//
// HypCfg.FeNextlineUntagged=0 degenerates to the reference order:
// advance ? next_block(npc_q) : npc_q — the table is not instantiated and
// corrections arrive only through the override path (as before, via the
// prediction redirect).
//
// fetch_address_o is the block presented to the I$/FTQ this cycle: the
// applying redirect target, the held redirect re-presentation, else npc_q —
// identical to the reference fetch_address encoding.

module g6lc_fe_nextline
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    // Boot (out of reset the cursor is the boot address)
    input  logic [G6LCCfg.VLEN-1:0] boot_addr_i,
    // Applying redirect record (g6lc_fe_redirect, one-cycle pulse)
    input  logic                    red_valid_i,
    input  logic [G6LCCfg.VLEN-1:0] red_pc_i,
    input  logic                    red_step_i,
    // Redirect-completion hold: re-present the armed target until its block
    // has been registered (frontend redirect_pend machinery)
    input  logic                    hold_i,
    input  logic [G6LCCfg.VLEN-1:0] hold_pc_i,
    // Advance = the FTQ push / I$ accept condition (if_ready)
    input  logic                    advance_i,
    // Line-table training (override #1/#2 and resolve)
    input  logic                    train_valid_i,
    input  logic [G6LCCfg.VLEN-1:0] train_pc_i,     // source block address
    input  logic                    train_taken_i,  // 0 = unlearn the entry
    input  logic [G6LCCfg.VLEN-1:0] train_target_i, // taken target block

    output logic [G6LCCfg.VLEN-1:0] npc_o,          // npc_q (enqueue cursor)
    output logic [G6LCCfg.VLEN-1:0] npc_d_o,        // next cursor (kernel out)
    output logic [G6LCCfg.VLEN-1:0] fetch_address_o,// block presented now
    // The line prediction currently steering npc_d (for the FTQ push record
    // and the BTB check's "what the line guessed" comparison)
    output logic                    line_taken_o,
    output logic [G6LCCfg.VLEN-1:0] line_target_o
);

  localparam g6lc_fetch_pkg::fetch_geo_t Geo = g6lc_fetch_pkg::geo(G6LCCfg);
  localparam int unsigned BLOCK_W = G6LCCfg.FETCH_ALIGN_BITS;
  localparam int unsigned NENT =
      (HypCfg.FeNextlineUntagged && HypCfg.FeNextlineEntries > 0)
          ? HypCfg.FeNextlineEntries : 0;
  localparam int unsigned LIDX_W = (NENT > 1) ? $clog2(NENT) : 1;

  function automatic logic [G6LCCfg.VLEN-1:0] next_block(logic [G6LCCfg.VLEN-1:0] addr);
    logic [63:0] nb;
    nb = g6lc_fetch_pkg::next_block(G6LCCfg, 64'(addr));
    return nb[G6LCCfg.VLEN-1:0];
  endfunction

  logic [G6LCCfg.VLEN-1:0] npc_d, npc_q;
  logic npc_rst_load_q;

  // ------------------------------------------------------------------
  // svt-stage: begin NL
  // Untagged line table + read-ahead
  // ------------------------------------------------------------------
  logic                    line_taken_q;
  logic [G6LCCfg.VLEN-1:0] line_target_q;

  if (NENT > 0) begin : gen_line_table
    // {taken, target} per entry; index = block address bits above the block
    // offset. Untagged: a hit is assumed whenever the entry was ever trained
    // (taken flag doubles as the valid bit).
    logic [NENT-1:0]                 ltaken_q;
    logic [NENT-1:0][G6LCCfg.VLEN-1:0] ltarget_q;
    logic [LIDX_W-1:0]               rd_idx, wr_idx;

    // hyp8: narrow read-ahead index — a LIDX_W-bit select/increment
    // feeding the 256:1 table read instead of the full-VLEN npc_d mux in
    // front of it. The equivalence: next_block(x) masks the block offset
    // before adding one block, so its index bits are x[idx]+1 (carry
    // propagates upward only, never into the field); npc_q is block
    // aligned, so next_block(npc_q)[idx] == npc_q[idx] + 1. cursor covers
    // the post-reset boot cycle.
    assign wr_idx = train_pc_i[BLOCK_W +: LIDX_W];

    always_comb begin
      if (red_valid_i)
        rd_idx = red_step_i ? red_pc_i[BLOCK_W +: LIDX_W] + LIDX_W'(1)
                            : red_pc_i[BLOCK_W +: LIDX_W];
      else if (hold_i)
        rd_idx = hold_pc_i[BLOCK_W +: LIDX_W];
      else if (advance_i)
        rd_idx = line_taken_q ? line_target_q[BLOCK_W +: LIDX_W]
                              : cursor_idx + LIDX_W'(1);
      else
        rd_idx = cursor_idx;
    end

    // Read one cycle ahead: the lookup of npc_d registers as the guess that
    // steers the address AFTER next — the index add/mux is off the kernel.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        line_taken_q  <= 1'b0;
        line_target_q <= '0;
      end else if (flush_i || red_valid_i) begin
        // a redirect/override invalidates the guess in flight
        line_taken_q  <= 1'b0;
      end else begin
        line_taken_q  <= ltaken_q[rd_idx];
        line_target_q <= ltarget_q[rd_idx];
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ltaken_q  <= '0;
        ltarget_q <= '0;
      end else if (flush_i) begin
        ltaken_q <= '0;
      end else if (train_valid_i) begin
        ltaken_q[wr_idx]  <= train_taken_i;
        ltarget_q[wr_idx] <= train_target_i;
      end
    end
  end else begin : gen_no_line_table
    // FeNextlineUntagged=0: sequential-only kernel (reference order)
    assign line_taken_q  = 1'b0;
    assign line_target_q = '0;
  end

  // ------------------------------------------------------------------
  // The kernel
  // ------------------------------------------------------------------
  // the live cursor: boot address out of reset, the NPC register after
  logic [G6LCCfg.VLEN-1:0] cursor;
  logic [((HypCfg.FeNextlineUntagged && HypCfg.FeNextlineEntries > 0)
          ? $clog2(HypCfg.FeNextlineEntries) : 1)-1:0] cursor_idx;
  assign cursor = npc_rst_load_q ? boot_addr_i : npc_q;
  // its table-index slice (hyp8 narrow rd_idx uses this for the increment)
  assign cursor_idx = cursor[BLOCK_W +: LIDX_W];
  always_comb begin : npc_select
    if (red_valid_i)      npc_d = red_step_i ? next_block(red_pc_i) : red_pc_i;
    // re-present the redirect target until its block has been registered
    else if (hold_i)      npc_d = hold_pc_i;
    else if (advance_i)   npc_d = line_taken_q ? line_target_q
                                               : next_block(cursor);
    else                  npc_d = cursor;
  end

  // The block presented to the I$/FTQ this cycle.
  assign fetch_address_o = red_valid_i ? red_pc_i
                         : hold_i      ? hold_pc_i
                         :               cursor;

  assign npc_o        = cursor;
  assign npc_d_o      = npc_d;
  assign line_taken_o = line_taken_q;
  assign line_target_o = line_target_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      npc_q          <= '0;
      npc_rst_load_q <= 1'b1;
    end else begin
      npc_q          <= npc_d;
      npc_rst_load_q <= 1'b0;
    end
  end

  // svt-stage: end NL
  // svt-stage: class NL decision
  // svt-stage: absorb NL by=read-ahead cond="line table read one cycle ahead; redirect record applies next cycle"
endmodule
