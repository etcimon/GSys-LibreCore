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
// Modified by: Etienne Cimon (commit-pointer width casts)
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
    output logic                                          sb_empty_o,
    // FSE: younger-than-branch cancel fired this cycle (SpeculativeSb path) - PERF
    output logic                                          spec_cancel_o,
    // U5 production: per-SB-slot cancel mask (sticky cancelled | same-cycle bmiss window)
    // OoO IQ/ROB/LSQ squash younger wrong-path ops without full-pipe flush.
    output logic [CVA6Cfg.NR_SB_ENTRIES-1:0]              cancelled_mask_o,
    // Per-slot issued mask (OoO IQ/LSQ liveness assertions)
    output logic [CVA6Cfg.NR_SB_ENTRIES-1:0]              sb_live_o,
    // T6b: per-hart head of the live ring — PC of the oldest issued entry of
    // each hart, found scanning from commit_pointer_q[0] in ring order.
    // T6b-2 recovery restarts each hart at this PC; unused until then.
    output logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:0]  sb_head_pc_o,
    output logic [CVA6Cfg.NrHarts-1:0]                    sb_head_valid_o,
    // LSQ alias validation: youngest load that read bytes an older store
    // resolved later - OoO only, tied low in order.
    input  logic                                          mem_violation_i,
    input  logic              [CVA6Cfg.TRANS_ID_BITS-1:0] mem_violation_id_i,
    input logic [CVA6Cfg.NR_SB_ENTRIES-1:0] phys_pending_i,
    input logic [CVA6Cfg.NR_SB_ENTRIES-1:0] phys_replay_i,
    input logic phys_mod_i,
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
    // Committing slot requests a refetch from its own PC - COMMIT_STAGE
    output logic              [CVA6Cfg.NrCommitPorts-1:0] commit_replay_o,
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
    // T6b-4b: reclaim pointer — the oldest live slot. Under mixed SMT this is
    // the age anchor for dispatch/IQ/LSQ and the store buffer; under legacy
    // commit order it aliases commit_pointer_q[0] (the commit head), so the
    // drained/single-hart consumers see a bit-identical value.
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0]                    reclaim_ptr_o,
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
    logic replay;  // memory-order violation: commit refetches from this PC
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

  // T6b-4b: per-hart commit heads over the shared ring. Under mixed SMT
  // residency the commit ports present per-hart head slots instead of
  // consecutive ring slots; commit_pointer_q[0] is the reclaim pointer (the
  // oldest live slot) and window accounting replaces the popcount so a
  // committed non-head hole cannot alias as allocatable space. Drained and
  // single-hart keep the legacy contiguous commit logic bit-identical.
  localparam bit MixedSmt = (CVA6Cfg.NrHarts > 1) && !CVA6Cfg.SmtDrainedHandoff;

  for (genvar i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
    // A cancelled entry still occupies its slot and still retires in order as
    // a commit_drop, but it must never source a forward: it is wrong-path.
    assign still_issued[i] = mem_q[i].issued & ~mem_q[i].cancelled;
    assign sb_live_o[i] = mem_q[i].issued;
  end

  always_comb begin
    sb_issued_cnt = '0;
    for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
      if (mem_q[i].issued) sb_issued_cnt += 1'b1;
    end
`ifdef G6LC_MUT_SB_POPCOUNT_FREE
    // MUTANT: restore the popcount free count under MIXED — a committed hole
    // inside the live window then reads as allocatable space and dispatch
    // overwrites a live entry (SBC_NO_OVERWRITE).
    sb_free_cnt = $clog2(CVA6Cfg.NR_SB_ENTRIES+1)'(CVA6Cfg.NR_SB_ENTRIES) - sb_issued_cnt;
`else
    if (MixedSmt) begin
      // Window accounting: only the tail [issue_ptr, reclaim) is allocatable.
      // Committed holes inside [reclaim, issue_ptr) stay non-allocatable until
      // the reclaim pointer passes them.
      automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] wdist;
      wdist = issue_pointer_q - commit_pointer_q[0];
      if ((wdist == '0) && (sb_issued_cnt != '0)) begin
        sb_free_cnt = '0;
      end else begin
        sb_free_cnt = $clog2(CVA6Cfg.NR_SB_ENTRIES+1)'(CVA6Cfg.NR_SB_ENTRIES) -
                      $clog2(CVA6Cfg.NR_SB_ENTRIES+1)'(wdist);
      end
    end else begin
      sb_free_cnt = $clog2(CVA6Cfg.NR_SB_ENTRIES+1)'(CVA6Cfg.NR_SB_ENTRIES) - sb_issued_cnt;
    end
