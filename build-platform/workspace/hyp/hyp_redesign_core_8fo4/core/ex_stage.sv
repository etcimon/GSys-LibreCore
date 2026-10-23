// hyp8 provenance: ADAPTED (sv-timing emit base; staggered-ALU forward
// taps + HypCfg propagation)
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
// Date: 19.04.2017
// Modified by: Etienne Cimon
// Description: Instantiation of all functional units residing in the execute stage


module ex_stage
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    // hyp8: staged-ALU/multiplier configuration.
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter type bp_resolve_t = logic,
    parameter type branchpredict_sbe_t = logic,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type exception_t = logic,
    parameter type fu_data_t = logic,
    parameter type icache_areq_t = logic,
    parameter type icache_arsp_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic,
    parameter type lsu_ctrl_t = logic,
    parameter type x_result_t = logic,
    parameter type acc_mmu_req_t = logic,
    parameter type acc_mmu_resp_t = logic,
    parameter type cbo_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    output logic [1:0] phys_valid_o,
    output logic [1:0][G6LCCfg.PLEN-1:0] phys_addr_o,
    output logic [1:0][G6LCCfg.TRANS_ID_BITS-1:0] phys_id_o,
    output logic [1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] phys_hart_o,
    output logic [1:0][1:0] phys_size_o,
    output logic lu_replay_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] lu_replay_id_o,
    // hyp8 g10: LSQ checked bits in (publish gate inside the load unit)
    // and the load-unit replay out toward the IQ re-arm
    // (issue_stage -> g6lc_ooo_dispatch -> g6lc_iq).
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] ld_checked_i,
    output logic                             replay_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] replay_tid_o,
    // Fetch flush request - CONTROLLER
    input logic flush_i,
    // FSE S4: younger-only LSU cancel (from scoreboard)
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Scoreboard issued mask (store-buffer liveness assertion) - ISSUE_STAGE
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_live_i,
    // Debug mode is enabled - CSR_REGFILE
    input logic debug_mode_i,
    // rs1 forwarding - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.VLEN-1:0] rs1_forwarding_i,
    // rs2 forwarding - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.VLEN-1:0] rs2_forwarding_i,
    // FU data useful to execute instruction - ISSUE_STAGE
    input fu_data_t [G6LCCfg.NrIssuePorts-1:0] fu_data_i,
    // ALU to ALU bypass control - ISSUE_STAGE
    input alu_bypass_t alu_bypass_i,
    // hyp8 g7: per-issue-port in-ALU forward selects from the IRO; the
    // ALU0 select mirrors the alu_data[0] port pick below. Bit 2 selects
    // the registered A3 (result3_q) slot for LAT_ALU_FULL producers.
    input  logic [G6LCCfg.NrIssuePorts-1:0][3:0] alu_fwd_a_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][3:0] alu_fwd_b_i,
    // hyp8 g7: the ALU0 pipe-stage tids back to the IRO's forward-select
    // compare (A1 slot, then the registered A2/WB-record slot, then the
    // registered A3 slot).
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]     alu_fwd_tid_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]     alu_fwd_qtid_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]     alu_fwd_rtid_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]     alu_fwd_htid_o,
    // hyp8 g7: A1 low-32 forward tap (observability; the forward itself
    // is selected inside the ALU by fwd_a/fwd_b).
    output logic [31:0]                          alu_fwd_low_o,
    // PC of the current instruction - ISSUE_STAGE
    input logic [G6LCCfg.VLEN-1:0] pc_i,
    // FSE S5: SMT hart of CTRL_FLOW instruction - ISSUE_STAGE
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] branch_hart_i,
    // Is_zcmt instruction - ISSUE_STAGE
    input logic is_zcmt_i,
    // Report whether instruction is compressed - ISSUE_STAGE
    input logic is_compressed_instr_i,
    // Report instruction encoding - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0][31:0] tinst_i,
    // Fixed Latency Unit result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] flu_result_o,
    // ID of the scoreboard entry at which a=to write back - ISSUE_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] flu_trans_id_o,
    // Fixed Latency Unit exception - ISSUE_STAGE
    output exception_t flu_exception_o,
    // FLU is ready - ISSUE_STAGE
    output logic flu_ready_o,
    // CSR buffer admission credit - ISSUE_STAGE (OoO CSR hazard)
    output logic csr_ready_o,
    // FLU result is valid - ISSUE_STAGE
    output logic flu_valid_o,
    // ALU instruction is valid - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] alu_valid_i,
    // AES instruction is valid - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] aes_valid_i,
    // Branch unit instruction is valid - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] branch_valid_i,
    // Information of branch prediction - ISSUE_STAGE
    input branchpredict_sbe_t branch_predict_i,
    // The branch engine uses the write back from the ALU - several_modules
    output bp_resolve_t resolved_branch_o,
    // Signaling that we resolved the branch - ISSUE_STAGE
    output logic resolve_branch_o,
    // CSR instruction is valid - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] csr_valid_i,
    // CSR address to write - COMMIT_STAGE
    output logic [11:0] csr_addr_o,
    // CSR commit - COMMIT_STAGE
    input logic csr_commit_i,
    // MULT instruction is valid - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] mult_valid_i,
    // LSU is ready - ISSUE_STAGE (queue has a free slot, not "empty")
    output logic lsu_ready_o,
    // Queued LSU posts - ISSUE_STAGE
    output logic [2:0] lsu_count_o,
    // LSU instruction is valid - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] lsu_valid_i,
    // Load result is valid - ISSUE_STAGE
    output logic load_valid_o,
    // Load result valid - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] load_result_o,
    // Load instruction ID - ISSUE_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] load_trans_id_o,
    // Exception generated by load instruction - ISSUE_STAGE
    output exception_t load_exception_o,
    // Store result is valid - ISSUe_STAGE
    output logic store_valid_o,
    // Store result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] store_result_o,
    // Store instruction ID - ISSUE_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] store_trans_id_o,
    // Exception generated by store instruction - ISSUE_STAGE
    output exception_t store_exception_o,
    // LSU commit - COMMIT_STAGE
    input logic lsu_commit_i,
    // Commit queue ready to accept another commit request - COMMIT_STAGE
    output logic lsu_commit_ready_o,
    // Commit transaction ID - COMMIT_STAGE
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_tran_id_i,
    // T6b-4b: reclaim pointer (oldest live slot) — the store buffer's age
    // anchor. commit_tran_id_i stays the committing (port-0) tid.
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] oldest_live_tid_i,
    // N1d: the commit head is an unpublished load — speculative-store
    // stalls are futile while it pends (see store_buffer).
    input logic head_phys_pending_i,
    // TO_BE_COMPLETED - ACC_DISPATCHER
    input logic stall_st_pending_i,
    // TO_BE_COMPLETED - COMMIT_STAGE
    output logic no_st_pending_o,
    // Shared TLB is busy processing a multi-cycle flush
    output logic shared_tlb_flush_busy_o,
    // Atomic result is valid - COMMIT_STAGE
    input logic amo_valid_commit_i,
    // FU is ready - ISSUE_STAGE
    output logic fpu_ready_o,
    // FPU instruction is ready - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] fpu_valid_i,
    // FPU format - ISSUE_STAGE
    input logic [1:0] fpu_fmt_i,
    // FPU rm - ISSUE_STAGE
    input logic [2:0] fpu_rm_i,
    // FPU frm - ISSUE_STAGE
    input logic [2:0] fpu_frm_i,
    // FPU precision control - CSR_REGFILE
    input logic [6:0] fpu_prec_i,
    // FP-2: hart of the FPU op in EX - ISSUE_STAGE; under mixed residency the
    // issuing op's hart owns frm/fprec (the scalars track the active hart).
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] fpu_hart_i,
    // Per-hart frm/fprec banks - CSR_REGFILE
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][2:0] fpu_frm_b_i,
    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][6:0] fpu_prec_b_i,
    // FPU transaction ID - ISSUE_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] fpu_trans_id_o,
    // FPU result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] fpu_result_o,
    // FPU valid - ISSUE_STAGE
    output logic fpu_valid_o,
    // FPU exception - ISSUE_STAGE
    output exception_t fpu_exception_o,
    // FPU early valid - ISSUE_STAGE
    output logic fpu_early_valid_o,
    // ALU2 instruction is valid - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] alu2_valid_i,
    // CVXIF instruction is valid - ISSUE_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] x_valid_i,
    // CVXIF is ready - ISSUE_STAGE
    output logic x_ready_o,
    // CVXIF undecoded instruction
    input logic [31:0] x_off_instr_i,
    // CVXIF transaction ID - ISSUE_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] x_trans_id_o,
    // CVXIF exception - ISSUE_STAGE
    output exception_t x_exception_o,
    // CVXIF result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] x_result_o,
    // CVXIF result valid - ISSUE_STAGE
    output logic x_valid_o,
    // CVXIF write enable - ISSUE_STAGE
    output logic x_we_o,
    // CVXIF destination register - ISSUE_STAGE
    output logic [4:0] x_rd_o,
    // CVXIF Result interface - SUBSYSTEM
    input logic x_result_valid_i,
    input x_result_t x_result_i,
    output logic x_result_ready_o,
    // CVXIF Issue transaction rejected -> illegal instruction - ISSUE_STAGE
    input logic x_transaction_rejected_i,
    // accelerate port result is valid - ACC_DISPATCHER
    input logic acc_valid_i,
    // Accelerator MMU access
    input acc_mmu_req_t acc_mmu_req_i,
    output acc_mmu_resp_t acc_mmu_resp_o,
    // Enable virtual memory translation - CSR_REGFILE
    input logic enable_translation_i,
    // Enable G-Stage memory translation - CSR_REGFILE
    input logic enable_g_translation_i,
    // Enable virtual memory translation for load/stores - CSR_REGFILE
    input logic en_ld_st_translation_i,
    // Enable G-Stage memory translation for load/stores - CSR_REGFILE
    input logic en_ld_st_g_translation_i,
    // Flush TLB - CONTROLLER
    input logic flush_tlb_i,
    input logic flush_tlb_vvma_i,
    input logic flush_tlb_gvma_i,
    // Privilege mode - CSR_REGFILE
    input riscv::priv_lvl_t priv_lvl_i,
    // Data endianness - CSR REGFILE
    input logic mbe_i,
    // Virtualization mode - CSR_REGFILE
    input logic v_i,
    // Privilege level at which load and stores should happen - CSR_REGFILE
    input riscv::priv_lvl_t ld_st_priv_lvl_i,
    // Virtualization mode at which load and stores should happen - CSR_REGFILE
    input logic ld_st_v_i,
    // Instruction is hypervisor load/store - CSR_REGFILE
    output logic csr_hs_ld_st_inst_o,
    // Supervisor user memory - CSR_REGFILE
    input logic sum_i,
    // Virtual Supervisor user memory - CSR_REGFILE
    input logic vs_sum_i,
    // Make executable readable - CSR_REGFILE
    input logic mxr_i,
    // Make executable readable Virtual Supervisor - CSR_REGFILE
    input logic vmxr_i,
    // TO_BE_COMPLETED - CSR_REGFILE
    input logic [G6LCCfg.PPNW-1:0] satp_ppn_i,
    // TO_BE_COMPLETED - CSR_REGFILE
    input logic [G6LCCfg.ASID_WIDTH-1:0] asid_i,
    // TO_BE_COMPLETED - CSR_REGFILE
    input logic [G6LCCfg.PPNW-1:0] vsatp_ppn_i,
    // TO_BE_COMPLETED - CSR_REGFILE
    input logic [G6LCCfg.ASID_WIDTH-1:0] vs_asid_i,
    // TO_BE_COMPLETED - CSR_REGFILE
    input logic [G6LCCfg.PPNW-1:0] hgatp_ppn_i,
    // TO_BE_COMPLETED - CSR_REGFILE
    input logic [G6LCCfg.VMID_WIDTH-1:0] vmid_i,
    // icache translation response - CACHE
    input icache_arsp_t icache_areq_i,
    // icache translation request - CACHE
    output icache_areq_t icache_areq_o,
    // Data cache request output - CACHE
    input dcache_req_o_t [2:0] dcache_req_ports_i,
    // Data cache request input - CACHE
    output dcache_req_i_t [2:0] dcache_req_ports_o,
    // Write buffer is empty - CACHE
    input logic dcache_wbuffer_empty_i,
    // TO_BE_COMPLETED - CACHE
    input logic dcache_wbuffer_not_ni_i,
    // AMO request - CACHE
    output amo_req_t amo_req_o,
    // AMO response - CACHE
    input amo_resp_t amo_resp_i,
    // To count the instruction TLB misses - PERF_COUNTERS
    output logic itlb_miss_o,
    // To count the data TLB misses - PERF_COUNTERS
    output logic dtlb_miss_o,
    // Report the PMP configuration - CSR_REGFILE
    input riscv::pmpcfg_t [avoid_neg(G6LCCfg.NrPMPEntries-1):0] pmpcfg_i,
    // Report the PMP addresses - CSR_REGFILE
    input logic [avoid_neg(G6LCCfg.NrPMPEntries-1):0][G6LCCfg.PLEN-3:0] pmpaddr_i,
    // T6b-2b: active fetch hart and hart owning the in-flight LSU translation
    // request; the LSU-side inputs above carry the request hart's context, the
    // fet_* set below the fetch hart's. Identical values when NrHarts==1 or
    // SmtDrainedHandoff.
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] fetch_hart_i,
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] lsu_hart_o,
    // T6b-2b: check-stage context hart (registered lsu_hart_o under mixed
    // residency, identical otherwise); selects the PMP set in the bank.
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] lsu_chk_hart_o,
    input logic [G6LCCfg.ASID_WIDTH-1:0] fet_asid_i,
    input logic [G6LCCfg.ASID_WIDTH-1:0] fet_vs_asid_i,
    input logic [G6LCCfg.VMID_WIDTH-1:0] fet_vmid_i,
    input logic [G6LCCfg.PPNW-1:0] fet_satp_ppn_i,
    input logic [G6LCCfg.PPNW-1:0] fet_vsatp_ppn_i,
    input logic [G6LCCfg.PPNW-1:0] fet_hgatp_ppn_i,
    input logic fet_mxr_i,
    input logic fet_vmxr_i,
    input logic fet_mbe_i,
    input riscv::pmpcfg_t [avoid_neg(G6LCCfg.NrPMPEntries-1):0] fet_pmpcfg_i,
    input logic [avoid_neg(G6LCCfg.NrPMPEntries-1):0][G6LCCfg.PLEN-3:0] fet_pmpaddr_i,
    // Information dedicated to RVFI - RVFI
    output lsu_ctrl_t rvfi_lsu_ctrl_o,
    // Information dedicated to RVFI - RVFI
    output [G6LCCfg.PLEN-1:0] rvfi_mem_paddr_o,
    // Original instruction AES bits
    input logic [5:0] orig_instr_aes_i
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin ex_stage status=proposal target=10-adjusted-FO4
  // svt-plan: cone one_cycle_select and mult_valid feed a shared FLU
  // result/TID mux; independent new FU latencies create completion collisions.
  // svt-plan: reshape make completion capacity explicit: reserve future
  // fixed-latency slots or buffer each FU response before fair arbitration.
  // svt-plan: boundary FU completion packet -> selected writeback packet;
  // coordinate ALU, AES, branch, CSR and mult/serdiv availability schedules.
  // svt-plan: carry result, TID+generation, hart, exception/flags, operation
  // class and branch recovery payload; filter killed owners before publication.
  // svt-plan: capacity acknowledge issue only with guaranteed completion
  // storage; a fixed-latency producer cannot be backpressured after its last edge.
  // svt-plan: effect localizes wide result selection and ready propagation,
  // enabling actual intra-FU cuts instead of data-only output registers.
  // svt-plan: cost response queues/arbitration and possible writeback delay;
  // keep CSR side effects and branch redirect timing separate from result muxing.
  // svt-plan: limit completion bandwidth remains finite; carry latency to
  // IQ wakeup, forwarding and scoreboard completion consistently.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 42.8 adjusted FO4 on the
  // Nangate45 board): execute stage: the FLU's single writeback port serialises ALU / branch / CSR / mult / AES; a stage on any of them is an FLU redesign.
  // svt-pipe: require-contract
  // svt-pipe: protocol flu valid=flu_valid_o id=flu_trans_id_o
  // svt-pipe: result flu valid=flu_valid_o flu_result_o
  // svt-pipe: no-cut on=flu_result_o
  // svt-pipe: no-cut on=flu_valid_o
  // svt-pipe: cycle flu q=alu_result d=flu_result_o hold=flu_valid_o steps=1
  // svt-pipe: cut-ok flu on=flu_result_o

  // -------------------------
  // Fixed Latency Units
  // -------------------------
  // all fixed latency units share a single issue port and a sing write
  // port into the scoreboard. At the moment those are:
  // 1. ALU - all operations are single cycle
  // 2. Branch unit: operation is single cycle, the ALU is needed
  //    for comparison
  // 3. CSR: This is a small buffer which saves the address of the CSR.
  //    The value is then re-fetched once the instruction retires. The buffer
  //    is only a single entry deep, hence this operation will block all
  //    other operations once this buffer is full. This should not be a major
  //    concern though as CSRs are infrequent.
  // 4. Multiplier/Divider: The multiplier has a fixed latency of 1 cycle.
  //                        The issue logic will take care of not issuing
  //                        another instruction if it will collide on the
  //                        output port. Divisions are arbitrary in length
  //                        they will simply block the issue of all other
  //                        instructions.


  logic current_instruction_is_sfence_vma;
  logic current_instruction_is_hfence_vvma;
  logic current_instruction_is_hfence_gvma;
  // These two register store the rs1 and rs2 parameters in case of `SFENCE_VMA`
  // instruction to be used for TLB flush in the next clock cycle.
  logic [G6LCCfg.VMID_WIDTH-1:0] vmid_to_be_flushed;
  logic [G6LCCfg.ASID_WIDTH-1:0] asid_to_be_flushed;
  logic [G6LCCfg.VLEN-1:0] vaddr_to_be_flushed;
  logic [G6LCCfg.GPLEN-1:0] gpaddr_to_be_flushed;

  // from ALU to branch unit
  logic alu_branch_res;  // branch comparison result
  exception_t branch_exception;  // B2 exception record, published only with br_lane_v
  logic [G6LCCfg.NrALUs-1:0][G6LCCfg.XLEN-1:0] alu_result;
  logic [G6LCCfg.XLEN-1:0] csr_result, mult_result, aes_result;
  logic [G6LCCfg.VLEN-1:0] branch_result;
  bp_resolve_t resolved_branch;
  logic csr_ready, mult_ready;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] mult_trans_id;
  logic mult_valid;

  fu_data_t [G6LCCfg.NrALUs-1:0] alu_data;

  logic [G6LCCfg.NrIssuePorts-1:0] one_cycle_select;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=ex_stage  region=2690  makespan=9.500 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: current_instruction_is_sfence_vma  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to current_instruction_is_sfence_vma
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node9957 c=3.50 slack=6.00 */
//     /* node9958 c=4.50 slack=5.00 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     current_instruction_is_sfence_vma <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node9959 c=9.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=ex_stage  region=2693  makespan=13.500 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: asid_to_be_flushed  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to asid_to_be_flushed
// order expect: vaddr_to_be_flushed  ready_cycle=2  ready_fo4=13.500  OpenSTA: report_timing -from clk_i -to vaddr_to_be_flushed
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node9962 c=3.50 slack=10.00 */
//     /* node9963 c=3.50 slack=10.00 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     asid_to_be_flushed <= …; // sv-timing: cycle 2/2 on clk_i
//     vaddr_to_be_flushed <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node9964 c=13.50 slack=0.00 */
//     /* node9965 c=13.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign one_cycle_select = alu_valid_i | branch_valid_i | csr_valid_i | aes_valid_i;

  fu_data_t one_cycle_data;
  fu_data_t branch_data;
  logic [G6LCCfg.VLEN-1:0] rs1_forwarding;
  logic [G6LCCfg.VLEN-1:0] rs2_forwarding;
  always_comb begin
    // Priority: highest issue port with a one-cycle op (branch/ALU/CSR/AES)
    one_cycle_data = one_cycle_select[0] ? fu_data_i[0] : '0;
    rs1_forwarding = rs1_forwarding_i[0];
    rs2_forwarding = rs2_forwarding_i[0];
    if (G6LCCfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        if (one_cycle_select[p]) begin
          one_cycle_data = fu_data_i[p];
          rs1_forwarding = rs1_forwarding_i[p];
          rs2_forwarding = rs2_forwarding_i[p];
        end
      end
    end
  end
  // I14: branch_unit fu_data is the CF issue port, never a later one-cycle
  // steal. SI const-folds to fu_data_i[0]. Same pick as IRO pc/compressed/bp.
  always_comb begin
    branch_data = fu_data_i[0];
    if (G6LCCfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        if (branch_valid_i[p]) branch_data = fu_data_i[p];
      end
      if (branch_valid_i[0]) branch_data = fu_data_i[0];
    end
  end

  // 1. ALU(s) (combinatorial)
  // I14: a CF's compare uses that port's operands. I4ak: else if port0 is
  // ALU, compute port0 — do not let a later one-cycle steal ALU0.
  assign alu_data[0] = (|branch_valid_i) ? branch_data :
                       (alu_valid_i[0] ? fu_data_i[0] : one_cycle_data);

  // Secondary ALU input: first issue port asserting alu2_valid (priority low→high)
  if (G6LCCfg.NrALUs >= 2) begin : gen_alu2_data_sel
    always_comb begin
      alu_data[1] = '0;
      for (int unsigned p = 0; p < G6LCCfg.NrIssuePorts; p++) begin
        if (alu2_valid_i[p]) alu_data[1] = fu_data_i[p];
      end
    end
  end

  // Extra ALUs: pair issue port p with ALU index p when available
  for (genvar a = 2; a < G6LCCfg.NrALUs; a++) begin : gen_extra_alu_data
    if (a < G6LCCfg.NrIssuePorts) begin
      assign alu_data[a] = alu_valid_i[a] ? fu_data_i[a] : '0;
    end else begin
      assign alu_data[a] = '0;
    end
  end

  // hyp8 g7: the ALU0 forward select mirrors the alu_data[0] port pick:
  // a branch steals the shared pipe first, then port 0's ALU op, then the
  // highest one-cycle port. Each pick carries that port's own spec-arm
  // metadata, so the forward tracks the actual occupant.
  logic [3:0] alu0_fwd_a, alu0_fwd_b;
  always_comb begin
    alu0_fwd_a = '0;
    alu0_fwd_b = '0;
    if (one_cycle_select[0]) begin
      alu0_fwd_a = alu_fwd_a_i[0];
      alu0_fwd_b = alu_fwd_b_i[0];
    end
    if (G6LCCfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        if (one_cycle_select[p]) begin
          alu0_fwd_a = alu_fwd_a_i[p];
          alu0_fwd_b = alu_fwd_b_i[p];
        end
      end
    end
    if (alu_valid_i[0]) begin
      alu0_fwd_a = alu_fwd_a_i[0];
      alu0_fwd_b = alu_fwd_b_i[0];
    end
    if (|branch_valid_i) begin
      alu0_fwd_a = '0;
      alu0_fwd_b = '0;
      if (G6LCCfg.SuperscalarEn) begin
        for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
          if (branch_valid_i[p]) begin
            alu0_fwd_a = alu_fwd_a_i[p];
            alu0_fwd_b = alu_fwd_b_i[p];
          end
        end
      end
      if (branch_valid_i[0]) begin
        alu0_fwd_a = alu_fwd_a_i[0];
        alu0_fwd_b = alu_fwd_b_i[0];
      end
    end
  end

  logic alu_s2_a3, alu_s3_a3;
  // hyp8: per-ALU result ownership of the packet on each fu_data port --
  // an issued ALU result (alu_in / the actual per-port ALU valids), not
  // merely a decoded one-cycle packet. Driven below beside alu_in.
  logic [G6LCCfg.NrALUs-1:0] alu_result_owner;
  alu_wrapper #(
      .G6LCCfg  (G6LCCfg),
      .HypCfg   (HypCfg),
      .fu_data_t(fu_data_t)
  ) alu_wrapper_i (
      .clk_i,
      .rst_ni,
      .alu_bypass_i    (alu_bypass_i),
      .fu_data_i       (alu_data),
      .fwd_a_i         (alu0_fwd_a),
      .fwd_b_i         (alu0_fwd_b),
      .result_valid_i  (alu_result_owner),
      .result_o        (alu_result),
      .alu_branch_res_o(alu_branch_res),
      .alu_fwd_low_o   (alu_fwd_low_o),
      .alu_fwd_tid_o   (alu_fwd_tid_o),
      .alu_fwd_qtid_o  (alu_fwd_qtid_o),
      .alu_fwd_rtid_o  (alu_fwd_rtid_o),
      .alu_fwd_htid_o  (alu_fwd_htid_o),
      .alu_s2_a3_o     (alu_s2_a3),
      .alu_s3_a3_o     (alu_s3_a3)
  );

  // 2. Branch Unit (combinatorial)
  // we don't silence the branch unit as this is already critical and we do
  // not want to add another layer of logic
  branch_unit #(
      .G6LCCfg(G6LCCfg),
      .HypCfg(HypCfg),
      .bp_resolve_t(bp_resolve_t),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .exception_t(exception_t),
      .fu_data_t(fu_data_t)
  ) branch_unit_i (
      .clk_i,
      .rst_ni,
      .flush_i,
      .v_i,
      .debug_mode_i,
      .fu_data_i         (branch_data),
      .pc_i,
      .hart_id_i         (branch_hart_i),
      .is_zcmt_i,
      .is_compressed_instr_i,
      .branch_valid_i    (|branch_valid_i),
      .branch_comp_res_i (alu_branch_res),
      .branch_result_o   (branch_result),
      .branch_predict_i,
      .resolved_branch_o (resolved_branch),
      .resolve_branch_o  (resolve_branch_raw),
      .branch_exception_o(branch_exception)
  );

  // 3. CSR (sequential)
  csr_buffer #(
      .G6LCCfg  (G6LCCfg),
      .HypCfg   (HypCfg),
      .fu_data_t(fu_data_t)
  ) csr_buffer_i (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .fu_data_i   (one_cycle_data),
      .csr_valid_i (|csr_valid_i),
      .csr_ready_o (csr_ready),
      .csr_result_o(csr_result),
      .csr_commit_i,
      .csr_commit_tid_i(commit_tran_id_i),
      .csr_addr_o
  );

  // -------------------------------------------------------
  // hyp8 g7: FLU lane records.
  //
  // Every unit's data register lives inside the FU itself: the ALU's A2
  // result_q, the branch unit's B2 resolve/result registers, the AES
  // stage-2 registers and the mult pipeline. This block carries only the
  // {valid, trans_id} bookkeeping across the same number of edges (plus a
  // one-deep operand_a capture for the CSR op, whose "result" is the rs1
  // passthrough csr_result_o), so the FLU writeback record presented to
  // the scoreboard is assembled from aligned lane records, never from
  // live issue inputs -- under the staged FUs a live fu_data_i field at
  // completion time would carry a *different* instruction's trans_id
  // (the emit base's one-cycle select). The IRO-acceptance FLU reservation
  // (g6lc_flu_reserve) admits at most one lane whose completion lands on
  // this shared port per cycle, so the select below is a record merge,
  // not an arbitration.
  //
  // Kill semantics: flush_i clears every lane record. A record whose tid
  // is already in cancelled_mask_i is suppressed at presentation -- H20:
  // a writeback landing in the resolve cycle of an op cancelled by that
  // resolve must not install. The scoreboard lifecycle install checks the
  // mask as well; the gate here additionally keeps the stale record off
  // the PRF write port.
  // -------------------------------------------------------
  localparam bit ALU_STAG = (HypCfg.AluStages >= 2) && HypCfg.AluStaggered;

  // Lane-in selects mirror the emit's result-mux priority (the
  // reservation table already guarantees at most one of these fires).
  logic br_in, alu_in, csr_in, aes_in;
  assign br_in  = |branch_valid_i;
  assign alu_in = ~br_in & |alu_valid_i;
  assign csr_in = ~br_in & ~|alu_valid_i & |csr_valid_i;
  assign aes_in = ~br_in & ~|alu_valid_i & ~csr_in & |aes_valid_i;

  // Result ownership per ALU slot: bit 0 mirrors the ALU0 lane-in select
  // (a branch packet sharing the pipe owns a compare, not a result);
  // bit 1 is any issued alu2 packet; extra ALUs take their port's ALU
  // valid. flush_i drops ownership for the killed packet's cycle.
  assign alu_result_owner[0] = alu_in && !flush_i;
  if (G6LCCfg.NrALUs >= 2) begin : gen_alu2_owner
    assign alu_result_owner[1] = (|alu2_valid_i) && !flush_i;
  end
  for (genvar a = 2; a < G6LCCfg.NrALUs; a++) begin : gen_alu_owner
    if (a < G6LCCfg.NrIssuePorts) begin
      assign alu_result_owner[a] = alu_valid_i[a] && !flush_i;
    end else begin
      assign alu_result_owner[a] = 1'b0;
    end
  end

  // Staggered ALU: the A2 register inside the ALU holds result_q and
  // fwd_tid2_q; only the valid needs the two-edge shift here. With
  // AluStages==3 the A3-class (LAT_ALU_FULL) records land one edge later:
  // alu_vld_q3 plus the ALU-exported slot-class taps pick the +2 or +3
  // record (the take-gate's WB reservation keeps them disjoint).
  logic alu_vld_q, alu_vld_q2, alu_vld_q3;
  // Comb-ALU fallback (ALU_STAG==0): the ex_stage register IS the record.
  logic                          alu_res_vld_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] alu_tid_q;
  logic [G6LCCfg.XLEN-1:0]         alu_res_q;
  // CSR / AES single-edge lane records.
  logic                          csr_vld_q, aes_vld_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] csr_tid_q, aes_tid_q;
  logic [G6LCCfg.XLEN-1:0]         csr_res_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : flu_lane_regs
    if (!rst_ni) begin
      alu_vld_q     <= 1'b0;
      alu_vld_q2    <= 1'b0;
      alu_vld_q3    <= 1'b0;
      alu_res_vld_q <= 1'b0;
      alu_tid_q     <= '0;
      alu_res_q     <= '0;
      csr_vld_q     <= 1'b0;
      csr_tid_q     <= '0;
      csr_res_q     <= '0;
      aes_vld_q     <= 1'b0;
      aes_tid_q     <= '0;
    end else if (flush_i) begin
      alu_vld_q     <= 1'b0;
      alu_vld_q2    <= 1'b0;
      alu_vld_q3    <= 1'b0;
      alu_res_vld_q <= 1'b0;
      csr_vld_q     <= 1'b0;
      aes_vld_q     <= 1'b0;
    end else begin
      alu_vld_q     <= alu_in;
      alu_vld_q2    <= alu_vld_q;
      alu_vld_q3    <= alu_vld_q2;
      // comb-mode record: I4ak pick -- port0's tid when port0 is the ALU
      // op, else the highest one-cycle port's tid (same source the staged
      // mode reaches via the ALU's own fwd_tid chain).
      alu_res_vld_q <= alu_in;
      alu_tid_q     <= alu_valid_i[0] ? fu_data_i[0].trans_id
                                      : one_cycle_data.trans_id;
      alu_res_q     <= alu_result[0];
      csr_vld_q     <= csr_in;
      csr_tid_q     <= one_cycle_data.trans_id;
      csr_res_q     <= csr_result;
      aes_vld_q     <= aes_in;
      aes_tid_q     <= one_cycle_data.trans_id;
    end
  end

  // The branch lane's record is the B2 output itself: resolved_branch
  // carries .valid/.trans_id and branch_result is the B2 result register.
  logic                          alu_lane_v_raw;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] alu_lane_tid;
  logic [G6LCCfg.XLEN-1:0]         alu_lane_res;
  // hyp8 r5: with AluStages==3 the A3-class (LAT_ALU_FULL) record is due
  // at +3 in the result3_q slot while low-class ops stay at +2 in
  // result_q. The two terms are disjoint -- the IRO-acceptance WB
  // reservation admits no +2 producer whose arrival would coincide with
  // a +3 completion.
  assign alu_lane_v_raw = ALU_STAG ? ((alu_vld_q2 & ~alu_s2_a3) |
                                     (alu_vld_q3 &  alu_s3_a3))
                                   : alu_res_vld_q;
  assign alu_lane_tid   = ALU_STAG ? ((alu_vld_q3 & alu_s3_a3) ? alu_fwd_rtid_o
                                                             : alu_fwd_qtid_o)
                                   : alu_tid_q;
  assign alu_lane_res   = ALU_STAG ? alu_result[0]  : alu_res_q;

  logic resolve_branch_raw;
  logic br_lane_v, alu_lane_v, csr_lane_v, aes_lane_v;
  assign br_lane_v  = resolved_branch.valid & ~cancelled_mask_i[resolved_branch.trans_id]
                    & sb_live_i[resolved_branch.trans_id];
  // A younger branch still in B1 when an older mispredict cancels its TID
  // must not publish its redirect: both the resolve pulse and the record
  // are qualified by the same cancellation-aware lane valid. A branch's
  // own flush is still allowed (no combinational !flush_i here).
  always_comb begin
    resolved_branch_o = resolved_branch;
    resolved_branch_o.valid = br_lane_v;
  end
  assign resolve_branch_o = resolve_branch_raw && br_lane_v;
  assign alu_lane_v = alu_lane_v_raw & ~cancelled_mask_i[alu_lane_tid];
  assign csr_lane_v = csr_vld_q & ~cancelled_mask_i[csr_tid_q];
  assign aes_lane_v = aes_vld_q & ~cancelled_mask_i[aes_tid_q];

  assign flu_valid_o = br_lane_v | alu_lane_v | csr_lane_v | aes_lane_v |
                       mult_valid;

  // FLU writeback record merge (record select, priority as in the emit:
  // branch > alu > csr > mult > aes; the reservation table makes the
  // priority unreachable in practice). The exception travels with the
  // winning branch record only -- an ALU/CSR/mult/AES completion must not
  // publish a branch's trap.
  always_comb begin
    flu_result_o    = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, branch_result};
    flu_trans_id_o  = resolved_branch.trans_id;
    flu_exception_o = '0;
    if (br_lane_v) begin
      // I14: flu tid/result of a CF is the resolving op's own record.
      flu_result_o    = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, branch_result};
      flu_trans_id_o  = resolved_branch.trans_id;
      flu_exception_o = branch_exception;
    end else if (alu_lane_v) begin
      flu_result_o   = alu_lane_res;
      flu_trans_id_o = alu_lane_tid;
    end else if (csr_lane_v) begin
      flu_result_o   = csr_res_q;
      flu_trans_id_o = csr_tid_q;
    end else if (mult_valid) begin
      flu_result_o   = mult_result;
      flu_trans_id_o = mult_trans_id;
    end else if (aes_lane_v) begin
      flu_result_o   = aes_result;
      flu_trans_id_o = aes_tid_q;
    end
  end

