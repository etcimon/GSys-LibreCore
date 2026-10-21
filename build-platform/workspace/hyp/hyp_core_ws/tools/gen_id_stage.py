# gen_id_stage.py — build hyp8 core/id_stage.sv from the sv-timing emit of
# <src>/core/id_stage.sv:
#   * scrub the sv-timing banner -> hyp8 ADAPTED provenance header
#   * apply the identity rename engine (same rules as materialize.py)
#   * add `parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8`
#   * decode: HypCfg.DecodeStages==1 keeps the original per-lane `decoder`
#     instances; ==3 splits each lane into s1 (context pack) -> reg -> s2
#     (instruction-bit decode) -> reg -> s3 (privilege/legality/exception),
#     feeding the existing ID->issue register.  hyp8 rank 4, +2 cycles.
#   * issue fill: ==1 keeps today's fills verbatim; ==3 drains the D2 stage
#     register (strict prefix, all-or-nothing per cycle) and moves the fetch
#     handshake to the D1 capture (upstream semantics: capture unconditional
#     on lane 0, fetch_entry_ready gated by ~stall_instr_fetch).
#   * macro/zcmt/cvxif sequencing: macro_decoder.issue_ack_i is driven by the
#     D1 fire of lane 0 (the "sub-op accepted into the pipe" event), which is
#     the staged analogue of the original issue_q[0] pop.
#
# Text-only generation (no tool runs). Every behavioural departure carries a
# `// hyp8:` marker.

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rename  # noqa: E402

ROOT = os.path.join("E:\\", rename.L)
SRC = os.path.join(ROOT, "build-platform", "workspace", "build", "sv-timing",
                   "hyp8-src", "emit", "core-8fo4", "corrected", "core",
                   "id_stage__svt.sv")
TGT = os.path.join(ROOT, "build-platform", "workspace", "hyp",
                   "hyp_redesign_core_8fo4", "core", "id_stage.sv")

t = open(SRC, encoding="utf-8").read()
t = rename.scrub_banner(t)
t = rename.apply_rename(t)

# -- header: ADAPTED provenance + modifications + SPDX ----------------------
t = t.replace(
    rename.BANNER_LINE,
    "// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)\n",
    1)
anchor = ("// Description: Instruction decode, contains the logic for decode,\n"
          "//              issue and read operands.\n")
assert anchor in t
t = t.replace(anchor, anchor + """//
// Modifications (c) 2026 Etienne Cimon: optional three-stage decode path
// (HypCfg.DecodeStages == 3): compressed/macro/Zcmt/CVXIF expansion context is
// captured into a D1 register, g6lc_decode_s2 (instruction-bit decode) feeds a
// D2 register, and g6lc_decode_s3 (privilege/CSR legality + exceptions) feeds
// the existing ID->issue register.  hyp8: rank-4 front-end depth cut, +2
// cycles of decode latency.  HypCfg.DecodeStages == 1 keeps the original
// single-cycle decoder composition.
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
""", 1)

# -- parameter: add HypCfg ---------------------------------------------------
p_old = "    parameter type x_compressed_resp_t = logic\n) ("
assert p_old in t
t = t.replace(p_old,
              "    parameter type x_compressed_resp_t = logic,\n"
              "    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = "
              "g6lc_hyp_pkg::Hyp8\n) (", 1)

