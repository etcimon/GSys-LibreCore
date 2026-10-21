// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
// Modified by: Etienne Cimon (2026) - A139 pipeline-design comments.
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
// Author: Angela Gonzalez, PlanV Technology
// Date: 26/02/2024
// Description: Hardware-PTW (Page-Table-Walker) for G6LC supporting sv32, sv39 and sv39x4.
//              This module is a merge of the PTW Sv39 developed by Florian Zaruba,
//              the PTW Sv32 developed by Sebastien Jacq and the PTW Sv39x4 by Bruno Sá.

/* verilator lint_off WIDTH */

module g6lc_ptw
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type pte_g6lc_t = logic,
    parameter type tlb_update_g6lc_t = logic,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter int unsigned HYP_EXT = 0
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,  // flush everything, we need to do this because
                          // actually everything we do is speculative at this stage
                          // e.g.: there could be a CSR instruction that changes everything
    output logic ptw_active_o,
    output logic walking_instr_o,  // set when walking for TLB
    output logic ptw_error_o,  // set when an error occurred
    output logic ptw_error_at_g_st_o,  // set when an error occurred at the G-Stage
    output logic ptw_err_at_g_int_st_o,  // set when an error occurred at the G-Stage during S-Stage translation
    output logic ptw_access_exception_o,  // set when a PMP access exception occurred
    input logic enable_translation_i,  // CSRs indicate to enable SV39 VS-Stage translation
    input logic enable_g_translation_i,  // CSRs indicate to enable SV39  G-Stage translation
    input logic en_ld_st_translation_i,  // enable virtual memory translation for load/stores
    input logic en_ld_st_g_translation_i,  // enable G-Stage translation for load/stores
    input logic v_i,  // current virtualization mode bit
    input logic ld_st_v_i,  // load/store virtualization mode bit
    input logic hlvx_inst_i,  // is a HLVX load/store instruction

    input logic lsu_is_store_i,  // this translation was triggered by a store
    // PTW memory interface
    input dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o,


    // to TLBs, update logic
    output tlb_update_g6lc_t shared_tlb_update_o,

    output logic [G6LCCfg.VLEN-1:0] update_vaddr_o,

    input logic [G6LCCfg.ASID_WIDTH-1:0] asid_i,
    input logic [G6LCCfg.ASID_WIDTH-1:0] vs_asid_i,
    input logic [G6LCCfg.VMID_WIDTH-1:0] vmid_i,

    // from TLBs
    // did we miss?
    input logic                    shared_tlb_access_i,
    input logic                    shared_tlb_hit_i,
    input logic [G6LCCfg.VLEN-1:0] shared_tlb_vaddr_i,

    input logic itlb_req_i,
    // T6b-2b: SMT hart owning this walk (fetch hart for ITLB walks, LSU
    // request hart for data walks), already context-selected by the caller.
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] req_hart_i,

    // from CSR file
    input logic [G6LCCfg.PPNW-1:0] satp_ppn_i,   // ppn from satp
    input logic [G6LCCfg.PPNW-1:0] vsatp_ppn_i,  // ppn from vsatp
    input logic [G6LCCfg.PPNW-1:0] hgatp_ppn_i,  // ppn from hgatp
    input logic                    mxr_i,
    input logic                    vmxr_i,
    input logic                    mbe_i,

    // Performance counters
    output logic shared_tlb_miss_o,

    // PMP
    input riscv::pmpcfg_t [avoid_neg(G6LCCfg.NrPMPEntries-1):0] pmpcfg_i,
    input logic [avoid_neg(G6LCCfg.NrPMPEntries-1):0][G6LCCfg.PLEN-3:0] pmpaddr_i,
    output logic [G6LCCfg.PLEN-1:0] bad_paddr_o,
    output logic [G6LCCfg.GPLEN-1:0] bad_gpaddr_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_ptw status=proposal target=10-adjusted-FO4
  // svt-plan: cone returned PTE decode/permission/page-size classification
  // feeds leaf response or next-level pointer and walk-state update.
  // svt-plan: boundary PTE validation -> leaf/next-level action;
  // retain raw PTE and walk context while classifying independently.
  // svt-plan: carry VA/GPA, level, S/G-stage, ASID/VMID/hart, access type,
  // root/privilege context, fault address and walk epoch with the PTE.
  // svt-plan: ownership fences/context changes cancel both classification
  // and queued refill; never emit a TLB update from an obsolete walk.
  // svt-plan: effect divides PTE checks from pointer/response construction;
  // arithmetic/address fields can be prepared in parallel with leaf checks.
  // svt-plan: cost one context stage and extra cycles per visited level;
  // issue only one next request per classified PTE and hold on cache refusal.
  // svt-plan: limit nested translation and NAPOT/superpage legality remain
  // part of the same verdict; added levels increase walk latency, not throughput.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 41.6 adjusted FO4 on the
  // Nangate45 board): page-table walker FSM.
  // svt-pipe: require-contract
  // svt-pipe: protocol ptw valid=itlb_req_i flush=flush_i
  // svt-pipe: no-cut on=data_rdata_q
  // svt-pipe: cycle ptw q=data_rdata_q d=ptw_active_o hold=itlb_req_i steps=1

  // input registers
  logic data_rvalid_q;
  logic [G6LCCfg.XLEN-1:0] data_rdata_q;

  pte_g6lc_t pte;
  // register to perform context switch between stages
  pte_g6lc_t gpte_q, gpte_d;

  //Field for SVNAPOT
  logic is_napot_64k;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ptw  region=5443  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: data_rdata_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to data_rdata_q
