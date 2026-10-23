// hyp8 provenance: REWRITTEN (sv-timing emit base, branch-cancel stage)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// hyp8 (group 6): scoreboard cancel kernel. Owns the mispredict
// qualification, the same-cycle younger-window membership vector, the
// combined cancelled-mask output and the per-slot sticky-cancel request
// that sb_lifecycle installs.
//
// Cancellation source: `resolved_branch_i` is the branch unit's REGISTERED
// B2 output record (branch_unit.sv group 7). The window below therefore
// opens one cycle after the resolve datapath evaluated -- with NO extra
// register in this module. `misp_outranked` qualification stays in the
// frontend redirect record; this module treats every is_mispredict record
// as authoritative.
//
// H20 semantics: a writeback that lands in the same cycle the B2 record
// resolves a mispredict belongs to an operation the mask below kills THIS
// cycle. It must not architecturally survive: sb_lifecycle installs the
// sticky cancel in the same next-state pass that installs WB results, the
// commit bundle presents the entry as a drop, and the PRF write gate
// (g6lc_prf) masks the write on the same combined mask. The mask output
// here is combinational over the registered B2 record so every consumer
// sees the kill in the resolve cycle itself.

module sb_cancel
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type sb_mem_t = logic
) (
    // Registered B2 resolve record - EX_STAGE (branch_unit)
    input  bp_resolve_t                                    resolved_branch_i,
    // Live entry array (read-only: cancelled bits + hart/keep fields)
    input  sb_mem_t [G6LCCfg.NR_SB_ENTRIES-1:0]            mem_q_i,
    // Allocation tail pointer (the window's upper bound)
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]               issue_pointer_i,
    // Same-cycle mispredict (cancel window open this cycle) - PMU/LIFECYCLE
    output logic                                          bmiss_o,
    // FSE: younger-than-branch cancel fired this cycle - PERF_COUNTERS
    output logic                                          spec_cancel_o,
    // U5 production: per-SB-slot cancel mask (sticky cancelled | same-cycle
    // bmiss window). OoO IQ/ROB/LSQ squash younger wrong-path ops without a
    // full-pipe flush.
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]              cancelled_mask_o,
    // Per-slot sticky-cancel request for the lifecycle install (already
    // hart-filtered and keep-filtered; applies only while bmiss_o).
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]              kill_req_o
);

  logic [G6LCCfg.TRANS_ID_BITS-1:0] after_flu_wb;
  // The mispredict's younger window as a membership vector: slot i lies on
  // the ring interval [after_flu_wb, issue_pointer). Both cancel walks
  // (the sticky install in sb_lifecycle and cancelled_mask_o here) used to
  // step a pointer through the ring with a data-dependent break; synthesis
  // keeps that walk serial -- a NR_SB_ENTRIES-deep chain of
  // increment/compare/decode (the mapped Nangate45 netlist: 144 cells,
  // 14.7 ns at 32 entries) -- whereas every slot's membership is two
  // compares and a mux (12 cells, 0.78 ns, 11x less area). Exact for
  // NR_SB_ENTRIES == 2**TRANS_ID_BITS (the ring the pointer arithmetic
  // already assumes): an empty interval (pointers equal) marks nothing, as
  // the walk's immediate break did.
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] bmiss_window;

  // Classic mispredict only. Cancel-younger on matching taken Jump without
  // NPC reseed kills correct target-path ops; with reseed it double-pushes
  // RAS on re-fetched calls. Taken Jump still cancels.
  // I11: B never drops a mispredict because the target looks unusable.
  // Record lifetime by slot identity: a resolve is authoritative only
  // while its own scoreboard slot is still occupied (.issued). Commit-ack
  // frees a cancelled entry by clearing .issued and .cancelled together,
  // so an in-flight B2 record that lands after its slot's retire-as-drop
  // free would otherwise read "not cancelled" on a dead TID and publish a
  // dead-context redirect (hyp8-osbi-scalar-r10, stale resolve at
  // c=967110 one edge after slot 7 freed).