# -- shared staged-path declarations ----------------------------------------
decl_anchor = """  // Decoder signals
  logic              [G6LCCfg.NrIssuePorts-1:0]       is_illegal_deco;
  logic              [G6LCCfg.NrIssuePorts-1:0][31:0] instruction_deco;
  logic              [G6LCCfg.NrIssuePorts-1:0]       is_compressed_deco;
"""
assert decl_anchor in t
t = t.replace(decl_anchor, decl_anchor + """
  // ------------------------------------------------------------------
  // hyp8 DecodeStages==3 stage registers (rank 4, +2 cycles).  D1 packs the
  // post-expansion/sequencer context (the g6lc_decode_s1 record plus the raw
  // fetch word the RVFI fields need); D2 holds the g6lc_decode_s2 candidate.
  // One global shift `dec_adv`: when the issue side cannot accept the whole
  // D2 prefix, all stage registers hold.
  typedef struct packed {
    logic [31:0]                                          instr;
    logic [31:0]                                          raw_instr;
    logic [15:0]                                          cinstr;
    logic                                                 is_compressed;
    logic                                                 is_illegal;
    logic                                                 is_macro;
    logic                                                 is_last_macro;
    logic                                                 is_double_macro;
    logic                                                 is_zcmt;
    logic [G6LCCfg.XLEN-1:0]                              jaddr;
    branchpredict_sbe_t                                   bp;
    exception_t                                           ex;
    logic [G6LCCfg.VLEN-1:0]                              pc;
    logic [((G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts))-1:0] hart;
  } d1_entry_t;
  typedef struct packed {
    scoreboard_entry_t                                    sbe;
    logic [31:0]                                          instr;
    logic [31:0]                                          tinst;
    logic [31:0]                                          raw_instr;
    logic [15:0]                                          cinstr;
    logic                                                 is_compressed;
    logic                                                 is_illegal;
    exception_t                                           ex;
    logic                                                 ecall;
    logic                                                 ebreak;
    logic                                                 frm_req;
    logic                                                 check_fprm;
    logic                                                 fp_hit;
    logic                                                 illegal;
    logic                                                 cf;
  } d2_entry_t;
  d1_entry_t [G6LCCfg.NrIssuePorts-1:0]  d1_q;
  d2_entry_t [G6LCCfg.NrIssuePorts-1:0]  d2_q;
  logic      [G6LCCfg.NrIssuePorts-1:0]  d1_vq, d2_vq;
  logic                                  dec_adv;
""", 1)

