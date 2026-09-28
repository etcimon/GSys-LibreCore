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
// Modified by: Etienne Cimon
// Date: 06.10.2017
// Description: Performance counters

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: per-hart PMU counter banks and LibreCore feature event sources.
// The upstream notice above is prose and declares no SPDX identifier, so the
// outbound offer is stated here as the file's single SPDX tag. See REUSE.toml.
// Etienne Cimon offers this file AS A WHOLE under:
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial


module perf_counters
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type exception_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter int unsigned NumPorts = 3  // number of miss ports
) (
    input logic clk_i,
    input logic rst_ni,
    input logic debug_mode_i,  // debug mode
    // Privilege level per event bank (Sscofpmf MINH/SINH/UINH filtering):
    // each bank is filtered by its own hart's privilege level, not the
    // active hart's.
    input riscv::priv_lvl_t [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] priv_lvl_b_i,
    // SRAM like interface
    input logic [11:0] addr_i,  // read/write address (up to ariane_pkg::MHPMCounterNum counters possible)
    input logic we_i,  // write enable
    input logic [CVA6Cfg.XLEN-1:0] data_i,  // data to write
    output logic [CVA6Cfg.XLEN-1:0] data_o,  // data to read
    // Active (fetch) hart: frontend/structural events (I$/ITLB/DTLB/D$ miss,
    // if_empty, stalls, L2/L3/PF, AI, write-buffer) are attributed to it as a
    // documented approximation — they observe shared frontend state.
    input logic [(CVA6Cfg.NrHarts <= 1 ? 1 : $clog2(CVA6Cfg.NrHarts))-1:0] hart_i,
    // Hart owning the CSR access on this port (the committing op's hart —
    // commit_instr_i[0].hart_id in the core). mhpmcounterN/mhpmeventN are
    // per-hart architectural CSRs, so the access bank is selected by it rather
    // than by the active hart; with one hart it is a constant 0.
    input logic [(CVA6Cfg.NrHarts <= 1 ? 1 : $clog2(CVA6Cfg.NrHarts))-1:0] csr_hart_i,
    // Sscofpmf: read-only OF vector for scountovf (bit i = OF of counter i), per hart
    output logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][31:0] scountovf_o,
    // Sscofpmf: local counter-overflow interrupt pending (OR of OF bits), per hart
    output logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] lcofi_o,
    // from commit stage
    input  scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0] commit_instr_i,     // the instruction we want to commit
    input  logic [CVA6Cfg.NrCommitPorts-1:0]              commit_ack_i,       // acknowledge that we are indeed committing
    // from L1 caches
    input logic l1_icache_miss_i,
    input logic l1_dcache_miss_i,
    // from MMU
    input logic itlb_miss_i,
    input logic dtlb_miss_i,
    // from issue stage
    input logic sb_full_i,
    // U5 OoO probes (tie 0 when OoOEn=0)
    input logic ooo_rename_stall_i,
    input logic ooo_iq_full_i,
    input logic ooo_rob_full_i,
    input logic ooo_lsq_stall_i,
    input logic ooo_stl_forward_i,
    // COH_OOO probes (tie 0 when unused)
    input logic ooo_phys_replay_i,   // load marked for replay by a modification event
    input logic coh_inval_apply_i,   // L1 coherence invalidation applied (WT return path)
    // Group 2: SoC memory hierarchy (tie 0 when unused)
    input logic l2_miss_i,
    input logic l3_hit_i,
    input logic l3_miss_i,
    input logic pf_issue_i,
    input logic pf_train_i,
    // T9b posted-write hold cycles (L2 index 7, L3 index 8)
    input logic l2_pwhold_i,
    input logic l3_pwhold_i,
    // Group 3: FSE speculation recovery (tie 0 when unused)
    input logic spec_cancel_i,
    // Group 4: Xg6lcai AI matrix (tie 0 when AiCfg.MatrixEn=0 / no copro)
    input logic ai_pmu_op_i,      // any AI result_valid pulse
    input logic ai_pmu_mma_i,     // MMA complete pulse
    input logic ai_pmu_post_i,    // requant / relu / gelu complete pulse
    input logic ai_pmu_t0_i,      // T0 single-cycle complete pulse
    input logic ai_pmu_busy_i,    // multi-cycle unit busy (level → cycle count)
    // Group 5: SL-W write-buffer post-ACK fixup queue (tie 0 when WtDcacheFixupDepth=0)
    input logic dcache_wbuf_void_ack_i,
    input logic dcache_wbuf_fixup_write_i,
    input logic dcache_wbuf_fixup_inval_i,
    input logic dcache_wbuf_fixup_full_i,
    // from frontend
    input logic if_empty_i,
    // from PC Gen
    input exception_t ex_i,
    input logic eret_i,
    input bp_resolve_t resolved_branch_i,
    // for newly added events
    input exception_t branch_exceptions_i,  //Branch exceptions->execute unit-> branch_exception_o
    input icache_dreq_t l1_icache_access_i,
    input dcache_req_i_t [2:0] l1_dcache_access_i,
    input  logic [NumPorts-1:0][CVA6Cfg.DCACHE_SET_ASSOC-1:0]miss_vld_bits_i,  //For Cache eviction (3ports-LOAD,STORE,PTW)
    input logic i_tlb_flush_i,
    input logic stall_issue_i,  //stall-read operands
    // Per-bank count inhibit: bank h counts only while
    // !mcountinhibit_b_i[h][i+2] so a peer's CSR write never suppresses this
    // hart's counting.
    input logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][31:0] mcountinhibit_b_i
);

  typedef logic [11:0] csr_addr_t;

  localparam int unsigned NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  logic [63:0] generic_counter_d[NH][MHPMCounterNum:1];
  logic [63:0] generic_counter_q[NH][MHPMCounterNum:1];

  //internal signal to keep track of exception
  logic read_access_exception, update_access_exception;

  // events[i][h]: counter i's selected event in bank h. Each bank owns its
  // own selector, so attribution is exact: a commit-derived event lands only
  // in the committing hart's bank, a structural event only in the active
  // hart's bank.
  logic [NH-1:0] events[MHPMCounterNum:1];
  // Event selector (group+index). Width is MHPMEventWidth (8).
  logic [MHPMEventWidth-1:0] mhpmevent_d[NH][MHPMCounterNum:1];
  logic [MHPMEventWidth-1:0] mhpmevent_q[NH][MHPMCounterNum:1];

  // Sscofpmf state: OF + privilege-mode inhibit bits per HPM counter.
  // Layout mirrors the architectural mhpmeventN packing on RV64:
  //   [63] OF, [62] MINH, [61] SINH, [60] UINH; selector in the low bits.
  logic of_d[NH][MHPMCounterNum:1], of_q[NH][MHPMCounterNum:1];
  logic minh_d[NH][MHPMCounterNum:1], minh_q[NH][MHPMCounterNum:1];
  logic sinh_d[NH][MHPMCounterNum:1], sinh_q[NH][MHPMCounterNum:1];
  logic uinh_d[NH][MHPMCounterNum:1], uinh_q[NH][MHPMCounterNum:1];
  // event_inhibited[i][h]: bank h's inhibit for counter i (priv_lvl_b_i[h]).
  logic [NH-1:0] event_inhibited[MHPMCounterNum:1];

  // Event matrix: one 32-entry vector per group (see ariane_pkg::MHPMEvent*)
  // per event bank. Selecting an event is then a plain index rather than a
  // case statement that every new feature has to edit. Undriven entries fold
  // away in synthesis, so the cost is the same 1-bit mux tree as before; the
  // win is that a feature registers its events in its own group without
  // touching the legacy list. Each entry is already hart-attributed, so a
  // bank only ever counts events that belong to its own hart.
  logic [MHPMEventGrpNum-1:0][MHPMEventIdxNum-1:0] event_group[NH];
  logic [MHPMEventGrpWidth-1:0] event_grp_sel[NH][MHPMCounterNum:1];
  logic [MHPMEventIdxWidth-1:0] event_idx_sel[NH][MHPMCounterNum:1];
  // internal signal to detect event on multiple commit ports
  logic [CVA6Cfg.NrCommitPorts-1:0] load_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] store_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] branch_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] call_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] return_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] int_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] fp_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] retire_event;
  // Per-bank ORs of the per-port commit events: bank h sees only the commit
  // ports whose committed instruction carries hart h.
  logic [NH-1:0] load_event_h, store_event_h, branch_event_h, call_event_h;
  logic [NH-1:0] return_event_h, int_event_h, fp_event_h, retire_event_h;

  //Multiplexer
  always_comb begin : Mux
    events = '{default: '0};
    for (int unsigned h = 0; h < NH; h++) event_group[h] = '0;
    load_event = '{default: 0};
    store_event = '{default: 0};
    branch_event = '{default: 0};
    call_event = '{default: 0};
    return_event = '{default: 0};
    int_event = '{default: 0};
    fp_event = '{default: 0};
    retire_event = '{default: 0};
    load_event_h = '0;
    store_event_h = '0;
    branch_event_h = '0;
    call_event_h = '0;
    return_event_h = '0;
    int_event_h = '0;
    fp_event_h = '0;
    retire_event_h = '0;

    for (int unsigned j = 0; j < CVA6Cfg.NrCommitPorts; j++) begin
      load_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == LOAD);
      store_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == STORE);
      branch_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == CTRL_FLOW);
      call_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == CTRL_FLOW && (commit_instr_i[j].op == ADD || commit_instr_i[j].op == JALR) && (commit_instr_i[j].rd == 'd1 || commit_instr_i[j].rd == 'd5));
      return_event[j] = commit_ack_i[j] & (commit_instr_i[j].op == JALR && commit_instr_i[j].rd == 'd0);
      int_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == ALU || commit_instr_i[j].fu == MULT);
      fp_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == FPU || commit_instr_i[j].fu == FPU_VEC);
      // T6b-4a: retired-instructions-per-hart event for the mixed-residency
      // measurement probe. commit_ack with no exception is the retirement
      // witness; same-hart cancellation means a peer's storms never enter
      // this hart's count.
      retire_event[j] = commit_ack_i[j] & !commit_instr_i[j].ex.valid;
      // Bucket the port's events into the committing instruction's hart bank.
      for (int unsigned h = 0; h < NH; h++) begin
        if (commit_instr_i[j].hart_id == $bits(commit_instr_i[j].hart_id)'(h)) begin
          load_event_h[h]   |= load_event[j];
          store_event_h[h]  |= store_event[j];
          branch_event_h[h] |= branch_event[j];
          call_event_h[h]   |= call_event[j];
          return_event_h[h] |= return_event[j];
          int_event_h[h]    |= int_event[j];
          fp_event_h[h]     |= fp_event[j];
          retire_event_h[h] |= retire_event[j];
        end
      end
    end

    for (int unsigned h = 0; h < NH; h++) begin
      // Attribution classes (T6b-3a): commit-derived events bank by the
      // committing instruction's hart; ex/eret by commit port 0's hart;
      // resolved-branch events (and the FLU branch exception, which shares
      // the resolving instruction — documented approximation) by the
      // branch's own hart; frontend/structural events by the active hart.
      automatic logic act   = (hart_i == HID_W'(h));
      automatic logic c0    = (commit_instr_i[0].hart_id == $bits(commit_instr_i[0].hart_id)'(h));
      automatic logic brh   = (resolved_branch_i.hart_id == $bits(resolved_branch_i.hart_id)'(h));
      // --- Group 0: legacy encoding (mhpmevent[7:5] == 0) ------------------
      // These indices are architectural in practice: software and the device-tree
      // PMU mapping already use them. Never renumber an entry here.
      event_group[h][MHPMGrpLegacy][5'd0]  = 1'b0;
      event_group[h][MHPMGrpLegacy][5'd1]  = l1_icache_miss_i && act;  //L1 I-Cache misses
      event_group[h][MHPMGrpLegacy][5'd2]  = l1_dcache_miss_i && act;  //L1 D-Cache misses
      event_group[h][MHPMGrpLegacy][5'd3]  = itlb_miss_i && act;  //ITLB misses
      event_group[h][MHPMGrpLegacy][5'd4]  = dtlb_miss_i && act;  //DTLB misses
      event_group[h][MHPMGrpLegacy][5'd5]  = load_event_h[h];  //Load accesses
      event_group[h][MHPMGrpLegacy][5'd6]  = store_event_h[h];  //Store accesses
      event_group[h][MHPMGrpLegacy][5'd7]  = ex_i.valid && c0;  //Exceptions
      event_group[h][MHPMGrpLegacy][5'd8]  = eret_i && c0;  //Exception handler returns
      event_group[h][MHPMGrpLegacy][5'd9]  = branch_event_h[h];  // Branch instructions
      event_group[h][MHPMGrpLegacy][5'd10] =
          resolved_branch_i.valid && resolved_branch_i.is_mispredict && brh;  //Branch mispredicts
      event_group[h][MHPMGrpLegacy][5'd11] = branch_exceptions_i.valid && brh;  //Branch exceptions
      // The standard software calling convention uses register x1 to hold the return address on a call
      // the unconditional jump is decoded as ADD op
      event_group[h][MHPMGrpLegacy][5'd12] = call_event_h[h];  //Call
      event_group[h][MHPMGrpLegacy][5'd13] = return_event_h[h];  //Return
      event_group[h][MHPMGrpLegacy][5'd14] = sb_full_i && act;  //MSB Full
      event_group[h][MHPMGrpLegacy][5'd15] = if_empty_i && act;  //Instruction fetch Empty
      event_group[h][MHPMGrpLegacy][5'd16] = l1_icache_access_i.req && act;  //L1 I-Cache accesses
      event_group[h][MHPMGrpLegacy][5'd17] =
          (l1_dcache_access_i[0].data_req || l1_dcache_access_i[1].data_req ||
           l1_dcache_access_i[2].data_req) && act;  //L1 D-Cache accesses
      event_group[h][MHPMGrpLegacy][5'd18] =
          ((l1_dcache_miss_i && miss_vld_bits_i[0] == 8'hFF) ||
           (l1_dcache_miss_i && miss_vld_bits_i[1] == 8'hFF) ||
           (l1_dcache_miss_i && miss_vld_bits_i[2] == 8'hFF)) && act;  //eviction
      event_group[h][MHPMGrpLegacy][5'd19] = i_tlb_flush_i && act;  //I-TLB flush
      event_group[h][MHPMGrpLegacy][5'd20] = int_event_h[h];  //Integer instructions
      event_group[h][MHPMGrpLegacy][5'd21] = fp_event_h[h];  //Floating Point Instructions
      event_group[h][MHPMGrpLegacy][5'd22] = stall_issue_i && act;  //Pipeline bubbles

      // Group 1: U5 OoO / MLP (mhpmevent[7:5]==1). Indices stable once published.
      event_group[h][3'd1][5'd0] = (sb_full_i | ooo_rename_stall_i | ooo_rob_full_i) && act;  // rename/ROB backpressure
      event_group[h][3'd1][5'd1] = (stall_issue_i | ooo_iq_full_i) && act;                    // IQ / issue stall
      event_group[h][3'd1][5'd2] = resolved_branch_i.valid && resolved_branch_i.is_mispredict && brh;
      event_group[h][3'd1][5'd3] = load_event_h[h];      // load traffic
      event_group[h][3'd1][5'd4] = store_event_h[h];     // store traffic
      event_group[h][3'd1][5'd5] = ooo_lsq_stall_i && act;  // LSQ / memdep / STL stall
      event_group[h][3'd1][5'd6] = ooo_stl_forward_i && act;  // store-to-load forward hits
      event_group[h][3'd1][5'd7] = ooo_rename_stall_i && act; // freelist / rename stall alone
      // T6b-4a: retired instructions, banked by the committing hart — the
      // architectural per-hart readout for the mixed-residency probe.
      event_group[h][3'd1][5'd8] = retire_event_h[h];
      // T6b-4a: cycles this hart held the active (fetch) context — the
      // architectural residency readout companion to the retired counter.
      event_group[h][3'd1][5'd9] = act;
      // Group 2: server memory hierarchy (mhpmevent[7:5]==2). Stable indices.
      event_group[h][3'd2][5'd0] = l3_miss_i && act;   // L3 miss
      event_group[h][3'd2][5'd1] = l3_hit_i && act;    // L3 hit
      event_group[h][3'd2][5'd2] = pf_issue_i && act;  // server PF issue
      event_group[h][3'd2][5'd3] = pf_train_i && act;  // server PF train
      event_group[h][3'd2][5'd4] = l2_miss_i && act;   // L2 miss (cluster)
      event_group[h][3'd2][5'd5] = coh_inval_apply_i && act;  // L1 coherence invalidation applied
      event_group[h][3'd2][5'd6] = ooo_phys_replay_i && act;  // COH_OOO load replay after modification
      // T9b: cycles an L2/L3 write- or line-hold stalls a requester behind
      // an unacknowledged posted write (tracker full, R1/R2, ATOP guard).
      event_group[h][3'd2][5'd7] = l2_pwhold_i && act;  // L2 posted-write hold
      event_group[h][3'd2][5'd8] = l3_pwhold_i && act;  // L3 posted-write hold

      // Group 3: FSE / deep speculation recovery (mhpmevent[7:5]==3)
      event_group[h][3'd3][5'd0] = resolved_branch_i.valid && resolved_branch_i.is_mispredict && brh;
      event_group[h][3'd3][5'd1] = spec_cancel_i && act;   // SpeculativeSb younger cancel
      event_group[h][3'd3][5'd2] = sb_full_i && act;       // in-flight window full
      event_group[h][3'd3][5'd3] = stall_issue_i && act;   // issue/RAW bubble
      event_group[h][3'd3][5'd4] = load_event_h[h];        // load pressure
      event_group[h][3'd3][5'd5] = store_event_h[h];       // store pressure

      // Group 4: Xg6lcai AI (mhpmevent[7:5]==MHPMGrpAI). See ariane_pkg.
      if (CVA6Cfg.AiCfg.MatrixEn) begin
        event_group[h][MHPMGrpAI][5'd0] = ai_pmu_op_i && act;
        event_group[h][MHPMGrpAI][5'd1] = ai_pmu_mma_i && act;
        event_group[h][MHPMGrpAI][5'd2] = ai_pmu_post_i && act;
        event_group[h][MHPMGrpAI][5'd3] = ai_pmu_t0_i && act;
        event_group[h][MHPMGrpAI][5'd4] = ai_pmu_busy_i && act;
      end

      // Group 5: SL-W write-buffer post-ACK fixup queue.
      if (CVA6Cfg.WtDcacheFixupDepth != 0) begin
        event_group[h][MHPMGrpSLW][5'd0] = dcache_wbuf_void_ack_i && act;
        event_group[h][MHPMGrpSLW][5'd1] = dcache_wbuf_fixup_write_i && act;
        event_group[h][MHPMGrpSLW][5'd2] = dcache_wbuf_fixup_inval_i && act;
        event_group[h][MHPMGrpSLW][5'd3] = dcache_wbuf_fixup_full_i && act;
      end

      // Groups 6..7 reserved.

      for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
        events[i][h] = event_group[h][event_grp_sel[h][i]][event_idx_sel[h][i]];
      end
    end

  end

  // Each bank owns its selector copy and reads only its own mhpmevent bank, so
  // a counter can never select (and thus count) a peer hart's event.
  for (genvar h = 0; h < NH; h++) begin : gen_bank_sel
    for (genvar i = 1; i <= MHPMCounterNum; i++) begin : gen_event_sel
      assign event_grp_sel[h][i] = mhpmevent_q[h][i][MHPMEventWidth-1:MHPMEventIdxWidth];
      assign event_idx_sel[h][i] = mhpmevent_q[h][i][MHPMEventIdxWidth-1:0];
    end
  end

  // Sscofpmf: scountovf bit i mirrors OF of mhpmcounter i (bits 0-2 hardwired 0;
  // only counters 3..MHPMCounterNum+2 exist here, indexed as 1..MHPMCounterNum).
  always_comb begin : scountovf_pack
    scountovf_o = '0;
    lcofi_o     = '0;
    if (CVA6Cfg.SscofpmfEn) begin
      for (int unsigned h = 0; h < NH; h++) begin
        for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
          scountovf_o[h][i+2] = of_q[h][i];
        end
        // Overflow is reported only to the owning hart, not broadcast.
        lcofi_o[h] = |scountovf_o[h];
      end
    end
  end

  always_comb begin : generic_counter
    generic_counter_d = generic_counter_q;
    data_o = 'b0;
    mhpmevent_d = mhpmevent_q;
    of_d = of_q;
    minh_d = minh_q;
    sinh_d = sinh_q;
    uinh_d = uinh_q;
    event_inhibited = '{default: 0};
    read_access_exception = 1'b0;
    update_access_exception = 1'b0;

    // Privilege-mode event filtering (Sscofpmf MINH/SINH/UINH).
    // Each bank is filtered by its own hart's privilege level
    // (priv_lvl_b_i[h]); debug_mode_i stays global — external debug under
    // mixed residency is unsupported (asserted at the CSR bank).
    if (CVA6Cfg.SscofpmfEn) begin
      for (int unsigned h = 0; h < NH; h++) begin
        for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
          unique case (priv_lvl_b_i[h])
            riscv::PRIV_LVL_M: event_inhibited[i][h] = minh_q[h][i];
            riscv::PRIV_LVL_S: event_inhibited[i][h] = sinh_q[h][i];
            riscv::PRIV_LVL_U: event_inhibited[i][h] = uinh_q[h][i];
            default:           event_inhibited[i][h] = 1'b0;
          endcase
        end
      end
    end

    // Increment each bank's non-inhibited counters with its own events; set
    // OF on wrap. A CSR write suppresses counting only in the accessed bank
    // (we_i && csr_hart_i == h), and mcountinhibit is per bank — a peer's
    // inhibit or write never touches this hart's counters.
    for (int unsigned h = 0; h < NH; h++) begin
      for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
        if ((!debug_mode_i) && !(we_i && csr_hart_i == HID_W'(h)) && !event_inhibited[i][h]) begin
          if ((events[i][h]) == 1 && (!mcountinhibit_b_i[h][i+2])) begin
            if (CVA6Cfg.SscofpmfEn && (&generic_counter_q[h][i])) begin
              of_d[h][i] = 1'b1;
            end
            generic_counter_d[h][i] = generic_counter_q[h][i] + 1'b1;
          end
        end
      end
    end

    //Read (the access bank is the committing CSR op's hart)
    if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_COUNTER_3)) && (addr_i < ( csr_addr_t'(riscv::CSR_MHPM_COUNTER_3) + csr_addr_t'(MHPMCounterNum))) ) begin
      if (riscv::XLEN == 32) begin
        data_o = CVA6Cfg.XLEN'(generic_counter_q[csr_hart_i][addr_i-riscv::CSR_MHPM_COUNTER_3+1][31:0]);
      end else begin
        data_o = generic_counter_q[csr_hart_i][addr_i-riscv::CSR_MHPM_COUNTER_3+1];
      end
    end else if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_COUNTER_3H)) && (addr_i < ( csr_addr_t'(riscv::CSR_MHPM_COUNTER_3H) + csr_addr_t'(MHPMCounterNum))) ) begin
      if (riscv::XLEN == 32) begin
        data_o = CVA6Cfg.XLEN'(generic_counter_q[csr_hart_i][addr_i-riscv::CSR_MHPM_COUNTER_3H+1][63:32]);
      end else begin
        read_access_exception = 1'b1;
      end
    end else if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_EVENT_3)) && (addr_i < (csr_addr_t'(riscv::CSR_MHPM_EVENT_3) + csr_addr_t'(MHPMCounterNum))) ) begin
      // Pack architectural mhpmeventN: selector in low bits; OF/filter when Sscofpmf.
      data_o = CVA6Cfg.XLEN'(mhpmevent_q[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1]);
      if (CVA6Cfg.SscofpmfEn && CVA6Cfg.IS_XLEN64) begin
        data_o[63] = of_q[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1];
        data_o[62] = minh_q[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1];
        data_o[61] = sinh_q[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1];
        data_o[60] = uinh_q[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1];
      end
    end else if( (addr_i >= csr_addr_t'(riscv::CSR_HPM_COUNTER_3)) && (addr_i < (csr_addr_t'(riscv::CSR_HPM_COUNTER_3) + csr_addr_t'(MHPMCounterNum))) ) begin
      if (riscv::XLEN == 32) begin
        data_o = CVA6Cfg.XLEN'(generic_counter_q[csr_hart_i][addr_i-riscv::CSR_HPM_COUNTER_3+1][31:0]);
      end else begin
        data_o = generic_counter_q[csr_hart_i][addr_i-riscv::CSR_HPM_COUNTER_3+1];
      end
      // `>` excluded hpmcounter3h itself, and the index subtracted the MACHINE-mode
      // base from a USER-mode address, indexing far outside the counter array.
    end else if( (addr_i >= csr_addr_t'(riscv::CSR_HPM_COUNTER_3H)) && (addr_i < (csr_addr_t'(riscv::CSR_HPM_COUNTER_3H) + csr_addr_t'(MHPMCounterNum))) ) begin
      if (riscv::XLEN == 32) begin
        data_o = CVA6Cfg.XLEN'(generic_counter_q[csr_hart_i][addr_i-riscv::CSR_HPM_COUNTER_3H+1][63:32]);
      end else begin
        read_access_exception = 1'b1;
      end
    end

    //Write
    if (we_i) begin
      if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_COUNTER_3)) && (addr_i < (csr_addr_t'(riscv::CSR_MHPM_COUNTER_3) + csr_addr_t'(MHPMCounterNum))) ) begin
        if (riscv::XLEN == 32) begin
          generic_counter_d[csr_hart_i][addr_i-riscv::CSR_MHPM_COUNTER_3+1][31:0] = data_i[31:0];
        end else begin
          generic_counter_d[csr_hart_i][addr_i-riscv::CSR_MHPM_COUNTER_3+1] = data_i;
        end
      end else if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_COUNTER_3H)) && (addr_i < (csr_addr_t'(riscv::CSR_MHPM_COUNTER_3H) + csr_addr_t'(MHPMCounterNum))) ) begin
        if (riscv::XLEN == 32) begin
          generic_counter_d[csr_hart_i][addr_i-riscv::CSR_MHPM_COUNTER_3H+1][63:32] = data_i[31:0];
        end else begin
          update_access_exception = 1'b1;
        end
      end else if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_EVENT_3)) && (addr_i < csr_addr_t'(riscv::CSR_MHPM_EVENT_3) + csr_addr_t'(MHPMCounterNum)) ) begin
        // WARL: selector always writable; OF/filter only with Sscofpmf.
        // Writing 0 to OF clears it (spec); writing 1 is ignored (sticky set).
        mhpmevent_d[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1] = data_i[MHPMEventWidth-1:0];
        if (CVA6Cfg.SscofpmfEn && CVA6Cfg.IS_XLEN64) begin
          if (!data_i[63]) of_d[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1] = 1'b0;
          minh_d[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1] = data_i[62];
          sinh_d[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1] = data_i[61];
          uinh_d[csr_hart_i][addr_i-riscv::CSR_MHPM_EVENT_3+1] = data_i[60];
        end
      end
    end
  end

  //Registers
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Explicit per-bank clear: a flat '{default:0} is not accepted for the
      // two-dimensional unpacked banks.
      for (int unsigned h = 0; h < NH; h++) begin
        for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
          generic_counter_q[h][i] <= '0;
          mhpmevent_q[h][i]       <= '0;
          of_q[h][i]              <= 1'b0;
          minh_q[h][i]            <= 1'b0;
          sinh_q[h][i]            <= 1'b0;
          uinh_q[h][i]            <= 1'b0;
        end
      end
    end else begin
      generic_counter_q <= generic_counter_d;
      mhpmevent_q       <= mhpmevent_d;
      if (CVA6Cfg.SscofpmfEn) begin
        of_q   <= of_d;
        minh_q <= minh_d;
        sinh_q <= sinh_d;
        uinh_q <= uinh_d;
      end else begin
        for (int unsigned h = 0; h < NH; h++) begin
          for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
            of_q[h][i]   <= 1'b0;
            minh_q[h][i] <= 1'b0;
            sinh_q[h][i] <= 1'b0;
            uinh_q[h][i] <= 1'b0;
          end
        end
      end
    end
  end

  // Attribution note (T6b-3a): every event and every CSR access is banked by
  // its true owner — commit-derived events by commit_instr_i[*].hart_id,
  // ex/eret by commit port 0's hart, resolved-branch events by
  // resolved_branch_i.hart_id, structural events by the active hart_i, and
  // the CSR access by csr_hart_i — so mixed-hart retirement counts exactly.
  // Under the drained handoff (or one hart) every select collapses onto the
  // active hart and the counts are identical to the pre-banked design.

endmodule
