// hyp8 provenance: REWRITTEN (sv-timing emit at the 8-FO4 budget)
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright 2026 GSys — LibreCore hypothesis core (8-FO4 redesign).
// Description: store buffer speculative-queue insertion, staged S1/S2.
//   S1 captures the arriving store (lowest-free slot one-hot + its age row
//   against the surviving entries, computed from the circular trans_id
//   distance anchored at the reclaim pointer) into a pending record.
//   S2 writes the entry payload and the age matrix row/column — the wrapper
//   applies the write into the stationary queue state. A store therefore
//   reserves its slot one cycle after presenting valid_i; `ready_o` in the
//   wrapper accounts for the pending S1 record (rank-2 registered ready).

module stb_insert
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned           DEPTH_SPEC = 4,
    parameter type                   entry_t    = logic,
    parameter type                   cbo_t      = logic,
    parameter bit                    AGE_EN     = 1'b1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,  // drop a staged (still speculative) insert
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // store arrival (LSU core interface)
    input  logic                             valid_i,
    input  logic [G6LCCfg.PLEN-1:0]          paddr_i,
    input  logic [G6LCCfg.XLEN-1:0]          data_i,
    input  logic [(G6LCCfg.XLEN/8)-1:0]      be_i,
    input  logic [1:0]                       data_size_i,
    input  cbo_t                             cbo_op_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_i,
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] st_hart_i,
    // G1ah fwd_keep at arrival (LEGACY_SMT_KEEP path; 0 under OoO)
    input  logic                             fwd_keep_i,
    // queue view for slot select + age row
    input  logic [DEPTH_SPEC-1:0]            spec_valid_i,
    input  logic [DEPTH_SPEC-1:0][G6LCCfg.TRANS_ID_BITS-1:0] spec_tid_i,
    // entries still live after this cycle's removals — the age row is
    // taken against them so the matrix never references a leaving slot
    input  logic [DEPTH_SPEC-1:0]            live_after_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] oldest_live_tid_i,
    // pending-record occupancy (feeds the registered ready accounting)
    output logic                             s1_v_o,
    // S2 writeback record: apply at the next edge into the queue state
    output logic                             s2_wr_valid_o,
    output logic [DEPTH_SPEC-1:0]            s2_slot_oh_o,
    output entry_t                           s2_entry_o,
    output logic [DEPTH_SPEC-1:0]            s2_older_row_o,  // spec_older[j][i]
    output logic [DEPTH_SPEC-1:0]            s2_older_col_o   // spec_older[i][j]
);

  function automatic logic ooo_older(input logic [G6LCCfg.TRANS_ID_BITS-1:0] a,
                                     input logic [G6LCCfg.TRANS_ID_BITS-1:0] b);
    return g6lc_ooo_pkg::ooo_age_older(G6LCCfg.TRANS_ID_BITS, 32'(a), 32'(b),
                                     32'(oldest_live_tid_i));
  endfunction

  // lowest set bit as a log-depth prefix OR (A140 carry-chain form)
  function automatic logic [DEPTH_SPEC-1:0] lowest_set(input logic [DEPTH_SPEC-1:0] x);
    logic [DEPTH_SPEC-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < DEPTH_SPEC; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction

  logic                     s1_v_q;
  logic [DEPTH_SPEC-1:0]    s1_slot_q;
  entry_t                   s1_entry_q;
  logic [DEPTH_SPEC-1:0]    s1_row_q, s1_col_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] s1_tid_q;

  wire ins_take = valid_i && !cancelled_mask_i[trans_id_i];

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_s1
    if (!rst_ni) begin
      s1_v_q    <= 1'b0;
      s1_slot_q <= '0;
      s1_entry_q <= '0;
      s1_row_q  <= '0;
      s1_col_q  <= '0;
      s1_tid_q  <= '0;
    end else begin
      // S1 -> S2 always drains (one-deep record); a same-cycle flush or a
      // cancel of the staged tid kills the writeback instead.
      s1_v_q <= ins_take;
      if (ins_take) begin
        s1_slot_q            <= lowest_set(~spec_valid_i);
        s1_entry_q.address   <= paddr_i;
        s1_entry_q.data      <= data_i;
        s1_entry_q.be        <= be_i;
        s1_entry_q.data_size <= data_size_i;
        s1_entry_q.valid     <= 1'b1;
        s1_entry_q.cbo_op    <= cbo_op_i;
        s1_entry_q.trans_id  <= trans_id_i;
        s1_entry_q.hart      <= st_hart_i;
        s1_entry_q.wait_rvalid <= 1'b0;
        s1_entry_q.fwd_keep  <= fwd_keep_i;
        s1_tid_q             <= trans_id_i;
        for (int unsigned j = 0; j < DEPTH_SPEC; j++) begin
          // spec_older[j][i]: entry j older than the arrival
          s1_row_q[j] <= live_after_i[j] &&
                         (!AGE_EN || ooo_older(spec_tid_i[j], trans_id_i));
          // spec_older[i][j]: the arrival older than entry j
          s1_col_q[j] <= live_after_i[j] &&
                         (AGE_EN && !ooo_older(spec_tid_i[j], trans_id_i));
        end
      end
    end
  end

  assign s1_v_o = s1_v_q;

  // S2: the staged record becomes a queue writeback unless the entry was
  // cancelled while staged or a flush evicts it — identical in effect to
  // the emit's same-cycle ins_active && !cancelled guard and the
  // "flush in the arrival's cycle evicts it" branch.
  assign s2_wr_valid_o = s1_v_q && !flush_i && !cancelled_mask_i[s1_tid_q];
  assign s2_slot_oh_o  = s1_slot_q;
  assign s2_entry_o    = s1_entry_q;
  assign s2_older_row_o = s1_row_q;
  assign s2_older_col_o = s1_col_q;

endmodule
