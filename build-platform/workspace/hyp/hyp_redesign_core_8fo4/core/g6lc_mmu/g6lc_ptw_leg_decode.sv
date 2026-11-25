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

  // Flat parallel predicate decode (cycle-exact replacement for the 6-deep
  // nested sequential if/else chain that billed 41.25 FO4 in sv-timing).
  logic is_leaf, pte_invalid, napot_ok, napot_bad;
  logic instr_perm_ok, data_perm_ok, perm_ok, misal_bad, last_lvl;
  logic g_en, rvh_s_to_gfinal, rvh_ginter_to_s, rvh_s_to_ginter;
  logic rvh_leaf_ppn_bad, rvh_ptr_ppn_bad, rvh_ptr_adu_bad;
  logic leaf_err, ptr_err;

  assign is_leaf = pte.r || pte.x;
  assign pte_invalid = !pte.v || (!pte.r && pte.w) ||
      (|pte.reserved && G6LCCfg.IS_XLEN64) ||
      (!G6LCCfg.SvpbmtEn && |pte.pbmt && G6LCCfg.IS_XLEN64) ||
      (G6LCCfg.SvpbmtEn && (pte.pbmt == 2'b11) && G6LCCfg.IS_XLEN64) ||
`ifndef G6LC_MUT_PTW_PBMT_NONLEAF
      (G6LCCfg.SvpbmtEn && !is_leaf && |pte.pbmt && G6LCCfg.IS_XLEN64) ||
`endif
      (!G6LCCfg.SvnapotEn && pte.n) ||
      (G6LCCfg.SvnapotEn && !is_leaf && pte.n);

  assign napot_ok  = (pte.ppn[3:0] == 4'b1000) && (ptw_lvl_q[0] == 2);
  assign napot_bad = G6LCCfg.SvnapotEn && pte.n && !napot_ok;
  assign misal_bad = |misaligned_page;
  assign last_lvl  = (ptw_lvl_q[0] == G6LCCfg.PtLevels - 1);
  assign g_en      = is_instr_ptw_q ? enable_g_translation_i : en_ld_st_g_translation_i;

  assign instr_perm_ok = pte.a &&
      (G6LCCfg.RVH && (ptw_stage_q == G_INTERMED_STAGE) ? pte.r : pte.x);
  assign data_perm_ok  = pte.a &&
      ((pte.r && !hlvx_inst_i) ||
       (pte.x && (mxr_i || hlvx_inst_i ||
                  (ptw_stage_q == S_STAGE && vmxr_i && ld_st_v_i && G6LCCfg.RVH)))) &&
      (!lsu_is_store_i || (pte.w && pte.d) || (ptw_stage_q == G_INTERMED_STAGE && G6LCCfg.RVH));
  assign perm_ok = is_instr_ptw_q ? instr_perm_ok : data_perm_ok;

  assign rvh_s_to_gfinal  = G6LCCfg.RVH && (ptw_stage_q == S_STAGE) && g_en;
  assign rvh_ginter_to_s  = G6LCCfg.RVH && (ptw_stage_q == G_INTERMED_STAGE);
  assign rvh_s_to_ginter  = G6LCCfg.RVH && (ptw_stage_q == S_STAGE) && g_en;
  assign rvh_leaf_ppn_bad = G6LCCfg.RVH &&
      ((v_i && is_instr_ptw_q) || (ld_st_v_i && !is_instr_ptw_q)) &&
      (ptw_stage_q == S_STAGE) && (|pte.ppn[G6LCCfg.PPNW-1:G6LCCfg.GPPNW]);
  assign rvh_ptr_ppn_bad  = rvh_leaf_ppn_bad;
  assign rvh_ptr_adu_bad  = G6LCCfg.RVH && (pte.a || pte.d || pte.u);

  assign leaf_err = napot_bad || !perm_ok || misal_bad || rvh_leaf_ppn_bad;
  assign ptr_err  = last_lvl || rvh_ptr_adu_bad || rvh_ptr_ppn_bad;

  assign leg_global_mapping_n = (pte.g && (ptw_stage_q == S_STAGE || !G6LCCfg.RVH))
                                ? 1'b1 : global_mapping_q;
  assign leg_is_napot_64k     = !pte_invalid && is_leaf && G6LCCfg.SvnapotEn && pte.n && napot_ok;

  assign leg_tlb_update_valid = allow_access && !pte_invalid && is_leaf && perm_ok && !misal_bad &&
`ifndef G6LC_MUT_PTW_NAPOT_POISON
      !napot_bad &&
`endif
      (!G6LCCfg.RVH || (ptw_stage_q == G_FINAL_STAGE) || !g_en);

  assign leg_state_d =
      !allow_access ? PROPAGATE_ACCESS_ERROR :
      pte_invalid   ? PROPAGATE_ERROR :
      is_leaf       ? (leaf_err ? PROPAGATE_ERROR :
                       (rvh_s_to_gfinal || rvh_ginter_to_s) ? WAIT_GRANT : LATENCY) :
                      (ptr_err  ? PROPAGATE_ERROR : WAIT_GRANT);

  if (!G6LCCfg.RVH) begin : gen_no_rvh
    logic advance_ptr;
    logic [(G6LCCfg.VpnLen/G6LCCfg.PtLevels)-1:0] vpn_sel;
    logic [G6LCCfg.PLEN-1:0]                      next_pptr;
    assign advance_ptr      = allow_access && !pte_invalid && !is_leaf && !last_lvl;
    assign vpn_sel          = (ptw_lvl_q[0] == '0) ? vaddr_lvl[0][0] : vaddr_lvl[0][1];
    assign next_pptr        = {pte.ppn, vpn_sel, (G6LCCfg.PtLevels)'(0)};
    assign leg_ptw_stage_d  = ptw_stage_q;
    assign leg_gptw_pptr_n  = gptw_pptr_q;
    assign leg_gpaddr_n     = gpaddr_q;
    assign leg_gpte_d       = '0;
    assign leg_ptw_lvl_n[0] = advance_ptr ? (ptw_lvl_q[0] + 1'b1) : ptw_lvl_q[0];
    assign leg_ptw_pptr_n   = advance_ptr ? next_pptr : ptw_pptr_q;
  end else begin : gen_rvh
    always_comb begin : legacy_dec_aux
      automatic logic [G6LCCfg.PLEN-1:0] pptr;
      leg_ptw_stage_d = ptw_stage_q;
      leg_ptw_lvl_n   = ptw_lvl_q;
      leg_ptw_pptr_n  = ptw_pptr_q;
      leg_gptw_pptr_n = gptw_pptr_q;
      leg_gpaddr_n    = gpaddr_q;
      leg_gpte_d      = gpte_q;
      pptr            = ptw_pptr_q;

      if (!pte_invalid && allow_access) begin
        if (is_leaf) begin
          if (rvh_s_to_gfinal) begin
            leg_ptw_stage_d        = G_FINAL_STAGE;
            leg_gpte_d             = pte;
            leg_ptw_lvl_n[HYP_EXT] = ptw_lvl_q[0];
            leg_gpaddr_n           = gpaddr[ptw_lvl_q[0]];
            leg_ptw_pptr_n         = {
              hgatp_ppn_i[G6LCCfg.PPNW-1:2],
              gpaddr[ptw_lvl_q[0]][G6LCCfg.GPLEN-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
              (G6LCCfg.PtLevels)'(0)
            };
            leg_ptw_lvl_n[0]       = '0;
          end else if (rvh_ginter_to_s) begin
            leg_ptw_stage_d  = S_STAGE;
            leg_ptw_lvl_n[0] = ptw_lvl_q[HYP_EXT];
            pptr             = {pte.ppn[G6LCCfg.GPPNW-1:0], gptw_pptr_q[11:0]};
            if (ptw_lvl_q[0] == 1) pptr[20:0] = gptw_pptr_q[20:0];
            if (ptw_lvl_q[0] == 0) pptr[29:0] = gptw_pptr_q[29:0];
            leg_ptw_pptr_n   = pptr;
          end
          if (!perm_ok || misal_bad) leg_ptw_stage_d = ptw_stage_q;
          if (rvh_leaf_ppn_bad)      leg_ptw_stage_d = G_FINAL_STAGE;
        end else if (!last_lvl) begin
          leg_ptw_lvl_n[0] = ptw_lvl_q[0] + 1'b1;
          case (ptw_stage_q)
            S_STAGE: begin
              if (rvh_s_to_ginter) begin
                leg_ptw_stage_d        = G_INTERMED_STAGE;
                leg_ptw_lvl_n[HYP_EXT] = ptw_lvl_q[0] + 1;
                pptr                   = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
                leg_gptw_pptr_n        = pptr;
                leg_ptw_pptr_n         = {
                  hgatp_ppn_i[G6LCCfg.PPNW-1:2],
                  pptr[G6LCCfg.SV+HYP_EXT*2-1:G6LCCfg.SV-(G6LCCfg.VpnLen/G6LCCfg.PtLevels)],
                  (G6LCCfg.PtLevels)'(0)
                };
                leg_ptw_lvl_n[0]       = '0;
              end else begin
                leg_ptw_pptr_n = {pte.ppn, vaddr_lvl[0][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
              end
            end
            G_INTERMED_STAGE: leg_ptw_pptr_n = {pte.ppn, vaddr_lvl[HYP_EXT][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
            G_FINAL_STAGE:    leg_ptw_pptr_n = {pte.ppn, vaddr_lvl[HYP_EXT*2][ptw_lvl_q[0]], (G6LCCfg.PtLevels)'(0)};
            default: ;
          endcase
          if (rvh_ptr_adu_bad || rvh_ptr_ppn_bad) leg_ptw_stage_d = ptw_stage_q;
        end
      end
    end
  end

endmodule