`ifdef G6LC_FETCH_B
  assign bmiss_o = resolved_branch_i.valid && resolved_branch_i.is_mispredict
                   && mem_q_i[resolved_branch_i.trans_id].issued;
`else
  assign bmiss_o = resolved_branch_i.valid && resolved_branch_i.is_mispredict
                   && mem_q_i[resolved_branch_i.trans_id].issued
                   && !(G6LCCfg.NrHarts > 1 &&
                        resolved_branch_i.cf_type == g6lc_core_pkg::JumpR &&
                        !g6lc_jalr_usable::usable(
                             G6LCCfg, G6LCCfg.VLEN,
                             64'(resolved_branch_i.target_address)));
`endif
  // R3a: cancel window starts after the *branch* tid, not FLU_WB. FLU_WB can
  // be a same-cycle mult/ALU result (ex_stage lane mux) while the branch
  // still resolves -- using FLU_WB+1 then cancels older correct-path ops.
  // hyp8: resolved_branch_i is the registered B2 record, so its trans_id is
  // exactly the resolving branch's slot.
  assign after_flu_wb = resolved_branch_i.trans_id + 'd1;
  assign spec_cancel_o = bmiss_o;

  // Combinational window for the OoO recovery mask (includes the same-cycle
  // bmiss window). FSE S5: same-hart filter as the sequential cancelled
  // sticky bits. Also driven without SpeculativeSb so LSU/issue see
  // same-cycle bmiss drops.
  always_comb begin : gen_bmiss_window
    for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
      automatic logic [G6LCCfg.TRANS_ID_BITS-1:0] slot_i;
      slot_i = G6LCCfg.TRANS_ID_BITS'(i);
      bmiss_window[i] = (after_flu_wb != issue_pointer_i) &&
          ((issue_pointer_i > after_flu_wb)
               ? (slot_i >= after_flu_wb && slot_i < issue_pointer_i)
               : (slot_i >= after_flu_wb || slot_i < issue_pointer_i));
    end
  end

  // Combined mask = sticky cancelled bits | same-cycle bmiss window.
  // The same-cycle mask must match the sequential cancel policy: under
  // FETCH_B every younger same-hart entry is killed; under legacy the
  // g6lc_sb_keep exemption lists apply identically.
  always_comb begin : gen_cancelled_mask
    cancelled_mask_o = '0;
    kill_req_o       = '0;
    for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
      cancelled_mask_o[i] = mem_q_i[i].cancelled;
    end
    if (bmiss_o) begin
      for (int unsigned w = 0; w < G6LCCfg.NR_SB_ENTRIES; w++) begin
        if (!bmiss_window[w]) continue;
        // NrHarts==1 -> hart_id always 0 -> identity (cancel all younger).
        // T19: the same-hart filter is a MIXED-residency device; under the
        // drained handoff every live entry is the resident hart's, so a tag
        // mismatch could only spare a wrong-path entry.
        if (G6LCCfg.NrHarts <= 1 || G6LCCfg.SmtDrainedHandoff ||
            mem_q_i[w].sbe.hart_id == resolved_branch_i.hart_id) begin
`ifdef G6LC_FETCH_B
          cancelled_mask_o[w] = 1'b1;
          kill_req_o[w]       = 1'b1;
`else
          if (!g6lc_sb_keep::keep(
                  G6LCCfg,
                  mem_q_i[w].sbe.fu,
                  mem_q_i[w].sbe.op,
                  mem_q_i[w].sbe.rd[4:0],
                  mem_q_i[w].sbe.rs1[4:0],
                  mem_q_i[w].sbe.rs2[4:0],
                  mem_q_i[w].sbe.use_imm) &&
              !g6lc_sb_keep::keep_prefix(
                  G6LCCfg,
                  mem_q_i[w].sbe.fu,
                  mem_q_i[w].sbe.rd[4:0],
                  64'(mem_q_i[w].sbe.pc),
                  64'(resolved_branch_i.pc),
                  resolved_branch_i.cf_type)) begin
            cancelled_mask_o[w] = 1'b1;
            kill_req_o[w]       = 1'b1;
          end
`endif
        end
      end
    end
  end

endmodule
