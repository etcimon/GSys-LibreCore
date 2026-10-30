// hyp8 provenance: ADAPTED (sv-timing emit base, registered lookup + credit)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 05.05.2017
// Description: Buffer to hold CSR address, this acts like a functional unit
//              to the scoreboard.
//
// hyp8 (group 6): on the OoO path the per-tid commit lookup and the
// dispatch credit are combinational:
//   - csr_addr_o is a combinational table read keyed by csr_commit_tid_i;
//     csr_commit_i only releases the matching record, it never gates the
//     address (a commit that has not happened yet must not starve the
//     lookup of its own request).
//   - the table is allocated at DISPATCH (disp_valid_i strobes, lane
//     order) — a resource released in commit order is owned in program
//     order (r33); the IQ-age frontier is a filter, not the owner.
//   - csr_credit_o is the post-sweep free count the dispatch group gate
//     compares against; csr_ready_o at the IRO/arbitrer is constant-true
//     because every granted CSR already owns an entry (asserted).
// The in-order (OoOEn==0) single-entry path keeps its emit timing
// bit-identically.


module csr_buffer
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Flush CSR - CONTROLLER
    input logic flush_i,
    // OoO: drop table entries whose scoreboard slot was cancelled - ISSUE_STAGE
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // OoO: scoreboard issued mask — a table entry whose owner slot is no
    // longer live is dead regardless of how a cancel raced the free.
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_live_i,
    // OoO dispatch allocation strobes - ISSUE_STAGE: one per issue lane,
    // pulsed the cycle the dispatch group that owns the lane is consumed
    // by the IQ. The table allocates at dispatch in lane order so a
    // resource released in commit order is owned in program order (r33).
    input  logic [G6LCCfg.NrIssuePorts-1:0] disp_valid_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] disp_tid_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][11:0] disp_addr_i,
    // OoO: free entries after the sweeps, read by the dispatch group gate.
    output logic [g6lc_ooo_pkg::ooo_csr_credit_bits(G6LCCfg)-1:0] csr_credit_o,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t fu_data_i,
    // CSR FU is ready - ISSUE_STAGE
    output logic csr_ready_o,
    // CSR instruction is valid - ISSUE_STAGE
    input logic csr_valid_i,
    // CSR buffer result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] csr_result_o,
    // commit the pending CSR OP - TO_BE_COMPLETED
    input logic csr_commit_i,
    // trans_id of the committing CSR (OoO only) - COMMIT_STAGE
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] csr_commit_tid_i,
    // CSR address to write - COMMIT_STAGE
    output logic [11:0] csr_addr_o
);

  // An atomic dispatch group must fit when the table is empty. In-order
  // retains one entry; one-/two-issue OoO retains its two-entry table.
  localparam int unsigned DEPTH = g6lc_ooo_pkg::ooo_csr_slots(G6LCCfg);
  localparam int unsigned CREDIT_W = g6lc_ooo_pkg::ooo_csr_credit_bits(G6LCCfg);

  typedef struct packed {
    logic [11:0] csr_address;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] tid;
    logic        valid;
  } csr_ent_t;

  csr_ent_t tab_d[DEPTH], tab_q[DEPTH];

  // control logic, scoreboard signals
  assign csr_result_o = fu_data_i.operand_a;

  if (!G6LCCfg.OoOEn) begin : gen_inorder
    assign csr_addr_o = tab_q[0].csr_address;
    // No OoO dispatch consumer exists in this profile.
    assign csr_credit_o = '0;

    // write logic
    always_comb begin : write
      tab_d = tab_q;
      // by default we are ready
      csr_ready_o = 1'b1;
      // if we have a valid uncommitted csr req or are just getting one WITHOUT a commit in, we are not ready
      // Depth one on purpose: a second CSR must not be accepted before the first
      // retires, or the two side effects could be applied out of program order.
      if ((tab_q[0].valid || csr_valid_i) && ~csr_commit_i) csr_ready_o = 1'b0;
      // if we got a valid from the scoreboard
      // store the CSR address
      if (csr_valid_i) begin
        tab_d[0].csr_address = fu_data_i.operand_b[11:0];
        tab_d[0].valid       = 1'b1;
      end
      // if we get a commit and no new valid instruction -> clear the valid bit
      if (csr_commit_i && ~csr_valid_i) begin
        tab_d[0].valid = 1'b0;
      end
      // clear the buffer if we flushed
      if (flush_i) tab_d[0].valid = 1'b0;
    end
  end else begin : gen_ooo
    // r33: the table is owned at DISPATCH in program order — a resource
    // released in commit order must be allocated in program order; the
    // IQ-age frontier is a filter, not the owner. disp_valid_i pulses once
    // per CSR lane at the consume edge; csr_credit_o is what the dispatch
    // group gate compares against. csr_valid_i no longer allocates: every
    // CSR granted at the FU already owns an entry (asserted below), so
    // csr_ready_o is constant-true for the IRO/arbitrer take gate.
    // Post-sweep free vector: an entry is free when invalid, dead-owner,
    // cancelled, or released by this cycle's commit. The dispatch credit
    // and the r35 parallel allocation picks both read it.
    logic [DEPTH-1:0] free_v;
    for (genvar i = 0; i < DEPTH; i++) begin : gen_free_v
      assign free_v[i] = !tab_q[i].valid
          || !sb_live_i[tab_q[i].tid]
          || cancelled_mask_i[tab_q[i].tid]
          || (csr_commit_i && (tab_q[i].tid == csr_commit_tid_i));
    end
    int unsigned free_count;
    always_comb begin
      // Credit is the popcount of the swept free vector.
      free_count = 0;
      for (int unsigned i = 0; i < DEPTH; i++)
        free_count += 32'(free_v[i]);
    end
    assign csr_credit_o = CREDIT_W'(free_count);
    // Already-allocated: the presented CSR always owns an entry.
    assign csr_ready_o = 1'b1;

    // The commit stage reads the address of the CSR it is retiring,
    // identified by trans_id -- issue order and commit order no longer
    // coincide. hyp8: the match is combinational on the live table keyed
    // by csr_commit_tid_i alone; csr_commit_i only releases the record
    // (in write_ooo below) and never gates the address.
    // r42-T item 23 (A22): the tid match is one-hot0 (a tid occupies at
    // most one table entry), so the serial last-match loop is a parallel
    // OR of exclusive arms.
    always_comb begin
      csr_addr_o = '0;
      for (int unsigned i = 0; i < DEPTH; i++)
        csr_addr_o |= (tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i))
                      ? tab_q[i].csr_address : '0;
    end

    //pragma translate_off
    logic commit_hit;
    always_comb begin
      commit_hit = 1'b0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i))
          commit_hit = 1'b1;
    end
    always_ff @(posedge clk_i) begin
      if (rst_ni && csr_commit_i) begin
        if (!commit_hit) $error("csr commit without table entry");
      end
    end
    // r42-T item 23 equivalence: parallel OR vs serial last-match.
    logic [11:0] ref_addr;
    always_comb begin
      ref_addr = '0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i))
          ref_addr = tab_q[i].csr_address;
    end
    int unsigned t2_csrb_addr_n = 0;
    always_ff @(posedge clk_i) begin
      if (rst_ni) begin
        t2_csrb_addr_n <= t2_csrb_addr_n + 1;
        g6lc_t2_csrb_addr_eq: assert (csr_addr_o === ref_addr)
          else $error("csr_buffer: equiv commit addr");
      end
    end
    //pragma translate_on

    localparam int unsigned NP = G6LCCfg.NrIssuePorts;
    logic alloc_dropped;
    logic [NP-1:0] allocated;
    int unsigned alloc_ent [NP];
    logic [NP-1:0] alloc_ok;
    // The arriving allocation is qualified against the cancel mask: a CSR
    // whose scoreboard slot is cancelled/drop-committed on the same edge
    // must not allocate — its slot is freed at that edge so the entry would
    // leak forever (r14x wedge: tid=5 never released).