// order expect: data_rvalid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to data_rvalid_q
// order expect: global_mapping_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to global_mapping_q
// order expect: gpaddr_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to gpaddr_q
// order expect: gpte_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to gpte_q
// order expect: gptw_pptr_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to gptw_pptr_q
// order expect: is_instr_ptw_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to is_instr_ptw_q
// order expect: kill_req_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to kill_req_q
// order expect: ptw_lvl_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ptw_lvl_q
// order expect: ptw_pptr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ptw_pptr_q
// order expect: ptw_stage_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to ptw_stage_q
// order expect: state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to state_q
// order expect: tag_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tag_valid_q
// order expect: tlb_update_asid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tlb_update_asid_q
// order expect: tlb_update_hart_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tlb_update_hart_q
// order expect: tlb_update_vmid_q  ready_cycle=1  ready_fo4=0.000  OpenSTA: report_timing -from clk_i -to tlb_update_vmid_q
// order expect: vaddr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to vaddr_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     data_rdata_q <= …; // sv-timing: cycle 1/1 on clk_i
//     data_rvalid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     global_mapping_q <= …; // sv-timing: cycle 1/1 on clk_i
//     gpaddr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     gpte_q <= …; // sv-timing: cycle 1/1 on clk_i
//     gptw_pptr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     is_instr_ptw_q <= …; // sv-timing: cycle 1/1 on clk_i
//     kill_req_q <= …; // sv-timing: cycle 1/1 on clk_i
//     ptw_lvl_q <= …; // sv-timing: cycle 1/1 on clk_i
//     ptw_pptr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     ptw_stage_q <= …; // sv-timing: cycle 1/1 on clk_i
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tag_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tlb_update_asid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tlb_update_hart_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tlb_update_vmid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     vaddr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node18946 c=3.50 slack=0.00 */
//     /* node18947 c=3.50 slack=0.00 */
//     /* node18948 c=3.50 slack=0.00 */
//     /* node18949 c=3.50 slack=0.00 */
//     /* node18950 c=3.50 slack=0.00 */
//     /* node18951 c=3.50 slack=0.00 */
//     /* node18952 c=3.50 slack=0.00 */
//     /* node18953 c=3.50 slack=0.00 */
//     /* node18954 c=3.50 slack=0.00 */
//     /* node18955 c=3.50 slack=0.00 */
//     /* node18956 c=3.50 slack=0.00 */
//     /* node18957 c=3.50 slack=0.00 */
//     /* node18958 c=0.00 slack=3.50 */
//     /* node18959 c=0.00 slack=3.50 */
//     /* node18960 c=0.00 slack=3.50 */
//     /* node18961 c=0.00 slack=3.50 */
//     /* node18962 c=0.00 slack=3.50 */
//     /* node18963 c=3.50 slack=0.00 */
//     /* node18964 c=3.50 slack=0.00 */
//     /* node18965 c=3.50 slack=0.00 */
//     /* node18966 c=3.50 slack=0.00 */
//     /* node18967 c=3.50 slack=0.00 */
//     /* node18968 c=3.50 slack=0.00 */
//     /* node18969 c=3.50 slack=0.00 */
//     /* node18970 c=3.50 slack=0.00 */
//     /* node18971 c=3.50 slack=0.00 */
//     /* node18972 c=3.50 slack=0.00 */
//     /* node18973 c=3.50 slack=0.00 */
//     /* node18974 c=3.50 slack=0.00 */
//     /* node18975 c=0.00 slack=3.50 */
//     /* node18976 c=0.00 slack=3.50 */
//     /* node18977 c=0.00 slack=3.50 */
//     /* node18978 c=0.00 slack=3.50 */
//     /* node18979 c=0.00 slack=3.50 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign pte = pte_g6lc_t'(data_rdata_q);

  enum logic [2:0] {
    IDLE,
    WAIT_GRANT,
    PTE_LOOKUP,
    WAIT_RVALID,
    PROPAGATE_ERROR,
    PROPAGATE_ACCESS_ERROR,
    KILL_REQ,
    LATENCY
  }
      state_q, state_d;

  logic [G6LCCfg.PtLevels-2:0] misaligned_page;
  logic shared_tlb_update_valid;
  logic [HYP_EXT:0][G6LCCfg.PtLevels-2:0] ptw_lvl_n, ptw_lvl_q;

  // define 3 PTW stages to be used in sv39x4. sv32 and sv39 are always in S_STAGE
  // S_STAGE -> S/VS-stage normal translation controlled by the satp/vsatp CSRs
  // G_INTERMED_STAGE -> Converts the S/VS-stage non-leaf GPA pointers to HPA (controlled by hgatp)
  // G_FINAL_STAGE -> Converts the S/VS-stage final GPA to HPA (controlled by hgatp)
  enum logic [1:0] {
    S_STAGE,
    G_INTERMED_STAGE,
    G_FINAL_STAGE
  }
      ptw_stage_q, ptw_stage_d;

  // is this an instruction page table walk?
  logic is_instr_ptw_q, is_instr_ptw_n;
  logic global_mapping_q, global_mapping_n;
  // latched tag signal
  logic tag_valid_n, tag_valid_q;
  // latched kill signal
  logic kill_req_n, kill_req_q;
  // register the ASID
  logic [G6LCCfg.ASID_WIDTH-1:0] tlb_update_asid_q, tlb_update_asid_n;
  // register the VMID
  logic [G6LCCfg.VMID_WIDTH-1:0] tlb_update_vmid_q, tlb_update_vmid_n;
  // register the requesting SMT hart (T6b-2b)
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] tlb_update_hart_q, tlb_update_hart_n;
  // register the VPN we need to walk, SV39 defines a 39 bit virtual address
  logic [G6LCCfg.VLEN-1:0] vaddr_q, vaddr_n;
  logic [HYP_EXT*2:0][G6LCCfg.PtLevels-2:0][(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1:0] vaddr_lvl;
  // register the VPN we need to walk, SV39x4 defines a 41 bit virtual address for the G-Stage
  logic [G6LCCfg.GPLEN-1:0] gpaddr_q, gpaddr_n, gpaddr_base;
  logic [G6LCCfg.PtLevels-1:0][G6LCCfg.GPLEN-1:0] gpaddr;
  // 4 byte aligned physical pointer
  logic [G6LCCfg.PLEN-1:0] ptw_pptr_q, ptw_pptr_n;
  logic [G6LCCfg.PLEN-1:0] gptw_pptr_q, gptw_pptr_n;

  // Assignments
  assign update_vaddr_o = vaddr_q;

  assign ptw_active_o = (state_q != IDLE);
  assign walking_instr_o = is_instr_ptw_q;
  // directly output the correct physical address
  assign req_port_o.address_index = ptw_pptr_q[G6LCCfg.DCACHE_INDEX_WIDTH-1:0];
  assign req_port_o.address_tag   = ptw_pptr_q[G6LCCfg.DCACHE_INDEX_WIDTH+G6LCCfg.DCACHE_TAG_WIDTH-1:G6LCCfg.DCACHE_INDEX_WIDTH];
  // we are never going to write with the HPTW
  assign req_port_o.data_wdata = '0;
  // we only issue one single request at a time
  assign req_port_o.data_id = '0;
  // user field not used
  assign req_port_o.data_wuser = '0;
  // not a write
  assign req_port_o.cbo_op = g6lc_core_pkg::CBO_NONE;

  // -----------
  // TLB Update
  // -----------

  assign gpaddr_base = {pte.ppn[G6LCCfg.GPPNW-1:0], vaddr_q[11:0]};
  assign gpaddr[G6LCCfg.PtLevels-1] = gpaddr_base;

  genvar z, w;
  generate
    for (z = 0; z < G6LCCfg.PtLevels - 1; z++) begin

      // check if the ppn is correctly aligned:
      // 6. If i > 0 and pa.ppn[i − 1 : 0] != 0, this is a misaligned superpage; stop and raise a page-fault
      // exception.
      assign misaligned_page[z] = (ptw_lvl_q[0] == (z)) && (pte.ppn[(G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(G6LCCfg.PtLevels-1-z)-1:0] != '0);

      // record the vaddr corresponding to each level
      for (w = 0; w < HYP_EXT * 2 + 1; w++) begin
        assign vaddr_lvl[w][z] = w==0 ?      vaddr_q[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(G6LCCfg.PtLevels-z-1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(G6LCCfg.PtLevels-z-2))]:
                                 w==1 ?  gptw_pptr_q[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(G6LCCfg.PtLevels-z-1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(G6LCCfg.PtLevels-z-2))]:
                                            gpaddr_q[12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(G6LCCfg.PtLevels-z-1))-1:12+((G6LCCfg.VpnLen/G6LCCfg.PtLevels)*(G6LCCfg.PtLevels-z-2))];
      end

      if (G6LCCfg.RVH) begin
        assign gpaddr[z][G6LCCfg.VpnLen-(G6LCCfg.VpnLen/G6LCCfg.PtLevels):0] = (ptw_lvl_q[0] == z) ? vaddr_q[G6LCCfg.VpnLen-(G6LCCfg.VpnLen/G6LCCfg.PtLevels):0] : gpaddr_base[G6LCCfg.VpnLen-(G6LCCfg.VpnLen/G6LCCfg.PtLevels):0];
        assign gpaddr[z][G6LCCfg.VpnLen:G6LCCfg.VpnLen-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)+1] = (ptw_lvl_q[0] == 0) ? vaddr_q[G6LCCfg.VpnLen:G6LCCfg.VpnLen-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)+1] : gpaddr_base[G6LCCfg.VpnLen:G6LCCfg.VpnLen-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)+1];
        assign gpaddr[z][G6LCCfg.GPLEN-1:G6LCCfg.VpnLen+1] = gpaddr_base[G6LCCfg.GPLEN-1:G6LCCfg.VpnLen+1];
      end


    end
  endgenerate

  always_comb begin : tlb_update
    shared_tlb_update_o.valid = shared_tlb_update_valid;
    shared_tlb_update_o.is_napot_64k = is_napot_64k;

    // update the correct page table level
    for (int unsigned y = 0; y < HYP_EXT + 1; y++) begin
      for (int unsigned x = 0; x < G6LCCfg.PtLevels - 1; x++) begin
        if(((enable_g_translation_i && enable_translation_i) || (en_ld_st_g_translation_i && en_ld_st_translation_i)) && G6LCCfg.RVH) begin
          // VS + G-Translation
          shared_tlb_update_o.is_page[x][y] = (ptw_lvl_q[y==1?0 : 1] == x);
        end else if (enable_translation_i || en_ld_st_translation_i || !G6LCCfg.RVH) begin
          // non-V, S-Translation
          shared_tlb_update_o.is_page[x][y] = y == 0 ? (ptw_lvl_q[0] == x) : 1'b0;
        end else begin
          // G-Translation
          shared_tlb_update_o.is_page[x][y] = y != 0 ? (ptw_lvl_q[0] == x) : 1'b0;
        end
      end
    end

    // set the global mapping bit
    if ((enable_g_translation_i || en_ld_st_g_translation_i) && G6LCCfg.RVH) begin
      shared_tlb_update_o.content   = (gpte_q | (global_mapping_q << 5));
      shared_tlb_update_o.g_content = pte;
    end else begin
      shared_tlb_update_o.content   = (pte | (global_mapping_q << 5));
      shared_tlb_update_o.g_content = '0;
    end

    // output the correct ASIDs
    shared_tlb_update_o.asid = tlb_update_asid_q;
    shared_tlb_update_o.vmid = G6LCCfg.RVH ? tlb_update_vmid_q : '0;
    shared_tlb_update_o.hart = tlb_update_hart_q;
    shared_tlb_update_o.vpn = vaddr_q[12+G6LCCfg.VpnLen-1:12];

    bad_paddr_o = ptw_access_exception_o ? ptw_pptr_q : 'b0;
    if (G6LCCfg.RVH)
      bad_gpaddr_o[G6LCCfg.GPLEN-1:0] = ptw_error_at_g_st_o ? ((ptw_stage_q == G_INTERMED_STAGE) ? gptw_pptr_q[G6LCCfg.GPLEN-1:0] : gpaddr_q) : 'b0;
  end

  assign req_port_o.tag_valid = tag_valid_q;
  assign req_port_o.kill_req  = (state_q == KILL_REQ);

  logic allow_access;



  pmp #(
      .G6LCCfg(G6LCCfg)
  ) i_pmp_ptw (
      // hyp8: the PMP's request boundary is now registered internally;
      // ptw_pptr_q is itself a register and stays stable from the cycle
      // the request issues (WAIT_GRANT) through the data wait, so the
      // +1 verdict is fully overlapped — the walk needs no extra state
      // (the per-level PMP step rides the existing grant/lookup cycles).
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .addr_i       (ptw_pptr_q),
      // PTW access are always checked as if in S-Mode...
      .priv_lvl_i   (riscv::PRIV_LVL_S),
      // ...and they are always loads
      .access_type_i(riscv::ACCESS_READ),
      // Configuration
      .conf_addr_i  (pmpaddr_i),
      .conf_i       (pmpcfg_i),
      .allow_o      (allow_access)
  );


  assign req_port_o.data_be = G6LCCfg.IS_XLEN32 ? be_gen_32(
      req_port_o.address_index[1:0], req_port_o.data_size
  ) : '1;



  //-------------------
  // Page table walker
  //-------------------
  // A virtual address va is translated into a physical address pa as follows:
  // 1. Let a be sptbr.ppn × PAGESIZE, and let i = LEVELS-1. (For Sv39,
  //    PAGESIZE=2^12 and LEVELS=3.)
  // 2. Let pte be the value of the PTE at address a+va.vpn[i]×PTESIZE. (For
  //    Sv32, PTESIZE=4.)
  // 3. If pte.v = 0, or if pte.r = 0 and pte.w = 1, or if any bits or encodings
  //    that are reserved for future standard use are set within pte, stop and raise
  //    a page-fault exception corresponding to the original access type.
  // 4. Otherwise, the PTE is valid. If pte.r = 1 or pte.x = 1, go to step 5.
  //    Otherwise, this PTE is a pointer to the next level of the page table.
  //    Let i=i-1. If i < 0, stop and raise an access exception. Otherwise, let
  //    a = pte.ppn × PAGESIZE and go to step 2.
  // 5. A leaf PTE has been found. Determine if the requested memory access
  //    is allowed by the pte.r, pte.w, and pte.x bits. If not, stop and
  //    raise an access exception. Otherwise, the translation is successful.
  //    Set pte.a to 1, and, if the memory access is a store, set pte.d to 1.
  //    The translated physical address is given as follows:
  //      - pa.pgoff = va.pgoff.
  //      - If i > 0, then this is a superpage translation and
  //        pa.ppn[i-1:0] = va.vpn[i-1:0].
  //      - pa.ppn[LEVELS-1:i] = pte.ppn[LEVELS-1:i].
  //
  // hyp8 (M1): the plan's address-formation split is realised by the
  // structure this FSM already has — every level's pointer is a pure
  // concatenation {ppn slice, vpn slice, zero pad} formed in the state
  // that selects it (IDLE / PTE_LOOKUP), registered into ptw_pptr_q, and
  // issued on the following WAIT_GRANT cycle: shift/select and issue are
  // already one state per cycle, so no extra formation state is added.
  // The per-level PMP step (+1) is overlapped: i_pmp_ptw registers its
  // request boundary while ptw_pptr_q sits stable across WAIT_GRANT, and
  // allow_access is consumed no earlier than PTE_LOOKUP — the verdict is
  // always for the address whose data is being evaluated. Flush/kill is
  // unchanged: KILL_REQ still answers the killed request and the flush
  // drain below is untouched (lsu_exception_ptw_o ownership stays in
  // g6lc_mmu's T42 requester-match — the active walk owns the fault).
  always_comb begin : ptw
    automatic logic [G6LCCfg.PLEN-1:0] pptr;
    // default assignments
    // PTW memory interface
    tag_valid_n             = 1'b0;
    kill_req_n              = kill_req_q;
    req_port_o.data_req     = 1'b0;
    req_port_o.data_size    = 2'(G6LCCfg.PtLevels);
    req_port_o.data_we      = 1'b0;
    ptw_error_o             = 1'b0;
    ptw_error_at_g_st_o     = 1'b0;
    ptw_err_at_g_int_st_o   = 1'b0;
    ptw_access_exception_o  = 1'b0;
    shared_tlb_update_valid = 1'b0;
    is_napot_64k            = 1'b0;
    is_instr_ptw_n          = is_instr_ptw_q;
    ptw_lvl_n               = ptw_lvl_q;
    ptw_pptr_n              = ptw_pptr_q;
    state_d                 = state_q;
    gpte_d                  = '0;
    ptw_stage_d             = ptw_stage_q;
    global_mapping_n        = global_mapping_q;
    // input registers
    tlb_update_asid_n       = tlb_update_asid_q;
    tlb_update_hart_n       = tlb_update_hart_q;
    vaddr_n                 = vaddr_q;
    pptr                    = ptw_pptr_q;

    if (G6LCCfg.RVH) begin
      gpaddr_n    = gpaddr_q;
      gptw_pptr_n = gptw_pptr_q;
      gpte_d = gpte_q;
      tlb_update_vmid_n = tlb_update_vmid_q;
    end

    shared_tlb_miss_o = 1'b0;


    case (state_q)

      IDLE: begin
        // by default we start with the top-most page table
        ptw_lvl_n        = '0;
        global_mapping_n = 1'b0;
        is_instr_ptw_n   = 1'b0;


        if (G6LCCfg.RVH) begin
          gpte_d   = '0;
          gpaddr_n = '0;
        end


        // if we got an ITLB miss
        if (((enable_translation_i | enable_g_translation_i) || (en_ld_st_translation_i || en_ld_st_g_translation_i)  || !G6LCCfg.RVH) && shared_tlb_access_i && ~shared_tlb_hit_i) begin
          if (((enable_translation_i && enable_g_translation_i) || (en_ld_st_translation_i && en_ld_st_g_translation_i)) && G6LCCfg.RVH) begin
            ptw_stage_d = G_INTERMED_STAGE;
            pptr = {
              vsatp_ppn_i,
              shared_tlb_vaddr_i[G6LCCfg.SV-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
              (G6LCCfg.PtLevels)'(0)
            };
            gptw_pptr_n = pptr;
            ptw_pptr_n = {
              hgatp_ppn_i[G6LCCfg.PPNW-1:2],
              pptr[G6LCCfg.SV+HYP_EXT*2-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
              (G6LCCfg.PtLevels)'(0)
            };
          end else if ((((enable_translation_i | enable_g_translation_i) && !enable_translation_i) || ((en_ld_st_translation_i || en_ld_st_g_translation_i) && !en_ld_st_translation_i)) && G6LCCfg.RVH) begin
            ptw_stage_d = G_FINAL_STAGE;
            gpaddr_n = shared_tlb_vaddr_i[G6LCCfg.SV+HYP_EXT*2-1:0];
            ptw_pptr_n = {
              hgatp_ppn_i[G6LCCfg.PPNW-1:2],
              shared_tlb_vaddr_i[G6LCCfg.SV+HYP_EXT*2-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
              (G6LCCfg.PtLevels)'(0)
            };
          end else begin
            ptw_stage_d = S_STAGE;
            if ((v_i || ld_st_v_i) && G6LCCfg.RVH)
              ptw_pptr_n = {
                vsatp_ppn_i,
                shared_tlb_vaddr_i[G6LCCfg.SV-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
                (G6LCCfg.PtLevels)'(0)
              };
            else
              ptw_pptr_n = {
                satp_ppn_i,
                shared_tlb_vaddr_i[G6LCCfg.SV-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
                (G6LCCfg.PtLevels)'(0)
              };
          end

          is_instr_ptw_n    = itlb_req_i;
          vaddr_n           = shared_tlb_vaddr_i;
          state_d           = WAIT_GRANT;
          shared_tlb_miss_o = 1'b1;

          if (itlb_req_i) begin
            tlb_update_asid_n = v_i ? vs_asid_i : asid_i;
            if (G6LCCfg.RVH) tlb_update_vmid_n = vmid_i;
          end else begin
            tlb_update_asid_n = ld_st_v_i ? vs_asid_i : asid_i;
            if (G6LCCfg.RVH) tlb_update_vmid_n = vmid_i;
          end
          // Owner hart is latched once with the request and is stable for the
          // whole (possibly multi-stage) walk.
          tlb_update_hart_n = req_hart_i;
        end
      end

      WAIT_GRANT: begin
        // send a request out
        req_port_o.data_req = 1'b1;
        // wait for the WAIT_GRANT
        if (req_port_i.data_gnt) begin
          // send the tag valid signal one cycle later
          tag_valid_n = 1'b1;
          // if the request has been flushed, kill it one cycle later
          state_d = (kill_req_q || flush_i) ? KILL_REQ : PTE_LOOKUP;
        end
      end

      KILL_REQ: begin
        kill_req_n = 1'b0;
        // even when killed, the request sends a response
        state_d = WAIT_RVALID;
      end

      PTE_LOOKUP: begin
        // we wait for the valid signal
        if (data_rvalid_q) begin

          // check if the global mapping bit is set
          if (pte.g && (ptw_stage_q == S_STAGE || !G6LCCfg.RVH)) global_mapping_n = 1'b1;

          // -------------
          // Invalid PTE
          // -------------
          // If pte.v = 0, or if pte.r = 0 and pte.w = 1, or if pte.reserved !=0 in sv39 and sv39x4, stop and raise a page-fault exception.
          // Reserved-field check: bits 60:54 must be 0; PBMT[62:61] allowed only with SvpbmtEn
          // and menvcfg.PBMTE (PBMTE not threaded here — accept non-zero PBMT when SvpbmtEn);
          // N bit handled by SvnapotEn.
          if (!pte.v || (!pte.r && pte.w) ||
              (|pte.reserved && G6LCCfg.IS_XLEN64) ||
              (!G6LCCfg.SvpbmtEn && |pte.pbmt && G6LCCfg.IS_XLEN64) ||
              (G6LCCfg.SvpbmtEn && (pte.pbmt == 2'b11) && G6LCCfg.IS_XLEN64) ||
              (!G6LCCfg.SvnapotEn && pte.n) ||
              (G6LCCfg.SvnapotEn && !(pte.r || pte.x) && pte.n))
            state_d = PROPAGATE_ERROR;
          // -----------
          // Valid PTE
          // -----------
          else begin
            state_d = LATENCY;
            // if pte.r = 1 or pte.x = 1 it is a valid leaf PTE
            if (pte.r || pte.x) begin
              // A 64KiB NAPOT page is identified by the N-bit being set and PPN[3:0] encoding '1000'
              if (G6LCCfg.SvnapotEn && pte.n) begin
                // Svnapot: Check if the leaf PTE represents a 64KiB NAPOT page
                is_napot_64k = (pte.ppn[3:0] == 4'b1000) && (ptw_lvl_q[0] == 2);
                // Svnapot: Any other encoding with the N-bit set is a reserved format and must cause a page fault
                // Additionally, fault if N is set on a megapage or gigapage
                if (!is_napot_64k) begin
                  state_d = PROPAGATE_ERROR;
                end
              end

              if (G6LCCfg.RVH) begin
                case (ptw_stage_q)
                  S_STAGE: begin
                    if ((is_instr_ptw_q && enable_g_translation_i) || (!is_instr_ptw_q && en_ld_st_g_translation_i)) begin
                      state_d = WAIT_GRANT;
                      ptw_stage_d = G_FINAL_STAGE;
                      if (G6LCCfg.RVH) gpte_d = pte;
                      ptw_lvl_n[HYP_EXT] = ptw_lvl_q[0];
                      gpaddr_n = gpaddr[ptw_lvl_q[0]];
                      ptw_pptr_n = {
                        hgatp_ppn_i[G6LCCfg.PPNW-1:2],
                        gpaddr[ptw_lvl_q[0]][G6LCCfg.GPLEN-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
                        (G6LCCfg.PtLevels)'(0)
                      };
                      ptw_lvl_n[0] = '0;
                    end
                  end
                  G_INTERMED_STAGE: begin
                    state_d = WAIT_GRANT;
                    ptw_stage_d = S_STAGE;
                    ptw_lvl_n[0] = ptw_lvl_q[HYP_EXT];
                    pptr = {pte.ppn[G6LCCfg.GPPNW-1:0], gptw_pptr_q[11:0]};
                    if (ptw_lvl_q[0] == 1) pptr[20:0] = gptw_pptr_q[20:0];
                    if (ptw_lvl_q[0] == 0) pptr[29:0] = gptw_pptr_q[29:0];
                    ptw_pptr_n = pptr;
                  end
                  default: ;
                endcase
              end
              // Valid translation found (either 1G, 2M or 4K entry)
              if (is_instr_ptw_q) begin
                // ------------
                // Update ITLB
                // ------------
                // If page is not executable, we can directly raise an error. This
                // doesn't put a useless entry into the TLB. The same idea applies
                // to the access flag since we let the access flag be managed by SW.
                if ((!pte.x && (!G6LCCfg.RVH || ptw_stage_q != G_INTERMED_STAGE)) || !pte.a
                    || (G6LCCfg.RVH && ptw_stage_q == G_INTERMED_STAGE && !pte.r)) begin
                  state_d = PROPAGATE_ERROR;
                  if (G6LCCfg.RVH) ptw_stage_d = ptw_stage_q;
                end else if ((G6LCCfg.RVH && ((ptw_stage_q == G_FINAL_STAGE) || !enable_g_translation_i)) || !G6LCCfg.RVH)
                  shared_tlb_update_valid = 1'b1;

              end else begin
                // ------------
                // Update DTLB
                // ------------
                // Check if the access flag has been set, otherwise throw a page-fault
                // and let the software handle those bits.
                // If page is not readable (there are no write-only pages)
                // we can directly raise an error. This doesn't put a useless
                // entry into the TLB.
                if (
                  (pte.a && ((pte.r && !hlvx_inst_i) || (pte.x && (mxr_i || hlvx_inst_i || (ptw_stage_q == S_STAGE && vmxr_i && ld_st_v_i && G6LCCfg.RVH)))))
                    // Request is a store: perform some additional checks
                    // If the request was a store and the page is not write-able, raise an error
                    // the same applies if the dirty flag is not set
                    // g-intermediate nodes however never need write-permission
                    && (!lsu_is_store_i || (pte.w && pte.d) || (ptw_stage_q == G_INTERMED_STAGE && G6LCCfg.RVH))
                ) begin
                  if ((G6LCCfg.RVH && ((ptw_stage_q == G_FINAL_STAGE) || !en_ld_st_g_translation_i)) || !G6LCCfg.RVH)
                    shared_tlb_update_valid = 1'b1;
                end else begin
                  state_d = PROPAGATE_ERROR;
                  if (G6LCCfg.RVH) ptw_stage_d = ptw_stage_q;
                end
              end

              // if there is a misaligned page, propagate error
              if (|misaligned_page) begin
                state_d = PROPAGATE_ERROR;
                if (G6LCCfg.RVH) ptw_stage_d = ptw_stage_q;
                shared_tlb_update_valid = 1'b0;
              end

              // check if 63:41 are all zeros
              if (G6LCCfg.RVH) begin
                if (((v_i && is_instr_ptw_q) || (ld_st_v_i && !is_instr_ptw_q)) && ptw_stage_q == S_STAGE && !((|pte.ppn[G6LCCfg.PPNW-1:G6LCCfg.GPPNW]) == 1'b0)) begin
                  state_d = PROPAGATE_ERROR;
                  ptw_stage_d = G_FINAL_STAGE;
                end
              end
              // this is a pointer to the next TLB level
            end else begin
              // pointer to next level of page table

              if (ptw_lvl_q[0] == G6LCCfg.PtLevels - 1) begin
                // Should already be the last level page table => Error
                ptw_lvl_n[0] = ptw_lvl_q[0];
                state_d = PROPAGATE_ERROR;
                if (G6LCCfg.RVH) ptw_stage_d = ptw_stage_q;


              end else begin
                ptw_lvl_n[0] = ptw_lvl_q[0] + 1'b1;
                state_d = WAIT_GRANT;

                if (G6LCCfg.RVH) begin
                  case (ptw_stage_q)
                    S_STAGE: begin
                      if (G6LCCfg.RVH && ((is_instr_ptw_q && enable_g_translation_i) || (!is_instr_ptw_q && en_ld_st_g_translation_i))) begin
                        ptw_stage_d = G_INTERMED_STAGE;
                        ptw_lvl_n[HYP_EXT] = ptw_lvl_q[0] + 1;
                        pptr = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
                        gptw_pptr_n = pptr;
                        ptw_pptr_n = {
                          hgatp_ppn_i[G6LCCfg.PPNW-1:2],
                          pptr[G6LCCfg.SV+HYP_EXT*2-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
                          (G6LCCfg.PtLevels)'(0)
                        };
                        ptw_lvl_n[0] = '0;
                      end else begin
                        ptw_pptr_n = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
                      end
                    end
                    G_INTERMED_STAGE: begin
                      ptw_pptr_n = {
                        pte.ppn, vaddr_lvl[HYP_EXT][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)
                      };
                    end
                    G_FINAL_STAGE: begin
                      ptw_pptr_n = {
                        pte.ppn, vaddr_lvl[HYP_EXT*2][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)
                      };
                    end
                    default: ;
                  endcase
                end else ptw_pptr_n = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};

                if (G6LCCfg.RVH && (pte.a || pte.d || pte.u)) begin
                  state_d = PROPAGATE_ERROR;
                  ptw_stage_d = ptw_stage_q;
                end

              end

              // check if 63:41 are all zeros
              if (G6LCCfg.RVH) begin
                if (((v_i && is_instr_ptw_q) || (ld_st_v_i && !is_instr_ptw_q)) && ptw_stage_q == S_STAGE && !((|pte.ppn[G6LCCfg.PPNW-1:G6LCCfg.GPPNW]) == 1'b0)) begin
                  state_d = PROPAGATE_ERROR;
                  ptw_stage_d = ptw_stage_q;
                end
              end
            end
          end

          // check if this access was actually allowed from a PMP perspective
          if (!allow_access) begin
            shared_tlb_update_valid = 1'b0;
            // we have to return the failed address in bad_addr
            ptw_pptr_n = ptw_pptr_q;
            if (G6LCCfg.RVH) ptw_stage_d = ptw_stage_q;
            state_d = PROPAGATE_ACCESS_ERROR;
          end
        end
        // we've got a data WAIT_GRANT so tell the cache that the tag is valid
      end
      // Propagate error to MMU/LSU
      PROPAGATE_ERROR: begin
        state_d = LATENCY;
        ptw_error_o = 1'b1;
        if (G6LCCfg.RVH) begin
          ptw_error_at_g_st_o   = (ptw_stage_q != S_STAGE) ? 1'b1 : 1'b0;
          ptw_err_at_g_int_st_o = (ptw_stage_q == G_INTERMED_STAGE) ? 1'b1 : 1'b0;
        end
      end
      PROPAGATE_ACCESS_ERROR: begin
        state_d = LATENCY;
        ptw_access_exception_o = 1'b1;
      end
      // wait for the rvalid before going back to IDLE
      WAIT_RVALID: begin
        if (data_rvalid_q) state_d = IDLE;
      end
      LATENCY: begin
        state_d = IDLE;
      end
      default: begin
        state_d = IDLE;
      end
    endcase

    // -------
    // Flush
    // -------
    // should we have flushed before we got an rvalid, wait for it until going back to IDLE
    if (flush_i) begin
      // on a flush check whether we are
      // 1. in the PTE Lookup check whether we still need to wait for an rvalid
      // 2. waiting for a grant, if so: wait for it
      // if not, go back to idle
      if ((state_q inside {PTE_LOOKUP, WAIT_RVALID}) && !data_rvalid_q) state_d = WAIT_RVALID;
      else if (state_q != WAIT_GRANT) state_d = LATENCY;

      kill_req_n = (state_q == WAIT_GRANT);
    end
  end

  // Big Endian Capability Additions
  // req_port_i.data_rdata is the data coming into the Page Table Walker from Data Memory. If mbe=1 meaning the processor is in Big Endian data mode, then we need to reverse the byte order to correctly view this data.
  // Otherwise, this page table walker would not be able to understand a page table stored in Big Endian byte order.
  logic [G6LCCfg.XLEN-1:0] endian_data;
  logic [G6LCCfg.XLEN-1:0] byteSwapped_data;
  assign byteSwapped_data = {<<8{req_port_i.data_rdata}};
  assign endian_data = mbe_i ? byteSwapped_data : req_port_i.data_rdata;

  //pragma translate_off
  // T6b-4 debug: dump the walk context whenever a PTE lookup propagates an
  // error — identifies wrong-base/wrong-index/stale-response corruption.
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q != PROPAGATE_ERROR && state_d == PROPAGATE_ERROR) begin
      $display("[ptw-err] t=%0t vaddr=%h lvl=%0d pptr=%h pte=%h (v=%b r=%b w=%b x=%b a=%b d=%b g=%b u=%b) instr=%b hart=%0d req_hart=%0d satp_ppn=%h state=%0d rdata=%h",
               $time, vaddr_q, ptw_lvl_q[0], ptw_pptr_q, data_rdata_q,
               pte.v, pte.r, pte.w, pte.x, pte.a, pte.d, pte.g, pte.u,
               is_instr_ptw_q, tlb_update_hart_q, req_hart_i, satp_ppn_i,
               state_q, endian_data);
    end
  end
  //pragma translate_on

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q           <= IDLE;
      is_instr_ptw_q    <= 1'b0;
      ptw_lvl_q         <= '0;
      tag_valid_q       <= 1'b0;
      kill_req_q        <= 1'b0;
      tlb_update_asid_q <= '0;
      tlb_update_hart_q <= '0;
      vaddr_q           <= '0;
      ptw_pptr_q        <= '0;
      global_mapping_q  <= 1'b0;
      data_rdata_q      <= '0;
      data_rvalid_q     <= 1'b0;
      if (G6LCCfg.RVH) begin
        gpaddr_q          <= '0;
        gptw_pptr_q       <= '0;
        ptw_stage_q       <= S_STAGE;
        gpte_q            <= '0;
        tlb_update_vmid_q <= '0;
      end
    end else begin
      state_q           <= state_d;
      ptw_pptr_q        <= ptw_pptr_n;
      is_instr_ptw_q    <= is_instr_ptw_n;
      ptw_lvl_q         <= ptw_lvl_n;
      tag_valid_q       <= tag_valid_n;
      kill_req_q        <= kill_req_n;
      tlb_update_asid_q <= tlb_update_asid_n;
      tlb_update_hart_q <= tlb_update_hart_n;
      vaddr_q           <= vaddr_n;
      global_mapping_q  <= global_mapping_n;
      //data_rdata_q      <= req_port_i.data_rdata;
      data_rdata_q      <= endian_data;
      data_rvalid_q     <= req_port_i.data_rvalid;

      if (G6LCCfg.RVH) begin
        gpaddr_q          <= gpaddr_n;
        gptw_pptr_q       <= gptw_pptr_n;
        ptw_stage_q       <= ptw_stage_d;
        gpte_q            <= gpte_d;
        tlb_update_vmid_q <= tlb_update_vmid_n;
      end
    end
  end

endmodule
/* verilator lint_on WIDTH */
