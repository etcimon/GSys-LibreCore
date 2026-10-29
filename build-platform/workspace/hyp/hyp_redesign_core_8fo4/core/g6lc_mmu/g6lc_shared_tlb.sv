// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
// Modified by: Etienne Cimon (2026) - A139 pipeline-design comments.
// Copyright (c) 2023 Thales.
// Copyright (c) 2024, PlanV Technology
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Angela Gonzalez PlanV Technology
// Date: 26/02/2024
//
// Description: N-way associative shared TLB, it allows to reduce the number
//              of ITLB and DTLB entries. This module is an update of the
//              shared TLB sv32 developed by Sebastien Jacq (Thales Research & Technology)
//              to be used with sv32, sv39 and sv39x4.

/* verilator lint_off WIDTH */
/* verilator lint_off SELRANGE */

module g6lc_shared_tlb #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type pte_g6lc_t = logic,
    parameter type tlb_update_g6lc_t = logic,
    parameter int SHARED_TLB_WAYS = 2,
    parameter int unsigned HYP_EXT = 0

) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,  // Flush normal translations signal
    input logic flush_vvma_i,  // Flush vs stage signal
    input logic flush_gvma_i,  // Flush g stage signal
    input logic s_st_enbl_i,  // s-stage enabled
    input logic g_st_enbl_i,  // g-stage enabled
    input logic v_i,  // virtualization mode
    input logic s_ld_st_enbl_i,  // s-stage enabled for load stores
    input logic g_ld_st_enbl_i,  // g-stage enabled for load stores
    input logic ld_st_v_i,  // virtualization mode for load stores

    input logic [G6LCCfg.ASID_WIDTH-1:0] dtlb_asid_i,
    input logic [G6LCCfg.ASID_WIDTH-1:0] itlb_asid_i,
    input logic [G6LCCfg.VMID_WIDTH-1:0] lu_vmid_i,
    // T6b-2b: VMID of the instruction-side requester (active hart context);
    // lu_vmid_i keeps the data-side/flush context.
    input logic [G6LCCfg.VMID_WIDTH-1:0] itlb_vmid_i,
    // T6b-2b: requesting SMT hart per side. The hart tag participates in the
    // lookup match only when NrHarts > 1 && !SmtDrainedHandoff; drained SMT2
    // intentionally keeps sharing entries across harts with equal ASIDs.
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] itlb_hart_i,
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] dtlb_hart_i,

    // from TLBs
    // did we miss?
    input logic                    itlb_access_i,
    input logic                    itlb_hit_i,
    input logic [G6LCCfg.VLEN-1:0] itlb_vaddr_i,

    input logic                    dtlb_access_i,
    input logic                    dtlb_hit_i,
    input logic [G6LCCfg.VLEN-1:0] dtlb_vaddr_i,

    input logic shared_tlb_miss_i,

    input logic [G6LCCfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,  //control inputs for flush
    input logic [G6LCCfg.VLEN-1:0] vaddr_to_be_flushed_i,
    input logic [G6LCCfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    input logic [G6LCCfg.GPLEN-1:0] gpaddr_to_be_flushed_i,

    // to TLBs, update logic
    output tlb_update_g6lc_t itlb_update_o,
    output tlb_update_g6lc_t dtlb_update_o,

    // Performance counters
    output logic itlb_miss_o,
    output logic dtlb_miss_o,

    output logic flush_busy_o,

    output logic                    shared_tlb_access_o,
    output logic                    shared_tlb_hit_o,
    output logic [G6LCCfg.VLEN-1:0] shared_tlb_vaddr_o,

    output logic itlb_req_o,

    // Update shared TLB in case of miss
    input tlb_update_g6lc_t shared_tlb_update_i

);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_shared_tlb status=proposal target=10-adjusted-FO4
  // svt-plan: cone flush row/tag reads -> per-way SFENCE/VVMA/GVMA
  // matching -> valid-bit writes and sweep completion.
  // svt-plan: boundary row read -> registered flush-match mask -> invalidate;
  // decouple row cursor advancement from accepted invalidation write completion.
  // svt-plan: carry row index, way mask, fence kind/context and sweep
  // generation; count outstanding mask/write packets before clearing flush busy.
  // svt-plan: conflict serialize or epoch-mask lookup/refill traffic so a
  // concurrent refill cannot recreate a translation the in-flight fence removes.
  // svt-plan: effect splits match logic from valid-array write arbitration;
  // steady one-row/cycle service needs independent read/write capacity.
  // svt-plan: cost row descriptors and sweep drain cycles; preserve page
  // overlap, global-entry and virtualization-specific matching semantics.
  // svt-plan: limit commit's fence completion depends on actual drained
  // writes; an advanced cursor alone does not mean invalidation is complete.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 14.7 adjusted FO4 on the
  // Nangate45 board): shared TLB: flush / lookup FSM.
  // svt-pipe: require-contract
  // svt-pipe: protocol stlb valid=itlb_access_i flush=flush_i
  // svt-pipe: no-cut on=flush_state_q
  // svt-pipe: cycle stlb q=flush_state_q d=flush_busy_o hold=itlb_access_i steps=1

  function logic [SHARED_TLB_WAYS-1:0] shared_tlb_way_bin2oh(input logic [$clog2(SHARED_TLB_WAYS
)-1:0] in);
    logic [SHARED_TLB_WAYS-1:0] out;
    out     = '0;
    out[in] = 1'b1;
    return out;
  endfunction

  localparam bit HART_TAG = (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;

  typedef struct packed {
    logic [G6LCCfg.ASID_WIDTH-1:0] asid;
    logic [G6LCCfg.VMID_WIDTH-1:0] vmid;
    // T6b-2b: owning SMT hart (compared only under mixed residency)
    logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart;
    logic [G6LCCfg.PtLevels+HYP_EXT-1:0][(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1:0] vpn;
    logic [G6LCCfg.PtLevels-2:0][HYP_EXT:0] is_page;
    logic [HYP_EXT*2:0] v_st_enbl;  // v_i,g-stage enabled, s-stage enabled
    logic is_napot_64k;  // Svnapot: Flag indicating a 64KiB NAPOT page
  } shared_tag_t;

  shared_tag_t shared_tag_wr;
  shared_tag_t [SHARED_TLB_WAYS-1:0] shared_tag_rd;

  typedef enum logic [1:0] {
    FLUSH_SFENCE,
    FLUSH_VVMA,
    FLUSH_GVMA
  } flush_kind_e;
  flush_kind_e flush_kind_q, flush_kind_d;

  typedef enum logic [1:0] {
    IDLE,
    FLUSH_READ,
    FLUSH_APPLY
  } flush_state_e;  //flushing states
  flush_state_e flush_state_q, flush_state_d;

  // flushing
  logic [$clog2(G6LCCfg.SharedTlbDepth)-1:0] flush_idx_q, flush_idx_d;
  logic [G6LCCfg.ASID_WIDTH-1:0] flush_asid_q, flush_asid_d;
  logic [G6LCCfg.VLEN-1:0] flush_vaddr_q, flush_vaddr_d;
  logic [G6LCCfg.VMID_WIDTH-1:0] flush_vmid_q, flush_vmid_d;
  logic [G6LCCfg.GPLEN-1:0] flush_gpaddr_q, flush_gpaddr_d;

  logic [SHARED_TLB_WAYS-1:0] sfence_match_way;
  logic [SHARED_TLB_WAYS-1:0] vvma_match_way;
  logic [SHARED_TLB_WAYS-1:0] gvma_match_way;
  logic [SHARED_TLB_WAYS-1:0] flush_match_way;

  logic flush_vmid_is0;
  logic flush_gpaddr_is0;

  // r42-T item 19: the live-arm flush select staged as registered
  // next-state bits (as item 16's T1/T2 split). flush_state_d already
  // encodes next-cycle ownership, so walk_own_q == (state==FLUSH_READ)
  // and walk_blk_q == (state!=IDLE) cycle-exactly; the miss-accept cone
  // reads bits instead of decoding the 3-state FSM inline.
  // svt-pipe: cycle stlb q=walk_own_q,walk_blk_q d=flush_state_d steps=1
  logic walk_own_q, walk_blk_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      walk_own_q <= 1'b0;
      walk_blk_q <= 1'b0;
    end else begin
`ifdef G6LC_MUT_T2_STLB_FLUSHSEL
      walk_own_q <= 1'b0;
      walk_blk_q <= 1'b0;
`else
      walk_own_q <= (flush_state_d == FLUSH_READ);
      walk_blk_q <= (flush_state_d != IDLE);
`endif
    end
  end

  logic [G6LCCfg.SharedTlbDepth-1:0][SHARED_TLB_WAYS-1:0] shared_tag_valid_q, shared_tag_valid_d;

  logic [               SHARED_TLB_WAYS-1:0] shared_tag_valid;

  logic [               SHARED_TLB_WAYS-1:0] tag_wr_en;
  logic [$clog2(G6LCCfg.SharedTlbDepth)-1:0] tag_wr_addr;
  logic [           $bits(shared_tag_t)-1:0] tag_wr_data;

  logic [               SHARED_TLB_WAYS-1:0] tag_rd_en;
  logic [$clog2(G6LCCfg.SharedTlbDepth)-1:0] tag_rd_addr;
  logic [           $bits(shared_tag_t)-1:0] tag_rd_data      [SHARED_TLB_WAYS-1:0];

  logic [               SHARED_TLB_WAYS-1:0] tag_req;
  logic [               SHARED_TLB_WAYS-1:0] tag_we;
  logic [$clog2(G6LCCfg.SharedTlbDepth)-1:0] tag_addr;

  logic [               SHARED_TLB_WAYS-1:0] pte_wr_en;
  logic [$clog2(G6LCCfg.SharedTlbDepth)-1:0] pte_wr_addr;
  logic [                  G6LCCfg.XLEN-1:0] pte_wr_data      [                1:0];

  logic [               SHARED_TLB_WAYS-1:0] pte_rd_en;
  logic [$clog2(G6LCCfg.SharedTlbDepth)-1:0] pte_rd_addr;
  logic [                  G6LCCfg.XLEN-1:0] pte_rd_data      [SHARED_TLB_WAYS-1:0] [HYP_EXT:0];

  logic [               SHARED_TLB_WAYS-1:0] pte_req;
  logic [               SHARED_TLB_WAYS-1:0] pte_we;
  logic [$clog2(G6LCCfg.SharedTlbDepth)-1:0] pte_addr;

  logic [G6LCCfg.PtLevels+HYP_EXT-1:0][(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1:0] vpn_d, vpn_q;
  logic [SHARED_TLB_WAYS-1:0][G6LCCfg.PtLevels-1:0] vpn_match;
  logic [SHARED_TLB_WAYS-1:0][G6LCCfg.PtLevels-1:0] page_match;
  logic [SHARED_TLB_WAYS-1:0][G6LCCfg.PtLevels-1:0] level_match;

  logic [SHARED_TLB_WAYS-1:0] match_asid;
  logic [SHARED_TLB_WAYS-1:0] match_vmid;
  logic [SHARED_TLB_WAYS-1:0] match_hart;
  logic [SHARED_TLB_WAYS-1:0] match_stage;

  pte_g6lc_t [SHARED_TLB_WAYS-1:0][HYP_EXT:0] pte;

  logic [G6LCCfg.VLEN-1-12:0] itlb_vpn_q;
  logic [G6LCCfg.VLEN-1-12:0] dtlb_vpn_q;

  logic [G6LCCfg.ASID_WIDTH-1:0] tlb_update_asid_q, tlb_update_asid_d;
  logic [G6LCCfg.VMID_WIDTH-1:0] tlb_update_vmid_q, tlb_update_vmid_d;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] tlb_update_hart_q, tlb_update_hart_d;

  logic shared_tlb_access_q, shared_tlb_access_d;
  logic shared_tlb_hit_d;
  logic [G6LCCfg.VLEN-1:0] shared_tlb_vaddr_q, shared_tlb_vaddr_d;

  logic      [ G6LCCfg.VpnLen-1:0] lu_vpn;
  logic      [SHARED_TLB_WAYS-1:0] vpn0_napot_match;
  logic      [SHARED_TLB_WAYS-1:0] napot_tag_match;
  pte_g6lc_t                       patched_pte;

  logic itlb_req_d, itlb_req_q;
  logic dtlb_req_d, dtlb_req_q;

  int i_req_d, i_req_q;

  logic [1:0][2:0] v_st_enbl;

  // replacement strategy
  logic [SHARED_TLB_WAYS-1:0] way_valid;
  logic update_lfsr;  // shift the LFSR
  logic [$clog2(SHARED_TLB_WAYS)-1:0] inv_way;  // first non-valid encountered
  logic [$clog2(SHARED_TLB_WAYS)-1:0] rnd_way;  // random index for replacement
  logic [$clog2(SHARED_TLB_WAYS)-1:0] repl_way;  // way to replace
  logic [SHARED_TLB_WAYS-1:0] repl_way_oh_d;  // way to replace (onehot)
  logic all_ways_valid;  // we need to switch repl strategy since all are valid

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_shared_tlb  region=5487  makespan=5.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: dtlb_req_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dtlb_req_q
// order expect: dtlb_vpn_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dtlb_vpn_q
// order expect: flush_asid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_asid_q
// order expect: flush_gpaddr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_gpaddr_q
// order expect: flush_idx_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_idx_q
// order expect: flush_kind_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_kind_q
// order expect: flush_state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_state_q
// order expect: flush_vaddr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_vaddr_q
// order expect: flush_vmid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_vmid_q
// order expect: i_req_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to i_req_q
// order expect: itlb_req_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to itlb_req_q
// order expect: itlb_vpn_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to itlb_vpn_q
// order expect: shared_tag_valid  ready_cycle=1  ready_fo4=5.000  OpenSTA: report_timing -from clk_i -to shared_tag_valid
// order expect: shared_tag_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to shared_tag_valid_q
// order expect: shared_tlb_access_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to shared_tlb_access_q
// order expect: shared_tlb_vaddr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to shared_tlb_vaddr_q
// order expect: tlb_update_asid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tlb_update_asid_q
// order expect: tlb_update_hart_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tlb_update_hart_q
// order expect: vpn_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to vpn_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     dtlb_req_q <= …; // sv-timing: cycle 1/1 on clk_i
//     dtlb_vpn_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_asid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_gpaddr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_idx_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_kind_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_vaddr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_vmid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     i_req_q <= …; // sv-timing: cycle 1/1 on clk_i
//     itlb_req_q <= …; // sv-timing: cycle 1/1 on clk_i
//     itlb_vpn_q <= …; // sv-timing: cycle 1/1 on clk_i
//     shared_tag_valid <= …; // sv-timing: cycle 1/1 on clk_i
//     shared_tag_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     shared_tlb_access_q <= …; // sv-timing: cycle 1/1 on clk_i
//     shared_tlb_vaddr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tlb_update_asid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tlb_update_hart_q <= …; // sv-timing: cycle 1/1 on clk_i
//     vpn_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node19212 c=3.50 slack=1.50 */
//     /* node19213 c=3.50 slack=1.50 */
//     /* node19214 c=3.50 slack=1.50 */
//     /* node19215 c=3.50 slack=1.50 */
//     /* node19216 c=3.50 slack=1.50 */
//     /* node19217 c=3.50 slack=1.50 */
//     /* node19218 c=3.50 slack=1.50 */
//     /* node19219 c=3.50 slack=1.50 */
//     /* node19220 c=3.50 slack=1.50 */
//     /* node19221 c=3.50 slack=1.50 */
//     /* node19222 c=3.50 slack=1.50 */
//     /* node19223 c=3.50 slack=1.50 */
//     /* node19224 c=3.50 slack=1.50 */
//     /* node19225 c=3.50 slack=1.50 */
//     /* node19226 c=3.50 slack=1.50 */
//     /* node19227 c=3.50 slack=1.50 */
//     /* node19228 c=3.50 slack=1.50 */
//     /* node19229 c=3.50 slack=1.50 */
//     /* node19230 c=3.50 slack=1.50 */
//     /* node19231 c=3.50 slack=1.50 */
//     /* node19232 c=3.50 slack=1.50 */
//     /* node19233 c=3.50 slack=1.50 */
//     /* node19234 c=3.50 slack=1.50 */
//     /* node19235 c=3.50 slack=1.50 */
//     /* node19236 c=3.50 slack=1.50 */
//     /* node19237 c=3.50 slack=1.50 */
//     /* node19238 c=3.50 slack=1.50 */
//     /* node19239 c=3.50 slack=1.50 */
//     /* node19240 c=3.50 slack=1.50 */
//     /* node19241 c=3.50 slack=1.50 */
//     /* node19242 c=5.00 slack=0.00 */
//     /* node19243 c=3.50 slack=1.50 */
//     /* node19244 c=3.50 slack=1.50 */
//     /* node19245 c=3.50 slack=1.50 */
//     /* node19246 c=3.50 slack=1.50 */
//     /* node19247 c=3.50 slack=1.50 */
//     /* node19248 c=3.50 slack=1.50 */
//     /* node19249 c=3.50 slack=1.50 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign shared_tlb_access_o = shared_tlb_access_q;
  assign shared_tlb_hit_o = shared_tlb_hit_d;
  assign shared_tlb_vaddr_o = shared_tlb_vaddr_q;
  assign itlb_req_o = itlb_req_q;
  assign v_st_enbl = {{v_i, g_st_enbl_i, s_st_enbl_i}, {ld_st_v_i, g_ld_st_enbl_i, s_ld_st_enbl_i}};
  assign lu_vpn = itlb_req_q ? itlb_vpn_q : dtlb_vpn_q;

  assign flush_vmid_is0 = ~(|flush_vmid_q);
  assign flush_gpaddr_is0 = ~(|flush_gpaddr_q);
  // r90: the flush kind is registered at flush start — a one-hot keeps
  // the two 2-bit compares off the apply path (exact: flush_kind_q is
  // only written while leaving IDLE, with the same flush_i > vvma >
  // gvma priority as the FSM's IDLE arm).
  logic is_sfence_q, is_vvma_q, is_gvma_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) {is_gvma_q, is_vvma_q, is_sfence_q} <= 3'b001;
    else if (flush_state_q == IDLE) begin
      if (flush_i)           {is_gvma_q, is_vvma_q, is_sfence_q} <= 3'b001;
      else if (flush_vvma_i) {is_gvma_q, is_vvma_q, is_sfence_q} <= 3'b010;
      else if (flush_gvma_i) {is_gvma_q, is_vvma_q, is_sfence_q} <= 3'b100;
    end
  end
//pragma translate_off
  always_ff @(posedge clk_i) begin : flush_kind_onehot_chk
    if (rst_ni && flush_state_q != IDLE &&
        ({is_gvma_q, is_vvma_q, is_sfence_q} !=
         {flush_kind_q == FLUSH_GVMA, flush_kind_q == FLUSH_VVMA, flush_kind_q == FLUSH_SFENCE}))
      $error("flush kind one-hot != flush_kind_q");
  end
//pragma translate_on
  assign flush_match_way = ({SHARED_TLB_WAYS{is_sfence_q}} & sfence_match_way)
                         | ({SHARED_TLB_WAYS{is_vvma_q}}   & vvma_match_way)
                         | ({SHARED_TLB_WAYS{is_gvma_q}}   & gvma_match_way);

  assign shared_tag_wr.asid = shared_tlb_update_i.asid;
  assign shared_tag_wr.vmid = shared_tlb_update_i.vmid;
  assign shared_tag_wr.hart = shared_tlb_update_i.hart;
  assign shared_tag_wr.is_page = shared_tlb_update_i.is_page;
  assign shared_tag_wr.v_st_enbl = v_st_enbl[i_req_q][HYP_EXT*2:0];

  genvar i_gen, x_gen;
  generate
    for (i_gen = 0; i_gen < SHARED_TLB_WAYS; i_gen++) begin : gen_match_tlb_ways
      //identify page_match for all TLB Entries

      for (x_gen = 0; x_gen < G6LCCfg.PtLevels; x_gen++) begin : gen_match
        assign page_match[i_gen][x_gen] = x_gen==0 ? 1 :((HYP_EXT==0 || x_gen==(G6LCCfg.PtLevels-1)) ? // PAGE_MATCH CONTAINS THE MATCH INFORMATION FOR EACH TAG OF is_1G and is_2M in sv39x4. HIGHER LEVEL (Giga page), THEN THERE IS THE Mega page AND AT THE LOWER LEVEL IS ALWAYS 1
            &(shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen] | (~v_st_enbl[i_req_q][HYP_EXT:0])):
                              ((&v_st_enbl[i_req_q][HYP_EXT:0]) ?
                              ((shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][0] && (shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-2-x_gen][HYP_EXT] || shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][HYP_EXT]))
                            || (shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][HYP_EXT] && (shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-2-x_gen][0] || shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][0]))):
                                shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][0] && v_st_enbl[i_req_q][0] || shared_tag_rd[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][HYP_EXT] && v_st_enbl[i_req_q][HYP_EXT]));

        //identify if vpn matches at all PT levels for all TLB entries
        assign vpn_match[i_gen][x_gen]        = (HYP_EXT==1 && x_gen==(G6LCCfg.PtLevels-1) && ~v_st_enbl[i_req_q][0]) ? //
            vpn_q[x_gen] == shared_tag_rd[i_gen].vpn[x_gen] &&  vpn_q[x_gen+HYP_EXT][(G6LCCfg.VpnLen%G6LCCfg.PtLevels)-HYP_EXT:0] == shared_tag_rd[i_gen].vpn[x_gen+HYP_EXT][(G6LCCfg.VpnLen%G6LCCfg.PtLevels)-HYP_EXT:0]: //
            vpn_q[x_gen] == shared_tag_rd[i_gen].vpn[x_gen];

        //identify if there is a hit at each PT level for all TLB entries
        assign level_match[i_gen][x_gen] = &vpn_match[i_gen][G6LCCfg.PtLevels-1:x_gen] && page_match[i_gen][x_gen];

      end
      assign vpn0_napot_match[i_gen] = lu_vpn[(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1 : 4] == shared_tag_rd[i_gen].vpn[0][(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1 : 4];
      assign napot_tag_match[i_gen] = (G6LCCfg.SvnapotEn && shared_tag_rd[i_gen].is_napot_64k) ?
                                  (vpn_match[i_gen][2] && vpn_match[i_gen][1] && vpn0_napot_match[i_gen]) : 1'b0;
    end
  endgenerate

  genvar w_gen;
  generate
    for (w_gen = 0; w_gen < G6LCCfg.PtLevels; w_gen++) begin
      assign vpn_d[w_gen]               = ((|v_st_enbl[1][HYP_EXT:0]) && itlb_access_i && ~itlb_hit_i && ~dtlb_access_i) ? //
          itlb_vaddr_i[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(w_gen+1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*w_gen)] :  //
          (((|v_st_enbl[0][HYP_EXT:0]) && dtlb_access_i && ~dtlb_hit_i) ?  //
          dtlb_vaddr_i[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(w_gen+1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*w_gen)] : vpn_q[w_gen]);
    end
  endgenerate

  if (G6LCCfg.RVH)  //THIS UPDATES THE EXTRA BITS OF VPN IN SV39x4
    assign vpn_d[G6LCCfg.PtLevels] = ((|v_st_enbl[1][HYP_EXT:0]) && itlb_access_i && ~itlb_hit_i && ~dtlb_access_i) ? //
        {{(((G6LCCfg.VpnLen/G6LCCfg.PtLevels)-(G6LCCfg.VpnLen%G6LCCfg.PtLevels))){1'b0}}, itlb_vaddr_i[G6LCCfg.VpnLen-1:G6LCCfg.VpnLen-(G6LCCfg.VpnLen%G6LCCfg.PtLevels)]} :  //
        (((|v_st_enbl[0][HYP_EXT:0]) && dtlb_access_i && ~dtlb_hit_i) ?  //
        {{(((G6LCCfg.VpnLen/G6LCCfg.PtLevels)-(G6LCCfg.VpnLen%G6LCCfg.PtLevels))){1'b0}}, dtlb_vaddr_i[G6LCCfg.VpnLen-1: G6LCCfg.VpnLen-(G6LCCfg.VpnLen%G6LCCfg.PtLevels)]} : //
        {{(((G6LCCfg.VpnLen/G6LCCfg.PtLevels)-(G6LCCfg.VpnLen%G6LCCfg.PtLevels))){1'b0}}, vpn_q[G6LCCfg.PtLevels][(G6LCCfg.VpnLen%G6LCCfg.PtLevels)-1:0]});

  ///////////////////////////////////////////////////////
  // tag comparison, hit generation
  // hyp8 (M1): the accept→compare staging the plan calls T1/T2 is the
  // shape this module already has: the arbitration result (itlb_req_q /
  // dtlb_req_q / i_req_q / vpn_q / tlb_update_*_q) is registered at the
  // accept edge with the tag/PTE RAM read enables, and the way compares +
  // PTE select evaluate in the following cycle when shared_tag_rd/pte are
  // valid. shared_tlb_hit_d must stay combinational with that compare —
  // the PTW samples it in the same cycle as the pulsed shared_tlb_access_q,
  // so registering it would misalign hit/access by a cycle. With
  // TlbStages==3 the small TLBs answer two cycles late; g6lc_mmu delays
  // the access/vaddr/context inputs presented here so the accept
  // conditions below only see final verdicts.
  ///////////////////////////////////////////////////////
  always_comb begin : itlb_dtlb_miss
    itlb_miss_o         = 1'b0;
    dtlb_miss_o         = 1'b0;

    tag_rd_en           = '0;
    pte_rd_en           = '0;

    itlb_req_d          = 1'b0;
    dtlb_req_d          = 1'b0;

    tlb_update_asid_d   = tlb_update_asid_q;
    tlb_update_vmid_d   = tlb_update_vmid_q;
    tlb_update_hart_d   = tlb_update_hart_q;

    shared_tlb_access_d = '0;
    shared_tlb_vaddr_d  = shared_tlb_vaddr_q;

    tag_rd_addr         = '0;
    pte_rd_addr         = '0;
    i_req_d             = i_req_q;

    //owning read ports while flush walker is active
`ifdef G6LC_MUT_T2_STLB_FLUSHSEL
    if (flush_state_q == FLUSH_READ) begin
      tag_rd_en   = '1;
      pte_rd_en   = '1;
      tag_rd_addr = flush_idx_q;
      pte_rd_addr = flush_idx_q;
    end else if ((flush_state_q != IDLE) || flush_i || flush_vvma_i || flush_gvma_i) begin
`else
    if (walk_own_q) begin
      tag_rd_en   = '1;
      pte_rd_en   = '1;
      tag_rd_addr = flush_idx_q;
      pte_rd_addr = flush_idx_q;
    end else if (walk_blk_q || flush_i || flush_vvma_i || flush_gvma_i) begin
`endif
      //minimal approach holding lookup quiet during flush
      // if we got an ITLB miss
    end else if ((|v_st_enbl[1][HYP_EXT:0]) & itlb_access_i & ~itlb_hit_i & ~dtlb_access_i) begin
      tag_rd_en           = '1;
      tag_rd_addr         = itlb_vaddr_i[12+:$clog2(G6LCCfg.SharedTlbDepth)];
      pte_rd_en           = '1;
      pte_rd_addr         = itlb_vaddr_i[12+:$clog2(G6LCCfg.SharedTlbDepth)];

      itlb_miss_o         = shared_tlb_miss_i;
      itlb_req_d          = 1'b1;
      tlb_update_asid_d   = itlb_asid_i;
      tlb_update_vmid_d   = itlb_vmid_i;
      tlb_update_hart_d   = itlb_hart_i;

      shared_tlb_access_d = '1;
      shared_tlb_vaddr_d  = itlb_vaddr_i;
      i_req_d             = 1;

      // we got an DTLB miss
    end else if ((|v_st_enbl[0][HYP_EXT:0]) & dtlb_access_i & ~dtlb_hit_i) begin
      tag_rd_en           = '1;
      tag_rd_addr         = dtlb_vaddr_i[12+:$clog2(G6LCCfg.SharedTlbDepth)];
      pte_rd_en           = '1;
      pte_rd_addr         = dtlb_vaddr_i[12+:$clog2(G6LCCfg.SharedTlbDepth)];

      dtlb_miss_o         = shared_tlb_miss_i;
      dtlb_req_d          = 1'b1;
      tlb_update_asid_d   = dtlb_asid_i;
      tlb_update_vmid_d   = lu_vmid_i;
      tlb_update_hart_d   = dtlb_hart_i;

      shared_tlb_access_d = '1;
      shared_tlb_vaddr_d  = dtlb_vaddr_i;
      i_req_d             = 0;
    end
  end  //itlb_dtlb_miss

  always_comb begin : tag_comparison
    shared_tlb_hit_d = 1'b0;
    dtlb_update_o    = '0;
    itlb_update_o    = '0;
    // r63: default so a non-hit path never infers a latch on patched_pte
    patched_pte      = '0;
    match_asid       = '{default: 0};
    match_vmid       = G6LCCfg.RVH ? '{default: 0} : '{default: 1};
    match_hart       = HART_TAG ? '{default: 0} : '{default: 1};


    if (!G6LCCfg.UseSharedTlb) begin
      if (shared_tlb_update_i.valid) begin
        shared_tlb_hit_d = 1'b1;
        if (itlb_req_q) begin
          itlb_update_o.valid = 1'b1;
          itlb_update_o.vpn = shared_tlb_update_i.vpn;
          itlb_update_o.is_page = shared_tlb_update_i.is_page;
          itlb_update_o.content = shared_tlb_update_i.content;
          itlb_update_o.g_content = shared_tlb_update_i.g_content;
          itlb_update_o.v_st_enbl = v_st_enbl[i_req_q][HYP_EXT*2:0];
          itlb_update_o.asid = shared_tlb_update_i.asid;
          itlb_update_o.vmid = shared_tlb_update_i.vmid;
          itlb_update_o.hart = shared_tlb_update_i.hart;
          itlb_update_o.is_napot_64k = shared_tlb_update_i.is_napot_64k;

        end else if (dtlb_req_q) begin
          dtlb_update_o.valid = 1'b1;
          dtlb_update_o.vpn = shared_tlb_update_i.vpn;
          dtlb_update_o.is_page = shared_tlb_update_i.is_page;
          dtlb_update_o.content = shared_tlb_update_i.content;
          dtlb_update_o.g_content = shared_tlb_update_i.g_content;
          dtlb_update_o.v_st_enbl = v_st_enbl[i_req_q][HYP_EXT*2:0];
          dtlb_update_o.asid = shared_tlb_update_i.asid;
          dtlb_update_o.vmid = shared_tlb_update_i.vmid;
          dtlb_update_o.hart = shared_tlb_update_i.hart;
          dtlb_update_o.is_napot_64k = shared_tlb_update_i.is_napot_64k;
        end
      end
    end else begin

      //number of ways
      for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
        // first level match, this may be a giga page, check the ASID flags as well
        // if the entry is associated to a global address, don't match the ASID (ASID is don't care)
        match_asid[i] = (((tlb_update_asid_q == shared_tag_rd[i].asid) || pte[i][0].g) && v_st_enbl[i_req_q][0]) || !v_st_enbl[i_req_q][0];

        if (G6LCCfg.RVH) begin
          match_vmid[i] = (tlb_update_vmid_q == shared_tag_rd[i].vmid && v_st_enbl[i_req_q][HYP_EXT]) || !v_st_enbl[i_req_q][HYP_EXT];
        end

        // T6b-2b: shared entries are per-hart under mixed residency; the
        // compare constant-folds to 1 otherwise (drained sharing is intended).
`ifdef G6LC_MUT_TLB_NO_HART_TAG
        // Review-only mutation: the hart tag never discriminates.
        match_hart[i] = 1'b1;
`else
        match_hart[i] = HART_TAG ? (shared_tag_rd[i].hart == tlb_update_hart_q) : 1'b1;
`endif

        // check if translation is a: S-Stage and G-Stage, S-Stage only or G-Stage only translation and virtualization mode is on/off
        match_stage[i] = shared_tag_rd[i].v_st_enbl == v_st_enbl[i_req_q][HYP_EXT*2:0];

        if (shared_tag_valid[i] && match_asid[i] && match_vmid[i] && match_hart[i] && match_stage[i]) begin
          if (|level_match[i] || napot_tag_match[i]) begin
            shared_tlb_hit_d = 1'b1;
            // Prepare PTE with NAPOT patching if needed
            patched_pte      = pte[i][0];  // take the S‑stage PTE only
            if (shared_tag_rd[i].is_napot_64k && G6LCCfg.SvnapotEn) begin
              // replace PPN[3:0] with vaddr[15:12] (equiv. lu_vpn[3:0])
              patched_pte.ppn[3:0] = lu_vpn[3:0];
            end
            if (itlb_req_q) begin
              itlb_update_o.valid = 1'b1;
              itlb_update_o.vpn = itlb_vpn_q;
              itlb_update_o.is_page = shared_tag_rd[i].is_page;
              itlb_update_o.content = patched_pte;
              itlb_update_o.g_content = pte[i][HYP_EXT];
              itlb_update_o.v_st_enbl = shared_tag_rd[i].v_st_enbl;
              itlb_update_o.asid = tlb_update_asid_q;
              itlb_update_o.vmid = tlb_update_vmid_q;
              itlb_update_o.hart = tlb_update_hart_q;
              itlb_update_o.is_napot_64k = G6LCCfg.SvnapotEn ? shared_tag_rd[i].is_napot_64k : 1'b0;
            end else if (dtlb_req_q) begin
              dtlb_update_o.valid = 1'b1;
              dtlb_update_o.vpn = dtlb_vpn_q;
              dtlb_update_o.is_page = shared_tag_rd[i].is_page;
              dtlb_update_o.content = patched_pte;
              dtlb_update_o.g_content = pte[i][HYP_EXT];
              dtlb_update_o.v_st_enbl = shared_tag_rd[i].v_st_enbl;
              dtlb_update_o.asid = tlb_update_asid_q;
              dtlb_update_o.vmid = tlb_update_vmid_q;
              dtlb_update_o.hart = tlb_update_hart_q;
              dtlb_update_o.is_napot_64k = G6LCCfg.SvnapotEn ? shared_tag_rd[i].is_napot_64k : 1'b0;
            end
          end
        end
      end
    end
  end  //tag_comparison

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      itlb_vpn_q <= '0;
      dtlb_vpn_q <= '0;
      tlb_update_asid_q <= '{default: 0};
      tlb_update_hart_q <= '0;
      shared_tlb_access_q <= '0;
      shared_tlb_vaddr_q <= '0;
      shared_tag_valid_q <= '0;
      vpn_q <= 0;
      itlb_req_q <= '0;
      dtlb_req_q <= '0;
      i_req_q <= 0;
      shared_tag_valid <= '0;
      flush_state_q <= IDLE;
      flush_idx_q <= '0;
      flush_asid_q <= '0;
      flush_vaddr_q <= '0;
      flush_kind_q <= FLUSH_SFENCE;
      flush_vmid_q <= '0;
      flush_gpaddr_q <= '0;

    end else begin
      itlb_vpn_q <= itlb_vaddr_i[G6LCCfg.SV-1:12];
      dtlb_vpn_q <= dtlb_vaddr_i[G6LCCfg.SV-1:12];
      tlb_update_asid_q <= tlb_update_asid_d;
      tlb_update_hart_q <= tlb_update_hart_d;
      shared_tlb_access_q <= shared_tlb_access_d;
      shared_tlb_vaddr_q <= shared_tlb_vaddr_d;
      shared_tag_valid_q <= shared_tag_valid_d;
      vpn_q <= vpn_d;
      itlb_req_q <= itlb_req_d;
      dtlb_req_q <= dtlb_req_d;
      i_req_q <= i_req_d;
      shared_tag_valid <= shared_tag_valid_q[tag_rd_addr];
      flush_state_q <= flush_state_d;
      flush_idx_q <= flush_idx_d;
      flush_asid_q <= flush_asid_d;
      flush_vaddr_q <= flush_vaddr_d;
      flush_kind_q <= flush_kind_d;
      flush_vmid_q <= flush_vmid_d;
      flush_gpaddr_q <= flush_gpaddr_d;

    end
  end

  if (G6LCCfg.RVH) begin
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        tlb_update_vmid_q <= '{default: 0};
      end else begin
        tlb_update_vmid_q <= tlb_update_vmid_d;
      end
    end
  end

  // ------------------
  // Update and Flush
  // ------------------

  logic [G6LCCfg.VpnLen-1:0] vpn_to_store;
  logic [$clog2(G6LCCfg.SharedTlbDepth)-1:0] vpn_index;
  //flushing signals
  logic flush_asid_is0;
  logic flush_vaddr_is0;
  logic flush_last_set;

  // When storing the VPN in the shared TLB, if NAPOT is used, the lower bits of the VPN are zeroed
  // This way, when searching for a match, we can compare the full VPN if NAPOT is not used
  // or only the upper bits if NAPOT is used (the lower bits are don't care)
  // The actual PPN is stored in the PTE, with the lower bits patched if NAPOT is used
  // This is done in the tag comparison logic above

  assign vpn_to_store =
    (shared_tlb_update_i.is_napot_64k && G6LCCfg.SvnapotEn)
      ? {shared_tlb_update_i.vpn[G6LCCfg.VpnLen-1:4], 4'b0}
      : shared_tlb_update_i.vpn;

  always_comb begin : flush_fsm
    flush_state_d = flush_state_q;
    flush_idx_d = flush_idx_q;
    flush_asid_d = flush_asid_q;
    flush_vaddr_d = flush_vaddr_q;
    flush_kind_d = flush_kind_q;
    flush_vmid_d = flush_vmid_q;
    flush_gpaddr_d = flush_gpaddr_q;

    unique case (flush_state_q)
      IDLE: begin
        if (G6LCCfg.UseSharedTlb && flush_i) begin
          flush_state_d = FLUSH_READ;
          flush_idx_d = '0;
          flush_asid_d = asid_to_be_flushed_i;
          flush_vaddr_d = vaddr_to_be_flushed_i;
          flush_kind_d = FLUSH_SFENCE;
          flush_vmid_d = '0;
          flush_gpaddr_d = '0;
        end else if (G6LCCfg.UseSharedTlb && flush_vvma_i) begin
          flush_state_d = FLUSH_READ;
          flush_idx_d = '0;
          flush_asid_d = asid_to_be_flushed_i;
          flush_vaddr_d = vaddr_to_be_flushed_i;
          flush_kind_d = FLUSH_VVMA;
          flush_vmid_d = lu_vmid_i;
          flush_gpaddr_d = '0;
        end else if (G6LCCfg.UseSharedTlb && flush_gvma_i) begin
          flush_state_d = FLUSH_READ;
          flush_idx_d = '0;
          flush_asid_d = '0;
          flush_vaddr_d = '0;
          flush_kind_d = FLUSH_GVMA;
          flush_vmid_d = vmid_to_be_flushed_i;
          flush_gpaddr_d = gpaddr_to_be_flushed_i;
        end
      end

      FLUSH_READ: begin
        flush_state_d = FLUSH_APPLY;
      end

      FLUSH_APPLY: begin
        if (flush_last_set) begin
          flush_state_d = IDLE;
          flush_idx_d   = '0;
        end else begin
          flush_idx_d   = flush_idx_q + 1'b1;
          flush_state_d = FLUSH_READ;
        end
      end

      default: begin
        flush_state_d = IDLE;
      end
    endcase
  end

  localparam int unsigned VPN_SEG_W = G6LCCfg.VpnLen / G6LCCfg.PtLevels;
  always_comb begin : sfence_match_logic
    sfence_match_way = '0;

    for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
      logic [G6LCCfg.PtLevels-1:0] flush_vpn_match;
      logic [G6LCCfg.PtLevels-1:0] flush_level_match;
      logic                        flush_addr_matches;
      logic                        flush_addr_napot_matches;
      logic                        upper_levels_match;

      flush_vpn_match          = '0;
      flush_level_match        = '0;
      flush_addr_matches       = 1'b0;
      flush_addr_napot_matches = 1'b0;
      upper_levels_match       = 1'b0;

      for (int unsigned level = 0; level < G6LCCfg.PtLevels; level++) begin
        flush_vpn_match[level] = flush_vaddr_q[12 + VPN_SEG_W*level +: VPN_SEG_W] == shared_tag_rd[i].vpn[level];
      end
      //comparing the flush VA with stored VPN level by level_match
      for (int unsigned level = 0; level < G6LCCfg.PtLevels; level++) begin
        upper_levels_match = 1'b1;
        for (int unsigned k = level; k < G6LCCfg.PtLevels; k++) begin
          upper_levels_match &= flush_vpn_match[k];
        end
        flush_level_match[level] = upper_levels_match && ((level==0)? 1'b1: shared_tag_rd[i].is_page[G6LCCfg.PtLevels-1-level][0]);
      end

      if (G6LCCfg.SvnapotEn && shared_tag_rd[i].is_napot_64k) begin
        //VA matching NAPOT tag
        flush_addr_napot_matches = ((G6LCCfg.PtLevels > 1)? (&flush_vpn_match[G6LCCfg.PtLevels-1:1]): 1'b1) && (flush_vaddr_q[12+VPN_SEG_W-1: 16] == shared_tag_rd[i].vpn[0][VPN_SEG_W-1: 4]);
      end

      flush_addr_matches = (|flush_level_match) || flush_addr_napot_matches;

      if (shared_tag_valid[i] && ((HYP_EXT == 0) || !shared_tag_rd[i].v_st_enbl[HYP_EXT*2])) begin
        if (flush_asid_is0 && flush_vaddr_is0) begin  //SFENCE.VMA x0, x0
          sfence_match_way[i] = 1'b1;
        end else if(flush_asid_is0 && flush_addr_matches && !flush_vaddr_is0) begin //SFENCE.VMA vaddr, x0
          sfence_match_way[i] = 1'b1;
        end else if(!pte[i][0].g && flush_addr_matches && (flush_asid_q == shared_tag_rd[i].asid) && !flush_vaddr_is0 && !flush_asid_is0) begin //SFENCE.VMA vaddr, asid
          sfence_match_way[i] = 1'b1;
        end else if(!pte[i][0].g && flush_vaddr_is0  &&(flush_asid_q == shared_tag_rd[i].asid) && !flush_asid_is0)begin
          sfence_match_way[i] = 1'b1;
        end
      end
    end
  end

  always_comb begin : vvma_match_logic
    vvma_match_way = '0;

    for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
      logic [G6LCCfg.PtLevels-1:0] flush_vpn_match;
      logic [G6LCCfg.PtLevels-1:0] flush_level_match;
      logic                        flush_addr_matches;
      logic                        flush_addr_napot_matches;
      logic                        upper_levels_match;
      logic                        current_vmid_matches;

      flush_vpn_match = '0;
      flush_level_match = '0;
      flush_addr_matches = 1'b0;
      flush_addr_napot_matches = 1'b0;
      upper_levels_match = 1'b0;

      for (int unsigned level = 0; level < G6LCCfg.PtLevels; level++) begin
        flush_vpn_match[level] = flush_vaddr_q[12 + VPN_SEG_W*level +: VPN_SEG_W] == shared_tag_rd[i].vpn[level];
      end
      for (int unsigned level = 0; level < G6LCCfg.PtLevels; level++) begin
        upper_levels_match = 1'b1;
        for (int unsigned k = level; k < G6LCCfg.PtLevels; k++) begin
          upper_levels_match &= flush_vpn_match[k];
        end
        flush_level_match[level] = upper_levels_match && ((level==0) ? 1'b1: shared_tag_rd[i].is_page[G6LCCfg.PtLevels-1-level][0]);
      end

      if (G6LCCfg.SvnapotEn && shared_tag_rd[i].is_napot_64k) begin
        flush_addr_napot_matches = ((G6LCCfg.PtLevels > 1) ? (&flush_vpn_match[G6LCCfg.PtLevels-1:1]) : 1'b1) && (flush_vaddr_q[12+VPN_SEG_W-1:16]==shared_tag_rd[i].vpn[0][VPN_SEG_W-1:4]);
      end

      flush_addr_matches = (|flush_level_match) || flush_addr_napot_matches;

      current_vmid_matches = ((shared_tag_rd[i].v_st_enbl[HYP_EXT] && (flush_vmid_q == shared_tag_rd[i].vmid)) ||!shared_tag_rd[i].v_st_enbl[HYP_EXT]);

`ifdef G6LC_MUT_T3_STLB_VVMA
      // Review mutant: the pre-r43 priority if-chain.
      if(G6LCCfg.RVH && shared_tag_valid[i] && shared_tag_rd[i].v_st_enbl[HYP_EXT*2] && shared_tag_rd[i].v_st_enbl[0]) begin
        if (flush_asid_is0 && flush_vaddr_is0 && current_vmid_matches) begin
          vvma_match_way[i] = 1'b1;
        end else if (flush_asid_is0 && flush_addr_matches && !flush_vaddr_is0 && current_vmid_matches) begin
          vvma_match_way[i] = 1'b1;
        end else if(!pte[i][0].g && flush_addr_matches && (flush_asid_q == shared_tag_rd[i].asid) && !flush_vaddr_is0 && !flush_asid_is0 && current_vmid_matches) begin
          vvma_match_way[i] = 1'b1;
        end else if(!pte[i][0].g && flush_vaddr_is0 && (flush_asid_q == shared_tag_rd[i].asid) && !flush_asid_is0 && current_vmid_matches) begin
          vvma_match_way[i] = 1'b1;
        end
      end
`else
      // r43-T T5 (A22): the four exclusive vvma arms factor to
      // (vaddr0 || addr_matches) && (asid0 || (!g && asid_eq)) — the
      // priority chain is exact-flattened into parallel arm values.
      if(G6LCCfg.RVH && shared_tag_valid[i] && shared_tag_rd[i].v_st_enbl[HYP_EXT*2] && shared_tag_rd[i].v_st_enbl[0]) begin
        vvma_match_way[i] = current_vmid_matches &&
            (flush_vaddr_is0 || flush_addr_matches) &&
            (flush_asid_is0 ||
             (!pte[i][0].g && (flush_asid_q == shared_tag_rd[i].asid)));
      end
`endif
    end
  end

//pragma translate_off
`ifndef G6LC_MUT_T3_STLB_VVMA
  // r43-T T5 equivalence: recompute the pre-r43 priority chain and
  // compare every cycle.
  int unsigned t3_stlb_vvma_n = 0;
  logic [SHARED_TLB_WAYS-1:0] vvma_ref;
  always_comb begin
    for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
      logic [G6LCCfg.PtLevels-1:0] fvpn;
      logic [G6LCCfg.PtLevels-1:0] flvl;
      logic                        fam, fnap, ulm, cvm;
      fvpn = '0; flvl = '0; fam = 1'b0; fnap = 1'b0; ulm = 1'b0;
      for (int unsigned level = 0; level < G6LCCfg.PtLevels; level++)
        fvpn[level] = flush_vaddr_q[12 + VPN_SEG_W*level +: VPN_SEG_W] == shared_tag_rd[i].vpn[level];
      for (int unsigned level = 0; level < G6LCCfg.PtLevels; level++) begin
        ulm = 1'b1;
        for (int unsigned k = level; k < G6LCCfg.PtLevels; k++)
          ulm &= fvpn[k];
        flvl[level] = ulm && ((level==0) ? 1'b1: shared_tag_rd[i].is_page[G6LCCfg.PtLevels-1-level][0]);
      end
      if (G6LCCfg.SvnapotEn && shared_tag_rd[i].is_napot_64k)
        fnap = ((G6LCCfg.PtLevels > 1) ? (&fvpn[G6LCCfg.PtLevels-1:1]) : 1'b1) && (flush_vaddr_q[12+VPN_SEG_W-1:16]==shared_tag_rd[i].vpn[0][VPN_SEG_W-1:4]);
      fam = (|flvl) || fnap;
      cvm = ((shared_tag_rd[i].v_st_enbl[HYP_EXT] && (flush_vmid_q == shared_tag_rd[i].vmid)) || !shared_tag_rd[i].v_st_enbl[HYP_EXT]);
      vvma_ref[i] = 1'b0;
      if(G6LCCfg.RVH && shared_tag_valid[i] && shared_tag_rd[i].v_st_enbl[HYP_EXT*2] && shared_tag_rd[i].v_st_enbl[0]) begin
        if (flush_asid_is0 && flush_vaddr_is0 && cvm) vvma_ref[i] = 1'b1;
        else if (flush_asid_is0 && fam && !flush_vaddr_is0 && cvm) vvma_ref[i] = 1'b1;
        else if(!pte[i][0].g && fam && (flush_asid_q == shared_tag_rd[i].asid) && !flush_vaddr_is0 && !flush_asid_is0 && cvm) vvma_ref[i] = 1'b1;
        else if(!pte[i][0].g && flush_vaddr_is0 && (flush_asid_q == shared_tag_rd[i].asid) && !flush_asid_is0 && cvm) vvma_ref[i] = 1'b1;
      end
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      t3_stlb_vvma_n <= t3_stlb_vvma_n + 1;
      g6lc_t3_stlb_vvma_eq: assert (vvma_match_way === vvma_ref)
        else $error("g6lc_shared_tlb: equiv vvma %b vs %b", vvma_match_way, vvma_ref);
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_shared_tlb vvma: checked=%0d", t3_stlb_vvma_n);
  end
`endif
//pragma translate_on

  always_comb begin : gvma_match_logic
    gvma_match_way = '0;

    for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
      logic [G6LCCfg.VpnLen-1:0] gppn_i;
      logic [G6LCCfg.PtLevels-1:0] gpaddr_vpn_match;
      logic [G6LCCfg.PtLevels-1:0] gpaddr_level_match;
      logic upper_levels_match;

      gppn_i             = '0;
      gpaddr_vpn_match   = '0;
      gpaddr_level_match = '0;
      upper_levels_match = '0;

      if (G6LCCfg.RVH) begin
        if (shared_tag_rd[i].v_st_enbl[0]) begin
          gppn_i[G6LCCfg.VpnLen-1:0] = pte[i][0].ppn[G6LCCfg.VpnLen-1:0];

          if (shared_tag_rd[i].is_page[1][0]) gppn_i[VPN_SEG_W-1:0] = shared_tag_rd[i].vpn[0];
          if (shared_tag_rd[i].is_page[0][0])
            gppn_i[2*VPN_SEG_W-1:0] = {shared_tag_rd[i].vpn[1], shared_tag_rd[i].vpn[0]};
        end else begin
          gppn_i[G6LCCfg.VpnLen-1:0] = G6LCCfg.VpnLen'({shared_tag_rd[i].vpn});
        end

        for (int unsigned level = 0; level < G6LCCfg.PtLevels; level++) begin
          gpaddr_vpn_match[level] = flush_gpaddr_q[12 + VPN_SEG_W*level +: VPN_SEG_W] == gppn_i[VPN_SEG_W*level +: VPN_SEG_W];
        end

        for (int unsigned level = 0; level < G6LCCfg.PtLevels; level++) begin
          upper_levels_match = 1'b1;
          for (int unsigned k = level; k < G6LCCfg.PtLevels; k++) begin
            upper_levels_match &= gpaddr_vpn_match[k];
          end
          gpaddr_level_match[level] = upper_levels_match && ((level == 0) ? 1'b1 : shared_tag_rd[i].is_page[G6LCCfg.PtLevels-1-level][HYP_EXT]);
        end
        if (shared_tag_valid[i] && shared_tag_rd[i].v_st_enbl[HYP_EXT]) begin
          if (flush_vmid_is0 && flush_gpaddr_is0) begin
            gvma_match_way[i] = 1'b1;
          end else if (flush_vmid_is0 && (|gpaddr_level_match) && !flush_gpaddr_is0) begin
            gvma_match_way[i] = 1'b1;
          end else if ((|gpaddr_level_match) && (flush_vmid_q == shared_tag_rd[i].vmid) && !flush_gpaddr_is0 && !flush_vmid_is0) begin
            gvma_match_way[i] = 1'b1;
          end else if (flush_gpaddr_is0 && (flush_vmid_q == shared_tag_rd[i].vmid) && !flush_vmid_is0) begin
            gvma_match_way[i] = 1'b1;
          end
        end
      end
    end
  end

  always_comb begin : update_flush
    shared_tag_valid_d = shared_tag_valid_q;
    tag_wr_en = '0;
    pte_wr_en = '0;

    if (G6LCCfg.UseSharedTlb && flush_state_q == FLUSH_APPLY) begin
      for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
        if (flush_match_way[i]) begin
          shared_tag_valid_d[flush_idx_q][i] = 1'b0;
        end
      end
    end

    if (G6LCCfg.UseSharedTlb && (flush_state_q == IDLE) && !flush_i && !flush_vvma_i && !flush_gvma_i && shared_tlb_update_i.valid) begin
      for (int unsigned i = 0; i < SHARED_TLB_WAYS; i++) begin
        if (repl_way_oh_d[i]) begin
          shared_tag_valid_d[vpn_index][i] = 1'b1;
          tag_wr_en[i] = 1'b1;
          pte_wr_en[i] = 1'b1;
        end
      end
    end
  end
  //update_flush

  assign flush_asid_is0 = ~(|flush_asid_q);
  assign flush_vaddr_is0 = ~(|flush_vaddr_q);
  assign flush_last_set = (flush_idx_q == G6LCCfg.SharedTlbDepth - 1);
  assign flush_busy_o = (G6LCCfg.UseSharedTlb) && (flush_state_q != IDLE);

  assign shared_tag_wr.is_napot_64k = shared_tlb_update_i.is_napot_64k;  // Svnapot: Propagate the NAPOT flag from the update packet into the tag structure to be stored
  genvar z_gen;
  generate
    for (z_gen = 0; z_gen < G6LCCfg.PtLevels; z_gen++) begin : gen_shared_tag
      assign shared_tag_wr.vpn[z_gen] = vpn_to_store[((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(z_gen+1))-1:((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*z_gen)];
    end
    if (G6LCCfg.RVH) begin : gen_shared_tag_hyp
      //THIS UPDATES THE EXTRA BITS OF VPN IN SV39x4
      assign shared_tag_wr.vpn[G6LCCfg.PtLevels] = {
        {(((G6LCCfg.VpnLen / G6LCCfg.PtLevels) - (G6LCCfg.VpnLen % G6LCCfg.PtLevels))) {1'b0}},
        shared_tlb_update_i.vpn[G6LCCfg.VpnLen-1:G6LCCfg.VpnLen-(G6LCCfg.VpnLen%G6LCCfg.PtLevels)]
      };
    end
  endgenerate


  assign tag_wr_data = shared_tag_wr;

  // derive the set index from bits [4 +: clog2] of the (possibly masked) VPN
  assign vpn_index = shared_tlb_update_i.vpn[$clog2(G6LCCfg.SharedTlbDepth)-1:0];
  // write the new entry into that set
  assign tag_wr_addr = vpn_index;
  assign pte_wr_addr = vpn_index;

  assign pte_wr_data[0] = shared_tlb_update_i.content[G6LCCfg.XLEN-1:0];
  assign pte_wr_data[1] = shared_tlb_update_i.g_content[G6LCCfg.XLEN-1:0];



  assign way_valid = shared_tag_valid_q[shared_tlb_update_i.vpn[$clog2(
      G6LCCfg.SharedTlbDepth
  )-1:0]];
  assign repl_way = (all_ways_valid) ? rnd_way : inv_way;
  assign update_lfsr = shared_tlb_update_i.valid & all_ways_valid;
  assign repl_way_oh_d = (shared_tlb_update_i.valid) ? shared_tlb_way_bin2oh(repl_way) : '0;

  g6lc_hyp_lzc #(
      .WIDTH(SHARED_TLB_WAYS)
  ) i_lzc (
      .in_i   (~way_valid),
      .cnt_o  (inv_way),
      .empty_o(all_ways_valid)
  );

  g6lc_hyp_lfsr #(
      .LfsrWidth(8),
      .OutWidth ($clog2(SHARED_TLB_WAYS))
  ) i_lfsr (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (update_lfsr),
      .out_o (rnd_way)
  );

  ///////////////////////////////////////////////////////
  // memory arrays and regs
  ///////////////////////////////////////////////////////

  assign tag_req  = tag_wr_en | tag_rd_en;
  assign tag_we   = tag_wr_en;
  assign tag_addr = tag_wr_en ? tag_wr_addr : tag_rd_addr;

  assign pte_req  = pte_wr_en | pte_rd_en;
  assign pte_we   = pte_wr_en;
  assign pte_addr = pte_wr_en ? pte_wr_addr : pte_rd_addr;

  for (genvar i = 0; i < SHARED_TLB_WAYS; i++) begin : gen_sram
    if (G6LCCfg.UseSharedTlb) begin
      // Tag RAM
      sram #(
          .DATA_WIDTH($bits(shared_tag_t)),
          .NUM_WORDS (G6LCCfg.SharedTlbDepth)
      ) tag_sram (
          .clk_i  (clk_i),
          .rst_ni (rst_ni),
          .req_i  (tag_req[i]),
          .we_i   (tag_we[i]),
          .addr_i (tag_addr),
          .wuser_i('0),
          .wdata_i(tag_wr_data),
          .be_i   ('1),
          .ruser_o(),
          .rdata_o(tag_rd_data[i])
      );

      assign shared_tag_rd[i] = shared_tag_t'(tag_rd_data[i]);

      for (genvar a = 0; a < HYP_EXT + 1; a++) begin : g_content_sram
        // PTE RAM
        sram #(
            .DATA_WIDTH(G6LCCfg.XLEN),
            .NUM_WORDS (G6LCCfg.SharedTlbDepth)
        ) pte_sram (
            .clk_i  (clk_i),
            .rst_ni (rst_ni),
            .req_i  (pte_req[i]),
            .we_i   (pte_we[i]),
            .addr_i (pte_addr),
            .wuser_i('0),
            .wdata_i(pte_wr_data[a]),
            .be_i   ('1),
            .ruser_o(),
            .rdata_o(pte_rd_data[i][a])
        );
        assign pte[i][a] = pte_g6lc_t'(pte_rd_data[i][a]);
      end
    end else begin
      assign shared_tag_rd[i] = '0;
    end
  end

//pragma translate_off
  // r42-T item 19 equivalence: the staged ownership bits must equal the
  // FSM decode they replaced every cycle.
  int unsigned t2_stlb_flushsel_n = 0;
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      t2_stlb_flushsel_n <= t2_stlb_flushsel_n + 1;
      g6lc_t2_stlb_flushsel_eq: assert (
        (walk_own_q === (flush_state_q == FLUSH_READ)) &&
        (walk_blk_q === (flush_state_q != IDLE)))
        else $error("shared_tlb: equiv flushsel own=%b/%b blk=%b/%b",
                    walk_own_q, flush_state_q == FLUSH_READ,
                    walk_blk_q, flush_state_q != IDLE);
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_shared_tlb flushsel: checked=%0d", t2_stlb_flushsel_n);
  end
//pragma translate_on
endmodule

/* verilator lint_on WIDTH */