`ifdef G6LC_MUT_CSRTAB_LEAK
    // Review-only mutation: the unqualified arrival — a cancelled dispatch
    // strobe still allocates a table entry.
    assign alloc_ok = disp_valid_i;
`elsif G6LC_MUT_CSRTAB_IRO_ALLOC
    // Review-only mutation (r33): allocation back at the IRO grant — a
    // younger, operand-ready CSR can take the last entry while an older
    // one stalls in the arbiter (the admission-order inversion).
    assign alloc_ok[0] = csr_valid_i && !cancelled_mask_i[fu_data_i.trans_id]
                       && !flush_i;
    if (NP > 1) assign alloc_ok[NP-1:1] = '0;
`else
    // r33: entries allocate at dispatch — the IQ consume strobes arrive in
    // lane order, so the oldest dispatched CSR always owns an entry before
    // any younger one issues.
    for (genvar p = 0; p < NP; p++) begin : gen_alloc_ok
      assign alloc_ok[p] = disp_valid_i[p] &&
          !cancelled_mask_i[disp_tid_i[p]] && !flush_i;
    end
`endif
    always_comb begin : write_ooo
      logic [DEPTH-1:0] alloc_used, rem, below;
      logic [NP-1:0][DEPTH-1:0] alloc_take;
      tab_d = tab_q;
      allocated = '0;
      alloc_used = '0;
      alloc_take = '0;
      for (int unsigned p = 0; p < NP; p++) alloc_ent[p] = 0;
