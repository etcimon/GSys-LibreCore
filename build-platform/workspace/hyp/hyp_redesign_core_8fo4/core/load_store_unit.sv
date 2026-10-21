// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// hyp8: HypCfg parameter; staggered A1/A2 request AGU (LsuAguStages==2, +1);
//       staged store-forward channel fwd_req/fwd_rsp between load_unit and
//       the store buffer inside store_unit; ld_checked_i / replay_o /
//       replay_tid_o boundary ports for the LSQ verdict and IQ re-arm.
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
// Modified by: Etienne Cimon (acc MMU misaligned exception pack)
// Date: 19.04.2017
// Description: Load Store Unit, handles address calculation and memory interface signals


module load_store_unit
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    // hyp8: AGU staging (LsuAguStages) + store-forward pipe (StoreFwdCycles)
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type exception_t = logic,
    parameter type fu_data_t = logic,
    parameter type icache_areq_t = logic,
    parameter type icache_arsp_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic,
    parameter type lsu_ctrl_t = logic,
    parameter type acc_mmu_req_t = logic,
    parameter type acc_mmu_resp_t = logic,
    parameter type cbo_t = logic,
    parameter type bp_resolve_t = logic
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
    // T33: load unit gives a parked load back for a commit-time refetch
    output logic lu_replay_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] lu_replay_id_o,
    // hyp8: same event as lu_replay_o, exported for the IQ re-arm input
    output logic replay_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] replay_tid_o,
    // hyp8: per-scoreboard-entry "load verdict is final" bits from the LSQ —
    // the load unit publishes only checked loads (L5).
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] ld_checked_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic flush_i,
    // FSE S4: SB cancelled TIDs for younger-only LSU recovery
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Scoreboard issued mask (store-buffer reservation liveness assertion)
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_live_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic stall_st_pending_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic no_st_pending_o,
    // Shared TLB is busy processing a multi-cycle flush
    output logic shared_tlb_flush_busy_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic amo_valid_commit_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic [31:0] tinst_i,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t fu_data_i,
    // Load Store Unit is ready - ISSUE_STAGE
    output logic lsu_ready_o,
    // Load Store Unit instruction is valid - ISSUE_STAGE
    input logic lsu_valid_i,
    // Signals speculative loads for non-idempotent load handling - EX_STAGE
    input logic speculative_load_i,

    // Load transaction ID - ISSUE_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] load_trans_id_o,
    // Load result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] load_result_o,
    // Load result is valid - ISSUE_STAGE
    output logic load_valid_o,
    // Load exception - ISSUE_STAGE
    output exception_t load_exception_o,

    // Store transaction ID - ISSUE_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] store_trans_id_o,
    // Store result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] store_result_o,
    // Store result is valid - ISSUE_STAGE
    output logic store_valid_o,
    // Store exception - ISSUE_STAGE
    output exception_t store_exception_o,

    // Commit the first pending store - TO_BE_COMPLETED
    input logic commit_i,
    // Commit queue is ready to accept another commit request - TO_BE_COMPLETED
    output logic commit_ready_o,
    // Commit transaction ID - TO_BE_COMPLETED
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_tran_id_i,
    // T6b-4b: reclaim pointer (oldest live slot) — the store buffer's age
    // anchor. commit_tran_id_i stays the committing (port-0) tid.
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] oldest_live_tid_i,
    // N1d: the commit head is an unpublished load — speculative-store
    // stalls are futile while it pends (see store_buffer).
    input logic head_phys_pending_i,
    // Result from branch unit - EX_STAGE
    input bp_resolve_t resolved_branch_i,
    // Enable virtual memory translation - TO_BE_COMPLETED
    input logic enable_translation_i,
    // Enable G-Stage memory translation - TO_BE_COMPLETED
    input logic enable_g_translation_i,
    // Enable virtual memory translation for load/stores - TO_BE_COMPLETED
    input logic en_ld_st_translation_i,
    // Enable G-Stage memory translation for load/stores - TO_BE_COMPLETED
    input logic en_ld_st_g_translation_i,

    // Accelerator request for G6LC's MMU
    input  acc_mmu_req_t  acc_mmu_req_i,
    output acc_mmu_resp_t acc_mmu_resp_o,

    // Instruction cache input request - CACHES
    input  icache_arsp_t icache_areq_i,
    // Instruction cache output request - CACHES
    output icache_areq_t icache_areq_o,

    // Current privilege mode - CSR_REGFILE
    input  riscv::priv_lvl_t                          priv_lvl_i,
    // Data Endian mode - CSR_REGFILE
    input  logic                                      mbe_i,
    // Current virtualization mode - CSR_REGFILE
    input  logic                                      v_i,
    // Privilege level at which load and stores should happen - CSR_REGFILE
    input  riscv::priv_lvl_t                          ld_st_priv_lvl_i,
    // Virtualization mode at which load and stores should happen - CSR_REGFILE
    input  logic                                      ld_st_v_i,
    // Instruction is a hyp load/store - CSR_REGFILE
    output logic                                      csr_hs_ld_st_inst_o,
    // Supervisor User Memory - CSR_REGFILE
    input  logic                                      sum_i,
    // Virtual Supervisor User Memory - CSR_REGFILE
    input  logic                                      vs_sum_i,
    // Make Executable Readable - CSR_REGFILE
    input  logic                                      mxr_i,
    // Make Executable Readable Virtual Supervisor - CSR_REGFILE
    input  logic                                      vmxr_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [      G6LCCfg.PPNW-1:0] satp_ppn_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [G6LCCfg.ASID_WIDTH-1:0] asid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [      G6LCCfg.PPNW-1:0] vsatp_ppn_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [G6LCCfg.ASID_WIDTH-1:0] vs_asid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [      G6LCCfg.PPNW-1:0] hgatp_ppn_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [G6LCCfg.VMID_WIDTH-1:0] vmid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [G6LCCfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [G6LCCfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [      G6LCCfg.VLEN-1:0] vaddr_to_be_flushed_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [     G6LCCfg.GPLEN-1:0] gpaddr_to_be_flushed_i,
    // TLB flush - CONTROLLER
    input  logic                                      flush_tlb_i,
    input  logic                                      flush_tlb_vvma_i,
    input  logic                                      flush_tlb_gvma_i,
    // Instruction TLB miss - PERF_COUNTERS
    output logic                                      itlb_miss_o,
    // Data TLB miss - PERF_COUNTERS
    output logic                                      dtlb_miss_o,

    // Data cache request output - CACHES
    input  dcache_req_o_t [2:0] dcache_req_ports_i,
    // Data cache request input - CACHES
    output dcache_req_i_t [2:0] dcache_req_ports_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic                dcache_wbuffer_empty_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic                dcache_wbuffer_not_ni_i,
    // AMO request - CACHE
    output amo_req_t            amo_req_o,
    // AMO response - CACHE
    input  amo_resp_t           amo_resp_i,

    // PMP configuration - CSR_REGFILE
    input riscv::pmpcfg_t [avoid_neg(G6LCCfg.NrPMPEntries-1):0]                   pmpcfg_i,
    // PMP address - CSR_REGFILE
    input logic           [avoid_neg(G6LCCfg.NrPMPEntries-1):0][G6LCCfg.PLEN-3:0] pmpaddr_i,

    // T6b-2b: active fetch hart and hart owning the in-flight LSU translation
    // request (0 while the MMU is lent to the accelerator). The LSU-side
    // architectural inputs above carry the lsu_hart_o context; the fet_* set
    // below carries the fetch_hart_i (active hart) context for the
    // instruction-side TLB/PTW/PMP paths. With NrHarts==1 or
    // SmtDrainedHandoff both select the same bank and the extra muxes are
    // transparent.
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] fetch_hart_i,
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] lsu_hart_o,
    // Hart owning the check-stage context: lsu_hart_o registered with the
    // request under mixed residency, identical to lsu_hart_o otherwise. The
    // bank selects the PMP set (checked one cycle after the lookup) with it.
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

    // RVFI information - RVFI
    output lsu_ctrl_t                    rvfi_lsu_ctrl_o,
    // RVFI information - RVFI
    output logic      [G6LCCfg.PLEN-1:0] rvfi_mem_paddr_o
);

  // data is misaligned
  logic data_misaligned;
  // --------------------------------------
  // 1st register stage - (stall registers)
  // --------------------------------------
  // those are the signals which are always correct
  // e.g.: they keep the value in the stall case
  lsu_ctrl_t lsu_ctrl, lsu_ctrl_byp;

  logic                        pop_st;
  logic                        pop_ld;

  // ------------------------------
  // Address Generation Unit (AGU)
  // ------------------------------
  // virtual address as calculated by the AGU in the first cycle
  logic [    G6LCCfg.VLEN-1:0] vaddr_i;
  logic [    G6LCCfg.XLEN-1:0] vaddr_xlen;
  logic                        overflow;
  logic                        g_overflow;
  logic [(G6LCCfg.XLEN/8)-1:0] be_i;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=load_store_unit  region=3158  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: chk_hart_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to chk_hart_q