`endif
  end

  // Port i is full when fewer than (i+1) free scoreboard slots remain.
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : gen_issue_full
    assign issue_full[i] = sb_free_cnt < $clog2(CVA6Cfg.NR_SB_ENTRIES+1)'(i + 1);
  end

  assign sb_full_o = issue_full[0];
  assign sb_empty_o = sb_issued_cnt == '0;

  // T6b: per-hart oldest live instruction. commit_pointer_q[0] is the oldest
  // live slot, so the first issued entry each hart owns in ring order from it
  // is that hart's head. NrHarts==1 folds to the commit head's PC.
  // T6b-2a: parallel form — rotate each hart's issued mask into ring order,
  // isolate the first set bit, rotate the index back, mux the PC once. No
  // serial dependence and no per-iteration PC mux; the serial scan is kept
  // below under translate_off as the equivalence reference.
  localparam int unsigned SB_NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (SB_NH > 1) ? $clog2(SB_NH) : 1;
  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] commit_sel_slot;
  logic [SB_NH-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] head_slot;
  logic [SB_NH-1:0] head_valid;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] reclaim_n;

  always_comb begin : sb_head_scan
    for (int unsigned h = 0; h < SB_NH; h++) begin
      automatic logic [CVA6Cfg.NR_SB_ENTRIES-1:0] rot;
      automatic logic [CVA6Cfg.NR_SB_ENTRIES-1:0] first;
      automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0]  hit;
      automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0]  slot;
      rot = '0;
      for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
        slot   = commit_pointer_q[0] + CVA6Cfg.TRANS_ID_BITS'(i);
        rot[i] = mem_q[slot].issued &&
                 (mem_q[slot].sbe.hart_id == $bits(mem_q[slot].sbe.hart_id)'(h));
      end
      first = rot & (~rot + 1'b1);
      hit   = '0;
      for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++)
        if (first[i]) hit = CVA6Cfg.TRANS_ID_BITS'(i);
      slot               = commit_pointer_q[0] + hit;
      head_slot[h]       = slot;
      head_valid[h]      = |rot;
      sb_head_valid_o[h] = |rot;
      sb_head_pc_o[h]    = (|rot) ? mem_q[slot].sbe.pc : '0;
    end
  end

//pragma translate_off
  // Serial reference (the T6b-1 implementation): the parallel scan above must
  // agree with it every cycle.
  logic [SB_NH-1:0][CVA6Cfg.VLEN-1:0] sb_head_pc_ref;
  logic [SB_NH-1:0]                   sb_head_valid_ref;
  always_comb begin : sb_head_ref
    automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] slot;
    automatic logic [SB_NH-1:0] found;
    slot              = commit_pointer_q[0];
    found             = '0;
    sb_head_valid_ref = '0;
    sb_head_pc_ref    = '0;
    for (int unsigned k = 0; k < CVA6Cfg.NR_SB_ENTRIES; k++) begin
      if (mem_q[slot].issued && int'(mem_q[slot].sbe.hart_id) < SB_NH &&
          !found[mem_q[slot].sbe.hart_id]) begin
        found[mem_q[slot].sbe.hart_id]             = 1'b1;
        sb_head_valid_ref[mem_q[slot].sbe.hart_id] = 1'b1;
        sb_head_pc_ref[mem_q[slot].sbe.hart_id]    = mem_q[slot].sbe.pc;
      end
      slot = slot + 1'b1;
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (sb_head_valid_o == sb_head_valid_ref)
      else $fatal(1, "sb_head_valid_o diverges from the serial reference");
      assert (sb_head_pc_o == sb_head_pc_ref)
      else $fatal(1, "sb_head_pc_o diverges from the serial reference");
    end
  end
//pragma translate_on

  // T6b-4b: flush-capable-privileged class. Anything that can raise a
  // commit-level flush, replay or architectural side effect must be able to
  // reach port 0 — the only side-effect port. A cancelled entry always
  // carries replay (set at cancel time), so drops are covered too.
  function automatic logic sb_privileged(input sb_mem_t e);
    return e.issued &&
           ((e.sbe.valid && e.sbe.ex.valid) ||
            (e.sbe.fu == ariane_pkg::CSR) ||
            e.replay ||
            (CVA6Cfg.RVA && ariane_pkg::is_amo(e.sbe.op)));
  endfunction

  // T6b-4b commit-port slot select.
  //  Port 0: the ring-oldest flush-capable-privileged head when one exists,
  //  else the reclaim entry (the ring-oldest live slot — today's choice).
  //  Port 1: the legacy +1 slot when it is live, same-hart, and BOTH halves
  //  of the pair are complete (the legacy pair only acks together, so a
  //  live-but-incomplete +1 would park the port behind an unretirable
  //  presentation), else the ring-oldest head of another hart (cross-hart),
  //  else +1 again so a dead presentation traces identically to the legacy
  //  slot.
  //  Under !MixedSmt the select is commit_pointer_q — bit-identical.
  if (MixedSmt) begin : gen_mixed_commit_sel
    always_comb begin
      automatic logic [SB_NH-1:0] priv;
      automatic logic [SB_NH-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] hdist;
      automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] port0_sel, p1_leg, x_slot;
      automatic logic [HID_W-1:0] port0_hart;
      automatic logic p1_leg_ok, p1_x_ok;
      automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] best;

      for (int unsigned h = 0; h < SB_NH; h++) begin
        // The override may only reroute a privileged head that can commit
        // now (wb'd, dropped, or replay-marked — the drop path acks without
        // sbe.valid). An un-issuable privileged head — e.g. a system-CSR op
        // still waiting on the IQ global-oldest gate — must NOT take port 0:
        // it would park the port behind the reclaim entry whose own commit
        // is exactly what that head waits on (observed deadlock: a hart-0
        // mret held port 0 while a hart-1 store head pinned the reclaim
        // anchor below it — neither could move). A non-committable head gets
        // port 0 anyway once the reclaim pointer reaches it.
        priv[h]  = head_valid[h] && sb_privileged(mem_q[head_slot[h]]) &&
                   (mem_q[head_slot[h]].sbe.valid ||
                    mem_q[head_slot[h]].cancelled ||
                    mem_q[head_slot[h]].replay);
        hdist[h] = head_slot[h] - commit_pointer_q[0];
      end
      // port 0 — ring-oldest committable privileged head, else the reclaim
      // entry.
      port0_sel = commit_pointer_q[0];
      begin
        automatic logic p0_found;
        p0_found = 1'b0;
        best     = '1;
        for (int unsigned h = 0; h < SB_NH; h++) begin
          if (priv[h] && (!p0_found || (hdist[h] < best))) begin
            p0_found  = 1'b1;
            best      = hdist[h];
            port0_sel = head_slot[h];
          end
        end
      end
      port0_hart           = mem_q[port0_sel].sbe.hart_id;
      commit_sel_slot[0]   = port0_sel;
      // port 1 — legacy +1 first, then the other hart's head.
      p1_leg    = port0_sel + CVA6Cfg.TRANS_ID_BITS'(1);
      p1_leg_ok = mem_q[p1_leg].issued && (mem_q[p1_leg].sbe.hart_id == port0_hart) &&
                  (mem_q[port0_sel].sbe.valid || mem_q[port0_sel].cancelled) &&
                  (mem_q[p1_leg].sbe.valid    || mem_q[p1_leg].cancelled);
      p1_x_ok   = 1'b0;
      x_slot    = p1_leg;
      best      = '1;
      for (int unsigned h = 0; h < SB_NH; h++) begin
        if ((HID_W'(h) != port0_hart) && head_valid[h] &&
            (head_slot[h] != port0_sel) && (!p1_x_ok || (hdist[h] < best))) begin
          p1_x_ok = 1'b1;
          best    = hdist[h];
          x_slot  = head_slot[h];
        end
      end
      if (CVA6Cfg.NrCommitPorts > 1) begin
        commit_sel_slot[1] = (p1_leg_ok || !p1_x_ok) ? p1_leg : x_slot;
      end
      for (int unsigned k = 2; k < CVA6Cfg.NrCommitPorts; k++)
        commit_sel_slot[k] = port0_sel + CVA6Cfg.TRANS_ID_BITS'(k);
    end
  end else begin : gen_legacy_commit_sel
    always_comb begin
      for (int unsigned k = 0; k < CVA6Cfg.NrCommitPorts; k++)
        commit_sel_slot[k] = commit_pointer_q[k];
    end
  end

  // output commit instruction directly
  always_comb begin : commit_ports
    for (int unsigned i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin
      commit_instr_o[i] = mem_q[commit_sel_slot[i]].sbe;
      commit_instr_o[i].trans_id = commit_sel_slot[i];
      if (CVA6Cfg.CohPolicy == config_pkg::COH_OOO &&
          !mem_q[commit_sel_slot[i]].cancelled && !mem_q[commit_sel_slot[i]].sbe.ex.valid &&
          (phys_pending_i[commit_sel_slot[i]] ||
           (phys_mod_i && mem_q[commit_sel_slot[i]].sbe.fu == ariane_pkg::LOAD)))
        commit_instr_o[i].valid = 1'b0;
      commit_drop_o[i] = mem_q[commit_sel_slot[i]].cancelled;
      commit_replay_o[i] = mem_q[commit_sel_slot[i]].replay;
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
//pragma translate_off
  // O7 alloc trace. Opt-in (`+sb_alloc`): unconditional always_comb $display
  // SIGSEGV'd the -O0 g6lc64_ai testharness at ~2.6k cycles (VL_WRITEF of
  // packed issue_q). Next full verilate must not emit it by default.
  logic sb_alloc_en;
  initial sb_alloc_en = $test$plusargs("sb_alloc");
//pragma translate_on
  always_comb begin : issue_fifo
    automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] cid;
    // default assignment
    mem_n     = mem_q;
    num_issue = '0;
    cid       = '0;

    // if we got an acknowledge from the issue stage, put this scoreboard entry in the queue
    for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      // G1t: link-jal is not unissued fallthrough. IRO flush_i is
      // flush_unissued — without this the jal is popped and never
      // allocated (mini P6 0x65). SI: alloc is !flush_unissued.
      // I14: B does not special-case link-jal on flush_unissued.
      if (decoded_instr_valid_i[i] && decoded_instr_ack_o[i] &&
`ifdef G6LC_FETCH_B
          !flush_unissued_instr_i