//pragma translate_off
  // Actual publication collision check: the IRO-acceptance reservation
  // admits at most one FLU completion per cycle; a live overlap here
  // means the merge above silently picked one record over another.
  always_ff @(negedge clk_i) begin
    if (rst_ni && !flush_i)
      assert ($onehot0({br_lane_v, alu_lane_v, csr_lane_v, aes_lane_v,
                       mult_valid}))
        else $error("ex_stage: FLU publication collision br=%b alu=%b csr=%b aes=%b mult=%b",
                    br_lane_v, alu_lane_v, csr_lane_v, aes_lane_v, mult_valid);
  end
//pragma translate_on

  // ready flags for FLU
  // OoO: csr_ready gates only the CSR hazard in issue_read_operands, not the
  // whole FLU — the dual-entry buffer holds two outstanding CSRs, so a pending
  // one no longer stops ALU/branch issue.
  always_comb begin
    flu_ready_o = mult_ready & (G6LCCfg.OoOEn ? 1'b1 : csr_ready);
  end
  assign csr_ready_o = csr_ready;

  // 4. Multiplication (Sequential)
  fu_data_t mult_data;
  // input silencing of multiplier — priority pick across issue ports
  always_comb begin
    mult_data = mult_valid_i[0] ? fu_data_i[0] : '0;
    if (G6LCCfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        if (mult_valid_i[p]) mult_data = fu_data_i[p];
      end
    end
  end

  mult #(
      .G6LCCfg  (G6LCCfg),
      .HypCfg   (HypCfg),
      .fu_data_t(fu_data_t)
  ) i_mult (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .mult_valid_i   (|mult_valid_i),
      .fu_data_i      (mult_data),
      .result_o       (mult_result),
      .mult_valid_o   (mult_valid),
      .mult_ready_o   (mult_ready),
      .mult_trans_id_o(mult_trans_id)
  );

  // ----------------
  // FPU
  // ----------------
  logic fpu_valid;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] fpu_trans_id;
  logic [G6LCCfg.XLEN-1:0] fpu_result;

  generate
    if (G6LCCfg.FpPresent) begin : fpu_gen
      fu_data_t fpu_data;
      always_comb begin
        fpu_data = fpu_valid_i[0] ? fu_data_i[0] : '0;
        if (G6LCCfg.SuperscalarEn) begin
          for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
            if (fpu_valid_i[p]) fpu_data = fu_data_i[p];
          end
        end
      end

      // FP-2: mixed-residency frm/fprec. The scalar CSR outputs track the
      // ACTIVE hart; when two harts are co-resident a peer's FPU op issued
      // this cycle would otherwise be rounded/precisioned with the wrong
      // hart's context. Constant-folds to the scalars wherever FPU ops can
      // only belong to one hart (NrHarts==1 or drained handoff).
      localparam bit FPU_HART_CTX = G6LCCfg.FpPresent && G6LCCfg.NrHarts > 1 &&
                                    !G6LCCfg.SmtDrainedHandoff;
      logic [2:0] fpu_frm_ctx;
      logic [6:0] fpu_prec_ctx;
