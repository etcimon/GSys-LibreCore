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
// Date: 08.04.2017
// Description: Scoreboard - keeps track of all decoded, issued and committed instructions

module scoreboard #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type exception_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type forwarding_t = logic,
    parameter type writeback_t = logic,
    parameter type rs3_len_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input  logic                                          clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                                          rst_ni,
    // Is scoreboard full - PERF_COUNTERS
    output logic                                          sb_full_o,
    // FSE: younger-than-branch cancel fired this cycle (SpeculativeSb path) - PERF
    output logic                                          spec_cancel_o,
    // U5 production: per-SB-slot cancel mask (sticky cancelled | same-cycle bmiss window)
    // OoO IQ/ROB/LSQ squash younger wrong-path ops without full-pipe flush.
    output logic [CVA6Cfg.NR_SB_ENTRIES-1:0]              cancelled_mask_o,
    // Prevent from issuing - CONTROLLER
    input  logic                                          flush_unissued_instr_i,
    // Flush whole scoreboard - CONTROLLER
    input  logic                                          flush_i,
    // Writeback Handling of CVXIF
    // TO_BE_COMPLETED - ISSUE_READ_OPERANDS
    input  logic                                          x_transaction_accepted_i,
    // TO_BE_COMPLETED - ISSUE_READ_OPERANDS
    input  logic                                          x_issue_writeback_i,
    // TO_BE_COMPLETED - ISSUE_READ_OPERANDS
    input  logic              [CVA6Cfg.TRANS_ID_BITS-1:0] x_id_i,
    // advertise instruction to commit stage, if commit_ack_i is asserted advance the commit pointer
    // Instructions to commit - COMMIT_STAGE
    output scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0] commit_instr_o,
    // Instruction is cancelled - COMMIT_STAGE
    output logic              [CVA6Cfg.NrCommitPorts-1:0] commit_drop_o,
    // Commit acknowledge - COMMIT_STAGE
    input  logic              [CVA6Cfg.NrCommitPorts-1:0] commit_ack_i,

    // instruction to put on top of scoreboard e.g.: top pointer
    // we can always put this instruction to the top unless we signal with asserted full_o
    // Handshake's data with decode stage - ID_STAGE
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       decoded_instr_i,
    // instruction value - ID_STAGE
    input  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    // Handshake's valid with decode stage - ID_STAGE
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]       decoded_instr_valid_i,
    // Handshake's acknowledge with decode stage - ID_STAGE
    output logic              [CVA6Cfg.NrIssuePorts-1:0]       decoded_instr_ack_o,

    // instruction to issue logic, if issue_instr_valid and issue_ready is asserted, advance the issue pointer
    // Entry about the instruction to issue - ISSUE_READ_OPERANDS
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       issue_instr_o,
    // Instruction to issue - ISSUE_READ_OPERANDS
    output logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_o,
    // Is there an instruction to issue - ISSUE_READ_OPERANDS
    output logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_instr_valid_o,
    // Issue stage acknowledge - ISSUE_READ_OPERANDS
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_ack_i,
    // Forwarding - ISSUE_READ_OPERANDS
    output forwarding_t                                        fwd_o,

    // Result from branch unit - EX_STAGE
    input bp_resolve_t resolved_branch_i,
    // Transaction ID at which to write the result back - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_i,
    // Results to write back - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0] wbdata_i,
    // Exception from a functional unit (e.g.: ld/st exception) - EX_STAGE
    input exception_t [CVA6Cfg.NrWbPorts-1:0] ex_i,
    // Indicates valid results - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0] wt_valid_i,
    // Cvxif we for writeback - EX_STAGE
    input logic x_we_i,
    // CVXIF destination register - ISSUE_STAGE
    input logic [4:0] x_rd_i,

    // Issue pointer - RVFI
    output logic [ CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_issue_pointer_o,
    // Commit pointer - RVFI
    output logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_commit_pointer_o,
    // G1mf: result-valid aligned-00 RVI
    // LOAD (issued, not cancelled) for
    // ID g1lo. Flop only — not G1lm.
    output logic [CVA6Cfg.NrHarts-1:0] g1mf_v_o,
    output logic [CVA6Cfg.NrHarts-1:0][4:0] g1mf_rd_o,
    output logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1mf_line_o,
    output logic [CVA6Cfg.NrHarts-1:0] g1mf_a3_o
);

  // this is the FIFO struct of the issue queue
  typedef struct packed {
    logic issued;  // this bit indicates whether we issued this instruction e.g.: if it is valid
    logic cancelled;  // this instruction was cancelled (speculative scoreboard)
    logic is_rd_fpr_flag;  // redundant meta info, added for speed
    scoreboard_entry_t sbe;  // this is the score board entry we will send to ex
  } sb_mem_t;
  sb_mem_t [CVA6Cfg.NR_SB_ENTRIES-1:0] mem_q, mem_n;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] still_issued;

  logic [CVA6Cfg.NrIssuePorts-1:0] issue_full;

  logic bmiss;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] after_flu_wb;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] speculative_instrs;

  logic [CVA6Cfg.NrIssuePorts-1:0] num_issue;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] issue_pointer_n, issue_pointer_q;
  logic [CVA6Cfg.NrIssuePorts:0][CVA6Cfg.TRANS_ID_BITS-1:0] issue_pointer;

  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] commit_pointer_n, commit_pointer_q;
  logic [$clog2(CVA6Cfg.NrCommitPorts):0] num_commit;

  // Free-slot count for N-wide issue (port k needs k+1 free entries).
  logic [$clog2(CVA6Cfg.NR_SB_ENTRIES+1)-1:0] sb_issued_cnt, sb_free_cnt;

  for (genvar i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
    assign still_issued[i] = mem_q[i].issued & ~mem_q[i].cancelled;
  end

  always_comb begin
    sb_issued_cnt = '0;
    for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
      if (mem_q[i].issued) sb_issued_cnt += 1'b1;
    end
    sb_free_cnt = $clog2(CVA6Cfg.NR_SB_ENTRIES+1)'(CVA6Cfg.NR_SB_ENTRIES) - sb_issued_cnt;
  end

  // Port i is full when fewer than (i+1) free scoreboard slots remain.
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : gen_issue_full
    assign issue_full[i] = sb_free_cnt < $clog2(CVA6Cfg.NR_SB_ENTRIES+1)'(i + 1);
  end

  assign sb_full_o = issue_full[0];

  // output commit instruction directly
  always_comb begin : commit_ports
    for (int unsigned i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin
      commit_instr_o[i] = mem_q[commit_pointer_q[i]].sbe;
      commit_instr_o[i].trans_id = commit_pointer_q[i];
      commit_drop_o[i] = mem_q[commit_pointer_q[i]].cancelled;
    end
  end

  assign issue_pointer[0] = issue_pointer_q;
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assign issue_pointer[i+1] = issue_pointer[i] + 'd1;
  end

  // an instruction is ready for issue if we have place in the issue FIFO and the decoder says it is valid
  always_comb begin
    issue_instr_o = decoded_instr_i;
    orig_instr_o  = orig_instr_i;
    for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      // make sure we assign the correct trans ID
      issue_instr_o[i].trans_id = issue_pointer[i];

      issue_instr_valid_o[i]    = decoded_instr_valid_i[i] & ~issue_full[i];
      decoded_instr_ack_o[i]    = issue_ack_i[i] & ~issue_full[i];
    end
  end

  // maintain a FIFO with issued instructions
  // keep track of all issued instructions
  always_comb begin : issue_fifo
    // default assignment
    mem_n     = mem_q;
    num_issue = '0;

    // if we got an acknowledge from the issue stage, put this scoreboard entry in the queue
    for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      // G1t: link-jal is not unissued fallthrough. IRO flush_i is
      // flush_unissued — without this the jal is popped and never
      // allocated (mini P6 0x65). SI: alloc is !flush_unissued.
      if (decoded_instr_valid_i[i] && decoded_instr_ack_o[i] &&
          g6lc_sb_keep::alloc(
              CVA6Cfg,
              flush_unissued_instr_i,
              decoded_instr_i[i].fu,
              decoded_instr_i[i].rd[4:0])) begin
        // the decoded instruction we put in there is valid (1st bit)
        // increase the issue counter and advance issue pointer
        num_issue += 'd1;
        mem_n[issue_pointer[i]] = '{
            issued: 1'b1,
            cancelled: 1'b0,
            is_rd_fpr_flag: CVA6Cfg.FpPresent && ariane_pkg::is_rd_fpr(decoded_instr_i[i].op),
            sbe: decoded_instr_i[i]
        };
        // Clear OoO tags at SB alloc (dispatch renames later when OoOEn)
        mem_n[issue_pointer[i]].sbe.p_rs1 = '0;
        mem_n[issue_pointer[i]].sbe.p_rs2 = '0;
        mem_n[issue_pointer[i]].sbe.p_rd  = '0;
        mem_n[issue_pointer[i]].sbe.ooo_renamed = 1'b0;
        // G1v: link-jal result is pc+ilen, not the J-imm. Flu may still
        // overwrite. SMT+SS only. SI: result stays the immediate.
        if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
            g6lc_sb_keep::link_jal(
                CVA6Cfg.SuperscalarEn,
                decoded_instr_i[i].fu,
                decoded_instr_i[i].rd[4:0])) begin
          mem_n[issue_pointer[i]].sbe.result = g6lc_sb_keep::link(
              64'(decoded_instr_i[i].pc),
              decoded_instr_i[i].is_compressed);
          // G1x: retire pc+ilen without waiting for flu. EX still
          // resolves the jump. SI: valid stays 0 until WB.
          mem_n[issue_pointer[i]].sbe.valid = 1'b1;
        end
      end
    end

    // ------------
    // FU NONE
    // ------------
    for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
      // The FU is NONE -> this instruction is valid immediately
      if (mem_q[i].sbe.fu == ariane_pkg::NONE && mem_q[i].issued) mem_n[i].sbe.valid = 1'b1;
    end

    // ------------
    // Write Back
    // ------------
    for (int unsigned i = 0; i < CVA6Cfg.NrWbPorts; i++) begin
      // check if this instruction was issued (e.g.: it could happen after a flush that there is still
      // something in the pipeline e.g. an incomplete memory operation)
      if (wt_valid_i[i] && mem_q[trans_id_i[i]].issued) begin
        if (mem_q[trans_id_i[i]].sbe.is_double_rd_macro_instr && mem_q[trans_id_i[i]].sbe.is_macro_instr) begin
          if (mem_q[trans_id_i[i]].sbe.is_last_macro_instr) begin
            mem_n[trans_id_i[i]].sbe.valid = 1'b1;
            mem_n[8'(trans_id_i[i])-1].sbe.valid = 1'b1;
          end else begin
            mem_n[trans_id_i[i]].sbe.valid = 1'b0;
          end
        end else begin
          mem_n[trans_id_i[i]].sbe.valid = 1'b1;
        end
        // G1w: flu of a link-jal sets valid (above) but must not replace
        // G1v's alloc-time pc+ilen with a stale next_pc (mini P6 0x14c).
        // SI / no-link: take wbdata (identity).
        if (!g6lc_sb_keep::keep_alloc_link(
                CVA6Cfg,
                mem_q[trans_id_i[i]].sbe.fu,
                mem_q[trans_id_i[i]].sbe.rd[4:0],
                64'(mem_q[trans_id_i[i]].sbe.result)))
          mem_n[trans_id_i[i]].sbe.result = wbdata_i[i];
        // save the target address of a branch (needed for debug in commit stage)
        if (CVA6Cfg.DebugEn) begin
          mem_n[trans_id_i[i]].sbe.bp.predict_address = resolved_branch_i.target_address;
        end
        if (mem_n[trans_id_i[i]].sbe.fu == ariane_pkg::CVXIF) begin
          if (x_we_i) mem_n[trans_id_i[i]].sbe.rd = x_rd_i;
          else mem_n[trans_id_i[i]].sbe.rd = 5'b0;
        end
        // write the exception back if it is valid
        if (ex_i[i].valid) mem_n[trans_id_i[i]].sbe.ex = ex_i[i];
        // write the fflags back from the FPU (exception valid is never set), leave tval intact
        else if(CVA6Cfg.FpPresent && (mem_q[trans_id_i[i]].sbe.fu == ariane_pkg::FPU || mem_q[trans_id_i[i]].sbe.fu == ariane_pkg::FPU_VEC)) begin
          mem_n[trans_id_i[i]].sbe.ex.cause = ex_i[i].cause;
        end
      end
    end

    // ------------
    // Cancel (U5.0: cancel younger than the mispredicted branch)
    // FSE S5: when NrHarts>1 only cancel same-hart younger ops so a peer
    // hart's in-flight window survives the mispredict isolation.
    // ------------
    // Circular window [after_flu_wb, issue_pointer[0]) — not just one entry.
    // Required for precise speculative recovery before full rename/ROB (U5.1+).
    // Hang-7: also cancel on the classic (!SpeculativeSb) path. flush_unissued
    // alone does not drop already-issued wrong-path ops (e.g. post-ret alias
    // jal); commit_drop of cancelled entries has no RF/LSU side-effects.
    if (bmiss) begin
      automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] cid;
      cid = after_flu_wb;
      for (int unsigned k = 0; k < CVA6Cfg.NR_SB_ENTRIES; k++) begin
        if (cid == issue_pointer[0]) break;
        // NrHarts==1 → hart_id always 0 → identity (cancel all younger).
        if (CVA6Cfg.NrHarts <= 1 ||
            mem_q[cid].sbe.hart_id == resolved_branch_i.hart_id) begin
          // Younger-cancel policy (soft-ladder iter-012 / hang-6–7 / R3a cont.5):
          //
          // Historical cont.5: *never* cancel LOAD — a cancelled ld s4 in
          // fdt_getprop left RF as a3 after a *false* cancel window that used
          // FLU_WB tid (wrong). after_flu_wb is now branch-tid based (below),
          // so correct-path epilogue loads re-issue after mispredict reseed.
          //
          // Soft-ladder PEEL_FDT_GETPROP (mepc=0x12eb2 mcause=6 mtval=0x12b2a):
          // under SuperscalarEn, wrong-path LOADs after RAS-miss / JAL still
          // RF-write when not cancelled — callee-saved s2/s3 observed holding
          // the check_node→next_tag *link* (ra residue) or 0. Prefer cancel of
          // younger LOADs on DI; SI keeps cont.5 exemption for legacy soaks.
          //
          // STORE/AMO still cancel (STQ / amo_buffer.cancel_i). Mark complete
          // so commit can drop without waiting for WB.
          // NrHarts>1: same-hart filter above preserves peer SMT windows.
          //
          // EXTRACT E0: keep predicate lives in g6lc_sb_keep (I4m–cf).
          // Do not add G0 here. SI still cont.5 LOAD-only keep.
          if (!g6lc_sb_keep::keep(
                  CVA6Cfg,
                  mem_q[cid].sbe.fu,
                  mem_q[cid].sbe.op,
                  mem_q[cid].sbe.rd[4:0],
                  mem_q[cid].sbe.rs1[4:0],
                  mem_q[cid].sbe.rs2[4:0],
                  mem_q[cid].sbe.use_imm) &&
              !g6lc_sb_keep::keep_prefix(
                  CVA6Cfg,
                  mem_q[cid].sbe.fu,
                  mem_q[cid].sbe.rd[4:0],
                  64'(mem_q[cid].sbe.pc),
                  64'(resolved_branch_i.pc),
                  resolved_branch_i.cf_type)) begin
            mem_n[cid].cancelled = 1'b1;
            mem_n[cid].sbe.valid = 1'b1;
          end
        end
        cid = cid + 1'b1;
      end
    end

    // ------------
    // Commit Port
    // ------------
    // we've got an acknowledge from commit
    for (int i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin
      if (commit_ack_i[i]) begin
        // this instruction is no longer in issue e.g.: it is considered finished
        mem_n[commit_pointer_q[i]].issued    = 1'b0;
        mem_n[commit_pointer_q[i]].cancelled = 1'b0;
        mem_n[commit_pointer_q[i]].sbe.valid = 1'b0;
      end
    end

    // ------
    // Flush
    // ------
    if (flush_i) begin
      for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
        // set all valid flags for all entries to zero
        mem_n[i].issued       = 1'b0;
        mem_n[i].cancelled    = 1'b0;
        mem_n[i].sbe.valid    = 1'b0;
        mem_n[i].sbe.ex.valid = 1'b0;
      end
    end
  end

  // Classic mispredict only. Cancel-younger on matching taken Jump without
  // NPC reseed kills correct target-path ops; with reseed it double-pushes
  // RAS on re-fetched calls. Hang-6 residual needs selective fallthrough kill.
  // EXTRACT E2: JALR-to-unusable is not a bmiss. Taken Jump still cancels.
  // I11: B never drops a mispredict because the target looks unusable.
`ifdef G6LC_FETCH_B
  assign bmiss = resolved_branch_i.valid && resolved_branch_i.is_mispredict;
`else
  assign bmiss = resolved_branch_i.valid && resolved_branch_i.is_mispredict
                 && !(CVA6Cfg.NrHarts > 1 &&
                      resolved_branch_i.cf_type == ariane_pkg::JumpR &&
                      !g6lc_jalr_usable::usable(
                           CVA6Cfg, CVA6Cfg.VLEN,
                           64'(resolved_branch_i.target_address)));
`endif
  // R3a: cancel window starts after the *branch* tid, not FLU_WB. FLU_WB can
  // be a same-cycle mult/ALU result (ex_stage flu mux) while the branch still
  // resolves — using FLU_WB+1 then cancels older correct-path ops (frame SDs).
  assign after_flu_wb = resolved_branch_i.trans_id + 'd1;
  // Younger cancel on mispredict (U5.0 / FSE / hang-7 classic path) — PMU g3
  assign spec_cancel_o = bmiss;

  // Combinational cancel mask for OoO recovery (includes same-cycle bmiss window)
  // FSE S5: same-hart filter as the sequential cancelled sticky bits.
  // Also driven without SpeculativeSb so LSU/issue see same-cycle bmiss drops.
  //
  // Soft-ladder I4m–r / hang-6: load_unit flushes ldbuf slots on this mask in
  // the *same* cycle as bmiss. Sequential sticky cancel (above) already drops
  // younger LOADs under SuperscalarEn so wrong-path RF writes cannot leave
  // ra/s2/s3 residue across multi-call FDT (next_tag 2nd entry, getprop).
  // The same-cycle mask must match that policy — previously it always skipped
  // LOAD, so ldbuf still completed wrong-path byte-loads before sticky latch.
  always_comb begin : gen_cancelled_mask
    cancelled_mask_o = '0;
    for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
      cancelled_mask_o[i] = mem_q[i].cancelled;
    end
    if (bmiss) begin
      automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] cid;
      cid = after_flu_wb;
      for (int unsigned k = 0; k < CVA6Cfg.NR_SB_ENTRIES; k++) begin
        if (cid == issue_pointer[0]) break;
        if (CVA6Cfg.NrHarts <= 1 ||
            mem_q[cid].sbe.hart_id == resolved_branch_i.hart_id) begin
          // EXTRACT E0: same keep as sequential cancel.
          if (!g6lc_sb_keep::keep(
                  CVA6Cfg,
                  mem_q[cid].sbe.fu,
                  mem_q[cid].sbe.op,
                  mem_q[cid].sbe.rd[4:0],
                  mem_q[cid].sbe.rs1[4:0],
                  mem_q[cid].sbe.rs2[4:0],
                  mem_q[cid].sbe.use_imm) &&
              !g6lc_sb_keep::keep_prefix(
                  CVA6Cfg,
                  mem_q[cid].sbe.fu,
                  mem_q[cid].sbe.rd[4:0],
                  64'(mem_q[cid].sbe.pc),
                  64'(resolved_branch_i.pc),
                  resolved_branch_i.cf_type)) begin
            cancelled_mask_o[cid] = 1'b1;
          end
        end
        cid = cid + 1'b1;
      end
    end
  end

  // FIFO counter updates
  if (CVA6Cfg.NrCommitPorts == 2) begin : gen_commit_ports
    assign num_commit = commit_ack_i[1] + commit_ack_i[0];
  end else begin : gen_one_commit_port
    assign num_commit = commit_ack_i[0];
  end

  assign commit_pointer_n[0] = (flush_i) ? '0 : commit_pointer_q[0] + num_commit;

  always_comb begin : assign_issue_pointer_n
    issue_pointer_n = issue_pointer[num_issue];
    if (flush_i) issue_pointer_n = '0;
  end

  // precompute offsets for commit slots
  for (genvar k = 1; k < CVA6Cfg.NrCommitPorts; k++) begin : gen_cnt_incr
    assign commit_pointer_n[k] = (flush_i) ? '0 : commit_pointer_n[0] + unsigned'(k);
  end

  // Forwarding logic
  writeback_t [CVA6Cfg.NrWbPorts-1:0] wb;
  for (genvar i = 0; i < CVA6Cfg.NrWbPorts; i++) begin
    assign wb[i].valid = wt_valid_i[i];
    assign wb[i].data = wbdata_i[i];
    assign wb[i].ex_valid = ex_i[i].valid;
    assign wb[i].trans_id = trans_id_i[i];
  end

  assign fwd_o.still_issued = still_issued;
  assign fwd_o.issue_pointer = issue_pointer[0];
  assign fwd_o.wb = wb;
  for (genvar i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
    assign fwd_o.sbe[i] = mem_q[i].sbe;
  end

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin : regs
    if (!rst_ni) begin
      mem_q            <= '{default: sb_mem_t'(0)};
      commit_pointer_q <= '0;
      issue_pointer_q  <= '0;
    end else begin
      issue_pointer_q <= issue_pointer_n;
      mem_q <= mem_n;
      mem_q[x_id_i].sbe.rd <= (x_transaction_accepted_i && ~x_issue_writeback_i) ? 5'b0 : mem_n[x_id_i].sbe.rd;
      commit_pointer_q <= commit_pointer_n;
    end
  end

  //RVFI
  assign rvfi_issue_pointer_o  = issue_pointer[CVA6Cfg.NrIssuePorts-1:0];
  assign rvfi_commit_pointer_o = commit_pointer_q;

  // G1mf: last result-valid aligned-00
  // RVI LOAD per hart (sbe.valid is WB
  // done, before commit_ack). SMT+SS.
  always_comb begin
    g1mf_v_o    = '0;
    g1mf_rd_o   = '0;
    g1mf_line_o = '0;
    g1mf_a3_o   = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64) begin
`ifndef G6LC_FETCH_B
      for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
        if (g6lc_sib_cjalr::sb_load00(
                CVA6Cfg, mem_q[i].issued, mem_q[i].cancelled,
                mem_q[i].sbe.valid, mem_q[i].sbe.ex.valid,
                mem_q[i].sbe.is_compressed,
                mem_q[i].sbe.pc[2:1] == 2'b00,
                mem_q[i].sbe.fu == ariane_pkg::LOAD,
                mem_q[i].sbe.rd[4:0] != 5'd0)) begin
          g1mf_v_o[mem_q[i].sbe.hart_id]    = 1'b1;
          g1mf_rd_o[mem_q[i].sbe.hart_id]   = mem_q[i].sbe.rd[4:0];
          g1mf_line_o[mem_q[i].sbe.hart_id] = mem_q[i].sbe.pc[CVA6Cfg.VLEN-1:4];
          g1mf_a3_o[mem_q[i].sbe.hart_id]   = mem_q[i].sbe.pc[3];
        end
      end
`endif
    end
  end

  //pragma translate_off
  initial begin
    assert (CVA6Cfg.NR_SB_ENTRIES == 2 ** CVA6Cfg.TRANS_ID_BITS)
    else $fatal(1, "Scoreboard size needs to be a power of two.");
  end
  // assert that we never acknowledge a commit if the instruction is not valid
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) commit_ack_i[0] |-> commit_instr_o[0].valid)
  else $fatal(1, "Commit acknowledged but instruction is not valid");
  if (CVA6Cfg.NrCommitPorts == 2) begin : gen_two_commit_ports
    assert property (
        @(posedge clk_i) disable iff (!rst_ni) commit_ack_i[1] |-> commit_instr_o[1].valid)
    else $fatal(1, "Commit acknowledged but instruction is not valid");
  end
  // assert that we never give an issue ack signal if the instruction is not valid
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assert property (
      @(posedge clk_i) disable iff (!rst_ni) issue_ack_i[i] |-> issue_instr_valid_o[i])
    else $fatal(1, "Issue acknowledged but instruction is not valid");
  end

  // there should never be more than one instruction writing the same destination register (except x0)
  // check that no functional unit is retiring with the same transaction id
  for (genvar i = 0; i < CVA6Cfg.NrWbPorts; i++) begin
    for (genvar j = 0; j < CVA6Cfg.NrWbPorts; j++) begin
      assert property (
        @(posedge clk_i) disable iff (!rst_ni) wt_valid_i[i] && wt_valid_i[j] && (i != j) |-> (trans_id_i[i] != trans_id_i[j]))
      else
        $fatal(
            1,
            "Two or more functional units are retiring instructions with the same transaction id!"
        );
    end
  end
  //pragma translate_on
endmodule