# -- decoder instantiation: two-mode generate --------------------------------
dec_start = t.index("  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin\n    decoder #(")
dec_end = t.index("  // G1hd: issued op is JALR")
dec_block = t[dec_start:dec_end]
# keep the original loop verbatim inside the DecodeStages==1 arm
STAGED = """  // hyp8: two decode organizations behind HypCfg.DecodeStages.  ==1 keeps
  // the original same-cycle decoder; ==3 registers the expansion context (D1)
  // and the instruction-bit decode (D2) so privilege/CSR legality (D3) sees
  // registered state -- rank-4 front-end depth, +2 cycles.
  if (HypCfg.DecodeStages == 1) begin : gen_dec1
""" + dec_block + """    assign dec_macro_ack = 1'b0;
  end else begin : gen_dec3
    // per-lane staged datapath: s1 (context pack) -> d1_q -> s2 -> d2_q -> s3
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_lane
      // D1 pack: the expansion chain's outputs for this lane
      g6lc_decode_s1 #(
          .G6LCCfg            (G6LCCfg),
          .branchpredict_sbe_t(branchpredict_sbe_t),
          .exception_t        (exception_t)
      ) i_d1 (
          .instruction_i              (instruction_deco[i]),
          .compressed_instr_i         (fetch_entry_i[i].instruction[15:0]),
          .is_compressed_i            (is_compressed_deco[i]),
          .is_illegal_i               (is_illegal_deco[i]),
          .is_macro_instr_i           (is_macro_instr[i]),
          .is_last_macro_instr_i      (is_last_macro_instr),
          .is_double_rd_macro_instr_i (is_double_rd_macro_instr),
          .is_zcmt_i                  (is_zcmt_instr[i]),
          .jump_address_i             (jump_address),
          .branch_predict_i           (fetch_entry_i[i].branch_predict),
          .ex_i                       (fetch_entry_i[i].ex),
          .pc_i                       (fetch_entry_i[i].address),
`ifdef G6LC_FETCH_B
          .smt_hart_id_i              (fetch_entry_i[i].hart_id),
`else
          .smt_hart_id_i              (smt_hart_id_i),
`endif
          .instruction_o              (d1_n[i].instr),
          .compressed_instr_o         (d1_n[i].cinstr),
          .is_compressed_o            (d1_n[i].is_compressed),
          .is_illegal_o               (d1_n[i].is_illegal),
          .is_macro_instr_o           (d1_n[i].is_macro),
          .is_last_macro_instr_o      (d1_n[i].is_last_macro),
          .is_double_rd_macro_instr_o (d1_n[i].is_double_macro),
          .is_zcmt_o                  (d1_n[i].is_zcmt),
          .jump_address_o             (d1_n[i].jaddr),
          .branch_predict_o           (d1_n[i].bp),
          .ex_o                       (d1_n[i].ex),
          .pc_o                       (d1_n[i].pc),
          .smt_hart_id_o              (d1_n[i].hart)
      );
      assign d1_n[i].raw_instr = fetch_entry_i[i].instruction;

      // D2: instruction-bit decode of the D1 register
      g6lc_decode_s2 #(
          .G6LCCfg            (G6LCCfg),
          .branchpredict_sbe_t(branchpredict_sbe_t),
          .exception_t        (exception_t),
          .scoreboard_entry_t (scoreboard_entry_t)
      ) i_d2 (
          .instruction_i              (d1_q[i].instr),
          .compressed_instr_i         (d1_q[i].cinstr),
          .is_compressed_i            (d1_q[i].is_compressed),
          .is_illegal_i               (d1_q[i].is_illegal),
          .is_macro_instr_i           (d1_q[i].is_macro),
          .is_last_macro_instr_i      (d1_q[i].is_last_macro),
          .is_double_rd_macro_instr_i (d1_q[i].is_double_macro),
          .is_zcmt_i                  (d1_q[i].is_zcmt),
          .jump_address_i             (d1_q[i].jaddr),
          .branch_predict_i           (d1_q[i].bp),
          .ex_i                       (d1_q[i].ex),
          .pc_i                       (d1_q[i].pc),
          .smt_hart_id_i              (d1_q[i].hart),
          .sbe_o                      (d2_n[i].sbe),
          .instr_o                    (d2_n[i].instr),
          .tinst_o                    (d2_n[i].tinst),
          .compressed_instr_o         (d2_n[i].cinstr),
          .is_compressed_o            (d2_n[i].is_compressed),
          .is_illegal_o               (d2_n[i].is_illegal),
          .ex_o                       (d2_n[i].ex),
          .ecall_o                    (d2_n[i].ecall),
          .ebreak_o                   (d2_n[i].ebreak),
          .frm_req_o                  (d2_n[i].frm_req),
          .check_fprm_o               (d2_n[i].check_fprm),
          .fp_hit_o                   (d2_n[i].fp_hit),
          .illegal_o                  (d2_n[i].illegal),
          .cf_o                       (d2_n[i].cf)
      );
      assign d2_n[i].raw_instr = d1_q[i].raw_instr;

      // D3: privilege/CSR legality + exception/interrupt/debug + final
      // scoreboard entry.  The per-hart context is selected by the hart id
      // recorded in the D2 register (the lane's own hart under mixed
      // residency -- the live fetch_entry may already hold a different lane).
      g6lc_decode_s3 #(
          .G6LCCfg            (G6LCCfg),
          .exception_t        (exception_t),
          .irq_ctrl_t         (irq_ctrl_t),
          .scoreboard_entry_t (scoreboard_entry_t),
          .interrupts_t       (interrupts_t),
          .INTERRUPTS         (INTERRUPTS)
      ) i_d3 (
          .dec_i                  (d2_q[i].sbe),
          .instr_i                (d2_q[i].instr),
          .tinst_i                (d2_q[i].tinst),
          .compressed_instr_i     (d2_q[i].cinstr),
          .is_compressed_i        (d2_q[i].is_compressed),
          .is_illegal_i           (d2_q[i].is_illegal),
          .ex_i                   (d2_q[i].ex),
          .pc_i                   (d2_q[i].sbe.pc),
          .ecall_i                (d2_q[i].ecall),
          .ebreak_i               (d2_q[i].ebreak),
          .frm_req_i              (d2_q[i].frm_req),
          .check_fprm_i           (d2_q[i].check_fprm),
          .fp_hit_i               (d2_q[i].fp_hit),
          .illegal_i              (d2_q[i].illegal),
          .cf_i                   (d2_q[i].cf),
          .debug_req_i            (debug_req_i),
`ifdef G6LC_MUT_DECODE_ACTIVE_IRQ
          .irq_ctrl_i             (irq_ctrl_i),
          .irq_i                  (irq_i),
`else
          .irq_ctrl_i             (SMT_MIXED_DECODE ? irq_ctrl_b_i[d2_q[i].sbe.hart_id] : irq_ctrl_i),
          .irq_i                  (SMT_MIXED_DECODE ? irq_b_i[d2_q[i].sbe.hart_id] : irq_i),
`endif
          .priv_lvl_i             (SMT_MIXED_DECODE ? priv_lvl_b_i[d2_q[i].sbe.hart_id] : priv_lvl_i),
          .v_i                    (SMT_MIXED_DECODE ? v_b_i[d2_q[i].sbe.hart_id] : v_i),
          .debug_mode_i           (SMT_MIXED_DECODE ? debug_mode_b_i[d2_q[i].sbe.hart_id] : debug_mode_i),
          .fs_i                   (SMT_MIXED_DECODE ? fs_b_i[d2_q[i].sbe.hart_id] : fs_i),
          .vfs_i                  (SMT_MIXED_DECODE ? vfs_b_i[d2_q[i].sbe.hart_id] : vfs_i),
          .frm_i                  (SMT_MIXED_DECODE ? frm_b_i[d2_q[i].sbe.hart_id] : frm_i),
          .vs_i                   (SMT_MIXED_DECODE ? vs_b_i[d2_q[i].sbe.hart_id] : vs_i),
          .tvm_i                  (SMT_MIXED_DECODE ? tvm_b_i[d2_q[i].sbe.hart_id] : tvm_i),
          .tw_i                   (SMT_MIXED_DECODE ? tw_b_i[d2_q[i].sbe.hart_id] : tw_i),
          .vtw_i                  (SMT_MIXED_DECODE ? vtw_b_i[d2_q[i].sbe.hart_id] : vtw_i),
          .tsr_i                  (SMT_MIXED_DECODE ? tsr_b_i[d2_q[i].sbe.hart_id] : tsr_i),
          .hu_i                   (SMT_MIXED_DECODE ? hu_b_i[d2_q[i].sbe.hart_id] : hu_i),
          .mcbie_i                (SMT_MIXED_DECODE ? mcbie_b_i[d2_q[i].sbe.hart_id] : mcbie_i),
          .scbie_i                (SMT_MIXED_DECODE ? scbie_b_i[d2_q[i].sbe.hart_id] : scbie_i),
          .hcbie_i                (SMT_MIXED_DECODE ? hcbie_b_i[d2_q[i].sbe.hart_id] : hcbie_i),
          .mcbcfe_i               (SMT_MIXED_DECODE ? mcbcfe_b_i[d2_q[i].sbe.hart_id] : mcbcfe_i),
          .scbcfe_i               (SMT_MIXED_DECODE ? scbcfe_b_i[d2_q[i].sbe.hart_id] : scbcfe_i),
          .hcbcfe_i               (SMT_MIXED_DECODE ? hcbcfe_b_i[d2_q[i].sbe.hart_id] : hcbcfe_i),
          .mcbze_i                (SMT_MIXED_DECODE ? mcbze_b_i[d2_q[i].sbe.hart_id] : mcbze_i),
          .scbze_i                (SMT_MIXED_DECODE ? scbze_b_i[d2_q[i].sbe.hart_id] : scbze_i),
          .hcbze_i                (SMT_MIXED_DECODE ? hcbze_b_i[d2_q[i].sbe.hart_id] : hcbze_i),
          .instruction_o          (decoded_instruction[i]),
          .orig_instr_o           (orig_instr[i]),
          .is_control_flow_instr_o(is_control_flow_instr[i]),
          .debug_from_trigger_i   (debug_from_trigger_i)
      );
    end

    // stage registers + global shift.  dec_adv is computed by the issue-fill
    // comb block (this module's only ordering owner) and pulses when the whole
    // D2 prefix can move into issue_q or D2 is empty.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        d1_q  <= '0;
        d2_q  <= '0;
        d1_vq <= '0;
        d2_vq <= '0;
      end else if (flush_i) begin
        // hyp8: the staged pipe has no flush_unissued_i port on this module --
        // flush_i is the only kill and clears both stage registers.
        d1_vq <= '0;
        d2_vq <= '0;
      end else if (dec_adv) begin
        for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
          d2_q[i]  <= d2_n[i];
          d2_vq[i] <= d1_vq[i];
          if (fetch_entry_valid_i[i] &&
              ((i == 0) || ~stall_instr_fetch[i])) begin
            // hyp8 lane-0 capture is unconditional on the sequencer stall so
            // macro/Zcmt/CVXIF sub-operations flow through the pipe exactly
            // once (upstream issue-register semantics); the fetch entry is
            // only consumed when ~stall_instr_fetch (see fetch_entry_ready_o).
            d1_q[i]  <= d1_n[i];
            // capture-time validity: same formula as today's
            // decoded_instruction_valid (Zcmt/CVXIF stall marks bubbles)
            d1_vq[i] <= decoded_instruction_valid[i];
          end else begin
            d1_vq[i] <= 1'b0;
          end
        end
      end
    end

    // fetch consumption moved to the D1 capture: a fetch entry leaves the
    // queue when its bundle enters the D1 register and no sequencer stall is
    // pending.  Lane 0 macro/Zcmt sub-ops keep the entry pinned
    // (~stall only on the last emission), matching upstream.
    always_comb begin
      fetch_entry_ready_o = '0;
      if (dec_adv) begin
        for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
          if (fetch_entry_valid_i[i] && ~stall_instr_fetch[i])
            fetch_entry_ready_o[i] = 1'b1;
        end
      end
    end

    // macro sequencer: its issue_ack_i is the D1 fire of lane 0 -- the
    // sub-operation leaving D1 is the staged analogue of the original
    // issue_q[0] pop (the FSM presents the next sub-op on the same edge, which
    // is what the D1 reload captures).
    assign dec_macro_ack = dec_adv && d1_vq[0];
  end
"""