`ifdef G6LC_MUT_FPU_ACTIVE_FRM
      // Review mutation: regress frm to the active hart — hart-tagged DYN
      // rounding must then fail under mixed residency.
      assign fpu_frm_ctx  = fpu_frm_i;
`else
      assign fpu_frm_ctx  = FPU_HART_CTX ? fpu_frm_b_i[fpu_hart_i] : fpu_frm_i;
`endif
      assign fpu_prec_ctx = FPU_HART_CTX ? fpu_prec_b_i[fpu_hart_i] : fpu_prec_i;

      fpu_wrap #(
          .G6LCCfg(G6LCCfg),
          .HypCfg(HypCfg),
          .exception_t(exception_t),
          .fu_data_t(fu_data_t)
      ) fpu_i (
          .clk_i,
          .rst_ni,
          .flush_i,
          .cancelled_mask_i,
          .fpu_valid_i(|fpu_valid_i),
          .fpu_ready_o,
          .fu_data_i(fpu_data),
          .fpu_fmt_i,
          .fpu_rm_i,
          .fpu_frm_i               (fpu_frm_ctx),
          .fpu_prec_i              (fpu_prec_ctx),
          .fpu_trans_id_o(fpu_trans_id),
          .result_o(fpu_result),
          .fpu_valid_o(fpu_valid),
          .fpu_exception_o,
          .fpu_early_valid_o
      );
    end else begin : no_fpu_gen
      assign fpu_ready_o       = '0;
      assign fpu_trans_id      = '0;
      assign fpu_result        = '0;
      assign fpu_valid         = '0;
      assign fpu_exception_o   = '0;
      assign fpu_early_valid_o = '0;
    end
  endgenerate

  // result MUX
  // This is really explicit so that synthesis tools can elide unused signals
  // Secondary ALU result rides the FPU WB port when present (legacy dual-issue).
  // hyp8 g7: ALU2 gets the same lane-record treatment as ALU0 -- its A2
  // register lives inside the ALU, so only {valid, trans_id} shift here
  // (the secondary ALUs expose no fwd_tid tap); comb mode captures
  // result+tid+valid one edge deep as the record.
  logic                          alu2_lane_v;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] alu2_lane_tid;
  logic [G6LCCfg.XLEN-1:0]         alu2_lane_res;
  if (G6LCCfg.SuperscalarEn && G6LCCfg.NrALUs >= 2) begin : gen_alu2_lane
    logic                          alu2_vld_q, alu2_vld_q2;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] alu2_tid_q, alu2_tid_q2;
    logic [G6LCCfg.XLEN-1:0]         alu2_res_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin : alu2_lane_regs
      if (!rst_ni) begin
        alu2_vld_q  <= 1'b0;
        alu2_vld_q2 <= 1'b0;
        alu2_tid_q  <= '0;
        alu2_tid_q2 <= '0;
        alu2_res_q  <= '0;
      end else if (flush_i) begin
        alu2_vld_q  <= 1'b0;
        alu2_vld_q2 <= 1'b0;
      end else begin
        alu2_vld_q  <= |alu2_valid_i;
        alu2_vld_q2 <= alu2_vld_q;
        alu2_tid_q  <= alu_data[1].trans_id;
        alu2_tid_q2 <= alu2_tid_q;
        alu2_res_q  <= alu_result[1];
      end
    end
    assign alu2_lane_v   = (ALU_STAG ? alu2_vld_q2 : alu2_vld_q) &
                           ~cancelled_mask_i[alu2_lane_tid];
    assign alu2_lane_tid = ALU_STAG ? alu2_tid_q2 : alu2_tid_q;
    assign alu2_lane_res = ALU_STAG ? alu_result[1] : alu2_res_q;
  end else begin : gen_no_alu2_lane
    assign alu2_lane_v   = 1'b0;
    assign alu2_lane_tid = '0;
    assign alu2_lane_res = '0;
  end

  if (G6LCCfg.SuperscalarEn && G6LCCfg.NrALUs >= 2) begin
    if (G6LCCfg.FpPresent) begin
      assign fpu_valid_o    = fpu_valid || alu2_lane_v;
      assign fpu_result_o   = fpu_valid ? fpu_result   : alu2_lane_res;
      assign fpu_trans_id_o = fpu_valid ? fpu_trans_id : alu2_lane_tid;
    end else begin
      assign fpu_valid_o    = alu2_lane_v;
      assign fpu_result_o   = alu2_lane_res;
      assign fpu_trans_id_o = alu2_lane_tid;
    end
  end else begin
    if (G6LCCfg.FpPresent) begin
      assign fpu_valid_o    = fpu_valid;
      assign fpu_result_o   = fpu_result;
      assign fpu_trans_id_o = fpu_trans_id;
    end else begin
      assign fpu_valid_o    = '0;
      assign fpu_result_o   = '0;
      assign fpu_trans_id_o = '0;
    end
  end

  // ----------------
  // Load-Store Unit
  // ----------------
  fu_data_t lsu_data;
  logic [31:0] lsu_tinst;
  logic speculative_load;
  always_comb begin
    lsu_data = lsu_valid_i[0] ? fu_data_i[0] : '0;
    lsu_tinst = tinst_i[0];
    speculative_load = 1'b0;

    if (G6LCCfg.SuperscalarEn) begin
      for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
        if (lsu_valid_i[p]) begin
          lsu_data  = fu_data_i[p];
          lsu_tinst = tinst_i[p];
          // Load after same-cycle branch on any earlier port is speculative
          if (G6LCCfg.SpeculativeSb) begin
            for (int unsigned e = 0; e < p; e++) begin
              if (branch_valid_i[e]) speculative_load = 1'b1;
            end
          end
        end
      end
    end
  end

  load_store_unit #(
      .G6LCCfg   (G6LCCfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .fu_data_t (fu_data_t),
      .icache_areq_t(icache_areq_t),
      .icache_arsp_t(icache_arsp_t),
      .icache_dreq_t(icache_dreq_t),
      .icache_drsp_t(icache_drsp_t),
      .lsu_ctrl_t(lsu_ctrl_t),
      .cbo_t(cbo_t),
      .acc_mmu_req_t(acc_mmu_req_t),
      .acc_mmu_resp_t(acc_mmu_resp_t),
      .bp_resolve_t(bp_resolve_t)
  ) lsu_i (
      .clk_i,
      .rst_ni,
      .phys_valid_o, .phys_addr_o, .phys_id_o, .phys_hart_o, .phys_size_o,
      .lu_replay_o, .lu_replay_id_o,
      .ld_checked_i,
      .replay_o, .replay_tid_o,
      .flush_i,
      .cancelled_mask_i,
      .sb_live_i,
      .stall_st_pending_i,
      .no_st_pending_o,
      .shared_tlb_flush_busy_o(shared_tlb_flush_busy_o),
      .fu_data_i              (lsu_data),
      .lsu_ready_o,
      .lsu_count_o,
      .lsu_valid_i            (|lsu_valid_i),
      .speculative_load_i     (speculative_load),
      .load_trans_id_o,
      .load_result_o,
      .load_valid_o,
      .load_exception_o,
      .store_trans_id_o,
      .store_result_o,
      .store_valid_o,
      .store_exception_o,
      .commit_i               (lsu_commit_i),
      .commit_ready_o         (lsu_commit_ready_o),
      .commit_tran_id_i,
      .oldest_live_tid_i,
      .head_phys_pending_i,
      .resolved_branch_i      (resolved_branch),
      .enable_translation_i,
      .enable_g_translation_i,
      .en_ld_st_translation_i,
      .en_ld_st_g_translation_i,
      .acc_mmu_req_i,
      .acc_mmu_resp_o,
      .icache_areq_i,
      .icache_areq_o,
      .priv_lvl_i,
      .mbe_i,
      .v_i,
      .ld_st_priv_lvl_i,
      .ld_st_v_i,
      .csr_hs_ld_st_inst_o,
      .sum_i,
      .vs_sum_i,
      .mxr_i,
      .vmxr_i,
      .satp_ppn_i,
      .vsatp_ppn_i,
      .hgatp_ppn_i,
      .asid_i,
      .vs_asid_i,
      .asid_to_be_flushed_i   (asid_to_be_flushed),
      .vmid_i,
      .vmid_to_be_flushed_i   (vmid_to_be_flushed),
      .vaddr_to_be_flushed_i  (vaddr_to_be_flushed),
      .gpaddr_to_be_flushed_i (gpaddr_to_be_flushed),
      .flush_tlb_i,
      .flush_tlb_vvma_i,
      .flush_tlb_gvma_i,
      .itlb_miss_o,
      .dtlb_miss_o,
      .dcache_req_ports_i,
      .dcache_req_ports_o,
      .dcache_wbuffer_empty_i,
      .dcache_wbuffer_not_ni_i,
      .amo_valid_commit_i,
      .amo_req_o,
      .amo_resp_i,
      .tinst_i                (lsu_tinst),
      .pmpcfg_i,
      .pmpaddr_i,
      .fetch_hart_i           (fetch_hart_i),
      .lsu_hart_o             (lsu_hart_o),
      .lsu_chk_hart_o         (lsu_chk_hart_o),
      .fet_asid_i             (fet_asid_i),
      .fet_vs_asid_i          (fet_vs_asid_i),
      .fet_vmid_i             (fet_vmid_i),
      .fet_satp_ppn_i         (fet_satp_ppn_i),
      .fet_vsatp_ppn_i        (fet_vsatp_ppn_i),
      .fet_hgatp_ppn_i        (fet_hgatp_ppn_i),
      .fet_mxr_i              (fet_mxr_i),
      .fet_vmxr_i             (fet_vmxr_i),
      .fet_mbe_i              (fet_mbe_i),
      .fet_pmpcfg_i           (fet_pmpcfg_i),
      .fet_pmpaddr_i          (fet_pmpaddr_i),
      .rvfi_lsu_ctrl_o,
      .rvfi_mem_paddr_o
  );

  if (G6LCCfg.CvxifEn) begin : gen_cvxif
    fu_data_t cvxif_data;
    always_comb begin
      // CVXIF is port-0 only by structural hazard; keep priority scan for safety
      cvxif_data = x_valid_i[0] ? fu_data_i[0] : '0;
      if (G6LCCfg.SuperscalarEn) begin
        for (int unsigned p = 1; p < G6LCCfg.NrIssuePorts; p++) begin
          if (x_valid_i[p]) cvxif_data = fu_data_i[p];
        end
      end
    end

    cvxif_fu #(
        .G6LCCfg(G6LCCfg),
        .exception_t(exception_t),
        .x_result_t(x_result_t)
    ) cvxif_fu_i (
        .clk_i,
        .rst_ni,
        .v_i,
        .x_valid_i(|x_valid_i),
        .x_trans_id_i(cvxif_data.trans_id),
        .x_illegal_i(x_transaction_rejected_i),
        .x_off_instr_i,
        .x_ready_o,
        .x_trans_id_o,
        .x_exception_o,
        .x_result_o,
        .x_valid_o,
        .x_we_o,
        .x_rd_o,
        .result_valid_i(x_result_valid_i),
        .result_i(x_result_i),
        .result_ready_o(x_result_ready_o)
    );
  end else begin : gen_no_cvxif
    assign x_result_ready_o = '0;
    assign x_trans_id_o     = '0;
    assign x_exception_o    = '0;
    assign x_result_o       = '0;
    assign x_valid_o        = '0;
    assign x_we_o           = '0;
    assign x_rd_o           = '0;
  end

  if (G6LCCfg.RVS) begin
    if (G6LCCfg.RVH) begin
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          current_instruction_is_sfence_vma  <= 1'b0;
          current_instruction_is_hfence_vvma <= 1'b0;
          current_instruction_is_hfence_gvma <= 1'b0;
        end else begin
          // TODO handle this with superscalar (issue only one instruction in this case?)
          if (flush_i) begin
            current_instruction_is_sfence_vma  <= 1'b0;
            current_instruction_is_hfence_vvma <= 1'b0;
            current_instruction_is_hfence_gvma <= 1'b0;
          end else if ((fu_data_i[0].operation == SFENCE_VMA && !v_i) && |csr_valid_i) begin
            current_instruction_is_sfence_vma <= 1'b1;
          end else if (((fu_data_i[0].operation == SFENCE_VMA && v_i) || fu_data_i[0].operation == HFENCE_VVMA) && |csr_valid_i) begin
            current_instruction_is_hfence_vvma <= 1'b1;
          end else if ((fu_data_i[0].operation == HFENCE_GVMA) && |csr_valid_i) begin
            current_instruction_is_hfence_gvma <= 1'b1;
          end
        end
      end
    end else begin
      assign current_instruction_is_hfence_vvma = 1'b0;
      assign current_instruction_is_hfence_gvma = 1'b0;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          current_instruction_is_sfence_vma <= 1'b0;
        end else begin
          if (flush_i) begin
            current_instruction_is_sfence_vma <= 1'b0;
          end else if (fu_data_i[0].operation == SFENCE_VMA && |csr_valid_i) begin
            current_instruction_is_sfence_vma <= 1'b1;
          end
        end
      end
    end
    if (G6LCCfg.RVH) begin
      // This process stores the rs1 and rs2 parameters of a SFENCE_VMA instruction.
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          vmid_to_be_flushed   <= '0;
          asid_to_be_flushed   <= '0;
          vaddr_to_be_flushed  <= '0;
          gpaddr_to_be_flushed <= '0;
          // if the current instruction in EX_STAGE is a sfence.vma, in the next cycle no writes will happen
        end else if ((~(current_instruction_is_sfence_vma || current_instruction_is_hfence_vvma || current_instruction_is_hfence_gvma)) && (~((fu_data_i[0].operation == SFENCE_VMA || fu_data_i[0].operation == HFENCE_VVMA || fu_data_i[0].operation == HFENCE_GVMA ) && |csr_valid_i))) begin
          vaddr_to_be_flushed  <= rs1_forwarding;
          gpaddr_to_be_flushed <= {rs1_forwarding[G6LCCfg.GPLEN-3:0], 2'b00};
          asid_to_be_flushed   <= rs2_forwarding[G6LCCfg.ASID_WIDTH-1:0];
          vmid_to_be_flushed   <= rs2_forwarding[G6LCCfg.VMID_WIDTH-1:0];
        end
      end
    end else begin
      assign vmid_to_be_flushed   = '0;
      assign gpaddr_to_be_flushed = '0;
      // This process stores the rs1 and rs2 parameters of a SFENCE_VMA instruction.
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
          asid_to_be_flushed  <= '0;
          vaddr_to_be_flushed <= '0;
          // if the current instruction in EX_STAGE is a sfence.vma, in the next cycle no writes will happen
        end else if ((~current_instruction_is_sfence_vma) && (~((fu_data_i[0].operation == SFENCE_VMA) && |csr_valid_i))) begin
          vaddr_to_be_flushed <= rs1_forwarding;
          asid_to_be_flushed  <= rs2_forwarding[G6LCCfg.ASID_WIDTH-1:0];
        end
      end
    end
  end else begin
    assign current_instruction_is_sfence_vma  = 1'b0;
    assign current_instruction_is_hfence_vvma = 1'b0;
    assign current_instruction_is_hfence_gvma = 1'b0;
    assign asid_to_be_flushed                 = '0;
    assign vaddr_to_be_flushed                = '0;
    assign vmid_to_be_flushed                 = '0;
    assign gpaddr_to_be_flushed               = '0;
  end

  // ----------------
  // Scalar Cryptography Unit
  // ----------------
  generate
    if (G6LCCfg.ZKN) begin : aes_gen
      aes #(
          .G6LCCfg  (G6LCCfg),
          .fu_data_t(fu_data_t)
      ) aes_i (
          .clk_i,
          .rst_ni,
          .fu_data_i     (one_cycle_data),
          .result_o      (aes_result),
          .orig_instr_aes(orig_instr_aes_i)
      );
    end else begin : no_aes_gen
      assign aes_result = '0;
    end
  endgenerate

endmodule