`ifndef G6LC_MUT_CSRTAB_LEAK
      // Owner-liveness sweep, before release and allocation: an entry whose
      // scoreboard slot is no longer issued is dead — this covers the race
      // where the cancel mask already cleared when the stale arrival lands.
      for (int unsigned i = 0; i < DEPTH; i++)
        if (tab_d[i].valid && !sb_live_i[tab_d[i].tid])
          tab_d[i].valid = 1'b0;
`endif
      // Wrong-path squash frees the credit without a commit.
      for (int unsigned i = 0; i < DEPTH; i++)
        if (tab_d[i].valid && cancelled_mask_i[tab_d[i].tid])
          tab_d[i].valid = 1'b0;
      // Commit releases the entry whose trans_id is retiring.
      for (int unsigned i = 0; i < DEPTH; i++)
        if (csr_commit_i && tab_d[i].valid && (tab_d[i].tid == csr_commit_tid_i))
          tab_d[i].valid = 1'b0;
      // Allocate in lane order (lane 0 first) into the lowest free entries.
      // Writing tab_d in place makes the first lane's entry invisible to
      // the second, so a two-CSR group takes two distinct entries.
`ifdef G6LC_MUT_CSRTAB_IRO_ALLOC
      for (int unsigned i = 0; i < DEPTH; i++)
        if (alloc_ok[0] && !allocated[0] && !tab_d[i].valid) begin
          tab_d[i].valid       = 1'b1;
          tab_d[i].tid         = fu_data_i.trans_id;
          tab_d[i].csr_address = fu_data_i.operand_b[11:0];
          allocated[0]         = 1'b1;
          alloc_ent[0]         = i;
        end
`elsif G6LC_MUT_T1_CSRALLOC
      // Review mutation (r35): the serial in-place lane scan — the
      // pre-rewrite implementation; the parallel form below is kept as
      // the equivalence reference either way.
      for (int unsigned p = 0; p < NP; p++)
        for (int unsigned i = 0; i < DEPTH; i++)
          if (alloc_ok[p] && !allocated[p] && !tab_d[i].valid) begin
            tab_d[i].valid       = 1'b1;
            tab_d[i].tid         = disp_tid_i[p];
            tab_d[i].csr_address = disp_addr_i[p];
            allocated[p]         = 1'b1;
            alloc_ent[p]         = i;
          end
`else
      // r35: parallel free-vector allocation — each lane takes the
      // lowest free one-hot not already claimed (A140 isolate: prefix-OR
      // of the shifted vector), so the picks never serialize through
      // the table writes the way the in-place scan did.
      for (int unsigned p = 0; p < NP; p++) begin
        rem   = free_v & ~alloc_used;
        below = rem << 1;
        for (int unsigned step = 1; step < DEPTH; step <<= 1)
          below |= below << step;
        if (alloc_ok[p]) alloc_take[p] = rem & ~below;
        alloc_used |= alloc_take[p];
      end
      for (int unsigned i = 0; i < DEPTH; i++) begin
        for (int unsigned p = 0; p < NP; p++) begin
          if (alloc_take[p][i]) begin
            tab_d[i].valid       = 1'b1;
            tab_d[i].tid         = disp_tid_i[p];
            tab_d[i].csr_address = disp_addr_i[p];
            allocated[p]         = 1'b1;
            alloc_ent[p]         = i;
          end
        end
      end
`endif
      if (flush_i) begin
        for (int unsigned i = 0; i < DEPTH; i++) tab_d[i].valid = 1'b0;
      end
      // A dispatch strobe that finds no entry means the group gate let a
      // group through without credit; the gate must make this unreachable.