t = t[:dec_start] + STAGED + t[dec_end:]

# add d1_n/d2_n + dec_macro_ack declarations next to the stage regs
t = t.replace("""  d1_entry_t [G6LCCfg.NrIssuePorts-1:0]  d1_q;
  d2_entry_t [G6LCCfg.NrIssuePorts-1:0]  d2_q;
  logic      [G6LCCfg.NrIssuePorts-1:0]  d1_vq, d2_vq;
  logic                                  dec_adv;
""",
"""  d1_entry_t [G6LCCfg.NrIssuePorts-1:0]  d1_q, d1_n;
  d2_entry_t [G6LCCfg.NrIssuePorts-1:0]  d2_q, d2_n;
  logic      [G6LCCfg.NrIssuePorts-1:0]  d1_vq, d2_vq;
  logic                                  dec_adv;
  logic                                  dec_macro_ack;
""", 1)

# -- macro decoder issue_ack: staged mode uses the D1 fire -------------------
old_ack = ".issue_ack_i               (issue_instr_ack_i[0]),"
assert old_ack in t
t = t.replace(old_ack,
              ".issue_ack_i               (HypCfg.DecodeStages == 3 ? dec_macro_ack\n"
              "                                        : issue_instr_ack_i[0]),", 1)

# fetch_entry_ready_o must not be driven by the issue-fill combs in staged
# mode (the D1-capture comb in gen_dec3 owns it there).
for rold in ("""      issue_n = issue_q;
      fetch_entry_ready_o = '0;
      took_fetch = 1'b0;
""",
             """    always_comb begin
      issue_n = issue_q;
      fetch_entry_ready_o = '0;
"""):
    assert rold in t, rold[:60]
