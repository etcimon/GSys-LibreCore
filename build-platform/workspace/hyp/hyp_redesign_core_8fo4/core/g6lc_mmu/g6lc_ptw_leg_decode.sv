// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_ptw_leg_decode - the single-state (PtwDecodeStage=0) PTE_LOOKUP
// verdict, extracted from g6lc_ptw's `ptw` FSM so the active
// PtwDecodeStage=1 profile elaborates only its own decode (r48). The
// parent instantiates this module only under `if (!PDEC)` and merges the
// leg_* next-state outputs on the PTE_LOOKUP rdata cycle; outside that
// cycle the outputs are unread, so the block computes unconditionally.
// The body is the pre-r48 FSM arm verbatim with next-state writes
// redirected to the leg_* ports; the [3:0]/[1:0] encodings mirror the
// parent's anonymous enums (same member order).
module g6lc_ptw_leg_decode
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type pte_g6lc_t = logic,
    parameter int unsigned HYP_EXT = 0
) (
    input  pte_g6lc_t   pte,
    input  logic [1:0]  ptw_stage_q,
    input  logic [HYP_EXT:0][G6LCCfg.PtLevels-2:0] ptw_lvl_q,
    input  logic [HYP_EXT*2:0][G6LCCfg.PtLevels-2:0][(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1:0] vaddr_lvl,
    input  logic [G6LCCfg.PtLevels-1:0][G6LCCfg.GPLEN-1:0] gpaddr,
    input  logic [G6LCCfg.PLEN-1:0] gptw_pptr_q,
    input  logic [G6LCCfg.PLEN-1:0] ptw_pptr_q,
    input  logic [G6LCCfg.PPNW-1:0] hgatp_ppn_i,
    input  logic        is_instr_ptw_q,
    input  logic        enable_g_translation_i,
    input  logic        en_ld_st_g_translation_i,
    input  logic [G6LCCfg.PtLevels-2:0] misaligned_page,
    input  logic        allow_access,
    input  logic        v_i,
    input  logic        ld_st_v_i,
    input  logic        lsu_is_store_i,
    input  logic        hlvx_inst_i,
    input  logic        mxr_i,
    input  logic        vmxr_i,
    // hold-context inputs: the FSM's next-state defaults this arm
    // leaves untouched must still be replayed on the merged outputs.
    input  logic [3:0]  state_q,
    input  logic        global_mapping_q,
    input  logic [G6LCCfg.GPLEN-1:0] gpaddr_q,
    input  pte_g6lc_t   gpte_q,
    output logic [3:0]  leg_state_d,
    output logic        leg_global_mapping_n,
    output logic        leg_is_napot_64k,
    output logic [1:0]  leg_ptw_stage_d,
    output logic [HYP_EXT:0][G6LCCfg.PtLevels-2:0] leg_ptw_lvl_n,
    output logic [G6LCCfg.PLEN-1:0] leg_ptw_pptr_n,
    output logic [G6LCCfg.PLEN-1:0] leg_gptw_pptr_n,
    output logic [G6LCCfg.GPLEN-1:0] leg_gpaddr_n,
    output pte_g6lc_t   leg_gpte_d,
    output logic        leg_tlb_update_valid
);

  // FSM encodings, same member order as g6lc_ptw's anonymous enums.
  localparam logic [3:0] WAIT_GRANT = 1, PROPAGATE_ERROR = 4,
      PROPAGATE_ACCESS_ERROR = 5, LATENCY = 7;
  localparam logic [1:0] S_STAGE = 0, G_INTERMED_STAGE = 1, G_FINAL_STAGE = 2;

  always_comb begin : legacy_dec
    automatic logic [G6LCCfg.PLEN-1:0] pptr;
    leg_state_d          = state_q;
    leg_global_mapping_n = global_mapping_q;
    leg_is_napot_64k     = 1'b0;
    leg_ptw_stage_d      = ptw_stage_q;
    leg_ptw_lvl_n        = ptw_lvl_q;
    leg_ptw_pptr_n       = ptw_pptr_q;
    leg_gptw_pptr_n      = gptw_pptr_q;
    leg_gpaddr_n         = gpaddr_q;
    leg_gpte_d           = '0;
    if (G6LCCfg.RVH) leg_gpte_d = gpte_q;
    leg_tlb_update_valid = 1'b0;
    pptr                 = ptw_pptr_q;

              // check if the global mapping bit is set
              if (pte.g && (ptw_stage_q == S_STAGE || !G6LCCfg.RVH)) leg_global_mapping_n = 1'b1;
    
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
                leg_state_d = PROPAGATE_ERROR;
              // -----------
              // Valid PTE
              // -----------
              else begin
                leg_state_d = LATENCY;
                // if pte.r = 1 or pte.x = 1 it is a valid leaf PTE
                if (pte.r || pte.x) begin
                  // A 64KiB NAPOT page is identified by the N-bit being set and PPN[3:0] encoding '1000'
                  if (G6LCCfg.SvnapotEn && pte.n) begin
                    // Svnapot: Check if the leaf PTE represents a 64KiB NAPOT page
                    leg_is_napot_64k = (pte.ppn[3:0] == 4'b1000) && (ptw_lvl_q[0] == 2);
                    // Svnapot: Any other encoding with the N-bit set is a reserved format and must cause a page fault
                    // Additionally, fault if N is set on a megapage or gigapage
                    if (!leg_is_napot_64k) begin
                      leg_state_d = PROPAGATE_ERROR;
                    end
                  end
    
                  if (G6LCCfg.RVH) begin
                    case (ptw_stage_q)
                      S_STAGE: begin
                        if ((is_instr_ptw_q && enable_g_translation_i) || (!is_instr_ptw_q && en_ld_st_g_translation_i)) begin
                          leg_state_d = WAIT_GRANT;
                          leg_ptw_stage_d = G_FINAL_STAGE;
                          if (G6LCCfg.RVH) leg_gpte_d = pte;
                          leg_ptw_lvl_n[HYP_EXT] = ptw_lvl_q[0];
                          leg_gpaddr_n = gpaddr[ptw_lvl_q[0]];
                          leg_ptw_pptr_n = {
                            hgatp_ppn_i[G6LCCfg.PPNW-1:2],
                            gpaddr[ptw_lvl_q[0]][G6LCCfg.GPLEN-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
                            (G6LCCfg.PtLevels)'(0)
                          };
                          leg_ptw_lvl_n[0] = '0;
                        end
                      end
                      G_INTERMED_STAGE: begin
                        leg_state_d = WAIT_GRANT;
                        leg_ptw_stage_d = S_STAGE;
                        leg_ptw_lvl_n[0] = ptw_lvl_q[HYP_EXT];
                        pptr = {pte.ppn[G6LCCfg.GPPNW-1:0], gptw_pptr_q[11:0]};
                        if (ptw_lvl_q[0] == 1) pptr[20:0] = gptw_pptr_q[20:0];
                        if (ptw_lvl_q[0] == 0) pptr[29:0] = gptw_pptr_q[29:0];
                        leg_ptw_pptr_n = pptr;
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
                      leg_state_d = PROPAGATE_ERROR;
                      if (G6LCCfg.RVH) leg_ptw_stage_d = ptw_stage_q;
                    end else if ((G6LCCfg.RVH && ((ptw_stage_q == G_FINAL_STAGE) || !enable_g_translation_i)) || !G6LCCfg.RVH)
                      leg_tlb_update_valid = 1'b1;
    
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
                        leg_tlb_update_valid = 1'b1;
                    end else begin
                      leg_state_d = PROPAGATE_ERROR;
                      if (G6LCCfg.RVH) leg_ptw_stage_d = ptw_stage_q;
                    end
                  end
    
                  // if there is a misaligned page, propagate error
                  if (|misaligned_page) begin
                    leg_state_d = PROPAGATE_ERROR;
                    if (G6LCCfg.RVH) leg_ptw_stage_d = ptw_stage_q;
                    leg_tlb_update_valid = 1'b0;
                  end
    
                  // check if 63:41 are all zeros
                  if (G6LCCfg.RVH) begin
                    if (((v_i && is_instr_ptw_q) || (ld_st_v_i && !is_instr_ptw_q)) && ptw_stage_q == S_STAGE && !((|pte.ppn[G6LCCfg.PPNW-1:G6LCCfg.GPPNW]) == 1'b0)) begin
                      leg_state_d = PROPAGATE_ERROR;
                      leg_ptw_stage_d = G_FINAL_STAGE;
                    end
                  end
                  // this is a pointer to the next TLB level
                end else begin
                  // pointer to next level of page table
    
                  if (ptw_lvl_q[0] == G6LCCfg.PtLevels - 1) begin
                    // Should already be the last level page table => Error
                    leg_ptw_lvl_n[0] = ptw_lvl_q[0];
                    leg_state_d = PROPAGATE_ERROR;
                    if (G6LCCfg.RVH) leg_ptw_stage_d = ptw_stage_q;
    
    
                  end else begin
                    leg_ptw_lvl_n[0] = ptw_lvl_q[0] + 1'b1;
                    leg_state_d = WAIT_GRANT;
    
                    if (G6LCCfg.RVH) begin
                      case (ptw_stage_q)
                        S_STAGE: begin
                          if (G6LCCfg.RVH && ((is_instr_ptw_q && enable_g_translation_i) || (!is_instr_ptw_q && en_ld_st_g_translation_i))) begin
                            leg_ptw_stage_d = G_INTERMED_STAGE;
                            leg_ptw_lvl_n[HYP_EXT] = ptw_lvl_q[0] + 1;
                            pptr = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
                            leg_gptw_pptr_n = pptr;
                            leg_ptw_pptr_n = {
                              hgatp_ppn_i[G6LCCfg.PPNW-1:2],
                              pptr[G6LCCfg.SV+HYP_EXT*2-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
                              (G6LCCfg.PtLevels)'(0)
                            };
                            leg_ptw_lvl_n[0] = '0;
                          end else begin
                            leg_ptw_pptr_n = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
                          end
                        end
                        G_INTERMED_STAGE: begin
                          leg_ptw_pptr_n = {
                            pte.ppn, vaddr_lvl[HYP_EXT][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)
                          };
                        end
                        G_FINAL_STAGE: begin
                          leg_ptw_pptr_n = {
                            pte.ppn, vaddr_lvl[HYP_EXT*2][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)
                          };
                        end
                        default: ;
                      endcase
                    end else leg_ptw_pptr_n = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
    
                    if (G6LCCfg.RVH && (pte.a || pte.d || pte.u)) begin
                      leg_state_d = PROPAGATE_ERROR;
                      leg_ptw_stage_d = ptw_stage_q;
                    end
    
                  end
    
                  // check if 63:41 are all zeros
                  if (G6LCCfg.RVH) begin
                    if (((v_i && is_instr_ptw_q) || (ld_st_v_i && !is_instr_ptw_q)) && ptw_stage_q == S_STAGE && !((|pte.ppn[G6LCCfg.PPNW-1:G6LCCfg.GPPNW]) == 1'b0)) begin
                      leg_state_d = PROPAGATE_ERROR;
                      leg_ptw_stage_d = ptw_stage_q;
                    end
                  end
                end
              end
    
              // check if this access was actually allowed from a PMP perspective
              if (!allow_access) begin
                leg_tlb_update_valid = 1'b0;
                // we have to return the failed address in bad_addr
                leg_ptw_pptr_n = ptw_pptr_q;
                if (G6LCCfg.RVH) leg_ptw_stage_d = ptw_stage_q;
                leg_state_d = PROPAGATE_ACCESS_ERROR;
              end
  end

endmodule