`ifdef G6LC_MUT_CSRTAB_LEAK
      alloc_dropped = csr_valid_i && !allocated[0] && !flush_i;
`else
      alloc_dropped = |(alloc_ok & ~allocated);
`endif
    end

    //pragma translate_off
    logic csrtab_trace;
    longint unsigned ct_cyc;
    initial csrtab_trace = 1'($test$plusargs("csrtab_trace"));
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) ct_cyc <= '0;
      else ct_cyc <= ct_cyc + 1;
    end
    always_ff @(posedge clk_i) begin
      if (rst_ni && alloc_dropped) $error("csr_buffer: CSR dispatch strobe with no free table entry");
    end
    // Every LIVE CSR granted at the FU owns a table entry — the
    // dispatch-time allocation makes the admission-order inversion
    // structurally impossible (tab_d read: post-sweep, post-alloc, so a
    // same-cycle consumer is still covered). A grant whose owner slot
    // died between dispatch and presentation is exempt: the liveness
    // sweep freed its entry and the dead op's result is dropped.
    logic [DEPTH-1:0] fu_entry;
    for (genvar i = 0; i < DEPTH; i++) begin : gen_fu_entry
      assign fu_entry[i] = tab_d[i].valid &&
                           (tab_d[i].tid == fu_data_i.trans_id);
    end
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      csr_valid_i |-> (|fu_entry) || flush_i ||
                      !sb_live_i[fu_data_i.trans_id] ||
                      cancelled_mask_i[fu_data_i.trans_id])
    else $error("csr_buffer: live CSR granted at FU with no table entry");
`ifndef G6LC_MUT_CSRTAB_LEAK
`ifndef G6LC_MUT_CSRTAB_IRO_ALLOC
    // r35 T1 equivalence (item: csr_buffer alloc): the serial in-place
    // lane scan over the swept table plus the per-entry predicate credit
    // sum — the pre-rewrite forms — recomputed as the reference every
    // cycle and compared against the live parallel-pick implementation.
    csr_ent_t ref_tab[DEPTH];
    logic [NP-1:0] ref_alloc;
    int unsigned ref_free;
    always_comb begin
      ref_tab   = tab_q;
      ref_alloc = '0;
      ref_free  = 0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (ref_tab[i].valid && !sb_live_i[ref_tab[i].tid])
          ref_tab[i].valid = 1'b0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (ref_tab[i].valid && cancelled_mask_i[ref_tab[i].tid])
          ref_tab[i].valid = 1'b0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (csr_commit_i && ref_tab[i].valid &&
            (ref_tab[i].tid == csr_commit_tid_i))
          ref_tab[i].valid = 1'b0;
      for (int unsigned p = 0; p < NP; p++)
        for (int unsigned i = 0; i < DEPTH; i++)
          if (alloc_ok[p] && !ref_alloc[p] && !ref_tab[i].valid) begin
            ref_tab[i].valid       = 1'b1;
            ref_tab[i].tid         = disp_tid_i[p];
            ref_tab[i].csr_address = disp_addr_i[p];
            ref_alloc[p]           = 1'b1;
          end
      if (flush_i)
        for (int unsigned i = 0; i < DEPTH; i++) ref_tab[i].valid = 1'b0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (!tab_q[i].valid
            || !sb_live_i[tab_q[i].tid]
            || cancelled_mask_i[tab_q[i].tid]
            || (csr_commit_i && (tab_q[i].tid == csr_commit_tid_i)))
          ref_free++;
    end
    int unsigned t1_csra_n = 0;
    always_ff @(posedge clk_i) begin : p_t1_csra_eq
      if (rst_ni) begin
        t1_csra_n <= t1_csra_n + 1;
`ifndef G6LC_MUT_T1_CSRALLOC
        g6lc_t1_csra_eq: assert (tab_d === ref_tab &&
                                 csr_credit_o === CREDIT_W'(ref_free))
          else $error("csr_buffer: equiv alloc");
`endif
      end
    end
    final begin
      if ($test$plusargs("equiv_report"))
        $display("[equiv] csr_buffer alloc: checked=%0d", t1_csra_n);
    end
`endif
`endif
`ifndef G6LC_MUT_CSRTAB_LEAK
    // A cancelled dispatch strobe allocates nothing — count it (not an
    // error). Under the IRO-alloc mutation disp_* is inert and the count
    // stays zero.
    longint unsigned ct_cancel_arrivals;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) ct_cancel_arrivals <= '0;
      else begin
        for (int unsigned p = 0; p < NP; p++)
          if (disp_valid_i[p] && !alloc_ok[p]) begin
            ct_cancel_arrivals <= ct_cancel_arrivals + 1;
            if (csrtab_trace)
              $display("[csrtab] cyc=%0d cancelled-dispatch ignored lane=%0d tid=%0d addr=%h (total=%0d)",
                       ct_cyc, p, disp_tid_i[p], disp_addr_i[p],
                       ct_cancel_arrivals + 1);
          end
      end
    end
    // Table identity: every valid entry has a live owner slot, and no two
    // entries can hold the same trans_id.
    for (genvar i = 0; i < DEPTH; i++) begin : gen_live_sva
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        tab_q[i].valid |-> sb_live_i[tab_q[i].tid])
      else $error("csr_buffer: table entry with dead owner slot");
    end
    always_ff @(posedge clk_i) begin
      if (rst_ni) begin
        for (int unsigned i = 0; i < DEPTH; i++)
          for (int unsigned j = i + 1; j < DEPTH; j++)
            if (tab_q[i].valid && tab_q[j].valid && (tab_q[i].tid == tab_q[j].tid))
              $error("csr_buffer: duplicate tid %0d in table", tab_q[i].tid);
      end
    end