if True:
    t = t.replace("""      issue_n = issue_q;
      fetch_entry_ready_o = '0;
      took_fetch = 1'b0;
""",
                  """      issue_n = issue_q;
      // hyp8: DecodeStages==3 drives fetch_entry_ready_o from the D1 capture
      // comb (gen_dec3); this block only owns it in the 1-stage path.
      if (HypCfg.DecodeStages == 1) fetch_entry_ready_o = '0;
      took_fetch = 1'b0;
""", 1)
    t = t.replace("""    always_comb begin
      issue_n = issue_q;
      fetch_entry_ready_o = '0;
""",
                  """    always_comb begin
      issue_n = issue_q;
      if (HypCfg.DecodeStages == 1) fetch_entry_ready_o = '0;
""", 1)

# -- superscalar fill: split by DecodeStages ----------------------------------
fill_old = """      // Fill empty tail from fetch ports as a *strict prefix* starting at
      // fetch port 0. Never skip a stalled/invalid earlier fetch port to take
      // a later one — instr_queue only pops/advances PC on a fire prefix from
      // port 0 (non-prefix ready[1]&&!ready[0] drops the second IQ slot).
      rptr = 0;
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        if (!issue_n[i].valid) begin
          took_fetch = 1'b0;
          if (rptr < G6LCCfg.NrIssuePorts && fetch_entry_valid_i[rptr] &&
              !fetch_entry_ready_o[rptr] && ~stall_instr_fetch[rptr]) begin
            fetch_entry_ready_o[rptr] = 1'b1;
            issue_n[i] = '{
                decoded_instruction_valid[rptr],
                decoded_hd[rptr],
                orig_instr[rptr],
                is_cf_hd[rptr],
                is_compressed_rvc[rptr] ? {16'b0, fetch_entry_i[rptr].instruction[15:0]} : fetch_entry_i[rptr].instruction,
                is_compressed_rvc[rptr]
            };
            rptr = rptr + 1;
            took_fetch = 1'b1;
          end else begin
            // Gap in the fetch stream: stop filling further issue slots.
            break;
          end
        end
      end
"""
assert fill_old in t, "superscalar fill anchor"
fill_new = """      if (HypCfg.DecodeStages == 1) begin
        // Fill empty tail from fetch ports as a *strict prefix* starting at
        // fetch port 0. Never skip a stalled/invalid earlier fetch port to take
        // a later one — instr_queue only pops/advances PC on a fire prefix from
        // port 0 (non-prefix ready[1]&&!ready[0] drops the second IQ slot).
        rptr = 0;
        for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
          if (!issue_n[i].valid) begin
            took_fetch = 1'b0;
            if (rptr < G6LCCfg.NrIssuePorts && fetch_entry_valid_i[rptr] &&
                !fetch_entry_ready_o[rptr] && ~stall_instr_fetch[rptr]) begin
              fetch_entry_ready_o[rptr] = 1'b1;
              issue_n[i] = '{
                  decoded_instruction_valid[rptr],
                  decoded_hd[rptr],
                  orig_instr[rptr],
                  is_cf_hd[rptr],
                  is_compressed_rvc[rptr] ? {16'b0, fetch_entry_i[rptr].instruction[15:0]} : fetch_entry_i[rptr].instruction,
                  is_compressed_rvc[rptr]
              };
              rptr = rptr + 1;
              took_fetch = 1'b1;
            end else begin
              // Gap in the fetch stream: stop filling further issue slots.
              break;
            end
          end
        end
        dec_adv = 1'b0;
      end else begin
        // hyp8 DecodeStages==3: drain the D2 prefix into the free issue
        // slots.  The whole pipe shifts together (dec_adv): D2 unloads only
        // when every valid lane has a free slot, otherwise all three stages
        // hold.  fetch_entry_ready_o is driven by the D1-capture comb in
        // gen_dec3, not here.
        int unsigned nd2;
        nd2 = 0;
        for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++)
          nd2 = nd2 + int'(d2_vq[i]);
        dec_adv = (nd2 == 0) || (wptr + nd2 <= G6LCCfg.NrIssuePorts);
        if (dec_adv) begin
          rptr = 0;
          for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
            if (!issue_n[i].valid) begin
              if (rptr < G6LCCfg.NrIssuePorts && d2_vq[rptr]) begin
                issue_n[i] = '{
                    1'b1,
                    decoded_hd[rptr],
                    orig_instr[rptr],
                    is_cf_hd[rptr],
                    d2_q[rptr].is_compressed ? {16'b0, d2_q[rptr].cinstr} : d2_q[rptr].raw_instr,
                    d2_q[rptr].is_compressed
                };
                rptr = rptr + 1;
              end else begin
                break;
              end
            end
          end
        end
      end
"""
t = t.replace(fill_old, fill_new, 1)