`else
          g6lc_sb_keep::alloc(
              CVA6Cfg,
              flush_unissued_instr_i,
              decoded_instr_i[i].fu,
              decoded_instr_i[i].rd[4:0])
`endif
      ) begin
        // the decoded instruction we put in there is valid (1st bit)
        // increase the issue counter and advance issue pointer
        num_issue += 'd1;
//pragma translate_off
        if (sb_alloc_en && $time() < 200000)
          $display("[sb-alloc] t=%0t idx=%0d pc=%h instr=%h ex.valid=%b valid=%b",
                   $time, issue_pointer[i], decoded_instr_i[i].pc, orig_instr_i[i],
                   decoded_instr_i[i].ex.valid, decoded_instr_valid_i[i]);
//pragma translate_on
        mem_n[issue_pointer[i]] = '{
            issued: 1'b1,
            cancelled: 1'b0,
            replay: 1'b0,
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
        // I14: B waits for flu. A keeps G1v/x (RC4 alias patch).
`ifndef G6LC_FETCH_B
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
`endif
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
        // I14/I17: B always takes flu. A keeps G1w (|result[63:12]|).
`ifdef G6LC_FETCH_B
        mem_n[trans_id_i[i]].sbe.result = wbdata_i[i];
`else
        if (!g6lc_sb_keep::keep_alloc_link(
                CVA6Cfg,
                mem_q[trans_id_i[i]].sbe.fu,
                mem_q[trans_id_i[i]].sbe.rd[4:0],
                64'(mem_q[trans_id_i[i]].sbe.result)))
          mem_n[trans_id_i[i]].sbe.result = wbdata_i[i];
`endif
        // save the target address of a branch (needed for debug in commit stage)
        if (CVA6Cfg.DebugEn || (CVA6Cfg.NrHarts > 1 &&
            mem_q[trans_id_i[i]].sbe.fu == ariane_pkg::CTRL_FLOW)) begin
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
          // I13: B cancels younger by program order only (FDT getprop
          // kept wrong-path LOADs of a0/s*). A keeps the exemption list.
`ifdef G6LC_FETCH_B
          mem_n[cid].cancelled = 1'b1;
          mem_n[cid].sbe.valid = 1'b1;
`else
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
`endif
        end
        cid = cid + 1'b1;
      end
    end

    // Memory-order violation: the load keeps its slot, retires as a drop and
    // asks commit to refetch from its own PC.
    if (CVA6Cfg.OoOEn && mem_violation_i && mem_q[mem_violation_id_i].issued) begin
      mem_n[mem_violation_id_i].cancelled = 1'b1;
      mem_n[mem_violation_id_i].replay    = 1'b1;
      mem_n[mem_violation_id_i].sbe.valid = 1'b1;
    end
    if (CVA6Cfg.CohPolicy == config_pkg::COH_OOO) begin
      for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
        if (phys_replay_i[i] && mem_q[i].issued && mem_q[i].sbe.fu == ariane_pkg::LOAD) begin
          mem_n[i].cancelled = 1'b1;
          mem_n[i].replay = 1'b1;
          mem_n[i].sbe.valid = 1'b1;
        end
      end
    end

    // ------------
    // Commit Port
    // ------------
    // we've got an acknowledge from commit
    for (int i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin
      if (commit_ack_i[i]) begin
        // this instruction is no longer in issue e.g.: it is considered finished
        // T6b-4b: free the muxed port slot (commit_sel_slot == commit_pointer_q
        // under legacy, so the drained/single-hart path is unchanged).
        mem_n[commit_sel_slot[i]].issued    = 1'b0;
        mem_n[commit_sel_slot[i]].cancelled = 1'b0;
        mem_n[commit_sel_slot[i]].replay    = 1'b0;
        mem_n[commit_sel_slot[i]].sbe.valid = 1'b0;
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
        mem_n[i].replay       = 1'b0;
        mem_n[i].sbe.valid    = 1'b0;
        mem_n[i].sbe.ex.valid = 1'b0;
      end
    end

    // ------
    // T6b-4b reclaim (MIXED only): the next-cycle reclaim pointer is the
    // oldest slot still live in mem_n at or after the current pointer —
    // rotate the issued mask into ring order from it and isolate the first
    // set bit (same structure as sb_head_scan). When nothing is live it
    // follows the allocation tail so the free-window stays consistent.
    // ------
    reclaim_n = commit_pointer_q[0];
    if (MixedSmt) begin
      automatic logic [CVA6Cfg.NR_SB_ENTRIES-1:0] live_rot;
      automatic logic [CVA6Cfg.NR_SB_ENTRIES-1:0] live_first;
      automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] rslot;
      live_rot = '0;
      for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
        rslot       = commit_pointer_q[0] + CVA6Cfg.TRANS_ID_BITS'(i);
        live_rot[i] = mem_n[rslot].issued;
      end
      live_first = live_rot & (~live_rot + 1'b1);
      for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++)
        if (live_first[i]) reclaim_n = commit_pointer_q[0] + CVA6Cfg.TRANS_ID_BITS'(i);
      if (live_rot == '0) reclaim_n = issue_pointer[num_issue];
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
    automatic logic [CVA6Cfg.TRANS_ID_BITS-1:0] cid;
    cancelled_mask_o = '0;
    cid              = '0;
    for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
      cancelled_mask_o[i] = mem_q[i].cancelled;
    end
    if (bmiss) begin
      cid = after_flu_wb;
      for (int unsigned k = 0; k < CVA6Cfg.NR_SB_ENTRIES; k++) begin
        if (cid == issue_pointer[0]) break;
        if (CVA6Cfg.NrHarts <= 1 ||
            mem_q[cid].sbe.hart_id == resolved_branch_i.hart_id) begin
          // EXTRACT E0: same keep as sequential cancel.
          // I13: B mask matches sequential cancel (no exemption list).
`ifdef G6LC_FETCH_B
          cancelled_mask_o[cid] = 1'b1;
`else
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
`endif
        end
        cid = cid + 1'b1;
      end
    end
  end

  // FIFO counter updates: count acknowledged commits across ALL ports.
  // This was special-cased for two ports and fell through to counting only
  // port 0 for every other width. A four-port configuration therefore retired
  // up to four entries per cycle -- the loop above clears `issued` for each
  // acknowledged port -- while advancing the commit pointer by at most one, so
  // the scoreboard FIFO desynchronised and already-retired slots were presented
  // again. Width-generic popcount, correct for any NrCommitPorts.
  always_comb begin : gen_commit_count
    num_commit = '0;
    for (int unsigned i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin
      if (commit_ack_i[i]) num_commit = num_commit + 1'b1;
    end
  end

  // T6b-4b: under MIXED, commit_pointer_q[0] is the reclaim pointer — it
  // jumps over committed holes to the oldest remaining live slot instead of
  // advancing by the ack popcount. commit_pointer_q[k>0] is unused under
  // MIXED (the port select is commit_sel_slot); gen_cnt_incr stays for shape.
  if (MixedSmt) begin : gen_reclaim_ptr
    assign commit_pointer_n[0] = (flush_i) ? '0 : reclaim_n;
    // Offsets from the underlying expression, not commit_pointer_n[0] — an
    // intra-vector read makes the packed signal self-referential (UNOPTFLAT).
    for (genvar k = 1; k < CVA6Cfg.NrCommitPorts; k++) begin : gen_reclaim_incr
      assign commit_pointer_n[k] = (flush_i) ? '0 : reclaim_n + CVA6Cfg.TRANS_ID_BITS'(k);
    end
  end else begin : gen_commit_ptr
    assign commit_pointer_n[0] = (flush_i) ? '0 : commit_pointer_q[0] + CVA6Cfg.TRANS_ID_BITS'(num_commit);
    for (genvar k = 1; k < CVA6Cfg.NrCommitPorts; k++) begin : gen_commit_incr
      assign commit_pointer_n[k] = (flush_i) ? '0 : commit_pointer_q[0] +
                                   CVA6Cfg.TRANS_ID_BITS'(num_commit) +
                                   CVA6Cfg.TRANS_ID_BITS'(k);
    end
  end

  always_comb begin : assign_issue_pointer_n
    issue_pointer_n = issue_pointer[num_issue];
    if (flush_i) issue_pointer_n = '0;
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
  // T6b-4b: per-port muxed commit slot (== commit_pointer_q under legacy).
  assign rvfi_commit_pointer_o = commit_sel_slot;
  assign reclaim_ptr_o         = commit_pointer_q[0];

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
  bit smt_progress_enabled;
  localparam int SMT_TRACE_HARTS = CVA6Cfg.NrHarts > 0 ? CVA6Cfg.NrHarts : 1;
  longint unsigned smt_retired_count[SMT_TRACE_HARTS];
  logic [CVA6Cfg.VLEN-1:0] smt_last_retired_pc[SMT_TRACE_HARTS];
  initial smt_progress_enabled = $test$plusargs("smt_progress");
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      foreach (smt_retired_count[h]) begin
        smt_retired_count[h] = 0;
        smt_last_retired_pc[h] = '0;
      end
    end else if (smt_progress_enabled) begin
      for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++)
        if (commit_ack_i[p] && !commit_drop_o[p]) begin
          smt_retired_count[commit_instr_o[p].hart_id]++;
          smt_last_retired_pc[commit_instr_o[p].hart_id] = commit_instr_o[p].pc;
        end
    end
  end
  final begin
    if (smt_progress_enabled)
      foreach (smt_retired_count[h])
        $display("[smt-progress] scope=%m hart=%0d retired=%0d last_pc=%h",
                 h, smt_retired_count[h], smt_last_retired_pc[h]);
  end
  bit smt_flow_enabled;
  int unsigned smt_flow_cycle = 0;
  int unsigned smt_flow_idle = 0;
  int unsigned smt_flow_snapshots = 0;
  int unsigned smt_flow_generation[CVA6Cfg.NR_SB_ENTRIES];
  initial smt_flow_enabled = $test$plusargs("smt_flow_trace");

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      smt_flow_cycle = 0;
      smt_flow_idle = 0;
      smt_flow_snapshots = 0;
      foreach (smt_flow_generation[s]) smt_flow_generation[s] = 0;
    end else if (smt_flow_enabled) begin
      smt_flow_cycle++;
      smt_flow_idle = (|commit_ack_i || flush_i) ? 0 : smt_flow_idle + 1;
      for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++)
        if (commit_ack_i[p])
          $display("[smt-flow] retire cycle=%0d port=%0d id=%0d gen=%0d hart=%0d pc=%h rd=%0d result=%h valid=%b drop=%b ex=%b replay=%b scope=%m",
                   smt_flow_cycle, p, commit_sel_slot[p], smt_flow_generation[commit_sel_slot[p]],
                   commit_instr_o[p].hart_id, commit_instr_o[p].pc, commit_instr_o[p].rd[4:0],
                   commit_instr_o[p].result, commit_instr_o[p].valid,
                   commit_drop_o[p], commit_instr_o[p].ex.valid,
                   mem_q[commit_sel_slot[p]].replay);
      for (int p = 0; p < CVA6Cfg.NrWbPorts; p++)
        if (wt_valid_i[p])
          $display("[smt-flow] wb cycle=%0d port=%0d id=%0d gen=%0d hart=%0d pc=%h issued=%b cancelled=%b data=%h ex=%b scope=%m",
                   smt_flow_cycle, p, trans_id_i[p], smt_flow_generation[trans_id_i[p]],
                   mem_q[trans_id_i[p]].sbe.hart_id, mem_q[trans_id_i[p]].sbe.pc,
                   mem_q[trans_id_i[p]].issued, mem_q[trans_id_i[p]].cancelled, wbdata_i[p], ex_i[p].valid);
      for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
        if (decoded_instr_valid_i[p] && decoded_instr_ack_o[p] && !flush_unissued_instr_i) begin
          smt_flow_generation[issue_pointer[p]]++;
          $display("[smt-flow] alloc cycle=%0d port=%0d id=%0d gen=%0d hart=%0d pc=%h insn=%h fu=%0d op=%0d rd=%0d rs1=%0d rs2=%0d scope=%m",
                   smt_flow_cycle, p, issue_pointer[p], smt_flow_generation[issue_pointer[p]],
                   decoded_instr_i[p].hart_id, decoded_instr_i[p].pc, orig_instr_i[p],
                   decoded_instr_i[p].fu, decoded_instr_i[p].op, decoded_instr_i[p].rd,
                   decoded_instr_i[p].rs1, decoded_instr_i[p].rs2);
        end
      if (flush_i || flush_unissued_instr_i || resolved_branch_i.valid)
        $display("[smt-flow] control cycle=%0d flush=%b flush_unissued=%b resolve=%b mispredict=%b target=%h",
                 smt_flow_cycle, flush_i, flush_unissued_instr_i, resolved_branch_i.valid,
                 resolved_branch_i.is_mispredict, resolved_branch_i.target_address);
      if (smt_flow_idle != 0 && smt_flow_idle % 1024 == 0 && smt_flow_snapshots < 4) begin
        smt_flow_snapshots++;
        $display("[smt-flow] stalled cycle=%0d idle=%0d issue_ptr=%0d commit_ptr=%0d full=%b decoded=%b ack=%b",
                 smt_flow_cycle, smt_flow_idle, issue_pointer_q, commit_pointer_q[0],
                 sb_full_o, decoded_instr_valid_i, decoded_instr_ack_o);
        for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
          $display("[smt-flow] offered port=%0d hart=%0d pc=%h insn=%h fu=%0d op=%0d rd=%0d rs1=%0d rs2=%0d",
                   p, decoded_instr_i[p].hart_id, decoded_instr_i[p].pc, orig_instr_i[p],
                   decoded_instr_i[p].fu, decoded_instr_i[p].op, decoded_instr_i[p].rd,
                   decoded_instr_i[p].rs1, decoded_instr_i[p].rs2);
        for (int s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++)
          if (mem_q[s].issued)
            $display("[smt-flow] slot id=%0d gen=%0d hart=%0d pc=%h valid=%b cancelled=%b fu=%0d op=%0d rd=%0d result=%h",
                     s, smt_flow_generation[s], mem_q[s].sbe.hart_id, mem_q[s].sbe.pc,
                     mem_q[s].sbe.valid, mem_q[s].cancelled, mem_q[s].sbe.fu,
                     mem_q[s].sbe.op, mem_q[s].sbe.rd, mem_q[s].sbe.result);
      end
    end
  end

  initial begin
    assert (CVA6Cfg.NR_SB_ENTRIES == 2 ** CVA6Cfg.TRANS_ID_BITS)
    else $fatal(1, "Scoreboard size needs to be a power of two.");
  end
  // assert that we never acknowledge a commit if the instruction is not valid
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) commit_ack_i[0] |-> commit_instr_o[0].valid)
  else $fatal(1, "Commit acknowledged but instruction is not valid");
  // Every commit port, not just port 1: the two-port special case left ports 2
  // and above unchecked in wider configurations.
  for (genvar cp = 1; cp < CVA6Cfg.NrCommitPorts; cp++) begin : gen_commit_port_valid
    assert property (
        @(posedge clk_i) disable iff (!rst_ni) commit_ack_i[cp] |-> commit_instr_o[cp].valid)
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

  // ----------------------------------------------------------------------
  // T6b-4b MIXED invariants — per-hart commit heads over the shared ring.
  // ----------------------------------------------------------------------
  if (MixedSmt) begin : gen_mixed_sbc_checks
    // Each committed port presents its hart's head, or the permitted legacy
    // same-hart +1 slot paired with a port-0 commit (per-hart program order).
    for (genvar p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin : gen_port_head_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        commit_ack_i[p] |->
        (commit_sel_slot[p] == head_slot[commit_instr_o[p].hart_id]) ||
        ((p > 0) &&
         (commit_sel_slot[p] == commit_sel_slot[0] + CVA6Cfg.TRANS_ID_BITS'(1)) &&
         (commit_instr_o[p].hart_id == commit_instr_o[0].hart_id) &&
         commit_ack_i[0]))
      else $fatal(1, "SBC_PORT_HEAD: commit port is neither a per-hart head nor the legacy +1 slot");
    end
    // Per-hart commit order is program order: no commit may retire while an
    // older same-hart entry is still live. Age is witnessed by a global
    // alloc-sequence stamp per slot — a monotonic total order that survives
    // both ring wraps and the non-uniform slot reuse that out-of-ring-order
    // commits create (per-slot generation counters are not a total order:
    // the alloc tail revisits freed slots while others stay live). Slots
    // committed by another port this same cycle are excluded: the legacy
    // same-hart +1 pair retires two program-adjacent entries together.
    int unsigned sbc_alloc_seq;
    int unsigned sbc_slot_seq[CVA6Cfg.NR_SB_ENTRIES];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        sbc_alloc_seq <= 0;
        foreach (sbc_slot_seq[s]) sbc_slot_seq[s] <= 0;
      end else begin
        int unsigned seq;
        seq = sbc_alloc_seq;
        for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++)
          if (decoded_instr_valid_i[i] && decoded_instr_ack_o[i] &&
              !flush_unissued_instr_i) begin
            seq = seq + 1;
            sbc_slot_seq[issue_pointer[i]] <= seq;
          end
        sbc_alloc_seq <= seq;
      end
    end
    function automatic logic sbc_older_live(
        input int unsigned h, input int unsigned s);
      for (int unsigned i = 0; i < CVA6Cfg.NR_SB_ENTRIES; i++) begin
        logic committing;
        committing = 1'b0;
        for (int unsigned q = 0; q < CVA6Cfg.NrCommitPorts; q++)
          if (commit_ack_i[q] && (int'(commit_sel_slot[q]) == i))
            committing = 1'b1;
        if (mem_q[i].issued && !committing && (i != s) &&
            (mem_q[i].sbe.hart_id == $bits(mem_q[i].sbe.hart_id)'(h)) &&
            (sbc_slot_seq[i] < sbc_slot_seq[s]))
          return 1'b1;
      end
      return 1'b0;
    endfunction
    for (genvar p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin : gen_prog_order_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        commit_ack_i[p] |->
        !sbc_older_live(int'(commit_instr_o[p].hart_id),
                        int'(commit_sel_slot[p])))
      else $fatal(1, "SBC_PROG_ORDER: per-hart commit order is not program order");
    end
    // Flush-capable-privileged entries never commit off port 0.
    for (genvar p = 1; p < CVA6Cfg.NrCommitPorts; p++) begin : gen_p1_priv_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        commit_ack_i[p] |-> !sb_privileged(mem_q[commit_sel_slot[p]]))
      else $fatal(1, "SBC_P1_PRIV: flush-capable-privileged entry committed off port 0");
    end
    // A cross-hart port-1 commit never coincides with a flush-capable
    // port-0 ack (covers every commit-level flush source). Ack-qualified to
    // match the commit-stage rule: a merely presented privileged head
    // flushes nothing and must not stall the peer's head.
    if (CVA6Cfg.NrCommitPorts > 1) begin : gen_xflush_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        (commit_ack_i[1] &&
         (commit_instr_o[1].hart_id != commit_instr_o[0].hart_id)) |->
        !(sb_privileged(mem_q[commit_sel_slot[0]]) && commit_ack_i[0]))
      else $fatal(1, "SBC_P1_XFLUSH: cross-hart port-1 commit under a flush-capable port-0 ack");
    end
    // A cross-hart port-1 commit never lands on a full-flush cycle: the
    // peer restart frontier samples the scoreboard head before the commit
    // lands, so a peer retire here would be refetched and committed a
    // second time (observed: parked restart pc froze at the committing
    // slot's pc and the hart resumed into an already-retired stream).
    if (CVA6Cfg.NrCommitPorts > 1) begin : gen_xcommit_flush_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        (commit_ack_i[1] &&
         (commit_instr_o[1].hart_id != commit_instr_o[0].hart_id)) |->
        !flush_i)
      else $fatal(1, "SBC_P1_FLUSH: cross-hart port-1 commit on a full-flush cycle");
    end
    // The reclaim window is contiguous: every live slot lies in
    // [reclaim, issue_pointer).
    for (genvar s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++) begin : gen_reclaim_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        mem_q[s].issued |->
        (((CVA6Cfg.TRANS_ID_BITS'(s) - commit_pointer_q[0]) <
          (issue_pointer_q - commit_pointer_q[0])) ||
         ((issue_pointer_q == commit_pointer_q[0]) && (sb_issued_cnt != '0))))
      else $fatal(1, "SBC_RECLAIM_WIN: live slot outside the reclaim window");
    end
    // Dispatch never allocates onto a live slot — the catching check for
    // G6LC_MUT_SB_POPCOUNT_FREE.
    for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : gen_overwrite_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        (decoded_instr_valid_i[i] && decoded_instr_ack_o[i] && !flush_unissued_instr_i) |->
        !mem_q[issue_pointer[i]].issued)
      else $fatal(1, "SBC_NO_OVERWRITE: dispatch allocated onto a live scoreboard slot");
    end
  end
  //pragma translate_on
endmodule