`endif
    // Prints every dispatch alloc/FU grant/release/cancel-sweep/flush so a
    // leaked entry can be attributed to an unqualified cancelled strobe vs
    // a miscounted credit.
    always_ff @(posedge clk_i) begin
      if (rst_ni && csrtab_trace) begin
        for (int unsigned p = 0; p < NP; p++)
          if (disp_valid_i[p])
            $display("[csrtab] cyc=%0d disp_alloc lane=%0d tid=%0d addr=%h ent=%0d cmask=%b allocated=%b dropped=%b free=%0d tab={%b,%b}",
                     ct_cyc, p, disp_tid_i[p], disp_addr_i[p], alloc_ent[p],
                     cancelled_mask_i[disp_tid_i[p]],
                     allocated[p], alloc_dropped, free_count,
                     tab_q[0].valid, tab_q[1].valid);
        if (csr_valid_i)
          $display("[csrtab] cyc=%0d fu_grant tid=%0d entry=%b tab={%b,%b}",
                   ct_cyc, fu_data_i.trans_id, |fu_entry,
                   tab_q[0].valid, tab_q[1].valid);
        if (csr_commit_i)
          $display("[csrtab] cyc=%0d release tid=%0d hit=%b tab={%b,%b}",
                   ct_cyc, csr_commit_tid_i, commit_hit,
                   tab_q[0].valid, tab_q[1].valid);
        for (int unsigned i = 0; i < DEPTH; i++)
          if (tab_q[i].valid && cancelled_mask_i[tab_q[i].tid])
            $display("[csrtab] cyc=%0d cancel_sweep ent=%0d tid=%0d addr=%h",
                     ct_cyc, i, tab_q[i].tid, tab_q[i].csr_address);
        if (flush_i)
          $display("[csrtab] cyc=%0d flush tab={%b,%b}",
                   ct_cyc, tab_q[0].valid, tab_q[1].valid);
      end
    end
    //pragma translate_on
  end

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      for (int unsigned i = 0; i < DEPTH; i++) tab_q[i] <= csr_ent_t'('0);
    end else begin
      tab_q <= tab_d;
    end
  end

  // HypCfg currently only documents the seam (the OoO staging is
  // structural); disp_* is in-order-unused.
  logic _unused_hyp;
  assign _unused_hyp = &{1'b0, HypCfg.WbReserve} | (|sb_live_i) |
                       (|disp_valid_i) | (|disp_tid_i) | (|disp_addr_i);

endmodule