# scalar fill: split by DecodeStages
fill1_old = """      if (!issue_n[0].valid && fetch_entry_valid_i[0]) begin
        fetch_entry_ready_o[0] = ~stall_instr_fetch[0];
        issue_n[0] = '{
            decoded_instruction_valid[0],
            decoded_hd[0],
            orig_instr[0],
            is_cf_hd[0],
            is_compressed_rvc[0] ? {16'b0, fetch_entry_i[0].instruction[15:0]} : fetch_entry_i[0].instruction,
            is_compressed_rvc[0]
        };
      end
"""
assert fill1_old in t, "scalar fill anchor"
fill1_new = """      if (HypCfg.DecodeStages == 1) begin
        if (!issue_n[0].valid && fetch_entry_valid_i[0]) begin
          fetch_entry_ready_o[0] = ~stall_instr_fetch[0];
          issue_n[0] = '{
              decoded_instruction_valid[0],
              decoded_hd[0],
              orig_instr[0],
              is_cf_hd[0],
              is_compressed_rvc[0] ? {16'b0, fetch_entry_i[0].instruction[15:0]} : fetch_entry_i[0].instruction,
              is_compressed_rvc[0]
          };
        end
        dec_adv = 1'b0;
      end else begin
        // hyp8 DecodeStages==3: D2 drains into issue_q[0] when the slot is
        // free (post-ack); the whole pipe shifts on dec_adv.  Fetch handshake
        // lives at the D1 capture in gen_dec3.
        dec_adv = ~d2_vq[0] || !issue_n[0].valid;
        if (dec_adv && d2_vq[0] && !issue_n[0].valid) begin
          issue_n[0] = '{
              1'b1,
              decoded_hd[0],
              orig_instr[0],
              is_cf_hd[0],
              d2_q[0].is_compressed ? {16'b0, d2_q[0].cinstr} : d2_q[0].raw_instr,
              d2_q[0].is_compressed
          };
        end
      end
"""
t = t.replace(fill1_old, fill1_new, 1)

