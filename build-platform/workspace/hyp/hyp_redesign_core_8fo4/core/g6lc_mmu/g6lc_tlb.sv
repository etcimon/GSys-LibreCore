// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
// Copyright (c) 2018 ETH Zurich and University of Bologna.
// Copyright (c) 2021 Thales.
// Copyright (c) 2022 Bruno Sá and Zero-Day Labs.
// Copyright (c) 2024 PlanV Technology
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
// Modified by: Etienne Cimon (comb defaults; Verilator LATCH)
// Date: 26/02/2024
//
// Description: Translation Lookaside Buffer, parameterizable to Sv32 or Sv39,
//              or sv39x4 fully set-associative
//              This module is a merge of the Sv32 TLB developed by Sebastien
//              Jacq (Thales Research & Technology), the Sv39 TLB developed
//              by Florian Zaruba and David Schaffenrath and the Sv39x4 by Bruno Sá.

module g6lc_tlb
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter type pte_g6lc_t = logic,
    parameter type tlb_update_g6lc_t = logic,
    parameter int unsigned TLB_ENTRIES = 4,
    parameter int unsigned HYP_EXT = 0
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,  // Flush normal translations signal
    input logic flush_vvma_i,  // Flush VS stage signal
    input logic flush_gvma_i,  // Flush G stage signal
    input logic s_st_enbl_i,  // S-stage enabled
    input logic g_st_enbl_i,  // G-stage enabled
    input logic v_i,  // virtualization mode
    // Update TLB
    input tlb_update_g6lc_t update_i,
    // Lookup signals
    input logic lu_access_i,
    input logic [G6LCCfg.ASID_WIDTH-1:0] lu_asid_i,
    input logic [G6LCCfg.VMID_WIDTH-1:0] lu_vmid_i,
    // T6b-2b: requesting SMT hart. Lookups additionally require the stored hart
    // tag to match only when NrHarts > 1 && !SmtDrainedHandoff (drained SMT2
    // deliberately keeps sharing entries across harts with equal ASIDs).
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] lu_hart_i,
    input logic [G6LCCfg.VLEN-1:0] lu_vaddr_i,
    output logic [G6LCCfg.GPLEN-1:0] lu_gpaddr_o,
    output pte_g6lc_t lu_content_o,
    output pte_g6lc_t lu_g_content_o,
    input logic [G6LCCfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    input logic [G6LCCfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    input logic [G6LCCfg.VLEN-1:0] vaddr_to_be_flushed_i,
    input logic [G6LCCfg.GPLEN-1:0] gpaddr_to_be_flushed_i,
    output logic [G6LCCfg.PtLevels-2:0] lu_is_page_o,
    output logic lu_hit_o
);
  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_tlb status=proposal target=10-adjusted-FO4
  // svt-plan: cone page-size/VPN/ASID/VMID matching, hit reduction,
  // replacement update and refill/flush writes share translation metadata.
  // svt-plan: boundary bank-local match records -> hit/payload select;
  // prepare refill decode separately, preserving the current install arbitration.
  // svt-plan: carry lookup VA, ASID/VMID/hart, stage enables, access kind,
  // selected PTEs/page sizes and translation epoch through the response.
  // svt-plan: conflict flush/context change kills pending hits and refills;
  // keep NAPOT, superpage overlap, global entries and two-stage matching exact.
  // svt-plan: effect separates parallel comparisons from global select and
  // permission consumers; bounds each bank's compare fanout.
  // svt-plan: cost match/PTE registers and +1 lookup cycle; MMU/LSU must hold
  // the request and align permissions, exceptions, hit and translated address.
  // svt-plan: limit replacing !lu_hit_o with an update-address CAM changes
  // policy unless lookup/refill ownership is reconciled; it is not a free cut.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 41.8 adjusted FO4 on the
  // Nangate45 board): TLB: tag match and replacement state.
  // svt-pipe: require-contract
  // svt-pipe: protocol tlb valid=lu_access_i flush=flush_i
  // svt-pipe: no-cut on=tags_q
  // svt-pipe: cycle tlb q=tags_q d=lu_hit_o hold=lu_access_i steps=1

  // SV39 defines three levels of page tables
  localparam bit HART_TAG = (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;
  struct packed {
    logic [G6LCCfg.ASID_WIDTH-1:0] asid;
    logic [G6LCCfg.VMID_WIDTH-1:0] vmid;
    // T6b-2b: owning SMT hart. Compared only when HART_TAG (mixed residency);
    // otherwise written but ignored so drained/single-hart hits are unchanged.
    logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart;
    // VPN is:
    // [0] -> VPN0
    // [1] -> VPN1
    // [2] -> VPN2
    // [3] -> 2-bit supplementary PPN2 in case of GPA
    logic [G6LCCfg.PtLevels+HYP_EXT-1:0][(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1:0] vpn;
    logic [G6LCCfg.PtLevels-2:0][HYP_EXT:0] is_page;
    logic [HYP_EXT*2:0] v_st_enbl;  // v_i, g-stage enabled, s-stage enabled
    logic valid;
    logic is_napot_64k;  // Svnapot: Flag indicating a 64KiB NAPOT page
  } [TLB_ENTRIES-1:0]
      tags_q, tags_n;

  struct packed {
    pte_g6lc_t pte;   // S or VS-stage Page Table Entry structure
    pte_g6lc_t gpte;  // G-stage Page Table Entry structure
  } [TLB_ENTRIES-1:0]
      content_q, content_n;

  logic [TLB_ENTRIES-1:0][G6LCCfg.PtLevels-1:0] vpn_match;
  logic [TLB_ENTRIES-1:0][G6LCCfg.PtLevels-1:0] level_match;
  logic [TLB_ENTRIES-1:0][HYP_EXT:0][G6LCCfg.PtLevels-1:0] vaddr_vpn_match;
  logic [TLB_ENTRIES-1:0][HYP_EXT:0][G6LCCfg.PtLevels-1:0] vaddr_level_match;
  logic [TLB_ENTRIES-1:0] lu_hit;  // to replacement logic
  logic [TLB_ENTRIES-1:0] replace_en;  // replace the following entry, set by replacement strategy
  logic [TLB_ENTRIES-1:0] match_asid;
  logic [TLB_ENTRIES-1:0] match_vmid;
  logic [TLB_ENTRIES-1:0] match_hart;
  logic [TLB_ENTRIES-1:0][G6LCCfg.PtLevels-1:0] page_match;
  logic [TLB_ENTRIES-1:0][HYP_EXT:0][G6LCCfg.PtLevels-1:0] vpage_match;
  logic [TLB_ENTRIES-1:0][G6LCCfg.PtLevels-2:0] is_page_o;
  logic [TLB_ENTRIES-1:0] match_stage;
  pte_g6lc_t g_content;
  logic [TLB_ENTRIES-1:0][(G6LCCfg.GPPNW-1):0] gppn;
  logic [HYP_EXT*2:0] v_st_enbl;

  logic [TLB_ENTRIES-1:0] napot_tag_match;
  pte_g6lc_t patched_pte;
  logic [TLB_ENTRIES-1:0] vpn0_napot_match;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_tlb  region=5464  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: content_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to content_q
// order expect: plru_tree_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to plru_tree_q
// order expect: tags_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tags_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     content_q <= …; // sv-timing: cycle 1/1 on clk_i
//     plru_tree_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tags_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node19090 c=3.50 slack=0.00 */
//     /* node19091 c=3.50 slack=0.00 */
//     /* node19092 c=3.50 slack=0.00 */
//     /* node19093 c=3.50 slack=0.00 */
//     /* node19094 c=3.50 slack=0.00 */
//     /* node19095 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // svt-stage: begin T1
  // hyp8 (M1, TlbStages=3): T1 captures the lookup request (vaddr, ASID,
  // VMID, hart tag, stage enables, access); the VPN/page-size/ASID/VMID
  // compares and the hit/PTE select then run in the following cycle on the
  // registered request; T2 registers the response (hit, PTEs, page size,
  // gpaddr). The downstream PMP verdict is the T3 step inside g6lc_mmu.
  // Any flush/context change kills the in-flight lookup — a killed request
  // reports a miss (never a stale hit on a just-invalidated entry); a miss
  // is always safe, it only costs a walk. With TlbStages==1 the lookup is
  // the original single-cycle combinational path.
  localparam bit TLB_STAGED = (HypCfg.TlbStages >= 2);

  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] rq_hart;
  logic [G6LCCfg.VLEN-1:0] rq_vaddr;
  logic [G6LCCfg.ASID_WIDTH-1:0] rq_asid;
  logic [G6LCCfg.VMID_WIDTH-1:0] rq_vmid;
  logic [HYP_EXT*2:0] rq_st_enbl;
  logic rq_s_enbl, rq_g_enbl, rq_access;
  logic t1_vld_q;

  logic [G6LCCfg.GPLEN-1:0] rsp_gpaddr;
  pte_g6lc_t rsp_content, rsp_g_content;
  logic [G6LCCfg.PtLevels-2:0] rsp_is_page;
  logic rsp_hit;
  logic [TLB_ENTRIES-1:0] lu_hit_rsp;

  logic [HYP_EXT*2:0] v_st_enbl_live;
  assign v_st_enbl_live = (G6LCCfg.RVH) ? $bits(v_st_enbl)'({v_i, g_st_enbl_i, s_st_enbl_i}) : '1;

  logic any_tlb_flush;
  assign any_tlb_flush = flush_i | flush_vvma_i | flush_gvma_i;

  logic [G6LCCfg.VLEN-1:0] rq_vaddr_q;
  logic [G6LCCfg.ASID_WIDTH-1:0] rq_asid_q;
  logic [G6LCCfg.VMID_WIDTH-1:0] rq_vmid_q;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] rq_hart_q;
  logic [HYP_EXT*2:0] rq_st_enbl_q;
  logic rq_s_enbl_q, rq_g_enbl_q, rq_access_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_tlb_t1
    if (!rst_ni) begin
      t1_vld_q    <= 1'b0;
      rq_vaddr_q  <= '0;
      rq_asid_q   <= '0;
      rq_vmid_q   <= '0;
      rq_hart_q   <= '0;
      rq_st_enbl_q <= '0;
      rq_s_enbl_q <= 1'b0;
      rq_g_enbl_q <= 1'b0;
      rq_access_q <= 1'b0;
    end else begin
      // capture the request; a flush cycle never captures (miss, not a
      // stale hit)
      t1_vld_q    <= lu_access_i & ~any_tlb_flush;
      rq_vaddr_q  <= lu_vaddr_i;
      rq_asid_q   <= lu_asid_i;
      rq_vmid_q   <= lu_vmid_i;
      rq_hart_q   <= lu_hart_i;
      rq_st_enbl_q <= v_st_enbl_live;
      rq_s_enbl_q <= s_st_enbl_i;
      rq_g_enbl_q <= g_st_enbl_i;
      rq_access_q <= lu_access_i;
    end
  end

  assign rq_vaddr   = TLB_STAGED ? rq_vaddr_q  : lu_vaddr_i;
  assign rq_asid    = TLB_STAGED ? rq_asid_q   : lu_asid_i;
  assign rq_vmid    = TLB_STAGED ? rq_vmid_q   : lu_vmid_i;
  assign rq_hart    = TLB_STAGED ? rq_hart_q   : lu_hart_i;
  assign rq_st_enbl = TLB_STAGED ? rq_st_enbl_q : v_st_enbl_live;
  assign rq_s_enbl  = TLB_STAGED ? rq_s_enbl_q : s_st_enbl_i;
  assign rq_g_enbl  = TLB_STAGED ? rq_g_enbl_q : g_st_enbl_i;
  assign rq_access  = TLB_STAGED ? rq_access_q : lu_access_i;
  assign v_st_enbl  = rq_st_enbl;
  //-------------
  // Translation
  //-------------

  genvar i_gen, x_gen, z_gen, w_gen;
  generate
    for (i_gen = 0; i_gen < TLB_ENTRIES; i_gen++) begin
      for (x_gen = 0; x_gen < G6LCCfg.PtLevels; x_gen++) begin
        // WARNING: `x` goes in the order {0 = 4K, 1 = 2M, 2 = 1G}.

        // Identify page_match for all TLB Entries:
        // `page_match[i][x] == 1` if the entry `i` represents a page of (non-strictly) bigger length than
        // requested.
        // 4K is always a match
        // In case of H-mode, the length of a page in the TLB is the smallest of S-translation and
        // G-translation
        if (x_gen == 0) begin
          assign page_match[i_gen][x_gen] = 1;
        end else begin
          if (HYP_EXT == 0 || x_gen == (G6LCCfg.PtLevels - 1)) begin
            // No H-mode or Giga page. Then both condition must be true:
            // - G-stage translation is *not* enabled or G-entry is a matching page (bit 1)
            // - S-translation is *not* enabled or S-entry i is a matching page (bit 0)
            assign page_match[i_gen][x_gen] = &(tags_q[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][HYP_EXT:0] | (~v_st_enbl[HYP_EXT:0]));
          end else begin
            // Other cases: H-mode and mega page
            assign page_match[i_gen][x_gen] = (&v_st_enbl[HYP_EXT:0]) ?
                // If S-translation and G-translation are active, then either:
                // - S-translation matches and G-translation is Mega or Giga
                // - G-translation matches and S-translation is Mega or Giga
                ((tags_q[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][0]       && (tags_q[i_gen].is_page[G6LCCfg.PtLevels-2-x_gen][HYP_EXT] || tags_q[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][HYP_EXT]))
            ||   (tags_q[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][HYP_EXT] && (tags_q[i_gen].is_page[G6LCCfg.PtLevels-2-x_gen][0]       || tags_q[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][0])))
            : // Else, either S or G-level must match depending which is active
                ((tags_q[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][0] && rq_s_enbl) || (tags_q[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][HYP_EXT] && rq_g_enbl));
          end
        end

        // Identify if VPN matches at levels `x` for TLB entry `i`
        if (G6LCCfg.RVH && x_gen == (G6LCCfg.PtLevels - 1)) begin
          // H-mode: extend the check on last level (Giga page) to include the supplementary bits in
          // GPA (cfg.GPPNW = 29 bits in Sv39x4, compared to 27 bits in Sv39)
          // /!\ Only in cases G-translation is active and not S-translation
          assign vpn_match[i_gen][x_gen] = rq_vaddr[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(x_gen+1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*x_gen)] == tags_q[i_gen].vpn[x_gen]
              && (rq_s_enbl || rq_vaddr[12+G6LCCfg.GPPNW-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(x_gen+1))] == tags_q[i_gen].vpn[x_gen+HYP_EXT][(G6LCCfg.GPPNW%(G6LCCfg.VpnLen/G6LCCfg.PtLevels))-1:0]);

        end else begin
          // Standard match
          assign vpn_match[i_gen][x_gen] = rq_vaddr[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(x_gen+1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*x_gen)] == tags_q[i_gen].vpn[x_gen];
        end

        // Identify if there is a hit at level `x`: VPN and page length must match
        assign level_match[i_gen][x_gen] = &vpn_match[i_gen][G6LCCfg.PtLevels-1:x_gen] && page_match[i_gen][x_gen];

        // Identify `vpage_match` (matching page type) and deduce `vaddr_level` match (hit at all level on the virtual addr to be flushed
        // and matching page type).
        for (z_gen = 0; z_gen < HYP_EXT + 1; z_gen++) begin
          assign vpage_match      [i_gen][z_gen][x_gen] = x_gen == 0 ? 1 : tags_q[i_gen].is_page[G6LCCfg.PtLevels-1-x_gen][z_gen];
          assign vaddr_level_match[i_gen][z_gen][x_gen] = &vaddr_vpn_match[i_gen][z_gen][G6LCCfg.PtLevels-1:x_gen] && vpage_match[i_gen][z_gen][x_gen];
        end

        // Identify if virtual address vpn matches at all PT levels for all TLB entries
        assign vaddr_vpn_match[i_gen][0][x_gen] = vaddr_to_be_flushed_i[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(x_gen+1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*x_gen)] == tags_q[i_gen].vpn[x_gen];
      end

      // Identify if the input virtual address matches a stored NAPOT tag
      assign vpn0_napot_match[i_gen] = rq_vaddr[12 + (G6LCCfg.VpnLen / G6LCCfg.PtLevels) - 1 : 16] == tags_q[i_gen].vpn[0][(G6LCCfg.VpnLen / G6LCCfg.PtLevels)-1 : 4];
      assign napot_tag_match[i_gen] = (G6LCCfg.SvnapotEn && tags_q[i_gen].is_napot_64k) ? vpn_match[i_gen][2] && vpn_match[i_gen][1] && vpn0_napot_match[i_gen] : 1'b0;

      if (G6LCCfg.RVH) begin
        for (x_gen = 0; x_gen < G6LCCfg.PtLevels; x_gen++) begin
          // Identify if GPADDR matches the GPPN
          assign vaddr_vpn_match[i_gen][HYP_EXT][x_gen] =  gpaddr_to_be_flushed_i[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(x_gen+1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*x_gen)] ==
                                                                      gppn[i_gen][    (G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(x_gen+1)-1 :    (G6LCCfg.VpnLen/G6LCCfg.PtLevels)*x_gen];
        end
      end

      // Reorganise the output structure to match `is_page` tag order: [1G, 2M]
      for (w_gen = 0; w_gen < G6LCCfg.PtLevels - 1; w_gen++) begin
        assign is_page_o[i_gen][w_gen] = page_match[i_gen][G6LCCfg.PtLevels-1-w_gen];
      end
    end
  endgenerate

  always_comb begin : translation

    // default assignment — hyp8: comb drives rsp_*; the staged response
    // register below decides what reaches the ports.
  // svt-stage: end T1
  // svt-stage: begin T2
    // hyp8: this comb only computes the per-entry match vectors now; the
    // response gather below selects the last matching entry by one-hot.
    match_asid     = '{default: 0};
    match_vmid     = G6LCCfg.RVH ? '{default: 0} : '{default: 1};
    match_hart     = '{default: 0};
    match_stage    = '{default: 0};

    for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
      // First level match, this may be a giga page, check the ASID flags as well
      // if the entry is associated to a global address, don't match the ASID (ASID is don't care)
      match_asid[i] = ((rq_asid == tags_q[i].asid || content_q[i].pte.g) && rq_s_enbl) || !rq_s_enbl;

      if (G6LCCfg.RVH) begin
        match_vmid[i] = (rq_vmid == tags_q[i].vmid && rq_g_enbl) || !rq_g_enbl;
      end

      // T6b-2b: under mixed residency a TLB entry is private to its owning
      // hart; the compare constant-folds to 1 for single-hart and drained
      // SMT2 (which intentionally shares entries across harts).
`ifdef G6LC_MUT_TLB_NO_HART_TAG
      // Review-only mutation: the hart tag never discriminates.
      match_hart[i] = 1'b1;
`else
      match_hart[i] = HART_TAG ? (tags_q[i].hart == rq_hart) : 1'b1;
`endif

      // Check if that S-stage and G-stage modes corresponds, and that
      // and virtualization mode is on/off
      match_stage[i] = tags_q[i].v_st_enbl[HYP_EXT*2:0] == v_st_enbl[HYP_EXT*2:0];

    end
  end

  // hyp8: the emit's serial `if (match) rsp_* = ...` (last match wins) is
  // factored into per-entry response records computed in independent
  // cones, a downward-prefix one-hot picking the HIGHEST matching entry,
  // and balanced masked-OR gathers. Identical dataflow, log depth.
  typedef struct packed {
    logic                            hit;
    logic [G6LCCfg.PtLevels-2:0]     is_page;
    pte_g6lc_t                       content;
    pte_g6lc_t                       g_content;
    logic [G6LCCfg.GPLEN-1:0]        gpaddr;
  } tlb_rsp_t;

  tlb_rsp_t rsp_i [TLB_ENTRIES];
  logic [TLB_ENTRIES-1:0] tlb_hitv, tlb_hi1;

  for (genvar gi = 0; gi < TLB_ENTRIES; gi++) begin : gen_rsp_rec
    // hyp8: disjoint per-field assigns. The emit's sequential `gp`/`gc`
    // writes overlap (the giga patch covers the mega range), so the
    // structural model billed one serial patch chain. Each field is an
    // independent mux — identical dataflow, parallel depth.
    localparam int unsigned LPW = G6LCCfg.VpnLen / G6LCCfg.PtLevels;
    logic                     rsp_hit_i;
    logic [G6LCCfg.GPLEN-1:0] gp;
    pte_g6lc_t                gc, pc_;
    assign rsp_hit_i = tags_q[gi].valid && match_asid[gi] && match_vmid[gi] &&
                       match_hart[gi] && match_stage[gi] &&
                       (|level_match[gi] || napot_tag_match[gi]);
    if (G6LCCfg.RVH) begin : gen_gp
      // S-stage GPA fields: PTE PPN, overridden by the vaddr on mega/giga
      // pages (the ranges are disjoint here).
      assign gp[11:0] = rq_vaddr[11:0];
      assign gp[12+LPW-1:12] =
          (rq_s_enbl && !(tags_q[gi].is_page[1][0] || tags_q[gi].is_page[0][0]))
              ? content_q[gi].pte.ppn[LPW-1:0]
              : rq_vaddr[12+LPW-1:12];
      assign gp[12+2*LPW-1:12+LPW] =
          (rq_s_enbl && !tags_q[gi].is_page[0][0])
              ? content_q[gi].pte.ppn[2*LPW-1:LPW]
              : rq_vaddr[12+2*LPW-1:12+LPW];
      if (G6LCCfg.GPLEN > 12 + 2 * LPW) begin : gen_gp_hi
        assign gp[G6LCCfg.GPLEN-1:12+2*LPW] =
            rq_s_enbl ? content_q[gi].pte.ppn[G6LCCfg.GPPNW-1:2*LPW]
                      : rq_vaddr[G6LCCfg.GPLEN-1:12+2*LPW];
      end
      // G-stage PTE (the response record's last-writer form): gpte with
      // the low PPN fields taken from gp on mega/giga G-pages.
      // Disjoint per-field selects.
      always_comb begin : p_gc
        gc = content_q[gi].gpte;
        if (tags_q[gi].is_page[1][HYP_EXT] || tags_q[gi].is_page[0][HYP_EXT])
          gc.ppn[8:0] = gp[20:12];
        if (tags_q[gi].is_page[0][HYP_EXT])
          gc.ppn[17:0] = gp[29:12];
      end
    end else begin : gen_gp_norvh
      assign gp = '0;
      assign gc = '0;
    end
    // 64 KiB Svnapot page: the low PPN bits come from the vaddr.
    always_comb begin : p_pc
      pc_ = content_q[gi].pte;
      pc_.ppn[3:0] = (tags_q[gi].is_napot_64k && G6LCCfg.SvnapotEn)
                     ? rq_vaddr[15:12] : content_q[gi].pte.ppn[3:0];
    end
    always_comb begin : p_rsp_i
      rsp_i[gi].hit       = rsp_hit_i;
      rsp_i[gi].is_page   = rsp_hit_i ? is_page_o[gi] : '0;
      rsp_i[gi].content   = rsp_hit_i ? pc_ : '0;
      rsp_i[gi].g_content = '0;
      rsp_i[gi].gpaddr    = '0;
      if (rsp_hit_i && G6LCCfg.RVH) begin
        rsp_i[gi].gpaddr    = gp;
        rsp_i[gi].g_content =
            level_match[gi][G6LCCfg.PtLevels-1] ? content_q[gi].gpte : gc;
      end
    end
    assign tlb_hitv[gi] = rsp_i[gi].hit;
  end

  // highest-set one-hot (downward prefix OR) -- the emit's loop made the
  // last matching entry win.
  logic [TLB_ENTRIES-1:0] tlb_above;
  always_comb begin : p_tlb_above
    tlb_above = tlb_hitv >> 1;
    for (int unsigned l = 1; l < TLB_ENTRIES; l = l << 1)
      tlb_above = tlb_above | (tlb_above >> l);
  end
  assign tlb_hi1 = tlb_hitv & ~tlb_above;
  assign lu_hit  = tlb_hitv;
  assign rsp_hit = |tlb_hitv;

  // balanced masked-OR gathers over the per-entry records
  localparam int unsigned TRLV = (TLB_ENTRIES > 1) ? $clog2(TLB_ENTRIES) : 1;
  logic [TRLV:0][TLB_ENTRIES-1:0][$bits(tlb_rsp_t)-1:0] rsp_tree;
  for (genvar gi = 0; gi < TLB_ENTRIES; gi++) begin : gen_rsp_t0
    assign rsp_tree[0][gi] = {$bits(tlb_rsp_t){tlb_hi1[gi]}} & tlb_rsp_t'(rsp_i[gi]);
  end
  for (genvar l = 0; l < TRLV; l++) begin : gen_rsp_lvl
    for (genvar t = 0; t < TLB_ENTRIES; t++) begin : gen_rsp_or
      if (t < ((TLB_ENTRIES + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
        if ((2 * t + 1) < ((TLB_ENTRIES + (1 << l) - 1) >> l)) begin : gen_pair
          assign rsp_tree[l+1][t] = rsp_tree[l][2*t] | rsp_tree[l][2*t+1];
        end else begin : gen_odd
          assign rsp_tree[l+1][t] = rsp_tree[l][2*t];
        end
      end else begin : gen_pad
        assign rsp_tree[l+1][t] = '0;
      end
    end
  end
  tlb_rsp_t rsp_sel;
  assign rsp_sel       = tlb_rsp_t'(rsp_tree[TRLV][0]);
  assign rsp_is_page   = rsp_sel.is_page;
  assign rsp_content   = rsp_sel.content;
  assign rsp_g_content = rsp_sel.g_content;
  assign rsp_gpaddr    = rsp_sel.gpaddr;

  // -----------------------------------------------
  // hyp8 (M1): T2 response register — hit verdict plus the selected PTEs,
  // page size and translated gpaddr. A flush landing in the compare cycle
  // kills the pending response (reports a miss; H1/N1d: never a stale hit
  // on an entry invalidated the same edge).
  // -----------------------------------------------
  logic rsp_hit_q;
  logic [G6LCCfg.GPLEN-1:0] rsp_gpaddr_q;
  pte_g6lc_t rsp_content_q, rsp_g_content_q;
  logic [G6LCCfg.PtLevels-2:0] rsp_is_page_q;
  logic [TLB_ENTRIES-1:0] lu_hit_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_tlb_t2
    if (!rst_ni) begin
      rsp_hit_q       <= 1'b0;
      rsp_gpaddr_q    <= '0;
      rsp_content_q   <= '{default: 0};
      rsp_g_content_q <= '{default: 0};
      rsp_is_page_q   <= '0;
      lu_hit_q        <= '0;
    end else begin
      rsp_hit_q       <= rsp_hit & t1_vld_q & ~any_tlb_flush;
      lu_hit_q        <= lu_hit & {TLB_ENTRIES{t1_vld_q & ~any_tlb_flush}};
      rsp_gpaddr_q    <= rsp_gpaddr;
      rsp_content_q   <= rsp_content;
      rsp_g_content_q <= rsp_g_content;
      rsp_is_page_q   <= rsp_is_page;
    end
  end

  assign lu_hit_o       = TLB_STAGED ? rsp_hit_q       : rsp_hit;
  assign lu_gpaddr_o    = TLB_STAGED ? rsp_gpaddr_q    : rsp_gpaddr;
  assign lu_content_o   = TLB_STAGED ? rsp_content_q   : rsp_content;
  assign lu_g_content_o = TLB_STAGED ? rsp_g_content_q : rsp_g_content;
  assign lu_is_page_o   = TLB_STAGED ? rsp_is_page_q   : rsp_is_page;
  // per-entry hit vector feeding PLRU (staged verdict when staged)
  assign lu_hit_rsp     = TLB_STAGED ? lu_hit_q        : lu_hit;

  logic asid_to_be_flushed_is0;  // ASID from SFENCE.VMA (rs2) is 0, active high
  logic vaddr_to_be_flushed_is0;  // VADDR from SFENCE.VMA (rs1) is 0, active high
  logic vmid_to_be_flushed_is0;  // indicates that the VMID provided is 0, active high
  logic gpaddr_to_be_flushed_is0;  // indicates that the GPADDR provided is 0, active high
  logic flush_addr_napot_match;
  logic flush_addr_matches;
  logic [G6LCCfg.VpnLen-1:0] temp_stored_vpn;
  logic [G6LCCfg.VpnLen-1:0] flush_vpn_masked;
  logic [G6LCCfg.VpnLen-1:0] stored_vpn_masked;
  logic [G6LCCfg.VpnLen-1:0] vpn_to_store;

  // svt-stage: end T2
  assign asid_to_be_flushed_is0   = ~(|asid_to_be_flushed_i);
  assign vaddr_to_be_flushed_is0  = ~(|vaddr_to_be_flushed_i);
  assign vmid_to_be_flushed_is0   = ~(|vmid_to_be_flushed_i);
  assign gpaddr_to_be_flushed_is0 = ~(|gpaddr_to_be_flushed_i);

  // ------------------
  // Update and Flush
  // ------------------
  always_comb begin : update_flush
    tags_n                 = tags_q;
    content_n              = content_q;
    temp_stored_vpn        = '0;
    flush_vpn_masked       = '0;
    stored_vpn_masked      = '0;
    flush_addr_napot_match = 1'b0;
    flush_addr_matches     = 1'b0;
    vpn_to_store           = '0;

    for (int unsigned i = 0; i < TLB_ENTRIES; i++) begin
      gppn[i] = '0;


      if (G6LCCfg.RVH) begin

        if (tags_q[i].v_st_enbl[0]) begin
          gppn[i] = content_q[i].pte.ppn[(G6LCCfg.GPPNW-1):0];
          // Mega Page
          if (tags_q[i].is_page[1][0])
            gppn[i][G6LCCfg.VpnLen/G6LCCfg.PtLevels-1:0] = tags_q[i].vpn[0];
          // Giga Page
          if (tags_q[i].is_page[0][0])
            gppn[i][2*(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1:0] = {tags_q[i].vpn[1], tags_q[i].vpn[0]};
        end else begin
          gppn[i][G6LCCfg.VpnLen-1:0] = G6LCCfg.VpnLen'(tags_q[i].vpn);
        end
      end

      if (tags_q[i].is_napot_64k && G6LCCfg.SvnapotEn) begin
        temp_stored_vpn = G6LCCfg.VpnLen'({tags_q[i].vpn[2], tags_q[i].vpn[1], tags_q[i].vpn[0]});
        // Mask the lower 4 bits of the VPN (addr[15:12]) for comparison
        flush_vpn_masked = vaddr_to_be_flushed_i[G6LCCfg.VpnLen+11:12] & ~'hF;
        stored_vpn_masked = temp_stored_vpn & ~'hF;
        flush_addr_napot_match = (flush_vpn_masked == stored_vpn_masked);
      end else begin
        flush_addr_napot_match = 1'b0;
      end
      flush_addr_matches = |vaddr_level_match[i][0] || flush_addr_napot_match;

      if (flush_i) begin
        if (!tags_q[i].v_st_enbl[HYP_EXT*2] || HYP_EXT == 0) begin
          // invalidate logic
          // flush everything if ASID is 0 and vaddr is 0 ("SFENCE.VMA x0 x0" case)
          if (asid_to_be_flushed_is0 && vaddr_to_be_flushed_is0) tags_n[i].valid = 1'b0;
          // flush vaddr in all addressing space ("SFENCE.VMA vaddr x0" case), it should happen only for leaf pages
          else if (asid_to_be_flushed_is0 && (flush_addr_matches) && (~vaddr_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
          // the entry is flushed if it's not global and asid and vaddr both matches with the entry to be flushed ("SFENCE.VMA vaddr asid" case)
          else if ((!content_q[i].pte.g) && (flush_addr_matches) && (asid_to_be_flushed_i == tags_q[i].asid ) && (!vaddr_to_be_flushed_is0) && (!asid_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
          // the entry is flushed if it's not global, and the asid matches and vaddr is 0. ("SFENCE.VMA 0 asid" case)
          else if ((!content_q[i].pte.g) && (vaddr_to_be_flushed_is0) && (asid_to_be_flushed_i  == tags_q[i].asid ) && (!asid_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
        end
      end else if (flush_vvma_i && G6LCCfg.RVH) begin
        if (tags_q[i].v_st_enbl[HYP_EXT*2] && tags_q[i].v_st_enbl[0]) begin
          // invalidate logic
          // flush everything if current VMID matches and ASID is 0 and vaddr is 0 ("SFENCE.VMA/HFENCE.VVMA x0 x0" case)
          if (asid_to_be_flushed_is0 && vaddr_to_be_flushed_is0 && ((tags_q[i].v_st_enbl[HYP_EXT] && lu_vmid_i == tags_q[i].vmid) || !tags_q[i].v_st_enbl[HYP_EXT]))
            tags_n[i].valid = 1'b0;
          // flush vaddr in all addressing space if current VMID matches ("SFENCE.VMA/HFENCE.VVMA vaddr x0" case), it should happen only for leaf pages
          else if (asid_to_be_flushed_is0 && (flush_addr_matches) && (~vaddr_to_be_flushed_is0) && ((tags_q[i].v_st_enbl[HYP_EXT] && lu_vmid_i == tags_q[i].vmid) || !tags_q[i].v_st_enbl[HYP_EXT]))
            tags_n[i].valid = 1'b0;
          // the entry is flushed if it's not global and asid and vaddr and current VMID matches with the entry to be flushed ("SFENCE.VMA/HFENCE.VVMA vaddr asid" case)
          else if ((!content_q[i].pte.g) && (flush_addr_matches) && (asid_to_be_flushed_i  == tags_q[i].asid  && ((tags_q[i].v_st_enbl[HYP_EXT] && lu_vmid_i == tags_q[i].vmid) || !tags_q[i].v_st_enbl[HYP_EXT])) && (!vaddr_to_be_flushed_is0) && (!asid_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
          // the entry is flushed if it's not global, and the asid and the current VMID matches and vaddr is 0. ("SFENCE.VMA/HFENCE.VVMA 0 asid" case)
          else if ((!content_q[i].pte.g) && (vaddr_to_be_flushed_is0) && (asid_to_be_flushed_i  == tags_q[i].asid  && ((tags_q[i].v_st_enbl[HYP_EXT] && lu_vmid_i == tags_q[i].vmid) || !tags_q[i].v_st_enbl[HYP_EXT])) && (!asid_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
        end
      end else if (flush_gvma_i && G6LCCfg.RVH) begin
        if (tags_q[i].v_st_enbl[HYP_EXT]) begin
          // invalidate logic
          // flush everything if vmid is 0 and addr is 0 ("HFENCE.GVMA x0 x0" case)
          if (vmid_to_be_flushed_is0 && gpaddr_to_be_flushed_is0) tags_n[i].valid = 1'b0;
          // flush gpaddr in all addressing space ("HFENCE.GVMA gpaddr x0" case), it should happen only for leaf pages
          else if (vmid_to_be_flushed_is0 && (|vaddr_level_match[i][HYP_EXT]) && (~gpaddr_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
          // the entry vmid and gpaddr both match with the entry to be flushed ("HFENCE.GVMA gpaddr vmid" case)
          else if ((|vaddr_level_match[i][HYP_EXT]) && (vmid_to_be_flushed_i == tags_q[i].vmid) && (~gpaddr_to_be_flushed_is0) && (~vmid_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
          // the entry is flushed if the vmid matches and gpaddr is 0. ("HFENCE.GVMA 0 vmid" case)
          else if ((gpaddr_to_be_flushed_is0) && (vmid_to_be_flushed_i == tags_q[i].vmid) && (!vmid_to_be_flushed_is0))
            tags_n[i].valid = 1'b0;
        end
        // normal replacement
      end else if (update_i.valid & replace_en[i] & !lu_hit_o) begin
        vpn_to_store = update_i.vpn;
        if (update_i.is_napot_64k && G6LCCfg.SvnapotEn) begin
          // Svnapot: For a NAPOT entry, normalize the VPN by clearing the lower bits before storage
          // This ensures that any address within the 64KiB range will match the same stored tag
          vpn_to_store[3:0] = 4'b0;
        end
        //update tag
        tags_n[i] = {
          update_i.asid,
          update_i.vmid,
          update_i.hart,
          // Zero-extended VPN to fit the tag width
          ((G6LCCfg.PtLevels + HYP_EXT) * (G6LCCfg.VpnLen / G6LCCfg.PtLevels))'(vpn_to_store),
          update_i.is_page,
          update_i.v_st_enbl,
          1'b1,
          G6LCCfg.SvnapotEn ? update_i.is_napot_64k : 1'b0  // Svnapot: Propagate the NAPOT flag into the TLB entry
        };
        // update content as well
        content_n[i].pte = update_i.content;
        if (G6LCCfg.RVH) content_n[i].gpte = update_i.g_content;
      end
    end
  end

  // -----------------------------------------------
  // PLRU - Pseudo Least Recently Used Replacement
  // -----------------------------------------------
  logic [2*(TLB_ENTRIES-1)-1:0] plru_tree_q, plru_tree_n;
  always_comb begin : plru_replacement
    plru_tree_n = plru_tree_q;
    replace_en  = '0;
    // The PLRU-tree indexing:
    // lvl0        0
    //            / \
    //           /   \
    // lvl1     1     2
    //         / \   / \
    // lvl2   3   4 5   6
    //       / \ /\/\  /\
    //      ... ... ... ...
    // Just predefine which nodes will be set/cleared
    // E.g. for a TLB with 8 entries, the for-loop is semantically
    // equivalent to the following pseudo-code:
    // unique case (1'b1)
    // lu_hit[7]: plru_tree_n[0, 2, 6] = {1, 1, 1};
    // lu_hit[6]: plru_tree_n[0, 2, 6] = {1, 1, 0};
    // lu_hit[5]: plru_tree_n[0, 2, 5] = {1, 0, 1};
    // lu_hit[4]: plru_tree_n[0, 2, 5] = {1, 0, 0};
    // lu_hit[3]: plru_tree_n[0, 1, 4] = {0, 1, 1};
    // lu_hit[2]: plru_tree_n[0, 1, 4] = {0, 1, 0};
    // lu_hit[1]: plru_tree_n[0, 1, 3] = {0, 0, 1};
    // lu_hit[0]: plru_tree_n[0, 1, 3] = {0, 0, 0};
    // default: begin /* No hit */ end
    // endcase
    for (
        int unsigned i = 0; i < TLB_ENTRIES; i++
    ) begin
      automatic int unsigned idx_base, shift, new_index;
      idx_base  = 0;
      shift     = 0;
      new_index = 0;
      // we got a hit so update the pointer as it was least recently used —
      // hyp8: tracks the staged verdict and the staged access flag
      if (lu_hit_rsp[i] & rq_access) begin
        // Set the nodes to the values we would expect
        for (int unsigned lvl = 0; lvl < $clog2(TLB_ENTRIES); lvl++) begin
          idx_base = $unsigned((2 ** lvl) - 1);
          // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
          shift = $clog2(TLB_ENTRIES) - lvl;
          // to circumvent the 32 bit integer arithmetic assignment
          new_index = ~((i >> (shift - 1)) & 32'b1);
          plru_tree_n[idx_base+(i>>shift)] = new_index[0];
        end
      end
    end
    // Decode tree to write enable signals
    // Next for-loop basically creates the following logic for e.g. an 8 entry
    // TLB (note: pseudo-code obviously):
    // replace_en[7] = &plru_tree_q[ 6, 2, 0]; //plru_tree_q[0,2,6]=={1,1,1}
    // replace_en[6] = &plru_tree_q[~6, 2, 0]; //plru_tree_q[0,2,6]=={1,1,0}
    // replace_en[5] = &plru_tree_q[ 5,~2, 0]; //plru_tree_q[0,2,5]=={1,0,1}
    // replace_en[4] = &plru_tree_q[~5,~2, 0]; //plru_tree_q[0,2,5]=={1,0,0}
    // replace_en[3] = &plru_tree_q[ 4, 1,~0]; //plru_tree_q[0,1,4]=={0,1,1}
    // replace_en[2] = &plru_tree_q[~4, 1,~0]; //plru_tree_q[0,1,4]=={0,1,0}
    // replace_en[1] = &plru_tree_q[ 3,~1,~0]; //plru_tree_q[0,1,3]=={0,0,1}
    // replace_en[0] = &plru_tree_q[~3,~1,~0]; //plru_tree_q[0,1,3]=={0,0,0}
    // For each entry traverse the tree. If every tree-node matches,
    // the corresponding bit of the entry's index, this is
    // the next entry to replace.
    for (int unsigned i = 0; i < TLB_ENTRIES; i += 1) begin
      automatic logic en;
      automatic int unsigned idx_base, shift, new_index;
      en        = 1'b1;
      idx_base  = 0;
      shift     = 0;
      new_index = 0;
      for (int unsigned lvl = 0; lvl < $clog2(TLB_ENTRIES); lvl++) begin
        idx_base = $unsigned((2 ** lvl) - 1);
        // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
        shift = $clog2(TLB_ENTRIES) - lvl;

        // en &= plru_tree_q[idx_base + (i>>shift)] == ((i >> (shift-1)) & 1'b1);
        new_index = (i >> (shift - 1)) & 32'b1;
        if (new_index[0]) begin
          en &= plru_tree_q[idx_base+(i>>shift)];
        end else begin
          en &= ~plru_tree_q[idx_base+(i>>shift)];
        end
      end
      replace_en[i] = en;
    end
  end

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      tags_q      <= '{default: 0};
      content_q   <= '{default: 0};
      plru_tree_q <= '{default: 0};
    end else begin
      tags_q      <= tags_n;
      content_q   <= content_n;
      plru_tree_q <= plru_tree_n;
    end
  end
  //--------------
  // Sanity checks
  //--------------

  //pragma translate_off

  initial begin : p_assertions
    assert ((TLB_ENTRIES % 2 == 0) && (TLB_ENTRIES > 1))
    else begin
      $error("TLB size must be a multiple of 2 and greater than 1");
      $stop();
    end
    assert (G6LCCfg.ASID_WIDTH >= 1)
    else begin
      $error("ASID width must be at least 1");
      $stop();
    end
  end

  // Just for checking
  function int countSetBits(logic [TLB_ENTRIES-1:0] vector);
    automatic int count = 0;
    foreach (vector[idx]) begin
      count += int'(vector[idx]);
    end
    return count;
  endfunction

  assert property (@(posedge clk_i) (countSetBits(lu_hit) <= 1))
  else begin
    $error("More then one hit in TLB!");
    $stop();
  end
  assert property (@(posedge clk_i) (countSetBits(replace_en) <= 1))
  else begin
    $error("More then one TLB entry selected for next replace!");
    $stop();
  end

  //pragma translate_on

  // svt-stage: class T1 value
  // svt-stage: class T2 value
endmodule
