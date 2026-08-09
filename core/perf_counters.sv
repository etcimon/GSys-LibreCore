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
// Modifications (c) 2026 Etienne Cimon: per-hart PMU event counters and LibreCore feature event sources.
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
    // Privilege level (Sscofpmf MINH/SINH/UINH filtering)
    input riscv::priv_lvl_t priv_lvl_i,
    // SRAM like interface
    input logic [11:0] addr_i,  // read/write address (up to ariane_pkg::MHPMCounterNum counters possible)
    input logic we_i,  // write enable
    input logic [CVA6Cfg.XLEN-1:0] data_i,  // data to write
    output logic [CVA6Cfg.XLEN-1:0] data_o,  // data to read
    // Sscofpmf: read-only OF vector for scountovf (bit i = OF of counter i)
    output logic [31:0] scountovf_o,
    // Sscofpmf: local counter-overflow interrupt pending (OR of OF bits)
    output logic lcofi_o,
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
    // Group 2: SoC memory hierarchy (tie 0 when unused)
    input logic l2_miss_i,
    input logic l3_hit_i,
    input logic l3_miss_i,
    input logic pf_issue_i,
    input logic pf_train_i,
    // Group 3: FSE speculation recovery (tie 0 when unused)
    input logic spec_cancel_i,
    // Group 4: Xg6lcai AI matrix (tie 0 when AiCfg.MatrixEn=0 / no copro)
    input logic ai_pmu_op_i,      // any AI result_valid pulse
    input logic ai_pmu_mma_i,     // MMA complete pulse
    input logic ai_pmu_post_i,    // requant / relu / gelu complete pulse
    input logic ai_pmu_t0_i,      // T0 single-cycle complete pulse
    input logic ai_pmu_busy_i,    // multi-cycle unit busy (level → cycle count)
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
    input logic [31:0] mcountinhibit_i
);

  typedef logic [11:0] csr_addr_t;

  logic [63:0] generic_counter_d[MHPMCounterNum:1];
  logic [63:0] generic_counter_q[MHPMCounterNum:1];

  //internal signal to keep track of exception
  logic read_access_exception, update_access_exception;

  logic events[MHPMCounterNum:1];
  // Event selector (group+index). Width is MHPMEventWidth (8).
  logic [MHPMEventWidth-1:0] mhpmevent_d[MHPMCounterNum:1];
  logic [MHPMEventWidth-1:0] mhpmevent_q[MHPMCounterNum:1];

  // Sscofpmf state: OF + privilege-mode inhibit bits per HPM counter.
  // Layout mirrors the architectural mhpmeventN packing on RV64:
  //   [63] OF, [62] MINH, [61] SINH, [60] UINH; selector in the low bits.
  logic of_d[MHPMCounterNum:1], of_q[MHPMCounterNum:1];
  logic minh_d[MHPMCounterNum:1], minh_q[MHPMCounterNum:1];
  logic sinh_d[MHPMCounterNum:1], sinh_q[MHPMCounterNum:1];
  logic uinh_d[MHPMCounterNum:1], uinh_q[MHPMCounterNum:1];
  logic event_inhibited[MHPMCounterNum:1];

  // Event matrix: one 32-entry vector per group (see ariane_pkg::MHPMEvent*).
  // Selecting an event is then a plain index rather than a case statement that
  // every new feature has to edit. Undriven entries fold away in synthesis, so
  // the cost is the same 1-bit mux tree as before; the win is that a feature
  // registers its events in its own group without touching the legacy list.
  logic [MHPMEventGrpNum-1:0][MHPMEventIdxNum-1:0] event_group;
  logic [MHPMEventGrpWidth-1:0] event_grp_sel[MHPMCounterNum:1];
  logic [MHPMEventIdxWidth-1:0] event_idx_sel[MHPMCounterNum:1];
  // internal signal to detect event on multiple commit ports
  logic [CVA6Cfg.NrCommitPorts-1:0] load_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] store_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] branch_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] call_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] return_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] int_event;
  logic [CVA6Cfg.NrCommitPorts-1:0] fp_event;

  //Multiplexer
  always_comb begin : Mux
    events[MHPMCounterNum:1] = '{default: 0};
    event_group = '0;
    load_event = '{default: 0};
    store_event = '{default: 0};
    branch_event = '{default: 0};
    call_event = '{default: 0};
    return_event = '{default: 0};
    int_event = '{default: 0};
    fp_event = '{default: 0};

    for (int unsigned j = 0; j < CVA6Cfg.NrCommitPorts; j++) begin
      load_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == LOAD);
      store_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == STORE);
      branch_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == CTRL_FLOW);
      call_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == CTRL_FLOW && (commit_instr_i[j].op == ADD || commit_instr_i[j].op == JALR) && (commit_instr_i[j].rd == 'd1 || commit_instr_i[j].rd == 'd5));
      return_event[j] = commit_ack_i[j] & (commit_instr_i[j].op == JALR && commit_instr_i[j].rd == 'd0);
      int_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == ALU || commit_instr_i[j].fu == MULT);
      fp_event[j] = commit_ack_i[j] & (commit_instr_i[j].fu == FPU || commit_instr_i[j].fu == FPU_VEC);
    end

    // --- Group 0: legacy encoding (mhpmevent[7:5] == 0) ----------------------
    // These indices are architectural in practice: software and the device-tree
    // PMU mapping already use them. Never renumber an entry here.
    event_group[MHPMGrpLegacy][5'd0]  = 1'b0;
    event_group[MHPMGrpLegacy][5'd1]  = l1_icache_miss_i;  //L1 I-Cache misses
    event_group[MHPMGrpLegacy][5'd2]  = l1_dcache_miss_i;  //L1 D-Cache misses
    event_group[MHPMGrpLegacy][5'd3]  = itlb_miss_i;  //ITLB misses
    event_group[MHPMGrpLegacy][5'd4]  = dtlb_miss_i;  //DTLB misses
    event_group[MHPMGrpLegacy][5'd5]  = |load_event;  //Load accesses
    event_group[MHPMGrpLegacy][5'd6]  = |store_event;  //Store accesses
    event_group[MHPMGrpLegacy][5'd7]  = ex_i.valid;  //Exceptions
    event_group[MHPMGrpLegacy][5'd8]  = eret_i;  //Exception handler returns
    event_group[MHPMGrpLegacy][5'd9]  = |branch_event;  // Branch instructions
    event_group[MHPMGrpLegacy][5'd10] =
        resolved_branch_i.valid && resolved_branch_i.is_mispredict;  //Branch mispredicts
    event_group[MHPMGrpLegacy][5'd11] = branch_exceptions_i.valid;  //Branch exceptions
    // The standard software calling convention uses register x1 to hold the return address on a call
    // the unconditional jump is decoded as ADD op
    event_group[MHPMGrpLegacy][5'd12] = |call_event;  //Call
    event_group[MHPMGrpLegacy][5'd13] = |return_event;  //Return
    event_group[MHPMGrpLegacy][5'd14] = sb_full_i;  //MSB Full
    event_group[MHPMGrpLegacy][5'd15] = if_empty_i;  //Instruction fetch Empty
    event_group[MHPMGrpLegacy][5'd16] = l1_icache_access_i.req;  //L1 I-Cache accesses
    event_group[MHPMGrpLegacy][5'd17] =
        l1_dcache_access_i[0].data_req || l1_dcache_access_i[1].data_req ||
        l1_dcache_access_i[2].data_req;  //L1 D-Cache accesses
    event_group[MHPMGrpLegacy][5'd18] =
        (l1_dcache_miss_i && miss_vld_bits_i[0] == 8'hFF) ||
        (l1_dcache_miss_i && miss_vld_bits_i[1] == 8'hFF) ||
        (l1_dcache_miss_i && miss_vld_bits_i[2] == 8'hFF);  //eviction
    event_group[MHPMGrpLegacy][5'd19] = i_tlb_flush_i;  //I-TLB flush
    event_group[MHPMGrpLegacy][5'd20] = |int_event;  //Integer instructions
    event_group[MHPMGrpLegacy][5'd21] = |fp_event;  //Floating Point Instructions
    event_group[MHPMGrpLegacy][5'd22] = stall_issue_i;  //Pipeline bubbles

    // Group 1: U5 OoO / MLP (mhpmevent[7:5]==1). Indices stable once published.
    event_group[3'd1][5'd0] = sb_full_i | ooo_rename_stall_i | ooo_rob_full_i;  // rename/ROB backpressure
    event_group[3'd1][5'd1] = stall_issue_i | ooo_iq_full_i;                    // IQ / issue stall
    event_group[3'd1][5'd2] = resolved_branch_i.valid && resolved_branch_i.is_mispredict;
    event_group[3'd1][5'd3] = |load_event;     // load traffic
    event_group[3'd1][5'd4] = |store_event;    // store traffic
    event_group[3'd1][5'd5] = ooo_lsq_stall_i; // LSQ / memdep / STL stall
    event_group[3'd1][5'd6] = ooo_stl_forward_i; // store-to-load forward hits
    event_group[3'd1][5'd7] = ooo_rename_stall_i; // freelist / rename stall alone
    // Group 2: server memory hierarchy (mhpmevent[7:5]==2). Stable indices.
    event_group[3'd2][5'd0] = l3_miss_i;   // L3 miss
    event_group[3'd2][5'd1] = l3_hit_i;    // L3 hit
    event_group[3'd2][5'd2] = pf_issue_i;  // server PF issue
    event_group[3'd2][5'd3] = pf_train_i;  // server PF train
    event_group[3'd2][5'd4] = l2_miss_i;   // L2 miss (cluster)

    // Group 3: FSE / deep speculation recovery (mhpmevent[7:5]==3)
    event_group[3'd3][5'd0] = resolved_branch_i.valid && resolved_branch_i.is_mispredict;
    event_group[3'd3][5'd1] = spec_cancel_i;   // SpeculativeSb younger cancel
    event_group[3'd3][5'd2] = sb_full_i;       // in-flight window full
    event_group[3'd3][5'd3] = stall_issue_i;   // issue/RAW bubble
    event_group[3'd3][5'd4] = |load_event;     // load pressure
    event_group[3'd3][5'd5] = |store_event;    // store pressure

    // Group 4: Xg6lcai AI (mhpmevent[7:5]==MHPMGrpAI). See ariane_pkg.
    if (CVA6Cfg.AiCfg.MatrixEn) begin
      event_group[MHPMGrpAI][5'd0] = ai_pmu_op_i;
      event_group[MHPMGrpAI][5'd1] = ai_pmu_mma_i;
      event_group[MHPMGrpAI][5'd2] = ai_pmu_post_i;
      event_group[MHPMGrpAI][5'd3] = ai_pmu_t0_i;
      event_group[MHPMGrpAI][5'd4] = ai_pmu_busy_i;
    end

    // Groups 5..7 reserved.

    for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
      events[i] = event_group[event_grp_sel[i]][event_idx_sel[i]];
    end

  end

  for (genvar i = 1; i <= MHPMCounterNum; i++) begin : gen_event_sel
    assign event_grp_sel[i] = mhpmevent_q[i][MHPMEventWidth-1:MHPMEventIdxWidth];
    assign event_idx_sel[i] = mhpmevent_q[i][MHPMEventIdxWidth-1:0];
  end

  // Sscofpmf: scountovf bit i mirrors OF of mhpmcounter i (bits 0-2 hardwired 0;
  // only counters 3..MHPMCounterNum+2 exist here, indexed as 1..MHPMCounterNum).
  always_comb begin : scountovf_pack
    scountovf_o = '0;
    if (CVA6Cfg.SscofpmfEn) begin
      for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
        scountovf_o[i+2] = of_q[i];
      end
    end
  end
  assign lcofi_o = CVA6Cfg.SscofpmfEn ? (|scountovf_o) : 1'b0;

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
    if (CVA6Cfg.SscofpmfEn) begin
      for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
        unique case (priv_lvl_i)
          riscv::PRIV_LVL_M: event_inhibited[i] = minh_q[i];
          riscv::PRIV_LVL_S: event_inhibited[i] = sinh_q[i];
          riscv::PRIV_LVL_U: event_inhibited[i] = uinh_q[i];
          default:           event_inhibited[i] = 1'b0;
        endcase
      end
    end

    // Increment the non-inhibited counters with active events; set OF on wrap.
    for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
      if ((!debug_mode_i) && (!we_i) && !event_inhibited[i]) begin
        if ((events[i]) == 1 && (!mcountinhibit_i[i+2])) begin
          if (CVA6Cfg.SscofpmfEn && (&generic_counter_q[i])) begin
            of_d[i] = 1'b1;
          end
          generic_counter_d[i] = generic_counter_q[i] + 1'b1;
        end
      end
    end

    //Read
    if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_COUNTER_3)) && (addr_i < ( csr_addr_t'(riscv::CSR_MHPM_COUNTER_3) + MHPMCounterNum)) ) begin
      if (riscv::XLEN == 32) begin
        data_o = generic_counter_q[addr_i-riscv::CSR_MHPM_COUNTER_3+1][31:0];
      end else begin
        data_o = generic_counter_q[addr_i-riscv::CSR_MHPM_COUNTER_3+1];
      end
    end else if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_COUNTER_3H)) && (addr_i < ( csr_addr_t'(riscv::CSR_MHPM_COUNTER_3H) + MHPMCounterNum)) ) begin
      if (riscv::XLEN == 32) begin
        data_o = generic_counter_q[addr_i-riscv::CSR_MHPM_COUNTER_3H+1][63:32];
      end else begin
        read_access_exception = 1'b1;
      end
    end else if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_EVENT_3)) && (addr_i < (csr_addr_t'(riscv::CSR_MHPM_EVENT_3) + MHPMCounterNum)) ) begin
      // Pack architectural mhpmeventN: selector in low bits; OF/filter when Sscofpmf.
      data_o = CVA6Cfg.XLEN'(mhpmevent_q[addr_i-riscv::CSR_MHPM_EVENT_3+1]);
      if (CVA6Cfg.SscofpmfEn && CVA6Cfg.IS_XLEN64) begin
        data_o[63] = of_q[addr_i-riscv::CSR_MHPM_EVENT_3+1];
        data_o[62] = minh_q[addr_i-riscv::CSR_MHPM_EVENT_3+1];
        data_o[61] = sinh_q[addr_i-riscv::CSR_MHPM_EVENT_3+1];
        data_o[60] = uinh_q[addr_i-riscv::CSR_MHPM_EVENT_3+1];
      end
    end else if( (addr_i >= csr_addr_t'(riscv::CSR_HPM_COUNTER_3)) && (addr_i < (csr_addr_t'(riscv::CSR_HPM_COUNTER_3) + MHPMCounterNum)) ) begin
      if (riscv::XLEN == 32) begin
        data_o = generic_counter_q[addr_i-riscv::CSR_HPM_COUNTER_3+1][31:0];
      end else begin
        data_o = generic_counter_q[addr_i-riscv::CSR_HPM_COUNTER_3+1];
      end
    end else if( (addr_i > csr_addr_t'(riscv::CSR_HPM_COUNTER_3H)) && (addr_i < (csr_addr_t'(riscv::CSR_HPM_COUNTER_3H) + MHPMCounterNum)) ) begin
      if (riscv::XLEN == 32) begin
        data_o = generic_counter_q[addr_i-riscv::CSR_MHPM_COUNTER_3H+1][63:32];
      end else begin
        read_access_exception = 1'b1;
      end
    end

    //Write
    if (we_i) begin
      if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_COUNTER_3)) && (addr_i < (csr_addr_t'(riscv::CSR_MHPM_COUNTER_3) + MHPMCounterNum)) ) begin
        if (riscv::XLEN == 32) begin
          generic_counter_d[addr_i-riscv::CSR_MHPM_COUNTER_3+1][31:0] = data_i;
        end else begin
          generic_counter_d[addr_i-riscv::CSR_MHPM_COUNTER_3+1] = data_i;
        end
      end else if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_COUNTER_3H)) && (addr_i < (csr_addr_t'(riscv::CSR_MHPM_COUNTER_3H) + MHPMCounterNum)) ) begin
        if (riscv::XLEN == 32) begin
          generic_counter_d[addr_i-riscv::CSR_MHPM_COUNTER_3H+1][63:32] = data_i;
        end else begin
          update_access_exception = 1'b1;
        end
      end else if( (addr_i >= csr_addr_t'(riscv::CSR_MHPM_EVENT_3)) && (addr_i < csr_addr_t'(riscv::CSR_MHPM_EVENT_3) + MHPMCounterNum) ) begin
        // WARL: selector always writable; OF/filter only with Sscofpmf.
        // Writing 0 to OF clears it (spec); writing 1 is ignored (sticky set).
        mhpmevent_d[addr_i-riscv::CSR_MHPM_EVENT_3+1] = data_i[MHPMEventWidth-1:0];
        if (CVA6Cfg.SscofpmfEn && CVA6Cfg.IS_XLEN64) begin
          if (!data_i[63]) of_d[addr_i-riscv::CSR_MHPM_EVENT_3+1] = 1'b0;
          minh_d[addr_i-riscv::CSR_MHPM_EVENT_3+1] = data_i[62];
          sinh_d[addr_i-riscv::CSR_MHPM_EVENT_3+1] = data_i[61];
          uinh_d[addr_i-riscv::CSR_MHPM_EVENT_3+1] = data_i[60];
        end
      end
    end
  end

  //Registers
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      generic_counter_q <= '{default: 0};
      mhpmevent_q       <= '{default: 0};
      of_q              <= '{default: 0};
      minh_q            <= '{default: 0};
      sinh_q            <= '{default: 0};
      uinh_q            <= '{default: 0};
    end else begin
      generic_counter_q <= generic_counter_d;
      mhpmevent_q       <= mhpmevent_d;
      if (CVA6Cfg.SscofpmfEn) begin
        of_q   <= of_d;
        minh_q <= minh_d;
        sinh_q <= sinh_d;
        uinh_q <= uinh_d;
      end else begin
        of_q   <= '{default: 0};
        minh_q <= '{default: 0};
        sinh_q <= '{default: 0};
        uinh_q <= '{default: 0};
      end
    end
  end

endmodule