// order expect: chk_ld_st_priv_lvl_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to chk_ld_st_priv_lvl_q
// order expect: chk_ld_st_v_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to chk_ld_st_v_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     chk_hart_q <= …; // sv-timing: cycle 1/1 on clk_i
//     chk_ld_st_priv_lvl_q <= …; // sv-timing: cycle 1/1 on clk_i
//     chk_ld_st_v_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node11693 c=3.50 slack=0.00 */
//     /* node11694 c=3.50 slack=0.00 */
//     /* node11695 c=3.50 slack=0.00 */
//     /* node11696 c=0.00 slack=3.50 */
//     /* node11697 c=0.00 slack=3.50 */
//     /* node11698 c=0.00 slack=3.50 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // hyp8: LsuAguStages==2 splits the XLEN request AGU into a low-half
  // capture (A1: operand_a+imm low half + carry, plus the whole request
  // context) and a high-half completion (A2) — the lsu_req_i record and its
  // valid are presented one cycle later (+1, rank 2 on the AGU cone).
  fu_data_t  fu_data_sel;
  logic      lsu_valid_sel;
  logic      spec_load_sel;
  logic [31:0] tinst_sel;
  generate
    if (HypCfg.LsuAguStages == 2) begin : gen_agu_staged
      logic [G6LCCfg.XLEN/2-1:0] agu_lo_q;
      logic                      agu_carry_q;
      fu_data_t                  fu_data_q;
      logic                      spec_load_q;
      logic [31:0]               tinst_q;
      logic                      lsu_valid_q;
      always_ff @(posedge clk_i or negedge rst_ni) begin : p_agu_a1
        if (~rst_ni) begin
          agu_lo_q     <= '0;
          agu_carry_q  <= 1'b0;
          fu_data_q    <= '0;
          spec_load_q  <= 1'b0;
          tinst_q      <= '0;
          lsu_valid_q  <= 1'b0;
        end else begin
          {agu_carry_q, agu_lo_q} <=
              (G6LCCfg.XLEN / 2 + 1)'(fu_data_i.operand_a[G6LCCfg.XLEN/2-1:0]) +
              (G6LCCfg.XLEN / 2 + 1)'(fu_data_i.imm[G6LCCfg.XLEN/2-1:0]);
          fu_data_q   <= fu_data_i;
          spec_load_q <= speculative_load_i;
          tinst_q     <= tinst_i;
          // a request killed between A1 and A2 is dropped, never presented
          lsu_valid_q <= lsu_valid_i && !flush_i;
        end
      end
      assign fu_data_sel   = fu_data_q;
      assign lsu_valid_sel = lsu_valid_q;
      assign spec_load_sel = spec_load_q;
      assign tinst_sel     = tinst_q;
      // two's-complement halves compose bit-exactly; the emit computed the
      // full-width signed add — the carry registered at A1 completes it here.
      assign vaddr_xlen = {
        (G6LCCfg.XLEN / 2)'($signed(fu_data_q.operand_a[G6LCCfg.XLEN-1:G6LCCfg.XLEN/2]) +
                           $signed(fu_data_q.imm[G6LCCfg.XLEN-1:G6LCCfg.XLEN/2]) +
                           {{(G6LCCfg.XLEN / 2 - 1) {1'b0}}, agu_carry_q}),
        agu_lo_q
      };
    end else begin : gen_agu_live
      assign fu_data_sel   = fu_data_i;
      assign lsu_valid_sel = lsu_valid_i;
      assign spec_load_sel = speculative_load_i;
      assign tinst_sel     = tinst_i;
      assign vaddr_xlen = $unsigned($signed(fu_data_i.imm) + $signed(fu_data_i.operand_a));
    end
  endgenerate
  assign vaddr_i = vaddr_xlen[G6LCCfg.VLEN-1:0];
  // we work with SV39 or SV32, so if VM is enabled, check that all bits [XLEN-1:38] or [XLEN-1:31] are equal
  assign overflow = (G6LCCfg.IS_XLEN64 && (!((&vaddr_xlen[G6LCCfg.XLEN-1:G6LCCfg.SV-1]) == 1'b1 || (|vaddr_xlen[G6LCCfg.XLEN-1:G6LCCfg.SV-1]) == 1'b0)));
  if (G6LCCfg.RVH) begin : gen_g_overflow_hyp
    assign g_overflow = (G6LCCfg.IS_XLEN64 && (!((|vaddr_xlen[G6LCCfg.XLEN-1:G6LCCfg.SVX]) == 1'b0)));
  end else begin : gen_g_overflow_no_hyp
    assign g_overflow = 1'b0;
  end

  logic st_valid_i;
  logic ld_valid_i;
  logic ld_translation_req;
  logic st_translation_req, g6lc_st_translation_req, acc_st_translation_req;
  logic [G6LCCfg.VLEN-1:0] ld_vaddr;
  logic [            31:0] ld_tinst;
  logic                    ld_hs_ld_st_inst;
  logic                    ld_hlvx_inst;
  logic [G6LCCfg.VLEN-1:0] st_vaddr;
  logic [            31:0] st_tinst;
  logic                    st_hs_ld_st_inst;
  logic                    st_hlvx_inst;
  logic translation_req, g6lc_translation_req, acc_translation_req;
  logic translation_valid, g6lc_translation_valid;
  logic [G6LCCfg.VLEN-1:0] mmu_vaddr, g6lc_mmu_vaddr, acc_mmu_vaddr;
  logic [G6LCCfg.PLEN-1:0] mmu_paddr, g6lc_mmu_paddr, acc_mmu_paddr, lsu_paddr;
  logic [31:0] mmu_tinst;
  logic        mmu_hs_ld_st_inst;
  logic        mmu_hlvx_inst;
  exception_t mmu_exception, g6lc_mmu_exception, acc_mmu_exception;
  exception_t   pmp_exception;
  logic         g6lc_mmu_ex_ptw;
  icache_areq_t pmp_icache_areq_i;
  logic         pmp_translation_valid;
  logic dtlb_hit, g6lc_dtlb_hit, acc_dtlb_hit;
  logic [G6LCCfg.PPNW-1:0] dtlb_ppn, g6lc_dtlb_ppn, acc_dtlb_ppn;

  logic                             ld_valid;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] ld_trans_id;
  logic [         G6LCCfg.XLEN-1:0] ld_result;
  logic                             st_valid;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] st_trans_id;
  logic [         G6LCCfg.XLEN-1:0] st_result;

  logic [                     11:0] page_offset;
  logic                             page_offset_matches;
  logic                             page_offset_spec_only;
  logic [         G6LCCfg.PLEN-1:0] load_paddr;
  logic                             load_paddr_valid;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] load_trans_id;
  // T6b: hart of the querying load for the store buffer's same-hart
  // speculative-forward filter.
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] load_hart;
  logic                             st_fwd_valid;
  logic [         G6LCCfg.XLEN-1:0] st_fwd_data;
  logic [     (G6LCCfg.XLEN/8)-1:0] st_fwd_be;

  exception_t misaligned_exception, g6lc_misaligned_exception, acc_misaligned_exception;
  exception_t ld_ex;
  exception_t st_ex;

  logic       hs_ld_st_inst;
  logic       hlvx_inst;
  logic [1:0] sum, mxr;
  logic [G6LCCfg.PPNW-1:0] satp_ppn[2:0];
  logic [G6LCCfg.ASID_WIDTH-1:0] asid[2:0], asid_to_be_flushed[1:0];
  logic [G6LCCfg.VLEN-1:0] vaddr_to_be_flushed[1:0];

  // -------------------
  // MMU e.g.: TLBs/PTW
  // -------------------

  if (G6LCCfg.MmuPresent) begin : gen_mmu
    localparam HYP_EXT = G6LCCfg.RVH ? 1 : 0;

    g6lc_mmu #(
        .G6LCCfg       (G6LCCfg),
        .exception_t   (exception_t),
        .icache_areq_t (icache_areq_t),
        .icache_arsp_t (icache_arsp_t),
        .icache_dreq_t (icache_dreq_t),
        .icache_drsp_t (icache_drsp_t),
        .dcache_req_i_t(dcache_req_i_t),
        .dcache_req_o_t(dcache_req_o_t),
        .HYP_EXT       (HYP_EXT)
    ) i_g6lc_mmu (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .flush_i(flush_i),
        .enable_translation_i(enable_translation_i),
        .enable_g_translation_i(enable_g_translation_i),
        .en_ld_st_translation_i(en_ld_st_translation_i),
        .en_ld_st_g_translation_i(en_ld_st_g_translation_i),
        .icache_areq_i(icache_areq_i),
        .icache_areq_o(pmp_icache_areq_i),
        // misaligned bypass
        .misaligned_ex_i(misaligned_exception),
        .lsu_req_i(translation_req),
        .lsu_vaddr_i(mmu_vaddr),
        .lsu_tinst_i(mmu_tinst),
        .lsu_is_store_i(st_translation_req),
        .csr_hs_ld_st_inst_o(csr_hs_ld_st_inst_o),
        .lsu_dtlb_hit_o(dtlb_hit),  // send in the same cycle as the request
        .lsu_dtlb_ppn_o(dtlb_ppn),  // send in the same cycle as the request

        .lsu_valid_o    (pmp_translation_valid),
        .lsu_paddr_o    (lsu_paddr),
        .lsu_exception_o(pmp_exception),
        .lsu_exception_ptw_o(g6lc_mmu_ex_ptw),

        .priv_lvl_i      (priv_lvl_i),
        .v_i,
        .ld_st_priv_lvl_i(ld_st_priv_lvl_i),
        .ld_st_v_i,
        .sum_i,
        .vs_sum_i,
        .mxr_i,
        .vmxr_i,
        .mbe_i           (mbe_i),

        .hlvx_inst_i    (mmu_hlvx_inst),
        .hs_ld_st_inst_i(mmu_hs_ld_st_inst),
        .satp_ppn_i,
        .vsatp_ppn_i,
        .hgatp_ppn_i,
        .asid_i,
        .vs_asid_i,
        .asid_to_be_flushed_i,
        .vmid_i,
        .vmid_to_be_flushed_i,
        .vaddr_to_be_flushed_i,
        .gpaddr_to_be_flushed_i,
        .flush_tlb_i,
        .flush_tlb_vvma_i,
        .flush_tlb_gvma_i,

        .fetch_hart_i   (fetch_hart_i),
        .lsu_hart_i     (lsu_hart_o),
        .fet_asid_i     (fet_asid_i),
        .fet_vs_asid_i  (fet_vs_asid_i),
        .fet_vmid_i     (fet_vmid_i),
        .fet_satp_ppn_i (fet_satp_ppn_i),
        .fet_vsatp_ppn_i(fet_vsatp_ppn_i),
        .fet_hgatp_ppn_i(fet_hgatp_ppn_i),
        .fet_mxr_i      (fet_mxr_i),
        .fet_vmxr_i     (fet_vmxr_i),
        .fet_mbe_i      (fet_mbe_i),
        .fet_pmpcfg_i   (fet_pmpcfg_i),
        .fet_pmpaddr_i  (fet_pmpaddr_i),

        .itlb_miss_o(itlb_miss_o),
        .dtlb_miss_o(dtlb_miss_o),
        .shared_tlb_flush_busy_o(shared_tlb_flush_busy_o),

        .req_port_i(dcache_req_ports_i[0]),
        .req_port_o(dcache_req_ports_o[0]),

        .pmpcfg_i,
        .pmpaddr_i
    );
  end else begin : gen_no_mmu
    // icache request without MMU, virtual and physical address are identical
    assign pmp_icache_areq_i.fetch_valid = icache_areq_i.fetch_req;
    assign shared_tlb_flush_busy_o = 1'b0;  //default 0 for shared_tlb flush
    if (G6LCCfg.VLEN >= G6LCCfg.PLEN) begin : gen_virtual_physical_address_instruction_vlen_greater
      assign pmp_icache_areq_i.fetch_paddr = icache_areq_i.fetch_vaddr[G6LCCfg.PLEN-1:0];
    end else begin : gen_virtual_physical_address_instruction_plen_greater
      assign pmp_icache_areq_i.fetch_paddr = G6LCCfg.PLEN'(icache_areq_i.fetch_vaddr);
    end
    assign pmp_icache_areq_i.fetch_exception = 'h0;
    // dcache request without mmu for load or store,
    // Delay of 1 cycle to match MMU latency giving the address tag
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        lsu_paddr <= '0;
        pmp_exception <= '0;
        pmp_translation_valid <= 1'b0;
      end else begin
        if (G6LCCfg.VLEN >= G6LCCfg.PLEN) begin : gen_virtual_physical_address_lsu
          lsu_paddr <= mmu_vaddr[G6LCCfg.PLEN-1:0];
        end else begin
          lsu_paddr <= G6LCCfg.PLEN'(mmu_vaddr);
        end
        pmp_exception <= misaligned_exception;
        pmp_translation_valid <= translation_req;
      end
    end

    // dcache interface of PTW not used
    assign dcache_req_ports_o[0].address_index = '0;
    assign dcache_req_ports_o[0].address_tag   = '0;
    assign dcache_req_ports_o[0].data_wdata    = '0;
    assign dcache_req_ports_o[0].data_req      = 1'b0;
    assign dcache_req_ports_o[0].data_be       = '1;
    assign dcache_req_ports_o[0].data_size     = 2'b11;
    assign dcache_req_ports_o[0].data_we       = 1'b0;
    assign dcache_req_ports_o[0].data_wuser    = '0;
    assign dcache_req_ports_o[0].kill_req      = '0;
    assign dcache_req_ports_o[0].tag_valid     = 1'b0;

    assign itlb_miss_o                         = 1'b0;
    assign dtlb_miss_o                         = 1'b0;
    assign dtlb_ppn                            = lsu_paddr[G6LCCfg.PLEN-1:12];
    assign dtlb_hit                            = 1'b1;
    assign g6lc_mmu_ex_ptw                     = 1'b0;

  end

  // ------------------
  // PMP
  // ------------------

  // T6b-2b: check-stage context. The PMP data check runs on the registered
  // (post-translation) address, one cycle after the request; under mixed
  // residency the live architectural inputs may already belong to the peer
  // hart, so the request's own context is replayed.
  localparam bit HART_CTX = (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] chk_hart_q;
  riscv::priv_lvl_t chk_ld_st_priv_lvl_q;
  logic chk_ld_st_v_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      chk_hart_q           <= '0;
      chk_ld_st_priv_lvl_q <= riscv::PRIV_LVL_M;
      chk_ld_st_v_q        <= 1'b0;
    end else if (HART_CTX) begin
      chk_hart_q           <= lsu_hart_o;
      chk_ld_st_priv_lvl_q <= ld_st_priv_lvl_i;
      chk_ld_st_v_q        <= ld_st_v_i;
    end
  end

  assign lsu_chk_hart_o = HART_CTX ? chk_hart_q : lsu_hart_o;

  pmp_data_if #(
      .G6LCCfg      (G6LCCfg),
      .icache_areq_t(icache_areq_t),
      .exception_t  (exception_t)
  ) i_pmp_data_if (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .icache_areq_i       (pmp_icache_areq_i),
      .icache_areq_o       (icache_areq_o),
      .icache_fetch_vaddr_i(icache_areq_i.fetch_vaddr),
      .lsu_valid_i         (pmp_translation_valid),
      .lsu_paddr_i         (lsu_paddr),
      .lsu_vaddr_i         (mmu_vaddr),
      .lsu_exception_i     (pmp_exception),
      .lsu_is_store_i      (st_translation_req),
      .lsu_valid_o         (translation_valid),
      .lsu_paddr_o         (mmu_paddr),
      .lsu_exception_o     (mmu_exception),
      .priv_lvl_i          (priv_lvl_i),
      .v_i                 (v_i),
      .ld_st_priv_lvl_i    (HART_CTX ? chk_ld_st_priv_lvl_q : ld_st_priv_lvl_i),
      .ld_st_v_i           (HART_CTX ? chk_ld_st_v_q : ld_st_v_i),
      .pmpcfg_i            (pmpcfg_i),
      .pmpaddr_i           (pmpaddr_i),
      .fet_pmpcfg_i        (fet_pmpcfg_i),
      .fet_pmpaddr_i       (fet_pmpaddr_i)
  );

  // ------------------
  // External MMU port
  // ------------------

  if (G6LCCfg.EnableAccelerator) begin
    // The MMU can be connected to G6LC or the ACCELERATOR
    enum logic {
      G6LC,
      ACC
    }
        mmu_state_d, mmu_state_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        mmu_state_q <= G6LC;
      end else begin
        mmu_state_q <= mmu_state_d;
      end
    end
    // Straightforward and slow-reactive MMU arbitration logic
    // This logic can be optimized to reduce answer latency and contention
    always_comb begin
      // Maintain state
      mmu_state_d                      = mmu_state_q;
      // Serve G6LC and gate the accelerator by default
      // MMU input
      misaligned_exception             = g6lc_misaligned_exception;
      st_translation_req               = g6lc_st_translation_req;
      translation_req                  = g6lc_translation_req;
      mmu_vaddr                        = g6lc_mmu_vaddr;
      // T6b-2b: G6LC translation requests are owned by the bypass head's hart
      lsu_hart_o                       = lsu_ctrl.hart;
      // MMU output
      g6lc_translation_valid           = translation_valid;
      g6lc_mmu_paddr                   = mmu_paddr;
      g6lc_mmu_exception               = mmu_exception;
      g6lc_dtlb_hit                    = dtlb_hit;
      g6lc_dtlb_ppn                    = dtlb_ppn;
      acc_mmu_resp_o.acc_mmu_valid     = '0;
      acc_mmu_resp_o.acc_mmu_paddr     = '0;
      acc_mmu_resp_o.acc_mmu_exception = '0;
      acc_mmu_resp_o.acc_mmu_dtlb_hit  = '0;
      acc_mmu_resp_o.acc_mmu_dtlb_ppn  = '0;
      unique case (mmu_state_q)
        G6LC: begin
          // Only the accelerator is requesting, and the lsu bypass queue is empty.
          if (acc_mmu_req_i.acc_mmu_req && !lsu_valid_i && lsu_ready_o) begin
            // Lock the MMU to the accelerator.
            // If the issue stage is firing a mem op in this cycle,
            // the bypass queue will buffer it.
            mmu_state_d = ACC;
          end
          // Make this a mealy FSM to cut some latency.
          // It should be okay timing-wise since g6lc's requests already
          // depend on lsu_valid_i. Moreover, lsu_ready_o is sequentially
          // generated by the bypass and, in this first implementation,
          // the acc request already depends combinatorially upon acc_mmu_req_i.acc_mmu_req.
        end
        ACC: begin
          // MMU input
          misaligned_exception             = '0;
          misaligned_exception.valid       = acc_mmu_req_i.acc_mmu_misaligned_ex;
          st_translation_req               = acc_mmu_req_i.acc_mmu_is_store;
          translation_req                  = acc_mmu_req_i.acc_mmu_req;
          mmu_vaddr                        = acc_mmu_req_i.acc_mmu_vaddr;
          // Accelerator translations are not owned by any SMT hart
          lsu_hart_o                       = '0;
          // MMU output
          acc_mmu_resp_o.acc_mmu_valid     = translation_valid;
          acc_mmu_resp_o.acc_mmu_paddr     = mmu_paddr;
          acc_mmu_resp_o.acc_mmu_exception = mmu_exception;
          acc_mmu_resp_o.acc_mmu_dtlb_hit  = dtlb_hit;
          acc_mmu_resp_o.acc_mmu_dtlb_ppn  = dtlb_ppn;
          g6lc_translation_valid           = '0;
          g6lc_mmu_paddr                   = '0;
          g6lc_mmu_exception               = '0;
          g6lc_dtlb_hit                    = '0;
          g6lc_dtlb_ppn                    = '0;
          // Get back to G6LC after the translation
          if (translation_valid) mmu_state_d = G6LC;
        end
        default: mmu_state_d = G6LC;
      endcase
    end
    always_comb begin
      // Feed forward
      lsu_ctrl = lsu_ctrl_byp;
      // Mask the lsu valid so that g6lc's req gets buffered in the
      // bypass queue when the MMU is being used by the accelerator.
      lsu_ctrl.valid = (mmu_state_q == ACC) ? 1'b0 : lsu_ctrl_byp.valid;
    end
  end else begin
    // MMU input
    assign misaligned_exception   = g6lc_misaligned_exception;
    assign st_translation_req     = g6lc_st_translation_req;
    assign translation_req        = g6lc_translation_req;
    assign mmu_vaddr              = g6lc_mmu_vaddr;
    assign lsu_hart_o             = lsu_ctrl.hart;
    // MMU output
    assign g6lc_translation_valid = translation_valid;
    assign g6lc_mmu_paddr         = mmu_paddr;
    assign g6lc_mmu_exception     = mmu_exception;
    assign g6lc_dtlb_hit          = dtlb_hit;
    assign g6lc_dtlb_ppn          = dtlb_ppn;
    // No accelerator
    assign acc_mmu_resp_o         = '0;
    // Feed forward the lsu_ctrl bypass
    assign lsu_ctrl               = lsu_ctrl_byp;
  end

  logic store_buffer_empty;
  // hyp8: staged store->load forward channel — load_unit requests at
  // request-grant (F1), the store buffer answers StoreFwdCycles later (F3).
  typedef struct packed {
    logic                                        valid;
    logic [G6LCCfg.PLEN-1:0]                     pa;
    logic [1:0]                                  size;
    logic [G6LCCfg.TRANS_ID_BITS-1:0]            tid;
    logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart;
    logic [(G6LCCfg.NrLoadBufEntries > 1 ? $clog2(G6LCCfg.NrLoadBufEntries) : 1)-1:0] tag;
  } stb_fwd_req_t;
  typedef struct packed {
    logic                                        valid;
    logic [G6LCCfg.XLEN-1:0]                     data;
    logic [(G6LCCfg.XLEN/8)-1:0]                 be;
    logic                                        forward_possible;
    logic [(G6LCCfg.NrLoadBufEntries > 1 ? $clog2(G6LCCfg.NrLoadBufEntries) : 1)-1:0] tag;
  } stb_fwd_rsp_t;
  stb_fwd_req_t fwd_req;
  stb_fwd_rsp_t fwd_rsp;
  // ------------------
  // Store Unit
  // ------------------
  store_unit #(
      .G6LCCfg(G6LCCfg),
      .HypCfg  (HypCfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .lsu_ctrl_t(lsu_ctrl_t),
      .cbo_t(cbo_t)
  ) i_store_unit (
      .clk_i,
      .rst_ni,
      .phys_valid_o(phys_valid_o[1]), .phys_addr_o(phys_addr_o[1]),
      .phys_id_o(phys_id_o[1]), .phys_hart_o(phys_hart_o[1]), .phys_size_o(phys_size_o[1]),
      .flush_i,
      .cancelled_mask_i,
      .sb_live_i,
      .stall_st_pending_i,
      .no_st_pending_o,
      .store_buffer_empty_o(store_buffer_empty),

      .valid_i   (st_valid_i),
      .lsu_ctrl_i(lsu_ctrl),
      .pop_st_o  (pop_st),
      .commit_i,
      .commit_ready_o,
      .amo_valid_commit_i,
      .mbe_i     (mbe_i),

      .valid_o              (st_valid),
      .trans_id_o           (st_trans_id),
      .result_o             (st_result),
      .ex_o                 (st_ex),
      // MMU port
      .translation_req_o    (g6lc_st_translation_req),
      .vaddr_o              (st_vaddr),
      .rvfi_mem_paddr_o     (rvfi_mem_paddr_o),
      .tinst_o              (st_tinst),
      .hs_ld_st_inst_o      (st_hs_ld_st_inst),
      .hlvx_inst_o          (st_hlvx_inst),
      .paddr_i              (g6lc_mmu_paddr),
      .ex_i                 (g6lc_mmu_exception),
      .dtlb_hit_i           (g6lc_dtlb_hit),
      // Load Unit
      .page_offset_i        (page_offset),
      .load_paddr_i         (load_paddr),
      .load_paddr_valid_i   (load_paddr_valid),
      .load_trans_id_i      (load_trans_id),
      .load_hart_i          (load_hart),
      .commit_tran_id_i,
      .oldest_live_tid_i,
      .head_phys_pending_i,
      .dcache_wbuffer_empty_i,
      .page_offset_matches_o(page_offset_matches),
      .page_offset_spec_only_o(page_offset_spec_only),
      .st_fwd_valid_o       (st_fwd_valid),
      .st_fwd_data_o        (st_fwd_data),
      .st_fwd_be_o          (st_fwd_be),
      .fwd_req_i            (fwd_req),
      .fwd_rsp_o            (fwd_rsp),
      // AMOs
      .amo_req_o,
      .amo_resp_i,
      // to memory arbiter
      .req_port_i           (dcache_req_ports_i[2]),
      .req_port_o           (dcache_req_ports_o[2])
  );

  // ------------------
  // Load Unit
  // ------------------
  load_unit #(
      .G6LCCfg(G6LCCfg),
      .HypCfg  (HypCfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .lsu_ctrl_t(lsu_ctrl_t)
  ) i_load_unit (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .valid_i   (ld_valid_i),
      .lsu_ctrl_i(lsu_ctrl),
      .pop_ld_o  (pop_ld),

      .valid_o              (ld_valid),
      .trans_id_o           (ld_trans_id),
      .result_o             (ld_result),
      .ex_o                 (ld_ex),
      .mbe_i                (mbe_i),
      // MMU port
      .translation_req_o    (ld_translation_req),
      .vaddr_o              (ld_vaddr),
      .tinst_o              (ld_tinst),
      .hs_ld_st_inst_o      (ld_hs_ld_st_inst),
      .hlvx_inst_o          (ld_hlvx_inst),
      .paddr_i              (g6lc_mmu_paddr),
      .ex_i                 (g6lc_mmu_exception),
      .ex_ptw_i             (g6lc_mmu_ex_ptw),
      .dtlb_hit_i           (g6lc_dtlb_hit),
      .dtlb_ppn_i           (g6lc_dtlb_ppn),
      // to store unit
      .page_offset_o        (page_offset),
      .load_paddr_o         (load_paddr),
      .load_paddr_valid_o   (load_paddr_valid),
      .load_trans_id_o      (load_trans_id),
      .load_hart_o          (load_hart),
      .phys_valid_o(phys_valid_o[0]), .phys_addr_o(phys_addr_o[0]),
      .phys_id_o(phys_id_o[0]), .phys_hart_o(phys_hart_o[0]), .phys_size_o(phys_size_o[0]),
      .page_offset_matches_i(page_offset_matches),
      .page_offset_spec_only_i(page_offset_spec_only),
      .lu_replay_o,
      .lu_replay_id_o,
      .store_buffer_empty_i (store_buffer_empty),
      .no_st_pending_i      (no_st_pending_o),
      .st_fwd_valid_i       (st_fwd_valid),
      .st_fwd_data_i        (st_fwd_data),
      .st_fwd_be_i          (st_fwd_be),
      .ld_checked_i,
      .fwd_req_o            (fwd_req),
      .fwd_rsp_i            (fwd_rsp),
      .replay_o,
      .replay_tid_o,
      .commit_tran_id_i,
      // to memory arbiter
      .req_port_i           (dcache_req_ports_i[1]),
      .req_port_o           (dcache_req_ports_o[1]),
      .dcache_wbuffer_not_ni_i,
      .dcache_wbuffer_empty_i
  );

  // ----------------------------
  // Output Pipeline Register
  // ----------------------------

  // amount of pipeline registers inserted for load/store return path
  // can be tuned to trade-off IPC vs. cycle time

  shift_reg #(
      .dtype(logic [$bits(ld_valid) + $bits(ld_trans_id) + $bits(ld_result) + $bits(ld_ex) - 1:0]),
      .Depth(G6LCCfg.NrLoadPipeRegs)
  ) i_pipe_reg_load (
      .clk_i,
      .rst_ni,
      .d_i({ld_valid, ld_trans_id, ld_result, ld_ex}),
      .d_o({load_valid_o, load_trans_id_o, load_result_o, load_exception_o})
  );

  shift_reg #(
      .dtype(logic [$bits(st_valid) + $bits(st_trans_id) + $bits(st_result) + $bits(st_ex) - 1:0]),
      .Depth(G6LCCfg.NrStorePipeRegs)
  ) i_pipe_reg_store (
      .clk_i,
      .rst_ni,
      .d_i({st_valid, st_trans_id, st_result, st_ex}),
      .d_o({store_valid_o, store_trans_id_o, store_result_o, store_exception_o})
  );

  // determine whether this is a load or store
  always_comb begin : which_op

    ld_valid_i           = 1'b0;
    st_valid_i           = 1'b0;

    g6lc_translation_req = 1'b0;
    g6lc_mmu_vaddr       = {G6LCCfg.VLEN{1'b0}};
    mmu_tinst            = {32{1'b0}};
    mmu_hs_ld_st_inst    = 1'b0;
    mmu_hlvx_inst        = 1'b0;

    // check the operation to activate the right functional unit accordingly
    unique case (lsu_ctrl.fu)
      // all loads go here
      LOAD: begin
        ld_valid_i           = lsu_ctrl.valid;
        g6lc_translation_req = ld_translation_req;
        g6lc_mmu_vaddr       = ld_vaddr;
        if (G6LCCfg.RVH) begin
          mmu_tinst         = ld_tinst;
          mmu_hs_ld_st_inst = ld_hs_ld_st_inst;
          mmu_hlvx_inst     = ld_hlvx_inst;
        end
      end
      // all stores go here
      STORE: begin
        st_valid_i           = lsu_ctrl.valid;
        g6lc_translation_req = st_translation_req;
        g6lc_mmu_vaddr       = st_vaddr;
        if (G6LCCfg.RVH) begin
          mmu_tinst         = st_tinst;
          mmu_hs_ld_st_inst = st_hs_ld_st_inst;
          mmu_hlvx_inst     = st_hlvx_inst;
        end
      end
      // not relevant for the LSU
      default: ;
    endcase
  end

  // ------------------------
  // Hypervisor Load/Store
  // ------------------------
  // determine whether this is a hypervisor load or store
  if (G6LCCfg.RVH) begin
    always_comb begin : hyp_ld_st
      // check the operator to activate the right functional unit accordingly
      hs_ld_st_inst = 1'b0;
      hlvx_inst     = 1'b0;
      case (lsu_ctrl.operation)
        // all loads go here
        HLV_B, HLV_BU, HLV_H, HLV_HU, HLV_W, HSV_B, HSV_H, HSV_W, HLV_WU, HLV_D, HSV_D: begin
          hs_ld_st_inst = 1'b1;
        end
        HLVX_WU, HLVX_HU: begin
          hs_ld_st_inst = 1'b1;
          hlvx_inst     = 1'b1;
        end
        default: ;
      endcase
    end
  end else begin
    assign hs_ld_st_inst = 1'b0;
    assign hlvx_inst     = 1'b0;
  end

  // ---------------
  // Byte Enable
  // ---------------
  // we can generate the byte enable from the virtual address since the last
  // 12 bit are the same anyway
  // and we can always generate the byte enable from the address at hand

  if (G6LCCfg.IS_XLEN64) begin : gen_8b_be
    assign be_i = be_gen(vaddr_i[2:0], extract_transfer_size(fu_data_sel.operation));
  end else begin : gen_4b_be
    assign be_i = be_gen_32(vaddr_i[1:0], extract_transfer_size(fu_data_sel.operation));
  end

  // ------------------------
  // Misaligned Exception
  // ------------------------
  // we can detect a misaligned exception immediately
  // the misaligned exception is passed to the functional unit via the MMU, which in case
  // can augment the exception if other memory related exceptions like a page fault or access errors
  always_comb begin : data_misaligned_detection
    g6lc_misaligned_exception = {
      {G6LCCfg.XLEN{1'b0}}, {G6LCCfg.XLEN{1'b0}}, {G6LCCfg.GPLEN{1'b0}}, {32{1'b0}}, 1'b0, 1'b0
    };
    data_misaligned = 1'b0;

    if (lsu_ctrl.valid) begin
      if (G6LCCfg.IS_XLEN64) begin
        case (lsu_ctrl.operation)
          // double word
          LD, SD, FLD, FSD,
                  AMO_LRD, AMO_SCD,
                  AMO_SWAPD, AMO_ADDD, AMO_ANDD, AMO_ORD,
                  AMO_XORD, AMO_MAXD, AMO_MAXDU, AMO_MIND,
                  AMO_MINDU, AMO_CASD, HLV_D, HSV_D: begin
            if (lsu_ctrl.vaddr[2:0] != 3'b000) begin
              data_misaligned = 1'b1;
            end
          end
          // AMOCAS.Q: 16-byte alignment
          AMO_CASQ: begin
            if (lsu_ctrl.vaddr[3:0] != 4'b0000) begin
              data_misaligned = 1'b1;
            end
          end
          default: ;
        endcase
      end
      case (lsu_ctrl.operation)
        // word
        LW, LWU, SW, FLW, FSW,
                AMO_LRW, AMO_SCW,
                AMO_SWAPW, AMO_ADDW, AMO_ANDW, AMO_ORW,
                AMO_XORW, AMO_MAXW, AMO_MAXWU, AMO_MINW,
                AMO_MINWU, AMO_CASW, HLV_W, HLV_WU, HLVX_WU, HSV_W: begin
          if (lsu_ctrl.vaddr[1:0] != 2'b00) begin
            data_misaligned = 1'b1;
          end
        end
        // half word
        LH, LHU, SH, FLH, FSH, HLV_H, HLV_HU, HLVX_HU, HSV_H: begin
          if (lsu_ctrl.vaddr[0] != 1'b0) begin
            data_misaligned = 1'b1;
          end
        end
        // byte -> is always aligned
        default: ;
      endcase
    end

    if (data_misaligned) begin
      case (lsu_ctrl.fu)
        LOAD: begin
          g6lc_misaligned_exception.cause = riscv::LD_ADDR_MISALIGNED;
          g6lc_misaligned_exception.valid = 1'b1;
          if (G6LCCfg.TvalEn)
            g6lc_misaligned_exception.tval = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (G6LCCfg.RVH) begin
            g6lc_misaligned_exception.tval2 = '0;
            g6lc_misaligned_exception.tinst = lsu_ctrl.tinst;
            g6lc_misaligned_exception.gva   = ld_st_v_i;
          end
        end
        STORE: begin

          g6lc_misaligned_exception.cause = riscv::ST_ADDR_MISALIGNED;
          g6lc_misaligned_exception.valid = 1'b1;
          if (G6LCCfg.TvalEn)
            g6lc_misaligned_exception.tval = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (G6LCCfg.RVH) begin
            g6lc_misaligned_exception.tval2 = '0;
            g6lc_misaligned_exception.tinst = lsu_ctrl.tinst;
            g6lc_misaligned_exception.gva   = ld_st_v_i;
          end
        end
        default: ;
      endcase
    end

    if (G6LCCfg.MmuPresent && en_ld_st_translation_i && lsu_ctrl.overflow) begin

      case (lsu_ctrl.fu)
        LOAD: begin
          g6lc_misaligned_exception.cause = riscv::LOAD_PAGE_FAULT;
          g6lc_misaligned_exception.valid = 1'b1;
          if (G6LCCfg.TvalEn)
            g6lc_misaligned_exception.tval = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (G6LCCfg.RVH) begin
            g6lc_misaligned_exception.tval2 = '0;
            g6lc_misaligned_exception.tinst = lsu_ctrl.tinst;
            g6lc_misaligned_exception.gva   = ld_st_v_i;
          end
        end
        STORE: begin
          g6lc_misaligned_exception.cause = riscv::STORE_PAGE_FAULT;
          g6lc_misaligned_exception.valid = 1'b1;
          if (G6LCCfg.TvalEn)
            g6lc_misaligned_exception.tval = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (G6LCCfg.RVH) begin
            g6lc_misaligned_exception.tval2 = '0;
            g6lc_misaligned_exception.tinst = lsu_ctrl.tinst;
            g6lc_misaligned_exception.gva   = ld_st_v_i;
          end
        end
        default: ;
      endcase
    end

    if (G6LCCfg.MmuPresent && G6LCCfg.RVH && en_ld_st_g_translation_i && !en_ld_st_translation_i && lsu_ctrl.g_overflow) begin

      case (lsu_ctrl.fu)
        LOAD: begin
          g6lc_misaligned_exception.cause = riscv::LOAD_GUEST_PAGE_FAULT;
          g6lc_misaligned_exception.valid = 1'b1;
          if (G6LCCfg.TvalEn)
            g6lc_misaligned_exception.tval = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (G6LCCfg.RVH) begin
            g6lc_misaligned_exception.tval2 = '0;
            g6lc_misaligned_exception.tinst = lsu_ctrl.tinst;
            g6lc_misaligned_exception.gva   = ld_st_v_i;
          end
        end
        STORE: begin
          g6lc_misaligned_exception.cause = riscv::STORE_GUEST_PAGE_FAULT;
          g6lc_misaligned_exception.valid = 1'b1;
          if (G6LCCfg.TvalEn)
            g6lc_misaligned_exception.tval = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (G6LCCfg.RVH) begin
            g6lc_misaligned_exception.tval2 = '0;
            g6lc_misaligned_exception.tinst = lsu_ctrl.tinst;
            g6lc_misaligned_exception.gva   = ld_st_v_i;
          end
        end
        default: ;
      endcase
    end
  end


  // ------------------
  // LSU Control
  // ------------------
  // new data arrives here
  lsu_ctrl_t lsu_req_i;

  assign lsu_req_i = {
    lsu_valid_sel,
    vaddr_i,
    tinst_sel,
    hs_ld_st_inst,
    hlvx_inst,
    overflow,
    g_overflow,
    fu_data_sel.operand_b,
    // Zacas: expected value travels as operand_c (imm must stay 0 for addr = rs1)
    (G6LCCfg.RVZacas && g6lc_core_pkg::is_amo_cas(fu_data_sel.operation)) ? fu_data_sel.operand_c
                                                                      : '0,
    // AMOCAS.Q high halves
    (G6LCCfg.RVZacas && fu_data_sel.operation == g6lc_core_pkg::AMO_CASQ) ? fu_data_sel.operand_b_hi : '0,
    (G6LCCfg.RVZacas && fu_data_sel.operation == g6lc_core_pkg::AMO_CASQ) ? fu_data_sel.operand_c_hi : '0,
    be_i,
    fu_data_sel.fu,
    fu_data_sel.operation,
    fu_data_sel.trans_id,
    fu_data_sel.hart,
    spec_load_sel,
    1'b0
  };

  lsu_bypass #(
      .G6LCCfg(G6LCCfg),
      .lsu_ctrl_t(lsu_ctrl_t),
      .bp_resolve_t(bp_resolve_t)
  ) lsu_bypass_i (
      .clk_i,
      .rst_ni,
      .cancelled_mask_i,
      .flush_i,
      .lsu_req_i      (lsu_req_i),
      .lsu_req_valid_i(lsu_valid_sel),
      .pop_ld_i       (pop_ld),
      .pop_st_i       (pop_st),
      .resolved_branch_i,

      .lsu_ctrl_o(lsu_ctrl_byp),
      .ready_o   (lsu_ready_o)
  );

  assign rvfi_lsu_ctrl_o = lsu_ctrl;

  //pragma translate_off
  // T6b-2b: while a data page-table walk is in flight the LSU holds its
  // request — the registered check-stage hart must equal the request hart,
  // so the PMP data check replays the same bank the request looked up.
  g6lc_chk_hart_walk_match :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      (HART_CTX && dtlb_miss_o) |=> (lsu_chk_hart_o == lsu_hart_o))
  else $error("[lsu] check-stage hart diverged from request hart during a data PTW walk");
  //pragma translate_on

endmodule