# -- smt_pause_hint: staged mode must compare the *issuing* instruction ------
ph_old = """  always_comb begin
    smt_pause_hint_o = '0;
    if (G6LCCfg.ZihintpauseEn && G6LCCfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        if (fetch_entry_valid_i[i] && issue_instr_ack_i[i] &&
            instruction_deco[i] == 32'h0100_000F) begin
          smt_pause_hint_o[fetch_entry_i[i].hart_id] = 1'b1;
        end
      end
    end
  end
"""
assert ph_old in t, "pause hint anchor"
ph_new = """  always_comb begin
    smt_pause_hint_o = '0;
    if (G6LCCfg.ZihintpauseEn && G6LCCfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
        if (HypCfg.DecodeStages == 1) begin
          if (fetch_entry_valid_i[i] && issue_instr_ack_i[i] &&
              instruction_deco[i] == 32'h0100_000F) begin
            smt_pause_hint_o[fetch_entry_i[i].hart_id] = 1'b1;
          end
        end else begin
          // hyp8: in the staged path instruction_deco is three cycles ahead of
          // issue; pulse on the instruction actually leaving issue_q (PAUSE is
          // never compressed, so orig_instr holds the raw encoding).
          if (issue_q[i].valid && issue_instr_ack_i[i] &&
              issue_q[i].orig_instr == 32'h0100_000F) begin
            smt_pause_hint_o[issue_q[i].sbe.hart_id] = 1'b1;
          end
        end
      end
    end
  end
"""
t = t.replace(ph_old, ph_new, 1)

# sanity: no leftover identity tokens
resid = [l for l in t.split("\n")
         if rename._RESID.search(l)]
assert not resid, resid[:10]

with open(TGT, "w", encoding="utf-8", newline="\n") as f:
    f.write(t)
print("id_stage.sv written:", len(t.split("\n")), "lines")


# keep tools/ free of compiled bytecode (the identity grep covers every
# file type — *.pyc embeds the original source tokens)
def _cleanup_pycache():
    import pathlib as _pl
    import shutil as _sh
    _d = _pl.Path(__file__).resolve().parent
    _sh.rmtree(_d / "__pycache__", ignore_errors=True)
    for _f in _d.glob("*.pyc"):
        try:
            _f.unlink()
        except OSError:
            pass


_cleanup_pycache()
