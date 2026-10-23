// hyp8 provenance: ADAPTED (sv-timing emit base, registered-ack bundle
// protocol + deferred CSR request)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// hyp8 (group 6): one architectural retirement event per accepted
// commit. The decision still evaluates combinationally on the presented
// bundle and commit_ack_o IS that decision (fire): the scoreboard frees
// the presented slot on the same event the architectural side effects
// fire, so no suppression record is needed — a slot that cannot fire
// stays presented until it can, and a fired slot is freed at once.
//
// CSR ops keep a staged request under HypCfg.CsrReadStages: csr_op_o/
// csr_wdata_o present while a committable CSR head is at port 0 (csr_req
// requires commit_bundle_valid_i[0] too). With CsrReadStages==1 the
// csr_regfile answers in the same cycle and the seen arm is bypassed;
// with ==2 the fire waits for csr_seen_match plus the registered
// rdata_valid. csr_exception_i merges only for the owning CSR head on
// its response cycle — a non-CSR head never consumes a stale CSR
// exception.
//
// SFENCE/HFENCE/FENCE/FENCE.I drain gates are still evaluated at fire
// time, so a held head retries each cycle exactly as the emit stalled
// on the same presentation.

// NEGATIVE CONTROL (verification only, not for the design): a mutated
// copy of commit_stage that restores the pre-repair one-cycle-delayed
// commit acknowledgement (commit_ack_o registered instead of the
// common-event fire). tb_g6lc_hyp8_control drives both stages with the
// same presentation and asserts the mutation lags the fire -- so the
// leaf fails if a delayed acknowledgement is ever restored.
module mut_commit_stage_delayed
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter type exception_t = logic,
    parameter type scoreboard_entry_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Request to halt the core - CONTROLLER
    input logic halt_i,
    // request to flush dcache, also flush the pipeline - CACHE
    input logic flush_dcache_i,
    // T6b-4b: full pipeline flush (flush_ctrl_id)
    input logic flush_i,
    // TO_BE_COMPLETED - EX_STAGE
    output exception_t exception_o,
    // Mark the F state as dirty - CSR_REGFILE
    output logic dirty_fp_state_o,
    // TO_BE_COMPLETED - CSR_REGFILE
    input logic single_step_i,
    // T6b-4b: per-hart dcsr.step bits from the SMT CSR bank
    input logic [G6LCCfg.NrHarts-1:0] step_hart_i,
    // The instruction we want to commit - ISSUE_STAGE
    input scoreboard_entry_t [G6LCCfg.NrCommitPorts-1:0] commit_instr_i,
    // The instruction is cancelled - ISSUE_STAGE
    input logic [G6LCCfg.NrCommitPorts-1:0] commit_drop_i,
    input logic [G6LCCfg.NrCommitPorts-1:0] commit_replay_i,
    // Acknowledge that we are indeed committing - ISSUE_STAGE
    // hyp8: REGISTERED, returns one cycle after the decision
    output logic [G6LCCfg.NrCommitPorts-1:0] commit_ack_o,
    // Acknowledge that we are indeed committing - CSR_REGFILE
    output logic [G6LCCfg.NrCommitPorts-1:0] commit_macro_ack_o,
    // Register file write address - ISSUE_STAGE
    output logic [G6LCCfg.NrCommitPorts-1:0][4:0] waddr_o,
    // Register file write data - ISSUE_STAGE
    output logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0] wdata_o,
    // Register file write enable - ISSUE_STAGE
    output logic [G6LCCfg.NrCommitPorts-1:0] we_gpr_o,
    // SMT hart tag for RF write banking - ISSUE_STAGE
    output logic [G6LCCfg.NrCommitPorts-1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] whart_o,
    // Floating point register enable - ISSUE_STAGE
    output logic [G6LCCfg.NrCommitPorts-1:0] we_fpr_o,
    // Result of AMO operation - CACHE
    input amo_resp_t amo_resp_i,
    // TO_BE_COMPLETED - FRONTEND_CSR_REGFILE
    output logic [G6LCCfg.VLEN-1:0] pc_o,
    // Decoded CSR operation - CSR_REGFILE
    output fu_op csr_op_o,
    // Data to write to CSR - CSR_REGFILE
    output logic [G6LCCfg.XLEN-1:0] csr_wdata_o,
    // Data to read from CSR - CSR_REGFILE
    input logic [G6LCCfg.XLEN-1:0] csr_rdata_i,
    // Write the fflags CSR - CSR_REGFILE
    output logic csr_write_fflags_o,
    // Exception or interrupt occurred in CSR stage (the same as commit) - CSR_REGFILE
    input exception_t csr_exception_i,
    // hyp8 g10: registered CSR read-response valid — the csr_regfile
    // two-phase read delivers the response one cycle after the presented
    // request's csr_seen arm; the CSR fire waits for it.
    input logic csr_rdata_valid_i,
    // hyp8 g10: scoreboard commit-bundle validity (the presented slot is
    // live AND decidable this cycle) — qualifies the commit decision.
    input logic [G6LCCfg.NrCommitPorts-1:0] commit_bundle_valid_i,
    // Commit the pending store - EX_STAGE
    output logic commit_lsu_o,
    // Commit buffer of LSU is ready - EX_STAGE
    input logic commit_lsu_ready_i,
    // Transaction id of first commit port - ID_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_tran_id_o,
    // Valid AMO in commit stage - EX_STAGE
    output logic amo_valid_commit_o,
    // No store is pending - EX_STAGE
    input logic no_st_pending_i,
    // Commit the pending CSR instruction - EX_STAGE
    output logic commit_csr_o,
    // Flush I$ and pipeline - CONTROLLER
    output logic fence_i_o,
    // Flush D$ and pipeline - CONTROLLER
    output logic fence_o,
    // Request a pipeline flush - CONTROLLER
    output logic flush_commit_o,
    // A dropped entry requests refetch from its own PC (memory-order replay)
    output logic replay_o,
    // Flush TLBs and pipeline - CONTROLLER
    output logic sfence_vma_o,
    // TO_BE_COMPLETED - CONTROLLER
    output logic hfence_vvma_o,
    // TO_BE_COMPLETED - CONTROLLER
    output logic hfence_gvma_o,
    // Shared TLB is still processing a multi-cycle flush
    input logic shared_tlb_flush_busy_i,
    // Breakpoint exception from trigger module
    input logic break_from_trigger_i
);

  // AMOCAS.Q dual-write helpers. Declared ahead of gen_waddr / gen_whart
  // because both generate blocks below read them.
  logic casq_hi_pending_q, casq_hi_pending_d;
  logic [G6LCCfg.XLEN-1:0] casq_hi_data_q;
  logic [4:0] casq_hi_rd_q;
  logic casq_dual_now;
  // T6b-4b: mixed SMT residency -- the scoreboard may present a cross-hart
  // head on port 1. Drained/single-hart constant-folds to the legacy gate.
  localparam bit MixedSmt = (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;
  logic p1_cross, port0_privileged;

  assign casq_dual_now = G6LCCfg.RVA && G6LCCfg.RVZacas &&
                          amo_resp_i.dual_we && amo_resp_i.ack &&
                          (commit_instr_i[0].op == g6lc_core_pkg::AMO_CASQ);

  for (genvar i = 0; i < G6LCCfg.NrCommitPorts; i++) begin : gen_waddr
    if (i == 0) begin
      assign waddr_o[0] = casq_hi_pending_q ? casq_hi_rd_q
                                          : commit_instr_i[0].rd[4:0];
    end else if (i == 1) begin
      assign waddr_o[1] = casq_dual_now
                           ? (commit_instr_i[0].rd[4:0] | 5'b00001)
                           : commit_instr_i[1].rd[4:0];
    end else begin
      assign waddr_o[i] = commit_instr_i[i].rd;
    end
  end

  // U6.1: RF write bank = committing instruction's SMT hart (not
  // active_fetch). AMOCAS.Q dual-WB and casq_hi reuse port-0's hart.
  for (genvar i = 0; i < G6LCCfg.NrCommitPorts; i++) begin : gen_whart
    if (i == 0) begin
      assign whart_o[0] = commit_instr_i[0].hart_id;
    end else if (i == 1) begin
      assign whart_o[1] = casq_dual_now ? commit_instr_i[0].hart_id
                                        : commit_instr_i[1].hart_id;
    end else begin
      assign whart_o[i] = commit_instr_i[i].hart_id;
    end
  end

  assign pc_o = commit_instr_i[0].pc;

  assign commit_tran_id_o = commit_instr_i[0].trans_id;

  logic instr_0_is_amo;
  logic [G6LCCfg.NrCommitPorts-1:0] commit_macro_ack;
  assign instr_0_is_amo = is_amo(commit_instr_i[0].op);
  // -------------------
  // Commit Instruction
  // -------------------
  logic tlb_flush_can_commit;
  assign tlb_flush_can_commit = no_st_pending_i && !shared_tlb_flush_busy_i;

  // ------------------------------------------------------------------
  // hyp8: common retirement event. `commit_dec[p]` is the same-cycle
  // decision and commit_ack_o IS that decision — no registered echo and
  // no suppression record; a held presentation simply cannot fire, and a
  // fired slot is freed on the same event its effects used.
  // ------------------------------------------------------------------
  logic [G6LCCfg.NrCommitPorts-1:0] commit_dec, fire;
  logic [G6LCCfg.NrCommitPorts-1:0] suppress;
  // Decision-block values for the CSR request outputs (the request itself
  // is driven by csr_req; the fire re-drives the same values).
  fu_op csr_op_dec;
  logic [G6LCCfg.XLEN-1:0] csr_wdata_dec;
  logic [G6LCCfg.NrCommitPorts-1:0] commit_macro_ack_dec;

  assign suppress = '0;
  // MUTATION: the acknowledgement is registered one cycle behind the
  // fire decision (the pre-repair behaviour). The scoreboard's slot
  // free and the CSR apply therefore land a cycle late.
  logic [G6LCCfg.NrCommitPorts-1:0] mut_ack_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mut_ack_q <= '0;
    else         mut_ack_q <= fire;
  end
  assign commit_ack_o = mut_ack_q;
  assign commit_macro_ack_o = commit_macro_ack_dec;

  // ------------------------------------------------------------------
  // hyp8: CSR two-phase hold. A presented CSR head drives csr_op_o/
  // csr_wdata_o immediately (the request for the +1 csr_regfile read);
  // csr_seen_q arms so the decision can only fire the NEXT cycle, when
  // csr_rdata_i / csr_exception_i are valid for that request.
  // ------------------------------------------------------------------
  logic csr_req, csr_seen_q, csr_seen_d;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] csr_tid_q;
  logic csr_head, csr_seen_match;

  assign csr_head = (commit_instr_i[0].fu == CSR);
  // The request is driven while a committable-looking CSR head is
  // presented: valid, decidable, no instruction exception, not halted,
  // not dropped, not suppressed. Exactly the emit's commit-block
  // preconditions plus the bundle-valid presentation.
  assign csr_req = csr_head && commit_instr_i[0].valid && !halt_i &&
                   commit_bundle_valid_i[0] &&
                   !commit_instr_i[0].ex.valid && !break_from_trigger_i &&
                   !commit_drop_i[0] && !suppress[0];
  assign csr_seen_match = csr_seen_q &&
                          (commit_instr_i[0].trans_id == csr_tid_q);

  always_comb begin
    csr_seen_d = csr_req;
    // consumed by the fire; a flush clears the outstanding request
    if (fire[0] || flush_i) csr_seen_d = 1'b0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      csr_seen_q <= 1'b0;
      csr_tid_q  <= '0;
    end else begin
      csr_seen_q <= csr_seen_d;
      if (csr_req) csr_tid_q <= commit_instr_i[0].trans_id;
    end
  end

  // Bare ident. Holding a store for the LSU was a compound guard on commit_dec.
  logic store_commit_hold;
  logic commit_csr_raw;
  logic amo_is_lr;
  assign store_commit_hold = (commit_instr_i[0].fu == STORE) &&
                             !(G6LCCfg.RVA && instr_0_is_amo) && !commit_lsu_ready_i;
  assign amo_is_lr = g6lc_core_pkg::is_amo_lr(commit_instr_i[0].op);
  // The final AND used to sit at the tail of the commit block, so it
  // inherited that block. Same cycle: the pulse still tracks commit_dec[0].
  assign commit_csr_o = commit_csr_raw && commit_dec[0];

  // write register file or commit instruction in LSU or CSR Buffer
  always_comb begin : commit
    // default assignments
    commit_dec[0] = 1'b0;
    commit_macro_ack[0] = 1'b0;

    amo_valid_commit_o = 1'b0;

    we_gpr_o[0] = 1'b0;
    we_fpr_o = '{default: 1'b0};
    commit_lsu_o = 1'b0;
    commit_csr_raw = 1'b0;
    // amos will commit on port 0
    // I4ar: leftover amo_resp.ack must not substitute amo result on a
    // non-AMO retire. I4am gated casq dual_we the same way; I4ao filters
    // commit_instr.result so a stale ack would still poison RF. Only an
    // actual AMO owns this mux.
    // Half muxes. An XLEN part-select does not fold, and one 64-bit
    // priority mux was the commit head. hyp8 XLEN is 64.
    begin
      logic amo_res_sel;
      amo_res_sel = G6LCCfg.RVA && amo_resp_i.ack && instr_0_is_amo;
      unique case (amo_res_sel)
        1'b1: begin
          wdata_o[0][31:0]  = amo_resp_i.result[31:0];
          wdata_o[0][63:32] = amo_resp_i.result[63:32];
        end
        default: begin
          wdata_o[0][31:0]  = commit_instr_i[0].result[31:0];
          wdata_o[0][63:32] = commit_instr_i[0].result[63:32];
        end
      endcase
    end
    // hyp8: csr_op_o/csr_wdata_o are driven by csr_req (the two-phase
    // request), not inside the commit block; the block's values go to
    // the dec signals selected below.
    csr_op_dec = ADD;  // this corresponds to a CSR NOP
    csr_wdata_dec = {G6LCCfg.XLEN{1'b0}};
    fence_i_o = 1'b0;
    fence_o = 1'b0;
    sfence_vma_o = 1'b0;
    hfence_vvma_o = 1'b0;
    hfence_gvma_o = 1'b0;
    csr_write_fflags_o = 1'b0;
    flush_commit_o = 1'b0;
    replay_o = 1'b0;
    p1_cross = 1'b0;
    port0_privileged = 1'b0;

    // SpeculativeSb: drop cancelled entries with no architectural
    // side-effects. Must not wait on LSU/AMO readiness.
    if (commit_drop_i[0] && !halt_i && !suppress[0]) begin
      commit_dec[0] = 1'b1;
      if (commit_replay_i[0]) begin
        flush_commit_o = 1'b1;
        replay_o = 1'b1;
      end
      // A dropped entry is squashed: it performs no architectural write.
    end else if (commit_instr_i[0].valid && commit_bundle_valid_i[0] &&
                 !halt_i && !suppress[0] &&
                 // hyp8: a CSR head enters the commit block only once the
                 // csr_regfile response is live for its request —
                 // same-cycle under CsrReadStages==1, or the armed seen
                 // record plus the registered response under ==2.
                 (!csr_head || ((HypCfg.CsrReadStages == 1 || csr_seen_match) &&
                                csr_rdata_valid_i))) begin
      // we will not commit the instruction if we took an exception
      if (commit_instr_i[0].ex.valid || break_from_trigger_i) begin
        // Exception without drop: hold until exception handling
      end else begin
        commit_dec[0] = 1'b1;

        if (G6LCCfg.RVZCMP && commit_instr_i[0].is_macro_instr && commit_instr_i[0].is_last_macro_instr)
          commit_macro_ack[0] = 1'b1;
        else commit_macro_ack[0] = 1'b0;

        // we can definitely write the register file
        if (G6LCCfg.FpPresent && g6lc_core_pkg::is_rd_fpr(commit_instr_i[0].op)) begin
          we_fpr_o[0] = 1'b1;
        end else begin
          we_gpr_o[0] = 1'b1;
        end

        // check whether the instruction we retire was a store
        if (store_commit_hold) begin
          commit_dec[0] = 1'b0;
        end else if (commit_instr_i[0].fu == STORE && !(G6LCCfg.RVA && instr_0_is_amo)) begin
          commit_lsu_o = 1'b1;
        end
        // ---------
        // FPU Flags
        // ---------
        if (G6LCCfg.FpPresent) begin
          if (commit_instr_i[0].fu inside {FPU, FPU_VEC}) begin
            // write the CSR with potential exception flags from retiring
            // floating point instruction
            csr_wdata_dec = {{G6LCCfg.XLEN - 5{1'b0}}, commit_instr_i[0].ex.cause[4:0]};
            csr_write_fflags_o = 1'b1;
          end
        end
        // ---------
        // CSR Logic
        // ---------
        // check whether the instruction we retire was a CSR instruction
        // and it did not throw an exception
        // hyp8: runs on the fire cycle (csr_seen_match); csr_rdata_i /
        // csr_exception_i are live for the request presented last cycle.
        if (csr_head) begin
          // write the CSR file (the request itself is driven outside)
          csr_op_dec    = commit_instr_i[0].op;
          csr_wdata_dec = commit_instr_i[0].result;
          if (!csr_exception_i.valid) begin
            commit_csr_raw = 1'b1;
            wdata_o[0]   = csr_rdata_i;
            if (G6LCCfg.OoOEn && commit_instr_i[0].op == WFI) flush_commit_o = 1'b1;
          end else begin
            commit_dec[0] = 1'b0;
            we_gpr_o[0] = 1'b0;
          end
        end
        // ------------------
        // SFENCE.VMA Logic
        // ------------------
        // sfence.vma is idempotent so we can safely re-execute it after
        // returning from interrupt service routine
        if (G6LCCfg.RVS && commit_instr_i[0].op == SFENCE_VMA) begin
          // no store pending so we can flush the TLBs and pipeline
          sfence_vma_o = tlb_flush_can_commit;
          commit_dec[0] = tlb_flush_can_commit;
        end
        // ------------------
        // HFENCE.VVMA Logic
        // ------------------
        if (G6LCCfg.RVH && commit_instr_i[0].op == HFENCE_VVMA) begin
          hfence_vvma_o   = tlb_flush_can_commit;
          commit_dec[0] = tlb_flush_can_commit;
        end
        // ------------------
        // HFENCE.GVMA Logic
        // ------------------
        if (G6LCCfg.RVH && commit_instr_i[0].op == HFENCE_GVMA) begin
          hfence_gvma_o   = tlb_flush_can_commit;
          commit_dec[0] = tlb_flush_can_commit;
        end
        // ------------------
        // FENCE.I Logic
        // ------------------
        // fence.i is idempotent so we can safely re-execute it after
        // returning from interrupt service routine
        if (commit_instr_i[0].op == FENCE_I || (flush_dcache_i && G6LCCfg.DCacheType == config_pkg::WB && commit_instr_i[0].fu != STORE)) begin
          commit_dec[0] = no_st_pending_i;
          fence_i_o = no_st_pending_i;
        end
        // ------------------
        // FENCE Logic
        // ------------------
        // fence is idempotent so we can safely re-execute it after
        // returning from interrupt service routine
        if (commit_instr_i[0].op == FENCE) begin
          commit_dec[0] = no_st_pending_i;
          fence_o = no_st_pending_i;
        end
        // ------------------
        // AMO
        // ------------------
        if (G6LCCfg.RVA && instr_0_is_amo) begin
          // AMO finished (AMOCAS.Q may dual-write rd and rd+1)
          // Hold amo_valid while dual_we pulse OR while finishing hi
          // write on 1-port.
          amo_valid_commit_o = 1'b1;
          // hyp8 RVZacas is 0. The dual-write arm does not fold and its
          // XLEN result slice was on the commit cone.
          commit_dec[0] = amo_resp_i.ack;
          // Soft-ladder B1 (b1-lrsc-cmpxchg): do NOT flush after LR.
          if (!amo_is_lr) begin
            flush_commit_o = amo_resp_i.ack;
          end
          we_gpr_o[0] = amo_resp_i.ack;
        end

        // The OoO csr_buffer frees an entry on each csr_commit_i pulse,
        // so the pulse must coincide with the real commit: FENCE/SFENCE
        // hold the head for store/TLB drain and would otherwise re-fire
        // the release on an already-freed entry.
        // commit_csr_o is commit_csr_raw && commit_dec[0], outside this block.
      end
    end

    if (G6LCCfg.NrCommitPorts > 1) begin
      commit_macro_ack[1] = 1'b0;
      commit_dec[1]     = 1'b0;
      // Preserve AMOCAS.Q dual-write on port1 (set above when
      // casq_dual_now)
      if (!(G6LCCfg.RVZacas && casq_dual_now)) begin
        we_gpr_o[1] = 1'b0;
        wdata_o[1]  = commit_instr_i[1].result;
      end

      // T6b-4b: under mixed residency the scoreboard may present a
      // cross-hart head on port 1. A presented port-0 entry that can
      // raise a commit-level flush, exception, replay or trigger break
      // ("flush-capable-privileged") blocks the cross-hart commit.
      p1_cross = MixedSmt && (commit_instr_i[1].hart_id != commit_instr_i[0].hart_id);
      port0_privileged = (commit_instr_i[0].fu inside {CSR}) ||
                         commit_instr_i[0].ex.valid ||
                         commit_replay_i[0] ||
                         (G6LCCfg.RVA && instr_0_is_amo) ||
                         break_from_trigger_i;
      // The exclusion must be ack-qualified, not presentation-qualified:
      // a privileged head that cannot yet commit flushes nothing this
      // cycle, and holding port 1 behind it deadlocks the ring. Only a
      // privileged port-0 fire can raise a commit-level flush.
      port0_privileged = port0_privileged && commit_dec[0];

      // -----------------
      // Commit Port 2
      // -----------------
      // check if the second instruction can be committed as well and the
      // first wasn't a CSR instruction; also if we are in single step
      // mode don't retire the second instruction
      if (!p1_cross && commit_dec[0] && commit_instr_i[1].valid
                                && commit_bundle_valid_i[1]
                                && !halt_i
                                && !suppress[1]
                                && !commit_replay_i[0] && !commit_replay_i[1]
                                && !(commit_instr_i[0].fu inside {CSR})
                                && !flush_dcache_i
                                && !(G6LCCfg.RVA && instr_0_is_amo)
                                && !single_step_i
                                && (!MixedSmt ||
                                    (commit_instr_i[1].trans_id != commit_instr_i[0].trans_id))) begin
        // only if the first instruction didn't throw an exception and
        // this instruction won't throw an exception and the functional
        // unit is of type ALU, LOAD, CTRL_FLOW, MULT, FPU or FPU_VEC
        if (!commit_instr_i[1].ex.valid && (commit_instr_i[1].fu inside {ALU, LOAD, CTRL_FLOW, MULT, FPU, FPU_VEC})) begin

          if (G6LCCfg.RVZCMP && commit_instr_i[1].is_macro_instr && commit_instr_i[1].is_last_macro_instr)
            commit_macro_ack[1] = 1'b1;
          else commit_macro_ack[1] = 1'b0;

          commit_dec[1] = 1'b1;

          // Port-1 squash is the port-0 rule: a dropped entry writes
          // nothing.
          if (!commit_drop_i[1]) begin
            if (G6LCCfg.FpPresent && g6lc_core_pkg::is_rd_fpr(commit_instr_i[1].op))
              we_fpr_o[1] = 1'b1;
            else we_gpr_o[1] = 1'b1;

            // additionally check if we are retiring an FPU instruction
            // because we need to make sure that we write all exception
            // flags
            if (G6LCCfg.FpPresent) begin
              if (commit_instr_i[1].fu inside {FPU, FPU_VEC}) begin
                if (csr_write_fflags_o)
                  csr_wdata_dec = {
                    {G6LCCfg.XLEN - 5{1'b0}},
                    (commit_instr_i[0].ex.cause[4:0] | commit_instr_i[1].ex.cause[4:0])
                  };
                else csr_wdata_dec = {{G6LCCfg.XLEN - 5{1'b0}}, commit_instr_i[1].ex.cause[4:0]};
                csr_write_fflags_o = 1'b1;
              end
            end
          end
        end
      end else if (p1_cross && commit_instr_i[1].valid
                                && commit_bundle_valid_i[1]
                                && !halt_i
                                && !suppress[1]
                                && !commit_replay_i[1]
                                && !commit_instr_i[1].ex.valid
                                && (commit_instr_i[1].fu inside {ALU, LOAD, CTRL_FLOW, MULT})
                                && !flush_dcache_i
                                && !step_hart_i[commit_instr_i[1].hart_id]
                                && !port0_privileged
                                && !flush_i
                                && (commit_instr_i[1].trans_id != commit_instr_i[0].trans_id)) begin
        // T6b-4b cross-hart head: simple, complete, non-speculative-
        // restart class only.
        if (G6LCCfg.RVZCMP && commit_instr_i[1].is_macro_instr && commit_instr_i[1].is_last_macro_instr)
          commit_macro_ack[1] = 1'b1;
        else commit_macro_ack[1] = 1'b0;

        commit_dec[1] = 1'b1;

        if (!commit_drop_i[1]) begin
          if (G6LCCfg.FpPresent && g6lc_core_pkg::is_rd_fpr(commit_instr_i[1].op))
            we_fpr_o[1] = 1'b1;
          else we_gpr_o[1] = 1'b1;
        end
      end
    end
    // No commit-stage value filter lives here (see the emit note: a
    // result-conditioned write is speculation visibility channel 5 and is
    // not expressible over any closed tuple).
    //
    // AMOCAS.Q is the one legitimate waddr retarget: on a single commit
    // port the held hi destination drives waddr_o[0] a cycle after the
    // AMO retired, so an ordinary retire in that cycle would write the
    // AMO's destination with its own result.
    if (G6LCCfg.RVA && G6LCCfg.RVZacas && casq_hi_pending_q && !instr_0_is_amo)
      we_gpr_o[0] = 1'b0;

    // hyp8: fire = decision, masked for CSR-first-presentation and
    // same-tid suppression (both already folded into the block enable).
    fire = commit_dec;

    if (G6LCCfg.RVZCMP) begin
      for (int i = 0; i < G6LCCfg.NrCommitPorts; i++) begin
        commit_macro_ack_dec[i] = commit_instr_i[i].is_macro_instr ? commit_macro_ack[i] : commit_dec[i];
      end
    end else commit_macro_ack_dec = commit_dec;
  end

  // commit_macro_ack_o is the same-cycle macro/last-instr decision folded
  // into the common event (assigned beside commit_ack_o above).

  // Dirty the FP state if we are committing anything related to the FPU
  // hyp8: keyed on the same-cycle fire (the architectural event), not on
  // the registered ack echo.
  always_comb begin : dirty_fp_state
    dirty_fp_state_o = 1'b0;
    for (int i = 0; i < G6LCCfg.NrCommitPorts; i++) begin
      dirty_fp_state_o |= fire[i] & ((commit_instr_i[i].fu inside {FPU, FPU_VEC} & G6LCCfg.FpPresent & g6lc_core_pkg::fd_changes_rd_state(
          commit_instr_i[i].op
      )) || (G6LCCfg.FpPresent && g6lc_core_pkg::is_rd_fpr(
          commit_instr_i[i].op
      ))) | (commit_instr_i[i].fu == ACCEL && commit_instr_i[i].vfp);
    end
  end

  // -----------------------------
  // Exception & Interrupt Logic
  // -----------------------------
  // here we know for sure that we are taking the exception
  always_comb begin : exception_handling
    exception_o.valid = 1'b0;
    exception_o.cause = '0;
    exception_o.tval  = '0;
    exception_o.tval2 = '0;
    exception_o.tinst = '0;
    exception_o.gva   = 1'b0;

    // we need a valid instruction in the commit stage
    if (commit_instr_i[0].valid && !commit_drop_i[0] && !suppress[0]) begin
      // ------------------------
      // check for CSR exception
      // ------------------------
      // hyp8: csr_exception_i is only meaningful on the CSR head's
      // response cycle — a non-CSR head must never consume a stale CSR
      // exception, so the merge requires csr_head plus the live response.
      if (csr_exception_i.valid && csr_head && csr_rdata_valid_i &&
          (HypCfg.CsrReadStages == 1 || csr_seen_match)) begin
        exception_o      = csr_exception_i;
        // if no earlier exception happened the commit instruction will
        // still contain the instruction bits from the ID stage.
        exception_o.tval = commit_instr_i[0].ex.tval;
        if (G6LCCfg.RVH) begin
          exception_o.tinst = commit_instr_i[0].ex.tinst;
          exception_o.tval2 = commit_instr_i[0].ex.tval2;
          exception_o.gva   = commit_instr_i[0].ex.gva;
        end
      end
      // ------------------------
      // Earlier Exceptions
      // ------------------------
      if (commit_instr_i[0].ex.valid) begin
//pragma translate_off
        if ($time() < 200000)
          $display("[commit-dbg] t=%0t pc=%h ex.valid=%b cause=%0d", $time, commit_instr_i[0].pc, commit_instr_i[0].ex.valid, commit_instr_i[0].ex.cause);
//pragma translate_on
        exception_o = commit_instr_i[0].ex;
      end
    end
    // Don't take any exceptions iff:
    // - If we halted the processor
    if (halt_i) begin
      exception_o.valid = 1'b0;
    end

    if (G6LCCfg.SDTRIG && !G6LCCfg.DebugEn && break_from_trigger_i) begin
      exception_o.valid = 1'b1;
      exception_o.cause = G6LCCfg.XLEN'(32'h00000003);
    end
  end

  always_comb begin
    casq_hi_pending_d = 1'b0;
    if (G6LCCfg.RVA && G6LCCfg.RVZacas && G6LCCfg.NrCommitPorts == 1) begin
      // Arm one cycle after dual_we/ack so hi write runs when resp pulse
      // is gone
      if (amo_resp_i.ack && amo_resp_i.dual_we && !casq_hi_pending_q)
        casq_hi_pending_d = 1'b1;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      casq_hi_pending_q <= 1'b0;
      casq_hi_data_q    <= '0;
      casq_hi_rd_q      <= '0;
    end else begin
      casq_hi_pending_q <= casq_hi_pending_d;
      if (amo_resp_i.ack && amo_resp_i.dual_we) begin
        casq_hi_data_q <= amo_resp_i.result_hi[G6LCCfg.XLEN-1:0];
        casq_hi_rd_q   <= commit_instr_i[0].rd[4:0] | 5'b00001;
      end
    end
  end

  // hyp8: csr_op_o/csr_wdata_o drive the request while the CSR head is
  // presented (the +1 csr_regfile answers next cycle; the fire then
  // re-drives them inside the commit block).
  always_comb begin
    if (csr_req) begin
      csr_op_o    = commit_instr_i[0].op;
      csr_wdata_o = commit_instr_i[0].result;
    end else begin
      csr_op_o    = csr_op_dec;
      csr_wdata_o = csr_wdata_dec;
    end
  end

endmodule
